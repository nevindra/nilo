//! `.set = .{ .views = .{ .plus = 1 } }` on a column that may be NULL.
//!
//! `SET "views" = "views" + $1` with `views` NULL stores NULL. The statement
//! runs, reports one row changed, and the counter is gone — the same shape as
//! `= NULL` in a condition, which is legal SQL, raises nothing and is never
//! what was meant (ADR 0039).

const sql = @import("nilo_sql");

const Post = struct {
    pub const nilo_table = .{ .name = "posts", .key = .id };

    id: i64,
    views: ?i64,
};

export fn refusal() void {
    _ = sql.updateFor(Post, @TypeOf(.{
        .set = .{ .views = .{ .plus = 1 } },
        .where = .{ .id = 7 },
    }));
}
