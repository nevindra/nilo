# Handlers

**A handler is an ordinary function that takes only what it needs and returns data, so you can test it without a server or a fake HTTP request.**

**Reference:** [handler arguments](../reference/handlers.md#handler-arguments), [handler returns](../reference/handlers.md#handler-returns), [`Str`](../reference/core.md#str) · **Design:** [Typed handlers](../design/typed-handlers.md)

```zig
fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse nilo.fail.notFound("no user {d}", .{id});
}

test "getUser" {
    var fake = Db.fake(.{ .id = 7 });
    try expectEqual(7, (try getUser(&fake, 7)).id);
    try expectError(error.Failed, getUser(&fake, 99));
}
```

## Arguments a handler can take

**Arguments are matched while compiling, by one rule: a pointer is a service, a value is request data.** Every argument type is [in the reference](../reference/handlers.md#handler-arguments).

| Argument | What nilo passes in |
|---|---|
| `*Ctx` | the raw request, for when you need full control |
| `*Db`, `*const Config` | a [service](./services.md), matched by its type |
| `u32`, `f64`, `Str`, `bool`, an enum | the path param, on a route with exactly one |
| `Path(T)` | the [path params, read by name](./requests.md#path-params) into a struct of yours; required on a route with two or more |
| `Query(T)` | the [query string](./requests.md#query-params), read into a struct of yours |
| `FromHeader("X-Staff-Id", T)` | one request header, converted the way a path param is; `?T` when the client may not send it. `c.header` reads the same thing; this also adds a parameter to the [OpenAPI document](./openapi.md) |
| `Authorization(.bearer)`, `Authorization(.{ .basic = "realm" })` | the `Authorization` header as one scheme: `.value` for a token, `.user` and `.password` for Basic. A missing header or another scheme is a 401 with `WWW-Authenticate`, before the handler runs, and a security scheme in the document. See [Checking somebody else's token](./jwt.md#the-signed-in-user-as-a-handler-argument) |
| `Idempotent(Replays, .{ .by = account })` | the `Idempotency-Key` header, and with it the route [answering once per key](./idempotency.md): a retry gets the stored answer back and the handler does not run |
| `Form(T)` | the body as an [HTML form](./forms.md), urlencoded or multipart, read into a struct of yours |
| `Bound(T)`, `Bound(Query(T))`, `Bound(Form(T))` | the same three, with [every field that failed](./forms.md#collecting-every-field-error-bound) handed to the handler instead of the first failure stopping the request |
| `Session(T)` | a struct of yours [sealed into a cookie](./sessions.md), a resolved value nilo supplies |
| `std.mem.Allocator` | the request arena, freed when the request ends |
| a type with `nilo_resolve` | a [resolved value](./middleware.md#resolved-values), usually the signed-in user |
| any other struct | the [request body](./requests.md#json-bodies), parsed from JSON |

Arguments can be in any order. A route with one path param takes it as a bare argument; a route with two or more reads them by name through `Path(T)`, because Zig keeps no argument names and two bare `u32` would compile either way round. Everything is matched by type, so it can sit anywhere in the list.

```zig
fn update(db: *Db, id: u32, arena: std.mem.Allocator, incoming: Patch) !User { … }
```

A mistake here stops the compiler with a message that names the route and says how to fix it, never a surprise at runtime. Asking for a service you forgot to register stops `listen()` before the socket opens.

## What a handler returns

**The return value becomes the response body.** Every return type is [in the reference](../reference/handlers.md#handler-returns).

| Return type | Response |
|---|---|
| `void` | 200, empty |
| `Str`, `[]const u8` | 200, `text/plain` |
| anything else | 200, that value as JSON |
| `?T` | 200 with the value, or **404** when it is null |
| `Status(code, T)` | that status, and headers if you set any |
| `Response(T)` | a status picked while the handler runs, and headers |
| `Redirect(status)` | that status and a `Location`, no body ([Responses](./responses.md#redirects)) |
| `FileBody`, `?FileBody` | a file on disk, sent without passing through your process; `?` is the same 404 ([Responses](./responses.md#files)) |
| a type with `nilo_content_type` and `nilo_write` | whatever it writes, under that content type: XML, CSV, HTML of your own ([Responses](./responses.md#xml-csv-and-other-formats)) |
| `!T` | any of the above, or a [failure](./errors.md) |

### Returning 404 with `?T`

**Return `?T` and a null becomes a 404.** This is the most common handler in any CRUD app, and the whole 404 is in the signature:

```zig
fn getUser(db: *Db, id: u32) !?User {
    return db.find(id);
}
```

Null goes out as `404 Not Found`, and the generated API description says the endpoint can answer 404. It cannot know that about an `orelse fail.notFound(…)` in the body, because a compile-time check cannot read a function body.

Write the `orelse` when you want a better message than `there is no /users/99`. You get both: your message, and the 404 in the document.

```zig
fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse fail.notFound("no user {d}", .{id});
}
```

`?T` never answers `200` with the body `null`. If that is really what you mean, return a struct with a nullable field, which says so.

### Combining `?` with `Status` and `Response`

**The `?` goes inside the wrapper**, because it is about the body, not the status around it. The other order is rejected by the compiler, with a message that says which to write ([ADR 203](../adr/203-a-question-mark-goes-inside-the-wrapper.md)).

| Write | Meaning |
|---|---|
| `!?T` | the value, or 404 |
| `!Status(201, ?T)` | 201 with the value, or 404 |
| `!Response(?T)` | the status the handler chose, or 404 |
| `!?FileBody`, `!?Bytes` | the file or the bytes, or 404 |
| `!Versioned(T)` with `.unchanged(v)` | the value, or a 304; a thing that is not there is `fail.notFound` |
| `!Status(204, void)` | 204, empty |

| Rejected | Why, and what to write |
|---|---|
| `?Status(201, T)` | a 201 with no body makes no sense; `Status(201, ?T)` |
| `?Response(T)` | the same; `Response(?T)` |
| `?Redirect(303)` | a redirect has no body for the `?` to be about; `Redirect(303)`, and `fail.notFound` |
| `?Versioned(T)`, `Versioned(?T)` | a thing that is not there has no version; `Versioned(T)` and `fail.notFound` |
| `*Ctx` and `void` | allowed, but not described: the document cannot say what the handler wrote ([ADR 120](../adr/120-a-ctx-handler-that-returns-nothing-may-have-written-it.md)) |

The `!` goes outermost in every row, and the API document describes every shape in the first table, 404 included.

### Choosing the status, or adding headers

**When the status is part of the contract, put it in the type**, so the document can name it instead of writing `default`:

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

When the status really depends on what the handler found (a 200 or a 201 from the same upsert), use `Response(T)`. Its `.status` is an ordinary field:

```zig
fn upsertUser(db: *Db, id: u32, incoming: NewUser) !Response(User) {
    const result = try db.upsert(id, incoming);
    return .{ .status = if (result.created) 201 else 200, .value = result.user };
}
```

The two behave the same at runtime. The difference is what the API description can say ([ADR 023](../adr/023-a-failure-mode-belongs-in-the-return-type.md)).

A `std.mem.Allocator` argument is the request arena. Build a header value in it: it lives exactly as long as the response needs it and is thrown away afterwards, so there is nothing to free.

`.of(…)` is required. A list written inside a handler lives in that handler's stack frame, and nilo reads the headers after the handler has returned, so `of` copies them into the response while the list still exists. You can set up to eight per response. A ninth is a compile error pointing at `c.setHeader`, which has no limit. [ADR 018](../adr/018-a-response-owns-its-headers.md) has the whole story, including why the slice this replaced passed every test and crashed in release.

## Using `*Ctx` directly

**When the typed arguments don't cover what you need, ask for a `*Ctx`:** a header, a body you want to look at before parsing, an answer written in pieces.

```zig
fn download(c: *nilo.Ctx, files: *Files) !void {
    const wanted = c.header("X-File") orelse return fail.badRequest("no X-File", .{});
    try c.send(200, "application/octet-stream", files.get(wanted.view()));
}
```

The typed layer compiles down into [`Ctx`](../reference/ctx.md#ctx) calls, so they are the same layer. A handler can take a `*Ctx` next to its typed arguments. Mixing costs nothing and needs no separate registration.

A handler that takes a `*Ctx` and sends its own answer should return `void`. One request gets one response, and sending a second is an assertion failure, not two responses on the wire.

See [Responses](./responses.md) for everything a `Ctx` can send, and [ADR 002](../adr/002-typed-handlers-are-a-thin-layer-over-ctx.md) for why the typed layer is thin.

## Request text: `Str`

**Text from a request (a param, a header, a query value) is a [`nilo.Str`](../reference/core.md#str), not a `[]const u8`.** It is valid while the request runs and not afterwards, and the type makes that visible:

| | |
|---|---|
| `s.view()` | the bytes, for reading now |
| `s.eql("admin")` | compare against a literal |
| `s.int(u32)` | parse a number out of it |
| `s.len()` | how many bytes |
| `s.keep(gpa)` | a copy that outlives the request, made on purpose |

Returning a `Str` from a handler is fine, because the response goes out before the request ends. Storing one in a service is the mistake `Str` exists to catch. In a debug build, reading a stale one panics instead of returning whatever the next request put there:

```
thread panic: Str used after its request finished. Request data dies with the
request; copy it with .keep() while the handler is still running if you need to
hold on to it. (while handling GET /read)
```

`keep` is how you say you mean it. See [Storing request text in a service](./services.md#storing-request-text-in-a-service) for how a service should do it.

The check cannot catch *everything*: Zig has no ownership system, so this is a debug-build check, not a guarantee. A `Str` reached through a pointer nilo never walked (inside a const slice, inside an untagged union) has no marker and is not watched. Release builds drop the whole mechanism, so it costs nothing there.

See [ADR 003](../adr/003-request-arena-and-the-str-type.md).
