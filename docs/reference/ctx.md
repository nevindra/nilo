# The request

**`Ctx` is one request in flight: everything a handler reads from it, answers with, and fails it with.**

**Guide:** [Requests](../guide/requests.md), [Responses](../guide/responses.md), [Cookies](../guide/cookies.md), [Sessions](../guide/sessions.md), [Errors](../guide/errors.md) · **Design:** [Request input](../design/request-input.md), [Responses](../design/responses.md), [Cookies and sessions](../design/cookies-sessions.md), [Errors](../design/errors.md)

This page covers reading a request, answering it, its cookies, session and uploads, and failing it.

## `Ctx`

### Reading

| | |
|---|---|
| `c.method` | `.GET`, `.POST`, … |
| `c.path()` | `Str`: the path, without the query string |
| `c.param(name)` | `?Str`, percent-decoded. `"*"` for a catch-all |
| `c.routeName()` | `?[]const u8`: the `operationId` of the route that matched, as the API description prints it: what `app.named` gave it, or the derived `getUsersId`. Null when nothing matched: a 404, a 405, a static file. For a middleware holding one authorisation table over every route ([ADR 162](../adr/162-a-middleware-can-learn-which-route-it-is-in-front-of.md)) |
| `c.query(name)` | `?Str`, percent-decoded, `+` as space |
| `c.queries()` | an iterator over every query parameter, in arrival order: `while (it.next()) \|q\|`, `q.name` and `q.value` are `Str`. A name sent twice appears twice |
| `c.queryString()` | `Str`: the query as it arrived, still encoded, no `?` on the front. `""` when there was none |
| `c.host()` | `Str`: the host this request was addressed to. `X-Forwarded-Host` from a trusted proxy, else the authority of an absolute-form target, else the `Host` header |
| `c.scheme()` | `Str`: `"https"` or `"http"`, what the **client** used. `"https"` on a listener with its own TLS, else `X-Forwarded-Proto` from a trusted proxy, else `"http"` |
| `c.listener()` | `u8`: which listener the request arrived on. `0` for the one `address` and `port` name, `1` for `also[0]`, and so on, in the order `listen()` was given them. Read off the connection, so no header can claim it; `0` in a test unless `.listener` is set ([ADR 252](../adr/252-a-request-knows-which-listener-it-came-in-on.md)) |
| `c.header(name)` | `?Str`, name matched case-insensitively. The **first** of that name |
| `c.clientHas(version)` | `bool`: whether `If-None-Match` names the tag a `nilo.Versioned(T)` with that `u64` goes out under. Asked before building the body, so `.unchanged(version)` skips the query as well as the bytes ([ADR 189](../adr/189-a-version-a-handler-names-is-an-etag.md)) |
| `c.authorization(.bearer)` | `!Authorization(.bearer)`: the header as one scheme, or the 401 with the challenge on it. For a resolver; a handler asks in its argument list |
| `c.verified(V)` | `!Verified(V)`: the bearer token verified through the `jwt.Verifier` `V`, or the 401. For a middleware guarding a prefix; a handler asks in its argument list |
| `c.headers()` | an iterator over every header, in arrival order: `while (it.next()) \|h\|`, `h.name` and `h.value` are `Str` |
| `c.cookie(name)` | `?Str`: as the client sent it, nothing decoded. Allocates nothing |
| `c.body()` | `!Str`: the whole body, up to `max_body` (1 MB) |
| `c.json(T)` | `!T`: the body parsed as JSON |
| `c.form(T)` | `!T`: the body parsed as a form, urlencoded or multipart |
| `c.jsonCollecting(T, &outcomes)` | `!T`: as `json`, recording why each field failed |
| `c.formCollecting(T, &outcomes)` | `!T`: as `form`, recording why each field failed |
| `c.requestId()` | `Str`: this request's id, from `X-Request-Id` or generated |
| `c.entropy(n)` | `![n]u8`: unguessable bytes from the OS, off the event loop. `n` is comptime |
| `c.entropyInto(buf)` | `!void`: the same, at a width nobody said while compiling |
| `c.hashPassword(gpa, text)` | `!pw.Hash`: argon2id, salted, off the loop and behind the Gate |
| `c.hashPasswordWith(cost, gpa, text)` | the same, at a `pw.Cost` of your own |
| `c.verifyPassword(gpa, stored, text)` | `!bool`: `stored` is `?[]const u8`; null means no such account |
| `c.verifyPasswordWith(cost, gpa, stored, text)` | the same, told what a hash of yours costs |
| `nilo.verifyPassword(gpa, stored, text)` | the same check with no request in hand: a CLI, a job, a test. Same Gate; see [`nilo_pw`](./pw.md) |
| `c.bodyStream()` | `!Body`: the body in pieces |
| `c.bodyStreamWith(.{ .max_bytes = … })` | the same, with a ceiling. Default 64 MB |
| `c.peer()` | a `*const Peer` for the address the connection came from: the proxy's, if there is one. `c.peer().address()` is valid for the whole request |
| `c.clientIp()` | `Str`: the client, looking through `trusted_proxies` or `trusted_hops`. Empty on a unix socket with neither set |
| `c.stopping()` | `bool`: the server has been told to stop and is draining. What the health page answers `stopping` on |
| `c.overdue()` | whether the deadline `nilo.deadline(ms)` gave this route has passed. Always false without one |
| `c.timeLeftMs()` | `?u32`: milliseconds left, `null` without a deadline, `0` once it has gone |
| `c.giveDeadline(ms)` | set one by hand. `nilo.deadline(ms)` is what normally calls this |
| `c.giveBodyLimit(bytes)` | how much body this request may read into the arena, over `listen()`'s `max_body`. `nilo.maxBody(bytes)` is what normally calls this; a body already read keeps the limit it was read under |
| `c.service(*Db)` | `?*Db` |
| `c.resolve(V)` | `!V`: a resolved value, worked out once per request |
| `c.keepAlive()` | whether the connection will carry another request |
| `c.connection()` | the same as the `Connection` line the response will carry: `.implied` (HTTP/1.1, staying open, no line), `.keep_alive` (HTTP/1.0, kept), `.close` |
| `c.io()` | `std.Io`: the server's loop, for a `std.Io.Queue`, `Event` or `Select`. Nothing is held per connection. With no server (a `testing.Client`) it is a process-wide `std.Io.Threaded` ([ADR 244](../adr/244-a-handler-is-given-the-loop-it-runs-on.md)) |
| `c.arena()` | `std.mem.Allocator`: memory that lasts exactly this request. Never freed by hand. Several threads may allocate from it at once, so a handler can give it to threads it starts inside `nilo.blocking` and return a value that borrows from it, once they are joined |
| `c.str(bytes)` | `Str`: text you allocated from `c.arena()`, stamped with this request's lifetime |

### Answering

| | |
|---|---|
| `c.setHeader(name, value)` | copied into the request arena |
| `c.setStaticHeader(name, value)` | not copied: for text that already outlives the request |
| `c.setTrailer(name, value)` | `!void`: a field sent after the body, for what is known only once the body is. Copied into the request arena. See [Trailers](#trailers) |
| `c.setCookie(cookie)` | a `Set-Cookie`. Calling it twice sets two, not one |
| `c.clearCookie(.{ .name = …, .path = …, .domain = … })` | delete one. Path and domain have to match |
| `c.redirect(status, location)` | a `Location` and no body |
| `c.send(status, content_type, bytes)` | **a second answer is `error.AlreadyAnswered`**, and the first stands; gzipped on the way out when `app.compress` is on and the body, the type and the client all qualify ([ADR 211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)); so are the two below |
| `c.sendKept(status, content_type, bytes)` | `send` for a body that already outlives the middleware chain (one in the request arena, or one a typed handler returned). Not copied when a middleware holds the answer, which `send` does copy ([ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)) |
| `c.sendText(status, text)` | `text/plain` |
| `c.sendJson(status, value)` | `application/json` |
| `c.sendEmpty(status)` | no body and no `Content-Type`: a 204, usually |
| `c.sendFile(.{ .file = f, .content_type = … })` | an open file. **Closed here**, on every way out, a second answer's `error.AlreadyAnswered` included |
| `c.stream(status, content_type)` | `!Stream`. A status with no body (204, 304, 1xx) is refused with a 500 saying so, and a second answer is `error.AlreadyAnswered` |
| `c.streamWith(status, content_type, .{ .buffer = … })` | the same, buffer of your own. Default 4 KB |
| `c.streamWith(…, .{ .length = n })` | a stream whose length is already known: `Content-Length` and no chunk framing ([ADR 101](../adr/101-a-stream-that-knows-its-length-says-so.md)) |
| `c.url(pattern, args)` | `!Str`: a URL for a route, every value percent-encoded and every mistake a compile error ([ADR 100](../adr/100-a-route-pattern-is-the-name-of-its-url.md)) |
| `c.events()` | `!Events` |
| `c.upgrade(loop, state)` | `!void`: the connection becomes a WebSocket and `loop` reads it. `{}` when there is no state. A request already answered is `error.AlreadyAnswered` |
| `c.upgradeWith(loop, state, .{ .protocols = &.{ "chat.v2", "chat.v1" } })` | the same, naming the subprotocols the route speaks (`.protocol` is the one-name spelling). The answer is the first the client offered, and none if it offered none of them |

### Response headers

**nilo writes some headers itself, and refuses to let `setHeader` write the ones that frame the response.** Every response carries a `Date` written by nilo; set one yourself and yours is sent instead ([ADR 197](../adr/197-a-response-says-when-it-was-sent.md)). `setHeader` refuses `Content-Type`, `Content-Length`, `Transfer-Encoding` and `Connection`. It also refuses a name that is not a valid token, and a value containing a control byte, because a newline in a value would start a second header, and two newlines would start a second response ([ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)). All three cases are a 500 naming the header. It also refuses `grpc-status` and `grpc-message`, which are trailers: use `setTrailer`. **A header set after the answer's head was written is refused with a sentence saying so, where it used to be lost without a word.** Set headers before sending, or hold the answer from a middleware with `next.hold(c)`, which keeps the head back until the chain has unwound ([ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md), [Middleware](middleware.md#holding-the-answer-with-nexthold)).

Setting the same header twice replaces it, except for `Set-Cookie` and `Vary`, which a response may carry more than once. `Set-Cookie` because two cookies cannot be folded into one line; `Vary` because two layers can each name their own axis, and replacing one would drop the other ([ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)). Setting either with a name and value that are already present adds nothing.

### Trailers

**A trailer is a field sent after the body, for what is known only once the body is** (a `Server-Timing` for work the body did, a checksum, a gRPC status) ([ADR 254](../adr/254-an-answer-can-carry-trailers.md)).

| | |
|---|---|
| `c.setTrailer(name, value)` | `!void`. Settable until the body ends, on every framing alike: before `send` for a whole answer, before `finish` for a stream, and after `next` from a middleware that called `next.hold(c)`. The last one set under a name wins |
| `c.trailers()` | the trailers set so far, in the order they were set |
| `c.clientReadsTrailers()` | `bool`: whether the request said so with a `TE` naming `trailers` (RFC 9110 §10.1.4) |
| `Ctx.checkTrailer(entry)` | `!void`: the checks `setTrailer` makes, on their own, for a caller that keeps an answer to send again and has to know first |

**How each framing carries them.** HTTP/2 sends them after the body. A chunked HTTP/1.1 stream sends them as the trailer section. **A whole HTTP/1.1 answer is chunked to carry them only when the request was HTTP/1.1, not a HEAD, had `TE: trailers`, and the status has a body; otherwise they are left off**, because a client that never asked could not have read them (RFC 9110 §6.5.1).

**Refused, with a sentence naming the field:** the names RFC 9110 §6.5.1 keeps out of trailers (the framing, the route, authentication, a cache rule, the content's type and encoding), a name that is not a token, and a value with a control byte. Copied into the request arena, so an answer with none costs nothing.

### `c.host` and `c.scheme`

**Use `host()` and `scheme()` when a handler writes a URL to its own service**: a password-reset link, an OAuth `redirect_uri`, an absolute `Location`. On a listener with its own TLS, `scheme()` is `"https"` from the connection. Behind a proxy, name the proxy with `.trusted_proxies` (or count it with `.trusted_hops`), and the two headers it writes are believed on connections it made, exactly as `X-Forwarded-For` is. With neither set, `scheme()` is `"http"` ([ADR 090](../adr/090-a-request-can-be-read-past-the-parts-a-handler-names.md), [ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)). A forwarded host that does not look like a host is dropped, not used, because this value ends up in a link somebody clicks.

**A target in absolute form sets `host()` before the `Host` header does.** `GET http://example.com/users/7` is what a client sends to something it believes is a proxy, and RFC 9112 §3.2 gives an origin server no choice: the authority on the request line is the host, and a `Host` header beside it is ignored ([ADR 095](../adr/095-a-target-is-read-in-the-form-it-arrived-in.md)). The router still matches on the path, so writing routes does not change. A trusted `X-Forwarded-Host` takes priority over both.

### Compressed request bodies

**A body sent with `Content-Encoding: gzip` is decompressed into the arena before anything reads it**: `body`, `json`, a struct argument, a form. `max_body` limits both the compressed and the decompressed size, and a body that does not decode is a 400 naming the encoding ([ADR 089](../adr/089-a-body-under-an-encoding-other-than-gzip-is-refused.md)). `bodyStream` does not decode, and answers a gzipped body with a 415. **Any other encoding is a 415** naming the header, before any handler runs ([ADR 089](../adr/089-a-body-under-an-encoding-other-than-gzip-is-refused.md)). The header is ignored on a request with no body.

### A stream with a `.length`

**A stream with a `.length` must write exactly that many bytes.** Writing past it is refused before any byte of the overrun is sent, because a client reading a `Content-Length` stops there and reads everything after it as the next response. Finishing short cannot be refused, because the head has already been sent, so the connection is closed and the log names both numbers.

### `c.url`

**`c.url` is checked while compiling.** A param with no value, a value with no param, a value a path segment cannot carry, and a `*` catch-all are all compile errors naming the field. Values are matched by name, so `.{ .slug = t, .id = 42 }` and `.{ .id = 42, .slug = t }` give the same URL. `nilo.url.into(buf, pattern, args)` is the same call with your own buffer and no allocation, for code with no request in flight. A text value that is empty, `.` or `..` is `error.BadValue`, because a browser follows `/u/../settings` to `/settings` and reads `%2E` as a dot ([ADR 100](../adr/100-a-route-pattern-is-the-name-of-its-url.md)).

### `c.sendFile`

`sendFile` also takes `size` (null asks the file), `etag` and `cache_control`, and uses them to answer `Range`, `If-Range`, `If-None-Match` and `HEAD`. A handler that knows before it runs that it will answer with a file returns [`FileBody`](./handlers.md#handler-returns) instead, which the API description can see.

### Tracing

| | |
|---|---|
| `c.span(comptime name)` | `nilo.trace.Span`: a span of this request's trace, a child of the current span and current itself until `end`. A `nilo_fetch` call or another `c.span` while it is open is its child. On an App that does not trace, or a trace that is not recorded, it records nothing |
| `span.end()` | records it and makes its parent current again. `defer span.end()` |
| `span.fail(err)` | marks it failed, with the error's name as `error.type` and the status message. `errdefer \|err\| span.fail(err)` |
| `c.traceId()` | `?[32]u8`: the trace id as lowercase hex, or null on an App that does not trace |

The name is comptime so that it is one of a few, which is what a trace view groups by ([ADR 247](../adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)). The guide page is [Tracing](../guide/tracing.md).

## `Cookie`

**What `c.setCookie` takes.** Only `name` and `value` have no default. The guide page is [Cookies](../guide/cookies.md).

| | Default |
|---|---|
| `name`, `value` | required |
| `path` | `"/"` |
| `domain` | `""`: this host, no subdomains |
| `max_age` | `null`: a session cookie |
| `expires` | `""`: an HTTP-date, if you have one |
| `secure` | `true` |
| `http_only` | `true` |
| `same_site` | `.lax`, or `.strict`, `.none`, `.unset` |

A value containing a space, comma, semicolon, quote, backslash or control byte is refused with a 500, because a `;` would start an attribute nobody wrote. `.none` without `.secure` is refused for a similar reason: browsers drop that combination.

## `Session(T)`

**The session, sealed into one cookie.** `T` is a struct of yours whose size is known while compiling: numbers, bools, enums, `[N]u8`, optionals, and structs of those. Not slices. See [Sessions](../guide/sessions.md).

| | |
|---|---|
| `s.get()` | `?T`: what the client sent, or null if it sent nothing readable |
| `s.set(value)` | replaces it; one `Set-Cookie` on this response |
| `s.setWith(value, options)` | the same, with your own cookie attributes |
| `s.clear()` | signs out by deleting the cookie |
| `s.clearWith(.{ .path = …, .domain = … })` | the same, matching a cookie set with a different path or domain |

`setWith` options: `path` (`"/"`), `domain` (`""`), `max_age` (`null`, a session cookie), `secure` (`true`), `same_site` (`.lax`). There is no `http_only`: it is always on.

### The cookie name

The cookie is named `__Host-session` (`nilo.session.host_cookie_name`) when it is `Secure`, at `/`, and has no `domain`, which is what the defaults give. Otherwise it is `session` (`nilo.session.cookie_name`), because a browser drops a `__Host-` cookie if any of those change. The plain name is read only with `listen(.{ .session_plain_name = true })`, after the prefixed one, and a `set` that would write it without that option fails with a message naming it. The next `set` writes the prefixed name and deletes the plain one, and `clear` deletes both.

### Expiry

**`max_age` sets the cookie attribute and also an expiry sealed inside the cookie**, where the client cannot change it; `Max-Age` alone is only advice, which a copied cookie ignores. Null seals `nilo.session.default_max_age`, 24 hours ([ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)). `nilo.session.openAt(T, cookie, key, when)` opens a session at a time you choose, for a test that wants the expiry boundary without a wall clock.

### The secret

**Every way a cookie can be unreadable gives the same answer: `null`.** That covers tampered, truncated, expired, sealed under another secret, or written by a build with a different shape of `T`. The secret comes from `listen(.{ .session_secret = … })` and must be exactly 32 bytes; a handler asking for a session when none is set answers 500. A cookie the secret does not open is tried under each of `session_fallback_secrets`, which open sessions but never seal them ([ADR 225](../adr/225-a-fallback-session-secret-opens-and-never-seals.md)).

## `Upload`

**One file from a multipart form, as a `Form(T)` field type.**

| | |
|---|---|
| `u.filename` | `Str`: **what the client said**, never a path to write to |
| `u.content_type` | `Str`: the client's claim, unverified |
| `u.bytes` | `Str`: the file itself |
| `u.len()` | its size |
| `u.saveTo(dir, name)` | `!void`: writes it into a [`Dir`](./streaming.md#dir) under **a name you choose** |

**`saveTo` either replaces the file at `name` or leaves it untouched.** The bytes go to a temporary name beside it and one rename puts them in place, so a request serving that same name from the same `Dir` never reads it half-written ([ADR 097](../adr/097-a-file-is-written-by-the-engine.md)). Passing `u.filename` as the name returns `error.NameNotAllowed`; it is never resolved as a path against the directory.

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
| `fail.internal(…)` | 500: logged, not sent |
| `fail.status(code, fmt, args)` | any status |

**All of them return `error.Failed`.** The message goes into a 240-byte slot with no allocation, and is sent as `{"error": "…", "status": 404}`, the same shape for every failure whatever the endpoint returns when it succeeds, or as the struct `app.failures(T)` named, filled from the same status and message ([ADR 024](../adr/024-every-failure-answers-as-json.md)). The guide page is [Errors](../guide/errors.md).
