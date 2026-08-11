# Testing

## Handlers are ordinary functions

The whole point of the signature rules is this: a handler takes only what it
needs, so a test hands it those things and calls it. No server, no socket, no
fake HTTP request.

```zig
fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse zfast.fail.notFound("no user {d}", .{id});
}

test "getUser" {
    var fake = Db.fake(.{ .id = 7 });
    try expectEqual(7, (try getUser(&fake, 7)).id);
    try expectError(error.Failed, getUser(&fake, 99));
}
```

Every fail function returns `error.Failed`, so that is what a refusal asserts on.
To check *which* refusal, look at the message the failure box holds — or drive the
request through the test client below, where the status is on the answer.

The rest follows the same shape:

```zig
// a query struct is an ordinary struct
const page_two = try listUsers(&db, .{ .value = .{ .page = 2 } });

// so is a resolved value
const profile = try me(.{ .id = 7, .name = .static("wati") });

// a body argument is the parsed struct, not JSON text
const created = try createUser(&db, .{ .name = .static("wati"), .age = 30 });
```

`zfast.blocking` and `zfast.Mutex` both work with no server under them, so a
handler that uses either is still callable from a test.

`Str.static("wati")` is how a test makes one: text that already outlives any
request, so nothing can go stale.

## Handlers that write their answer

A handler that returns a value is tested by calling it. One that *writes* its
answer — a stream, an event stream, anything sending from a `*Ctx` — needs
somewhere to write to. So there is a client for that:

```zig
var app = zfast.App.init(testing.allocator);
defer app.deinit();
try app.get("/report.csv", report);

var client = try zfast.testing.Client.init(testing.allocator, .{});
defer client.deinit();

const answer = try client.get(&app, "/report.csv");
try testing.expectEqual(@as(u16, 200), answer.status);
try testing.expect(answer.chunked);

var buf: [4096]u8 = undefined;
try testing.expectEqualStrings("id,name\n1,wati\n", try answer.text(&buf));
```

It runs one request through the App with no server and no socket. Everything the
request path does happens: middleware, routing, the arena, the response written
to a buffer instead of a connection.

### Sending a request

| | |
|---|---|
| `client.get(&app, "/path")` | |
| `client.post(&app, "/path", body)` | with `Content-Length` set |
| `client.request(&app, "PUT", "/path", body)` | any method |
| `client.send(&app, raw)` | the whole request written out, for a header or a version the others don't cover |

`send` is the one for anything unusual — HTTP/1.0, a `Range`, a header your
middleware reads:

```zig
const answer = try client.send(&app,
    "GET /video.mp4 HTTP/1.1\r\nHost: t\r\nRange: bytes=0-20\r\n\r\n");
try testing.expectEqual(@as(u16, 206), answer.status);
```

### Reading the answer

| | |
|---|---|
| `answer.status` | |
| `answer.header("content-type")` | case-insensitive, `null` if absent |
| `answer.body` | the bytes after the head — still chunk-framed if it was a stream |
| `answer.text(&buf)` | the body as a client sees it, framing undone |
| `answer.raw` | everything, exactly as it went on the wire |
| `answer.head` | the status line and headers |
| `answer.chunked` | whether it arrived in chunks |
| `answer.keep_alive` | whether the connection could have carried another request |

A client may be reused for as many requests as you like; each one gets a fresh
arena, exactly as a real connection does between requests.

`Client.init(gpa, .{ .response_bytes = 1 << 20 })` for a stream that produces a
lot — an answer that doesn't fit is truncated rather than failing.

None of this is on the request path, and none of it exists in a running server.

## Running the suite

```
zig build test
```

zfast's own suite runs **in both `Debug` and `ReleaseSafe`**, and `-Doptimize=`
cannot change that. That is not decoration: the bug that made
[ADR 0019](../adr/0019-a-response-owns-its-headers.md) necessary passed 175
tests in `Debug` and segfaulted in release, because a stack temporary still holds
the right bytes until something reuses the stack. A suite that only runs in one
mode can't see that class of bug at all.

Worth doing the same in your own `build.zig` if you hold anything across a
handler's return.
