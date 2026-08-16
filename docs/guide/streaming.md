# Streaming

When the length of a response isn't known when the head goes out — a report being
generated, a file being assembled, tokens from a model — the handler writes it
instead of returning it.

## A response in pieces

```zig
fn report(c: *nilo.Ctx, db: *Db) !void {
    var body = try c.stream(200, "text/csv");
    for (db.rows()) |row| try body.print("{d},{s}\n", .{ row.id, row.name });
    try body.finish();
}
```

`Transfer-Encoding: chunked` is handled for you, the connection survives to carry
another request, and an HTTP/1.0 client — which has no chunked encoding — gets
the body unframed with `Connection: close`, because there the end of the body is
the end of the connection.

| | |
|---|---|
| `body.writeAll(bytes)` | append |
| `body.print(fmt, args)` | append, formatted |
| `body.json(value)` | serialise straight into the response |
| `body.flush()` | push what's buffered out now |
| `body.live()` | false once the server has been asked to stop |
| `body.finish()` | say where the body ends — **required** |
| `body.writer` | a plain `std.Io.Writer`, for anything that takes one |

**Nothing is allocated per piece** — one buffer when the stream opens, and that
is all, however long it runs. A streamed request costs two allocations whether it
writes 1 piece or 200
([ADR 0020](../adr/0020-a-request-that-lasts-is-still-one-request.md)).

`finish()` is required: it writes the marker saying where the body ends. Forget
it and nilo writes one so the connection stays usable, and logs that it had to.

`c.streamWith(.{ .buffer = 16 * 1024 })` for a different buffer size; the default
is 4 KB.

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

Every send flushes, so an event doesn't sit waiting for the one after it.
`Cache-Control: no-cache` and `X-Accel-Buffering: no` go out with the head — the
second is what stops an nginx in front holding the events back until a buffer
fills.

| | |
|---|---|
| `events.send(.{ .name = …, .id = …, .data = … })` | one event; a `data` spanning lines becomes one `data:` per line |
| `events.data(text)` | `data:` and nothing else |
| `events.json(name, value)` | an event whose data is `value` as JSON |
| `events.comment(text)` | a line the client ignores — for proxies that close a quiet connection |
| `events.retry(millis)` | how long the browser waits before reconnecting |
| `events.live()` | false once the server is stopping |
| `events.close()` | end the stream |

The browser side is `EventSource`, which needs nothing from you:

```js
const source = new EventSource("/tokens");
source.addEventListener("token", (e) => output.append(e.data));
```

A browser reconnecting sends `Last-Event-ID`, which is an ordinary request
header: `c.header("Last-Event-ID")`.

## Ending, on purpose and otherwise

`live()` is the one to know about. It goes false when the server has been asked
to stop, so a loop that checks it lets a deploy finish: measured with a client
mid-stream, `Ctrl-C` to process exit took **204 ms**, and the client got the
closing event rather than a dropped connection. A stream that ignores it holds
the shutdown open for as long as it runs — up to `shutdown_grace_ms`, after which
it is cut off.

The other way a stream ends needs no check: when the client goes away the next
write fails, and the error unwinds the handler.

## What it costs to hold one open

One fiber each, which v1 measured at **~21 KB**: 10,000 open streams is about
210 MB, before anything of yours. That is the number to plan around, and turning
`read_buffer` and `write_buffer` down in `listen()` takes it to ~17 KB.

A client that opens a stream and then stops reading is cut off by
`write_timeout_ms`, which bounds one write rather than the whole response — so a
stream sending an event a minute is inside the limit however long it runs. See
[Deploying](./deploying.md#deadlines).

## Testing one

A handler that writes its answer can't be tested by calling it — there's nowhere
for it to write. That's what the [test client](./testing.md#handlers-that-write-their-answer)
is for.

`zig build run-stream` is a working example: a streamed CSV report, an event
stream, and a chunked upload, browser page included.
