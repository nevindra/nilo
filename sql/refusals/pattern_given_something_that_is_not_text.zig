//! A pattern operator handed a number. The pattern is built out of the text
//! handed in, and there is nothing to build one out of here — so this stops
//! with the column and the type named, rather than inside the Dialect.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    _ = sql.selectFor(User, @TypeOf(.{
        .where = .{ .email = .{ .contains = @as(i32, 7) } },
    }));
}
