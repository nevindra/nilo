# zfast

An HTTP framework for Zig, aimed at people coming from Go or Node.

**What it chases is that the signature is the whole contract** — a handler you
can read, test as a plain function, and generate documentation from, on a server
whose memory you can put a number on
([ADR 0015](./docs/adr/0015-what-zfast-borrows-and-from-whom.md)). That makes it
a framework for building APIs and services. Rendering HTML pages is somebody
else's job, and [templates are refused](./docs/roadmap.md#not-coming) rather
than queued up.

> **0.1.0** — the first release. Routing, typed handlers, JSON, HTML forms and
> file uploads, cookies, sessions, redirects, middleware, static files, resolved values,
> groups and plugins, a generated OpenAPI document, streamed responses and
> server-sent events, large request bodies, range requests, and WebSocket.
> Needs Zig 0.16.
>
> Measured, at last, on a machine nobody else was using — the numbers and what
> is in them are at the bottom of this page. `zfast` is a working name and may
> change before 1.0.

```zig
const zfast = @import("zfast");

// Two lines of wiring, once, in your root file. `listen()` names whichever
// one is missing.
pub const std_options = zfast.std_options;       // engine chatter out of your logs
pub const std_options_debug_io = zfast.debug_io; // `std.log` off the event loop

// `?User` says it may not be there, so null goes out as a 404 — and the
// generated API document says the endpoint answers 404.
fn getUser(db: *Db, id: u32) !?User {
    return db.find(id);
}

// `Status(201, User)` puts the status in the type, so the document names it.
fn createUser(db: *Db, incoming: NewUser) !zfast.Status(201, User) {
    return .{ .value = try db.add(incoming) };
}

pub fn main() !void {
    var app = zfast.App.init(gpa);
    defer app.deinit();

    try app.provide(&db);
    try app.use(zfast.logger.standard);
    try app.get("/users/:id", getUser);
    try app.post("/users", createUser);
    try app.static("/", "public");

    try app.listen(.{});
}
```

A handler is an ordinary function. It takes only what it needs, returns data,
and a test calls it directly — no server, no fake request. What each argument
means is worked out while compiling, by one rule: **a pointer is a service, a
value is request data.**

## Install

Needs Zig 0.16. From an empty directory, `zig init` first — `zig fetch` writes
into a `build.zig.zon` that has to exist already:

```
zig init
zig fetch --save git+https://github.com/nevindra/zfast?ref=v0.1.0
```

The `?ref=` is the version you get. Leave it off and `zig fetch` takes whatever
`main` happens to be that day, which is a different library every time somebody
installs.

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

Seven runnable ones live in [`examples/`](./examples/):

```
zig build run-hello    # the smallest thing that serves
zig build run-rest     # a service, JSON in and out, query params, auth middleware
zig build run-orders   # the same ideas on a domain that is not one flat struct
zig build run-forms    # an HTML form, a session cookie, an upload and a redirect
zig build run-spa      # a single-page app's files next to its API
zig build run-stream   # a streamed report, an event stream, an upload
zig build run-chat     # a WebSocket, browser page included
```

`rest` is the one to read first. `orders` is the one that answers "yes, but what
about…": resources inside resources, a body with structs and lists inside it, a
state machine that answers 409, an upsert whose status is not known until it
runs, and a service that owns everything it was handed. `forms` is the one for
people building a web page rather than an API — a `<form>` posted, a session
cookie set, a file uploaded, and a 303 so the reload button behaves.

## Documentation

**[The guide](./docs/guide/)** is the place to start — one page per thing you
might want to do, in the order you would meet them:

| | |
|---|---|
| [Getting started](./docs/guide/getting-started.md) | install, the two root lines, your first server |
| [Handlers](./docs/guide/handlers.md) | what a handler may ask for, and what it may return |
| [Routing](./docs/guide/routing.md) | patterns, precedence, groups, plugins |
| [Requests](./docs/guide/requests.md) | path params, query structs, JSON bodies, large uploads |
| [Forms](./docs/guide/forms.md) | an HTML form as a struct of yours, and file uploads |
| [Responses](./docs/guide/responses.md) | statuses, headers, redirects, and `Ctx` when you want full control |
| [Cookies](./docs/guide/cookies.md) | reading and setting them, and the signed-in user |
| [Sessions](./docs/guide/sessions.md) | a struct of yours, sealed into one cookie |
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
- [`CHANGELOG.md`](./CHANGELOG.md) — what changed, per release

## Not here yet

Queued up: `sendfile`, `permessage-deflate`, compressing a handler's response,
and broadcasting to WebSockets a handler doesn't hold. Each with its reason in
[`docs/roadmap.md`](./docs/roadmap.md); the ones decided against rather than
queued up are in [`docs/adr/`](./docs/adr/).

**Templates are not one of them.** There is no template layer and none is
planned, because rendering a page means allocating per request and the two
numbers below are what zfast is for. Forms, file uploads, cookies, sessions and
redirects all work — a `<form>` posted to a handler is an ordinary request. But
if your application's job is to produce HTML, [jetzig](https://www.jetzig.dev/)
is built for that and this isn't. Whether anything else from that world is worth
having gets decided one feature at a time, on whether it earns its cost.

**The `chat` example is an echo server**, not a chat room. zfast does the
handshake, framing, masking, pings and the closing handshake, and a handler
holds its own connection — but sending to a connection some *other* handler
holds is the roadmap item above, blocked on an upstream defect. Two browser
tabs will not see each other yet.

**Sessions are here, and nothing is stored on the server.** `Session(T)` seals
a struct of yours into one cookie with `XChaCha20Poly1305` — so there is no
table, no expiry sweep, no lock, and nothing added to what an idle connection
costs ([ADR 0035](./docs/adr/0035-a-session-is-sealed-into-the-cookie.md)).
What that cannot do is revoke one, and the
[guide](./docs/guide/sessions.md#what-it-cannot-do) says so in the same breath.
What stays yours is what a password check is and where the secret lives — the
same line zfast draws around authentication.

**TLS is a refusal rather than a gap** — terminate it in front, and the
[deploying guide](./docs/guide/deploying.md#tls-and-the-proxy-in-front) has the
five lines that do it ([ADR 0028](./docs/adr/0028-tls-is-terminated-in-front.md)).
HTTP/2 and a gRPC server go with that decision. Static files *are* compressed,
once, when the App is built.

## Principles

Developer experience comes first; performance is pursued as long as it doesn't
make life harder for the user ([ADR 0001](./docs/adr/0001-dx-wins-below-the-10-percent-threshold.md)).

That trade has a budget, and it isn't one number
([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)):

| | |
|---|---|
| Throughput and p99 | DX wins below 10% |
| Allocations per request | a hard invariant — currently 1, held by a test |
| Memory per idle connection | a hard invariant — every feature states its cost |

Throughput is elastic and the bottom two aren't: an extra allocation isn't 10%
slower on average, it's fine a million times and then it's the tail. Those two
rows are what lets zfast say "low memory" at all, and they now read 1 allocation
and 8,767 bytes.

Where the design is borrowed from — FastAPI for the signature, Elysia for
resolved values and plugins, nginx and TigerBeetle for the memory discipline,
Elm for the error messages — is
[ADR 0015](./docs/adr/0015-what-zfast-borrows-and-from-whom.md).

The Elm part is the one with a build step behind it. Get a handler wrong and
compilation stops with a sentence naming your route, your argument and the fix;
[`refusals/`](./refusals/) is 50 programs written wrong on purpose that keep it
that way ([ADR 0027](./docs/adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).

## Measured

One quiet machine, four physical cores, loopback, a routed `GET` with a path
param returning ~1 KB of JSON. The method, and everything it does not cover, is
in [`docs/benchmarks.md`](./docs/benchmarks.md); eight other servers through the
same harness are in [`docs/comparison.md`](./docs/comparison.md).

| | |
|---|---|
| Throughput | 1,456,636 req/s |
| p99 | 57µs |
| Memory per idle connection | 8,767 bytes, flat from 1,000 to 10,000 |
| Idle server | 5.4 MB |
| Allocations per request | 1 — the JSON body; a POST with a body pays more |

**The throughput number is the least useful one here.** zfast's own code is
about 4% of a request's CPU and the rest is `epoll`, `recv`, `send` and the TCP
path — so at this payload the top of that comparison is five servers making the
same syscalls and landing in the same place. The honest reading is that zfast is
*in* the fastest group, not ahead of it.

The two worth anything are the flat 8,767 and the single allocation, because
they are properties of the design rather than of the machine, and they are what
the invariants above exist to keep.

And a handler that touches a database makes every row of that comparison
identical to everybody else's.
