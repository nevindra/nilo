# Middleware and resolved values

Two ways to put something between the request and the handler. They are not
interchangeable: **middleware enforces, a resolved value provides.**

## Middleware

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

An onion: everything before `next.run(c)` happens on the way in, everything after
on the way out. Not calling `next` at all ends the chain, which is all a
rejecting auth middleware has to do:

```zig
fn requireToken(c: *nilo.Ctx, next: nilo.Next) !void {
    const token = c.header("Authorization") orelse
        return fail.unauthorized("this endpoint needs a token", .{});
    if (!valid(token.view())) return fail.unauthorized("that token is not valid", .{});
    try next.run(c);
}
```

Returning an error goes down exactly the same path a failing handler does.

Registration order between `use` and `get` doesn't matter — chains are resolved
when `listen()` is called, so middleware registered after a route still applies
to it. Middleware also runs when nothing matched, so your logger sees 404s and
CORS can answer a preflight for a path that has no route.

`useOn(prefix, mw)` scopes by the front of the request path.
`group("/api").use(mw)` is the same thing said better — see
[Routing](./routing.md#groups).

See [ADR 0009](../adr/0009-middleware-is-an-onion-of-ctx-functions.md).

### The two routes that can't be guarded

Every API with accounts has the same shape: a prefix behind a session, and two
routes inside it that can't be — **you can't require a session to create one.**

```zig
const v1 = app.group("/v1");
try v1.use(requireOperator);          // everything under /v1

const open = v1.without(requireOperator);
try open.post("/sign-up", signUp);    // …except these two
try open.post("/sign-in", signIn);
```

`without(mw)` hands back the same group with that one middleware off for the
routes registered through it. Everything else in the chain still runs — your
logger still logs the sign-up, CORS still answers its preflight.

**The default stays deny**, which is the point: a route added to `/v1` next month
is guarded because nobody did anything, rather than open because nobody
remembered. And the exception is written where the route is, so renaming
`/sign-up` moves it — where the alternative, a list of paths compared against
`c.path()` inside the middleware, would go on guarding a route that no longer
exists while the real one went open, with nothing failing to compile
([ADR 0080](../adr/0080-a-route-can-say-it-is-not-covered.md)).

Registering the open routes before the `use` call does **not** work and it looks
like it should: chains are resolved in `listen()`, so mount order carries no
meaning at all (ADR 0009).

### And the one route that wants more

The other direction, for an endpoint that wants a guard its neighbours do not:

```zig
try app.with(adminOnly).delete("/users/:id", removeUser);
```

`with` hands back a group exactly as `without` does, so there is no second way
to register a route and nothing new to learn. A carried middleware runs
**innermost** — the group's session check has to have run by the time the
route's own check of what that session may do runs.

The two compose, because they are the same vocabulary:

```zig
const v1 = app.group("/v1");
try v1.use(requireOperator);
try v1.without(requireOperator).with(rateLimitSignups).post("/sign-up", signUp);
```

Both match on the joined pattern **and the method**, so renaming the route moves
its middleware with it, `/v1/orders` does not cover `/v1/orders/:id`, and a
guard on `DELETE /users/:id` does not cover the `GET` beside it. That last part
is the difference between this and `useOn`, where the prefix is a string
somebody has to keep in step
([ADR 0126](../adr/0126-a-route-can-say-what-covers-it.md)).

## The ones that come with it

```zig
try app.use(nilo.logger.standard);
try app.use(nilo.cors.permissive);
```

`logger.with(.{ .level = .debug, .slow_micros = 250_000 })` logs ordinary
requests at a level of your choosing and anything slower than `slow_micros` at
`.warn`, so slow requests stand out without a second tool.

`cors.with(.{ .origins = &.{"https://app.example.com"}, .credentials = true })`
— also `methods`, `headers`, `expose`, `max_age`. `permissive` is
`origins: &.{"*"}` with no credentials, which is reasonable for a public API
and wrong for one behind a cookie.

**Name as many origins as you serve.** A production front end and a staging one
is the ordinary case, and `Access-Control-Allow-Origin` carries one value, so
nilo compares the request's `Origin` against your list and sends back the one
that matched:

```zig
try app.use(nilo.cors.with(.{
    .origins = &.{ "https://app.example.com", "https://staging.example.com" },
    .credentials = true,
}));
```

The compare is unrolled while compiling, so it is one `mem.eql` per entry
against a literal and nothing is allocated. An origin you did not name gets an
ordinary response with no `Access-Control-Allow-Origin` on it, and the browser
is what refuses it. Write them lowercase — a browser does, and nilo refuses a
capital letter at build time rather than letting it silently never match.

### When the origins come from the environment

The address of your front end is a fact about *where this was deployed*, not
about the program, so staging and production naming different ones is the
ordinary case rather than an awkward one. `cors.reading` is the same middleware
with its list read from somewhere you fill before `listen()`
([ADR 0110](../adr/0110-an-origin-is-a-fact-about-the-deployment.md)):

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

Everything else stays where it was: the methods, the headers, `credentials` and
`max_age` are all still compile-time, because none of them changes between one
deployment of the same service and another.

Three things worth knowing. **The text is borrowed**, so whatever you split has
to outlive the server — the environment block and a `.env`'s text both do, and
that is what keeps a cross-origin response at zero allocations. **`"*"` is
refused**: answering anybody is `cors.permissive`, which needs no list at all.
And a list you never filled refuses every cross-origin request, so nilo says so
in the log once, the first time it happens.

## When one client asks too often

<!-- compiles: body -->
```zig
try app.useOn("/api", nilo.allowance.with(.{ .per_window = 100, .window_s = 60 }));
```

A hundred requests a minute from one address; the hundred-and-first is a 429
with a `Retry-After`, and your handler never runs. Put it on a group rather than
the whole App and the routes outside that prefix are not counted at all — a
health check a load balancer hits every second is the usual reason.

The sign-in form is the case worth naming separately, because the number is
different by two orders of magnitude:

<!-- compiles: body -->
```zig
try app.useOn("/api", nilo.allowance.with(.{ .per_window = 100, .window_s = 60 }));
try app.useOn("/sign-in", nilo.allowance.with(.{
    .per_window = 5,
    .window_s = 60,
    .name = "sign-in",       // ← counted apart from the one above
}));
```

**`.name` is what keeps two allowances separate.** Two `with()` calls carrying
the same options are the same table, which is usually what you want — the same
allowance applied in two places — and is wrong the moment the two are meant to
be counted apart. Different numbers already make them different; give one a name
when the numbers happen to match.

### Behind a proxy, say which machines are in front

This counts against `c.clientIp()`, which is the socket's address unless you
have told nilo what stands in front:

```zig
try app.listen(.{ .trusted_proxies = &.{"private"} });
```

An entry is a CIDR, a bare address, or one of two names — `"private"` for the
RFC 1918 ranges plus the loopback and their v6 equivalents, `"loopback"` for the
loopback alone. `trusted_hops = 1` still works and is the older shape; the
description wins when both are set, because a count goes wrong the day somebody
puts a CDN in front and nothing says so
([ADR 0129](../adr/0129-a-proxy-is-trusted-by-which-one-it-is.md)).

Leave it at zero behind a proxy and every request looks like it came from the
proxy — one address, one slot, and the first busy second locks out everybody.
nilo cannot see your deployment, but it can see a refusal whose request carried
an `X-Forwarded-For` and was counted against the connection's own address, and
it says so in the log the first time that happens.

### What it costs, and what it is not

Nothing per request: the table is sized while compiling and lives in the
binary's `.bss`, 131,072 bytes at the default `.slots = 16 * 1024`. Nothing is
allocated at startup either, and a program that never calls `with` links none of
it. `.slots` is the number of addresses remembered at once, at eight bytes each,
and it is a power of two.

**`allowance.keyed` counts against something you know instead** — the account
that signed in, the API key, the tenant. Ten accounts behind one office NAT
share an address-keyed allowance they should not, and one account on ten
machines gets ten:

```zig
try app.useOn("/api", nilo.allowance.keyed(account, .{
    .per_window = 1000,
    .on_null = .reject,
}));
```

`account` is any `fn (*nilo.Ctx) ?nilo.Str`, and its bytes are not kept — what
goes in the table is a tag computed from them. `.on_null` has no default and
that is deliberate: on a sign-in route a silent "not counted" leaves every
*failed* sign-in uncounted, which is the attack the route exists to stop
([ADR 0131](../adr/0131-a-key-the-application-knows-is-a-word-of-its-own.md)).

Two things it does on purpose, both the same trade
([ADR 0114](../adr/0114-an-allowance-is-a-table-sized-while-compiling.md)). A
table with no room left **forgets whichever of its addresses has been quiet longest**
rather than making two addresses share one allowance, and a slot two requests
reach at the same instant **lets them both through**. Being loose for one window
is a smaller wrong than refusing somebody who has made no requests at all.

And it is not a defence against a flood. A refused request is still read,
parsed, matched and answered — cheaply, but not for free. Somebody opening ten
thousand sockets is stopped by `max_connections` on `listen`, which counts per
process rather than per address.

## Resolved values

Some things a handler needs are neither a service nor request data: they are
worked out *from* the request. Authentication is the whole genre. So the type
says how it is worked out, and a handler asks for it by writing it in its
argument list:

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

No registration step, nothing added to `main`. A resolver that fails goes down
the same path a failing handler does, so `fail.unauthorized` is how it refuses.
And `me` is still an ordinary function: `me(.{ .id = 7, .name = … })` in a test.

A resolver takes a `*Ctx`, a service, a `std.mem.Allocator`, and **other resolved
values** — that last one being how `Admin` gets built out of `CurrentUser`
instead of out of a second copy of the auth code. It can't take a path param or
the body: a resolver belongs to the request, not to a route, and the same
`CurrentUser` serves `/me` and `/orders/:id`. Ask for a `*Ctx` if you need one.

It's worked out **once per request**, which matters as soon as you also want to
guard a whole prefix.

## Which one to reach for

```zig
fn requireAdmin(c: *nilo.Ctx, next: nilo.Next) !void {
    const user = try c.resolve(CurrentUser);
    if (!user.is_admin) return fail.forbidden("admins only", .{});
    try next.run(c);
}

try app.useOn("/admin", requireAdmin);
fn stats(user: CurrentUser) !Stats { … }   // the same user, not a second lookup
```

Only routes that name a resolved value get it, so it's the wrong tool for
securing a prefix — a handler that forgets the argument simply isn't
authenticated. `useOn` is what makes a rule apply whether the handler cooperates
or not, and `c.resolve` is how the two meet: the middleware's lookup and the
handler's argument are the same one lookup.

See [ADR 0016](../adr/0016-resolved-values-are-declared-by-their-type.md).

## Writing your own middleware

The signature is `fn (c: *nilo.Ctx, next: nilo.Next) !void`. There is no
registration type and no builder — `app.use` takes the function.

Middleware is at the `Ctx` layer on purpose: it has no argument list to inject
into, and giving it one would mean a second dependency system that runs for every
request whether or not anybody wanted it. What it can do instead is set headers,
read the request, refuse, and hand something to the handler through
`c.cacheResolved` — which is what `c.resolve` uses.
