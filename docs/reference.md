# Reference

The whole surface, as a list. For what any of it is *for*, see
[the guide](./guide/).

## The modules

Eight ship, and a project links only what it imports
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
| `nilo_fetch` | calling somebody else's HTTP API | [below](#nilo_fetch) |
| `nilo_core` | `Str`, the [Scope](#scope) and [percent coding](#nilo_corepercent), shared by the rest | [below](#run) |

```zig
const nilo = @import("nilo_http");    // the alias everybody writes
const sql = @import("nilo_sql");      // only if you talk to Postgres or SQLite
const s3 = @import("nilo_s3");        // only if you store objects
const id = @import("nilo_id");        // only if you make identifiers
const config = @import("nilo_config");// only if you read settings
const pw = @import("nilo_pw");        // only if you hash passwords
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
| `app.provide(&thing)` | register a service, looked up later by its pointer type |
| `app.spawn(f, args)` | work that is not a request, started once the server is up ([ADR 0086](./adr/0086-work-that-is-not-a-request-belongs-to-the-server.md)) |
| `app.use(mw)` | middleware, everywhere |
| `app.useOn(prefix, mw)` | middleware, under a path prefix |
| `app.without(mw)` | the same App with `mw` off for the routes registered through what comes back — how a sign-up route sits inside a guarded prefix ([ADR 0080](./adr/0080-a-route-can-say-it-is-not-covered.md)) |
| `app.group(prefix)` | a group — see below |
| `app.get / post / put / delete / patch / head / options (pattern, handler)` | a route |
| `app.route(method, pattern, handler)` | any other method |
| `app.static(url_prefix, dir_path)` | a directory, read into memory at startup |
| `app.staticWith(url_prefix, dir_path, options)` | the same, with [options](#static-options) |
| `app.docs(options)` | serve an [OpenAPI document](./guide/openapi.md) |
| `app.listen(options)` | run until stopped. Stops the process on a startup error |
| `app.start(io)` | everything `listen()` does before it accepts anything — services checked, chains resolved, pools opened, schemas checked. For a migration, a script or a test; `listen()` does not repeat it ([ADR 0079](./adr/0079-there-is-a-phase-before-the-server.md)). What it does *not* start is `spawn`, which needs a server |
| `app.shutdown()` | stop, from any thread or from inside a handler |
| `app.tryListen / tryRoute / tryStatic / tryStaticWith` | the same calls, error returned rather than reported |
| `app.checkServices()` | `error.MissingService` if a route needs one nobody provided |

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

### `listen` options

| | Default |
|---|---|
| `address` | `"127.0.0.1"` — an address, not a host name |
| `port` | `8787` |
| `threads` | `0` (one per core) |
| `read_buffer` | `8 * 1024` — also the ceiling on a request head |
| `write_buffer` | `4 * 1024` |
| `arena_keep` | `16 * 1024` — of a connection's request arena, kept between requests |
| `reuse_address` | `true` |
| `stop_on_signal` | `true` — Ctrl-C and SIGTERM |
| `shutdown_grace_ms` | `10_000` |
| `header_timeout_ms` | `10_000` — the whole head, from its first byte |
| `idle_timeout_ms` | `75_000` — a connection between requests |
| `body_timeout_ms` | `30_000` — any one read of a body |
| `write_timeout_ms` | `30_000` — any one write to the client |
| `max_connections` | `10_000` — held at once, 4,669 bytes each when idle. `0` = no limit |
| `max_body` | `1024 * 1024` — the most `c.body()` reads into the arena |
| `trusted_hops` | `0` — how many proxies stand in front, for `c.clientIp()` |
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

## Handler arguments

| Argument | Passed in |
|---|---|
| `*Ctx` | the request itself |
| `*Db`, `*const Config` | a service, by type |
| `u32`, `f64`, `Str`, `bool`, an enum | a path param, positionally |
| `Query(T)` | the query string as a struct |
| `Form(T)` | the body as an HTML form — urlencoded or multipart |
| `Bound(W)` | any of the three above, with its failures instead of a 400 |
| `Session(T)` | the session, out of its cookie |
| `std.mem.Allocator` | the request arena |
| a type with `nilo_resolve` | a resolved value |
| any other struct | the body, parsed from JSON |

A body field may be `Patch(T)`, which tells "not sent" from "sent as null":
`.absent`, `.cleared`, `.value`. Give it `= .absent` as its default;
`.orNull()` collapses the two empty cases.

`Form(T)` and a plain struct are the same slot — a form *is* the body — so
asking for both is a compile error. A `Form(T)` field is a `Str`, a number, a
`bool`, an enum or an `Upload`, optionally in a `?`; a default is what "not
sent" means. See [Forms](./guide/forms.md).

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

```zig
Status(201, User){ .headers = .of(&.{…}), .value = user }
Status(204, void){}                                        // an empty response
Response(User){ .status = if (made) 201 else 200, .value = user }
Redirect(303).to("/welcome")                               // written `return .to(…)`
Redirect(303).with("/welcome", .of(&.{…}))                 // …with headers of its own
FileBody{ .dir = files.dir, .name = name }                 // `?FileBody` — null is a 404
```

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
| `.rename_all` | how a variant's name or an enum's tag is spelled on the wire. Not field names |

`.rename_all` takes `.lowercase`, `.UPPERCASE`, `.camelCase`, `.PascalCase`,
`.SCREAMING_SNAKE_CASE` and `.@"kebab-case"`. The first two join the words
(`not_found` → `notfound`); `.SCREAMING_SNAKE_CASE` keeps the underscore. There
is no `.snake_case` — that is what a Zig field name already is, and asking for
it is a compile error rather than a no-op.

`nilo.jsonParseFor(@This())` is the reader, and it is a second line because
`std.json` picks the parser for a type and nothing can add a declaration to a
type you wrote. Only needed if the type arrives in a request; sending needs
nothing. Adding it to a type with no `nilo_json` is a compile error.

Without a marker a `union(enum)` is externally tagged — `{"metrics":{…}}`, what
`std.json` writes — and it is written by nilo's own writer either way. An
*untagged* union has nothing saying which arm is live and is left to `std.json`
whole. A variant carrying no payload is legal under `.tag` and is the
discriminator on its own; under the default encoding it is not covered.

The generated API description follows whichever encoding the type asked for:
`oneOf` of one-key objects for the default, and `oneOf` with `discriminator`
plus a per-arm `allOf` for a tagged one. See
[Responses](./guide/responses.md#json-shapes-of-your-own).

## `Ctx`

### Reading

| | |
|---|---|
| `c.method` | `.GET`, `.POST`, … |
| `c.path()` | `Str` — the path, without the query string |
| `c.param(name)` | `?Str`, percent-decoded. `"*"` for a catch-all |
| `c.query(name)` | `?Str`, percent-decoded, `+` as space |
| `c.header(name)` | `?Str`, name matched case-insensitively |
| `c.cookie(name)` | `?Str` — as the client sent it, nothing decoded. Allocates nothing |
| `c.body()` | `!Str` — the whole body, up to `max_body` (1 MB) |
| `c.json(T)` | `!T` — the body parsed as JSON |
| `c.form(T)` | `!T` — the body parsed as a form, urlencoded or multipart |
| `c.jsonCollecting(T, &outcomes)` | `!T` — as `json`, recording why each field failed |
| `c.formCollecting(T, &outcomes)` | `!T` — as `form`, recording why each field failed |
| `c.requestId()` | `Str` — this request's id, from `X-Request-Id` or generated |
| `c.entropy(n)` | `![n]u8` — unguessable bytes from the OS, off the event loop. `n` is comptime |
| `c.hashPassword(gpa, text)` | `!pw.Hash` — argon2id, salted, off the loop and behind the Gate |
| `c.hashPasswordWith(cost, gpa, text)` | the same, at a `pw.Cost` of your own |
| `c.verifyPassword(gpa, stored, text)` | `!bool` — `stored` is `?[]const u8`; null means no such account |
| `c.verifyPasswordWith(cost, gpa, stored, text)` | the same, told what a hash of yours costs |
| `c.bodyStream()` | `!Body` — the body in pieces |
| `c.bodyStreamWith(.{ .max_bytes = … })` | the same, with a ceiling. Default 64 MB |
| `c.peer()` | the address the connection came from — the proxy's, if there is one |
| `c.clientIp()` | `Str` — the client, looking through `trusted_hops` proxies |
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

## `Str`

| | |
|---|---|
| `s.view()` | the bytes |
| `s.eql(other)` | compare against a `[]const u8` |
| `s.int(T)` | parse as base-10 |
| `s.len()` | |
| `s.keep(gpa)` | a copy that outlives the request; the caller frees it |
| `Str.static(bytes)` | text that already outlives any request — what a test uses |

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
| `run.deinit()` | |
| `run.arena()` | `std.mem.Allocator` — memory that lasts as long as this tick |
| `run.str(bytes)` | `Str` — text you allocated from `run.arena()`, stamped with this tick |
| `run.reset()` | end the tick: the memory goes back, the pages stay, and every `Str` from it goes stale |

## Scope

Not a type — the two calls above, `arena()` and `str()`. A `Ctx` has them and a
`Run` has them, and anything asking for a Scope takes either
([ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md)). It is checked
while compiling, so passing something else is a Refusal naming the call rather
than an error from inside the module.

`nilo_core` is the module both live in. A project importing `nilo` never has to
name it — `nilo.Str` and `nilo.Run` are the same declarations — but a program
with no server in it can depend on `nilo_core` alone.

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

`c` is a Scope, the same as everywhere else.

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

// `nowMillis` answers an `i64` — a clock reads backwards as well as forwards —
// and a v7 takes the six bytes of a `u64`.
const key = id.v7(try c.entropy(id.Uuid.v7_entropy), @intCast(nilo.nowMillis()));
_ = try db.insert(Doc, c, .{ .id = key, .title = nilo.Str.static("notes") });
```

where `Doc.id` is a `sql.Uuid`, which is this same type.

| | |
|---|---|
| `id.v4(entropy)` | random — 122 bits of the `[16]u8` you pass in |
| `id.v7(entropy, ms)` | sortable — `ms` in the first six bytes, then the `[10]u8` |
| `u.toText()` | `[36]u8` by value: `550e8400-e29b-41d4-a716-446655440000` |
| `u.writeText(w)` | the same, into a `*std.Io.Writer` |
| `id.Uuid.parse(text)` | `!Uuid`, `error.InvalidUuid`. Hyphens optional |
| `u.version()` | `u4` — `4`, `7`, or whatever the bytes claim |
| `u.millis()` | `?u64` — the millisecond a v7 carries, null for anything else |
| `u.eql(other)`, `u.isNil()`, `id.Uuid.nil` | |
| `id.Uuid.byte_len`, `.text_len`, `.v4_entropy`, `.v7_entropy` | 16, 36, 16, 10 |

A `Uuid` in a returned struct leaves as its text rather than as sixteen
numbers, and one in a Row is written and read as the `uuid` column.

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

## `Dir`

A directory, opened once and held open — what a service hands a `FileBody`.

| | |
|---|---|
| `Dir.open(path)` | `!Dir` — relative to the working directory the server runs in. Startup work |
| `d.close()` | |
| `d.openFile(name)` | `!File` — a name inside it, resolved by the kernel against the descriptor |

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
| `nilo.Mutex` | `.init`, then `try lock()`, `unlock()`, `tryLock()` |
| `nilo.blocking(f, args)` | run a blocking call off the event loop |
| `nilo.Gate` | `.open(n)`, then `try enter()`, `leave()` — a lock that lets `n` through |
| `nilo.sleep(ms)` | wait without parking the thread |
| `nilo.spawn(f, args)` | run something that is not a request, now — `error.NoServer` if nothing is listening |
| `app.spawn(f, args)` | the same fiber, registered before the server and started once it is up ([the guide](./guide/background.md)) |
| `nilo.randomSecure(&buf)` | fill a buffer you already hold, off the event loop |
| `nilo.monotonicNanos()` | a clock reading, for durations |

`lock()` and `sleep()` fail with `error.Canceled` if the request went away, which
maps to a 503.

## What time it is

| | |
|---|---|
| `nilo.nowMicros()` | `i64` — microseconds since the epoch. What `sql.Timestamp` counts |
| `nilo.nowMillis()` | `i64` — milliseconds. What a UUID v7 puts in its first six bytes |

Plain functions rather than calls on a `Ctx` or a `Run`: reading the wall clock
needs no event loop and nobody owns the time, so there is nothing for a Scope to
be the holder of
([ADR 0045](./adr/0045-core-knows-what-time-it-is.md)). They are `nilo_core`'s,
so a program with no server in it has them too. 15ns a call.

**Use `monotonicNanos` for a duration, never these.** A wall clock moves when an
operator moves it, so two readings a second apart can come back in either order.

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
threshold and `0` turns it off. A stream, a body reader and a WebSocket are not
watched at all: holding the connection is what they are for. See
[ADR 0034](./adr/0034-the-thing-a-handler-holds-is-watched-at-run-time.md).

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

nilo.cors.permissive                                    // origin "*", no credentials
nilo.cors.with(.{ .origin = …, .methods = …, .headers = …,
                   .expose = …, .credentials = false, .max_age = 0 })
```

## Static options

`app.staticWith(prefix, dir, …)`:

| | Default |
|---|---|
| `index` | `"index.html"` |
| `cache_control` | `"public, max-age=3600"` |
| `spa_fallback` | `""` (off) |
| `max_file_bytes` | `8 * 1024 * 1024` |
| `max_total_bytes` | `64 * 1024 * 1024` |
| `dotfiles` | `false` |

`max_file_bytes` is a threshold, not a ceiling: a file over it is listed but not
read, and each request opens it and sends it from the disk — no gzipped copy, an
ETag made of the modification time and the size, and one file descriptor for as
long as the response takes. `max_total_bytes` counts held bytes only. See
[Static files](./guide/static-files.md#files-too-big-to-hold).

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

## Testing

| | |
|---|---|
| `testing.Client.init(gpa, .{ .response_bytes = 64 * 1024 })` | |
| `client.get(&app, path)` / `post(&app, path, body)` | |
| `client.postWith(&app, path, content_type, body)` | a POST that says what its body is — what a form needs |
| `client.request(&app, method, path, body)` | |
| `client.send(&app, raw_request)` | the whole request, written out |
| `answer.status` / `.head` / `.body` / `.raw` / `.chunked` / `.keep_alive` | |
| `answer.interim` | `?[]const u8` — the `100 Continue` that came first, or null. `.status` is the final one either way |
| `answer.header(name)` | case-insensitive, the first of that name |
| `answer.headerAt(name, n)` / `.headerCount(name)` | for the ones a response repeats |
| `answer.setCookie(name)` | the whole `Set-Cookie` line that sets it |
| `answer.text(&buf)` | the body with chunk framing undone |

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
| `pub const nilo_table = Other` | a narrower Row: the same table as `Other`, fewer columns, checked against it while compiling |

### `Db`

```zig
var db = sql.Db.init(gpa, "postgres://…", .{});
defer db.deinit();
db.checking(&.{ User, Order });   // optional
try app.provide(&db);
```

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
| `timeout_ms` | how long a caller waits for a free connection. Default 10,000 |
| `schema_mismatch_is_fatal` | whether a Row that disagrees with its table stops startup. Default true |
| `prepared` | whether a statement is kept prepared on the connection it went down. Default true |

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
`db.raw` is never prepared, because its text arrives at run time. Set
`.prepared = false` behind a **connection pooler in transaction mode**
(pgbouncer), which hands out a different server connection per transaction.

A Row may name a **view** or a **materialized view** as well as a table. The
column types are checked there; nullability is not, because Postgres does not
track `NOT NULL` through a view
([ADR 0056](./adr/0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md)).
An identity key, a sequence default and a generated column need nothing said
about them — an insert names a subset of the Row's columns and `RETURNING`
brings the rest back. Indexes and constraints are refused on the record: a Row
cannot say one, and one that could would be a migration file.

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
| `db.count(User, c, .{ .where = … })` | `!usize`. `.where` only, and optional — no condition counts the table |
| `db.exists(User, c, .{ .where = … })` | `!bool` — `SELECT EXISTS(…)`, so it stops at the first match |
| `db.insert(User, c, .{ .email = … })` | `!User` — the stored row, generated key included. A subset of the columns |
| `db.insertMany(User, c, rows)` | `![]User` — a whole batch in one statement, back in the order it was sent. `rows` is a `[]const Line`, `Line` a named struct of the columns being written; see below |
| `db.insertOrIgnore(User, c, .{ … }, .email)` | `!?User` — the stored row, or `null` when one was already there. `ON CONFLICT … DO NOTHING` |
| `db.insertOrUpdate(User, c, .{ … }, .email)` | `!User` — stored, or the existing row with these values written over it. `ON CONFLICT … DO UPDATE` |
| `db.update(User, c, .{ .set = …, .where = … })` | `!usize` — rows changed. Both halves required |
| `db.updateMany(User, c, rows)` | `![]User` — a whole batch in one statement, found by the Row's key. No `.where`: the join is the condition; see below |
| `db.updateReturning(User, c, .{ .set = …, .where = … })` | `![]User` — the rows as they now are. One statement where an update and a select are two and a race |
| `db.delete(User, c, .{ .where = … })` | `!usize` — rows deleted. `.where` required |
| `db.deleteReturning(User, c, .{ .where = … })` | `![]User` — the rows that were removed |
| `db.stream(User, c, .{ … })` | rows one at a time; see below |
| `db.raw(User, c, sql, .{ … })` | `![]User` — a statement this module will not write |
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
| `.order` | `.{ .created_at = .desc }`, one column per field |
| `.limit` / `.offset` | a literal is baked into the SQL; a variable becomes a parameter. A literal limit is also the row ceiling, so the result list is allocated once |
| `.set` | update only: columns to new values |

### Conditions

Different fields are ANDed. Several operators on one field are ANDed too.

| | |
|---|---|
| `.id = 7` | `"id" = $1` |
| `.age = .{ .gt = 18, .lt = 65 }` | `"age" > $1 AND "age" < $2` |
| `.eq` `.ne` `.gt` `.gte` `.lt` `.lte` | |
| `.like` / `.ilike` | and `.not_like` / `.not_ilike` |
| `.in = &.{ 1, 2, 3 }` | `= ANY($1)` — one parameter, so the statement stays a constant |
| `.not_in = &.{ 1, 2, 3 }` | `<> ALL($1)` — one parameter likewise |
| `.deleted_at = null` | `IS NULL` |
| `.deleted_at = .{ .ne = null }` | `IS NOT NULL` |
| `.handle = .{ .not_distinct_from = maybe }` | `IS NOT DISTINCT FROM $1` — `=` with null treated as a value. **The one operator an optional may reach**; `.distinct_from` is its negation |
| `.any = .{ .{ … }, .{ … } }` | OR, bracketed. Not `.or`, which is a keyword — so `any` is a reserved column name |

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
| `sql.Timestamp` | microseconds since the epoch, written as RFC 3339 in JSON. `timestamptz`. `.now()`, `.fromSeconds(s)`, `.seconds()` |
| `sql.Uuid` | `nilo_id`'s [`Uuid`](#nilo_id), re-exported — the same type either import gives you. `uuid` |
| `sql.Json(T)` | a `T` stored as `jsonb`, parsed per row into the request arena. Not available in `db.stream`, which allocates nothing |
| `sql.Decimal` | a `numeric`, held as its digits. `.text` is the value; there is no arithmetic. Writes itself into JSON as a **string**, so a consumer's `JSON.parse` cannot round it into an `f64` ([ADR 0050](./adr/0050-a-numeric-is-digits-and-a-string-in-json.md)) |
| `sql.Interval`, `sql.Inet` | an `interval` and an `inet`, held as the text Postgres prints. `.text` is the value |
| `sql.AsText("money")` | any Postgres type at all, held as its text — the door out of this table. A column type of your own is any struct or enum with `nilo_column`, `nilo_read(text, arena)` and `nilo_write(arena)`; see below |
| a slice | an array column, with no wrapper: `[]const Str` is `text[]`, `[]const i32` is `int4[]`, `?[]const i32` a nullable one, `[]const ?i32` one whose elements may be NULL ([ADR 0051](./adr/0051-an-array-is-a-slice-and-a-slice-is-one-deep.md)). `[]const u8` is text, so a list of text is `[]const Str` or `[]const []const u8`. Not available in `db.stream` |
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
| `error.AlreadyExists` | a unique violation. **409** by default — the only one with a default |
| `error.ConstraintViolated` | foreign key, check or not-null. 500: usually the code is wrong |
| `error.Disconnected` | the database went away, or was never there |
| `error.TimedOut` | a statement ran past `tx.deadline`. No default status — what a deadline means is the handler's to decide |
| `error.Locked` | a `.lock = .update_nowait` found a row somebody else is holding. No default status — a held row is a 409, a 503 or a retry depending on the endpoint |
| `error.QueryFailed` | anything else. The server's text is logged, never sent |
