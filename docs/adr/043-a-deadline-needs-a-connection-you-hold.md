# A deadline needs a connection you hold

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)

## Context

[ADR 022](./022-a-deadline-belongs-to-an-operation-not-to-a-request.md) says an operation should have a deadline. A query did not have one. `Db.Opts` carries `timeout_ms`, which bounds how long a caller waits for a free connection, and stops the moment one is handed over. After that a statement may run until the client gives up, the request is cancelled, or somebody notices in a dashboard.

## Decision

### `tx.deadline(ms)`, on the transaction and not on `Db`

```zig
var tx = try db.begin(c, .{});
defer tx.deinit();
try tx.deadline(2_000);
const rows = try tx.select(Report, c, .{ .where = … });
```

`tx.deadline` sends `SET LOCAL statement_timeout` down the connection the transaction is holding. Statements after it that run past the number come back `error.TimedOut`. Postgres undoes a `SET LOCAL` at the end of the transaction however it ends, so the connection goes back to the pool carrying nothing.

**On the transaction, and not on `Db`, because there is no way to attach a deadline to a statement in the same message as the statement.** `SET` takes no placeholder and the extended protocol has no field for it, so a deadline is always a second command, which means it has to travel down the same connection as the statement it is bounding. `db.select` takes whichever connection is free and gives it straight back, so there is no *it* to set anything on. Holding one connection across two statements is the whole of what a transaction already is; a deadline is the second thing that needs it.

**`error.TimedOut` is a fifth member of `wire.Error`**, which is a short list on purpose. It earns the place because a deadline nobody can tell fired is half a feature: the handler that chose the number is the one that knows whether to shed the request, answer from a cache, or ask for less. It carries no default status, unlike `AlreadyExists`: a deadline means something different every time it is set.

### A statement that fails inside a transaction does not cost a reconnect

The first live test of a cancelled statement came back green with an error line under it: a transaction could not be rolled back (`ConnectionBusy`). It reproduced with an ordinary unique violation too, so it had nothing to do with deadlines and had been true for as long as transactions have.

Postgres answers a failed statement inside a transaction with a `ReadyForQuery` whose status byte is `E`, meaning this transaction is aborted, a state the session recovers from with exactly one command, `ROLLBACK`. pg.zig reads the byte and maps it to its own `.fail`, which is also what it sets when the socket dies, and `canQuery` refuses both. So the `ROLLBACK` this module has to send was refused by the driver, and `Tx.rollback` did the only safe thing left: destroyed the connection rather than return one it could not vouch for. Correct, and paid for with TCP, TLS and auth on every failed statement.

`Tx.revive` tells the two apart. The signal is `conn.err`: it is set only by an `ErrorResponse`, so an `err` beside `.fail` means a statement got a reply and the socket is alive. `Tx.fresh`, which every statement starts with, turns that into `Tx.aborted` before it empties `err`, and `revive` reads `aborted`.

**Every statement on an aborted transaction is revived and sent, not only the `ROLLBACK`.** Postgres answers one with `25P02`, *current transaction is aborted*, which is the truth and the answer the guide always promised. Left in `.fail`, pg.zig refused it before it left the process, `translate` called that `Disconnected`, and the connection was destroyed.

**A commit on an aborted transaction sends a `ROLLBACK` and answers `error.QueryFailed`.** Sent, the `COMMIT` is answered with the command tag `ROLLBACK` and no error at all, and pg.zig does not read the tag, so a handler that caught a statement's error without a savepoint and then committed was told its work was kept, answered 200, and had kept none of it. A `ROLLBACK` that cannot reach the server answers `Disconnected` instead, the nearer truth. `ROLLBACK TO SAVEPOINT` is the one statement that clears `aborted`, because it is the one an aborted transaction takes. The SQLite Wire, whose transactions survive a failed statement, is held to the same rule so that a handler tested against it fails the way it will fail on Postgres ([ADR 065](./065-one-writer-is-not-a-setting-it-is-the-database.md)).

### Proven with a severed connection, not a passing behaviour

The fix is not falsifiable from behaviour, which is why it went untested for a cycle: `Pool.release` destroys the connection and dials a replacement on the spot, so the rows come back either way and `Pool.stats()` reads the same. A test written against what a handler sees passes whether or not the fix is there, the shape [ADR 032](./032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) is about.

**A TCP proxy in the test, between the pool and the Postgres that `DATABASE_URL` names, run as tasks on the same `std.Io.Threaded` the pool dials through.** `sql/severed.zig` listens on port 0, accepts, dials the real server, pumps both ways, and exposes `cut(index)`. The `Db` under test is opened against the proxy with `size = 1`, so the connection a transaction holds is the one the proxy can point at.

Three properties of the cut are the design rather than the plumbing:

- **It is a reset, not a close.** A FIN leaves the client in `CLOSE_WAIT`, its next write succeeds, the far end answers RST, and the read then sees `EPIPE`, which `std.Io.Threaded` spells `error.SocketUnconnected`. `translate` lists it with the other dead-socket names now, because a statement revived into an aborted transaction meets exactly that write. An RST while `ESTABLISHED` puts `ECONNRESET` on the next write, which is `ConnectionResetByPeer` at the caller. `SO_LINGER` with a zero timeout is how `close` says RST, and a write that beats the reset succeeds, is answered by it, and the read after it meets `ECONNRESET` all the same.
- **The pumps are cancelled before either descriptor is closed.** A close under a thread blocked in `readv` wakes nothing and leaves the socket open underneath, so no reset would ever go out. `Future.cancel` gets a task out of a syscall.
- **A transaction ends with `commit`, never `deinit` alone**, because a rollback that cannot reach the server logs at `err` and the test runner counts that as a failure nothing can expect. `commit` walks the same `revive` -> `fresh` -> statement path and returns the error instead.

Two tests hold it. The first runs a second statement after the cut and then a commit, and reads `postgres.dirtyConnections()` move by one: the dead half of `revive`, against the live half where it holds still. The second is the path where a stale `err` and a real transport failure meet: `fresh` reads the aborted transaction off the `23505`, the commit rolls back rather than committing, and the `ROLLBACK` is the first thing to touch the reset socket. Without `fresh`, that write failure is reported as the `AlreadyExists` still on the connection, the bug, verbatim. What neither test can see is a `revive` that wrongly let a *dead* connection out; telling that apart needs a counter that moves only when a statement is written, and nothing reads it yet.

## What was rejected

**A pool-wide ceiling in the startup packet.** This was the intended design and it is the one that costs nothing per query: PostgreSQL treats an unknown startup parameter as a run-time setting, so `statement_timeout` handed over at connect would apply to every statement on every connection with no round trip at all. It could not be built against the driver pinned when this was decided: `auth.zig` constructed the startup message from `username`, `application_name` and `database` and never passed the parameter map, though the field existed on both sides. The pin has carried the fix since `nevindra/pg.zig@0a8dab4` (upstream `2907296`), so this is no longer rejected but not yet built; it is under Next in the roadmap.

**Adding `Db.Opts.statement_timeout_ms` anyway**, to be honoured when the pin moves. An option that is declared, plumbed and silently does nothing is the defect above; the option arrives with the pin.

**Sending the `COMMIT` on an aborted transaction and letting Postgres say so**, which is what `commit` did until 2026-09. Postgres says so with a command tag, not an error, and the tag is the one thing nothing on this side reads; the test that proves it is "a commit after a failed statement nobody undid is refused" in `live.zig`.

**A socket read timeout**, `pg.Conn.QueryOpts.timeout`. It is a no-op in the pinned driver, and it would be the wrong mechanism if it worked: `SO_RCVTIMEO` gives up on reading the answer and leaves the statement running on the server, holding its locks. `statement_timeout` cancels the statement where it is running.

**A deadline on `db.select`, outside any transaction.** Two round trips for one query, every time, and the `SET` would have to be `SET` rather than `SET LOCAL`, which means the connection goes back to the pool carrying it and the next request inherits a deadline it never asked for.

**A deadline as an argument to `begin`.** Same number of round trips, and it breaks the signature of a call that is already written.

**`pg_terminate_backend` from a second connection**, to sever the test connection. Postgres hangs up when it gets round to it, not between two lines of the test, and it hangs up with a FIN, the spelling that reports wrong. The proxy's `cut` is a call that has returned before the next statement is written.

**Putting the severed-connection case in `sql/live.zig`.** It would run there, on the same `Threaded`. It is a root of its own so that a proxy that wedges is a binary that wedges, with a name of its own in `ps`, rather than one test among a hundred.

**Closing the socket and letting the pumps find out.** The order that deadlocks: a close under a blocked read wakes nothing.

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes:

| Axis | Cost |
|---|---|
| Allocations per request | None. The statement is printed into a stack buffer; nothing on the HTTP request path changed. |
| Memory per idle connection | None. No new field on `Ctx` or on a pooled connection. |
| Throughput and p99 | None for a transaction that does not call `deadline`. One round trip for one that does, the price named at the call site. A failed statement inside a transaction got faster: a destroyed connection and a reconnect became a `ROLLBACK`. |
| Binary size | Zero on every measured binary: pg.zig is `.lazy = true`, so none of this is fetched, let alone linked, by a program that does not name `nilo_sql`. |

The severed-connection test itself costs nothing on any of the four axes: a test root under `test-sql`, skipped when `DATABASE_URL` reaches nothing. The proxy is two 8 KB buffers per direction on task stacks, for the life of one test.

## Consequences

- A handler can bound a query, and can tell when the bound was what stopped it. Both halves are opt-in and neither costs anything to a caller who does not use them.
- A pool-wide floor is an operator's job today, not nilo's: `ALTER ROLE app SET statement_timeout = '30s'` does what the startup parameter would have done, from the side that can already do it.
- `postgres.zig` reads one pg.zig private field, `conn._state`, in one function, and that function says what it depends on and when to delete it.
- Two upstream defects are written down here rather than in a comment nobody finds: `startup_parameters` never reaching the startup message (fixed in the pin since `0a8dab4`), and `.fail` conflating an aborted transaction with a broken connection.
- Whether zio spells a peer's reset and a peer's plain close the same way `std.Io.Threaded` does is not known, and is a note rather than a change.
