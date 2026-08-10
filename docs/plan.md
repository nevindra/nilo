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
- Four built-in middlewares: logger, CORS, recover, static files

**Rejected until v2** — and these rejections matter as much as the acceptances

- Auth (the mechanism is provided, the contents are not — exactly like Fiber)
- WebSocket and SSE. Long-lived connections have a completely different memory model from request-response; the request arena does not apply there, and forcing it would wreck a design that is currently tidy.
- Template engine, sessions, TLS

## Zig version support

The latest stable release only, on one branch. The users being aimed at download Zig, run `zig build`, and give up if it fails — they are not going to go hunting for the right branch. The consequence: every new Zig release brings a few awkward weeks, made worse by zio following a branch-per-version pattern too.

## Build order

1. ~~**A skeleton that runs.**~~ *Done.* Accept connections through zio, parse HTTP/1.1, return "hello". No framework yet. The one goal: get the Bulkhead shaped correctly.
2. ~~**The `Ctx` layer.**~~ *Done.* Router, params, JSON, the request arena, `Str`. At this point it is usable, benchmarkable, and releasable if it came to that.
3. ~~**The typed layer.**~~ *Done.* The compile-time engine, matching services by type, fail functions. Decisions born here: [ADR 0006](./adr/0006-services-via-a-runtime-registry.md) and [ADR 0007](./adr/0007-failure-box-bound-to-the-fiber.md).
4. **Middleware and the four built-ins.**
5. **Documentation and examples.** For this particular audience, documentation is not a supplement — it is the product.

The benchmark script has lived in the repo since stage 1, even unrun in anger, so that when a measuring machine turns up it is one command away instead of a new project.

## Risks

| Risk | How it is handled |
|---|---|
| ~~The compile-time layer is the hardest and most fragile part~~ *Cleared.* The typed layer landed in stage 3 without needing its safety net | The `Ctx` layer underneath can be released on its own — that is the safety net, and it is deliberate |
| zio is a one-person project; it could stop when Zig 0.17 lands | The Bulkhead, fitted from stage 1 rather than patched on later |
| The "high performance" claim has nothing behind it yet | No numbers in the README until there is a measuring machine |
| The `Str` guarantee cannot be complete | The debug-build trap has to exist from day one |
| `std.json` may not be fast enough, and it sits on the hot path of the chosen metric | A custom serialiser for the small-JSON path is likely needed; measure first |
| Static files are deeper than they look (range requests, caching, sendfile) | Do it last in v1, or push it to v2 if things get tight |

## Still open

- **The name.** `zfast` is a working name. The `z-` prefix is crowded in the Zig ecosystem already (`zap`, `zzz`, `zon`, a dozen `zig-*`), so it is easy to confuse. The module name has to be easy to change without touching user code.
- **Where to measure.** Still nothing. Stage 3 did get run under `wrk` on a shared Linux VM, but only to confirm the server does not fall over and no responses get crossed — a shared machine cannot be used to compare numbers, so none were kept and none went into the README. Until there is a quiet machine, [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md) is not active and every conflict goes to DX.
- **The router algorithm.** Invisible to users, so there is no DX conflict here — pure work, to be decided with numbers later.

## Metrics

What counts as "fast" for zfast:

- **Primary:** requests per second **and p99** on a routed GET with a path param returning ~1KB of JSON, keep-alive, no pipelining.
- **Secondary:** memory per idle connection.

p99 is counted too, so that winning on throughput while stalling the tail requests does not count. One consequence is binding already: keep-alive is the main path, and there must be no stop-the-world allocation in the middle of a request.
