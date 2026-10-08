//! `.age = .{ .ne = null }` on a column that cannot be null. It is `IS NOT
//! NULL`, which every row of a `NOT NULL` column satisfies, so the condition
//! filters nothing and reads as though it did.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    age: i32,
    deleted_at: ?i64,
};

export fn refusal() void {
    const found = sql.selectFor(User, @TypeOf(.{
        .where = .{ .age = .{ .ne = null } },
    }));
    _ = found;
}
