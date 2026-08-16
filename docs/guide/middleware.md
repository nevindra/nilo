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

## The built-in two

```zig
try app.use(nilo.logger.standard);
try app.use(nilo.cors.permissive);
```

`logger.with(.{ .level = .debug, .slow_micros = 250_000 })` logs ordinary
requests at a level of your choosing and anything slower than `slow_micros` at
`.warn`, so slow requests stand out without a second tool.

`cors.with(.{ .origin = "https://app.example.com", .credentials = true })` —
also `methods`, `headers`, `expose`, `max_age`. `permissive` is `origin: "*"`
with no credentials, which is reasonable for a public API and wrong for one
behind a cookie.

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
