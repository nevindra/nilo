//! Resolved values — things zfast works out from the request before the
//! handler runs, chief among them the signed-in user (ADR 0016).
//!
//! A type says how it is worked out, by carrying the function that does it:
//!
//! ```zig
//! const CurrentUser = struct {
//!     pub const zfast_resolve = authenticate;
//!
//!     id: u32,
//!     name: Str,
//! };
//!
//! fn authenticate(c: *Ctx, db: *Db) !CurrentUser {
//!     const token = c.header("Authorization") orelse
//!         return fail.unauthorized("this endpoint needs a token", .{});
//!     return db.userForToken(token.view()) orelse
//!         return fail.unauthorized("that token is not valid", .{});
//! }
//!
//! fn me(user: CurrentUser) !Profile { ... }   // and that is the whole wiring
//! ```
//!
//! This is ADR 0009's one admitted gap: middleware can reject a request but
//! cannot hand the handler the user it just looked up. The shape refused
//! there was a `c.locals` map — untyped state smuggled in through the side
//! door — and this is the shape taken instead. The value is *declared*, not
//! stashed: which types a handler wants is in its argument list, whether
//! they can be produced is settled while compiling, and nothing is looked up
//! by string at runtime.
//!
//! What a resolver may ask for is deliberately narrower than what a handler
//! may: a `*Ctx`, a service, the request arena, and other resolved values.
//! Not a path param, a query struct, or the body — a resolver belongs to the
//! request, not to a route, and a route is the only thing that knows what
//! `:id` means. A resolver that wants any of those takes a `*Ctx` and helps
//! itself.
//!
//! Worked out **once per request** and shared by everyone who asks, so a
//! middleware guarding a prefix and a handler taking the value do not
//! authenticate twice. A request that asks for none of this allocates
//! nothing and runs the code it ran before (ADR 0018).

const std = @import("std");
const names = @import("names.zig");
const ctx_mod = @import("ctx.zig");
const service_mod = @import("service.zig");
const fail = @import("fail.zig");
const str_mod = @import("str.zig");
const http1 = @import("http1.zig");
const bulkhead = @import("bulkhead.zig");

const Ctx = ctx_mod.Ctx;

/// The declaration a type carries to say how it is worked out. Named the
/// way `zfast_query` and `zfast_response` are, so the three markers the
/// compile-time engine looks for all read alike.
pub const marker = "zfast_resolve";

/// Whether `T` is a resolved value. Asked by the typed engine while working
/// out what a handler argument means, and by this module about a resolver's
/// own arguments.
pub fn isResolved(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, marker),
        else => false,
    };
}

/// The resolved value of type `V` for this request: the one already worked
/// out if something asked earlier, otherwise worked out now and remembered.
///
/// The entry point for both callers — the typed engine filling in a handler
/// argument, and `Ctx.resolve` for a middleware that wants the value in
/// order to guard on it.
pub fn value(comptime V: type, c: *Ctx) !V {
    const nothing: []const type = &.{};
    return valueWithin(V, nothing, c);
}

/// Settle everything about `V` while compiling, so that a route asking for
/// it either builds or says why. Called by the typed engine as it works out
/// what a handler argument means, which is the earliest point at which
/// anybody has named the type.
pub fn check(comptime V: type) void {
    comptime {
        const nothing: []const type = &.{};
        checkResolvable(V, nothing);
    }
}

/// `value`, carrying the chain of resolvers already being worked out so a
/// loop is a compile error rather than a compiler that never returns.
fn valueWithin(comptime V: type, comptime being_resolved: []const type, c: *Ctx) !V {
    comptime checkResolvable(V, being_resolved);

    if (c.cachedResolved(V)) |already| return already;

    const f = @field(V, marker);
    const Fn = comptime fnTypeOf(V, @TypeOf(f));
    const params = @typeInfo(Fn).@"fn".params;
    const roles = comptime rolesOf(V, params);
    const deeper = being_resolved ++ [_]type{V};

    var args: std.meta.ArgsTuple(Fn) = undefined;
    inline for (params, 0..) |p, i| {
        const P = p.type.?;
        switch (comptime roles[i]) {
            .ctx => args[i] = c,
            .service => args[i] = c._services.get(P) orelse return fail.internal(
                "service {s} was never registered; call app.provide() before app.listen()",
                .{@typeName(P)},
            ),
            .arena => args[i] = c._arena,
            .resolved => args[i] = try valueWithin(P, deeper, c),
        }
    }

    const produced = @call(.auto, f, args);
    const resolved: V = if (@typeInfo(@TypeOf(produced)) == .error_union) try produced else produced;

    // Remembered only once it exists: a resolver that failed has stopped the
    // request anyway, so there is nobody left to ask a second time.
    try c.cacheResolved(V, resolved);
    return resolved;
}

/// Every service the chain behind `V` needs, so a service used only by a
/// resolver is still caught by `listen()` rather than by the first request
/// that touches that route (ADR 0006).
pub fn requirements(comptime V: type, comptime route: []const u8) []const service_mod.Requirement {
    comptime {
        const nothing: []const type = &.{};
        return requirementsWithin(V, nothing, route);
    }
}

fn requirementsWithin(
    comptime V: type,
    comptime being_resolved: []const type,
    comptime route: []const u8,
) []const service_mod.Requirement {
    comptime {
        checkResolvable(V, being_resolved);

        const Fn = fnTypeOf(V, @TypeOf(@field(V, marker)));
        const params = @typeInfo(Fn).@"fn".params;
        const roles = rolesOf(V, params);
        const deeper = being_resolved ++ [_]type{V};

        var list: []const service_mod.Requirement = &.{};
        for (params, 0..) |p, i| {
            switch (roles[i]) {
                .service => list = list ++
                    [_]service_mod.Requirement{service_mod.requirementFor(p.type.?, route)},
                .resolved => list = list ++ requirementsWithin(p.type.?, deeper, route),
                else => {},
            }
        }
        return list;
    }
}

// ---- the compile-time side ----

const Role = enum { ctx, service, arena, resolved };

/// Everything that has to be true of `V` before it can be worked out, said
/// while compiling. The check runs before anything else in both entry
/// points, so a mistake here is never a runtime surprise (ADR 0015: the
/// failure mode to avoid is a wall of errors from four frames down).
fn checkResolvable(comptime V: type, comptime being_resolved: []const type) void {
    comptime {
        for (being_resolved) |earlier| {
            if (earlier != V) continue;
            // Two types each declaring the other as an argument. Left alone
            // this is a compiler that expands for ever rather than a message.
            @compileError(
                "zfast: the resolved value `" ++ names.of(V) ++ "` is worked out from itself — " ++
                    loop(being_resolved, V) ++ "\n" ++
                    "  Break the loop: one of these resolvers should take a `*Ctx` and read what " ++
                    "it needs directly, rather than asking for the other value.",
            );
        }

        const Fn = fnTypeOf(V, @TypeOf(@field(V, marker)));
        const info = @typeInfo(Fn).@"fn";

        const Returned = info.return_type orelse @compileError(
            "zfast: the resolver on `" ++ names.of(V) ++ "` has no return type.",
        );
        const Produced = switch (@typeInfo(Returned)) {
            .error_union => |u| u.payload,
            else => Returned,
        };
        if (Produced != V) @compileError(
            "zfast: the resolver on `" ++ names.of(V) ++ "` returns " ++ names.of(Produced) ++
                ", not " ++ names.of(V) ++ ".\n" ++
                "  A type's `" ++ marker ++ "` is how that type is worked out from a request, so " ++
                "it has to hand back that type.",
        );

        _ = rolesOf(V, info.params);
    }
}

fn rolesOf(comptime V: type, comptime params: []const std.builtin.Type.Fn.Param) []const Role {
    comptime {
        var roles: [params.len]Role = undefined;
        for (params, 0..) |p, i| {
            const P = p.type orelse @compileError(
                "zfast: argument " ++ num(i + 1) ++ " of the resolver on `" ++ names.of(V) ++
                    "` has no type.",
            );
            roles[i] = roleOf(V, P, i);
        }
        const frozen = roles;
        return &frozen;
    }
}

fn roleOf(comptime V: type, comptime P: type, comptime i: usize) Role {
    if (P == *Ctx or P == *const Ctx) return .ctx;
    if (P == std.mem.Allocator) return .arena;
    if (isResolved(P)) return .resolved;
    if (@typeInfo(P) == .pointer and @typeInfo(P).pointer.size == .one) return .service;

    @compileError(
        "zfast: argument " ++ num(i + 1) ++ " of the resolver on `" ++ names.of(V) ++ "` is a " ++
            names.of(P) ++ ", which a resolver cannot be given.\n" ++
            "  A resolver belongs to the request, not to a route, so there is no `:id` for it to " ++
            "be handed and no query struct to fill in.\n" ++
            "  What it can ask for: a `*Ctx`, a service (`*Db`), a `std.mem.Allocator` for the " ++
            "request arena, or another resolved value.\n" ++
            "  For anything else — a path param, the query string, the body — take a `*Ctx` and " ++
            "read it: `c.param(\"id\")`, `c.query(\"page\")`, `c.json(T)`.",
    );
}

fn fnTypeOf(comptime V: type, comptime F: type) type {
    return switch (@typeInfo(F)) {
        .@"fn" => F,
        .pointer => |p| if (@typeInfo(p.child) == .@"fn") p.child else notAFunction(V, F),
        else => notAFunction(V, F),
    };
}

fn notAFunction(comptime V: type, comptime F: type) noreturn {
    @compileError(
        "zfast: `" ++ names.of(V) ++ "." ++ marker ++ "` is a " ++ names.of(F) ++
            ", not a function.\n" ++
            "  It is the function that works the value out from a request:\n" ++
            "      pub const " ++ marker ++ " = authenticate;   // fn (c: *Ctx) !" ++
            names.of(V) ++ "\n" ++
            "  The function's name, not a call to it.",
    );
}

/// `A → B → A` — the loop, for the message that refuses it.
fn loop(comptime being_resolved: []const type, comptime V: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        var started = false;
        for (being_resolved) |T| {
            if (!started and T != V) continue;
            started = true;
            out = out ++ names.of(T) ++ " → ";
        }
        return out ++ names.of(V);
    }
}

fn num(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

// ---- tests ----
//
// The compile-error paths are not tested here, because a `@compileError` a
// test triggers is a build that fails rather than a test that passes. They
// are exercised by hand and their wording is the thing under review.

const testing = std.testing;

const Db = struct {
    ok_token: []const u8 = "secret",

    fn userFor(self: *const Db, token: []const u8) ?u32 {
        return if (std.mem.eql(u8, token, self.ok_token)) 7 else null;
    }
};

/// How many times each resolver actually ran, so memoisation can be
/// observed rather than assumed.
var authenticate_runs: usize = 0;
var admin_runs: usize = 0;

const CurrentUser = struct {
    pub const zfast_resolve = authenticate;

    id: u32,
};

fn authenticate(c: *Ctx, db: *Db) !CurrentUser {
    authenticate_runs += 1;
    const token = c.header("Authorization") orelse
        return fail.unauthorized("this endpoint needs a token", .{});
    const id = db.userFor(token.view()) orelse
        return fail.unauthorized("that token is not valid", .{});
    return .{ .id = id };
}

/// Composition: worked out from another resolved value rather than from the
/// request directly.
const Admin = struct {
    pub const zfast_resolve = requireAdmin;

    user: CurrentUser,
};

fn requireAdmin(user: CurrentUser) !Admin {
    admin_runs += 1;
    if (user.id != 7) return fail.forbidden("admins only", .{});
    return .{ .user = user };
}

/// A Ctx over an in-memory request head, which is all a resolver can see.
/// Held in the caller's frame because Ctx borrows from every field of it.
const Standin = struct {
    arena: std.heap.ArenaAllocator,
    lifetime: str_mod.Lifetime = .{},
    request: http1.Request = .{},
    services: service_mod.Registry,
    in: std.Io.Reader = .fixed(""),
    out: std.Io.Writer = .fixed(&.{}),
    in_flight: fail.InFlight = .{},
    restore_slot: ?*anyopaque = null,

    fn init() Standin {
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .services = service_mod.Registry.init(testing.allocator),
        };
    }

    /// Fail functions write into the box bound to the fiber (ADR 0007), and
    /// there is no fiber here — so the fallback slot stands in for one, the
    /// same way `App.handleRequest` sets it up for a test.
    fn start(self: *Standin) void {
        self.in_flight.startRequest("GET", "/me");
        self.restore_slot = bulkhead.setFallbackSlot(&self.in_flight);
    }

    fn ctx(self: *Standin, head: []const u8) Ctx {
        return .{
            .method = .GET,
            ._arena = self.arena.allocator(),
            ._lifetime = &self.lifetime,
            ._in = &self.in,
            ._out = &self.out,
            ._request = &self.request,
            ._path = "/me",
            ._query = "",
            ._head = head,
            ._params = &.{},
            ._services = &self.services,
        };
    }

    fn deinit(self: *Standin) void {
        _ = bulkhead.setFallbackSlot(self.restore_slot);
        self.services.deinit();
        self.arena.deinit();
    }
};

const with_token = "GET /me HTTP/1.1\r\nAuthorization: secret\r\n\r\n";
const without_token = "GET /me HTTP/1.1\r\nHost: x\r\n\r\n";

test "a resolved value is worked out from the request" {
    authenticate_runs = 0;
    var db = Db{};

    var stand = Standin.init();
    defer stand.deinit();
    stand.start();
    try stand.services.add(&db);

    var c = stand.ctx(with_token);
    const user = try value(CurrentUser, &c);

    try testing.expectEqual(@as(u32, 7), user.id);
    try testing.expectEqual(@as(usize, 1), authenticate_runs);
}

test "a resolver that fails stops the request the way a handler does" {
    var db = Db{};

    var stand = Standin.init();
    defer stand.deinit();
    stand.start();
    try stand.services.add(&db);

    var c = stand.ctx(without_token);
    try testing.expectError(error.Failed, value(CurrentUser, &c));

    // And it is a fail function's message, so the client is told what to do
    // rather than handed a 500.
    try testing.expectEqual(@as(u16, 401), stand.in_flight.failure.status);
    try testing.expectEqualStrings(
        "this endpoint needs a token",
        stand.in_flight.failure.message(),
    );
}

test "asking twice in one request works it out once" {
    // The case this exists for: a middleware guarding `/admin` resolves the
    // user to check it, and the handler behind it asks for the same user.
    // Authenticating twice would mean two database lookups per request.
    authenticate_runs = 0;
    var db = Db{};

    var stand = Standin.init();
    defer stand.deinit();
    stand.start();
    try stand.services.add(&db);

    var c = stand.ctx(with_token);
    const first = try value(CurrentUser, &c);
    const second = try value(CurrentUser, &c);

    try testing.expectEqual(first.id, second.id);
    try testing.expectEqual(@as(usize, 1), authenticate_runs);
}

test "a resolver can be built out of another resolved value" {
    authenticate_runs = 0;
    admin_runs = 0;
    var db = Db{};

    var stand = Standin.init();
    defer stand.deinit();
    stand.start();
    try stand.services.add(&db);

    var c = stand.ctx(with_token);
    const admin = try value(Admin, &c);

    try testing.expectEqual(@as(u32, 7), admin.user.id);
    try testing.expectEqual(@as(usize, 1), authenticate_runs);
    try testing.expectEqual(@as(usize, 1), admin_runs);

    // And the value the chain went through is the one already worked out,
    // so asking for it afterwards costs nothing.
    _ = try value(CurrentUser, &c);
    try testing.expectEqual(@as(usize, 1), authenticate_runs);
}

test "the services a resolver needs are visible to listen()" {
    // A `*Db` nobody else mentions still has to be caught at startup rather
    // than by the first request that touches an authenticated route.
    const needed = comptime requirements(Admin, "/admin/stats");
    try testing.expectEqual(@as(usize, 1), needed.len);
    try testing.expectEqualStrings(@typeName(Db), needed[0].type_name);
    try testing.expect(needed[0].needs_mutable);
    try testing.expectEqualStrings("/admin/stats", needed[0].route);
}

test "isResolved only says yes to a type carrying the marker" {
    try testing.expect(isResolved(CurrentUser));
    try testing.expect(isResolved(Admin));
    try testing.expect(!isResolved(Db));
    try testing.expect(!isResolved(u32));
    try testing.expect(!isResolved([]const u8));
}
