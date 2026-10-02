# The SQL runtime

**A statement's SQL is fixed while compiling; the runtime's job is to get that constant to the right connection, wait for it correctly, and report exactly what came back.**

**Guide:** [Running it](../guide/sql/running.md), [Transactions](../guide/sql/transactions.md), [SQLite](../guide/sql/sqlite.md) · **Reference:** [`Db`](../reference/sql.md#db), [Options](../reference/sql.md#options), [`Tx`](../reference/sql.md#tx), [Errors](../reference/sql.md#errors)

The code is `sql/db.zig` (`Db`, `Tx`, `Savepoint`, `watching`, `lastProblem`), `sql/wire.zig` (the contract every driver meets: `Error`, `Problem`, `Isolation`, `Begin`), `sql/postgres.zig` and `sql/sqlite.zig` (the two Wires), and `sql/dialect.zig` (the compile-time half that writes the SQL).

## Overview

```
handler
  │ db.find / db.select / db.insert          tx.deadline(ms) / tx.select(.lock=…) / tx.savepoint()
  ▼                                              ▼
 Db (pool, a Service) ───────begin()─────────► Tx (one connection, held until it ends)
  │ planOf(): a 128-bit hash of the             │
  │ comptime SQL names the prepared plan        │
  ▼                                              ▼
 Wire: postgres.zig (socket, suspends          Wire: same contract, one writer +
 the fiber) or sqlite.zig (.hop or             N read-only readers, two Conditions
 .in_fiber, no socket to wait on)
  │ run / exec, through fill / only / execTold / stream
  ├──────────► db.watching(f): Sent{sql, plan, micros, rows, failed, route}, no values
  ▼
one pooled connection
  │ fails
  ▼
wire.Problem: the database's words, to whoever is watching
sql.problem(c): a name to switch on and the constraint that fired, threadlocal, to the call that caused it
```

A program that opens `sql.Db` with no other settings gets the left edge of this: a pool, a plan cache, and a startup that opens one connection for whatever runs before the first request.

## Rules

1. **Every statement this module builds, and `db.raw`/`tx.raw`, is prepared once and reused, keyed by a 128-bit hash of its text.** The plan name is a compile-time constant, so the run-time cost is one load and one comparison. That is why `db.raw` and `tx.raw` take `comptime sql`; there is no equivalent for SQL assembled at run time. [ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)
2. **A deadline needs the connection it limits, so it is on `Tx`, not `Db`.** `tx.deadline(ms)` sends `SET LOCAL statement_timeout` on the connection the transaction already holds, and a statement that fails inside a transaction is recovered instead of costing a reconnect. **Once a failed statement has aborted a transaction, every later statement is rejected and `commit` rolls back**, returning `QueryFailed` instead of the silent `ROLLBACK` tag Postgres sends for such a `COMMIT`. SQLite follows the same rule; `ROLLBACK TO SAVEPOINT` is how to continue. [ADR 043](../adr/043-a-deadline-needs-a-connection-you-hold.md), [ADR 065](../adr/065-one-writer-is-not-a-setting-it-is-the-database.md)
3. **Transactions exist to handle contention.** `db.begin` takes an isolation level and `read_only`. A `.lock` mode (`.update`, `.update_nowait`, `.update_skip_locked`, `.share`) holds the rows a read matched, and a savepoint is what a nested transaction really is. A `.lock` outside a transaction is a compile error: the SQL would be valid, but the promise to hold the row would be missing. [ADR 048](../adr/048-contention-is-what-a-transaction-is-for.md)
4. **Nullability has three answers, not two.** A Dialect's schema inspection answers `UNKNOWN` for a column no database can honestly call not-null (a view on either database, or a SQLite primary key that is not the rowid alias and has no `NOT NULL`, which a program reads as a plain non-optional field), and the schema check skips only that column instead of guessing. [ADR 050](../adr/050-a-view-or-a-rowid-alias-is-not-a-nullable-column.md)
5. **Round trips are not the cost worth optimising.** Pipelining is rejected, because a Postgres wait suspends the fiber, not the thread. When several statements must be applied together, a data-modifying CTE through `db.raw` does it in the one round trip nilo already makes. [ADR 053](../adr/053-a-round-trip-is-not-the-cost-worth-chasing.md)
6. **A second database is a second type.** `sql.Named(name)` returns a separate `Db` type, so a replica, a reporting warehouse or a second tenant appears in a handler's argument list. There is no automatic read routing and no query cache, because both need an invalidation rule this module cannot see. [ADR 054](../adr/054-a-second-database-is-a-second-type.md)
7. **A Dialect is compile-time, and where two databases cannot agree, it is a compile error naming the dialect.** This was proven by writing the SQLite Dialect against the same interface Postgres uses, with no database or event loop needed to test it. [ADR 055](../adr/055-the-second-dialect-is-the-test-of-the-seam.md)
8. **Which thread runs a SQLite statement is a choice with no default.** `sqlite.Wire(.{ .threading = .{ .hop = nilo } })` or `.in_fiber`. `sql/` cannot call `nilo.blocking` itself, and `std.Io.concurrent` would still hold an executor thread for the whole call, so the setting has to come from the program that already imports both modules. Under `.hop`, each statement gets its own worker (`nilo.blockingReserved`), so one slow read cannot leave another statement holding its connection while it waits in the pool's queue. [ADR 064](../adr/064-a-file-has-no-socket-to-wait-on.md)
9. **One writer and several read-only readers is how SQLite works, not a pool setting.** Waiting for a free connection uses two `std.Io.Condition`s, not one, so a returning writer cannot wake a fiber waiting for a reader, or the reverse. `db.raw` is routed by its first keyword, with a safety net of read-only readers that holds in memory as well as on a file; `:memory:` is one database private to its pool; and durability defaults to WAL with `synchronous = NORMAL`. [ADR 065](../adr/065-one-writer-is-not-a-setting-it-is-the-database.md)
10. **The guard against returning a connection to the pool twice works in every build.** Closing a `Streamed` twice is caught by a plain `bool` checked before the guard runs, not a check compiled out outside Debug. [ADR 093](../adr/093-a-guard-against-double-release-is-not-a-debug-trap.md)
11. **Waiting for a free connection has a time limit.** `core.Limits` only starts a timer once a connection turns out to be busy, so a statement that never queues pays nothing. On SQLite, the writer's `TimedOut` names the SQL of the statement currently holding the connection, since there is no fiber identity to tell a self-deadlock from a genuinely busy database. [ADR 107](../adr/107-a-wait-for-a-connection-has-a-bound.md)
12. **Every statement can be watched, and a read can show its plan.** `db.watching(f)` is told each statement's SQL, plan name, duration, row count, whether it failed, and the route whose request sent it. Parameter values are never included, because they are the interesting part and may also be a password. `db.explain` takes the same arguments as `db.select` and returns that statement's plan with its values bound. `db.rawExplain` does the same for a raw statement, inside a transaction it rolls back, because `ANALYZE` runs what it plans. [ADR 108](../adr/108-a-statement-can-be-watched.md), [ADR 232](../adr/232-a-read-can-show-its-plan.md)
13. **Startup opens exactly the connection its own work needs, and says when a check was skipped.** With `connect_on_init = 0`, one connection is still opened when a schema check or an `app.before` hook is about to run. A failed connection is a warning, not a reason to refuse to start. A `Db` that reaches `nilo_start` without `checking` ever being called warns once, unless `.unchecked = true` says that is intended. [ADR 115](../adr/115-a-boot-dials-the-connection-its-work-needs.md), [ADR 192](../adr/192-a-db-with-no-schema-check-says-so-or-is-told.md)
14. **A failed statement is reported twice, to two different places.** The database's own message (`wire.Problem`, an out-parameter) goes to whoever is watching. A precise error name you can switch on goes to the call that caused it, together with the constraint that fired, through `sql.problem(c)`: `ForeignKeyViolated`, `NotNullViolated`, `CheckViolated`, `ConstraintViolated`, and `RolledBack` for a serialization failure or deadlock (the one error where running the transaction again is the right response). It is cleared by every statement, so it can never describe someone else's failure. By default, `AlreadyExists` answers 409, and `RolledBack` and `Disconnected` answer 503, because the request cannot change what they mean. [ADR 117](../adr/117-a-statement-that-failed-says-what-the-database-said.md)
15. **A dependency bug must be reproduced before it is considered fixed.** A reported panic when refusing to start turned out to be two upstream pg.zig bugs on top of each other. The pin bump was verified by running both throwaway reproductions against both pins, not just by the test suite passing. [ADR 122](../adr/122-the-panic-under-the-panic.md)
16. **A statement interrupted by a cancellation passes the cancellation back.** It returns `QueryFailed` (or `Disconnected` from a pool wait) with the cancellation re-armed. Connecting and rolling back run with cancellation held off, so a fiber whose only way out is its next `sleep` still gets out. A `COMMIT` is also protected, so its outcome is always known. [ADR 223](../adr/223-a-statement-cut-off-by-a-cancellation-hands-it-back.md)
17. **A plan made stale by a migration is prepared again.** Outside a transaction, the Wire drops the plan and sends the statement once more; inside one, the result is `RolledBack` and the plan is dropped when the transaction ends. [ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)
18. **A pooled connection is asked whether it is still there before it is used.** One `poll` with no wait on its socket; a connection the server closed or reset while it idled is replaced before anything is sent down it, so a restart costs no request a 5xx. Nothing is ever sent twice: a failure after the write cannot say whether the server ran the statement, so it is not resent. [ADR 237](../adr/237-an-idle-connection-is-asked-before-it-is-used.md)
19. **A stream let go early gives its connection back within a bound.** At most 1 MiB of the rest is read off the socket; past that the connection is handed back as failed, and pg.zig closes it and dials a replacement. A 42 MB rest costs 21 to 34 ms where it cost 178 to 313. Inside a transaction the rest is read whole, because closing the connection would roll the transaction back. [ADR 238](../adr/238-a-stream-let-go-early-reads-a-megabyte-of-what-is-left.md)
20. **A Postgres URL with no `sslmode` is encrypted unless the host is this machine, and a pooler in the URL turns prepared statements off.** `require` for any other host (refused if the server offers no TLS, `sslmode=disable` to opt out), `disable` for `localhost`, `127.0.0.0/8`, `::1`, a unix socket or no host; `prefer` stays refused because anybody on the path can downgrade it. `pgbouncer=true` sets `Opts.prepared = false`, `26000` (the server has no such prepared statement) is forgotten and retried once, and `tcp_user_timeout` is refused. [ADR 241](../adr/241-a-postgres-url-without-sslmode-is-encrypted-unless-it-stays-on-this-machine.md)
21. **SQLite's C is compiled `ReleaseFast` whatever the program is built as**, and zqlite's Zig in the program's mode, so one object serves Debug and `ReleaseSafe` and the 34-second `ReleaseSafe` compile of the amalgamation never runs. A cold Debug build pays 14 seconds more for it, once. [ADR 249](../adr/249-sqlite-is-compiled-releasefast-whatever-the-program-is.md)

## Decisions

| ADR | What it decides |
|---|---|
| [043](../adr/043-a-deadline-needs-a-connection-you-hold.md) | A statement's deadline is `tx.deadline(ms)`, sent on the transaction's own connection |
| [048](../adr/048-contention-is-what-a-transaction-is-for.md) | Isolation level on `begin`, `.lock` modes on a read, and savepoints as nested transactions |
| [050](../adr/050-a-view-or-a-rowid-alias-is-not-a-nullable-column.md) | Nullability has three answers, and where each Dialect has to say `UNKNOWN` |
| [051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md) | Prepared statements by default, keyed by a hash of the text; `db.raw`/`tx.raw` take `comptime sql` |
| [053](../adr/053-a-round-trip-is-not-the-cost-worth-chasing.md) | Pipelining was measured and rejected; a CTE applies several statements together |
| [054](../adr/054-a-second-database-is-a-second-type.md) | `sql.Named` for a second `Db`; no automatic read routing, no query cache |
| [055](../adr/055-the-second-dialect-is-the-test-of-the-seam.md) | The SQLite Dialect as the test of the interface shared with Postgres |
| [064](../adr/064-a-file-has-no-socket-to-wait-on.md) | SQLite's threading choice (`.hop` or `.in_fiber`) has no default, why `sql/` cannot call `nilo.blocking` itself, and why a statement under `.hop` never queues in the pool |
| [065](../adr/065-one-writer-is-not-a-setting-it-is-the-database.md) | The SQLite pool: one writer, N read-only readers, two conditions, routing, `:memory:`, durability |
| [093](../adr/093-a-guard-against-double-release-is-not-a-debug-trap.md) | The double-release guard on `Streamed.close` is a plain `bool`, active in every build |
| [107](../adr/107-a-wait-for-a-connection-has-a-bound.md) | `timeout_ms` also applies on SQLite, through `core.Limits`, and the writer's message names what holds it |
| [108](../adr/108-a-statement-can-be-watched.md) | `db.watching`, and what `Sent` includes and deliberately leaves out |
| [115](../adr/115-a-boot-dials-the-connection-its-work-needs.md) | `nilo_start` opens one connection for the startup work about to use the pool |
| [117](../adr/117-a-statement-that-failed-says-what-the-database-said.md) | `wire.Problem` for a watcher; a precise error name and `sql.problem` for the caller |
| [122](../adr/122-the-panic-under-the-panic.md) | Two upstream pg.zig bugs on top of each other, found by reproducing rather than reading a trace, and the pin that fixes both |
| [192](../adr/192-a-db-with-no-schema-check-says-so-or-is-told.md) | A `Db` that never calls `checking` warns once; `.unchecked = true` says it was intended |
| [223](../adr/223-a-statement-cut-off-by-a-cancellation-hands-it-back.md) | A cancellation that interrupts a statement is re-armed for the caller; release and rollback are protected from it |
| [232](../adr/232-a-read-can-show-its-plan.md) | `db.explain`: the plan of the read `db.select` would send, with values bound, `ANALYZE` on Postgres; `db.rawExplain` for a raw statement, rolled back; on a tiny test database only the plan's structure is safe to assert |
| [237](../adr/237-an-idle-connection-is-asked-before-it-is-used.md) | A Postgres connection is polled once before each use and replaced if the server closed it; a statement is never resent after a failure |
| [238](../adr/238-a-stream-let-go-early-reads-a-megabyte-of-what-is-left.md) | A Postgres stream closed early reads at most 1 MiB of the rest, then has its connection replaced; inside a transaction the rest is read whole |
| [241](../adr/241-a-postgres-url-without-sslmode-is-encrypted-unless-it-stays-on-this-machine.md) | A URL with no `sslmode` is `require` off this machine and `disable` on it; `pgbouncer=true` turns prepared statements off; `26000` is retried once; `tcp_user_timeout` is refused |
| [249](../adr/249-sqlite-is-compiled-releasefast-whatever-the-program-is.md) | The SQLite amalgamation is compiled `ReleaseFast` in every mode; zqlite's Zig keeps the program's |

Related topics: every statement here being a compile-time constant, which both the prepared-statement cache and the Dialect's compile errors depend on, is [ADR 036](../adr/036-the-shape-of-a-query-is-settled-while-compiling.md) (sql-query); why `sql/` cannot import `nilo_http` and so cannot call `nilo.blocking` for SQLite's thread hop is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md) (layering); the per-connection stack cost that a parked fiber, a hop and a `Problem`'s slices are all measured against is [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory); the one place `nilo.Gate` is used today, the example a second limited caller would follow, is [ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md) (pw); a raw statement's parameters and `SELECT` list being checked like an ordinary Row's are [ADR 116](../adr/116-a-raw-parameter-is-converted-the-way-a-rows-is.md) and [ADR 106](../adr/106-a-select-list-shorter-than-the-row-is-refused.md) (sql-raw).

## Open questions

- **Whether `.hop` or `.in_fiber` is faster for a cache-hit read has not been measured.** [ADR 064](../adr/064-a-file-has-no-socket-to-wait-on.md) recommends `.hop` for now, and the run that would settle it is in [the todo list](../todo.md).
- **Telling a fiber waiting for the writer it already holds from one that is genuinely waiting** still needs a fiber identity that `std.Io` does not give a Service. Named as open in [ADR 107](../adr/107-a-wait-for-a-connection-has-a-bound.md) and tracked in the roadmap.
- **An `AnyScope` has no route**, so a statement sent through a function pointer reaches the watcher with `route` null ([ADR 108](../adr/108-a-statement-can-be-watched.md)).
- **A children statement cannot be explained**; only the statement that reads the parents can ([ADR 232](../adr/232-a-read-can-show-its-plan.md)).
- **The SQLite pool has no live test under real contention** (two writers colliding, `busy_timeout` expiring), per [the todo list](../todo.md).
- **Nothing reports how a pool is doing**: connections in use, how long callers waited, statements run, per [the todo list](../todo.md).
- **Whether `sql/live.zig`'s `connect_on_init = size` workaround is still needed has not been tested.** [ADR 122](../adr/122-the-panic-under-the-panic.md) says the reconnector may now park under `std.Io.Threaded` since it moved to an `Io.Group` task, and asks for a re-test before removing it.
