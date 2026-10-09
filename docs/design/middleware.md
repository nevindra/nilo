# Middleware

**Middleware is a stack of `Ctx` functions wrapped around the handler, worked out once at `listen()`, so the order of `use` calls and routes does not matter, and a single route can add or remove middleware for itself.**

**Guide:** [Middleware and resolved values](../guide/middleware.md) · **Reference:** [Middleware](../reference/middleware.md)

The code is `http/middleware.zig` (`Middleware`, `Next`, `chainFor`), `http/typedmw.zig` (a middleware given services and resolved values), `http/app.zig` (`use`, `useOn`, `with`, `without`, `GroupWith`), `http/wiring.zig` (`resolveChains`), and `http/ctx.zig` (`routeName`).

## Overview

```
  registration time                          listen()                    request time
  ────────────────                          ──────────                   ────────────
  app.use(logger)         ─┐
  v1.use(requireOperator)  ├─► per-route exclusions/attachments ─► resolveChains ─► []Middleware, resolved
  v1.without(op).with(rl)  ─┘        (with/without recorded by                        │
       .post("/sign-up")             the joined prefix+pattern)                       ▼
                                                                          Next{ rest, handler }.run(c)
                                                                          mw1(c, next) → mw2(c, next) → … → handler(c)
                                                                          (before next.run: on the way in
                                                                           after next.run: on the way out)
```

## Rules

1. **Middleware works on the `Ctx` and produces no value for the handler: middleware enforces, a resolved value provides.** They are not two ways to do the same thing. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
2. **A middleware is one function, `fn(*Ctx, Next) anyerror!void`, wrapped around the rest of the chain, not split into `before`/`after` hooks.** A local variable needed on both sides of `next.run(c)`, such as a timer's start, would have nowhere to live with two hooks; with one function it is an ordinary local. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
2a. **A middleware may be given what it needs after `Next`: services, resolved values, `Path(T)`, the arena.** It is wrapped while compiling into the bare form, and what it declares is held at `listen()`: a missing service stops the server, and a `Path(T)` is held against every route the middleware covers. A query, a body or a bare path param is refused, because a middleware covers many routes. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md), `http/typedmw.zig`
3. **Not calling `next` ends the chain**, which is all a middleware that rejects a request (such as auth) needs to do. A middleware that fails goes through the same fail-function path a handler does (full rule on [`errors`](./errors.md)). [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
4. **The chain is a slice built once, at `listen()`, by `resolveChains`, not fused into a single function at compile time.** `Next` is two words passed by value and allocates nothing per request. Fusing the chain was measured against ADR 017's throughput threshold and rejected, because of the ordering rules it would impose on every route. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
5. **Because chains are built at `listen()` rather than when each route is registered, it does not matter whether `use` comes before or after a route.** The order of `use`/`useOn` calls among themselves still matters: middleware runs in registration order, and middleware registered with a prefix only runs on routes under that prefix. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
6. **The chain runs even when no route matches**, with the 404 response in place of the handler, so a logger sees every miss and CORS can answer a preflight for a path that does not exist. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
7. **A group can exclude a middleware.** `without(mw)` returns the same group (or the App) with `mw` turned off for routes registered through it. The rest of the chain still runs, the default is still "deny", and the exception is recorded against the same `joined(prefix, pattern)` the route uses, so renaming the route moves the exception with it. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
8. **A route can add a middleware for itself alone with `with(mw)`**, the same idea in the other direction. `app.with(adminOnly).delete("/users/:id", removeUser)` needs no second way to register routes and no options struct. The added middleware runs innermost, after whatever the group already requires. [ADR 099](../adr/099-a-route-can-say-what-covers-it.md)
9. **A guard gets what it needs from a resolved value; it does not pass values to the handler through untyped state.** There is no `c.locals` map: a middleware that loads a user and a handler that wants it both call `c.resolve(T)`, which runs once per request. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
10. **A group exposes the prefix it was built with as `mounted_at`**, so a plugin or an exclusion that needs its prefix reads it, instead of parsing `@typeName` or taking it as a second argument that could drift from the first. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
11. **A middleware can call `c.routeName()` to learn which route it is in front of**: the given or derived `operationId`, or null when nothing matched (a 404, a 405, a static file). It is worked out once at registration by the same function the OpenAPI document uses, so a table keyed by the document's names and a table keyed by `routeName` cannot disagree about which operation is which. [ADR 162](../adr/162-a-middleware-can-learn-which-route-it-is-in-front-of.md)
12. **There is no `recover` middleware, because Zig cannot recover from a panic.** `@panic` stops the process; nothing unwinds and no `defer` runs. Instead, a panic handler names the request that was running, using the same fiber slot `fail` uses (full rule on [`errors`](./errors.md)), and the documentation advises running `ReleaseSafe` under a supervisor. [ADR 007](../adr/007-no-recover-middleware.md)

## Decisions

| ADR | What it decides |
|---|---|
| [007](../adr/007-no-recover-middleware.md) | Why there is no `recover` middleware, and what the panic handler does instead |
| [008](../adr/008-middleware-is-an-onion-of-ctx-functions.md) | The wrapped-function design, `Next`, chains built at `listen()`, and `without` |
| [099](../adr/099-a-route-can-say-what-covers-it.md) | `with`, the counterpart to `without`, added innermost |
| [162](../adr/162-a-middleware-can-learn-which-route-it-is-in-front-of.md) | `c.routeName()`, so a permission table can use the same names the document prints |
| [262](../adr/262-a-log-line-has-one-sink.md) | `nilo.logFn`, the one sink: JSON that is JSON, a handler's line joined to its request, format and level set in `listen()`, and `logger`'s `skip` |

Related topics: the fail-function path a middleware's failure goes through, and the fiber-bound `Failure` the panic handler reads, are in [`errors`](./errors.md) (ADR 004, ADR 006); the built-in middleware (`logger`, `cors`, `allowance`, `deadline`, `maxBody`) is documented in the reference, and `allowance`'s own rules are in [`rate-limiting`](./rate-limiting.md); resolved values as the alternative to a guard passing state is [ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md) (typed-handlers); the `operationId` a route can give itself, which `routeName` returns, is [ADR 119](../adr/119-a-route-can-say-its-own-name.md) (openapi).

## Open questions

Nothing is open.
