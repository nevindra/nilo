# Typed handlers are a thin layer over Ctx, not a replacement for it

zfast has two API layers, and that is deliberate. `Ctx` is the real API. A typed handler is only a compile-time layer that, while compiling, turns into exactly the same `Ctx` calls — free at runtime.

```zig
fn getUser(db: *Db, id: u32) !User { ... }        // 90% of cases
fn download(ctx: *Ctx, id: u32) !void { ... }     // needs full control
```

Services (a database, config, a logger) are matched through the same engine: registered once when the `App` is built, then asked for by handlers according to their type. The compile-time engine already has to read the argument list to tell a path param from a body; telling a service apart is just one more branch in the same place.

In Zig, "magic" like this is free at runtime — there is no reflection as in Go, no trait machinery as in Rust. What you pay for is not speed but **the quality of the error message when a user gets a signature wrong**, and that has to be handled by hand with carefully written `@compileError`s.

## Consequences

- A handler becomes an ordinary function that can be tested without starting a server and without fake HTTP, including with fake services. No other Zig framework can say this, so it is the main marketing material — not a side effect.
- The way out for cases that do not fit (streaming, large uploads, SSE) is not a patch: it is genuinely the layer underneath, and you just ask for a `*Ctx`.
- The `Ctx` layer can be finished and released first. If the compile-time engine turns out to be a dead end, there is already a working framework people can use — that is the safety net.
- Middleware works at the `Ctx` layer, handlers at the typed layer. The two do not collide and there are not two ways to do the same thing.
- If there are two services of the same type (two databases, say), they have to be told apart with named wrappers.
