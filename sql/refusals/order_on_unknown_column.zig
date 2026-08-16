//! Sorting by a column the Row does not read. Every column named anywhere in
//! a query is checked against the Row, not only the ones in the condition.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    created_at: i64,
};

export fn refusal() void {
    const found = sql.selectFor(User, @TypeOf(.{ .order = .{ .creted_at = .desc } }));
    _ = found;
}
