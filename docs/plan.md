# zfast plan

A working document: the v1 scope, the build order, the risks, and the things deliberately left open.
Decisions that are already binding live in [`docs/adr/`](./adr/); the vocabulary is in [`CONTEXT.md`](../CONTEXT.md).

## Where this sits

The model is **GoFiber**: the feel of Express, a fast engine underneath. It is aimed at Go and Node people giving Zig a try.

Worth being honest about from the start: GoFiber is not Go's performance champion — the fast part is fasthttp underneath it. Fiber wins on *comfort*. Taking Fiber as the model means what we are chasing is **"http.zig for Go people"**, not the benchmark crown. See [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md).

## v1 scope

**In**

- Complete HTTP/1.1: keep-alive, chunked
- Router: path params, query params
- Typed handlers on top of the Ctx layer
- JSON in and out
- A middleware chain
- Two built-in middlewares — logger and CORS — plus static files, which turned out to be a terminal handler rather than a middleware because it needs state ([ADR 0010](./adr/0010-static-files-are-held-in-memory.md))
- Response headers on `Ctx` — a prerequisite for CORS, see [ADR 0009](./adr/0009-middleware-is-an-onion-of-ctx-functions.md)

**Rejected until v2** — and these rejections matter as much as the acceptances

- Range requests, `sendfile`, and serving a file too big to hold in memory ([ADR 0010](./adr/0010-static-files-are-held-in-memory.md)).
- A `recover` middleware. It was in this list until stage 4's design work established that Zig cannot recover from a panic at all, and that what people actually want from it has been in the request loop since stage 3. Not deferred — impossible. See [ADR 0008](./adr/0008-no-recover-middleware.md).
- Route groups. `app.use(prefix, mw)` covers the case that matters; groups only save repeating the prefix.
- Handing values from middleware to handlers. The concrete gap this leaves is auth resolving a user, and it is the thing a request-scoped value concept has to solve in v2 ([ADR 0009](./adr/0009-middleware-is-an-onion-of-ctx-functions.md)).
- Auth (the mechanism is provided, the contents are not — exactly like Fiber)
- WebSocket and SSE. Long-lived connections have a completely different memory model from request-response; the request arena does not apply there, and forcing it would wreck a design that is currently tidy.
- Template engine, sessions, TLS

## Zig version support

The latest stable release only, on one branch. The users being aimed at download Zig, run `zig build`, and give up if it fails — they are not going to go hunting for the right branch. The consequence: every new Zig release brings a few awkward weeks, made worse by zio following a branch-per-version pattern too.

## Build order

1. ~~**A skeleton that runs.**~~ *Done.* Accept connections through zio, parse HTTP/1.1, return "hello". No framework yet. The one goal: get the Bulkhead shaped correctly.
2. ~~**The `Ctx` layer.**~~ *Done.* Router, params, JSON, the request arena, `Str`. At this point it is usable, benchmarkable, and releasable if it came to that.
3. ~~**The typed layer.**~~ *Done.* The compile-time engine, matching services by type, fail functions. Decisions born here: [ADR 0006](./adr/0006-services-via-a-runtime-registry.md) and [ADR 0007](./adr/0007-failure-box-bound-to-the-fiber.md).
4. ~~**Middleware and the built-ins.**~~ *Done.* Designed up front in [ADR 0008](./adr/0008-no-recover-middleware.md) and [ADR 0009](./adr/0009-middleware-is-an-onion-of-ctx-functions.md). Response headers on `Ctx`, the onion chain, `use`/`useOn`, logger, CORS, and the panic handler that names the in-flight request. Static files came last and needed a decision of their own: [ADR 0010](./adr/0010-static-files-are-held-in-memory.md).
5. ~~**Documentation and examples.**~~ *Done.* For this particular audience, documentation is not a supplement — it is the product. Three runnable examples under `examples/`, each built and tested by `zig build test` so none of them can rot unnoticed.

The two v1 items that belonged to no stage are in as well: **chunked bodies** (read, discarded, and rejected with a 400 when the sizes and the stream come apart) and **percent-decoding** of path params and query values.

Two things turned up while writing the examples, which is what examples are for:

- A Service with mutable state is shared across executor threads and had no correct way to be locked. Fixed by adding one item to the Bulkhead: [ADR 0011](./adr/0011-shared-services-need-a-lock-from-the-bulkhead.md).
- Restarting the server failed with `AddressInUse` every time, because `SO_REUSEADDR` was off. During development that is every restart. Now on by default.

The benchmark script has lived in the repo since stage 1, even unrun in anger, so that when a measuring machine turns up it is one command away instead of a new project.

## Risks

| Risk | How it is handled |
|---|---|
| ~~The compile-time layer is the hardest and most fragile part~~ *Cleared.* The typed layer landed in stage 3 without needing its safety net | The `Ctx` layer underneath can be released on its own — that is the safety net, and it is deliberate |
| zio is a one-person project; it could stop when Zig 0.17 lands | The Bulkhead, fitted from stage 1 rather than patched on later |
| The "high performance" claim has nothing behind it yet | No numbers in the README until there is a measuring machine |
| The `Str` guarantee cannot be complete | The debug-build trap has to exist from day one |
| `std.json` may not be fast enough, and it sits on the hot path of the chosen metric | A custom serialiser for the small-JSON path is likely needed; measure first |
| ~~Static files are deeper than they look (range requests, caching, sendfile)~~ *Cleared.* Serving from memory kept v1's version small, and caching came along free with it | Range requests and `sendfile` are v2, and arrive as an addition rather than a rewrite ([ADR 0010](./adr/0010-static-files-are-held-in-memory.md)) |
| A Service is shared across executor threads, and nothing makes a user notice | `zfast.Mutex` from the Bulkhead, in the README and in the example everyone copies. Nothing forces it — Zig has no ownership tracking to force it with ([ADR 0011](./adr/0011-shared-services-need-a-lock-from-the-bulkhead.md)) |
| A panic in any handler takes the whole process down, and Go people will assume otherwise | Cannot be fixed in Zig. Say it plainly in the docs, recommend `ReleaseSafe` and a supervisor, and log which request was in flight ([ADR 0008](./adr/0008-no-recover-middleware.md)) |

## Still open

- **The name.** `zfast` is a working name. The `z-` prefix is crowded in the Zig ecosystem already (`zap`, `zzz`, `zon`, a dozen `zig-*`), so it is easy to confuse. The module name has to be easy to change without touching user code.
- **Where to measure.** Still nothing. Stage 3 did get run under `wrk` on a shared Linux VM, but only to confirm the server does not fall over and no responses get crossed — a shared machine cannot be used to compare numbers, so none were kept and none went into the README. Until there is a quiet machine, [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md) is not active and every conflict goes to DX.
- **The router algorithm.** Still a linear scan, and which structure replaces it — radix tree, per-method buckets, something else — needs numbers nobody has yet. What the scan *costs* did not need numbers: it used to re-split the request path once per route, which is a different kind of wrong from "linear". Patterns are now split at registration and the path once per request, and a route with a different segment count is rejected on an integer compare. Measured in-process, worst case with the wanted route last: **3.7× at 50 routes, 1.4× at 5**. Never slower, so it does not owe the benchmark anything.
- **Reloading static files without a restart.** For a build-output directory this does not matter, since deployment restarts anyway. For local development it is a real annoyance and wants a watch option in v2.

## Metrics

What counts as "fast" for zfast:

- **Primary:** requests per second **and p99** on a routed GET with a path param returning ~1KB of JSON, keep-alive, no pipelining.
- **Secondary:** memory per idle connection.

p99 is counted too, so that winning on throughput while stalling the tail requests does not count. One consequence is binding already: keep-alive is the main path, and there must be no stop-the-world allocation in the middle of a request.

### What can be measured without a quiet machine

Requests per second is the number that needs a machine nobody else is using. Two others do not, and both are now recorded:

- **Allocations per request: 3** on the primary metric's shape, with CORS installed — the head copied so its `Str`s outlive the read buffer, the response header list, and the JSON body. All three are bump allocations into an arena that is already warm; none is a syscall or a lock. Held there by a test (`the request path stays inside its allocation budget`), so putting a fourth back needs a reason. It was 6.
- **Memory per idle connection: ~21 KB** with the default buffers, measured as the RSS difference across 1,000 held-open keep-alive connections. About 4 KB of that is the read and write buffers, which `Options.read_buffer` / `write_buffer` turn down: at 2 KB each the figure is ~17 KB. Most of what is left is the fiber's own stack, which is zio's to hand out.

Neither says how fast the server is. Both notice when it gets worse, which is what is available until there is somewhere honest to measure.

A third kind of number needs no machine at all: how the work grows. Two places were growing wrong, and both were fixed on that basis rather than on a benchmark.

- **Finding the end of a request head** restarted from byte zero on every read. A head arriving in one packet cost one pass; the same head dribbled in a byte at a time cost a pass per byte — quadratic, and reachable by any client that chooses to be slow. It now resumes where it left off.
- **Route matching** re-split the request path for every route it tried. See "Still open" above.
