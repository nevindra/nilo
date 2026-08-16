//! A type that reads and writes itself as text and never says which Postgres
//! type it is. The name is what both casts have to spell — `"col"::text` on
//! the way out and `$1::<name>` on the way in — so without it there is no
//! statement to write.

const std = @import("std");
const sql = @import("nilo_sql");

const Span = struct {
    text: []const u8,

    pub fn nilo_read(raw: []const u8, arena: std.mem.Allocator) !Span {
        return .{ .text = try arena.dupe(u8, raw) };
    }

    pub fn nilo_write(self: Span, arena: std.mem.Allocator) ![]const u8 {
        _ = arena;
        return self.text;
    }
};

const Booking = struct {
    pub const nilo_table = .{ .name = "bookings", .key = .id };

    id: i64,
    stay: Span,
};

export fn refusal() void {
    _ = sql.selectFor(Booking, @TypeOf(.{}));
}
