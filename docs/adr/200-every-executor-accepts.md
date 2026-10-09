# Every executor accepts

**Status:** accepted
**Topic:** [engine](../design/engine.md)
**Applies:** [ADR 001](./001-zio-as-the-engine-behind-the-bulkhead.md),
[ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 194](./194-an-accept-loop-that-is-out-of-descriptors-waits.md),
[ADR 198](./198-a-backlog-is-sized-for-the-burst-not-the-load.md),
[ADR 199](./199-a-connection-is-served-by-the-thread-it-was-dealt-to.md).
**Found by:** [HttpArena](https://github.com/MDA2AV/HttpArena)'s
`limited-conn` profile — 4,096 connections, each closed after ten requests —
reporting nilo at 426K req/s on **18 of 64 cores**, with a p50 of 48 µs and a
p99 of 100 ms, against 2.0–2.7M req/s for everything above it. Two runs at
two backlogs gave the p99 away: 3 ms at a backlog of 128 and 100 ms at
4,096, each equal to the backlog divided by the rate connections were being
accepted at.

## Context

Until this ADR nilo accepted on one fiber. `serve` ran the accept loop as
the main task of executor 0: `accept` with a 200 ms timeout, so the loop
could look at the stop flag between connections, then `spawn` the
connection onto an executor chosen round-robin, then `accept` again. Every
other executor served connections and never accepted one.

What that costs is not the `accept` syscall. It is that **each accepted
connection is one round trip through one executor's loop**: a race group
with a timer in it, a park, a poll, a wake, a stack from the pool, a task
pushed onto another executor's queue and an eventfd write to wake it, and
back to `accept`. On the arena's box that came to ~23 µs of one core per
connection, serial, which is ~42,600 connections a second whatever the
other sixty-three threads are doing. At ten requests a connection that is
426K req/s, and it is the number the profile reported.

The shape of the failure is worth writing down, because it did not look
like a bottleneck. CPU sat at 18 cores of 64, so the server looked idle.
p50 was 48 µs, so requests looked fast. Only the first request on each
connection paid, and it paid the time its handshake spent queued in the
kernel's backlog behind ~42,000 others a second: 128 / 45K = 2.8 ms at the
old backlog, 4,096 / 42.6K = 96 ms at the new one. ADR 198's larger
backlog did exactly what it promised for a burst, and for a sustained rate
of connections it turned "SYN dropped, retried a second later" into "held
for a tenth of a second" — a better failure, and the same ceiling.

`bench/main.zig` on this box, `/health`, server on eight cores and
[gcannon](https://github.com/MDA2AV/gcannon) on the other eight,
reproduces it: 512 connections closed after ten requests, **660–668K req/s,
p50 17 µs, p99 8.2 ms**, the server using 2.5 of its 8 cores. 512 / 66K
connections a second = 7.8 ms, which is the p99.

Nothing above nilo on that column pays a loop round trip per connection.
hyper's accept task and actix's dedicated accept thread both call `accept`
until `EAGAIN` on one readiness wake, a few microseconds a connection; the
C engines run one listener per thread under `SO_REUSEPORT`. Through zio,
`accept` is one connection per call and one park per call, so the only way
to take connections faster is to have more fibers taking them.

## Decision

**One acceptor per executor, all on the one listening socket.** `serve`
spawns `threads` acceptor fibers back to back — zio deals spawns
round-robin, so consecutive spawns land on consecutive executors — and each
sits in its own `accept`. The kernel hands a completed handshake to one of
the waiting acceptors; which one does not matter, because the connection
is then dealt round-robin by `spawn` as before, and the load spreads the
same way it did.

Three things change with it, and each is smaller than it sounds:

- **Acceptors wait with no timeout and are cancelled.** The 200 ms
  `accept` timeout existed so that the one loop could poll the stop flag.
  Now the main fiber waits for it, and on seeing it cancels the acceptors'
  group, which is what ends a pending `accept` cleanly. A stop rings a
  doorbell (`Stop.bell`, a `zio.ev.Async` in a `CompletionQueue` the main
  fiber drives), so it is seen at once; the wait times out every 200 ms for
  a listener's failure and as a net under a ring, one timer per server
  instead of a race group and a timer per connection accepted. `notify` is
  atomics and one eventfd write, a kevent or a pipe write, with no lock,
  which is what lets a signal handler ring it where it may not touch a wait
  queue; a `request` that loaded the doorbell is waited out before it
  leaves the stack. The first version only polled, `zio.sleep(200 ms)`,
  and a stop waited for the next look: up to a fifth of a second on every
  `shutdown()`, and eight seconds of the Debug suite, a fifth of a second
  for each server a test started and stopped
  ([the run](../../bench/result/build.md#where-zig-build-test-waits-on-zig-017)). The group is cancelled before the connections'
  group and before the listener is closed, so no `accept` is ever pending
  on a socket being taken away, which is the hazard the old comment named.
- **`Capacity.take` is a compare-and-swap.** It was a load and an
  increment, on the strength of there being one caller; with N callers two
  could read the same free slot. The "server is full" warning's timestamp
  moves into `Capacity` as an atomic, claimed by CAS, so N acceptors
  refusing in the same minute write it once.
- **A listener failure is kept, not returned.** An acceptor that sees an
  error `accept` should never return stores it — the first one wins — and
  exits; the main fiber notices within one poll, cancels the rest and
  returns that error from `serve`, which is what one loop returning it did.
  ADR 194's descriptor-shortage backoff stays, per acceptor, with the
  warning and its "works again" claimed once between them.

Same box, same shape, interleaved three times, before → after:
**660–668K → 1.97M req/s** (2.95×), p99 8.2 ms → 1.5–1.8 ms, the server
at 6 of 8 cores. At the arena's 4,096 connections, 708K → 1.75M, p99 61 ms
→ 41 ms. Keep-alive throughput on the same server is unchanged: 2.62–2.65M
against 2.64M, three pairs. `bench/shutdown.py` comes back 6 of 6 on both
WebSocket and HTTP, `bench/fdlimit.py` waits the shortage out, and
`bench/burst.py` gets a thousand connections through with
`ListenOverflows +0`.

## What it costs

**Memory:** one fiber per executor parked in `accept`, for the life of the
server — its stack's committed pages, a few kilobytes each, sixty-four of
them on the arena's box. Not per connection, so the 4,669 bytes an idle
connection holds do not move. Nothing per request, nothing on the binary
that the linker could not already see, and one timer per server fewer
than before per connection accepted.

**Fairness:** with N acceptors on one socket, which acceptor gets a
connection is the kernel's choice. On io_uring each pending `accept` is
its own request and completes with its own connection, so nothing is
woken for nothing. On epoll and kqueue a readable listener can wake more
than one loop for one connection, and the losers see `EAGAIN` inside zio's
`accept` and go back to waiting — the thundering-herd cost of a shared
listener, paid only under bursts. `SO_REUSEPORT` (below) is the
alternative if it ever shows.

**The property ADR 199 gave a handler** — one OS thread from first line
to last — is untouched: a connection is still dealt once and served where
it was dealt.

## Alternatives

**`SO_REUSEPORT`, one listening socket per executor.** Removes the shared
accept queue and its lock, and the kernel hashes connections across the
sockets. Rejected for now because it has a failure the shared socket does
not: a connection hashed to a socket whose acceptor is busy waits for that
one acceptor, and a connection in the queue of a socket that closes is
reset rather than moved. zio already exposes `reuse_port`, so this is one
option and a loop away if the shared socket's lock shows in a profile.

**Multishot accept** (`IORING_ACCEPT_MULTISHOT`): one SQE that keeps
delivering connections without being re-armed. The cheapest accept there
is on io_uring, and zio does not expose it; also useless on epoll and
kqueue, which the Engine still runs on.

**Serve the connection on the executor that accepted it, with no
handoff.** The remaining cost per connection is the cross-thread push and
the eventfd write that wakes the home executor. zio homes every spawn
round-robin (`spawnTask`, `getNextExecutor`) and has no way to say "here";
an option for it is the upstream ask, and the roadmap carries it. On
epoll and kqueue it would also pin the socket's I/O to the accepting loop
for free, which is the reason zio gives for spreading spawns in the first
place.

**Make the one acceptor cheaper.** Dropping the per-accept timer and the
eventfd write would take a few microseconds off 23; actix's dedicated
thread manages ~5 µs per connection with a loop that accepts until
`EAGAIN`, which zio's one-connection-per-call `accept` cannot do. A factor
of two or three from one fiber against a factor of N from N fibers, and
the N fibers are forty lines.

**log2 of the threads, at least two, as [dusty](https://github.com/lalinsky/dusty) does.** dusty went from two accept loops to five on 24 threads and took one request per connection from 145K to 239K req/s, and past five lost: 12 and 24 loops gave back 20–40% of it and doubled the median. Swept here on eight threads, server and gcannon on separate physical cores, three interleaved rounds: at one request per connection 3 acceptors read 472–490K against 466–477K for 8, and at ten requests per connection 3 read 1.70–1.72M against 1.81–1.83M, and 1.58M against 1.64–1.68M at 4,096 connections. Keep-alive did not move. log2 loses 4–7% where connections carry ten requests and gains nothing outside the spread where they carry one, so on eight threads it stays one per executor ([`http.md`](../../bench/result/http.md#how-many-acceptors-eight-threads-want)). Whether sixty-four acceptors are past dusty's knee is a reading this box cannot take, and the roadmap carries it.

## Consequences

- `http/engine/zio.zig`: `Acceptor.run` is the loop, `Accepting` is what
  the acceptors share, `Capacity.take` is a CAS, `accept_poll_ms` is the
  main fiber's poll. Nothing outside the Engine changes; the Bulkhead's
  contract is the same.
- [`http.md`](../../bench/result/http.md#what-one-accept-fiber-caps-a-server-at)
  carries the arena's two runs and the local pairs.
- The roadmap gains an upstream row: a spawn homed on the current executor.
- HttpArena's next run is the reading this box cannot take: `limited-conn`
  at 4,096 connections on sixty-four threads, and `echo-ws-limited`, which
  is the same bottleneck behind a handshake. The local factor says 1.2M
  req/s or more on the first, from 426K; sixty-four acceptors against
  eight may say more.
