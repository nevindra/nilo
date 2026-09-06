# A route can say what covers it

[ADR 0080](0080-a-route-can-say-it-is-not-covered.md) gave a route a way to say
a middleware does **not** cover it, and closed the shape every API with
accounts has: a prefix behind a session, and the two routes inside it that
cannot be, because you cannot require a session to create one.

It said out loud what it left open:

> the awkward case is a route wanting *more* than its neighbours, and a group
> of one says that, just not where the route is written.

That is the other direction, and it is what `with` is.

## The vocabulary was one-sided

`use`, `useOn`, `group().use` and `without` are the whole of it, and the first
three scope by path. So a single endpoint behind an extra guard meant one of:

```zig
// A prefix invented to match exactly one route, and nothing that stops a
// sibling being added under it later.
try app.useOn("/v1/users/:id", adminOnly);

// Or a group holding one route, where the guard is three lines from the
// route it guards.
const danger = app.group("/v1/users");
try danger.use(adminOnly);
try danger.delete("/:id", removeUser);
```

Both work. What is wrong with them is the same thing ADR 0080 said about a
skip-list of paths inside a middleware: the guard and the route it guards are
held together by a string somebody has to keep in step. Rename the route and
the first one silently guards nothing; add a sibling and it silently guards
that too.

Gin and Fiber both take middleware as extra arguments to the route itself —
`r.DELETE("/users/:id", adminOnly, removeUser)`. That solves the drift and
costs a second shape: a route is registered one way with middleware and another
way without.

## What it does now

```zig
try app.with(adminOnly).delete("/users/:id", removeUser);
```

`with` hands back a group, exactly as `without` does. There is no second way to
register a route, no options struct, and nothing new to learn — a reader who
knows `without` knows this. `GroupOf(prefix, excluded)` is now
`GroupWith(prefix, excluded, &.{})`, so nothing that named the old type broke.

The two compose, because they are the same vocabulary:

```zig
const v1 = app.group("/v1");
try v1.use(requireOperator);
try v1.without(requireOperator).with(rateLimitSignups).post("/sign-up", signUp);
```

**A carried middleware runs innermost.** Not a coin flip between two orders:
the group's session check has to have run by the time the route's own check of
what that session may do runs. Attaching last in the chain is what the nesting
means.

**It is exact, and it is the joined pattern.** `mw.Attached` mirrors
`mw.Exemption` field for field, and both are recorded by the registration
itself, through the same `joined(prefix, pattern)` call. Renaming the route
moves the middleware with it. `/v1/orders` does not cover `/v1/orders/:id` and
does not cover `/v1/orders-archive`, which is the difference between this and
`useOn`.

## What it costs

**Nothing per request.** Chains are resolved once at `listen()`
([ADR 0009](0009-middleware-is-an-onion-of-ctx-functions.md)), so a route
carrying a middleware costs exactly what a route covered by a `use` costs:
running it. `chainFor` grows a second loop over a list that is empty for every
App that never calls `with`.

**Nothing per connection**, and nothing on the stack: `attached` is a comptime
parameter of the group's type, and the group has no fields but the App pointer.
An empty `inline for` compiles to nothing, which is the same trick `excepting`
already used.

**Startup**: one entry per `with` per route, in a list beside the exemptions.

## What was rejected

**Middleware as extra arguments to the route.** What Gin and Fiber do. It is
the shape everybody arriving from Go expects, and it means two registration
signatures per verb — fourteen more functions on `App`, fourteen more on
`Group` — where `with` needs one function and no new shape at all.

**An options struct on the route.** `app.get(pattern, handler, .{ .use = … })`.
Same objection, plus it puts the guard after the handler, which is the wrong
way round for something that runs first.

**A prefix that matches one route.** What people do today. It is the string
that has to be kept in step, which is the failure this exists to stop.
