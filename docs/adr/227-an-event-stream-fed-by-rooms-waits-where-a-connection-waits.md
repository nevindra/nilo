# An event stream fed by Rooms waits where a connection waits

**Status:** accepted
**Topic:** [responses](../design/responses.md)
**Extends:** [ADR 019](./019-a-request-that-lasts-is-still-one-request.md), whose held stream costs 21 KB, and [ADR 035](./035-a-broadcast-rings-a-bell-it-does-not-write.md), whose Room had only WebSockets in it.

## Context

The commonest server-sent-events program is a feed: a browser opens `EventSource`, and every event it will ever see is something somebody else said. Before this, nilo's only way to write one was `c.events()` with a loop the handler kept, and a handler that keeps a loop keeps its fiber suspended inside the request. A suspended fiber holds its stack at its high-water mark ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)), so a held stream costs **21,566 bytes** per connection against **5,183** for one waiting for its next request, measured the same afternoon ([the run](../../bench/result/http.md#a-stream-whose-events-come-from-rooms-costs-what-an-idle-connection-does)). And the handler had nothing to wait on that a Room could ring: a Room's seats belonged to Sockets.

A WebSocket had already solved both halves. [ADR 035](./035-a-broadcast-rings-a-bell-it-does-not-write.md) gave it a Room whose speaker never writes to another connection, and [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) handed its loop back to the connection, which waits from its own frame. A feed is a WebSocket that never reads a message, so it wants the same two things.

## Decision

**`return c.eventsFrom(rooms, .{})` sits an event stream in one Room or a tuple of them, writes the head, and hands the stream to the connection loop, which (on HTTP/2, the connection's own fiber, ADR 260) writes every post as an event until the client goes or the server stops.**

```zig
fn feed(c: *nilo.Ctx, lobby: *nilo.Room) !void {
    return c.eventsFrom(lobby, .{ .keepalive_ms = 15_000, .retry_ms = 3_000 });
}
```

1. **The handler returns; the connection waits.** The stream is put in the handover slot a Socket uses, a union of the two, and the connection loop runs it after the request's frames have unwound. A stream fed by rooms costs **5,184 bytes**, an idle connection to within two, and a handler that touched 32 KiB of stack before returning keeps none of it.
2. **One Room holds both kinds of member.** A WebSocket and an event stream take the same seat and are rung by the same bell, so `say`, `print` and `json` reach both. `room.event(.{ .name, .id, .data })` is the one that says more: an event stream sends `event:` and `id:` with it, and a WebSocket gets `data` as a text message, because a frame has nowhere to carry the other two. A line break in `name` or `id` is `error.EventFieldBreaksLine` and nothing is said, the rule `Events.send` already kept.
3. **A binary post is not an event.** A stream's seat is marked text-only, and a binary post to it is counted in `missed` rather than sent, because an event is lines of text and a binary payload cut into `data:` lines is not what anybody sent. It is counted rather than refused because the speaker does not know who is listening.
4. **A client that speaks has gone.** After its request an `EventSource` sends nothing, so a stream that finds its socket readable reads either a hang-up or bytes that can never be answered, since this response never ends. Either way the stream ends and its seats go.
5. **A keep-alive comment every `keepalive_ms`**, 30 seconds by default: under nginx's default read timeout of 60, and the same stretch a WebSocket waits before it pings ([ADR 021](./021-a-websocket-is-a-handler-that-does-not-return.md)). `0` sends none. It is the empty comment, `:` and a blank line, three bytes, the least a proxy counts as the connection speaking.
6. **`retry_ms` is sent once, before anything else**, and null leaves the browser's own. After it comes what a Room that keeps history said since the client's `Last-Event-ID` ([ADR 229](./229-a-room-that-keeps-history-catches-a-returning-stream-up.md)).
7. **A full room is a 503, before the head.** Every seat is taken before the head goes out, so a room that has none left is an answer the client can read, naming `seats` as the number to raise, rather than a 200 that ends at once and an `EventSource` reconnecting into the same wall every three seconds.
8. **A server that stops ends the stream itself**, after what was already queued, with the last chunk, so the client sees a stream that finished rather than a socket that vanished ([ADR 019](./019-a-request-that-lasts-is-still-one-request.md)).
9. **HTTP/1.0 and HEAD keep ADR 019's answers.** A 1.0 client gets the events unframed and the connection closes with the stream. A HEAD gets the head a GET would and takes no seat.
10. **`rooms` is checked while compiling.** Anything but a `*nilo.Room`, a key of a pool (`rooms.named(key)`, [ADR 228](./228-a-room-for-a-key-is-lent-from-a-pool.md)) or a non-empty tuple of them is refused naming what it was given, and an empty tuple is refused as a stream that could only ever send comments. Both are in `refusals/`.

## Why a client's hang-up can be read here and not on an ordinary request

The roadmap holds "nothing tells a handler its client has gone" open for a reason: a read-side EOF is not a client that left, because a client that sent its request and then half-closed with `shutdown(SHUT_WR)` is still waiting for the answer. That is true of an answer that ends. This one does not, so a client waiting for its end is waiting for nothing, and one that half-closed has said it will send no more, which for a stream is the same as leaving. The rule is narrow on purpose: it holds for a response that never ends and for nothing else, and the open entry stays open.

The alternative was to ignore the read side and find a gone client at the next write. On a quiet feed that is the next keep-alive, up to thirty seconds with a seat held, and with keep-alive off it is the next post, which on a room nobody speaks in is never.

## Why the handover is a union with a `none`, and its `run` a pointer

The handover slot lives on the connection loop's frame, which [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) keeps under a page. An optional of the union would carry a second tag beside the union's own, padded to the Socket's alignment, on every connection whether it ever upgrades or not; `none` is a variant instead. The Socket is the largest variant by its state buffer, so the event stream fits inside what the slot already was; `/health` reading the same before and after is the check.

The stream's `run` travels in the slot as a pointer, the way a Socket's loop does. The connection loop names every variant, so calling `run` directly linked the stream's loop and the Room behind it into every server: **+6,720 bytes** on `hello`, which has no room and no stream. Through the pointer, only a program that calls `eventsFrom` references it.

## On HTTP/2 the connection's fiber is the writer

A multiplexed connection has no reader and writer to give one stream for the rest of its life, so on HTTP/2 the stream gives the connection a bell and a step instead (`Http2Events`, ADR 260). The Rooms ring the connection, which writes each post as `DATA` under both windows in turn with its other streams; the handler has returned, so the stream holds no fiber, and its cost is the `Stream` and the pipe's state, 6.2 KB at 10,000 against 19.6 KB parked ([the run](../../bench/result/http.md#what-an-event-stream-handed-to-the-http2-connection-costs)). Heartbeats, history, `Last-Event-ID`, the room limits and leaving every Room are the same code: The walk over a stream's seats is `deliverSeats` for HTTP/2, and HTTP/1.1's `RoomEvents.deliver` is the same walk written out beside it (through a sink it cost every program that calls `eventsFrom` 16 bytes, ADR 017); the wait is only HTTP/1.1's loop. The connection reaches the stream through function pointers here too, so a program without `eventsFrom` links none of it.

## What was rejected

- **A seat for `c.events()`**, the stream kept by its handler and woken by the room: it needs no handover and costs 21,566 bytes a connection, four times what the same feed costs handed over, and it keeps whatever stack the handler touched.
- **A stream that stays after its client half-closes**, above: a seat held until a write fails, which on a quiet room is never.
- **Rooms that carry only one kind of member**, a WebSocket Room and an event Room: the same feed would need saying twice, and the program deciding which kind a client is before it can speak to it.
- **Framing a binary post as `data:` lines**, or base64: a stream would receive bytes nobody sent as text. Counting it as missed says what happened.
- **An optional union for the handover**, above: a tag and its padding on every connection's loop frame.
- **A direct call to the stream's `run`**, above: 6.7 KB on every server that never streams.
- **Refusing `eventsFrom` on HTTP/2**, as stage 5.3 did: a browser offered HTTP/2 (ADR 259) would have been refused the one stream shape a browser opens most.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | None on a route that does not call it. `eventsFrom` takes none of its own: a seat is one the room made when it was made, the head goes into the connection's write buffer, and its two headers fit in the inline ones. `room.event` is one allocation, as `say` is. |
| Memory per idle connection | Unchanged for a connection that never streams, 5,183 and 5,182 bytes at 10,000 on `/health`, interleaved over two rounds. A stream fed by rooms costs **5,184**, against 21,566 for one held by its handler. A seat gained one `bool`, the text-only mark, which is a room's cost up front and not measured apart from the rest ([the run](../../bench/result/http.md#a-stream-whose-events-come-from-rooms-costs-what-an-idle-connection-does)). |
| Throughput and p99 | Not measured. Nothing on the request path changed; a post to a room gained one branch per seat, the text-only check before a binary post is queued. |
| Binary size | **+656 B** on `hello` and on `rest`, stripped `ReleaseFast`, measured together with the rooms chain of ADR 035 that shipped beside it: the union's dispatch and the walk over a socket's rooms at its end, which every program that can upgrade links. A program that calls `eventsFrom` pays the stream's loop on top. |

## What it breaks

Nothing of this ADR's own. `c.events()` is unchanged and remains the answer for a stream whose handler has something to say between events. The breaking half of the same change, a socket in any number of rooms, is ADR 035's and in `CHANGELOG.md`.
