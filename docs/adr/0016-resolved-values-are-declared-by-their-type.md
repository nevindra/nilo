# A resolved value is declared by its type, not stashed on the request

ADR 0009 shipped middleware with one gap written into its consequences:

> **Middleware cannot hand values to a handler.** […] auth middleware can reject a request but cannot pass the resolved user to the handler. […] it is the concrete thing a request-scoped value concept has to solve in v2, and it should be recorded as that rather than patched over with a `c.locals` map that would smuggle untyped state back in through the side door.

This is that concept. A type says how it is worked out from a request, and a handler asks for it by writing it in its argument list:

```zig
const CurrentUser = struct {
    pub const nilo_resolve = authenticate;

    id: u32,
    name: Str,
};

fn authenticate(c: *Ctx, db: *Db) !CurrentUser {
    const token = c.header("Authorization") orelse
        return fail.unauthorized("this endpoint needs a token", .{});
    return db.userForToken(token.view()) orelse
        return fail.unauthorized("that token is not valid", .{});
}

fn me(user: CurrentUser) !Profile { … }
```

There is no registration step. `app.provide` is not called, nothing is added to `main`, and the route is written the way every other route is.

## Why not a type map on the request

The obvious design, and the one every neighbouring framework picked: Go's `context.Value`, axum's `Extensions`, Fiber's `c.Locals`. Middleware puts a value in, the handler takes it out, keyed by type or by string.

Rejected on three counts, and the first is the one that decides it:

1. **Nothing checks that the value is there.** A handler reads `c.locals("user")` for a route somebody forgot to put behind the auth middleware, and finds out at runtime — the 3 a.m. failure ADR 0006 built the startup service check to avoid. With a declared type, the question "can this value be produced here" has an answer while compiling, because producing it does not depend on the route at all.
2. **It is untyped in a language that did not have to be.** Storing `*anyopaque` and casting on the way out throws away the one thing Zig is offering.
3. **It costs every request something.** A map on `Ctx` is a field, an init, and a lookup on requests that never use it. Declaring the value keeps that cost on the routes that asked (ADR 0018).

Elysia's `resolve` is where the shape came from (ADR 0015). Zig can do it better than Elysia can, because the check happens before the program runs rather than during startup codegen.

## What a resolver may ask for, and what it may not

A resolver takes a `*Ctx`, a service, the request arena, and **other resolved values**. That last one is the composition case, and it is what makes `Admin` a thing worked out from `CurrentUser` rather than a second copy of the authentication code.

It may **not** take a path param, a query struct, or the body. A resolver belongs to the request, not to a route, and a route is the only thing that knows what `:id` means — the same `CurrentUser` is used by `/me` and by `/orders/:id`, and only one of those has an `:id` to hand over. A resolver that wants one takes a `*Ctx` and reads it. Asking for anything else is a compile error naming the argument and listing the four things it could have been.

A loop — `A` resolved from `B` resolved from `A` — is also a compile error, and it has to be: left alone it is not a bad program but a compiler that never returns. The message prints the loop.

## Worked out once per request

The pattern this exists to serve has two askers, not one:

```zig
try app.useOn("/admin", requireAdmin);   // guards the whole prefix
fn stats(user: CurrentUser) !Stats { … } // and the handler wants the user
```

Middleware still cannot receive an argument, so a guard reaches the value through `c.resolve(CurrentUser)`. If that authenticated a second time, every guarded route would silently do twice the database work — the guard's lookup and the handler's. So the value is remembered on the `Ctx` for the rest of the request, and the second ask is a pointer compare over a list two entries long.

The memory is the request arena, which means a resolved value dies exactly when the request does, exactly as every `Str` inside it does (ADR 0004). A test drives two different tokens down one keep-alive connection, because a cache that outlived its request would be the worst bug this feature could have.

## Division of labour: middleware guards, resolved values provide

Worth stating plainly, because the two now overlap and people will ask which to reach for.

A resolved value is **pull**: only routes that name it pay for it, and a route that forgets to name it simply does not authenticate. That is right for data and wrong for enforcement — you cannot secure a prefix by hoping every handler under it remembers to take an argument.

Middleware is **push**: it runs on everything under its prefix whether the handler cooperates or not. That is what `useOn("/admin", …)` is for, and it stays the answer for enforcement.

The two compose through `c.resolve`, which is why that method exists at all.

## Consequences

- `CONTEXT.md`'s "Middleware […] produces no value for the handler" stands unchanged, and is no longer a limitation anybody trips over.
- A service used by nothing but a resolver is still checked by `listen()`. `typed.requirements` walks into resolver chains, so forgetting `provide(&sessions)` for a `*Sessions` that appears in no handler signature still stops the server before the socket opens.
- A handler taking a resolved value is still an ordinary function: `me(.{ .id = 7 })` in a test, no server, no fake request. That is the property ADR 0003 exists to protect, and this does not spend any of it.
- A resolver is *not* a middleware and cannot wrap the handler — no "after" half, no short-circuit that answers. Refusing is the only control it has, which is all authentication needs. Anything that wants to see the response is middleware.
- Three markers now exist for the compile-time engine to read — `nilo_query`, `nilo_response`, `nilo_resolve` — and the order they are tested in matters: a resolved value is a struct, and a plain struct argument is the request body, so the marker check has to come first.
