# zfast

An HTTP framework for Zig, aimed at people coming from Go or Node.

> **Status: stage 4 of 5 — middleware, response headers, and the logger and CORS built-ins, on top of the typed layer. Still missing: static file serving, chunked bodies, percent-decoding, and `HEAD` routes have to be registered explicitly rather than falling back to `GET`.**
> `zfast` is a working name and may change.

## Documents

- [`CONTEXT.md`](./CONTEXT.md) — project vocabulary
- [`docs/plan.md`](./docs/plan.md) — v1 scope, build order, risks
- [`docs/adr/`](./docs/adr/) — design decisions and the reasoning behind them

## What it looks like

```zig
const fail = zfast.fail;

const User = struct { id: u32, name: zfast.Str };

fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse fail.notFound("no user {d}", .{id});
}

var app = zfast.App.init(gpa);
try app.provide(&db);
try app.get("/users/:id", getUser);
try app.listen(.{});
```

A handler is an ordinary function: it takes only what it needs and returns data. Which means you can test it without starting a server, and without a fake HTTP request.

```zig
test "getUser" {
    var fake = Db.fake(.{ .id = 7 });
    try expectEqual(7, (try getUser(&fake, 7)).id);
    try expectError(error.Failed, getUser(&fake, 99));
}
```

Arguments are matched at compile time, by one rule: **a pointer is a service, a value is request data.**

| Argument | What zfast passes in |
|---|---|
| `*Ctx` | the raw request — the way out when you need full control |
| `*Db`, `*const Config` | a service, matched by its type |
| `u32`, `Str`, `bool`, an enum | a path param, in the order they appear in the pattern |
| a struct | the request body, parsed from JSON |

The return value becomes the response: `void` → empty 200, `Str`/`[]const u8` → `text/plain`, anything else → JSON. Wrap it in `Response(T)` when the status isn't 200.

Getting any of this wrong stops the compiler with a message that names the route and tells you what to do about it — never a runtime surprise. Asking for a service you forgot to register stops `listen()` before the socket opens.

When you need full control — streaming, large uploads — the handler simply asks for a `*Ctx`. Both layers are the same layer: the typed one compiles down into `Ctx` calls.

## Middleware

```zig
fn timing(c: *zfast.Ctx, next: zfast.Next) !void {
    const started = std.time.milliTimestamp();
    try next.run(c);
    std.log.info("{s} took {d}ms", .{ c.path().view(), std.time.milliTimestamp() - started });
}

try app.use(zfast.logger.standard);
try app.use(zfast.cors.permissive);
try app.use(timing);
try app.useOn("/api", requireToken);
```

An onion: everything before `next.run(c)` happens on the way in, everything after on the way out. Not calling `next` at all ends the chain, which is all a rejecting auth middleware has to do. Returning an error goes down exactly the same path a failing handler does.

Registration order between `use` and `get` doesn't matter — chains are resolved when `listen()` is called, so middleware registered after a route still applies to it.

## A note on panics

Zig cannot recover from a panic: an integer overflow or an out-of-bounds index takes the whole process down, every in-flight connection with it. There is no `recover` middleware because there cannot be one — see [ADR 0008](./docs/adr/0008-no-recover-middleware.md).

Handler *errors* are a different thing and are already handled: they become a response, and the connection stays alive. For the rest, run `ReleaseSafe` in production (in `ReleaseFast` an overflow is undefined behaviour instead of a loud crash) behind a supervisor that restarts. Adding

```zig
pub const panic = zfast.panic;
```

to your root file makes the crash say which request caused it:

```
thread 589880 panic: integer overflow (while handling GET /boom/50)
```

## Principles

Developer experience comes first; performance is pursued as long as it doesn't make life harder for the user. The reasoning is in [ADR 0001](./docs/adr/0001-dx-wins-below-the-10-percent-threshold.md).

There are no benchmark numbers yet, so there are no performance claims here.
