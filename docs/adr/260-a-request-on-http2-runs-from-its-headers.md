# A request on HTTP/2 runs from its headers, and its body and its answer are pipes

**Status:** accepted
**Topic:** [framing](../design/framing.md)
**Extends:** [ADR 220](./220-grpc-is-served-over-h2c-behind-a-flag.md) (a call runs before its message is whole, and its budget is held by the call's reads), [ADR 253](./253-an-answer-is-handed-to-the-framing-that-carried-its-request.md) (the `.http2` arm streams), [ADR 227](./227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md) (an event stream handed over holds no fiber on HTTP/2 either), [ADR 019](./019-a-request-that-lasts-is-still-one-request.md) (a stream and a body stream on every framing)
**Applies:** [ADR 259](./259-http2-is-a-framing-of-every-request.md), [ADR 017](./017-the-trade-budget-has-four-axes.md), [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)

## Context

The HTTP/2 connection collects a call whole before it runs it and collects its answer whole before it frames it (ADR 220, ADR 253). That was the right shortcut for a unary gRPC call and is wrong for everything else a request does. On HTTP/1.1 a handler runs as soon as the head is read: `c.bodyStream()` reads an upload of 64 MiB through a buffer of the handler's, `Expect: 100-continue` is answered when the handler first reads, `c.stream()` writes a CSV of any length in pieces, `c.sendFile` sends a file, and an event stream runs for an hour. On HTTP/2 each of those is refused (ADR 259), and once a browser reaches HTTP/2 a route that worked would stop working because the framing changed under it. That is the opposite of what the direction is for.

Both halves have one shape: bytes passed between the call's fiber and the connection's fiber, with the client's flow-control window in between. The connection's fiber is the only one that touches the socket (ADR 220), so a call never waits on the socket; it waits on the connection.

## Decision

**A request on HTTP/2 runs when its header block is whole**, gRPC calls included, as an HTTP/1.1 request runs when its head is read. A `GET` whose HEADERS carry END_STREAM is unchanged. What the client sends after the headers reaches the handler through the **inbound pipe**, and what the handler sends goes out through the **outbound pipe**.

**The inbound pipe is the request's reader.** The connection appends a stream's `DATA` to that stream's buffer, as it does now, and the call reads from it through a `std.Io.Reader`, waiting on the connection when the buffer is empty and the stream has not ended. The body is framed by the transport: `http1.Request` gains a body kind for it that ends where the stream ends, and a `content-length` the client sent is held by the connection to what arrived (ADR 259). What the handler has read is given back: to the connection's budget, and to the client as a `WINDOW_UPDATE`, so a stream holds at most its window of unread bytes and a connection at most its budget (ADR 220), whatever the handlers do. So:

- `c.body()` reads to the end, held to `max_body` as on HTTP/1.1. A body that had arrived whole before it was asked for is handed over where it lies, in the stream's arena, which is the request's, and is not copied.
- `c.bodyStream()` reads it in pieces, held to its own `max_bytes` (ADR 019); the client sends no faster than the handler reads.
- `Expect: 100-continue` is answered with a `:status 100` HEADERS frame when the handler first reads a body that has not arrived, which is the moment HTTP/1.1 answers it.
- A gRPC call's message is read by the envelope through the pipe: the five-byte prefix, the one message, and a gzip message inflated on the call's fiber, charged to the connection's budget before the copy is made and waiting on the connection when there is no room, where it used to wait in the connection's `waiting` state.
- A client that stops sending a body is held to the bound a chunked HTTP/1.1 body is held to, on the call's read rather than on the connection.

**The outbound pipe is the `.http2` arm writing in pieces.** `streamHead` hands the connection a HEADERS frame, `piece` lends it the stream's buffer and waits until the bytes are in the connection's writer, and `end` sends END_STREAM with the trailers. No allocation per piece: the buffer is the one `c.stream` takes when it opens (ADR 019), lent for the length of the wait, and the connection writes the `DATA` frames straight out of it, as many as both windows allow. A client that stops reading holds the call in that wait until the write deadline resets the stream, and the call's next write fails, as it would on a dead HTTP/1.1 socket. So:

- `c.stream()`, `c.events()` and a streamed answer of any kind work on HTTP/2 as on HTTP/1.1, `live()` and the shutdown signal included.
- **A file is read into frames**, a buffer at a time through the same pipe. There is no `sendfile` on HTTP/2, because frame headers go between the pieces; over TLS, where a browser is, HTTP/1.1 has none either.
- A reset stream wakes its call with the error a closed socket gives.

**An event stream handed to the connection holds no fiber on HTTP/2 either** (ADR 227). The rooms ring the HTTP/2 connection's bell, and the connection writes what was posted to each handed-over stream as `DATA` when it wakes; the handler has returned. `RoomEvents` splits its loop into the step that writes what is posted, which both framings run, and the wait, which only HTTP/1.1's connection loop does.

**A WebSocket stays HTTP/1.1.** RFC 8441's extended CONNECT is not offered, so a browser opens an HTTP/1.1 connection for a WebSocket, which it does by itself, and `c.upgrade` on HTTP/2 is refused with a sentence saying so.

**What waits on what is the Bulkhead's.** A call waits on its connection through a primitive in `bulkhead.zig` built on the Engine's mutex and condition, because `spawnLocal` can place a call on another thread; nothing in `h2conn.zig` names zio (ADR 001).

**A gRPC stream's API is not decided here.** Server, client and bidirectional streaming are what the pipes make possible, and the shape a handler writes them in belongs to the roadmap's direction [a stream is one shape](../roadmap.md#a-stream-is-one-shape), which builds on these two pipes rather than beside them.

## What it costs

The budget each part is held to, replaced by what was measured when the stage lands:

- **A request that sends no body and answers whole**: the time and allocations it had under ADR 259.
- **A request with a small body**: at most one more wait than a collected one, measured on the message rows of `zig build profile`; `c.body()` on a body that arrived whole allocates nothing.
- **A stream**: no allocation per piece; its pieces per second over HTTP/2 against HTTP/1.1 on record.
- **A file over TLS**: its throughput over HTTP/2 against HTTP/1.1 on the same build.
- **A handed-over event stream on HTTP/2**: its idle figure per stream, against a fiber's, at 1,000 and 10,000 streams.
- **An upload through `bodyStream`**: what one connection holds at most, the budget and no more, while a client sends faster than the handler reads.

## What was rejected

**Running a request when its body is whole, and streaming only for routes that say so.** Two paths, a declaration a route has to remember, and a `bodyStream` that silently became "the body, held to `max_body`" on one framing. The rule that a request runs from its head is HTTP/1.1's already.

**A copy of every piece into a buffer the connection owns.** An allocation or a ring per stream, held for as long as the stream lives, to save the call one wait it has to make anyway for flow control.

**Running a call on the connection's fiber when it is the only one.** The connection stops reading while it waits, and a `PING`, a `RST_STREAM` or a `WINDOW_UPDATE` goes unanswered for as long as the handler takes; flow control on a stream needs the other side reading.

**WebSockets over HTTP/2 (RFC 8441).** A browser falls back to HTTP/1.1 by itself, and a WebSocket handed to the connection holds no fiber there (ADR 062); on HTTP/2 each would need its own flow control on a stream for no saving a client can see.

**`sendfile` on HTTP/2 over plain TCP**, a header written and then the payload sent from the file per frame. Possible, and an optimisation for h2c without TLS, which is not where a static-heavy site meets browsers; it is in [`todo.md`](../todo.md) for the session that measures it.
