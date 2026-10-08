# A spawned fiber belongs to the server, and it is started where the server is running

**Status:** accepted
**Topic:** [engine](../design/engine.md)

## Context

nilo had nowhere to put work that is not a request. Everything that ran, ran because a socket asked for it, which is a good default and is why the per-connection numbers in [ADR 017](./017-the-trade-budget-has-four-axes.md) are as small as they are, but it rules out a whole family of ordinary things: a metrics exporter that batches before it sends, a job that runs every minute, and a message sent to somebody else's WebSocket connection.

A spike (`spike/broadcast`) built four shapes of broadcast and measured them, because sending to a socket a handler does not hold needed `spawn` to build at all, and only one half of what it needed turned out to be affordable. The other half, a Room that broadcasts to sockets, shipped later once the reason it looked unaffordable turned out to be wrong; that is [ADR 035](./035-a-broadcast-rings-a-bell-it-does-not-write.md), which cites this one for `spawn` and stands on its own for everything about broadcasting itself.

Once `spawn` existed, it answered `error.NoServer` unless a server was running, correctly: the fiber is owned by the accept loop's group, counted while it runs and cut off when the grace period ends. But `listen()` does not return, so there was no "after the server started" for a program to spawn from that was not inside a handler, and every application that wanted a ticker started it from the first request that happened to arrive. The obvious fix, moving where the Engine arms its group to before it calls `ready`, was not enough on its own: `App.startServices` is idempotent by design ([ADR 180](./180-work-that-needs-the-services-runs-on-their-loop.md)), because a program that migrates before it serves calls `app.start(io)` and then `listen()`, and opening a pool twice leaks the first one. Under that order, `nilo_start` runs with no server at all, no zio Runtime, no accept loop, no group, so a ticker started from a Service hook there got `error.NoServer` and `listen()` never asked again. A Service hook was the wrong seam whatever it was called: the phase after the pool and before the socket is not the phase after the socket, and the second one is optional.

## Decision

### `spawn` enters the Bulkhead, joined to the server's lifetime

`nilo.spawn(func, args)` runs `func` in a fiber of its own, joined to the accept loop's group rather than detached: counted while it runs, cancelled when the shutdown grace period ends, exactly like a connection. A detached fiber left shutdown lying: `Stop.in_flight` did not count it and `group.cancel()` did not reach it, so a fiber nobody can see at shutdown is not something to hand users. It is unambiguously the Engine's to supply, the same argument [ADR 010](./010-shared-services-need-a-lock-from-the-bulkhead.md) made for `Mutex`: what a fiber is, how one is started, and what happens to it at shutdown are things only the Engine knows.

Two things follow from being joined:

- **`fail` in a spawned fiber says nothing, and that is correct.** The task-local slot is unset there, so `fail.notFound` finds no `InFlight` and returns a plain `error.Failed` with no message, the documented behaviour outside a request already. The one coupling that makes this safe rather than a leak: `bulkhead.slot()` falls back to a threadlocal, `fallback_slot`, and on a server the only thing that sets it is `bulkhead.blocking`, inside `zio.blockInPlace`, which submits to the thread *pool*. The assignment happens on a pool thread and spawned fibers run on executor threads, so the two never collide. **This went off once**: `serveRequest` also set it, on every request, on the executor, and left it set across the request's suspensions, so spawned work wrote into whichever request last set it. It is set there now only with no Engine underneath, and `setFallbackSlot` refuses in Debug to be called from a fiber that has a slot of its own, which every live test in the Debug run passes through. What that check cannot see is a fiber with no slot setting it ([risks](../risks.md#open)).
- **A `Str` must not cross into spawned work.** A `Str` points into the request arena, reset when the request ends, and a spawned fiber outlives the call that started it by definition, so a `Str` captured into one is a use-after-free the moment the request finishes first, and in development the fiber usually wins the race so it will not look like one. Zig cannot catch this: `spawn` takes arguments by value, and the guide says plainly that anything borrowed from a request has to be copied first.

### `app.spawn`: registered beside the routes, started by the server

```zig
try app.provide(&exporter);
try app.spawn(flushEvery, .{&exporter});
try app.listen(.{ .port = 8080 });
```

Same word as the primitive because it is the same fiber; what differs is when. `nilo.spawn` is *now* and needs a running server. `app.spawn` is *when there is one*, registered beside the routes and started by `listen()` once it arms the accept loop's group, independent of which of the two service-start orders the program used:

```zig
try app.start(threaded.io());        // nilo_start runs HERE
try migrate(&db);
try app.listen(.{ .port = 8080 });   // listen() starts what app.spawn registered
```

The shape of the work is a loop around a wait that can say stop:

```zig
fn flushEvery(exporter: *Exporter) void {
    while (true) {
        nilo.sleep(60_000) catch return;   // Canceled — the server is going
        exporter.flush() catch |err| std.log.err("flush: {t}", .{err});
    }
}
```

### A swallowed cancel does not keep the server

The stop reaches a spawned fiber as one cancel, and the first wait the fiber reaches spends it. Work that reads that wait's failure as an ordinary one, a cancelled S3 call logged as a storage error inside a job that then carries on, goes back to its loop with nothing left to cancel it: the `nilo.sleep` that was meant to say stop sleeps instead, the group's cancel waits for the fiber, and `listen()` never returns ([`history.md`](../history.md#a-suite-that-hangs-and-a-build-that-looks-stuck) has the case).

So `spawn` and `spawnLocal` bind a task-local mark, `in_spawned_work`, around the work, and `serve` raises `cancelling_spawned` for the length of the group's cancel; `group.cancel()` waits for every task, so the flag is up for as long as any of them still runs. `nilo.sleep` in marked work answers `error.Canceled` at once while it is up, however many cancels came before. HTTP/1.1 requests are not marked, so one still waiting while the server drains keeps its wait. gRPC calls are, because `spawnLocal` starts them (`http/grpc.zig`); that changes nothing, since the flag is only up while `group.cancel()` runs, which cancels those calls anyway.

**Only `sleep` reads it.** The loop above is the shape spawned work is documented to have, and its `sleep` is the wait that decides whether the loop goes round again. A swallower whose next wait is a queue, a mutex or another S3 call still waits through the stop; the contract for that is the one Zig and zio already have, and nilo uses it itself (`fetch/fetch.zig`, `s3/store.zig`): code that handles `error.Canceled` without returning it calls `nilo.io().recancel()`, so the next cancellation point fails again. The reference says so beside `sleep`.

**The flag is process-wide**, with `background`'s own limit: one server per process. A second server's stop would raise it for the first one's spawned sleeps too, the same way the second would take `background` from the first.

`func` may not fail: there is no request to answer and nobody to answer it, so an error has nowhere to go, and it logs instead. The two things that must not travel in are the same two `nilo.spawn` refuses to survive: a `Str`, and a fail function, which has no request to fail.

The Engine's group is armed before `ready` runs rather than after, so a `ready` that fails cancels whatever it had already started, which is what "the server did not start" has to mean. `App` keeps two separate flags for this: `services_started` (ADR 180's guard, skipped when `app.start(io)` ran first) and `background_started` (set once, by whichever of `listen()`'s two callers reaches it first). They are separate because skipping the background work along with the services is exactly the bug this decision fixes: a program that calls `app.start` before `listen` still needs `listen()` to start what `app.spawn` registered.

## What was rejected

**Accepting the doubled per-connection budget and shipping broadcast anyway**, at the time `spawn` alone was on the table. A second fiber per connection to drain a broadcast queue measured at 8,673 bytes per idle connection against ADR 017's 8,767-byte invariant, doubling the cost of every connection whether or not it broadcasts, for a feature most applications do not use, silently, on a user's behalf. `zio.BroadcastChannel` in place of the queue changed nothing about that number, because the fiber is the price and no amount of cleverness about the queue touches it; it also crashed under connection churn, reported upstream as [zio#667](https://github.com/lalinsky/zio/issues/667). See [ADR 035](./035-a-broadcast-rings-a-bell-it-does-not-write.md) for how the fiber was avoided entirely once zio exposed a way to park on a completion.

**A second Service hook, `nilo_serving`.** Type-driven and allocation-free, and it was the first shape drawn for the ticker problem. It only ever serves something that is already a Service, which a ticker need not be, at the price of a second comptime hook and its own refusals; `app.spawn` reaches both a Service and a plain function.

**Moving the group above `ready` and stopping there.** Fixes the common case, and every example in the repository takes it, but it leaves the published `app.start` / `migrate` / `listen` order silently starting nothing, a trap this repository has been caught by more than once and writes down each time: a thing that is documented, plausible, and has never been run.

**`app.every(ms, func, args)`.** Tempting, because the case is nearly always a schedule, but it bakes in policy that has no answer right for everybody: what happens when a tick overruns the next one, whether a missed tick is dropped or caught up, whether the first tick is at zero or at `ms`. `spawn` plus `sleep` is the loop, written where it can be read; a schedule can be built on top later without taking the primitive back. It was: a schedule is a type that makes the caller answer all three questions, and `every(ms, f)` stays refused ([ADR 161](./161-a-schedule-is-a-type-that-makes-the-caller-choose.md)).

**Leaving it to `recancel` at every catch site.** It is the right contract for code that knows it swallowed a cancel, and the reference points to it. But the swallow that hung a server was not a catch anybody could see: a library's `error.Canceled` became the caller's own `error.Storage` two functions down, and from there it is an ordinary failure. A contract every catch site has to keep is kept by most of them; one wait that refuses once the server is going covers the documented loop whatever the catch sites did.

**Every wait reading the flag** — `Mutex.lock`, a `Gate`, the queues, the outbound calls. It would close the remaining case above, at the price of a load and a task-local read on every wait of every request, on the path ADR 017 counts, for a loop shape nobody is told to write. `sleep` is the wait the documented loop has.

**`nilo.spawn` queueing when there is no server yet.** Would make one call do both jobs, at the price of turning a documented error into hidden state, and of `error.NoServer`, what a unit test calling a handler directly gets, quietly meaning something else at startup.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none: nothing on the request path is touched. `app.spawn` costs one allocation per registered function, at registration, for its arguments. |
| Memory per idle connection | none: the fiber is per process, not per socket. It is not free, a fiber holds its stack at its high-water mark, measured at 8,673 bytes for the broadcast-writer shape that was rejected for exactly this cost, but it is paid once per ticker rather than once per connection. The `in_spawned_work` binding adds a 40-byte `TaskLocal` node to every spawned fiber's stack for its life ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)): once per ticker, and once per gRPC call `spawnLocal` starts, never per idle connection. |
| Throughput and p99 | none on the request path: the accept loop is unchanged, and `nilo.sleep` adds one atomic load, the task-local read only following while a stop is under way. |
| Binary size | paid only by a program that calls `spawn`: the trampolines are instantiated per registered function and the linker drops the list for a program that never calls it. |

## Consequences

- The Bulkhead's contract grows by `spawn`, joined to the server's lifetime; a threaded Engine satisfies it with a thread and a join handle.
- `App` grows a list and a flag, both startup-only, and the Engine's group is armed before `ready` rather than after it.
- `http/live.zig` is the first test in the framework's own suite to stand a real server up: it listens on port 0 and never connects, since the feature starts without being asked and two optimize modes running at once cannot collide.
- The OTel batching exporter and periodic jobs this was built for need only `spawn` and none of the rest of this decision.
