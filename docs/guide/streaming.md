# Streaming

**When a response's length is not known when the head goes out, the handler writes the body in pieces instead of returning it.**

**Reference:** [`Stream`](../reference/streaming.md#stream), [`Events`](../reference/streaming.md#events), [`Room`](../reference/streaming.md#room), [`Rooms`](../reference/streaming.md#rooms) · **Design:** [Responses](../design/responses.md)

Typical cases are a report being generated, a file being assembled, or tokens arriving from a model.

## Streaming a response

```zig
fn report(c: *nilo.Ctx, db: *Db) !void {
    var body = try c.stream(200, "text/csv");
    for (db.rows()) |row| try body.print("{d},{s}\n", .{ row.id, row.name });
    try body.finish();
}
```

[`c.stream`](../reference/streaming.md#stream) handles `Transfer-Encoding: chunked` for you, and the connection stays open for another request. An HTTP/1.0 client has no chunked encoding, so it gets the body unframed with `Connection: close`: there, the end of the connection marks the end of the body.

| | |
|---|---|
| `body.writeAll(bytes)` | append |
| `body.print(fmt, args)` | append, formatted |
| `body.json(value)` | serialise straight into the response |
| `body.flush()` | push what's buffered out now |
| `body.live()` | false once the server has been asked to stop |
| `body.finish()` | say where the body ends: **required** |
| `body.writer` | a plain `std.Io.Writer`, for anything that takes one |

**Nothing is allocated per piece.** There is one buffer when the stream opens, and that is all, however long it runs. A streamed request costs two allocations whether it writes 1 piece or 200 ([ADR 019](../adr/019-a-request-that-lasts-is-still-one-request.md)).

`finish()` is required: it writes the marker that says where the body ends. If you forget it, nilo writes one so the connection stays usable, and logs that it had to.

For a different buffer size, use `c.streamWith(200, "text/csv", .{ .buffer = 16 * 1024 })`; the default is 4 KB.

## Server-sent events

```zig
fn tokens(c: *nilo.Ctx, llm: *Llm) !void {
    var events = try c.events();
    while (events.live()) {
        const token = llm.next() orelse break;
        try events.send(.{ .name = "token", .data = token });
    }
    try events.json("done", .{ .finished = true });
    try events.close();
}
```

**Every send flushes, so an event never waits for the one after it.** [`c.events()`](../reference/streaming.md#events) sends `Cache-Control: no-cache` and `X-Accel-Buffering: no` with the head. The second one stops an nginx in front from holding the events back until a buffer fills.

| | |
|---|---|
| `events.send(.{ .name = …, .id = …, .data = … })` | one event; a `data` spanning lines becomes one `data:` per line |
| `events.data(text)` | `data:` and nothing else |
| `events.json(name, value)` | an event whose data is `value` as JSON |
| `events.comment(text)` | a line the client ignores, for proxies that close a quiet connection |
| `events.retry(millis)` | how long the browser waits before reconnecting |
| `events.live()` | false once the server is stopping |
| `events.close()` | end the stream |

On the browser side, `EventSource` needs nothing from you:

```js
const source = new EventSource("/tokens");
source.addEventListener("token", (e) => output.append(e.data));
```

A reconnecting browser sends `Last-Event-ID`, which is an ordinary request header: `c.header("Last-Event-ID")`.

## Event streams fed by a room

**When every event comes from other requests, hand the stream to a [`Room`](../reference/streaming.md#room) and let the handler return.** Most event streams have nothing of their own to say: a browser opens one, and every event it sees is something another request said. The handler does not need to stay for that. Put the streams in a room, say things into the room, and hand the stream over:

<!-- compiles -->
```zig
fn feed(c: *nilo.Ctx, news: *nilo.Room) !void {
    return c.eventsFrom(news, .{ .retry_ms = 5_000 });
}

fn publish(news: *nilo.Room, headline: nilo.Str) !void {
    try news.event(.{ .name = "headline", .data = headline.view() });
}
```

`eventsFrom` takes a seat in the room, writes the head and returns. From then on the connection waits on the room the same way an idle connection waits for its next request, and every `say`, `print`, `json` or `event` into the room goes out as an event, one chunk each. While nothing is said, a comment goes out every 30 seconds, so a proxy that closes quiet connections sees this one speak (`.keepalive_ms`, `0` for none). The stream ends when the browser goes away or the server stops.

To listen to more than one room, pass a tuple: `c.eventsFrom(.{ lobby, mine }, .{})`, and the stream hears all of them. A room can hold WebSockets and event streams together, so the chat room a socket speaks into can be the one a read-only page listens to. A binary message said into it reaches the sockets and is counted as missed for the streams, because an event is text.

**A browser that reconnects can be caught up.** It sends `Last-Event-ID`, the id of the last event it read, and a room made with `.history` keeps its latest text posts, including those said while nobody was listening. `eventsFrom` writes the ones after that id before anything new, and nothing is written twice:

```zig
var news = try nilo.Room.initWith(gpa, .{ .history = 256 });
```

Give every post in such a room an id, with `room.event(.{ .id = … })`. A post without one does not move the browser's last id, so it would be written again on the next reconnect. An id the room no longer has replays nothing ([ADR 229](../adr/229-a-room-that-keeps-history-catches-a-returning-stream-up.md)).

**To reach one user rather than everybody, use a key in a [`nilo.Rooms`](../reference/streaming.md#rooms) pool:** `c.eventsFrom(.{ news, rooms.named(key) }, .{})` with the user's key, and `rooms.json(key, value)` from wherever the notification starts. The [WebSocket guide](./websocket.md#reaching-one-user-on-every-tab-nilorooms) has the rest.

When the handler does have work of its own between events, such as a model's tokens as they arrive, use `c.events()` above; it costs what [an open stream](#what-an-open-stream-costs) costs.

## A stream with a known length

**If the bytes were already counted, say so with `.length`.** A handler moving bytes out of something that knows its size, such as an S3 object or an upstream response, should pass it:

```zig
var body = try c.streamWith(200, object.content_type, .{ .length = object.len });
```

The head then carries `Content-Length` and no `Transfer-Encoding`, and the pieces go out unframed. The gain is not less framing overhead. A browser downloading a chunked response has nothing to draw a progress bar against, and a `Range` request against it cannot be answered at all, which is exactly the request a large download makes when it resumes.

**A stream with a length is held to it.** Writing past the stated length fails with `error.WriteFailed` before any byte of the overrun goes out, because a client reading a `Content-Length` stops there and would read everything after it as the start of the next response. Finishing short cannot be refused, since the head has already gone, so the connection closes and the log names both numbers ([ADR 101](../adr/101-a-stream-that-knows-its-length-says-so.md)).

## Trailers

**A stream can end with trailers**, fields that go after the last piece. Set them before `finish`, which is what sends them:

```zig
fn report(c: *nilo.Ctx, db: *Db) !void {
    var body = try c.stream(200, "text/csv");
    var rows: usize = 0;
    for (db.rows()) |row| {
        try body.print("{d},{s}\n", .{ row.id, row.name });
        rows += 1;
    }
    try c.setTrailer("x-rows", try std.fmt.allocPrint(c.arena(), "{d}", .{rows}));
    try body.finish();
}
```

On an HTTP/1.1 stream they are the trailer section of the chunked body. A client only reads them if it said `TE: trailers`, and `c.clientReadsTrailers()` tells you; setting them when it did not is harmless, and they are left off. A stream with a known length has no chunked body to carry them. The names that may not be trailers are listed under [Trailers](./responses.md#trailers).

## When a stream ends

**Check `live()` in the loop so a deploy can finish.** It goes false when the server has been asked to stop. Measured with a client mid-stream, `Ctrl-C` to process exit took **204 ms**, and the client got the closing event rather than a dropped connection. A stream that ignores it holds the shutdown open for as long as it runs, up to `shutdown_grace_ms`, after which it is cut off.

The other way a stream ends needs no check: when the client goes away, the next write fails and the error unwinds the handler.

## What an open stream costs

**A held stream costs one fiber, and much more than the 4,669 bytes of an idle connection.** A stream is a handler that has not returned, so it keeps its buffers (an idle connection gives them back, a streaming one is using them) and its stack at the high-water mark of everything the handler has touched ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)). Lowering `read_buffer` and `write_buffer` in `listen()` reduces it directly, which it does not for an idle connection.

**A held stream measures 21,058 bytes**, against 4,674 for an idle keep-alive connection on the same server in the same run ([`bench/result/http.md`](../../bench/result/http.md)). Ten thousand of them is about 210 MB, and that is the minimum, not the total.

**Your handler's stack is added on top, byte for byte.** The same table has a handler that touches 32 KiB before its first wait, and it measures 53,825 bytes: 32,767 more, which is the 32 KiB, held for as long as the stream lasts because the frame holding it never unwinds. So measure your own handler with `python3 bench/mem.py --port … --path … --hold` before planning for ten thousand, and keep what a streaming handler puts on its stack small.

**A stream handed to a room pays none of this.** `c.eventsFrom` returns from the handler before the stream waits, so it costs what an idle connection does: 5,184 bytes against 21,566 for a held stream, measured on the same host the same afternoon, and whatever stack the handler touched first is given back ([ADR 227](../adr/227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md)). If all your events come from somewhere else, that is the version to plan ten thousand of.

A client that opens a stream and then stops reading is cut off by `write_timeout_ms`. It bounds one write, not the whole response, so a stream sending one event a minute stays inside the limit however long it runs. See [Deploying](./deploying.md#deadlines).

## Testing a stream

A handler that writes its answer cannot be tested by calling it, because there is nowhere for it to write. Use the [test client](./testing.md#the-test-client) for that.

`zig build run-stream` is a working example: a streamed CSV report, an event stream, and a chunked upload, with a browser page.
