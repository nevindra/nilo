# zfast

Zig hands you a compiler and gets out of the way. Everything above it (routing,
parsing a request, talking to Postgres) you write yourself, or you don't ship.

**zfast is that layer, and it has exactly one idea: your types are the contract,
and the compiler is the check.**

Here is what that buys. This is a route:

```zig
fn getUser(db: *Db, id: u32) !?User {
    return db.find(id);
}
```

Not a handler you hang a decorator on. The route. zfast reads that signature
while compiling and hands back URL matching, an `id` already parsed into a
`u32`, a **400** with a real sentence when it isn't a number, a **404** when
`null` comes back, and an OpenAPI document that says all three.

Delete the `?` and the 404 leaves the document too. There is no second copy of
anything to keep in step, because there is no second copy of anything.

One rule covers the whole argument list:

> **A pointer is a service. A value is request data.**

That's it. That's the API. No decorators, no macros, no codegen step, no
`schema.yaml`.

> **0.1.0**, the first release · needs **Zig 0.16** · `zfast` is a working name
> and will probably change before 1.0.

## Then we did it again, to SQL

If the idea is any good it should survive leaving HTTP. So: a plain struct is a
table.

```zig
const User = struct {
    pub const zfast_table = .{ .name = "users", .key = .id };

    id: i64,
    email: zfast.Str,
    age: i32,
    created_at: sql.Timestamp,
};

const adults = try db.select(User, c, .{
    .where = .{ .age = .{ .gt = 18 } },
    .order = .{ .created_at = .desc },
    .limit = 10,
});
```

No tags. No schema file. No generated client you re-run a CLI to refresh.

And here's the part worth stopping on. **That query is already a `const` in your
binary before the program starts:**

```sql
SELECT "id", "email", "age", "created_at" FROM "users"
WHERE "age" > $1 ORDER BY "created_at" DESC LIMIT 10
```

Exactly one thing reaches run time, and it's the `18`. Drizzle, whose approach
this borrows, rebuilds that string on every single request, because JavaScript
has nowhere else to do it. Zig has somewhere else.

Which means this is a **build error**, not a 500 at 3am:

```
$ zig build
error: zfast: User has no column `agee`, asked for in a condition.
       Did you mean `age`?
```

> **Where it actually is.** The compile-time half is built and tested: Rows, the
> Postgres dialect, conditions, `SELECT`/`DELETE`, the schema check, 17
> refusals, 70 tests in two optimize modes. Nothing reaches a socket yet, so you
> **can't query a database with this today**. Design and reasoning:
> [ADR 0039](./docs/adr/0039-the-shape-of-a-query-is-settled-while-compiling.md).

One more thing falls out for free. `db.one(...)` returns `?User`, so a handler
returning `!?User` answers 404 **and the OpenAPI document says so**, because the
`?` already meant that. Two modules that never import each other, agreeing,
because they read the same types you wrote.

It is **not an ORM** and won't become one. No change tracking, which is a copy
of every row. No lazy relations, which are queries nobody wrote. No identity
map, which is a lifetime bug waiting for a language with no GC. Joins and
aggregates go through `db.raw`, which still fills your struct. The line is one
sentence: *one table, conditions that filter rows.*

## The bill

Most frameworks say "fast" and "lightweight". Here are numbers instead:

| | |
|---|---|
| **1 allocation** | per request. Held by a test that fails if it becomes 2. |
| **8,767 bytes** | per idle connection. Flat from 1,000 connections to 10,000. |
| **57µs** | p99, **9× below** Go's `net/http` and **11× below** Fiber |
| **5.4 MB** | idle server |

The throughput number (1.4M req/s) is the *least* interesting one and
[the benchmarks page says so](./docs/benchmarks.md): at this payload the top of
the table is five servers making identical syscalls. The two that are actually
properties of the design are the 8,767 and the 1.

## 73 programs written wrong on purpose

Everyone tests that their code works. This repo also tests **that its error
messages still say the right thing**, with 73 programs that are *supposed* to
fail to compile and a build step that checks the wording of every failure.

Because an error message is only a feature until someone refactors it into
mush.

```
$ zig build
error: zfast: route "/users/:user/pets/:pet" has 2 path params (:user, :pet), but its handler only takes 1.
       Path params are matched by position, so the ones at the end would never be read.
       Add the arguments (`id: u32`, `name: zfast.Str`, …), drop the unused `:` from the
       pattern, or ask for a `*Ctx` if you would rather fetch them yourself with `c.param("…")`.
```

Every refusal names what you did **and** what to do instead. Fix it in one pass,
without a search engine. So can your coding agent, and
[that's a whole section](#writing-an-app-against-it-by-hand-or-with-an-agent).

## What's here, honestly

| | | |
|---|---|---|
| **`zfast`** | HTTP: routing, typed handlers, middleware, cookies and sessions, static files, streaming, WebSocket, OpenAPI | **shipped** |
| **`zfast_sql`** | Postgres: your struct is the table | **half-built**: compiles queries, can't run them |

Two modules today. Config, CLI arguments and an HTTP client are the obvious next
ones, because Zig makes you hand-roll all three.

But this isn't going to become a junk drawer, because there's a bar to clear:

> **A part gets in if it's expressible as a type you already wrote, checked
> while compiling, with its cost written down.**

Need an annotation to work? Not it. Can't say what it costs? Doesn't ship until
it can ([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)).
Templates are the first thing that bar turns away
([here's why](#what-it-wont-do)).

Modules stay separate, and it's not tidiness: Zig doesn't compile what nothing
imports, so an HTTP-only project pays **zero bytes** for `zfast_sql` and never
fetches a Postgres driver.

## A whole server

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
| `db: *Db` | a **pointer** is a service, the one you handed to `provide` |
| `id: u32` | a **value** is request data, here `:id`, converted, or a 400 if it won't |
| `!?User` | it may not be there, so `null` goes out as a **404**, and the API document says the endpoint answers 404 |
| `!Status(201, User)` | the status is in the type, so the API document names it |

Answering with a file is the same shape, a return type rather than a side
effect, so the generated document can still see it:

```zig
fn invoice(files: *Files, id: u32) !?zfast.FileBody {
    const name = files.nameOf(id) orelse return null;
    return .{ .dir = files.dir, .name = name, .content_type = "application/pdf" };
}
```

The file is opened inside a directory a Service opened at startup, never a path
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
| **Handlers are ordinary functions** | a test calls one directly. No server, no fake request, no fixture |
| **Mistakes are refused, in words** | at compile time or at startup, a sentence naming your route, your argument and the fix |
| **Order decides nothing** | routes, middleware and `docs()` register in any order. No shadowing, no precedence to keep in your head |
| **The API document writes itself** | OpenAPI 3.1 read off the same signatures, so it can't drift from the code |
| **The memory has a number on it** | 8,767 bytes per idle connection, flat, and one allocation per request. Both held by tests |
| **It says what it won't do** | templates, TLS, HTTP/2, all refused on the record rather than left as a maybe |

## Install

Zig 0.16 and nothing else. No C library, no system package.

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
for people building a web page rather than an API: a `<form>` posted, a session
cookie set, a file uploaded, and a 303 so the reload button behaves.

## Writing an app against it, by hand or with an agent

The same design that makes this pleasant by hand is what makes an agent reliable
on it. A model doesn't need a special API. It needs three things it can't supply
for itself:

- a surface small enough to hold all of at once
- no ordering it has to infer from code it hasn't read
- a build that says what's wrong, instead of a server that starts anyway

**One rule covers the whole argument list.** Pointer is a service, value is
request data. There is no second rule, so there is very little to misremember,
and very little to invent something else in place of.

**Order decides nothing.** Register routes in any order: `/users/new` and
`/users/:id` both work either way, because matching picks the most specific
route rather than the first one
([ADR 0013](./docs/adr/0013-the-most-specific-route-wins-and-duplicates-are-refused.md)).
`use` after `get` still applies. `docs()` before or after your routes. So a new
route can be appended anywhere without reading what is above it, which is how
both a person in a hurry and an agent actually edit a file.

**A mistake is refused rather than tolerated**, in three places, in the order
you would meet them.

*While compiling:* an argument zfast can't make sense of, a pattern that can't
work, two request bodies, a `Form` and a JSON body in the same handler, a column
that isn't on your struct. [The one up top](#73-programs-written-wrong-on-purpose)
is a fair sample of the register.

*At startup, before a single request is served:* a route registered twice, a
service nobody provided, a line of root wiring missing.

```
error: the route "GET /users/:name" answers the same requests as "/users/:id", which is
       already registered — whichever came second would never run. Drop one, or give them
       different paths. (Param names do not tell two routes apart: "/users/:id" and
       "/users/:name" are the same route.)

error: service *Db was never registered, but 3 routes need it ("/users/:id", "/users",
       "/users/:id/orders") — call app.provide() before app.listen()
```

*While running:* the two mistakes no compiler can see. Holding request data past
the request is trapped in a `Debug` build.

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

Those messages don't drift, because
[`refusals/`](./refusals/) and [`sql/refusals/`](./sql/refusals/) hold **73
programs written wrong on purpose** (56 for HTTP, 17 for SQL) and the build
checks the wording of every one
([ADR 0027](./docs/adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).
It's also how a module earns its way in: by bringing its own refusals, not by
being useful.

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
read from the same signatures the router reads. There's no second copy of the
contract to leave stale, and where a signature doesn't say something the
document says `default` rather than guessing
([ADR 0017](./docs/adr/0017-the-api-description-comes-from-the-signatures.md)).
Your app serves it at `/openapi.json`, so a generated client or an agent can
read the contract back out of the running server.

> **Pointing an agent at zfast:** [`docs/reference.md`](./docs/reference.md) is
> the whole API surface on one page, [`CONTEXT.md`](./CONTEXT.md) is the
> project's vocabulary. About 26 KB together, small enough to hand over whole.
> And every [ADR](./docs/adr/) names the alternative it rejected, so "why not
> X?" has an answer on file instead of being argued out again.

## Documentation

**[The guide](./docs/guide/)** is 17 pages, one per thing you might want to do,
in the order you'd meet them: getting started, handlers, routing, requests,
forms, responses, cookies, sessions, streaming, WebSocket, middleware, services,
static files, errors, testing, OpenAPI, deploying.

When you want *why* rather than *how*:

| | |
|---|---|
| [`docs/reference.md`](./docs/reference.md) | the entire API surface on one page |
| [`docs/adr/`](./docs/adr/) | 39 decisions, each naming the alternative it rejected |
| [`CONTEXT.md`](./CONTEXT.md) | the vocabulary, and the words this project refuses |
| [`docs/roadmap.md`](./docs/roadmap.md) | what's next, what's refused, what's undecided |
| [`docs/history.md`](./docs/history.md) | what was measured, and what was got wrong |

## What it won't do

**Templates.** Rendering means building a string per request, which is an
allocation per request, and that number is an invariant here rather than
something to trade. If your app's job is HTML, [jetzig](https://www.jetzig.dev/)
is built for that.

**TLS**, and therefore **HTTP/2** and **gRPC**. Terminate it in front; the
[deploying guide](./docs/guide/deploying.md#tls-and-the-proxy-in-front) has the
five lines ([ADR 0028](./docs/adr/0028-tls-is-terminated-in-front.md)).

**Revoking a session.** `Session(T)` is sealed into the cookie, so there's no
table, no sweep, no lock, and no revocation
([ADR 0035](./docs/adr/0035-a-session-is-sealed-into-the-cookie.md)).

**Query a database.** Not yet. See above.

Everything refused has an ADR naming the alternative it lost to. Everything
queued has a reason in [`docs/roadmap.md`](./docs/roadmap.md).

## How decisions get made

DX first, performance as long as it doesn't cost you anything
([ADR 0001](./docs/adr/0001-dx-wins-below-the-10-percent-threshold.md)). That
trade runs on four axes, not one
([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)):

| | |
|---|---|
| Throughput and p99 | DX wins below 10% |
| Allocations per request | invariant. Currently 1, held by a test |
| Memory per idle connection | invariant. Every feature states its cost |
| Binary size | a feature the linker can't drop states its measured cost |

Throughput is elastic; the middle two aren't. An extra allocation isn't 10%
slower on average, it's fine a million times and then it's your tail latency.

Two rules keep that from eroding as more parts land: **a feature that can't be
made to fit doesn't ship in a worse shape**, and **every change is measured
against all four before it's written**, not after.

Borrowed from FastAPI (the signature), Elysia (resolved values, plugins), nginx
and TigerBeetle (memory discipline), Elm (error messages), Drizzle (the query
shape). Credit and reasoning:
[ADR 0015](./docs/adr/0015-what-zfast-borrows-and-from-whom.md).

## License

MIT. See [LICENSE](./LICENSE).
