//! The marker is there and does not name a table. `.key` alone says which
//! column identifies a row without saying which rows.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.selectFor(User, @TypeOf(.{}));
    _ = found;
}
