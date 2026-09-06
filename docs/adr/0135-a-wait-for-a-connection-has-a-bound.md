# A wait for a connection has a bound

`Db.Opts.timeout_ms` says how long a caller waits for a free connection. On
Postgres it is handed to pg.zig's pool and honoured. On SQLite `Wire.open` read
`open_opts.size` and dropped the rest, so **the option a caller set to bound a
queue was silently ignored** — and `connect_on_init` is documented as
meaningless there while `timeout_ms` was not.

Underneath it there was nothing to honour it with. `takeWriter` waited on a
`std.Io.Condition` with no deadline at all:

```zig
while (self.conns[0].busy) self.free_writer.wait(self.io, &self.lock) catch
    return error.TimedOut;
```

There is exactly one writer connection to a SQLite database, because
[that is what the database is](0074-one-writer-is-not-a-setting-it-is-the-database.md).
So a handler holding a `Tx` and then sending a statement through `db` rather
than `tx` — one character — queues for the connection it is itself holding, and
waited for as long as the process lived, with nothing in the log and nothing
holding it. On Postgres the same mistake takes a second pool connection and
merely runs outside the transaction.

This is the third wait in this repository to be found with no bound on it, after
the two in `fetch/` that
[CLAUDE.md](../../CLAUDE.md) now warns about in a paragraph of its own: *a wait
on a flag needs a bound and the giving-up path needs to set something.*

## The bound is the Engine's, arrived at the way `fetch`'s is

`std.Io.Condition` has `wait` and `waitUncancelable` and **no timed wait**. Its
internals use `io.futexWaitTimeout`, which is public, so a condition variable
with a deadline could be written here in about thirty lines.

It is not, because nilo already has an answer to "stop a fiber that is waiting"
and it is [ADR 0065](0065-the-way-out-was-open-the-clock-was-not.md): the
Engine owns the timer, a Service owns the number, and `core.Limits` is the
vocabulary between them. `nilo_fetch` bounds an outbound call that way and
`nilo_s3` inherits it. A second mechanism inside `nilo_sql` would be a second
thing to get right, in a file that has already had one wait bug
([ADR 0116](0116-a-queue-per-question-not-one-condition-for-two.md)).

So `wire.OpenOpts` gains a `limits`, `Db.nilo_start` takes one, and the two
`take` calls arm a `Bound` around the wait. A cancellation reaches the parked
fiber, `wait` returns `error.Canceled`, and `bound.fired()` is what says the
cancellation was this wait's own rather than a shutdown.

**`db.nilo_start(io)` is therefore `db.nilo_start(io, limits)`**, which is the
shape `nilo_fetch` and `nilo_s3` already have. `app.listen()` passes the
Engine's; a `Db` a CLI or a test holds passes `.off` and is bounded by nothing,
which is what it was before this either way.

## Armed by a fiber that is going to wait, and by no other

The timer is registered only once the connection has turned out to be busy:

```zig
if (!self.conns[0].busy) {          // the ordinary path
    self.conns[0].busy = true;
    return 0;
}
var bound: core.Limits.Bound = .idle;   // only now
```

Arming is the Engine putting an entry in a timer wheel. Doing that per
statement would put the cost of the queue on every statement that never
queues, which is nearly all of them.

## What it cannot do, and says instead

**It cannot tell the self-deadlock from an honestly busy database.** Doing that
means knowing *which fiber* holds the writer, and `std.Io` hands a Service no
fiber identity to hold it by. A flag on the Wire saying "somebody is in a
transaction" is not enough: two fibers, one holding a `Tx` and one calling
`db.exec`, are the same flag and only one of them is a mistake — the other is a
request that should wait.

So the writer's message names the cause it is most often going to be:

```
nilo_sql: a statement waited 10000ms for the writer connection and gave up.
There is one writer, so either the database is busy or this fiber is queueing
for a connection it already holds — a `db.…` call inside a handler holding a
`tx` waits for itself. `timeout_ms` is the bound.
```

A guess, said as a guess, beats a wait that says nothing. The reader's message
is the other half and names the number to raise.

## Watched firing, because a bound that has never fired is not a bound

Every test under `zig build test-sql` runs on `std.Io.Threaded`, which cannot
cancel a fiber, so every `Limits` they hand a Wire is `.off` and nothing armed
there can ever fire. By
[ADR 0033](0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) that
is the same standing as no bound at all — which is exactly the standing the old
code had.

`sql/deadline.zig` stands a real server up, spawns a fiber that begins a
transaction and then writes `db.exec`, and asserts `TimedOut` comes back. It is
the shape `fetch/deadline.zig` established and it hangs off `test-sql` rather
than `test`, because `test` deliberately does not build this module
([ADR 0075](0075-a-dependency-a-dependent-does-not-import-is-not-downloaded.md)).

**It coordinates no port.** The server asks for port 0 and nothing connects: the
work under test is a spawned fiber (ADR 0086), so the three loopback ranges the
other live files keep apart do not gain a fourth.

**And it names `nilo_sql` rather than `sql.zig`**, which cost `zig build
layering` one line: a module may name itself. `fetch/deadline.zig` reaches its
own module as a file beside it, which builds a second copy — cheap there,
because `nilo_fetch` names only Core. `nilo_sql` names two drivers, a generated
options file and libsqlite, so a second copy would be that wiring written twice
and a `sql.Db` the real one is not equal to. Importing itself is neither upward
nor sideways, and the build hands it the same module instance.

## What it costs

**Nothing on a statement that finds its connection free** — one `bool` test
that was already there, and no timer.

**One timer arm and one release on a statement that queues**, which is a fiber
that was about to park anyway.

**`core.Limits.slot_size` — 192 bytes — of the frame that takes a connection.**
That is stack a handler touches, and by
[ADR 0063](0063-a-handlers-stack-is-per-connection.md) stack is held per
*connection* for the life of it, so this is 192 bytes per connection on a
server that reaches SQLite. It is paid whether or not the timer is armed,
because the storage is declared in the frame either way.

**Nothing on Postgres**, whose `Wire` ignores the new field: pg.zig's pool has
its own acquire timeout and always honoured this number.

## What was rejected

**A timed condition variable built on `io.futexWaitTimeout`.** Above: it is a
second mechanism for something nilo already has one of, in the file that has
already had a wait bug.

**Refusing `db.…` inside a handler that holds a `tx` at compile time.** There
is nothing to see: `db` and `tx` are two values, and whether one is live when
the other is called is a run-time fact.

**A `Locked` rather than a `TimedOut`.** `Locked` means *somebody else holds
this row and you said not to wait*, which is a different sentence. This waited.

**Leaving the wait unbounded and documenting it.** That is what
`connect_on_init` did on this Wire, and the option that was documented as
meaningless is the one nobody was bitten by.
