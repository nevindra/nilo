//! Two operators on one column in a `.set`. A column is changed once per
//! statement, and `views + 1 - 2` is a sum somebody wrote as two thoughts —
//! so the arithmetic goes in the operand instead.

const sql = @import("nilo_sql");

const Post = struct {
    pub const nilo_table = .{ .name = "posts", .key = .id };

    id: i64,
    views: i64,
};

export fn refusal() void {
    _ = sql.updateFor(Post, @TypeOf(.{
        .set = .{ .views = .{ .plus = 1, .minus = 2 } },
        .where = .{ .id = 7 },
    }));
}
