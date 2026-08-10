# zfast

An HTTP framework for Zig, aimed at people coming from Go or Node.

> **Status: v1 feature-complete, v2 in progress, unreleased.** Routing with path params, query params and catch-alls; typed handlers, JSON, middleware, logger, CORS, static files, chunked bodies. v2 has added resolved values, route groups and plugins, and an OpenAPI document generated from the handler signatures. Not yet benchmarked on a quiet machine, so there are no performance claims here.
> `zfast` is a working name and may change.

```zig
const zfast = @import("zfast");

// Two lines of wiring, once, in your root file. `listen()` names whichever
// one is missing.
pub const std_options = zfast.std_options; // keeps the engine's debug chatter out of your logs
pub const std_options_debug_io = zfast.debug_io; // keeps `std.log` off the event loop

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

## Install

Needs Zig 0.16. From your project:

```
zig fetch --save git+https://github.com/…/zfast
```

Then hand the module to whatever imports it, in `build.zig`:

```zig
const zfast = b.dependency("zfast", .{ .target = target, .optimize = optimize });

const exe = b.addExecutable(.{
    .name = "my-app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfast", .module = zfast.module("zfast") }},
    }),
});
```

`zig build run`, and the paragraph at the top of this file is a working server.

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
| a type with `zfast_resolve` | a value worked out from the request — the signed-in user, usually |
| any other struct | the request body, parsed from JSON |

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

When you need full control — a header the typed layer has no argument for, a body you want to look at before parsing — the handler simply asks for a `*Ctx`. Both layers are the same layer: the typed one compiles down into `Ctx` calls, and a handler can take a `*Ctx` alongside its typed arguments.

## What a `Ctx` can do

```zig
fn handler(c: *zfast.Ctx) !void { … }
```

Reading the request:

| | |
|---|---|
| `c.method` | `.GET`, `.POST`, … |
| `c.path()` | the path, without the query string |
| `c.param("id")` | a path param, percent-decoded — `null` if the pattern has no such name |
| `c.query("q")` | a query param, percent-decoded, `+` counting as a space |
| `c.header("X-Token")` | a request header, name matched case-insensitively |
| `c.body()` | the whole body, read once into the request arena |
| `c.json(T)` | the body, parsed as JSON into `T` |
| `c.service(*Db)` | a registered service, for a handler that took no typed arguments |
| `c.resolve(CurrentUser)` | a resolved value, for middleware — which has no argument list to ask in |

Answering:

| | |
|---|---|
| `c.sendText(200, "hi")` | `text/plain` |
| `c.sendJson(201, value)` | serialised and sent |
| `c.send(200, "text/csv", bytes)` | a content type of your own |
| `c.setHeader(name, value)` | a response header, copied — set it *before* sending |
| `c.setStaticHeader(name, value)` | the same, for text that already outlives the request (a literal), so nothing is copied |

One request gets one response: a response is flushed the moment it is sent, so there is nothing left to change afterwards. `Content-Type`, `Content-Length` and `Connection` are the framework's to write and setting them is refused — a response carrying two of any of those is malformed.

The limits worth knowing: a body is read whole, up to 1 MB, so this is not the layer for a large upload, and there is no way to write a response in pieces. Both are v2 ([`docs/plan.md`](./docs/plan.md)).

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

## Request bodies

A struct argument is the body, parsed from JSON. A body that does not fit gets the same treatment a query param does — the field named, and what was wrong with it:

```
the request body has a field "titl" this endpoint does not know. It takes: title, done (optional)
the request body is missing "age" (a whole number)
"plan" has to be one of free, paid, not text
"name" has to be text, not a number
the request body is not valid JSON — it stops making sense at line 1, column 12
the request body is empty. This endpoint expects a JSON object with: title, done (optional)
```

A field with a default is what "absent" is allowed to mean, exactly as in a query struct. Working out which of these to say costs a second parse, which is paid only by a request that was already going to be refused.

## The signed-in user, and anything else worked out per request

Some things a handler needs are neither a service nor request data: they are worked out *from* the request. Authentication is the whole genre. So the type says how it is worked out, and a handler asks for it by writing it in its argument list:

```zig
const CurrentUser = struct {
    pub const zfast_resolve = authenticate;   // ← the whole wiring

    id: u32,
    name: Str,
};

fn authenticate(c: *zfast.Ctx, db: *Db) !CurrentUser {
    const token = c.header("Authorization") orelse
        return fail.unauthorized("this endpoint needs a token", .{});
    return db.userForToken(token.view()) orelse
        return fail.unauthorized("that token is not valid", .{});
}

fn me(user: CurrentUser) !Profile {
    return .{ .id = user.id, .name = user.name };
}
```

No registration step, nothing added to `main`. A resolver that fails goes down the same path a failing handler does, so `fail.unauthorized` is how it refuses. And `me` is still an ordinary function: `me(.{ .id = 7, .name = … })` in a test.

A resolver takes a `*Ctx`, a service, a `std.mem.Allocator`, and **other resolved values** — that last one being how `Admin` gets built out of `CurrentUser` instead of out of a second copy of the auth code. It can't take a path param or the body: a resolver belongs to the request, not to a route, and the same `CurrentUser` serves `/me` and `/orders/:id`. Ask for a `*Ctx` if you need one.

It's worked out **once per request**, which matters as soon as you also want to guard a whole prefix:

```zig
fn requireAdmin(c: *zfast.Ctx, next: zfast.Next) !void {
    const user = try c.resolve(CurrentUser);
    if (!user.is_admin) return fail.forbidden("admins only", .{});
    try next.run(c);
}

try app.useOn("/admin", requireAdmin);
fn stats(user: CurrentUser) !Stats { … }   // the same user, not a second lookup
```

Which one to reach for: **middleware enforces, a resolved value provides.** Only routes that name a resolved value get it, so it's the wrong tool for securing a prefix — a handler that forgets the argument simply isn't authenticated. `useOn` is what makes a rule apply whether the handler cooperates or not, and `c.resolve` is how the two meet. See [ADR 0016](./docs/adr/0016-resolved-values-are-declared-by-their-type.md).

## Groups, and plugins

A group is one prefix and everything under it:

```zig
const api = app.group("/api/v1");
try api.use(requireToken);              // only /api/v1/…
try api.get("/users/:id", getUser);     // → /api/v1/users/:id
try api.group("/admin").get("/stats", stats);
```

The prefix is compile-time text joined onto each pattern, so the route registered is the one literal you'd have typed, and it's what every error message quotes back. A group leaves nothing behind at runtime.

A plugin is an ordinary function that takes one. There's no plugin type and nothing to register:

```zig
fn metrics(g: anytype) !void {
    try g.get("/metrics", scrape);
    try g.use(countRequests);
}

try metrics(app.group("/internal"));
```

Because it's handed the group rather than the App, the same function mounts at any prefix, or at two.

A prefix is literal text — `app.group("/orgs/:org")` is a compile error. Middleware is scoped by comparing the front of the request path against the prefix, and `/orgs/:org` is the front of no real path, so every middleware on that group would quietly never run. Put the param in the route patterns.

## Documentation, from the signatures

You already wrote the contract. One line serves it:

```zig
app.docs(.{ .title = "Orders", .version = "2.1.0" });
```

An OpenAPI 3.1 document at `/openapi.json`, and a page for reading it at `/docs`. Both are built when `listen()` runs, so it doesn't matter whether this line comes before or after your routes.

Nothing is annotated and nothing is kept in step, because there's nothing to keep in step — `fn getUser(db: *Db, id: u32) !User` is read by exactly the same pass that decides what to pass in:

```json
"/users/{id}": { "get": {
  "operationId": "getUsersId",
  "parameters": [{"name":"id","in":"path","required":true,"schema":{"type":"integer"}}],
  "responses": {"200": {"content": {"application/json": {"schema": … User … }}}}
}}
```

A `Query(T)` becomes the query parameters, with a defaulted field marked not-required. A struct argument becomes the request body. An enum becomes the list of its names.

What it won't do is claim what your signature doesn't say. A handler returning `Response(T)` picks its status at runtime, so the document says `default` rather than guessing `200`. A type with no JSON shape is `{}` — "anything", which is true. A handler that takes a `*Ctx` and digs the body out by hand documents nothing, which is an accurate description of what it told anybody.

The document is served from memory like a static file, so it arrives with an ETag and a repeat visit is a 304, and it costs the request path nothing. The `/docs` page pulls its viewer from a CDN — set `.ui_path = ""` to turn it off; the document itself never needs the network. See [ADR 0017](./docs/adr/0017-the-api-description-comes-from-the-signatures.md).

## Errors

`fail.notFound(...)` and friends can be called from anywhere, with no `Ctx` in hand:

```zig
return db.find(id) orelse fail.notFound("no user {d}", .{id});
```

Any other error a handler returns goes through a mapping table — `error.InvalidCharacter` is a 400, `error.Timeout` a 503 — and anything unrecognised becomes a 500 whose error name is logged but not sent to the client. Either way the connection stays alive: a 404 is a normal thing to answer, not a reason to hang up.

## Middleware

```zig
fn timing(c: *zfast.Ctx, next: zfast.Next) !void {
    const started = zfast.monotonicNanos();
    try next.run(c);
    const took_us = (zfast.monotonicNanos() - started) / std.time.ns_per_us;
    std.log.info("{f} took {d}µs", .{ c.path(), took_us });
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

A path that exists under some other method is a 405, not a 404, because those are different problems and a 404 sends you looking for a registration bug that isn't there:

```
$ curl -i -X DELETE localhost:8787/users
HTTP/1.1 405 Method Not Allowed
Allow: GET, HEAD, POST

DELETE is not allowed here. This path answers: GET, HEAD, POST
```

`HEAD` is in there without anyone registering one, because the `GET` route already answers it. An `OPTIONS` nobody registered is answered with a 204 and the same `Allow` — that being the question the method exists to ask. Register `app.options(...)` yourself and yours wins.

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

## Handlers must not block

`zfast.Mutex` is one case of a rule that runs through everything: **many requests share one OS thread, so a handler that waits stops all of them.** Not just the request doing the waiting — every other request that happens to be on that thread, including ones that had no work left to do.

It is easy to measure. One handler sitting in `nanosleep` for two seconds, and a second request asking for a route that does nothing:

```
$ curl localhost:8787/slow &        # 2 seconds of blocking
$ curl -w '%{time_total}\n' localhost:8787/                   
1.701                               # ...paid by a request that had nothing to wait for
```

The way out is `zfast.blocking`, which hands the call to a pool of real threads and parks only this request:

```zig
fn getUser(db: *Db, id: u32) !User {
    return zfast.blocking(Db.query, .{ db, id });   // instead of db.query(id)
}
```

Same arguments, same return value, errors included. It allocates nothing, and outside a running server it just calls the function — so the handler is still an ordinary function a test can call.

What needs wrapping is anything that waits on the operating system:

| | |
|---|---|
| a database driver — `libpq`, SQLite, a socket you opened yourself | `zfast.blocking` |
| `std.fs` — reading or writing a file | `zfast.blocking` |
| `std.http.Client`, or any call out to another service | `zfast.blocking` |
| a `std.Thread.Mutex`, semaphore, or channel from `std` | `zfast.Mutex` |
| sleeping, backing off, waiting out a rate limit | `try zfast.sleep(ms)` |

Pure computation does not need it — parsing, JSON, a hash, a loop over a slice. Those are using the thread, not waiting on it. A *long* computation is a different problem, and `zfast.blocking` handles that one too.

`zfast.sleep` fails with `error.Canceled` if the request went away while waiting, the same way `Mutex.lock` does, and that maps to a 503 already.

Nothing forces any of this — Zig has no way to mark a function as blocking, so a handler that calls the driver directly still compiles and still works. It just takes the rest of its thread down with it under load. See [ADR 0014](./docs/adr/0014-handlers-must-not-block-the-thread.md).

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

error: service *main.Db was never registered, but 4 routes need it
("/users", "/users/:id", "/admin/stats", …) — call app.provide() before app.listen()

error: zfast: static directory "public" could not be opened (FileNotFound) —
the path is relative to the working directory the server runs in

warning: std.log will block the event loop. Add to your root source file:
pub const std_options_debug_io = zfast.debug_io;
```

That line is the whole answer, so it is also the last thing on the screen: `listen()` stops the process there rather than returning an error, which would print a stack trace through zfast's own files on top of it. Which file inside the engine noticed the port was taken is not your problem.

If you would rather handle it — a test, or a program that falls back to another port — `tryListen()`, `tryRoute()` and `tryStatic()` are the same calls with the error coming back as a value.

## Stopping

`listen()` returns when the server is stopped — Ctrl-C, a `SIGTERM` from whatever is supervising the process, or `app.shutdown()` from anywhere:

```zig
try app.listen(.{});      // returns on Ctrl-C or SIGTERM
std.log.info("bye", .{}); // and this runs
```

What happens in between is the part that matters for a deploy. The server stops accepting; requests already being answered are finished, and their responses go out saying `Connection: close` so the client opens a fresh connection to whatever replaced this process. Connections merely sitting idle between keep-alive requests are closed at once — they are holding no work, and waiting on them would put the whole grace period behind every open browser tab.

A handler that runs past `.shutdown_grace_ms` (10 seconds by default) is cut off, with a line in the log saying how many were. Pressing Ctrl-C a second time skips the waiting entirely.

`app.shutdown()` is safe from any thread and from inside a handler, so an admin endpoint that stops the server is an ordinary handler. The App is a service like any other, so hand it to itself first:

```zig
fn quit(app: *zfast.App) []const u8 {
    app.shutdown();
    return "going down\n";
}

try app.provide(&app);          // …or `*zfast.App was never registered` at startup
try app.post("/admin/quit", quit);
```

## Tuning

`listen()` takes the knobs that change how the server uses the machine:

```zig
try app.listen(.{
    .address = "0.0.0.0",     // IPv4 or IPv6 — "::" for every interface
    .port = 8080,
    .threads = 0,             // 0 = one per core
    .read_buffer = 8 * 1024,  // also the ceiling on a request head (431 past it)
    .write_buffer = 4 * 1024,
    .shutdown_grace_ms = 10_000,
    .stop_on_signal = true,   // off if your program handles signals itself
});
```

`address` is an address to bind to, not a host name — nothing is resolved, so which interface you land on is never a lookup's decision.

The two buffers are most of what an idle connection costs, so turn them down for a server holding a lot of connections open and up for one sending large responses. Measured on a 2-core Linux box across 1,000 held-open connections: **~21 KB per idle connection** with the defaults, **~17 KB** at 2 KB each.

On the request path, a routed GET returning JSON with CORS installed makes **three allocations**, all of them bump allocations into a request arena that is already warm. A test holds it there.

No requests-per-second figures, on purpose: that number needs a machine nobody else is using, and there isn't one yet ([`docs/plan.md`](./docs/plan.md)).

## What isn't here yet

WebSocket and SSE, TLS, sessions, templates, auth contents, range requests, streamed responses, and bodies over 1 MB.

Most of that list is one missing decision rather than several: the request arena is currently the only answer to where memory comes from, and none of streaming, large bodies, or long-lived connections fits inside it. That decision is the next stage. Each item is listed with its reason in [`docs/plan.md`](./docs/plan.md); the ones that are refusals rather than backlog are in [`docs/adr/`](./docs/adr/).

## Documents

- [`CONTEXT.md`](./CONTEXT.md) — project vocabulary
- [`docs/plan.md`](./docs/plan.md) — v1 scope, build order, risks
- [`docs/adr/`](./docs/adr/) — design decisions and the reasoning behind them

## Principles

Developer experience comes first; performance is pursued as long as it doesn't make life harder for the user ([ADR 0001](./docs/adr/0001-dx-wins-below-the-10-percent-threshold.md)).

That trade has a budget, and it isn't one number ([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)):

| | |
|---|---|
| Throughput and p99 | DX wins below 10% |
| Allocations per request | a hard invariant — currently 3, held by a test |
| Memory per idle connection | a hard invariant — every feature states its cost |

Throughput is elastic and the bottom two aren't: an extra allocation isn't 10% slower on average, it's fine a million times and then it's the tail. Those two rows are what lets zfast say "low memory" at all.

Where the design is borrowed from — FastAPI for the signature, Elysia for resolved values and plugins, nginx and TigerBeetle for the memory discipline, Elm for the error messages — is [ADR 0015](./docs/adr/0015-what-zfast-borrows-and-from-whom.md).

There are no benchmark numbers yet, so there are no performance claims here.
