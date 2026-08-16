//! A condition on a column that does not exist. `age` was typed `agee`, and
//! the Row is right there in the same file — so this is settled while
//! compiling rather than by a database saying no at three in the morning.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
};

export fn refusal() void {
    const found = sql.selectFor(User, @TypeOf(.{ .where = .{ .agee = .{ .gt = 18 } } }));
    _ = found;
}
