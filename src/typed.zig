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
//! | `u32`, `Str`, `bool`, an enum | a path param, in the order `:name` appears in the pattern |
//! | a struct              | the request body, parsed from JSON         |
//!
//! The return value becomes the response: `void` → empty 200,
//! `Str`/`[]const u8` → text/plain, anything else → JSON. Wrap it in
//! `Response(T)` when the status is not 200.
//!
//! Zig does not keep argument names, so path params are matched **by
//! position**, not by name. Every mismatch — the param count, a type that
//! makes no sense, two request bodies — stops compilation with a message
//! naming the route. That message quality is the only price this layer
//! charges (ADR 0003), so it is taken seriously here.

const std = @import("std");
const ctx_mod = @import("ctx.zig");
const router = @import("router.zig");
const service_mod = @import("service.zig");
const fail = @import("fail.zig");
const str_mod = @import("str.zig");

const Ctx = ctx_mod.Ctx;
const Str = str_mod.Str;

/// A response with a status other than 200.
///
/// ```zig
/// fn createUser(incoming: NewUser) !Response(User) {
///     return .{ .status = 201, .value = ... };
/// }
/// ```
pub fn Response(comptime T: type) type {
    return struct {
        pub const zfast_response = T;

        status: u16 = 200,
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
            if (roles[i] != .service) continue;
            list = list ++ [_]service_mod.Requirement{service_mod.requirementFor(p.type.?, pattern)};
        }
        return list;
    }
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
                "nothing here. For things that may be absent — query params, headers — ask for a " ++
                "`*Ctx` and use `c.query(\"…\")`.",
        ),

        else => @compileError(
            "zfast: argument " ++ num(i + 1) ++ " of the handler for route \"" ++ pattern ++
                "\" is a " ++ @typeName(P) ++ ", which zfast does not recognise.\n" ++
                "  What you can ask for: `*Ctx`, a pointer to a service (`*Db`), a path param " ++
                "(`u32`, `zfast.Str`, `bool`, an enum), or one struct for the request body.",
        ),
    };
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

/// The name of every `:param` in the pattern, in order of appearance.
fn patternParamNames(comptime pattern: []const u8) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        var segs = std.mem.splitScalar(u8, pattern, '/');
        while (segs.next()) |s| {
            if (s.len > 1 and s[0] == ':') names = names ++ [_][]const u8{s[1..]};
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
    if (P == Str) return s;

    const text = s.view();
    return switch (@typeInfo(P)) {
        .int => std.fmt.parseInt(P, text, 10) catch
            return fail.badRequest(":{s} has to be a whole number, not \"{s}\"", .{ name, text }),
        .float => std.fmt.parseFloat(P, text) catch
            return fail.badRequest(":{s} has to be a number, not \"{s}\"", .{ name, text }),
        .bool => if (std.mem.eql(u8, text, "true")) true else if (std.mem.eql(u8, text, "false")) false else
            return fail.badRequest(":{s} has to be true or false, not \"{s}\"", .{ name, text }),
        .@"enum" => std.meta.stringToEnum(P, text) orelse
            return fail.badRequest(":{s} is not one of the known choices: \"{s}\"", .{ name, text }),
        else => comptime unreachable,
    };
}

fn sendResult(c: *Ctx, result: anytype) !void {
    const R = @TypeOf(result);
    const value = if (@typeInfo(R) == .error_union) try result else result;
    const T = @TypeOf(value);

    if (T == void) return;
    if (comptime hasNamedDecl(T, "zfast_response")) return sendValue(c, value.status, value.value);
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
