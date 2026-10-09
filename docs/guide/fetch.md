# Calling somebody else's API

**`nilo_fetch` is the HTTP client for calling other services from inside a handler: one shared client for the whole program, a deadline on every call, and the response kept in the request's memory.**

**Reference:** [`nilo_fetch`](../reference/fetch.md#nilo_fetch), [`fetch.Target`](../reference/fetch.md#fetchtarget), [`fetch.Exchange`](../reference/fetch.md#fetchexchange), [`fetch.testing`](../reference/fetch.md#fetchtesting) · **Design:** [Outbound calls](../design/fetch.md)

`nilo_fetch` is an HTTP client for use inside a handler: a payment provider, a geocoder, a webhook, somebody's JSON API. It is `std.http.Client` (its pool, HTTP/1.1, TLS) with the policy a server needs and a script does not, added in front in about sixty lines ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

It is a **Fitting**: it borrows the event loop and owns no destination. A `sql.Db` holds a pool to the one database named in its URL; a `fetch.Client` is given an address on every call and holds no connection to any named system, which is what lets one client serve every API a program talks to.

```zig
const fetch = @import("nilo_fetch");
```

and in `build.zig`, beside `nilo_http`:

```zig
.{ .name = "nilo_fetch", .module = nilo.module("nilo_fetch") },
```

## Making a call

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

The client is a [service](./services.md): registered once, asked for by type. **One is enough for the whole program.** The pool inside it is keyed by host, so calls to three different APIs share it without knowing about each other, and a second client would load the certificate bundle a second time.

`c` is a Scope: the `*Ctx` a handler holds, or a [`nilo.Run`](../reference/core.md#run) where there is no request (a startup path, a ticker, a test). The body comes back as a `Str` in that Scope's arena, so it lives exactly as long as the request does and nothing is freed by hand.

| Call | |
|---|---|
| `api.get(c, url, .{})` | `Response` |
| `api.post(c, url, body, .{})` | `Response` |
| `api.put(c, url, body, .{})` | `Response` |
| `api.delete(c, url, .{})` | `Response` |
| `api.patch(c, url, body_or_null, .{})` | `Response` |
| `api.send(c, method, url, body_or_null, .{})` | for a method the five above do not cover |
| `api.postJson(c, url, value, .{})` | `Response`: `value` written as JSON, with `content-type` set for you. `putJson`, `patchJson` and `sendJson` work the same way |
| `api.postForm(c, url, fields, .{})` | `Response`: `fields` written as a form body (`application/x-www-form-urlencoded`), with `content-type` set for you. `putForm` and `sendForm` work the same way |

**Most APIs take JSON, so you can pass the value itself.** `postJson` writes it out with `std.json` into the Scope's arena (the same one allocation every caller already paid by calling `std.json.Stringify.valueAlloc` by hand) and sets `content-type: application/json`, unless your `headers` name one, in which case yours is sent instead. It is the outgoing counterpart of `res.json(T, c)` ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn chargeJson(api: *fetch.Client, c: *nilo.Ctx) !Receipt {
    const res = try api.postJson(c, "https://api.example.com/v1/charges", .{
        .amount = 500,
        .currency = "idr",
    }, .{});
    if (!res.ok()) return nilo.fail.status(502, "the payment service said no", .{});
    return res.json(Receipt, c);
}
```

A body you already have as text is refused here while compiling: `std.json` would write it out as *one JSON string*, quotes and escapes included, and the far end would answer 400 to a body that looked right in your editor. Send that one with `post`.

**An OAuth token endpoint takes a form, and `postForm` writes it.** The code exchange and the client-credentials grant are `application/x-www-form-urlencoded` (RFC 6749 §4.1.3, §4.4.2). `postForm` takes a struct under the same rules as a query (an int, a bool, text, or an optional of one, null left out), encodes it into one allocation sized exactly, and says the `content-type`. The one difference from a query string is the space, which is `+` in a form and `%20` in a URL; a literal `+` is `%2B` in both. When the provider wants `client_secret_basic`, `fetch.basicAuth` builds the header the RFC's way: the id and the secret are form-encoded before they are joined and base64-encoded, which plain Basic does not do, and a secret with a `+` or a `:` in it fails only at the provider ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn token(api: *fetch.Client, c: *nilo.Ctx, client_id: []const u8, secret: []const u8) !fetch.Response {
    const auth = try fetch.basicAuth(c, client_id, secret);
    return api.postForm(c, "https://auth.example.com/oauth/token", .{
        .grant_type = "client_credentials",
        .scope = "read write", // goes as read+write
    }, .{ .headers = &.{.{ .name = "authorization", .value = auth }} });
}
```

**A query string is a struct, and the encoding is done for you.** `fetch.withQuery(c, base, params)` returns the URL with the params appended, percent-encoded, in the Scope's memory: one allocation, sized exactly. A field is an int, a bool, text (a `[]const u8`, a string literal, a `Str`) or an optional of one, where null leaves the param out; anything else is a Refusal naming the field. A base that already has a `?` gets `&`.

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn search(api: *fetch.Client, c: *nilo.Ctx, q: nilo.Str, page: u32) !fetch.Response {
    const url = try fetch.withQuery(c, "https://api.example.com/search", .{
        .q = q, // "a b" goes as a%20b, "a/b" as a%2Fb
        .page = page,
        .cursor = @as(?[]const u8, null), // left out
    });
    return api.get(c, url, .{});
}
```

Every call takes a URL, `Exchange.begin` included, which is why this is a function and not a field on the call. A path segment (`/v1/charges/{id}` with the id encoded on the way in) needs a base for the path to attach to, and that is a [target](#targets): the same struct is then the query, and the segments are filled from it by name.

The last argument is a `Call`: per-call overrides, every field null, so `.{}` is the ordinary case:

| Field | |
|---|---|
| `headers` | `[]const std.http.Header`, written to the wire in this order. A header std has a slot for (`host`, `authorization`, `user-agent`, `content-type`, `connection`, `accept-encoding`) is sent once, as your copy, not alongside std's own ([ADR 182](../adr/182-a-header-std-owns-goes-out-once.md)) |
| `timeout_ms` | this call's own deadline, instead of the client's |
| `stall_ms` | this call's own limit on silence, instead of the client's |
| `max_body` | this call's own body limit, instead of the client's |

**You can pass headers you did not choose.** A `headers` list copied from a `curl` command line carries `user-agent`, `host` and `authorization` as strings, and std writes each of those itself. Pass them as they are: nilo tells std to leave its own copy out, and keeping track of which headers std owns is nilo's job, not yours. The one to know about is `accept-encoding`. The line is sent as written, but the client still decodes nothing, so a server that sends `gzip` because you asked for it gives you `error.HttpContentEncodingUnsupported`, not a `Str` full of gzip. Leave it out and the client asks for identity itself.

## Reading the response

| | |
|---|---|
| `res.status` | `std.http.Status` |
| `res.ok()` | `bool`: 2xx |
| `res.body` | `Str`, in the Scope's arena. Freed when the request ends |
| `res.header(name)` | `?[]const u8`, case-insensitive; null when the response did not include it |
| `res.headers` | the whole header block, kept in the Scope next to the body |
| `res.json(T, c)` | `T`, parsed into the same Scope. Unknown fields are ignored |

**The response headers are kept with the body.** `Retry-After` on a 429, `ETag` for the next conditional GET, `Location` on a 201, `Link` on an API that pages by header, `X-RateLimit-Remaining` before deciding whether to make the next call: `res.header("retry-after")` reads any of them after the call, because the block was copied into the Scope before the body was read over it. It is the same copy `head.keep(c)` makes on an `Exchange`, made for you here because a whole-body call has no other moment to make it: one arena allocation the size of the block, next to the body's own ([ADR 187](../adr/187-a-head-that-outlives-its-body.md)).

**A 4xx or a 5xx is a `Response`, not an error.** The call worked and the service said no; only the caller knows which of those matters and what to say about it. It is worth a `switch`, because the far end's status is not yours to pass on:

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

const Repo = struct {
    full_name: []const u8,
    stargazers_count: u64,
};

const GitHub = fetch.Target("github", .{ .timeout_ms = 2_000 });

fn stars(github: *GitHub, c: *nilo.Ctx, owner: nilo.Str, name: nilo.Str) !u64 {
    const res = github.get(c, "/repos/{}/{}", .{ owner, name }, .{}) catch |err| switch (err) {
        error.TimedOut => return nilo.fail.status(504, "github took longer than 2s", .{}),
        else => return err,
    };

    if (!res.ok()) return switch (@intFromEnum(res.status)) {
        404 => nilo.fail.notFound("no repository {s}/{s}", .{ owner.view(), name.view() }),
        403, 429 => nilo.fail.status(502, "github is rate-limiting this address; retry after {s}", .{
            res.header("retry-after") orelse res.header("x-ratelimit-reset") orelse "a while",
        }),
        else => nilo.fail.status(502, "github answered {d}", .{@intFromEnum(res.status)}),
    };

    const repo = res.json(Repo, c) catch
        return nilo.fail.status(502, "github sent something this program cannot read", .{});
    return repo.stargazers_count;
}
```

That example shows four habits worth keeping:

- **Text from a request that goes into a URL is percent-encoded**, never pasted in. `%2e%2e%2f` in a path param is how a caller reaches an endpoint you never meant to offer. Each `{}` in a target's path is encoded on the way in, with `/` treated as data, by the same `nilo.percent` a query goes through ([ADR 057](../adr/057-percent-is-needed-by-two-layers.md)).
- **`error.TimedOut` gets its own branch**, because it is the one failure every caller of anything must handle, and 504 says *the thing I called is slow* where 500 would say *I am broken*.
- **A refusal says when to come back**, because the header that carries that is on the response, one call away.
- **The struct you parse into is what your program depends on**, not a copy of the far end's schema: `Repo` names two of GitHub's hundred fields, and the parse ignores the rest.

[`examples/outbound`](../../examples/outbound/main.zig) is that handler with a `main` around it, against GitHub's public API.

## Targets

**A target is a type that holds everything about one service you call: its host, its credentials and its limits.** A program that calls Stripe from six handlers would otherwise write Stripe's host, its `authorization` and its timeout six times, and there is nowhere on the client to write them once, because the client is shared by the whole program (the pool is in it). With targets, two services are two types, each opened once on the client, and a handler asks for the one it wants the way it asks for a database ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)). The API is [`fetch.Target`](../reference/fetch.md#fetchtarget).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

const Stripe = fetch.Target("stripe", .{ .timeout_ms = 5_000, .max_in_flight = 8 });

const Refund = struct { id: []const u8, amount: u64 };

fn refund(stripe: *Stripe, c: *nilo.Ctx, charge_id: nilo.Str) !Refund {
    const res = try stripe.postJson(c, "/v1/charges/{}/refunds", .{charge_id}, .{ .amount = 500 }, .{});
    if (!res.ok()) return nilo.fail.status(502, "stripe said no", .{});
    return res.json(Refund, c);
}
```

and in `main`, once, beside the client:

```zig
var stripe = try Stripe.open(&api, .{
    .base = cfg.stripe_base, // https://api.stripe.com
    .authorization = cfg.stripe_key,
});
try app.provide(&stripe);
```

**What is on the type is true of the service wherever the program runs; what is passed to `open` belongs to the deployment.** It is the same split [a bucket makes](./s3.md): the name, the timeouts and the limits are Stripe's, and the base URL and the key come from a `Config`. A sandbox host with a test key in development and the real pair in production is then one binary, not two.

| On the type | Default | |
|---|---|---|
| `max_in_flight` | 0 | calls to this service at once, under the client's own limit. `0` means no separate limit. Set it for a slow third party, so its calls queue at its own gate instead of holding the permits every other service shares |
| `timeout_ms` | the client's | this service's own deadline; a `Call` still overrides it for one call |
| `stall_ms` | the client's | the same, for silence |
| `max_body` | the client's | the same, for the body |
| `retry` | null | what happens when the service has a bad minute: [see Retrying](#retrying). Null is one try, and the target then holds and runs none of it |
| `ready` | null | a path the [health route](./deploying.md#health-checks) GETs on every probe, with a 2xx meaning ready. Null means "started is ready", because a load balancer asks every second, and calling somebody else's API at that rate costs money and hits rate limits without checking much |

| Passed to `open` | |
|---|---|
| `base` | `https://api.stripe.com`, or `https://api.sandbox.example.com/v2`: scheme, host, and a path prefix if there is one. No query and no fragment; a trailing `/` is dropped. Otherwise `error.BaseNotAbsolute` or `error.BaseHasQuery` |
| `authorization` | sent on every call, unless the call's own `headers` include one |
| `user_agent` | the same |
| `headers` | anything else the service always wants: `accept`, an API version, a tenant. A call's own header of the same name replaces it |

Every call the client has, the target has with a **path** instead of the URL: `get`, `post`, `put`, `delete`, `patch`, `send`, `postJson`, `putJson`, `patchJson`, `sendJson`, `postForm`, `putForm`, `sendForm`, and `url(c, path, args)` for just the URL (for an `Exchange` begun on the client, or a link written into a response).

**The path is a template, checked while compiling.** `{}` is a segment filled by position from a tuple, and the count is checked: two `{}` and one argument is a compile error, not a 404 from the far end. A segment is an int, a bool or text, and text is percent-encoded with `/` treated as data, so an id from a request that says `../admin` stays one segment instead of walking up the path.

**Name the segments and the same struct becomes the query.** `{id}` is filled from the field `id`, and every field the template does not name is appended as a query param under `withQuery`'s rules; an optional that is null is left out:

<!-- compiles -->
```zig
fn refunds(stripe: *Stripe, c: *nilo.Ctx, charge_id: nilo.Str, cursor: ?nilo.Str) !fetch.Response {
    // GET /v1/charges/<charge_id>/refunds?limit=20, and &starting_after=… when there is one
    return stripe.get(c, "/v1/charges/{id}/refunds", .{
        .id = charge_id,
        .limit = 20,
        .starting_after = cursor,
    }, .{});
}
```

A name with no matching field, a tuple for a named segment, a struct for a positional one, and a template that mixes the two are each refused while compiling, with a sentence that says what to write instead.

**The call's own headers win.** A `Call` on a target is the same `Call`, and a line in its `headers` naming `authorization` or `user-agent` replaces the target's value: one line on the wire, yours, following the rule [ADR 182](../adr/182-a-header-std-owns-goes-out-once.md) already sets for std's own headers. A line naming any other standing header replaces it too, so a target that says `accept: application/json` can ask for `text/csv` on one call. An ordinary call with no headers of its own costs nothing here; a call that passes its own headers to a target that has some costs one arena allocation for the merge.

**A target's own gate is taken before the client's.** With `max_in_flight` on the type, a call to a slow service waits at that service's own gate without holding a permit the others share; the client's limit on live connections still applies across all of them. The target starts the client underneath it, so a program that provides three targets and never the client works. One that provides all four starts the client four times, which sets the same `Io` four times.

## Retrying

**A call to a service that has a bad minute is tried again by a mechanism, with your numbers.** The loop each caller used to write had four traps in three lines: a POST sent again charges twice, a sleep with no jitter sends every caller back at the same instant, `Retry-After` is read by hand or not at all, and a loop with no budget turns a service's bad minute into three times its load. Declare `.retry` on the target and the numbers are yours while the rest is nilo's ([ADR 271](../adr/271-a-retry-is-the-callers-numbers-and-nilos-mechanism.md)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

const Payments = fetch.Target("payments", .{
    .timeout_ms = 5_000,
    .retry = .{
        .times = 3, // up to four calls in all
        .backoff = .{ .exponential = .{ .from_ms = 200, .to_ms = 3_000, .jitter = .full } },
        .mint_key = "Idempotency-Key", // Stripe takes this header; nilo makes the key
    },
});

fn chargeCard(payments: *Payments, c: *nilo.Ctx) !fetch.Response {
    // A POST, retried under one key that every try carries.
    return payments.postJson(c, "/v1/charges", .{}, .{ .amount = 500 }, .{});
}
```

| In `.retry` | Default | |
|---|---|---|
| `times` | 2 | tries after the first |
| `backoff` | exponential, 100 ms to 2 s, full jitter | the wait between tries; the same `Backoff` as [a job's](./jobs.md), `.jitter` being `.none`, `.full` (anywhere from none to the whole wait) or `.equal` (the top half) |
| `statuses` | 429, 502, 503, 504 | the answers that mean "later". A 500 is not here by default, because it is as often a bug that will answer the same again |
| `retry_after_max_ms` | 5,000 | the longest `Retry-After` is waited for. The header (seconds or an HTTP date) is a floor on the wait, and a service that says an hour is waited for this long |
| `budget` | `percent = 20, min_per_sec = 10, window_s = 10` | retries allowed up to this share of the calls made in the window, plus a floor a second so a quiet service can still retry. There is no way to turn it off |
| `mint_key` | null | the header a POST or PATCH with no key of its own is given one under. Naming it says the service honours it |

**Only a call that can be sent again is.** GET, HEAD, PUT, DELETE and OPTIONS are. A POST or PATCH is retried only if it carries an `Idempotency-Key` header of yours (in `Call.headers` or the target's standing headers) or the type names `mint_key`; otherwise it is sent once, exactly as without `.retry`. A transport failure before any answer (a refused or reset connection, a name that did not resolve, this call's own `TimedOut`) is retried the same way a status is, and `error.Canceled` never is. When the tries run out the last answer comes back as itself: a 503 is still a `Response`.

**A retry never outlives the route's deadline.** Before each wait nilo asks how much time the route has left, and a wait that would leave nothing to try with is not taken: you get the answer you have, at once. The wait itself is a sleep on the fiber the call already holds, with no permit held, so a service's bad minute does not become a queue for every other call through the gate.

**The budget is what stops the herd.** When a service answers 503 to most calls, a budget of 20% means it sees the calls it was given plus a fifth more, where three tries each would have sent it three times as many. It is per target: one service's bad minute does not spend another's allowance. A caller who wants it wide says `percent = 1000`, and cannot say none.

**A target that declares nothing pays nothing**: no state, no code on the call path, one try. A target that declares `.retry` holds 264 bytes once for the budget, and a call that succeeds first time asks the arena for what it did without ([the numbers](../../bench/result/fetch.md#a-sized-read-gives-back-the-arenas-second-page-and-what-a-retry-costs)). A call that is retried leaves each failed try's head and body in the request's arena, so a large body on a service that often says "later" is a reason for a lower `max_body`. A streamed body (`Exchange` with `.stream`) is not reachable through a target, and `nilo_s3`'s `putStream` and `stream` are never retried: a reader is spent by the first try.

**A reaped connection is not a retry.** The replay `nilo_fetch` makes onto a fresh connection when the pooled one was closed by the peer while idle is transport hygiene inside one try; it costs no wait, no budget and none of `times`.

`nilo_s3` takes the same `retry` on the Store, for `Throttled` and `Unavailable` ([the s3 guide](./s3.md)).

## Client settings

**Passed to `init`, once:**

| Field | Default | |
|---|---|---|
| `max_in_flight` | 32 | calls at once, across every host. Past it a caller waits for a permit instead of opening another connection |
| `timeout_ms` | 30,000 | how long one whole call may take: connect, send, head and body. `0` means no limit |
| `stall_ms` | 0 | how long the far end may send **nothing**: time since the last byte, not since the call began. `0` means no such limit. This is the other kind of timeout, for a call whose whole purpose is the transfer ([below](#stall-timeout-stall_ms)) |
| `max_body` | 8 MiB | a longer body is `error.BodyTooLarge`, enforced while reading, so a `content-length` that lies cannot get past it |
| `max_drain` | 64 KiB | how much of an unread body is worth reading to keep a pooled connection. Past it the connection is dropped instead |
| `read_buffer_size` | 8 KiB | the buffer each connection reads the socket through, so how much one read brings in. std's own default, passed through; one per connection, on the heap |
| `forward_request_id` | true | a call made under a `*Ctx` carries the request's id as `X-Request-Id`, so the service you called can log the same id you did. Under a `nilo.Run` there is no request and nothing is sent; a call that sets its own `X-Request-Id` keeps it ([ADR 158](../adr/158-a-request-id-goes-out-with-the-call.md)) |
| `proxy` | null | an egress proxy for `http://` calls, `.{ .url = "http://user:secret@proxy.corp:3128", .bypass = &.{"corp.example"} }` ([below](#going-out-through-a-proxy-and-trusting-a-private-authority)) |
| `roots` | null | the certificate authorities an `https://` call trusts, as a bundle you loaded. Null is the system's |

**On an App that traces, a call made under a `*Ctx` also sends `traceparent`**, so the service you called continues the same trace, and the call shows up as a span of its own under the request's ([Tracing](./tracing.md)).

**`max_in_flight` is not optional in practice.** `std.http.Client`'s pool limits *idle* connections and does not limit connections in use at all, so without it the limit on live connections is however many handlers happen to be running, and an HTTPS connection allocates 59,151 bytes of TLS and socket buffers, of which about 12 KB are resident after a small answer and 45 KB after one the size of a TLS record ([measured](../../bench/result/fetch.md#what-a-connection-in-the-pool-holds-over-tls-measured)). Five hundred concurrent handlers would be up to 22.5 MB nobody asked for, and five hundred handshakes. Thirty-two times that is the most this client will ever hold.

**`timeout_ms` limits the whole call, not each read**, because a server sending one byte a second satisfies any per-read limit and never finishes. The server's own [deadlines](./deploying.md#deadlines) follow the same reasoning from the other side.

**It fires with or without an Engine.** Under a server the deadline is set on the fiber ([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)), and `app.provide` is what gives the client the Engine's `Limits`. A client started with `nilo_start(io, .none)` (a test, a CLI, a worker with no server around it) has no fiber to arm, so each step of the call runs as a task of that `Io`, and that task is what gets cancelled when time runs out ([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)). The cost is one thread hop per step, paid only in that case. Until 0.5 such a client had `timeout_ms` configured but nothing to fire it, and the first CLI built on nilo wrote its own watchdog to work around that. `.off`, the older name for `.none`, is kept so that program still compiles.

### Going out through a proxy and trusting a private authority

**Two settings, both given by you and neither read from the environment.** A network whose only way out is a forward proxy, and a service whose certificate a company authority signed, are written like this:

```zig
var roots: std.crypto.Certificate.Bundle = .empty;
defer roots.deinit(gpa);
try roots.rescan(gpa, io, now); // the system's authorities...
try roots.addCertsFromFilePathAbsolute(gpa, io, now, "/etc/corp/ca.pem"); // ...and one more

var api: fetch.Client = .init(gpa, .{
    .roots = &roots,
    .proxy = .{ .url = "http://user:secret@proxy.corp:3128", .bypass = &.{ "corp.example", "127.0.0.1" } },
});
```

**The proxy carries `http://` calls only.** An `https://` call it would carry is `error.TlsThroughProxy`, before anything is dialled, because std 0.17 cannot start TLS inside its tunnel and would send the request in the clear. A host in `bypass` (and every host under it) is dialled directly, and so is its `https://`; `localhost` is not skipped unless you list it. The user and password in the URL go to the proxy as `Proxy-Authorization` and to nobody else, a redirect to another origin never carries them, and a URL that is not `http://` or `https://` with a host stops the program at start with `error.InvalidProxy`. The pass-through you may have expected, `HTTP_PROXY` and `NO_PROXY` read from the environment, is one line of your own configuration away and is not done for you ([ADR 267](../adr/267-a-call-can-go-through-a-proxy-and-trust-a-private-authority.md)).

**`roots` is a bundle, and it is yours.** It must outlive the client and not change while the client lives; the client never frees it. Give it an empty bundle and an `https://` call trusts nobody, which is how you hold a program to one authority.

### Calling a service on a unix socket

**A service on `unix:/run/orders.sock`, the Docker Engine, or a local agent is called by naming the socket beside the URL.** The URL is still the request (its host becomes the `Host` header, its path the request line), so a Target for Docker is one line and every path hangs off it:

```zig
const Docker = fetch.Target("docker", .{});
var docker = try Docker.open(&client, .{ .base = "http://docker/v1.43", .unix_socket = "/var/run/docker.sock" });
// docker.get(c, "/containers/{id}/json", .{ .id = id }, .{})
```

Without a Target, `client.get(c, "http://docker/containers/json", .{ .unix_socket = "/var/run/docker.sock" })`. The URL must be `http://` (`error.TlsOverSocket` otherwise), the path absolute (`error.InvalidSocket`), and a proxy in `Settings` is not used for it: a socket never leaves the host, so one client proxies Stripe and talks to Docker. A redirect to another origin is `error.RedirectLeavesSocket` and is not followed over TCP ([ADR 272](../adr/272-a-call-names-the-socket-it-goes-over.md)).

### Stall timeout (`stall_ms`)

**`stall_ms` limits silence inside a call, not the length of the call.** A download may legitimately take an hour, so the only sensible `timeout_ms` for a call whose whole purpose is the transfer is `0`. That leaves a peer that went quiet with the socket open (a CDN edge that lost its origin, a NAT that dropped the mapping, a Wi-Fi handover) with nothing to end it. With `stall_ms`, nothing arriving for that long is `error.Stalled`, counted from the last byte received, not from the start. The two work together (`timeout_ms` on the whole call, `stall_ms` on the gaps), and a caller sets either or both ([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn pull(api: *fetch.Client, c: *nilo.Ctx) !void {
    var out = try c.stream(200, "application/octet-stream");
    var ex: fetch.Exchange = .idle;
    defer ex.end();
    _ = try ex.begin(api, .{
        .method = .GET,
        .url = "https://mirror.example.com/large.iso",
        .timeout_ms = 0, // however long it takes
        .stall_ms = 10_000, // but never ten seconds of nothing
    });
    _ = ex.pipe(&out.writer) catch |err| switch (err) {
        error.Stalled => return nilo.fail.status(504, "the mirror went quiet", .{}),
        else => return err,
    };
    try out.finish();
}
```

It is not a per-read timeout, which ADR 056 rejected and still rejects: a server sending one byte a second is *slow*, passes this check, and whether slow is acceptable is for you to judge against your other connections. What this catches is a server sending nothing. `Stalled` is a different error from `TimedOut` because a caller does different things with them: a stalled transfer is restarted on a fresh connection, while a call that used up its whole budget is abandoned.

Under a server it uses the Engine's timer, reset on every chunk; on a client with no Engine it is the same task-and-cancel mechanism ADR 056 built, with the wait measured from the last byte. Either way, a transfer that keeps moving never triggers it.

## Errors

**A call fails with one of these, and a 4xx or 5xx is not among them.**

| Error | |
|---|---|
| `error.TimedOut` | this call's own deadline ran out |
| `error.Stalled` | nothing arrived for `stall_ms`; the peer still holds the socket |
| `error.Canceled` | the server is shutting down underneath the call. Reported separately from `TimedOut`, not guessed at |
| `error.RedirectRefused` | the response was a 3xx with a `Location`, and the call did not choose what to do with redirects. `Client.get` and its siblings follow them; an `Exchange` sets `.redirects = .follow` or `.expose` ([below](#streaming-a-large-response-exchange)) |
| `error.InsecureRedirect` | a followed redirect led from `https` to `http`, so it was not followed: the next request would have crossed the network in the clear |
| `error.BodyTooLarge` | the body went past `max_body`, and reading stopped there |
| `error.BodyTooShort` | the body ended before the length its own head announced |
| `error.TlsThroughProxy` | an `https://` call that `Settings.proxy` would carry; name its host in `bypass` to reach it directly |
| `error.InvalidProxy` | `Settings.proxy.url` is not an `http://` or `https://` URL with a host; raised by the start, before the program serves |
| `error.TlsOverSocket` / `error.InvalidSocket` / `error.RedirectLeavesSocket` | a call over a unix socket that is `https://`, whose path is not an absolute socket path, or whose redirect left the origin ([above](#calling-a-service-on-a-unix-socket)) |
| `error.NotStarted` | a call made before `listen()`: the client is finished at startup like any other service |
| the rest | `std.Uri.ParseError`, `std.http.Client`'s connect and receive errors, and the reader and writer errors, unchanged |

`NotStarted` is the one a unit test runs into: a handler called directly, with no App around it, has a client nobody started. The fix is the same one the [testing page](./testing.md#checking-and-starting-services-in-a-test) gives for a database (`app.start(io)`, in a test that never listens), or a fake in the handler's argument list, which is what the signature rules are for.

## Compressed responses

**Every call asks for an uncompressed body.** `send` puts `Accept-Encoding: identity` on every call, so `res.body` is the body and not a gzip stream. `std.http.Client` on its own advertises gzip and then hands back the compressed bytes; decompressing is a separate call there, and a caller who forgets it gets unreadable bytes and no error. Decompressing here would cost a 32 KiB flate window on the handler's stack, which is held per *connection* ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)), so identity is the trade-off chosen. A server that ignores the header and sends gzip anyway causes an error, not a `Str` full of noise.

## Streaming a large response (`Exchange`)

**An `Exchange` lets you read the response head, decide, and then move the body somewhere other than memory.** The calls above read the whole body into the Scope, which is right for an API answering JSON and wrong for anything measured in megabytes. An `Exchange` applies the same policy but leaves the body on the socket. It is the outgoing counterpart of a [body reader](./requests.md#streaming-a-large-body) for an incoming request. The API is [`fetch.Exchange`](../reference/fetch.md#fetchexchange).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn mirror(api: *fetch.Client, c: *nilo.Ctx) !void {
    var ex: fetch.Exchange = .idle;
    defer ex.end();

    const head = try ex.begin(api, .{
        .method = .GET,
        .url = "https://example.com/report.csv",
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
| `ex.begin(api, .{…})` | `Head`: `status`, `content_length`, `content_type`, `header(name)` (case-insensitive), `ok()`; and `redirected`, the `std.Uri` a followed redirect ended at, or null, with `location(&buf)` to write it out as one string |
| `head.keep(c)` | the same head copied into the Scope, so it still reads correctly after the body has been read |
| `ex.take(c, max)` | the rest of the body as a `Str` in the Scope, refusing anything over `max` |
| `ex.readInto(buf)` | exactly `buf.len` bytes, or `error.BodyTooShort` |
| `ex.pipe(w)` | the rest into a `*std.Io.Writer`, and how many bytes |
| `ex.stream(w, limit)` | one chunk into `w`, at most `limit`, and how many bytes; `0` is the end. For a body moved in pieces of your own choosing |
| `ex.discard()` | "I will not read this body; close the connection." For the probe that asked for one byte and got the whole file |
| `ex.end()` | required, and safe to call twice |

`Begin` takes everything a `Call` does and more: `headers`, `host`, `authorization`, `content_type` and `user_agent` (four headers std would otherwise write itself, which a signed request must control); `timeout_ms`, `stall_ms`, a `body` of `.none`, `.slice` or `.stream` with a length, and `redirects`. The explicit fields are for a caller who has the value; putting the same name in `headers` is the other way to set it, and doing both sends two lines on the wire.

**A followed redirect leaves your credentials at the origin you sent them to.** If the service answers with a redirect to a file host or a CDN, the request that follows carries no `authorization`, `cookie`, `proxy-authorization` or `www-authenticate`, and none of a `Target`'s standing headers (an `x-api-key` looks like any other header, so all of them stay behind). Another origin is another scheme, host or port: `api.example.com` redirecting to `files.example.com`, to `api.example.com:8443` or to `example.com` all count, and a hop to `http://` from `https://` is `error.InsecureRedirect`. A redirect that stays on the same origin keeps everything. `res.redirected` says where a `get` ended, or null when it was not redirected. If the far side needs the credential, make the second call yourself, to the address `res.redirected` gives or the `Location` header, with the line you mean to send ([ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)).

**Following a redirect is a choice each call makes.** `redirects` is `.refuse` by default, and then a 3xx with a `Location` is `error.RedirectRefused`: a caller who never thought about redirects finds out from the error, instead of reading a 301 as a broken server. `.follow = &buf` follows the chain, three deep at most, and the response comes back with `head.redirected` set to the URL it actually came from, so the connections after a probe can go straight there instead of following the chain again. The text lives in your buffer, which is why `head.location(&buf)` takes one to write into instead of returning a slice ([ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)). `.expose` returns the 3xx itself, which is what a signed request needs (a signature is computed over one host and one path, and following would send the `authorization` header somewhere it was never meant to go), and what a client that reads the body of a 301 needs, which is where S3 puts its reason ([ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)).

**Everything in `Head` points into the connection's read buffer, and the first byte of body you read overwrites it.** Read what you need before `take` or `pipe`, or call `head.keep(c)` for a copy in the Scope that still reads correctly afterwards, for example the `etag` the next run compares against, read before the body and needed after it ([ADR 187](../adr/187-a-head-that-outlives-its-body.md)). A [borrowed row](./sql/raw.md) makes the same trade for the same reason: the alternative is an allocation per call for text most callers look at once, so the borrowed head is the default and the copy is one line where you need it.

**There is no buffer to declare.** `take`, `readInto`, `pipe` and `stream` copy from the connection's own read buffer straight to the destination, whatever the framing. The `transfer_buffer` field is only for a caller who reads *buffered* from `ex.reader` (`take`, `peek`, a delimiter). It does not change how much one socket read brings in; that is `read_buffer_size` on the client. Until 0.5 the guide said a bigger buffer meant fewer trips, a download manager gave sixteen segments 64 KiB each because of it, and the syscall count did not change ([ADR 186](../adr/186-the-transfer-buffer-serves-nothing-here.md)).

**An `Exchange` must not be copied once begun**, because it holds a live `std.http.Client.Request`. Declare it, fill it where it is, and leave it there. `defer ex.end()` is not optional: it gives the permit back and returns the connection to the pool, or drops it if what was left unread is more than `max_drain`. When you already know the body is not wanted (a `Range` probe that got the whole object back), call `ex.discard()` before `end`, and the connection is dropped with the body whatever `max_drain` would have decided. That keeps `max_drain` a policy for every call instead of a setting changed for one ([ADR 184](../adr/184-a-caller-that-knows-says-discard.md)).

**A streamed request body is sent on a connection of its own**, never one from the pool. A pooled connection may be one the server closed while it idled, and a body that is a reader cannot be sent twice, so the call would consume the reader and fail; a `.slice` body is protected by a replay and a `.stream` body by this. The cost is a handshake per streamed body (TLS included over `https://`), which is small against a body big enough to be streamed. While one goes out, `stall_ms` counts every chunk your reader hands over as progress.

**A request body with no known length cannot be streamed.** `.stream` takes the length because HTTP can send a body of unknown length only as chunked, and the services this exists for, S3 among them, answer `411` to that. Not knowing the length is therefore a compile error here instead of somebody else's status code.

## What it costs

**On the request path, nothing that was not already there.** One call is one permit and two arena allocations (the header block, then the body; [ADR 187](../adr/187-a-head-that-outlives-its-body.md)), plus the JSON written out or the URL built if you asked for either, and the parse if you asked for that. **The real cost is per idle connection, and it is not stack**: a handler that has made one call holds about 2,130 bytes more than one that has not, for the life of the connection. The fiber's stack goes back when the handler returns ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)), and what stays is a page of the request arena that the body was read into, kept by `arena_keep`, which any handler that puts a kilobyte in its arena holds. A body that announces its `content-length` is read into exactly that many bytes; it was 4,170 while it was read by growing a buffer ([measured](../../bench/result/fetch.md#a-sized-read-gives-back-the-arenas-second-page-and-what-a-retry-costs)). Taking the 4 KiB transfer buffer out of `send` moved it by 14 bytes, because a buffer no byte ever touched was never a resident page. A call that is still waiting for its answer holds about 17 KB of stack until it gets it.

Everything measured is `http://`. [`bench/result/fetch.md`](../../bench/result/fetch.md) has the numbers on all four of [ADR 017](../adr/017-the-trade-budget-has-four-axes.md)'s axes, and says plainly that nothing has been measured through TLS yet.

## What it does not do

**There is no circuit breaker or rate limiter, and a retry happens only where you declared one.** A target with no `.retry` makes one try, because how many times to try and what counts as failure are facts about somebody else's service that a default would only guess. A breaker, which stops calling a service that is down instead of waiting out the timeout on every call, is not built ([the todo list](../todo.md)). A client (not a target) has no retry: wrap the call in a target, which is the sentence "this service is this URL and gets this many tries".

## Testing

**The usual answer is to not give the handler a real client at all.** A handler that takes a `*fetch.Client` is an ordinary function: shape the far end's response into a struct, and test the function that turns that struct into yours, which is what `examples/outbound` does with its `card`. For the call itself, the module's own tests start a real socket on `std.Io.Threaded` with no Engine anywhere (which is the entry condition for its layer), and you can use the server they drive.

**`fetch.testing.Canned` is one real exchange, for your own test suite.** Open it, say what it answers, start it with `io.concurrent` beside the call, and finish the client with `nilo_start(io, .none)` as `listen()` would have done. It binds port 0 and reads the kernel's chosen port back, so there is no port range to keep separate from anybody else's. `serveOne` reads the whole request, and `request()` and `requestBody()` show what arrived, which is what a test about a POST needs ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)). The API is [`fetch.testing`](../reference/fetch.md#fetchtesting).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn retryAfterIsRead(io: std.Io, gpa: std.mem.Allocator) !void {
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
    try std.testing.expect(std.mem.startsWith(u8, canned.request(), "GET / "));
}
```

`io` is a `std.Io.Threaded` the test owns: `var threaded: std.Io.Threaded = .init(std.testing.allocator, .{}); defer threaded.deinit();` and `threaded.io()`. Use `concurrent`, not `async`, because `async` may run the server on your own thread, where it sits in `accept` waiting for the connection that same thread was about to make; the module's tests found that as a hang at zero CPU ([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)).

**A call over a unix socket is tested with `Canned.openUnix(io, path)`.** It listens on a socket file at `path` where `open` would bind a loopback port, and the call names that path as its `unix_socket`. The URL the test sends is its own, since over a socket only the `Host` and the path reach the server, and the socket file is yours to remove ([the reference](../reference/fetch.md#fetchtesting)).

**A Target's `.retry` is tested with `canned.serveScript(script, count)`.** It answers `count` requests from a list of replies, one connection each, so every try is a connection that can be counted: `canned.tried` says how many arrived and when, and `headOfTry(n)` gives the head of each. Start it with `io.concurrent`, and check `tried` after the call returns.

## See also

- [The reference](../reference/fetch.md#nilo_fetch): the whole API as a list.
- [Object storage](./s3.md): `nilo_s3` is this module with SigV4 in front of it, and the only module that imports a Fitting.
- [Checking somebody else's token](./jwt.md): the fetch that gets a JWKS document.
- [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md): why the deadline is on the fiber and not in std.
