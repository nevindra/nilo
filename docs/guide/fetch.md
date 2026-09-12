# Calling somebody else's API

`nilo_fetch` is an HTTP client for the inside of a handler: a payment
provider, a geocoder, a webhook, somebody's JSON API. It is
`std.http.Client` — the pool, HTTP/1.1, TLS — with the policy a server needs
and a script does not put in front of it, in about sixty lines
([ADR 0070](../adr/0070-a-fitting-borrows-the-loop.md)).

It is a **Fitting**: it borrows the event loop and owns no destination. A
`sql.Db` holds a pool to one database named in its URL; a `fetch.Client` is
handed an address on every call and holds no connection to any named system,
which is what lets one client serve every API a program talks to.

```zig
const fetch = @import("nilo_fetch");
```

and in `build.zig`, beside `nilo_http`:

```zig
.{ .name = "nilo_fetch", .module = nilo.module("nilo_fetch") },
```

## One call

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

const Receipt = struct { id: []const u8, amount: u64 };

fn charge(api: *fetch.Client, c: *nilo.Ctx) !Receipt {
    const res = try api.post(c, "https://api.example.com/v1/charges", "amount=500", .{});
    if (!res.ok()) return nilo.fail.status(502, "the payment service said no", .{});
    return res.json(Receipt, c);
}
```

and in `main`, once:

```zig
var api: fetch.Client = .init(gpa, .{});
defer api.deinit();
try app.provide(&api);
```

The client is a [service](./services.md): registered once, asked for by type.
**One is enough for the whole program** — the pool inside it is keyed by
host, so calls to three different APIs share it without knowing about each
other, and a second client would load the certificate bundle a second time.

`c` is a Scope: the `*Ctx` a handler holds, or a [`nilo.Run`](../reference.md#run)
where there is no request — a startup path, a ticker, a test. The body comes
back as a `Str` in that Scope's arena, so it lives exactly as long as the
request does and nothing is freed by hand.

| Call | |
|---|---|
| `api.get(c, url, .{})` | `Response` |
| `api.post(c, url, body, .{})` | `Response` |
| `api.put(c, url, body, .{})` | `Response` |
| `api.delete(c, url, .{})` | `Response` |
| `api.send(c, method, url, body_or_null, .{})` | for a method the four above do not name |

The last argument is a `Call` — per-call overrides, every field null, so
`.{}` is the ordinary case:

| Field | |
|---|---|
| `headers` | `[]const std.http.Header`, written to the wire in this order |
| `timeout_ms` | this call's own deadline, over the client's |
| `max_body` | this call's own body ceiling, over the client's |

## Reading the answer

| | |
|---|---|
| `res.status` | `std.http.Status` |
| `res.ok()` | `bool` — 2xx |
| `res.body` | `Str`, in the Scope's arena. Goes when the request does |
| `res.json(T, c)` | `T`, parsed into the same Scope. Unknown fields are ignored |

**A 4xx or a 5xx is a `Response`, not an error.** The call worked and the
service said no; only the caller knows which of those matters and what to
say about it. The distinction is worth a `switch`, because the far end's
status is not yours to forward:

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

const Repo = struct {
    full_name: []const u8,
    stargazers_count: u64,
};

fn stars(api: *fetch.Client, c: *nilo.Ctx, owner: nilo.Str, name: nilo.Str) !u64 {
    var url: std.Io.Writer.Allocating = .init(c.arena());
    try url.writer.writeAll("https://api.github.com/repos/");
    try nilo.percent.encodeWrite(&url.writer, owner.view(), .unreserved);
    try url.writer.writeByte('/');
    try nilo.percent.encodeWrite(&url.writer, name.view(), .unreserved);

    const res = api.get(c, url.written(), .{
        .timeout_ms = 2_000,
        .headers = &.{.{ .name = "user-agent", .value = "my-app" }},
    }) catch |err| switch (err) {
        error.TimedOut => return nilo.fail.status(504, "github took longer than 2s", .{}),
        else => return err,
    };

    if (!res.ok()) return switch (@intFromEnum(res.status)) {
        404 => nilo.fail.notFound("no repository {s}/{s}", .{ owner.view(), name.view() }),
        403, 429 => nilo.fail.status(502, "github is rate-limiting this address", .{}),
        else => nilo.fail.status(502, "github answered {d}", .{@intFromEnum(res.status)}),
    };

    const repo = res.json(Repo, c) catch
        return nilo.fail.status(502, "github sent something this program cannot read", .{});
    return repo.stargazers_count;
}
```

Three things in there are the habits worth keeping. **Text from a request
going into a URL is percent-encoded**, never pasted — `%2e%2e%2f` in a path
param is how a caller reaches an endpoint you never meant to offer, and
`nilo.percent` is in Core so a handler and a Service can both reach it
([ADR 0066](../adr/0066-percent-is-needed-by-two-layers.md)). **`error.TimedOut`
gets its own arm**, because it is the one failure every caller of anything
has to have an answer for, and 504 says *the thing I asked is slow* where 500
would say *I am broken*. And **the struct you parse into is what your program
depends on**, not a transcription of the far end's schema: `Repo` names two of
GitHub's hundred fields, and the parse ignores the rest.

[`examples/outbound`](../../examples/outbound/main.zig) is that handler with
a `main` around it, against GitHub's public API.

## The client's settings

Given to `init`, once:

| Field | Default | |
|---|---|---|
| `max_in_flight` | 32 | calls at once, across every host. Past it a caller waits for a permit rather than opening another connection |
| `timeout_ms` | 30,000 | how long one whole call may take — connect, send, head and body. `0` is no limit |
| `max_body` | 8 MiB | a longer body is `error.BodyTooLarge`, enforced while reading, so a `content-length` that lies cannot get past it |
| `max_drain` | 64 KiB | how much of an unread body is worth reading to keep a pooled connection. Past it the connection is dropped instead |
| `forward_request_id` | true | a call made under a `*Ctx` carries the request's id as `X-Request-Id`, so the service you called can log the same id you did. Under a `nilo.Run` there is no request and nothing is sent; a call that names its own `X-Request-Id` keeps it ([ADR 0196](../adr/0196-a-request-id-goes-out-with-the-call.md)) |

**`max_in_flight` is the one that is not a nicety.** `std.http.Client`'s pool
bounds *idle* connections and does not bound in-use ones at all, so without
it the ceiling on live connections is however many handlers happen to be
running — and an HTTPS connection holds 59,151 bytes of TLS and socket
buffers. Five hundred concurrent handlers would be 29.6 MB nobody asked for
and five hundred handshakes. Thirty-two times that is the most the client
will ever hold.

**`timeout_ms` bounds the whole call rather than each read**, because a
server sending one byte a second satisfies any per-read limit you care to
name and never finishes. It is the same reasoning the server's own
[deadlines](./deploying.md#deadlines) follow from the other side.

## What it answers instead

| Error | |
|---|---|
| `error.TimedOut` | this call's own deadline ran out |
| `error.Canceled` | the server is shutting down underneath the call. Told apart from `TimedOut` rather than guessed at |
| `error.BodyTooLarge` | the body passed `max_body`, and reading stopped there |
| `error.BodyTooShort` | the body ended before the length its own head announced |
| `error.NotStarted` | a call made before `listen()` — the client is finished at startup like any other service |
| the rest | `std.Uri.ParseError`, `std.http.Client`'s connect and receive errors, and the reader and writer errors, unchanged |

`NotStarted` is the one a unit test meets: a handler called directly, with no
App around it, has a client nobody started. The fix is the same one the
[testing page](./testing.md#two-things-listen-does-that-the-client-does-not)
gives for a database — `app.start(io)` — or a fake in the handler's argument
list, which is what the signature rules are for.

## The body is asked for uncompressed

`send` puts `Accept-Encoding: identity` on every call, so `res.body` is the
body rather than a gzip stream. `std.http.Client` on its own advertises gzip
and then hands back the compressed bytes — decompressing is a separate call
there, and a caller who does not make it gets unreadable bytes and no error.
Decompressing here would cost a 32 KiB flate window on the handler's stack,
which is held per *connection*
([ADR 0063](../adr/0063-a-handlers-stack-is-per-connection.md)), so identity
is the trade taken. A server that ignores the header and gzips anyway is an
error rather than a `Str` full of noise.

## A body too big to hold

The four calls above take the whole body into the Scope, which is right for
an API answering JSON and wrong for anything measured in megabytes. An
`Exchange` is the same policy with the body left on the socket: **read the
response head, decide, then move the bytes somewhere that is not memory.**
What a [body reader](./requests.md#bodies-too-big-to-hold) is for a request
coming in, this is for an answer going the other way.

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn mirror(api: *fetch.Client, c: *nilo.Ctx) !void {
    var transfer: [16 * 1024]u8 = undefined;
    var ex: fetch.Exchange = .idle;
    defer ex.end();

    const head = try ex.begin(api, .{
        .method = .GET,
        .url = "https://example.com/report.csv",
        .transfer_buffer = &transfer,
    });
    if (!head.ok()) return nilo.fail.status(502, "upstream answered {d}", .{@intFromEnum(head.status)});
    if (head.content_length) |n| if (n > 64 << 20) return nilo.fail.status(502, "report too large", .{});

    var body = try c.streamWith(200, head.content_type orelse "text/csv", .{ .length = head.content_length });
    _ = try ex.pipe(&body.writer);
    try body.finish();
}
```

| | |
|---|---|
| `ex.begin(api, .{…})` | `Head` — `status`, `content_length`, `content_type`, `header(name)` case-insensitively, `ok()` |
| `ex.take(c, max)` | the rest of the body as a `Str` in the Scope, refusing over `max` |
| `ex.readInto(buf)` | exactly `buf.len` bytes, or `error.BodyTooShort` |
| `ex.pipe(w)` | the rest into a `*std.Io.Writer`, and how many bytes |
| `ex.end()` | required, and safe twice |

`Begin` takes what a `Call` does and more: `headers`, `host`, `authorization`
and `content_type` — three headers std would otherwise write for itself, which
a signed request has to control — `timeout_ms`, a `body` of `.none`,
`.slice` or `.stream` with a length, and two buffers.

**Everything in `Head` points into the connection's read buffer, and the
first byte of body read overwrites it.** Read what you need — or copy it —
before `take` or `pipe`. That is the bargain a [borrowed row](./sql/raw.md) makes,
for the same reason: the alternative is an allocation per call for text most
callers glance at once.

**The buffers are yours because their cost is yours.** `transfer_buffer` is
what the body moves through; bigger is fewer trips into the connection and
more stack held per connection. An empty `redirect_buffer` — the default —
means redirects are not followed and a 302 comes back as itself, which is the
right answer for anything signed: a signature is computed over one host and
one path, and following a redirect would send the `authorization` header
somewhere it was never meant to go.

**An `Exchange` must not be copied once begun** — it holds a live
`std.http.Client.Request`. Declare it, fill it where it stands, leave it
there. `defer ex.end()` is the line that is not optional: it gives the permit
back and returns the connection to the pool, or drops it if what was left
unread is past `max_drain`.

**A body with no length cannot be sent streamed.** `.stream` takes the
length because HTTP can frame an unknown length only as chunked, and the
services this exists for — S3 among them — answer `411` to that. Not knowing
the length is therefore a compile error here rather than somebody else's
status code.

## What it costs

On the request path, nothing that was not already there: one call is one
permit, one arena allocation for the body, and the parse if you asked for
one. **What it costs is per idle connection**, and it is stack: a handler
that has made one call holds 4,139 bytes more than one that has not, for the
life of the connection, at the depth `std.http.Client` drives the fiber to
([ADR 0063](../adr/0063-a-handlers-stack-is-per-connection.md)). That is
still the largest per-connection figure in the toolkit, and the levers left
are small.

Everything measured is `http://`;
[`bench/result/fetch.md`](../../bench/result/fetch.md) has the numbers on all
four of [ADR 0018](../adr/0018-the-trade-budget-has-three-axes.md)'s axes and
says plainly that nothing has been put on a scale through TLS yet.

## What it is not

A retry policy, a circuit breaker or a rate limiter. How many times, how long
between, and what counts as failure are facts about somebody else's service,
and a default that guessed them would turn one outage into a thundering herd.
A caller who knows them writes three lines — a loop, a
[`nilo.sleep`](./services.md#what-needs-wrapping) between attempts, and a
`switch` on which errors are worth another go. What is here is the part that
is the same for everybody: do not hold a connection forever, do not hold more
than you meant to, and do not read more than you asked for.

## Testing

A handler that takes a `*fetch.Client` is an ordinary function, and the
usual answer is not to give it one: shape the far end's response into a
struct, and test the function that turns that struct into yours, which is
what `examples/outbound` does with its `card`. For the call itself, the
module's own tests stand a real socket up on `std.Io.Threaded` with no
Engine anywhere — which is the entry condition for its layer, and the shape
to copy for a test that wants a real exchange.

## See also

- [The reference](../reference.md#nilo_fetch) — the surface as a list.
- [Object storage](./s3.md) — `nilo_s3` is this module with SigV4 in front of
  it, and the only module that imports a Fitting.
- [Checking somebody else's token](./jwt.md) — the fetch that gets a JWKS
  document.
- [ADR 0065](../adr/0065-the-way-out-was-open-the-clock-was-not.md) — why the
  deadline is on the fiber rather than in std.
