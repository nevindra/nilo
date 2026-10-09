# A Fitting borrows the loop and owns no destination

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)

## Context

`nilo_s3` needs to speak HTTP to an object store. A handler needs to speak HTTP to Stripe. Both want the same four things in front of `std.http.Client`, and neither can reach the other's copy: `http/` cannot hold it, because a Service may not import `nilo_http` (sideways, and `zig build layering` refuses it, the wall that already sent `percent` down a layer, [ADR 057](./057-percent-is-needed-by-two-layers.md)); `nilo_core` cannot hold it, because Core does no IO at all and a drain policy needs `std.http.Client`; and a module of its own could not be imported by `nilo_s3` either, since needing the event loop makes it a Service and a Service importing a Service is sideways again.

**Nobody had asked how big the thing being housed is.** `spike/outbound/` measured it before it was designed around: the policy nilo would add came to 65 lines against `std/http/Client.zig`'s 1,867 and `std/crypto/tls/Client.zig`'s 1,670, under 2% of the client it sits in front of. `std.http.Client` is already the client (pool, HTTP/1.1, TLS); what is missing is policy, the kind a script does not need and a server does. The spike also answered the question that decides whether a fourth layer can be *held* rather than declared: its tests run under `std.Io.Threaded`, with no engine and an empty dependency list.

Once the policy half shipped, two rounds of a real program (fdm) made it the strong half and the ordinary call the thin one. `examples/outbound/main.zig` was the evidence: `std.json.Stringify.valueAlloc` and a `content-type` line by hand on every POST, a search endpoint assembled through an `Allocating` writer and `percent.encodeWrite` one param at a time, five lines to build a URL with two path params, a `user-agent` and a timeout on every call to Stripe. Two things could not be said at all, because the client has no destination to say them about: a ceiling on calls to *this* service, so one slow third party does not eat the permits every other one shares, and a `nilo_ready` for the upstream.

## Decision

### A Fitting borrows the loop and owns no destination

**A fourth layer, between the bottom layer and Service, called a Fitting.** A Fitting borrows the loop and owns no destination: `nilo_fetch` is a Fitting, `nilo_sql` is a Service because it holds a pool to a database named in its URL.

| Layer | Modules | The loop | Entry condition |
|---|---|---|---|
| Core | `core/` | needs none | `zig test core/core.zig`, no module graph |
| Tool | `id/`, `config/`, `pw/`, `cache/`, `jwt/` | needs none | `zig test <m>/<m>.zig`, no module graph |
| **Fitting** | `fetch/`, `job/` | **borrows** | **`zig test` under `std.Io.Threaded`, no Engine** |
| Service | `sql/`, `s3/` | borrows, and holds a named system | needs the module graph |
| App | `http/` | owns it | — |

**The entry condition is the load-bearing half of this**, and it is why the layer is a layer rather than a shelf. The bottom layer's condition is tests under a plain `zig test`; a Fitting borrows the loop so it cannot meet that one, but `std.Io.Threaded` is std's own, so a module that only *borrows* an `Io` can be driven by one without an Engine existing. `fetch/live.zig` opens a real socket at both ends and proves it on every run. A module that cannot be tested that way is holding a connection to something, which makes it a Service. That line is sharp in code rather than only in prose: `Client` holds no credentials and no endpoint, and is given a URL on every call.

### The ordinary call sends JSON and a query

**A value of a type the caller chose cannot sit in a field of a struct nilo declared.** `Client.Call` is a plain struct and has to stay one: the moment the last argument is `anytype`, a `.headers = &.{.{ .name = …, .value = … }}` literal loses its result type and stops coercing to `[]const std.http.Header`, which is every existing call site, and a union arm cannot carry an `anytype` either. So the two things that take a value of the caller's own are functions, and the thing that takes none is a field.

**`client.postJson(c, url, value, .{})`**, with `putJson`, `patchJson` and `sendJson(c, method, url, value, .{})` beside it. The value is written with `std.json.Stringify.valueAlloc` into the Scope's arena and sent under `content-type: application/json`, unless `call.headers` already carries a `content-type`, which then goes once ([ADR 182](./182-a-header-std-owns-goes-out-once.md)). Text is refused while compiling: a `[]const u8` handed here would go out as one JSON *string*, quotes and all, and the far end would answer 400 to a body that looked right in the editor. A body already encoded goes through `post`.

**`fetch.withQuery(c, base, .{ .page = 2, .q = "a b" })`** answers `base?page=2&q=a%20b` in the Scope's memory. A field is an int, a bool, text (`[]const u8`, a string literal, a `Str`) or an optional of one, and a null optional is the param left out; any other type is a Refusal naming the field. A base that already has a `?` gets `&`; one ending in `?` or `&` gets the first param straight after it. The space is `%20` and the hex is upper-case, for the reason `core/percent.zig` gives: both are the difference between a signed request that verifies and one that does not. The URL is one arena allocation, sized exactly: the params are measured and then written, the way every caller of `core.percent` already does.

**`postForm`, `putForm` and `sendForm` write a form body, and `fetch.basicAuth` builds the OAuth `client_secret_basic` header.** The fields are a struct under `withQuery`'s rules and Refusals (a Refusal there says "form field"), measured and written by the same walk into one allocation sized exactly, with `content-type: application/x-www-form-urlencoded` said for you unless the call names one. The one difference from a query is the space, `+` in a form and `%20` in a URL; `core.percent` has no `+` to give on purpose, so the form style rewrites each `%20` itself in `fetch.zig`, and a literal `+` is `%2B` in both. `basicAuth(c, id, secret)` form-encodes the id and the secret before it joins them with `:` and base64-encodes the result (RFC 6749 §2.3.1), where RFC 7617's plain Basic joins them raw and a secret holding a `+` or a `:` fails only at the provider; it answers the header value, passed in `Call.headers` like any other. Both are plain functions the linker drops when nothing names them.

**`fetch.testing.Canned`** is a loopback server for a caller's own suite: `open(io)`, `reply(status, headers, body)`, `url(&buf)`, `serveOne`, `request()`, `requestBody()`, `close()`. Port 0 and the kernel's answer read back, so a suite needs no port range of its own.

### A target is a type, and a path is a template

`fetch.Client` is one for the whole program on purpose: the connection pool lives in it, and a second client loads the certificate bundle a second time. That leaves nowhere to write "Stripe is `https://api.stripe.com`, sends `authorization: Bearer …`, and gets five seconds", so every call repeated all three.

**`fetch.Target(name, options)` returns a type. Two services are two types, therefore two Services, and a handler names the one it wants.**

```zig
const Stripe = fetch.Target("stripe", .{ .timeout_ms = 5_000, .max_in_flight = 8 });

var stripe = try Stripe.open(&api, .{
    .base = "https://api.stripe.com",
    .authorization = cfg.stripe_key,
});
try app.provide(&stripe);

fn charge(stripe: *Stripe, c: *nilo.Ctx, id: nilo.Str) !Receipt {
    const res = try stripe.get(c, "/v1/charges/{}", .{id}, .{});
    if (!res.ok()) return nilo.fail.status(502, "stripe said no", .{});
    return res.json(Receipt, c);
}
```

The type-keyed registry resolves `*Stripe` with nothing added to it, and a target started by `listen()` starts the client under it, so a program that provides three targets and never the client works.

**What is on the type is [ADR 059](./059-a-bucket-is-a-type-and-a-key-is-not.md)'s rule, read the same way: whatever is a property of the service rather than of the deployment.** The name, `max_in_flight`, `timeout_ms`, `stall_ms`, `max_body` and a `ready` path are the service's and sit on the type. **The base URL and the credential are the deployment's**, given to `open`: a sandbox host and a test key in development, the real pair in production, one binary ([ADR 039](./039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)). It is a URL built from a base held once rather than assembled at every call site, and a header block that is the standing headers plus the call's, merged only when both have something in them.

**A path is a template, read while compiling**, two shapes decided by the arguments: a tuple fills `{}` by position (`"/v1/charges/{}", .{id}`, count checked against count of arguments); a struct fills `{name}` by field, and every field the template does not name is a query param under `withQuery`'s rules. A name with no field, a tuple for a named segment, a struct for a positional one, and a template mixing the two are each a Refusal saying what to write instead. A segment is an int, a bool or text, and text is percent-encoded with `/` as data, so an id off a request that says `../admin` is one segment rather than a walk; an optional is refused in a segment where it is welcome in a query, because a segment cannot be left out.

**Standing headers, and the call's own over them.** `authorization` and `user_agent` are fields on `Open` and go through std's own slot; anything else is a list of lines. A line in the call's `headers` naming `authorization` or `user-agent` goes *instead* of the standing value (the rule [ADR 182](./182-a-header-std-owns-goes-out-once.md) set for std's own slot), and a line naming any other standing header shadows it.

**A target's gate is taken before the client's and given back after it.** `max_in_flight` on the type is a semaphore of the target's own, so a call to a slow service queues at that service's gate holding no permit the others share; zero, the default, is no gate of its own. Target then client, always, and the client's permit goes back before the target's `defer` runs.

**`nilo_ready` is started-is-ready unless the type names a path.** The reason is `s3.Store`'s ([ADR 154](./154-a-health-route-asks-the-services.md)): a balancer asks every second, and a GET to somebody else's API at that rate is a bill and a rate limit rather than a check.

## What was rejected

**Relax the never-a-sibling rule, adding `nilo_fetch` to `s3`'s `may_import`.** One line in the `layers` table, and it turns "a module imports downward only, never a sibling" into "whatever the table says". The value of the rule is that it cannot be argued with per case.

**Two copies of the policy.** The outcome [ADR 057](./057-percent-is-needed-by-two-layers.md) was written to avoid one layer down, at forty lines; this is the same mistake at a few hundred, and the second copy would never be deleted.

**Put it in Core anyway.** Core does no IO, and a drain policy needs `std.http.Client`; admitting it would cost the property every other file down there is holding up.

**Do nothing until a second Fitting exists.** Close, but `nilo_s3` was being designed at the same time, and the policy would have been written inside it. The layer costs an amendment to two ADRs; the delay costs the thing the amendment exists to prevent.

**`.body = .{ .json = value }` on `Call`, and `.query = .{ … }` beside it.** The spelling that reads best. A union arm and a struct field both need a type nilo can name, and the value's type is the caller's; making the last argument `anytype` and reading the fields off it breaks the `headers` literal at every existing call site.

**A type-erased `Query`, a pointer and a write function, so the field could exist.** `.query = fetch.query(&.{ .page = 2 })` takes the address of a temporary, and what the language promises about that temporary's lifetime is not something a caller should have to know to write a GET.

**`query: []const Param` at run time**, and a growing writer for the URL. No struct, no Refusal, every int turned to text by hand, and one to three allocations for bytes that fit in one sized exactly.

**Refusing a non-struct JSON body.** `std.json` writes an int, an array or an enum as itself, and each is a body some API takes; text is the one shape that is silently wrong, and that is the one refused.

**A struct of defaults on `Client`**, `client.get(c, url, .{ .target = &stripe })`. Every call still writes the host, and a handler cannot say in its signature which service it reaches, the objection [ADR 054](./054-a-second-database-is-a-second-type.md) made to one `Db` with a name argument.

**`.base` on the type.** The endpoint is the deployment's; a comptime base would make development and production two binaries.

**A path built through `withQuery` alone.** `withQuery` needs no base and a path does; a segment is not a param, since it is encoded with `/` as data and cannot be left out.

**An `Exchange` begun on a target.** Wanted, and not built: `Exchange.begin` takes a client and a URL, and a target's `url(c, path, args)` is the URL, so the standing headers and the target's gate do not reach a streamed call. It waits on a caller who streams from a service that has standing headers (`docs/todo.md`).

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes, a Fitting costs a program that does not import one **nothing at all**: no allocation, no per-connection memory, no throughput, zero bytes, because nothing it compiles names `nilo_fetch` and the linker never sees it. `nilo_http` names it in one file, `http/otlp.zig`, which only the body of `app.trace` reaches ([ADR 247](./247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)); a program that does not trace compiles none of it, and the measurement is in that ADR.

For a program that does import one, each axis is measured in [`bench/result/fetch.md`](../../bench/result/fetch.md) against the same call made through a plain `std.http.Client` with none of the policy round it:

| axis | `nilo_fetch` | the call itself (std's) |
|---|---|---|
| allocations per call | **1**, the body into the Scope's arena | connection setup only, pooled |
| memory per idle connection | **+2,132 bytes** over an idle connection, which is 2,009 fewer than the plain std call: the body is read at the size `content-length` announced, so what stays is the 2,048 any handler that puts a kilobyte in its arena holds. The module's own part is a constant 27 bytes over the plain call and not per connection | **+4,141 bytes**, of which 4,096 is a retained arena page |
| throughput | **within ±1%**, below this harness's drift | −40% off the floor |
| binary size, stripped ReleaseFast | **+1,688 bytes** | +655,600 bytes |

The one that matters is the second column: an outbound call is still the most expensive thing a handler can do to the per-connection axis, and it is held for as long as the *inbound* connection stays open ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)). It is not fiber stack, which a call gives back whole when the handler returns (72 bytes with `arena_keep = 0`, and a marginal stack cost of zero); it is one page of the request arena, kept resident by `arena_keep`, and `Exchange.take` now reads a body that announced its length into exactly that many bytes, which halves it: 8,852 bytes an idle connection at 10,000 connections before, 6,810 after, against 4,678 for `/health` ([`bench/result/fetch.md`](../../bench/result/fetch.md), *The 4,139 was the arena* and *A sized read gives back the arena's second page*). A chunked body, or one announced past `max_body`, still takes the growing read. A call that is *waiting* holds about 17.4 KB of stack for as long as it waits, 80% of it nilo's own frames. Arming a deadline on top of it is free: two bytes an idle connection and nothing measurable on throughput, because a 192-byte slot lands inside a page the fiber had already touched ([ADR 056](./056-the-way-out-was-open-the-clock-was-not.md)).

A call through a target adds the same two arena allocations a plain call makes (the header block, then the body) plus the URL, one allocation sized exactly in place of the `Allocating` writer a caller was assembling it with by hand; a call that passes headers of its own under a target with standing lines adds one more for the merge. A target's gate is one more semaphore wait per call on a target that asked for one, and a null test on one that did not. Binary size is a type per target, each carrying the calls it instantiates; nothing for a program that names none.

**The layer's first tenant was 65 lines, and that argument is on the record too.** A layer housing sixty-five lines does not justify itself by volume; it justifies itself by where a rule can be enforced, `zig build layering` reading the `layers` table and refusing an import that is not in it, a build step rather than a paragraph. `job/` becoming the second Fitting is what settled whether the layer was worth having.
