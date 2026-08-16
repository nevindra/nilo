//! The conflict target is a string rather than a column name. Every other
//! place a caller names a column takes an enum literal — `.key = .id`,
//! `.{ .email = … }` in a condition — and a string here would be the one
//! spelling that is different, quoted straight into the SQL.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.insertOrIgnoreFor(User, @TypeOf(.{ .email = "a@b.c" }), "email");
    _ = found;
}
