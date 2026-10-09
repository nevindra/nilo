# Middleware and resolved values

**There are two ways to put something between the request and the handler, and they are not interchangeable: middleware enforces a rule, a resolved value provides a value.**

**Reference:** [`app.use`, `app.useOn`](../reference/app.md#app), [`with`, `without`](../reference/app.md#group), [built-in middleware](../reference/middleware.md#built-in-middleware) · **Design:** [Middleware](../design/middleware.md), [CORS and the proxy](../design/cors-proxy.md), [Rate limiting](../design/rate-limiting.md)

## How middleware works

```zig
fn timing(c: *nilo.Ctx, next: nilo.Next) !void {
    const started = nilo.monotonicNanos();
    try next.run(c);
    const took_us = (nilo.monotonicNanos() - started) / std.time.ns_per_us;
    std.log.info("{f} took {d}µs", .{ c.path(), took_us });
}

try app.use(nilo.logger.standard);
try app.use(nilo.cors.permissive);
try app.use(timing);
try app.useOn("/api", requireToken);
```

**Middleware is an onion: everything before `next.run(c)` happens on the way in, everything after it on the way out.** Not calling `next` at all ends the chain, which is all an auth middleware has to do to reject a request:

```zig
fn requireToken(c: *nilo.Ctx, next: nilo.Next, tokens: *TokenStore) !void {
    const token = c.header("Authorization") orelse
        return fail.unauthorized("this endpoint needs a token", .{});
    if (!tokens.valid(token.view())) return fail.unauthorized("that token is not valid", .{});
    try next.run(c);
}
```

`tokens: *TokenStore` is a service, handed over by the same rule a handler follows. See [Giving a middleware what it needs](#giving-a-middleware-what-it-needs).

Returning an error takes exactly the same path as a failing handler. **A middleware that stops the chain has to answer**, with a fail function or a `c.send`: one that returns without answering and without calling `next` is a 500, and the log names it as `middleware N of M`. The empty 200 a handler gets for returning nothing is the handler's, and a guard that forgot its 401 must not read as a success.

**To learn the status after `next.run(c)`, read it the way the logger does.** `c.answered()` is the status once something has been written. When `next.run` returned an error before anything was written, the status the App is about to send is `fail.resolveStatus(failure, err)` with `fail.current()`, or `fail.statusFor(err)` when there is no failure set. Asking `fail` instead of mapping the error yourself keeps what you record in step with what was actually sent.

The order of `use` and `get` calls does not matter. Chains are resolved when `listen()` is called, so middleware registered after a route still applies to it. Middleware also runs when no route matched, so your logger sees 404s and CORS can answer a preflight for a path that has no route.

`useOn(prefix, mw)` limits a middleware to paths that start with the prefix. `group("/api").use(mw)` does the same thing more clearly; see [Routing](./routing.md#groups).

See [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md).

### Giving a middleware what it needs

**After `*Ctx` and `Next`, a middleware takes the services and resolved values it needs as arguments, and `listen()` checks that they exist.** A pointer is a service, and a value is a resolved value, as in a handler:

```zig
fn requireKey(c: *nilo.Ctx, next: nilo.Next, keys: *KeyStore, user: CurrentUser) !void {
    if (!keys.allows(user.id)) return fail.forbidden("no key for {d}", .{user.id});
    try next.run(c);
}

try app.provide(&keys);
try app.use(requireKey);      // also useOn, a group's use, with, without
```

**A service nobody provided stops the server at `listen()`**, naming the middleware and the type, like a handler's. That is the point: fetching it inside the middleware with `c.service(*KeyStore)` gives a `?*KeyStore`, and `orelse return next.run(c)` lets every request through when the store is missing, which is the one mistake an auth middleware must not make. A resolved value is worked out once per request, so the middleware and the handler behind it share one `CurrentUser`, and a resolver that fails (`fail.unauthorized`) ends the chain through the normal error path.

What a middleware may take after `Next`:

| Argument | What it is |
|---|---|
| `*T`, `*const T` | a service |
| a type carrying `nilo_resolve` | a resolved value |
| `nilo.Path(T)` | the path params by name; each route the middleware covers must have them, or `listen()` says which route and which param |
| `std.mem.Allocator`, `std.Io` | the request arena, the server's loop |

**A query, a header, a form, a body or a bare path param is refused while compiling.** A middleware covers many routes, so it would read a different thing on each. Take the `*Ctx` it already has (`c.query("page")`), or move the read into a resolved value. A middleware with only `*Ctx` and `Next` is unchanged; this is optional. See [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md).

### Excluding routes from a middleware (`without`)

**Every API with accounts has a prefix behind a session and two routes inside it that cannot require one: you cannot require a session to create one.**

```zig
const v1 = app.group("/v1");
try v1.use(requireOperator);          // everything under /v1

const open = v1.without(requireOperator);
try open.post("/sign-up", signUp);    // …except these two
try open.post("/sign-in", signIn);
```

[`without(mw)`](../reference/app.md#group) returns the same group with that one middleware turned off for the routes registered through it. Everything else in the chain still runs: your logger still logs the sign-up, and CORS still answers its preflight.

**The default stays deny**, and that is the point. A route added to `/v1` next month is guarded without anyone doing anything, instead of open because somebody forgot. The exception is also written where the route is, so renaming `/sign-up` moves it. The alternative, a list of paths compared against `c.path()` inside the middleware, would keep guarding a route that no longer exists while the real one was left open, and nothing would fail to compile ([ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)).

Registering the open routes before the `use` call does **not** work, even though it looks like it should: chains are resolved in `listen()`, so the order you register things in has no meaning at all (ADR 008).

### Adding a middleware to one route (`with`)

**`with` does the opposite of `without`: it adds a guard to one endpoint that its neighbours do not have.**

```zig
try app.with(adminOnly).delete("/users/:id", removeUser);
```

`with` returns a group exactly as `without` does, so there is no second way to register a route and nothing new to learn. A middleware added this way runs **innermost**, because the group's session check has to run before the route's own check of what that session is allowed to do.

The two combine:

```zig
const v1 = app.group("/v1");
try v1.use(requireOperator);
try v1.without(requireOperator).with(rateLimitSignups).post("/sign-up", signUp);
```

Both match on the full pattern **and the method**. So renaming the route moves its middleware with it, `/v1/orders` does not cover `/v1/orders/:id`, and a guard on `DELETE /users/:id` does not cover the `GET` beside it. That is the difference from `useOn`, where the prefix is a string somebody has to keep in step with the routes ([ADR 099](../adr/099-a-route-can-say-what-covers-it.md)).

## Built-in logger and CORS

```zig
try app.use(nilo.logger.standard);
try app.use(nilo.cors.permissive);
```

`logger.with(.{ .level = .debug, .slow_micros = 250_000 })` logs ordinary requests at a level you choose and anything slower than `slow_micros` at `.warn`, so slow requests stand out without a second tool.

`logger.with(.{ .skip = &.{ "/healthz", "/metrics" } })` leaves those exact paths out of the log, so a health check called every second does not bury the requests that matter. Whether lines are text or JSON, and from which level, is not the logger's to say: it is `listen(.{ .log = .{ .format = .json, .level = .warn } })`, read at run time so one binary serves a laptop and a collector, and it needs `.logFn = nilo.logFn` in your root `std_options` (`nilo.std_options` has it). In JSON the access line is one flat object with `time` and `level` beside the request's fields ([ADR 262](../adr/262-a-log-line-has-one-sink.md)).

`cors.with(.{ .origins = &.{"https://app.example.com"}, .credentials = true })` also accepts `methods`, `headers`, `expose` and `max_age`. `permissive` is `origins: &.{"*"}` with no credentials, which is reasonable for a public API and wrong for one behind a cookie.

**List every origin you serve.** A production front end plus a staging one is the ordinary case, and `Access-Control-Allow-Origin` can carry only one value, so nilo compares the request's `Origin` against your list and sends back the one that matched:

```zig
try app.use(nilo.cors.with(.{
    .origins = &.{ "https://app.example.com", "https://staging.example.com" },
    .credentials = true,
}));
```

The comparison is unrolled while compiling, so it is one `mem.eql` per entry against a literal, and nothing is allocated. An origin you did not list gets an ordinary response with no `Access-Control-Allow-Origin`, and the browser is what blocks it. Write origins in lowercase, as browsers do: nilo rejects a capital letter at build time rather than letting it silently never match.

### CORS origins from the environment

**When the front-end address differs between deployments, read the origin list at startup with `cors.reading`.** The address of your front end is a fact about *where this was deployed*, not about the program, so staging and production naming different origins is normal. `cors.reading` is the same middleware with its list read from something you fill before `listen()` ([ADR 088](../adr/088-an-origin-is-a-fact-about-the-deployment.md)):

```zig
var origins: nilo.cors.Origins = .empty;      // outlives the App

pub fn main() !void {
    // …settings read with nilo_config…
    var buf: [4][]const u8 = undefined;
    try origins.setSplit(&buf, settings.web_origins);   // "https://a.com,https://b.com"

    try app.use(nilo.cors.reading(&origins, .{ .credentials = true }));
    try app.listen(.{});
}
```

Everything else stays compile-time: the methods, the headers, `credentials` and `max_age`, because none of them changes between deployments of the same service.

Three things to know:

- **The text is borrowed**, so whatever you split has to outlive the server. The environment block and a `.env` file's text both do, and that is what keeps a cross-origin response at zero allocations.
- **`"*"` is rejected.** To allow anybody, use `cors.permissive`, which needs no list.
- A list you never filled rejects every cross-origin request, so nilo says so in the log once, the first time it happens.

## CSRF protection

<!-- compiles: body -->
```zig
try app.use(nilo.csrf.sameOrigin);
```

**A `POST`, `PUT`, `PATCH` or `DELETE` that the browser says came from a page this server does not serve gets a 403, and your handler never runs.** A `GET` is never checked, because a link from another site is a `GET`. A route that changes something on a `GET` is the thing to fix, and no CSRF check can fix it. See [`nilo.csrf`](../reference/middleware.md#nilocsrf).

There is no token to put in your forms. The browser writes `Sec-Fetch-Site` and `Origin` on the request, and a page cannot forge either, so nilo reads those ([ADR 224](../adr/224-a-request-that-changes-something-says-where-it-came-from.md)). `curl`, a webhook and another server send neither and are let through: none of them is carrying somebody else's cookie.

**Why you would want this even with `SameSite=Lax` on your cookie:** Lax lets through a page on another subdomain of your site (a user's upload on `files.example.com`, for instance), and does nothing once a cookie needs `SameSite=None`. This check blocks both.

A front end served from another origin is listed, the same way CORS lists it:

<!-- compiles: body -->
```zig
try app.use(nilo.csrf.with(.{ .origins = &.{"https://app.example.com"} }));
```

When that address comes from the environment, `nilo.csrf.reading(&origins)` takes the same `nilo.cors.Origins` your `cors.reading` does, so one variable filled before `listen()` serves both. A route that really does accept posts from anywhere opts out with `app.without(nilo.csrf.sameOrigin).post(…)`.

## Security headers

<!-- compiles: body -->
```zig
try app.use(nilo.secure.api(.{}));
```

**One line sends the headers a browser reads as policy: `nosniff`, a Content-Security-Policy, HSTS, `X-Frame-Options` and a `Referrer-Policy`.** There are two presets, one for each kind of server. `api` is for a server that answers with JSON: it tells the browser not to render, frame or run anything in the answer. `pages` is for a server that also serves its own front end: scripts, styles, fonts and images load from your own origin, and nothing frames the page but your own. See [`nilo.secure`](../reference/middleware.md#nilosecure) for every header and its value.

A page that loads something from elsewhere names it in its own CSP:

<!-- compiles: body -->
```zig
try app.use(nilo.secure.pages(.{
    .csp = "default-src 'self'; img-src 'self' https://cdn.example.com; connect-src 'self' https://api.example.com",
}));
```

Every header is a field, and `null` turns one off: `.hsts = null` on a server that is only ever reached over plain HTTP inside a cluster. The values with a fixed set of choices are enums, so `.referrer_policy = .same_origin` is checked by the compiler and a typo does not compile. The whole block is put together while compiling, so it costs one store per request and no allocation.

**A server with both an API and pages uses both presets.** Install `api` on the App and `pages` on the group that serves the front end; the group's replaces the App's on its routes. A handler that sets one of these headers itself, such as a `Content-Security-Policy` for one page, replaces that one line, and the rest of the block still goes out.

**HSTS is sent on plain HTTP too, and a browser ignores it there.** Behind a platform that terminates TLS for you (Fly, Render, Cloud Run, a load balancer), it is the only place the header comes from. One thing to know: if you serve `https://localhost` in development, the browser remembers HSTS for `localhost` on every port, so use `.hsts = null` in that build.

## Rate limiting

<!-- compiles: body -->
```zig
try app.useOn("/api", nilo.allowance.with(.{ .per_window = 100, .window_s = 60 }));
```

**This allows a hundred requests a minute from one address; the hundred-and-first gets a 429 with a `Retry-After`, and your handler never runs.** Put it on a group rather than the whole App and routes outside that prefix are not counted at all. A health check that a load balancer hits every second is the usual reason. See [`nilo.allowance`](../reference/middleware.md#niloallowance).

The sign-in form deserves its own limit, because the right number differs by two orders of magnitude:

<!-- compiles: body -->
```zig
try app.useOn("/api", nilo.allowance.with(.{ .per_window = 100, .window_s = 60 }));
try app.useOn("/sign-in", nilo.allowance.with(.{
    .per_window = 5,
    .window_s = 60,
    .name = "sign-in",       // ← counted apart from the one above
}));
```

**`.name` keeps two allowances separate.** Two `with()` calls with the same options share one table. That is usually what you want (the same allowance applied in two places), and wrong as soon as the two are meant to be counted separately. Different numbers already make them different tables; give one a name when the numbers happen to match.

### Limits and policy from the environment

**A rate limit and a Content-Security-Policy are facts about where the program was deployed, so they can be filled from your settings before `listen()`.** Give the options the address of a variable instead of a literal. The variable is a container-level `var`, so its address is known while compiling, and the middleware reads it on each request ([ADR 264](../adr/264-a-deployment-fact-is-a-late-value.md), after [ADR 088](../adr/088-an-origin-is-a-fact-about-the-deployment.md)):

<!-- compiles -->
```zig
const std = @import("std");
const nilo = @import("nilo_http");

// Read with nilo_config (see Settings); a plain struct here.
const Settings = struct {
    api_rate: u32 = 100,                      // API_RATE
    csp: []const u8 = "default-src 'self'",   // CSP
};
var settings: Settings = .{};

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    // settings = read.value().?;  // from the environment, before the next lines
    try app.useOn("/api", nilo.allowance.with(.{ .per_window = &settings.api_rate, .window_s = 60 }));
    try app.use(nilo.secure.pages(.{ .csp = &settings.csp }));
    try app.listen(.{});
}
```

Numbers are `u32` (a `u16` field is a compile error naming the type), and the CSP is a `[]const u8`; both can also stay literals. A held value that cannot work (a count of zero, a count over 1023 on an address-keyed allowance, an empty CSP) answers 500 with a sentence naming the allowance or the policy until it is fixed, because a middleware has no hook at `listen()`. The table's `.slots` stays a constant: it sizes `.bss`.

**Every answer through an allowance says where the client stands**: `RateLimit-Policy: "default";q=100;w=60` and `RateLimit: "default";r=37;t=21`, the remaining count and the seconds to the end of the window, from the IETF draft that clients are starting to read. `.headers = false` turns them off. A million an hour is only writable on `allowance.keyed` (`.per_window = 1_000_000, .window_s = 3600`): an address's slot stops at 1023.

### Rate limiting behind a proxy

**Tell nilo which machines are in front of it, or every request is counted against the proxy's address.** The allowance counts against `c.clientIp()`, which is the socket's address unless you have said what stands in front:

```zig
try app.listen(.{ .trusted_proxies = &.{"private"} });
```

An entry is a CIDR, a bare address, or one of two names: `"private"` for the RFC 1918 ranges plus loopback and their IPv6 equivalents, and `"loopback"` for loopback alone. `trusted_hops = 1` still works and is the older setting. When both are set, `trusted_proxies` wins, because a hop count goes wrong the day somebody puts a CDN in front and nothing says so ([ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)).

Leave it unset behind a proxy and every request looks like it came from the proxy: one address, one slot, and the first busy second locks out everybody. nilo cannot see your deployment, but it can see a rejected request that carried an `X-Forwarded-For` and was counted against the connection's own address, and it logs that the first time it happens.

### Rate limiting: cost and limits

**It costs nothing per request.** The table is sized while compiling and lives in the binary's `.bss`: 131,072 bytes at the default `.slots = 16 * 1024`. Nothing is allocated at startup either, and a program that never calls `with` links none of it. `.slots` is the number of addresses remembered at once, at eight bytes each, and must be a power of two.

**`allowance.keyed` counts against something your application knows instead of the address**: the signed-in account, the API key, the tenant. Ten accounts behind one office NAT would otherwise share one address-keyed allowance, and one account on ten machines would get ten:

```zig
try app.useOn("/api", nilo.allowance.keyed(account, .{
    .per_window = 1000,
    .on_null = .reject,
}));
```

`account` is any `fn (*nilo.Ctx) ?nilo.Str`, and its bytes are not kept: the table stores a tag computed from them. `.on_null` has no default, on purpose. On a sign-in route, silently not counting a request with no key would leave every *failed* sign-in uncounted, which is exactly the attack the limit exists to stop ([ADR 104](../adr/104-a-key-the-application-knows-is-a-word-of-its-own.md)).

Two behaviours are deliberate, and both make the same trade ([ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)). When the table is full, it **forgets the address that has been quiet longest** rather than making two addresses share one allowance. And when two requests reach the same slot at the same instant, it **lets both through**. Being loose for one window is a smaller mistake than rejecting somebody who has made no requests at all.

**The table belongs to one process.** Two instances keep two tables, so `.per_window = 100` admits 200, and a rolling deploy is two instances while it lasts ([ADR 110](../adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md)). A limit that has to hold across instances is not something `allowance` can give yet.

**It is not a defence against a flood.** A rejected request is still read, parsed, matched and answered: cheaply, but not for free. Somebody opening ten thousand sockets is stopped by `max_connections` on `listen`, which counts per process rather than per address.

## Resolved values

**Some things a handler needs are neither a service nor request data: they are worked out from the request.** Authentication is the typical case. The type says how the value is worked out, and a handler asks for it by writing it in its argument list:

```zig
const CurrentUser = struct {
    pub const nilo_resolve = authenticate;   // ← the whole wiring

    id: u32,
    name: Str,
};

fn authenticate(c: *nilo.Ctx, db: *Db) !CurrentUser {
    const token = c.header("Authorization") orelse
        return fail.unauthorized("this endpoint needs a token", .{});
    return db.userForToken(token.view()) orelse
        return fail.unauthorized("that token is not valid", .{});
}

fn me(user: CurrentUser) !Profile {
    return .{ .id = user.id, .name = user.name };
}
```

There is no registration step and nothing to add to `main`. A resolver that fails takes the same path as a failing handler, so it rejects with `fail.unauthorized`. And `me` is still an ordinary function: call `me(.{ .id = 7, .name = … })` in a test.

A resolver can take a `*Ctx`, a service, a `std.mem.Allocator`, and **other resolved values**. That last one is how `Admin` is built from `CurrentUser` instead of from a second copy of the auth code. It can take the path params by name, `Path(T)`, to work something out of one (the tenant out of `:org`); it cannot take a bare path param or the body, because a resolver belongs to the request rather than to a route, and the same `CurrentUser` serves `/me` and `/orders/:id`. From a handler, the field names are checked against that route while compiling; from a middleware's `c.resolve`, they are read at run time and a route without the name is a 500 naming the resolver, the param and the route. Ask for a `*Ctx` if you need the query or the body.

It is worked out **once per request**, which matters as soon as you also want to guard a whole prefix.

## Middleware or resolved value?

```zig
fn requireAdmin(c: *nilo.Ctx, next: nilo.Next, user: CurrentUser) !void {
    if (!user.is_admin) return fail.forbidden("admins only", .{});
    try next.run(c);
}

try app.useOn("/admin", requireAdmin);
fn stats(user: CurrentUser) !Stats { … }   // the same user, not a second lookup
```

**Use middleware to secure a prefix, and a resolved value to hand the user to a handler.** Only routes that name a resolved value get it, so it is the wrong tool for securing a prefix: a handler that forgets the argument is simply not authenticated. `useOn` makes a rule apply whether or not the handler cooperates. A middleware takes the resolved value as an argument, as above, and the middleware's lookup and the handler's argument are the same single lookup. `c.resolve(CurrentUser)` does the same from a middleware that takes no arguments.

See [ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md).

## A permission table for every route

**Check permissions in one table, from one middleware, instead of in every handler.** A check per handler leaves the ninety-first endpoint open with no error and no failing test. A table consulted from one place does not, as long as that place can tell which route it is in front of. `c.routeName()` is the route's `operationId`, the same name the API description prints, so a middleware can key a default-deny table by it, and a test can check the table against the document in both directions:

```zig
const required = std.StaticStringMap(Capability).initComptime(.{
    .{ "createPartner", .manage_partners },
    .{ "addPartnerCapability", .manage_partners },
    // …every write in the product, or it is refused for everybody
});

fn authorize(c: *nilo.Ctx, next: nilo.Next) !void {
    const name = c.routeName() orelse return next.run(c);   // a 404 is not ours to refuse
    if (c.method == .GET or c.method == .HEAD) return next.run(c);
    const needed = required.get(name) orelse
        return fail.forbidden("{s} is not in the permission table", .{name});
    const user = try c.resolve(CurrentUser);
    if (!user.can(needed)) return fail.forbidden("{s} needs {s}", .{ name, @tagName(needed) });
    try next.run(c);
}

try app.useOn("/api", authorize);
```

A route registered without `named` still has a name: the derived one, so `getApiPartners` is what the table sees and what the document says. `app.routes()` lists the same name for each route, for a test that checks every key is a route and every route is a key without going through the document ([ADR 162](../adr/162-a-middleware-can-learn-which-route-it-is-in-front-of.md)).

## Changing an answer after `next`

**`next.run(c)` writes the answer as soon as the handler sends it**, so the code after it can read what was sent and change nothing. A header set there is refused with an error that names `hold`, where Go and Gin lose it without a word.

**`next.hold(c)` keeps the answer unwritten until your middleware returns**, and gives you an `nilo.Answer` to read and change:

<!-- compiles -->
```zig
fn timing(c: *nilo.Ctx, next: nilo.Next) !void {
    const started = nilo.monotonicNanos();
    const answer = try next.hold(c);
    var buf: [32]u8 = undefined;
    const took = (nilo.monotonicNanos() - started) / std.time.ns_per_ms;
    try answer.setHeader("Server-Timing", try std.fmt.bufPrint(&buf, "app;dur={d}", .{took}));
}
```

| | |
|---|---|
| `answer.status()` | the status, or null when nothing below answered |
| `answer.body()` | the body of a whole answer as it was sent, null for a stream or a file |
| `answer.setHeader(name, value)` | a header on the answer |
| `answer.setTrailer(name, value)` | a [trailer](./responses.md#trailers) on the answer, a stream's too |
| `answer.replace(status, content_type, body)` | a different whole answer, such as a 304 or a page of HTML; the body is copied |

`replace` is refused once a head has gone, which is a stream's. A stream's trailers can still be set, because its end is held as well.

**A failure after `hold` replaces a held whole answer.** A failure below `hold` comes back from it as an error, the same as from `run`, and nilo answers it after the chain. So `hold` does not show you a failure's answer. To put a header on every answer including failures, set it with `defer` around `run`:

```zig
fn served(c: *nilo.Ctx, next: nilo.Next) !void {
    defer c.setHeader("X-Served-By", "nilo") catch {};
    try next.run(c);
}
```

**Holding costs a copy.** A body handed to `c.send` has to outlive the handler, so under `hold` it is copied into the request arena. That is free while the body fits in `arena_keep` (16 KiB by default) and expensive above it: a 64 KiB body cost 63% of throughput in the measurement behind [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md). A value a typed handler returns, `c.sendJson`, `c.sendKept` and a static file are not copied. [`c.sendKept(status, content_type, body)`](../reference/ctx.md#answering) is `send` for a body that already outlives the chain, such as one in the arena or a global, and never copies it. Only the routes behind a `hold` pay, and a middleware that does not call it costs nothing.

## Writing your own middleware

**The signature is `fn (c: *nilo.Ctx, next: nilo.Next) !void`.** There is no registration type and no builder: `app.use` takes the function.

Middleware works at the `Ctx` layer on purpose. It has no argument list to inject into, and giving it one would mean a second dependency system that runs for every request whether or not anybody wanted it. What it can do instead is set headers, read the request, reject it, and hand something to the handler through `c.cacheResolved`, which is what `c.resolve` uses.
