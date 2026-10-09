# The engine

**The Engine is the bottom layer, the part that talks to the operating system, and nilo never calls it directly: everything goes through the Bulkhead, a fixed contract that lets the Engine be replaced without changing a line of user code.**

**Guide:** [Deploying](../guide/deploying.md), [Work that is not a request](../guide/background.md) · **Reference:** [`listen` options](../reference/app.md#listen-options), [Concurrency](../reference/app.md#concurrency)

The contract is `http/bulkhead.zig`; the only file allowed to name zio is `http/engine/zio.zig`.

## Overview

```
  user code (App, Ctx, Service)
          │  never names zio
          ▼
  http/bulkhead.zig ── the contract: accept, read, write, Mutex, blocking,
          │             sleep, spawn, halfClose, Limits.arm/release
          ▼
  http/engine/zio.zig ── the only file that may name zio (ADR 001)
          │
          │  one acceptor fiber per executor, all parked on one listening
          │  socket, backlog 4,096 (ADR 198, ADR 200)
          ▼
  spawn deals the connection round-robin to an executor, which then
  keeps it start to finish (ADR 199)
          │
          ▼
  serve() reads the head, sheds past max_in_flight (ADR 159), runs the
  handler; a completion the loop still holds is cancelled before the
  frame returns, and a refused request is half-closed before it is
  closed (ADR 077, ADR 195)
```

## Rules

1. **Everything nilo needs from the Engine goes through the Bulkhead, and only the Engine names zio.** nilo uses zio for io_uring, epoll, kqueue and IOCP on top of fibers, instead of writing its own event loop. [ADR 001](../adr/001-zio-as-the-engine-behind-the-bulkhead.md)
2. **A Service with mutable state locks with `nilo.Mutex`, which parks the fiber, not the OS thread.** Handlers run at the same time on every executor thread nilo starts (`Options.threads`, by default one per core the process may use, [ADR 230](../adr/230-a-cpu-quota-sets-the-thread-count.md)), and a `std.Thread.Mutex` would stall every connection on that thread. [ADR 010](../adr/010-shared-services-need-a-lock-from-the-bulkhead.md)
3. **A call that waits on the operating system goes through `nilo.blocking` or `nilo.sleep`, and a handler that skips them is caught at run time.** The watchdog measures the longest time a fiber ran without parking (per message on a WebSocket) and logs a handler that held its thread longer than `block_warning_ms`. A wait through the server's `Io` is not a hold: the run loop's turn stamp, read only for a stretch already too long, says the fiber parked. A blocking call that finds no idle worker starts one, up to the pool's ceiling, so a short call never waits out a long one while the ceiling has room. [ADR 013](../adr/013-handlers-must-not-block-the-thread.md)
4. **Work that is not a request runs as a fiber tied to the server's lifetime.** `nilo.spawn` returns `error.NoServer` when nothing is listening; `app.spawn` registers before `listen()` and starts once `listen()` has set up the accept loop's group. Neither may carry a `Str` or a fail function across. [ADR 028](../adr/028-a-spawned-fiber-belongs-to-the-server.md)
5. **An operation the loop is still holding outlives the stack frame that started it, so the frame does not return until the loop hands it back.** A WebSocket's `Wake` is torn down before its stack and before the socket closes. [ADR 077](../adr/077-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md)
6. **A handler writes a file through one Bulkhead operation, `Dir.writeFileAtomic`, which parks the fiber, not the thread.** `Upload.saveTo` writes to a temporary name next to the destination and renames it into place, so a reader never sees a half-written file. [ADR 097](../adr/097-a-file-is-written-by-the-engine.md)
7. **`address` is read as a prefix, and `"unix:"` listens on a path instead of a port.** A leftover socket file is removed before binding only if it is a socket and nothing is listening on it. A connection that arrives over a unix socket is trusted like a loopback proxy, because only the local machine can reach it. [ADR 103](../adr/103-a-path-is-an-address-to-listen-on.md)
8. **Once `max_in_flight` requests are being answered, the next one gets an immediate 503 instead of waiting in a queue.** The count is checked before the arena is touched or the router is asked, and the connection is closed instead of kept, because a shed client should move to a different replica. [ADR 159](../adr/159-a-server-past-its-limit-says-so-at-once.md)
9. **When the accept loop runs out of file descriptors it waits instead of stopping the server.** On `ProcessFdQuotaExceeded`, `SystemFdQuotaExceeded` and `SystemResources` it backs off from 5 ms up to one second and retries. `listen()` warns at startup when `ulimit -n` is lower than `max_connections`. [ADR 194](../adr/194-an-accept-loop-that-is-out-of-descriptors-waits.md)
10. **A rejected request's connection is half-closed before it is closed, whenever unread bytes could turn the close into a reset.** `shutdown(SHUT_WR)` sends the FIN, then up to 64 KiB is read and discarded for up to a second, so a 431, 413 or shed 503 reaches the client instead of being lost to a reset. [ADR 195](../adr/195-a-refused-request-is-hung-up-on-with-a-fin.md)
11. **The listen backlog defaults to 4,096, sized for bursts, not steady load.** Beyond it, a SYN is silently dropped (not refused), and the client's TCP retries a second later with nothing in the server's log. On older kernels, `somaxconn` still caps the value. [ADR 198](../adr/198-a-backlog-is-sized-for-the-burst-not-the-load.md)
12. **A connection is served start to finish by the executor it was handed to.** zio is built with `.scheduling = .pinned` (`zioFor` in `build.zig` sets it for every copy, and an application's root `zio_options` can override it). That gives up zio's work stealing in exchange for lower CPU cost per request below saturation, and it means threadlocal state a handler read before a wait is still valid after it. [ADR 199](../adr/199-a-connection-is-served-by-the-thread-it-was-dealt-to.md)
13. **Every executor accepts connections, on one shared listening socket.** One acceptor fiber per thread replaced the single accept loop that limited every server to the rate one fiber could handle. Accepted connections are still handed out round-robin as before. [ADR 200](../adr/200-every-executor-accepts.md)
14. **A server can listen on more than one address, sharing one route table, one connection budget and one thread pool.** `Options.also` lists extra listeners, each with an address, a port and a certificate. `max_connections` counts sockets across all of them. [ADR 213](../adr/213-a-server-answers-on-more-than-one-address.md)
15. **A `nilo.Gate` serves waiters in the order they arrived, and `enterWithin(ms)` limits how long one waits.** A returned turn goes directly to the oldest waiter, never back into a count that a newcomer could grab first. A wait that times out holds nothing and leaves the line. [ADR 222](../adr/222-a-gate-serves-its-waiters-in-the-order-they-came.md)
16. **A container's CPU quota sets the thread count: the quota rounded up, plus one.** The CPU affinity mask cannot see a quota, so `threads = 0` used to read every core of the host and the quota then throttled them. At startup nilo reads the tightest limit from the process's cgroup and its parents, and logs the count and the reason when it is lower than the number of cores. The count is capped at 64. [ADR 230](../adr/230-a-cpu-quota-sets-the-thread-count.md)
17. **A request knows which listener it came in on, and a route can be bound to some.** `c.listener()` is the position in the list `listen()` was given, one byte on the connection's `Peer`; `app.onListener(&.{1})` makes a route a 404 on the others, before any middleware of it runs. [ADR 252](../adr/252-a-request-knows-which-listener-it-came-in-on.md)
18. **A connection is ended after about 1,000 requests.** The last answer says `Connection: close` (HTTP/2: a GOAWAY), with up to a tenth taken off per connection so a pool does not end together, and a WebSocket is never ended by it. Without it a connection stays on the executor and the instance it was dealt to for as long as its client keeps it, which was measured as one executor at 4.0 times the mean and an added instance at 0% CPU. [ADR 275](../adr/275-a-connection-is-ended-after-a-number-of-requests.md)

## Decisions

| ADR | What it decides |
|---|---|
| [001](../adr/001-zio-as-the-engine-behind-the-bulkhead.md) | zio is the Engine, reached only through the Bulkhead |
| [010](../adr/010-shared-services-need-a-lock-from-the-bulkhead.md) | `nilo.Mutex`, a lock that parks the fiber, comes from the Bulkhead |
| [013](../adr/013-handlers-must-not-block-the-thread.md) | `nilo.blocking`/`nilo.sleep` for blocking calls, and the watchdog that catches a handler that skipped them |
| [028](../adr/028-a-spawned-fiber-belongs-to-the-server.md) | `nilo.spawn`/`app.spawn`: work that is not a request, tied to the server's lifetime |
| [244](../adr/244-a-handler-is-given-the-loop-it-runs-on.md) | `io: std.Io`, `c.io()`, `nilo.io()`: the server's loop, held nowhere per connection |
| [077](../adr/077-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md) | An operation the loop holds must be handed back before its frame returns |
| [097](../adr/097-a-file-is-written-by-the-engine.md) | `Upload.saveTo`, one atomic Bulkhead write operation |
| [103](../adr/103-a-path-is-an-address-to-listen-on.md) | `"unix:"` as an address prefix, and when a leftover socket file is removed |
| [159](../adr/159-a-server-past-its-limit-says-so-at-once.md) | `max_in_flight`: shed a request instead of queueing it |
| [194](../adr/194-an-accept-loop-that-is-out-of-descriptors-waits.md) | The accept loop backs off when descriptors run out instead of stopping |
| [195](../adr/195-a-refused-request-is-hung-up-on-with-a-fin.md) | A rejected request's connection is half-closed before it is closed |
| [198](../adr/198-a-backlog-is-sized-for-the-burst-not-the-load.md) | The listen backlog defaults to 4,096 |
| [199](../adr/199-a-connection-is-served-by-the-thread-it-was-dealt-to.md) | No task migration; a connection stays on the executor it was handed to |
| [275](../adr/275-a-connection-is-ended-after-a-number-of-requests.md) | `max_requests_per_connection`: `Connection: close` or a GOAWAY on a connection's last request, so a connection is dealt again |
| [200](../adr/200-every-executor-accepts.md) | One acceptor fiber per executor, not one accept loop for the server |
| [213](../adr/213-a-server-answers-on-more-than-one-address.md) | `Options.also`: several listeners sharing one server |
| [252](../adr/252-a-request-knows-which-listener-it-came-in-on.md) | `c.listener()` and `onListener`: a request's listener, and a route bound to some |
| [222](../adr/222-a-gate-serves-its-waiters-in-the-order-they-came.md) | `nilo.Gate` gives a freed turn to the oldest waiter, and `enterWithin` limits the wait |
| [230](../adr/230-a-cpu-quota-sets-the-thread-count.md) | A container's CPU quota plus one is the default thread count, capped at 64 |

Related topics: [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (principles) is the budget every "what it costs" section above is measured against; [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory) is the per-idle-connection floor these decisions are careful not to raise; [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md) and [ADR 210](../adr/210-a-services-wait-on-its-own-socket-is-a-park.md) (deadlines) cover the timeouts that work alongside the accept loop and the watchdog; [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md) (lifecycle) explains why the accept loop's group must be set up before a `ready` hook that might spawn something; [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md) and [ADR 027](../adr/027-tls-is-terminated-in-front.md) (tls) are what `also`'s `tls` field and a unix listener's trust rely on.

## Open questions

- **An inherited listener cannot be taken over.** Letting a supervisor hand the process an already-open descriptor (so a deploy with nothing in front stops dropping in-flight connections) is not built. It needs a naming protocol (`LISTEN_FDS` or a bare number) and a user who runs without a proxy. Recorded in [ADR 103](../adr/103-a-path-is-an-address-to-listen-on.md)'s "What is left" and in [`docs/decided.md`](../decided.md).
- **An extra listener bound to port 0 cannot report which port it got.** `boundPort()` only answers for the first listener. In [`docs/todo.md`](../todo.md), waiting for someone who binds a second listener to port 0 outside a test.
- **A connection is still handed from the accepting executor to another one by round-robin `spawn`.** Serving it on the executor that accepted it would remove the last cross-thread hop per connection, and zio can now do that (`spawnInto(.local)`, which a gRPC call already uses). Not done without a benchmark: round-robin is what spreads connections evenly today, and one acceptor per executor might not spread them as evenly by itself. In [`docs/todo.md`](../todo.md).
