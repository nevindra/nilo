//! A comparison against null. `> NULL` is never true in SQL, so this is a
//! condition that quietly matches no rows — the worst kind, because the query
//! runs and answers.

const sql = @import("zfast_sql");

const User = struct {
    pub const zfast_table = .{ .name = "users", .key = .id };

    id: i64,
    deleted_at: ?i64,
};

export fn refusal() void {
    const found = sql.selectFor(User, @TypeOf(.{
        .where = .{ .deleted_at = .{ .gt = null } },
    }));
    _ = found;
}
