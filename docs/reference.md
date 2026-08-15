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
| `std.mem.Allocator` | the request arena |
| a type with `zfast_resolve` | a resolved value |
| any other struct | the body, parsed from JSON |

A body field may be `Patch(T)`, which tells "not sent" from "sent as null":
`.absent`, `.cleared`, `.value`. Give it `= .absent` as its default;
`.orNull()` collapses the two empty cases.

## Handler returns

| Returned | Response |
|---|---|
| `void` | 200, empty, no `Content-Type` |
| `Str`, `[]const u8` | 200, `text/plain` |
| anything else | 200, that value as JSON |
| `?T` | 200 with the value, **404** when null |
| `Status(code, T)` | that status — and the API description names it |
| `Response(T)` | a status chosen at runtime; the description says `default` |

```zig
Status(201, User){ .headers = .of(&.{…}), .value = user }
Status(204, void){}                                        // an empty response
Response(User){ .status = if (made) 201 else 200, .value = user }
```

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
| `c.body()` | `!Str` — the whole body, up to `max_body` (1 MB) |
| `c.json(T)` | `!T` — the body parsed as JSON |
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
refused by `setHeader`. Set headers before sending.

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
| `client.request(&app, method, path, body)` | |
| `client.send(&app, raw_request)` | the whole request, written out |
| `answer.status` / `.head` / `.body` / `.raw` / `.chunked` / `.keep_alive` | |
| `answer.header(name)` | case-insensitive |
| `answer.text(&buf)` | the body with chunk framing undone |
