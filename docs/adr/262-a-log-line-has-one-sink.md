# A log line has one sink, and its format and level are set when the program starts

**Status:** accepted
**Topic:** [middleware](../design/middleware.md)
**Extends:** [ADR 008](./008-middleware-is-an-onion-of-ctx-functions.md) (the logger middleware), [ADR 088](./088-an-origin-is-a-fact-about-the-deployment.md) (a deployment fact is read at run time)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md), [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md), [ADR 006](./006-failure-box-bound-to-the-fiber.md)

## Context

`logger` built a line and handed it to `std.log`, and Zig 0.17's default `logFn` puts `info: ` in front of every line. So `.format = .json` reached stderr as `info: {"method":...}`, which a collector does not parse. Nothing in the repository set a `logFn`, and a library cannot: it is a declaration of the program's root. Three more gaps sat beside it. A handler's `std.log.warn` carried no request id, so the line that said why a request was slow could not be joined to the access line that said it was. No path could be left out of the access log, and a load balancer's health check is one line a second. And the logger's format and level were comptime options, so the same binary could not log text on a laptop and JSON under a collector, the situation ADR 088 resolved for CORS origins.

## Decision

**`nilo.logFn` is the sink, and `nilo.std_options` installs it.** A program that wrote `pub const std_options = nilo.std_options;` (the line `listen()` already asks for) gets it with no change; one with its own options adds `.logFn = nilo.logFn`. It writes exactly one line per call, with no allocation: two static buffers (1 KiB for the message, 1.5 KiB for the line) used while the stderr lock std's default takes is held, which is what makes sharing them safe, then one write. A message that does not fit is cut at a character boundary, and a JSON line is cut inside its `msg` and still closed, so a truncated line is still an object.

- **text:** `2026-10-09T12:00:00.123Z warn(scope) message request=ab12`. The scope is left off for `.default`, the request off outside a request.
- **json:** `{"time":"…","level":"warn","scope":"…","msg":"…","request":"…"}`, the message escaped (bytes that are not UTF-8 become U+FFFD, as in the access line's path), `scope` and `request` left out when there are none.

**The request id comes from the fiber slot.** `fail.InFlight`, which `bulkhead.slot()` points at, gains a pointer to the Ctx in flight and the function that reads its id. `serve.serveRequest` sets them once the Ctx exists and clears them on every way out, and HTTP/2 calls go through the same function, so a handler's line carries its id on both framings. The id is read only when a line is written, after the level has let it through: a request that logs nothing makes no id and does no work.

**The access line is flat.** `logger` sends its object under the scope `nilo_access` when `logFn` is installed, and the sink splices `time` and `level` in front of its fields, so JSON is one object, never an object held in a string. In text the scope is left off and the line reads as it always has, with a time and level in front. Without the sink (`log.installed` is a comptime fact) it goes out under `.default` as before.

**Format and level are `listen(.{ .log = .{ .format = .text | .json, .level = … } })`.** Read once at `listen()` into two atomics, so a deployment sets them from `nilo_config`. `std_options.log_level` stays the comptime ceiling: a call below it is compiled out and costs nothing; the run-time level filters inside it, and is null by default, meaning the program's own `std_options.log_level`, so a program that sets nothing logs what it logged and the floor is never above the comptime one. The floor filters the access line only when `nilo.logFn` is installed: behind std's default there is no floor but the comptime one. The logger's `.format` option is gone. Its `.level` stays: which level a line *is* (and `slow_micros` raising it to `.warn`) is a fact about the code, whether that level is written at all is the process's.

**`logger.with(.{ .skip = &.{ "/healthz" } })`** never logs a request whose path equals one of the literals. The compare is unrolled at compile time, so an empty list costs nothing; a skipped request is still answered, its `X-Request-Id` still set, and its error still passed along.

**`listen()` warns once at startup** when the format is `.json` and the root's `std_options.logFn` is not `nilo.logFn`, with the line to add (`wiring.checkRootWiring`, beside the two warnings it already makes).

**A log call made while another is being written does not touch the first one's buffers.** The statics belong to the call holding the lock, and the lock is recursive on a thread, so a `format` method that logs, or a panic handler, would otherwise overwrite the line in progress. A per-thread depth marks it, and the nested call formats into its own small stack buffers (256 bytes of message), written before the outer line. A fiber parked inside the write leaves the mark raised for another on its thread, which then takes the small path: a shorter line, never a torn one.

## The four axes

- **Allocations per request:** none added; the allocation-budget test holds. The id is made on demand.
- **Memory per idle connection:** unchanged, measured. `InFlight` is a local of `handleConnection`'s frame, live while the connection waits for its next request, so it may not grow. It gains two words (the Ctx and one reader function) and loses the method and path slices the panic handler used, which are now read from the Ctx: 16 bytes smaller. `bench/mem.py` on `example-hello` (ReleaseFast, 200 and 1000 connections) reads 5,325 B and 4,805 B a connection before and after, and `park-check` holds. **The sink keeps no buffer on the stack**: a suspended fiber keeps its stack at its high-water mark (ADR 062), and 2.5 KiB of buffers would have been held by every connection whose handler logged once. They are statics taken under the lock; the frames left are `formatAndEmit` (72 to 120 bytes) and `emit` (120 bytes, `render` inlined), read from the ReleaseFast binary, plus `std.fmt`'s own frames for the caller's message, which std's default pays too. `example-hello` with the access logger on (so every request logs) reads 4,997 B and 4,739 B a connection at 200 and 1000 connections, against 5,325 B and 4,805 B before the change.
- **Throughput and p99:** a request that logs nothing adds two stores and a store on the way out. An access line adds one atomic load for the level and one for the format.
- **Binary size:** smaller than before the sink. `example-hello`, ReleaseFast, `strip`ped, goes from 1,144,160 bytes at fe51c44 to 1,075,856 (-68,304), because the sink replaces std's `defaultLog` and its terminal-colour machinery. The first version, which did its formatting inside the generic `logFn`, was 1,185,904 (+41,744): everything in a generic body is instantiated once per `std.log` call site. `logFn` now only formats the caller's message into a stack buffer, as std's default does, and hands the bytes to two `noinline` non-generic functions (`emit`, `write`) that hold the time, level, scope, id lookup, escaping, UTF-8 repair and the lock. To be added to the running total in ADR 017.

## What was rejected

- **A logger that writes to stderr itself.** It would fix JSON for the access line alone and leave every handler's line in std's shape, which is the same problem one level down.
- **Making the process format a comptime option of `std_options`.** The format is a fact of the deployment, not of the build (ADR 088).
- **A request id stored on every `std.log` call by the caller.** A handler would have to pass it, and the point is that code which does not know it is in a request still gets the id.
- **An object-as-string for the access line in JSON.** What the logger did before the sink existed to flatten it; it makes a collector parse twice.
