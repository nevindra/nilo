//! An `Idempotent` over a store that takes the request's scope (the shape
//! `sql.Replays` has) and cannot free a key
//! ([ADR 268](../docs/adr/268-an-answer-kept-for-a-retry-is-a-row-when-instances-share-a-database.md)).
//! A failed handler has to release its claim, and a store with no `del` would
//! leave the marker to answer 409 to the retry that exists to run again.

const nilo = @import("nilo_http");

const Shared = struct {
    pub const takes_scope = true;
    pub const max_bytes: usize = 4096;

    pub fn getInto(self: *Shared, scope: anytype, key: []const u8, out: []u8) !?[]const u8 {
        _ = .{ self, scope, key, out };
        return null;
    }
    pub fn putIfAbsentFor(self: *Shared, scope: anytype, key: []const u8, value: []const u8, ttl_s: u32) !bool {
        _ = .{ self, scope, key, value, ttl_s };
        return true;
    }
    pub fn put(self: *Shared, scope: anytype, key: []const u8, value: []const u8) !void {
        _ = .{ self, scope, key, value };
    }
};

fn place(key: nilo.Idempotent(Shared, .{})) u32 {
    return @intCast(key.key.len());
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/orders", place) catch {};
}
