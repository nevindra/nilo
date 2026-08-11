# Handlers

A handler is an ordinary function. It takes only what it needs and returns data.
Which means you can test it without starting a server, and without a fake HTTP
request:

```zig
fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse zfast.fail.notFound("no user {d}", .{id});
}

test "getUser" {
    var fake = Db.fake(.{ .id = 7 });
    try expectEqual(7, (try getUser(&fake, 7)).id);
    try expectError(error.Failed, getUser(&fake, 99));
}
```

## What a handler may ask for

Arguments are matched while compiling, by one rule: **a pointer is a service, a
value is request data.**

| Argument | What zfast passes in |
|---|---|
| `*Ctx` | the raw request — the way out when you need full control |
| `*Db`, `*const Config` | a [service](./services.md), matched by its type |
| `u32`, `f64`, `Str`, `bool`, an enum | a path param, in the order they appear in the pattern |
| `Query(T)` | the [query string](./requests.md#query-params), read into a struct of yours |
| `std.mem.Allocator` | the request arena, freed when the request ends |
| a type with `zfast_resolve` | a [resolved value](./middleware.md#resolved-values) — the signed-in user, usually |
| any other struct | the [request body](./requests.md#json-bodies), parsed from JSON |

Order is free, except among path params: those are positional, so the first
scalar argument is the first `:param` in the pattern, the second is the second.
Everything else is matched by type, so it can sit anywhere in the list.

```zig
fn update(db: *Db, id: u32, arena: std.mem.Allocator, incoming: Patch) !User { … }
```

Getting any of this wrong stops the compiler with a message that names the route
and tells you what to do about it — never a runtime surprise. Asking for a
service you forgot to register stops `listen()` before the socket opens.

## What a handler returns

The return value becomes the response body:

| Return type | Response |
|---|---|
| `void` | 200, empty |
| `Str`, `[]const u8` | 200, `text/plain` |
| anything else | 200, that value as JSON |
| `?T` | 200 with the value, or **404** when it is null |
| `Status(code, T)` | that status, and headers if you set any |
| `Response(T)` | a status picked while the handler runs, and headers |
| `!T` | any of the above, or a [failure](./errors.md) |

### "It might not be there": `?T`

The commonest handler in any CRUD app, and the whole 404 is in the signature:

```zig
fn getUser(db: *Db, id: u32) !?User {
    return db.find(id);
}
```

Null goes out as `404 Not Found`, and the generated API description says the
endpoint answers 404 — which it cannot know about an `orelse fail.notFound(…)`
in the body, because a compile-time check cannot read a function body.

Write the `orelse` when you want a better sentence than `there is no /users/99`.
You get both: your message, and the 404 in the document.

```zig
fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse fail.notFound("no user {d}", .{id});
}
```

What `?T` no longer does is answer `200` with the body `null`. If that really is
what you mean, return a struct with a nullable field, which says so.

### Choosing the status, or adding headers

When the status is part of the contract, put it in the type — the document can
then name it instead of writing `default`:

```zig
fn createUser(db: *Db, arena: std.mem.Allocator, incoming: NewUser) !Status(201, User) {
    const created = try db.add(incoming);
    return .{
        .headers = .of(&.{.{
            .name = "Location",
            .value = try std.fmt.allocPrint(arena, "/users/{d}", .{created.id}),
        }}),
        .value = created,
    };
}

fn deleteUser(db: *Db, id: u32) !Status(204, void) {
    if (!try db.remove(id)) return fail.notFound("no user {d}", .{id});
    return .{};
}
```

When the status genuinely depends on what the handler found — a 200 or a 201 out
of the same upsert — that is what `Response(T)` is for, and its `.status` is an
ordinary field:

```zig
fn upsertUser(db: *Db, id: u32, incoming: NewUser) !Response(User) {
    const result = try db.upsert(id, incoming);
    return .{ .status = if (result.created) 201 else 200, .value = result.user };
}
```

The two behave identically at runtime. The difference is what the API
description can say ([ADR 0024](../adr/0024-a-failure-mode-belongs-in-the-return-type.md)).

A `std.mem.Allocator` argument is the request arena — the thing to build a header
value in, since it lives exactly as long as the response needs it to and is
thrown away afterwards. Nothing to free.

`.of(…)` is not decoration. A list written inside a handler belongs to that
handler's stack frame, and zfast reads the headers after the handler has
returned; `of` copies them into the response while the list is still there. Up to
eight per response — a ninth is a compile error pointing at `c.setHeader`, which
has no limit.
[ADR 0019](../adr/0019-a-response-owns-its-headers.md) has the whole story,
including why the slice this replaced passed every test and crashed in release.

## The way out: `*Ctx`

When you need something the typed layer has no argument for — a header, a body
you want to look at before parsing, an answer written in pieces — the handler
asks for a `*Ctx`:

```zig
fn download(c: *zfast.Ctx, files: *Files) !void {
    const wanted = c.header("X-File") orelse return fail.badRequest("no X-File", .{});
    try c.send(200, "application/octet-stream", files.get(wanted.view()));
}
```

Both layers are the same layer: the typed one compiles down into `Ctx` calls, and
a handler can take a `*Ctx` alongside its typed arguments. There is no penalty
for mixing, and no separate registration.

A handler taking a `*Ctx` and sending its own answer should return `void`. One
request gets one response, and sending a second is an assertion failure rather
than two responses on the wire.

See [Responses](./responses.md) for everything a `Ctx` can send, and
[ADR 0003](../adr/0003-typed-handlers-are-a-thin-layer-over-ctx.md) for why the
typed layer is a thin one.

## `Str`, and text that belongs to the request

Text arriving from a request — a param, a header, a query value — is a
`zfast.Str`, not a `[]const u8`. It is valid while the request runs and not
afterwards, and the type says so:

| | |
|---|---|
| `s.view()` | the bytes, for reading now |
| `s.eql("admin")` | compare against a literal |
| `s.int(u32)` | parse a number out of it |
| `s.len()` | how many bytes |
| `s.keep(gpa)` | a copy that outlives the request — the deliberate way out |

Returning a `Str` from a handler is fine: the response goes out before the
request ends. Storing one in a service is the mistake `Str` exists to catch, and
in a debug build reading a stale one panics rather than returning whatever the
next request put there:

```
thread panic: Str used after its request finished. Request data dies with the
request; copy it with .keep() while the handler is still running if you need to
hold on to it. (while handling GET /read)
```

`keep` is how you mean it — see
[Holding on to request text](./services.md#holding-on-to-request-text) for the
pattern a service wants.

What the trap cannot promise is *everything*: Zig has no ownership system, so
this is a debug-build check and not a guarantee. A `Str` reached through a
pointer zfast never walked — inside a const slice, inside an untagged union —
carries no marker and is not watched. Release builds drop the whole mechanism,
at no cost.

See [ADR 0004](../adr/0004-request-arena-and-the-str-type.md).
