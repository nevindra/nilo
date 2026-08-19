# 0086 — work that is not a request belongs to the server, not to a service

**Status:** accepted
**Amends:** [ADR 0029](./0029-a-spawned-fiber-belongs-to-the-server.md), [ADR 0079](./0079-there-is-a-phase-before-the-server.md)

## Context

[ADR 0029](./0029-a-spawned-fiber-belongs-to-the-server.md) put `spawn` in the
Bulkhead and named the family it was for: "a metrics exporter that batches
before it sends, a job that runs every minute". Then it shipped the fiber and
not the place to start one from.

`nilo.spawn` answers `error.NoServer` unless a server is running, which is
correct — the fiber is owned by the accept loop's group, counted while it runs
and cut off when the grace period ends. But `listen()` does not return, so
there is no "after the server started" for a program to spawn from, and the
only place left is inside a handler. Every application that wanted a ticker
started it from the first request that happened to arrive.

The obvious fix is four lines. `serve` set the group after it called `ready`:

| | |
|---|---|
| `http/engine/zio.zig:746` | `try ready(state, rt.io())` — where `nilo_start` runs |
| `http/engine/zio.zig:820` | `background.store(&group, .release)` |

Nothing between them accepts a connection, so moving the second above the
first costs nothing and lets a Service start its own ticker from `nilo_start`.

**That is not enough, and the reason is one line in `App`.**

## The finding

`startServices` is idempotent, and it has to be
([ADR 0079](./0079-there-is-a-phase-before-the-server.md)): a program that
migrates before it serves calls `app.start(io)` and then `listen()`, and
opening the pool twice leaks the first one. So the guard:

```zig
fn startServices(self: *App, io: std.Io, limits: bulkhead.Limits) anyerror!void {
    if (self.services_started) return;
```

means that under the order ADR 0079 recommends and `guide/sql.md` publishes —

```zig
try app.start(threaded.io());        // nilo_start runs HERE
try migrate(&db);
try app.listen(.{ .port = 8080 });   // ready() returns immediately
```

— `nilo_start` runs in a phase with **no server at all**. The `Io` is the
caller's own `std.Io.Threaded`; there is no zio Runtime, no accept loop and no
group. A ticker started there gets `error.NoServer`, and `listen()` never asks
again.

So a Service hook is the wrong seam whatever it is called. `nilo_start` is the
phase after the pool and before the socket, and background work needs the
phase after the socket. The two are not the same phase and one of them is
optional.

## Decision

**`app.spawn(func, args)` — registered beside the routes, started by the
server.**

```zig
try app.provide(&exporter);
try app.spawn(flushEvery, .{&exporter});
try app.listen(.{ .port = 8080 });
```

The same word as the primitive, because it is the same fiber; what differs is
when. `nilo.spawn` is *now* and needs a running server. `app.spawn` is *when
there is one*, and does not care which of ADR 0079's two orders the program
used, because it is not attached to the service phase at all.

The shape of the work is unchanged from ADR 0029, and it is a loop around a
wait that can say stop:

```zig
fn flushEvery(exporter: *Exporter) void {
    while (true) {
        nilo.sleep(60_000) catch return;   // Canceled — the server is going
        exporter.flush() catch |err| std.log.err("flush: {t}", .{err});
    }
}
```

Two things follow, and both are the point rather than side effects. The
group **does** move above `ready`, because that is where the App now starts
this work — and a `ready` that fails now cancels whatever it had already
started, which is what "the server did not start" has to mean. And the two
guards in `App` are separate flags: `services_started` is skipped when
`start(io)` ran first, and skipping the background with it is exactly the bug
above.

### What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes:

- **Allocations per request: none.** Nothing on the request path is touched.
  One allocation per registered function, at registration, for the arguments —
  their type differs per entry and the list holds one kind of thing.
- **Memory per idle connection: none.** The fiber is per process, not per
  socket. It is not free — a fiber holds its stack at its high-water mark, and
  ADR 0029 measured one at 8,673 bytes — but it is paid once per ticker rather
  than once per connection, which is the whole difference between this and the
  broadcast writer ADR 0029 refused.
- **Throughput and p99: none.** The accept loop and the request path are
  unchanged; this is two statements at startup.
- **Binary size:** paid only by a program that calls `spawn` — the trampolines
  are instantiated per registered function and the linker drops the list for
  one that never does. *Not yet measured; the stripped `ReleaseFast` number
  owes its line in ADR 0018's running total.*

## What was rejected, and why

- **A second Service hook, `nilo_serving`.** Type-driven, no allocation, and
  it was the first shape drawn. It only ever serves something that is already
  a Service, which a ticker need not be, and it buys that by adding a second
  comptime hook and its refusals to `service.zig` — where the ADR 0065 note
  says a *third* `nilo_start` parameter was refused for less. `app.spawn`
  reaches both a Service and a plain function.

- **Moving the group above `ready` and stopping there.** Genuinely fixes the
  common case, and every example in this repository takes it. It leaves the
  published ADR 0079 order silently starting nothing, which is the trap this
  repository has been caught by four times and writes down each time: a thing
  that is documented, plausible, and has never been run.

- **`app.every(ms, func, args)`.** Tempting, because the case is nearly always
  a schedule. It bakes in policy — what happens when a tick overruns the next
  one, whether a missed tick is dropped or caught up, whether the first tick is
  at zero or at `ms` — and none of those have an answer that is right for
  everybody. `spawn` plus `sleep` is the loop, written where it can be read;
  a schedule can be built on top later without taking the primitive back.

- **`nilo.spawn` queueing when there is no server yet.** It would make one call
  do both jobs, at the price of turning a documented error into hidden state,
  and of `error.NoServer` — which is what a unit test calling a handler
  directly gets — quietly meaning something else at startup.

## Consequences

- `App` grows a list and a flag, both startup-only.
- The Engine's group is armed before `ready` rather than after it.
- `http/live.zig` is the first test in the framework's own suite to stand a
  real server up. It listens on port 0 and never connects: the feature starts
  without being asked, so nothing needs to know the port and two optimize
  modes running at once cannot collide.
- `nilo.spawn` is unchanged, and stays the right call from inside a handler.
