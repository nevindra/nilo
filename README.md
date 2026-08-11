# zfast

An HTTP framework for Zig, aimed at people coming from Go or Node.

> **0.1.0** — the first release. Routing, typed handlers, JSON, middleware,
> static files, resolved values, groups and plugins, a generated OpenAPI
> document, streamed responses and server-sent events, large request bodies,
> range requests, and WebSocket. Needs Zig 0.16.
>
> Not benchmarked on a quiet machine yet, so there are no performance claims
> here — and there are [no timeouts](#not-here-yet), so put a reverse proxy in
> front. `zfast` is a working name and may change before 1.0.

```zig
const zfast = @import("zfast");

// Two lines of wiring, once, in your root file. `listen()` names whichever
// one is missing.
pub const std_options = zfast.std_options;       // engine chatter out of your logs
pub const std_options_debug_io = zfast.debug_io; // `std.log` off the event loop

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

A handler is an ordinary function. It takes only what it needs, returns data,
and a test calls it directly — no server, no fake request. What each argument
means is worked out while compiling, by one rule: **a pointer is a service, a
value is request data.**

## Install

Needs Zig 0.16.

```
zig fetch --save git+https://github.com/nevindra/zfast
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

`zig build run`, and the paragraph above is a working server. Longer version, with
what each line is for: [Getting started](./docs/guide/getting-started.md).

## Examples

Five runnable ones live in [`examples/`](./examples/):

```
zig build run-hello    # the smallest thing that serves
zig build run-rest     # a service, JSON in and out, query params, auth middleware
zig build run-spa      # a single-page app's files next to its API
zig build run-stream   # a streamed report, an event stream, an upload
zig build run-chat     # a WebSocket, browser page included
```

## Documentation

**[The guide](./docs/guide/)** is the place to start — one page per thing you
might want to do, in the order you would meet them:

| | |
|---|---|
| [Getting started](./docs/guide/getting-started.md) | install, the two root lines, your first server |
| [Handlers](./docs/guide/handlers.md) | what a handler may ask for, and what it may return |
| [Routing](./docs/guide/routing.md) | patterns, precedence, groups, plugins |
| [Requests](./docs/guide/requests.md) | path params, query structs, JSON bodies, large uploads |
| [Responses](./docs/guide/responses.md) | statuses, headers, and `Ctx` when you want full control |
| [Streaming](./docs/guide/streaming.md) | answers written in pieces, and server-sent events |
| [WebSocket](./docs/guide/websocket.md) | upgrading a connection, and what it costs |
| [Middleware](./docs/guide/middleware.md) | the onion, plus the signed-in user as a resolved value |
| [Services](./docs/guide/services.md) | shared state, locks, and the rule about blocking |
| [Static files](./docs/guide/static-files.md) | a directory in memory, ETags, range requests |
| [Errors](./docs/guide/errors.md) | `fail` functions, the mapping table, what the client sees |
| [Testing](./docs/guide/testing.md) | handlers as functions, and the test client for the rest |
| [OpenAPI](./docs/guide/openapi.md) | a document written from the signatures |
| [Deploying](./docs/guide/deploying.md) | startup errors, panics, shutdown, tuning |

[**The reference**](./docs/reference.md) is the same surface as a list: every
`Ctx` method, every `App` method, every options struct, on one page.

Then there is the reasoning, for when you want to know why something is the way
it is rather than how to use it:

- [`docs/adr/`](./docs/adr/) — design decisions, one per file, each with the
  alternative it rejected
- [`CONTEXT.md`](./CONTEXT.md) — the project's vocabulary: what a Service is,
  what a Str is, what words are deliberately avoided
- [`docs/roadmap.md`](./docs/roadmap.md) — what's next, what's refused, and what
  nobody has decided yet
- [`docs/history.md`](./docs/history.md) — how 0.1.0 got built, and what has
  been measured
- [`CHANGELOG.md`](./CHANGELOG.md) — what changed, per release. Empty until
  there is a release to change from

## Not here yet

**There are no deadlines of any kind** — no read, header or write timeout. A
client that opens a connection and then goes quiet parks a fiber until TCP gives
up on it. That is the largest hole there is, so put zfast behind a reverse proxy
that has timeouts until it's filled.

Also absent: TLS, sessions, templates, `sendfile`, `permessage-deflate`, and
broadcasting to WebSockets a handler doesn't hold. Each with its reason in
[`docs/roadmap.md`](./docs/roadmap.md); the ones that are refusals rather than
backlog are in [`docs/adr/`](./docs/adr/).

## Principles

Developer experience comes first; performance is pursued as long as it doesn't
make life harder for the user ([ADR 0001](./docs/adr/0001-dx-wins-below-the-10-percent-threshold.md)).

That trade has a budget, and it isn't one number
([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)):

| | |
|---|---|
| Throughput and p99 | DX wins below 10% |
| Allocations per request | a hard invariant — currently 3, held by a test |
| Memory per idle connection | a hard invariant — every feature states its cost |

Throughput is elastic and the bottom two aren't: an extra allocation isn't 10%
slower on average, it's fine a million times and then it's the tail. Those two
rows are what lets zfast say "low memory" at all.

Where the design is borrowed from — FastAPI for the signature, Elysia for
resolved values and plugins, nginx and TigerBeetle for the memory discipline,
Elm for the error messages — is
[ADR 0015](./docs/adr/0015-what-zfast-borrows-and-from-whom.md).

There are no benchmark numbers yet, so there are no performance claims here.
