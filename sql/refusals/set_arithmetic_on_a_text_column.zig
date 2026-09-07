//! `.plus` on a column that holds no number.
//!
//! The two operators a `.set` has are arithmetic, and Postgres would read
//! `"title" + $1` as an operator it has no definition for. Saying so here names
//! the column and the type it reads as, which the database's own message does
//! not.

const sql = @import("nilo_sql");

const Post = struct {
    pub const nilo_table = .{ .name = "posts", .key = .id };

    id: i64,
    title: []const u8,
};

export fn refusal() void {
    _ = sql.updateFor(Post, @TypeOf(.{
        .set = .{ .title = .{ .plus = 1 } },
        .where = .{ .id = 7 },
    }));
}
