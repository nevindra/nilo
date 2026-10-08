# A migration waits five seconds for a table

**Status:** accepted
**Topic:** [sql-migrations](../design/sql-migrations.md)
**Extends:** [ADR 123](./123-a-migration-is-a-diff-against-a-snapshot.md) (what `apply` does inside a version's transaction)

## Context

An `ALTER TABLE` on Postgres takes `ACCESS EXCLUSIVE`, the lock nothing else can share. If a transaction is open on the table, even one that only read it, the `ALTER` waits for it, and **every read and write to that table queues behind the waiting `ALTER`**, because Postgres grants locks in order. A report that runs for ten minutes, or a `psql` session somebody left in `BEGIN`, turns a migration that would take a millisecond into ten minutes of a table answering nothing. `apply` set no bound, so that wait lasted as long as the transaction in front of it.

Behind the wait sat a second cost nothing said: several steps the diff writes read or rewrite the whole table while they hold that lock. `SET NOT NULL` and a new `CHECK` read every row, and a type change that is not in place (`int4` to `int8`, `float4` to `float8`, which the diff calls safe because no value changes) writes every row again. A step's `why` said none of it.

## Decision

**Each version tells Postgres how long one step may wait for a lock, 5,000 ms unless the version says otherwise.** `migrate.apply` sends `SELECT set_config('lock_timeout', $1, true)` right after the advisory lock and the ledger check, from `Version.lock_timeout_ms`. A step that waits longer fails with `error.Locked` (the server's `55P03`), `apply` logs one `warn` line naming the version and the step, and the transaction rolls back, so nothing is kept. `0` waits for good, and also overrides a `lock_timeout` the connection's URL set.

- **After the advisory lock, not before.** Waiting for another replica's migration is what that lock is for, and it holds no table while it waits.
- **At READ COMMITTED, named, on every transaction that takes the lock** (`apply`, `ensureLedger`, `createMissing`, `addMissingColumns`; `Dialect.has_read_committed`, true on Postgres). A plain `BEGIN` is whatever the role's `default_transaction_isolation` says, and under REPEATABLE READ the snapshot is taken when the lock's `SELECT` starts, before it waits. The replica that waited then reads a ledger from before the other committed, finds its version missing and runs it again: its `CREATE TABLE` fails with `42P07`, or its ledger row with `23505`, and the boot fails for a version that was already applied. Asking for the level in the `BEGIN` costs no round trip and leaves it to no role's setting. Found by a probe with two pools on a role set to REPEATABLE READ (`live.zig`).
- **`createMissing` and `addMissingColumns` take the same lock and the same bound**, the default 5,000 ms, from the helpers `apply` calls (`migrate.enterLocked`). They alter tables too, and an `ADD COLUMN` waits for `ACCESS EXCLUSIVE` like any step; a wait that runs out fails with `error.Locked` and one `warn` line, and nothing is kept.
- **For the transaction only.** The `true` is `SET LOCAL`'s scope, so the connection goes back to the pool with the setting it came out with.
- **Not in the hash.** The hash covers the statements; moving the timeout after a version ran changes when it gives up, not what it does, so it is not drift.
- **In the twin.** The Postgres `.sql` twin writes `SET LOCAL lock_timeout = <ms>;` after its `BEGIN`, so `psql -f` gives up where `db migrate` does. SQLite has no such setting: a write there waits on the one write lock, and `busy_timeout` bounds that already (`Dialect.lock_timeout` is `null`).

**Five seconds** is a stall a request sits out well inside the thirty to sixty seconds a proxy usually gives it, and longer than a request's own transaction ordinarily lasts. What holds a table past that is a report, a stuck transaction or a person, and waiting behind it is the outage. A boot that gives up fails, and its supervisor starts it again, which is a retry with the backoff the platform already has.

**A step that holds the table while it reads or writes every row says so in its `why`**: "readings.note may no longer be null, which reads every row while reads and writes to readings wait". The same words go into the generated file's comment and the twin, where a reviewer reads them before the version runs.

**The diff keeps writing the one-statement forms.** `ADD CONSTRAINT … NOT VALID` then `VALIDATE CONSTRAINT`, or a `CHECK (x IS NOT NULL)` then `SET NOT NULL` over it, take the weaker lock only when the second statement runs in a transaction of its own. A version is one transaction, so in the same version the first statement's `ACCESS EXCLUSIVE` is still held when the second reads the table, and the two-step form would cost a statement and save nothing. A table big enough to need it gets the second half as a version of its own, written by hand, and the `why` is what tells somebody to.

## What it costs

- **Allocations per request**: none; `apply` runs at boot or from the command line.
- **Memory per idle connection**: none.
- **Throughput and p99**: one round trip per version applied. A boot with nothing to apply skips `apply` altogether (`applyPending` reads the ledger first).
- **Binary size**: one constant statement and one log line, in a program that links the migrator.

## What was rejected

- **No default, a bound only when asked.** The version that needs one is the one nobody thought about, on the table somebody else was reading.
- **A retry loop inside `apply`.** It would sleep on the boot path with an `Io` the migrator does not hold, and it would hide a transaction that has been open for an hour behind a boot that eventually succeeds. The error and the line name the table's problem; the supervisor already retries.
- **A shorter default, a few hundred milliseconds.** It is what a tool that retries on its own can afford. Without a retry, a request's ordinary transaction on a busy table would fail the boot often enough to teach people to set `0`.
- **A `statement_timeout` as well.** A step that holds its lock and then runs long is a migration doing its work; bounding it would roll back a rewrite of a big table at the moment it was nearly done. The wait before anything happens is the part that stalls everyone else.
- **Two transactions per version, so the two-step forms help.** A version that half-applies is what ADR 123's one transaction exists to rule out.
