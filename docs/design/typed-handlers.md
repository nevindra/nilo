# Typed handlers

**A plain function is nilo's real API: while compiling, nilo reads its argument list and turns it into exactly the `Ctx` calls you would have written by hand, so the only cost is making the error messages good, with nothing paid at run time.**

**Guide:** [Handlers](../guide/handlers.md), [Services](../guide/services.md) · **Reference:** [Handler arguments](../reference/handlers.md#handler-arguments), [`Run`](../reference/core.md#run), [`AnyScope`](../reference/core.md#anyscope)

The code is `http/typed.zig` (the argument loop, `requirements`, `checkAnswer`), `http/wiring.zig` (`missingService`, `Requirement`), `http/app.zig` (`provide`), `http/ctx.zig` (`resolve`, `cachedResolved`), and `core/scope.zig` (`Run`, `AnyScope`).

## Overview

```
  fn handler(a: *Db, b: PathType, c: SomeResolved, d: BodyStruct) !T
                |        |             |               |
             service   path/query   nilo_resolve      plain
             by type   by nilo_parse  (once, cached    struct
                                       on Ctx)         (JSON)
                |        |             |               |
                `--------+-------------+---------------'
                         v
              typed.requirements collects services and resolver chains,
              per route, while compiling
                         v
              listen() checks every one against app.provide()
              before the socket opens

  A resolver, a Db statement, an ordinary service function: written
  against a Scope (arena(), str()), a shape rather than an interface,
  so the same body runs under a Ctx and under a Run.

    *Ctx  ── request ──┐                    ┌── Run ── a tick, a CLI, a test
                        ├── same shape ──────┤
              give/resolve on Run, entropy on both

  Storing one as a callback (a bus, a queue) erases it: AnyScope, a
  pointer and a five-entry function table, made only where the erasure
  happens.
```

## Rules

1. **A typed handler is a thin compile-time layer over `Ctx`, never a replacement for it.** It costs nothing at run time; the work goes into a clear `@compileError` when an argument does not fit. [ADR 002](../adr/002-typed-handlers-are-a-thin-layer-over-ctx.md)
2. **A service is matched by the type of a handler's argument**, against a run-time registry keyed by `@typeName`. `app.provide` fills it, in any order, before `listen()`. [ADR 002](../adr/002-typed-handlers-are-a-thin-layer-over-ctx.md), [ADR 005](../adr/005-services-via-a-runtime-registry.md)
3. **A service a route needs but nobody provided is caught at `listen()`, naming the route and the type**, not on the first request that reaches it. `app.missingService()` returns the same information as plain data, for a test that checks the wiring without a socket. [ADR 005](../adr/005-services-via-a-runtime-registry.md)
4. **A per-request value is declared on its own type with `nilo_resolve`, and a handler gets it by listing it as an argument.** There is no registration step, and the compiler checks whether the value can be produced before the route ever runs. [ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md)
5. **A resolver may take a `*Ctx`, a service, the request arena, other resolved values and the path params by name (`Path(T)`), and nothing else.** A bare path param, a query struct or the body would tie the value to one route, while a resolver belongs to the whole request; a `Path(T)` names what it reads, is held against the handler's route while compiling and, from a bare middleware, is read by name at run time. A loop between resolvers is a compile error that prints the loop. [ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md)
6. **A resolved value is computed once per request and cached on the `Ctx`**, so a guard and the handler behind it share one lookup instead of doing it twice. It lives in the request arena and ends with the request. [ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md)
7. **Middleware guards; a resolved value provides.** Middleware runs on everything under its prefix, whatever the handler does; a resolved value is only computed for a route that asks for it. A guard uses `c.resolve` to reach a value a handler further down also wants. [ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md)
8. **A `Run` has the same Scope shape as a `Ctx`, so a service function written against `arena()` and `str()` works for a request, a scheduled tick, a CLI or a test alike.** `Run.entropy` generates a key the same way `Ctx.entropy` does, given an `Io` when the Run is created (`Run.initIo`); a `Run` created without one returns `error.NoIo` instead of making up bytes. [ADR 128](../adr/128-a-scope-that-can-mint-a-key.md)
9. **What a request works out for itself, a tick has to be given.** `Run.give(V, value)` sets a value once at the top, and `Run.resolve(V)` returns it, including a `null` that was given. `error.NotGiven` means nobody called `give`; it is never a silent "missing". A request never calls `give`: there, the same value is a `nilo_resolve` type, which removes the third state instead of detecting it. [ADR 133](../adr/133-a-value-that-reaches-the-bottom.md)
10. **Storing a Scope behind a function pointer (a bus, a queue, any stored callback) turns it into an `AnyScope`: a pointer plus a five-entry function table, created only at that point.** `AnyScope.of(scope)` costs two stores and no allocation; each call through it costs one indirect call, paid only by whoever stored it. [ADR 144](../adr/144-a-scope-that-crosses-a-function-pointer.md)
11. **An `AnyScope` answers `resolve` from what the underlying Scope already holds, and never runs a resolver.** A type that is only requested on the far side of the function pointer returns `error.NotGiven` unless something earlier already resolved it. The fix is a bare `_ = try c.resolve(V);` in the middleware that already checked the value, before `next.run`. [ADR 144](../adr/144-a-scope-that-crosses-a-function-pointer.md)
12. **A `?` around a return wrapper (`Status`, `Response`, `Redirect`, `Versioned`) is rejected while compiling, and the message says where the `?` should go.** nilo reads `Status(201, ?T)`; `?Status(201, T)` used to pass the wrapper check and reach the JSON writer as an unknown struct. [ADR 203](../adr/203-a-question-mark-goes-inside-the-wrapper.md)

## Decisions

| ADR | What it decides |
|---|---|
| [002](../adr/002-typed-handlers-are-a-thin-layer-over-ctx.md) | A typed handler is a compile-time layer over `Ctx`, free at run time |
| [005](../adr/005-services-via-a-runtime-registry.md) | Services are matched through a run-time registry, checked at `listen()` |
| [015](../adr/015-resolved-values-are-declared-by-their-type.md) | `nilo_resolve`: a per-request value declared by its type, not stored on the request |
| [128](../adr/128-a-scope-that-can-mint-a-key.md) | `Run.entropy`: a Scope that can generate a key, like `Ctx.entropy` |
| [133](../adr/133-a-value-that-reaches-the-bottom.md) | `Run.give`/`Run.resolve`: what a tick cannot work out, it is given, with `error.NotGiven` instead of null |
| [144](../adr/144-a-scope-that-crosses-a-function-pointer.md) | `AnyScope`: a Scope type-erased only where it has to pass through a function pointer |
| [203](../adr/203-a-question-mark-goes-inside-the-wrapper.md) | A `?` outside a return wrapper is rejected, saying where it belongs |

Related topics: why a Scope is a shape checked while compiling instead of an interface at the root is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md); why `Ctx.entropy` is only reachable from a `Ctx` and not from a module below it is [ADR 042](../adr/042-entropy-belongs-to-the-loop.md); why `Ctx.hashPassword` takes a permit from a process-wide Gate instead of relying on `nilo.blocking` alone is [ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md); the four axes every one of these decisions was measured against are [ADR 017](../adr/017-the-trade-budget-has-four-axes.md); what `?T` means as a return type on its own is [ADR 023](../adr/023-a-failure-mode-belongs-in-the-return-type.md); reading the JSON a body argument arrives as is covered in [json](json.md).

## Open questions

- **A service argument is found by scanning the registry on every request**, 1.2 ns per entry: 1.6% of a request with four services, rising to 13.4% with thirty-two. This is accepted under ADR 017's limit for every app in `examples/`. The fix, resolving services into the route at `listen()`, is open in [`docs/todo.md`](../todo.md).
