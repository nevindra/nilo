//! An upsert conflicting on a column the marker declares no unique over.
//!
//! The database refuses an `ON CONFLICT` with no constraint behind it, and it
//! refuses it when the statement runs: the first request down this path in
//! production. A table this program builds declares its uniques in the
//! marker, so the target is checked against them here instead.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    name: []const u8,
};

export fn refusal() void {
    const stmt = sql.insertOrIgnoreFor(User, @TypeOf(.{ .email = "a@b.c", .name = "Ada" }), .email);
    _ = stmt;
}
