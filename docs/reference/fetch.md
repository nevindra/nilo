# nilo_fetch

**`nilo_fetch` is an HTTP client for calling somebody else's API from inside a request, with the limits a server needs.**

**Guide:** [Calling somebody else's API](../guide/fetch.md) · **Design:** [Outbound calls](../design/fetch.md)

## `nilo_fetch`

An HTTP client for calling somebody else's API from inside a request. It is a **Fitting**: it borrows the event loop and owns no destination ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

The client underneath is `std.http.Client` (connection pool, HTTP/1.1, TLS). This module adds the policy a server needs and a script does not, in about sixty lines.

```zig
const fetch = @import("nilo_fetch");

var api: fetch.Client = .init(gpa, .{});
try app.provide(&api);

fn charge(api: *fetch.Client, c: *nilo.Ctx) !Receipt {
    const res = try api.postJson(c, "https://api.example.com/v1/charges", .{ .amount = 500 }, .{});
    if (res.status == .too_many_requests) return nilo.fail.status(503, "retry after {s}", .{res.header("retry-after") orelse "a while"});
    if (!res.ok()) return nilo.fail.status(502, "the payment service said no", .{});
    return res.json(Receipt, c);
}
```

### `fetch.Client` calls

| Call | |
|---|---|
| `client.get(c, url, .{})` | `Response` |
| `client.post(c, url, body, .{})` | `Response` |
| `client.put(c, url, body, .{})` | `Response` |
| `client.delete(c, url, .{})` | `Response` |
| `client.patch(c, url, body_or_null, .{})` | `Response`. `null` for an endpoint whose whole request is its path |
| `client.send(c, method, url, body_or_null, .{})` | for a method the five above do not cover. **The body decides the framing, not the method** ([ADR 174](../adr/174-the-body-decides-not-the-method.md)): a DELETE with a body sends it with its `content-length`, and a POST with `null` sends `content-length: 0`. `error.HeadTooLong` means a body on a method std sends none for, whose head did not fit the connection's buffer |
| `client.postJson(c, url, value, .{})` | `Response`: `value` written with `std.json` into the Scope and sent as `content-type: application/json`, unless `headers` names a content type. `putJson`, `patchJson` and `sendJson(c, method, url, value, .{})` work the same way. Passing text here is a Refusal, because it would be sent as one JSON string ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)) |
| `client.postForm(c, url, fields, .{})` | `Response`: `fields` written as an `application/x-www-form-urlencoded` body and sent with that `content-type`, unless `headers` names one. The field types, the null that leaves a field out and the Refusals are `withQuery`'s, naming a form field. A space is `+` and a literal `+` is `%2B`, where a query string says `%20`. `putForm` and `sendForm(c, method, url, fields, .{})` work the same way. Text here is a Refusal ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)) |
| `fetch.formBody(c, .{ .grant_type = "client_credentials" })` | `[]const u8`: the form body alone, in the Scope, one allocation of exactly the right size, for `post` with a `content-type` of your own |
| `fetch.basicAuth(c, id, secret)` | `[]const u8`: the `authorization` value `Basic …` the OAuth way, with the id and the secret form-encoded before they are joined with `:` and base64-encoded (RFC 6749 §2.3.1), so a secret with a `+`, a `:` or a space reaches the provider as it was written. Pass it as `.headers = &.{.{ .name = "authorization", .value = value }}` |
| `fetch.withQuery(c, base, .{ .page = 2, .q = "a b" })` | `[]const u8`: `base?page=2&q=a%20b`, in the Scope, one allocation of exactly the right size. A field may be an int, a bool, text, or an optional of one (null is left out); anything else is a Refusal naming the field. Uses `&` after a base that already has a `?` ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)) |
| `res.ok()` | `bool`: a 2xx status |
| `res.status` | `std.http.Status` |
| `res.body` | `Str`, in the Scope you passed. Freed when the request ends |
| `res.headers` | `[]const u8`: the header block the response arrived with, kept in the Scope ([ADR 187](../adr/187-a-head-that-outlives-its-body.md)) |
| `res.header(name)` | `?[]const u8`, case-insensitive; null when the response did not have it. For example `Retry-After` on a 429, `ETag` for the next conditional GET, `Location` on a 201 |
| `res.json(T, c)` | `T`, parsed into the same Scope |

`c` is a Scope: the `*Ctx` a handler was given, or a `nilo.Run` where there is no request. Passing anything else is a Refusal naming the call.

### `Client.Settings`

Given to `init`:

| Field | Default | |
|---|---|---|
| `max_in_flight` | 32 | calls at once, across every host. Past this, a caller waits for a permit instead of opening another connection. An HTTPS connection holds 59,151 bytes |
| `timeout_ms` | 30,000 | how long one whole call may take. `0` means no limit. **The shorter of this and the time the Scope's route has left**, if it has a [deadline](./middleware.md#nilodeadline): the call is `error.TimedOut` when either runs out, and a request whose time has already passed (including time spent queued for a permit) fails without dialling ([ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)). A `nilo.Run` has no deadline. It works with or without an Engine: under `listen()` the Engine cancels the fiber; on a client started with `nilo_start(io, .none)`, each step of the call runs as a task of that `Io` and the task is cancelled, which costs one thread hop per step, only in that case ([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)) |
| `stall_ms` | 0 | how long the other side may send **nothing** before the call fails with `error.Stalled`: time since the last byte, not since the call began. `0` means no such limit. While a `.stream` body goes out, every chunk the source hands over counts as a byte, since nothing arrives from the peer meanwhile. Works together with `timeout_ms`; the Engine's timer is re-armed on every chunk, or without an Engine the wait is measured from the last byte ([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)) |
| `max_body` | 8 MiB | a longer body fails with `error.BodyTooLarge`, checked while reading |
| `max_drain` | 64 KiB | how much of an unread body to read in order to keep a pooled connection. Past this the connection is dropped |
| `read_buffer_size` | 8 KiB | each connection's socket read buffer, and therefore how much one read brings in. std's default, passed through ([ADR 186](../adr/186-the-transfer-buffer-serves-nothing-here.md)) |
| `forward_request_id` | true | a call made under a `*Ctx` sends the request's id as `X-Request-Id`, so the other side's logs line up with yours. A `Run` has no id and sends none; a call that sets its own `X-Request-Id` in `headers` keeps it ([ADR 158](../adr/158-a-request-id-goes-out-with-the-call.md)) |

### `Client.Call`

Given per call: `headers`, and `timeout_ms` / `stall_ms` / `max_body` to override the settings above for one call. **A header std has its own slot for** (`host`, `authorization`, `user-agent`, `content-type`, `connection`, `accept-encoding`) **is sent once**: your copy replaces std's instead of being sent beside it ([ADR 182](../adr/182-a-header-std-owns-goes-out-once.md)).

### A call under a traced request

**On an App that calls `app.trace`, a call made under a `*Ctx` is a client span, and it sends `traceparent`** naming that span, plus the `tracestate` the request arrived with. The span has the method, `server.address`, `server.port`, the status, and the error's name when the call failed. A call that sets its own `traceparent` in `headers` keeps it, and no span id is sent for it. A `Run` declares no trace and sends none. An `Exchange` sends only the headers it is given, as it does for the request id ([ADR 158](../adr/158-a-request-id-goes-out-with-the-call.md)), so a signed `nilo_s3` request is not traced. A Scope of your own joins by declaring `traceBegin(self) ?core.trace.Outbound` and `traceEnd(self, core.trace.Outbound, core.trace.Ended) void` ([ADR 247](../adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md), [Tracing](../guide/tracing.md)).

### Redirects

**`Client.get` and the calls beside it follow up to three redirects, and what they send does not follow the call to another origin.** A change of scheme, host or port is another origin ([ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)). Past one, the `authorization`, `cookie`, `proxy-authorization` and `www-authenticate` lines, the `host` the call named, and every standing header of a `Target` are not sent; a hop from `https` to `http` is `error.InsecureRedirect`. Inside one origin everything goes along. A 303, and a 301 or 302 on a POST, become a GET without a body; any other redirect of a call that has a body is `error.RedirectRequiresResend`. `Response.redirected` is the URL the call ended at (without userinfo or fragment), in the Scope, or null when it was not redirected.

### Responses with no body

**A response that has no body by definition ends at its head.** A response to HEAD, a 1xx, a 204 and a 304 are complete at the blank line whatever `content-length` or `transfer-encoding` say, so `send` returns an empty body immediately and the connection is kept ([ADR 176](../adr/176-an-answer-with-no-body-ends-at-its-head.md)).

### Errors

**Each error means one thing.** `error.TimedOut` is this call's own deadline. `error.Stalled` is `stall_ms` passing with nothing arriving while the other side keeps the socket open. `error.Canceled` is the server shutting down underneath the call. The three are kept distinct instead of guessed at. `error.RedirectRefused` is a 3xx with a `Location` under an `Exchange` that did not choose a redirect policy (`Client.get` and the other calls above do follow redirects). `error.InsecureRedirect` is a followed redirect that led from `https` to `http`: it is not followed. `error.NotStarted` is a call made before `listen()`; the client is finished at startup like any other service.

**A 4xx or 5xx is a `Response`, not an error.** The call worked and the service said no; only the caller knows which of those matters.

### Compression

**The body is requested uncompressed.** `send` sends `Accept-Encoding: identity`, so `res.body` is the body and not a gzip stream. This differs from `std.http.Client`'s default, which advertises gzip and then returns the compressed bytes from `Response.reader`: decompressing is a separate call there, and a caller who forgets it gets unreadable bytes and no error. Decompressing here would cost a 32 KiB flate window on the handler's stack, which is held per *connection* ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)), so identity is the trade taken. A server that ignores the header and sends gzip anyway causes an error, not a `Str` full of noise.

`examples/outbound/` shows all of this against a real API, and [`bench/result/fetch.md`](../../bench/result/fetch.md) has the cost on each of ADR 017's four axes.

### What it does not do

**An answer sent before the body was finished is the answer.** When writing a large body fails because the server refused it on the head and closed, `begin` returns that refusal (a 4xx or 5xx) rather than `WriteFailed`, and the connection is not reused. A 2xx in that position is not taken, since the server never received the whole upload.

**No retry policy, circuit breaker or rate limiter.** Those are decisions about somebody else's service, and belong to whoever knows what that service promises.

### `fetch.Target`

**A service's base URL, standing headers and limits, as a type of its own**, opened once on the client and asked for by type. Two services are two types ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

const Stripe = fetch.Target("stripe", .{ .timeout_ms = 5_000, .max_in_flight = 8 });

fn charge(stripe: *Stripe, c: *nilo.Ctx, charge_id: nilo.Str) !fetch.Response {
    return stripe.get(c, "/v1/charges/{}", .{charge_id}, .{});
}
```

| | |
|---|---|
| `fetch.Target(name, .{…})` | a type. `name` tells two targets with the same options apart, and is what the health route calls it; an empty name is a Refusal |
| `Stripe.open(&client, .{ .base, .authorization, .user_agent, .headers })` | `error.BaseNotAbsolute` for a base with no scheme or host, `error.BaseHasQuery` for one with a `?` or `#`; a trailing `/` is dropped. Every value is held, not copied |
| `app.provide(&stripe)` | starts the client under it at `listen()`; the client itself is provided only if a handler asks for it by that type |
| `stripe.get(c, path, args, .{})` | `Response`. Also `post(c, path, args, body, .{})`, `put`, `delete`, `patch(c, path, args, body_or_null, .{})`, `send(c, method, path, args, body_or_null, .{})`, `postJson(c, path, args, value, .{})`, `putJson`, `patchJson`, `sendJson`, `postForm(c, path, args, fields, .{})`, `putForm`, `sendForm`: every call the client has, with a path instead of the URL and the same `Call` last |
| `stripe.url(c, path, args)` | `[]const u8`: the URL alone, in the Scope, one allocation of exactly the right size, for an `Exchange` begun on the client |
| `stripe.nilo_ready(scope)` | ready once started, unless the type names a `ready` path, which is then fetched with GET on every probe, and anything but a 2xx is reported |

**`fetch.target.Options`**, on the type: `max_in_flight` (0 means no limit of its own; otherwise this service's own semaphore, taken before the client's and released after), `timeout_ms`, `stall_ms`, `max_body` (each null to use the client's, and a `Call` can still override them for one call), and `ready` (null, or a path starting with `/`).

**`path` is a template known at compile time.** `{}` is filled by position from a tuple (`"/repos/{}/{}", .{ owner, name }`), and the count is checked. `{name}` is filled from the struct field of that name, and **every field the template does not name becomes a query param** under `withQuery`'s rules: `"/v1/charges/{id}/refunds", .{ .id = id, .limit = 10, .cursor = cursor }`, with a null cursor left out. A segment may be an int, a bool or text, and `/` inside it is encoded as data. Each of these is a Refusal: a count that does not match, a name with no field, a tuple for a named segment, a struct for a positional one, a template mixing the two, a segment of another type, and a path that does not start with `/`.

**Standing headers, and a call's headers over them.** `authorization` and `user_agent` use std's slot; a line in `Call.headers` naming either replaces it ([ADR 182](../adr/182-a-header-std-owns-goes-out-once.md)). A line naming any other standing header overrides it. There is no allocation unless a call with its own headers meets a target that also has some, and then there is one.

### `fetch.Exchange`

**An `Exchange` is for a body too large to hold in memory.** The calls above hold the whole body in the Scope, which is right for an API that answers with JSON and wrong for anything measured in megabytes. An `Exchange` applies the same policy but leaves the body on the socket: **read the response head, decide, then move the bytes somewhere that is not memory.**

```zig
var ex: fetch.Exchange = .idle;
defer ex.end();

const head = try ex.begin(client, .{ .method = .GET, .url = url });
if (head.content_length) |n| if (n > ceiling) return error.TooLarge;
_ = try ex.pipe(&body.writer);   // straight out, allocating nothing
```

| | |
|---|---|
| `ex.begin(client, .{…})` | `Head`: status, `content_length`, `content_type`, `header(name)` (case-insensitive), `ok()`, and `redirected` / `location(&buf)`: the `std.Uri` a followed redirect ended at, or null, and the same as one string. Its text lives in the `.follow` buffer the call was given ([ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)) |
| `head.keep(c)` | the same `Head` copied into the Scope, valid after the body is read: one arena allocation the size of the header block ([ADR 187](../adr/187-a-head-that-outlives-its-body.md)) |
| `ex.take(c, max)` | the rest of the body as a `Str` in the Scope, refusing anything over `max` |
| `ex.readInto(buf)` | exactly `buf.len` bytes, or `error.BodyTooShort` |
| `ex.pipe(w)` | the rest of the body into a `*std.Io.Writer`, and how many bytes |
| `ex.stream(w, limit)` | one chunk into `w`, at most `limit`, and how many bytes; `0` means the end. It is what one socket read delivered, and it runs inside both timeouts, which the same call on `ex.reader` does not |
| `ex.discard()` | "I will not read this body; close the connection", for example after a probe that got the whole file. `max_drain` stays a policy, not a switch ([ADR 184](../adr/184-a-caller-that-knows-says-discard.md)) |
| `ex.end()` | required, and safe to call twice |

**`Begin` options.** `Begin` takes `headers`, `host`, `authorization`, `content_type`, `user_agent`, `timeout_ms`, `route_left_ms` (the Scope's time left from `core.timeLeftOf`, which `Client.send` and the other calls fill in themselves; a caller of `Exchange.begin` with a Scope passes it to get the same narrowing), `stall_ms`, a `body` of `.none` / `.slice` / `.stream`, and `origin_only` (header names that never leave the origin the call was made to, in addition to the credentials above), and `redirects`: `.refuse` (the default; a 3xx with a `Location` fails with `error.RedirectRefused`), `.follow = &buf` (followed up to three deep, resolved in the buffer, and held to the origin rule in [Redirects](#redirects)) or `.expose` (the 3xx returned as it is, which is what a signed request and an S3 client want) ([ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)). A name in `headers` that std has a slot for tells std to leave its slot out, so the line is sent once. The explicit fields are for a caller who has the value but not a whole header line; setting both a field *and* the line sends two lines ([ADR 182](../adr/182-a-header-std-owns-goes-out-once.md)). `transfer_buffer` is only for a caller who reads buffered data from `ex.reader`: `take`, `readInto`, `pipe` and `stream` never fill it, and the empty default is the normal case ([ADR 186](../adr/186-the-transfer-buffer-serves-nothing-here.md)).

**A `.stream` body is sent on a connection no pool held.** It is a reader that cannot be read twice, so it cannot be replayed onto a second connection when the first turns out to be one the server closed while it idled, the case that protects a `.slice` body. Instead it never meets one: the call uses a second std client whose pool keeps nothing, so every streamed body opens a connection (one TCP handshake, plus TLS over `https://`) and closes it after. Calls with a slice, no body or `get` are unchanged, and the second client costs nothing until the first streamed body, when an `https://` call scans the system's root certificates once, as the first call on the main client does.

**Do not copy an `Exchange` once it has begun**, because it holds a `std.http.Client.Request`. Declare it, fill it in place, and leave it there.

### `fetch.testing`

**A canned server for your own test suite**: one real exchange over a loopback socket on `std.Io.Threaded`, with no Engine anywhere. It is what the module's own tests use, exported ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn oneExchange(io: std.Io, gpa: std.mem.Allocator) !void {
    var canned = try fetch.testing.Canned.open(io);
    defer canned.close();
    canned.reply("429 Too Many Requests", "Retry-After: 30\r\n", "slow down");
    var served = try io.concurrent(fetch.testing.Canned.serveOne, .{&canned});
    defer served.cancel(io) catch {};

    var api: fetch.Client = .init(gpa, .{});
    defer api.deinit();
    try api.nilo_start(io, .none);

    var run: nilo.Run = .init(gpa);
    defer run.deinit();
    var buf: [64]u8 = undefined;
    const res = try api.get(&run, try canned.url(&buf), .{});
    try std.testing.expectEqualStrings("30", res.header("retry-after").?);
}
```

| | |
|---|---|
| `Canned.open(io)` | bound to port 0 on loopback, with the port the kernel chose read back, so there is no port range to keep separate from anybody else's |
| `canned.reply(status, headers, body)` | what `serveOne` answers: the status line after `HTTP/1.1 `, headers each ending in `\r\n` (`Content-Length` is written for you), and the body as given |
| `canned.url(&buf)` | `http://127.0.0.1:<port>/` |
| `canned.serveOne()` | accepts one connection, reads the whole request, answers, and closes. **Start it with `io.concurrent`**, never `io.async`, which may run it on your own thread and wait there for the connection you were about to make |
| `canned.request()` | the request head that arrived, one line per header, `\n` between them |
| `canned.requestBody()` | the request body that arrived, up to a kilobyte |
| `canned.close()` | |

The client is finished with `nilo_start(io, .none)`, as `listen()` would have done. `.none` means "no Engine to arm a deadline on", and the client then enforces the timeout itself ([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)).
