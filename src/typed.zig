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
//! | `std.mem.Allocator`   | the request arena, freed when the request ends |
//! | a type carrying `zfast_resolve` | a resolved value, worked out from the request (ADR 0016) |
//! | any other struct      | the request body, parsed from JSON         |
//!
//! The return value becomes the response: `void` → empty 200,
//! `Str`/`[]const u8` → text/plain, anything else → JSON. Wrap it in
//! `Response(T)` when the status is not 200, or when the response carries
//! headers of its own.
//!
//! Zig does not keep argument names, so path params are matched **by
//! position**, not by name. Every mismatch — the param count, a type that
//! makes no sense, two request bodies — stops compilation with a message
//! naming the route. That message quality is the only price this layer
//! charges (ADR 0003), so it is taken seriously here.

const std = @import("std");
const ctx_mod = @import("ctx.zig");
const http1 = @import("http1.zig");
const router = @import("router.zig");
const service_mod = @import("service.zig");
const fail = @import("fail.zig");
const str_mod = @import("str.zig");
const resolve = @import("resolve.zig");
const openapi = @import("openapi.zig");

const Ctx = ctx_mod.Ctx;
const Str = str_mod.Str;

/// A response with a status other than 200, headers of its own, or both.
///
/// ```zig
/// fn createUser(incoming: NewUser) !Response(User) {
///     return .{
///         .status = 201,
///         .headers = &.{.{ .name = "Location", .value = "/users/7" }},
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
    return struct {
        pub const zfast_response = T;

        status: u16 = 200,
        headers: []const Header = &.{},
        value: T,
    };
}

/// One header on a `Response`.
pub const Header = http1.Header;

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
    /// The request arena, for a handler that has to build something that
    /// outlives its own stack frame — a `Location` header, usually.
    arena,
    /// A value zfast works out from the request before the handler runs —
    /// the signed-in user, usually (ADR 0016).
    resolved,
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
                    .arena => args[i] = c._arena,
                    .resolved => args[i] = try resolve.value(P, c),
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
        // Whether zfast can refuse this request before the handler runs.
        // Not a guess — it is exactly the routes with something to convert.
        var can_reject = false;

        for (params, 0..) |p, i| switch (roles[i]) {
            .param => can_reject = can_reject or p.type.? != Str,
            .query => {
                query = queryFields(p.type.?.zfast_query);
                can_reject = true;
            },
            .body => {
                body = openapi.schemaOf(p.type.?);
                can_reject = true;
            },
            else => {},
        };

        return .{
            .method = .other, // filled in by the caller, which knows the verb
            .pattern = pattern,
            .params = path_params,
            .query = query,
            .body = body,
            .answer = answerOf(Fn),
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

        if (hasNamedDecl(V, "zfast_response")) {
            const Inner = V.zfast_response;
            // The status of a `Response(T)` is a field the handler fills in,
            // so it is not knowable here. Saying "default" is the truth;
            // claiming 200 for a route that answers 201 would not be.
            if (Inner == void) return .{ .status = null, .content_type = "", .schema = null };
            return .{
                .status = null,
                .content_type = contentTypeFor(Inner),
                .schema = openapi.schemaOf(Inner),
            };
        }

        return .{ .status = 200, .content_type = contentTypeFor(V), .schema = openapi.schemaOf(V) };
    }
}

fn contentTypeFor(comptime T: type) []const u8 {
    if (T == Str or T == []const u8 or T == []u8) return "text/plain";
    return "application/json";
}

// ---- the compile-time side ----

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
            @typeName(F) ++ ".\n" ++
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
        var body_seen = false;
        var query_seen = false;
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
                .body => {
                    if (body_seen) @compileError(
                        "zfast: the handler for route \"" ++ pattern ++ "\" asks for two request " ++
                            "bodies (argument " ++ num(i + 1) ++ " is a " ++ @typeName(P) ++ ").\n" ++
                            "  A request only has one body. If " ++ @typeName(P) ++
                            " is a service, ask for it as a pointer: `*" ++ @typeName(P) ++ "`.",
                    );
                    body_seen = true;
                },
                .query => {
                    if (query_seen) @compileError(
                        "zfast: the handler for route \"" ++ pattern ++ "\" asks for the query " ++
                            "string twice (argument " ++ num(i + 1) ++ ").\n" ++
                            "  A request has one query string. Put every field in a single struct " ++
                            "and ask for that.",
                    );
                    query_seen = true;
                    checkQueryFields(pattern, P.zfast_query, i);
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

fn roleOf(comptime pattern: []const u8, comptime P: type, comptime i: usize) Role {
    if (P == *Ctx or P == *const Ctx) return .ctx;
    if (P == Str) return .{ .param = 0 };
    if (P == std.mem.Allocator) return .arena;
    if (comptime hasNamedDecl(P, "zfast_query")) return .query;
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
                    "\" is a " ++ @typeName(P) ++ ".\n" ++
                    "  Text from a request is asked for as a `zfast.Str`, not a bare slice: Str is " ++
                    "what stops the contents from outliving the request (ADR 0004).\n" ++
                    "  Inside the handler, `.view()` reads it and `.keep()` holds on to it.",
            ),
            else => @compileError(
                "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                    "\" is a " ++ @typeName(P) ++ ", which cannot be matched.\n" ++
                    "  A service is asked for as a pointer to a single value (`*Db`).",
            ),
        },

        .@"struct" => .body,

        .optional => @compileError(
            "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                "\" is a " ++ @typeName(P) ++ ".\n" ++
                "  A path param on a route that matched is always present, so an optional means " ++
                "nothing here.\n" ++
                "  A query param is the thing that may be absent, and there an optional is " ++
                "exactly right: put the field in a struct and ask for `zfast.Query(That)`.",
        ),

        else => @compileError(
            "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                "\" is a " ++ @typeName(P) ++ ", which zfast does not recognise.\n" ++
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
                    "\" is a `Query(" ++ @typeName(T) ++ ")`, but " ++ @typeName(T) ++
                    " is not a struct.\n" ++
                    "  The query string is read into a struct: one field per query param.",
            ),
        };

        if (info.fields.len == 0) @compileError(
            "zfast: the `Query(" ++ @typeName(T) ++ ")` on route \"" ++ pattern ++
                "\" has no fields, so it would read nothing.\n" ++
                "  Add one field per query param you want: `page: u32 = 1`.",
        );

        for (info.fields) |f| {
            const Inner = switch (@typeInfo(f.type)) {
                .optional => |o| o.child,
                else => f.type,
            };
            if (Inner == Str) continue;
            switch (@typeInfo(Inner)) {
                .int, .float, .bool, .@"enum" => {},
                else => @compileError(
                    "zfast: the field `" ++ f.name ++ ": " ++ @typeName(f.type) ++ "` of the " ++
                        "`Query(" ++ @typeName(T) ++ ")` on route \"" ++ pattern ++
                        "\" is not something a query value can become.\n" ++
                        "  A query param arrives as text, so a field is a `zfast.Str`, a number, " ++
                        "a `bool`, or an enum — optionally wrapped in `?` when it may be absent.",
                ),
            }
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
        "\" is a " ++ @typeName(P) ++ ", so zfast reads it as a path param — but " ++ has ++ ".\n" ++
        "  Add `:name` to the route pattern, or — if " ++ @typeName(P) ++
        " is a service — ask for it as a pointer: `*" ++ @typeName(P) ++ "`.";
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

/// Turn one piece of request text into the type the handler asked for.
/// `label` is how it is named back to the client — `:id` for a path param,
/// `?page` for a query one — so the same message serves both.
fn convert(comptime P: type, s: Str, comptime label: []const u8) !P {
    if (P == Str) return s;

    const text = s.view();
    return switch (@typeInfo(P)) {
        .int => std.fmt.parseInt(P, text, 10) catch
            return fail.badRequest(label ++ " has to be a whole number, not \"{s}\"", .{text}),
        .float => std.fmt.parseFloat(P, text) catch
            return fail.badRequest(label ++ " has to be a number, not \"{s}\"", .{text}),
        .bool => boolFrom(text) orelse
            return fail.badRequest(label ++ " has to be true or false, not \"{s}\"", .{text}),
        .@"enum" => std.meta.stringToEnum(P, text) orelse
            return fail.badRequest(
                label ++ " is not one of the known choices ({s}): \"{s}\"",
                .{ comptime enumChoices(P), text },
            ),
        else => comptime unreachable,
    };
}

/// The names of an enum's values, for the message that says what was
/// expected. Built once at compile time.
fn enumChoices(comptime E: type) []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (@typeInfo(E).@"enum".fields) |f| names = names ++ [_][]const u8{f.name};
        return join(names, ", ");
    }
}

fn boolFrom(text: []const u8) ?bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return null;
}

fn sendResult(c: *Ctx, result: anytype) !void {
    const R = @TypeOf(result);
    const value = if (@typeInfo(R) == .error_union) try result else result;
    const T = @TypeOf(value);

    if (T == void) return;
    if (comptime hasNamedDecl(T, "zfast_response")) {
        // Copied rather than borrowed, the same as `Ctx.setHeader`: a
        // handler assembling a header value has the request arena to build
        // it in, and should not have to think about which of the two it is.
        for (value.headers) |h| try c.setHeader(h.name, h.value);
        return sendValue(c, value.status, value.value);
    }
    return sendValue(c, 200, value);
}

fn sendValue(c: *Ctx, status: u16, value: anytype) !void {
    const T = @TypeOf(value);
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
