# An index on a big table is built outside a transaction

**Status:** accepted
**Topic:** [sql-migrations](../design/sql-migrations.md)
**Extends:** [ADR 123](./123-a-migration-is-a-diff-against-a-snapshot.md) (a version is one transaction, except one marked otherwise), [ADR 240](./240-a-migration-waits-five-seconds-for-a-table.md) (the migration lock is asked for and not waited for)

## Context

Every version is one transaction (ADR 123), and Postgres refuses `CREATE INDEX CONCURRENTLY` inside one. So the `create_index` the diff writes for a table that already has rows takes a `SHARE` lock, and every insert, update and delete on the table waits until the build ends. On a table of a few thousand rows that is milliseconds; on fifty million it is an outage, and the step's `why` said so without offering a way out. The way out is a step that runs outside the version's transaction and is recorded in the ledger on its own, and two things about Postgres decide its shape.

**A `CONCURRENTLY` build that fails halfway leaves its index behind**, in the catalog with `indisvalid = false`: never used by a query, maintained by every write, and in the way of the next attempt, whose `CREATE INDEX` of that name fails with "already exists". A unique index over rows that repeat fails exactly this way. `IF NOT EXISTS`, the obvious way to make the step safe to run again, passes over the invalid index without a word and reports success.

**A build waits for every statement in the database that began before it and is still running**, not only those on its table. So anything that sits in a statement waiting for a lock the building session holds is waited for by the build, and the two deadlock. Postgres ends one of them with `40P01`, which can be the build. This is not a corner: the migration's own advisory lock, taken by `pg_advisory_xact_lock` in the other replicas, is that statement.

## Decision

**A `Version` may say `.transactional = false`: its steps run one at a time on one held connection with no `BEGIN`, and the ledger row is written after the last.** `migrate.apply` branches to `applyOutside` on it. Postgres only: on SQLite, where a write holds the whole file whatever it is and nothing is refused inside a transaction, a version marked so is `error.NotTransactional` and nothing is applied. The flag is not in the hash, as `lock_timeout_ms is not` (ADR 240).

### How a step outside the transaction is recorded when the version around it fails

**There is no version around it.** A version is either in a transaction or outside one, never both, and `generate` cuts a plan in two when it is asked to: the steps that stay, as version N, and the named `CREATE INDEX CONCURRENTLY` steps as version N+1, `<name>_concurrently`, after it (`Plan.splitOutside`). The ledger records each on its own because each is a version, and no new column or table is needed. When every new index is named there is no N, and the only version written is the outside one.

What each failure leaves:

| failure | the database | the ledger | the next run |
|---|---|---|---|
| version N fails | nothing kept (its transaction) | no row for N | N runs again; N+1 never started, since versions apply in order |
| N+1 fails at its first step | N is committed | row for N, none for N+1 | N+1 runs |
| N+1 fails after some steps | those indexes are built and valid; the one that failed may be invalid | none for N+1 | N+1 runs whole; valid indexes are passed over, the invalid one dropped and built again |
| the process dies mid-build | as above; the connection closing releases the lock | as above | as above |

**A version outside a transaction is retried whole, so its steps have to be safe to run twice.** The generated ones are: `CREATE [UNIQUE] INDEX CONCURRENTLY IF NOT EXISTS`, and the invalid index of a failed build is dropped first (`dropInvalid`). A step of the person's own in such a version is theirs to make repeatable, and the version file's header says so.

**The database is a version behind the binary until the build ends**, and `expect` refuses to serve it meanwhile. That is deliberate and not free: a missing index rarely makes a deploy unsafe, and a boot that waits for a long build is a cost the person chose by naming it. See the open question below.

### The invalid index is dropped, not refused

Before each step that has an `index` (the quoted, qualified name `generate` writes into the version file), `applyOutside` asks `pg_index.indisvalid` through `to_regclass`. Invalid: `DROP INDEX CONCURRENTLY IF EXISTS`, with a `warn` line naming it, and the build goes on. Absent or valid: nothing, and `IF NOT EXISTS` passes over the valid one (a build that finished before the ledger row did).

An invalid index holds nothing worth keeping, and refusing would turn one failed deploy into a boot that fails identically until somebody connects with `psql`. The cost is that a person's own invalid index of that name is dropped as well; a version that builds an index of that name says what the index is, and an invalid one is no index. The drop is concurrent so that it does not itself take the table's strongest lock.

### One lock, asked for and not waited for

`applyOutside` holds a connection with no transaction, so the lock is the session-level `pg_try_advisory_lock` on the same key the transaction form uses, and a version in a transaction and one outside it wait for each other. It is let go on every way out of the function, because it outlives a statement and the connection goes back to the pool.

**Every migration lock is now asked for, not waited for** (`migrate.polled`): `pg_try_advisory_xact_lock` (`Dialect.advisoryLock`) and its session twin, asked again after `SELECT pg_sleep(0.2)` (`Dialect.lock_pause`) until the answer is true. A free lock costs one statement, as before. This was found by a test, not by reading: two replicas applying the same outside version deadlocked with `40P01`, the second sitting in `pg_advisory_lock` while the first's build waited for it. The same hazard is between a build and any ordinary version's blocking lock, so the transaction form changed with it. Postgres's `lock_timeout` no longer bounds the wait for this lock, and it never covered it in the transaction form (ADR 240 sets it after the lock).

### The held connection is `Begin.transaction = false`

`wire.Begin` gets `transaction: bool = true`. Postgres skips the `BEGIN`; `commit` and `rollback` send nothing and give the connection back. SQLite refuses it while compiling. It is a public option of `db.begin` and the doc comment says what it is for and that the caller undoes session state before releasing.

### A build is not bound by `lock_timeout`

**The steps of an outside version run with `lock_timeout` at 0, and the connection's own value is put back after.** ADR 240's bound is a setting of the transaction `apply` opens, so the held connection would otherwise carry the one its URL or role gave it (a few seconds in a production role that follows the usual advice, ten in the test suite, ADR 239). `applyOutside` reads `current_setting('lock_timeout')`, sets `0` for the session (`Dialect.session_lock_timeout_set`), and sets the value back on every way out, because the connection returns to the pool.

The reason is what the wait is. A `CREATE INDEX CONCURRENTLY` waits for every transaction in the database that began before it (`WaitForOlderSnapshots`, per database), and Postgres counts that as a lock wait. The transaction waited for is not blocked by it, and nothing queues behind the build: writers carry on, which is the point of the version. What a bound buys ADR 240's version, protecting everyone queued behind a step, buys nothing here, and it costs a boot that fails on every attempt for as long as an analytics query or a stuck session lasts, with `expect` refusing to serve meanwhile. The one lock the build does ask for, `SHARE UPDATE EXCLUSIVE` on the table, conflicts with DDL and `VACUUM` only, so a wait for it queues those and no reads or writes. The backstops are the operator's `statement_timeout` and the deploy's own deadline; `Version.lock_timeout_ms` stays what it is for a version in a transaction. Found when the build failed with `Locked` under load in the live suite, where the other optimize mode's transactions were the older ones, and held by `live.zig` ("a build waits out a transaction older than itself"): a sleeping statement older than the build, a connection limited to one second, and the build completes after the sleep and leaves the one second in place.

The live tests of this ADR run in a database of their own per optimize mode (`nilo_live_concurrently_<mode>`, created when absent; they skip with a line where the role cannot create one), so no other test's transaction is older than a build. That replaces the lock between the two modes the tests had, which existed for the same wait: the modes no longer share a database.

### Asking for it: `db generate --concurrently <index>,…`

**The person names the index.** Whether a table is big enough for a blocking build to matter is a fact about the database the migration will meet, which the repository does not hold. Each `create_index` for a table that exists says in its `why` how to ask (`--concurrently orders_org_id_idx`); a name that matches no index the diff creates on an existing table holds the whole version back, as a `--drop` that names nothing does. An index on a table the same plan creates is in the `CREATE TABLE`'s version, where there is nothing to block.

The outside version's file says `.transactional = false`, each step carries `.index`, and its `.sql` twin has no `BEGIN` or `COMMIT`, drops the invalid index by psql's `\gexec` before each build, and keeps the ledger row last. A SQLite twin of a version so marked is an ordinary one.

## What it costs

- **Allocations per request**: none. This runs at boot or from the command line.
- **Memory per idle connection**: none.
- **Throughput and p99**: none on the request path. A build outside a transaction takes longer than the blocking one, because Postgres scans the table twice and waits for older transactions between the scans: on a table of one million rows of `md5` text, 1.07 to 2.3 times as long as the blocking build, while 622 to 1,106 writes got through it where the blocking build let through 0 to 7 (`live.zig`, Postgres 18, both optimize modes, same afternoon, [`bench/result/sql.md`](../../bench/result/sql.md)). A free lock costs one statement as before; a contended one polls every 200 ms, so a replica that waited learns of a release up to 200 ms late.
- **Binary size**: `applyOutside`, `dropInvalid`, `polled` and a few constants, in a program that links the migrator.

## What was rejected

- **Making every index on an existing table concurrent.** It splits every ordinary `generate` that adds an index into two versions, doubles the scans for the tables where a blocking build costs milliseconds, adds the invalid-index failure to a path that never had it, and cannot be undone by the person who knows the table is small.
- **A word in the Row's marker** (`.index = .{ .org_id, .concurrently }`). It would put migration mechanics in the type for ever, after the index exists and the word means nothing, and the snapshot would have to ignore it when comparing.
- **One version with an outside step in it.** Then the ledger must say that the version is applied except for one step: a row per step (a new key and a new column in `nilo_migrations`, a break for every existing ledger), or a version recorded before its last step ran and trusted afterwards. Two versions use the ledger as it is.
- **Refusing when an invalid index is found**, as above.
- **`IF NOT EXISTS` alone**, which records the version over an index that does nothing.
- **A transaction held only for its advisory lock**, with the steps on other connections. It needs a pool of at least two, and a database with `idle_in_transaction_session_timeout` ends the lock a long build outlives. A held connection with no transaction is never idle in one.
- **A blocking `pg_advisory_lock` on the held connection.** It deadlocked with the build in the test above.
- **A sleep in Zig between asks.** The migrator holds no `Io`, and ADR 240 rejected a retry loop for that reason; the pause is the database's.
- **Running the outside version in the same boot transaction's connection after `COMMIT`.** The connection goes back to the pool at the commit; there is no later moment at which it is still the caller's.

## Open

- **Serving while a build is pending.** A binary whose only missing version is a `CONCURRENTLY` index cannot say "serve anyway". Nothing in the ledger distinguishes it from a missing table.
- **A redefined index** (same name, other columns) is dropped by version N and built by N+1, so queries that used it go without while N+1 runs. Building under a temporary name and swapping is not written.
- **A key added in the same run that points at a unique index built this way** is applied before the index exists. The unique stays out of `--concurrently` for now.
- **`REINDEX CONCURRENTLY`, `VACUUM` and the like** can be written by hand into an outside version; nothing generates them.
