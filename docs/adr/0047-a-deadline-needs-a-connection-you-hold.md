# A deadline needs a connection you hold, and holding one is what a transaction is

[ADR 0023](./0023-a-deadline-belongs-to-an-operation-not-to-a-request.md) says
an operation should have a deadline. A query did not have one. `Db.Opts`
carries `timeout_ms`, which bounds **how long a caller waits for a free
connection** and stops the moment one is handed over — after that a statement
may run until the client gives up, the request is cancelled, or somebody
notices in a dashboard.

## What was decided

**`tx.deadline(ms)`**, which sends `SET LOCAL statement_timeout` down the
connection the transaction is holding. Statements after it that run past the
number come back `error.TimedOut`.

```zig
var tx = try db.begin(c);
defer tx.deinit();
try tx.deadline(2_000);
const rows = try tx.select(Report, c, .{ .where = … });
```

**On the transaction, and not on `Db`.** That is the decision rather than a
shortcut, and it comes out of one fact: there is no way to attach a deadline
to a statement in the same message as the statement. `SET` takes no
placeholder and the extended protocol has no field for it, so a deadline is
always a second command — which means it has to travel down the same
connection as the statement it is bounding. `db.select` takes whichever
connection is free and gives it straight back, so **there is no *it* to set
anything on.** Holding one connection across two statements is the whole of
what a transaction already is; a deadline is the second thing that needs it.

**`error.TimedOut` is a fifth member of `wire.Error`**, which is a short list
on purpose. It earns the place because a deadline nobody can tell fired is
half a feature: the handler that chose the number is the one that knows
whether to shed the request, answer from a cache, or ask for less. It carries
**no default status** — unlike `AlreadyExists`, a deadline means something
different every time it is set.

## Why not the alternatives

**A pool-wide ceiling in the startup packet.** This was the intended design
and it is the one that costs nothing per query: PostgreSQL treats an unknown
startup parameter as a run-time setting, so `statement_timeout` handed over at
connect would apply to every statement on every connection with no round trip
at all. **It cannot be built against the pinned driver.** `Conn.AuthOpts` has
a `startup_parameters` field, `proto.StartupMessage` has a `params` field and
writes it correctly — and `auth.zig` constructs the message from `username`,
`application_name` and `database` and never passes the map. The plumbing
exists on both sides and is disconnected at the last hop. It is a one-line
fix upstream, and until it lands the field is decoration.

**Adding `Db.Opts.statement_timeout_ms` anyway**, to be honoured when the pin
moves. Refused, and the reason is what this ADR just walked into: an option
that is declared, plumbed and silently does nothing is exactly the defect
above, and having just spent an afternoon on somebody else's version of it,
shipping one is not the lesson to take. The option arrives with the pin.

**A socket read timeout.** `pg.Conn.QueryOpts` has a `timeout` field, which
would look like the answer. It is a no-op — the body is commented out behind
a `// FIX: set timeout` and all it does is set a flag. It would also be the
wrong mechanism if it worked: `SO_RCVTIMEO` gives up on *reading the answer*
and leaves the statement running on the server, holding its locks, with the
connection in a state nobody can name. `statement_timeout` cancels the
statement where it is running.

**A deadline on `db.select`, outside any transaction.** It would be two round
trips for one query, every time, with nothing to amortise them over — and the
`SET` would have to be `SET` rather than `SET LOCAL`, which means the
connection goes back to the pool carrying it and the next request inherits a
deadline it never asked for. That is worse than not having the feature.

**A deadline as an argument to `begin`.** Same number of round trips, and it
breaks the signature of a call that is already written. A method is additive
and puts the cost where it is paid.

## What it costs

Put against the four axes
([ADR 0018](./0018-the-trade-budget-has-three-axes.md)).

| Axis | Cost |
|---|---|
| Allocations per request | **none.** The statement is printed into a 48-byte stack buffer; nothing on the HTTP request path changed. |
| Memory per idle connection | **none.** No new field on `Ctx` or on a pooled connection. |
| Throughput and p99 | **none** for a transaction that does not call it. **One round trip** for one that does, which is the price named at the call site. A failed statement inside a transaction got *faster* — see below. |
| Binary size | **zero** on every measured binary. No example and no benchmark imports `nilo_sql`, and pg.zig is `.lazy = true`, so none of this is fetched let alone linked ([ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)). |

## What the first test corrected

**Every failed statement inside a transaction was costing a full reconnect,
and nothing could see it.** The first live test of a cancelled statement came
back green with an error line under it: *a transaction could not be rolled
back (ConnectionBusy)*. It reproduced with an ordinary unique violation too,
so it had nothing to do with deadlines and had been true for as long as
transactions have.

The chain: Postgres answers a failed statement inside a transaction with a
ReadyForQuery whose status byte is `E` — *this transaction is aborted* — which
is a state the session recovers from with exactly one command, `ROLLBACK`.
pg.zig reads the byte and maps it to its own `.fail`, **which is also what it
sets when the socket dies**, and `canQuery` refuses both. So the `ROLLBACK`
this module has to send was refused by the driver, and `Tx.rollback` did the
only safe thing left: destroyed the connection rather than return one it could
not vouch for. Correct, and paid for with TCP, TLS and auth on every failed
statement.

`Tx.revive` tells the two apart before rolling back. The signal is
`conn.err`: it is set only by an ErrorResponse, and `Tx.fresh` empties it at
the start of every statement — so a set `err` means *this* statement got a
reply and the socket is alive. That interlock exists because of an earlier
bug in the same place, which is the second time `fresh` has turned out to be
load-bearing for a reason it was not written for.

**The fix is not falsifiable from behaviour, and that is why the test reads a
counter.** `Pool.release` destroys the connection and dials a replacement on
the spot, so the rows come back either way and `Pool.stats()` reads the same.
A test written against what a handler sees passes whether or not the fix is
there — the shape
[ADR 0033](./0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) is
about. `postgres.dirtyConnections()` reads pg.zig's own `pg_pool_dirty`, and
the assertion was watched to fail before it was kept.

## Consequences

- A handler can bound a query, and can tell when the bound was what stopped
  it. Both halves are opt-in and neither costs anything to a caller who does
  not use them.
- **A pool-wide floor is an operator's job today**, not nilo's:
  `ALTER ROLE app SET statement_timeout = '30s'` does what the startup
  parameter would have done, from the side that can already do it.
- `postgres.zig` reads one pg.zig private field, `conn._state`, in one
  function, and that function says what it depends on and when to delete it.
  It is the only place in nilo that does.
- Two upstream defects are written down here rather than in a comment nobody
  finds: `startup_parameters` never reaching the startup message, and `.fail`
  conflating an aborted transaction with a broken connection. Both are small
  and both are worth sending.
