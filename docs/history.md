# How zfast was built

The record of how 0.1.0 got here: what was in scope, what order it was built in, what each pass from the outside found, and what has been measured. Kept because how a mistake hid is usually worth more than what the mistake was.

What is coming next is in [`roadmap.md`](./roadmap.md). The decisions that are binding are in [`adr/`](./adr/); the vocabulary is in [`CONTEXT.md`](../CONTEXT.md).

## Where it came from

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
- **Answers written in pieces, and server-sent events** ([ADR 0020](./adr/0020-a-request-that-lasts-is-still-one-request.md)). `c.stream(200, "text/csv")` for a body whose length nobody knows yet, `c.events()` for a stream a browser watches. Nothing is allocated per piece — held there by a test that sends 200 of them and counts two allocations for the whole request. A shutdown with a client mid-stream took 204 ms and the client got its closing event.
- **Request bodies read in pieces** ([ADR 0020](./adr/0020-a-request-that-lasts-is-still-one-request.md)). `c.bodyStream()` for a body too big to hold: bounded by the buffer the handler passes in, and it allocates nothing at all. Measured on the streaming example, five rounds of a 3 MB upload plus a 50,000-row streamed report moved RSS by 72 KB.
- **Range requests** ([ADR 0021](./adr/0021-a-range-is-a-slice-and-two-headers.md)). Listed for two stages as blocked on the same memory decision as streaming, and blocked on nothing: a file is already in memory, so a range is a slice and two headers. The work was all in the parser, where every edge case is a way to serve the wrong bytes silently.
- **WebSocket** ([ADR 0022](./adr/0022-a-websocket-is-a-handler-that-does-not-return.md)). `c.upgrade()`, and the handler owns the loop — so it takes services by type and sits behind the same middleware as everything else. Verified against a real client: text, binary, UTF-8, fragments reassembled, ping answered, close echoed, and a message past the buffer refused with 1009.
- **A test client** (`zfast.testing.Client`). A handler that returns a value is tested by calling it; one that *writes* its answer needs somewhere to write to. This is that somewhere, and it undoes chunk framing so a test asserts on what the client would see.

### What was left, and why the reason was wrong

The remaining list had been written as "one decision about where memory comes from". That turned out to be too tidy — the honest version is in [ADR 0020](./adr/0020-a-request-that-lasts-is-still-one-request.md), which asks instead what a `Ctx` means when the handler holding it has been running for twenty minutes. Streaming needed that answer. Range requests needed nothing at all, and had been sitting behind it for two stages.

What is still outstanding, and what it would take, is in [`roadmap.md`](./roadmap.md).

### What v2 cost the binary

**21 KB on the hello example, and the linker cannot give it back.** 1,030,792 bytes before, 1,052,248 after — stripped `ReleaseFast`, measured rather than estimated. Reading the symbols says where it is *not*: the modules themselves are tiny (`openapi` 4.5 KB, `static` 1.6 KB, `body` 1.0 KB, `range` 118 bytes, and `websocket` 437 bytes in a binary that uses it). The rest is the generics they wake up.

That is the same lesson [ADR 0017](./adr/0017-the-api-description-comes-from-the-signatures.md) learned the expensive way. The API description was reported at +43 KB until the binary was actually read: 37 KB of it was one extra instantiation of `std.sort.block`, which `std.sort.pdq` replaces for free since URLs cannot tie. 2% of a binary for the whole of v2 is a fair trade — but the number to publish is the one that was read off the binary, not the one the diff suggested.

## ~~Known bug: `Response(T).headers` dangles when a value is computed~~ *Fixed*

Found while running the suite in `ReleaseSafe` and `ReleaseFast` during v2. **It was a v1 bug, present since stage 6.** Fixed by making a `Response` own its headers — `.headers = .of(&.{…})`, a breaking change to a public type ([ADR 0019](./adr/0019-a-response-owns-its-headers.md)). Kept here because how it hid matters more than what it was.

```zig
return .{
    .status = 201,
    .headers = &.{.{
        .name = "Location",
        .value = try std.fmt.allocPrint(arena, "/users/{d}", .{created.id}),
    }},
    .value = created,
};
```

`headers` is a `[]const Header`. When every part of that literal is comptime-known, Zig promotes the array to static memory and the slice is valid for ever. When any part is not — and a `Location` header never is — the array is a **temporary in the handler's own stack frame**, and returning a slice of it is a use-after-return. `sendResult` reads it after the frame is gone.

In `Debug` the bytes happen to still be there, so every test passed. In `ReleaseSafe` and `ReleaseFast` it was a segfault.

Two tests failed on it, and they were exactly the two that compute a header value:

- `app.test.a handler can ask for the request arena to build a header in`
- `main.test.createUser refuses a body that does not make sense` (the rest example)

The test that passed — `Response(T) carries headers of its own` — uses literal values only, which is what hid this.

### Why it was bad beyond the two tests

It was in the README's flagship `Response(T)` example, in the rest example, and `ReleaseSafe` is the mode the README tells people to deploy in (ADR 0008). Stage 6 added `Response.headers` specifically so a 201 with a `Location` would not need a `*Ctx`; that is the exact shape that broke.

### What fixing it took

No fix keeps `&.{…}` with a runtime value, because the lifetime is the problem and not the contents — `sendResult` cannot copy from a pointer that is already dangling when it receives it. So `Response(T)` owns its headers by value now, which is a breaking change to a public type:

```zig
.headers = .of(&.{.{ .name = "Location", .value = … }}),
```

`Headers` is an inline array of eight, and `of` copies the list at the call site while it is still alive. Taking the list as `anytype` rather than `[]const Header` keeps its length in the type, so a ninth header is a compile error naming both numbers instead of a truncation. Reading them back is `.view()`. `c.setHeader` never had the problem and still has no cap.

### The finding underneath it

The suite was 175 tests and green, and the bug was reachable from the front page of the README. `zig build test` now runs everything in `Debug` **and** `ReleaseSafe`, and `-Doptimize=` no longer changes that. A cold run went from about 7 seconds to about 90 seconds, almost all of it LLVM on the release side; a run with nothing changed is still about 6 seconds, because Zig caches per module. That is the price of the class of bug that only exists in one mode, and the mode it exists in is the one people deploy.

## Risks that cleared

Three of the ones written down at the start turned out not to bite, and it is worth saying why — a risk that clears for a reason is a design that held.

- **"The compile-time layer is the hardest and most fragile part."** The safety net was that the `Ctx` layer underneath could be released on its own. The typed layer landed in stage 3 without needing it.
- **"Static files are deeper than they look — range requests, caching, `sendfile`."** Serving from memory kept the first version small, caching came along free with it, and range requests arrived later as an addition rather than a rewrite ([ADR 0010](./adr/0010-static-files-are-held-in-memory.md), [ADR 0021](./adr/0021-a-range-is-a-slice-and-two-headers.md)). `sendfile` is the one part still outstanding, and it is the one that contradicts holding files in memory.
- **"The suite is only ever run in `Debug`, and a lifetime bug can pass there and crash in release."** Cleared, at a price — it cost one bug first, the one above. `zig build test` runs everything in `Debug` and `ReleaseSafe` now, and `-Doptimize=` cannot turn that off.

The ones still standing are in [`roadmap.md`](./roadmap.md).

## What was measured

What counts as "fast" for zfast:

- **Primary:** requests per second **and p99** on a routed GET with a path param returning ~1KB of JSON, keep-alive, no pipelining.
- **Secondary:** memory per idle connection.

p99 is counted too, so that winning on throughput while stalling the tail requests does not count. One consequence is binding already: keep-alive is the main path, and there must be no stop-the-world allocation in the middle of a request.

### What can be measured without a quiet machine

Requests per second is the number that needs a machine nobody else is using. Two others do not, and both are now recorded:

- **Allocations per request: 1** on the primary metric's shape, with CORS installed — the JSON body, and nothing else. A bump allocation into an arena that is already warm; not a syscall and not a lock. Held there by a test (`the request path stays inside its allocation budget`), so putting a second back needs a reason. It was 6, then 3, and the two that went in the 0.1.0 optimisation pass were the copy of the request head (a request with no body does not need one) and the response header list (the first four live in the `Ctx`).
- **Memory per idle connection: ~21 KB** with the default buffers, measured as the RSS difference across 1,000 held-open keep-alive connections. About 4 KB of that is the read and write buffers, which `Options.read_buffer` / `write_buffer` turn down: at 2 KB each the figure is ~17 KB. Most of what is left is the fiber's own stack, which is zio's to hand out.

Neither says how fast the server is. Both notice when it gets worse, which is what is available until there is somewhere honest to measure.

### Where the time inside a request goes

`zig build profile` times the pieces of one request against in-memory buffers — the inside view, where `bench/bench.sh` is the outside one. Each row is the best of five runs, warmed first.

```
  read the head                  17ns    3.0%
  parse the head                 98ns   16.8%
  copy the head to the arena     27ns    4.6%
  match the route                41ns    7.2%
  serialise the body            165ns   28.4%
  write the response             87ns   15.1%
  arena alloc + reset            20ns    3.5%
```

Reading and parsing the head is no longer the largest single thing a request does; serialising the body is. Both of those sentences are new, and the reason is in "the optimisation pass" below. The remaining quarter is the glue: building the `Ctx`, walking the middleware chain, matching handler arguments, decoding path params.

**Two things about this table were wrong for the whole of v1 and v2, and both flattered the framework.**

The first: the end-to-end figure it divides by was the very first loop the program ran, so it paid for a cold arena, a cold instruction cache and a CPU that had not clocked up. On this machine that made it 1343ns where the warmed figure was 643ns — so *every percentage in the table was understated by about half*. `bestOf` warms and takes the best of five now.

The second is worse, because it is what hid a microsecond. This file profiled a 25-byte `{id,name}` payload while `main.zig` — the benchmark target, the thing the primary metric is defined on — answered with a kilobyte. The row that said `serialise the body 97ns 16.4%` was measuring a response the server never sends. Profiled on the payload the server really sends, `std.json` took **1038ns**: more than everything else in the request put together, and invisible for two versions because the profiler and the target disagreed about what a response looks like. A profiler measuring a different payload from the thing being profiled is worse than no profiler.

Route matching went **39ns → 52ns** (best of eight runs, same machine, minutes apart) when the router stopped returning the first match and started returning the most specific one. That is about 2% of a request, spent on making registration order stop mattering and on catch-all routes; ADR 0001 puts the bar at 10%, so this is a trade it had already made. The full accounting, including two attempts at winning it back, is in [ADR 0013](./adr/0013-the-most-specific-route-wins-and-duplicates-are-refused.md).

### The optimisation pass before 0.1.0

Everything above had been measured but never *acted* on. This pass did the acting, and the method mattered as much as the result: each change was A/B'd end to end against a build of the previous commit, best of five runs of 1.5M requests, on five request shapes at once — because a change that helps a 121-byte head can hurt a 556-byte one, and only measuring both catches it. Three ideas that looked good in the abstract were measured and dropped (see the end).

The five shapes, before and after, in nanoseconds per request:

| Shape | Before | After | |
|---|---|---|---|
| **Primary metric — routed GET, path param, ~1KB JSON, CORS** | **1684** | **605** | **−64%** |
| GET, small head (121B), small JSON | 658 | 430 | −35% |
| GET, browser head (556B, 13 headers), small JSON | 872 | 559 | −36% |
| GET, `Query(T)` struct from three params | 712 | 569 | −20% |
| GET, literal route, text out | 398 | 309 | −22% |
| POST, JSON body in, JSON out | 992 | 808 | −19% |
| *(floor: `*Ctx` handler, no typed layer)* | 436 | 307 | −30% |

What did it, in order of how much it was worth:

- **A JSON writer generated from the type** (`src/json.zig`), which is where the −64% comes from. Two things were slow about `std.json` for a response: it writes each brace, quoted field name and colon through the writer separately, and it escapes a string a byte at a time. So the constant parts of the output are one comptime string per field now, and a string is scanned 32 bytes at a time for the three characters JSON cannot carry — the run in between goes out whole, and almost every string has no such character at all. On the primary metric's payload, **1038ns → 126ns**; on a small one, 75ns → 22ns. The output is byte-for-byte what `std.json` writes, which is not a hope: `covers()` decides while compiling which types this path may touch, anything else falls back unchanged, floats are handed to `std.json` field by field rather than reimplemented, and the tests hold the two against each other value by value. Two things `std.json` does that are easy to get wrong were found this way and left to it: a `[N]u8` is a *string* to it, not a list of numbers, and a type with its own `jsonStringify` has the last word.

- **A request head walked once instead of once per line per delimiter** (`src/scan.zig`, used by `http1.parseHead`). Finding the end of the head called `std.mem.indexOfScalar` once per header line, and parsing it called it twice more; each call is a pass that restarts, with its own preamble, every twenty bytes. Now a block is loaded, compared against the byte, and the positions are read off a bitmask — two delimiters for one load. The colons are handled *as a mask* rather than walked: for each line the colons inside it are isolated with a shift and an `and`, which answers both "is there one at all", which is what makes a malformed line a 400, and "where is the first", which is what names the header. Walking them instead cost 70ns on a browser's head, because a header *value* is full of colons and none of them is interesting. Finding the end: **183ns → 51ns**. Parsing: **303ns → 163ns**.

- **The request head is no longer copied when nothing will read it again.** Every `Str` from a request points into the head, and the head sits in the connection's read buffer, so it was copied into the arena on principle. But only a *read* can overwrite it — and a GET has no body to read and no protocol taking the socket over. So the copy is made only for a request that will read again, which `Request.readsMore` answers. Worth 19ns on a small head and 77ns on a browser's, plus one of the three allocations. What keeps it from becoming the next ADR 0019 is `Ctx.aboutToRead`: every path that reads from the connection calls it, and it fails loudly in a debug build if this decision said there would be no such path. `Request.upgrade` is deliberately looser than `websocket.isUpgrade`, so it cannot be the narrower of the two.

- **The first four response headers live in the `Ctx`.** An `ArrayList` meant an arena allocation on every request that had any middleware at all, for something that fits in 128 bytes of a struct already on the stack. CORS sets one to three; a static file two. The fifth spills, and then the spill is the whole list.

- **The query string is walked once too**, with `&` and `=` found together the way the head's newlines and colons are, and the `&`s counted up front so the list is one allocation rather than one per doubling. `?q=hello%20world&sort=newest&page=3`: **263ns → 191ns**. Percent-decoding also went from three passes to one — and a `%` that is not a real escape now costs nothing at all, where it used to allocate a byte-for-byte copy.

**What was measured and dropped**, because it is worth the same as what landed:

- **Filtering header lines by their first byte alone**, skipping the colon scan entirely. It was the fastest thing tried — 255ns → 137ns on a browser's head — and it silently accepts a header line with no colon in it, which this parser explicitly promises not to do. The mask version keeps the check and gets most of the win.
- **Shrinking `Match`.** It is 288 bytes, almost all of it room for eight path params, and it is returned by value. Cutting `max_params` to 2 to measure the copy was worth about 10ns — real, and not worth a public limit or a refactor.
- **A larger `json_hint`**, so a ~1KB response fits without growing. No measurable difference: the arena extends the most recent allocation in place, so the growth was nearly free already. A documented constant should not change without a number behind it.

**What it cost the binary: 5,680 bytes**, measured the way the v2 figure below was — the hello example, stripped `ReleaseFast`, 1,052,248 → 1,057,928. Half a percent, for a generated writer and a scanner, on an example that returns text and never serialises anything. Worth saying rather than leaving to be discovered, since v2's 21 KB got a section of its own.

The three-axis budget in [ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md) came through this intact. Throughput went up rather than down, allocations per request went 3 → 1, and memory per idle connection did not move — `Ctx` grew by 136 bytes for the inline headers, and it lives on the fiber stack for the duration of a request, not on a connection sitting idle.

What this says about where to look next: `parse the head` at 17% and `write the response` at 15% are now the two largest, and both are closer to their floor than `std.json` ever was. The next real gain is architectural — the linear route scan ([`roadmap.md`](./roadmap.md)) — not local.

### Where the time goes on a connection that lasts

The profile above is one request-response, which was the whole of zfast when it was written. Everything v2 added is shaped the other way round — one request, then work per message, per piece or per kilobyte — and none of it had been timed at all. Against in-memory buffers, so there is no kernel in these:

```
  websocket: frame overhead           27ns
  websocket: receive 16 KiB          821ns   20.6 GB/s
  websocket: send 16 KiB             438ns   37.4 GB/s
  stream: 200 pieces                3216ns
  stream: one piece                   16ns
  sse: 200 events                  11880ns
  sse: one event                      59ns
  body: 1 MiB, Content-Length      38378ns   27.3 GB/s
  body: 1 MiB, chunked 8 KiB       36342ns   28.9 GB/s
  range: parse one                   109ns
```

The point of putting a throughput next to a duration is that one loop doing something silly is invisible in nanoseconds and obvious in gigabytes per second. `receive` first measured **2.6 GB/s against 33 GB/s** for `send` — the same 16 KiB, the same copy, with unmasking as the only difference. RFC 6455's `byte ^= key[i % 4]` is a byte at a time; the key repeats every four bytes, so the whole thing is one XOR against a repeating pattern and therefore a vector operation. 6,451ns → 821ns, and the chat example's binary got 920 bytes smaller.

The other rows are near enough to memcpy that there is nothing in them: a body is bounded by the copy it has to make, and a stream piece is 16ns of formatting.

### How the work grows

A third kind of number needs no machine at all: how the work grows. Two places were growing wrong, and both were fixed on that basis rather than on a benchmark.

- **Finding the end of a request head** restarted from byte zero on every read. A head arriving in one packet cost one pass; the same head dribbled in a byte at a time cost a pass per byte — quadratic, and reachable by any client that chooses to be slow. It now resumes where it left off.
- **Route matching** re-split the request path for every route it tried, which is a different kind of wrong from "linear". Patterns are split at registration now and the path once per request, and a route with a different segment count is rejected on an integer compare. Measured in-process, worst case with the wanted route last: **3.7× at 50 routes, 1.4× at 5**. Never slower, so the linear scan does not owe the benchmark anything — replacing it is still open ([`roadmap.md`](./roadmap.md)).

## After 0.1.0: deadlines

The one thing 0.1.0 shipped without that made it unsafe to expose directly. `nc host 8787`, say nothing, and a fiber was parked until TCP gave up — minutes, from one laptop, with no tool and no bandwidth.

The decision it needed is in [ADR 0023](./adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md), and it went the other way from where it looked like it was going. Not a deadline per request: **a limit on one wait for the network.** A request deadline would have had to kill a stream that runs for an hour and a 4 GB upload on a domestic line, both of which are working correctly, and implementing it honestly would have meant interrupting a handler — which Zig cannot do safely, the same fact that rules out a `recover` middleware.

Four limits, then, on four different waits: the head, an idle connection, one read of a body, one write to the client. The subtle one is the head, and it is the whole defence: it is an *absolute* deadline shared by every read, because a client sending one byte a second satisfies a per-read limit of any size forever and never finishes. A test counts the arming rather than trusting the comment.

Measured against the real server on a real socket, with the limits turned down to 1000ms (2000ms idle) so a check takes seconds:

```
  a healthy request                        200 in 10ms
  two requests on one keep-alive           both 200
  a head that stops halfway                408 at 1001ms
  a head at one byte every 300ms           408 at 1201ms
  an idle keep-alive connection            closed at 2000ms, nothing written
  a body that stops halfway                connection released at 1002ms
  80,000 answers asked for, none read      closed at 1116ms
```

The last row is the one ADR 0020 could not answer. Before this, that client held a fiber in a blocked write for as long as the kernel allowed.

Two things about how it was built are worth keeping.

**The Engine needed nothing new.** zio already keeps a timeout on its reader and its writer and applies it to every operation, so putting a limit on the next read is a field store — no timer, no watchdog fiber, nothing per connection. What the Bulkhead added was the split: `engine.Clocks` can apply a limit and has no idea why, `bulkhead.Deadlines` knows why and has no idea how.

**That split is also the test seam, and it is why the tests are quick.** `Deadlines` reaches its target through a vtable, so a test hands `App` one that writes down what it was asked for instead of doing it. "The header deadline is armed once, however many reads the head takes" is then a counting assertion that runs in a millisecond — where a socket test would have to wait out a real deadline to prove a negative. What zio does with a limit once it has one is checked by hand; the table above is that run.

One wart the tests found: `drain` was arming the body limit on requests that had no body, which left a limit meant for a body sitting on a connection about to go idle. And one log line got fixed on the way past — `handler GET /users/7 failed after answering: WriteFailed` sends whoever reads it hunting for a bug in a handler that did nothing wrong, so when the write ran out of time it now says the client stopped reading.
