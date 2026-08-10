# zfast plan

A working document: the v1 scope, the build order, the risks, and the things deliberately left open.
Decisions that are already binding live in [`docs/adr/`](./adr/); the vocabulary is in [`CONTEXT.md`](../CONTEXT.md).

## Where this sits

Through v1 the model was **GoFiber**: the feel of Express, a fast engine underneath, aimed at Go and Node people giving Zig a try. That got v1 built, and it is no longer the model — v1 overtook Fiber in the two places that decide everything above `Ctx`, so from v2 the architecture comes from elsewhere and Fiber stays only as the tone. Where each piece is borrowed from, and why, is [ADR 0015](./adr/0015-what-zfast-borrows-and-from-whom.md).

The audience does not change: people coming from Go and Node. What changes is the claim being chased. v1 chased "http.zig for Go people". v2 chases **"the signature is the whole contract"** — a handler you can read, test as a plain function, and get documentation from, on a server whose memory you can put a number on.

Still not the benchmark crown. See [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md), now the first row of the three-axis budget in [ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md).

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
- Writing a response in pieces, and reading a body larger than `Ctx.max_body` (1 MB). Both are the same missing thing — a request whose bytes do not all have to exist at once — and both would need the request arena to stop being the answer to where memory comes from. Written down as limits in the README rather than left for somebody to find with a 413.
- A `recover` middleware. It was in this list until stage 4's design work established that Zig cannot recover from a panic at all, and that what people actually want from it has been in the request loop since stage 3. Not deferred — impossible. See [ADR 0008](./adr/0008-no-recover-middleware.md).
- ~~Route groups.~~ *Landed in v2.* The v1 reasoning — "groups only save repeating the prefix" — was right about groups as a naming convenience and wrong about them as a packaging unit, which is what a plugin needs. See "v2" below.
- ~~Handing values from middleware to handlers.~~ *Landed in v2*, as resolved values rather than as the request-scoped map this line was imagining ([ADR 0016](./adr/0016-resolved-values-are-declared-by-their-type.md)).
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

6. ~~**A pass over the developer experience.**~~ *Done.* The framework was used from a fresh project, the way somebody who had just found it would, and the gaps that turned up were the ones only writing the code finds:

- **Query params had no typed form**, though "Router: path params, query params" has been in the v1 scope since stage 1. Half of it had been built. Now `Query(T)` ([ADR 0012](./adr/0012-the-query-string-is-a-struct-of-your-own.md)).
- **`Response(T)` could not carry headers**, so a 201 with a `Location` — the most ordinary thing a POST does — meant dropping to `*Ctx` and giving up the whole typed layer to get one header out.
- **A handler had no allocator.** Found while writing the `Location` example: the header value has to outlive the handler's stack frame, and nothing gave it anywhere to live. A `std.mem.Allocator` argument is now the request arena.
- **Route patterns were checked with `std.debug.assert`**, so `app.get("users", …)` — a missing slash — was `reached unreachable code` at startup, and undefined behaviour in `ReleaseFast`. The pattern is `comptime`; every one of these is a build error now.
- **Registration order silently decided which route won**, and a duplicate route was accepted without a word ([ADR 0013](./adr/0013-the-most-specific-route-wins-and-duplicates-are-refused.md)).
- **`AddressInUse` printed a stack trace through zio's internals** — the single most common way a server fails to start, answered with a tour of the Engine. ADR 0002 says the Engine is not the user's business; a crash log is where that matters most.
- **The two root-file wiring lines were undocumented**, and forgetting either failed quietly: `std.log` blocking the event loop looks like a slow server, and the Engine's debug output looks like your own logs are missing. `listen()` now names whichever one is absent.
- **`zig build test` printed `failed command` on a passing suite**, because Zig's build runner reads any stderr from a test binary as failure. Tests run under their own root now, with logging off.

Two things turned up while writing the examples, which is what examples are for:

- A Service with mutable state is shared across executor threads and had no correct way to be locked. Fixed by adding one item to the Bulkhead: [ADR 0011](./adr/0011-shared-services-need-a-lock-from-the-bulkhead.md).
- Restarting the server failed with `AddressInUse` every time, because `SO_REUSEADDR` was off. During development that is every restart. Now on by default.

The benchmark script has lived in the repo since stage 1, even unrun in anger, so that when a measuring machine turns up it is one command away instead of a new project.

7. ~~**A second pass, from the outside.**~~ *Done.* The framework was installed into an empty project again — `zig fetch`, a `build.zig`, an API — and driven with curl the way somebody evaluating it would. Stage 6 found the gaps that show up while writing handlers; these are the ones that only show up while *running* them.

- **A body that did not fit was answered with `Bad Request` and nothing else.** A query param has always got `?page has to be a whole number, not "soon"`; the same mistake one layer down got four words. The server knew — `error=UnknownField` was right there in the log — and did not say. The body is now diagnosed against the struct it was supposed to become, and the field is named. The second parse this costs is paid only by a request that was already going to be refused.
- **A wrong verb on a real path was a 404**, so `DELETE /users` on a path with a `GET` and a `POST` on it said "not found" — which sends you hunting for a route registration bug that is not there. Now a 405 with `Allow`, and an `OPTIONS` nobody registered is answered rather than refused.
- **There was no way to stop a server.** `listen()` blocked forever and the only exit was a signal killing the process mid-response. Now `App.shutdown()`, plus SIGINT and SIGTERM by default: stop accepting, finish what is in flight, say `Connection: close` on the way out. What is waited on is requests, not connections — waiting on connections put the full grace period behind every idle browser tab, which was the first version of this and was worse than nothing.
- **The one-line startup messages were still followed by a stack trace**, because `listen()` returned the error and Zig prints a trace for an error reaching `main`. Stage 6 got the trace out of zio; it was still touring zfast. `listen()` now stops the process after saying why, and `tryListen()` is there for a caller that wants the value instead.
- **A forgotten `provide()` printed once per route**, so five routes sharing a `*Db` printed the same sentence and the same fix five times. One line per service now, naming the routes.
- **`address` was IPv4 only** — `parseIp4`, so `"::1"` was refused by a message that did not mention IPv6 existed. Now `parseIp`.
- **`Ctx` was undocumented.** The README called it "the way out when you need full control" without once saying what it could do, so the first guess at a method name was a compile error. Its surface is a table in the README now — and the two things it cannot do, streaming a response and a body over 1 MB, are written down as limits rather than left to be discovered.

8. ~~**A third pass, from the outside, reading the docs as instructions.**~~ *Done.* Stage 6 found what writing handlers exposes and stage 7 what running them exposes. This one followed the README literally — copying each snippet into a fresh project and compiling it — and found that the documentation had drifted from the code in places where the code was right.

- **A handler that waits stalls every other request on its thread, and nothing said so.** The largest gap in v1, and the only one on this list that is a design hole rather than a wrong sentence. Measured at 1.7 seconds of latency inflicted on a request that had nothing to wait for. `zfast.blocking` and `zfast.sleep` are the way out, the README states the general rule, and the reasoning is in [ADR 0014](./adr/0014-handlers-must-not-block-the-thread.md). It had been hiding behind ADR 0011, which described the mutex instance of it correctly and left the rule itself unwritten.
- **The README and all three examples described the two root-file lines backwards**, saying `std_options` was what kept `std.log` off the event loop when it is `std_options_debug_io`. The startup warnings stage 6 added had it right, so the framework was contradicting its own documentation — and the docs are what people follow.
- **The README's timing middleware could not compile.** It used `std.time.milliTimestamp`, which Zig 0.16 does not have. The Engine's monotonic clock was in the Bulkhead but not exported, so there was no way to write a timing middleware at all. Now `zfast.monotonicNanos`.
- **The README's shutdown example failed at startup.** `fn quit(app: *zfast.App)` is shown as an ordinary handler, and it is — but `*zfast.App` is a Service like any other and the example never called `provide`. Copying it verbatim got `service *app.App was never registered`.
- **A duplicate route said its piece and then printed a stack trace anyway.** Stage 7 fixed exactly this for `listen()` and missed `app.get`, which returned `error.DuplicateRoute` into the user's `try`. Now it stops the process the way `listen()` does, with `tryRoute` for a caller that wants the value.
- **A 204 and a 304 both carried `Content-Length: 0`.** Forbidden outright on a 204 (RFC 9112 §6.2), and on a 304 it announces that the resource the client already holds is empty. Both statuses are now framed as what they are: responses that end at the blank line.
- **`std.log.info("{s}", .{c.path()})` — the first thing anybody writes — was a compile error from inside `std.Io.Writer`**, naming neither zfast nor the fix. `Str` has a `format` method now, so `{f}` works.

## v2

The direction was settled first, in [ADR 0015](./adr/0015-what-zfast-borrows-and-from-whom.md), because three of v1's deferrals were deferred for want of a decided shape rather than for want of work.

### Landed

- **Resolved values** ([ADR 0016](./adr/0016-resolved-values-are-declared-by-their-type.md)). The gap ADR 0009 wrote into its own consequences: middleware can refuse a request but cannot hand the handler the user it just looked up. A type now declares how it is worked out, a handler asks for it by writing it in its argument list, and the chain is settled while compiling — no type map, nothing looked up by string. Worked out once per request, so a guard on a prefix and the handler behind it do not authenticate twice.
- **Groups and plugins** ([ADR 0015](./adr/0015-what-zfast-borrows-and-from-whom.md)). ADR 0009 deferred groups on the grounds that they only save repeating a prefix, which is true of a group as a naming convenience and false of one as a packaging unit. `app.group("/api/v1")` carries routes, middleware and static files; a plugin is an ordinary function that takes one, so it can be mounted anywhere, or twice.
- **The API description** ([ADR 0017](./adr/0017-the-api-description-comes-from-the-signatures.md)). `app.docs(.{ … })` and there is an OpenAPI 3.1 document at `/openapi.json`, read off the same argument list the compile-time engine reads. Served as a file, so it gets an ETag and a 304 for free (ADR 0010) and adds nothing to the request path.
- **The trade budget, sharpened** ([ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md)). ADR 0001's one 10% rule is now three: throughput may slip 10% for DX, while allocations per request and memory per idle connection are hard invariants. That split is what "low memory" is allowed to mean.

### Not started

Everything left is engine-shaped rather than DX-shaped, and every item on this list needs the same thing first: **the request arena has to stop being the only answer to where memory comes from.** That is one decision, not five, and it is what the next stage is.

- Writing a response in pieces, and reading a body larger than `Ctx.max_body` (1 MB).
- Range requests and `sendfile`, and serving a file too big to hold in memory ([ADR 0010](./adr/0010-static-files-are-held-in-memory.md)).
- WebSocket and SSE. A long-lived connection has a completely different memory model from request-response; Phoenix Channels is the shape to borrow (ADR 0015) — a socket gets its own lifecycle and its own state rather than being forced through the request arena.
- Reloading static files without a restart. A development annoyance rather than a design hole.
- TLS, sessions, templates.

### Open, from the work that has landed

- **The linker cannot drop what nobody uses.** The API description costs +43 KB on the hello example whether or not `docs()` is called, because the switch is a runtime `null` check ([ADR 0017](./adr/0017-the-api-description-comes-from-the-signatures.md)). Fixing it properly needs a build option that a `zig fetch` dependent has to thread through, which is a worse ergonomic problem than the one it solves. Recorded, not solved.
- **The API description is silent about authentication.** A handler taking a `CurrentUser` needs an `Authorization` header, and the document does not say so — the header is a line of Zig inside the resolver, not something in a type ([ADR 0017](./adr/0017-the-api-description-comes-from-the-signatures.md)). Whatever fixes this must not become a second thing to keep in step with the resolver, which is the drift the generated document exists to avoid.
- **A group prefix cannot carry a param.** `app.group("/orgs/:org")` is refused, because `use` scopes middleware by comparing the front of the request path against the prefix and `/orgs/:org` is the front of no real path — so every middleware on such a group would quietly never run. Making it work means teaching middleware scoping to match patterns rather than prefixes.

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
- **The router algorithm.** Still a linear scan, and which structure replaces it — radix tree, per-method buckets, something else — needs numbers nobody has yet. What the scan *costs* did not need numbers: it used to re-split the request path once per route, which is a different kind of wrong from "linear". Patterns are now split at registration and the path once per request, and a route with a different segment count is rejected on an integer compare. Measured in-process, worst case with the wanted route last: **3.7× at 50 routes, 1.4× at 5**. Never slower, so it does not owe the benchmark anything. Whatever replaces it has to keep specificity ordering, which is a property of the structure rather than a cost added to it ([ADR 0013](./adr/0013-the-most-specific-route-wins-and-duplicates-are-refused.md)).
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

### Where the time inside a request goes

`zig build profile` times the pieces of one request against in-memory buffers — the inside view, where `bench/bench.sh` is the outside one. The end-to-end figure wobbles by a third on a busy box and is not worth quoting; the proportions hold, and they were a surprise:

```
  read the head                  76ns   12.8%
  parse the head                132ns   22.2%
  copy the head to the arena     24ns    4.1%
  match the route                65ns   11.0%
  serialise the body             97ns   16.4%
  write the response             70ns   11.9%
  arena alloc + reset            20ns    3.4%
```

Reading and parsing the head is the largest single thing a request does, and it had never been looked at as a cost. The remaining third is the glue: building the `Ctx`, walking the middleware chain, matching handler arguments, decoding path params.

Route matching went **39ns → 52ns** (best of eight runs, same machine, minutes apart) when the router stopped returning the first match and started returning the most specific one. That is about 2% of a request, spent on making registration order stop mattering and on catch-all routes; ADR 0001 puts the bar at 10%, so this is a trade it had already made. The full accounting, including two attempts at winning it back, is in [ADR 0013](./adr/0013-the-most-specific-route-wins-and-duplicates-are-refused.md).

What this says about where to look next: `std.json` at 13% is the one thing on this list with no ceiling on how much better it could get, and plan.md has been flagging it as a risk since stage 1. The rest is close enough to the floor that the next real gain is architectural, not local.

### How the work grows

A third kind of number needs no machine at all: how the work grows. Two places were growing wrong, and both were fixed on that basis rather than on a benchmark.

- **Finding the end of a request head** restarted from byte zero on every read. A head arriving in one packet cost one pass; the same head dribbled in a byte at a time cost a pass per byte — quadratic, and reachable by any client that chooses to be slow. It now resumes where it left off.
- **Route matching** re-split the request path for every route it tried. See "Still open" above.
