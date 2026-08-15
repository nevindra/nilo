# Reference

The whole surface, as a list. For what any of it is *for*, see
[the guide](./guide/).

## Root wiring

```zig
pub const std_options = zfast.std_options;         // engine chatter → warnings
pub const std_options_debug_io = zfast.debug_io;   // std.log off the event loop
pub const panic = zfast.panic;                     // optional: name the request in a crash
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
literal; the type is `zfast.Group("/api")`.

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
| `Session(T)` | the session, out of its cookie |
| `std.mem.Allocator` | the request arena |
| a type with `zfast_resolve` | a resolved value |
| any other struct | the body, parsed from JSON |

A body field may be `Patch(T)`, which tells "not sent" from "sent as null":
`.absent`, `.cleared`, `.value`. Give it `= .absent` as its default;
`.orNull()` collapses the two empty cases.

`Form(T)` and a plain struct are the same slot — a form *is* the body — so
asking for both is a compile error. A `Form(T)` field is a `Str`, a number, a
`bool`, an enum or an `Upload`, optionally in a `?`; a default is what "not
sent" means. See [Forms](./guide/forms.md).

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

```zig
Status(201, User){ .headers = .of(&.{…}), .value = user }
Status(204, void){}                                        // an empty response
Response(User){ .status = if (made) 201 else 200, .value = user }
Redirect(303).to("/welcome")                               // written `return .to(…)`
Redirect(303).with("/welcome", .of(&.{…}))                 // …with headers of its own
```

`Redirect` takes 301, 302, 303, 307 or 308; anything else is a compile error.
303 is the one a form POST wants.

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
| `c.bodyStream()` | `!Body` — the body in pieces |
| `c.bodyStreamWith(.{ .max_bytes = … })` | the same, with a ceiling. Default 64 MB |
| `c.peer()` | the address the connection came from — the proxy's, if there is one |
| `c.clientIp()` | `Str` — the client, looking through `trusted_hops` proxies |
| `c.service(*Db)` | `?*Db` |
| `c.resolve(V)` | `!V` — a resolved value, worked out once per request |
| `c.keepAlive()` | whether the connection will carry another request |

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
| `c.stream(status, content_type)` | `!Stream` |
| `c.streamWith(status, content_type, .{ .buffer = … })` | the same, buffer of your own. Default 4 KB |
| `c.events()` | `!Events` |
| `c.upgrade()` | `!Socket` |
| `c.upgradeWith(.{ .protocol = "chat.v1" })` | the same, naming a subprotocol |

`Content-Type`, `Content-Length`, `Transfer-Encoding` and `Connection` are
refused by `setHeader`. Set headers before sending. Setting the same header
twice replaces it — except `Set-Cookie`, which a response may carry more than
one of.

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

`Close`: `.normal`, `.going_away`, `.protocol_error`, `.unsupported`,
`.invalid_payload`, `.policy`, `.too_big`, `.internal`, or a number.

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
| `zfast.Mutex` | `.init`, then `try lock()`, `unlock()`, `tryLock()` |
| `zfast.blocking(f, args)` | run a blocking call off the event loop |
| `zfast.sleep(ms)` | wait without parking the thread |
| `zfast.spawn(f, args)` | run something that is not a request |
| `zfast.monotonicNanos()` | a clock reading, for durations |

`lock()` and `sleep()` fail with `error.Canceled` if the request went away, which
maps to a 503.

A handler that waits on the operating system without going through one of these
holds the thread every other request on it is being served by. zfast notices and
says so, once a second at most:

```
handler GET /users/7 held its thread for 2003ms. Every other request being
served on that thread waited the whole time. Hand the call that waits to
zfast.blocking (ADR 0014).
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
try zfast.spawn(flushMetrics, .{&exporter});
```

Sending to a WebSocket somebody else's connection is holding is **not** here.
[ADR 0029](adr/0029-a-spawned-fiber-belongs-to-the-server.md) has the
measurement that says why.

## Built-in middleware

```zig
zfast.logger.standard                                    // one info line per request
zfast.logger.with(.{ .level = .info, .slow_micros = 0 }) // slower than this → .warn

zfast.cors.permissive                                    // origin "*", no credentials
zfast.cors.with(.{ .origin = …, .methods = …, .headers = …,
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
