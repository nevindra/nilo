//! The benchmark target: a routed GET with a path param returning ~1KB of
//! JSON over keep-alive, which is the primary metric in docs/history.md.
//!
//! Deliberately minimal — anything installed here would end up being
//! measured. The examples worth reading are in `examples/`.

const std = @import("std");
const nilo = @import("nilo_http");
const fail = nilo.fail;

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;

/// A panic still takes the process down — Zig cannot recover (ADR 0008) —
/// but this makes it say which request was being served when it happened.
pub const panic = nilo.panic;

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

    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.provide(&db);

    // Middleware order is the order registered; where the routes are
    // registered relative to this does not matter (ADR 0009).
    //
    // `logger.standard` is deliberately absent: this same binary is the
    // benchmark target, and a log line per request would measure the
    // logger rather than the framework. Add it in a real app.
    try app.use(nilo.cors.permissive);

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
