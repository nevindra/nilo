<h1 align="center">nilo</h1>

<p align="center">
  <strong>Your types are the contract. The compiler is the check.</strong>
</p>

<p align="center">
  <a href="https://ziglang.org/"><img alt="Zig 0.16" src="https://img.shields.io/badge/zig-0.16-f7a41d?style=flat-square&logo=zig&logoColor=white"></a>
  <a href="./CHANGELOG.md"><img alt="version 0.2.0" src="https://img.shields.io/badge/version-0.2.0-3b82f6?style=flat-square"></a>
  <a href="./docs/reference.md"><img alt="10 modules" src="https://img.shields.io/badge/modules-10-8957e5?style=flat-square"></a>
  <a href="./refusals/README.md"><img alt="195 refusals" src="https://img.shields.io/badge/mistakes%20refused%20while%20compiling-195-e05d44?style=flat-square"></a>
  <a href="./docs/adr/"><img alt="153 ADRs" src="https://img.shields.io/badge/decisions%20on%20file-153-6b7280?style=flat-square"></a>
  <a href="./LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-16a34a?style=flat-square"></a>
</p>

---

Zig gives you a compiler and not much else. Routing a request, reading settings
out of the environment, hashing a password, creating a table, talking to
Postgres: you write all of that yourself, or you don't ship.

nilo is a toolkit for that layer. Ten modules, one idea. A plain function is a
route. A plain struct is a table. Nothing is annotated anywhere, because the
signature and the field list already say everything nilo needs.

The biggest module is an HTTP server, but the server is not the point. You
import what you use, and Zig never compiles the rest.

| | |
|---|---|
| **One rule** | a pointer is a service, a value is request data. There is no second rule. |
| **One allocation** | per request. A test fails if it ever becomes two. |
| **195 refusals** | mistakes that stop the build with a sentence nilo wrote, held in place by six build steps. |
| **Zero glue** | routing, the 400, the 404, the OpenAPI document and the SQL all read the same struct. |

> **0.2.0**, needs **Zig 0.16**. It used to be called `zfast`. Five things break
> coming from 0.1.0, and [Upgrading](./CHANGELOG.md#upgrading-from-010) lists
> all five with the fix next to each.

## A route is just a function

```zig
fn getUser(db: *Db, id: u32) !?User {
    return db.find(id);
}
```

That is the whole route. No decorator, no annotation, no registration struct.
nilo reads that signature while your program compiles and hands back five
things:

- the URL matching
- `id`, already parsed into a `u32`
- a 400 with a real sentence in it when `id` isn't a number
- a 404 when `db.find` returns `null`
- an OpenAPI document that mentions all of the above

Delete the `?` and the 404 disappears from the document too, because the
document is read from that same signature. There is no second copy of the
contract to keep in step. There is no second copy of anything.

## A whole server

```zig
const std = @import("std");
const nilo = @import("nilo_http");

// Two lines of wiring, once, in your root file. Forget one and
// `listen()` tells you which.
pub const std_options = nilo.std_options;       // engine chatter out of your logs
pub const std_options_debug_io = nilo.debug_io; // `std.log` off the event loop

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

Everything nilo needs to know is in those two signatures, and one rule covers
the whole argument list.

> ### A pointer is a service. A value is request data.
>
> That's it. That's the API.

So the two functions say four things, all of them settled before the program
runs:

| You wrote | It means |
|---|---|
| `db: *Db` | a pointer, so it's a service: the one you handed to `provide` |
| `id: u32` | a value, so it's request data: here `:id`, converted, or a 400 if it won't convert |
| `!?User` | it might not be there, so `null` goes out as a 404, and the API document says so |
| `!Status(201, User)` | the status is part of the type, so the API document names it |

**Registration order doesn't matter.** `/users/new` and `/users/:id` both work
whichever you write first, because matching picks the most specific route rather
than the first one. `use` after `get` still applies. `docs()` can go anywhere.
You can append a route to the bottom of a file without reading what is above it.

And because a handler is an ordinary function taking only what it needs, a test
just calls it:

```zig
test "getUser" {
    var fake = Db.fake(.{ .id = 7 });
    try expectEqual(7, (try getUser(&fake, 7)).?.id);
    try expect(try getUser(&fake, 99) == null);
}
```

No server. No socket. No fake request, no fixture file. Scaffolding is the part
that goes wrong when you write it from a half-remembered example, so there
isn't any.

## The same idea in the other modules

If "your types are the contract" is a good idea, it should keep working once you
leave HTTP. Here it is three more times.

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

No tags on the fields. No schema file. No generated client you re-run a CLI to
refresh.

Here is the part worth stopping on. That query is already a constant in your
binary before the program starts:

```sql
SELECT "id", "org_id", "email", "age", "created_at" FROM "users"
WHERE "age" > $1 ORDER BY "created_at" DESC LIMIT 10
```

The only thing that reaches runtime is the `18`. Drizzle, where this idea comes
from, rebuilds that string on every request, because JavaScript has nowhere else
to build it. Zig has somewhere else.

Which means a typo is a build error instead of a 500 at 3am:

```
$ zig build
error: nilo: User has no column `agee`, asked for in a condition.
       Did you mean `age`?
```

**The same struct also makes the table.** `createMissing` creates every table a
list of Rows describes, and every statement it sends is already in `.rodata`:

```zig
try sql.migrate.createMissing(&db, &run, &.{ Org, User });
```

For a schema that changes, your project gets a `db` command out of a `main` of
ten lines:

```console
$ db check                       # do the Rows and the migrations agree?
$ db generate --name add_nickname
$ db migrate
```

`generate` and `check` **open no database**. Both halves of the diff are files —
your types on one side, a snapshot the repository keeps in git on the other — so
working out a migration needs no shadow copy of a database and no
`DATABASE_URL`, and CI needs no service container. A rename is written in the
type (`.was = .{ .email = "e_mail" }`) rather than guessed from the diff or
asked at a prompt, so the same code produces the same migration for everybody.
A version is one `.zig` file holding a list of steps, and it is exactly what
runs. There is no `down`, and
[ADR 0153](./docs/adr/0153-a-migration-is-a-diff-against-a-snapshot.md) is the
reasoning.

Four words go in the marker, and every one of them is checked while compiling.
`.references` is checked hardest, because both sides have to hold the same
value:

```
$ zig build
error: nilo: User.org_id is []const u8 and points at Org.id, which is i64.
         Two sides of a foreign key hold the same value, so they are the same
         type. One of the two is wrong about its column.
```

That is a bug that normally surfaces at the first insert in production, in a
message about a cast rather than about a design.

Postgres and SQLite, written the same way. Point `DATABASE_URL` at a real
Postgres and the live half of the suite runs against it; without one, those
tests skip and the rest still run.

It is not an ORM and it won't turn into one. No change tracking, which costs a
copy of every row. No lazy relations, which are queries nobody wrote. No
identity map, which is a lifetime bug waiting to happen in a language with no
garbage collector. Joins and aggregates go through `db.raw`, which still fills
your struct and still counts the `SELECT` list against it while compiling. The
line is one sentence: one table, and conditions that filter rows
([ADR 0039](./docs/adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)).

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

The field name, upper-cased, is the variable name. `database_url` is read from
`DATABASE_URL`. A field can be text, a number, a bool, an enum, or any of those
wrapped in `?`. Anything else fails to compile, with a sentence naming the field
and saying why.

If three settings are wrong you get all three at once, instead of fixing one,
redeploying, and finding the next:

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

argon2id, stored as a PHC string any other library can read. One hash costs 13ms
and 19 MiB, which is slow enough to stall every other request sharing that
thread and fast enough that nothing in your log would mention it. So you call
the method on `c` rather than on the module: it moves the work off the event
loop and lets only eight run at a time.

Look at the second call again. `stored` is optional on purpose. Signing in with
an email that has no account does the hashing work anyway, because answering in
one millisecond instead of thirty would quietly turn your login form into a list
of who has an account.

### Three modules, agreeing

`nilo_sql` never imports `nilo_http`. They don't know about each other at all.

But `db.one(...)` returns `?User`. A handler returning `!?User` answers 404. And
the OpenAPI document says the endpoint can answer 404. Three separate pieces of
the toolkit agree without talking to each other, because all three read the same
struct you wrote.

That's the whole thesis. Nothing here is glued together at runtime.

## Install

Zig 0.16 and nothing else. No C library, no system package.

```console
$ zig init                                                          # only if you have no build.zig.zon yet
$ zig fetch --save git+https://github.com/nevindra/nilo?ref=v0.2.0
```

**Keep the `?ref=`.** Without it, `zig fetch` takes whatever `main` happens to be
that day. Two people installing a week apart get two different libraries, and
neither of them asked for a version.

Then hand the modules you want to whatever imports them, in `build.zig`:

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

The package is `nilo` and the module is `nilo_http`. **There is no module called
`nilo`**, because the name belongs to the project rather than to any one part of
it. `nilo_sql`, `nilo_s3`, `nilo_fetch`, `nilo_cache`, `nilo_jwt`, `nilo_config`,
`nilo_pw`, `nilo_id` and `nilo_core` are its siblings, and you add a line above
for each one you actually use. In your own code, alias it back to something
short:

```zig
const nilo = @import("nilo_http");
```

Run `zig build run` and the server further up this page is serving.
[Getting started](./docs/guide/getting-started.md) walks the same ground line by
line.

## Try it

Nine runnable examples live in [`examples/`](./examples/):

```console
$ zig build run-hello      # the smallest thing that serves
$ zig build run-rest       # a service: JSON in and out, query params, auth middleware
$ zig build run-orders     # the same ideas on a domain that is not one flat struct
$ zig build run-forms      # an HTML form, a session cookie, an upload and a redirect
$ zig build run-spa        # a single-page app's files next to its API
$ zig build run-stream     # a streamed report, an event stream, an upload
$ zig build run-chat       # a WebSocket, browser page included
$ zig build run-scheduled  # work that is not a request, owned by the server
$ zig build run-outbound   # calling somebody else's API from inside a handler
```

Read **`rest`** first. Go to **`orders`** when you hit "yes, but what about…":
resources inside resources, a body with structs and lists in it, a state machine
that answers 409, an upsert whose status isn't known until it runs. **`forms`**
is the one for people building a web page rather than an API.

## 🐈 Why it's called nilo

Nilo was my cat. She isn't around any more.

She was quick, the kind of quick you notice from across a room, and cheerful
about it. Nothing ever had to be coaxed out of her. And she spent most of her
time looking after the other cats in the house, which nobody had asked her to do
and nothing made necessary. It was just what she was like.

So this carries her name, because I wanted something of hers still around. It
was called `zfast` before, which said the one thing the project did and nothing
at all about how it should feel to use, and the second half is the one I care
about more. Naming it after her is what made me write that half down.

So that's the brief, and it's why this is a toolkit instead of just a server.
Here are the same three words, in the order they win when two of them disagree.

**Helpful.** Zig hands you a compiler and no ordinary parts. If you pick it up
for an ordinary job, like an API, a form, a settings struct, a password to
store, you should find that job already done, in a module small enough to read
in one sitting. Things get built here because the job is common, not because the
job is interesting.

**Quick.** One allocation per request. 4,669 bytes per idle connection for the
framework itself, flat, plus whatever stack your handler touches. Those are
measurements with tests holding them in place, not adjectives.

**Cheerful.** Nothing here scolds you. When you get something wrong you get a
sentence saying what you did and what to do instead, usually before your program
has finished compiling. Being fast at something you hate using was never the
goal.

The next three sections are those three words, in that order. It is also the
order the trade-offs get made in.

I'd like this to outlive my own use of it, which means other people writing
parts of it. [Contributing](#contributing) is what that takes.

## 🧰 Helpful: what's in the box

| Module | What it does | What isn't in it |
|---|---|---|
| **`nilo_http`** | routing, typed handlers, middleware, cookies and sessions, static files, streaming, WebSocket, OpenAPI, metrics, rate limiting | templates and TLS, both on the record below |
| **`nilo_sql`** | Postgres and SQLite. Your struct is the table, and it makes the table: reads, writes, transactions, streaming, the schema, the diff and the ledger | a command that runs a migration for you. Joins and aggregates, which go through `db.raw`. SQLite refuses batches, row locks and deadlines, and says so while compiling |
| **`nilo_s3`** | object storage: S3, MinIO, R2. Your bucket is a type. Get, put, range, stream, presigned GET and POST | `LIST`, `COPY`, multipart |
| **`nilo_fetch`** | calling somebody else's HTTP API from inside a request: the policy in front of `std.http.Client` | retries, circuit breaker |
| **`nilo_cache`** | an expiring cache in this process: `get`, `put`, TTLs, stats, on a fixed budget with nothing allocated per operation | pointers in a cached value, which is a compile error naming the field |
| **`nilo_jwt`** | checking somebody else's signed token: RS256 and a JWKS | fetching the key set and refreshing it, which is a GET and a cache |
| **`nilo_config`** | settings out of the environment, every bad one named at once | file parsing, and that's a decision |
| **`nilo_pw`** | password hashing: argon2id, stored as PHC | rate limiting the endpoint |
| **`nilo_id`** | UUIDs, v4 and v7 | where the randomness comes from |
| **`nilo_core`** | `Str`, the Scope, the clock and percent coding, shared by the rest | any IO at all, on purpose |

Which module a file belongs in is decided by one question: does it need the
event loop? A module imports downward only and never sideways, which is what
lets two of them be worked on at the same time. `zig build layering` enforces
that, so it's a build step rather than a paragraph in a document
([ADR 0041](./docs/adr/0041-a-module-sits-where-the-loop-puts-it.md),
[ADR 0042](./docs/adr/0042-the-bottom-layer-holds-more-than-one-module.md)).

It's also why `nilo_sql` asks for a Scope instead of a `Ctx`. The same query
runs inside a handler, inside a CLI, or inside a test with no server in the
process.

**The way out is open.** `nilo_fetch` is how a handler dials out, and `nilo_s3`
is the first module built on it
([ADR 0070](./docs/adr/0070-a-fitting-borrows-the-loop.md)). Mail and a Redis
client are unwritten but no longer blocked, which makes them the most useful
thing an outside contributor could pick up.
[`docs/roadmap.md`](./docs/roadmap.md) has the queue, one list per module.

**This isn't going to become a junk drawer**, because there is a bar:

> A part gets in if you can express it as a type you already wrote, checked
> while compiling, with its cost written down.

Does it need an annotation to work? Then it isn't this. Can't say what it costs?
Then it waits until it can.

### What it won't do

| | Why, and where to go instead |
|---|---|
| **Templates** | rendering means a string per request, which is an allocation per request, and that number is fixed here rather than negotiable. If your app's job is HTML, [jetzig](https://www.jetzig.dev/) is built for it |
| **TLS**, and so HTTP/2 and gRPC | terminate it in front. The [deploying guide](./docs/guide/deploying.md#tls-and-the-proxy-in-front) has the five lines ([ADR 0028](./docs/adr/0028-tls-is-terminated-in-front.md)) |
| **Revoking a session** | `Session(T)` is sealed into the cookie, so there is no table, no sweep, no lock, and no way to revoke one ([ADR 0035](./docs/adr/0035-a-session-is-sealed-into-the-cookie.md)) |
| **Parsing config files** | `nilo_config` reads the environment. A TOML parser is weeks of work to arrive where somebody else already is, and depending on one taxes every project that imports the module ([ADR 0043](./docs/adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)) |

None of these are gaps. Each has an ADR naming the alternative it lost to, so if
you think a decision is wrong there's something specific to argue with.

## ⚡ Quick: what it costs

Most frameworks say "fast" and "lightweight". Here are numbers instead.

| | |
|---|---|
| **1 allocation** | per request. A test fails if it ever becomes 2 |
| **4,669 bytes** | per idle connection, for the framework. Flat from 1,000 connections to 10,000. An idle WebSocket is 5,183. A handler adds the stack it touches ([ADR 0063](./docs/adr/0063-a-handlers-stack-is-per-connection.md), [ADR 0071](./docs/adr/0071-where-a-connection-waits-is-what-it-costs.md)) |
| **69µs** | p99 under load: 9.4× below Go's `net/http`, 11× below Fiber |
| **5.4 MB** | idle server |
| **1,401,412 req/s** | on four physical cores, and the least interesting number on this page |

Throughput is the least interesting because
[the benchmarks page says so itself](./bench/result/http.md): at this payload the
top of the table is five servers making identical syscalls, and nilo's own code
is about 4% of a request's CPU. The two numbers that are properties of the
design are the 4,669 and the 1.

### Against eight other servers, same machine, same session

Every candidate serves `GET /users/:id` and returns the **same 982 bytes** of
JSON, verified byte for byte before it is allowed into the table
([`docs/comparison.md`](./docs/comparison.md)):

| | Where nilo lands |
|---|---|
| Throughput | 1st of 9, and inside the noise of http.zig |
| p99 under equal load | 2nd of 9, and 3–45× ahead of everything outside the top two |
| CPU per request | 2nd of 9 |
| Memory, idle server | 2nd of 9, at 5.4 MB |
| Memory per connection | 3rd of 9, and it was 7th before this measurement got the code changed |
| Warm rebuild, release | **last of the five compiled languages**, at 7.4s |

The last row is the honest one. nilo finishing 0.8% ahead of http.zig is not a
result; two servers doing the same syscalls landed in the same place, which is
what should happen. The tail latency is a result, and so is the build time,
against us.

### Binary size

Zig doesn't compile what nothing imports, so an HTTP-only project pays **zero
bytes** for `nilo_sql` and downloads no database driver either. The drivers sit
behind `.sql = true` on the dependency, and `zig build fetch-check -Dnetwork`
builds a project importing only the server and fails if anything but zio lands.
Both halves are measured, and the second only since
[ADR 0075](./docs/adr/0075-a-lazy-dependency-is-a-request.md): before it, the
bytes claim was true and the download claim was 11.1 MB out.

The same holds one level down. A stripped `ReleaseFast` program naming only the
Postgres driver is **1,785,640 bytes**; the same program naming SQLite instead
is **2,291,696**, and the difference is the amalgamation shipping inside your
binary. A program that never calls the migration half links none of it, checked
by building both sides and comparing byte for byte
([`bench/result/sql.md`](./bench/result/sql.md)).

### How the trade-offs get made

Developer experience comes first, and performance comes along as long as it
doesn't cost you anything
([ADR 0001](./docs/adr/0001-dx-wins-below-the-10-percent-threshold.md)). That
trade runs on four axes, not one
([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)):

| Axis | The rule |
|---|---|
| Throughput and p99 | a nicer API wins if it costs under 10% |
| Allocations per request | fixed. Currently 1, held by a test |
| Memory per idle connection | fixed. Every feature states its own cost |
| Binary size | anything the linker can't drop states its measured cost |

Throughput is elastic. The middle two aren't. An extra allocation isn't "10%
slower on average", it's fine a million times and then it's your tail latency.

Two rules keep this from eroding as more parts land. **A feature that can't be
made to fit doesn't ship in a worse shape**, and every change is measured
against all four axes before it's written, not after. Response compression is
what that looks like in practice: the shape that would fit is known, it hasn't
been built, and no allocate-per-request version shipped in the meantime.

## 🙂 Cheerful: what happens when you get it wrong

An error message is a feature right up until somebody refactors it into mush.

So this repository tests its error messages. There are **195 programs in it that
are supposed to fail to compile**, and six build steps checking the wording of
every single failure:

| Step | Programs | Over |
|---|---|---|
| `zig build refusals` | 109 | the framework |
| `zig build refusals-sql` | 59 | queries, rows and schemas |
| `zig build refusals-s3` | 10 | buckets and keys |
| `zig build refusals-config` | 9 | settings |
| `zig build refusals-cache` | 5 | cached values |
| `zig build refusals-pw` | 3 | passwords |

Every one of them tells you what you did *and* what to do about it:

```
$ zig build
error: nilo: route "/users/:user/pets/:pet" has 2 path params (:user, :pet), but its handler only takes 1.
       Path params are matched by position, so the ones at the end would never be read.
       Add the arguments (`id: u32`, `name: nilo.Str`, …), drop the unused `:` from the
       pattern, or ask for a `*Ctx` if you would rather fetch them yourself with `c.param("…")`.
```

You fix that in one pass, without opening a search engine. Mistakes get caught
in three places, in the order you'll meet them.

**While compiling.** An argument nilo can't make sense of. A route pattern that
can't work. Two request bodies in one handler. A column that isn't on your
struct. Two sides of a foreign key holding different types. A setting whose type
nothing can convert into.

**At startup, before a single request is served.** A route registered twice, a
service nobody provided, a line of root wiring missing:

```
error: the route "GET /users/:name" answers the same requests as "/users/:id", which is
       already registered — whichever came second would never run. Drop one, or give them
       different paths. (Param names do not tell two routes apart: "/users/:id" and
       "/users/:name" are the same route.)

error: service *Db was never registered, but 3 routes need it ("/users/:id", "/users",
       "/users/:id/orders") — call app.provide() before app.listen()
```

**While running**, for the two mistakes no compiler can see. Holding request
data past the end of its request is trapped in a Debug build:

```
panic: Str used after its request finished. Request data dies with the request; copy it
       with .keep() while the handler is still running if you need to hold on to it.
```

And a handler that blocks the thread its neighbours share gets timed and named
in the log, in any build:

```
warning: handler GET /report held its thread for 412ms. Every other request being served
         on that thread waited the whole time. Hand the call that waits to
         nilo.blocking (ADR 0014).
```

### This is also why agents do well here

A model doesn't need a special API. It needs three things it can't supply for
itself: a surface small enough to hold all at once, no ordering it has to infer
from code it hasn't read, and a build that says what's wrong instead of a server
that starts anyway.

That's the same list a person in a hurry needs. One rule for the whole argument
list, so there's very little to misremember. Registration order that doesn't
matter, so a new route can go anywhere in the file. 195 held error messages, so
a mistake comes back as a sentence at build time rather than a 500 at runtime.

Point one at [`docs/reference.md`](./docs/reference.md) for the whole API on one
page and [`CONTEXT.md`](./CONTEXT.md) for the vocabulary. Both together are
small enough to hand over whole. Your app also serves its own OpenAPI document
at `/openapi.json`, so a generated client or an agent can read the contract back
out of the running server.

## Documentation

**[The guide](./docs/guide/)** is one page per thing you might want to do, in
the order you'd meet them: getting started, handlers, routing, requests, forms,
responses, cookies, sessions, streaming, WebSocket, middleware, services, static
files, errors, settings, SQL, background work, testing, OpenAPI, metrics,
deploying.

When you want *why* rather than *how*:

| | |
|---|---|
| [`docs/reference.md`](./docs/reference.md) | the entire API surface on one page |
| [`docs/adr/`](./docs/adr/) | 153 decisions, each naming the alternative it rejected |
| [`CONTEXT.md`](./CONTEXT.md) | the vocabulary, and the words this project refuses to use |
| [`docs/roadmap.md`](./docs/roadmap.md) | what's next, what's refused, what's undecided |
| [`docs/history.md`](./docs/history.md) | what got measured, and what turned out to be wrong |
| [`docs/comparison.md`](./docs/comparison.md) | how this sits next to the other Zig options |
| [`bench/result/`](./bench/result/) | every benchmark run, and what each one changed |

## Contributing

This is one person's toolkit so far, and it's built to stop being one.
Questions, issues and "why on earth is it like this?" are all welcome. That last
one especially: if the answer isn't already written down somewhere, that's the
bug.

Nothing load-bearing here lives only in my head. Every design decision has a
file in [`docs/adr/`](./docs/adr/) naming the alternative it beat. The rules are
build steps rather than paragraphs, so `zig build layering` and
`zig build refusals` tell you that you broke something instead of me telling you
in a review three days later. And the roadmap is one list per module, because
two modules touch no file in common and two people can work at the same time
without a merge to negotiate.

**[CONTRIBUTING.md](./CONTRIBUTING.md)** has the rest: what a change has to
carry, where to start, and how to point an agent at this.

## Where the ideas came from

FastAPI, for the signature being the whole contract. Elysia, for resolved values
and plugins. nginx and TigerBeetle, for taking memory seriously enough to put
numbers on it. Elm, for deciding error messages were worth the work. Drizzle,
for the shape of the query.
[ADR 0015](./docs/adr/0015-what-nilo-borrows-and-from-whom.md) says who gets
credit for what.

## License

MIT. See [LICENSE](./LICENSE).
