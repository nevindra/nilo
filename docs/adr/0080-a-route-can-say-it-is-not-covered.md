# 0080 — a route can say a middleware does not cover it

**Status:** accepted
**Amends:** [ADR 0009](./0009-middleware-is-an-onion-of-ctx-functions.md)

## Context

Every API with accounts has the same shape: one prefix, almost all of it behind
a session, and two routes inside it that cannot be — **you cannot require a
session to create one.**

nilo offered `app.use(mw)`, `app.useOn(prefix, mw)`, and the same two on a
group. There was nothing that removed a middleware, nothing that attached one to
a single route, and no `exceptOn`. So `g.use(requireOperator)` on `/v1` guarded
`/v1/sign-up` too, and sign-up answered 401 — which is what it did, on the first
run of the application that found this, in ten tests at once.

**Registering the open routes first does not help**, and that is the expensive
part: it looks like it should. Chains are resolved in `listen()`, so mount order
carries no meaning at all (ADR 0009). The failure is silent, immediate and
un-Googleable.

Three ways out existed and all three are bad:

1. **A path skip-list inside the middleware.** Default-deny, which is the right
   direction: a route added later is guarded by accident rather than exposed by
   accident. The cost is that the exception is a **string** compared against
   `c.path()`, in a framework whose whole claim is that the compiler checks the
   contract. Rename the route and the guard protects a 404 while the real one
   goes open, and nothing fails to compile.
2. **`useOn` per resource subgroup.** Declarative, and default-*allow*: every new
   prefix is unguarded until somebody remembers. This is the one that ships a
   security hole eventually.
3. **Move the open routes out of the prefix** — `/sign-in` beside `/v1` rather
   than inside it. Free, and it means the URL layout is decided by the middleware
   rather than by the API.

A second cost was stacked on (1). A `Middleware` is a bare
`*const fn (*Ctx, Next) anyerror!void` with nowhere to keep state, so a prefix
has to be a comptime parameter of a function returning one — and **a `Group` did
not publish the prefix it was built with.** `Group(prefix)` had `prefix` as a
comptime parameter of the type and no `pub const` inside it, so a
`mount(g: anytype)` plugin could not ask `g` where it was mounted. The
application that found this passed the prefix as a second argument and kept the
two in step with a local constant. Parsing `@typeName(@TypeOf(g))` was the only
alternative and is not something to ship.

## Decision

**`without(mw)` hands back the same group with that middleware off for the
routes registered through it.**

```zig
const v1 = app.group("/v1");
try v1.use(requireOperator);

const open = v1.without(requireOperator);
try open.post("/sign-up", signUp);
try open.post("/sign-in", signIn);
```

Three properties, and each of them is why one of the three workarounds lost:

- **The default stays deny.** The guard is on the group; a route says otherwise
  about itself. A route added next month is guarded because nobody did anything.
- **The exception is where the route is.** Renaming `/sign-up` moves it, because
  the exception is recorded by the same `joined(prefix, pattern)` the
  registration uses — there is no second copy of the string to fall out of step.
- **The URL layout is not decided by the middleware.** `/sign-up` stays inside
  `/v1` where it belongs.

Everything else in the chain still runs: the logger still logs the sign-up, CORS
still answers its preflight. It is one middleware off one route, not a route with
no chain.

The exclusion list is a **comptime parameter of the group's type** —
`GroupOf(prefix, excluded)`, of which `Group(prefix)` is the empty case — so
which routes carry an exception is settled while compiling, and the `inline for`
that records them compiles to nothing for every group that has none.

**And `mounted_at` is published**, on a group and on the App. One line, and it
is what makes a plugin able to know where it is — which several other features
would want too, and which had no answer at all.

## What was rejected

**Per-route middleware — `g.postWith(&.{guard}, "/x", h)`.** It is the positive
form of the same idea and it is default-*allow*, which is workaround (2) with
nicer syntax. It also needs a second copy of all seven verb methods.

**A `g.open(pattern, handler)` that runs no middleware at all.** Simpler, and
wrong: it drops the logger and CORS from exactly the routes an operator most
wants to see in the log.

**Making `use` take an `except` list of patterns.** The strings end up in the
`use` call rather than in the middleware, which is a smaller version of the same
problem: renaming the route still leaves the exception behind, and now it is
somewhere else in the file.

## What it costs

Nothing on any of the four axes. The exemptions are consulted once per route in
`resolveChains`, which runs at `listen()`; the request path is unchanged, because
what a request sees is still a resolved chain of function pointers. An App with
no `without` call carries one empty `ArrayList` and never looks at it.
