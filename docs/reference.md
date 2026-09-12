# Reference

The whole surface, as a list. For what any of it is *for*, see
[the guide](./guide/).

## The modules

Ten ship, and a project links only what it imports
([ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md),
[ADR 0042](./adr/0042-the-bottom-layer-holds-more-than-one-module.md)).

| | | |
|---|---|---|
| `nilo_http` | the server — everything on this page unless it says otherwise | [below](#app) |
| `nilo_sql` | Postgres and [SQLite](#sqlite) | [below](#nilo_sql) |
| `nilo_s3` | object storage — S3, MinIO, R2, anything that speaks it | [below](#nilo_s3) |
| `nilo_id` | UUIDs | [below](#nilo_id) |
| `nilo_config` | settings out of the environment | [below](#nilo_config) |
| `nilo_pw` | password hashing | [below](#nilo_pw) |
| `nilo_cache` | an expiring cache in this process | [below](#nilo_cache) |
| `nilo_jwt` | checking somebody else's signed token | [below](#nilo_jwt) |
| `nilo_fetch` | calling somebody else's HTTP API | [below](#nilo_fetch) |
| `nilo_core` | `Str`, the [Scope](#scope) and [percent coding](#nilo_corepercent), shared by the rest | [below](#run) |

```zig
const nilo = @import("nilo_http");    // the alias everybody writes
const sql = @import("nilo_sql");      // only if you talk to Postgres or SQLite
const s3 = @import("nilo_s3");        // only if you store objects
const id = @import("nilo_id");        // only if you make identifiers
const config = @import("nilo_config");// only if you read settings
const pw = @import("nilo_pw");        // only if you hash passwords
const cache = @import("nilo_cache");  // only if you cache something
const jwt = @import("nilo_jwt");      // only if you verify somebody else's tokens
```

**There is no module called `nilo`.** The word names the project — the `nilo: `
prefix on every Refusal, and the `nilo_table` / `nilo_resolve` / `nilo_start`
markers that go in your own structs. Nothing re-exports the others, because an
umbrella module would cost every project the bytes of every module.

`nilo_http` re-exports what it needs from `nilo_core`, so `nilo.Str` and
`nilo.Run` are the same declarations `nilo_core` holds. A program with no server
in it imports `nilo_core` directly and links no router and no event loop.

## Root wiring

```zig
pub const std_options = nilo.std_options;         // engine chatter → warnings
pub const std_options_debug_io = nilo.debug_io;   // std.log off the event loop
pub const panic = nilo.panic;                     // optional: name the request in a crash
```

## `App`

| | |
|---|---|
| `App.init(gpa)` | a new App. The allocator is for the App's furniture, not for requests |
| `app.deinit()` | |
| `app.provide(&thing)` | register a service, looked up later by its pointer type. A service may declare `pub fn nilo_start(self: *T, io: std.Io) !void` to finish building itself once there is an event loop ([ADR 0040](./adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)) and `pub fn nilo_stop(self: *T) void` to put it down again before the loop goes ([ADR 0151](./adr/0151-a-service-is-stopped-before-the-loop-is.md)). **A service that put work on the loop needs the second one**, or the loop cannot be torn down. A third, `pub fn nilo_ready(self: *T, scope: *nilo_core.AnyScope) ?[]const u8`, is what `app.health` asks ([ADR 0192](./adr/0192-a-health-route-asks-the-services.md)) |
| `app.spawn(f, args)` | work that is not a request, started once the server is up ([ADR 0086](./adr/0086-work-that-is-not-a-request-belongs-to-the-server.md)) |
| `app.use(mw)` | middleware, everywhere |
| `app.useOn(prefix, mw)` | middleware, under a path prefix |
| `app.without(mw)` | the same App with `mw` off for the routes registered through what comes back — how a sign-up route sits inside a guarded prefix ([ADR 0080](./adr/0080-a-route-can-say-it-is-not-covered.md)) |
| `app.with(mw)` | the other direction: the same App with `mw` **on** for the routes registered through what comes back, so one endpoint can be guarded where its neighbours are not ([ADR 0126](./adr/0126-a-route-can-say-what-covers-it.md)) |
| `app.named("listPartners")` | the same App with the next route registered through what comes back carrying that as its `operationId`, instead of the one derived from the method and the path ([ADR 0149](./adr/0149-a-route-can-say-its-own-name.md)) |
| `app.group(prefix)` | a group — see below |
| `app.get / post / put / delete / patch / head / options (pattern, handler)` | a route |
| `app.route(method, pattern, handler)` | any other method |
| `app.static(url_prefix, dir_path)` | a directory, read into memory at startup |
| `app.staticWith(url_prefix, dir_path, options)` | the same, with [options](#static-options) |
| `app.docs(options)` | serve an [OpenAPI document](./guide/openapi.md) |
| `app.health(path)` | a page that says whether this process can do its job — `200 {"status":"ok"}`, or `503` naming the services that are not ready and why, or `503 {"status":"stopping"}` once the server was told to stop. Asks every service that declared `pub fn nilo_ready(self: *T, scope: *nilo_core.AnyScope) ?[]const u8` — null is ready, a sentence is why not ([Deploying](./guide/deploying.md#knowing-whether-it-is-ready), [ADR 0192](./adr/0192-a-health-route-asks-the-services.md)) |
| `app.metrics(options)` | count every request and serve the numbers at `/metrics`, Prometheus format ([Metrics](./guide/metrics.md), [ADR 0100](./adr/0100-the-route-table-is-the-registry.md)) |
| `app.expose(name, kind, &atomic)` | publish a `std.atomic.Value(u64)` of your own on that page. `kind` is `.counter` or `.gauge` |
| `app.listen(options)` | run until stopped. Stops the process on a startup error |
| `app.start(io)` | everything `listen()` does before it accepts anything — services checked, chains resolved, pools opened, schemas checked. For a migration, a script or a test; `listen()` does not repeat it ([ADR 0079](./adr/0079-there-is-a-phase-before-the-server.md)). What it does *not* start is `spawn`, which needs a server |
| `app.shutdown()` | stop, from any thread or from inside a handler |
| `app.tryListen / tryRoute / tryStatic / tryStaticWith` | the same calls, error returned rather than reported |
| `app.checkServices()` | `error.MissingService` if a route needs one nobody provided |
| `app.routes()` | every route, in registration order — a view rather than a copy. `.len()`, `.at(i)` and `{f}` ([ADR 0127](./adr/0127-a-route-pattern-is-the-name-of-its-url.md)) |

`pattern` and `handler` are `comptime`. Registration order never matters.

### `Group`

`app.group("/api")` returns one. It has `group`, `use`, `useOn`, `without`,
`provide`, `get`, `post`, `put`, `delete`, `patch`, `head`, `options`, `route`,
`tryRoute`, `static`, `staticWith`, `tryStatic`, `tryStaticWith` — the same as an
App, minus `listen`, `docs` and `shutdown`. The prefix is compile-time text and
must be literal; the type is `nilo.Group("/api")`.

`@TypeOf(g).mounted_at` is where it is mounted — `"/api"`, and `""` for an App,
so a plugin taking `anytype` can ask either.

`g.without(mw)` is the same group with `mw` off for the routes registered
through it, which is how the two routes that create a session sit inside a
prefix that requires one. Its type is `nilo.GroupOf("/api", &.{mw})`.

`g.with(mw)` is the other direction, for a route that wants *more* than its
neighbours. A carried middleware runs innermost, and both `with` and `without`
match on the joined pattern **and the method**, so a `DELETE` guard does not
cover the `GET` beside it. They compose:

```zig
const v1 = app.group("/v1");
try v1.use(requireOperator);
try v1.without(requireOperator).with(rateLimitSignups).post("/sign-up", signUp);
```

### `listen` options

| | Default |
|---|---|
| `address` | `"127.0.0.1"` — an address, not a host name. `"unix:/run/nilo.sock"` listens on a path ([ADR 0130](./adr/0130-a-path-is-an-address-to-listen-on.md)) |
| `port` | `8787` — not read when `address` names a unix socket |
| `threads` | `0` (one per core) |
| `read_buffer` | `8 * 1024` — also the ceiling on a request head |
| `write_buffer` | `4 * 1024` |
| `arena_keep` | `16 * 1024` — of a connection's request arena, kept between requests |
| `reuse_address` | `true` — on a unix socket, removes a socket file left behind by a process that is gone |
| `stop_on_signal` | `true` — Ctrl-C and SIGTERM |
| `shutdown_grace_ms` | `10_000` |
| `header_timeout_ms` | `10_000` — the whole head, from its first byte |
| `idle_timeout_ms` | `75_000` — a connection between requests |
| `body_timeout_ms` | `30_000` — any one read of a body |
| `body_min_rate` | `8 * 1024` — bytes a second a buffered body has to keep up. `0` = off |
| `body_grace_ms` | `10_000` — before the rate is asked for |
| `write_timeout_ms` | `30_000` — any one write to the client |
| `max_connections` | `10_000` — held at once, 4,669 bytes each when idle. `0` = no limit |
| `max_in_flight` | `0` — the most requests answered at once; past it a request is a `503` with `Retry-After: 1` at once rather than a place in a queue. `0` = no limit ([ADR 0197](./adr/0197-a-server-past-its-limit-says-so-at-once.md)) |
| `max_body` | `1024 * 1024` — the most `c.body()` reads into the arena. One route can say its own with [`nilo.maxBody(bytes)`](#nilomaxbody) |
| `trusted_hops` | `0` — how many proxies stand in front, for `c.clientIp()` |
| `trusted_proxies` | `&.{}` — **which** ones: CIDRs, bare addresses, `"private"`, `"loopback"`. Wins over `trusted_hops` ([ADR 0129](./adr/0129-a-proxy-is-trusted-by-which-one-it-is.md)) |
| `session_secret` | `null` — 32 bytes, for `Session(T)`. The same on every instance |
| `block_warning_ms` | `250` — say so when a handler holds its thread. `0` = off |

**`arena_keep` is the one in that table with a cliff under it.** A response
larger than it does not fit in what the arena retains, so the block goes back to
the operating system after every request and the next one faults it in a page at
a time — 257 minor faults for a megabyte, with the kernel zeroing each page. A
server that assembles large responses in `c.arena()` should set this just past
the largest of them, and no higher: the memory is held **per connection**, so a
megabyte here across ten thousand connections is ten gigabytes
([ADR 0096](./adr/0096-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)).
Leaving it alone is right for a server whose responses fit in 16 KiB.

Each of the four deadlines bounds one wait for the network, not a request, so a
long upload or an hour-long stream is not hurried by any of them. `0` turns one
off. See [Deploying](./guide/deploying.md#deadlines).

Past `max_connections` a connection is accepted and closed at once — no request
read, no status sent
([why](./guide/deploying.md#how-many-connections-at-once)).

### `metrics` options

`app.metrics(.{ … })`, all `comptime`.

| | Default |
|---|---|
| `path` | `"/metrics"` — an ordinary route, so middleware in front of it applies |
| `buckets` | `100, 500, 1_000, 5_000, 10_000, 50_000, 100_000, 1_000_000` — latency boundaries in microseconds, climbing. Reported as seconds |

What goes on the page: `nilo_requests_total{method,route,status}` by status
class, `nilo_request_duration_seconds` as a histogram, `nilo_responses_total`
by exact code for the whole process, `nilo_requests_in_flight`, and anything
`app.expose` was given.

Counted per **route**, not per path — `/users/1` and `/users/2` are both
`/users/:id`. Five slots are not routes: `<unmatched>`, `<method not allowed>`, `<shed>`,
`<static file>` and `<unparsed>`. A route that has answered nothing has no
series at all. See [Metrics](./guide/metrics.md).

## Handler arguments

| Argument | Passed in |
|---|---|
| `*Ctx` | the request itself |
| `*Db`, `*const Config` | a service, by type |
| `u32`, `f64`, `Str`, `bool`, an enum | a path param, positionally |
| a type with `nilo_parse` | a path param too — `sql.Uuid` is one |
| `Query(T)` | the query string as a struct |
| `FromHeader("X-Staff-Id", T)` | one request header, converted like a path param |
| `Authorization(.bearer)`, `Authorization(.{ .basic = "realm" })` | the `Authorization` header as one scheme — absent or another scheme is a 401 with the challenge on it |
| `Idempotent(Replays, .{ .by = fn })` | the `Idempotency-Key` header, and with it the route answering once per key: a retry gets the kept answer back and the handler does not run |
| `Form(T)` | the body as an HTML form — urlencoded or multipart |
| `Bound(W)` | any of the three above, with its failures instead of a 400 |
| `Session(T)` | the session, out of its cookie |
| `std.mem.Allocator` | the request arena |
| a type with `nilo_resolve` | a resolved value |
| any other struct | the body, parsed from JSON |

A body field may be `Patch(T)`, which tells "not sent" from "sent as null":
`.absent`, `.cleared`, `.value`. Give it `= .absent` as its default;
`.orNull()` collapses the two empty cases.

**A path param may also be a type that parses itself.** Give a type
`pub fn nilo_parse(text: []const u8) ?Self` and nilo calls it with the segment,
answering 400 when it returns null — so a malformed uuid is refused at the
router instead of in every handler. `sql.Uuid` already carries it:

<!-- compiles -->
```zig
fn showDoc(db: *Db, c: *nilo.Ctx, doc_id: sql.Uuid) !?Doc {
    return db.find(Doc, c, doc_id);
}
```

on `/docs/:doc_id` is the whole of it. What the document says about the param comes
from the type as well: a `Uuid` publishes `{"type":"string","format":"uuid"}`
through its `nilo_openapi`, so a generated client gets the format rather than a
bare string. The declaration is looked for by name and never imported, which is
what lets a module in the bottom layer offer it
([ADR 0142](./adr/0142-a-path-param-can-parse-itself.md)).

**A `Query(T)` or `Form(T)` field takes one too**, and for the same reason: one
arrival has one answer, so `/deals/:id` and `?actor=<uuid>` cannot read the same
type two different ways
([ADR 0158](./adr/0158-one-arrival-one-answer.md)). So a field is a `Str`, a
number, a `bool`, an enum, **or a type with `nilo_parse`** — `sql.Uuid` and
`sql.Timestamp` both are — optionally in a `?`, and a `Form(T)` field may also
be an `Upload`.

`Form(T)` and a plain struct are the same slot — a form *is* the body — so
asking for both is a compile error. A `Form(T)` field is a `Str`, a number, a
`bool`, an enum or an `Upload`, optionally in a `?`; a default is what "not
sent" means. See [Forms](./guide/forms.md).

### `FromHeader(name, T)`

One request header, as an argument the signature declares
([ADR 0163](./adr/0163-a-header-a-handler-can-be-given.md)):

<!-- compiles -->
```zig
fn addComment(
    actor: nilo.FromHeader("X-Staff-Id", sql.Uuid),
    tracing: nilo.FromHeader("X-Request-Id", ?Str),
) !usize {
    _ = actor.value;
    const asked = tracing.value orelse return 0;
    return asked.len();
}
```

`.value` is the header, converted the way a path param is: a `?T` is null when
the header is not sent, anything else is a 400 saying which header is required,
and text that will not convert is the same 400 in the same words. Two of them
on one handler is ordinary — unlike `Query(T)`, which is one struct.

`c.header("X-Staff-Id")` still reads it and is not going anywhere. What the
wrapper adds is the generated document: a header parameter, so a client built
from the OpenAPI knows the endpoint needs one. The name is checked while
compiling — empty, or anything that is not a header token, is a Refusal.

**`FromHeader` and not `Header`**: `nilo.Header` is the response side, and has
been since 0.2.0.

### `Authorization(scheme)`

The `Authorization` header, read as the one scheme the endpoint takes
([ADR 0191](./adr/0191-an-authorization-header-a-handler-can-ask-for.md)):

<!-- compiles -->
```zig
fn whose(auth: nilo.Authorization(.bearer), db: *sql.Db, c: *nilo.Ctx) !User {
    return try db.one(User, c, .{ .where = .{ .email = auth.value } }) orelse
        return nilo.Authorization(.bearer).refuse("that token is not one of ours", .{});
}

fn admin(auth: nilo.Authorization(.{ .basic = "admin" })) !nilo.Status(204, void) {
    if (!std.mem.eql(u8, auth.user.view(), "root")) {
        return nilo.Authorization(.{ .basic = "admin" }).refuse("not for {s}", .{auth.user.view()});
    }
    return .{};
}
```

| | |
|---|---|
| `.bearer` | `.value` is the token as sent — the bytes after the scheme, blanks trimmed, nothing decoded |
| `.{ .basic = "realm" }` | `.user` and `.password`, base64 opened and split at the **first** colon. The realm is required (RFC 7617) and is what the browser's prompt shows |
| `T.challenge` | the `WWW-Authenticate` value — `Bearer`, or `Basic realm="…"` |
| `T.refuse(fmt, args)` | `fail.unauthorized` with `T.challenge` on it — for the refusal *after* reading, when the token did not verify or the password did not match |
| `c.authorization(scheme)` | the same read from a resolver or a middleware, which have no argument list |

The scheme is matched case-insensitively (RFC 9110 §11.1), and **every 401
carries `WWW-Authenticate`** (§15.5.2) — the two things the hand-written six
lines got wrong in both places this repository had them. Absent, another
scheme, an empty token, Basic that is not base64 or has no colon: each is a
401 saying which, before the handler runs. In the document, a `security`
entry and a 401 rather than a parameter, so a generated client signs in.

Bearer allocates nothing; Basic decodes into the request arena, once. There is
no chain that also looks in the query string or a cookie, on purpose: a token
in a query string is a token in every access log on the way here.

### `Idempotent(Replays, options)`

The `Idempotency-Key` header, as the argument that makes a route answer once
per key ([ADR 0193](./adr/0193-a-request-answered-once-is-answered-the-same-way-again.md)):

<!-- compiles -->
```zig
const Replays = cache.Space("orders-replay", []const u8, .{ .ttl_s = 86_400, .max_bytes = 16 << 10 });

fn account(c: *nilo.Ctx) ?Str {
    return c.header("X-Account");
}

const NewOrder = struct { sku: Str, qty: u32 };
const Placed = struct { id: u64, sku: Str };

fn placeOrder(key: nilo.Idempotent(Replays, .{ .by = account }), body: NewOrder) !nilo.Status(201, Placed) {
    _ = key;                                 // the header as sent, if the handler wants it
    return .{ .value = .{ .id = 7, .sku = body.sku } };
}
```

The first request with a key runs the handler and **keeps what it returned** —
status, the `Response(T)` headers of its own, the body. Every later request
with that key gets the kept answer back, byte for byte, with
`Idempotent-Replayed: true` on it, and the handler does not run. What the
handler *failed* with is not kept, so a retry after a `fail.…` or an error
runs it again.

| | |
|---|---|
| `Replays` | where answers are kept: a `cache.Space` holding `[]const u8`, `app.provide`d. Any type with `getInto`, `putIfAbsent`, `put`, `del`, `max_bytes` and `Held` will do, which is what a table over Redis would carry |
| `.by` | whose key it is — a function of one `*Ctx` answering `?Str`. Two callers choosing the same key must never see each other's answer, so leave it null only on an endpoint with one caller. Null from the function is a 403 |
| `.key` | the header as sent |

Before the handler runs, and each with the header named: **400** with no
`Idempotency-Key` or one over 255 bytes; **409** when the same key is still
being answered; **422** when the key is reused on a different request — the
method, path, query and body are fingerprinted. In the document, a required
header parameter and the two extra answers. A handler that returns nothing, a
file or a redirect has no answer nilo can keep, and is a Refusal.

On the route that asks, and nowhere else: one arena allocation of the
Space's `max_bytes` to read a kept answer into, one to encode the answer being
kept, and the JSON buffer the answer was taking anyway. Nothing on the stack.

### A query field that is a list

A `Query(T)` field may be a slice, and every arrival of that name is one
element ([ADR 0164](./adr/0164-a-query-parameter-that-is-a-list.md)):

<!-- compiles -->
```zig
const Filter = struct {
    tag: []const Str = &.{},
    limit: u32 = 20,
};

fn search(q: nilo.Query(Filter)) !usize {
    return q.value.tag.len;
}
```

**Both spellings are read**: `?tag=a&tag=b&tag=c` and `?tag=a,b,c` are the same
three elements, in the order they arrived, allocated from the request arena.
`?tag=a,b` is what nilo writes into the document — `"style":"form"`,
`"explode":false` — and `?tag=a&tag=b` is what half the clients in the world
send anyway; a server that takes the first and drops the rest answers with fewer
rows, which looks exactly like a filter that worked.

An empty value contributes nothing, so `?tag=` is an empty list rather than a
list holding one empty string — which is also why a list field wants `= &.{}`
rather than being required, and why it is never `required` in the document.
That is the cost of the separator: a value with a comma in it cannot be sent.

**"Not sent" and "sent empty" cannot be told apart**, and `?[]const Str` is not
the way out: it compiles, and it answers null for both. What an optional list
changes is only what *nothing* is spelled as — null instead of `&.{}` — not
which nothing it was. Every filter written against a list has so far meant the
same thing by either, which is why there is no second spelling for it.

The element converts exactly like a scalar field would, so `[]const Kind` for an
enum refuses `?kind=nope` with the same sentence a single `kind` gets, and under
`Bound(Query(T))` it is the **first** bad value that is reported. A list of
something a query value cannot become at all is a Refusal.

### `Bound(W)`

`Bound(Form(T))`, `Bound(Query(T))`, `Bound(T)` for a JSON body. Occupies the
same slot as what it wraps.

| | |
|---|---|
| `b.value()` | `?T` — the binding, or null if **any** field failed |
| `b.fail()` | a 422 naming every field that did not bind |
| `b.failed()`, `b.failedCount()` | whether, and how many |
| `b.failures()` | an iterator of `Failure` |
| `b.given("name")` | `Str` — the text that arrived, bound or not. Name checked while compiling |
| `b.must("name", holds, "wants …")` | a rule of your own, added to the same answer → `Checked` |
| `Bound(W).ok(value)` | a binding where everything bound, for a test calling the handler directly |

A `Failure` carries `field`, `reason`, `given`, `kind`, `expected`, `said`, and
`say(w)` — nilo's own sentence for it. `reason` is one of `.missing`,
`.not_a_number`, `.not_true_or_false`, `.not_a_choice`, `.wrong_kind`, or
**null when the failure is a rule of yours**; that is the whole list, and it is
not a validator. Nothing is allocated per failed field. See
[Forms](./guide/forms.md#when-one-field-is-wrong-and-the-rest-are-fine)
and [ADR 0036](./adr/0036-a-binding-hands-its-failures-to-the-handler.md).

`must` returns a `Checked`, which has the same `value`, `failed`,
`failedCount`, `given`, `failures` and `fail`, and one more `must` to chain.
`holds` is the rule holding, not failing. A handler that checks no rules never
builds one and pays nothing
([ADR 0082](./adr/0082-a-rule-of-your-own-joins-the-answer.md)).

## Handler returns

| Returned | Response |
|---|---|
| `void` | 200, empty, no `Content-Type` |
| `Str`, `[]const u8` | 200, `text/plain` |
| anything else | 200, that value as JSON |
| `?T` | 200 with the value, **404** when null |
| `Status(code, T)` | that status — and the API description names it |
| `Response(T)` | a status chosen at runtime; the description says `default` |
| `Redirect(code)` | that status and a `Location`, no body |
| `FileBody` | a file on disk, opened and sent without being held in memory |
| a type with `nilo_content_type` and `nilo_write` | 200, the bytes `nilo_write` wrote, under that content type — [below](#a-type-that-writes-its-own-answer) |

```zig
Status(201, User){ .headers = .of(&.{…}), .value = user }
Status(204, void){}                                        // an empty response
Response(User){ .status = if (made) 201 else 200, .value = user }
Redirect(303).to("/welcome")                               // written `return .to(…)`
Redirect(303).with("/welcome", .of(&.{…}))                 // …with headers of its own
FileBody{ .dir = files.dir, .name = name }                 // `?FileBody` — null is a 404
```

**A handler that also takes a `*Ctx` and returns `void` is the one case the
document cannot describe.** It sends 200 with an empty body if the handler
wrote nothing, and whatever the handler wrote if it did, and nilo has no way to
tell which from the signature — so the description says it does not know, and
`listen()` says how many routes are in that state. A handler that means "200,
empty" says so by returning `Status(200, void)` and is described like anything
else ([ADR 0150](./adr/0150-a-ctx-handler-that-returns-nothing-may-have-written-it.md)).

`Redirect` takes 301, 302, 303, 307 or 308; anything else is a compile error.
303 is the one a form POST wants.

`FileBody` fields: `dir` (a [`Dir`](#dir)), `name`, `content_type`
(`"application/octet-stream"`), `cache_control` (`""`) and `headers` — a
`Content-Disposition` goes in the last of those, and there is no `download_as`.
The name is checked before it is opened: a `..` segment, an absolute path, a NUL
— and on Windows a backslash or a drive letter — answer the same 404 a missing
file does. `Range`, `If-Range`, `If-None-Match` and `HEAD` work as they do for a
static file; the API description says the body is `application/octet-stream`
with `format: binary` whatever the content type is at run time. See
[Responses](./guide/responses.md#files).

`Headers` holds up to 8 by value; a ninth is a compile error.

### A type that writes its own answer

XML for a consumer that will not change, CSV for a spreadsheet, HTML from a
template of your own: a type carrying two declarations goes out as whatever it
writes, under the label it names
([ADR 0195](./adr/0195-a-type-can-write-its-own-answer.md)).

<!-- compiles -->
```zig
const Invoice = struct {
    number: u32,
    total: i64,

    pub const nilo_content_type = "application/xml";
    pub const nilo_openapi = .{ .type = "string" };

    pub fn nilo_write(self: Invoice, w: *std.Io.Writer) !void {
        try w.print("<invoice><number>{d}</number><total>{d}</total></invoice>", .{ self.number, self.total });
    }
};

fn showInvoice(number: u32) ?Invoice {
    if (number == 0) return null;
    return .{ .number = number, .total = 1500 };
}
```

Every wrapper works the way it does for JSON: `?Invoice` is a 404 when null,
`Status(201, Invoice)` is a 201, `Response(Invoice)` carries headers, and an
`Idempotent` route keeps the answer with its label. The body is written into
the request arena the way a JSON one is — one allocation, the same one — and
nothing is linked by a program with no such type.

**Both declarations or neither.** One without the other is a compile error, and
so is an empty content type, one with a control character in it, or a
`nilo_write` with any other signature. The document names the content type and
describes the body with `nilo_openapi` when the type carries one — `{}` and a
note otherwise, the way a type that writes its own JSON is described. nilo
knows nothing about XML, CSV or HTML and does not parse any of them on the way
in; a body arriving in one of those is `c.body()`.

## JSON shapes

A struct is its fields and an enum is its tag name. A type that wants something
else says so with `nilo_json`, which is plain data and is read while compiling
([ADR 0085](./adr/0085-a-type-says-how-its-json-is-spelled.md)).

<!-- compiles -->
```zig
const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const nilo_json = .{ .tag = "signal", .rename_all = .@"kebab-case" };
    pub const jsonParse = nilo.jsonParseFor(@This());

    metrics: struct { threshold: f64 },
    log_volume: struct { query: []const u8 },
    disabled,
};
```

| | |
|---|---|
| `.tag` | the discriminator's key. A `union(enum)` only: the variant's name goes under it, and the variant's own fields go beside it in the same object |
| `.rename_all` | how a name is spelled on the wire — an enum's tag, a union's variant, or **a struct's field names** |

`.rename_all` takes `.lowercase`, `.UPPERCASE`, `.camelCase`, `.PascalCase`,
`.SCREAMING_SNAKE_CASE` and `.@"kebab-case"`. The first two join the words
(`not_found` → `notfound`); `.SCREAMING_SNAKE_CASE` keeps the underscore. There
is no `.snake_case` — that is what a Zig field name already is, and asking for
it is a compile error rather than a no-op. Two names that land on one is also a
compile error, in every shape: it would put the same key in an object twice.

### A struct that renames its fields

A Row is snake_case because Postgres is and a wire is camelCase because the
browser is. Saying so once beats a mapping function written out field by field,
which is what a DTO layer is and which nothing holds against the Row it came from
([ADR 0181](./adr/0181-a-field-name-is-a-spelling-too.md)):

<!-- compiles -->
```zig
const Contact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    id: u32,
    full_name: []const u8,   // goes out as "fullName"
    partner_id: u32,         // and "partnerId"
};
```

The API description says the same keys, so a generated client reads what the
server sends. It costs nothing per request: the name is a comptime string either
way, written as part of the same call the punctuation is in.

**It is a spelling for what goes *out*, and using one for what comes in is a
Refusal.** `std.json` chooses the parser for a body and reads it into the field
names as they are written, so such a type would document `fullName` and answer
400 to a client that sent it. A struct with `rename_all` used as a request body,
a form or a query string is a compile error naming the route. Give what comes in
a struct of its own, spelled the way the wire spells it.

A renamed struct nilo's own writer cannot reach is refused as well. One shape it
does not recognise — a tuple, an array of bytes, an untagged union, a type that
writes its own JSON and says nothing about it, anything past eight deep — sends
the whole value to `std.json`, which does not read the marker.

**A type that writes its own JSON *and says what it looks like* is a leaf rather
than one of those**, and that is the difference between a marker that can be used
here and one that cannot
([ADR 0182](./adr/0182-a-leaf-that-says-what-it-is-can-be-carried.md)). A
`nilo_openapi` may only name `"string"`, `"integer"`, `"number"` or `"boolean"`,
so a type carrying one has promised its JSON is a single scalar — which is the
promise the writer needs to keep writing the object around it. `sql.Uuid`,
`sql.Timestamp`, `sql.AsText` and `id.Uuid` are all leaves, so a Row-shaped
response holding any of them can rename its fields:

```zig
const Contact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    id: sql.Uuid,            // still "id", and still 36 characters
    full_name: nilo.Str,     // goes out as "fullName"
    created_at: sql.Timestamp,  // "createdAt", still RFC 3339
};
```

It is also worth 33% of such a response whether or not anything is renamed:
`covers` is answered for the *whole* value, so one leaf used to send every string
beside it to `std.json` as well — 250ns → 165ns on a 305-byte row with three
uuids in it ([`bench/result/http.md`](../bench/result/http.md)). Your own type
gets the same by writing the same two declarations.

**The marker is per type, not inherited.** A struct renames its own fields; a
union renames its *variants* and leaves a payload struct's fields to that
struct's own marker; a nested struct that says nothing keeps its own spelling.

`nilo.jsonParseFor(@This())` is the reader, and it is a second line because
`std.json` picks the parser for a type and nothing can add a declaration to a
type you wrote. Only needed if the type arrives in a request; sending needs
nothing. Adding it to a type with no `nilo_json` is a compile error, and so is
adding it to a struct that only renames — there is nothing for the reader to do
differently.

Without a marker a `union(enum)` is externally tagged — `{"metrics":{…}}`, what
`std.json` writes — and it is written by nilo's own writer either way. An
*untagged* union has nothing saying which arm is live and is left to `std.json`
whole. A variant carrying no payload is legal under `.tag` and is the
discriminator on its own; under the default encoding it is not covered.

The generated API description follows whichever encoding the type asked for:
`oneOf` of one-key objects for the default, and `oneOf` with `discriminator`
plus a per-arm `allOf` for a tagged one. See
[Responses](./guide/responses.md#json-shapes-of-your-own).

**A `[]const u8` or a `Str` that is not valid UTF-8 goes out as an array of
byte values** — `{"name":[255]}` — because JSON has no way to carry a byte that
is not text. That is what `std.json` does with the same value, and this writer's
whole contract is to write what `std.json` writes
([ADR 0121](./adr/0121-a-byte-that-is-not-text-is-not-a-string.md)). The
description still calls the field a string, since the type is text and only the
value is not.

## `Ctx`

### Reading

| | |
|---|---|
| `c.method` | `.GET`, `.POST`, … |
| `c.path()` | `Str` — the path, without the query string |
| `c.param(name)` | `?Str`, percent-decoded. `"*"` for a catch-all |
| `c.query(name)` | `?Str`, percent-decoded, `+` as space |
| `c.queries()` | an iterator over every query parameter, in arrival order — `while (it.next()) \|q\|`, `q.name` and `q.value` are `Str`. A name sent twice appears twice |
| `c.queryString()` | `Str` — the query as it arrived, still encoded, no `?` on the front. `""` when there was none |
| `c.host()` | `Str` — the host this request was addressed to. `X-Forwarded-Host` under `trusted_hops`, else the authority of an absolute-form target, else the `Host` header |
| `c.scheme()` | `Str` — `"https"` or `"http"`, what the **client** used. `X-Forwarded-Proto` under `trusted_hops`, else always `"http"` |
| `c.header(name)` | `?Str`, name matched case-insensitively. The **first** of that name |
| `c.authorization(.bearer)` | `!Authorization(.bearer)` — the header as one scheme, or the 401 with the challenge on it. For a resolver; a handler asks in its argument list |
| `c.headers()` | an iterator over every header, in arrival order — `while (it.next()) \|h\|`, `h.name` and `h.value` are `Str` |
| `c.cookie(name)` | `?Str` — as the client sent it, nothing decoded. Allocates nothing |
| `c.body()` | `!Str` — the whole body, up to `max_body` (1 MB) |
| `c.json(T)` | `!T` — the body parsed as JSON |
| `c.form(T)` | `!T` — the body parsed as a form, urlencoded or multipart |
| `c.jsonCollecting(T, &outcomes)` | `!T` — as `json`, recording why each field failed |
| `c.formCollecting(T, &outcomes)` | `!T` — as `form`, recording why each field failed |
| `c.requestId()` | `Str` — this request's id, from `X-Request-Id` or generated |
| `c.entropy(n)` | `![n]u8` — unguessable bytes from the OS, off the event loop. `n` is comptime |
| `c.entropyInto(buf)` | `!void` — the same, at a width nobody said while compiling |
| `c.hashPassword(gpa, text)` | `!pw.Hash` — argon2id, salted, off the loop and behind the Gate |
| `c.hashPasswordWith(cost, gpa, text)` | the same, at a `pw.Cost` of your own |
| `c.verifyPassword(gpa, stored, text)` | `!bool` — `stored` is `?[]const u8`; null means no such account |
| `c.verifyPasswordWith(cost, gpa, stored, text)` | the same, told what a hash of yours costs |
| `c.bodyStream()` | `!Body` — the body in pieces |
| `c.bodyStreamWith(.{ .max_bytes = … })` | the same, with a ceiling. Default 64 MB |
| `c.peer()` | the address the connection came from — the proxy's, if there is one |
| `c.clientIp()` | `Str` — the client, looking through `trusted_proxies` or `trusted_hops`. Empty on a unix socket with neither set |
| `c.stopping()` | `bool` — the server has been told to stop and is draining. What the health page answers `stopping` on |
| `c.overdue()` | whether the deadline `nilo.deadline(ms)` gave this route has passed. Always false without one |
| `c.timeLeftMs()` | `?u32` — milliseconds left, `null` without a deadline, `0` once it has gone |
| `c.giveDeadline(ms)` | set one by hand. `nilo.deadline(ms)` is what normally calls this |
| `c.giveBodyLimit(bytes)` | how much body this request may read into the arena, over `listen()`'s `max_body`. `nilo.maxBody(bytes)` is what normally calls this; a body already read keeps the limit it was read under |
| `c.service(*Db)` | `?*Db` |
| `c.resolve(V)` | `!V` — a resolved value, worked out once per request |
| `c.keepAlive()` | whether the connection will carry another request |
| `c.arena()` | `std.mem.Allocator` — memory that lasts exactly this request. Never freed by hand |
| `c.str(bytes)` | `Str` — text you allocated from `c.arena()`, stamped with this request's lifetime |

### Answering

| | |
|---|---|
| `c.setHeader(name, value)` | copied into the request arena |
| `c.setStaticHeader(name, value)` | not copied — for text that already outlives the request |
| `c.setCookie(cookie)` | a `Set-Cookie`. Calling it twice sets two, not one |
| `c.clearCookie(.{ .name = …, .path = …, .domain = … })` | delete one. Path and domain have to match |
| `c.redirect(status, location)` | a `Location` and no body |
| `c.send(status, content_type, bytes)` | |
| `c.sendText(status, text)` | `text/plain` |
| `c.sendJson(status, value)` | `application/json` |
| `c.sendEmpty(status)` | no body and no `Content-Type` — a 204, usually |
| `c.sendFile(.{ .file = f, .content_type = … })` | an open file. **Closed here**, on every way out |
| `c.stream(status, content_type)` | `!Stream` |
| `c.streamWith(status, content_type, .{ .buffer = … })` | the same, buffer of your own. Default 4 KB |
| `c.streamWith(…, .{ .length = n })` | a stream whose length is already known: `Content-Length` and no chunk framing ([ADR 0128](./adr/0128-a-stream-that-knows-its-length-says-so.md)) |
| `c.url(pattern, args)` | `!Str` — a URL for a route, every value percent-encoded and every mistake a compile error ([ADR 0127](./adr/0127-a-route-pattern-is-the-name-of-its-url.md)) |
| `c.events()` | `!Events` |
| `c.upgrade(loop, state)` | `!void` — the connection becomes a WebSocket and `loop` reads it. `{}` when there is no state |
| `c.upgradeWith(loop, state, .{ .protocol = "chat.v1" })` | the same, naming a subprotocol |

`Content-Type`, `Content-Length`, `Transfer-Encoding` and `Connection` are
refused by `setHeader`. So is a name that is not a token, and a value holding a
control byte — a newline in one would start a second header, and two would start
a second response ([ADR 0087](./adr/0087-a-header-value-cannot-end-its-own-line.md)).
All three are a 500 naming the header. Set headers before sending. Setting the
same header twice replaces it — except `Set-Cookie` and `Vary`, which a response
may carry more than one of. `Set-Cookie` because two cookies cannot be folded
into one line; `Vary` because two layers each name their own axis, and replacing
threw one away ([ADR 0089](./adr/0089-two-layers-can-each-name-a-vary-axis.md)).
Setting either with a name and value already present adds nothing.

**`host()` and `scheme()` are how a handler writes a URL to its own service** —
a password-reset link, an OAuth `redirect_uri`, an absolute `Location`. nilo
does not speak TLS, so with no `trusted_hops` set `scheme()` is always
`"http"`; behind a proxy set it and the two headers that proxy writes are
believed, exactly as `X-Forwarded-For` is
([ADR 0112](./adr/0112-a-request-can-be-read-past-the-parts-a-handler-names.md)).
A forwarded host that is not host-shaped is dropped rather than used, because
this ends up in a link somebody clicks.

**A target that arrived in absolute form answers `host()` before the header
does.** `GET http://example.com/users/7` is what a client sends to what it
believes is a proxy, and RFC 9112 §3.2 gives an origin server no choice: the
authority on the request line is the host, and a `Host` header beside it is
ignored ([ADR 0120](./adr/0120-a-target-is-read-in-the-form-it-arrived-in.md)).
The router still matches on the path, so nothing about writing routes changes.
A trusted `X-Forwarded-Host` outranks both.

**A body arriving under a `Content-Encoding` other than `identity` is a 415**
naming the header, before any handler runs — nilo decodes none of them, and
handing a gzip stream to `c.json` produced a 400 about malformed JSON that was
true of the bytes and useless to whoever sent them
([ADR 0111](./adr/0111-a-body-under-an-encoding-nilo-cannot-read-is-refused.md)).
The header on a request with no body is ignored.

**A stream with a `.length` is held to it.** Writing past the promise is
refused before a byte of the overrun goes out, because a client reading a
`Content-Length` stops there and everything after it is read as the next
response. Finishing short cannot be refused — the head has gone — so the
connection closes and the log names both numbers.

**`c.url` is checked while compiling.** A param with no value, a value with no
param, a value a path segment cannot carry and a `*` catch-all are all compile
errors naming the field. Values are matched by name, so `.{ .slug = t, .id = 42 }`
and `.{ .id = 42, .slug = t }` are the same URL. `nilo.url.into(buf, pattern, args)`
is the same call with a buffer of your own and no allocation, for code with no
request in flight.

`sendFile` also takes `size` (null asks the file), `etag` and `cache_control`,
and answers a `Range`, an `If-Range`, an `If-None-Match` and a `HEAD` from them.
A handler that knows it is answering with a file before it runs returns
[`FileBody`](#handler-returns) instead, which the API description can see.

## `Cookie`

What `c.setCookie` takes. Only `name` and `value` have no default.

| | Default |
|---|---|
| `name`, `value` | — |
| `path` | `"/"` |
| `domain` | `""` — this host, no subdomains |
| `max_age` | `null` — a session cookie |
| `expires` | `""` — an HTTP-date, if you have one |
| `secure` | `true` |
| `http_only` | `true` |
| `same_site` | `.lax` — or `.strict`, `.none`, `.unset` |

A value holding a space, comma, semicolon, quote, backslash or control byte is
refused with a 500: a `;` would start an attribute nobody wrote. `.none`
without `.secure` is refused for the same kind of reason — browsers drop it.

## `Session(T)`

The session, sealed into one cookie. `T` is a struct of yours of a size known
while compiling — numbers, bools, enums, `[N]u8`, optionals and structs of
those. Not slices. See [Sessions](./guide/sessions.md).

| | |
|---|---|
| `s.get()` | `?T` — what the client sent, or null if it sent nothing readable |
| `s.set(value)` | replace it; one `Set-Cookie` on this response |
| `s.setWith(value, options)` | the same, with the cookie's attributes your own |
| `s.clear()` | sign out — deletes the cookie |
| `s.clearWith(.{ .path = …, .domain = … })` | the same, matching a cookie set elsewhere |

`setWith` options: `path` (`"/"`), `domain` (`""`), `max_age` (`null` — a
session cookie), `secure` (`true`), `same_site` (`.lax`). No `http_only`: it
is always on.

`max_age` sets the cookie attribute **and** an expiry sealed inside the cookie,
where the client cannot reach it — `Max-Age` alone is advice a copied cookie
does not take. Null seals `nilo.session.default_max_age`, 24 hours
([ADR 0088](./adr/0088-an-expiry-a-client-can-ignore-is-not-one.md)).
`nilo.session.openAt(T, cookie, key, when)` opens one against a time you name,
for a test that wants the boundary without a wall clock.

Every way a cookie can be unreadable — tampered, truncated, expired, sealed
under another secret, written by a build with a different shape of `T` — is the
same answer, `null`. The secret comes from
`listen(.{ .session_secret = … })` and must be exactly 32 bytes; a handler
asking for a session with none set answers 500.

## `Upload`

One file out of a multipart form, as a `Form(T)` field type.

| | |
|---|---|
| `u.filename` | `Str` — **what the client said**, never a path to write to |
| `u.content_type` | `Str` — the client's claim, unverified |
| `u.bytes` | `Str` — the file itself |
| `u.len()` | how big it is |
| `u.saveTo(dir, name)` | `!void` — write it into a [`Dir`](#dir) under **a name of yours** |

`saveTo` replaces the file at `name` or leaves it untouched: the bytes go to a
temporary name beside it and one rename puts them in place, so a request
serving that same name out of the same `Dir` never reads it half-written
([ADR 0123](adr/0123-a-file-is-written-by-the-engine.md)). Handing `u.filename`
in as the name is `error.NameNotAllowed`, not a path resolved against the
directory.

## `Str`

| | |
|---|---|
| `s.view()` | the bytes |
| `s.eql(other)` | compare against a `[]const u8` |
| `s.int(T)` | parse as base-10 |
| `s.len()` | |
| `s.trimmed()` | the bytes with whitespace off both ends, borrowed |
| `s.blank()` | whether there is nothing but whitespace — including nothing at all |
| `s.keep(gpa)` | a copy that outlives the request; the caller frees it |
| `Str.static(bytes)` | text that already outlives any request — what a test uses |

`{f}` prints one: `std.log.info("path={f}", .{c.path()})`. `{s}` cannot be made
to work, because Zig reserves it for byte slices and a `Str` is a struct.

**`blank()` is the check in front of a write that takes a name, a title or a
body**, because required text arrives as `"  "` in the ordinary case rather than
the rare one — a field somebody tabbed through, a paste that brought its newline
along ([ADR 0175](./adr/0175-required-text-arrives-as-two-spaces.md)). The set is
`std.ascii.whitespace`, which includes the `\n` a hand-written `" \t\r\n"` drops
about half the time; a comment whose entire body is a newline is required text
that renders as an empty screen.

It is a read of the bytes and not a validation rule — whether a blank title is a
422 stays yours, the same line `len()` and `eql()` already draw.

## `Run`

A [Scope](#scope) for work that is not a request: a CLI run, the tick of a
scheduled task, a test. Handed to anything that would otherwise take a `*Ctx`.

```zig
var run = nilo.Run.init(gpa);
defer run.deinit();

const rows = try db.select(User, &run, .{ .where = .{ .age = .{ .gt = 18 } } });
```

| | |
|---|---|
| `nilo.Run.init(gpa)` | |
| `nilo.Run.initIo(gpa, io)` | the same, and able to `entropy` |
| `run.deinit()` | |
| `run.arena()` | `std.mem.Allocator` — memory that lasts as long as this tick |
| `run.str(bytes)` | `Str` — text you allocated from `run.arena()`, stamped with this tick |
| `run.entropy(n)` | `![n]u8` from the operating system. `error.NoIo` on a Run built by `init` |
| `run.entropyInto(buf)` | `!void` — the same, at a width nobody said while compiling |
| `run.give(V, value)` | hand this tick a value for something below to ask for |
| `run.resolve(V)` | `!V` — what `give` put there. `error.NotGiven` if nothing did |
| `run.reset()` | end the tick: the memory goes back, what was given goes with it, and every `Str` from it goes stale |

`entropy` is spelled the same as [`Ctx.entropy`](#reading), so one function body
compiles under both — which is what "pass the `*Ctx`, or a `nilo.Run` if there
is no request" has always promised, and was false of the most common function in
any program, the one that mints a key
([ADR 0160](./adr/0160-a-scope-that-can-mint-a-key.md)):

```zig
fn create(db: *Db, scope: anytype, title: []const u8) !Doc {
    const key = id.Uuid.v7(try scope.entropy(id.Uuid.v7_entropy), nilo.nowMillis());
    return db.insert(Doc, scope, .{ .id = key, .title = title });
}
```

`init` leaves it null rather than requiring an `Io`, because handing out memory
and stamping a lifetime need none and most Runs never mint anything; `initIo`
takes the same `Io` the pool or the `std.Io.Threaded` was started with, which a
CLI, a seed and a test all have in hand by the time they build a Run.

**`run.str` is for text you allocated; a literal wants
[`Str.static`](#str).** The two are not interchangeable and the difference is
what each one promises: `run.str` stamps the tick, so the `Str` goes stale when
the tick ends and the use-after-request trap can catch it; `Str.static` carries
no marker and is never stale, which is the right answer for a literal in the
program's own text. It matters most where a Scope is already in hand and reaching
for it is the obvious move — building a list, where `run.str` costs a call per
element and says nothing true about a literal:

<!-- compiles -->
```zig
const types: []const Str = &.{ .static("DealValueChanged"), .static("DealWon") };
```

### A value that reaches the bottom

`nilo_resolve` works a value out once per request, and it arrives as a **handler
argument** — which is the top of the call stack. What needs it is often the
bottom: an audit row assembled sixty call sites down, where every function in
between would have to carry a value it has no business knowing about
([ADR 0165](./adr/0165-a-value-that-reaches-the-bottom.md)).

Both scopes answer `resolve`, so one function body reaches it either way:

```zig
fn record(db: *Db, scope: anytype, what: Event) !void {
    const actor = try scope.resolve(Actor);   // a *Ctx or a *Run
    _ = try db.insert(AuditRow, scope, .{ .agent = actor.agent, … });
}
```

**Where the value comes from is what differs, and that is the point.** Under a
server, `Actor` carries `nilo_resolve` and is worked out from the request — so
"is it set?" is answered while compiling, and no middleware has to remember
anything (ADR 0016). A seed or a CLI has no request to work it out from, so it
is told once at the top:

```zig
var run = nilo.Run.initIo(gpa, io);
defer run.deinit();
try run.give(Actor, .{ .agent = "nightly-import" });
```

`run.resolve` answers `error.NotGiven` rather than null, for the same reason
`entropy` answers `error.NoIo`: a value nobody set has to be louder than a value
nobody read — the failure this exists for is an audit column that is quietly
NULL. What was given is copied into the tick's arena, so `reset` clears it, and
giving the same type twice replaces it.

**Given-as-null is given.** `give` records the type whatever the value, so a
`Caller { agent: ?Uuid }` handed over with `agent = null` resolves to that, and
`error.NotGiven` means only that nobody called `give`. The three states stay
apart, which matters when one of them — nobody wired it up — is a bug and
another — no agent, an ordinary human session — is most of your traffic.

A request never needs `give`: a value read off the request is a `nilo_resolve`,
and declaring it removes the third state entirely, because the resolver does not
depend on the route and a route asking for the value does not compile without
it.

## Scope

Not a type — the two calls above, `arena()` and `str()`. A `Ctx` has them and a
`Run` has them, and anything asking for a Scope takes either
([ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md)). It is checked
while compiling, so passing something else is a Refusal naming the call rather
than an error from inside the module.

`nilo_core` is the module both live in. A project importing `nilo` never has to
name it — `nilo.Str` and `nilo.Run` are the same declarations — but a program
with no server in it can depend on `nilo_core` alone.

### `AnyScope`

A Scope with its type erased, for the one place the shape above cannot reach:
**the other side of a function pointer**
([ADR 0177](./adr/0177-a-scope-that-crosses-a-function-pointer.md)). Zig has no
closures, so a bus, a queue or a job registry stores a callback as a function
pointer — and a function pointer names one type per argument, so a reaction
cannot be generic over the Scope it runs under while still running under a
request *and* under a `Run` in a test.

```zig
const Reaction = *const fn (scope: *nilo.AnyScope, payload: []const u8) anyerror!void;

fn notify(scope: *nilo.AnyScope, payload: []const u8) !void {
    const kept = try scope.arena().dupe(u8, payload);
    _ = try db.insert(Notice, scope, .{ .body = kept });
}

var erased = nilo.AnyScope.of(c);   // or `.of(&run)` outside a request
try reaction(&erased, payload);
```

| | |
|---|---|
| `nilo.AnyScope.of(scope)` | erase a `*Ctx` or a `*Run`. Two stores, no allocation |
| `erased.arena()` | the wrapped Scope's, through the vtable |
| `erased.str(bytes)` | the same, stamped with the wrapped Scope's lifetime |
| `erased.entropy(n)` | `![n]u8` |
| `erased.entropyInto(buf)` | `!void`, and the one the vtable actually carries |
| `erased.requestId()` | `?Str` — the request's id when it was made from a `*Ctx`, `null` from a `Run` ([ADR 0196](./adr/0196-a-request-id-goes-out-with-the-call.md)) |

It passes the Scope check, so `db.select(Row, &erased, …)` works — a reaction can
query. `resolve` is not here: it is generic over the type asked for, so it cannot
cross a function pointer either.

**It borrows.** The pointer inside is the Scope's own, so an `AnyScope` may not
outlive the `Ctx` or `Run` it was made from — in practice it is a local beside the
call. **And the ordinary Scope is unchanged**: every call in nilo and in
`nilo_sql` still takes `anytype` and still costs no indirect call. The vtable is
paid for only where somebody erases one.

## `nilo_core.percent`

RFC 3986, both directions. The server decodes every path param and query value
through it and you never call that half; the encoding half is for building a
URL or signing one, and a Service can reach it because it is in Core rather
than behind `nilo_http`
([ADR 0066](./adr/0066-percent-is-needed-by-two-layers.md)).

```zig
const percent = @import("nilo_core").percent;

var buf: [256]u8 = undefined;
const key = percent.encodeInto(&buf, "holiday photos/bali.jpg", .path);
// "holiday%20photos/bali.jpg"
```

A handler reaches the same thing as **`nilo.percent`** without adding an import
— which is the other half of what ADR 0066 is about, and what
`examples/outbound/` uses to put a path param into a URL it is about to fetch.

| Call | |
|---|---|
| `percent.encodedLen(raw, set)` | `usize` — exact, not an estimate: every byte becomes one or three |
| `percent.encodeInto(dst, raw, set)` | `[]u8` — the part of `dst` used. `dst` must be `encodedLen` or longer |
| `percent.encodeWrite(w, raw, set)` | straight to a `*std.Io.Writer`, for something assembled a piece at a time |
| `percent.decode(gpa, raw, plus_as_space)` | `![]const u8` — allocates only if there is something to decode, else hands `raw` back |
| `percent.decodeInto(dst, raw, plus_as_space)` | `[]u8` — the part of `dst` used |
| `percent.decodedLen(raw)` | `usize` |
| `percent.needed(raw, plus_as_space)` | `bool` — whether decoding would change anything |

`set` is `.path`, where `/` is a separator and stays, or `.unreserved`, where
`/` is data and becomes `%2F`. Everything outside RFC 3986's unreserved set —
`A-Z`, `a-z`, `0-9`, `-`, `.`, `_`, `~` — is escaped in both, which includes
`!`, `*`, `'`, `(` and `)` if you are arriving from `encodeURIComponent`.

Three things are not options, because each is a failure that says nothing when
it happens: **a space is always `%20` and never `+`**, **hex is uppercase**, and
**there is no allocating encoder** — measure with `encodedLen` or write with
`encodeWrite`. `decode` allocates because the request path needs it to.

`plus_as_space` is the decoder's only switch, and it is for query values:
`?q=a+b` means "a b" because HTML forms have encoded it that way since 1995. It
stays off for path params, where a `+` is a plain `+`.

## `nilo_fetch`

An HTTP client for calling somebody else's API from inside a request. A
**Fitting**: it borrows the event loop and owns no destination
([ADR 0070](./adr/0070-a-fitting-borrows-the-loop.md)).

`std.http.Client` is the client — pool, HTTP/1.1, TLS. What this adds is the
policy a server needs and a script does not, in about sixty lines.

```zig
const fetch = @import("nilo_fetch");

var api: fetch.Client = .init(gpa, .{});
try app.provide(&api);

fn charge(api: *fetch.Client, c: *nilo.Ctx) !Receipt {
    const res = try api.post(c, "https://api.example.com/v1/charges", "amount=500", .{});
    if (!res.ok()) return nilo.fail.status(502, "the payment service said no", .{});
    return res.json(Receipt, c);
}
```

| Call | |
|---|---|
| `client.get(c, url, .{})` | `Response` |
| `client.post(c, url, body, .{})` | `Response` |
| `client.put(c, url, body, .{})` | `Response` |
| `client.delete(c, url, .{})` | `Response` |
| `client.send(c, method, url, body_or_null, .{})` | for a method the four above do not name |
| `res.ok()` | `bool` — 2xx |
| `res.status` | `std.http.Status` |
| `res.body` | `Str`, in the Scope you passed. Goes when the request does |
| `res.json(T, c)` | `T`, parsed into the same Scope |

`c` is a Scope — the `*Ctx` a handler was given, or a `nilo.Run` where there is
no request. Handing over something that is neither is a Refusal naming the call.

**`Client.Settings`**, given to `init`:

| Field | Default | |
|---|---|---|
| `max_in_flight` | 32 | calls at once, across every host. Past it a caller waits for a permit rather than opening another connection — an HTTPS one holds 59,151 bytes |
| `timeout_ms` | 30,000 | how long one whole call may take. `0` is no limit |
| `max_body` | 8 MiB | a longer body is `error.BodyTooLarge`, enforced while reading |
| `max_drain` | 64 KiB | how much of an unread body is worth reading to keep a pooled connection. Past it the connection is dropped |
| `forward_request_id` | true | a call made under a `*Ctx` sends the request's id as `X-Request-Id`, so the other side's log lines up with this one. A `Run` has no id and sends none; a call naming its own `X-Request-Id` in `headers` keeps it ([ADR 0196](./adr/0196-a-request-id-goes-out-with-the-call.md)) |

**`Client.Call`**, given per call: `headers`, and `timeout_ms` / `max_body` to
override the settings above for one call.

**Errors worth naming.** `error.TimedOut` is this call's own deadline;
`error.Canceled` is the server shutting down underneath it, and the two are
told apart rather than guessed at. `error.NotStarted` is a call made before
`listen()` — the client is finished at startup like any other service.

**A 4xx or a 5xx is a `Response`, not an error.** The call worked and the
service said no; only the caller knows which of those matters.

**The body is asked for uncompressed.** `send` sends
`Accept-Encoding: identity`, so `res.body` is the body rather than a gzip
stream. This differs from `std.http.Client`'s default, which advertises gzip
and then returns the compressed bytes from `Response.reader` — decompressing is
a separate call there, and a caller who does not make it gets unreadable bytes
and no error. Decompressing here would cost a 32 KiB flate window on the
handler's stack, which is per *connection*
([ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md)), so identity is
the trade taken. A server that ignores the header and gzips anyway is an error
rather than a `Str` full of noise.

`examples/outbound/` is the whole of this against a real API, and
[`bench/result/fetch.md`](../bench/result/fetch.md) is what it costs on each of
ADR 0018's four axes.

**What it is not**: a retry policy, a circuit breaker or a rate limiter. Those
are decisions about somebody else's service and belong to whoever knows what
that service promises.

### `fetch.Exchange`

The four calls above hold the whole body in the Scope, which is right for an
API answering JSON and wrong for anything measured in megabytes. An `Exchange`
is the same policy with the body left on the socket: **read the response head,
decide, then move the bytes somewhere that is not memory.**

```zig
var ex: fetch.Exchange = .idle;
defer ex.end();

const head = try ex.begin(client, .{ .method = .GET, .url = url });
if (head.content_length) |n| if (n > ceiling) return error.TooLarge;
_ = try ex.pipe(&body.writer);   // straight out, allocating nothing
```

| | |
|---|---|
| `ex.begin(client, .{…})` | `Head` — status, `content_length`, `content_type`, `header(name)` (case-insensitive), `ok()` |
| `ex.take(c, max)` | the rest of the body as a `Str` in the Scope, refusing over `max` |
| `ex.readInto(buf)` | exactly `buf.len` bytes, or `error.BodyTooShort` |
| `ex.pipe(w)` | the rest into a `*std.Io.Writer`, and how many bytes |
| `ex.end()` | required, and safe twice |

`Begin` takes `headers`, `host`, `authorization`, `content_type`, `timeout_ms`,
a `body` of `.none` / `.slice` / `.stream`, and the two buffers — an empty
`redirect_buffer` means redirects are not followed, which is what a signed
request wants. **The buffers are the caller's because their cost is the
caller's stack**, and by
[ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md) that is per
connection.

**It must not be copied once begun**: it holds a `std.http.Client.Request`.
Declare it, fill it where it stands, leave it there.

## `nilo_s3`

Object storage — S3, MinIO, R2, Backblaze, anything that speaks the same
dialect. A **Service**: it borrows the loop and holds a destination
([ADR 0070](./adr/0070-a-fitting-borrows-the-loop.md)). SigV4 and S3's
semantics are all it is; the HTTP underneath is `nilo_fetch`
([ADR 0067](./adr/0067-most-of-an-s3-client-is-not-s3.md),
[ADR 0072](./adr/0072-an-object-store-is-a-service-that-dials.md)).

<!-- compiles -->
```zig
const s3 = @import("nilo_s3");

// A bucket is a type, and its name is compiled in (ADR 0068).
const Avatars = s3.Bucket("avatars", .{ .max_bytes = 2 << 20 });

fn avatar(avatars: *Avatars, c: *nilo.Ctx, key: nilo.Str) !void {
    const object = try avatars.get(c, key.view());
    return c.send(200, object.content_type.view(), object.bytes.view());
}
```

and at startup:

```zig
var store = try s3.open(gpa, .{
    .endpoint = "https://s3.ap-southeast-1.amazonaws.com",
    .region = "ap-southeast-1",
    .credentials = .{ .static = .{
        .access_key_id = settings.aws_key,
        .secret_access_key = settings.aws_secret,
    } },
});
defer store.deinit();

var avatars = try Avatars.open(&store);
defer avatars.deinit();
try app.provide(&avatars);
```

**One Store, many Buckets.** The Store owns the connection pool, the
credentials and the derived signing key; a Bucket owns a name and the options
that go with it. Two buckets over one Store share one pool, and starting a
Store twice is a no-op.

| Call | |
|---|---|
| `bucket.get(c, key)` | `Object` — `bytes`, `content_type`, `etag`, `len`. One allocation holds all four |
| `bucket.getRange(c, key, .{ .from, .to })` | the same, for a slice. `to` is inclusive |
| `bucket.getIf(c, key, etag)` | `Conditional` — `.unmodified` or `.object`. A 304 is a success, so it is a union rather than an error |
| `bucket.stream(c, key, &reading, buf)` | fills a `Reading` — `len`, `content_type`, `etag`, then `pipe(w)` and `close()` |
| `bucket.put(c, key, .{ .bytes, .content_type })` | also takes `cache_control` and `content_disposition` |
| `bucket.putStream(c, key, .{ .reader, .len, .content_type })` | framed by length, never chunked — S3 does not accept chunked |
| `bucket.delete(c, key)` | |
| `bucket.head(c, key)` | `Meta` — `len`, `content_type`, `etag` |
| `bucket.presign(c, key, seconds)` | `Presigned` — `url` and `expires_at`. No socket |
| `bucket.presignPost(c, key, .{ .seconds = 900 })` | `Posted` — `url`, `fields` and `expires_at`, for a browser uploading straight to the bucket. No socket |

`c` is a Scope, the same as everywhere else.

**A presigned POST is a form rather than a link.** `presign` gives somebody a URL
to fetch; `presignPost` gives a browser everything it needs to upload without the
bytes passing through your server. `url` is the bucket, not the key, and `fields`
go into the form in the order they come back, with the file input **last**. S3
ignores whatever follows the file part.

| `s3.Post` | Default | |
|---|---|---|
| `seconds` | — | clamped to `presign_max` and to what the credentials have left, the same three ways `presign` is |
| `content_type` | null | an `eq` condition on `$Content-Type`. Null lets the browser send what it likes |
| `max_bytes` | the bucket's `max_bytes` | **clamped to it, and defaulted to it**, so a form with no ceiling is not something this hands out |
| `prefix` | false | `key` is the start of a key rather than the whole of one, so the browser picks the filename. The condition becomes `starts-with` |

```html
<form action="{url}" method="post" enctype="multipart/form-data">
  <!-- one hidden input per field, in order -->
  <input type="file" name="file">   <!-- last -->
</form>
```

The reason it is here rather than in your application is one line of SigV4: the
policy is signed with the key ADR 0069 derives once a day, and a second
implementation of that outside nilo is two places that have to agree about a
rotation. They disagree at 00:00 UTC, and the symptom is uploads failing with a
403 that says nothing.

**`s3.Options`**, given to `open`:

| Field | Default | |
|---|---|---|
| `endpoint` | — | `https://host[:port]`, no path. **The scheme decides whether payloads are hashed**: `UNSIGNED-PAYLOAD` over TLS, a real SHA-256 over plaintext |
| `region` | `us-east-1` | |
| `credentials` | — | `.static` or `.fetch` |
| `max_in_flight` | 32 | calls at once. An HTTPS connection holds 59,151 bytes, so this times that is the ceiling |
| `timeout_ms` | 30,000 | one call, end to end |
| `max_drain` | 64 KiB | how much of a refused body is worth reading to keep the connection |
| `refresh_margin_s` | 300 | how long before expiry temporary credentials are replaced |

**Bucket options**, the second argument to `Bucket`:

| Field | Default | |
|---|---|---|
| `max_bytes` | 8 MiB | the largest object a bounded `get` will hold, **checked against `content-length` before a byte is read** |
| `style` | `.virtual` | `.path` for MinIO and anything on a bare host |
| `sse` | null | `.aes256` or `.aws_kms` |
| `presign_max` | 3600 | the longest life a presigned URL may claim |
| `key_max` | 512 | the longest key. Comptime because it sizes a stack buffer, and stack is per connection |
| `session_token_max` | 0 | room for a session token. **Zero is right for static credentials** and costs nothing; STS sources set 2048 and pay per connection |

**Temporary credentials** are one function, called lazily by the request that
notices they are near expiry — there is no background task:

```zig
.credentials = .{ .fetch = fetchFromIrsa },   // fn (gpa, io) !s3.Credentials
```

**Seven errors, because a handler would do something different about each**:
`NotFound` (the only one with a default status, 404), `TooLarge`, `Throttled`,
`Unavailable`, `TimedOut`, `Rejected` and `Failed`. S3's own code and message
are logged rather than sent on — `Rejected` reaching a client as a 403 would be
telling the caller they are not allowed when the truth is that the *server's*
credentials are wrong. A skewed clock is read out of the body and said plainly.

**What it is not**: `LIST`, multipart upload, bucket lifecycle, or anything
else whose success path is XML — [ADR 0068](./adr/0068-a-bucket-is-a-type-and-a-key-is-not.md)
is where that line is drawn and why.

[`bench/result/s3.md`](../bench/result/s3.md) is what it costs on all four of
ADR 0018's axes, against the same seven routes written in Go and Rust. It also
says plainly why Bun has no row.

## `nilo_id`

UUIDs, as a module of their own
([ADR 0042](./adr/0042-the-bottom-layer-holds-more-than-one-module.md)). The
same `Uuid` `nilo_sql` reads a `uuid` column into, so a generated key goes
straight into an insert. Nothing here allocates and nothing here does IO.

<!-- compiles: body -->
```zig
const id = @import("nilo_id");

const key = try id.v7Now(c);   // a *Ctx, or a `nilo.Run` built with `initIo`
_ = try db.insert(Doc, c, .{ .id = key, .title = nilo.Str.static("notes") });
```

where `Doc.id` is a `sql.Uuid`, which is this same type.

| | |
|---|---|
| `id.v7Now(scope)` | `!Uuid` — sortable, from the Scope's randomness and the clock |
| `id.v4(entropy)` | random — 122 bits of the `[16]u8` you pass in |
| `id.v7(entropy, ms)` | sortable — `ms` in the first six bytes, then the `[10]u8` |
| `u.toText()` | `[36]u8` by value: `550e8400-e29b-41d4-a716-446655440000` |
| `u.writeText(w)` | the same, into a `*std.Io.Writer` |
| `id.Uuid.parse(text)` | `!Uuid`, `error.InvalidUuid`. Hyphens optional |
| `u.version()` | `u4` — `4`, `7`, or whatever the bytes claim |
| `u.millis()` | `?u64` — the millisecond a v7 carries, null for anything else |
| `u.eql(other)`, `u.isNil()`, `id.Uuid.nil` | |
| `id.Uuid.byte_len`, `.text_len`, `.v4_entropy`, `.v7_entropy` | 16, 36, 16, 10 |

**`{f}` prints one**, which is what a refusal naming the record it could not find
wants ([ADR 0176](./adr/0176-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)):

```zig
return nilo.fail.notFound("partner {f} not found", .{id});
```

`{s}` cannot be made to work — Zig reserves it for byte slices and a `Uuid` is a
struct — and `writeText` is a method, so it answers a writer you already hold and
answers nothing to a format string.

**`v7Now` is the call for a key and `v7` is the call for a key at a time you
chose** — a backfill, a row that existed before its id did. `v7Now` is
`c.entropy(…)` and the clock, which is the pair every `create` writes out
otherwise, `@intCast` included. On a `Run` built by `init` rather than `initIo`
it is `error.NoIo`, which is what `scope.entropy` answers on its own.

A `Uuid` in a returned struct leaves as its text rather than as sixteen
numbers, and one in a Row is written and read as the `uuid` column.

**A v7 is sortable across milliseconds and not within one.** Its first six
bytes are the clock and the other ten are the entropy you passed, with no
counter — so two keys minted in the same millisecond come back in random order
relative to each other, and RFC 9562 allows a counter there deliberately not
taken ([ADR 0042](./adr/0042-the-bottom-layer-holds-more-than-one-module.md)):
a counter is a threadlocal or an atomic, and having no state is what lets `v7`
be called from any fiber without a lock.

**The trap is not "the ids are unordered" — it is "they look ordered as long as
the timestamps differ".** The case that finds it is a row whose timestamp comes
from `now()` inside a transaction. That is Postgres behaviour rather than
nilo's: `now()` is the *transaction's* clock, so every row one command writes
carries the identical instant, and the whole of the ordering then rests on ten
random bytes. `ORDER BY occurred_at, id` looks right in every test where the
writes were a millisecond apart and reshuffles the rows written together.

If the order rows were written in is something your product shows, store it:
an ordinal column the command fills, or a sequence. A v7 orders by *when*, and
two things that happened at the same instant have no *when* to be ordered by.

**The randomness is an argument, and it has to be unguessable.** Entropy is IO
and a module in the bottom layer has no Bulkhead to reach through, so `v4` and
`v7` take what they need rather than fetching it — inside a request that is
`c.entropy(n)`, outside one it is `std.Io.randomSecure`
([ADR 0046](./adr/0046-entropy-belongs-to-the-loop.md)). A v4 built from a
seeded `std.Random.DefaultPrng` is fine in a test and is a session token anybody
can predict in production; nothing here can tell the difference.

## `nilo_config`

Settings, read into a struct of your own before the socket opens
([ADR 0043](./adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)).
Nothing here allocates and nothing here does IO.

```zig
const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,                                   // a default is "not set"
    database_url: []const u8,                           // no default: required
    log_level: enum { debug, info, warn } = .info,
    workers: ?u8 = null,                                // may be absent
};

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stderr().writer(init.io, &buf);

    const read = config.fromEnv(Settings, init.minimal.environ);
    const settings = read.value() orelse {
        try read.report(&out.interface);
        try out.interface.flush();
        std.process.exit(2);
    };
    // an ordinary struct — `app.provide(&settings)` makes it a Service
}
```

The field name upper-cased is the variable: `database_url` is read from
`DATABASE_URL`. A field is text, a number, a `bool`, an enum, or any of those
wrapped in `?`; anything else is a Refusal.

| | |
|---|---|
| `config.fromEnv(T, environ)` | `Read(T)` out of the process environment |
| `config.from(T, source)` | out of anything with `get(name) ?[]const u8` |
| `config.fromWith(T, .{ .prefix = "NILO_" }, source)` | the same, with a prefix on every name |

| | |
|---|---|
| `r.value()` | `?T` — the Config, or null when any setting failed |
| `r.report(w)` | every failure, one per line, into a `*std.Io.Writer`. Writes nothing when there are none |
| `r.failed()`, `r.failedCount()` | |
| `r.failures()` | an iterator of `Failure`, in the order the struct declares them |
| `r.given("port")` | the text that arrived, converted or not. Field name checked while compiling |
| `r.nameOf("port")` | `"PORT"`, prefix and all |

A `Failure` is `.field`, `.name`, `.reason`, `.given`, `.expected`, and
`.say(w)` writes nilo's own sentence for it. `Reason` is `missing`,
`not_a_number`, `not_true_or_false`, `not_a_choice` — four, and it stays four:
whether the port is one this machine may bind is your question.

| Source | |
|---|---|
| `config.Env{ .environ = … }` | the environment block, read where it lies. Allocates nothing. POSIX only |
| `config.Map{ .map = init.environ_map }` | the portable half, and what Windows uses |
| `config.Fixed{ .pairs = &.{ .{ "PORT", "9000" } } }` | pairs of your own — the seam for a file you parsed yourself |
| `config.Dotenv{ .text = … }` | a `.env`'s **text**. You open the file; this reads it |
| `config.layered(.{ a, b })` | several sources in the order they win — the first with the name answers |

### A `.env`

`Dotenv` takes text, not a path
([ADR 0064](./adr/0064-a-dotenv-is-text-somebody-else-read.md)), so the module
still opens no file and still allocates nothing. **The text has to outlive the
Config** — a `[]const u8` field points into it, exactly as it points into the
environment block.

```zig
const text = std.Io.Dir.cwd().readFileAlloc(io, ".env", gpa, .limited(64 * 1024)) catch "";
const file = config.Dotenv{ .text = text };

const read = config.from(Settings, config.layered(.{
    config.Env{ .environ = init.minimal.environ },   // a set variable wins
    file,                                            // the file is the floor
}));

try file.report(w);   // writes nothing when the file is clean
```

`io` and `environ` both come from `main`'s own argument, and `w` is
`std.Io.File.stderr().writer(io, &buf)`'s `.interface`. The whole of a real
`main` — the one this is a fragment of — is on
[the settings page](./guide/config.md#the-whole-of-a-real-main).

| | |
|---|---|
| `f.get("PORT")` | `?[]const u8` — the first line setting that name |
| `f.failed()`, `f.failedCount()` | lines that meant to be settings and are not |
| `f.failures()` | an iterator of `BadLine` |
| `f.report(w)` | every bad line, one per line. Writes nothing when there are none |

A `BadLine` is `.number`, `.why`, `.name`, and `.say(w)`. `Wrong` is
`no_equals`, `empty_name`, `bad_name`, `unbalanced_quote` — all about the shape
of the line; whether the value converts is `Reason`'s question. **A report never
quotes a value**, because a `.env` is where a password lives.

Reads `NAME=value`, blank lines, `#` comments on their own line, `'` and `"`
quoting, an optional `export ` prefix, and CRLF. **Refuses** escapes, multi-line
values, `${OTHER}` interpolation, and comments after a value — so
`PASSWORD=abc#123` is intact, and `PORT=8080 # the port` says
`PORT has to be a whole number, not "8080 # the port"` rather than guessing.

**It opens no files.** `std.zon.parse` is in the standard library;
[sam701/zig-toml](https://github.com/sam701/zig-toml) is the one to reach for
if the file has to be TOML. Either way the pairs come back as a `Fixed` and
this module never had to carry the dependency.

## `nilo_pw`

Password hashing
([ADR 0048](./adr/0048-a-password-hash-is-gated-because-forgetting-is-silent.md)).
Argon2id, in the PHC form everybody else writes.

<!-- compiles: body -->
```zig
// signing up
const stored = try c.hashPassword(pw.huge_pages, form.password.view());
_ = try db.insert(User, c, .{ .email = form.email, .password = stored.text() });

// signing in
const row = try db.one(User, c, .{ .where = .{ .email = form.email } });
if (!try c.verifyPassword(pw.huge_pages, if (row) |r| r.password.view() else null, form.password.view()))
    return nilo.fail.unauthorized("that is not a sign-in", .{});

// and while the plaintext is still in hand, if the Cost has gone up since
if (row) |r| if (try pw.needsRehash(r.password.view(), .default)) {
    const fresh = try c.hashPassword(pw.huge_pages, form.password.view());
    _ = try db.update(User, c, .{ .set = .{ .password = fresh.text() }, .where = .{ .id = r.id } });
};
```

| | |
|---|---|
| `c.hashPassword(gpa, text)` | `!pw.Hash` — the call a handler makes |
| `c.verifyPassword(gpa, stored, text)` | `!bool` — `stored` is `?[]const u8` |
| `c.verifyPasswordWith(cost, gpa, stored, text)` | the same, if you hash at anything but the default |
| `pw.needsRehash(stored, cost)` | `!bool` — was this row written weaker than you write now |
| `pw.huge_pages` | the allocator to hand it: the 19 MiB in 2 MiB pages, 11.0 ms against 13.6 |
| `stored.text()` | the PHC string, `$argon2id$v=19$m=19456,t=2,p=1$…` |
| `pw.Cost.default` | OWASP's first recommendation: 19 MiB, 2 passes, 1 lane |
| `pw.Cost.floor_memory_kib` | 7168 — below it is a compile error |
| `pw.salt_len` | 16 |
| `pw.bytesFor(cost)` | what one hash asks the allocator for. 19,922,944 at the default |
| `pw.hash` / `pw.hashWith` / `pw.verify` / `pw.verifyWith` | the pure functions, for a program with no server |

**Call the `Ctx` methods, not `nilo_pw` directly.** One hash is 13 ms and
19 MiB. Thirteen milliseconds is *under* `block_warning_ms`, so calling the
module straight from a handler holds the thread on every sign-in and **nothing
in the log ever says so**. The methods take the salt from `c.entropy`, park the
fiber on the blocking pool, and hold one of
`listen(.{ .password_hashes_at_once = 8 })` permits.

**`stored` is optional and null is the point.** A sign-in for an address with
no account has no hash to check; returning early there answers in a millisecond
instead of thirty and turns the form into a query for which addresses are
registered. Passing null does the work anyway and answers false — **at the Cost
you give `verifyPasswordWith`**, which is why that method exists: the work done
for an account that is not there has to be the work done for one that is
([ADR 0049](./adr/0049-a-hash-asks-for-the-pages-it-walks.md)).

**`gpa` is an argument because 19 MiB is worth seeing.** Not `c.arena()` — the
request arena is reset per request keeping `arena_keep` bytes, and pushing
19 MiB through it spends the one budget nilo treats as an invariant. Hand it
`pw.huge_pages` and the same 19 MiB arrives in ten pages instead of 4,864: 11.0
ms a hash against 13.6, with nothing held between them. On anything that is not
Linux it *is* `std.heap.page_allocator`, so the call site reads the same
everywhere.

**A hash made elsewhere verifies here**, at any parallelism, and a hash made
here can be read by anything that reads PHC. That is the only reason to have a
format.

## `nilo_cache`

An expiring cache in this process, and nothing that needs a loop
([ADR 0138](./adr/0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)).
A tool module: it imports nothing, so `zig test cache/cache.zig` runs the whole
of it and a program that is not a server can take it on its own.

<!-- compiles: body -->
```zig
// once, where the program starts
store = try cache.open(gpa, .{ .bytes = 64 << 20 });
defer store.deinit();
carts = Carts.open(&store);

// and wherever the work is
carts.put("u42", .{ .owner = 42, .items = 3, .total_cents = 125_000 });
if (carts.get("u42")) |cart| {
    _ = cart.items;
}
```

`Carts` is a type of your own, declared once beside the others:

```zig
const Cart = struct { owner: u64, items: u16, total_cents: u64 };

const Carts = cache.Space("cart", Cart, .{ .ttl_s = 300 });
```

| | |
|---|---|
| `cache.open(gpa, .{ .bytes = n })` | `!Store` — all the memory, taken here |
| `cache.Space(name, V, .{ .ttl_s = s })` | a keyspace, as a type |
| `Space.open(&store)` | the value a handler holds |
| `space.put(key, value)` | for the Space's `ttl_s` |
| `space.putFor(key, value, ttl_s)` | for a life of its own. `0` is "until the ring writes over it" |
| `space.get(key)` | `?V` for a flat value; `?[]const u8` and a `*Held` for bytes |
| `space.del(key)` | `bool` — was there anything to forget |
| `space.putIfAbsent(key, value)` | store only if the key is free, and say whether it was — `bool` for a flat value, `!bool` for bytes. One shard lock around the scan and the write, so two callers racing get one `true` between them. What `nilo.Idempotent` claims a key with ([ADR 0193](./adr/0193-a-request-answered-once-is-answered-the-same-way-again.md)) |
| `space.getInto(key, buf)` | the bytes read as `get` reads them, into a buffer of your choosing rather than a `Held` — for a caller whose buffer is an arena |
| `store.stats()` | hits, and the three different ways of missing |
| `store.bytesHeld()` | every byte it will ever hold, and it never moves |
| `store.shardCount()` | how many it got, which is at most the `shards` asked for |
| `store.clear()` | forget everything |

**The value type decides the shape of `get`.** A flat value — a number, an
enum, a struct with no pointer anywhere in it — has a size known while
compiling, so it comes back by value and nobody declares a buffer. Bytes do
not, so the Space says how large one can be and hands out the array to read
into:

<!-- compiles -->
```zig
const Pages = cache.Space("page", []const u8, .{ .max_bytes = 4096 });

fn render(pages: *Pages, path: []const u8) ![]const u8 {
    var held: Pages.Held = undefined;
    if (pages.get(path, &held)) |cached| return cached;
    const html = "…";
    try pages.put(path, html);
    return html;
}
```

**`Held` is your stack, and stack is held per connection for the life of it**
([ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md)). A handler
declaring a 4 KiB `Held` has added 4 KiB to every connection that reaches it.
It is written as an array you declare rather than a buffer the cache hides
because that is the only way the number is yours to see.

**A value with a pointer in it is a compile error, and the field is named.** A
cache entry outlives the call that wrote it, so a slice stored in one would
point at a request that has ended. Go's cache stores `interface{}` and gets
away with it because a collector holds the other end; there is none here.
Encode it and use a `Space` of `[]const u8`.

**One number decides the memory and it is a ceiling.** `bytes` is the whole
budget — the ring the values live in and the table that points at them come out
of it together, and `bytesHeld()` is never above it. Nothing is allocated after
`open`, nothing grows, and there is no sweep: an entry goes when its time is up
or when the ring writes over it.

| | |
|---|---|
| `.bytes` | the budget. Five sixths to the values, the rest to the table |
| `.entries` | how many the table points at, when that split is wrong. Clamped to the budget rather than added to it |
| `.shards` | how many writers can be inside at once, and how many independent rings. 64, and cut down if the budget cannot carry that many |

**`stats()` is how "why is my cache not hitting" gets an answer.** A miss with
nothing ever written under that key is `misses`; one whose entry the ring wrote
over is `evicted`; one past its time is `expired`. `Stats.evictionRate()` asks
the question directly: high means the cache wants more `bytes`, low with few
hits means it is being asked about keys nobody wrote. `rescued` counts entries a
read moved out of the write cursor's way, which is the policy working.

The counters are exact and the *reading* is not a snapshot: nothing is locked
while they are summed, because a lookup takes no lock either
([ADR 0188](./adr/0188-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)).
`evicted` also counts the rare read whose bytes a `put` overwrote mid-copy —
that read found the key and lost it to the ring, which is what the word means.

**A `get` takes no lock at all**, so readers do not queue behind each other:
124.5M reads a second on eight threads against 108.8M when they did. A `put`
does take one, per shard.

**A new entry has to be asked for twice before it gets the run of the ring.** It
lands in a tenth of it and is copied into the rest when something reads it
again, so a flood of keys nobody asks for twice cannot flush what the cache is
holding (ADR 0187). Two things follow: a cache with room still admits freely,
and a cache written to and never read holds its first entries indefinitely
rather than forgetting the oldest.

Sizing, measured rather than guessed: on Zipf 0.99 a ring at a fortieth of the
working set answers 63.9% of lookups and one at a fifth answers 94.1%, which is
96–98% of what a cache that size could reach. **Ask for the hit rate you want
rather than for a multiple of the data**, and read `stats()` to find out whether
you got it.

Holding one entry costs 8 bytes of table slot, 12 bytes of header, and the key
— about 20 bytes over the value, and **64.3 bytes an entry on 200,000 of them,
against go-cache's 100.2, freecache's 132.0 and bigcache's 149.4**. That budget
is the whole of nilo's memory; the two Go ring caches bound only their values
and put the index on top, so the same 12 MiB budget cost them 25.2 and 28.5 MiB
of RSS ([`bench/result/cache.md`](../bench/result/cache.md), which also records
the single-threaded rows where go-cache is faster, and why).

**What it will not do is leave this process.** Two instances of your program
have two caches that do not agree, neither survives a restart, and nothing here
reaches a network. That is the trade the module is for; ADR 0139 argues it, and
names `nilo_redis` as the other answer nobody has needed yet.

## `nilo_jwt`

Checking somebody else's signed token, and nothing that needs a loop
([ADR 0140](./adr/0140-nilo-verifies-a-token-and-does-not-fetch-one.md)). A
tool module: it imports nothing, so `zig test jwt/jwt.zig` runs the whole of
it.

<!-- compiles -->
```zig
const jwt = @import("nilo_jwt");

const Claims = struct {
    sub: []const u8,
    email: []const u8,
    email_verified: bool,
};

fn signIn(gpa: std.mem.Allocator, keys: *const jwt.Keys, id_token: []const u8) !Claims {
    return jwt.verify(Claims, gpa, id_token, .{
        .keys = keys,
        .issuer = "https://accounts.google.com",
        .audience = "…apps.googleusercontent.com",
        .now_s = @divFloor(nilo.nowMillis(), 1000),
    });
}
```

| | |
|---|---|
| `jwt.parseKeys(gpa, bytes)` | `!Keys` — a JWKS document read into the keys it can verify with |
| `keys.deinit()` | frees the lot |
| `keys.find(kid)` | `?Key`. A set with one key answers for a token that named none |
| `jwt.verify(Claims, gpa, token, opts)` | `!Claims` — the whole check, then the payload |
| `jwt.key_sizes` | the modulus lengths that have a branch: 256, 384, 512 bytes |

`Options`:

| | |
|---|---|
| `.keys` | `*const Keys`, the issuer's |
| `.issuer` | refuse a token whose `iss` is not this. Null skips it |
| `.audience` | refuse a token whose `aud` does not carry this. Null skips it |
| `.now_s` | seconds since the epoch. An argument, not a clock |
| `.leeway_s` | how far the two clocks may disagree, both ways. `0` |

**Fetching the key set is yours.** It is an HTTPS GET, which `nilo_fetch`
already sends, and holding the answer is `nilo_cache`. What this module does
is the half where being wrong is silent.

<!-- compiles: body -->
```zig
const res = try client.get(&run, "https://www.googleapis.com/oauth2/v3/certs", .{});
var keys = try jwt.parseKeys(gpa, res.body.view());
defer keys.deinit();
```

**Three things are not options**, because each of them is a way to write a
verifier that passes every test and is open:

- **The algorithm is nilo's constant, never the token's `alg`.**
  `{"alg":"none"}` and an HMAC signed with the RSA modulus you published are
  both refused before a key is looked up.
- **Nothing in the payload is read until the signature has passed.** An `exp`
  off an unverified token is a number somebody chose.
- **`exp` is required.** A credential with no end is not one.

Strings in the returned claims point into the allocator you passed. Hand it
`c.arena()` and there is nothing to free.

| what it answers instead | when |
|---|---|
| `error.NotAToken` | not three base64url segments, or the header is not JSON |
| `error.WrongAlgorithm` | the header says anything but `RS256`, `none` included |
| `error.NoSuchKey` | the `kid` is not in the set, or none was named and the set has more than one key |
| `error.BadSignature` | the key is right and the signature is not |
| `error.NoExpiry` / `error.Expired` / `error.NotYetValid` | `exp` missing, `exp` passed, `nbf` not arrived |
| `error.WrongIssuer` / `error.WrongAudience` | `iss` or `aud` is not what you named |
| `error.ClaimsNotReadable` | the signature passed and the payload does not fit your struct |
| `error.KeySizeNotSupported` | a modulus that is not 2048, 3072 or 4096 bits |

**What it will not do**: HS256 and the EC families, encrypted tokens, signing,
discovery, PKCE and the nonce. Signing is absent because a server issuing its
own sessions has [`Session(T)`](#sessiont) and needs no token; the rest is the
sign-in flow, which is yours.

## `Dir`

A directory, opened once and held open — what a service hands a `FileBody`.

| | |
|---|---|
| `Dir.open(path)` | `!Dir` — relative to the working directory the server runs in. Startup work |
| `d.close()` | |
| `d.openFile(name)` | `!File` — a name inside it, resolved by the kernel against the descriptor |
| `d.writeFileAtomic(name, bytes)` | `!void` — replace `name` with `bytes`, all of it or none of it |

Nothing here resolves a path, which is why a name is a name: `openFile` hands it
to the kernel with the directory, so there is no normalisation step to get
wrong. A symlink inside the directory is followed. `error.FileNotFound` is the
one open failure with a better answer than a 500, and a `FileBody` turns it into
the 404 a file that was never there gets.

## `Stream`

| | |
|---|---|
| `s.writeAll(bytes)` / `s.print(fmt, args)` / `s.json(value)` | append |
| `s.flush()` | push what's buffered |
| `s.live()` | false once the server is stopping |
| `s.finish()` | end the body — **required** |
| `s.writer` | a plain `std.Io.Writer` |

## `Events`

| | |
|---|---|
| `e.send(.{ .name = …, .id = …, .data = … })` | one event |
| `e.data(text)` | `data:` alone |
| `e.json(name, value)` | data as JSON |
| `e.comment(text)` | a line the client ignores |
| `e.retry(millis)` | the browser's reconnect delay |
| `e.live()` | false once the server is stopping |
| `e.close()` | |

## `Body`

| | |
|---|---|
| `b.read(&buf)` | `!?[]u8` — the next piece, `null` at the end |
| `b.writeTo(w)` | `!u64` — pump it all into a `std.Io.Writer` |
| `b.discardRest()` | |
| `b.seen()` | bytes read so far |
| `b.size()` | `?u64` — what the request announced; `null` if chunked |
| `b.reader` | a plain `std.Io.Reader` |

## `Socket`

| | |
|---|---|
| `s.receive()` | `!?Message` — the buffer is the executor's, lent for one message |
| `s.send(kind, data)` | `.text` or `.binary` |
| `s.sendText(text)` / `s.sendBinary(bytes)` | |
| `s.print(fmt, args)` | one text message, formatted — no buffer of your own |
| `s.json(value)` | one text message, serialised |
| `s.ping(data)` | |
| `s.close(code, reason)` | safe to call twice |
| `s.closedCleanly()` | whether the other end said goodbye |
| `s.live()` | false once the server is stopping |

`receive` returns `null` when the server is stopping, after telling the client
so with a 1001 — a message loop needs no shutdown branch of its own
([ADR 0052](adr/0052-a-message-is-copied-once-and-framed-once.md)). `live()` is
for a handler doing work of its own between messages. Sending on a socket that
has already closed writes nothing rather than failing.

`c.upgradeWith(loop, state, .{ .idle_ms = 30_000 })` — how long this connection
may say nothing before nilo pings it. No answer by the end of the next stretch
closes it with 1001. Not a deadline: a quiet WebSocket is a working one, so
silence asks a question rather than ending anything. `0` waits forever.
`.max_message` is the ceiling on one message, 16 KiB by default; a frame
announcing more is refused with a 1009 before a byte of it is read.

`.origins` is **which pages may open this socket, and it defaults to yours
alone.** A browser applies no CORS to a WebSocket — no preflight, and it ignores
`Access-Control-Allow-Origin` — so the handshake is an ordinary GET that arrives
carrying the session cookie, and nothing but the server can refuse it
([ADR 0102](adr/0102-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md)).
An `Origin` that does not name the authority the request's `Host` named is a
403. The scheme is not compared, because TLS is terminated in front. A request
with no `Origin` at all — `curl`, a native client — is allowed, because the
ambient cookie this guards is a browser's.

```zig
// the page is on another host to the socket
return c.upgradeWith(chatLoop, room, .{ .origins = &.{"https://app.example.com"} });
// a public socket carrying nothing worth stealing
return c.upgradeWith(feedLoop, {}, .{ .origins = &.{"*"} });
```

`Close`: `.normal`, `.going_away`, `.protocol_error`, `.unsupported`,
`.invalid_payload`, `.policy`, `.too_big`, `.internal`, or a number.

## `Room`

Saying something to sockets a handler does not hold
([ADR 0038](adr/0038-a-broadcast-rings-a-bell-it-does-not-write.md)). A
service like any other: provide one, take it by type.

```zig
var room = try nilo.Room.init(gpa);
defer room.deinit();
try app.provide(&room);

fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
    return c.upgrade(chatLoop, room);
}

fn chatLoop(socket: *nilo.Socket, room: *nilo.Room) !void {
    try room.join(socket);
    defer room.leave(socket);

    while (try socket.receive()) |message| {
        try room.say(message.kind, message.data);
    }
}
```

| | |
|---|---|
| `nilo.Room.init(gpa)` | `!Room` — 1,024 seats, backlog of 4 |
| `nilo.Room.initWith(gpa, .{ .seats = …, .backlog = … })` | `!Room` |
| `room.deinit()` | |
| `room.join(&socket)` | `!void` — `error.RoomFull` when every seat is taken |
| `room.leave(&socket)` | safe twice, safe without joining — pair it with `defer` |
| `room.say(kind, data)` | to everybody in the room, sender included |
| `room.sayText(text)` / `room.sayBinary(bytes)` | |
| `room.print(fmt, args)` | one text message, formatted into the post itself |
| `room.json(value)` | one text message, serialised |
| `room.count()` | how many connections are in it |
| `room.missed(&socket)` | posts this connection was too slow to take |
| `room.full = .drop_oldest` | or `.drop_newest`, when a connection's backlog fills |

The loop is the one an echo server writes: nothing in it mentions the other
connections, and nothing handles an incoming broadcast. `receive` writes those
out on the way past, from the fiber that owns the socket — which is why one
client that stops reading costs that client and nobody else.

`defer room.leave(&socket)` is not optional. Zig has no destructor, and a seat
nobody gives up is one the next connection cannot have.

Sizing a room generously is a memory decision and nothing else: `join` and
`say` both cost what the room *holds*, not what it was sized for, and a `say`
into an empty room allocates nothing at all
([ADR 0052](adr/0052-a-message-is-copied-once-and-framed-once.md)).

## Failing

| | |
|---|---|
| `fail.badRequest(fmt, args)` | 400 |
| `fail.unauthorized(…)` | 401 |
| `fail.forbidden(…)` | 403 |
| `fail.notFound(…)` | 404 |
| `fail.conflict(…)` | 409 |
| `fail.tooLarge(…)` | 413 |
| `fail.unprocessable(…)` | 422 |
| `fail.tooManyRequests(…)` | 429 |
| `fail.internal(…)` | 500 — logged, not sent |
| `fail.status(code, fmt, args)` | any |

All return `error.Failed`. The message goes into a 240-byte slot, no allocation,
and goes out as `{"error": "…", "status": 404}` — the same shape for every
failure, whatever the endpoint returns when it works.

## Concurrency

| | |
|---|---|
| `nilo.Mutex` | `.init`, then `try lock()`, `unlock()`, `tryLock()`, `lockUncancelable()` |
| `nilo.blocking(f, args)` | run a blocking call off the event loop |
| `nilo.Gate` | `.open(n)`, then `try enter()`, `leave()` — a lock that lets `n` through |
| `nilo.sleep(ms)` | wait without parking the thread |
| `nilo.spawn(f, args)` | run something that is not a request, now — `error.NoServer` if nothing is listening |
| `app.spawn(f, args)` | the same fiber, registered before the server and started once it is up ([the guide](./guide/background.md)) |
| `nilo.randomSecure(&buf)` | fill a buffer you already hold, off the event loop |
| `nilo.monotonicNanos()` | a clock reading, for durations |

`lock()` and `sleep()` fail with `error.Canceled` if the request went away, which
maps to a 503. `lockUncancelable()` cannot fail and cannot be interrupted, which
is for a cleanup path — one that has nowhere to put a failure, and would leave
something unreleased if it gave up
([ADR 0104](adr/0104-a-cleanup-path-is-not-cancellable.md)). Only for a short
section that does not itself wait; `lock()` is still the one to reach for.

## What time it is

| | |
|---|---|
| `nilo.nowMicros()` | `i64` — microseconds since the epoch. What `sql.Timestamp` counts |
| `nilo.nowMillis()` | `i64` — milliseconds. What a UUID v7 puts in its first six bytes |
| `nilo.monotonicMicros()` | `i64` — microseconds since an arbitrary point. Two of them subtracted is how long something took |

Plain functions rather than calls on a `Ctx` or a `Run`: reading the wall clock
needs no event loop and nobody owns the time, so there is nothing for a Scope to
be the holder of
([ADR 0045](./adr/0045-core-knows-what-time-it-is.md)). They are `nilo_core`'s,
so a program with no server in it has them too. 15ns a call.

**Use `monotonicMicros` for a duration, never the other two.** A wall clock
moves when an operator moves it or when NTP steps it, so two readings a second
apart can come back in either order. It is the clock `db.watching` times a
statement with ([ADR 0137](./adr/0137-a-statement-can-be-watched.md)).

A handler that waits on the operating system without going through one of these
holds the thread every other request on it is being served by. nilo notices and
says so, once a second at most:

```
handler GET /users/7 held its thread for 2003ms. Every other request being
served on that thread waited the whole time. Hand the call that waits to
nilo.blocking (ADR 0014).
```

It fires on the first request, with nobody else waiting, which is the point —
under `curl` the mistake is otherwise invisible. `block_warning_ms` is the
threshold and `0` turns it off. What is measured is the longest stretch the
fiber ran **without parking**, so a stream, a body reader and a WebSocket are
watched on the same terms as anything else — a blocking call inside a WebSocket
loop is where it costs the most
([ADR 0034](./adr/0034-the-thing-a-handler-holds-is-watched-at-run-time.md),
[ADR 0132](./adr/0132-what-is-watched-is-one-unparked-stretch.md)).

`spawn` starts `f` in a fiber the server owns: counted while it runs, cut off
when the shutdown grace period ends. `error.NoServer` if nothing is listening.
Two things must not travel into it, and the compiler catches neither — a `Str`,
which points into the request arena that is about to be reset, and a fail
function, which has no request to fail and so returns a bare error nobody turns
into a response. Copy what you borrow, and log instead of failing.

```zig
try nilo.spawn(flushMetrics, .{&exporter});
```

**From `main` there is no such moment**, because `listen()` does not return.
`app.spawn` registers the same work before the server and starts it once there
is one — after the port is taken, before the first connection is accepted, and
whichever of ADR 0079's two startup orders the program used
([ADR 0086](./adr/0086-work-that-is-not-a-request-belongs-to-the-server.md),
[the guide](./guide/background.md)):

```zig
try app.spawn(flushEvery, .{&exporter});
try app.listen(.{});
```

The work is a loop around a wait that can say stop: `nilo.sleep` fails with
`error.Canceled` when the grace period ends, and that is the only way out.

Sending to a WebSocket somebody else's connection is holding does not need
this — see [`Room`](#room). It needs no fiber of its own, which is the whole
of [ADR 0038](adr/0038-a-broadcast-rings-a-bell-it-does-not-write.md).

## Built-in middleware

```zig
nilo.logger.standard                                    // one info line per request
nilo.logger.with(.{ .level = .info, .slow_micros = 0,   // slower than this → .warn
                     .format = .text,                    // or .json, one object per line
                     .request_id = false })              // X-Request-Id out, and on the line

nilo.cors.permissive                                    // origins &.{"*"}, no credentials
nilo.cors.with(.{ .origins = &.{…}, .methods = …, .headers = …,
                   .expose = …, .credentials = false, .max_age = 0 })

nilo.cors.reading(&origins, .{ … })                     // the list read at run time

nilo.allowance.with(.{ .per_window = 100, .window_s = 60,   // 429 past this
                        .slots = 16 * 1024,                  // addresses remembered
                        .ipv6_prefix = 64, .name = "" })

nilo.allowance.keyed(account, .{ .per_window = 1000,        // …counted against
                        .window_s = 60, .slots = 4 * 1024,   //   what `account`
                        .on_null = .reject, .name = "" })    //   returns

nilo.deadline(2000)                                         // how long a route gets
nilo.maxBody(50 << 20)                                      // how much body it takes
```

`origins` is a list because `Access-Control-Allow-Origin` carries one value:
the request's `Origin` is compared against each entry and the one that matched
is what goes out. Lowercase, and refused at build time otherwise. `&.{"*"}`
answers anyone and reads no header at all; anything else also sends
`Vary: Origin`, whether or not it matched.

**`cors.reading` is the same middleware with the list read at run time**, for
the deployment fact `with` cannot express — the front end at one address in
staging and another in production
([ADR 0110](./adr/0110-an-origin-is-a-fact-about-the-deployment.md)).
Everything but the list stays comptime.

| | |
|---|---|
| `nilo.cors.Origins` | where the list lives. `.empty` to start; a `var` that outlives the App |
| `o.set(&.{ … })` | take a list you assembled. `error.OriginNotLowercase`, `.OriginEmpty`, `.OriginIsWildcard` |
| `o.setSplit(&buf, text)` | split `"https://a.com,https://b.com"` into `buf`, which is yours. `error.TooManyOrigins` past its length |
| `nilo.cors.reading(&o, .{ … })` | the middleware. `.origins` in the options is a compile error — the list is `o`'s |

**The text is borrowed and has to outlive the server** — the environment block
and a `.env`'s text both do — which is what lets the matched origin go out
without being copied, so a cross-origin request still allocates nothing. `"*"`
is refused: that is `cors.permissive`. A list nobody filled refuses every
cross-origin request and says so in the log once.

### `nilo.allowance`

**How many requests one address may make inside a window.** Past it the request
is a 429 carrying `Retry-After`, and the handler is never reached.

<!-- compiles: body -->
```zig
try app.useOn("/api", nilo.allowance.with(.{ .per_window = 100, .window_s = 60 }));
```

| | |
|---|---|
| `.per_window` | how many requests, 1 to 1023 |
| `.window_s` | how long the window is, in seconds. Also what `Retry-After` says |
| `.slots` | how many addresses are remembered at once. A power of two, ≥ 64. Eight bytes each |
| `.ipv6_prefix` | how much of an IPv6 address is one client. 64 is one customer's allocation |
| `.name` | tells this allowance apart from another with the same numbers |

The table is sized while compiling and lives in `.bss`: **no allocation per
request and none at startup**, 131,072 bytes at the default, and nothing at all
in a program that does not use it. The window **slides** — the previous one is
weighed by how far into the current one the request arrived — so a hundred at
11:59:59 and a hundred at 12:00:00 is not two hundred through.

Two things it does on purpose
([ADR 0114](./adr/0114-an-allowance-is-a-table-sized-while-compiling.md)):
a bucket with no room **forgets its stalest address** rather than letting two
share one allowance, and a slot under contention **lets the request through**.
Both are the same trade — being loose for one window beats refusing somebody who
has made no requests at all.

Two `with()` calls carrying the same options are one table. Give one a `.name`
to count a sign-in route apart from a search route.

**Behind a proxy, set `.trusted_hops`** on `listen`, or every request looks like
it came from the proxy and the whole table is one slot. A refusal that finds an
`X-Forwarded-For` on a request counted against the socket's own address says so
in the log once.

It is not a defence against a flood — a refused request is still read, parsed,
matched and answered. That is `max_connections`.

#### `allowance.keyed` — counted against something the application knows

**`with` counts against the address**, which is right for a scraper and wrong
for everything the application knows: ten accounts behind one office NAT share
an allowance they should not, and one account on ten machines gets ten.

```zig
fn account(c: *nilo.Ctx) ?nilo.Str {
    const who = c.session(Account) orelse return null;
    return who.id;
}

try app.useOn("/api", nilo.allowance.keyed(account, .{
    .per_window = 1000,
    .on_null = .reject,
}));
```

The first argument is a function of one `*Ctx` returning `?[]const u8` or
`?nilo.Str`. **Its bytes are not kept** — they live in the request arena — so
what goes in the table is a 64-bit tag from a keyed hash, in a word of its own
beside the counters ([ADR 0131](./adr/0131-a-key-the-application-knows-is-a-word-of-its-own.md)).

| | |
|---|---|
| `.per_window` | how many requests, 1 to 65,535 — the whole range, unlike `with` |
| `.window_s` | as `with` |
| `.slots` | how many keys are remembered at once. A power of two, ≥ 64. **Sixteen** bytes each; 4,096 by default |
| `.on_null` | **required.** `.skip` — not counted, and through. `.reject` — a 403 |
| `.name` | as `with` |

**`on_null` has no default on purpose.** `keyed(signedInAccount, …)` on a
sign-in route with a silent skip leaves every *failed* sign-in uncounted, which
is the attack the route exists to stop. The right shape for that route is the
*claimed* username with `.on_null = .reject`, composed with an address-keyed
`allowance.with` underneath it — which is `use` twice.

`.reject` answers 403 rather than 429: nothing was rated and nothing exceeded,
and a `Retry-After` on it would be a lie.

### `nilo.deadline`

**How long a route gets**, as a middleware:

```zig
try app.with(nilo.deadline(2000)).get("/report", buildReport);
```

`listen()`'s four deadlines bound one wait for the network each and none of them
bounds the request. This clamps every wait nilo owns — the body, the write, a
stream's pieces, a WebSocket's silence — to whichever comes first.

**A running handler is not interrupted**, and deliberately is not: a cancel
firing mid-handler is a cancel every handler, every `nilo.Mutex` and every
Service has to survive
([ADR 0104](./adr/0104-a-cleanup-path-is-not-cancellable.md)). A loop doing its
own work asks `c.overdue()`:

```zig
while (try rows.next()) |row| {
    if (c.overdue()) return nilo.fail.status(503, "too many rows to do in time", .{});
    try out.json(row);
}
```

A handler that fails while overdue with nothing sent gets a 503 naming the
budget. One that finishes late still answers — the work is done and correct —
and the lateness is a log line
([ADR 0133](./adr/0133-a-route-can-say-how-long-it-has.md)). `deadline(0)` is a
compile error.

### `nilo.maxBody`

**How much body a route takes**, as a middleware:

```zig
try app.with(nilo.maxBody(50 << 20)).post("/import", importCsv);
try app.with(nilo.maxBody(1024)).post("/sign-in", signIn);
```

`listen()`'s `max_body` is one number for every route, and an import and a
sign-in do not have the same budget. This is the same argument `nilo.deadline`
makes about time, with the same answer: the route says. It bounds every read
into the request arena — `c.body()`, a JSON body, a `Form(T)`, a `Bound(…)`
of either — and a `Content-Length` past it is a 413 before a byte is read.
Lowering is as ordinary as raising.

**It does not touch `c.bodyStream()`**, which holds nothing in the arena and
takes a `max_bytes` of its own
([ADR 0194](./adr/0194-a-route-can-say-how-much-body-it-takes.md)).
`maxBody(0)` is a compile error.

## `nilo.accept`

What the request's `Accept` header says about one media type. One call, no
allocation, and the reader the single-page fallback decides with
([ADR 0109](./adr/0109-a-fallback-answers-a-navigation-not-a-missing-asset.md)).

```zig
switch (nilo.accept.asks(c.header("Accept"), "text/html")) {
    .named => …,      // the client asked for it, or for `text/*`
    .anything => …,   // it said `*/*` and nothing more specific
    .unsaid => …,     // there is no Accept header at all
    .refused => …,    // it named other types, or named this one with q=0
}
```

`asks(header, kind)` takes `?[]const u8` — `c.header(…)` gives a `?Str`, so
pass `if (c.header("Accept")) |h| h.view() else null`. The type is comptime and
has to be a full media type: `"text/*"` is a compile error, because the answer
is about one type rather than a family.

The most specific entry decides, which is RFC 9110's rule: `text/html;q=0, */*`
is `.refused` for HTML and `.anything` for everything else. There is no
`Format`-shaped negotiation over several offers — this answers one question and
a handler with two things to serve asks it twice.

## Static options

`app.staticWith(prefix, dir, …)`:

| | Default |
|---|---|
| `index` | `"index.html"` |
| `cache_control` | `"public, max-age=3600"` |
| `spa_fallback` | `""` (off) |
| `spa_fallback_for` | `.navigations` — or `.any_path`, which is what shipped before 0.2.0 |
| `max_file_bytes` | `8 * 1024 * 1024` |
| `max_total_bytes` | `64 * 1024 * 1024` |
| `dotfiles` | `false` |
| `reload` | `false` — hold nothing, open every file per request |

`spa_fallback_for` decides which requests the fallback answers: `.navigations`
is a request naming `text/html`, or one that named nothing and has no file
extension in its last path segment, and everything else under the prefix is a
404 naming the path. See
[Static files](./guide/static-files.md#the-fallback-and-what-it-is-for).

`max_file_bytes` is a threshold, not a ceiling: a file over it is listed but not
read, and each request opens it and sends it from the disk — no gzipped copy, an
ETag made of the modification time and the size, and one file descriptor for as
long as the response takes. `max_total_bytes` counts held bytes only. See
[Static files](./guide/static-files.md#files-too-big-to-hold).

Both the length and the ETag of a spilled file come from one look at the
descriptor whose bytes are about to go out, so editing a file under a running
server cannot serve a stale length under a stale tag
([ADR 0125](./adr/0125-a-file-is-described-by-the-descriptor-being-sent.md)).

**`reload = true` is `max_file_bytes = 0` with a name**: nothing is held, every
file is opened per request, and editing one works without a restart. For
development — it gives up the in-memory copy and the gzipped one — and a file
that did not exist at startup still needs a restart, because the list of names
comes from the walk.

## OpenAPI options

`app.docs(…)`:

| | Default |
|---|---|
| `title` | `"API"` |
| `version` | `"1.0.0"` |
| `description` | `""` |
| `path` | `"/openapi.json"` |
| `ui_path` | `"/docs"` — empty for none |

A type with a `jsonStringify` is described by what it says, not by its fields —
`std.json` calls the function and never reads them, so reflecting them would
describe something the server does not send
([ADR 0076](./adr/0076-a-type-that-writes-its-own-json-says-so.md)):

```zig
pub const nilo_openapi = .{ .type = "string", .format = "uuid" };
```

`type` is required — `"string"`, `"integer"`, `"number"`, `"boolean"` — and
`format` is an optional hint. nilo's own types carry it already (`Uuid`,
`Timestamp`, `Decimal`, `Interval`, `Inet`). One with a custom writer and no
marker gets `{}` and a description saying so.

### The document without a server

`app.writeOpenApi(w)` writes the same bytes `/openapi.json` serves, to any
writer, with **no port, no database and no network**
([ADR 0167](./adr/0167-the-document-is-a-build-artefact.md)):

<!-- compiles -->
```zig
fn listUsers() ![]const User {
    return &.{};
}

pub fn writeTheDocument(gpa: std.mem.Allocator) ![]u8 {
    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/users", listUsers);
    app.docs(.{ .title = "Orders", .version = "2.1.0" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try app.writeOpenApi(&out.writer);
    return gpa.dupe(u8, out.written());
}
```

Call it after the routes are registered and before `listen`. The operations are
collected as each route is registered, so nothing has to have started.

**`app.provide` does not have to be called**, which is what makes the build
step's binary genuinely clean. `provide` is for the request path; writing the
document needs only the operations, so a program that does nothing but write it
links no database driver and needs no stand-in `*Db` to get registration past
the type checker.

**Register the routes in one place both callers use.** A `routes.zig` that
`main.zig` and the document step each call is the same argument as `buildDocs`
going through this method rather than beside it: two route lists is how a
checked-in contract starts describing a server that no longer exists, and the
one somebody forgets to add to the second list disappears with no error and no
failing test.

**This is what makes the document a build artefact rather than a thing you
curl.** A checked-in `openapi.json` is how a typed frontend client is generated
and how a breaking change shows up in review; producing it by booting a server
means `listen`, which means `db.checking`, which means a migrated database — so
a file describing a set of types ends up needing Postgres. `zig build openapi >
openapi.json` needs none of it.

The title and version come from `app.docs(.{ … })` if it was called, and are
`"API"` / `"1.0.0"` if it was not, so a program that serves no document can
still write one. The served copy goes through this same call, which is what
stops a checked-in file and a running server describing two different APIs.

## Testing

| | |
|---|---|
| `testing.Client.init(gpa, .{ .response_bytes = 64 * 1024 })` | |
| `.{ .client_address = "203.0.113.7" }` | what `c.peer()` and `c.clientIp()` answer |
| `.{ .cookies = true }` | keep what the answers set and send it back — a browser's jar. Off by default |
| `client.get(&app, path)` / `post(&app, path, body)` | |
| `client.postWith(&app, path, content_type, body)` | a POST that says what its body is — what a form needs |
| `client.request(&app, method, path, body)` | |
| `client.sendRequest(&app, .{ .method, .path, .headers, .content_type, .body })` | all of it, described. Every field has a default |
| `client.setHeader(name, value)` | sent with every request from now on. Setting it again replaces it |
| `client.cookie(name)` | `?[]const u8` — what the jar holds |
| `client.send(&app, raw_request)` | the whole request, written out. Sticky headers and the jar are **not** applied |
| `answer.status` / `.head` / `.body` / `.raw` / `.chunked` / `.keep_alive` | |
| `answer.interim` | `?[]const u8` — the `100 Continue` that came first, or null. `.status` is the final one either way |
| `answer.header(name)` | case-insensitive, the first of that name |
| `answer.headerAt(name, n)` / `.headerCount(name)` | for the ones a response repeats |
| `answer.setCookie(name)` | the whole `Set-Cookie` line that sets it |
| `answer.text(&buf)` | the body with chunk framing undone, into a buffer you sized |
| `answer.bytes(arena)` | the same, into memory the arena owns |
| `answer.json(T, arena)` | `!T` — the body read back as a value ([ADR 0180](./adr/0180-a-response-is-read-back-the-way-it-was-written.md)) |

**`answer.json` is there because nilo already decided how the value was
written**, so a test asking what came back should not have to reach for
`std.json` and walk a `Value`:

```zig
const made = try answer.json(struct { id: []const u8 }, arena);
```

It de-chunks first, and everything is copied into `arena` so what comes back
outlives the client's response buffer and the next request on it. **Unknown
fields are ignored**, which is the opposite of the rule on the way in and
deliberately: an unknown field in a *request* is the client's typo and is a 400
naming it, while a response with more fields than the test asked about is the
ordinary case. Ask for `std.json.Value` when the shape itself is what is being
asserted.

### An App and a Client, wired together

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
| `wired.app` | a plain `App` — every registration call is the one documented above |
| `wired.get(path)` / `post(path, body)` / `postWith(…)` / `request(…)` | the `Client` calls, without the `&app` |
| `wired.sendRequest(r)` / `send(raw)` / `setHeader(n, v)` / `cookie(n)` | likewise |
| `wired.deinit()` | the client, then the App |

**The routes and the services stay yours**, which is where the line is: `app` is
a field rather than something behind methods, so nothing here is a second API and
no database is assumed. `Client` is unchanged and is still the answer when a test
needs two of them against one App — two addresses, two cookie jars.

A WebSocket route has no answer to read, so it has a driver of its own
([ADR 0113](./adr/0113-a-websocket-route-can-be-driven-from-a-test.md)):

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
| `chat.text(s)` / `binary(b)` / `ping(b)` / `pong(b)` | queue one frame, masked as a client must |
| `chat.close(code, why)` | queue a close frame |
| `chat.fragments(.text, &.{ … })` | one message split across continuations |
| `chat.raw(bytes)` | bytes framed by nobody — for what a **malformed** frame does |
| `chat.setHeader(name, value)` | sent with the handshake — an `Origin`, a cookie, a subprotocol |
| `chat.open(&app, path)` | run it. The queue is cleared, so the same conversation can open again |
| `talk.accepted()` / `.status` / `.header(name)` | the handshake |
| `talk.at(n)` / `.first(kind)` / `.messages` | the frames the server sent, decoded and in order |
| `talk.closedWith()` | the close code, or null if it never closed |

A `Message` is `.kind` (`.text`, `.binary`, `.ping`, `.pong`, `.close`),
`.bytes`, and `.code()` / `.reason()` for a close frame.

**The frames are queued before the server runs, not while it runs.** One
thread and no socket, so a test cannot read what the server said and then
decide what to send next — and a conversation between *two* sockets, a `Room`
broadcast included, needs two connections and is out of reach here.

### A failed assertion that can be read

`std.testing` prints both sides with `{any}`, and `{any}` is the specifier that
means *do not call the type's own formatter* — so a `Uuid` prints as sixteen
decimal numbers and a `[]const u8` as its bytes. On a schema with many uuid
columns nearly every row asserted on comes out as noise
([ADR 0169](./adr/0169-a-failed-assertion-that-can-be-read.md)):

```zig
errdefer std.debug.print("row: {f}\n", .{nilo.testing.show(row)});
```

`show(value)` renders as JSON into whatever writer is formatting it — the
rendering nilo already has for the types it carries, so a `Uuid` is text, a
`Str` is a string and a `Timestamp` is RFC 3339. **Nothing is allocated**, which
is what lets it sit inside a `std.debug.print` while you are poking about. For an
actual `[]const u8`, `std.fmt.allocPrint(gpa, "{f}", .{nilo.testing.show(v)})`
needs nothing from here.

It is a renderer and not an assertion on purpose: an `expectEqual` of nilo's own
would pull `expectEqualDeep`, `expectEqualSlices` and `expectError` behind it,
and it would not have helped the failure this came from, which was an
`expectError` finding a payload rather than two values that differed. A `Json(T)`
column nests JSON inside the JSON, which reads well and is not meant to be parsed
back.

### Catching a refusal with no request in flight

A service function called from a CLI, a seed or a plain test refuses through the
same fail functions, and outside a request there is nowhere to park the status —
so four different refusals arrive at the caller as four identical
`error.Failed`. `Refusals` gives the test the status and the sentence back
([ADR 0161](./adr/0161-a-refusal-outside-a-request-is-still-a-refusal.md)):

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
| `refusals.begin()` | install the slot. Not a constructor: what goes in the slot is this struct's address |
| `refusals.end()` | put back whatever was there. Safe twice, safe on one that never began |
| `refusals.caught()` | `?Refused` — `.status` and `.message`, or null if nothing refused |
| `refusals.clear()` | forget the last one, for a test that makes a second call |

`clear` between calls matters: without it the second assertion passes on the
first call's sentence, which is the one way a test like this goes quietly wrong.
`message` is borrowed from the `Refusals`, so it lives as long as that does.
This is a test type — the slot it installs is the Bulkhead's fallback, the one a
call made off the loop already uses, and a running server has a real slot per
fiber.

## `nilo_sql`

A second module, imported separately. A project that never imports it links
none of it ([ADR 0040](./adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)).

**Two databases, one API.** `sql.Db` is Postgres and `sql.Sqlite(…)` is SQLite;
everything on the rest of this page is written once and works against either.
[SQLite](#sqlite) says what it takes to open one and lists the four things it
refuses.

```zig
const sql = @import("nilo_sql");
```

### A Row

```zig
const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: nilo.Str,
    age: i32,
    created_at: sql.Timestamp,
};
```

| | |
|---|---|
| `.name` | the table, **written out**. Never guessed from the type name. `"app.users"` is a schema and a table; a bare name is whatever `search_path` resolves to |
| `.key` | the column that identifies a row. Defaults to `id` when there is a field of that name |
| `.managed = false` | this program reads the table and does not build it; the migrator leaves it alone. See [Migrations](#migrations) |
| `pub const nilo_table = Other` | a narrower Row: the same table as `Other`, fewer columns, checked against it while compiling |
| `pub const nilo_table = .projection` | a Row that owns no table at all — the shape `db.raw` fills. See below |

#### A Row that owns no table

A join, an aggregate or a window function comes back in a shape no table has.
`.projection` is a Row that says so
([ADR 0155](./adr/0155-a-row-that-owns-no-table.md)):

<!-- compiles -->
```zig
const Busiest = struct {
    pub const nilo_table = .projection;

    email: Str,
    documents: i64,
};
```

It has every column type, every reader and every conversion an ordinary Row has,
and no table, so `db.select`, `db.find`, `db.insert` and the migrator all refuse
it while compiling, naming the type and saying it is a projection. `db.raw` and
`db.exec` are what it is for. Before this the only way to spell such a shape was
to give it a `.name` that pointed at a real table it did not match, which
compiled and then said nothing when somebody wrote `db.select` against it.

### `Db`

```zig
var db = sql.Db.init(gpa, "postgres://…", .{});
defer db.deinit();
db.checking(&.{ User, Order });   // optional
db.watching(sql.logging);         // optional
try app.provide(&db);
```

`db.watching(f)` calls `f` with a `sql.Sent` after every statement — the text,
the plan name it is kept under, how long the database took, how many rows moved
and whether it failed. **Not the values it bound**, which are somebody's
password as often as they are an id
([ADR 0137](./adr/0137-a-statement-can-be-watched.md)). `sql.logging` is a
ready-made one that writes a debug line. A `Db` nobody watches pays one null
test per statement.

A statement that failed also carries `sent.problem`: the database's own
`message`, its SQLSTATE `code`, `severity`, `detail`, `hint` and the
`constraint` that was violated
([ADR 0146](./adr/0146-a-statement-that-failed-says-what-the-database-said.md)).
Fields a given database does not answer are empty rather than null — SQLite has
no SQLSTATE and does not invent one. When the driver refused the statement
before it left the process, `message` is the Zig error's name, which is the case
this exists for: `error.QueryFailed` used to be the whole of what a program
could see. It lives in the request's arena, so a watcher keeping one past the
request copies it, and it still never reaches the client
([ADR 0025](./adr/0025-every-failure-answers-with-the-same-json-body.md)).

**`sql.problem(c)` is the same struct asked for from the other end** — by the
call that failed rather than by an observer of every call. See
[Errors](#errors).

`db.nilo_start(io, limits)` is what `listen()` calls; a program starting a `Db`
by hand passes `.off` and the pool's waits are bounded by nothing.
`db.nilo_stop()` is the other half, and `listen()` calls that too — after the
last connection is cut off and before the Engine's loop is torn down, so the
pool lets go of the loop it was built on
([ADR 0151](./adr/0151-a-service-is-stopped-before-the-loop-is.md)). **A `Db`
is not usable after `listen()` returns.** A program driving one by hand calls
`deinit` as it always did.

`db.nilo_ready(scope)` is what `app.health` asks: `SELECT 1` down the pool,
and the reason when it did not come back — so a server started with
`connect_on_init = 0` over a database that is down is a 503 on its health
page rather than a 200 over an empty pool
([ADR 0192](./adr/0192-a-health-route-asks-the-services.md)). An `s3` Store
answers the same question with whether it started.

`init` opens nothing. The pool is built by `listen()`, which is the only
moment there is an event loop to dial through — so a server starts with its
database switched off, and the first request that needs it gets
`error.Disconnected`.

**A database on the same box should be reached over its unix socket** —
`postgres://app:secret@%2Fvar%2Frun%2Fpostgresql%2F.s.PGSQL.5432/shop`, the
full socket path with the slashes percent-encoded. Same server and same query:
197k req/s across a Docker published port, 359k over loopback TCP, 458k over
the socket, with p99 halved ([`bench/result/sql.md`](../bench/result/sql.md)).

| `Opts` | |
|---|---|
| `size` | connections held open. Default 10. The knob with a real curve behind it: 8 → 133k req/s, 16 → 148k, 32 → 180k, 64 → 206k, with p99 best at 32. Each one is a Postgres backend and a slot against `max_connections` |
| `connect_on_init` | how many to dial during `listen()`. Default 0 — set it to `size` when driving a `Db` from a `std.Io.Threaded` ([ADR 0062](./adr/0062-a-pool-that-dialled-itself-whatever-it-was-told.md)) |
| `timeout_ms` | how long a caller waits for a free connection. Default 10,000. Bounded on SQLite too since [ADR 0135](./adr/0135-a-wait-for-a-connection-has-a-bound.md), where it needs the Engine to enforce it |
| `schema_mismatch_is_fatal` | whether a Row that disagrees with its table stops startup. Default true |
| `prepared` | whether a statement is kept prepared on the connection it went down. Default true |

**A suite whose database is not running: turn the log level down, and do it with
`std.testing.log_level`.** A `Db` that cannot dial says so at `warn` and returns
the error ([ADR 0178](./adr/0178-a-suite-whose-database-is-down-is-not-a-suite-that-failed.md)),
but pg.zig logs its own connect failure at `err` — and the Zig test runner counts
a logged `err` as a failed test, so a suite that skipped 95 tests exactly as it
meant to still exits 1.

```zig
test "…" {
    const previous = std.testing.log_level;
    std.testing.log_level = .warn;
    defer std.testing.log_level = previous;
    …
}
```

`std.testing.log_level` is a plain `pub var` the runner compares against on every
line. **`std_options` in a tested file is never consulted** and this is the thing
to know before spending an afternoon on it: the root of a test build is the
compiler's own `test_runner.zig`, which declares `std_options` itself, so a copy
in your file is dead code that appears to work whenever the build runner caches
the step and skips the binary.

`sql.Named("replica")` is a **second `Db` type**, so a second database is a
second service and which pool a statement takes is written in the handler's
argument list. Nothing routes between them: an automatic reader needs health
checking, lag awareness and read-after-write safety, and the last fails
silently ([ADR 0060](./adr/0060-a-second-database-is-a-second-type.md)).
`sql.Named("")` is a Refusal. There is no query cache — invalidation cannot
be right from a module that sees only its own writes.

Every statement this module sends is a comptime constant, so it is kept
prepared on its connection under a name derived from its own text — worth
**30% of a key lookup and 14% of a page with a sort**, ~12 µs either way
([ADR 0057](./adr/0057-a-statement-that-is-a-constant-can-be-prepared-once.md)).
`db.raw` is prepared too, since its text is comptime
([ADR 0148](./adr/0148-a-raw-statement-is-counted-while-compiling.md)). Set
`.prepared = false` behind a **connection pooler in transaction mode**
(pgbouncer), which hands out a different server connection per transaction.

A Row may name a **view** or a **materialized view** as well as a table. The
column types are checked there; nullability is not, because Postgres does not
track `NOT NULL` through a view
([ADR 0056](./adr/0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md)).
An identity key, a sequence default and a generated column need nothing said
about them — an insert names a subset of the Row's columns and `RETURNING`
brings the rest back.

A Row says three things about its schema and no more: `.unique`, `.index` and
`.references` ([ADR 0153](./adr/0153-a-migration-is-a-diff-against-a-snapshot.md),
which amends the older refusal that it may say none). Only the Row that names a
table may say them, and nothing enforces that because the language does — a
borrowed Row's marker is a `type`, and there is nowhere on a type to write
`.unique`. Where the line falls is where the compiler stops being able to
check: `CHECK (age > 18)` is text nilo cannot read, so it is written by hand in
a step, and **nilo never touches what it did not create**. See
[Migrations](#migrations).

### SQLite

The same `Db`, over a file instead of a server. Everything below this section —
Rows, queries, batches, upserts, conditions, streaming, transactions — is the
same code and the same types; what changes is the five things SQLite refuses,
listed at the end.

```zig
const Db = sql.Sqlite(.{ .threading = .{ .hop = nilo } });

var db = Db.init(gpa, "/var/lib/app/shop.db", .{});
defer db.deinit();
try app.provide(&db);
```

`threading` **has no default and the compiler will not let you leave it out**.
SQLite is a library reading a file rather than a server on a socket, so there
is no wait for the event loop to park on and the choice cannot be made for you
([ADR 0073](./adr/0073-a-file-has-no-socket-to-wait-on.md)):

| | |
|---|---|
| `.{ .hop = nilo }` | hand each statement to the Engine's thread pool and park the fiber. Costs a few microseconds per statement; **no statement can stall an executor thread**. The payload is `nilo` itself, passed in because `sql/` may not import `nilo_http` |
| `.in_fiber` | run it on the fiber that asked. Faster when every statement is a cached lookup; a slow one holds a thread that serves other connections |

Which is the better default is unmeasured and is `docs/roadmap.md`'s Next 1 for
this module. When in doubt take `.hop`: its bad case is a few microseconds and
`.in_fiber`'s is a stalled thread.

| `sqlite.Options` | |
|---|---|
| `threading` | above. **No default** |
| `busy_timeout_ms` | how long to wait for a lock another *process* holds before answering `error.Locked`. Default 5,000 |
| `cache_kib` | `PRAGMA cache_size`, or null for SQLite's 2,000 KiB. **A ceiling, not an allocation**: a connection holds 28 KiB opened and grows towards this as pages are touched ([`bench/result/sql.md`](../bench/result/sql.md) §9) |
| `synchronous` | `.normal` (the default, WAL's recommended setting — the database cannot corrupt, a power cut can lose recent transactions) or `.full`. `OFF` is not offered |

`wire.OpenOpts` is the same struct both drivers take, so `size`, `timeout_ms`
and the rest are written the same way. **`size` is one writer and `size - 1`
readers**, and that is the database rather than a setting: SQLite allows one
writer at a time, so writes queue on a single connection and reads run beside
them under WAL ([ADR 0074](./adr/0074-one-writer-is-not-a-setting-it-is-the-database.md)).
`connect_on_init` is ignored — a file is opened or it is not.

Every connection is primed with `journal_mode = WAL` and `foreign_keys = ON`.
Which connection a statement takes is decided by its first keyword: `SELECT`
and `PRAGMA` take a reader, everything else takes the writer. That is exact for
everything this module generates and a **guess for `db.raw`**, whose text is
yours — a `raw` that writes and looks like a read lands on a read-only
connection and fails loudly. On a file. Not in memory, where SQLite's URI
`mode=` overrides the open flags and the backstop is absent.

The url is a path, or SQLite's URI form. **A bare `:memory:` is refused at
`open`**, because a pool of them is several separate empty databases; the
shared form `file:name?mode=memory&cache=shared` is one, and lives only as
long as a connection to it does.

`sql.SqliteNamed("cache", .{…})` is the second-database form, exactly as
`sql.Named` is for Postgres. `sql.sqlite.version` is the bundled SQLite's
version string — the amalgamation is vendored by the driver, so it is what the
build pinned rather than what the machine had.

**What SQLite refuses, while compiling, naming the dialect:**

| | why |
|---|---|
| `insertMany` | no `unnest` and no array parameter. The batch form SQLite has grows its own statement text, which is the rule this module is built on. Write a row at a time inside one transaction — cheap here, because there is no round trip to pay per statement |
| `.lock` | writers are serialised by a lock over the whole database, so there is no row to hold against anybody |
| `tx.deadline` | needs the database to enforce it, and there is no server. `sqlite3_interrupt` aborts the whole connection rather than one statement. `busy_timeout_ms` covers the case that actually happens |
| a list column | no array type. A list belongs in its own table, or in a TEXT column your own code encodes |
| `.isolation` other than `.serializable` | SQLite gives every transaction a snapshot and serialises the writers. There is no weaker level to ask for |

A `sql.Uuid` is **not** on that list, and only stopped being on it in
[ADR 0078](./adr/0078-a-uuid-is-whatever-the-database-stores.md). SQLite has no
uuid type, so one travels as the thirty-six hyphenated characters into a TEXT
column — which is what the schema check has always asked for, and what makes
`sqlite3` show the id and `WHERE public = '…'` typeable. Postgres still sends
sixteen bytes. Your Row says `public: sql.Uuid` either way.

**Nor are `.in`, a `sql.Json(T)` column or an enum column**, though until
[ADR 0119](./adr/0119-the-sqlite-write-path-is-compiled.md) all three behaved as
if they were: each read correctly and failed to *compile* on the way in, from
inside the driver. SQLite has neither a `jsonb` nor an enum type, so a document
and a tag both bind as text, and `.in` binds its whole list as one JSON array
that `json_each` takes apart — which is what keeps the statement a constant on
a database with no array parameter. `.in` is the only one of the three that
costs anything: **one arena allocation per condition, on SQLite alone**,
because the array has to be written where Postgres sends a native one.

So **code that batches is not portable between the two dialects**, and that is
the seam refusing rather than lying. The schema check is weaker too, by exactly
as much as SQLite is: a column's declared type is free text and what is
enforced is one of five affinities, so it catches a `Str` field over an
`INTEGER` column and does not catch an `i32` over a column holding values that
do not fit.

SQLite costs **523,352 bytes** to a program that names it and **zero** to one
that does not — both drivers live in one module, but `sql/sqlite.zig` is
analysed only when something names it, so a Postgres-only binary carries no
amalgamation at all.

### Queries

Every one takes the Row, a [Scope](#scope) — the `*Ctx` inside a handler, a
`*nilo.Run` anywhere else — and a struct written where it is used. All of them
compile their SQL to a constant.

The Scope is why this module names no App: `arena()` and `str()` were the only
things it ever asked a `Ctx` for, so a query runs the same in a CLI as in a
request ([ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md)).

| | |
|---|---|
| `db.select(User, c, .{ … })` | `![]User` |
| `db.one(User, c, .{ … })` | `!?User` — a handler returning this answers 404, and the document says so. Carries its own `LIMIT 1`, so a `.limit` beside it is refused |
| `db.find(User, c, id)` | `!?User` — the same, on the column the Row's `.key` names. Takes the key itself, not a condition |
| `db.page(User, c, .{ .where = …, .order = …, .limit = 20 })` | `!Page(User)` — `.rows` and `.total`, in one statement. `.limit` and `.order` are required; see below |
| `db.count(User, c, .{ .where = … })` | `!usize`. `.where` only, and optional — no condition counts the table |
| `db.exists(User, c, .{ .where = … })` | `!bool` — `SELECT EXISTS(…)`, so it stops at the first match |
| `db.insert(User, c, .{ .email = … })` | `!User` — the stored row, generated key included. A subset of the columns |
| `db.insertMany(User, c, rows)` | `![]User` — a whole batch in one statement, back in the order it was sent. `rows` is a `[]const Line`, `Line` a named struct of the columns being written; see below |
| `db.insertOrIgnore(User, c, .{ … }, .key)` | `!?User` — the stored row, or `null` when one was already there. `ON CONFLICT … DO NOTHING`. `.key` is the Row's own key; a column name is for a unique index that is not the key |
| `db.insertOrUpdate(User, c, .{ … }, .email)` | `!User` — stored, or the existing row with these values written over it. `ON CONFLICT … DO UPDATE` |
| `db.update(User, c, .{ .set = …, .where = … })` | `!usize` — rows changed. Both halves required |
| `db.updateMany(User, c, rows)` | `![]User` — a whole batch in one statement, found by the Row's key. No `.where`: the join is the condition; see below |
| `db.updateReturning(User, c, .{ .set = …, .where = … })` | `![]User` — the rows as they now are. One statement where an update and a select are two and a race |
| `db.updateReturningOne(User, c, .{ .set = …, .where = … })` | `!?User` — the same for a `.where` holding a key, so a PATCH endpoint is one call and null is its 404 |
| `db.delete(User, c, .{ .where = … })` | `!usize` — rows deleted. `.where` required |
| `db.deleteReturning(User, c, .{ .where = … })` | `![]User` — the rows that were removed |
| `db.stream(User, c, .{ … })` | rows one at a time; see below |
| `db.raw(User, c, sql, .{ … })` | `![]User` — a statement this module will not write. `sql` is **comptime**: the `SELECT` list is counted against the Row's fields and each column that plainly has a name is checked against the field in its position, and the statement is kept prepared like every other ([ADR 0148](./adr/0148-a-raw-statement-is-counted-while-compiling.md)) |
| `db.rawOne(User, c, sql, .{ … })` | `!?User` — the same, for a statement whose `WHERE` holds a key. **No `LIMIT 1` is added**; see below |
| `db.exec(c, sql, .{ … })` | `!usize` — a statement that answers with *nothing*, and the rows it changed. `CREATE TABLE`, `CREATE INDEX`, `PRAGMA`, `VACUUM`. No Row, because none is being filled ([ADR 0078](./adr/0078-a-uuid-is-whatever-the-database-stores.md)) |
| `db.begin(c, .{})` | `!Tx`. `.{ .isolation = …, .read_only = … }` rides on the `BEGIN`; see below |

**Set operations are conditions.** Over one table `UNION` is
`.any = .{ .{ a }, .{ b } }`, `INTERSECT` is `.{ a, b }` and `EXCEPT` is
`.{ a, not_b }` — every leaf has a negation and `.any` nests, so the boolean
algebra is closed. Over two tables it is a view, and a Row may name one
([ADR 0058](./adr/0058-a-set-operation-over-one-table-is-a-condition.md)).
There is no pipelining: a round trip is 24 µs, the query inside it is 2, and
a server here serves 215,000 requests a second with a query in every one
because a waiting fiber frees its thread
([ADR 0059](./adr/0059-a-round-trip-is-not-the-cost-worth-chasing.md)).
Statements that must land together are a data-modifying CTE through `db.raw`.

**A statement you wrote is one nilo does not cast.** `Decimal`, `Interval`,
`Inet` and any `AsText` column travel as the text the database printed, and the
`::text` (or `CAST(… AS TEXT)`) that makes that true is added to the SELECT list
*nilo* writes. A `db.raw` list is yours, so nilo adds nothing to it and the
driver hands back a `numeric` the reader cannot parse — at run time, on one
route, with no compile error anywhere near it. So `db.raw` now refuses it while
compiling: a bare column, or a `*`, in the position of an as-text field is a
Refusal naming the column, the field and the field's column type
([ADR 0154](./adr/0154-a-raw-statement-cannot-cast-what-it-did-not-write.md)).
Writing the cast yourself is the fix, and the message says so:

```zig
const rows = try db.raw(Invoice, c, "SELECT id, total::text FROM invoices", .{});
```

An aliased expression — `sum(amount)::text AS total` — is already an expression
rather than a column path, so it passes. What the check refuses is the shape
that could only ever be wrong.

**`rawOne` and `updateReturningOne` are the unwrap, not a narrower statement**
([ADR 0179](./adr/0179-a-statement-with-a-key-in-it-has-a-single-row-answer.md)).
A statement whose `WHERE` holds a primary key answers with one row or none, and
what the handler wants is `!?T` — `?Row` is already a 404 in the typed layer. So
this:

```zig
const found = try db.raw(Card, c, card_sql, .{id});
return if (found.len > 0) found[0] else null;
```

becomes `return db.rawOne(Card, c, card_sql, .{id});`.

**Unlike `db.one`, no `LIMIT 1` is added.** This module did not write the
statement and has nowhere honest to put one — a `LIMIT` after a `UNION ALL` or
inside a CTE means something else. A statement that matches many rows still
costs every one of them and this hands back the first. The same reading applies
to `updateReturningOne`: the `.where` is yours, an `UPDATE` matching several rows
updates all of them, and what changes is the shape of the answer.

Both exist on a `Tx` too.

**`db.page` is a `select` carrying the count the condition matched before the
`.limit` cut it** ([ADR 0185](./adr/0185-a-page-knows-what-it-left-out.md)):

```zig
const found = try db.page(Order, c, .{
    .where = .{ .status = "open" },
    .order = .{ .id = .asc },
    .limit = 20,
    .offset = 40,
});
// found.rows is []Order, found.total is every order that matched.
```

```sql
SELECT "id", "status", count(*) OVER () FROM "orders"
  WHERE "status" = $1 ORDER BY "id" ASC LIMIT 20 OFFSET $2
```

**A `db.count` beside a `db.select` is two statements against a table somebody
else can write between**, so the total and the rows can disagree with nothing
saying so. A window function rides on the page and cannot. It costs one integer
read per statement rather than per row, and a condition matching nothing answers
with no rows and a total of zero.

`.limit` and `.order` are both required, and `.lock` is refused. With no ceiling
this is the whole table and the total is `rows.len`; with no order Postgres owes
the `LIMIT` nothing, so two requests for the same page can hold one row twice and
miss another; and `FOR UPDATE` beside a window function is a run-time error from
Postgres. `tx.page` is the same call inside a transaction. `sql.Page(Row)` is the
answer's type, for a handler returning one.

### A batch

`insertMany` sends one array per column and lets Postgres `unnest` them, so
the statement text is a constant and the batch size is data
([ADR 0053](./adr/0053-a-batch-is-one-array-per-column.md)). One round trip
whatever the size, one allocation per column, and — because it is one
statement — a batch that violates a constraint stores none of its rows.

```zig
const Line = struct { sku: Str, qty: i32 };
const stored = try db.insertMany(Item, c, lines);   // lines: []const Line
```

The rows are a slice of a **named** struct, because the statement is compiled
from the element type. Two columns cannot be batched and both say so at
compile time: a list column, because `unnest` would flatten it, and an enum
that has not declared `nilo_column`, because the cast has to name a type that
lives in the database.

`updateMany` is the mirror, joined against the table instead of selected into
it. Each row of the batch carries the Row's **key**, which is what it is found
by and the one field the struct must have; every other field it carries is
set.

```zig
const Change = struct { id: i64, qty: i32 };
const changed = try db.updateMany(Item, c, changes);   // []const Change
```

A key the table does not have matches nothing, so a shorter answer than the
batch is how you tell which landed. Two things it does not promise, both
because a join is a join: the **order** is the planner's, and a batch naming
one key twice changes that row once. `db.update` in a loop is the answer where
either matters.

### Upserts

The last argument is the conflict target — the column the database has a
unique constraint on, written the way a key is. `.{ .tenant_id, .email }` for
one spanning two columns. Postgres refuses the statement if no such constraint
exists; a Row cannot name one, so nothing on this side can check it.

Two calls rather than one option, because the answers differ:
`DO NOTHING` stores no row and `RETURNING` then yields none, so ignoring
returns `?User` and updating returns `User`.

`insertOrUpdate` sets **every column you passed except the conflict target and
the Row's key**. The target is what the rows were matched on; the key
identifies the row that is already there, and `"id" = EXCLUDED."id"` would
renumber it. A call where that leaves nothing to set is a compile error
pointing at `insertOrIgnore`.

### Options

| | |
|---|---|
| `.where` | a condition; see below |
| `.order` | `.{ .created_at = .desc }`, one column per field. `.asc_nulls_last` and its three siblings say where NULLs go, which the two databases otherwise disagree about |
| `.limit` / `.offset` | a literal is baked into the SQL; a variable becomes a parameter. A literal limit is also the row ceiling, so the result list is allocated once |
| `.set` | update only: columns to new values, or `.{ .views = .{ .plus = 1 } }` for arithmetic on the column's own value |

### Conditions

Different fields are ANDed. Several operators on one field are ANDed too.

| | |
|---|---|
| `.id = 7` | `"id" = $1` |
| `.age = .{ .gt = 18, .lt = 65 }` | `"age" > $1 AND "age" < $2` |
| `.eq` `.ne` `.gt` `.gte` `.lt` `.lte` | |
| `.like` / `.ilike` | and `.not_like` / `.not_ilike`. **These do not escape the text you give them**; the row below is the one to reach for |
| `.contains` `.starts_with` `.ends_with` | the pattern is built *and* escaped by the statement, so `%` and `_` in a search term match themselves. `i` in front folds case (`.icontains`), `not_` in front negates — twelve in all. On SQLite the case-sensitive half is a Refusal: its `LIKE` folds ASCII case and cannot be told not to |
| `.in = &.{ 1, 2, 3 }` | `= ANY($1)` — one parameter, so the statement stays a constant |
| `.not_in = &.{ 1, 2, 3 }` | `<> ALL($1)` — one parameter likewise |
| `.deleted_at = null` | `IS NULL` |
| `.deleted_at = .{ .ne = null }` | `IS NOT NULL` |
| `.handle = .{ .not_distinct_from = maybe }` | `IS NOT DISTINCT FROM $1` — `=` with null treated as a value. **The one operator an optional may reach**; `.distinct_from` is its negation |
| `.status = sql.given(maybe)` | `($1 IS NULL OR "status" = $1)` — the term is in the statement when the filter carried a value and out of it when it did not. See below |
| `.any = .{ .{ … }, .{ … } }` | OR, bracketed. Not `.or`, which is a keyword — so `any` is a reserved column name |
| `.exists = .{ .{ .in = Other, .where = .{ … } } }` | `EXISTS (SELECT 1 FROM …)`, joined on the `.references` `Other` declares. `.not_exists` negates; both are reserved column names, and both nest inside `.any` |

A column that does not exist is a compile error naming the near miss.

**A null is written, never held.** The two lines above are `IS NULL` because
the compiler can see the null. An optional that *might* be null is a compile
error, because whether the statement says `= $1` or `IS NULL` would then
depend on a value that arrives after the statement is a constant — and
`= NULL` is never true in SQL, so the query would run and answer nothing.
Reach for `.not_distinct_from` — one statement that means what you wanted —
or branch
([ADR 0044](./adr/0044-a-condition-holds-a-value-not-a-maybe.md)). The
null-safe pair is the exception because its statement does **not** change
when the value turns out to be null: `"handle" IS NOT DISTINCT FROM $1` is
the same six words either way, so nothing is left until run time.

**And a filter that is absent is a different question from one that is null.**
`.status = null` asks for the rows whose status is nothing; a screen with a
search box and three dropdowns wants *no condition on status at all*, which is
the opposite. `sql.given` is that, and it is a word rather than an optional so
the two stay tellable apart
([ADR 0183](./adr/0183-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)):

```zig
const found = try db.page(Partner, c, .{
    .where = .{
        .name = .{ .icontains = sql.given(filter.search) },
        .exists = .{
            .{ .in = PartnerCapability, .where = .{ .capability = sql.given(filter.capability) } },
        },
    },
    .order = .{ .name = .asc },
    .limit = 20,
});
```

```sql
($1 IS NULL OR "name" ILIKE …) AND ($2 IS NULL OR EXISTS (SELECT 1 FROM …))
```

**One statement, one parameter list and one prepared plan however the screen is
set**, which is what the guard buys over a statement per combination of filters.
Postgres folds `$1 IS NULL` away while a custom plan is in use — which is the
first five executions and for as long after that as the custom plan wins — so
the term that *is* set plans as if the guard were not written. `SET
plan_cache_mode = force_custom_plan` is the lever if one query disagrees.

Inside an `.exists` it drops the **whole subquery**, not one term of it: with the
term dropped the subquery would ask whether *any* joined row exists, which
excludes every row that has none. For the same reason it cannot sit beside a
condition that is always there in one `.exists` — write a second entry.

Six things are Refusals, each with its own sentence: a `sql.given` inside
`.any` (OR reverses what dropping means), on `.in` (a list that may be absent is
the empty list, which `.in` already reads), on `not_distinct_from` (which takes
an optional already), on a value that is not optional, beside a fixed condition
in one `.exists`, and in the condition of an `UPDATE` or a `DELETE` — where a
term that may not be there is the whole table.

### A row in another table

```zig
db.select(Partner, c, .{ .where = .{
    .name = .{ .icontains = search },
    .exists = .{
        .{ .in = PartnerCapability, .where = .{ .capability = cap } },
    },
} });
```

**The join is read out of the schema, not written here.** It comes from the
`.references` the other Row declares, which is already checked while compiling —
the target has to be a Row, the target column one of its columns, and the two
Zig types the same. A Row that declares none is a compile error saying so, and
one that points at this table from **two** columns is a compile error naming
both: which of them joins is a question about what the query means.
`.on = .<column>` says which, and is also the way in for a Row over a view.

The entries are a list because a struct cannot carry the same field twice, and
narrowing on two capabilities is the ordinary case. They are ANDed.

**This is the only place the *one table* line moves**, and
[ADR 0171](./adr/0171-a-row-over-there-is-a-condition.md) says why: an `EXISTS`
changes neither the column list nor the row count, so the Row still describes
the answer and `.limit` still means what you think. A join changes both, and is
still `db.raw`.

### A key of several columns

```zig
pub const nilo_table = .{ .name = "seats", .key = .{ .tenant_id, .id } };
```

```zig
const seat = try db.find(Seat, c, .{ .tenant_id = tenant, .id = id });
```

Named fields rather than a tuple: two `i64` key columns written the other way
round would find the wrong row and report nothing. Leaving one out, adding a
column that is not part of the key, and passing a tuple are all compile errors.
`updateMany` joins on every column, and `CREATE TABLE` writes a
`PRIMARY KEY (…)` constraint rather than a clause on one column.

### Streaming

For a result set too big to hold. Rows come back as `sql.Borrowed(User)` —
`User` with every `Str` replaced by `[]const u8`, because the text points
into the buffer the rows arrive in and dies at the next `next()`.

```zig
var rows = try db.stream(User, c, .{});
defer rows.close();                       // required
while (try rows.next()) |u| try s.print("{d},{s}\n", .{ u.id, u.email });
```

### `Tx`

```zig
var tx = try db.begin(c, .{});
defer tx.deinit();          // rolls back unless committed
_ = try tx.insert(Order, c, .{ … });
try tx.commit();
```

`tx` carries every read and write call above — `select`, `one`, `find`,
`count`, `exists`, `insert`, `insertMany`, `update`, `updateMany`,
`updateReturning`, `delete`, `deleteReturning` and `raw` — all down the one
connection it holds. Forgetting the `defer` is caught in Debug by a counter
asserted at `db.deinit()`.

**The type is spelled `sql.Db.Tx`**, which only matters when a function of
yours *takes* one — `fn append(self: *Bus, tx: *sql.Db.Tx, …)`. Every example
here starts with `var tx = try db.begin(…)` and infers it, so the name never
had to be written down until something wanted to be handed a transaction
somebody else opened. It hangs off `Db` rather than off the module because a
transaction belongs to the pool it came out of; `sql.Tx` does not exist.

| | |
|---|---|
| `db.begin(c, .{ .isolation = …, .read_only = … })` | both ride on the `BEGIN` itself, so neither costs a round trip. `.isolation` is `.read_committed`, `.repeatable_read` or `.serializable`; left out means whatever the server is set to |
| `tx.deadline(ms)` | bound every statement after it, for the life of this transaction. `error.TimedOut` past it |
| `tx.savepoint()` | `!Savepoint` — a mark one part of the transaction can be undone back to; see below |

```zig
var tx = try db.begin(c, .{});
defer tx.deinit();
try tx.deadline(2_000);                   // one round trip
const rows = try tx.select(Report, c, .{ .where = … });
```

**Only a transaction has one**, and that is the design
([ADR 0047](./adr/0047-a-deadline-needs-a-connection-you-hold.md)): a deadline
is always a second command, so it has to go down the same connection as the
statement it bounds. `db.select` takes whichever connection is free and gives
it straight back, so there is nothing to set one on. Postgres undoes it when
the transaction ends, however it ends. For a floor under everything, set it on
the role: `ALTER ROLE app SET statement_timeout = '30s'`.

#### Holding the rows a read matched

A read inside a transaction can hold what it matched until that transaction
ends, which is what makes read-modify-write safe.

| | |
|---|---|
| `.lock = .update` | hold every matching row against another writer, waiting for anyone already holding it |
| `.lock = .update_nowait` | the same, except a row somebody else holds fails at once with `error.Locked` |
| `.lock = .update_skip_locked` | the same, except a row somebody else holds is left out of the answer — a work queue |
| `.lock = .share` | hold against a writer, and let other readers hold it too |

```zig
var tx = try db.begin(c, .{});
defer tx.deinit();
const held = try tx.select(Item, c, .{ .where = .{ .id = id }, .lock = .update });
_ = try tx.update(Item, c, .{ .set = .{ .qty = held[0].qty - 1 }, .where = .{ .id = id } });
try tx.commit();
```

`find` has no `.lock` — it takes a key rather than options — so a locked read
of one row is `tx.one(Row, c, .{ .where = .{ .id = id }, .lock = .update })`.

**A `.lock` outside a transaction is a compile error.** Postgres wraps a lone
statement in a transaction of its own and ends it immediately, so the lock
would be taken and dropped before the handler read a row: the statement works,
and the promise it was written for is missing
([ADR 0054](./adr/0054-contention-is-what-a-transaction-is-for.md)).

#### Savepoints

| | |
|---|---|
| `tx.savepoint()` | `!Savepoint` — put a mark down |
| `sp.deinit()` | undo everything since the mark, unless it was released. For a `defer` |
| `sp.release()` | `!void` — keep the work, and drop the mark |
| `sp.rollback()` | undo the work now; the transaction carries on |

```zig
var sp = try tx.savepoint();
defer sp.deinit();

if (tx.insert(Tag, c, .{ .name = name })) |_| {
    try sp.release();
} else |err| switch (err) {
    error.AlreadyExists => sp.rollback(),   // it was already there; carry on
    else => return err,
}
```

**This is what a nested transaction is** — Postgres has no nested `BEGIN`, and
an inner "commit" is not durable; it only means the outer transaction may
still commit it. It earns its round trip on one path and that path matters: a
statement that fails inside a transaction aborts all of it, so without a mark
there is no way to try something and carry on.

Undoing or dropping a savepoint destroys every savepoint taken after it, which
is Postgres's rule. A `defer sp.deinit()` on one of those sends nothing rather
than asking the server to release a mark it no longer has.

### Types

| | |
|---|---|
| `sql.Timestamp` | microseconds since the epoch, written as RFC 3339 in JSON. `timestamptz`. `.now()`, `.fromSeconds(s)`, `.seconds()`, `.nilo_parse(text)` |
| `sql.Uuid` | `nilo_id`'s [`Uuid`](#nilo_id), re-exported — the same type either import gives you. `uuid` |
| `sql.Json(T)` | a `T` stored as `jsonb`, parsed per row into the request arena. Not available in `db.stream`, which allocates nothing |
| `sql.Decimal` | a `numeric`, held as its digits. `.text` is the value; there is no arithmetic. Writes itself into JSON as a **string**, so a consumer's `JSON.parse` cannot round it into an `f64` ([ADR 0050](./adr/0050-a-numeric-is-digits-and-a-string-in-json.md)) |
| `sql.Interval`, `sql.Inet` | an `interval` and an `inet`, held as the text Postgres prints. `.text` is the value |
| `sql.Bytes` | bytes rather than text: `bytea` on Postgres, `BLOB` on SQLite. `.bytes` is the value, `sql.Bytes.of(hash)` writes one. The slice a read hands back lives in the request arena, the way a `Str` does. This is what to reach for instead of `sql.AsText("bytea")`, which goes through hex printing and costs a conversion each way ([ADR 0174](./adr/0174-bytes-are-a-type-not-a-second-protocol.md)) |
| `sql.AsText("money")` | any Postgres type at all, held as its text — the door out of this table. A column type of your own is any struct or enum with `nilo_column`, `nilo_read(text, arena)` and `nilo_write(arena)`; see below |
| a slice | an array column, with no wrapper: `[]const Str` is `text[]`, `[]const i32` is `int4[]`, `?[]const i32` a nullable one, `[]const ?i32` one whose elements may be NULL ([ADR 0051](./adr/0051-an-array-is-a-slice-and-a-slice-is-one-deep.md)). `[]const u8` is text, so a list of text is `[]const Str` or `[]const []const u8`. `[]const sql.Uuid` is `uuid[]`, in both directions and as an `.in` list ([ADR 0145](./adr/0145-a-raw-parameter-is-converted-the-way-a-rows-is.md)). Not available in `db.stream` |
| an enum | read out of `text`, a `varchar` or a Postgres enum. A value the Zig enum does not have fails the request. Add `pub const nilo_column = "user_role"` to it and the column is checked at startup — and can be batched |

#### A column type of your own

The list above is what this module chose to know about, and it is not closed.
A struct or an enum carrying three declarations is a column type:

```zig
const Cents = struct {
    value: i64,

    pub const nilo_column = "numeric";

    pub fn nilo_read(text: []const u8, arena: std.mem.Allocator) !Cents { … }
    pub fn nilo_write(self: Cents, arena: std.mem.Allocator) ![]const u8 { … }
};
```

It travels as the text Postgres prints — `"col"::text` on the way out,
`$1::numeric` on the way in — which is the one representation every Postgres
type has, including the ones that arrive with an extension
([ADR 0055](./adr/0055-a-column-type-can-come-from-outside-this-module.md)).
The column is judged at startup like any other, and the type works everywhere
a column type does: conditions, `.set`, `insert`, a batch.

`sql.AsText(name)` is the whole of that for a type that is just the text, and
`sql.Decimal`, `sql.Interval` and `sql.Inet` are three instances of it.

**A `Timestamp` reads back what it prints.** `Timestamp.nilo_parse(text)` is
`?Timestamp`, and it is the same declaration that makes a type a path param
([ADR 0142](./adr/0142-a-path-param-can-parse-itself.md)) and, since
[ADR 0158](./adr/0158-one-arrival-one-answer.md), a query field — so a keyset
cursor the server printed one request ago is an ordinary typed argument
([ADR 0159](./adr/0159-what-a-server-prints-it-can-read.md)):

```zig
const Page = struct { after: ?sql.Timestamp = null, limit: u32 = 50 };

fn feed(db: *Db, c: *nilo.Ctx, page: nilo.Query(Page)) ![]Event { … }
```

It takes an offset — `2026-08-16T16:30:00+07:00` is the same moment as
`2026-08-16T09:30:00Z` — and fractional seconds, truncated at microseconds
because that is the resolution the column has. It refuses a bare local time with
no zone, because that is not an instant. The round trip is the property that is
tested: what `writeRfc3339` prints, `nilo_parse` reads back to the same
microsecond.

Two mistakes stop at compile time: one of `nilo_read`/`nilo_write` without the
other, and both without a `nilo_column`. **An array of one is not read** —
`[]const Decimal` is the same boundary it always was.

An array column is judged **exactly**: an `int4[]` reads into a `[]const i32`
and not into a `[]const i64`, because the driver picks its element decoder off
the array's own type. An array with a NULL in it read into a non-optional
element, or an array more than one dimension deep, fails the request rather
than the process.

### Errors

| | |
|---|---|
| `error.AlreadyExists` | a unique violation (`23505`). **409** by default — the only one with a default |
| `error.ForeignKeyViolated` | `23503` — a row this statement names is not there, or a row it removes is still named by another. No default status: a 409 for a delete that lost a race, a 400 for an insert naming a parent that never existed |
| `error.NotNullViolated` | `23502`. 500: a Row and a table that disagree |
| `error.CheckViolated` | `23514` — a `CHECK` somebody wrote on purpose, so the endpoint that tripped it usually knows what it means |
| `error.ConstraintViolated` | the rest of class 23 — an exclusion constraint, a `RESTRICT` |
| `error.Disconnected` | the database went away, or was never there |
| `error.TimedOut` | a statement ran past `tx.deadline`. No default status — what a deadline means is the handler's to decide |
| `error.Locked` | a `.lock = .update_nowait` found a row somebody else is holding. No default status — a held row is a 409, a 503 or a retry depending on the endpoint |
| `error.QueryFailed` | anything else. The server's own words are on `Sent.problem` for a watcher and in the log; they never reach the client ([ADR 0146](./adr/0146-a-statement-that-failed-says-what-the-database-said.md)) |

Both Wires answer the same word for the same failure. SQLite's extended result
codes name the three above natively, which is what lets a handler tested against
SQLite branch on what Postgres will send it.

**`sql.problem(c)` is what the name cannot carry** — *which* unique index fired
([ADR 0184](./adr/0184-a-failure-belongs-to-the-call-that-caused-it.md)):

```zig
db.delete(Staff, c, .{ .where = .{ .id = id } }) catch |err| switch (err) {
    error.ForeignKeyViolated => return nilo.fail.conflict(
        "{s} was given something to do a moment ago and can no longer be deleted.",
        .{name},
    ),
    else => return err,
};
```

```zig
const said = sql.problem(c) orelse return err;
if (std.mem.eql(u8, said.constraint, "staff_email_key")) …
```

It answers a `sql.Problem` — `code`, `constraint`, `detail`,
`message` — for the last statement **this fiber** ran, and null when it worked.
It belongs to the call rather than to the `Db`, which is one Service shared by
every request in flight: it is bound to the fiber, every statement clears it, and
a Scope that is not the one the failure happened under gets null rather than
somebody else's row. Read it in the `catch` — it lives as long as the request
does, and the next statement replaces it.

`db.watching` is unchanged and is still the way to see *every* statement. The two
answer different questions.

### Migrations

The three marker words above are the schema half; this is what reads them. It
is `sql.migrate`, `sql.table`, `sql.ddl` and `sql.snapshot`, and a program that
never names one links none of it — 0 bytes on `zig build size-sql`, both probes
([`bench/result/sql.md` §10](../bench/result/sql.md)).

```zig
const Org = struct {
    pub const nilo_table = .{ .name = "orgs", .key = .id };

    id: i64,
    name: []const u8,
};

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .unique = .{.{ .columns = .{.email}, .ignoring_case = true }},
        .index = .{ .created_at, .{ .org_id, .created_at } },
        .references = .{ .org_id = .{ Org, .id, .cascade } },
        .was = .{ .email = "handle" },
    };

    id: i64,
    org_id: i64,
    email: []const u8,
    nickname: ?[]const u8,
    created_at: sql.Timestamp,
};
```

| in the marker | what it says |
|---|---|
| `.unique = .{ .email }` | one column. `.{ .{ .tenant_id, .name } }` is one constraint over two |
| `.{ .columns = .{.email}, .ignoring_case = true }` | the named form. `.ignoring_case` is `lower(...)` on Postgres and `COLLATE NOCASE` on SQLite, and it is a Refusal on a column that is not text |
| `.index = .{ .created_at }` | the same three shapes, without the uniqueness |
| `.references = .{ .org_id = .{ Org, .id } }` | keyed by the column doing the pointing, and it names the **Row** rather than a table, so renaming the table moves the key with it. A third entry says what happens on delete: `.cascade`, `.restrict` or `.set_null` |
| `.was = .{ .email = "handle" }` | this column used to be called that. The old name is text, because it is not a column any more |
| `.managed = false` | somebody else builds this table. `plan`, `createMissing` and `generate` skip it entirely |

**`.managed = false` is for the table this program reads and does not own.** A
foreign key names the *Row* that owns the table it points at, so
`comments.author_staff_id` cannot say it points at `staff` without a `Staff`
Row — and a `Staff` Row is part of the schema the diff sees, so the tool emits
`CREATE TABLE staff` for a table that has existed for a year and whose real
definition has twenty columns this program never needed. One word settles it:

<!-- compiles -->
```zig
const Staff = struct {
    pub const nilo_table = .{ .name = "staff", .managed = false };

    id: i64,
    email: Str,
};
```

Everything else about the Row is unchanged — `.references` may point at it,
`db.checking` still holds it against the live schema, and every statement reads
it the same way. What changes is only who *builds* it
([ADR 0162](./adr/0162-a-table-this-program-reads-and-does-not-build.md)). The
word is written into `migrations/snapshot.zon`, where `managed: true` is silence
and `managed: false` is a line, so a program that starts or stops building a
table is a visible change in a reviewed file.

Names follow Postgres' own convention, so a schema nilo generates and one
somebody wrote by hand look the same: `users_email_key`,
`users_org_id_created_at_idx`, `users_org_id_fkey`.

**A key that is an integer is generated and one that is not is supplied.** That
is a rule rather than a word in the marker: `id: i64` becomes
`GENERATED BY DEFAULT AS IDENTITY` on Postgres and
`INTEGER PRIMARY KEY AUTOINCREMENT` on SQLite, and `id: sql.Uuid` becomes a
`NOT NULL PRIMARY KEY` the insert has to fill.

#### Creating tables

```zig
try sql.migrate.createMissing(&db, &run, &.{ User, Org });
```

One `CREATE TABLE IF NOT EXISTS` per Row plus its indexes, in one transaction.
**The order is worked out while compiling**, not from the list: foreign keys are
written inline, which is the only shape SQLite has, so `orgs` is created before
`users` whichever way round they are written. Two tables pointing at each other
is a compile error naming both.

This is for a test, a fixture or a single-file SQLite application. It is not a
migration: it creates what is missing and never alters what is there.

| | |
|---|---|
| `migrate.createMissing(db, scope, Rows)` | the above |
| `migrate.tablesOf(D, Rows)` | comptime: every table as the types describe it, in create order |
| `migrate.missingOf(D, Rows)` | comptime: just the statements |
| `ddl.createTable(D, Row)` | comptime: one `CREATE TABLE`, as text |

#### The diff

```zig
const change = try sql.migrate.plan(arena, Db.Dialect, desired, before);
```

`desired` is `migrate.tablesOf(D, Rows)` — the types. `before` is a
`snapshot.Doc`, which is `migrations/snapshot.zon` read back. **Both halves are
files, so a diff needs no database**, and two branches that both generate
conflict in git rather than at deploy.

`Plan.steps` is what to run, in order, each with its `kind`, its `sql` and a
line of `why`. `Plan.problems` is what the diff will not write, and **every one
of them is collected rather than the first being returned**. Two are refused on
purpose: a type or nullability change on SQLite, which has no
`ALTER COLUMN`; and any foreign-key change on a table that already exists, on
both dialects, because the one-statement form takes an `ACCESS EXCLUSIVE` lock
and scans the table. The `Problem` spells out the `ADD CONSTRAINT … NOT VALID`
then `VALIDATE CONSTRAINT` pair to write instead.

`Plan.destructive()` and `Plan.needsBackfill()` are the two questions a command
asks before writing a file out.

#### The ledger, and applying

```zig
const chain = try sql.migrate.chainOf(arena, manifest.versions);

try sql.migrate.ensureLedger(&db, &run);
const ran = try sql.migrate.applyPending(&db, &run, chain);
```

A `Version` is a number, a name and its steps, and **it holds no hash** — a hash
a caller can fill in is a hash a caller can fill in wrong, and a wrong one turns
the drift check into decoration. `chainOf` is the only thing that computes one:
it walks the list once and hands back a `Chain`, which is the versions plus a
hash each, with `.head()`, `.headHash()` and `.len()`.

The hash is **chained**: each one is taken over the version before it, so editing
version 3 moves the hash of 3 and of everything after it, and `migrate.drift`
finds the edit by looking at the head rather than by walking the lot. It is over
the SQL rather than over the file bytes, so reformatting a generated file does
not read as tampering and changing a statement does.

`nilo_migrations` is an ordinary Row — `migrate.Applied` — with the version, the
name, that hash, when it was applied and how many milliseconds it took. `apply`
is one transaction: take the advisory lock, check whether this version is
already there, run every step, insert the row, commit. It answers `false` when
the version had already been applied, which is what nine of ten replicas booting
together get.

`migrate.applyPending(&db, &run, chain)` is the whole list, in order, one
transaction each, answering how many ran. That is the in-process runner a
single-file SQLite application calls between `app.start(io)` and `listen()`.
`migrate.drift(&db, &run, chain)` answers which applied versions have been
edited since — a `Drift` per version with what the ledger recorded and what the
steps hash to now.

**The lock is not decoration.** `pg_advisory_xact_lock` is taken inside the
transaction and released by the commit, so ten replicas starting at once run the
migration once. SQLite has no advisory lock and needs none: one writer is the
database.

A version is a **list of steps**, and `Kind.data` is the one the diff never
produces. That is what makes expand and contract expressible — the backfill goes
between the `add_column` that made the column and the `change_null` that
tightens it, in one transaction, in one version.

#### Refusing to serve a database that is behind

```zig
try sql.migrate.expect(&db, &run, manifest.head);
```

One query, before `listen()`. **This is the check almost nothing has**, and it
catches one incident shape: the code went out before the migration did, and
every request that touches the new column answers 500 until somebody notices.

A database *ahead* of the binary is allowed and only logged. That is the
ordinary middle of a two-stage deploy, and refusing it would make expand and
contract impossible.

`migrate.standing(db, scope, want)` is the same query as a value — `.at`,
`.want` and a `.verdict()` of `.level`, `.ahead` or `.behind` — for a program
that would rather decide than be refused.

#### The files

```zig
const state = try sql.migrations.read(gpa, io, dir, Db.Dialect);
const out = try sql.migrations.generate(gpa, io, dir, Db.Dialect, desired, .{
    .name = "add_nickname",
});
```

`read` opens a `migrations/` directory and hands back the snapshot it holds and
every version file in it, sorted. `generate` runs the diff and writes three
files: `NNNN_name.zig`, then `manifest.zig`, then `snapshot.zon`. **In that
order, and it matters** — a run that dies halfway leaves a snapshot that is
still behind, and the next run generates the same version again rather than
skipping it.

`check` is `generate` with nothing written: the same `Plan`, so CI and the
person at the keyboard are looking at one answer.

An `Outcome` says which of three things happened. `isEmpty()` means the Rows and
the migrations already agree. `wasHeld()` means the version was not written
because something in it loses data and `allow_destructive` was not set. Anything
else wrote the file named in `.file`.

| | |
|---|---|
| `migrations.read(gpa, io, dir, D)` | the snapshot and the version list on disk |
| `migrations.check(gpa, io, dir, D, desired)` | the `Plan`, written nowhere |
| `migrations.generate(gpa, io, dir, D, desired, opts)` | the `Plan`, written out |
| `migrations.renderVersion(gpa, n, name, steps, opts)` | one version file, as text |
| `migrations.renderManifest(gpa, entries, opts)` | the manifest, as text |
| `migrations.checkName(name)` | `a-z`, `0-9` and `_`, or `error.BadName` |

A version file is **one `.zig` file holding a list of steps**, because a
prepared statement is one statement and nilo prepares everything it sends
(ADR 0057). Splitting a `.sql` file into statements means a lexer that knows
about `;` inside a string literal and inside `$$…$$`, and getting it subtly
wrong runs three quarters of a migration. The list is already split.
[ADR 0153](adr/0153-a-migration-is-a-diff-against-a-snapshot.md) is the
argument, including what the layout costs.

#### The commands

```zig
const Tool = sql.cli.Tool(Db, &.{ User, Org });
return Tool.run(gpa, io, out, try sql.cli.parse(argv[1..]), &db, manifest.versions);
```

A project's migration tool is a `main` of ten lines. `sql.cli` owns argument
parsing, dispatch and **every sentence a person reads**; the caller owns the
allocator, the connection string and the `Db` type, because nobody else knows
them. `run` takes a `Db` that is already started and hands back an exit code
rather than calling `std.process.exit`.

| Command | What it does |
|---|---|
| `generate --name <snake_case> [--drop]` | diff the Rows against the snapshot and write the next version. No database |
| `check` | the same diff, written nowhere. Exit 1 when they disagree. No database |
| `status [--sql]` | which versions this database has. `--sql` prints the waiting statements |
| `migrate` | apply what is waiting, one transaction per version, behind the lock |
| `verify` | has an applied version been edited since it ran? |

Every command takes `--dir <path>`, which defaults to `migrations`. There is no
`down`; `generate` is forward-only by design, and the usage text says so where
somebody will ask.

**The exit code is the API for CI.** `0` did what was asked. `1` the caller has
something to do — a diff `check` found, a version `generate` held back, drift
against the ledger, versions waiting. `2` the command line was wrong. A CI job
branches on those without reading a word.

`--drop` is what stands between a renamed field and a dropped column.
`generate` writes nothing at all when a step loses data and the flag is absent:
it prints the steps, says which one it is refusing, and exits 1. Run it again
with `--drop` and the generated file records that you did, as
`.destructive = true` on the step.

`status` marks a version `edited` rather than `applied` when its file no longer
hashes to what ran. It is the command people type first, so it is the one that
has to stop saying everything is fine.

#### Starting a migrations directory

`generate` writes `manifest.zig`, and the tool imports it — so the first build
needs one before the first `generate` can run. Write it once:

```zig
const std = @import("std");
const migrate = @import("nilo_sql").migrate;

pub const head: i64 = 0;
pub const versions: []const migrate.Version = &.{};

pub fn chain(gpa: std.mem.Allocator) !migrate.Chain {
    return migrate.chainOf(gpa, versions);
}
```

From then on it is the tool's file, rewritten by every `generate` and never
edited by hand.

