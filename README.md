# zfast

An HTTP framework for Zig, aimed at people coming from Go or Node.

> **Status: stage 2 of 5 (the `Ctx` layer) — routing with path params, query params, request headers, JSON in/out, the per-request arena, and `Str` with its debug-build lifetime trap. Typed handlers (stage 3) are not here yet: handlers currently take `*Ctx`.**
> `zfast` is a working name and may change.

## Documents

- [`CONTEXT.md`](./CONTEXT.md) — project vocabulary
- [`docs/rencana.md`](./docs/rencana.md) — v1 scope, build order, risks
- [`docs/adr/`](./docs/adr/) — design decisions and the reasoning behind them

*Design notes are currently written in Indonesian.*

## What it's meant to look like

```zig
const User = struct { id: u32, name: zfast.Str };

fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse
        http.notFound("user {d} not found", .{id});
}

app.get("/users/:id", getUser);
```

A handler is an ordinary function: it takes only what it needs and returns data. Which means you can test it without starting a server.

```zig
test "getUser" {
    var fake = Db.fake(.{ .id = 7 });
    try expectEqual(7, (try getUser(&fake, 7)).id);
}
```

When you need full control — streaming, large uploads — the handler simply asks for a `*Ctx`.

## Principles

Developer experience comes first; performance is pursued as long as it doesn't make life harder for the user. The reasoning is in [ADR 0001](./docs/adr/0001-dx-menang-dengan-ambang-10-persen.md).

There are no benchmark numbers yet, so there are no performance claims here.
