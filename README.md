# zfast

An HTTP framework for Zig, aimed at people coming from Go or Node.

> **Status: v1 feature-complete, unreleased.** Routing with path params, query params and catch-alls; typed handlers, JSON, middleware, logger, CORS, static files, chunked bodies. Not yet benchmarked on a quiet machine, so there are no performance claims here.
> `zfast` is a working name and may change.

```zig
const zfast = @import("zfast");

// Two lines of wiring, once, in your root file. The first keeps `std.log`
// from blocking the event loop; the second keeps the engine's debug
// chatter out of your logs. `listen()` names whichever one is missing.
pub const std_options = zfast.std_options;
pub const std_options_debug_io = zfast.debug_io;

fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse zfast.fail.notFound("no user {d}", .{id});
}

pub fn main() !void {
    var app = zfast.App.init(gpa);
    defer app.deinit();

    try app.provide(&db);
    try app.use(zfast.logger.standard);
    try app.get("/users/:id", getUser);
    try app.static("/", "public");

    try app.listen(.{});
}
```

Three runnable examples live in [`examples/`](./examples/):

```
zig build run-hello    # the smallest thing that serves
zig build run-rest     # a service, JSON in and out, query params, auth middleware
zig build run-spa      # a single-page app's files next to its API
```

## Handlers are ordinary functions

A handler takes only what it needs and returns data. Which means you can test it without starting a server, and without a fake HTTP request.

```zig
test "getUser" {
    var fake = Db.fake(.{ .id = 7 });
    try expectEqual(7, (try getUser(&fake, 7)).id);
    try expectError(error.Failed, getUser(&fake, 99));
}
```

Arguments are matched at compile time, by one rule: **a pointer is a service, a value is request data.**

| Argument | What zfast passes in |
|---|---|
| `*Ctx` | the raw request — the way out when you need full control |
| `*Db`, `*const Config` | a service, matched by its type |
| `u32`, `f64`, `Str`, `bool`, an enum | a path param, in the order they appear in the pattern |
| `Query(T)` | the query string, read into a struct of yours |
| `std.mem.Allocator` | the request arena, freed when the request ends |
| a struct | the request body, parsed from JSON |

The return value becomes the response: `void` → empty 200, `Str`/`[]const u8` → `text/plain`, anything else → JSON. Wrap it in `Response(T)` when the status isn't 200, or when the response carries headers of its own:

```zig
fn createUser(db: *Db, arena: std.mem.Allocator, incoming: NewUser) !Response(User) {
    const created = try db.add(incoming);
    return .{
        .status = 201,
        .headers = &.{.{
            .name = "Location",
            .value = try std.fmt.allocPrint(arena, "/users/{d}", .{created.id}),
        }},
        .value = created,
    };
}
```

A `std.mem.Allocator` argument is the request arena — the thing to build a header value in, since it lives exactly as long as the response needs it to and is thrown away afterwards. Nothing to free.

Getting any of this wrong stops the compiler with a message that names the route and tells you what to do about it — never a runtime surprise. Asking for a service you forgot to register stops `listen()` before the socket opens.

When you need full control — streaming, large uploads — the handler simply asks for a `*Ctx`. Both layers are the same layer: the typed one compiles down into `Ctx` calls.

## Query params

A path param is positional; a query param is named and may be missing. So it arrives as a struct, one field per param:

```zig
const Search = struct {
    q: Str,             // no default: absent is a 400 saying which one
    page: u32 = 1,      // a default is what "absent" means
    sort: Sort = .newest,
    tag: ?Str = null,   // optional: absent is null
};

fn search(db: *Db, params: Query(Search)) ![]const Item {
    return db.search(params.value.q.view(), params.value.page);
}
```

The types are checked before your handler runs, so the answers to a client that gets it wrong are already written:

```
?q is required
?page has to be a whole number, not "soon"
?sort is not one of the known choices (newest, oldest): "sideways"
```

Values arrive percent-decoded, with `+` counting as a space the way an HTML form sends one. `Query(Search)` is an ordinary struct, so a test builds one directly — `listUsers(&db, .{ .value = .{ .page = 2 } })` — and never touches a query string.

## Errors

`fail.notFound(...)` and friends can be called from anywhere, with no `Ctx` in hand:

```zig
return db.find(id) orelse fail.notFound("no user {d}", .{id});
```

Any other error a handler returns goes through a mapping table — `error.InvalidCharacter` is a 400, `error.Timeout` a 503 — and anything unrecognised becomes a 500 whose error name is logged but not sent to the client. Either way the connection stays alive: a 404 is a normal thing to answer, not a reason to hang up.

## Middleware

```zig
fn timing(c: *zfast.Ctx, next: zfast.Next) !void {
    const started = std.time.milliTimestamp();
    try next.run(c);
    std.log.info("{s} took {d}ms", .{ c.path().view(), std.time.milliTimestamp() - started });
}

try app.use(zfast.logger.standard);
try app.use(zfast.cors.permissive);
try app.use(timing);
try app.useOn("/api", requireToken);
```

An onion: everything before `next.run(c)` happens on the way in, everything after on the way out. Not calling `next` at all ends the chain, which is all a rejecting auth middleware has to do. Returning an error goes down exactly the same path a failing handler does.

Registration order between `use` and `get` doesn't matter — chains are resolved when `listen()` is called, so middleware registered after a route still applies to it. Middleware also runs when nothing matched, so your logger sees 404s and CORS can answer a preflight for a path that has no route.

## Routes

```zig
try app.get("/users/:id", getUser);   // one segment, typed and converted
try app.get("/users/new", newForm);   // a literal always wins over :id
try app.get("/files/*", serveFile);   // the rest of the path, as c.param("*")
```

Order doesn't matter here either. `/users/new` beats `/users/:id` beats `/files/*` because it is more specific, not because of where it sits in your `main` — the same rule `use` and `get` already follow.

Registering the same path twice is refused rather than quietly ignored, because the second handler would never run and nothing about the running server would say so. Param names don't tell two routes apart: `/users/:id` and `/users/:name` answer the same requests, so they collide.

```
error: the route "GET /users/:name" answers the same requests as "/users/:id",
which is already registered — whichever came second would never run.
```

A pattern that can't work — no leading slash, a `:` with no name, a `*` that isn't last, the same param name twice — is a build error naming the route, not something you find out at startup.

## Static files

```zig
try app.static("/", "public");

try app.staticWith("/assets", "dist", .{
    .cache_control = "public, max-age=31536000, immutable",
    .spa_fallback = "index.html",
});
```

The directory is read into memory when the server starts, so nothing touches the disk while requests are being served ([ADR 0010](./docs/adr/0010-static-files-are-held-in-memory.md)). Each file gets an ETag at load, so a repeat visit is a 304 with no body. Path traversal isn't possible, because there is no path to resolve — just a name looked up in a fixed list. Dotfiles are skipped unless you ask for them.

`spa_fallback` is what makes a browser reload on `/users/42` reach your client-side router instead of a 404.

The limit: a file that doesn't fit in memory can't be served. Range requests and `sendfile` are v2.

## Services are shared across threads

Handlers run concurrently on several OS threads. A service you only read from is fine as-is. One that gets written to needs a lock — and it needs **`zfast.Mutex`**, not `std.Thread.Mutex`, because that one blocks the whole thread and every other request being served on it:

```zig
const Store = struct {
    lock: zfast.Mutex = .init,
    users: std.ArrayList(User) = .empty,
};

fn addUser(store: *Store, incoming: NewUser) !User {
    try store.lock.lock();
    defer store.lock.unlock();
    ...
}
```

It still works with no server running, so a handler that takes the lock is still testable as a plain function. See [ADR 0011](./docs/adr/0011-shared-services-need-a-lock-from-the-bulkhead.md).

## A note on panics

Zig cannot recover from a panic: an integer overflow or an out-of-bounds index takes the whole process down, every in-flight connection with it. There is no `recover` middleware because there cannot be one — see [ADR 0008](./docs/adr/0008-no-recover-middleware.md).

Handler *errors* are a different thing and are already handled, as above. For the rest, run `ReleaseSafe` in production (in `ReleaseFast` an overflow is undefined behaviour instead of a loud crash) behind a supervisor that restarts. Adding

```zig
pub const panic = zfast.panic;
```

to your root file makes the crash say which request caused it:

```
thread 589880 panic: integer overflow (while handling GET /boom/50)
```

## When it won't start

Everything that can stop a server before the socket opens says so in one line, in words, with the fix in it:

```
error: port 8787 is already in use — something else is listening on 127.0.0.1:8787.
Stop it, or pass `.port = …` to listen() with a free one.

error: the handler for route "/x" needs service *main.Db, which was never
registered — call app.provide() before app.listen()

warning: std.log will block the event loop. Add to your root source file:
pub const std_options_debug_io = zfast.debug_io;
```

No stack trace through the engine's internals: which file inside zio noticed the port was taken is not your problem.

## Tuning

`listen()` takes the knobs that change how the server uses the machine:

```zig
try app.listen(.{
    .address = "0.0.0.0",
    .port = 8080,
    .threads = 0,           // 0 = one per core
    .read_buffer = 8 * 1024,  // also the ceiling on a request head (431 past it)
    .write_buffer = 4 * 1024,
});
```

The two buffers are most of what an idle connection costs, so turn them down for a server holding a lot of connections open and up for one sending large responses. Measured on a 2-core Linux box across 1,000 held-open connections: **~21 KB per idle connection** with the defaults, **~17 KB** at 2 KB each.

On the request path, a routed GET returning JSON with CORS installed makes **three allocations**, all of them bump allocations into a request arena that is already warm. A test holds it there.

No requests-per-second figures, on purpose: that number needs a machine nobody else is using, and there isn't one yet ([`docs/plan.md`](./docs/plan.md)).

## What isn't in v1

WebSocket and SSE, TLS, sessions, templates, route groups, auth contents, range requests, and middleware handing values to handlers. Each is listed with its reason in [`docs/plan.md`](./docs/plan.md); the ones that are refusals rather than backlog are in [`docs/adr/`](./docs/adr/).

## Documents

- [`CONTEXT.md`](./CONTEXT.md) — project vocabulary
- [`docs/plan.md`](./docs/plan.md) — v1 scope, build order, risks
- [`docs/adr/`](./docs/adr/) — design decisions and the reasoning behind them

## Principles

Developer experience comes first; performance is pursued as long as it doesn't make life harder for the user. The reasoning is in [ADR 0001](./docs/adr/0001-dx-wins-below-the-10-percent-threshold.md).

There are no benchmark numbers yet, so there are no performance claims here.
