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
| `Response(T)` | a status and headers of your choosing |
| `!T` | the same, or a [failure](./errors.md) |

### Choosing the status, or adding headers

```zig
fn createUser(db: *Db, arena: std.mem.Allocator, incoming: NewUser) !Response(User) {
    const created = try db.add(incoming);
    return .{
        .status = 201,
        .headers = .of(&.{.{
            .name = "Location",
            .value = try std.fmt.allocPrint(arena, "/users/{d}", .{created.id}),
        }}),
        .value = created,
    };
}
```

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
next request put there. `keep` is how you mean it.

See [ADR 0004](../adr/0004-request-arena-and-the-str-type.md).
