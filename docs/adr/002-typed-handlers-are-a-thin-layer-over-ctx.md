# Typed handlers are a thin layer over Ctx, not a replacement for it

**Status:** accepted
**Topic:** [typed-handlers](../design/typed-handlers.md)

nilo has two API layers, and that is deliberate. `Ctx` is the real API. A typed handler is only a compile-time layer that, while compiling, turns into exactly the same `Ctx` calls — free at runtime.

```zig
fn getUser(db: *Db, id: u32) !User { ... }        // 90% of cases
fn download(ctx: *Ctx, id: u32) !void { ... }     // needs full control
```

Services (a database, config, a logger) are matched through the same engine: registered once when the `App` is built, then asked for by handlers according to their type. The compile-time engine already has to read the argument list to tell a path param from a body; telling a service apart is just one more branch in the same place.

In Zig, "magic" like this is free at runtime — there is no reflection as in Go, no trait machinery as in Rust. What you pay for is not speed but **the quality of the error message when a user gets a signature wrong**, and that has to be handled by hand with carefully written `@compileError`s.

## Path params: by name from two, by position for one

Zig keeps no argument names, so a bare `id: u32` cannot say which `:name` of the pattern it is. **A route with exactly one path param may still take it as a bare argument**, since there is nothing to confuse. **A route with two or more reads them by name, with `nilo.Path(T)`**: a struct whose field names are the pattern's `:names` (a trailing wildcard is `@"*"`) and whose field types are anything a positional param may be (a number, `Str`, `bool`, an enum, a type carrying `nilo_parse`).

```zig
const Member = struct { org: u32, id: u32 };
fn member(db: *Db, p: nilo.Path(Member)) !?User { … p.value.org, p.value.id … }
app.get("/orgs/:org/members/:id", member);
```

The struct is the route's params, and the compiler holds the two together. Each of these stops compilation with a sentence naming the route: a field that names no param of the pattern (the message lists the route's params and suggests the one left over), a param of the pattern with no field (unless the handler holds a `*Ctx` and reads it with `c.param`), an optional field, a type a path param cannot be, two `Path(T)` arguments, and a `Path(T)` beside a bare path param. A bare path param on a route with two or more params is refused with the fix written out from the handler's own types: `route "/orgs/:org/members/:id" has 2 path params (:org, :id); read them by name: nilo.Path(struct { org: u32, id: u32 })`.

Each field is read from the slot of the matched route's params whose index is worked out while compiling from its name, so it costs no string comparison and no allocation at run time, and a route that does not ask for `Path(T)` pays nothing. A conversion failure is the same 400 the positional form gives, naming the field (`:id has to be a whole number`). The resolver side is in ADR 015.

## What was rejected

**Path params matched by position at any count.** This was the rule until `Path(T)`: the first bare scalar argument was the first `:param`, the second the second. `fn member(id: u32, org: u32)` on `/orgs/:org/members/:id` compiled, ran, and answered a tenant-scoped query with the two ids swapped; chi and Express read params by name and cannot do this. The cost of the positional form is a silent wrong answer on exactly the routes where the ids are the same type, so it is kept only where it cannot be ambiguous.

## Consequences

- A handler becomes an ordinary function that can be tested without starting a server and without fake HTTP, including with fake services. No other Zig framework can say this, so it is the main marketing material — not a side effect.
- The way out for cases that do not fit (streaming, large uploads, SSE) is not a patch: it is genuinely the layer underneath, and you just ask for a `*Ctx`.
- The `Ctx` layer can be finished and released first. If the compile-time engine turns out to be a dead end, there is already a working framework people can use — that is the safety net.
- Middleware works at the `Ctx` layer, handlers at the typed layer. The two do not collide and there are not two ways to do the same thing.
- A route with two or more path params is read through `Path(T)` (see above), and a handler written the old way is a compile error that writes the struct to use.
- If there are two services of the same type (two databases, say), they have to be told apart with named wrappers.
