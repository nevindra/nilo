//! The stage-3 example App (the typed layer) — and the benchmark target
//! at the same time: a routed GET with a path param returning ~1KB of
//! JSON over keep-alive (the primary metric in docs/plan.md).
//!
//! Note the shape of the handlers: ordinary functions taking a service
//! and a path param, returning data. No `Ctx` except where full control
//! is genuinely needed.

const std = @import("std");
const zfast = @import("zfast.zig");
const bulkhead = @import("bulkhead.zig");
const fail = zfast.fail;

pub const std_options_debug_io = bulkhead.debug_io;

const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
    bio: []const u8,
};

/// A service: registered once in `main`, asked for by handlers via its
/// type.
const Db = struct {
    // The payload is made ~1KB so the benchmark numbers match the metric.
    const bio = "A systems nerd who writes Zig before breakfast. " ** 19;

    max_id: u32,

    fn find(self: *const Db, id: u32) ?User {
        if (id == 0 or id > self.max_id) return null;
        return .{
            .id = id,
            .name = "Routed Tester",
            .email = "tester@example.dev",
            .bio = bio,
        };
    }
};

fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse fail.notFound("no user {d}", .{id});
}

fn health() []const u8 {
    return "alive\n";
}

pub fn main() !void {
    var db = Db{ .max_id = 1_000_000 };

    var app = zfast.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.get("/health", health);

    try app.listen(.{});
}

// A handler is an ordinary function, so it is tested without starting a
// server and without fake HTTP — which is exactly what ADR 0003 promised.
test "getUser" {
    var db = Db{ .max_id = 10 };
    try std.testing.expectEqual(@as(u32, 7), (try getUser(&db, 7)).id);
    try std.testing.expectError(error.Failed, getUser(&db, 99));
}

test {
    _ = @import("zfast.zig");
}
