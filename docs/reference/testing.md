# Testing

**nilo's test helpers send requests to an App in memory, with no socket, and read back what it answered.**

**Guide:** [Testing](../guide/testing.md) · **Design:** [Testing](../design/testing.md)

## Testing

### `testing.Client`

| | |
|---|---|
| `testing.Client.init(gpa, .{ .response_bytes = 64 * 1024 })` | an answer larger than this is `error.ResponseTooLarge` |
| `.{ .client_address = "203.0.113.7" }` | what `c.peer()` and `c.clientIp()` return |
| `.{ .cookies = true }` | keeps the cookies responses set and sends them back, like a browser's cookie jar: a cookie removed by `Max-Age` or by a past `Expires` leaves it, and one named `__Secure-` or `__Host-` that breaks the rules a browser holds it to is dropped. Off by default |
| `.{ .read_buffer = 16 * 1024 }` | the largest request head the client's reader takes, the server's `read_buffer`: a head that does not fit is the 431 a server gives. Set the number given to `listen()` |
| `client.get(&app, path)` / `post(&app, path, body)` / `put(&app, path, body)` / `patch(&app, path, body)` / `delete(&app, path)` | each sends its method, with `Content-Length` set when there is a body. `delete` carries none; `request` sends one under any method |
| `client.postWith(&app, path, content_type, body)` | a POST that states its content type, which a form needs |
| `client.request(&app, method, path, body)` | |
| `client.sendRequest(&app, .{ .method, .path, .headers, .content_type, .body })` | the whole request, described field by field. Every field has a default |
| `client.setHeader(name, value)` | sent with every later request. Setting it again replaces it |
| `client.cookie(name)` | `?[]const u8`: what the jar holds |
| `client.send(&app, raw_request)` | the whole request, written out by hand. Sticky headers and the jar are **not** applied |
| `answer.status` / `.head` / `.body` / `.raw` / `.chunked` / `.keep_alive` | |
| `answer.interim` | `?[]const u8`: the `100 Continue` that came first, or null. `.status` is the final status either way |
| `answer.header(name)` | case-insensitive, the first header with that name |
| `answer.headerAt(name, n)` / `.headerCount(name)` | for headers a response repeats |
| `answer.setCookie(name)` | the whole `Set-Cookie` line that sets it |
| `answer.text(&buf)` | the body with chunk framing removed, into a buffer you sized |
| `answer.bytes(arena)` | the same, into memory the arena owns |
| `answer.json(T, arena)` | `!T`: the body parsed back into a value ([ADR 147](../adr/147-a-response-is-read-back-the-way-it-was-written.md)) |
| `error.AnswerStale` | what the three above return once the client has sent a later request: `.body` borrows the client's single buffer while `.status` is a value, and without this error the two would silently disagree ([ADR 171](../adr/171-an-answer-knows-which-request-it-was.md)) |

### `answer.json`

**`answer.json` exists because nilo already decided how the value was written**, so a test that checks the response should not have to use `std.json` and walk a `Value`:

```zig
const made = try answer.json(struct { id: []const u8 }, arena);
```

It removes chunk framing first, and copies everything into `arena`, so the result outlives the client's response buffer and the next request on it. Read it *before* that next request: asking an answer for its body afterwards returns `error.AnswerStale`, not the later request's bytes. **Unknown fields are ignored.** That is deliberately the opposite of the rule for requests: an unknown field in a *request* is the client's typo and gets a 400 naming it, while a response with more fields than the test asked about is normal. Ask for `std.json.Value` when the shape itself is what the test checks.

### `testing.Wired`

**An App and a Client in one value.**

```zig
var wired = try nilo.testing.Wired.init(testing.allocator, .{});
defer wired.deinit();

try wired.app.provide(&db);
try wired.app.post("/partners", createPartner);

const answer = try wired.post("/partners", body);
```

| | |
|---|---|
| `Wired.init(gpa, options)` | the same `Options` a `Client` takes |
| `wired.app` | a plain `App`: every registration call is the one documented in [The App](./app.md) |
| `wired.app.limits.max_body = 4096` | what `listen(.{ .max_body = 4096 })` would have copied onto the App; `max_in_flight` and `request_deadline_ms` likewise |
| `wired.get(path)` / `post(path, body)` / `put(path, body)` / `patch(path, body)` / `delete(path)` / `postWith(…)` / `request(…)` | the `Client` calls, without the `&app` |
| `wired.sendRequest(r)` / `send(raw)` / `setHeader(n, v)` / `cookie(n)` | likewise |
| `wired.io()` | the `std.Io` a handler gets from `c.io()` or an `io: std.Io` argument in a test: a process-wide `std.Io.Threaded`. Start a writer fiber on it with `io.concurrent`; `Wired` cannot run `app.spawn` ([ADR 244](../adr/244-a-handler-is-given-the-loop-it-runs-on.md)) |
| `wired.deinit()` | deinits the client, then the App |

**Your routes and services stay yours.** `app` is a field, not something behind methods, so nothing here is a second API and no database is assumed. `Client` is unchanged, and is still what to use when a test needs two clients against one App: two addresses, two cookie jars.

### `testing.Live`

**A real server on an ephemeral port, for what only a running server does.**

```zig
const live = try nilo.testing.Live.start(testing.allocator, &app, .{ .threads = 1 });
defer live.stop() catch {};
// connect to 127.0.0.1:live.port
```

| | |
|---|---|
| `Live.start(gpa, app, options)` | starts `app.tryListen` as an `io.concurrent` task of a `std.Io.Threaded` the value owns, returns a `*Live` once `app.boundPort()` answers; `options` is a `nilo.Options`, whose `port` (forced to 0) and `stop_on_signal` (forced off) are overridden |
| `live.port` | the port the kernel chose, on 127.0.0.1 |
| `live.clientIo()` | the `std.Io` of the pool the listener runs on, for a client the test writes; not the server's loop |
| `live.stop()` | shuts the server down the way a deployed one is, waits for the listener, and frees the value; `error.ServerDidNotStop` after ten seconds, when the value is left alive |

**Every wait is bounded.** `start` gives the port three seconds and returns the error `tryListen` failed with when it fails sooner (`error.ServerNeverCameUp` otherwise). The App must be registered before `start` and outlive the value ([ADR 244](../adr/244-a-handler-is-given-the-loop-it-runs-on.md)). It is test-only: nothing outside `nilo.testing` names it.

### `testing.Conversation`

**A WebSocket route has no answer to read, so it has its own test driver** ([ADR 091](../adr/091-a-websocket-route-can-be-driven-from-a-test.md)):

```zig
var chat: nilo.testing.Conversation = try .init(gpa, .{});
defer chat.deinit();

try chat.text("hello");
try chat.close(1000, "bye");

const talk = try chat.open(&app, "/chat");
try testing.expectEqualStrings("hello", talk.at(0).?.bytes);
```

| | |
|---|---|
| `Conversation.init(gpa, .{ … })` | the same `Options` a `Client` takes |
| `chat.text(s)` / `binary(b)` / `ping(b)` / `pong(b)` | queues one frame, masked as a client must |
| `chat.close(code, why)` | queues a close frame |
| `chat.fragments(.text, &.{ … })` | one message split across continuation frames |
| `chat.raw(bytes)` | bytes sent without framing, to test what a **malformed** frame does |
| `chat.setHeader(name, value)` | sent with the handshake: an `Origin`, a cookie, a subprotocol |
| `chat.open(&app, path)` | runs it. The queue is cleared, so the same conversation can be opened again |
| `talk.accepted()` / `.status` / `.header(name)` | the handshake |
| `talk.at(n)` / `.first(kind)` / `.messages` | the frames the server sent, decoded and in order |
| `talk.closedWith()` | the close code, or null if it never closed |

A `Message` has `.kind` (`.text`, `.binary`, `.ping`, `.pong`, `.close`), `.bytes`, and `.code()` / `.reason()` for a close frame.

**The frames are queued before the server runs, not while it runs.** There is one thread and no socket, so a test cannot read what the server said and then decide what to send next. A conversation between *two* sockets, including a `Room` broadcast, needs two connections and is not possible here.

### `testing.show`

**`show` makes a failed assertion readable.** `std.testing` prints both sides with `{any}`, and `{any}` means *do not call the type's own formatter*, so a `Uuid` prints as sixteen decimal numbers and a `[]const u8` as its bytes. On a schema with many uuid columns, nearly every row in a failed assertion comes out as noise ([ADR 137](../adr/137-a-failed-assertion-that-can-be-read.md)):

```zig
errdefer std.debug.print("row: {f}\n", .{nilo.testing.show(row)});
```

`show(value)` renders the value as JSON into whatever writer is formatting it, using the rendering nilo already has for its own types: a `Uuid` is text, a `Str` is a string, and a `Timestamp` is RFC 3339. **Nothing is allocated**, which is why it can sit inside a `std.debug.print` while you are debugging. For an actual `[]const u8`, `std.fmt.allocPrint(gpa, "{f}", .{nilo.testing.show(v)})` needs nothing extra.

It is a renderer, not an assertion, on purpose. An `expectEqual` of nilo's own would drag in `expectEqualDeep`, `expectEqualSlices` and `expectError`, and it would not have helped the failure that prompted this, which was an `expectError` finding a payload, not two values that differed. A `Json(T)` column nests JSON inside the JSON, which reads well but is not meant to be parsed back.

### `testing.tmpDir`

**A directory of its own for one test, and the path to a file in it**, for code that opens a file by name: a SQLite database, a socket, a directory `app.static` serves ([ADR 250](../adr/250-a-test-directory-hands-back-its-path.md)). `std.testing.tmpDir` gives a `Dir` and no path.

```zig
var tmp = nilo.testing.tmpDir();
defer tmp.cleanup();

var buf: [128]u8 = undefined;
const url = try tmp.path(&buf, "app.db");
var db: Db = .init(gpa, url, .{ .size = 2 });
```

| | |
|---|---|
| `nilo.testing.tmpDir()` | `TmpDir`: a new directory under `.zig-cache/tmp/`, open. Always iterable, so listing it cannot panic the way std's does without `.iterate = true` |
| `tmp.dir` | the open `std.Io.Dir`, for writing a file in by handle |
| `tmp.path(buf, name)` | `![:0]u8`: the path of `name` in the directory, written into `buf` and zero-terminated. `error.NoSpaceLeft` when `buf` is too short |
| `tmp.pathAlloc(gpa, name)` | `![:0]u8`: the same path in memory the caller frees |
| `tmp.path(buf, "")` | the directory itself, which is what `app.static` takes. `TmpDir.dir_path_len` is its length |
| `tmp.cleanup()` | closes the directory and removes it with everything in it |

**No path points into the `TmpDir`**, so a fixture can take a path in its `init` and return the `TmpDir` by value. The path is relative to the working directory, as std's directory is. It is `nilo_core.tmpDir`, so a test in `nilo_sql` or any module that cannot name `nilo_http` has the same one.

### `testing.Refusals`

**`Refusals` catches a refusal made with no request in flight.** A service function called from a CLI, a seed script or a plain test refuses through the same fail functions, but outside a request there is nowhere to store the status, so four different refusals all reach the caller as the same `error.Failed`. `Refusals` gives the test the status and the message back ([ADR 129](../adr/129-a-refusal-outside-a-request-is-still-a-refusal.md)):

```zig
var refusals: nilo.testing.Refusals = .{};
refusals.begin();
defer refusals.end();

try testing.expectError(error.Failed, comment.edit(&db, &run, id, someone_else, "hi"));
const said = refusals.caught().?;
try testing.expectEqual(@as(u16, 409), said.status);
```

| | |
|---|---|
| `refusals.begin()` | installs the slot. Not a constructor, because what goes in the slot is this struct's address |
| `refusals.end()` | puts back whatever was there before. Safe to call twice, and safe on one that never began |
| `refusals.caught()` | `?Refused`: `.status` and `.message`, or null if nothing was refused |
| `refusals.clear()` | forgets the last one, for a test that makes a second call |

**Call `clear` between calls.** Without it, the second assertion passes on the first call's message, which is the one way a test like this silently goes wrong. `message` is borrowed from the `Refusals`, so it lives as long as that does. This is a test-only type: the slot it installs is the Bulkhead's fallback, the one a call made outside the event loop already uses, and a running server has a real slot per fiber.
