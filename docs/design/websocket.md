# WebSockets

**A WebSocket is an ordinary handler that does not return for a while, not a separate kind of thing.**

**Guide:** [WebSocket](../guide/websocket.md) · **Reference:** [`Socket`](../reference/streaming.md#socket), [`Room`](../reference/streaming.md#room)

The code is `http/websocket.zig` (the handshake, the frame reader, `Socket`), `core/ws_frame.zig` (the frame as bytes: header, masking, close payload, shared with the client in `nilo_fetch`), `http/room.zig` (broadcast), and `http/testing.zig` (`Conversation`, for driving one from a test).

## Overview

```
  app.get("/chat", chat) ──► c.upgrade(loop, state)
                                  │  101, keepAlive() = false from here
                                  ▼
                             loop(socket, state)         an ordinary function, never returns
                                  │
                    ┌─────────────┴──────────────┐
                    ▼                             ▼
            socket.receive()               room.say(kind, data)
            one message, or null            one alloc, refcounted, framed
            (close, EOF, reset,              once, posted to every seat's ring
             or the server stopping)
                    │                             │
                    └───────────────┬─────────────┘
                                     ▼
                a post for THIS seat is written out by THIS
                fiber, inside receive(), on its way past
```

A message that is complete and already in the connection's read buffer is unmasked and handed over right there. Nothing takes a buffer from `scratch.zig`'s free list until it has to (a fragmented message, one split across reads, or one bigger than the read buffer).

## Rules

1. **A WebSocket handler is a plain function**, taking services by type and registered with `app.get` like any route. `c.upgrade(loop, state)` is what keeps it running until the conversation ends. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md)
2. **The buffer `receive` fills is the only message size limit.** `Options.max_message` (16 KiB by default) closes a frame that claims to be bigger with a 1009, before any of its payload is read. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md)
3. **Ping, pong and the closing handshake are handled inside `receive`**, never passed to the handler. A handler calls `closedCleanly()` to find out whether the other side said goodbye properly. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md)
4. **A client that has simply gone is not an error.** `receive` returns `null` for a close frame, a FIN, a reset between two frames, or the server stopping (which sends a 1001 first). A reset or a failed read in the *middle* of a frame is still `error.ReadFailed`. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md), [ADR 202](../adr/202-a-reset-between-frames-is-a-client-that-has-gone.md)
5. **Sending on a socket that has already closed writes nothing instead of failing**, the same idea in the other direction. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md)
6. **An invalid goodbye is a framing error (1002) and is never echoed back**: a close payload of one byte, an unassigned close code, or a reason that is not UTF-8. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md), [ADR 046](../adr/046-a-message-is-copied-once-and-framed-once.md)
7. **A handshake with an `Origin` header is rejected with a 403 unless that origin is the request's own `Host` or one listed in the route's `Options.origins`.** Browsers apply no CORS to WebSockets, so if the server does not check, nobody does. A request with no `Origin` at all is allowed. [ADR 080](../adr/080-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md)
8. **`Options.idle_ms` (30 s by default) triggers a check, not a hard deadline.** After that much silence the server sends a ping; if the ping goes unanswered through another silence, it closes with 1001. `0` waits forever. Inside a frame it is a hard limit (twice `idle_ms` per read), because a ping cannot reach a client that stopped halfway through a frame. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md), [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md)
9. **A `Room` is a service like any other**, with `join`, `say` and `leave`, taken by type, and a socket can be in as many rooms as it joins. An event stream can sit in the same room as the sockets, and a room can keep its latest posts for a client that comes back ([ADR 229](../adr/229-a-room-that-keeps-history-catches-a-returning-stream-up.md), [ADR 227](../adr/227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md)). The sender never writes to another socket: `say` copies a pointer into each seat and signals it, and the fiber that already owns each connection writes that connection's post out as it passes through `receive`. [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md)
10. **A post is one reference-counted allocation**, freed by whichever seat reads it last, and framed once by the room instead of once per recipient. A broadcast costs what the room actually *holds* (via `roll`), never what it was sized for. [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md), [ADR 046](../adr/046-a-message-is-copied-once-and-framed-once.md)
11. **A full backlog drops posts instead of disconnecting**: `Full.drop_oldest` (the default) or `.drop_newest`. `room.missed(&socket)` reports how many were dropped, because the server never closes a connection just for being slow. [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md)
12. **`defer room.leave(&socket)` is always correct**: it is safe to call twice, safe on a socket that never joined, and it takes its two locks with `lockUncancelable`, so a cancellation during a broadcast cannot skip releasing the seat. [ADR 082](../adr/082-a-cleanup-path-is-not-cancellable.md)
13. **A `print` or `json` on a live socket is checked against what was actually written, and a Room's `print` and `json` drop the post with `error.WriteFailed` on a mismatch.** While the payload fits the write buffer, `Writer.end` gives the exact count, and a mismatch closes with 1011 instead of corrupting every frame that follows. [ADR 076](../adr/076-a-frame-that-lies-about-its-length-is-not-sent.md)
14. **A WebSocket route can be tested without a real socket.** `testing.Conversation` queues frames, runs the handshake and the loop, and returns what the server sent, decoded independently of nilo's encoder. It is scripted, not interactive, so a conversation between two live sockets still needs `http/live.zig`. [ADR 091](../adr/091-a-websocket-route-can-be-driven-from-a-test.md)
15. **A Room for a key is borrowed from a pool created up front.** `nilo.Rooms` creates `rooms` Rooms with `seats` seats each at `init`, lends one to a key on the first `join`, and takes it back when the last seat leaves. Saying something to a key with nobody in it allocates nothing. Every call that reaches a Room by key pins it, so it is never lent to a new key while the old one could still post to it. [ADR 228](../adr/228-a-room-for-a-key-is-lent-from-a-pool.md)
16. **The handshake and the wire are read as RFC 6455 writes them.** The `Sec-WebSocket-Protocol` answer is a protocol the client offered and the route speaks (`Options.protocol`, `Options.protocols`), or none; `Sec-WebSocket-Key` must be 16 bytes of base64 or the upgrade is a 400; `Connection` is a token list; a length in a wider form than it needs is a 1002; `ping` cuts its data to 125 bytes; and a room post and a direct `send` leave in the order they were made, because `send`, `print`, `json` and `close` write the connection's waiting posts first. [ADR 046](../adr/046-a-message-is-copied-once-and-framed-once.md)

## Decisions

| ADR | What it decides |
|---|---|
| [021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md) | A WebSocket is a handler; the buffer is the only size limit; a vanished client is `null`, not an error |
| [035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md) | `Room`: the sender never writes to another socket, posts are reference-counted, and the backlog policy |
| [046](../adr/046-a-message-is-copied-once-and-framed-once.md) | Copying and unmasking happen in one pass; a post is framed once by the room; an invalid goodbye is a framing error; the handshake negotiates its sub-protocol and checks its key; headers are read strictly; posts and direct sends keep their order |
| [076](../adr/076-a-frame-that-lies-about-its-length-is-not-sent.md) | `print`/`json` check the second formatting pass against `Writer.end`: a Socket closes instead of corrupting the stream, a Room drops the post and returns `error.WriteFailed` |
| [080](../adr/080-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md) | `Origin` is checked against `Host` or `Options.origins`; browsers apply no CORS here |
| [082](../adr/082-a-cleanup-path-is-not-cancellable.md) | `Room.leave` takes its locks with `lockUncancelable`, added to the Bulkhead |
| [091](../adr/091-a-websocket-route-can-be-driven-from-a-test.md) | `testing.Conversation`: scripted frames, decoded independently, through the public API |
| [202](../adr/202-a-reset-between-frames-is-a-client-that-has-gone.md) | A reset between frames is `null`, not a logged `ReadFailed`; a reset in the middle of a frame still is |
| [216](../adr/216-a-message-that-arrived-whole-is-handed-over-where-it-lies.md) | A complete message already in the read buffer is unmasked and handed over there, taking no free-list buffer |
| [228](../adr/228-a-room-for-a-key-is-lent-from-a-pool.md) | `nilo.Rooms`: a Room per key, borrowed from a pool sized up front, pinned while anything reaches it by key |

Related topics: the WebSocket *client* in `nilo_fetch`, which reads and writes the same frames from `nilo_core`, is [ADR 281](../adr/281-nilo-fetch-opens-a-websocket-and-the-framing-is-core.md); a handler that ignores the server's stopping flag keeps a deploy waiting, see [ADR 019](../adr/019-a-request-that-lasts-is-still-one-request.md); why a `std.log` call on a per-connection path becomes a lock every connection queues on is [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md); why an assert cannot be the check in ADR 076 is [ADR 007](../adr/007-no-recover-middleware.md) (Zig cannot recover from a panic) and [ADR 032](../adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) (a check must have been seen to fail); TLS being terminated in front, which is why `Origin`'s scheme is not compared, is [ADR 027](../adr/027-tls-is-terminated-in-front.md).

## Open questions

- **The Autobahn test suite (`wstest`) is run by hand, not by `zig build test`.** `bench/autobahn/run.sh` runs it, and the last run passed all 294 cases ([history](../history.md)); nothing re-runs it when the frame reader changes.
- **`permessage-deflate` is not implemented.** Negotiating it needs a compressor per connection, which is memory nilo has not budgeted for, per [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md).
- **`Room.leave`'s narrow cancellation window has no test.** Reproducing it needs a broadcast in progress and a cancellation landing between two specific instructions, which the test suite cannot yet arrange, per [ADR 082](../adr/082-a-cleanup-path-is-not-cancellable.md).
- **A short-lived socket that sends large messages still pays for an `mmap` per connection.** [ADR 216](../adr/216-a-message-that-arrived-whole-is-handed-over-where-it-lies.md) narrowed the free-list cost to that case, and says nobody has asked about it since.
