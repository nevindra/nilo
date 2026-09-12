//! The compile-time engine — turns a typed handler into an ordinary `Ctx`
//! handler while compiling (ADR 0003).
//!
//! ```zig
//! fn getUser(db: *Db, id: u32) !User { ... }
//! app.get("/users/:id", getUser);
//! ```
//!
//! All this engine reads is the argument list. The rule is one sentence:
//! **a pointer is a service, a value is request data.**
//!
//! | Argument              | What it means                              |
//! |-----------------------|--------------------------------------------|
//! | `*Ctx`                | the raw request — the way out when you need full control |
//! | `*Db`, `*const Cfg`   | a service, matched by its type             |
//! | `u32`, `Str`, `bool`, a float, an enum | a path param, in the order `:name` (and a trailing `*`) appears in the pattern |
//! | a type carrying `nilo_parse` | a path param the type reads itself — `sql.Uuid` (ADR 0142) |
//! | `Query(T)`            | the query string, read into a struct of yours |
//! | `Form(T)`             | the body as an HTML form, into a struct of yours (ADR 0031) |
//! | `std.mem.Allocator`   | the request arena, freed when the request ends |
//! | a type carrying `nilo_resolve` | a resolved value, worked out from the request (ADR 0016) |
//! | any other struct      | the request body, parsed from JSON         |
//!
//! A `Form(T)` and a plain struct are the same slot — a form *is* the body —
//! so a handler asking for both stops compilation.
//!
//! The return value becomes the response: `void` → empty 200,
//! `Str`/`[]const u8` → text/plain, anything else → JSON. Wrap it in
//! `Response(T)` when the status is not 200, or when the response carries
//! headers of its own, and `Redirect(status)` when the answer is a
//! `Location` (ADR 0032).
//!
//! Zig does not keep argument names, so path params are matched **by
//! position**, not by name. Every mismatch — the param count, a type that
//! makes no sense, two request bodies — stops compilation with a message
//! naming the route. That message quality is the only price this layer
//! charges (ADR 0003), so it is taken seriously here.

const std = @import("std");
const naming = @import("names.zig");
const headers_mod = @import("headers.zig");
const convert_mod = @import("convert.zig");
const ctx_mod = @import("ctx.zig");
const form_mod = @import("form.zig");
const http1 = @import("http1.zig");
const router = @import("router.zig");
const service_mod = @import("service.zig");
const fail = @import("fail.zig");
const authorization_mod = @import("authorization.zig");
const idempotent_mod = @import("idempotent.zig");
const str_mod = @import("nilo_core");
const resolve = @import("resolve.zig");
const openapi = @import("openapi.zig");
const patch_mod = @import("patch.zig");
const bound_mod = @import("bound.zig");
const filebody = @import("filebody.zig");
const json_mod = @import("json.zig");
const mark = @import("jsonmark.zig");
const ownbody = @import("ownbody.zig");

const Ctx = ctx_mod.Ctx;
const Str = str_mod.Str;

/// A response with a status other than 200, headers of its own, or both.
///
/// ```zig
/// fn createUser(incoming: NewUser) !Response(User) {
///     return .{
///         .status = 201,
///         .headers = .of(&.{.{ .name = "Location", .value = "/users/7" }}),
///         .value = created,
///     };
/// }
/// ```
///
/// The headers are copied on the way out, exactly as `Ctx.setHeader` does,
/// so a value built in the request arena is safe to hand over. The ones the
/// framework writes itself — Content-Type, Content-Length, Connection — are
/// refused here too; the content type follows from the return type.
pub fn Response(comptime T: type) type {
    // `Response(void)` — a 204, almost always — carries nothing, so the
    // field it would carry it in defaults to nothing and `.{ .status = 204 }`
    // is the whole return. Written as its own branch rather than as
    // `value: T = undefined`, which would have compiled for every T and let
    // a forgotten `.value` go out as whatever was on the stack.
    if (T == void) return struct {
        pub const nilo_response = void;
        /// What a nilo compile error calls this type, which is the name the
        /// reader's own import line gives it (ADR 0122).
        pub const nilo_type_name = "nilo.Response(void)";

        status: u16 = 200,
        headers: Headers = .{},
        value: void = {},
    };
    return struct {
        pub const nilo_response = T;
        /// What a nilo compile error calls this type, which is the name the
        /// reader's own import line gives it (ADR 0122).
        pub const nilo_type_name = "nilo.Response(" ++ naming.of(T) ++ ")";

        status: u16 = 200,
        headers: Headers = .{},
        value: T,
    };
}

/// `Response(T)` with the status settled while compiling, so the generated
/// description can name it.
///
/// ```zig
/// fn createUser(arena: std.mem.Allocator, incoming: NewUser) !Status(201, User) {
///     return .{
///         .headers = .of(&.{.{ .name = "Location", .value = try location(arena, made.id) }}),
///         .value = made,
///     };
/// }
///
/// fn deleteUser(db: *Db, id: u32) !Status(204, void) {
///     if (!try db.remove(id)) return fail.notFound("no user {d}", .{id});
///     return .{};
/// }
/// ```
///
/// The two types differ in one thing and it is not the runtime behaviour:
/// a `Response(T)` picks its status while the request is running, so the
/// API description can only write `default`, while this one is part of the
/// signature and comes out as `"201"` (ADR 0024). Reach for `Response(T)`
/// when the status genuinely depends on what the handler found — a 200 or a
/// 201 from the same upsert — and for this one the rest of the time.
pub fn Status(comptime code: u16, comptime T: type) type {
    if (T == void) return struct {
        pub const nilo_response = void;
        pub const nilo_status = code;
        /// What a nilo compile error calls this type, which is the name the
        /// reader's own import line gives it (ADR 0122).
        pub const nilo_type_name = std.fmt.comptimePrint("nilo.Status({d},void)", .{code});

        headers: Headers = .{},
        value: void = {},
    };
    return struct {
        pub const nilo_response = T;
        pub const nilo_status = code;
        /// What a nilo compile error calls this type, which is the name the
        /// reader's own import line gives it (ADR 0122).
        pub const nilo_type_name = std.fmt.comptimePrint("nilo.Status({d},{s})", .{ code, naming.of(T) });

        headers: Headers = .{},
        value: T,
    };
}

/// One header on a `Response`.
pub const Header = http1.Header;

/// The headers a `Response` carries. Declared in `headers.zig`, which is
/// vocabulary rather than engine, and re-exported here because
/// `nilo.Headers` is what a caller writes.
pub const Headers = headers_mod.Headers;

/// The query string, read into a struct of your own — the counterpart to a
/// path param, for the things that are named rather than positional.
///
/// ```zig
/// const Search = struct {
///     q: Str,             // required: absent is a 400
///     page: u32 = 1,      // a default is what "absent" means
///     tag: ?Str = null,   // optional: absent is null
/// };
///
/// fn search(params: Query(Search)) ![]const Item {
///     ... params.value.page ...
/// }
/// ```
///
/// Field names are the query names, and the field types are converted and
/// checked the same way path params are — `?page=x` on a `u32` is a 400
/// saying so, not a 500. A plain struct argument is still the request body;
/// this wrapper is what tells the two apart at a glance.
pub fn Query(comptime T: type) type {
    return struct {
        pub const nilo_query = T;
        /// What a nilo compile error calls this type, which is the name the
        /// reader's own import line gives it (ADR 0122).
        pub const nilo_type_name = "nilo.Query(" ++ naming.of(T) ++ ")";

        value: T,
    };
}

/// One request header, as a typed argument
/// ([ADR 0163](../docs/adr/0163-a-header-a-handler-can-be-given.md)).
///
/// ```zig
/// fn addComment(
///     actor: FromHeader("X-Staff-Id", Uuid),
///     body: NewComment,
/// ) !Status(201, Comment) {
///     ... actor.value ...
/// }
/// ```
///
/// `c.header(name)` reads the same value; what this adds is that the header
/// appears in the generated document, so a client made from it knows the
/// endpoint needs one.
///
/// **Absent is decided by the type, the way a query field decides it.** A
/// `?T` is null when the header is not there; anything else is a 400 naming
/// the header. Text that will not convert is a query param's 400, word for
/// word.
///
/// Named `FromHeader` because `nilo.Header` is the response side (ADR 0107).
pub fn FromHeader(comptime name: []const u8, comptime T: type) type {
    return struct {
        pub const nilo_header = .{ .name = name, .value = T };
        /// What a nilo compile error calls this type, which is the name the
        /// reader's own import line gives it (ADR 0122).
        pub const nilo_type_name = "nilo.FromHeader(\"" ++ name ++ "\", " ++ naming.of(T) ++ ")";

        value: T,
    };
}

/// What `Idempotent(Replays, …)` takes beside the Space.
pub const IdempotentOptions = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 0122).
    pub const nilo_type_name = "nilo.IdempotentOptions";

    /// Whose key it is. A function of one `*Ctx` answering the account, the
    /// tenant, the API key — whatever tells two callers apart — or null for
    /// a request with nobody behind it, which is a 403. Leave it null only
    /// on an endpoint with one caller: two clients choosing the same key
    /// must never see each other's answer.
    by: ?*const fn (*Ctx) ?Str = null,
};

/// The `Idempotency-Key` header, as a typed argument that makes the route
/// answer once per key
/// ([ADR 0193](../docs/adr/0193-a-request-answered-once-is-answered-the-same-way-again.md)).
///
/// ```zig
/// const Replays = cache.Space("orders-replay", []const u8, .{ .ttl_s = 86_400, .max_bytes = 16 << 10 });
///
/// fn placeOrder(key: nilo.Idempotent(Replays, .{ .by = account }), body: NewOrder, db: *sql.Db, c: *nilo.Ctx) !nilo.Status(201, Order)
/// ```
///
/// The first request with a key runs the handler and keeps what it
/// returned; every later one with that key gets the kept answer back with
/// `Idempotent-Replayed: true`, and the handler does not run. No key is a
/// 400, a key still being answered is a 409, a key reused on a different
/// request is a 422. What the handler *failed* with is not kept. `Replays`
/// is a `cache.Space` holding bytes, provided as a service; `.key` is the
/// header as sent. The account of what it costs is in `idempotent.zig`.
pub fn Idempotent(comptime Replays: type, comptime options: IdempotentOptions) type {
    return struct {
        pub const nilo_idempotent = .{ .replays = Replays, .by = options.by };
        /// What a nilo compile error calls this type, which is the name the
        /// reader's own import line gives it (ADR 0122).
        pub const nilo_type_name = "nilo.Idempotent(" ++ naming.of(Replays) ++ ", …)";

        /// The `Idempotency-Key` the client sent, as sent.
        key: Str,
    };
}

/// The role of one handler argument, decided at compile time.
const Role = union(enum) {
    ctx,
    service,
    /// Index of the path param in the route pattern, by position.
    param: usize,
    body,
    query,
    /// One named request header, read into the type it was asked for
    /// ([ADR 0163](../docs/adr/0163-a-header-a-handler-can-be-given.md)).
    /// Its own role rather than a flavour of `.query`, because two of them on
    /// one handler is ordinary and two query structs is not.
    header,
    /// The `Authorization` header, read as one scheme and refused with a
    /// challenge ([ADR 0191](../docs/adr/0191-an-authorization-header-a-handler-can-ask-for.md)).
    /// Not a flavour of `.header`, because absent is a 401 rather than a
    /// 400 and the document carries it as a security scheme, not a
    /// parameter.
    authorization,
    /// The `Idempotency-Key` header, and with it the whole of the route
    /// answering once per key (ADR 0193). Its own role because it is the
    /// one argument that can end the request before the handler runs with
    /// a *success*, and the one that has to see the handler's answer after.
    idempotent,
    /// The body again, but as an HTML form rather than as JSON (ADR 0031).
    /// A separate role and not a flavour of `.body`, because the two are
    /// the same slot and asking for both has to be refused.
    form,
    /// The request arena, for a handler that has to build something that
    /// outlives its own stack frame — a `Location` header, usually.
    arena,
    /// A value nilo works out from the request before the handler runs —
    /// the signed-in user, usually (ADR 0016).
    resolved,
    /// The same three slots again, read as a binding that hands its failures
    /// to the handler instead of ending the request (`bound.zig`).
    ///
    /// Three variants rather than one carrying a slot, so that every place
    /// which has to treat a binding exactly like the slot it occupies says
    /// so by naming both — `Bound(Form(T))` beside a `Form(U)` is asking for
    /// the form twice, and the message for that already exists.
    bound_body,
    bound_form,
    bound_query,
};

/// Turn `f` into an ordinary `Ctx` handler. `pattern` comes along so the
/// path param count can be checked and error messages can name the route.
pub fn wrap(comptime pattern: []const u8, comptime f: anytype) router.CtxHandler {
    const Fn = comptime fnTypeOf(pattern, @TypeOf(f));
    const params = @typeInfo(Fn).@"fn".params;
    const roles = comptime rolesOf(pattern, params);
    const param_names = comptime patternParamNames(pattern);
    comptime if (idempotentAt(roles) != null) checkKeepable(pattern, Fn);

    const Wrapper = struct {
        fn run(c: *Ctx) anyerror!void {
            var args: std.meta.ArgsTuple(Fn) = undefined;
            // Before anything else is read, because a replay reads nothing
            // else: the kept answer goes out and the handler never runs
            // (ADR 0193). `null` here means there is no such argument.
            const replaying: ?Begun = if (comptime idempotentAt(roles)) |at|
                switch (try idempotentBegin(params[at].type.?, c)) {
                    .replayed => return,
                    .fresh => |begun| begun,
                }
            else
                null;

            inline for (params, 0..) |p, i| {
                const P = p.type.?;
                switch (comptime roles[i]) {
                    .ctx => args[i] = c,
                    // **Logged as well as answered** (ADR 0079). `listen()`
                    // refuses to open the socket over this and names the type
                    // and the routes, so a server never reaches here — but
                    // `testing.Client` does not call `listen()`, and a test
                    // used to get a bare 500 on every route that wanted the
                    // service with nothing anywhere naming it. That is the
                    // worst shape a clue can have, because the same routes
                    // work over a real socket, so the evidence points at the
                    // test.
                    .service => args[i] = c._services.get(P) orelse {
                        // A warning and not an error, for the reason the
                        // unopened pool logs one: `std.log.err` fails the
                        // test runner, and this fires in a test by design.
                        std.log.warn(
                            "service {s} was never registered, and route \"{s}\" needs it. " ++
                                "`app.listen()` refuses to start over this and says which routes; " ++
                                "a test driving the App itself does not, so here it is. " ++
                                "Call app.provide() before serving.",
                            .{ @typeName(P), pattern },
                        );
                        return fail.internal(
                            "service {s} was never registered; call app.provide() before app.listen()",
                            .{@typeName(P)},
                        );
                    },
                    .param => |nth| args[i] = try paramValue(P, c, param_names[nth]),
                    .body => args[i] = try c.json(P),
                    .query => args[i] = .{ .value = try queryValue(P.nilo_query, c) },
                    .header => args[i] = .{ .value = try headerValue(P, c) },
                    .authorization => args[i] = try c.authorization(P.nilo_authorization),
                    .idempotent => args[i] = .{ .key = replaying.?.key },
                    .form => args[i] = .{ .value = try c.form(P.nilo_form) },
                    .arena => args[i] = c._arena,
                    .resolved => args[i] = try resolve.value(P, c),
                    // The outcomes live here, on the stack of the fiber that
                    // is already serving this request, and are copied into
                    // the binding. Sized while compiling, so a field that did
                    // not bind costs no allocation (ADR 0018).
                    .bound_body => {
                        var outcomes: P.Outcomes = undefined;
                        const filled = try c.jsonCollecting(P.Value, &outcomes);
                        args[i] = .from(filled, outcomes);
                    },
                    .bound_form => {
                        var outcomes: P.Outcomes = undefined;
                        const filled = try c.formCollecting(P.Value, &outcomes);
                        args[i] = .from(filled, outcomes);
                    },
                    .bound_query => {
                        var outcomes: P.Outcomes = undefined;
                        const filled = queryValueCollecting(P.Value, c, &outcomes);
                        args[i] = .from(filled, outcomes);
                    },
                }
            }
            if (comptime idempotentAt(roles)) |at| {
                return idempotentFinish(params[at].type.?, c, replaying.?, @call(.auto, f, args));
            }
            return sendResult(c, @call(.auto, f, args));
        }
    };
    return Wrapper.run;
}

/// A kept answer is one the handler returned, so a handler that writes its
/// own, or answers with a file or a redirect, cannot be idempotent this way
/// (ADR 0193). Said at the route rather than on the first replay.
fn checkKeepable(comptime pattern: []const u8, comptime Fn: type) void {
    comptime {
        if (returnsNothing(Fn)) @compileError(
            "nilo: the handler for route \"" ++ pattern ++ "\" takes an `Idempotent(…)` and " ++
                "returns nothing, so there is no answer to keep.\n" ++
                "  A kept answer is one the handler returned: a struct, a `Status(code, T)`, a " ++
                "`Response(T)`. A handler that writes its own response through the Ctx has " ++
                "nothing nilo can send again.",
        );
        const Returned = @typeInfo(Fn).@"fn".return_type.?;
        var V = switch (@typeInfo(Returned)) {
            .error_union => |u| u.payload,
            else => Returned,
        };
        if (@typeInfo(V) == .optional) V = @typeInfo(V).optional.child;
        if (hasNamedDecl(V, "nilo_redirect") or filebody.isFileBody(V)) @compileError(
            "nilo: the handler for route \"" ++ pattern ++ "\" takes an `Idempotent(…)` and " ++
                "returns a " ++ naming.of(V) ++ ", which is not an answer nilo can keep.\n" ++
                "  A file is sent from disk and a redirect is a status and a Location; what " ++
                "is kept and sent again is a body the handler returned. Answer with the " ++
                "thing that was made — the order, the receipt — and let the client follow it.",
        );
    }
}

/// Which argument is the `Idempotent(…)`, if any. At most one, which
/// `rolesOf` holds.
fn idempotentAt(comptime roles: []const Role) ?usize {
    for (roles, 0..) |r, i| if (r == .idempotent) return i;
    return null;
}

/// What `idempotentBegin` hands the rest of the request.
const Begun = struct {
    key: Str,
    /// The Space's key: `by`, a NUL, the client's key — or the key alone.
    under: []const u8,
    fingerprint: u64,
};

const BeginOutcome = union(enum) { replayed, fresh: Begun };

/// Read the key, claim it or find what was kept under it, and either send
/// the kept answer or say the handler may run (ADR 0193).
fn idempotentBegin(comptime P: type, c: *Ctx) !BeginOutcome {
    const Replays = P.nilo_idempotent.replays;
    const replays = c._services.get(*Replays) orelse {
        std.log.warn(
            "the Space {s} was never registered, and route \"{s}\" keeps its answers in it. " ++
                "Call app.provide() on it before serving.",
            .{ @typeName(Replays), c._path },
        );
        return fail.internal("the Space {s} was never registered; call app.provide() before app.listen()", .{@typeName(Replays)});
    };

    const key = c.header(idempotent_mod.header_name) orelse return fail.badRequest(
        "this endpoint wants an {s} header, so that a request sent twice is answered once",
        .{idempotent_mod.header_name},
    );
    if (key.len() == 0 or key.len() > idempotent_mod.max_key) return fail.badRequest(
        "the {s} header has to be between 1 and {d} bytes",
        .{ idempotent_mod.header_name, idempotent_mod.max_key },
    );

    const under: []const u8 = if (P.nilo_idempotent.by) |by| blk: {
        const who = by(c) orelse return fail.forbidden(
            "this endpoint keeps its answers per caller, and this request has no caller",
            .{},
        );
        const joined = try c._arena.alloc(u8, who.len() + 1 + key.len());
        @memcpy(joined[0..who.len()], who.view());
        joined[who.len()] = 0;
        @memcpy(joined[who.len() + 1 ..], key.view());
        break :blk joined;
    } else key.view();

    // The body is read here, once, and the handler's `body: T` reads the
    // same bytes: `c.body()` keeps what it read.
    const raw = try c.body();
    const fingerprint = idempotent_mod.fingerprintOf(@tagName(c.method), c._path, c._query, raw.view());

    // The claim is what makes two requests racing for one key get one
    // handler run between them: the cache takes the marker under its lock.
    const claimed = replays.putIfAbsent(under, &idempotent_mod.marker(fingerprint)) catch |err| switch (err) {
        error.TooLarge => unreachable, // a marker is thirteen bytes and `max_bytes` is at least 256
    };
    if (claimed) return .{ .fresh = .{ .key = key, .under = under, .fingerprint = fingerprint } };

    // Somebody was first. Into the arena rather than a `Held` on the
    // stack, which would be `max_bytes` per idle connection (ADR 0063).
    const room = try c._arena.alloc(u8, Replays.max_bytes);
    const kept = replays.getInto(under, room) orelse
        // Gone between the claim and the read — evicted, or expired on the
        // boundary. Nothing to replay, so this request is the first again.
        return .{ .fresh = .{ .key = key, .under = under, .fingerprint = fingerprint } };
    const record = idempotent_mod.decode(kept) orelse
        return .{ .fresh = .{ .key = key, .under = under, .fingerprint = fingerprint } };

    if (record.fingerprint != fingerprint) return fail.unprocessable(
        "the {s} header {s} was already used for a different request; a key is for retrying one " ++
            "request, not for sending another",
        .{ idempotent_mod.header_name, key.view() },
    );
    if (record.kind == .in_flight) return fail.conflict(
        "a request with {s} {s} is still being answered; ask again in a moment",
        .{ idempotent_mod.header_name, key.view() },
    );

    var it = record.eachHeader();
    while (it.next()) |h| try c.setHeader(h.name, h.value);
    try c.setStaticHeader(idempotent_mod.replayed_name, "true");
    try c.send(record.status, record.contentType(), record.body);
    return .replayed;
}

/// What the handler answered, kept and then sent — or not kept, when it
/// failed, so the next retry runs it again (ADR 0193).
fn idempotentFinish(comptime P: type, c: *Ctx, begun: Begun, result: anytype) !void {
    const Replays = P.nilo_idempotent.replays;
    const replays = c._services.get(*Replays).?; // `idempotentBegin` found it

    const R = @TypeOf(result);
    const value = if (@typeInfo(R) == .error_union) result catch |err| {
        _ = replays.del(begun.under);
        return err;
    } else result;
    const T = @TypeOf(value);

    // The same reading `sendResult` does, with the answer rendered rather
    // than sent so it can be kept first.
    var own_headers: []const http1.Header = &.{};
    var status: u16 = 200;
    const inner = if (comptime hasNamedDecl(T, "nilo_response")) blk: {
        own_headers = value.headers.view();
        status = if (comptime hasNamedDecl(T, "nilo_status")) T.nilo_status else value.status;
        break :blk value.value;
    } else value;
    const V = @TypeOf(inner);

    const present = if (comptime @typeInfo(V) == .optional)
        inner orelse {
            _ = replays.del(begun.under);
            return fail.notFound("there is no {s}", .{c._path});
        }
    else
        inner;
    const B = @TypeOf(present);

    var kind: idempotent_mod.Kind = .empty;
    var content_type: []const u8 = "";
    var body: []const u8 = "";
    if (B == void) {
        // nothing to render
    } else if (comptime ownbody.writesItsOwnBody(B)) {
        var out: std.Io.Writer.Allocating = try .initCapacity(c._arena, ctx_mod.json_hint);
        try present.nilo_write(&out.writer);
        kind = .own;
        content_type = B.nilo_content_type;
        body = out.written();
    } else if (B == Str) {
        kind = .text;
        body = present.view();
    } else if (comptime json_mod.isByteSlice(B)) {
        kind = .text;
        body = present;
    } else {
        var out: std.Io.Writer.Allocating = try .initCapacity(c._arena, ctx_mod.json_hint);
        try json_mod.write(&out.writer, present);
        kind = .json;
        body = out.written();
    }

    const record = idempotent_mod.encode(c._arena, kind, status, begun.fingerprint, own_headers, content_type, body) catch |err| switch (err) {
        error.TooLarge => {
            _ = replays.del(begun.under);
            std.log.warn("route \"{s}\" answered with more headers than an idempotency record holds; the answer was sent and not kept", .{c._path});
            return sendKept(c, own_headers, status, kind, content_type, body);
        },
        else => |e| return e,
    };
    replays.put(begun.under, record) catch |err| switch (err) {
        error.TooLarge => {
            // The answer goes out either way; what is lost is the replay,
            // and a retry runs the handler again. Said once per occurrence
            // because the fix is a number in the Space.
            _ = replays.del(begun.under);
            std.log.warn(
                "route \"{s}\" answered {d} bytes, more than the {d} its Space keeps; the answer was sent and not kept",
                .{ c._path, record.len, Replays.max_bytes },
            );
        },
    };
    return sendKept(c, own_headers, status, kind, content_type, body);
}

fn sendKept(c: *Ctx, own_headers: []const http1.Header, status: u16, kind: idempotent_mod.Kind, content_type: []const u8, body: []const u8) !void {
    for (own_headers) |h| try c.setHeader(h.name, h.value);
    return c.send(status, if (kind == .own) content_type else kind.contentType(), body);
}

/// Which services this handler needs. Computed at compile time and used by
/// App to check the registry once at startup.
pub fn requirements(comptime pattern: []const u8, comptime f: anytype) []const service_mod.Requirement {
    comptime {
        const Fn = fnTypeOf(pattern, @TypeOf(f));
        const params = @typeInfo(Fn).@"fn".params;
        const roles = rolesOf(pattern, params);

        var list: []const service_mod.Requirement = &.{};
        for (params, 0..) |p, i| {
            switch (roles[i]) {
                .service => list = list ++
                    [_]service_mod.Requirement{service_mod.requirementFor(p.type.?, pattern)},
                // A service used by nothing but a resolver still has to be
                // caught by `listen()`, or the first request to an
                // authenticated route finds it instead (ADR 0016).
                .resolved => list = list ++ resolve.requirements(p.type.?, pattern),
                else => {},
            }
        }
        return list;
    }
}

/// What this route's signature says about it, for the generated API
/// description (ADR 0017). Read from the very same argument list `wrap`
/// reads, which is the whole point: there is one contract, not a contract
/// and a description of it that can drift apart.
/// The verb is not in here: `App.route` takes it as an ordinary runtime
/// argument, so the caller fills it in on the value this hands back.
/// Everything else is settled while compiling.
pub fn operation(comptime pattern: []const u8, comptime f: anytype) openapi.Operation {
    comptime {
        // Reading a signature and describing it are one comptime evaluation
        // sharing one branch budget, and the default 1,000 was already nearly
        // spent: most of it goes on `openapi.nameOf` walking a type name
        // character by character to decide what to file the shape under. The
        // marker check ADR 0142 added per argument is what took the `orders`
        // example over, and the cost is a compile that stops rather than one
        // that is slow. Raised here because this is where the whole of the
        // work is asked for; the loop that spends it is two files away.
        @setEvalBranchQuota(20_000);

        const Fn = fnTypeOf(pattern, @TypeOf(f));
        const params = @typeInfo(Fn).@"fn".params;
        const roles = rolesOf(pattern, params);

        // Named by the pattern and typed by whichever argument claimed
        // them. A `*Ctx` handler claims none, and text is what a path param
        // is until somebody converts it.
        var path_params: []const openapi.Param = &.{};
        for (patternParamNames(pattern), 0..) |name, nth| {
            var schema = openapi.schemaOf(Str);
            for (params, 0..) |p, i| switch (roles[i]) {
                .param => |claimed| if (claimed == nth) {
                    schema = openapi.schemaOf(p.type.?);
                },
                else => {},
            };
            path_params = path_params ++ [_]openapi.Param{.{ .name = name, .schema = schema }};
        }

        var query: []const openapi.Field = &.{};
        var headers: []const openapi.Field = &.{};
        var security: openapi.Security = .none;
        var idempotent = false;
        var body: ?*const openapi.Schema = null;
        var body_kind: openapi.BodyKind = .json;
        // Whether nilo can refuse this request before the handler runs.
        // Not a guess — it is exactly the routes with something to convert.
        var can_reject = false;

        // A handler holding a `*Ctx` and returning nothing has sent its
        // answer itself, somewhere in its body, and no reading of its
        // signature will find out what. That is a different thing from a
        // handler that returns nothing *because* the answer is empty.
        var wants_ctx = false;

        for (params, 0..) |p, i| switch (roles[i]) {
            .ctx => wants_ctx = true,
            .param => can_reject = can_reject or p.type.? != Str,
            .query => {
                query = queryFields(p.type.?.nilo_query);
                can_reject = true;
            },
            // A header the signature asks for is a header the document can
            // promise, which is the whole of ADR 0163: `c.header` reads one
            // and appears nowhere, so a generated client could not know the
            // endpoint needed it. `required` follows the optional, the way a
            // query field's does.
            .header => {
                const asked = p.type.?.nilo_header;
                headers = headers ++ [_]openapi.Field{.{
                    .name = asked.name,
                    .schema = openapi.schemaOf(asked.value),
                    .required = @typeInfo(asked.value) != .optional,
                }};
                can_reject = true;
            },
            .body => {
                body = openapi.schemaOf(p.type.?);
                can_reject = true;
            },
            // The same slot as a body and described the same way, with one
            // difference the document has to carry: which encoding the
            // client is expected to send. A form with a file in it can only
            // be multipart, and saying otherwise would send somebody's
            // generated client to a 400.
            .form => {
                const Fields = p.type.?.nilo_form;
                body = openapi.schemaOf(Fields);
                body_kind = if (form_mod.holdsAFile(Fields)) .multipart else .urlencoded;
                can_reject = true;
            },
            // A security scheme rather than a parameter, which is what a
            // generated client reads to know it has to sign in — and a 401
            // in the responses, since nilo writes one before the handler
            // runs (ADR 0191).
            .authorization => security = switch (p.type.?.nilo_authorization) {
                .bearer => .bearer,
                .basic => .basic,
            },
            // A required header parameter, the way a `FromHeader` is, plus
            // the two answers only this route can give (ADR 0193).
            .idempotent => {
                headers = headers ++ [_]openapi.Field{.{
                    .name = idempotent_mod.header_name,
                    .schema = openapi.schemaOf([]const u8),
                    .required = true,
                }};
                idempotent = true;
                can_reject = true;
            },
            // Described exactly as the slot it binds — the request looks the
            // same on the wire either way — but `can_reject` stays false, and
            // that is the whole difference. nilo no longer refuses this
            // request before the handler runs; what the handler answers
            // instead is a line in a function body, and the document promises
            // what the signature settles and nothing else (ADR 0024).
            .bound_body => body = openapi.schemaOf(readInto(roles[i], p.type.?)),
            .bound_form => {
                const Fields = readInto(roles[i], p.type.?);
                body = openapi.schemaOf(Fields);
                body_kind = if (form_mod.holdsAFile(Fields)) .multipart else .urlencoded;
            },
            .bound_query => query = queryFields(readInto(roles[i], p.type.?)),
            else => {},
        };

        var answer = answerOf(Fn);
        // **This is the one thing about a handler nilo cannot read off the
        // signature** ([ADR 0150](../docs/adr/0150-a-ctx-handler-that-returns-nothing-may-have-written-it.md)).
        // A handler holding a `*Ctx` and returning nothing may have written a
        // response itself, or may have taken the Ctx to read a header and left
        // nilo to send 200 with an empty body. Both are ordinary and Zig has
        // no way to tell them apart.
        //
        // So the document says it does not know, which fails in the safe
        // direction: over-claiming an empty 200 on a route that streams a
        // file would be a document that lies. A handler that wants the second
        // one described says so in its return type — `Status(204, void)`, or
        // `Status(200, void)` — and gets a described response with no body.
        answer.written = wants_ctx and returnsNothing(Fn);

        return .{
            .method = .other, // filled in by the caller, which knows the verb
            .pattern = pattern,
            .params = path_params,
            .query = query,
            .headers = headers,
            .security = security,
            .idempotent = idempotent,
            .body = body,
            .body_kind = body_kind,
            .answer = answer,
            .can_reject = can_reject,
        };
    }
}

fn queryFields(comptime T: type) []const openapi.Field {
    comptime {
        var out: []const openapi.Field = &.{};
        for (@typeInfo(T).@"struct".fields) |f| {
            const is_list = queryList(f.type) != null;
            out = out ++ [_]openapi.Field{.{
                .name = f.name,
                .schema = openapi.schemaOf(f.type),
                // Absent is allowed when there is a default to fall back to,
                // or when the field is optional and absent means null — the
                // same two exemptions `queryValue` applies at runtime. A list
                // is never required: nothing sent is the empty list, which is
                // what `queryValue` does with one (ADR 0164).
                .required = !is_list and
                    f.default_value_ptr == null and @typeInfo(f.type) != .optional,
                .list = is_list,
            }};
        }
        return out;
    }
}

/// Whether the handler returns `void` — either bare or through an error
/// union. `Status(204, void)` is not this: it is a value that says what to
/// send, and it is returned.
fn returnsNothing(comptime Fn: type) bool {
    comptime {
        const Returned = @typeInfo(Fn).@"fn".return_type orelse return true;
        return switch (@typeInfo(Returned)) {
            .error_union => |u| u.payload == void,
            else => Returned == void,
        };
    }
}

/// What the return type says the response will be. The mapping is the one
/// `sendResult` performs, read the other way round.
fn answerOf(comptime Fn: type) openapi.Answer {
    comptime {
        const empty = openapi.Answer{ .status = 200, .content_type = "", .schema = null };

        const Returned = @typeInfo(Fn).@"fn".return_type orelse return empty;
        const V = switch (@typeInfo(Returned)) {
            .error_union => |u| u.payload,
            else => Returned,
        };
        if (V == void) return empty;

        // A redirect has no body to describe and a status that is part of
        // the type, so it is the most completely described thing a
        // signature can produce (ADR 0032).
        if (hasNamedDecl(V, "nilo_redirect")) return .{
            .status = V.nilo_redirect,
            .content_type = "",
            .schema = null,
            .redirect = true,
        };

        if (hasNamedDecl(V, "nilo_response")) {
            // The status of a `Response(T)` is a field the handler fills in,
            // so it is not knowable here. Saying "default" is the truth;
            // claiming 200 for a route that answers 201 would not be. A
            // `Status(code, T)` puts the code in the type instead, which is
            // the whole reason that type exists (ADR 0024).
            const status: ?u16 = if (hasNamedDecl(V, "nilo_status")) V.nilo_status else null;
            const Inner = V.nilo_response;
            if (Inner == void) return .{ .status = status, .content_type = "", .schema = null };
            return answerWith(status, Inner);
        }

        return answerWith(200, V);
    }
}

/// The success answer for a handler returning `V`, with `?V` read as "and a
/// 404 when it is not there" (ADR 0024) — so the body described is the thing
/// itself rather than "the thing or null".
fn answerWith(comptime status: ?u16, comptime V: type) openapi.Answer {
    comptime {
        const Present = switch (@typeInfo(V)) {
            .optional => |o| o.child,
            else => V,
        };
        // Read after the unwrap, in the same place and for the same reason
        // `sendValue` dispatches after it: `?FileBody` has two things to say
        // — a file, and a 404 — and reading it before would lose one of them.
        // The body is described as bytes rather than as the struct's fields,
        // which are a descriptor and a name and belong to the server.
        if (filebody.isFileBody(Present)) return .{
            .status = status,
            .content_type = "",
            .schema = null,
            .not_found = Present != V,
            .binary = true,
        };
        return .{
            .status = status,
            .content_type = if (ownbody.writesItsOwnBody(Present)) Present.nilo_content_type else contentTypeFor(Present),
            .schema = openapi.schemaOf(Present),
            .not_found = Present != V,
        };
    }
}

/// What a returned value is labelled as. Bytes are text and everything else is
/// JSON, and **which types count as bytes is `json.isByteSlice`'s to say** —
/// named by exact type here, this missed `[:0]const u8` and labelled it
/// `application/json` while the body it labelled was a JSON array of numbers
/// and the generated document said `type: string`. Three files reading the
/// same question is what put them out of step; one of them answering it fixes
/// all three at once.
fn contentTypeFor(comptime T: type) []const u8 {
    if (T == Str or json_mod.isByteSlice(T)) return "text/plain";
    return "application/json";
}

// ---- the compile-time side ----

/// Everything that can be wrong with a route's pattern and its handler,
/// checked from the method the caller actually wrote. See ADR 0027: the
/// message is the same wherever it fires, but the reference trace Zig prints
/// under it only reaches back two frames, and this is what puts the caller's
/// own line inside those two.
pub fn check(comptime pattern: []const u8, comptime handler: anytype) void {
    comptime {
        router.validatePattern(pattern);
        const Fn = fnTypeOf(pattern, @TypeOf(handler));
        _ = rolesOf(pattern, @typeInfo(Fn).@"fn".params);
        checkAnswer(pattern, Fn);
    }
}

/// What the return type has to get right, said at the route. Today that is
/// one thing: a type that writes its own answer carries two declarations,
/// and one without the other is refused here rather than sent as JSON with
/// a label nobody chose (ADR 0195).
fn checkAnswer(comptime pattern: []const u8, comptime Fn: type) void {
    comptime {
        const Returned = @typeInfo(Fn).@"fn".return_type orelse return;
        var V = switch (@typeInfo(Returned)) {
            .error_union => |u| u.payload,
            else => Returned,
        };
        if (V == void) return;
        if (hasNamedDecl(V, "nilo_response")) V = V.nilo_response;
        if (V == void) return;
        if (@typeInfo(V) == .optional) V = @typeInfo(V).optional.child;
        ownbody.check(pattern, V);
    }
}

fn fnTypeOf(comptime pattern: []const u8, comptime F: type) type {
    const Fn = switch (@typeInfo(F)) {
        .@"fn" => F,
        // A handler may also be given as a function pointer.
        .pointer => |p| if (@typeInfo(p.child) == .@"fn") p.child else notAFunction(pattern, F),
        else => notAFunction(pattern, F),
    };
    if (@typeInfo(Fn).@"fn".is_generic) @compileError(
        "nilo: the handler for route \"" ++ pattern ++ "\" is still generic (it has an " ++
            "`anytype` or `comptime` argument).\n" ++
            "  nilo has to know the type of every argument to match it. Write the types out.",
    );
    if (@typeInfo(Fn).@"fn".is_var_args) @compileError(
        "nilo: the handler for route \"" ++ pattern ++ "\" uses C varargs, which cannot be matched.",
    );
    return Fn;
}

fn notAFunction(comptime pattern: []const u8, comptime F: type) noreturn {
    @compileError(
        "nilo: the handler for route \"" ++ pattern ++ "\" has to be a function, not " ++
            naming.of(F) ++ ".\n" ++
            "  Write `app.get(\"" ++ pattern ++ "\", getUser)` — the function's name, not a call to it.",
    );
}

fn rolesOf(
    comptime pattern: []const u8,
    comptime params: []const std.builtin.Type.Fn.Param,
) []const Role {
    comptime {
        const param_names = patternParamNames(pattern);
        var roles: [params.len]Role = undefined;
        var used: usize = 0;
        var body_at: ?usize = null;
        var form_at: ?usize = null;
        var query_at: ?usize = null;
        var idempotent_at: ?usize = null;
        var wants_ctx = false;

        for (params, 0..) |p, i| {
            const P = p.type orelse @compileError(
                "nilo: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                    "\" has no type.",
            );
            roles[i] = roleOf(pattern, P, i);
            switch (roles[i]) {
                .ctx => wants_ctx = true,
                .param => {
                    if (used == param_names.len) @compileError(tooFewPatternParams(pattern, P, i, param_names));
                    roles[i] = .{ .param = used };
                    used += 1;
                },
                // Both arguments are named, and on purpose. nilo cannot know
                // which of the two was meant to be the body, so a message
                // that blamed only the second would send people to fix the
                // one argument that was probably already right.
                .body, .bound_body => {
                    if (body_at) |first| @compileError(
                        "nilo: the handler for route \"" ++ pattern ++ "\" takes two structs by " ++
                            "value — argument " ++ num(first + 1) ++ " is a " ++
                            naming.of(params[first].type.?) ++ " and argument " ++ num(i + 1) ++
                            " is a " ++ naming.of(P) ++ " — and a request only has one body.\n" ++
                            "  A value is request data and a pointer is a service, so whichever of " ++
                            "the two is not read from the body is asked for as a pointer: `*" ++
                            naming.of(params[first].type.?) ++ "`." ++
                            orMeantAsAParam(param_names, used),
                    );
                    body_at = i;
                    checkNotRenamed(pattern, readInto(roles[i], P), "request body");
                },
                // A form *is* the body — the same bytes, read by a different
                // rule — so the two are one slot and asking for both is the
                // same mistake as asking for two bodies. Worth its own
                // message because the fix is not "make one a pointer": one
                // of the two has to go.
                .form, .bound_form => {
                    if (form_at) |first| @compileError(
                        "nilo: the handler for route \"" ++ pattern ++ "\" asks for the form " ++
                            "twice — argument " ++ num(first + 1) ++ " and argument " ++
                            num(i + 1) ++ ".\n" ++
                            "  A request has one body. Put every field in a single struct and " ++
                            "ask for that.",
                    );
                    form_at = i;
                    const Fields = readInto(roles[i], P);
                    checkNotRenamed(pattern, Fields, "form");
                    form_mod.checkFields(Fields, if (roles[i] == .form)
                        "the `Form(" ++ naming.of(Fields) ++ ")` on route \"" ++ pattern ++ "\""
                    else
                        "the `Bound(Form(" ++ naming.of(Fields) ++ "))` on route \"" ++
                            pattern ++ "\"");
                },
                .query, .bound_query => {
                    if (query_at) |first| @compileError(
                        "nilo: the handler for route \"" ++ pattern ++ "\" asks for the query " ++
                            "string twice — argument " ++ num(first + 1) ++ " and argument " ++
                            num(i + 1) ++ ".\n" ++
                            "  A request has one query string. Put every field in a single struct " ++
                            "and ask for that.",
                    );
                    query_at = i;
                    checkNotRenamed(pattern, readInto(roles[i], P), "query string");
                    checkQueryFields(pattern, readInto(roles[i], P), i);
                },
                // Checked here, at the first place anybody names the type,
                // rather than deep inside the call that works it out. The
                // message names the resolver rather than the route: the
                // mistake belongs to the type, and would greet every route
                // that asked for it.
                .resolved => resolve.check(P),
                .idempotent => {
                    if (idempotent_at) |first| @compileError(
                        "nilo: the handler for route \"" ++ pattern ++ "\" asks for the " ++
                            "Idempotency-Key twice — argument " ++ num(first + 1) ++ " and argument " ++
                            num(i + 1) ++ ".\n" ++
                            "  A request has one key and one kept answer. Ask for it once.",
                    );
                    idempotent_at = i;
                },
                else => {},
            }
        }

        if (body_at != null and form_at != null) @compileError(
            "nilo: the handler for route \"" ++ pattern ++ "\" asks for both a request body " ++
                "(argument " ++ num(body_at.? + 1) ++ ", a " ++ naming.of(params[body_at.?].type.?) ++
                ") and a form (argument " ++ num(form_at.? + 1) ++ ") — and a request only has " ++
                "one body.\n" ++
                "  A form *is* the body, read as `application/x-www-form-urlencoded` or " ++
                "`multipart/form-data` instead of as JSON. Ask for one or the other, not both.",
        );

        // A handler holding a `*Ctx` may ignore path params — it can reach
        // them itself via `c.param("…")`. One without a `*Ctx` has no other
        // way in, so an unused param there is almost certainly a forgotten
        // argument.
        if (!wants_ctx and used < param_names.len) @compileError(
            "nilo: route \"" ++ pattern ++ "\" has " ++ num(param_names.len) ++ " path params (:" ++
                join(param_names, ", :") ++ "), but its handler only takes " ++ num(used) ++ ".\n" ++
                "  Path params are matched by position, so the ones at the end would never be read.\n" ++
                "  Add the arguments (`id: u32`, `name: nilo.Str`, …), drop the unused `:` from the " ++
                "pattern, or ask for a `*Ctx` if you would rather fetch them yourself with " ++
                "`c.param(\"…\")`.",
        );
        const frozen = roles;
        return &frozen;
    }
}

/// Refuse a struct that renames its fields where a request is *read*
/// ([ADR 0181](../docs/adr/0181-a-field-name-is-a-spelling-too.md)).
///
/// `rename_all` on a struct is a spelling for what goes out: `json.write` sends
/// the renamed keys and the API description promises them. Nothing renames on
/// the way in — `std.json` chooses the parser for a body and reads it into the
/// field names as they are written — so a type used for both would send
/// `fullName`, document `fullName`, and answer 400 to a client that sent it.
///
/// **A refusal rather than a second mechanism**, which is the whole of the
/// decision. One direction that works beats two that can disagree about one
/// field, and the two would be told apart by nothing a reader can see at the
/// call site.
fn checkNotRenamed(comptime pattern: []const u8, comptime T: type, comptime what: []const u8) void {
    comptime {
        const Renamed = mark.renamedFieldsWithin(T) orelse return;
        @compileError(
            "nilo: the " ++ what ++ " on route \"" ++ pattern ++ "\" is read into `" ++
                naming.of(Renamed) ++ "`, which renames its fields — and a renamed field name is a " ++
                "spelling for what goes out (ADR 0181).\n" ++
                "  nilo writes the renamed keys and the API description promises them; nothing " ++
                "renames on the way in, so a client sending what the document says would be a 400 " ++
                "naming every field.\n" ++
                "  Keep this type for the response, and give what comes in a struct of its own, " ++
                "spelled the way the wire spells it.",
        );
    }
}

/// The struct behind an argument that reads one, reaching through a binding
/// when there is one. `Form(T)`, `Query(T)` and `Bound(Form(T))` all answer
/// `T`, which is what every check on the fields wants to be given.
fn readInto(comptime role: Role, comptime P: type) type {
    return switch (role) {
        .body => P,
        .form => P.nilo_form,
        .query => P.nilo_query,
        .bound_body, .bound_form, .bound_query => P.Value,
        else => comptime unreachable,
    };
}

fn roleOf(comptime pattern: []const u8, comptime P: type, comptime i: usize) Role {
    if (P == *Ctx or P == *const Ctx) return .ctx;
    if (P == Str) return .{ .param = 0 };
    if (P == std.mem.Allocator) return .arena;
    // Before the two below it: a binding wraps one of them, and it is the
    // outer type that says how failures are answered.
    if (comptime hasNamedDecl(P, bound_mod.marker)) return switch (P.nilo_bound_slot) {
        .body => .bound_body,
        .form => .bound_form,
        .query => .bound_query,
    };
    if (comptime hasNamedDecl(P, "nilo_query")) return .query;
    if (comptime hasNamedDecl(P, "nilo_header")) {
        checkHeaderValue(pattern, P, i);
        return .header;
    }
    if (comptime authorization_mod.is(P)) return .authorization;
    if (comptime hasNamedDecl(P, "nilo_idempotent")) {
        idempotent_mod.checkSpace(P.nilo_idempotent.replays, pattern);
        return .idempotent;
    }
    if (comptime hasNamedDecl(P, form_mod.marker)) return .form;
    // Before `.@"struct" => .body`, and with a message of its own: an
    // `Upload` in the argument list is somebody reaching for a file the way
    // they would reach for a path param, and reading it as the request body
    // would land them in a JSON parse error about a type they never sent.
    if (P == form_mod.Upload) @compileError(
        "nilo: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
            "\" is a `nilo.Upload`, which is a field of a form rather than an argument of " ++
            "its own.\n" ++
            "  A file arrives as one field among several, so it is asked for inside the " ++
            "struct the form is read into:\n" ++
            "    const NewAvatar = struct { caption: nilo.Str, image: nilo.Upload };\n" ++
            "    fn upload(incoming: nilo.Form(NewAvatar)) !nilo.Status(201, Avatar) { … }",
    );
    // The other half of that mistake, and worth its own message for the same
    // reason: the two types are both "a file" and point in opposite
    // directions. Read as the request body — which is what a struct by value
    // is — this would land somewhere inside `std.json` being asked to parse a
    // directory descriptor, which is a message nilo did not write (ADR 0015).
    if (comptime filebody.isFileBody(P)) @compileError(
        "nilo: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
            "\" is a `nilo.FileBody`, which is what a handler answers *with* rather than " ++
            "something it is given.\n" ++
            "  A file arriving from the client is a `nilo.Upload`, one field of a form:\n" ++
            "    fn upload(incoming: nilo.Form(NewAvatar)) !nilo.Status(201, Avatar) { … }\n" ++
            "  A file going to the client is the return type:\n" ++
            "    fn invoice(files: *Files, id: u32) !?nilo.FileBody { … }",
    );
    // Before the `.@"struct" => .body` below, which would otherwise swallow
    // it: a resolved value is a struct too, and the marker is what tells the
    // two apart (ADR 0016).
    if (comptime resolve.isResolved(P)) return .resolved;
    // Before the switch entirely, and not only before `.@"struct" => .body`:
    // a type that says it can parse itself is a path param whatever kind it
    // is, and what a type says about itself wins over what its kind would
    // otherwise have meant (ADR 0142). Reading the marker is also what checks
    // its shape, so a `nilo_parse` written wrong is refused here.
    if (comptime convert_mod.parsesItself(P)) return .{ .param = 0 };

    return switch (@typeInfo(P)) {
        .int, .float, .bool, .@"enum" => .{ .param = 0 },

        .pointer => |p| switch (p.size) {
            .one => .service,
            .slice => @compileError(
                "nilo: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                    "\" is a " ++ naming.of(P) ++ ".\n" ++
                    "  Text from a request is asked for as a `nilo.Str`, not a bare slice: Str is " ++
                    "what stops the contents from outliving the request (ADR 0004).\n" ++
                    "  Inside the handler, `.view()` reads it and `.keep()` holds on to it.",
            ),
            else => @compileError(
                "nilo: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                    "\" is a " ++ naming.of(P) ++ ", which cannot be matched.\n" ++
                    "  A service is asked for as a pointer to a single value (`*Db`).",
            ),
        },

        .@"struct" => .body,

        .optional => @compileError(
            "nilo: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                "\" is a " ++ naming.of(P) ++ ".\n" ++
                "  A path param on a route that matched is always present, so an optional means " ++
                "nothing here.\n" ++
                "  A query param is the thing that may be absent, and there an optional is " ++
                "exactly right: put the field in a struct and ask for `nilo.Query(That)`.",
        ),

        else => if (comptime patch_mod.isPatch(P)) @compileError(
            "nilo: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                "\" is a `Patch(…)`, which is a field of a request body rather than an " ++
                "argument of its own.\n" ++
                "  A Patch says whether the body mentioned one field, so it only means " ++
                "anything inside the struct that body is read into:\n" ++
                "    const EditUser = struct { name: nilo.Patch(nilo.Str) = .absent };\n" ++
                "    fn editUser(id: u32, incoming: EditUser) !?User { … }",
        ) else @compileError(
            "nilo: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                "\" is a " ++ naming.of(P) ++ ", which nilo does not recognise.\n" ++
                "  What you can ask for: `*Ctx`, a pointer to a service (`*Db`), a path param " ++
                "(`u32`, `nilo.Str`, `bool`, an enum, or a type carrying `nilo_parse`), " ++
                "`nilo.Query(T)` for the query string, `nilo.FromHeader(\"X-Thing\", T)` for " ++
                "one header, a `std.mem.Allocator` for the request " ++
                "arena, or one struct for the request body.",
        ),
    };
}

/// A `FromHeader` has to name a header and ask for something request text can
/// become (ADR 0163). Checked where the argument is read, so the message
/// names the route and the header rather than landing inside `convert`.
fn checkHeaderValue(comptime pattern: []const u8, comptime P: type, comptime i: usize) void {
    comptime {
        const named = P.nilo_header.name;
        const V = P.nilo_header.value;

        if (named.len == 0) @compileError(
            "nilo: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                "\" is a `FromHeader(\"\", …)`, which names no header.\n" ++
                "  Write the header the client sends: `FromHeader(\"X-Staff-Id\", nilo.Str)`.",
        );
        // The same rule `http1` holds a response header to, asked here
        // because a name with a space in it can never match anything and the
        // document would carry it verbatim.
        if (!http1.headerNameOk(named)) @compileError(
            "nilo: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                "\" asks for the header \"" ++ named ++ "\", which is not a header name.\n" ++
                "  A header name is letters, digits and `-`, with no spaces or colons: " ++
                "`FromHeader(\"X-Staff-Id\", nilo.Str)`.",
        );

        if (!convert_mod.convertible(V)) @compileError(
            "nilo: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                "\" asks for the header \"" ++ named ++ "\" as a " ++ naming.of(V) ++
                ", which request text cannot become.\n" ++
                "  A header arrives as text, so it is read as a `nilo.Str`, a number, a " ++
                "`bool`, an enum, or a type that parses itself with `nilo_parse` — wrapped " ++
                "in `?` when the client may not send it.",
        );
    }
}

/// Read one header into the type the handler asked for. Absent is null for an
/// optional and a 400 for anything else, which is the rule `queryValue`
/// follows for a field with no default.
fn headerValue(comptime P: type, c: *const Ctx) !P.nilo_header.value {
    const V = P.nilo_header.value;
    const named = P.nilo_header.name;
    const Inner = switch (@typeInfo(V)) {
        .optional => |o| o.child,
        else => V,
    };

    if (c.header(named)) |s| {
        // `.query` rather than a slot of its own, for the reason a path param
        // uses it: what differs between the slots is how a form spells a
        // boolean, and a header is not a form.
        return try convert(Inner, .query, s, named);
    }
    if (comptime @typeInfo(V) == .optional) return null;
    return fail.badRequest("the {s} header is required", .{named});
}

/// Every field of a `Query(T)` struct has to be something a query value can
/// actually be turned into. Checked here so the message names the field
/// rather than landing somewhere inside the conversion.
fn checkQueryFields(comptime pattern: []const u8, comptime T: type, comptime i: usize) void {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                    "\" is a `Query(" ++ naming.of(T) ++ ")`, but " ++ naming.of(T) ++
                    " is not a struct.\n" ++
                    "  The query string is read into a struct: one field per query param.",
            ),
        };

        if (info.fields.len == 0) @compileError(
            "nilo: the `Query(" ++ naming.of(T) ++ ")` on route \"" ++ pattern ++
                "\" has no fields, so it would read nothing.\n" ++
                "  Add one field per query param you want: `page: u32 = 1`.",
        );

        for (info.fields) |f| {
            if (convert_mod.convertible(f.type)) continue;
            // A list of them, which is `?tag=a,b` and `?tag=a&tag=b`
            // ([ADR 0164](../docs/adr/0164-a-query-parameter-that-is-a-list.md)).
            // Checked here rather than in `convertible`, because the answer is
            // different one slot over: a `Form(T)` reads a body this file does
            // not, and promising a list there would compile and fill nothing.
            if (queryList(f.type)) |Item| {
                if (convert_mod.convertible(Item)) continue;
                @compileError(
                    "nilo: the field `" ++ f.name ++ ": " ++ naming.of(f.type) ++ "` of the " ++
                        "`Query(" ++ naming.of(T) ++ ")` on route \"" ++ pattern ++
                        "\" is a list of " ++ naming.of(Item) ++ ", which a query value " ++
                        "cannot become.\n" ++
                        "  Each value arrives as text, so the element is a `nilo.Str`, a " ++
                        "number, a `bool`, an enum, or a type that parses itself with " ++
                        "`nilo_parse`: `tags: []const nilo.Str = &.{}`.",
                );
            }
            @compileError(
                "nilo: the field `" ++ f.name ++ ": " ++ naming.of(f.type) ++ "` of the " ++
                    "`Query(" ++ naming.of(T) ++ ")` on route \"" ++ pattern ++
                    "\" is not something a query value can become.\n" ++
                    "  A query param arrives as text, so a field is a `nilo.Str`, a number, " ++
                    "a `bool`, an enum, or a type that parses itself with `nilo_parse` — " ++
                    "optionally wrapped in `?` when it may be absent.",
            );
        }
    }
}

/// The third thing an unplaceable struct can be, said only on a route that
/// still has a slot going spare.
///
/// The two-bodies message assumed a struct nilo cannot place is a service,
/// and told somebody with a `Uuid` argument to write `*Uuid` — which is a
/// database connection's shape, not a uuid's. That was the only answer there
/// was before a type could parse itself. Now there is a second one, and a
/// route with an unclaimed `:id` is exactly where it is the right one
/// (ADR 0142). Empty on a route with every param taken, because there the
/// sentence above is still the whole truth.
fn orMeantAsAParam(
    comptime param_names: []const []const u8,
    comptime used: usize,
) []const u8 {
    if (used >= param_names.len) return "";
    return "\n  Or, if it is meant to be the path param `:" ++ param_names[used] ++
        "`: a path param is a number, a `nilo.Str`, a `bool`, an enum, or a type carrying " ++
        "`pub fn nilo_parse(text: []const u8) ?Self`.";
}

fn tooFewPatternParams(
    comptime pattern: []const u8,
    comptime P: type,
    comptime i: usize,
    comptime param_names: []const []const u8,
) []const u8 {
    const has = if (param_names.len == 0)
        "the route has no path params at all"
    else
        "the route only has " ++ num(param_names.len) ++ " (:" ++ join(param_names, ", :") ++ ")";

    return "nilo: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
        "\" is a " ++ naming.of(P) ++ ", so nilo reads it as a path param — but " ++ has ++ ".\n" ++
        "  Add `:name` to the route pattern, or — if " ++ naming.of(P) ++
        " is a service — ask for it as a pointer: `*" ++ naming.of(P) ++ "`.";
}

/// The name of everything the pattern captures, in order of appearance:
/// each `:param`, and a trailing `*` under the name `"*"`.
fn patternParamNames(comptime pattern: []const u8) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        var segs = std.mem.splitScalar(u8, pattern, '/');
        while (segs.next()) |s| {
            if (s.len > 1 and s[0] == ':') names = names ++ [_][]const u8{s[1..]};
            if (std.mem.eql(u8, s, router.wildcard)) names = names ++ [_][]const u8{router.wildcard};
        }
        return names;
    }
}

fn num(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

fn join(comptime parts: []const []const u8, comptime separator: []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (parts, 0..) |p, i| result = result ++ (if (i == 0) "" else separator) ++ p;
        return result;
    }
}

// ---- the runtime side ----

fn paramValue(comptime P: type, c: *const Ctx, comptime name: []const u8) !P {
    // The route already matched, so the param is certainly there; the
    // `orelse` is only so a bug in nilo itself shows up as a message
    // rather than a panic.
    const s = c.param(name) orelse
        return fail.internal("path param :{s} was not filled in by the router", .{name});
    // `.query` rather than a slot of its own: a path param and a query value
    // are both URL text and parse identically. `form` is the only slot that
    // differs, and a path param is never one.
    return convert(P, .query, s, ":" ++ name);
}

/// The element of a query field that is a list, or null when it is not one
/// ([ADR 0164](../docs/adr/0164-a-query-parameter-that-is-a-list.md)).
///
/// `convert.zig`'s, because `bound.zig` has to give the same answer when it
/// words the failure of one — and a list that fills here and reports as
/// "cannot fail" over there ends at an `unreachable`.
const queryList = convert_mod.listElement;

/// How many values a query string holds for `name`, counting the pieces of
/// each comma-joined one.
fn countList(c: *const Ctx, comptime name: []const u8) usize {
    var n: usize = 0;
    var it = c.queries();
    while (it.next()) |p| {
        if (!std.mem.eql(u8, p.name.view(), name)) continue;
        var pieces = std.mem.splitScalar(u8, p.value.view(), ',');
        while (pieces.next()) |piece| {
            if (piece.len > 0) n += 1;
        }
    }
    return n;
}

/// Every value of one repeated or comma-joined query parameter, converted
/// ([ADR 0164](../docs/adr/0164-a-query-parameter-that-is-a-list.md)).
///
/// **Both spellings are read, and that is the decision.** `?type=A,B` is what
/// nilo writes into the document as `style: form, explode: false`, and it is
/// what a client generated from that document sends. `?type=A&type=B` is what
/// half the clients in the world send anyway, and a server that takes the
/// first and drops the rest answers with fewer rows — which looks exactly
/// like a filter that worked. Reading both costs one comparison and removes
/// the failure mode rather than documenting it.
///
/// **One allocation, for a route that asked for a list and no other.** The
/// elements point into the query string, which lives as long as the request;
/// what is allocated is the slice of them, sized by a first pass, out of the
/// request arena (ADR 0018).
///
/// An empty value contributes nothing, so `?tags=` is an empty list rather
/// than a list holding one empty string. That is the cost of the separator:
/// a value with a comma in it cannot be sent, and a value that is empty
/// cannot be told from an absent one.
fn collectList(
    comptime Item: type,
    c: *const Ctx,
    comptime name: []const u8,
    comptime label: []const u8,
) ![]const Item {
    const n = countList(c, name);
    if (n == 0) return &.{};

    const out = c.arena().alloc(Item, n) catch
        return fail.internal("no room for the values of {s}", .{label});

    var at: usize = 0;
    var it = c.queries();
    while (it.next()) |p| {
        if (!std.mem.eql(u8, p.name.view(), name)) continue;
        var pieces = std.mem.splitScalar(u8, p.value.view(), ',');
        while (pieces.next()) |piece| {
            if (piece.len == 0) continue;
            out[at] = try convert(Item, .query, Str.fromRequest(piece, c._lifetime), label);
            at += 1;
        }
    }
    return out[0..at];
}

/// `collectList`, recording what would not convert instead of answering with
/// it (ADR 0164). The **first** bad value is the one the handler is told
/// about, and the rest of the list is still read: a filter with one typo in
/// it is a filter, not a request with nothing in it.
fn collectListCollecting(
    comptime Item: type,
    c: *const Ctx,
    comptime name: []const u8,
    outcome: *convert_mod.Outcome,
) ![]const Item {
    const n = countList(c, name);
    if (n == 0) return &.{};

    const out = try c.arena().alloc(Item, n);
    var at: usize = 0;
    var it = c.queries();
    while (it.next()) |p| {
        if (!std.mem.eql(u8, p.name.view(), name)) continue;
        var pieces = std.mem.splitScalar(u8, p.value.view(), ',');
        while (pieces.next()) |piece| {
            if (piece.len == 0) continue;
            const text = Str.fromRequest(piece, c._lifetime);
            var converted: Item = undefined;
            if (convert_mod.tryConvert(Item, .query, text, &converted)) |reason| {
                if (outcome.reason == null) {
                    outcome.given = text;
                    outcome.reason = reason;
                }
            } else {
                out[at] = converted;
                at += 1;
            }
        }
    }
    return out[0..at];
}

/// Read the query string into `T`. A field that is absent falls back to its
/// default, or to null if it is optional; one with neither is required, and
/// saying so is a 400 rather than a surprise zero.
fn queryValue(comptime T: type, c: *const Ctx) !T {
    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const label = "?" ++ f.name;
        if (comptime queryList(f.type)) |Item| {
            // A list is never "absent": nothing sent is the empty list, which
            // is what every filter written against one already means. A
            // default is still honoured, for the field that wants one.
            const found = try collectList(Item, c, f.name, label);
            if (found.len == 0) {
                if (f.defaultValue()) |default| {
                    @field(out, f.name) = default;
                } else if (@typeInfo(f.type) == .optional) {
                    @field(out, f.name) = null;
                } else {
                    @field(out, f.name) = &.{};
                }
            } else {
                @field(out, f.name) = found;
            }
        } else if (c.query(f.name)) |s| {
            const Inner = switch (@typeInfo(f.type)) {
                .optional => |o| o.child,
                else => f.type,
            };
            @field(out, f.name) = try convert(Inner, .query, s, label);
        } else if (f.defaultValue()) |default| {
            @field(out, f.name) = default;
        } else if (@typeInfo(f.type) == .optional) {
            @field(out, f.name) = null;
        } else {
            return fail.badRequest("{s} is required", .{label});
        }
    }
    return out;
}

/// Read the query string into `T`, recording why each field that would not
/// bind did not rather than stopping at the first one.
///
/// Cannot fail: a query string is always there to be read — an absent one is
/// every field missing — so there is nothing here to return an error for.
fn queryValueCollecting(
    comptime T: type,
    c: *const Ctx,
    outcomes: *[@typeInfo(T).@"struct".fields.len]convert_mod.Outcome,
) T {
    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
        outcomes[i] = .{};
        const Inner = switch (@typeInfo(f.type)) {
            .optional => |o| o.child,
            else => f.type,
        };

        if (comptime queryList(f.type)) |Item| {
            // The same reading as `queryValue`, with the one difference this
            // whole function is: a value that will not convert is recorded
            // rather than answered (ADR 0164, `bound.zig`).
            const found = collectListCollecting(Item, c, f.name, &outcomes[i]) catch &.{};
            if (found.len == 0) {
                if (f.defaultValue()) |default| {
                    @field(out, f.name) = default;
                } else if (@typeInfo(f.type) == .optional) {
                    @field(out, f.name) = null;
                } else {
                    @field(out, f.name) = &.{};
                }
            } else {
                @field(out, f.name) = found;
            }
        } else if (c.query(f.name)) |s| {
            outcomes[i].given = s;
            var converted: Inner = undefined;
            if (convert_mod.tryConvert(Inner, .query, s, &converted)) |reason| {
                outcomes[i].reason = reason;
                if (f.defaultValue()) |default| @field(out, f.name) = default;
            } else {
                @field(out, f.name) = converted;
            }
        } else if (f.defaultValue()) |default| {
            @field(out, f.name) = default;
        } else if (@typeInfo(f.type) == .optional) {
            @field(out, f.name) = null;
        } else {
            outcomes[i].reason = .missing;
        }
    }
    return out;
}

/// Turn one piece of request text into the type the handler asked for.
/// Path params, query values and form fields all come through here, so all
/// three say the same thing when the text does not fit (`convert.zig`).
const convert = convert_mod.convert;

fn sendResult(c: *Ctx, result: anytype) !void {
    const R = @TypeOf(result);
    const value = if (@typeInfo(R) == .error_union) try result else result;
    const T = @TypeOf(value);

    if (T == void) return;
    // Before `nilo_response`, and carrying no body of its own: a redirect
    // is a status and a Location, and its `headers` are how a sign-in sends
    // a `Set-Cookie` on the way out (ADR 0032).
    if (comptime hasNamedDecl(T, "nilo_redirect")) {
        for (value.headers.view()) |h| try c.setHeader(h.name, h.value);
        return c.redirect(T.nilo_redirect, value.location);
    }
    if (comptime hasNamedDecl(T, "nilo_response")) {
        // Copied rather than borrowed, the same as `Ctx.setHeader`: a
        // handler assembling a header value has the request arena to build
        // it in, and should not have to think about which of the two it is.
        for (value.headers.view()) |h| try c.setHeader(h.name, h.value);
        const status = if (comptime hasNamedDecl(T, "nilo_status"))
            T.nilo_status
        else
            value.status;
        return sendValue(c, status, value.value);
    }
    return sendValue(c, 200, value);
}

fn sendValue(c: *Ctx, status: u16, value: anytype) !void {
    const T = @TypeOf(value);
    // Nothing to describe and nothing to send. Under a 204 that is the whole
    // response; under any other status it is an empty body with no content
    // type, which is still the truth.
    if (T == void) return c.sendEmpty(status);
    // `?T` is how a signature says "this may not exist", and the only answer
    // HTTP has for that is a 404 (ADR 0024). The alternative — 200 with the
    // body `null` — is a thing nobody meant and every client crashes on.
    if (comptime @typeInfo(T) == .optional) {
        const present = value orelse return fail.notFound("there is no {s}", .{c._path});
        return sendValue(c, status, present);
    }
    // Here, and not up in `sendResult` beside `Redirect`, because of where
    // the optional is unwrapped. `?Redirect` is not an idiom — a redirect is
    // an answer the handler decided on, so there is nothing for the `?` to
    // mean — while `?FileBody` is the *main* idiom: a file that may not be
    // there is what "the invoice for this id" almost always is, and ADR 0037
    // leans on `?` meaning a 404 exactly as it does everywhere else
    // (ADR 0024). Recognised after the unwrap, one line of dispatch serves
    // both `FileBody` and `?FileBody`.
    //
    // `status` is not passed on, and that is not an oversight: what a file
    // answers with is decided by the conditional and range machinery in
    // `sendfile.send` — a 200, a 206, a 304 or a 416 — and no field on a
    // `Response(FileBody)` could be right about which.
    if (comptime filebody.isFileBody(T)) return filebody.send(c, value);
    // A type that writes its own answer, under its own label (ADR 0195).
    // Dispatched here, after every wrapper is taken apart, so `?T`,
    // `Status(201, T)` and `Response(T)` all reach it the way they reach
    // JSON. What it costs is what JSON costs: the same arena buffer, the
    // same `send`.
    if (comptime ownbody.writesItsOwnBody(T)) {
        var out: std.Io.Writer.Allocating = try .initCapacity(c._arena, ctx_mod.json_hint);
        try value.nilo_write(&out.writer);
        return c.send(status, T.nilo_content_type, out.written());
    }
    if (T == Str) return c.sendText(status, value.view());
    // The same question `contentTypeFor` asks, and it has to be the same
    // answer: a body sent as JSON under a `text/plain` label, or the other way
    // round, is the response and its own description disagreeing.
    if (comptime json_mod.isByteSlice(T)) return c.sendText(status, value);
    return c.sendJson(status, value);
}

fn hasNamedDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

// ---- tests ----

const testing = std.testing;

/// A type of the reader's own carrying all three declarations `sql.Uuid`
/// carries: it reads itself out of request text, writes its own JSON, and
/// says what that JSON looks like. `http/` may not import `nilo_id`, and each
/// of the three is a declaration read by name precisely so that it need not
/// (ADR 0042, ADR 0076, ADR 0142).
const Ticket = struct {
    number: u32,

    pub fn nilo_parse(text: []const u8) ?Ticket {
        if (text.len == 0 or text[0] != 'T') return null;
        return .{ .number = std.fmt.parseInt(u32, text[1..], 10) catch return null };
    }

    pub fn jsonStringify(self: Ticket, jw: anytype) !void {
        var buf: [16]u8 = undefined;
        try jw.write(std.fmt.bufPrint(&buf, "T{d}", .{self.number}) catch unreachable);
    }

    pub const nilo_openapi = .{ .type = "string", .format = "ticket" };
};

fn showTicket(id: Ticket) Ticket {
    return id;
}

test "a type that says it can parse itself is a path param, not the request body" {
    // The whole of the bug ADR 0142 closes: a struct by value used to be the
    // request body whatever it said about itself, so a route could not take
    // one as its `:id` at all.
    const roles = comptime rolesOf("/tickets/:id", @typeInfo(@TypeOf(showTicket)).@"fn".params);
    try testing.expect(roles[0] == .param);
    try testing.expectEqual(@as(usize, 0), roles[0].param);
}

test "the third answer is offered only where there is a slot for it" {
    // The sentence itself, because a Refusal can only pin the first line of a
    // message and this one is the third. What it guards is the mistake
    // ADR 0142 found: the old wording told everybody to write `*Uuid`.
    try testing.expectEqualStrings(
        "\n  Or, if it is meant to be the path param `:sku`: a path param is a number, " ++
            "a `nilo.Str`, a `bool`, an enum, or a type carrying " ++
            "`pub fn nilo_parse(text: []const u8) ?Self`.",
        comptime orMeantAsAParam(&.{"sku"}, 0),
    );

    // A route with no params, and one whose only param is already claimed.
    // Both leave the old two-sentence message exactly as it was.
    try testing.expectEqualStrings("", comptime orMeantAsAParam(&.{}, 0));
    try testing.expectEqualStrings("", comptime orMeantAsAParam(&.{"id"}, 1));
}

test "a path param that parses itself is described by what the type says, not by its fields" {
    var op = comptime operation("/tickets/:id", showTicket);
    op.method = .GET;

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try openapi.write(&w, &.{op}, .{});
    const doc = buf[0..w.end];

    // `number: u32` is what reflecting the struct would have published, and
    // it is not what arrives on the wire.
    try testing.expect(std.mem.indexOf(u8, doc, "\"name\":\"id\",\"in\":\"path\"," ++
        "\"required\":true,\"schema\":{\"type\":\"string\",\"format\":\"ticket\"}") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"number\"") == null);

    // And nilo can now refuse the request before the handler runs, which is
    // the other half of what the reporter was after.
    try testing.expect(std.mem.indexOf(u8, doc, "\"400\"") != null);
}

test "a Str path param is still a bare string, so nothing was widened by accident" {
    const showName = struct {
        fn showName(name: Str) Str {
            return name;
        }
    }.showName;

    var op = comptime operation("/people/:name", showName);
    op.method = .GET;

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try openapi.write(&w, &.{op}, .{});
    const doc = buf[0..w.end];

    try testing.expect(std.mem.indexOf(u8, doc, "\"name\":\"name\",\"in\":\"path\"," ++
        "\"required\":true,\"schema\":{\"type\":\"string\"}") != null);
    // Nothing to convert, so nothing to refuse.
    try testing.expect(std.mem.indexOf(u8, doc, "\"400\"") == null);
}
