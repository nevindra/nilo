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
const naming = @import("names.zig");

const Limits = @import("nilo_core").Limits;

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
        start: ?*const fn (*anyopaque, std.Io, Limits) anyerror!void = null,
        /// Set only for a service that declared `nilo_stop`. The mirror of
        /// `start`, and the reason it exists is that a service which put
        /// work on the Engine's loop has to take it off again before the
        /// loop is torn down (ADR 0151).
        stop: ?*const fn (*anyopaque) void = null,
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
    /// **Two arities, and the older one is not deprecated.** A Service that
    /// only wants the loop writes `nilo_start(self, io)` and is untouched by
    /// ADR 0065; one that also wants to bound an outbound call writes
    /// `nilo_start(self, io, limits)`. Both erase to the same three-argument
    /// pointer, so the registry holds one kind of thing and the branch is a
    /// `comptime` one paid once per service type.
    ///
    /// Widening every hook to three parameters instead would have been one
    /// line in `sql/db.zig` and a break for every Service written outside this
    /// repository, for a parameter most of them will not use.
    fn startHook(comptime T: type) ?*const fn (*anyopaque, std.Io, Limits) anyerror!void {
        if (!@hasDecl(T, "nilo_start")) return null;

        const params = @typeInfo(@TypeOf(T.nilo_start)).@"fn".params;
        if (params.len != 2 and params.len != 3) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_start takes " ++
                std.fmt.comptimePrint("{d}", .{params.len}) ++
                " parameters, and it has to take 2 or 3.\n" ++
                "  fn nilo_start(self: *" ++ naming.of(T) ++ ", io: std.Io) !void\n" ++
                "  fn nilo_start(self: *" ++ naming.of(T) ++ ", io: std.Io, limits: nilo_core.Limits) !void\n" ++
                "  The second form is for a service that bounds an outbound call with a deadline.",
        );

        return &struct {
            fn call(erased: *anyopaque, io: std.Io, limits: Limits) anyerror!void {
                const self: *T = @ptrCast(@alignCast(erased));
                if (params.len == 2) return T.nilo_start(self, io);
                return T.nilo_start(self, io, limits);
            }
        }.call;
    }

    /// The `nilo_stop` hook, erased the way `nilo_start` is.
    ///
    /// **One arity and no error.** A stop hook runs from a `defer` on the
    /// way out of `listen()`, where there is nobody left to hand a failure
    /// to and nothing useful to do with one — a service that hits trouble
    /// putting something down logs it and carries on, which is what every
    /// `deinit` in this repository already does. And it takes no `std.Io`:
    /// the loop it was started on is the loop it is still on, and a service
    /// that needed to remember it kept it in `nilo_start` (ADR 0151).
    ///
    /// A service with no `nilo_stop` is the ordinary case and costs one
    /// branch, once, on the way out.
    fn stopHook(comptime T: type) ?*const fn (*anyopaque) void {
        if (!@hasDecl(T, "nilo_stop")) return null;

        const info = @typeInfo(@TypeOf(T.nilo_stop));
        if (info != .@"fn") @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_stop is not a function, and it has to be one.\n" ++
                "  fn nilo_stop(self: *" ++ naming.of(T) ++ ") void",
        );
        const f = info.@"fn";
        if (f.params.len != 1) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_stop takes " ++
                std.fmt.comptimePrint("{d}", .{f.params.len}) ++
                " parameters, and it has to take 1.\n" ++
                "  fn nilo_stop(self: *" ++ naming.of(T) ++ ") void\n" ++
                "  It runs on the way out of `listen()`, so there is nothing else to hand it.",
        );
        if (f.params[0].type != *T) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_stop takes " ++
                naming.of(f.params[0].type orelse anyopaque) ++
                ", and it has to take `*" ++ naming.of(T) ++ "`.\n" ++
                "  A stop hook puts something down, so it needs the service it is putting down.",
        );
        // The type is deliberately not printed. An inferred error union has
        // no readable name — `names.of` renders it as the `@typeInfo` chain
        // that produced it — and naming it adds nothing the reader needs.
        if (f.return_type != void) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_stop returns something other than `void`, and " ++
                "a stop hook has to return `void`.\n" ++
                "  fn nilo_stop(self: *" ++ naming.of(T) ++ ") void\n" ++
                "  It runs from a `defer` on the way out of `listen()`, where there is nobody " ++
                "left to hand a failure to. Log what went wrong and carry on.",
        );

        return &struct {
            fn call(erased: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(erased));
                T.nilo_stop(self);
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
                "nilo: app.provide() wants a pointer to a service, not " ++ naming.of(P) ++
                    ".\n  Services outlive the App, so what gets registered is a pointer to one: " ++
                    "`app.provide(&db)`.",
            ),
        };
        if (info.size != .one) @compileError(
            "nilo: app.provide() wants a pointer to a single value, not " ++ naming.of(P) ++ ".",
        );

        if (info.is_const and @hasDecl(info.child, "nilo_start")) @compileError(
            "nilo: " ++ naming.of(info.child) ++ " has a `nilo_start`, so it finishes building " ++
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
            .stop = stopHook(info.child),
        });
    }

    /// Finish building every service that asked to be finished, in the
    /// order they were provided. Run once, from inside `listen()`, before
    /// the first connection is accepted (ADR 0040).
    ///
    /// The first failure stops the rest: a server whose database is
    /// unreachable should not go on to open anything else and then answer
    /// requests it cannot serve.
    pub fn start(self: *const Registry, io: std.Io, limits: Limits) !void {
        for (self.entries.items) |e| {
            if (e.start) |hook| try hook(e.ptr, io, limits);
        }
    }

    /// Let every service that asked put down what it is holding, **in the
    /// reverse of the order they were provided** — the ordinary unwinding
    /// order, so a service built on top of another is taken down first.
    ///
    /// Run from inside `listen()`, after the last connection has been cut
    /// off and before the Engine's loop is torn down (ADR 0151). It cannot
    /// fail and it cannot be skipped: a service that put work on the loop
    /// and did not take it off is a loop that cannot be deinitialised, and
    /// zio says so with an assert on the way out.
    ///
    /// **It also runs when the server never started.** `start` stops at the
    /// first failure, so the services before that one are up and holding
    /// things, and "the server did not start" has to mean they let go.
    /// A hook is therefore written to survive being called on a service
    /// whose `nilo_start` never ran.
    pub fn stopAll(self: *const Registry) void {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (e.stop) |hook| hook(e.ptr);
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

/// A service that records being stopped, and the order it happened in.
var stop_order: [4]u8 = @splat(0);
var stopped_count: usize = 0;

fn Stoppable(comptime mark: u8) type {
    return struct {
        const Self = @This();
        stopped: bool = false,

        pub fn nilo_stop(self: *Self) void {
            self.stopped = true;
            stop_order[stopped_count] = mark;
            stopped_count += 1;
        }
    };
}

test "a service that says how to stop is stopped, and one that does not is left alone" {
    stopped_count = 0;
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    var one = Stoppable('a'){};
    var plain = Db{};
    try r.add(&one);
    try r.add(&plain);

    r.stopAll();
    try testing.expect(one.stopped);
    try testing.expectEqual(@as(usize, 1), stopped_count);
}

test "services are stopped in the reverse of the order they were provided" {
    stopped_count = 0;
    stop_order = @splat(0);
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    var first = Stoppable('1'){};
    var second = Stoppable('2'){};
    var third = Stoppable('3'){};
    try r.add(&first);
    try r.add(&second);
    try r.add(&third);

    // The ordinary unwinding order, so a service built on top of another is
    // put down before the one underneath it (ADR 0151).
    r.stopAll();
    try testing.expectEqual(@as(usize, 3), stopped_count);
    try testing.expectEqualSlices(u8, "321", stop_order[0..3]);
}

test "a service is stopped even though it never started" {
    stopped_count = 0;
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    // `start` stops at the first failure, so a service registered before the
    // one that refused the boot is up and holding something. Nothing here
    // ever calls `start`, which is that case.
    var never = Stoppable('x'){};
    try r.add(&never);

    r.stopAll();
    try testing.expect(never.stopped);
}
