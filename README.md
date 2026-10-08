<h1 align="center">nilo</h1>

<p align="center">
  <strong>Your types are the contract. The compiler is the check.</strong>
</p>

<p align="center">
  <a href="https://www.http-arena.com/frameworks/nilo/"><img alt="HTTP Arena H/1.1: #2 of 79" src="https://img.shields.io/static/v1?label=HTTP%20Arena%20H%2F1.1&message=%232%20of%2079&color=e3b341&labelColor=8a5a12&style=flat-square"></a>
  <a href="https://www.http-arena.com/frameworks/nilo/"><img alt="HTTP Arena WebSocket: #1 of 22" src="https://img.shields.io/static/v1?label=HTTP%20Arena%20WebSocket&message=%231%20of%2022&color=e3b341&labelColor=8a5a12&style=flat-square"></a>
</p>

<p align="center">
  <a href="https://ziglang.org/"><img alt="Zig 0.16" src="https://img.shields.io/badge/zig-0.16-f7a41d?style=flat-square&logo=zig&logoColor=white"></a>
  <a href="./CHANGELOG.md"><img alt="version 0.7.0" src="https://img.shields.io/badge/version-0.7.0-3b82f6?style=flat-square"></a>
  <a href="./docs/reference/"><img alt="12 modules" src="https://img.shields.io/badge/modules-12-8957e5?style=flat-square"></a>
  <a href="./refusals/README.md"><img alt="532 refusals" src="https://img.shields.io/badge/mistakes%20refused%20while%20compiling-532-e05d44?style=flat-square"></a>
  <a href="./docs/adr/"><img alt="252 ADRs" src="https://img.shields.io/badge/decisions%20on%20file-252-6b7280?style=flat-square"></a>
  <a href="./LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-16a34a?style=flat-square"></a>
</p>

<p align="center">
  <a href="#-quickstart">Quickstart</a> ·
  <a href="#-performance-measured">Performance</a> ·
  <a href="./docs/guide/">Guide</a> ·
  <a href="./docs/reference/">Reference</a> ·
  <a href="./examples/">Examples</a> ·
  <a href="./CHANGELOG.md">Changelog</a>
</p>

---

Zig gives you a fast compiler and leaves the rest to you: routing, settings, password hashing, tables, Postgres. **nilo is that rest: an HTTP framework for Zig, and the toolkit it is built from**, twelve small modules you import one at a time.

Every module runs on the same idea. **A plain function is a route. A plain struct is a table.** nilo reads your types while the program compiles, so there is nothing to annotate and nothing to keep in sync.

```zig
fn getUser(db: *Db, id: u32) !?User {
    return db.find(id);
}
```

Those three lines are a complete route. From them you get:

- `id` already parsed into a `u32`
- a 400 with a readable sentence when it isn't a number
- a 404 when `db.find` returns `null`
- an OpenAPI document that says all of the above

### At a glance

- 🏁 **#2 of 79** on [HttpArena](https://www.http-arena.com/frameworks/nilo/)'s HTTP/1.1 board, and **#1 of 22** on WebSocket, among untuned entries.
- 🪶 **1 allocation** per request. A test fails if it ever becomes 2.
- 💾 **4,669 bytes** per idle connection.
- 🧯 **532 mistakes caught while compiling**, each with a sentence that tells you the fix.
- 🔌 **Zero glue.** Routing, errors, OpenAPI and SQL all read the same struct.

## ⚡ Quickstart

You need Zig 0.16 and nothing else: no C library, no system package.

```console
$ zig init                                                          # only if you have no build.zig.zon yet
$ zig fetch --save 'git+https://github.com/nevindra/nilo?ref=v0.7.0#e1b859f8230a4cffd09d8e84411f7bcd7524258a'
```

**Keep the `#commit` part.** The tag is annotated, and Zig 0.16's `zig fetch` doesn't peel it, so `?ref=v0.7.0` on its own gives you whatever `main` is that day.

```zig
const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;       // two lines of wiring, once, in your root file;
pub const std_options_debug_io = nilo.debug_io; // forget one and `listen()` says which

fn getUser(db: *Db, id: u32) !?User {
    return db.find(id);
}

fn createUser(db: *Db, incoming: NewUser) !nilo.Status(201, User) {
    return .{ .value = try db.add(incoming) };
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.provide(&db);
    try app.use(nilo.logger.standard);
    try app.get("/users/:id", getUser);
    try app.post("/users", createUser);
    try app.static("/", "public");
    app.docs(.{ .title = "Users", .version = "1.0.0" });

    try app.listen(.{});
}
```

Then add it to `build.zig`:

```zig
const nilo = b.dependency("nilo", .{
    .target = target,
    .optimize = optimize,
    // Only if you import nilo_sql. This is what fetches the database drivers;
    // leave it off and a project that serves HTTP downloads none of them.
    .sql = true,
});

const exe = b.addExecutable(.{
    .name = "my-app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nilo_http", .module = nilo.module("nilo_http") },
        },
    }),
});
```

Run `zig build run` and it's serving. [Getting started](./docs/guide/getting-started.md) walks through the same steps line by line.

The package is `nilo`, and each module is its own import: `nilo_http`, `nilo_sql`, `nilo_s3`, `nilo_fetch`, `nilo_job`, `nilo_cache`, `nilo_jwt`, `nilo_proto`, `nilo_config`, `nilo_pw`, `nilo_id` and `nilo_core`. **There is no module called `nilo`**, so alias the one you use: `const nilo = @import("nilo_http");`.

> **Upgrading from 0.6.0?** [Read this before you deploy](https://github.com/nevindra/nilo/releases/tag/v0.7.0#read-this-before-you-deploy): each change, and how to fix it. From 0.5.0, read [v0.6.0's](https://github.com/nevindra/nilo/releases/tag/v0.6.0#read-this-before-you-deploy) first.

## ✨ A route is just a function

The whole API fits in one rule:

> ### A pointer is a service. A value is request data.

Read `getUser` with that rule in mind:

- `db: *Db` is a pointer, so it's a service: the one you passed to `provide`.
- `id: u32` is a value, so it's request data: here the `:id` in the path, converted, or a 400 if it won't convert.
- `!?User` might be empty, so `null` goes out as a 404, and the API document says so.
- `!Status(201, User)` puts the status in the type, so the API document names it too.

There is no second copy of the contract. Delete the `?` and the 404 leaves the document as well.

**Registration order doesn't matter.** `/users/new` and `/users/:id` both work whichever you write first, `use` after `get` still applies, and `docs()` can go anywhere.

**Tests are plain function calls.** A handler takes only what it needs, so there is no server, socket or fixture to set up:

```zig
test "getUser" {
    var fake = Db.fake(.{ .id = 7 });
    try expectEqual(7, (try getUser(&fake, 7)).?.id);
    try expect(try getUser(&fake, 99) == null);
}
```

## 🧩 The same idea, everywhere

### Your struct is a table

```zig
const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .unique = .{ .{ .email, .ignoring_case } },
        .references = .{ .org_id = .{ Org, .id } },
    };

    id: i64,
    org_id: i64,
    email: nilo.Str,
    age: i32,
    created_at: sql.Timestamp,
};

const adults = try db.select(User, c, .{
    .where = .{ .age = .{ .gt = 18 } },
    .order = .{ .created_at = .desc },
    .limit = 10,
});
```

No tags, no schema file, no generated client. The query is checked against your struct while compiling, so a typo fails the build instead of returning a 500 at 3am:

```
$ zig build
error: nilo: User has no column `agee`, asked for in a condition.
       Did you mean `age`?
```

The same struct creates the table and generates migrations from a diff, without opening a database in CI. Postgres and SQLite are written the same way. It isn't an ORM: a struct can carry the row its foreign key points at, the rows that point back, or a sum by group, and every statement behind them is written while compiling. Anything past that goes through `db.raw`, which still fills your struct.

### Your settings are a struct too

```zig
const Settings = struct {
    port: u16 = 8080,                  // a default means "not set is fine"
    database_url: []const u8,          // no default means required
    log_level: enum { debug, info, warn } = .info,
    workers: ?u8 = null,
};

const read = config.fromEnv(Settings, init.minimal.environ);
const settings = read.value() orelse {
    try read.report(stderr);
    std.process.exit(2);
};
```

Every wrong setting is reported at once, not one per redeploy:

```
3 settings could not be read from the environment:
  PORT has to be a whole number, not "soon"
  DATABASE_URL is not set
  LOG_LEVEL has to be one of debug, info, warn, not "verbose"
```

### Passwords are a value

<!-- compiles: body -->
```zig
// signing up
const stored = try c.hashPassword(gpa, form.password.view());
_ = try db.insert(User, c, .{ .email = form.email, .password = stored.text() });

// signing in
const row = try db.one(User, c, .{ .where = .{ .email = form.email } });
if (!try c.verifyPassword(gpa, if (row) |r| r.password.view() else null, form.password.view()))
    return nilo.fail.unauthorized("that is not a sign-in", .{});
```

argon2id, stored in a format any other library can read, and hashed off the event loop. An email with no account takes as long as one with an account, so your login form doesn't reveal who has signed up.

## 🙂 When you get it wrong

Mistakes come back as sentences that say what you did and what to do about it, and most of them arrive before your program finishes compiling:

```
$ zig build
error: nilo: route "/users/:user/pets/:pet" has 2 path params (:user, :pet), but its handler only takes 1.
       Path params are matched by position, so the ones at the end would never be read.
       Add the arguments (`id: u32`, `name: nilo.Str`, …), drop the unused `:` from the
       pattern, or ask for a `*Ctx` if you would rather fetch them yourself with `c.param("…")`.
```

What a compiler can't see is caught at startup, before the first request:

```
error: service *Db was never registered, but 3 routes need it ("/users/:id", "/users",
       "/users/:id/orders") — call app.provide() before app.listen()
```

And while the server runs, a handler that blocks its thread is named in the log:

```
warning: handler GET /report held its thread for 412ms. Every other request being served
         on that thread waited the whole time. Hand the call that waits to
         nilo.blocking (ADR 013).
```

The same things make nilo easy for coding agents: a small API, no ordering to guess, and a build that explains itself. Point one at [`docs/reference/`](./docs/reference/).

## 📏 Performance, measured

On [HttpArena](https://www.http-arena.com/frameworks/nilo/), an independent board that runs every entry on the same 64-core machine, nilo is **#2 of 79 on HTTP/1.1** and **#1 of 22 on WebSocket**, among untuned entries like itself.

| | |
|---|---|
| **Throughput** | 1,401,412 req/s on four physical cores |
| **p99 under load** | 69 µs: 9.4× lower than Go's `net/http`, 11× lower than Fiber |
| **Memory per idle connection** | 4,669 bytes, flat to 10,000 connections |
| **Idle server** | 5.4 MB |
| **Binary** | 1.79 MB stripped with Postgres, 2.29 MB with SQLite, and no database driver at all if you don't import `nilo_sql` |

Against eight other servers returning the same JSON, nilo is 1st on throughput, 2nd on p99, and last of the five compiled languages on rebuild time, at 7.4 s. The full comparison is in [`docs/comparison.md`](./docs/comparison.md), and every run is in [`bench/result/`](./bench/result/).

## 🧰 What's in the box

| Module | What it does | Left out |
|---|---|---|
| **`nilo_http`** | Routing, typed handlers, middleware, cookies and sessions, static files, streaming, WebSocket, rooms that broadcast to sockets and event streams and reach one user by key, OpenAPI, metrics, OpenTelemetry tracing ([guide](./docs/guide/tracing.md)), rate limiting, CSRF, security headers, gzip (libdeflate behind `.libdeflate = true`, [guide](./docs/guide/responses.md#compression)), optional TLS 1.3, and optional HTTP/2 beside HTTP/1.1 for every route ([guide](./docs/guide/deploying.md#http2-for-a-browser)) with unary gRPC on it ([guide](./docs/guide/grpc.md)) | Templates, HTTP/2 in the default build, WebSocket over HTTP/2, streaming gRPC |
| **`nilo_sql`** | Postgres and SQLite: reads, writes, transactions, streaming, schema and migrations. Window functions, CTEs and any other join go through `db.raw`, which still fills your struct, counts its columns while compiling and checks their types the first time it runs ([guide](./docs/guide/sql/raw.md)) | Window functions and CTEs written in Zig rather than SQL, `down` migrations |
| **`nilo_s3`** | S3, MinIO and R2: get, put, multipart upload, range, stream, list, presigned URLs | `COPY` |
| **`nilo_fetch`** | Calling another HTTP API from inside a request | Retries, circuit breaker |
| **`nilo_job`** | Background and scheduled work, queued in the database you already have, with three levels of urgency and cron schedules | Exactly-once, time zones |
| **`nilo_cache`** | An expiring in-process cache on a fixed memory budget | Pointers in cached values |
| **`nilo_jwt`** | Verifying tokens: RS256, ES256 and rotating JWKS | Signing tokens, HS256 |
| **`nilo_proto`** | Protobuf as plain structs: decode, encode, OTLP-sized messages in a handful of allocations | A `.proto` compiler, proto2 |
| **`nilo_config`** | Settings from the environment | Config files |
| **`nilo_pw`** | Password hashing with argon2id | |
| **`nilo_id`** | UUID v4 and v7 | |
| **`nilo_core`** | The types the other modules share | |

## 🚫 What it won't do

- **Templates.** If your app is mostly HTML, [jetzig](https://www.jetzig.dev/) is built for it.
- **HTTP/2 in the default build.** It is behind `.http2 = true`, and a browser reaches it only over TLS, which is `.tls = true` or a proxy in front ([deploying guide](./docs/guide/deploying.md#tls-and-a-reverse-proxy)). With both flags a TLS listener offers `h2` and `http/1.1` and serves every route on either; gRPC rides it, unary calls only ([gRPC guide](./docs/guide/grpc.md)).
- **Revoking a session.** Sessions are sealed into the cookie, so there's no session table to delete from.

Each of these was decided on purpose; [`docs/decided.md`](./docs/decided.md) says why.

## 🧪 Examples

Eleven runnable examples live in [`examples/`](./examples/):

```console
$ zig build run-hello      # the smallest thing that serves
$ zig build run-rest       # a service: JSON in and out, query params, auth middleware
$ zig build run-orders     # the same ideas on a domain that is not one flat struct
$ zig build run-forms      # an HTML form, a session cookie, an upload and a redirect
$ zig build run-spa        # a single-page app's files next to its API
$ zig build run-embedded   # a single-page app carried inside the binary, next to its own JSON API
$ zig build run-stream     # a streamed report, an event stream, an upload
$ zig build run-chat       # a WebSocket, browser page included
$ zig build run-scheduled  # work that is not a request, owned by the server
$ zig build run-outbound   # calling somebody else's API from inside a handler
$ zig build run-sqlite     # two Rows on one SQLite file: tables at boot, parents, children, a grouped report, a transaction
```

Start with **`rest`**. Swap `run-` for `dev-` to restart the server every time you save.

If the link fails on `.sframe` in `crt1.o`, add `-Dtarget=x86_64-linux-gnu` ([why](./docs/guide/getting-started.md#fixing-the-sframe-link-error)).

## 📚 Documentation

- **[The guide](./docs/guide/)**: one page for each thing you might want to do, from your first handler to deploying.
- **[The reference](./docs/reference/)**: the entire API, one page a module.
- **[Comparison](./docs/comparison.md)**: how nilo sits next to the other Zig options.

## 🐈 Why it's called nilo

Nilo was my cat. She was quick, the kind of quick you notice from across a room, cheerful about it, and she spent most of her time looking after the other cats in the house, which nobody had asked her to do. **Helpful, quick, cheerful**: that's what this project tries to be, in that order.

## 🤝 Contributing

Questions, issues and "why on earth is it like this?" are all welcome. [CONTRIBUTING.md](./CONTRIBUTING.md) covers where to start, and [the roadmap](./docs/roadmap.md) says where it is going and [the todo list](./docs/todo.md) has what's open. Mail is the most useful module nobody has written yet.

nilo borrows from FastAPI, Elysia, Elm and Drizzle; [ADR 014](./docs/adr/014-what-nilo-borrows-and-from-whom.md) says what came from where.

## License

MIT. See [LICENSE](./LICENSE).
