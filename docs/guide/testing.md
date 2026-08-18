# Testing

## Handlers are ordinary functions

The whole point of the signature rules is this: a handler takes only what it
needs, so a test hands it those things and calls it. No server, no socket, no
fake HTTP request.

```zig
fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse nilo.fail.notFound("no user {d}", .{id});
}

test "getUser" {
    var fake = Db.fake(.{ .id = 7 });
    try expectEqual(7, (try getUser(&fake, 7)).id);
    try expectError(error.Failed, getUser(&fake, 99));
}
```

Every fail function returns `error.Failed`, so that is what a refusal asserts on.
A handler returning `?T` says the same thing by answering null, so there the
assertion is `try expect(try getUser(&fake, 99) == null)` and no error is
involved at all.
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

// a binding where everything bound, which is what most tests want
const signed_up = try signUp(.ok(.{ .email = .static("wati@example.com"), .age = 31 }));
```

`Bound(W)` is the one argument a test cannot spell as a plain struct — it has
private fields, because a half-filled struct is exactly what it exists to
withhold. `.ok(value)` is the binding where every field bound. To test the
*other* branch, drive the request through the test client below: what a handler
does with a failure is a 422 on the wire, and that is the thing worth asserting
on.

`nilo.blocking` and `nilo.Mutex` both work with no server under them, so a
handler that uses either is still callable from a test.

`Str.static("wati")` is how a test makes one: text that already outlives any
request, so nothing can go stale.

## Handlers that write their answer

A handler that returns a value is tested by calling it. One that *writes* its
answer — a stream, an event stream, anything sending from a `*Ctx` — needs
somewhere to write to. So there is a client for that:

```zig
var app = nilo.App.init(testing.allocator);
defer app.deinit();
try app.get("/report.csv", report);

var client = try nilo.testing.Client.init(testing.allocator, .{});
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

### Two things `listen()` does that the client does not

**It checks the services.** `listen()` refuses to open the socket when a route
needs a service nobody registered, and names the type and the routes. A test
driving the App itself gets a 500 on those routes instead — with the type in the
log, since
[ADR 0079](../adr/0079-there-is-a-phase-before-the-server.md), rather than in
silence. `try app.checkServices();` after the `provide` calls is the whole gate,
and it is worth one line in a test that registers a lot of routes.

**It starts the services.** A `*Db` provided to an App has no pool until
`nilo_start` runs, and until then every query answers `error.Disconnected`. So a
test with a database needs the phase:

```zig
var threaded: std.Io.Threaded = .init(testing.allocator, .{});
defer threaded.deinit();          // must outlive every query below

try app.provide(&db);
try app.start(threaded.io());     // services checked, pools open, schema checked
```

`app.start` also runs `db.checking`, which is worth having in a test for its own
sake: a Row that disagrees with its table passes an entire suite otherwise.

## Running the suite

```
zig build test        # Debug — 0.8s, the one to keep hitting
zig build test-all    # Debug and ReleaseSafe — 7.8s, before you push
```

nilo's own suite runs **in both `Debug` and `ReleaseSafe`**, and `-Doptimize=`
cannot change that. That is not decoration: the bug that made
[ADR 0019](../adr/0019-a-response-owns-its-headers.md) necessary passed 175
tests in `Debug` and segfaulted in release, because a stack temporary still holds
the right bytes until something reuses the stack. A suite that only runs in one
mode can't see that class of bug at all.

The two modes are split across two steps only so the fast one can be run without
thinking about it. `test-all` is what CI runs on every push, so nothing reaches
`main` having been checked in one mode — which is the part that matters, and the
part that is easy to lose by making it a flag somebody has to remember.

Worth doing the same in your own `build.zig` if you hold anything across a
handler's return: the split costs nothing and the second mode is the only thing
that sees a dangling pointer before your users do.
