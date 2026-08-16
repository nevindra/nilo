# zfast

**An HTTP framework for Zig, built to be hard to get wrong — by you, or by your
coding agent.**

Write a plain Zig function. zfast reads its arguments while compiling and hands
back a routed endpoint, typed input, a 400 for anything that doesn't fit, and an
OpenAPI document. Nothing is annotated. One function is your route, your test
and your API description
([ADR 0015](./docs/adr/0015-what-zfast-borrows-and-from-whom.md)).

That design pays off twice. It is pleasant to write by hand — and it is why
Claude Code and the rest land working code here, instead of something that
compiles and quietly does the wrong thing:

- Get an argument wrong → the build stops, in a sentence naming the fix.
- Register a route twice, or forget a service → the server refuses to start.
- Change a handler → the API document changes with it. There is no second copy.

The whole API surface is [one page](./docs/reference.md), small enough to hand a
model in full. [More on that](#writing-an-app-against-it--by-hand-or-with-an-agent).

Zig has needed one of these. If you're coming from Go or Node the handler will
look familiar — the bill won't: **one allocation per request**, **8,767 bytes
per idle connection**, and a p99 the
[comparison table](./docs/comparison.md) puts **9× below Go's `net/http`** and
**11× below Fiber**.

Rendering HTML pages is somebody else's job. There is no template layer and
[none is planned](#refused-on-the-record).

> **0.1.0**, the first release · needs **Zig 0.16** · `zfast` is a working name
> and may change before 1.0.

## What it looks like

```zig
const std = @import("std");
const zfast = @import("zfast");

// Two lines of wiring, once, in your root file. `listen()` names whichever
// one is missing.
pub const std_options = zfast.std_options;       // engine chatter out of your logs
pub const std_options_debug_io = zfast.debug_io; // `std.log` off the event loop

fn getUser(db: *Db, id: u32) !?User {
    return db.find(id);
}

fn createUser(db: *Db, incoming: NewUser) !zfast.Status(201, User) {
    return .{ .value = try db.add(incoming) };
}

pub fn main() !void {
    var app = zfast.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.provide(&db);
    try app.use(zfast.logger.standard);
    try app.get("/users/:id", getUser);
    try app.post("/users", createUser);
    try app.static("/", "public");
    app.docs(.{ .title = "Users", .version = "1.0.0" });

    try app.listen(.{});
}
```

Four things in those two signatures, all settled while compiling:

| Written | Means |
|---|---|
| `db: *Db` | a **pointer** is a service — the one you handed to `provide` |
| `id: u32` | a **value** is request data — here `:id`, converted, or a 400 if it won't |
| `!?User` | it may not be there, so `null` goes out as a **404** — and the API document says the endpoint answers 404 |
| `!Status(201, User)` | the status is in the type, so the API document names it |

That is the whole rule for an argument list: **a pointer is a service, a value
is request data.** There is no second rule, no decorator and no macro.

Answering with a file is the same shape — a return type, not a side effect, so
the generated document can still see it:

```zig
fn invoice(files: *Files, id: u32) !?zfast.FileBody {
    const name = files.nameOf(id) orelse return null;
    return .{ .dir = files.dir, .name = name, .content_type = "application/pdf" };
}
```

The file is opened inside a directory a Service opened at startup — never a path
worked out from the request. The bytes go straight from the file to the socket
without passing through your process. `Range`, `If-Range` and `If-None-Match`
work as they do for a static file, and the `?` is still a 404
([ADR 0037](./docs/adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)).

The static tree does the same at the top end. A file over `max_file_bytes` is
opened per request instead of being refused at startup, so a directory with a
video in it now serves instead of failing to load.

## Why you might want it

| | |
|---|---|
| **Handlers are ordinary functions** | a test calls one directly — no server, no fake request, no fixture |
| **Mistakes are refused, in words** | at compile time or at startup, a sentence naming your route, your argument and the fix |
| **Order decides nothing** | routes, middleware and `docs()` register in any order — no shadowing, no precedence to keep in your head |
| **The API document writes itself** | OpenAPI 3.1 read off the same signatures, so it can't drift from the code |
| **The memory has a number on it** | 8,767 bytes per idle connection, flat, and one allocation per request — both held by tests |
| **It says what it won't do** | templates, TLS, HTTP/2 — refused on the record rather than left as a maybe |

## Install

Zig 0.16 and nothing else — no C library, no system package.

```
zig init                                                          # only if you have no build.zig.zon yet
zig fetch --save git+https://github.com/nevindra/zfast?ref=v0.1.0
```

**Keep the `?ref=`.** Without it `zig fetch` takes whatever `main` happens to be
that day, so two people installing a week apart get two different libraries and
neither of them asked for a version.

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

`zig build run`, and the code above is a working server.
[Getting started](./docs/guide/getting-started.md) walks the same thing through
line by line.

## Try it

Seven runnable examples live in [`examples/`](./examples/):

```
zig build run-hello    # the smallest thing that serves
zig build run-rest     # a service, JSON in and out, query params, auth middleware
zig build run-orders   # the same ideas on a domain that is not one flat struct
zig build run-forms    # an HTML form, a session cookie, an upload and a redirect
zig build run-spa      # a single-page app's files next to its API
zig build run-stream   # a streamed report, an event stream, an upload
zig build run-chat     # a WebSocket, browser page included
```

Read **`rest`** first. Reach for **`orders`** when you hit "yes, but what
about…": resources inside resources, a body with structs and lists in it, a
state machine that answers 409, an upsert whose status is not known until it
runs, and a service that owns everything it was handed. **`forms`** is the one
for people building a web page rather than an API — a `<form>` posted, a session
cookie set, a file uploaded, and a 303 so the reload button behaves.

## Writing an app against it — by hand, or with an agent

The same design that makes this pleasant by hand is what makes an agent reliable
on it. A model doesn't need a special API. It needs three things it can't supply
for itself:

- a surface small enough to hold all of at once
- no ordering it has to infer from code it hasn't read
- a build that says what's wrong, instead of a server that starts anyway

**One rule covers the whole argument list.** Pointer is a service, value is
request data. There is no second rule, so there is very little to misremember —
and very little to invent something else in place of.

**Order decides nothing.** Register routes in any order: `/users/new` and
`/users/:id` both work either way, because matching picks the most specific
route rather than the first one
([ADR 0013](./docs/adr/0013-the-most-specific-route-wins-and-duplicates-are-refused.md)).
`use` after `get` still applies. `docs()` before or after your routes. So a new
route can be appended anywhere without reading what is above it — which is how
both a person in a hurry and an agent actually edit a file.

**A mistake is refused rather than tolerated**, in three places, in the order
you would meet them.

*While compiling* — an argument zfast can't make sense of, a pattern that can't
work, two request bodies, a `Form` and a JSON body in the same handler:

```
$ zig build
error: zfast: route "/users/:user/pets/:pet" has 2 path params (:user, :pet), but its handler only takes 1.
       Path params are matched by position, so the ones at the end would never be read.
       Add the arguments (`id: u32`, `name: zfast.Str`, …), drop the unused `:` from the
       pattern, or ask for a `*Ctx` if you would rather fetch them yourself with `c.param("…")`.
```

*At startup, before a single request is served* — a route registered twice, a
service nobody provided, a line of root wiring missing:

```
error: the route "GET /users/:name" answers the same requests as "/users/:id", which is
       already registered — whichever came second would never run. Drop one, or give them
       different paths. (Param names do not tell two routes apart: "/users/:id" and
       "/users/:name" are the same route.)

error: service *Db was never registered, but 3 routes need it ("/users/:id", "/users",
       "/users/:id/orders") — call app.provide() before app.listen()
```

*While running* — the two mistakes no compiler can see. Holding request data
past the request is trapped in a `Debug` build:

```
panic: Str used after its request finished. Request data dies with the request; copy it
       with .keep() while the handler is still running if you need to hold on to it.
```

and a handler that blocks the thread its neighbours are sharing is timed and
named in the log, in any build:

```
warning: handler GET /report held its thread for 412ms. Every other request being served
         on that thread waited the whole time. Hand the call that waits to
         zfast.blocking (ADR 0014).
```

Every one of those names what you did and what to do instead. A person reads one
and fixes it in a single pass; so does an agent, at build or boot time rather
than by shipping a 500 and reading the logs afterwards.

The compile-time ones are held in place, not left to drift:
[`refusals/`](./refusals/) is **56 programs written wrong on purpose**, and the
build checks the wording of the message each one produces
([ADR 0027](./docs/adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).

**Tests are calls, not scaffolding.** A handler takes only what it needs, so a
test hands it those things and calls it:

```zig
test "getUser" {
    var fake = Db.fake(.{ .id = 7 });
    try expectEqual(7, (try getUser(&fake, 7)).?.id);
    try expect(try getUser(&fake, 99) == null);
}
```

No server, no socket, no fake request, no fixture file. Scaffolding is exactly
the part that goes wrong when it's written from a half-remembered example.

**Nothing has to be kept in step.** `app.docs(…)` serves an OpenAPI 3.1 document
read from the same signatures the router reads. Nothing is annotated, so there
is no second copy of the contract to leave stale — and where a signature doesn't
say something, the document says `default` rather than guessing
([ADR 0017](./docs/adr/0017-the-api-description-comes-from-the-signatures.md)).
Your own app serves it at `/openapi.json`, so whatever consumes your API — a
generated client, or an agent writing against it — can read the contract back
out of the running server.

> **Pointing an agent at zfast:** [`docs/reference.md`](./docs/reference.md) is
> the whole API surface on one page and [`CONTEXT.md`](./CONTEXT.md) is the
> project's vocabulary. About 26 KB together — small enough to hand over whole,
> and enough to write against without guessing. Every
> [ADR](./docs/adr/) names the alternative it rejected, so "why not X?" has an
> answer on file rather than being argued out again.

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
| [Static files](./docs/guide/static-files.md) | a directory held in memory, ETags, range requests |
| [Errors](./docs/guide/errors.md) | `fail` functions, the mapping table, what the client sees |
| [Testing](./docs/guide/testing.md) | handlers as functions, and the test client for the rest |
| [OpenAPI](./docs/guide/openapi.md) | a document written from the signatures |
| [Deploying](./docs/guide/deploying.md) | startup errors, panics, shutdown, tuning |

And when you want to know *why* rather than *how*:

| | |
|---|---|
| [`docs/reference.md`](./docs/reference.md) | the same surface as a list — every `Ctx` method, every `App` method, every options struct, one page |
| [`docs/adr/`](./docs/adr/) | design decisions, one per file, each with the alternative it rejected |
| [`CONTEXT.md`](./CONTEXT.md) | the project's vocabulary: what a Service is, what a Str is, what words are avoided |
| [`docs/roadmap.md`](./docs/roadmap.md) | what's next, what's refused, what nobody has decided yet |
| [`docs/history.md`](./docs/history.md) | how 0.1.0 got built, and what has been measured |
| [`CHANGELOG.md`](./CHANGELOG.md) | what changed, per release |

## What it won't do

### Queued up

`permessage-deflate`, compressing a handler's response, and streaming a
multipart upload rather than holding it — each with its reason in
[`docs/roadmap.md`](./docs/roadmap.md).

Broadcasting to WebSockets a handler doesn't hold used to be on this list. It
is [`zfast.Room`](./docs/reference.md#room) now, at 4 measured bytes per idle
connection
([ADR 0038](./docs/adr/0038-a-broadcast-rings-a-bell-it-does-not-write.md)).

### Refused on the record

**Templates.** There is no template layer and none is planned, because rendering
a page means allocating per request and the two numbers below are what zfast is
for. Forms, file uploads, cookies, sessions and redirects all work — a `<form>`
posted to a handler is an ordinary request. But if your application's job is to
produce HTML, [jetzig](https://www.jetzig.dev/) is built for that and this
isn't.

**TLS.** Terminate it in front. The
[deploying guide](./docs/guide/deploying.md#tls-and-the-proxy-in-front) has the
five lines that do it
([ADR 0028](./docs/adr/0028-tls-is-terminated-in-front.md)). HTTP/2 and a gRPC
server follow from the same decision. Static files *are* compressed, once, when
the App is built.

### Sharp edges in 0.1.0

**The `chat` example is an echo server**, not a chat room. zfast does the
handshake, framing, masking, pings and the closing handshake, and a handler
holds its own connection — but sending to a connection some *other* handler
holds is the roadmap item above, blocked on an upstream defect. Two browser tabs
will not see each other yet.

**A session cannot be revoked.** `Session(T)` seals a struct of yours into one
cookie with `XChaCha20Poly1305`, so there is no table, no expiry sweep, no lock,
and nothing added to what an idle connection costs
([ADR 0035](./docs/adr/0035-a-session-is-sealed-into-the-cookie.md)). What that
buys is the flat number below; what it costs is revocation, and the
[guide](./docs/guide/sessions.md#what-it-cannot-do) says so in the same breath.
What a password check is, and where the secret lives, stay yours — the same line
zfast draws around authentication.

## The numbers

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
about 4% of a request's CPU; the rest is `epoll`, `recv`, `send` and the TCP
path. At this payload the top of that comparison is five servers making the same
syscalls and landing in the same place, so the honest reading is that zfast is
*in* the fastest group, not ahead of it. And a handler that touches a database
makes every row of that comparison identical to everybody else's.

The two worth anything are the flat 8,767 and the single allocation, because
they are properties of the design rather than of the machine.

## How the trade-offs get made

Developer experience comes first; performance is pursued as long as it doesn't
make life harder for the user
([ADR 0001](./docs/adr/0001-dx-wins-below-the-10-percent-threshold.md)). That
trade has a budget, and it isn't one number
([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)):

| | |
|---|---|
| Throughput and p99 | DX wins below 10% |
| Allocations per request | a hard invariant — currently 1, held by a test |
| Memory per idle connection | a hard invariant — every feature states its cost |

Throughput is elastic and the bottom two aren't: an extra allocation isn't 10%
slower on average, it's fine a million times and then it's the tail. Those two
rows are what lets zfast say "low memory" at all.

Where the design is borrowed from — FastAPI for the signature, Elysia for
resolved values and plugins, nginx and TigerBeetle for the memory discipline,
Elm for the error messages — is
[ADR 0015](./docs/adr/0015-what-zfast-borrows-and-from-whom.md).

## License

MIT. See [LICENSE](./LICENSE).
