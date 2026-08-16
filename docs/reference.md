# Reference

The whole surface, as a list. For what any of it is *for*, see
[the guide](./guide/).

## The modules

Six ship, and a project links only what it imports
([ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md),
[ADR 0042](./adr/0042-the-bottom-layer-holds-more-than-one-module.md)).

| | | |
|---|---|---|
| `nilo_http` | the server — everything on this page unless it says otherwise | [below](#app) |
| `nilo_sql` | Postgres | [below](#nilo_sql) |
| `nilo_id` | UUIDs | [below](#nilo_id) |
| `nilo_config` | settings out of the environment | [below](#nilo_config) |
| `nilo_pw` | password hashing | [below](#nilo_pw) |
| `nilo_core` | `Str` and the [Scope](#scope), shared by the rest | [below](#run) |

```zig
const nilo = @import("nilo_http");    // the alias everybody writes
const sql = @import("nilo_sql");      // only if you talk to Postgres
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
| `app.use(mw)` | middleware, everywhere |
| `app.useOn(prefix, mw)` | middleware, under a path prefix |
| `app.group(prefix)` | a group — see below |
| `app.get / post / put / delete / patch / head / options (pattern, handler)` | a route |
| `app.route(method, pattern, handler)` | any other method |
| `app.static(url_prefix, dir_path)` | a directory, read into memory at startup |
| `app.staticWith(url_prefix, dir_path, options)` | the same, with [options](#static-options) |
| `app.docs(options)` | serve an [OpenAPI document](./guide/openapi.md) |
| `app.listen(options)` | run until stopped. Stops the process on a startup error |
| `app.shutdown()` | stop, from any thread or from inside a handler |
| `app.tryListen / tryRoute / tryStatic / tryStaticWith` | the same calls, error returned rather than reported |
| `app.checkServices()` | `error.MissingService` if a route needs one nobody provided |

`pattern` and `handler` are `comptime`. Registration order never matters.

### `Group`

`app.group("/api")` returns one. It has `group`, `use`, `useOn`, `provide`,
`get`, `post`, `put`, `delete`, `patch`, `head`, `options`, `route`, `tryRoute`,
`static`, `staticWith`, `tryStatic`, `tryStaticWith` — the same as an App, minus
`listen`, `docs` and `shutdown`. The prefix is compile-time text and must be
literal; the type is `nilo.Group("/api")`.

### `listen` options

| | Default |
|---|---|
| `address` | `"127.0.0.1"` — an address, not a host name |
| `port` | `8787` |
| `threads` | `0` (one per core) |
| `read_buffer` | `8 * 1024` — also the ceiling on a request head |
| `write_buffer` | `4 * 1024` |
| `reuse_address` | `true` |
| `stop_on_signal` | `true` — Ctrl-C and SIGTERM |
| `shutdown_grace_ms` | `10_000` |
| `header_timeout_ms` | `10_000` — the whole head, from its first byte |
| `idle_timeout_ms` | `75_000` — a connection between requests |
| `body_timeout_ms` | `30_000` — any one read of a body |
| `write_timeout_ms` | `30_000` — any one write to the client |
| `max_connections` | `10_000` — held at once, about 9 KB each. `0` = no limit |
| `max_body` | `1024 * 1024` — the most `c.body()` reads into the arena |
| `trusted_hops` | `0` — how many proxies stand in front, for `c.clientIp()` |
| `session_secret` | `null` — 32 bytes, for `Session(T)`. The same on every instance |
| `block_warning_ms` | `250` — say so when a handler holds its thread. `0` = off |

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

A `Failure` carries `field`, `reason`, `given`, `kind`, `expected`, and
`say(w)` — nilo's own sentence for it. `reason` is one of `.missing`,
`.not_a_number`, `.not_true_or_false`, `.not_a_choice`, `.wrong_kind`; that is
the whole list, and it is not a validator. Nothing is allocated per failed
field. See [Forms](./guide/forms.md#when-one-field-is-wrong-and-the-rest-are-fine)
and [ADR 0036](./adr/0036-a-binding-hands-its-failures-to-the-handler.md).

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
| `c.upgrade()` | `!Socket` |
| `c.upgradeWith(.{ .protocol = "chat.v1" })` | the same, naming a subprotocol |

`Content-Type`, `Content-Length`, `Transfer-Encoding` and `Connection` are
refused by `setHeader`. Set headers before sending. Setting the same header
twice replaces it — except `Set-Cookie`, which a response may carry more than
one of.

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

Every way a cookie can be unreadable — tampered, truncated, sealed under
another secret, written by a build with a different shape of `T` — is the
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

## `nilo_id`

UUIDs, as a module of their own
([ADR 0042](./adr/0042-the-bottom-layer-holds-more-than-one-module.md)). The
same `Uuid` `nilo_sql` reads a `uuid` column into, so a generated key goes
straight into an insert. Nothing here allocates and nothing here does IO.

```zig
const id = @import("nilo_id");

const key = id.v7(try c.entropy(id.Uuid.v7_entropy), nilo.nowMillis());
_ = try db.insert(User, c, .{ .id = key, .email = form.email });
```

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
    const read = config.fromEnv(Settings, init.minimal.environ);
    const settings = read.value() orelse {
        try read.report(stderr);
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

**It parses no files.** `std.zon.parse` is in the standard library;
[sam701/zig-toml](https://github.com/sam701/zig-toml) is the one to reach for
if the file has to be TOML. Either way the pairs come back as a `Fixed` and
this module never had to carry the dependency.

## `nilo_pw`

Password hashing
([ADR 0048](./adr/0048-a-password-hash-is-gated-because-forgetting-is-silent.md)).
Argon2id, in the PHC form everybody else writes.

```zig
// signing up
const stored = try c.hashPassword(gpa, form.password);
_ = try db.insert(User, conn, .{ .email = form.email, .password = stored.text() });

// signing in
const row = try db.find(User, conn, .{ .email = form.email });
if (!try c.verifyPassword(gpa, if (row) |r| r.password else null, form.password))
    return nilo.fail(401, "that is not a sign-in");
```

| | |
|---|---|
| `c.hashPassword(gpa, text)` | `!pw.Hash` — the call a handler makes |
| `c.verifyPassword(gpa, stored, text)` | `!bool` — `stored` is `?[]const u8` |
| `stored.text()` | the PHC string, `$argon2id$v=19$m=19456,t=2,p=1$…` |
| `pw.Cost.default` | OWASP's first recommendation: 19 MiB, 2 passes, 1 lane |
| `pw.Cost.floor_memory_kib` | 7168 — below it is a compile error |
| `pw.salt_len` | 16 |
| `pw.bytesFor(cost)` | what one hash asks the allocator for. 19,922,944 at the default |
| `pw.hash` / `pw.hashWith` / `pw.verify` | the pure functions, for a program with no server |

**Call the `Ctx` methods, not `nilo_pw` directly.** One hash is 13 ms and
19 MiB. Thirteen milliseconds is *under* `block_warning_ms`, so calling the
module straight from a handler holds the thread on every sign-in and **nothing
in the log ever says so**. The methods take the salt from `c.entropy`, park the
fiber on the blocking pool, and hold one of
`listen(.{ .password_hashes_at_once = 8 })` permits.

**`stored` is optional and null is the point.** A sign-in for an address with
no account has no hash to check; returning early there answers in a millisecond
instead of thirty and turns the form into a query for which addresses are
registered. Passing null does the work anyway and answers false.

**`gpa` is an argument because 19 MiB is worth seeing.** Not `c.arena()` — the
request arena is reset per request keeping `arena_keep` bytes, and pushing
19 MiB through it spends the one budget nilo treats as an invariant.

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
| `s.receive(&buf)` | `!?Message` — the buffer is the message ceiling |
| `s.send(kind, data)` | `.text` or `.binary` |
| `s.sendText(text)` / `s.sendBinary(bytes)` | |
| `s.ping(data)` | |
| `s.close(code, reason)` | safe to call twice |
| `s.closedCleanly()` | whether the other end said goodbye |
| `s.live()` | false once the server is stopping |

`c.upgradeWith(.{ .idle_ms = 30_000 })` — how long this connection may say
nothing before nilo pings it. No answer by the end of the next stretch closes
it with 1001. Not a deadline: a quiet WebSocket is a working one, so silence
asks a question rather than ending anything. `0` waits forever.

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
    var socket = try c.upgrade();
    try room.join(&socket);
    defer room.leave(&socket);

    var buf: [16 * 1024]u8 = undefined;
    while (try socket.receive(&buf)) |message| {
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
| `room.count()` | how many connections are in it |
| `room.missed(&socket)` | posts this connection was too slow to take |
| `room.full = .drop_oldest` | or `.drop_newest`, when a connection's backlog fills |

The loop is the one an echo server writes: nothing in it mentions the other
connections, and nothing handles an incoming broadcast. `receive` writes those
out on the way past, from the fiber that owns the socket — which is why one
client that stops reading costs that client and nobody else.

`defer room.leave(&socket)` is not optional. Zig has no destructor, and a seat
nobody gives up is one the next connection cannot have.

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
| `nilo.spawn(f, args)` | run something that is not a request |
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

## Testing

| | |
|---|---|
| `testing.Client.init(gpa, .{ .response_bytes = 64 * 1024 })` | |
| `client.get(&app, path)` / `post(&app, path, body)` | |
| `client.postWith(&app, path, content_type, body)` | a POST that says what its body is — what a form needs |
| `client.request(&app, method, path, body)` | |
| `client.send(&app, raw_request)` | the whole request, written out |
| `answer.status` / `.head` / `.body` / `.raw` / `.chunked` / `.keep_alive` | |
| `answer.header(name)` | case-insensitive, the first of that name |
| `answer.headerAt(name, n)` / `.headerCount(name)` | for the ones a response repeats |
| `answer.setCookie(name)` | the whole `Set-Cookie` line that sets it |
| `answer.text(&buf)` | the body with chunk framing undone |

## `nilo_sql`

A second module, imported separately. A project that never imports it links
none of it ([ADR 0040](./adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)).

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
| `.name` | the table, **written out**. Never guessed from the type name |
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

| `Opts` | |
|---|---|
| `size` | connections held open. Default 10 |
| `connect_on_init` | how many to dial during `listen()`. Default 0 |
| `timeout_ms` | how long a caller waits for a free connection. Default 10,000 |
| `schema_mismatch_is_fatal` | whether a Row that disagrees with its table stops startup. Default true |

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
| `db.update(User, c, .{ .set = …, .where = … })` | `!usize` — rows changed. Both halves required |
| `db.updateReturning(User, c, .{ .set = …, .where = … })` | `![]User` — the rows as they now are. One statement where an update and a select are two and a race |
| `db.delete(User, c, .{ .where = … })` | `!usize` — rows deleted. `.where` required |
| `db.deleteReturning(User, c, .{ .where = … })` | `![]User` — the rows that were removed |
| `db.stream(User, c, .{ … })` | rows one at a time; see below |
| `db.raw(User, c, sql, .{ … })` | `![]User` — a statement this module will not write |
| `db.begin(c)` | `!Tx` |

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
| `.any = .{ .{ … }, .{ … } }` | OR, bracketed. Not `.or`, which is a keyword — so `any` is a reserved column name |

A column that does not exist is a compile error naming the near miss.

**A null is written, never held.** The two lines above are `IS NULL` because
the compiler can see the null. An optional that *might* be null is a compile
error, because whether the statement says `= $1` or `IS NULL` would then
depend on a value that arrives after the statement is a constant — and
`= NULL` is never true in SQL, so the query would run and answer nothing.
Branch on it instead
([ADR 0044](./adr/0044-a-condition-holds-a-value-not-a-maybe.md)).

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
var tx = try db.begin(c);
defer tx.deinit();          // rolls back unless committed
_ = try tx.insert(Order, c, .{ … });
try tx.commit();
```

`tx` carries every read and write call above — `select`, `one`, `find`,
`count`, `exists`, `insert`, `update`, `updateReturning`, `delete`,
`deleteReturning` and `raw` — all down the one connection it holds.
Forgetting the `defer` is caught in Debug by a counter asserted at
`db.deinit()`.

| | |
|---|---|
| `tx.deadline(ms)` | bound every statement after it, for the life of this transaction. `error.TimedOut` past it |

```zig
var tx = try db.begin(c);
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

### Types

| | |
|---|---|
| `sql.Timestamp` | microseconds since the epoch, written as RFC 3339 in JSON. `timestamptz`. `.now()`, `.fromSeconds(s)`, `.seconds()` |
| `sql.Uuid` | `nilo_id`'s [`Uuid`](#nilo_id), re-exported — the same type either import gives you. `uuid` |
| `sql.Json(T)` | a `T` stored as `jsonb`, parsed per row into the request arena. Not available in `db.stream`, which allocates nothing |

### Errors

| | |
|---|---|
| `error.AlreadyExists` | a unique violation. **409** by default — the only one with a default |
| `error.ConstraintViolated` | foreign key, check or not-null. 500: usually the code is wrong |
| `error.Disconnected` | the database went away, or was never there |
| `error.TimedOut` | a statement ran past `tx.deadline`. No default status — what a deadline means is the handler's to decide |
| `error.QueryFailed` | anything else. The server's text is logged, never sent |
