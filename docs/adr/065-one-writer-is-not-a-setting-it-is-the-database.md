# One writer is not a setting, it is the database

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)

## Context

[ADR 064](./064-a-file-has-no-socket-to-wait-on.md) settled how a SQLite statement reaches a thread and whose C brings SQLite in. What is left is everything that follows from SQLite not being a server: a pool whose shape is not a preference, a `db.raw` whose destination cannot be worked out while compiling, a durability default that decides what a benchmark means, a test story with a trap that does not announce itself, and a wait that has to wake the fiber actually waiting for what came free. Postgres answers all of these the same way, it is a server, it holds the rules, and the pool is a set of interchangeable connections to it. None of that survives the move to a file.

## Decision

### The pool is one writer and several read-only readers, each queued on its own condition

SQLite serialises writers over the whole database. In WAL mode readers do not block behind the writer, which is why WAL is what almost every deployment runs; what WAL does not do is make two writers possible. A homogeneous pool, the shape pg.zig has and the shape `zqlite.Pool` has, therefore lies about the database: two connections both able to write means two statements racing for the same lock, and the loser surfaces `SQLITE_BUSY`, an error that arrives because two of nilo's own pool connections collided rather than an answer to anything the caller asked. So: one writer connection, for every `insert`, `update`, `delete`, every `Tx`, and every write `exec`; N reader connections, opened with `OpenFlags.ReadOnly`; `busy_timeout` on all of them, whose expiry is what becomes `Locked`, reachable in ordinary operation only from outside the process. `zqlite.Pool` is not used: it is a thread-safe pool of equal connections, the right shape for the library and the wrong one for this contract.

The wait for a free connection is two `std.Io.Condition` fields, `free_writer` and `free_reader`, not one. A pool that queued both waits on a single condition tested different predicates: `release` woke whichever fiber happened to be next, and a returning reader could wake the fiber queued for the writer, which re-tested `conns[0].busy`, found it still true, and went back to sleep, while the fiber that actually wanted a reader was never woken at all. Under a load that both reads and writes that is a request which stalls with nothing in the log and nothing holding it. `release` now picks by which connection came back and calls `broadcast`, not `signal`, on that condition alone:

```zig
if (at == 0) self.free_writer.broadcast(self.io) else self.free_reader.broadcast(self.io);
```

The two conditions cannot serve each other, which is what makes the split exact rather than a heuristic: there is exactly one writer, so a returning reader can satisfy nobody in `takeWriter`, and a returning writer can satisfy nobody in `takeReader`. `broadcast` rather than `signal` matters because the wait is cancellable on purpose, a fiber whose request is gone gives its turn up rather than holding it, and a `signal` consumed by a waiter that then answers `TimedOut` is a wakeup nobody else receives, the same lost wakeup arriving by a different road. Waking everybody queued for the one thing that just became free costs a re-test of one `bool` each, on fibers that are by definition already waiting.

### Which connection a statement takes: comptime where it can be, a keyword and a backstop where it cannot

Every statement this module generates is a comptime constant ([ADR 036](./036-the-shape-of-a-query-is-settled-while-compiling.md)) and starts with its own verb, so `SELECT` versus `INSERT` is settled before the program runs. `db.raw`'s text is the exception: it arrives at run time, so nothing in the process is told in advance whether it reads or writes. `Wire.exec`, which returns no rows, always takes the writer, since every statement with no rows to hand back is a write. `Wire.run`, which returns rows, is what both an ordinary `SELECT` and a `db.raw` that returns rows go through, and it picks by `wantsWriter`, a check of the trimmed text's first word: `SELECT` or `PRAGMA` go to a reader, everything else, including a `WITH` that starts a CTE, goes to the writer.

The guess is safe in the direction it is allowed to be wrong: a `db.raw` that writes and looks like a read is refused by SQLite with `ReadOnly` on its first call, because the reader connections are opened read-only, rather than answering from the wrong snapshot. `WITH` goes to the writer outright, because a CTE may write and the keyword alone does not say, and being wrong in that direction costs a report the writer's time rather than costing correctness. That combination, a keyword read for the common case and a connection that refuses on its own for the case the keyword gets wrong, is what makes a guess acceptable here: on its own, reading the keyword is wrong quietly, and sending everything through the writer makes the slowest statements in the system queue behind the one connection that must never be held. Together, the loud failure lands on the first call, naming the dialect, rather than sometime later on a connection nobody is watching.

**`tx.raw` is not this rule, and the distinction is load-bearing.** A `Tx` holds one connection for its whole life, so `tx.raw` goes down the transaction's connection, the writer, and always did. If `raw` inside a transaction went to a reader instead, it would read a connection that cannot see the transaction's uncommitted writes, a plausible answer, no error, no log line. The existing API already prevents it by having two functions rather than one.

### Durability: WAL and `synchronous = NORMAL`

`PRAGMA synchronous = FULL` makes SQLite wait for the disk to confirm before reporting success. One autocommitted `INSERT` measured at 660 µs on this machine, an fsync, and every library pays the same. `NORMAL` under WAL is what SQLite itself recommends for application use: the database cannot corrupt, and what can be lost is the most recent transactions if the machine loses power, and only then. `OFF`, where corruption is possible, is not offered. This is the one decision here that chooses somebody else's data-loss risk for them, which is why `FULL` is one field away and documented next to the default.

It also makes a benchmark comparison unfair unless the benchmark says so: SQLite at `NORMAL` beside a Postgres configured for full durability wins the write shapes decisively, and the margin is a difference in promises rather than in speed. So a SQLite arm carries both sides configured to the same durability, or SQLite measured at both settings with the difference stated above the table. The batch shape needs the same treatment: `insertMany` is refused on SQLite ([ADR 055](./055-the-second-dialect-is-the-test-of-the-seam.md)), so its batch column is a row at a time inside one transaction, a different shape rather than a slower one, written into the table rather than left blank.

### Tests: the in-memory database has a trap, and it is quiet

`:memory:` is private per connection, so a pool of one writer and N readers opened on it is N+1 separate empty databases; writes go to one and reads find nothing, which looks exactly like a bug in the code under test. `:memory:` is refused, with a message naming the shared form, and refused at `open` rather than while compiling, because a database URL is a run-time value the compiler cannot see, the same boundary that puts the reader-count check below at `listen()` rather than in a Refusal.

A shared in-memory database cannot use WAL: WAL needs a shared-memory file beside the database, and `PRAGMA journal_mode = WAL` returns `memory` rather than failing, so a suite that runs entirely in memory exercises a different journal mode from production and never tests the reader/writer split, `busy_timeout` or anything `Locked` depends on. And the read-only flag does not survive `mode=memory`: SQLite's URI `mode=` parameter takes precedence over the flags handed to `sqlite3_open_v2`, so a connection opened `OpenFlags.ReadOnly` against `file:x?mode=memory&cache=shared` writes; on a file the same flag refuses with `error.ReadOnly`. That is not a curiosity, it is the backstop the routing above leans on: in memory there is no connection SQLite will stop from writing, so the split matters for correctness rather than coverage. The suite is split on that line: tests about statements run on the shared in-memory database, tests about locking, WAL, the pool and `Locked` run against a file in a temporary directory, and the file test also asserts `journal_mode` comes back `wal`. Both SQLite behaviours have been run against zqlite 0.0.1 and SQLite 3.53.0, the library this module ships with, in [`spike/sqlite_facts`](../../spike/sqlite_facts/), because the flags a wrapper passes to `sqlite3_open_v2` decide several of them.

One operational consequence goes with the shared-database trap: it is destroyed when its last connection closes, so the pool opens the writer first and holds it for the pool's life.

### Reader count is checked at `listen()`, not while compiling

Under ADR 064's `.hop`, every SQLite call runs on an Engine thread-pool worker, and a reader connection beyond the number of workers can never be busy: it holds memory and waits. What it holds was measured rather than assumed, one writer and eight readers over a 2.9 MB table:

| | total | per connection |
|---|---|---|
| opened, idle | 252 KiB | 28 KiB |
| after every reader has scanned the whole table | 16,892 KiB | 1,876 KiB |

Both are real and are two different deployments rather than a range to split: a service doing primary-key lookups stays near the first row, one running reports over a table larger than the cache converges on the second. `cache_size`'s default (`-2000`, 2,000 KiB) is a ceiling SQLite grows toward and never past, not a number held regardless of use, and lowering it bought nothing in `pread64` counts at either shape tried, so it stays at SQLite's default and the guide says what the two rows above say. Each connection also keeps its own copies of whatever [ADR 051](./051-a-statement-that-is-a-constant-can-be-prepared-once.md) says to keep prepared, on top of both figures and unmeasured.

The guard cannot be a Refusal: the worker count is a run-time value, usually derived from the machine's CPU count, and the reader count comes from configuration, so nothing in the compiler can see both. It is a startup check at `listen()`, in the same place the service registry is checked. The reader default is the worker count.

### A transaction is held to Postgres's rule about a failed statement

SQLite keeps a transaction going after a statement in it fails; Postgres
aborts it, refuses every statement after it with `25P02`, and answers a
`COMMIT` by rolling back. A handler that caught `AlreadyExists` without a
savepoint and went on to commit kept the rest of its work here and lost all
of it there, and the test suite run against this Wire was the one telling it
the code was right. So the writer's connection carries `aborted`, set by any
statement that fails inside the transaction, stepping included, since that is
where an `INSERT … RETURNING` meets its constraint. While it is set a
statement is refused as `QueryFailed` with the same line Postgres's `25P02`
gets, and `commit` rolls back and answers `QueryFailed`. `ROLLBACK TO
SAVEPOINT` clears it, as it does on Postgres ([ADR 043](./043-a-deadline-needs-a-connection-you-hold.md)).

A `COMMIT` SQLite itself refuses, a deferred foreign key still broken or a
`BUSY`, leaves the transaction open. The writer is rolled back before it goes
back to the pool, where it used to go back mid-transaction for the next
request to run inside.

### `tx.deadline` is refused on SQLite, naming the dialect

[ADR 043](./043-a-deadline-needs-a-connection-you-hold.md) put `deadline` on the `Tx` because a deadline has to be set on the connection the statement will travel down. On Postgres that is a message to a server; SQLite has no server, and the only mechanism is `sqlite3_interrupt`, called from another thread while the statement runs. It needs a timer and a cross-thread poke, machinery this module does not have; it is connection-wide rather than statement-wide, so it would abort whatever else that connection is running, and under `.hop` the fiber that set the deadline is parked and cannot be woken to fire it anyway; and `busy_timeout` already covers the case that actually happens, waiting on a lock nobody is releasing. So `tx.deadline` is a Refusal naming the dialect, in the shape `.lock` already uses.

## What was rejected

**A homogeneous pool of equal connections.** Lies about the database: two connections that can both write race for the same lock, and the loser's `SQLITE_BUSY` answers nothing the caller asked.

**Routing `db.raw` by sending every call to the writer.** Safe, and it makes the slowest statements in the system queue behind the one connection that must never be held.

**Routing `db.raw` by reading the first keyword alone, with no read-only backstop.** Wrong on `WITH … INSERT` if the keyword read maps a CTE to a reader, and wrong quietly: no error, no log line, a plausible wrong answer.

**One `Condition` with `broadcast`, keeping a single wait.** Correct, and it wakes every fiber queued for either resource on every release, so a writer-heavy load repeatedly wakes every reader-waiter only to send it back to sleep. Two `Condition` fields cost sixteen bytes on a `Wire` a program has one of.

**Two conditions kept on `signal`.** Reintroduces the lost wakeup through cancellation, the failure this section exists to close.

**Recording which fiber holds the writer, so a self-deadlock could answer `Locked`.** A different question from waking the right queue; left as an open roadmap item on the pool.

**Making `schema_mismatch_is_fatal`-style leniency the answer to any of the above**, or otherwise softening a correctness question into a warning. Each of these traps (`:memory:`, the read-only flag, the lost wakeup) is a case where the honest failure is loud, and softening it treats the symptom.

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes, this ADR spends memory and nothing else, in a place nilo had not spent it before: per pool connection rather than per HTTP connection.

| Axis | Cost |
|---|---|
| Allocations per request | 0. Routing is a comptime branch or one keyword check; the pool is built at `listen()`. |
| Memory per idle connection | 0 B on an HTTP connection. Per pool connection: 28 KiB opened and idle, growing to 1,876 KiB once a connection has touched `cache_size` worth of pages, times the reader count. Prepared statements are on top and unmeasured. Two `Condition` fields add sixteen bytes on the `Wire`, once per pool. |
| Throughput and p99 | Not taken; any figure needs the durability setting stated beside it, or it is a figure about fsync. |
| Binary size | Counted in [ADR 064](./064-a-file-has-no-socket-to-wait-on.md); nothing here links anything that ADR does not. |

## Consequences

- The pool is nilo's, not zqlite's or pg.zig's: one writer, N read-only readers, WAL, `busy_timeout`, opened writer-first and held, waited on through two conditions rather than one.
- One Refusal and two startup checks, and which is which follows from what the compiler can see: `tx.deadline` is a Refusal, a row in `sql_refusals` in `build.zig`; `:memory:` and the reader count are checked at `open` and `listen()`, because a URL and a worker count both arrive at run time.
- The suite gains a temporary-directory arm for tests about locking, which cannot run in memory.
- If the writer/reader wait ever hangs again, the pool has lost a wakeup: `sql/sqlite.zig`'s test takes every connection, parks one fiber on each queue, gives back only a reader, and requires the reader-waiter be the one served. On a two-core box, `std.Io.Threaded`'s default `async_limit` is one less than the logical core count, so a test wanting two parked fibers needs to ask for the room or it deadlocks in a way that looks exactly like the bug it is testing for; `ps -o etime,cputime` showing minutes of wall against no CPU is the diagnosis either way.
