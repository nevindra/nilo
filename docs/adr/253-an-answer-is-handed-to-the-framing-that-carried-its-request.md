# An answer is handed to the framing that carried its request

**Status:** accepted
**Topic:** [framing](../design/framing.md)
**Applies:** [ADR 220](./220-grpc-is-served-over-h2c-behind-a-flag.md) (the HTTP/2 connection whose calls the second arm is for; its translation is unchanged here), [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) (where a connection parks is what it costs), [ADR 201](./201-a-response-is-flushed-before-the-connection-waits.md) (`settle`), [ADR 009](./009-static-files-are-held-in-memory-or-opened.md) (a file sent from disk, zero-copy where the connection allows)

## Context

`Ctx` wrote HTTP/1.1 itself. Eleven places in four files (`Ctx.send`, a copy of it in `serve.zig`, `sendfile.writeBody`, two streamed heads, the stream's pieces and its end, the abandoned stream's terminator, `100 Continue`, the 101) called `http1.write*` with a status line, `Connection`, chunking and `settle` in their hands. That was right while HTTP/1.1 was the only framing. It stopped being right with [ADR 220](./220-grpc-is-served-over-h2c-behind-a-flag.md): a gRPC call reaches the App as HTTP/1.1 text, its answer is written as HTTP/1.1 into memory, and `grpc.zig` parses that answer back to frame it. The translation was the right way to ship unary gRPC, and it is the wrong foundation for what the roadmap's first direction asks for next: trailers a route sets, an HTTP/2 stream, HTTP/2 for an ordinary route. Each of those needs `Ctx` to say what the answer is and something else to say what bytes it is.

The inventory (every site, file and line, read at `6a914dd`) found the write side small and closed, and the read side the opposite: `Ctx` reads a header by scanning the raw head when asked, which is what keeps a request at one allocation, so a neutral list of fields would cost the HTTP/1.1 path the thing the hard axis protects.

## Decision

**`Ctx` hands every answer to `Ctx._framing`, a `Framing` in `http/framing.zig`, and nothing above that file writes a protocol's bytes.** `Ctx` decides the status, the content type, the headers middleware and the handler set, the body (whole, streamed or a file) and whether the connection carries another request; the framing decides the status line, `Date`, `Connection`, a length or chunks, `settle`, zero-copy and `100 Continue`.

- **A tagged union, `union(enum) { http1: Http1, http2: ... }`, not a `Ctx` generic over its transport.** A generic `Ctx` would compile every handler once per framing and spend the size axis; the union costs one compare of a tag a write, which never mispredicts on a connection that has one arm.
- **The HTTP/2 arm exists only under `-Dgrpc`.** Without the flag its type is `noreturn`, the tag is known while compiling, `Framing` is the size of `Http1`, and the default build pays not even the compare.
- **The HTTP/1.1 arm writes exactly the bytes `http1.zig` wrote before**, so `behaviour.zig` and `testing.Client`, which read raw HTTP/1.1 back, are its regression net and needed no change.
- **The HTTP/2 arm collects an answer whole** (`Collected`: status, content type, headers, body) and copies it into the arena, because a call's answer is framed by the connection's fiber after the call's has returned (ADR 220). A stream, a file and an interim answer are refused there by name (`error.NotCollected`) until the roadmap's second direction gives them a pipe with the client's window in it. Nothing constructs this arm yet: stage 2 of [the framing page](../design/framing.md#how-the-direction-is-built) is what moves `grpc.zig` onto it.
- **A WebSocket and an event stream handed to the connection loop are HTTP/1.1 only.** `Framing.wire` gives them the connection's reader and writer and is null on a framing with none of one request's own; on HTTP/2 a handshake is a 400 that says so. WebSockets over HTTP/2 (RFC 8441) are not served.
- **The request head stays a field block.** The HTTP/1.1 parser's facts about framing (`minor_version`, `keep_alive`, `chunked`) are read by the arm, not by `Ctx`, except where `Ctx` still reads them for the request body, which the read half of the direction (stage 3) moves.
- **`Ctx.send` and the answers App makes itself end in one function**, `Ctx.writeWhole`, where `serve.sendDirect` had been a second copy of the write.

## What it costs

Measured against `6a914dd` built the same afternoon, default and `-Dgrpc`, in [`bench/result/http.md`](../../bench/result/http.md#an-answer-handed-to-the-framing):

- **Allocations per request:** unchanged. The four budget tests pass as they were. `Collected` will allocate on an HTTP/2 call once stage 2 constructs it, and stage 2 measures that against the text it replaces.
- **Memory per idle connection:** unchanged to the byte, 5,190 B marginal at 10,000 connections in the default build and 5,197 B with `-Dgrpc`, before and after. `Ctx` grew by its arm (the reader, the writer and the version, with a tag under `-Dgrpc`), and `Ctx` lives in `serveRequest`'s frame, which is `noinline` and unwound before a connection parks.
- **Throughput and p99:** inside the spread end to end, 1.48 M requests a second against 1.49 M with a spread of 17% across rounds, p99 60 to 70 µs on both sides. In process the default build's routed GET is about 20 ns slower (394 to 406 ns against 418 to 426); the build that pays the compare is not, and a row the change cannot reach (`json.zig` serialising the body) moved by half of it, so it is placement and not the dispatch.
- **Binary size:** 400 bytes smaller in the default build (`serve.sendDirect`'s copy of the write gone), 832 bytes larger with `-Dgrpc` (`Collected`), stripped `ReleaseFast` `nilo-hello`.

## What was rejected

**A `Ctx` generic over its framing (`Ctx(comptime F: type)`).** No dispatch at all, and every handler, middleware and typed wrapper compiled once per framing, which is the size axis spent for a compare the measurement could not find.

**A function pointer or a vtable for the framing.** It puts an indirect call on every write and takes away the inlining a direct call to the HTTP/1.1 arm keeps, for a set of framings that is closed and known while compiling.

**A neutral list of request fields, filled by both framings.** Clean on paper, and it costs the HTTP/1.1 path a list on the stack or an allocation where it now scans only the headers a handler asks for, which is most often none. The field block is the cheaper representation of the same thing.

**Both arms always compiled.** The default build would pay a byte of tag in every `Ctx` and a compare on every write for an arm it can never construct.

**Building the HTTP/2 arm and moving `grpc.zig` onto it in the same change.** The seam is the go or no-go and was measured alone, so that what it costs the HTTP/1.1 path is a number and not part of a larger one.
