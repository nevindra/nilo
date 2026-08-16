//! The key names a column the Row does not read. Nothing could identify what
//! came back, because the value that would identify it was never selected.

const sql = @import("zfast_sql");

const User = struct {
    pub const zfast_table = .{ .name = "users", .key = .user_id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    _ = sql.row.keyOf(User);
}
