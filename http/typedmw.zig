//! A middleware that is given what it needs — the typed layer for the onion
//! (ADR 008).
//!
//! ```zig
//! fn requireKey(c: *Ctx, next: Next, keys: *KeyStore, user: CurrentUser) !void {
//!     if (!keys.allows(user.id)) return fail.forbidden("no key for {d}", .{user.id});
//!     try next.run(c);
//! }
//!
//! try app.use(requireKey);
//! ```
//!
//! The first two arguments are always `*Ctx` and `Next`. What follows is read
//! by the rule a handler follows, narrowed to what a middleware can mean: a
//! middleware covers many routes, so it can be given what belongs to the
//! request or to the program, and nothing that belongs to one route.
//!
//! | Argument after `Next`  | What it means                                           |
//! |------------------------|---------------------------------------------------------|
//! | `*Db`, `*const Cfg`    | a service, matched by its type                          |
//! | a type carrying `nilo_resolve` | a resolved value, worked out once per request and shared with the handler (ADR 015) |
//! | `Path(T)`              | the path params by name; held against every route the middleware covers at `listen()` |
//! | `std.mem.Allocator`    | the request arena                                       |
//! | `std.Io`               | the server's loop                                       |
//!
//! Not a query, a header, a form, a body or a bare path param: each is one
//! route's, and a middleware that asked for it would read a different thing
//! on every route or none. It is refused while compiling with a sentence that
//! says so. A middleware that wants one of those takes the `*Ctx` it already
//! has, or moves the read into a resolved value.
//!
//! **Wrapped while compiling into an ordinary `Middleware`**, so the onion,
//! `Next` and the chain are the ones a bare function runs in, and a request
//! pays what the same arguments cost a handler: a service is a lookup in the
//! registry (`service.required`, the one a handler uses), a resolved value is
//! `resolve.value` and is worked out once however many ask, and nothing
//! allocates. A bare `fn (*Ctx, Next)` never comes through here.
//!
//! **A missing service is a refusal at `listen()`**, joined with the ones
//! handlers and resolvers declare, so an auth middleware that cannot find its
//! key store stops the server instead of letting every request through. A
//! `Path(T)` is held at `listen()` against each route the middleware covers
//! (`App.checkMiddlewarePaths`), so a route without the param is named before
//! the first request. A request that matched neither a route nor a static
//! file has no params, so a middleware that reads some stands aside on it and
//! hands on to `next`: the 404 or 405 is the one it would have got without
//! the middleware. A static mount a path-reading middleware covers is refused
//! at `listen()` instead, because standing aside there would serve the file
//! unguarded.
//! Zig keeps no function names while compiling, so a
//! message names a middleware by what it takes: "the middleware taking
//! (*KeyStore, CurrentUser)".

const std = @import("std");
const naming = @import("names.zig");
const ctx_mod = @import("ctx.zig");
const mw = @import("middleware.zig");
const resolve = @import("resolve.zig");
const service_mod = @import("service.zig");
const pathparams = @import("pathparams.zig");

const Ctx = ctx_mod.Ctx;

/// Whether `f` is a middleware that takes more (or other) than `*Ctx` and
/// `Next`. A bare `Middleware` value, a `Limited`, and a function of exactly
/// that shape are not: they are registered as they always were.
pub fn isTyped(comptime f: anytype) bool {
    return isTypedType(@TypeOf(f));
}

/// `isTyped`, from the type alone: a registration that was handed a runtime
/// `Middleware` has no function to wrap, and is asked this instead.
pub fn isTypedType(comptime T: type) bool {
    comptime {
        if (T == mw.Middleware or T == mw.Limited) return false;
        const Fn = fnTypeOf(T) orelse return false;
        const params = @typeInfo(Fn).@"fn".param_types;
        if (params.len != 2) return true;
        return params[0] != *Ctx or params[1] != mw.Next;
    }
}

/// A typed middleware held as a pointer in a variable cannot be wrapped: the
/// wrapper is generated from the function, which has to be known while
/// compiling. Called where a registration meets a pointer type.
pub fn refuseRuntimePointer(comptime T: type) void {
    comptime {
        if (!isTypedType(T) or @typeInfo(T) != .pointer) return;
        @compileError(
            "nilo: a typed middleware has to be a function known while compiling, and this one is held in a variable.\n" ++
                "  It is a " ++ naming.of(T) ++ ". nilo wraps the function into the bare form, which needs the function itself: " ++
                "pass its name, `app.use(requireKey)`, not a pointer to it. A middleware that is " ++
                "only `fn (*Ctx, Next)` may be held in a variable.",
        );
    }
}

/// What a typed middleware declares for `listen()` to hold: the services it
/// needs, and the path params it reads.
pub const Needs = struct {
    /// Services and the services behind its resolved values, each with the
    /// middleware as the thing that needs it.
    requirements: []const service_mod.Requirement,
    /// The wrapped function, to find it in a route's chain.
    run: mw.Middleware,
    /// "the middleware taking (…)", for a message.
    who: []const u8,
    /// The path param names it reads, directly and through resolvers.
    paths: []const []const u8,
};

/// `Needs` of a typed middleware as a slice of one, and of anything else as a
/// slice of none, so a comptime `with` can keep it beside the chain.
pub fn needsOf(comptime f: anytype) []const Needs {
    comptime {
        if (!isTypedType(@TypeOf(f))) return &.{};
        const Fn = checked(f);
        const params = @typeInfo(Fn).@"fn".param_types;
        const roles = rolesOf(Fn, params);
        const who = whoOf(Fn);
        var reqs: []const service_mod.Requirement = &.{};
        var paths: []const []const u8 = &.{};
        for (params[2..], roles[2..]) |p, role| {
            switch (role) {
                .service => reqs = reqs ++ [_]service_mod.Requirement{service_mod.requirementFor(p.?, who)},
                .resolved => {
                    reqs = reqs ++ resolve.requirements(p.?, who);
                    paths = paths ++ resolve.pathNames(p.?);
                },
                .path => paths = paths ++ @typeInfo(p.?.nilo_path).@"struct".field_names,
                else => {},
            }
        }
        return &[_]Needs{.{ .requirements = reqs, .run = wrap(f), .who = who, .paths = paths }};
    }
}

/// `f` as an ordinary `Middleware`. The same function gives the same pointer,
/// so `without(f)` finds what `use(f)` put in the chain.
pub fn wrap(comptime f: anytype) mw.Middleware {
    const Fn = comptime checked(f);
    const params = @typeInfo(Fn).@"fn".param_types;
    const roles = comptime rolesOf(Fn, params);
    const who = comptime whoOf(Fn);
    const reads_paths = comptime readsPaths(params, roles);

    const Wrapper = struct {
        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            // A request that matched no route (a 404 or a 405) has no params
            // to read. Reading them would turn a scanner's request into a
            // 500, so a middleware that needs path params stands aside and
            // the request gets the answer it would have got without it.
            // A static file is not that request: it matched no route either,
            // and `listen()` has refused a mount a path-reading middleware
            // covers, so one that gets here anyway is not passed through.
            if (comptime reads_paths) {
                if (c._route == null and c._static_file == null) return next.run(c);
            }
            var args: std.meta.ArgsTuple(Fn) = undefined;
            args[0] = c;
            args[1] = next;
            inline for (params[2..], 2..) |p, i| {
                const P = p.?;
                switch (comptime roles[i]) {
                    .service => args[i] = try service_mod.required(P, who, c._services),
                    .arena => args[i] = c._arena,
                    .io => args[i] = c.io(),
                    .resolved => args[i] = try resolve.value(P, c),
                    // By name, at run time, as a resolver's is: the route is
                    // only known per request. `listen()` has already held the
                    // names against every route this covers, so this is the
                    // last line for a request that matched no route.
                    .path => args[i] = .{ .value = try pathparams.readByName(P.nilo_path, who, c) },
                    .ctx => unreachable,
                }
            }
            return @call(.auto, f, args);
        }
    };
    return Wrapper.run;
}

fn readsPaths(comptime params: []const ?type, comptime roles: []const Role) bool {
    comptime {
        for (params[2..], roles[2..]) |p, role| {
            switch (role) {
                .path => return true,
                .resolved => if (resolve.pathNames(p.?).len > 0) return true,
                else => {},
            }
        }
        return false;
    }
}

const Role = enum { ctx, service, arena, io, resolved, path };

fn fnTypeOf(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .@"fn" => T,
        .pointer => |p| if (@typeInfo(p.child) == .@"fn") p.child else null,
        else => null,
    };
}

/// "fn (*Ctx, Next, …)", for a refusal about the shape of the whole.
fn signature(comptime Fn: type) []const u8 {
    comptime {
        var out: []const u8 = "fn (";
        for (@typeInfo(Fn).@"fn".param_types, 0..) |p, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ (if (p) |t| naming.of(t) else "anytype");
        }
        return out ++ ")";
    }
}

fn whoOf(comptime Fn: type) []const u8 {
    comptime {
        var out: []const u8 = "the middleware taking (";
        for (@typeInfo(Fn).@"fn".param_types[2..], 0..) |p, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ naming.of(p.?);
        }
        return out ++ ")";
    }
}

/// The function type of `f`, after the checks on its shape: `*Ctx` and `Next`
/// first, and nothing but void or an error union of void to hand back.
fn checked(comptime f: anytype) type {
    comptime {
        const Fn = fnTypeOf(@TypeOf(f)) orelse @compileError(
            "nilo: a middleware has to be a function, not " ++ naming.of(@TypeOf(f)) ++ ".\n" ++
                "  Write `app.use(requireKey)`: the function's name, not a call to it.",
        );
        const info = @typeInfo(Fn).@"fn";
        if (info.is_generic or info.attrs.varargs) @compileError(
            "nilo: the middleware " ++ signature(Fn) ++ " is still generic (an `anytype` or " ++
                "`comptime` argument) or takes C varargs.\n" ++
                "  nilo has to know the type of every argument to match it. Write the types out.",
        );
        if (info.param_types.len < 2 or info.param_types[0].? != *Ctx and info.param_types[0].? != *const Ctx) @compileError(
            "nilo: the first argument of the middleware " ++ signature(Fn) ++ " has to be a `*Ctx`.\n" ++
                "  A middleware is `fn (c: *Ctx, next: Next) !void`, and may take services and " ++
                "resolved values after those two.",
        );
        if (info.param_types[1].? != mw.Next) @compileError(
            "nilo: the second argument of the middleware " ++ signature(Fn) ++ " has to be a `Next`.\n" ++
                "  A middleware is `fn (c: *Ctx, next: Next) !void`, and may take services and " ++
                "resolved values after those two; `next.run(c)` is how it lets the request through.",
        );
        const Returned = info.return_type.?;
        const Produced = switch (@typeInfo(Returned)) {
            .error_union => |u| u.payload,
            else => Returned,
        };
        if (Produced != void) @compileError(
            "nilo: the middleware " ++ signature(Fn) ++ " returns a " ++ naming.of(Produced) ++ ".\n" ++
                "  A middleware returns `!void` (or `void`): it answers through the Ctx or " ++
                "calls `next.run(c)`, and produces no value. A value for the handler is a " ++
                "resolved value (ADR 015).",
        );
        return Fn;
    }
}

fn rolesOf(comptime Fn: type, comptime params: []const ?type) []const Role {
    comptime {
        var roles: [params.len]Role = undefined;
        roles[0] = .ctx;
        roles[1] = .ctx;
        for (params[2..], 2..) |p, i| {
            roles[i] = roleOf(Fn, p.?, i);
        }
        const frozen = roles;
        return &frozen;
    }
}

fn roleOf(comptime Fn: type, comptime P: type, comptime i: usize) Role {
    comptime {
        if (P == std.mem.Allocator) return .arena;
        if (P == std.Io) return .io;
        if (resolve.isResolved(P)) {
            resolve.check(P);
            return .resolved;
        }
        if (pathparams.isPath(P)) {
            pathparams.checkShape(P.nilo_path, "the `" ++ naming.of(P) ++ "` of " ++ whoOf(Fn));
            return .path;
        }
        if (@typeInfo(P) == .pointer and @typeInfo(P).pointer.size == .one and
            P != *Ctx and P != *const Ctx) return .service;

        @compileError(
            "nilo: argument " ++ num(i + 1) ++ " of " ++ whoOf(Fn) ++ " is a " ++ naming.of(P) ++
                ", which a middleware cannot be given.\n" ++
                "  A middleware covers many routes, so it cannot ask for one route's query " ++
                "string, header, form, body or positional path param: each would be a different " ++
                "thing on every route, or nothing on most.\n" ++
                "  What it can ask for: a service (`*KeyStore`), a resolved value (a type carrying " ++
                "`nilo_resolve`), a `std.mem.Allocator` for the request arena, a `std.Io`, or the " ++
                "path params by name: `nilo.Path(struct { org: u32 })`.\n" ++
                "  For the query, a header or the body, use the `*Ctx` it already has " ++
                "(`c.query(\"page\")`, `c.json(T)`), or move the read into a resolved value.",
        );
    }
}

fn num(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}
