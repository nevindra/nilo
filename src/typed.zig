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
//! | `Query(T)`            | the query string, read into a struct of yours |
//! | `Form(T)`             | the body as an HTML form, into a struct of yours (ADR 0031) |
//! | `std.mem.Allocator`   | the request arena, freed when the request ends |
//! | a type carrying `zfast_resolve` | a resolved value, worked out from the request (ADR 0016) |
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
const converting = @import("convert.zig");
const ctx_mod = @import("ctx.zig");
const form_mod = @import("form.zig");
const http1 = @import("http1.zig");
const router = @import("router.zig");
const service_mod = @import("service.zig");
const fail = @import("fail.zig");
const str_mod = @import("str.zig");
const resolve = @import("resolve.zig");
const openapi = @import("openapi.zig");
const patch_mod = @import("patch.zig");
const bound_mod = @import("bound.zig");
const filebody = @import("filebody.zig");

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
        pub const zfast_response = void;

        status: u16 = 200,
        headers: Headers = .{},
        value: void = {},
    };
    return struct {
        pub const zfast_response = T;

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
        pub const zfast_response = void;
        pub const zfast_status = code;

        headers: Headers = .{},
        value: void = {},
    };
    return struct {
        pub const zfast_response = T;
        pub const zfast_status = code;

        headers: Headers = .{},
        value: T,
    };
}

/// One header on a `Response`.
pub const Header = http1.Header;

/// The headers a `Response` carries, held by value rather than pointed at.
///
/// That is the whole reason this type exists. `headers: []const Header` read
/// beautifully and was a use-after-return: a list written in the handler
/// lives in the handler's own stack frame, and zfast reads it after the
/// handler has returned. With every value a literal the compiler puts the
/// list in static memory and it happens to work; with a computed one — and a
/// `Location` never is a literal — `Debug` gets away with it and release
/// segfaults ([ADR 0019](../docs/adr/0019-a-response-owns-its-headers.md)).
///
/// `of` copies while the list is still alive, which is why it has to be
/// called where the list is written:
///
/// ```zig
/// .headers = .of(&.{
///     .{ .name = "Location", .value = try std.fmt.allocPrint(arena, "/users/{d}", .{id}) },
/// }),
/// ```
///
/// What is copied is the two slices, not the bytes they point at, so the
/// usual rule still holds for the *value*: a literal, something a Service
/// owns, or something built in the request arena. `c.setHeader` remains the
/// way to set a header without a count to think about.
pub const Headers = struct {
    /// How many one response can carry. Enough for the ones a handler
    /// actually decides — `Location`, a couple of `Set-Cookie`, a cache
    /// directive — and small enough that carrying them by value is 264
    /// bytes rather than something worth measuring. Past this, `c.setHeader`
    /// has no limit.
    pub const room = 8;

    entries: [room]Header = undefined,
    count: usize = 0,

    /// Copy a list of headers written out in place. The list may be a
    /// pointer to one (`&.{…}`, which is what reads best) or the tuple
    /// itself; either way its length is known while compiling, which is what
    /// lets a ninth header be a compile error rather than a surprise.
    pub fn of(list: anytype) Headers {
        // The `.one` is doing work: a slice is a pointer too, and
        // dereferencing one is an error from inside this function rather
        // than the message below — the exact failure ADR 0015 is about.
        const items = switch (@typeInfo(@TypeOf(list))) {
            .pointer => |p| if (p.size == .one) list.* else notAList(@TypeOf(list)),
            else => list,
        };
        const count = comptime lengthOf(@TypeOf(items));
        var made: Headers = .{ .count = count };
        inline for (0..count) |i| {
            made.entries[i] = .{ .name = items[i].name, .value = items[i].value };
        }
        return made;
    }

    /// The headers that were set, in the order they were written.
    pub fn view(self: *const Headers) []const Header {
        return self.entries[0..self.count];
    }

    fn lengthOf(comptime Items: type) usize {
        comptime {
            const count = switch (@typeInfo(Items)) {
                .array => |a| a.len,
                .@"struct" => |s| if (s.is_tuple) s.fields.len else notAList(Items),
                else => notAList(Items),
            };
            if (count > room) @compileError(std.fmt.comptimePrint(
                "zfast: a Response can carry {d} headers and this one was given {d}.\n" ++
                    "  Set the rest with `c.setHeader`, which has no limit.",
                .{ room, count },
            ));
            return count;
        }
    }

    fn notAList(comptime Items: type) noreturn {
        @compileError(
            "zfast: Response headers have to be written out where they are set — " ++
                ".of(&.{.{ .name = \"Location\", .value = where }}) — and this is a " ++
                naming.of(Items) ++ ".\n" ++
                "  A slice would not say how many there are until the program runs, and the " ++
                "response has to hold them itself.",
        );
    }
};

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
        pub const zfast_query = T;

        value: T,
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
    /// The body again, but as an HTML form rather than as JSON (ADR 0031).
    /// A separate role and not a flavour of `.body`, because the two are
    /// the same slot and asking for both has to be refused.
    form,
    /// The request arena, for a handler that has to build something that
    /// outlives its own stack frame — a `Location` header, usually.
    arena,
    /// A value zfast works out from the request before the handler runs —
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

    const Wrapper = struct {
        fn run(c: *Ctx) anyerror!void {
            var args: std.meta.ArgsTuple(Fn) = undefined;
            inline for (params, 0..) |p, i| {
                const P = p.type.?;
                switch (comptime roles[i]) {
                    .ctx => args[i] = c,
                    .service => args[i] = c._services.get(P) orelse
                        return fail.internal(
                            "service {s} was never registered; call app.provide() before app.listen()",
                            .{@typeName(P)},
                        ),
                    .param => |nth| args[i] = try paramValue(P, c, param_names[nth]),
                    .body => args[i] = try c.json(P),
                    .query => args[i] = .{ .value = try queryValue(P.zfast_query, c) },
                    .form => args[i] = .{ .value = try c.form(P.zfast_form) },
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
            return sendResult(c, @call(.auto, f, args));
        }
    };
    return Wrapper.run;
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
        var body: ?*const openapi.Schema = null;
        var body_kind: openapi.BodyKind = .json;
        // Whether zfast can refuse this request before the handler runs.
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
                query = queryFields(p.type.?.zfast_query);
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
                const Fields = p.type.?.zfast_form;
                body = openapi.schemaOf(Fields);
                body_kind = if (form_mod.holdsAFile(Fields)) .multipart else .urlencoded;
                can_reject = true;
            },
            // Described exactly as the slot it binds — the request looks the
            // same on the wire either way — but `can_reject` stays false, and
            // that is the whole difference. zfast no longer refuses this
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
        answer.written = wants_ctx and returnsNothing(Fn);

        return .{
            .method = .other, // filled in by the caller, which knows the verb
            .pattern = pattern,
            .params = path_params,
            .query = query,
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
            out = out ++ [_]openapi.Field{.{
                .name = f.name,
                .schema = openapi.schemaOf(f.type),
                // Absent is allowed when there is a default to fall back to,
                // or when the field is optional and absent means null — the
                // same two exemptions `queryValue` applies at runtime.
                .required = f.default_value_ptr == null and @typeInfo(f.type) != .optional,
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
        if (hasNamedDecl(V, "zfast_redirect")) return .{
            .status = V.zfast_redirect,
            .content_type = "",
            .schema = null,
            .redirect = true,
        };

        if (hasNamedDecl(V, "zfast_response")) {
            // The status of a `Response(T)` is a field the handler fills in,
            // so it is not knowable here. Saying "default" is the truth;
            // claiming 200 for a route that answers 201 would not be. A
            // `Status(code, T)` puts the code in the type instead, which is
            // the whole reason that type exists (ADR 0024).
            const status: ?u16 = if (hasNamedDecl(V, "zfast_status")) V.zfast_status else null;
            const Inner = V.zfast_response;
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
            .content_type = contentTypeFor(Present),
            .schema = openapi.schemaOf(Present),
            .not_found = Present != V,
        };
    }
}

fn contentTypeFor(comptime T: type) []const u8 {
    if (T == Str or T == []const u8 or T == []u8) return "text/plain";
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
        _ = rolesOf(pattern, @typeInfo(fnTypeOf(pattern, @TypeOf(handler))).@"fn".params);
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
        "zfast: the handler for route \"" ++ pattern ++ "\" is still generic (it has an " ++
            "`anytype` or `comptime` argument).\n" ++
            "  zfast has to know the type of every argument to match it. Write the types out.",
    );
    if (@typeInfo(Fn).@"fn".is_var_args) @compileError(
        "zfast: the handler for route \"" ++ pattern ++ "\" uses C varargs, which cannot be matched.",
    );
    return Fn;
}

fn notAFunction(comptime pattern: []const u8, comptime F: type) noreturn {
    @compileError(
        "zfast: the handler for route \"" ++ pattern ++ "\" has to be a function, not " ++
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
        var wants_ctx = false;

        for (params, 0..) |p, i| {
            const P = p.type orelse @compileError(
                "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
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
                // Both arguments are named, and on purpose. zfast cannot know
                // which of the two was meant to be the body, so a message
                // that blamed only the second would send people to fix the
                // one argument that was probably already right.
                .body, .bound_body => {
                    if (body_at) |first| @compileError(
                        "zfast: the handler for route \"" ++ pattern ++ "\" takes two structs by " ++
                            "value — argument " ++ num(first + 1) ++ " is a " ++
                            naming.of(params[first].type.?) ++ " and argument " ++ num(i + 1) ++
                            " is a " ++ naming.of(P) ++ " — and a request only has one body.\n" ++
                            "  A value is request data and a pointer is a service, so whichever of " ++
                            "the two is not read from the body is asked for as a pointer: `*" ++
                            naming.of(params[first].type.?) ++ "`.",
                    );
                    body_at = i;
                },
                // A form *is* the body — the same bytes, read by a different
                // rule — so the two are one slot and asking for both is the
                // same mistake as asking for two bodies. Worth its own
                // message because the fix is not "make one a pointer": one
                // of the two has to go.
                .form, .bound_form => {
                    if (form_at) |first| @compileError(
                        "zfast: the handler for route \"" ++ pattern ++ "\" asks for the form " ++
                            "twice — argument " ++ num(first + 1) ++ " and argument " ++
                            num(i + 1) ++ ".\n" ++
                            "  A request has one body. Put every field in a single struct and " ++
                            "ask for that.",
                    );
                    form_at = i;
                    const Fields = readInto(roles[i], P);
                    form_mod.checkFields(Fields, if (roles[i] == .form)
                        "the `Form(" ++ naming.of(Fields) ++ ")` on route \"" ++ pattern ++ "\""
                    else
                        "the `Bound(Form(" ++ naming.of(Fields) ++ "))` on route \"" ++
                            pattern ++ "\"");
                },
                .query, .bound_query => {
                    if (query_at) |first| @compileError(
                        "zfast: the handler for route \"" ++ pattern ++ "\" asks for the query " ++
                            "string twice — argument " ++ num(first + 1) ++ " and argument " ++
                            num(i + 1) ++ ".\n" ++
                            "  A request has one query string. Put every field in a single struct " ++
                            "and ask for that.",
                    );
                    query_at = i;
                    checkQueryFields(pattern, readInto(roles[i], P), i);
                },
                // Checked here, at the first place anybody names the type,
                // rather than deep inside the call that works it out. The
                // message names the resolver rather than the route: the
                // mistake belongs to the type, and would greet every route
                // that asked for it.
                .resolved => resolve.check(P),
                else => {},
            }
        }

        if (body_at != null and form_at != null) @compileError(
            "zfast: the handler for route \"" ++ pattern ++ "\" asks for both a request body " ++
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
            "zfast: route \"" ++ pattern ++ "\" has " ++ num(param_names.len) ++ " path params (:" ++
                join(param_names, ", :") ++ "), but its handler only takes " ++ num(used) ++ ".\n" ++
                "  Path params are matched by position, so the ones at the end would never be read.\n" ++
                "  Add the arguments (`id: u32`, `name: zfast.Str`, …), drop the unused `:` from the " ++
                "pattern, or ask for a `*Ctx` if you would rather fetch them yourself with " ++
                "`c.param(\"…\")`.",
        );
        const frozen = roles;
        return &frozen;
    }
}

/// The struct behind an argument that reads one, reaching through a binding
/// when there is one. `Form(T)`, `Query(T)` and `Bound(Form(T))` all answer
/// `T`, which is what every check on the fields wants to be given.
fn readInto(comptime role: Role, comptime P: type) type {
    return switch (role) {
        .body => P,
        .form => P.zfast_form,
        .query => P.zfast_query,
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
    if (comptime hasNamedDecl(P, bound_mod.marker)) return switch (P.zfast_bound_slot) {
        .body => .bound_body,
        .form => .bound_form,
        .query => .bound_query,
    };
    if (comptime hasNamedDecl(P, "zfast_query")) return .query;
    if (comptime hasNamedDecl(P, form_mod.marker)) return .form;
    // Before `.@"struct" => .body`, and with a message of its own: an
    // `Upload` in the argument list is somebody reaching for a file the way
    // they would reach for a path param, and reading it as the request body
    // would land them in a JSON parse error about a type they never sent.
    if (P == form_mod.Upload) @compileError(
        "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
            "\" is a `zfast.Upload`, which is a field of a form rather than an argument of " ++
            "its own.\n" ++
            "  A file arrives as one field among several, so it is asked for inside the " ++
            "struct the form is read into:\n" ++
            "    const NewAvatar = struct { caption: zfast.Str, image: zfast.Upload };\n" ++
            "    fn upload(incoming: zfast.Form(NewAvatar)) !zfast.Status(201, Avatar) { … }",
    );
    // The other half of that mistake, and worth its own message for the same
    // reason: the two types are both "a file" and point in opposite
    // directions. Read as the request body — which is what a struct by value
    // is — this would land somewhere inside `std.json` being asked to parse a
    // directory descriptor, which is a message zfast did not write (ADR 0015).
    if (comptime filebody.isFileBody(P)) @compileError(
        "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
            "\" is a `zfast.FileBody`, which is what a handler answers *with* rather than " ++
            "something it is given.\n" ++
            "  A file arriving from the client is a `zfast.Upload`, one field of a form:\n" ++
            "    fn upload(incoming: zfast.Form(NewAvatar)) !zfast.Status(201, Avatar) { … }\n" ++
            "  A file going to the client is the return type:\n" ++
            "    fn invoice(files: *Files, id: u32) !?zfast.FileBody { … }",
    );
    // Before the `.@"struct" => .body` below, which would otherwise swallow
    // it: a resolved value is a struct too, and the marker is what tells the
    // two apart (ADR 0016).
    if (comptime resolve.isResolved(P)) return .resolved;

    return switch (@typeInfo(P)) {
        .int, .float, .bool, .@"enum" => .{ .param = 0 },

        .pointer => |p| switch (p.size) {
            .one => .service,
            .slice => @compileError(
                "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                    "\" is a " ++ naming.of(P) ++ ".\n" ++
                    "  Text from a request is asked for as a `zfast.Str`, not a bare slice: Str is " ++
                    "what stops the contents from outliving the request (ADR 0004).\n" ++
                    "  Inside the handler, `.view()` reads it and `.keep()` holds on to it.",
            ),
            else => @compileError(
                "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                    "\" is a " ++ naming.of(P) ++ ", which cannot be matched.\n" ++
                    "  A service is asked for as a pointer to a single value (`*Db`).",
            ),
        },

        .@"struct" => .body,

        .optional => @compileError(
            "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                "\" is a " ++ naming.of(P) ++ ".\n" ++
                "  A path param on a route that matched is always present, so an optional means " ++
                "nothing here.\n" ++
                "  A query param is the thing that may be absent, and there an optional is " ++
                "exactly right: put the field in a struct and ask for `zfast.Query(That)`.",
        ),

        else => if (comptime patch_mod.isPatch(P)) @compileError(
            "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                "\" is a `Patch(…)`, which is a field of a request body rather than an " ++
                "argument of its own.\n" ++
                "  A Patch says whether the body mentioned one field, so it only means " ++
                "anything inside the struct that body is read into:\n" ++
                "    const EditUser = struct { name: zfast.Patch(zfast.Str) = .absent };\n" ++
                "    fn editUser(id: u32, incoming: EditUser) !?User { … }",
        ) else @compileError(
            "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                "\" is a " ++ naming.of(P) ++ ", which zfast does not recognise.\n" ++
                "  What you can ask for: `*Ctx`, a pointer to a service (`*Db`), a path param " ++
                "(`u32`, `zfast.Str`, `bool`, an enum), `zfast.Query(T)` for the query string, " ++
                "a `std.mem.Allocator` for the request arena, or one struct for the request body.",
        ),
    };
}

/// Every field of a `Query(T)` struct has to be something a query value can
/// actually be turned into. Checked here so the message names the field
/// rather than landing somewhere inside the conversion.
fn checkQueryFields(comptime pattern: []const u8, comptime T: type, comptime i: usize) void {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(
                "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                    "\" is a `Query(" ++ naming.of(T) ++ ")`, but " ++ naming.of(T) ++
                    " is not a struct.\n" ++
                    "  The query string is read into a struct: one field per query param.",
            ),
        };

        if (info.fields.len == 0) @compileError(
            "zfast: the `Query(" ++ naming.of(T) ++ ")` on route \"" ++ pattern ++
                "\" has no fields, so it would read nothing.\n" ++
                "  Add one field per query param you want: `page: u32 = 1`.",
        );

        for (info.fields) |f| {
            if (converting.convertible(f.type)) continue;
            @compileError(
                "zfast: the field `" ++ f.name ++ ": " ++ naming.of(f.type) ++ "` of the " ++
                    "`Query(" ++ naming.of(T) ++ ")` on route \"" ++ pattern ++
                    "\" is not something a query value can become.\n" ++
                    "  A query param arrives as text, so a field is a `zfast.Str`, a number, " ++
                    "a `bool`, or an enum — optionally wrapped in `?` when it may be absent.",
            );
        }
    }
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

    return "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
        "\" is a " ++ naming.of(P) ++ ", so zfast reads it as a path param — but " ++ has ++ ".\n" ++
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
    // `orelse` is only so a bug in zfast itself shows up as a message
    // rather than a panic.
    const s = c.param(name) orelse
        return fail.internal("path param :{s} was not filled in by the router", .{name});
    return convert(P, s, ":" ++ name);
}

/// Read the query string into `T`. A field that is absent falls back to its
/// default, or to null if it is optional; one with neither is required, and
/// saying so is a 400 rather than a surprise zero.
fn queryValue(comptime T: type, c: *const Ctx) !T {
    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const label = "?" ++ f.name;
        if (c.query(f.name)) |s| {
            const Inner = switch (@typeInfo(f.type)) {
                .optional => |o| o.child,
                else => f.type,
            };
            @field(out, f.name) = try convert(Inner, s, label);
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
    outcomes: *[@typeInfo(T).@"struct".fields.len]converting.Outcome,
) T {
    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
        outcomes[i] = .{};
        const Inner = switch (@typeInfo(f.type)) {
            .optional => |o| o.child,
            else => f.type,
        };

        if (c.query(f.name)) |s| {
            outcomes[i].given = s;
            var converted: Inner = undefined;
            if (converting.tryConvert(Inner, s, &converted)) |reason| {
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
const convert = converting.convert;

fn sendResult(c: *Ctx, result: anytype) !void {
    const R = @TypeOf(result);
    const value = if (@typeInfo(R) == .error_union) try result else result;
    const T = @TypeOf(value);

    if (T == void) return;
    // Before `zfast_response`, and carrying no body of its own: a redirect
    // is a status and a Location, and its `headers` are how a sign-in sends
    // a `Set-Cookie` on the way out (ADR 0032).
    if (comptime hasNamedDecl(T, "zfast_redirect")) {
        for (value.headers.view()) |h| try c.setHeader(h.name, h.value);
        return c.redirect(T.zfast_redirect, value.location);
    }
    if (comptime hasNamedDecl(T, "zfast_response")) {
        // Copied rather than borrowed, the same as `Ctx.setHeader`: a
        // handler assembling a header value has the request arena to build
        // it in, and should not have to think about which of the two it is.
        for (value.headers.view()) |h| try c.setHeader(h.name, h.value);
        const status = if (comptime hasNamedDecl(T, "zfast_status"))
            T.zfast_status
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
    if (T == Str) return c.sendText(status, value.view());
    if (T == []const u8 or T == []u8) return c.sendText(status, value);
    return c.sendJson(status, value);
}

fn hasNamedDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}
