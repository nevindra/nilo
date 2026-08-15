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

## After 0.1.0: what building a CRUD app found

Not a feature and not a bug report — a todo API written from `zig init` to `curl`, by somebody who had only the guide, to see what the DX is actually like at the shape zfast is most likely to be used in. Everything below is something that trip hit.

The happy path held up. `GET`, `POST` with a `Location`, `PUT`, `PATCH` — correct on the first run, no framework compile errors, and the validation messages are as good in a real app as they are in the tests. What follows is what was *around* it.

**`Response(void)` did not compile.** `return .{ .status = 204 }` gave `missing struct field: value`; adding `.value = {}` gave `Unable to stringify type 'void'`, four frames inside `std.json`. The cause is worth recording because it is a shape to watch for: `answerOf` had a branch for `Response(void)` and `sendValue` had no `void` case, so one side of the bridge was documenting a case the other side could not reach. A dead branch on one side of a boundary is evidence the other side is missing one.

It also broke the rule [ADR 0015](./adr/0015-what-zfast-borrows-and-from-whom.md) sets for itself — *every check fires at the first place a human named the thing, or it does not ship*. Two of the errors on this trip came from inside `std`, not from zfast.

**The generated document could not be used for CRUD.** Every read handler ended `orelse fail.notFound(…)`, and not one of those 404s reached the document, because `fail` calls live in a function body and comptime cannot read one. Every write endpoint said `default` for its status. The fix was to move both into the return type — `!?T` and `Status(code, T)`, [ADR 0024](./adr/0024-a-failure-mode-belongs-in-the-return-type.md) — rather than to add the annotation FastAPI uses, which would have been a second thing to keep in step.

The `!?T` slot turned out to be free. It used to answer `200` with the body `null`, which is a thing nobody means by a get-by-id.

**Errors went out as `text/plain`.** The best error messages in the ecosystem, in the one format the code reading them cannot accept: `res.json()` throws on every 4xx, in the `catch` where the frontend was going to show the user what went wrong. [ADR 0025](./adr/0025-every-failure-answers-with-the-same-json-body.md).

**Validation stopped at the first level.** `{"address":{"street":"jl mawar"}}` was a bare `Bad Request`, where the same mistake one level up got a sentence. `describeBadBody` walked the top level and `fits()` checked a struct field only for being an object at all, so the loop found nothing and fell through. Now it recurses and names the field by where it is — `address.city`, `lines[1].qty`.

**PATCH could not express itself.** `{}` and `{"due":null}` arrive identical through `?T`, so "leave it alone" and "clear it" are the same request. [ADR 0026](./adr/0026-a-patch-needs-three-answers-and-an-optional-has-two.md).

**The `Str` trap missed the way anybody would test it.** Two `curl` calls stashed a `Str` and read it back, and got the stale bytes with no complaint; the same thing on one keep-alive connection panicked correctly. Every connection started its generation counter at zero, so the second connection's counter matched what the first connection's `Str` was holding. Spans per connection fixed it. The lesson is not about counters: **the case the trap was tested with was the case that could not fail.** Same request, same handler, two connections instead of one, and the safety feature was off.

**Two-fifths of the app was memory bookkeeping.** 58 lines of dupe/free/lock against 84 lines of handler, and not one page of the guide talked about the pattern. That is what owning memory costs in Zig rather than anything zfast does, but the audience is people for whom it is new, so [Services](./guide/services.md#holding-on-to-request-text) now says it plainly and the `rest` example — the one everybody copies — was extended to `PUT`, `PATCH` and `DELETE` so that it shows the whole shape rather than the easy half.

That last point is the one worth generalising. `rest` had no `DELETE`, which is why nobody found that `Response(void)` could not compile.

Measured, stripped `ReleaseFast`: **+6 KB on hello, +14 KB on rest**, and the allocation budget is unchanged — the failure path uses a stack buffer, and the nested description allocates in the request arena on a request that was already going to be refused.

## After 0.1.0: what a domain that is not one flat struct found

The trip above was a todo list — one struct, four fields. So the next one was deliberately the opposite: orders with lines in them, an address, a customer, a state machine, an upsert, three services and an upload. It is in the repo as [`examples/orders`](../examples/orders/main.zig), because a stress test nobody can run again is an anecdote.

**Most of it was uneventful, which is the finding.** The file compiled on the third try, and both failures were Zig rather than zfast: `packed` is a keyword, and two top-level `const`s shadowed two parameters. Nothing in the argument-list rules needed a second look at three services, two path params on one route, a `Str` param beside a `Query(T)`, a resolver that takes a service, and a middleware written by a function. The comptime layer scales.

**A route that writes its own answer was documented as answering nothing.** The upload endpoint sends a 202 with a JSON body; the document said `"200": "an empty response"`. The roadmap had this recorded as *routes that drop to `*Ctx` drop out of the document* — which would have been fine. They did not drop out. They stayed in and lied, and a wrong entry in a generated document is worse than a missing one because nobody goes looking for it. A handler holding a `*Ctx` and returning nothing now says so, and `listen()` counts them at startup.

**A generic lost its shape's name.** The obvious answer to writing every body struct twice — once with `Str`, once with `[]const u8` — is to write it once with the text type as a parameter. Doing that turned `Address` into `Addressed(str.Str)`, which is not an identifier, so the shape went from a named component to an anonymous copy at every use. Fixing the naming rather than the generic was the right end to pull: `main.Page(main.Order)` reads back as `Page_Order`, `[]const u8` reads as `Text`, and two generics that render to the same name and are not the same shape both lose it rather than one silently describing the other.

**An enum's refusal argued with itself.** `{"to":"teleported"}` answered `"to" has to be one of draft, placed, …, not text` — and it *was* text. The query-string half of the same feature had the better sentence all along (`?stage is not one of the known choices (…): "nonsense"`), so the body half now uses it and quotes back the word it was given.

**The suite caught the bug it exists to catch, in the test helper.** Six tests passed in `Debug` and failed in `ReleaseSafe`, because a `&.{ … }` written inside a function is a pointer into that function's frame. That is [ADR 0019](./adr/0019-a-response-owns-its-headers.md)'s bug met from the user's side, and the reason `zig build test` runs both modes every time.

**What stayed hard is what a service owns.** With lines, an address and a customer in one row, a hand-written `free` is a dozen calls that fall out of step with the type the first time a field is added; an arena per row makes freeing one call. And a read has to copy into the request arena before returning, because zfast writes the response after the handler returns and a `DELETE` in that gap frees the text mid-write. Neither is zfast's to fix — but neither was written down, and now both are, in [Services](./guide/services.md#once-a-row-is-more-than-one-string).

## After 0.1.0: making the rule about error messages hold

[ADR 0015](./adr/0015-what-zfast-borrows-and-from-whom.md) borrowed Elm's standard and wrote it with teeth — *fires where a human named the thing, says what is wrong, says the fix, or it does not ship* — and then nothing held it. The CRUD trip above found two checks that had already got past it. Being found by accident is the whole problem, so the next piece of work was the thing that would find them on purpose.

`refusals/` is 39 programs written wrong on purpose. Each has to fail to compile with a message named in a table in `build.zig`, and `zig build test` compiles all of them ([ADR 0027](./adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)). The detail that makes it a rule rather than 39 assertions is that **the build script supplies the `zfast: ` prefix** — so a check that stops somewhere inside the standard library cannot be written down as passing, only fixed or deleted.

Writing the cases found four defects, in the part of the codebase whose message quality had been argued about the most:

- **Two messages had no `zfast:` prefix**, both on `Response.headers` — in the file that documents the rule.
- **A slice handed to `Headers.of` never reached its message.** `of` dereferenced any pointer and a slice is a pointer, so it stopped with `index syntax required for slice type '[]http1.Header'`: an error from inside zfast, about zfast, three lines above the sentence written for exactly that mistake.
- **The two-bodies message blamed the wrong argument.** `fn placeOrder(store: Store, incoming: NewOrder)` — a service passed by value — was told `NewOrder` was the surplus body and advised to make *it* a pointer. `NewOrder` was the one correct thing in the signature. zfast cannot tell which of two structs was meant to be the body, so it now names both and states the rule.
- **zfast's types were spelled with zfast's file names.** `str.Str`, `[]http1.Header` — true, and about a source tree the reader does not have. `src/names.zig` prints them as `zfast.Str` and `[]zfast.Header`, and leaves a type of the reader's own where they wrote it.

Then it exposed something bigger than any of them. The rule has two halves and only the second was being checked; on the first — *fires where a human named the thing* — zfast was failing everywhere. Zig reports a `@compileError` inside zfast and points back with a reference trace two frames deep, and both of those frames were `src/app.zig`. The reader's own line was the third entry, hidden behind a flag they would have to know to pass:

```
referenced by:
    route__anon_702: src/app.zig:284:22
    post__anon_685: src/app.zig:244:23
    6 reference(s) hidden; use '-freference-trace=8' to see all references
```

The fix is that `post` — and every other registration method — runs the check itself instead of letting the error surface from wherever the work is done. Same checks, same words, called one frame from the reader:

```
referenced by:
    refusal: refusals/two_bodies.zig:17:13
```

Measured stripped, `ReleaseFast`: **+0 bytes** on hello, rest and orders alike, all of it being comptime. The cost is build time — a warm `zig build test` went from 6.4s to 15.4s, because the compiler keeps nothing from a compilation that failed and all 39 are re-analysed every run. It goes on `test` anyway: enforcement that has to be asked for is a sentence in a document again, which is where this started.

## After 0.1.0: what the router scan actually costs

"No machine to measure on" had been doing more work than it should. It is true of *throughput* — requests per second on a quiet box, which is what [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s 10% rule needs and what nothing here can produce. It is not true of the pieces: `zig build profile` measures those in-process and always could. The linear router scan had been sitting under the first excuse while being answerable by the second.

So it got measured. Two route sets, five sizes, wanted route registered last so nothing is captured early:

| routes | 1 | 5 | 25 | 50 | 100 |
|---|---|---|---|---|---|
| mixed — four methods, three depths | 27ns | 47ns | 56ns | 107ns | 167ns |
| same shape — every route `GET /thingN/:id/leaf` | 53ns | 84ns | 242ns | 431ns | 855ns |

The first set is what an app looks like and the cheap filters throw out nearly everything. The second is the ceiling: same method, same length, same score, so every route runs the full segment walk. The distance between the rows is the whole story — it is the first literal segment doing all the rejecting.

**The useful number is where it crosses.** One request is 585ns of zfast's own work, measured with one route. A 25-route app spends ~9% of that matching, a 50-route app ~16%, a 100-route app ~23%. The scan passes ADR 0001's bar at **around 30 routes**, which is an ordinary app rather than a pathological one. That turns the roadmap entry from *needs numbers nobody has* into a threshold — with the caveat, stated because it matters, that this is 10% of zfast's work and not of a real request's wall clock.

**And a hypothesis was tried and was wrong**, which is the other half of what measuring is for. The idea was that "linear" was the wrong thing to blame: rejecting a route reads about ten bytes and a `Route` is seven times that, so the scan looked like it was pulling in cache lines to read four fields. Lifting those four into a packed parallel array made the mixed set 7% faster and the same-shape set 10% slower — a wash, bought with eight bytes per route of duplicated state that `add` has to keep in step. Reverted. The routes are walked in order, the prefetcher was already covering the stride, and what the scan actually spends is compares and the first `mem.eql`.

What survives is the harness. The question is now one command for anyone who wants to ask it again, which is the part that was missing when the answer was "there are no numbers".

## After 0.1.0: a machine turned up, and one of the numbers was about us

The measuring machine the benchmark script had been waiting for since stage 1 finally existed. What it produced is in [`benchmarks.md`](./benchmarks.md) and [`comparison.md`](./comparison.md) — 1.31M req/s, 16,961 bytes per idle connection, first place on throughput against eight other servers and second on the tail. Pleasant, and not the useful part.

**The useful part was being wrong twice in one afternoon, in public, about our own build.**

The first was a measuring mistake and it flattered nobody. The server was pinned to CPUs 0–7 and the load generator to 8–15, which reads like eight cores each. On this machine CPUs 0–7 are the eight physical cores' *first threads* and 8–15 are their SMT siblings, so both halves were sharing all eight cores. Splitting by physical core instead — four whole ones each — made the server **faster on half as many cores**, 1.14M to 1.31M. Every number taken before that was wrong in the same direction.

The second was worse, because it was an accusation. `zig build -Doptimize=ReleaseFast` takes 15 seconds warm, and that got written down as "zfast has the slowest edit-rebuild loop in the field, 75× Go's", with the cause named as the comptime typed layer. Both halves false:

- **`zig build` is `Debug`, and `Debug` is 0.4s.** Nobody's edit loop was ever 15 seconds. The 15 is a release build, which is a thing you do before you ship, not on every save. Against Go's 0.2s in the same loop, zfast is behind by two tenths of a second.
- **Comptime is nearly free.** Measured by building progressively less of zfast in `ReleaseFast`: a Zig hello world with no zfast at all is **7.1s**, zfast with zero routes is 14.6s, and thirty-two routes is 16.6s. So half the release build is Zig's own floor, ~7.5s is zfast's library arriving as machine code for LLVM to chew, and the thing that looked most expensive — one specialised handler generated per route — costs **59ms each**.

The general lesson is the one [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md) keeps needing: a number is not a finding until you know what is in it. "15 seconds" was measured correctly and meant something entirely different from what it was used to argue.

**What actually changed.** One real choice existed and it was in the test step. A warm suite is 0.8s in `Debug` and 7.8s in both modes, so [ADR 0019](./adr/0019-a-response-owns-its-headers.md)'s both-modes rule — which exists because a use-after-return passed 175 tests in `Debug` and segfaulted in release — was charging 10× to the loop somebody sits in. `zig build test` is now `Debug` and `zig build test-all` is both, with CI running `test-all` on every push. The standard did not move; the clock did. The repo had no CI at all before this, so the split came with the thing that makes it safe rather than after it.

And one price named in an ADR turned out to have quietly stopped being real: [ADR 0027](./adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md) recorded the 39 refusals as "about 9 seconds on every `zig build test`" that "never cache". On Zig 0.16 they cache, and they are 0.5s. Nothing was done to earn that, which is exactly why it needed checking.

*It needed checking harder. Re-run later against a clean checkout of this very commit, `zig build refusals` is **10.6s** warm for those 39 — they never started caching, and the 0.5s was a bad measurement. The paragraph above stays where it is because it is the mistake it warns about, made in the same breath: "a number is not a finding until you know what is in it", followed immediately by a number nobody looked into. See [ADR 0027](./adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md), which now carries the corrected figure.*

**What was left alone.** Memory per idle connection is 16,961 bytes and seventh of nine — http.zig holds a connection in 11.2 KB, Bun in 338 bytes. zfast is the leaner one below about a thousand connections and is not above it, so the README's "low memory" needs the qualifier or the number needs to come down. Not fixed here, and written down rather than left to be discovered, which is the only part of that sentence this project has earned yet.

*It came down. A keep-alive connection was holding every buffer page it had ever touched until close; between requests those pages now go back, and the figure is 8,767 bytes flat — third of nine, and third place is behind Bun and nothing else. The number is in [`benchmarks.md`](./benchmarks.md).*

## After 0.1.0: the release build, and the third wrong reason

The build number kept getting attributed to the wrong thing. It had already been wrong twice — once as "the slowest edit loop in the field" when `zig build` is `Debug` and 0.4s, once as the comptime typed layer when comptime is nearly free. The remaining sentence, *"half the release build is Zig's own floor and the other ~7.5s is zfast's library arriving as machine code for LLVM to chew"*, was measured correctly and still named the wrong cause.

Stopping the same build at each stage says where it goes:

| | |
|---|---|
| parse and sema — every comptime handler included | **0.5s** |
| and LLVM, with the debug info left out | 7.3s |
| and the debug info | 14.7s |
| the same, stopping before the link | 14.6s |

The frontend is 3%. The linker does not appear at all — `build-obj` and `build-exe` came out 30ms apart. **Half of a release build is debug info**, and it is half for two reasons rather than one: 1.9 MB of DWARF has to be generated and then carried as metadata through every optimisation pass, and some of the machine code stops existing, because with nothing to read, std's stack-trace machinery — a DWARF reader and an ELF parser — is dead. `.text` goes from 787 KB to 498 KB.

**And the comparison had been unfair in the same place.** Rust's `[profile.release]` leaves debug info out unless asked; Zig emits it and makes you opt out. So "zfast 15.0s against axum 4.8s" was a build that does the work sitting next to a build that skips it. Measured both ways, warm: axum is 6.5s with and 4.7s without, zfast 14.7s and 7.4s. zfast is still last. It is last by 2.7s rather than by 10.2s, and the difference between those two readings was nobody's code.

**What changed.** `zig build -Doptimize=ReleaseFast` now leaves debug info out of the two binaries whose whole job is to be measured — 14.7s to 7.4s, the binary 6.0 MB to 0.8 MB. It costs nothing at runtime: 1,996,698 req/s against 1,988,414, inside this machine's noise. What it costs is the file and the line on every frame of a panic, so the examples and the tests keep theirs, and `-Dstrip` overrides in both directions.

**A mistake made while doing it, caught by re-measuring something that should not have moved.** The helper deciding this returned `bool`, so every mode that had not asked for debug info got told to keep it — and Zig already leaves it out in `ReleaseSmall`. That mode went from 3.7s to 6.9s, quietly, in a change whose entire subject was build time. The only reason it was noticed is that the mode table was measured again afterwards rather than assumed unchanged. The return type is `?bool` now, and `null` means *the mode decides*.

**One dead end, recorded because it looks alive.** `-fno-llvm` builds the same executable with Zig's self-hosted backend in **0.31s** — 47× faster. The binary does 615,264 req/s against 1,988,414, with a p99 of 555ms. It is not a release build, and for the loop where build speed is the thing that matters, `Debug` is already 0.4s.

## After 0.1.0: the parser gets a fuzzer, and what the first hour of it found

The request head is the one piece of zfast that a stranger writes directly. Every test of it, all the way to here, was an input somebody thought of — which is a decent way to check the cases you know and no way at all to find the ones you don't.

**The coverage-guided fuzzer was the plan, and it does not work.** Zig 0.16 has `zig build test --fuzz`, and `std/Build/Fuzz.zig` is 99 mentions of it, so it looked like a switch to flick. It fails to compile: `lib/compiler/test_runner.zig:566` passes a `*builtin.StackTrace` where `std.debug.writeStackTrace` wants a `*const debug.StackTrace`, and that line is only instantiated in fuzz mode. Nothing of ours is involved — a five-line file with a `std.testing.fuzz` call and no imports reproduces it.

So the targets are written as `std.testing.fuzz` targets anyway, and two other things drive them:

- **`zig build test`** replays a corpus through them. That is the regression half: every input this has ever caught, plus every nasty shape anybody wrote down — both framing headers at once, `Content-Length: -1`, a chunk size of `ffffffffffffffff`, a head boundary landing exactly on a block edge.
- **`zig build fuzz`** generates them. Not random bytes, mostly: three quarters of the inputs are built to be nearly valid and then damaged in one place, because random bytes are almost never a request and a run made of them re-checks that nonsense is refused. A million inputs is about eight seconds, and CI runs a million on every push with the commit SHA as the seed — so a given commit always fuzzes the same million, and a red job re-run gives the same answer rather than a coin toss.

**Two of the three properties are differential**, and that is what makes them worth having. "It does not crash" is a low bar for a parser; the interesting question is whether the fast implementation and an obvious one agree. Where a head *ends* is where the next request begins, and `Content-Length` and `Transfer-Encoding` are the two fields a smuggled request is built out of, so a disagreement about any of them is a security bug rather than a wrong answer. The reference is written to be obviously right: no blocks, no bitmasks, no resuming.

The third property is about resuming specifically. `readHead` is called again every time more bytes arrive and does not rescan what it has seen — it backs up three bytes, so a `\r\n\r\n` split across two reads is still found. Three is exactly the kind of number that is right until it is off by one, so the check replays a head arriving a byte at a time and requires the resumed answer to equal the from-scratch answer at every single prefix.

### What it found

**A header line with no name was accepted.** `: value` — colon first, nothing before it. zfast ignored the line and carried on; every reference parser refuses it, and RFC 9110 §5.1 says a field name is one or more characters. zfast already refused a line with *no* colon, so this was the same rule applied inconsistently. It is a 400 now. Small, and precisely the kind of leniency that ends up in a smuggling write-up years later.

**`readChunkedBody` is arena-only, and nothing said so.** The property that a body cannot exceed its limit was written with the testing allocator, and `0\r\n\r\n` — a body of no chunks — panicked with *Invalid free*: the empty body comes back as a slice that was never allocated. Reading further, a chunk that fails partway leaves what it had, too. Both are correct against the request arena, which is the only thing that ever calls it, and neither survives a general allocator. The contract is written down now, and the check reads into an arena like the server does.

**The corpus was decoding to nothing.** `std.testing.Smith` replays a recorded input as a length-prefixed stream, and the helper building those prefixes wrote them with `std.mem.toBytes(@as(u32, text.len))`. That compiles, and every entry came out with `0xaa` where the length should be — the undefined-memory pattern. Every corpus entry was silently replaying as an empty input, and the suite was green while testing air. What caught it was a test whose whole job is to check that one corpus entry arrives at the target as the bytes it was written as, added because a corpus you cannot see decode is a corpus you are trusting.

**And the first thing it caught was the oracle.** The reference request-line parser split on spaces, which made `GET /x` an unsupported version where zfast said malformed request line. zfast was right. A reference implementation is code, it gets things wrong like code, and a differential test that has never disagreed with anything is not evidence of much.

Twenty million generated inputs, plus the corpus in both build modes, and the three properties hold.

## Four ways to broadcast, three of them wrong

`spike/broadcast` existed for about a day and is gone with
[ADR 0029](./adr/0029-a-spawned-fiber-belongs-to-the-server.md), which is what
it was for. It answered the question [ADR
0022](./adr/0022-a-websocket-is-a-handler-that-does-not-return.md) had left
open — what does it take to write to a socket this fiber does not own — and the
answer was not the one that ADR had guessed at twice.

**The obvious problem is not the problem.** A connection's write buffer belongs
to the fiber serving it, so two fibers writing into it interleave frames. That
is real, and a lock per socket fixes it: no torn frames in any shape the spike
tried. So the first version held the room's lock across every write, and the
second — the fix anybody reaches for — held it only long enough to copy out who
was there, then took a lock per socket for the writes.

They are exactly as dead as each other. Eight clients, one of them handed a
socket and then never reading from it, two healthy clients wanting only to talk
to each other: their messages never arrived, in either version, at a five-second
timeout. Contention was never what was wrong. The broadcast is done by the
*speaker's own fiber*, which walks the connections, reaches the wedged one, and
blocks there — and never gets back to reading its own socket. Any design where
fiber A writes to socket B ties A's liveness to B's readiness to read, and no
lock granularity touches that.

**So the write has to be done by a fiber that serves only B, and a fiber has a
price.** 400 idle connections, RSS delta, repeated until the number stopped
moving — byte-identical across runs:

| | bytes per idle connection |
|---|---|
| one fiber | 66,959 |
| two fibers | 75,633 |
| **difference** | **8,673** |

[ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md) calls 8,767 bytes per
idle connection a hard invariant. The writer fiber costs that entire budget a
second time, to within one percent. The absolute numbers are a Debug build and
mean nothing on their own; both modes carried an identical member struct, so the
delta is the fiber and nothing else.

**The obvious way to get it back does not.** `zio.BroadcastChannel` — one ring
for the whole server instead of a queue per connection — is better in two ways
that matter. Delivery went from 5,925 of 12,000 messages to 12,000 of 12,000,
and the send path collapsed to `wire.send(post)`: no lock, no walk, no touching
another connection's memory at all, which deletes the nastiest thing in the file
(a registry holding pointers into other fibers' stacks). It made no difference
whatsoever to the number above. Idle, the two agree to the byte, because a queue
that is never written costs nothing. The fiber is the price.

It also crashed 2 runs in 4 under connection churn, inside zio's own wait queue:
a waiter node pushed onto a list it was already in. The same test crashed 0 of 2
with no spawned fiber and 0 of 4 with a per-connection queue, so it is not churn
on its own. A shared ring has no per-consumer close, so the only way to stop one
reader is to cancel its fiber — that difference is forced, not chosen. Worth
reporting upstream regardless of what zfast does, because the check is
`runtime_safety`-only: in `ReleaseFast` the same race relinks the node with
nothing said.

**What shipped was the half that was paid for.** `zfast.spawn` — somewhere to
put work that is not a request, joined to the server's group rather than
detached, because the spike's detached version made shutdown announce eight
fibers when there were sixteen. Broadcast did not ship, and the reason is now a
number instead of a shrug. The shape that would cost nothing extra is the one
ADR 0022 guessed second — a mailbox the connection's own fiber drains — and it
turns out to be blocked on one exported line upstream: zio has `ev.NetPoll`,
`ev.Async.notify` and `ev.Group.init(.race)`, which is exactly how its own
`timedWaitForIo` races a read against a timer, but nothing public parks a fiber
on a completion. Asked for as
[zio#668](https://github.com/lalinsky/zio/issues/668), with the 8,673 bytes
attached, since a number is a better argument than a request.

**The thing that nearly went wrong quietly.** A spawned fiber has no task-local
slot, so `bulkhead.slot()` falls through to a threadlocal — and a threadlocal is
what [ADR 0007](./adr/0007-failure-box-bound-to-the-fiber.md) exists to say is
the wrong answer. If anything ever set it on an executor thread, spawned work
would write its failure message into an unrelated user's response. It does not,
because the one place that writes it does so from inside `zio.blockInPlace`,
which runs on a thread-pool worker. That is a real invariant held up by a
coincidence of scheduling, and until this it was written down nowhere. Both ends
carry a comment now.

## The suite that was never failing

`zig build test` had been printing a red block that reads exactly like a failure
report — a warning line, then `failed command:` and the path of a test binary —
and doing it often enough to be written off as a flaky suite under load. It was
neither flaky nor a failure. Underneath the red, every run said
`76/76 steps succeeded; 722/722 tests passed`, and every run exited 0.

**Two mistakes, and each one hid the other.**

The first: `src/test_root.zig` set `std_options` with a log function that threw
every line away, and a comment in `build.zig` explained why that was necessary.
It had never run. In a test build the root module is the compiler's own
`lib/compiler/test_runner.zig`, which declares `std_options` itself, so a tested
file's copy of it is never read. The runner's log function writes to stderr, and
the build runner answers stderr from a test process with that red block. One
test — the one checking that bytes written after `finish()` are dropped loudly —
tripped it every single time.

The second is why "every single time" looked like "sometimes". A run step that
already succeeded is cached, so `zig build test` six times in a row executes the
binary once and prints nothing on the other five. Green runs were not evidence
of anything. Forcing the run — `touch` one source file per iteration — gave the
warning eight times out of eight, at which point there was nothing intermittent
left to chase.

The fix is three lines in the test that provokes the warning: turn
`std.testing.log_level` down around it and put it back. Scoped there rather than
set once for the whole suite, because the warning earns its keep — a test that
trips it *by accident* should still say so. `zig build test-all` now produces
zero bytes of output.

Worth keeping in mind for the next one: a green run only means something if the
run actually ran, and a build that exits 0 can still print something shaped like
a failure.

## The third guard that was written not to catch anything

Straight after the one above, and the same shape: the test guarding
[ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md)'s hard invariant —
one allocation per request — opened with

> `// No middleware, deliberately. A path that matched no route builds its`
> `// chain out of the request arena — that is one allocation, it predates`
> `// any of this, and it would hide the thing being measured here.`

Every word of that is true, and together they mean the one shape nearly every
app deploys — assets behind a logger — was the one shape the allocation budget
never checked. A path that matched no route had no chain precomputed, so
`handleRequest` built one per request out of the arena. Static files go down
that path by design (ADR 0010), so every asset served with any middleware
registered broke the invariant, quietly, and the guard was written to look the
other way.

Chains for static files are resolved at `listen()` now, beside the routes'.
**Per file, not per set** — and that is the part worth remembering. A set has
one URL prefix, so one chain for the whole set looks obviously sufficient; it
is not, because a middleware can be scoped *below* the prefix:

```zig
app.static("/assets", "public");
app.useOn("/assets/private", auth);
```

One chain per set would be the chain for `/assets`, and that `auth` would
never run. The failure is silent and it fails open. Per file costs a slice per
file at startup, on files already held in memory, and has no such case.

The test now puts a global middleware and a scoped one in front of the asset,
and **counts that the middleware ran** — because zero allocations is also what
an empty chain looks like, and a test that cannot tell those apart would have
passed happily while the fix quietly dropped everybody's middleware. Reverted
against the old behaviour it reads `expected 0, found 1`.

What still costs one allocation is a 404 or a 405, and that stays: the set of
paths that are neither a route nor a file is every string there is, so there is
nothing to precompute for.

## The three gaps that were nobody's decision

Everything absent from 0.1.0 had a reason written down — TLS is refused, broadcast waits on zio, response compression has a design nobody has had yet. Three things had no reason at all. They were simply missing, and the review that found them found them the way anybody would: by asking what somebody coming from Express does in their first ten minutes.

**Cookies.** Not sessions — cookies. `c.header("Cookie")` and split `a=1; b=2` yourself. `docs/guide/middleware.md` had been writing "behind a cookie" in an example for weeks, so the concept was acknowledged and the tool was not there.

**Form bodies.** A struct argument meant JSON. `<form method="post">` sends urlencoded, and multipart once it has a file, and neither reached a handler.

**Redirects.** Possible as `Status(302, void)` with a `Location` header, which is three lines for a one-line idea and invisible to the generated document.

Three ADRs came out of it — [0030](./adr/0030-a-cookie-is-a-header-and-set-cookie-is-the-one-that-repeats.md), [0031](./adr/0031-a-form-is-the-body-read-by-another-rule.md), [0032](./adr/0032-a-redirect-puts-its-status-in-the-type.md) — and what follows is the part that was not obvious in advance.

### The bug that would have had no symptom

`Ctx.setHeader` replaces. Setting `Vary` twice is somebody changing their mind, and sending both would be untidy at best. That rule is right for every response header there is, except one.

RFC 6265 §3 says a server sending two cookies sends two `Set-Cookie` lines, and — unlike every other repeatable field — that they may **not** be folded into one comma-separated value. (A cookie's `Expires` attribute contains a comma. That is how it ended up being true.)

Applied unchanged, the replace rule would have meant a handler setting a session cookie and a preference cookie delivered only the preference. No error, no log line, no failing test unless somebody wrote one that set two. `http1.repeats` is a list of one entry and it is a function rather than an inline `eqlIgnoreCase` precisely because a list of one that is really a rule needs somewhere to say why.

### The thing that is refused rather than escaped

```zig
try c.setCookie(.{ .name = "session", .value = "abc; Path=/admin" });
```

That is not a malformed cookie. It is a cookie **with a path nobody wrote**, because `;` separates attributes and RFC 6265's grammar has no escaping to defend with. A `\r\n` in the same position is response splitting outright.

There is nothing to encode it as, so it is refused before anything is allocated — a 500 naming the character and saying to encode the value first. A 500 and not a 400: the request did nothing wrong. Base64 and hex, which is what a session token actually is, pass untouched.

### Two rules that made the form parser one function shorter each

`Query(T)` and `Form(T)` convert their fields the same way and must say the same thing when the text does not fit. That was going to be two copies of `convert`, so it is now `convert.zig` — one module, used by path params, query values and form fields alike. `"age" has to be a whole number, not "soon"` is the sentence a bad `?age=` has always produced, and now a bad form field produces it too because it is the same line of code.

The other rule is that **a form is the body.** `Form(T)` sits exactly where a plain struct argument would have read JSON, so asking for both is a compile error with its own message — the two-bodies advice ("make one a pointer, so it is a service") is wrong here, because one of the two genuinely has to go.

### What the multipart parser is careful about, and why each is silent

Three, and none of them fails loudly when got wrong:

- **The boundary is matched at the start of a line only.** A boundary string occurring inside a file is data. An `indexOf` that did not check would truncate the upload there, and only for files that happened to contain it.
- **The line break in front of the boundary is framing.** A byte too many or too few corrupts every file that goes through. A text upload would look fine.
- **A part with a `filename` is a file even when it is empty.** That is a browser saying "the field was there and nothing was chosen". Reading it as a text field puts an empty string where a handler expected an `Upload`.

Each has a test named after the mistake rather than after the feature. The one that pins the file's bytes to the body's own address is there because "it works" and "it does not memcpy a 900 KB upload" look identical from outside.

The part count is capped at 256. The arrays are sized from a count of boundaries in the body, and without a cap a megabyte of nothing but boundaries — about 15,000 of them under the default `max_body` — is half a megabyte of arena for a request carrying no data at all. That is the client choosing how much memory to spend, which is the shape of every limit in this project.

### The compile error that is really documentation

`Redirect(200)` stops compilation, and the message lists the five statuses that carry a `Location` with what each is for. That sentence is the whole reason `Redirect` is worth more than a header helper:

> 303 (see other — what a form POST answers with, so the reload does not post again)

**303 after a POST is the one people get wrong**, and getting it wrong means a browser's reload button submits the form a second time. Putting it in the compile error puts it where somebody is already reading, which is [ADR 0027](./adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)'s argument applied to a thing that is not a mistake in zfast's own terms at all.

### What it cost

Reading a cookie allocates **nothing**, and there is a test that says so: a request carrying four cookies through a route that reads one, counted through the same `budget.Counting` the primary metric uses. That is the header being walked where it lies, the same as `c.header` — a map built on the way in would have been an allocation on every request that carries cookies to save a scan on the few that read two.

Setting one costs **one arena allocation**, sized by `cookie.lengthOf` before it is written. A test holds the length function and the writer together, because a length that disagreed with what gets written is either a buffer overrun or a truncated cookie, and both are the kind of thing that works until it does not.

A form costs what `c.json` costs and for the same reason — the body is read whole, bounded by `max_body`. Nothing inside it is copied: every name, filename and file is a slice of the body already in the arena.

Seven new refusals, bringing it to 46. `examples/forms` is the seventh example and the first one that is a web page rather than an API.

### The measurement that had quietly stopped being true

Counting the refusals meant touching the sentence next to the count, which said they cache on Zig 0.16 and cost 0.5s. They do not, and they never did.

Measured warm on this machine: 46 refusals are ~12.8s of a ~17s `zig build test`, at about 270ms each. Re-run against a clean checkout of the commit that made the claim, the 39 that existed then are 10.6s — not 0.5s. The original entry, "about 9 seconds", was right the whole time and had been struck through in favour of a number nobody checked.

The lesson is not about caching. That correction sits four paragraphs below this file's own line about a number not being a finding until you know what is in it, which makes it the mistake it warns about committed in the same breath. **A number saying a cost went away on its own deserves more scrutiny than one saying work made something faster**, not less — there is nobody to argue with it. [ADR 0027](./adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md) carries the corrected figure and keeps the wrong one visible.

## The rule that only ever passed, and the stopwatch that came out of it

Three separate times, a guard turned out not to be guarding anything, and each time somebody found it by accident: the suite whose green runs were not evidence, the allocation budget test written to look the other way, and the build-time number that improved on its own. All three are written up above. Putting them side by side is the only reason the shape is visible — separately each read as bad luck.

The shape: **each had only ever been observed passing.** A check that has only been seen to pass and a check that cannot fail look identical from the outside, because passing is the default state of both. [ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) makes watching it fail part of shipping it.

Writing that ADR immediately produced a fourth instance of the thing it describes. The first draft listed four incidents, of which two were the same one — `history.md` writes the budget test up under a heading about "the third guard", which from memory sounds like a separate event — and the description of the first said the suite "passed with the implementation deleted", which is not what happened and is written down nowhere. Both were caught by opening `history.md` and reading it rather than remembering it. The ADR keeps the account of its own draft, because an entry about only ever having observed something passing, drafted from memory of the observation, is the cheapest available demonstration that this is not about being careless.

### The rule with no guard at all

[ADR 0014](./adr/0014-handlers-must-not-block-the-thread.md) had said it outright: *"Nothing forces it. A handler calling the driver directly still compiles and still passes its tests."* It had also considered detection and rejected it in one line — Zig has no effect system, so there is nothing to detect with at compile time.

That is true, and it answers the wrong question. "Can the compiler prove this function blocks" is no. "Can the server notice that one just did" is yes, with a stopwatch, and nobody had asked.

It matters more than the ADR's wording suggests, because this bug is invisible in development *because* there is no load. One `curl` against a handler that queries a database synchronously returns the right answer at the right speed and looks correct in every way a person can check by looking. It needs a second request to exist at all, and the second request normally turns up in production.

`src/watchdog.zig` measures elapsed time minus time the fiber spent parked. Parked time is not guessed at — `zfast.blocking`, `zfast.sleep`, `zfast.Mutex.lock`, `bulkhead.randomSecure`, reading the body and writing the response each report their own wait. What is left is the handler running, and a quarter of a second of it without one yield gets a line in the log naming the route.

### What the measurement cost, and the trap inside it

The first working version cost **116ns of a 612ns request — 19%**, twice [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s budget. Four clock reads per request, at 27ns each, because `CLOCK_MONOTONIC` does the full timekeeping arithmetic every time.

`CLOCK_MONOTONIC_COARSE` costs 5ns and only moves once a millisecond, which against a quarter-second threshold is not a compromise at all. But reached through `std.os.linux.clock_gettime` it costs **571ns**, not 5ns, because zfast links libc and that path skips the vDSO. The first attempt at the optimisation was a hundred times slower than the thing it replaced and looked identical on the page — it showed up only because the profile went from 728ns to 3040ns and there was no story that fit.

The other half of the 116ns was not the clock at all. It was `fail.inFlight()`, which finds the request through the fiber slot, called twice on the response-write path. The `Ctx` carries the pointer now.

**610ns before, 668ns after: 58ns, 9.5%.** Inside the budget and not comfortably. Six runs of each, interleaved, the before taken from a `git worktree` at the parent commit rather than by stashing — which turned out to matter, because uninterleaved passes on this same machine read 612 against 728 half an hour apart and 681 against 673 ten minutes later. The second pair would have been quoted as "under the noise" and would have been wrong.

### What it looks like against a real server

Two handlers on two executor threads, both waiting 600ms, one holding the thread and one going through `zfast.blocking`. From the client they are three milliseconds apart — 0.6007s against 0.6034s — and nothing in either response tells them apart. That is the bug in one line: with one request, the wrong version is indistinguishable from the right one.

With four in flight and one trivial request behind them:

```
/quick behind 4x /slow      1.654528s
/quick behind 4x /proper    0.002606s
```

Six hundred times, paid by a request that had nothing to wait for. [ADR 0014](./adr/0014-handlers-must-not-block-the-thread.md) measured the first half of this and got 1.701s; what it never had was the second column. The single `curl` at `/slow` produced the warning on its own, and nothing was ever said about `/proper`.

### Seven tests, three of which exist to prove it stays quiet

Which is [ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) applied to the first thing built after it. A handler that busy-waits 30ms is caught; the same wait through `zfast.blocking` is not; a stream is not; a server with `block_warning_ms = 0` is not. Half of a detector's job is not firing — one that cries wolf gets switched off, and then it is worth less than nothing, because its absence looks exactly like its silence.

They cost about 150ms of wall clock to prove something about wall clock. Paid rather than skipped.
