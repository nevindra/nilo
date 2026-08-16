//! Services — long-lived things registered once when the App is built (a
//! database connection, config, a logger), then asked for by handlers
//! according to their type.
//!
//! ```zig
//! try app.provide(&db);                // once, while assembling the App
//! fn getUser(db: *Db, id: u32) !User   // asked for by argument type
//! ```
//!
//! The registry is a runtime one, keyed by type name. ADR 0006 explains
//! why: `App` stays one ordinary type, and a handler asking for a service
//! that was never registered is caught by `listen()` — before a single
//! request is served, rather than at three in the morning.

const std = @import("std");
const names = @import("names.zig");

/// What a handler needs from the registry. Computed at compile time by the
/// typed engine, then checked once at startup.
pub const Requirement = struct {
    type_name: []const u8,
    /// The handler asked for a mutable pointer (`*Db`, not `*const Db`).
    needs_mutable: bool,
    /// The route that needs it, so the error message is actionable.
    route: []const u8,
};

/// The requirement implied by a handler argument's pointer type.
pub fn requirementFor(comptime P: type, comptime route: []const u8) Requirement {
    const info = @typeInfo(P).pointer;
    return .{
        .type_name = @typeName(info.child),
        .needs_mutable = !info.is_const,
        .route = route,
    };
}

pub const Registry = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        type_name: []const u8,
        ptr: *anyopaque,
        is_const: bool,
        /// Set only for a service that declared `nilo_start`. Null is the
        /// ordinary case and costs one branch at startup, never per
        /// request.
        start: ?*const fn (*anyopaque, std.Io) anyerror!void = null,
    };

    /// The `nilo_start` hook, with the type erased so the registry can hold
    /// it beside every other service.
    ///
    /// A service that needs the event loop cannot be built before
    /// `listen()`, because the loop does not exist until then — and a
    /// connection pool dialled without one blocks the thread every request
    /// on it shares (ADR 0014). Declaring `nilo_start` says "finish
    /// building me once there is a loop", and `listen()` calls it before
    /// accepting anything (ADR 0040).
    fn startHook(comptime T: type) ?*const fn (*anyopaque, std.Io) anyerror!void {
        if (!@hasDecl(T, "nilo_start")) return null;
        return &struct {
            fn call(erased: *anyopaque, io: std.Io) anyerror!void {
                return T.nilo_start(@ptrCast(@alignCast(erased)), io);
            }
        }.call;
    }

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.gpa);
    }

    /// Register a service. `ptr` must outlive the App — this registry only
    /// stores the pointer, it copies nothing.
    ///
    /// Two services of the same type (two databases, say) have to be told
    /// apart with named wrappers; the second one is rejected here
    /// (ADR 0003).
    pub fn add(self: *Registry, ptr: anytype) !void {
        const P = @TypeOf(ptr);
        const info = switch (@typeInfo(P)) {
            .pointer => |p| p,
            else => @compileError(
                "nilo: app.provide() wants a pointer to a service, not " ++ names.of(P) ++
                    ".\n  Services outlive the App, so what gets registered is a pointer to one: " ++
                    "`app.provide(&db)`.",
            ),
        };
        if (info.size != .one) @compileError(
            "nilo: app.provide() wants a pointer to a single value, not " ++ names.of(P) ++ ".",
        );

        if (info.is_const and @hasDecl(info.child, "nilo_start")) @compileError(
            "nilo: " ++ names.of(info.child) ++ " has a `nilo_start`, so it finishes building " ++
                "itself when the server starts — and it was provided as `*const`, which " ++
                "leaves it nothing to build into.\n  Provide it as `app.provide(&thing)` " ++
                "with a `var`.",
        );

        const type_name = @typeName(info.child);
        for (self.entries.items) |e| {
            if (sameName(e.type_name, type_name)) return error.ServiceAlreadyRegistered;
        }
        try self.entries.append(self.gpa, .{
            .type_name = type_name,
            .ptr = @ptrCast(@constCast(ptr)),
            .is_const = info.is_const,
            .start = startHook(info.child),
        });
    }

    /// Finish building every service that asked to be finished, in the
    /// order they were provided. Run once, from inside `listen()`, before
    /// the first connection is accepted (ADR 0040).
    ///
    /// The first failure stops the rest: a server whose database is
    /// unreachable should not go on to open anything else and then answer
    /// requests it cannot serve.
    pub fn start(self: *const Registry, io: std.Io) !void {
        for (self.entries.items) |e| {
            if (e.start) |hook| try hook(e.ptr, io);
        }
    }

    /// Fetch the service of type `P` (a pointer type), or null if it was
    /// never registered — or if it was registered as `*const` while the
    /// handler asked to be able to mutate it.
    pub fn get(self: *const Registry, comptime P: type) ?P {
        const info = @typeInfo(P).pointer;
        const type_name = @typeName(info.child);
        for (self.entries.items) |e| {
            if (!sameName(e.type_name, type_name)) continue;
            if (e.is_const and !info.is_const) return null;
            return @ptrCast(@alignCast(e.ptr));
        }
        return null;
    }

    pub fn has(self: *const Registry, req: Requirement) bool {
        for (self.entries.items) |e| {
            if (!sameName(e.type_name, req.type_name)) continue;
            return !(e.is_const and req.needs_mutable);
        }
        return false;
    }

    /// Type names from `@typeName` are normally the very same literal, so
    /// compare the pointers first; comparing contents is just a safety net.
    fn sameName(a: []const u8, b: []const u8) bool {
        return a.ptr == b.ptr or std.mem.eql(u8, a, b);
    }
};

// ---- tests ----

const testing = std.testing;

const Db = struct { n: u32 = 0 };
const Config = struct { debug: bool = false };

test "provide, then fetch by type" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    var db = Db{ .n = 7 };
    var cfg = Config{ .debug = true };
    try r.add(&db);
    try r.add(&cfg);

    try testing.expectEqual(@as(u32, 7), r.get(*Db).?.n);
    try testing.expect(r.get(*Config).?.debug);

    // Mutated through the service, visible in the original.
    r.get(*Db).?.n = 9;
    try testing.expectEqual(@as(u32, 9), db.n);
}

test "a type that was never registered comes back null" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    var db = Db{};
    try r.add(&db);
    try testing.expect(r.get(*Config) == null);
}

test "two services of the same type are rejected" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    var one = Db{};
    var two = Db{};
    try r.add(&one);
    try testing.expectError(error.ServiceAlreadyRegistered, r.add(&two));
}

test "registered const, asked for mutable, rejected" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    const cfg = Config{ .debug = true };
    try r.add(&cfg);

    try testing.expect(r.get(*const Config) != null);
    try testing.expect(r.get(*Config) == null);
    try testing.expect(r.has(requirementFor(*const Config, "/x")));
    try testing.expect(!r.has(requirementFor(*Config, "/x")));
}

test "has answers the requirements computed at compile time" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    var db = Db{};
    try r.add(&db);

    try testing.expect(r.has(requirementFor(*Db, "/users/:id")));
    try testing.expect(r.has(requirementFor(*const Db, "/users/:id")));
    try testing.expect(!r.has(requirementFor(*Config, "/users/:id")));
}
