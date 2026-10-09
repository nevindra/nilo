# The App

**The App is the server: where services, middleware and routes are registered, and what `listen()` takes to run it.**

**Guide:** [Getting started](../guide/getting-started.md), [Routing](../guide/routing.md), [Services](../guide/services.md), [Deploying](../guide/deploying.md) · **Design:** [Lifecycle](../design/lifecycle.md), [Routing](../design/routing.md), [The engine](../design/engine.md)

This page covers the App and its groups, the options `listen()` takes, the concurrency tools, and the options for `static` and the OpenAPI document.

## `App`

### Services and startup

| | |
|---|---|
| `App.init(gpa)` | a new App. The allocator is for the App's own structures, not for requests |
| `app.deinit()` | |
| `app.provide(&thing)` | registers a service, looked up later by its pointer type. A service may declare up to four hooks. `pub fn nilo_start(self: *T, io: std.Io) !void` finishes building it once there is an event loop ([ADR 037](../adr/037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)). `pub fn nilo_stop(self: *T) void` shuts it down before the loop goes ([ADR 121](../adr/121-a-service-is-stopped-before-the-loop-is.md)); **a service that put work on the loop needs this one**, or the loop cannot be torn down. `pub fn nilo_ready(self: *T, scope: *nilo_core.AnyScope) ?[]const u8` is what `app.health` asks ([ADR 154](../adr/154-a-health-route-asks-the-services.md)). `pub fn nilo_check(self: *T, io: std.Io) !void` runs once after the work `before` registered and before the first request, for a service that has something to verify once boot work is done: a `Db` checks its Rows against their tables there, after the `createMissing` that made them ([ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)) |
| `app.spawn(f, args)` | work that is not a request, started once the server is up ([ADR 028](../adr/028-a-spawned-fiber-belongs-to-the-server.md)) |
| `app.before(f, args)` | work that needs the services and has to finish before the first request: a migration, a version check, a key set fetched once. `f` is `fn (run: *nilo.Run, …) !void`, run once inside `listen()`, after the services have started and before what `spawn` registered, on the server's loop. If it fails, the server does not start ([ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)). A fail function called inside it is not lost: the log line that stops the boot includes its status and message, and which piece of work it was ([ADR 129](../adr/129-a-refusal-outside-a-request-is-still-a-refusal.md)) |
| `app.checkServices()` | `error.MissingService` if a route needs a service nobody provided |

### Middleware

| | |
|---|---|
| `app.use(mw)` | middleware on every route. `mw` is `fn (*Ctx, Next) !void`, or the same with services and resolved values after `Next` ([typed middleware](middleware.md#typed-middleware)); `useOn`, a group's `use`, `with` and `without` take either too. One that returns without answering and without calling `next.run(c)` is a 500 that names it (`middleware 2 of 3`) ([ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)) |
| `app.useOn(prefix, mw)` | middleware under a path prefix. A route whose pattern has a `:param` or `*` where the prefix has a word (`GET /files/*` beside `useOn("/files/private", …)`) has its chain resolved per request from the real path |
| `app.without(mw)` | the same App with `mw` turned off for the routes registered through the value it returns. This is how a sign-up route sits inside a guarded prefix ([ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)) |
| `app.with(mw)` | the opposite: the same App with `mw` turned **on** for the routes registered through the value it returns, so one endpoint can be guarded while its neighbours are not ([ADR 099](../adr/099-a-route-can-say-what-covers-it.md)) |
| `app.guard(mw, cookie)` | declares that `mw` rejects a request without the session cookie named `cookie`, so every route it covers is described in the API document with a `cookieAuth` requirement and a 401. Which routes it covers is read from `use`/`useOn`/`with`/`without` when the document is written; only the cookie's name is taken on trust. One per App; a second is `error.GuardAlreadyDeclared`. Declaring it does not install it ([ADR 153](../adr/153-an-authorization-header-a-handler-can-ask-for.md)) |

### Routes

| | |
|---|---|
| `app.get / post / put / delete / patch / head / options (pattern, handler)` | a route |
| `app.route(method, pattern, handler)` | a route for any other method |
| `nilo.neverWaits(handler)` | the handler, promised never to wait, as an argument of `app.get` and the rest: `try app.post("/echo", nilo.neverWaits(echo))`. Over HTTP/2 a call to a route known never to wait runs on its connection's own fiber, with no fiber of its own, which took the CPU of a small request from 2.45 to 1.25 µs ([ADR 260](../adr/260-a-request-on-http2-runs-from-its-headers.md)). nilo knows it from the signature when every argument is request data or a service that declares `pub const nilo_never_waits = true;` (a `cache.Space` does; a database, a store and an outbound client wait and say nothing); it cannot see into a `*Ctx`, so the promise is the author's. Nothing changes on HTTP/1.1. A route with middleware, or whose call parked while it ran that way, keeps a fiber, and the second is named once in the log |
| `app.rpc(T)` | every `pub fn` of the struct `T` as an RPC method, `POST /<T.nilo_service>/<Method>` with the function's first letter upper-cased (`sayHello` is `SayHello`); each must read or answer a protobuf message, and is the route `app.post` would have registered. `group.rpc(T)` adds the group's prefix and middleware ([gRPC](../guide/grpc.md#writing-a-method), [ADR 258](../adr/258-a-struct-of-typed-functions-is-an-rpc-service.md)) |
| `app.named("listPartners")` | the same App, where the next route registered through the value it returns gets that `operationId` instead of the one derived from the method and path ([ADR 119](../adr/119-a-route-can-say-its-own-name.md)). Letters, digits, `_` and `-`, starting with a letter or `_`, so `auth-login` works as a name a code generator can use ([ADR 119](../adr/119-a-route-can-say-its-own-name.md)) |
| `app.onListener(&.{1})` | the same App, where the routes registered through the value it returns answer only on the listeners numbered (`0` is the one `address` and `port` name, `1` is `also[0]`, up to 31). A request on another listener gets the 404 an unknown path gets, before any middleware of the route runs; a route not bound answers on every listener. Checked while compiling; also on a group ([ADR 252](../adr/252-a-request-knows-which-listener-it-came-in-on.md)) |
| `app.group(prefix)` | a group: see [`Group`](#group) below |
| `app.routes()` | every route, in registration order, as a view, not a copy. `.len()`, `.at(i)` and `{f}` ([ADR 100](../adr/100-a-route-pattern-is-the-name-of-its-url.md)). `.at(i)` has `.method`, `.pattern` and `.name` (the `operationId`, given or derived), so a table keyed by name can be checked against the route table ([ADR 162](../adr/162-a-middleware-can-learn-which-route-it-is-in-front-of.md)) |

`pattern` and `handler` are `comptime`. Registration order never matters.

### Static files

| | |
|---|---|
| `app.static(url_prefix, dir_path)` | a directory, read into memory at startup |
| `app.staticWith(url_prefix, dir_path, options)` | the same, with [options](#static-options) |
| `app.embedded(url_prefix, files)` | files the binary carries, as a list of `.{ .path, .bytes }` with `@embedFile` on each, served the same way a directory is ([Static files](../guide/static-files.md#embedded-files), [ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)) |
| `app.embeddedWith(url_prefix, files, options)` | the same, with the [options that are not about a disk](#static-options) |

### Documents, health, metrics, tracing and compression

| | |
|---|---|
| `app.docs(options)` | serves an [OpenAPI document](../guide/openapi.md). Returns nothing, so no `try` |
| `app.failures(T)` | the body every failure is sent with, when nilo's `{"error":…,"status":…}` is not what your clients read. `T` is a struct whose fields are the JSON, with `pub fn nilo_failure(status: u16, message: []const u8) T` filling it from the status and the fail function's message; the document's `Failure` schema comes from the same fields. Once per App; a second is `error.FailureShapeAlreadySet`. Responses written before there is a request to route (400, 408, 415, 431, a shed 503) keep nilo's own shape ([Errors](../guide/errors.md#the-error-response-body), [ADR 024](../adr/024-every-failure-answers-as-json.md)) |
| `app.health(path)` | a page that says whether this process can do its job: `200 {"status":"ok"}`, or `503` naming the services that are not ready and why, or `503 {"status":"stopping"}` once the server has been told to stop. It asks every service that declared `pub fn nilo_ready(self: *T, scope: *nilo_core.AnyScope) ?[]const u8`, where null means ready and a sentence says why not ([Deploying](../guide/deploying.md#health-checks), [ADR 154](../adr/154-a-health-route-asks-the-services.md)). Described in the document as a `200` of `{"status":…}`, and not counted among the routes that write their own answer ([ADR 120](../adr/120-a-ctx-handler-that-returns-nothing-may-have-written-it.md)) |
| `app.metrics(options)` | counts every request and serves the numbers at `/metrics`, in Prometheus format ([Metrics](../guide/metrics.md), [ADR 079](../adr/079-the-route-table-is-the-registry.md)) |
| `app.expose(name, kind, &atomic)` | publishes a `std.atomic.Value(u64)` of your own on that page. `kind` is `.counter` or `.gauge` |
| `app.trace(options)` | every request a server span, a `nilo_fetch` call under it a client span carrying `traceparent`, and `c.span(name)` for the rest; sent as OTLP/HTTP protobuf to `endpoint/v1/traces` by a fiber of the server every `flush_ms` ([Tracing](../guide/tracing.md), [ADR 247](../adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)). Options that could send nothing are refused here: `error.TraceServiceEmpty`, `error.TraceEndpointNotHttp`, `error.TraceSampleOutOfRange`, `error.TraceBatchEmpty`, `error.TraceTooManyHeaders`. Once per App; a second is `error.TracingAlreadyEnabled` |
| `app.compress(options)` | gzips every text response that is at least `min_bytes` and at most `max_bytes` long and going to a client whose `Accept-Encoding` accepts it, per request, using a compressor borrowed from a pool of one per thread. Sets `Content-Encoding: gzip`, `Vary: Accept-Encoding` and the compressed length. A client that did not ask gets the body unchanged. Does not apply to streams, event streams or static files. Once per App; a second is `error.CompressionAlreadyEnabled` ([Responses](../guide/responses.md#compression), [ADR 211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)) |

### Running

| | |
|---|---|
| `app.listen(options)` | runs until stopped. Stops the process on a startup error |
| `app.start(io)` | everything `listen()` does before it accepts anything (services checked, middleware chains resolved, pools opened, the work `before` registered run, every `nilo_check` run after it), for a program that never listens: a test using `testing.Client`, a script, a worker on `jobs.serveOn(io)` ([ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)). **Not before `listen()`**: a service keeps the `Io` it was started on, so `start(io)` followed by `listen()` is refused when any service took one. For work between the pool and the server, use `app.before` ([ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)). It does *not* start `spawn` work, which needs a server |
| `app.shutdown()` | stops the server, from any thread or from inside a handler |
| `app.boundPort()` | `?u16`: the port the server is listening on, from any thread. Null before `listen()` has bound, and for a unix socket. `.port = 0` asks the kernel for a free port, and this returns it |
| `app.tryListen / tryRoute / tryStatic / tryStaticWith` | the same calls, returning the error instead of reporting it. A refused `tryRoute` registers nothing, its exemptions and attachments included, and its one line naming the route it collided with is a `warn`. `tryStatic` on a directory that does not exist returns `error.StaticDirNotFound` with no log line; a problem inside a directory that does exist is still logged in one line, since the error cannot name the file ([ADR 207](../adr/207-a-try-call-hands-back-the-error-and-says-nothing.md)) |

### Which calls fail

**Every call above returns an error union and needs a `try`, except these**, which return a value or nothing: `App.init`, `app.deinit`, `app.group`, `app.without`, `app.with`, `app.named`, `app.onListener`, `app.docs`, `app.routes`, `app.boundPort` and `app.shutdown`. Three fail in one named way: `app.guard` with `error.GuardAlreadyDeclared`, `app.failures` with `error.FailureShapeAlreadySet`, `app.compress` with `error.CompressionAlreadyEnabled`, and `app.trace` with `error.TracingAlreadyEnabled` beside the option errors in its row. `app.listen`, `app.route` and the `static` calls stop the process on the errors they can explain in one line, and their `try*` versions return the same errors instead ([ADR 207](../adr/207-a-try-call-hands-back-the-error-and-says-nothing.md)).

### `Group`

**`app.group("/api")` returns a group.** It has `group`, `use`, `useOn`, `without`, `with`, `named`, `onListener`, `provide`, `get`, `post`, `put`, `delete`, `patch`, `head`, `options`, `route`, `tryRoute`, `static`, `staticWith`, `tryStatic` and `tryStaticWith`: the same as an App, minus `listen`, `docs` and `shutdown`. The prefix is compile-time text and must be a literal; the type is `nilo.Group("/api")`.

`@TypeOf(g).mounted_at` is where it is mounted: `"/api"`, or `""` for an App, so a plugin taking `anytype` can ask either.

`g.without(mw)` is the same group with `mw` off for the routes registered through it. This is how the two routes that create a session sit inside a prefix that requires one. Its type is `nilo.GroupOf("/api", &.{mw})`.

`g.with(mw)` is the opposite, for a route that needs *more* than its neighbours. A middleware added this way runs innermost. Both `with` and `without` match on the joined pattern **and the method**, so a guard on `DELETE` does not cover the `GET` next to it. They can be combined:

```zig
const v1 = app.group("/v1");
try v1.use(requireOperator);
try v1.without(requireOperator).with(rateLimitSignups).post("/sign-up", signUp);
```

### `listen` options

| | Default |
|---|---|
| `address` | `"127.0.0.1"`: an address, not a host name. `"unix:/run/nilo.sock"` listens on a path ([ADR 103](../adr/103-a-path-is-an-address-to-listen-on.md)). Loopback in a container is warned about at startup, since a published port cannot reach it ([Containers](../guide/deploying.md#containers)) |
| `port` | `8787`. Not read when `address` names a unix socket |
| `threads` | `0`: one per core, or one more than a container's CPU quota where there is one; at most 64 ([ADR 230](../adr/230-a-cpu-quota-sets-the-thread-count.md)) |
| `read_buffer` | `16 * 1024`. Also the limit on a request head. Paid only while a connection is busy; an idle one gives the pages back ([ADR 196](../adr/196-a-head-is-mostly-cookies-and-sixteen-kilobytes-of-them.md)) |
| `write_buffer` | `4 * 1024` |
| `arena_keep` | `16 * 1024`: how much of a connection's request arena is kept between requests |
| `reuse_address` | `true`. On a unix socket, removes a socket file left behind by a process that has exited |
| `backlog` | `4096`: completed handshakes the kernel holds for `accept`. Past it a SYN is dropped and the client retries a second later. This is `somaxconn`'s default, and the kernel caps it there ([ADR 198](../adr/198-a-backlog-is-sized-for-the-burst-not-the-load.md)) |
| `stop_on_signal` | `true`: Ctrl-C and SIGTERM stop the server |
| `shutdown_grace_ms` | `10_000` |
| `header_timeout_ms` | `10_000`: the whole head, from its first byte |
| `idle_timeout_ms` | `75_000`: a connection between requests |
| `body_timeout_ms` | `30_000`: any one read of a body |
| `body_min_rate` | `8 * 1024`: bytes per second a buffered body has to keep up. `0` turns it off |
| `body_grace_ms` | `10_000`: time before the minimum rate is enforced |
| `write_timeout_ms` | `30_000`: any one write to the client. Cut to a route's deadline when that is nearer ([ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)) |
| `request_deadline_ms` | `0`: a deadline every request starts with, the same thing [`nilo.deadline(ms)`](./middleware.md#nilodeadline) gives one route. A route that takes over the connection drops it; a route's own deadline is kept. `0` means none ([ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)) |
| `max_connections` | `10_000` held at once, 4,669 bytes each when idle. `0` means no limit. `listen()` warns when the process's file descriptor limit (`ulimit -n`) is below it, and the accept loop waits out a shortage instead of stopping ([ADR 194](../adr/194-an-accept-loop-that-is-out-of-descriptors-waits.md)) |
| `max_requests_per_connection` | `1000`: requests one HTTP/1.1 connection is answered before the server ends it, less up to a tenth, chosen per connection so connections opened together do not all end together. The last answer carries `Connection: close`. A WebSocket is never ended by it. `0` means never ([ADR 275](../adr/275-a-connection-is-ended-after-a-number-of-requests.md)) |
| `max_requests_per_h2_connection` | `0` (never): the same cap for an HTTP/2 connection (`-Dhttp2`), which is sent a GOAWAY naming the last call it will answer. Off because h2load does not reopen after a GOAWAY; a browser and a gRPC channel do ([ADR 275](../adr/275-a-connection-is-ended-after-a-number-of-requests.md)) |
| `max_in_flight` | `0`: the most requests answered at once. Past it, a request immediately gets a `503` with `Retry-After: 1` instead of waiting in a queue. `0` means no limit ([ADR 159](../adr/159-a-server-past-its-limit-says-so-at-once.md)) |
| `max_body` | `1024 * 1024`: the most `c.body()` reads into the arena. One route can set its own with [`nilo.maxBody(bytes)`](./middleware.md#nilomaxbody), or read it from configuration with `nilo.maxBody(&limit)` |
| `trusted_hops` | `0`: how many proxies are in front, for `c.clientIp()`, `c.host()` and `c.scheme()` |
| `trusted_proxies` | `&.{}`: **which** proxies, as CIDRs, bare addresses, `"private"` or `"loopback"`. Their headers are read only on connections one of them made. Takes priority over `trusted_hops` ([ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)) |
| `session_secret` | `null`: 32 bytes, for `Session(T)`. Must be the same on every instance |
| `session_fallback_secrets` | `&.{}`: secrets a session cookie is still opened with when `session_secret` does not open it; nothing is sealed with them. Use it for the old secret after a rotation (kept for the longest `max_age` you seal with, then removed), or for the next secret, staged one deploy ahead across several instances. At most three, each 32 bytes and none equal to `session_secret`. Remove a leaked one immediately ([ADR 225](../adr/225-a-fallback-session-secret-opens-and-never-seals.md), [guide](../guide/sessions.md#rotating-the-secret)) |
| `session_plain_name` | `false`: also read a session cookie named `session`, after `__Host-session`. A sibling subdomain can plant that name, so it is off unless the session is set with a `domain`, a `path` other than `/` or `secure = false` (which cannot carry the prefix, and whose `set` fails without this), or the program is upgrading from 0.6.0, for as long as its longest `max_age` ([ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md), [guide](../guide/sessions.md#the-__host--cookie-name)) |
| `tls` | `null`. `.{ .cert = "…pem", .key = "…pem" }` serves HTTPS (TLS 1.3) on a build that passed `.tls = true` to the dependency (`-Dtls` in this repository); any other build refuses it at `listen()`. In a build that also passed `.http2 = true` the handshake offers `h2` and `http/1.1` by ALPN, `h2` first, and the connection is served as what was chosen; a client that sends no ALPN is served HTTP/1.1, one that offers ALPN with neither protocol gets RFC 7301's `no_application_protocol` alert, and without the flag only `http/1.1` is offered ([ADR 259](../adr/259-http2-is-a-framing-of-every-request.md)). Both files are read before the port is taken, and a key that does not belong to the certificate is refused there, instead of failing every handshake later ([ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)). In that build it costs 560 KB of binary and a page per idle connection, about 300 µs of CPU per handshake with an ECDSA certificate and 2.6 ms with an RSA-2048 one, and it has not been audited; a proxy in front is still the recommendation ([ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md), [deploying](../guide/deploying.md#tls-without-a-proxy)) |
| `also` | `&.{}`: more addresses to answer on, each `.{ .address, .port, .tls }` and nothing else. One server, one route table, one thread pool; a request is told its listener's number (`c.listener()`) and a route can be bound to some (`app.onListener`), and `max_connections` counts sockets across all of them. It is meant for a cleartext port next to a TLS one, or a gRPC port next to an HTTP one. Costs 82 KB of resident memory per extra listener on sixteen threads, and nothing per connection or per request ([ADR 213](../adr/213-a-server-answers-on-more-than-one-address.md), [ADR 252](../adr/252-a-request-knows-which-listener-it-came-in-on.md)) |
| `block_warning_ms` | `250`: logs a warning when a handler holds its thread this long. `0` turns it off |
| `log` | `.{ .format = .text, .level = std.log.default_level }`: how a log line is written and the lowest level written, **at run time**, so a deployment sets them from `nilo_config`. `.format = .json` writes one object a line (`time`, `level`, `scope`, `msg`, `request`) and wants `nilo.logFn` in the root `std_options`, which `listen()` says when it is missing. `std_options.log_level` stays the comptime ceiling and `.level` filters inside it ([ADR 262](../adr/262-a-log-line-has-one-sink.md)) |
| `password_hashes_at_once` | `8`: password hashes run at once through `c.hashPassword` and `c.verifyPassword`. Past it, a sign-in waits its turn instead of failing. Limits concurrency, not the queue ([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)) |

**`arena_keep` is the option in this table with a cliff.** A response larger than it does not fit in what the arena keeps, so the block goes back to the operating system after every request, and the next request faults it back in one page at a time: 257 minor faults for a megabyte, with the kernel zeroing each page. A server that builds large responses in `c.arena()` should set this just above the largest of them, and no higher, because the memory is held **per connection**: a megabyte here across ten thousand connections is ten gigabytes ([ADR 075](../adr/075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)). The default is right for a server whose responses fit in 16 KiB.

**Each of the four timeouts bounds one wait for the network, not a whole request**, so a long upload or an hour-long stream is not cut short by any of them. `0` turns one off. See [Deploying](../guide/deploying.md#deadlines). What happens when each limit in this table is reached (the status and the log line) is one table under [When a bound is hit](../guide/deploying.md#what-happens-at-each-limit).

Past `max_connections`, a connection is accepted and closed immediately, with no request read and no status sent ([why](../guide/deploying.md#how-many-connections-at-once)).

### `metrics` options

`app.metrics(.{ … })`, all `comptime`.

| | Default |
|---|---|
| `path` | `"/metrics"`: an ordinary route, so middleware in front of it applies |
| `buckets` | `100, 500, 1_000, 5_000, 10_000, 50_000, 100_000, 1_000_000`: latency boundaries in microseconds, in increasing order. Reported in seconds |

**What the page shows:** `nilo_requests_total{method,route,status}` by status class, `nilo_request_duration_seconds` as a histogram, `nilo_responses_total` by exact code for the whole process, `nilo_requests_in_flight`, and anything given to `app.expose`.

Requests are counted per **route**, not per path: `/users/1` and `/users/2` both count as `/users/:id`. Five slots are not routes: `<unmatched>`, `<method not allowed>`, `<shed>`, `<static file>` and `<unparsed>`. A route that has answered nothing has no series at all. See [Metrics](../guide/metrics.md).

### `compress` options

`app.compress(.{ … })`.

| | Default |
|---|---|
| `min_bytes` | `1024`: bodies shorter than this are sent uncompressed |
| `max_bytes` | `1048576`: bodies longer than this are sent uncompressed, because gzipping runs whole on the executor thread (about 7 ms a megabyte at `.default`, 2.4 ms in a libdeflate build). `0` means no limit |
| `level` | `.default`, zlib's level 6. `.fastest` is level 1, `.best` is level 9; in a libdeflate build, levels 1, 6 and 7 |

A 206, a 416, a `Content-Range` and `Cache-Control: no-transform` are never compressed, and a strong `ETag` becomes weak when the body is ([ADR 211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)).

**What it costs:** one compressor per thread, about 288 KB each, created when the middleware chains are resolved; one arena allocation for each compressed response; and tens of microseconds of gzip per body (`zig build bench-compress` has the table). Nothing per connection, and nothing on a response that is not compressed ([ADR 211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)).

**Which deflate** is the build's: the standard library's by default, and [libdeflate](https://github.com/ebiggers/libdeflate) when the dependency is given `.libdeflate = true` (`-Dlibdeflate` in this repository), for responses and static files alike. The options, their defaults and which bodies are compressed are the same in both; the libdeflate build gzips in a quarter to a third of the time, holds a compressor in one mapping kept off huge pages (8 KB resident until it is first used, about 229 KB after), and costs about 42 KB of binary. It links no libc ([ADR 248](../adr/248-gzip-is-libdeflate-when-a-build-asks-for-it.md)).

### `trace` options

`app.trace(.{ … })`. The text is borrowed and has to outlive the App.

| | Default |
|---|---|
| `service` | required: `service.name`, what every span is filed under |
| `endpoint` | `"http://localhost:4318"`: the OTLP/HTTP receiver. `/v1/traces` is added |
| `headers` | `&.{}`: sent with every export, a vendor's key mostly. At most 16 |
| `resource` | `&.{}`: `nilo.trace.Attribute`s (`.key`, `.value`) beside `service.name`, such as `deployment.environment.name` |
| `sample` | `1.0`: the fraction of traces that start here to record, decided from the trace id. A request that joined a trace follows the trace's decision |
| `join` | `true`: a request with a valid `traceparent` joins that trace. `false` starts a new one for every request |
| `flush_ms` | `1000`: how often the exporter sends what the rings hold |
| `spans_per_thread` | `1024`, rounded up to a power of two: finished spans each thread holds before the next is dropped. A span is about 200 bytes |
| `max_batch` | `512`: the most spans one export carries |
| `timeout_ms` | `10000`: how long one export may take |

**What a span carries.** A server span is named `METHOD /route` (the method alone when no route matched) with `http.request.method`, `http.route`, `http.response.status_code` and `url.path` (cut at 96 bytes); a 5xx is an error with `error.type`. A client span is named for its method, with `http.request.method`, `server.address`, `server.port`, `http.response.status_code`, and the error's name when the call failed; a 4xx is an error too. The resource has `service.name` and `telemetry.sdk.name = "nilo"`.

**What it costs:** two clock reads, two ids from a generator per thread, one walk of the request headers and a copy into this thread's ring per request; no allocation and no lock. One ring per thread and one batch, held for the life of the App. A full ring drops new spans and counts them, and an export that fails drops its batch; a receiver that cannot be reached is logged at most once a minute. What is left when the server stops is sent on the way out ([ADR 247](../adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)).

## Concurrency

| | |
|---|---|
| `nilo.Mutex` | `.init`, then `try lock()`, `unlock()`, `tryLock()`, `lockUncancelable()` |
| `nilo.blocking(f, args)` | runs a blocking call off the event loop. A call that finds no idle worker starts one, up to the pool's ceiling (twice the logical CPUs), and past it waits its turn ([ADR 013](../adr/013-handlers-must-not-block-the-thread.md#how-the-pool-grows)) |
| `nilo.blockingReserved(f, args)` | the same, on a thread of its own even past the pool's ceiling, where a plain call would wait for a worker, for a caller holding a connection or a lock. Every call that finds no idle worker starts one, so its callers must already be bounded ([ADR 064](../adr/064-a-file-has-no-socket-to-wait-on.md#a-statement-under-hop-gets-a-thread-of-its-own)) |
| `nilo.Gate` | `.open(n)`, then `try enter()` or `try enterWithin(ms)`, and `leave()`: a lock that lets `n` callers through and serves the rest in arrival order. `enterWithin` gives up with `error.TimedOut`, holding nothing ([ADR 222](../adr/222-a-gate-serves-its-waiters-in-the-order-they-came.md)) |
| `nilo.sleep(ms)` | waits without blocking the thread. In spawned work (`spawn`, `spawnLocal`, and so gRPC calls), `error.Canceled` at once for as long as the server is cancelling it, so a cancel the work swallowed cannot keep the server from stopping; an HTTP/1.1 request draining during a stop keeps its wait. Only `sleep` does this: spawned work that catches `error.Canceled` and carries on puts it back with `nilo.io().recancel()`, or its next queue, lock or S3 call waits through the stop ([ADR 028](../adr/028-a-spawned-fiber-belongs-to-the-server.md#a-swallowed-cancel-does-not-keep-the-server)) |
| `nilo.spawn(f, args)` | runs something that is not a request, now. `error.NoServer` if nothing is listening |
| `app.spawn(f, args)` | the same fiber, registered before the server starts and started once it is up ([the guide](../guide/background.md)) |
| `nilo.io()` | the server's `std.Io`, for a spawned fiber that waits on a queue a handler fills ([ADR 244](../adr/244-a-handler-is-given-the-loop-it-runs-on.md)) |
| `nilo.randomSecure(&buf)` | fills a buffer you already hold, off the event loop |
| `nilo.verifyPassword(gpa, stored, text)` | `c.verifyPassword` with no request in hand: the same Gate and pool, or inline with no loop ([`nilo_pw`](./pw.md)) |
| `nilo.monotonicNanos()` | a clock reading, for measuring durations |

**`lock()` and `sleep()` fail with `error.Canceled` if the request went away**, which becomes a 503. `lockUncancelable()` cannot fail and cannot be interrupted. It is for a cleanup path: one that has nowhere to report a failure, and would leave something unreleased if it gave up ([ADR 082](../adr/082-a-cleanup-path-is-not-cancellable.md)). Use it only for a short section that does not itself wait; `lock()` is still the default choice.

**`nilo.blocking` bounds the calls it runs, not the threads a call starts.** A function handed to it that spawns threads of its own is outside the pool's count, so bounding that fan-out is the caller's ([the guide](../guide/services.md#a-blocking-call-that-fans-out)). The call returns what the function returns, errors included; an error carries only its name, so a failure with data in it is returned as a value ([the recipe](../guide/services.md#a-failure-that-carries-data)). `nilo.Mutex` works from a blocking worker as from a fiber ([shared state](../guide/services.md#state-shared-between-fibers-and-blocking-workers)).

## Static options

`app.staticWith(prefix, dir, …)`:

| | Default |
|---|---|
| `index` | `"index.html"` |
| `cache_control` | `"public, max-age=3600"` |
| `cache_rules` | none. A list of `.{ .prefix, .suffix, .cache_control }`, the first match by a file's path in the tree giving its header instead of `cache_control` |
| `spa_fallback` | `""` (off) |
| `spa_fallback_for` | `.navigations`, or `.any_path`, which was the behaviour before 0.2.0 |
| `max_file_bytes` | `8 * 1024 * 1024` |
| `max_total_bytes` | `64 * 1024 * 1024` |
| `dotfiles` | `false` |
| `reload` | `false`. When true, holds nothing and opens every file per request |
| `follow` | `false`. When true, keeps the files in memory and reads the directory again when it changes ([ADR 277](../adr/277-a-static-directory-can-follow-the-disk-and-a-response-finishes-on-the-tree-it-began-on.md)) |
| `follow_poll_ms` | `1000`. How often a followed directory is looked at where the OS raises no event |
| `compress` | `true`. Gzip every file worth it once at load |
| `precompressed` | `true`. A `.br` or `.gz` beside a compressible file is served as its coding |

**A name on disk is matched as a browser sends it, and a symlink is never served.** A request for `/caf%C3%A9.png` finds `café.png`, and a path that decodes to an escaped `/`, a NUL, a backslash or a `.` or `..` segment finds nothing. The directory walk skips symlinks and names them in one startup warning; a spilled file, and every file under `reload`, is opened with `O_NOFOLLOW` and answers 404 if it became a link. A `FileBody` an application returns still follows links ([ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)).

**`precompressed` serves what the build already compressed** ([ADR 273](../adr/273-a-file-a-build-compressed-is-served-as-the-coding-of-the-file-beside-it.md)). `app.js.br` and `app.js.gz` beside `app.js` (any type `compressible` accepts) answer a client whose `Accept-Encoding` prefers them: the highest `q`, `br` on a tie, never one at `q=0`. A `.gz` replaces the gzip copy nilo would make; a `.br` leaves it. Each form has its own ETag, a file with more than one form sends `Vary: Accept-Encoding` on every answer, `Content-Length` is the form's length, and a request with `Range` gets the plain bytes. **The siblings are not files**: `/app.js.br` is a 404, and a sibling not smaller than its file, (for `.br`) older than it, or (for `.gz`) not a gzip of its bytes is ignored with one warning. A file over `max_file_bytes` takes its siblings from the disk. `.precompressed = false` lists them as ordinary files.

**`spa_fallback_for` decides which requests the fallback answers.** `.navigations` means a `GET` or `HEAD` with `Sec-Fetch-Mode: navigate` or, when the header is absent, an `Accept` that lists `text/html`; `*/*` alone, no `Accept` and every `fetch` are not, and get a 404 naming the path. The path is never read. `static.navigational(.{ .accept, .fetch_mode })` is the test. See [Static files](../guide/static-files.md#the-spa-fallback).

**`max_file_bytes` is a threshold, not a limit.** A file over it is listed but not read into memory, and each request opens it and sends it from disk: no gzipped copy, an ETag made from the modification time and size, and one file descriptor for as long as the response takes. `max_total_bytes` counts only the bytes held in memory. See [Static files](../guide/static-files.md#large-files-served-from-disk).

Both the length and the ETag of a file served from disk come from one look at the descriptor whose bytes are about to be sent, so editing a file under a running server cannot serve a stale length under a stale tag ([ADR 098](../adr/098-a-file-is-described-by-the-descriptor-being-sent.md)).

**`cache_rules` is settled while the files load.** A rule matches a file's path in the tree (relative, forward slashes, no leading `/`) by `.prefix` and `.suffix`, both of which must hold and an empty one holds for every file; the first rule a file matches wins and an empty `.cache_control` leaves the header off. A request does no matching: the result is the header each file already carried ([Static files](../guide/static-files.md#one-tree-two-cache-policies)).

`app.embeddedWith(prefix, files, …)` takes `index`, `cache_control`, `cache_rules`, `spa_fallback`, `spa_fallback_for`, `compress`, `compress_min_bytes` and `precompressed`, with the defaults above, and none of the others: nothing in the binary is served from disk, there is no total to exceed, every name was written by the caller, and there is no disk to reload from.

**`embedDir(b, nilo_http, dir)` is a function of nilo's `build.zig`**, imported by a dependent as `@import("nilo").embedDir`. It walks `dir` (relative to the build root, or absolute) when the build is configured and returns a module exporting `files`, an array of `static.Embedded`, to hand to `app.embedded("/", &frontend.files)`. Regular files only, a `.` segment and symlinks left out, an empty directory stops the build ([ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md), [Static files](../guide/static-files.md#a-vue-or-react-build-in-the-binary)). A path listed twice, and a fallback that names no entry, are refused at startup ([ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)).

### `nilo.app`

**`nilo.app(b, options)` is a function of nilo's `build.zig`**, imported by a dependent as `@import("nilo").app`, that writes the whole `build` of a server ([ADR 263](../adr/263-a-first-project-is-one-call-from-its-build-file.md), [Getting started](../guide/getting-started.md#add-it-to-a-project-you-already-have)).

```zig
const nilo = @import("nilo");
pub fn build(b: *std.Build) void {
    _ = nilo.app(b, .{ .name = "hello", .root = b.path("src/main.zig") });
}
```

| `nilo.AppOptions` field | |
|---|---|
| `.name` | the executable's name |
| `.root` | a `LazyPath` to the file with `main` |
| `.target`, `.optimize` | read from `-Dtarget` and `-Doptimize` when null; the mode passes unchanged to the dependency, the executable and the test |
| `.sql` | imports `nilo_sql` and fetches its drivers (`-Dsql`, [ADR 066](../adr/066-a-lazy-dependency-is-a-request.md)) |
| `.tls`, `.http2`, `.libdeflate` | the dependency's flags of the same names, each off until set |
| `.tls_module` | a `*std.Build.Module` of your own tls.zig, in place of nilo's pin; implies `.tls` ([below](#a-tls-library-of-your-own)) |

It imports `nilo_http` into the root module, installs the executable, and adds the steps `run` (arguments after `--` reach the server), `dev` (the restart on every save of [ADR 190](../adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md), where `-D` options and `--no-incremental` go after `--`) and `test` (the root module's tests). It returns `nilo.AppBuilt`: `.exe` and `.tests` (the compile steps), and `.dependency`, the `nilo` dependency it fetched, from which `module("nilo_id")` or any other module is taken without a second instance. Every field of `AppOptions` after `.root` has a default, so a field added later changes no project already written.

**`follow = true` keeps the held copies and follows the disk**: the directory is read again, as one new generation, when a file, a sibling or a name changes, and a response in flight finishes on the old one. A tree that fails to read keeps the last good one. One thread and one `inotify` descriptor per followed directory; `follow` with `reload` serves every file from disk and follows the names.

**`reload = true` is the same as `max_file_bytes = 0`**: nothing is held, every file is opened per request, and edits show up without a restart. It is for development, since it gives up the in-memory and gzipped copies. A file that did not exist at startup still needs a restart, because the list of names comes from the directory walk at startup.

## A TLS library of your own

Pass `.tls = true, .tls_own = true` to `b.dependency("nilo", …)` (or `.tls_module = …` to `nilo.app`) and nilo's pin of tls.zig is neither fetched nor built; the `tls` import is yours to write, on the module nilo exports ([ADR 274](../adr/274-a-dependent-can-bring-its-own-tls-library.md)):

```zig
const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .tls = true, .tls_own = true });
const tls = b.dependency("tls", .{ .target = target, .optimize = optimize });
nilo.module("nilo_http").addImport("tls", tls.module("tls"));
```

Setting the option and leaving the line out stops the build with an error that names it. `.tls_own` without `.tls` is refused at configuration.

**The surface nilo uses** is all `http/engine/zio.zig` asks of the module, and a module is compatible if it has it. A missing name fails to compile at its use in the Engine.

| name | used for |
|---|---|
| `config.CertKeyPair` | `fromFilePath(gpa, io, dir, cert, key)`, `deinit(gpa)`, `.bundle.bytes` and `.key` (its `signature_scheme` and per-scheme public key) for the key check at `listen()` |
| `config.Server` | `.auth`, `.now`, `.rng`, `.alpn_protocols`, `.offload` |
| `config.Offload` | `.{ .run = fn }`, the signature on the blocking pool ([ADR 217](../adr/217-a-handshakes-signature-is-computed-off-the-executor.md)) |
| `server(reader, writer, config.Server)` | the handshake, returning a connection |
| `input_buffer_len`, `output_buffer_len` | the record buffers |
| the connection | `reader(buf)`, `writer(buf)`, `cleartext_buf`, `alpn_protocol`, `close()` |

The pin in `build.zig.zon` is the commit this is tested against, with the `offload` option and the RSA signing fix; an upstream release that has both is a drop-in.

## OpenAPI options

`app.docs(…)`:

| | Default |
|---|---|
| `title` | `"API"` |
| `version` | `"1.0.0"` |
| `description` | `""` |
| `path` | `"/openapi.json"` |
| `ui_path` | `"/docs"`. Empty for none |

**A type with a `jsonStringify` is described by a marker, not by its fields**, because `std.json` calls the function and never reads the fields, so describing them would describe something the server does not send ([ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)):

```zig
pub const nilo_openapi = .{ .type = "string", .format = "uuid" };
```

`type` is required (`"string"`, `"integer"`, `"number"` or `"boolean"`), and `format` is an optional hint. nilo's own types already carry it (`Uuid`, `Timestamp`, `Decimal`, `Interval`, `Inet`). A type with a custom writer and no marker is described as `{}` with a description saying so.

### The document without a server

**`app.writeOpenApi(w)` writes the same bytes `/openapi.json` serves**, to any writer, with **no port, no database and no network** ([ADR 135](../adr/135-the-document-is-a-build-artefact.md)):

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

Call it after the routes are registered and before `listen`. The operations are collected as each route is registered, so nothing has to be started.

**You do not have to call `app.provide`**, which keeps the build step's binary free of everything else. `provide` is for handling requests; writing the document needs only the operations, so a program that only writes it links no database driver and needs no placeholder `*Db` to get route registration past the type checker.

**Register the routes in one place that both programs use.** A `routes.zig` that `main.zig` and the document step both call follows the same reasoning as `buildDocs` going through this method instead of a separate path: two route lists is how a checked-in contract starts describing a server that no longer exists, and a route somebody forgets to add to the second list disappears with no error and no failing test.

**This makes the document a build artefact, not something you fetch with curl.** A checked-in `openapi.json` is how a typed frontend client is generated and how a breaking change shows up in review. Producing it by booting a server means `listen`, which means `db.checking`, which means a migrated database, so a file describing some types would end up needing Postgres. `zig build openapi > openapi.json` needs none of that.

The title and version come from `app.docs(.{ … })` if it was called, and default to `"API"` / `"1.0.0"` if not, so a program that serves no document can still write one. The served copy goes through this same call, which is what stops a checked-in file and a running server from describing two different APIs.
