# A service is stopped before the loop is

`listen()` hands every service the Engine's `std.Io` and lets it finish
building itself ([ADR 0040](0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)).
Nothing ever told it to stop.

For a year that cost nothing visible, because the one service that puts work
on the loop — `nilo_sql`'s pool — put it on an OS thread instead, and a thread
nobody joins is a thread the process exit reaps. Then pg.zig moved its
reconnector to an `Io.Group`, the work became a task on nilo's own loop, and
the gap turned into this:

```
info: nilo stopped
thread 398981 panic: reached unreachable code
zio/src/runtime.zig:1592: std.debug.assert(self.task_count.load(.acquire) == 0);
http/engine/zio.zig:919:  defer rt.deinit();
```

A Runtime cannot be torn down while a task is outstanding, and nilo was tearing
it down with one outstanding.

## What it actually breaks, which is more than it looks

Two paths, and the second is the one nobody would have predicted.

**nilo looks at the world and refuses to start.** `db.checking` finds a Row
that disagrees with its table, `nilo_start` returns `error.SchemaMismatch`, and
the person reading the message nilo worked hard to write gets a Zig panic
stapled underneath it. That reads as "and then nilo crashed", which is the
opposite of what just happened.

**And an ordinary server, stopped normally, whose database never came up.**
The log says `info: nilo listening…`, then `info: nilo stopped`, then it
panics. That is not an edge: it is every deploy where Postgres is down, which
is exactly the case
[ADR 0039](0039-the-shape-of-a-query-is-settled-while-compiling.md) promises
nilo survives.

It also makes a sentence in
[ADR 0062](0062-a-pool-that-dialled-itself-whatever-it-was-told.md) false.
That ADR recorded `bench/sql_server.zig` as booting with the database switched
off, connecting when it came up, **and shutting down clean**. The first two
hold. The third was only ever tested against a database that came up.

## The shape

`nilo_stop` is the mirror of `nilo_start`, read by name like every other
marker:

```zig
pub fn nilo_stop(self: *Self) void
```

**One arity, no `Io`, no error**, and each of the three is a decision.

No `Io`, because the loop a service is stopped on is the loop it was started
on. A service that needed to remember it kept it in `nilo_start`, which
`nilo_sql`'s pool does.

No error, because this runs from a `defer` on the way out of `listen()`, where
there is nobody left to hand a failure to. A service that hits trouble putting
something down logs it and carries on — which is what every `deinit` in this
repository already does.

One arity, because there is no second thing to hand it. `nilo_start` has two
([ADR 0065](0065-the-way-out-was-open-the-clock-was-not.md) added `limits`), and
that was a real cost paid for a real reason; nothing here needs the same.

## Where it runs, and why both halves matter

Inside the Engine's `serve`, registered immediately after the Runtime:

```zig
const rt = try zio.Runtime.init(gpa, …);
defer rt.deinit();
defer stopping(state);
```

Defers unwind in reverse, so this lands **after the connection group is
cancelled and before the Runtime is deinitialised**. Both edges are
load-bearing. Stop a service while a handler still holds it and that is a
use-after-free; leave it running past `rt.deinit()` and that is the assert
above.

**It runs on the failure paths too**, which is the case that named the ADR.
`ready` can start a pool and then refuse the boot, and "the server did not
start" has to mean the pool let go of the loop. So `Registry.stopAll` is
written to survive a service whose `nilo_start` never ran, and `Db.nilo_stop`
clears `wire` so that it and the caller's own `defer db.deinit()` are each a
no-op after the first.

Services stop in the **reverse** of the order they were provided — the ordinary
unwinding order, so a service built on top of another is put down first.

## What it costs

Against [ADR 0018](0018-the-trade-budget-has-three-axes.md)'s axes:

- **Allocations per request: none.** This is startup and shutdown only.
- **Throughput, p99, memory per connection: nothing.** Not on any path a
  request takes.
- **Binary size:** one nullable function pointer per registered service, and
  one call site. A program whose services declare no `nilo_stop` generates the
  branch and nothing else.

## The alternative that was rejected

**Leaving it to the caller's `defer db.deinit()`.** That is where the teardown
lives today and it is one line, already written in every example. It cannot
work, and the reason is ordering rather than taste: `db.deinit()` is the
caller's defer, so it runs *after* `listen()` returns — and `listen()` returns
after the Runtime is gone. There is no line a caller can write that runs inside
`listen()`, which is the only place this can happen.

**Cancelling the pool's task from nilo's own group** was the other idea. nilo's
`zio.Group` holds the connections and the background work it spawned itself; a
task pg.zig put on the loop is in pg.zig's group and nilo cannot see it. A
framework that reaches into a driver's internals to shut it down is a framework
that breaks on the driver's next release — which is precisely how this
surfaced.

## Consequences

- `nilo_stop` on the marker list, `Registry.stopAll`, `App.serverStopping`, and
  a `stopping` hook in the Bulkhead's contract — the first change to that
  contract since [ADR 0065](0065-the-way-out-was-open-the-clock-was-not.md).
- `sql.Db.nilo_stop`, which closes the pool. **A `Db` is not usable after
  `listen()` returns**, which it was not usefully before either: the caller's
  `defer db.deinit()` was already closing it one line later.
- Four refusals for a malformed `nilo_stop`: not a function, wrong arity, taken
  by value, and one that can fail.
- Three tests on the registry, and two reproductions that now exit 0 where they
  used to panic.
- pg.zig is pinned past
  [its own fix](https://github.com/lalinsky/pg.zig/commit/91d07055c57b80de1fb4c91129d56ecd9799bce8)
  for the double unlock this was found underneath — see
  [ADR 0152](0152-the-panic-under-the-panic.md).
