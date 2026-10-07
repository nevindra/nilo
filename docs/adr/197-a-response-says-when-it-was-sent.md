# A response says when it was sent, and not that it stays open

**Status:** accepted
**Topic:** [responses](../design/responses.md)
**Applies:** [ADR 001](./001-zio-as-the-engine-behind-the-bulkhead.md),
[ADR 006](./006-failure-box-bound-to-the-fiber.md),
[ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 041](./041-core-knows-what-time-it-is.md).
**Found by:** reading [actix-web](https://github.com/actix/actix-web)'s
`actix-http/src/date.rs` and `h1/encoder.rs` against nilo's `writeHead` —
the one header actix writes on every response that nilo wrote on none, and
the one nilo wrote on every response that actix writes only when it says
something.

## Context

Every response nilo wrote carried a status line, `Content-Type`,
`Content-Length`, `Connection: keep-alive` or `close`, and whatever the
handler added. Two things about that list were wrong, in opposite
directions, and together they are thirteen bytes.

**There was no `Date`.** RFC 9110 §6.6.1 is not ambiguous about it: an
origin server with a clock *must* send one on every 2xx, 3xx and 4xx
response. The header is what a cache reads to do freshness arithmetic —
`Age`, `max-age`, `Expires` are all relative to it — and without one a CDN,
an nginx `proxy_cache` or a browser falls back to the time it received the
bytes, which the RFC calls "the recipient's best guess". nginx in front adds
one if missing; HAProxy and the cloud balancers do not. Every other server in
`bench/compare/` sends one, and `docs/comparison.md`'s wire figures were
crediting nilo thirty-seven bytes it should have been spending.

**`Connection: keep-alive` was on every HTTP/1.1 response.** RFC 9112 §9.3:
an HTTP/1.1 connection is persistent unless a `close` says otherwise, so
the line told the client what it already assumed. Go's `net/http` and hyper
omit it; nginx sends it; both are correct. It carries information in exactly
two cases: an HTTP/1.0 client that asked to stay and is being kept, and a
connection that is closing.

## Decision

**Every response head carries a `Date`, second after the status line**, on
every path that writes a head — `send`, a stream, a file, a HEAD, the
canned 400/408/415/431/503 that go out before there is a Ctx. The interim
responses — a 100, a 101 — carry none, which §6.6.1 allows. A handler that
sets a `Date` of its own is trusted about it and the framework's is left
off; the name is deliberately not on `isReservedHeader`'s list.

**The `Connection` line is written only when it carries information.**
`http1.Connection` has three states — `implied`, `keep_alive`, `close` — and
The write picks one from `keepAlive()` and the request's version (`Ctx.connection()` was public until ADR 259 removed it).
`implied` writes nothing.

**The date is formatted once a second per thread, lazily, and never from a
task.** actix keeps a formatted date per worker and has a timer refresh it
every 500 ms. nilo has no place to hang a timer that is not the Engine, and
does not need one: `date.now()` reads the wall clock — 15 ns from the vDSO,
`core/clock.zig` has the measurement, and it is `nilo_core`'s clock rather
than a new one on the Bulkhead — compares the second against the one this
thread's copy was formatted for, and reformats only when it has moved. A
threadlocal, and the reason that is right here and wrong for the fiber slot
of ADR 006 is stated in `http/date.zig`: nothing between the clock read and
the copy out can suspend, so no other fiber can run on the thread in
between. Under `zig test` the second can be pinned, so a test can expect a
literal head.

## What it costs, against ADR 017

- **Allocations per request: none.** The cache is a threadlocal of 40
  bytes; the copy out is by value on the stack. `test "the request path
  stays inside its allocation budget"` holds it.
- **Memory per idle connection: none.** Nothing is held per connection.
- **Throughput and p99: unchanged.** One clock read and one integer compare
  per response, plus a 29-byte format once a second per thread. On the wire
  the benchmark response goes from 1,110 bytes to 1,123 — plus 37, minus 24
  — which is the number Go, axum, Fiber and Bun all send for the same body.
  Eight interleaved pairs against the tree before, on the box
  [`bench/result/http.md`](../../bench/result/http.md#what-a-date-costs-and-what-leaving-connection-off-gives-back)
  names: −0.1% on requests a second, with the sign changing between pairs,
  and p99 inside the same 3.7–4.0 ms band on both sides.
- **Binary size: +6,064 bytes on `hello`, +6,072 on `rest`**, stripped
  `ReleaseFast`. Not the 400 the formatter was guessed at, and the split
  is the useful part: 1,842 is `date.writeLine` with `std.time.epoch`'s
  year and month loops inlined into it; about 2,000 is the errno name table
  that `core.nowMicros`'s panic message pulls in, which no HTTP binary had
  paid for before because nothing on the request path read the wall clock;
  the rest is the three head writers and `sendFinal` growing by a call.

## What was rejected

- **A refresh task per thread, actix's shape.** Costs a fiber per worker for
  the life of the process, can be half a second stale, and needs the Engine
  to exist — a unit test calling `App.handleRequest` on buffers would get no
  date. The lazy read is cheaper and correct on every path.
- **A process-wide cache behind an atomic.** One cache line every thread
  writes once a second and reads on every response — exactly the
  cross-thread traffic actix's per-worker design exists to avoid, and the
  threadlocal costs nothing to get the same property.
- **`CLOCK_REALTIME_COARSE`.** 2 ns instead of 15, and Linux-only; a second
  clock to explain for 13 ns on an 11 µs request. `core/clock.zig` had
  already measured and declined it.
- **Keeping `Connection: keep-alive` for the clients that might read its
  absence as `close`.** No HTTP/1.1 client does; persistence has been the
  default since RFC 2068 in 1997. HTTP/1.0 keeps the header, which is the
  case the line was invented for.
- **Reserving `Date` the way `Content-Length` is reserved.** A second
  `Content-Length` is a smuggling bug; a handler's own `Date` is a choice
  the RFC leaves to the origin server, and refusing it buys nothing.
