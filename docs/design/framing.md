# Framing

**A request is one thing whatever framing carried it: `Ctx` decides what the answer is, and the framing, HTTP/1.1 or HTTP/2, decides the bytes it leaves in.**

**Guide:** [Requests](../guide/requests.md) · **Reference:** [Ctx](../reference/ctx.md)

The code is `http/framing.zig` (the union and both arms), the eleven places in `ctx.zig`, `serve.zig`, `sendfile.zig` and `stream.zig` that hand an answer to it, and `http/grpc.zig`, the HTTP/2 connection whose calls it collects. This page is also where the roadmap's first direction, [a request is one thing whatever framing carried it](../roadmap.md#a-request-is-one-thing-whatever-framing-carried-it), is laid out stage by stage.

## Overview

```
                    HTTP/1.1 connection                       HTTP/2 connection (-Dgrpc)
                    serve.handleConnection                    grpc.Conn, one fiber a call
                            │                                          │
             head parsed in place, borrowed            call collected, its head written as a
             from the read buffer (ADR 201)            field block in the call's arena
                            │                                          │
                            └──────────────► Ctx ◄─────────────────────┘
                                   route, middleware, typed handler
                                              │
                         Ctx._framing: union(enum) { http1, http2 }
                            │                                          │
         status line, Date, Connection,              Collected: status, type, headers,
         Content-Length or chunks, settle,           body, trailers, the failure, copied
         sendfile, 100 Continue, the 101             into the call's arena for the
                                                     connection's fiber to frame
```

## Rules

1. **Nothing above `framing.zig` writes a protocol's bytes.** `Ctx` hands the framing a status, a content type, the headers middleware and the handler set, a body that is whole, streamed or a file, and whether the connection may carry another request; the arm decides the status line, `Connection`, chunking, `settle` and zero-copy. [ADR 253](../adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md)
2. **The framing is a tagged union, not a `Ctx` generic over its transport**, so every handler is compiled once and a write costs one compare of a tag. [ADR 253](../adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md)
3. **The HTTP/2 arm exists only in a build that asked for gRPC.** Without `-Dgrpc` its type is `noreturn`, the tag is known while compiling, and the default build pays not even the compare. [ADR 253](../adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md), [ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md)
4. **The HTTP/1.1 arm writes exactly the bytes `http1.zig` wrote before the seam**, so `behaviour.zig` and `testing.Client`, which read raw HTTP/1.1, are the regression net for it and are not changed by it. [ADR 253](../adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md)
5. **The HTTP/2 arm collects an answer whole**, with its trailers and the error it failed with, and copies it into the call's arena; every gRPC call is answered through it, because a call's answer is framed by the connection's fiber after the call's fiber has returned. A stream, a file and a `100 Continue` are not collected yet and are refused by name. [ADR 253](../adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md), [ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md)
6. **A WebSocket and an event stream handed to the connection loop are HTTP/1.1 only.** Both take the connection's reader and writer for the rest of their life, which `Framing.wire` gives them, and a multiplexed connection has none to give; on HTTP/2 the handshake is a 400 with a sentence, and WebSockets over HTTP/2 (RFC 8441) are not served. [ADR 253](../adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md), [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md)
7. **The request head stays a field block, not a list of fields.** `Ctx` reads a header by scanning the head when asked, which is what keeps a request at one allocation; an HTTP/2 call's fields reach it as such a block in the call's arena (today inside the HTTP/1.1 text stage 3 removes), rather than HTTP/1.1 paying for a list. [ADR 253](../adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md)
8. **A trailer is one list on `Ctx`, settable until the body ends, on every framing alike.** HTTP/2 sends it after the body; an HTTP/1.1 chunked stream as a trailer section; a whole HTTP/1.1 answer is chunked to carry it only when the request sent `TE: trailers`, and leaves it off otherwise. A name RFC 9110 §6.5.1 bars is refused where it is set, and a route that sets none pays nothing. [ADR 254](../adr/254-an-answer-can-carry-trailers.md)
9. **An answer is written when it is sent, unless a middleware holds it** with `next.hold(c)`, and then when the chain has unwound. A header set after the head was written is refused with a sentence naming `hold`. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
10. **A framing is told when an answer is a failure, and with which error.** HTTP/1.1 ignores it; gRPC picks its code from the error before the status, because a status alone cannot tell a duplicate row from a lost race. [ADR 254](../adr/254-an-answer-can-carry-trailers.md)

## How the direction is built

The roadmap's direction, in the order each stage depends on the one before it. A stage leaves this list when it lands; what it measured is in its ADR and in [`bench/result/http.md`](../../bench/result/http.md#an-answer-handed-to-the-framing).

1. **The answer goes through the framing.** The union, the HTTP/1.1 arm and the collecting HTTP/2 arm, with every write site moved onto it (ADR 253). Measured against the build before it on all four axes.
2. **gRPC reads its answer from the collected arm, a trailer is part of every answer, and a middleware can hold an answer.** `c.setTrailer`, `next.hold(c)`, a late header refused, and gRPC codes from the error (ADR 254, ADR 008). Measured against the build before it on all four axes ([`bench/result/http.md`](../../bench/result/http.md#trailers-a-held-answer-and-grpc-answered-from-what-it-collected)).
3. **An HTTP/2 call is handed to the App as a head, not as HTTP/1.1 text.** A second way into `serveRequest` that takes a parsed head and the field block, keeping every refusal `parseHead` makes that applies to HTTP/2. This removes the read half of the translation, the App's 229 ns of a 973 ns call.
4. **Codecs follow the content type, and a service is a struct.** The body door the todo list asks for, so a type with a `wire` table is read and written as `application/proto` by the typed layer; Connect's unary protocol over both framings; and `app.service(T)`, a struct of typed functions served as `/package.Service/Method`.
5. **One port, and HTTP/2 for ordinary routes.** h1 and h2c told apart by the first 24 bytes, and `h2` offered by ALPN on a `-Dtls` listener for every route. This revises [ADR 027](../adr/027-tls-is-terminated-in-front.md)'s refusal of HTTP/2 for browsers, and needs the idle figure of an HTTP/2 connection serving ordinary routes.
6. **Streams on HTTP/2**: a pipe from a call's fiber to the connection's, with the client's window in between, which lets the collecting arm stream. That stage belongs to the roadmap's second direction, [a stream is one shape](../roadmap.md#a-stream-is-one-shape).

## Decisions

| ADR | What it decides |
|---|---|
| [253](../adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md) | `Ctx` hands its answer to a framing, a tagged union whose HTTP/2 arm exists only under `-Dgrpc`, and what that costs the HTTP/1.1 path |
| [254](../adr/254-an-answer-can-carry-trailers.md) | An answer carries trailers on every framing; gRPC answers from the collected arm, with `grpc-status` a trailer and its code taken from the error first |
| [008](../adr/008-middleware-is-an-onion-of-ctx-functions.md) | A middleware changes an answer after `next` by holding it (`next.hold`), and a header set after the head is refused |

Related topics: [ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md) (topic grpc, no page of its own) is the HTTP/2 connection whose calls the second arm collects. [ADR 027](../adr/027-tls-is-terminated-in-front.md) and [`tls.md`](./tls.md) hold the refusal of HTTP/2 for browsers that stage 5 would revise. [`http1-protocol.md`](./http1-protocol.md) is the HTTP/1.1 arm's wire format, and [`engine.md`](./engine.md) the connection loops both arms sit on.

## Open questions

- **`Ctx.connection()` returns `http1.Connection`.** It is public and names an HTTP/1.1 header, which has no meaning on HTTP/2. `keepAlive()` says the same thing in neutral words; whether `connection()` leaves the public surface is a breaking change to decide before stage 5.
- **A file on HTTP/2 has no zero-copy.** It becomes reads into frames under the client's window, a second and slower path that a static-heavy server on HTTP/2 would notice; it needs its own number before stage 5 offers HTTP/2 to browsers.
- **An event stream handed to the connection loop does not fit a multiplexed connection.** On HTTP/2 it would keep a fiber per stream, a different memory figure that stage 6 has to measure.
