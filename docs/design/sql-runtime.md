# The SQL runtime

**A statement's shape is settled while compiling, and everything in this topic exists to get that constant to the right connection, wait for it correctly, and say precisely what came back.** How to use it is the guide ([`guide/sql/running.md`](../guide/sql/running.md), [`guide/sql/transactions.md`](../guide/sql/transactions.md), [`guide/sql/sqlite.md`](../guide/sql/sqlite.md)); every name and signature is the reference ([`reference/sql.md`](../reference/sql.md#db), [`#options`](../reference/sql.md#options), [`#tx`](../reference/sql.md#tx), [`#errors`](../reference/sql.md#errors)). The code is `sql/db.zig` (`Db`, `Tx`, `Savepoint`, `watching`, `lastProblem`), `sql/wire.zig` (the contract every driver meets: `Error`, `Problem`, `Isolation`, `Begin`), `sql/postgres.zig` and `sql/sqlite.zig` (the two Wires), and `sql/dialect.zig` (the comptime half that writes the SQL).

## How the pieces fit

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

A program that opens `sql.Db` with nothing else set gets the left edge of this: a pool, a plan cache, and a boot that dials one connection for whatever runs before the first request.

## The rule in force

1. **Every statement this module builds, and `db.raw`/`tx.raw`, is prepared once and reused by a 128-bit hash of its text.** The name is a comptime constant, so the run-time cost is one load and one test; `db.raw` and `tx.raw` take `comptime sql` for exactly this reason, and a caller who assembled SQL at run time has no replacement. [ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)
2. **A deadline needs the connection it bounds, so it lives on `Tx`, not `Db`.** `tx.deadline(ms)` sends `SET LOCAL statement_timeout` down the connection the transaction already holds, and a statement that fails inside a transaction is revived rather than costing a reconnect. **A transaction a failed statement aborted refuses every statement after it and rolls back at `commit`**, answering `QueryFailed` rather than the silent `ROLLBACK` tag Postgres sends for such a `COMMIT`; SQLite is held to the same rule, and `ROLLBACK TO SAVEPOINT` is the way on. [ADR 043](../adr/043-a-deadline-needs-a-connection-you-hold.md), [ADR 065](../adr/065-one-writer-is-not-a-setting-it-is-the-database.md)
3. **Contention is what a transaction is for.** `db.begin` takes an isolation level and `read_only`, a `.lock` mode (`.update`, `.update_nowait`, `.update_skip_locked`, `.share`) holds the rows a read matched, and a savepoint is what a nested transaction actually is; a `.lock` outside a transaction is a Refusal, because the SQL is legal and the promise to hold the row is the thing missing. [ADR 048](../adr/048-contention-is-what-a-transaction-is-for.md)
4. **Nullability has three answers, not two.** A Dialect's introspection answers `UNKNOWN` for a column no database can honestly call not-null, a view on either database or a SQLite rowid alias, and the schema check skips only that column rather than guessing one way. [ADR 050](../adr/050-a-view-or-a-rowid-alias-is-not-a-nullable-column.md)
5. **A round trip, not the statement itself, is the cost worth chasing.** Pipelining is refused because a Postgres wait suspends the fiber rather than the thread; where several statements must land together, a data-modifying CTE through `db.raw` does it in the one round trip nilo already sends. [ADR 053](../adr/053-a-round-trip-is-not-the-cost-worth-chasing.md)
6. **A second database is a second type.** `sql.Named(name)` gives back a distinct `Db` type, so a replica, a reporting warehouse or a second tenant is written in a handler's argument list; there is no automatic read routing and no query cache, because both need an invalidation rule this module cannot see from here. [ADR 054](../adr/054-a-second-database-is-a-second-type.md)
7. **A Dialect is comptime, and where two databases cannot agree it is a Refusal naming the dialect.** Proven by writing the SQLite Dialect against the same seam Postgres uses, with no database and no event loop needed to test it. [ADR 055](../adr/055-the-second-dialect-is-the-test-of-the-seam.md)
8. **A SQLite statement's thread is a choice with no default.** `sqlite.Wire(.{ .threading = .{ .hop = nilo } })` or `.in_fiber`; `sql/` cannot reach `nilo.blocking` itself, and `std.Io.concurrent` still holds an executor thread for the call's whole duration, so the field has to arrive from the program that already imports both modules. Under `.hop` each statement gets a worker of its own (`nilo.blockingReserved`), so one slow read cannot leave a statement holding its connection in the pool's queue. [ADR 064](../adr/064-a-file-has-no-socket-to-wait-on.md)
9. **One writer and several read-only readers is what SQLite is, not a pool setting.** The wait for a free connection is two `std.Io.Condition`s, not one, so a returning writer cannot wake a fiber waiting for a reader and vice versa; `db.raw` is routed by its first keyword with a read-only backstop, a bare `:memory:` is refused at `open`, and durability defaults to WAL with `synchronous = NORMAL`. [ADR 065](../adr/065-one-writer-is-not-a-setting-it-is-the-database.md)
10. **A guard against handing the pool a connection twice holds in every build.** Closing a `Streamed` twice is caught by a plain `bool` checked before the guard runs, not one compiled away outside Debug. [ADR 093](../adr/093-a-guard-against-double-release-is-not-a-debug-trap.md)
11. **A wait for a free connection has a bound.** `core.Limits` arms a timer only once a connection is found busy, so a statement that never queues pays nothing; on SQLite the writer's `TimedOut` names the statement text currently holding the connection, since there is no fiber identity to tell a self-deadlock from an honestly busy database. [ADR 107](../adr/107-a-wait-for-a-connection-has-a-bound.md)
12. **A statement can be watched, and a read can show its plan.** `db.watching(f)` is told the SQL, its plan name, how long it took, how many rows, whether it failed, and the route whose request sent it, for every statement in the module; the parameter values are never in it, because they are the interesting half and also a password. `db.explain` takes what `db.select` takes and answers the plan of that statement with its values bound; `db.rawExplain` does the same for a raw statement, inside a transaction it rolls back, since `ANALYZE` runs what it plans. [ADR 108](../adr/108-a-statement-can-be-watched.md), [ADR 232](../adr/232-a-read-can-show-its-plan.md)
13. **A boot dials exactly the connection its own work needs, and says when a check was skipped.** `connect_on_init = 0` still dials one connection when a schema check or an `app.before` hook is about to run, a failed dial is a warning rather than a refusal to start, and a `Db` that reaches `nilo_start` with `checking` never called warns once unless `.unchecked = true` says the gap is meant. [ADR 115](../adr/115-a-boot-dials-the-connection-its-work-needs.md), [ADR 192](../adr/192-a-db-with-no-schema-check-says-so-or-is-told.md)
14. **A failed statement reports twice, to two addresses.** The database's own words (`wire.Problem`, an out-parameter) go to whoever is watching; a name precise enough to switch on (`ForeignKeyViolated`, `NotNullViolated`, `CheckViolated`, `ConstraintViolated`, and `RolledBack` for a serialization failure or a deadlock, the one error where running the transaction again is right) plus the constraint that fired go to the call that caused it, through `sql.problem(c)`, cleared by every statement so it can never answer for somebody else's failure. `AlreadyExists` answers 409 and `RolledBack` and `Disconnected` 503 by default, because the request cannot change what they mean. [ADR 117](../adr/117-a-statement-that-failed-says-what-the-database-said.md)
15. **A dependency bug is reproduced before it is believed fixed.** A reported panic on refusing to start turned out to be two upstream pg.zig bugs stacked, and bumping the pin was checked by running both throwaway reproductions against both pins, not by the suite going green. [ADR 122](../adr/122-the-panic-under-the-panic.md)
16. **A statement cut off by a cancellation hands it back.** It answers `QueryFailed` (or `Disconnected` from a pool wait) with the cancellation re-armed, and connections and rollbacks run with cancellation held off, so a fiber whose only way out is its next `sleep` still leaves. A `COMMIT` is held off too, so its outcome is always known. [ADR 223](../adr/223-a-statement-cut-off-by-a-cancellation-hands-it-back.md)
17. **A plan a migration made stale is prepared again.** Outside a transaction the Wire deallocates it and sends the statement once more; inside one the answer is `RolledBack` and the plan is dropped when the transaction ends. [ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)

## Decisions

| ADR | What it decides |
|---|---|
| [043](../adr/043-a-deadline-needs-a-connection-you-hold.md) | A statement's deadline is `tx.deadline(ms)`, sent down the transaction's own connection |
| [048](../adr/048-contention-is-what-a-transaction-is-for.md) | Isolation level on `begin`, `.lock` modes on a read, and savepoints as what a nested transaction is |
| [050](../adr/050-a-view-or-a-rowid-alias-is-not-a-nullable-column.md) | Nullability is a three-way answer, and where each Dialect has to say `UNKNOWN` |
| [051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md) | Prepared statements on by default, keyed by a hash of the text; `db.raw`/`tx.raw` take `comptime sql` |
| [053](../adr/053-a-round-trip-is-not-the-cost-worth-chasing.md) | Pipelining is measured and refused; a CTE is the answer for several statements landing together |
| [054](../adr/054-a-second-database-is-a-second-type.md) | `sql.Named` for a second `Db`; no automatic read routing, no query cache |
| [055](../adr/055-the-second-dialect-is-the-test-of-the-seam.md) | The SQLite Dialect as the test of the Postgres/SQLite seam |
| [064](../adr/064-a-file-has-no-socket-to-wait-on.md) | SQLite's threading choice (`.hop` or `.in_fiber`) has no default, why `sql/` cannot reach `nilo.blocking` itself, and why a statement under `.hop` never queues on the pool |
| [065](../adr/065-one-writer-is-not-a-setting-it-is-the-database.md) | The SQLite pool: one writer, N read-only readers, two conditions, routing, `:memory:`, durability |
| [093](../adr/093-a-guard-against-double-release-is-not-a-debug-trap.md) | The double-release guard on `Streamed.close` is a plain `bool`, held in every build |
| [107](../adr/107-a-wait-for-a-connection-has-a-bound.md) | `timeout_ms` is honoured on SQLite too, through `core.Limits`, and the writer's message names its holder |
| [108](../adr/108-a-statement-can-be-watched.md) | `db.watching`, and what `Sent` carries and deliberately leaves out |
| [115](../adr/115-a-boot-dials-the-connection-its-work-needs.md) | `nilo_start` dials one connection for whatever boot work is about to ask of the pool |
| [117](../adr/117-a-statement-that-failed-says-what-the-database-said.md) | `wire.Problem` to a watcher, a precise error name and `sql.problem` to the caller |
| [122](../adr/122-the-panic-under-the-panic.md) | Two stacked upstream pg.zig bugs, found by reproducing rather than reading a trace, and the pin that fixes both |
| [192](../adr/192-a-db-with-no-schema-check-says-so-or-is-told.md) | A `Db` that never calls `checking` warns once; `.unchecked = true` says it was meant |
| [223](../adr/223-a-statement-cut-off-by-a-cancellation-hands-it-back.md) | A cancellation that cuts a statement off is re-armed for the caller; release and rollback are held off from it |
| [232](../adr/232-a-read-can-show-its-plan.md) | `db.explain`: the plan of the read `db.select` would send, values bound, `ANALYZE` on Postgres; `db.rawExplain` for a raw statement, rolled back; on a tiny test database only the plan's structure is safe to assert |

Beside this topic: every statement here being a comptime constant, the precondition the prepared-statement cache and the Dialect refusals both rest on, is [ADR 036](../adr/036-the-shape-of-a-query-is-settled-while-compiling.md) (sql-query); why `sql/` cannot name `nilo_http` and so cannot reach `nilo.blocking` for SQLite's thread hop is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md) (layering); the per-connection stack cost that a parked fiber, a hop and a `Problem`'s slices are all measured against is [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory); the one place `nilo.Gate` is applied today, the precedent a second bounded caller would follow, is [ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md) (pw); a raw statement's parameters and its `SELECT` list being checked the way an ordinary Row's are is [ADR 116](../adr/116-a-raw-parameter-is-converted-the-way-a-rows-is.md) and [ADR 106](../adr/106-a-select-list-shorter-than-the-row-is-refused.md) (sql-raw).

## Open

- **Which of `.hop` and `.in_fiber` wins on a cache-hit read is unmeasured.** [ADR 064](../adr/064-a-file-has-no-socket-to-wait-on.md) recommends `.hop` provisionally, and the run that would settle it is in [the roadmap](../roadmap.md).
- **Telling a fiber that queues for the writer it already holds from one that is honestly waiting still needs a fiber identity `std.Io` does not hand a Service.** Named as an open question in [ADR 107](../adr/107-a-wait-for-a-connection-has-a-bound.md) and carried in the roadmap.
- **An `AnyScope` carries no route**, so a statement sent from the far side of a function pointer reaches the watcher with `route` null ([ADR 108](../adr/108-a-statement-can-be-watched.md)).
- **A children statement cannot be explained**, only the statement that reads the parents ([ADR 232](../adr/232-a-read-can-show-its-plan.md)).
- **The SQLite pool has no live test against real contention**, two writers meeting and `busy_timeout` expiring, per [the roadmap](../roadmap.md).
- **Nothing reports how a pool is doing**: connections in use, how long a caller waited, statements run, per [the roadmap](../roadmap.md).
- **Whether `sql/live.zig`'s `connect_on_init = size` workaround is still needed is untested.** [ADR 122](../adr/122-the-panic-under-the-panic.md) says the reconnector may now park under `std.Io.Threaded` since it moved to an `Io.Group` task, and asks that it be re-tested rather than assumed before removal.
