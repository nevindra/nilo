# Deadlines

**A deadline in nilo limits one wait on the network, never a whole request, and nothing ever cancels a handler while it is running.**

**Guide:** [Deadlines](../guide/deploying.md#deadlines) · **Reference:** [`listen` options](../reference/app.md#listen-options), [`Ctx`](../reference/ctx.md), [`nilo.deadline`](../reference/middleware.md#nilodeadline), [`nilo_fetch`](../reference/fetch.md), [What time it is](../reference/core.md#the-clock)

The code is `http/bulkhead.zig` (`Options`, `Deadlines`), `http/ctx.zig` (`overdue`, `timeLeftMs`, `giveDeadline`, `giveDefaultDeadline`, `tookOver`, `armWriteLimit`), `http/deadline.zig` (the `nilo.deadline` middleware), `core/limits.zig` (`Limits`, `Bound`), `core/scope.zig` (`timeLeftOf`, `within`), `fetch/deadline.zig` and `fetch/fetch.zig` (`Exchange`, `timeout_ms`, `stall_ms`), and `sql/postgres.zig` (`Limits.waiting`/`waited` around a wire).

## Overview

```
inbound, listen()                          outbound, a Service
------------------------------             ------------------------------
header_timeout_ms   one head, absolute     nilo_start(io, limits)
idle_timeout_ms     between requests       Bound.arm(limits, ms)  -> zio.AutoCancel
body_timeout_ms      \ one read run,       Bound.fired()          -> Engine: cancels the fiber
body_min_rate, grace / rate-floored        (no Engine)            -> cancels a task instead
write_timeout_ms    one write

request_deadline_ms (listen floor)         fetch's Exchange:
  |> nilo.deadline(ms) on a route (wins)     timeout_ms  the whole call
  |> Deadlines.set: the tighter always wins  stall_ms    silence since the last byte
  |> dropped by a takeover unless named

a Service's own wait on its socket (pg.zig, a pool queue)
  -> Limits.waiting()/waited() so the watchdog blames the wait, not the handler
```

## Rules

1. **A deadline limits one wait on the network, not a request or a computation.** Nothing in nilo can be interrupted in the middle of a handler, so every failure a deadline causes shows up as an ordinary read or write error, which every call site already handles. [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)
2. **`listen()` has four operation limits**: `header_timeout_ms` (10,000; one clock for the whole head, started once), `idle_timeout_ms` (75,000; between requests), `body_timeout_ms` (30,000; one read of the body) and `write_timeout_ms` (30,000; one write). Zero turns any of them off. [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)
3. **A buffered body must also arrive at a minimum rate.** The reads that assemble one get `body_grace_ms + bytes / body_min_rate` (defaults 10,000 and 8 KiB/s) on top of the per-read limit, because a per-read limit alone is satisfied forever by one byte every twenty-nine seconds. `body_min_rate = 0` turns the rate floor off and keeps the per-read limit. [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)
4. **A body that misses its deadline answers 408, not 500.** Every timeout arrives as `error.ReadFailed`; `Ctx.slowBody` asks `Deadlines.timedOut()` and turns it into `error.BodyTooSlow`. A 500 would blame the server for something the client did. [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)
5. **A WebSocket has no read deadline after the handshake.** A quiet connection is a working one. What would catch a peer that vanished without a FIN is a ping, which is a separate WebSocket feature and not part of this. The write limit still applies, and that catches a client that has stopped reading. [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)
6. **A Service that reaches the network on its own gets the same clock nilo gives the connection**, as `core.Limits` in `nilo_start(io, limits)`, the same call that hands it `std.Io`. [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)
7. **A `Bound` is armed in place and never returned by value.** `bound.arm(limits, ms)` takes `*Bound` because the Engine's timer state depends on its address (`zio.AutoCancel` stores `&self` as its timer's userdata); a `Bound` copied after arming would leave the timer pointing at an abandoned slot. The only mistake this design allows is forgetting to call `arm`, and that is harmless: an unarmed `Bound` limits nothing. [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)
8. **Ask the bound why a call ended, not the error.** `std.Io.Reader`'s error set is fixed, so a cancellation arrives as an ordinary `error.ReadFailed`. After the call, check `bound.fired()`. [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)
9. **With an Engine, a `Bound` cancels the fiber's operation; without one, it cancels a task instead**, because `std.Io.Threaded` has no fiber to interrupt but can cancel the task the wait runs in. The Engine's slot is `zio.AutoCancel`, measured at 176 bytes and held in the 192-byte `Limits.slot_size` that Core declares and `http/bulkhead.zig` checks at compile time. [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)
10. **An outbound call has two separate clocks, and both apply.** `timeout_ms` limits the whole call; `stall_ms` limits silence since the last byte arrived. A call that is honestly slow and a peer that has gone quiet are different failures and need different responses: a stalled segment is retried on a fresh connection, a timed-out one is not. [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)
11. **A route sets its own request deadline with `nilo.deadline(ms)`; `listen()`'s `request_deadline_ms` is only the default every request starts with.** Every `arm*` call for a read goes through `Deadlines.set`, and `armWrite` has the rule of the next entry: the nearer of two limits wins, so a deadline can only get shorter, never longer. [ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)
12. **A request deadline reaches the write too, one case wide.** `Ctx.armWriteLimit` re-arms the write clock where the answer or a takeover writes, and `serve.handleConnection` arms `write_timeout_ms` again before every request. When what is left of the deadline is no more than `write_timeout_ms` the write is bounded by the deadline; when more is left it keeps its per-write limit, because the Engine holds one timeout per side and an absolute time would cut a long, steady download at `write_timeout_ms`. A deadline already passed leaves the write alone, so its 503 can go out. [ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)
13. **A request deadline does not interrupt a running handler either.** It catches the same things the operation deadlines above already limit (a slow read, a slow write), and gives the handler `c.overdue()` and `c.timeLeftMs()` to check for itself. Both return safe answers (`false`, `null`) on a route with no deadline. [ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)
14. **What happens at the deadline depends on what has already been sent.** If nothing was sent, the answer is a 503 naming the budget. If something was already sent, it is left alone, because a half-sent response cannot become a 503. A handler that finishes late without checking still answers, and a warning is logged instead of the answer being thrown away. [ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)
15. **Taking over the connection drops a default deadline but keeps one the route asked for.** `c.stream()`, `c.events()`, `c.upgrade()` and `c.bodyStream()` all go through one function, `tookOver`, so a default meant for health checks cannot cut off an hour-long stream, while a route that called `nilo.deadline(ms)` and then streamed keeps what it asked for. [ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)
16. **A Service waiting on its own socket counts as parked, and has to report it.** `Limits.waiting()`/`waited()` tell the watchdog a fiber is parked inside a Service's own `Io` (a Postgres round trip, a pool queue), one pair per statement rather than per row. `nilo_fetch` reports one pair per socket step instead (the head, each body read, the drain), because a body read in pieces hands the fiber back to the handler in between. Without this, every slow query and every slow outbound call was wrongly reported as a handler blocking its thread. [ADR 210](../adr/210-a-services-wait-on-its-own-socket-is-a-park.md)
17. **A route's deadline reaches the calls it makes.** A Scope that declares `timeLeftMs()` (a `Ctx`) is read by `nilo_fetch`, `nilo_s3` (through fetch) and `nilo_sql`, and each call takes the shorter of its own bound and the time left through `core.within`; a request whose time has passed makes no call. SQL arms a `Bound` around the Wire call and sends nothing to the server. [ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)

## Decisions

| ADR | What it decides |
|---|---|
| [022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md) | The four inbound operation limits, the body rate floor, and what each timeout tells the client |
| [056](../adr/056-the-way-out-was-open-the-clock-was-not.md) | `core.Limits`, how a Service arms a `Bound`, and fetch's split between `timeout_ms` and `stall_ms` |
| [105](../adr/105-a-route-can-say-how-long-it-has.md) | `nilo.deadline(ms)`, `request_deadline_ms` as the default, and what taking over the connection does to it |
| [210](../adr/210-a-services-wait-on-its-own-socket-is-a-park.md) | A Service reports its own waits to the watchdog through `Limits.waiting`/`waited` |

Related topics: the watchdog these deadlines report to, and what counts as parked, is [ADR 013](../adr/013-handlers-must-not-block-the-thread.md) (engine); the per-connection memory a `Bound`'s slot costs is measured against [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory); the per-route override pattern `nilo.deadline` follows is [ADR 099](../adr/099-a-route-can-say-what-covers-it.md) (middleware); why a Fitting is the layer that can hold `Limits` at all is [ADR 061](../adr/061-a-fitting-borrows-the-loop.md) (fetch); the SQL-side deadline this does not replace, `tx.deadline`, is [ADR 043](../adr/043-a-deadline-needs-a-connection-you-hold.md) (sql-runtime).

## Open questions

- **Nothing tells a handler that its client has gone.** A read-side EOF does not mean the client left (a half-closed client is still waiting for its answer), so the obvious implementation is wrong. Tracked in [the todo list](../todo.md) under `nilo_http`; it needs two separate signals, not one flag.
- **A deadline that also covers `nilo.sleep` and `nilo.Mutex.lock`.** Both already return `error.Canceled` on shutdown, and a caller cannot yet tell that apart from a deadline by the error name alone. [ADR 105](../adr/105-a-route-can-say-how-long-it-has.md) records it as worth doing; it is not done.
