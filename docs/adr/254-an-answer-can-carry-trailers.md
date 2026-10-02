# An answer can carry trailers, and gRPC answers from what it collected

**Status:** accepted
**Topic:** [framing](../design/framing.md)
**Extends:** [ADR 220](./220-grpc-is-served-over-h2c-behind-a-flag.md) (a call's answer is read from the collected arm, `grpc-status` is a trailer, and its code comes from the error first; revised there in place), [ADR 253](./253-an-answer-is-handed-to-the-framing-that-carried-its-request.md) (the HTTP/2 arm is constructed now, and a framing is told about a failure and about trailers), [ADR 008](./008-middleware-is-an-onion-of-ctx-functions.md) (a trailer set after `next` needs `next.hold(c)`, decided there)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 246](./246-the-headers-a-browser-reads-as-policy-are-one-block.md) (code reached through a pointer only a caller sets, so the linker drops it for everybody else), [ADR 155](./155-a-request-answered-once-is-answered-the-same-way-again.md) (an answer kept to send again, trailers included)

## Context

A trailer is a field sent after the body: what a server knows only once the body is written, a checksum, a count, how long it took, or, for gRPC, the call's status. nilo had none. A route could set `grpc-status` with `c.setHeader`, and it worked only because `grpc.zig` parsed the App's HTTP/1.1 answer back out of memory and moved that header into HTTP/2 trailers ([ADR 220](./220-grpc-is-served-over-h2c-behind-a-flag.md)). On HTTP/1.1 the same line was an ordinary header, so code that meant one thing on one framing meant another on the other.

That parse was also where gRPC lost the error. A route that failed with `error.AlreadyExists` from `nilo_sql` reached the client as a 409, and the status table read a 409 as `ABORTED`; a client told `ABORTED` retries a call whose row already exists. A rolled-back transaction arrived as a 503 and left as `UNAVAILABLE`, where `ABORTED` is the code that means it.

Stage 1 ([ADR 253](./253-an-answer-is-handed-to-the-framing-that-carried-its-request.md)) built the collecting arm and left it unconstructed. This is stage 2 of [the framing page](../design/framing.md#how-the-direction-is-built).

**How others do it.** Go's `net/http` asks for a trailer's name to be declared in a `Trailer` header before the body, or a magic `Trailer:` prefix on a header set after; a trailer set without either is lost without a word. Axum and hyper put trailers on the body type, so a route returning a plain body has nowhere to set one. ASP.NET Core has `AppendTrailer` with `SupportsTrailers()` to ask first, and drops one on HTTP/1.1 without chunking. Node sets them on the response with `addTrailers` and writes them only on a chunked answer. None refuses a trailer that RFC 9110 says a recipient must not act on.

## Decision

**`c.setTrailer(name, value)` is one list on `Ctx`, settable until the body ends, on every framing alike, and each framing delivers it the way it can.**

- **Settable until the body ends**: before `send` for a whole answer, before `finish` for a stream, and after `next` only from a middleware that called `next.hold(c)` ([ADR 008](./008-middleware-is-an-onion-of-ctx-functions.md)). After that it is refused with a sentence naming where it should have been set. The same name set twice keeps the last, as a header does. Copied into the request arena.
- **Delivered:** on HTTP/2, a HEADERS frame after the body. On an HTTP/1.1 chunked stream, a trailer section after the last chunk. On a whole HTTP/1.1 answer, chunked so it can carry one **only when the request said `TE: trailers`**, was HTTP/1.1 and not 1.0, was not a `HEAD`, and the status has a body; otherwise it is left off, which RFC 9110 §6.5.1 allows and which is all a client that never asked could have read. A stream framed by its length or by the connection closing has nowhere to put one and leaves it off.
- **Refused where it is set**: a name RFC 9110 §6.5.1 says a recipient must not process as a trailer (framing and the connection, routing and request modifiers, authentication and cookies, response controls, the content's type, encoding and range) and a pseudo-header, plus anything `setHeader` refuses for its bytes. `http1.barredFromTrailer` is the list, one name a line.
- **A route that sets none pays nothing**: the list is empty, the check is whether it is, and the HTTP/1.1 writers that know how to chunk a whole answer and end a stream with a trailer section are reached through a pointer the first `setTrailer` sets. A program that never calls it links neither, the move [ADR 246](./246-the-headers-a-browser-reads-as-policy-are-one-block.md) made for `nilo.secure`'s block.
- **The typed layer has it too**: `nilo.Response(T)` and `nilo.Status(code)` take `.trailers`, beside `.headers`. An idempotency or cache record keeps a trailer as a field whose name starts with `:`, which no header name can, so a record written before this change reads the same.

**`grpc-status` and `grpc-message` are trailers and nothing else.** `c.setHeader("grpc-status", …)` is refused with a sentence pointing at `setTrailer`, which was how a route set its own status until now. One way, the same on both framings.

**gRPC answers from the collected arm.** `serveRequest` takes a `framing.Sink`, the connection's writer or a `framing.Collected`, and a call's answer is collected there: status, content type, headers, body, trailers, and, when it failed, the error and the sentence it carried (`Framing.failed`). `grpc.zig`'s `parseResponse`, `unchunk` and `framedIn` are gone. The body is collected with five bytes of room in front of it, so the gRPC length prefix is written there and the message is framed without a second copy; the body and the content type are one allocation.

**A failed call's code comes from the error first, and from the status only when the error says nothing.** `error.AlreadyExists` is `ALREADY_EXISTS` (6) and `error.RolledBack` is `ABORTED` (10), where both used to be whatever 409 meant. A code the route set as a trailer still wins, and a deadline that passed still makes `DEADLINE_EXCEEDED`.

**`App.grpcHost` is a compile error in a build without `-Dgrpc`.** The collecting arm is `noreturn` there, so reaching it would be undefined behaviour in ReleaseFast; the profile did reach it, and crashed, before the refusal was written.

## What it costs

Measured against `372b766` built the same afternoon, default and `-Dgrpc`, in [`bench/result/http.md`](../../bench/result/http.md#trailers-a-held-answer-and-grpc-answered-from-what-it-collected). The figures are for this change and the hold of ADR 008 together, because they ship as one.

- **Allocations per request:** unchanged for a route that sets no trailer and does not hold; the budget test passes as it was. A trailer is two copies into the arena when set. A gRPC call: 4, 10 and 8 arena allocations on the suite's three services against 4, 9 and 8, and 495, 697 and 824 bytes against 615, 978 and 1,082. The one more is `Meta/Who` copying the headers it sets, which the old path paid inside a larger text.
- **Memory per idle connection:** unchanged, 5,165 to 5,182 B marginal at 1,000 to 10,000 connections in both builds.
- **Throughput and p99:** in the default build 1,611 k requests a second against 1,633 k, −1.3% and in every round, p99 59.5 µs on both; with `-Dgrpc` 1,608 k against 1,610 k. In process a unary gRPC call is 902 to 910 ns against 1,083 to 1,118, −17%. The first cut cost a routed GET in a `-Dgrpc` build 18%, because the collecting code inlined into `Framing.whole`; `Collected.whole` and `head` are `noinline` for that, and the GET is 411 ns against 392 to 395.
- **Binary size:** +3,696 bytes in the default build and −47,008 with `-Dgrpc`, stripped `ReleaseFast` `nilo-hello`. The trailer writers behind a pointer took 2,656 bytes out of the first cut.

## What was rejected

**`grpc-status` set as a header, kept working beside the trailer.** Two ways to say one thing, one of which means a different thing on HTTP/1.1. Refused, with a `CHANGELOG.md` line for the route that set it that way.

**A trailer that must be declared before the body, as Go asks.** It makes the route say a name twice and loses the trailer without a word when it forgets; nilo knows the list when it writes the head of a whole answer, and a stream's `Trailer` header would promise what a route may not set after all.

**Always chunking a whole HTTP/1.1 answer that carries a trailer.** A client that did not send `TE: trailers` may not read a trailer section at all (RFC 9110 §6.5.1), and the answer would lose its `Content-Length` for nothing.

**Trailers on the body type, as hyper does.** A route returning a plain value would have nowhere to set one, and a middleware none at all.

**The gRPC code from the status alone, with a finer status table.** A status already means something of its own: a 409 is a conflict the client may retry and a 503 a server that is down, and neither is what a duplicate row or a rolled-back transaction tells a gRPC client. The error is the only thing that knows.

**An unreachable arm left in a build without `-Dgrpc`.** It compiled, and in ReleaseFast it was undefined behaviour the profile reached; a refusal costs nothing and says which flag.
