# Testing

**A handler is tested by calling it; a handler that writes its own answer is tested through a test client with no server and no socket.**

**Reference:** [`nilo.testing.Client`](../reference/testing.md#testingclient), [`Wired`](../reference/testing.md#testingwired), [`tmpDir`](../reference/testing.md#testingtmpdir) · **Design:** [Testing](../design/testing.md)

## Testing a handler by calling it

**A handler takes only what it needs, so a test builds those things and calls it.** No server, no socket, no fake HTTP request. That is the point of the signature rules.

```zig
/// The service the handler asks for. In the program it reads a table; in a
/// test it is whatever the test builds.
const Users = struct {
    rows: []const User,

    pub fn find(self: *Users, id: u32) ?User {
        for (self.rows) |u| if (u.id == id) return u;
        return null;
    }
};

fn getUser(users: *Users, id: u32) !User {
    return users.find(id) orelse nilo.fail.notFound("no user {d}", .{id});
}

test "getUser" {
    var users: Users = .{ .rows = &.{.{ .id = 7, .name = .static("wati") }} };
    try expectEqual(7, (try getUser(&users, 7)).id);
    try expectError(error.Failed, getUser(&users, 99));
}
```

nilo ships no fake database. A pointer argument is a service, and a service is a type you wrote, so a test builds one. When the handler takes the real `*sql.Db`, the test uses a real database; see [Testing against a real database](#testing-against-a-real-database).

Every `fail` function returns `error.Failed`, so that is what a test for a refusal checks. A handler returning `?T` refuses by returning null, so there the check is `try expect(try getUser(&users, 99) == null)` and no error is involved. To check *which* refusal, look at the message the failure holds, or send the request through the test client below, where the status is on the response.

Everything else works the same way:

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

`Bound(W)` is the one argument a test cannot write as a plain struct. It has private fields, because a half-filled struct is exactly what it exists to hold back. `.ok(value)` is the binding where every field bound. To test the *other* branch, send the request through the test client below: what a handler does with a failure is a 422 on the wire, and that is what is worth checking.

`nilo.blocking` and `nilo.Mutex` both work with no server running, so a handler that uses either can still be called from a test.

`Str.static("wati")` is how a test makes a `Str`: text that already outlives any request, so nothing can go stale.

## The test client

**A handler that writes its own answer is tested through [`nilo.testing.Client`](../reference/testing.md#testingclient).** A handler that returns a value is tested by calling it. One that *writes* its answer (a stream, an event stream, anything sending from a `*Ctx`) needs somewhere to write to:

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

It runs one request through the App with no server and no socket. Everything on the request path still happens: middleware, routing, the arena, and the response, written to a buffer instead of a connection.

### Sending a request

| | |
|---|---|
| `client.get(&app, "/path")` | |
| `client.post(&app, "/path", body)` | with `Content-Length` set |
| `client.put(&app, "/path", body)`, `patch` likewise, `client.delete(&app, "/path")` | the method named, `delete` with no body |
| `client.request(&app, "OPTIONS", "/path", body)` | any method |
| `client.sendRequest(&app, .{ … })` | any of the above plus headers, every field defaulted |
| `client.send(&app, raw)` | the whole request written out, for a version the others don't cover |

**Use `sendRequest` when a route reads a header:**

```zig
const answer = try client.sendRequest(&app, .{
    .path = "/video.mp4",
    .headers = &.{.{ .name = "Range", .value = "bytes=0-20" }},
});
try testing.expectEqual(@as(u16, 206), answer.status);
```

`client.setHeader("Authorization", "Bearer t")` sets a header for every request from then on, which is what a suite behind a bearer token needs.

`send` is for what nothing else can express: an HTTP/1.0 request, or a deliberately malformed one. **With `send`, write the `Host` yourself.** Every other method adds one for you, and an HTTP/1.1 request without one is a 400 before it reaches a route ([ADR 070](../adr/070-a-request-nobody-else-would-answer-is-refused.md)). `send` also applies neither `setHeader` nor the cookie jar: the bytes are sent exactly as given.

### Keeping cookies between requests

**`Client.init(gpa, .{ .cookies = true })` keeps the cookies responses set and sends them back**, the way a browser does. Without it, signing in and then making a request *as* that user means copying the `Set-Cookie` from one response into the next request by hand.

```zig
var client = try nilo.testing.Client.init(testing.allocator, .{ .cookies = true });
defer client.deinit();

_ = try client.postWith(&app, "/sign-in", "application/x-www-form-urlencoded",
    "email=wati%40example.dev&password=hunter2");

// Carries the session cookie the sign-in set.
const answer = try client.get(&app, "/me");
```

It is off by default so that suites written before it existed keep testing what they always tested ([ADR 086](../adr/086-the-test-client-can-do-what-a-client-does.md)). `client.cookie(nilo.session.host_cookie_name)` returns what the jar holds for a `Session(T)` (`__Host-session` with the default options), for a test that wants to look at it rather than only send it.

### Reading the response

| | |
|---|---|
| `answer.status` | |
| `answer.header("content-type")` | case-insensitive, `null` if absent |
| `answer.body` | the bytes after the head, still chunk-framed if it was a stream |
| `answer.text(&buf)` | the body as a client sees it, framing undone |
| `answer.bytes(arena)` | the same, into memory the arena owns |
| `answer.json(T, arena)` | the body read back as a value |
| `answer.raw` | everything, exactly as it went on the wire |
| `answer.head` | the status line and headers |
| `answer.chunked` | whether it arrived in chunks |
| `answer.keep_alive` | whether the connection could have carried another request |

**`answer.json` reads the body back into a type**, because nilo already decided how the value was written. Walking a `std.json.Value` to pull one field out of a create response took four lines at every call site ([ADR 147](../adr/147-a-response-is-read-back-the-way-it-was-written.md)):

```zig
const made = try answer.json(struct { id: []const u8 }, arena);
try testing.expectEqual(@as(usize, 36), made.id.len);
```

It removes chunk framing first and copies everything into the arena, so what it returns survives the next request on the same client. Fields you did not ask for are ignored: you are asking about part of the response, not checking its whole shape. When the shape *is* what you are checking, ask for `std.json.Value`.

A client can be reused for as many requests as you like. Each one gets a fresh arena, exactly as a real connection does between requests.

### `Wired`: an App and a Client together

**[`Wired`](../reference/testing.md#testingwired) is the App and Client pair most test files build:**

```zig
var wired = try nilo.testing.Wired.init(testing.allocator, .{});
defer wired.deinit();

try wired.app.provide(&db);
try wired.app.post("/partners", createPartner);

const answer = try wired.post("/partners", "{\"name\":\"Wati\"}");
try testing.expectEqual(@as(u16, 201), answer.status);
```

`wired.app` is a plain `App`, so routes, services, groups and `docs()` are registered exactly as anywhere else. It is not a second API, and no database is assumed. Every `Client` method is on it without the `&app`: `wired.get`, `.post`, `.put`, `.patch`, `.delete`, `.postWith`, `.request`, `.sendRequest`, `.send`, `.setHeader`, `.cookie`.

`Client` is still there for a test that needs two clients against one App: two addresses, two cookie jars.

Use `Client.init(gpa, .{ .response_bytes = 1 << 20 })` for a stream that produces a lot. **A response that does not fit is `error.ResponseTooLarge`** from the call that sent the request, where it used to be cut short with its status intact, so a 200 with half a body passed every assertion on the status.

**What `listen()` would have set, a test sets on the App.** A Client never calls `listen()`, so the App has the default limits; `wired.app.limits.max_body = 4096` is what `listen(.{ .max_body = 4096 })` copies there, and `max_in_flight` and `request_deadline_ms` sit beside it. `app.session_key` is the same kind of field ([Sessions](./sessions.md)).

None of this is on the request path, and none of it exists in a running server.

### Checking and starting services in a test

**`listen()` does two things the test client does not: it checks the services and it starts them.**

**Checking.** `listen()` refuses to open the socket when a route needs a service nobody registered, and names the type and the routes. A test driving the App directly gets a 500 on those routes instead, with the type in the log since [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md), not silently. `try app.checkServices();` after the `provide` calls is the whole check, and it is worth one line in a test that registers a lot of routes.

**Starting.** A `*Db` provided to an App has no pool until `nilo_start` runs, and until then every query returns `error.Disconnected`. So a test with a database needs this step:

```zig
var threaded: std.Io.Threaded = .init(testing.allocator, .{});
defer threaded.deinit();          // must outlive every query below

try app.provide(&db);
try app.start(threaded.io());     // services checked, pools open, schema checked
```

`app.start` also runs `db.checking`, which is worth having in a test on its own: otherwise a Row that disagrees with its table passes the whole suite.

`app.start` is for a program that never listens, which a test is. In a program that does listen, the same work goes in `app.before` and `listen()` runs it on its own loop. `app.start` followed by `listen()` is refused ([ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)).

### A real server in a test

**`Wired` has no server, so it cannot run what only a server does.** `app.spawn` fibers, `nilo.io()` as the loop the connections run on, and an idle deadline firing with no request in flight all need `listen()`. [`testing.Live`](../reference/testing.md#testinglive) starts one on the real Engine, on a port the kernel chose, and a test drives it with any client:

```zig
var app = nilo.App.init(testing.allocator);
defer app.deinit();
try app.post("/append", append);
try app.spawn(Wal.write, .{&wal});

const live = try nilo.testing.Live.start(testing.allocator, &app, .{ .threads = 1 });
defer live.stop() catch {};

// connect to 127.0.0.1:live.port with std.http.Client, nilo.fetch or a socket
```

`start` returns once the port is bound, and `stop` is the shutdown a deployed server gets, so the fibers are cancelled before it returns. Every wait in both is bounded: a server that never binds is the error it failed with, not a hung suite. It costs a thread and a second of wall clock at most, so keep it for what only a running server can show and test the rest through `Wired`. The [background guide](./background.md#a-queue-a-handler-fills-and-a-fiber-empties) has the writer this was written for.

## Testing against a real database

**A handler that takes `db: *Db` is tested against a real database**, because the SQL statement is what it would be tested for, and that is exactly what a fake leaves out. On SQLite this costs nothing to set up: the database lives in memory, one per test, and the App starts it the way `listen()` would. [`examples/sqlite/`](../../examples/sqlite/main.zig) tests itself this way:

```zig
const Stack = struct {
    threaded: std.Io.Threaded,
    db: Db,
    app: nilo.App,
    client: nilo.testing.Client,

    fn open(gpa: std.mem.Allocator) !*Stack {
        const self = try gpa.create(Stack);
        self.* = .{
            .threaded = .init(gpa, .{}),
            // One database the whole pool shares and no other test sees,
            // gone when the pool closes.
            .db = Db.init(gpa, ":memory:", .{ .size = 2 }),
            .app = nilo.App.init(gpa),
            .client = try nilo.testing.Client.init(gpa, .{}),
        };
        self.db.checking(schema);
        try self.app.provide(&self.db);
        try self.app.before(makeTables, .{&self.db});
        try routes(&self.app);
        try self.app.start(self.threaded.io()); // pool, tables, schema check
        return self;
    }

    fn close(self: *Stack, gpa: std.mem.Allocator) void {
        self.client.deinit();
        self.app.deinit();
        self.db.nilo_stop();
        self.db.deinit();
        self.threaded.deinit();
        gpa.destroy(self);
    }
};
```

It is heap-allocated because the App holds a pointer to the Db and the client hands out a `Ctx` pointing at the App, so none of the three may move. `:memory:` is a database private to the pool that opens it, so every test gets an empty one without naming it, and tests running side by side cannot see each other's rows; a `file:NAME?mode=memory&cache=shared` URL is shared by every pool on that name ([SQLite](./sql/sqlite.md#the-database-filename)).

A program on Postgres tests against Postgres. `sql/live.zig` shows how this repository does it: the URL comes from `DATABASE_URL` through `build.zig`, and every test skips when there is none, so the everyday loop never needs a server running. Where `$CI` is set, a missing URL fails the build instead, so losing the variable cannot turn the suite green ([ADR 239](../adr/239-a-live-test-skips-on-a-laptop-and-fails-on-ci.md)).

### A file opened by its path

**A test that needs a real file, a SQLite database in WAL, a socket, a directory to serve, takes a directory of its own from `nilo.testing.tmpDir()` and asks it for the path.** `std.testing.tmpDir` gives a `Dir` and no path, and the one it uses is not documented ([ADR 250](../adr/250-a-test-directory-hands-back-its-path.md)):

```zig
test "a write waits on a lock another connection holds" {
    var tmp = nilo.testing.tmpDir();
    defer tmp.cleanup(); // the directory and the database in it

    var buf: [128]u8 = undefined;
    const url = try tmp.path(&buf, "app.db");
    var db: Db = .init(testing.allocator, url, .{ .size = 2 });
    defer db.deinit();
    // ...
}
```

The path goes into a buffer you hold, or into an allocator with `tmp.pathAlloc(gpa, "app.db")`, and nothing points back into `tmp`, so a fixture can take it in `init` and return the `TmpDir` by value. An empty name is the directory itself, for `app.static`. Use a file rather than `mode=memory` when the test is about locking, WAL or `Locked`: an in-memory database answers `memory` to `PRAGMA journal_mode = WAL` and never takes the locks a file does ([ADR 065](../adr/065-one-writer-is-not-a-setting-it-is-the-database.md)).

## Running the suite

```
zig build test        # Debug, plus the refusals and every module's gate — the loop
zig build test-all    # the same in ReleaseSafe as well — the gate, and what CI runs
```

**Read the exit code, not the word "failed".** `zig build` prints `failed command: …` for every step that wrote to stderr, and a test that logs at `warn` writes to stderr, so a passing run can print several of them and still exit 0. The exit code and the `Build Summary` (which names a failed step as one) are what count. A test passes with a `warn` line in its output; only `std.log.err` fails it, because Zig's test runner treats an `err` line as a failure. That is why everything on nilo's request path logs at `warn` and keeps `err` for a server that is refusing to start, and why a test of your own that exercises a refusal on purpose may log one and still pass. `grep` for the summary rather than for the word if a CI step has to decide.

What each costs is measured, not remembered: [`bench/result/build.md`](../../bench/result/build.md) has the numbers, and what to change when they move.

**nilo's own suite runs in both `Debug` and `ReleaseSafe`**, and `-Doptimize=` cannot change that. This matters: the bug that led to [ADR 018](../adr/018-a-response-owns-its-headers.md) passed 175 tests in `Debug` and segfaulted in release, because a stack temporary still holds the right bytes until something reuses the stack. A suite that runs in only one mode cannot see that kind of bug at all.

The two modes are split into two steps only so the fast one can be run without thinking about it. `test-all` is what CI runs on every push, so nothing reaches `main` having been checked in only one mode. That is the part that matters, and it is easy to lose if it becomes a flag somebody has to remember.

Do the same in your own `build.zig` if you hold anything past a handler's return: the split costs nothing, and the second mode is the only thing that catches a dangling pointer before your users do.
