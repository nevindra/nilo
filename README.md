# zfast

An HTTP framework for Zig, aimed at people coming from Go or Node.

> **Status: stage 3 of 5 (the typed layer) — typed handlers, services matched by type, and failure functions, on top of the stage-2 `Ctx` layer. Still missing: middleware and the four built-ins (stage 4), chunked bodies, percent-decoding, and `HEAD` routes have to be registered explicitly rather than falling back to `GET`.**
> `zfast` is a working name and may change.

## Documents

- [`CONTEXT.md`](./CONTEXT.md) — project vocabulary
- [`docs/rencana.md`](./docs/rencana.md) — v1 scope, build order, risks
- [`docs/adr/`](./docs/adr/) — design decisions and the reasoning behind them

*Design notes are currently written in Indonesian.*

## What it looks like

```zig
const gagal = zfast.gagal;

const User = struct { id: u32, name: zfast.Str };

fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse
        gagal.notFound("user {d} not found", .{id});
}

var app = zfast.App.init(gpa);
try app.daftarkan(&db);
try app.get("/users/:id", getUser);
try app.dengarkan(.{});
```

A handler is an ordinary function: it takes only what it needs and returns data. Which means you can test it without starting a server, and without a fake HTTP request.

```zig
test "getUser" {
    var fake = Db.fake(.{ .id = 7 });
    try expectEqual(7, (try getUser(&fake, 7)).id);
    try expectError(error.Gagal, getUser(&fake, 99));
}
```

Arguments are matched at compile time, by one rule: **a pointer is a service, a value is request data.**

| Argument | What zfast passes in |
|---|---|
| `*Ctx` | the raw request — the way out when you need full control |
| `*Db`, `*const Config` | a service, matched by its type |
| `u32`, `Str`, `bool`, an enum | a path param, in the order they appear in the pattern |
| a struct | the request body, parsed from JSON |

The return value becomes the response: `void` → empty 200, `Str`/`[]const u8` → `text/plain`, anything else → JSON. Wrap it in `Jawaban(T)` when the status isn't 200.

Getting any of this wrong stops the compiler with a message that names the route and tells you what to do about it — never a runtime surprise. Asking for a service you forgot to register stops `dengarkan()` before the socket opens.

When you need full control — streaming, large uploads — the handler simply asks for a `*Ctx`. Both layers are the same layer: the typed one compiles down into `Ctx` calls.

*The public API is in Indonesian where the concept is zfast's own (`balasJson`, `dengarkan`, `daftarkan`) and in English where the HTTP world already has a word (`get`, `post`, `Str`, `keep`).*

## Principles

Developer experience comes first; performance is pursued as long as it doesn't make life harder for the user. The reasoning is in [ADR 0001](./docs/adr/0001-dx-menang-dengan-ambang-10-persen.md).

There are no benchmark numbers yet, so there are no performance claims here.
