//! `.set = .{ .x = .now }` on a column that is not a `sql.Timestamp`.
//!
//! `.now` is the database's clock, written as the dialect's own expression,
//! and it means nothing in an integer or a text column.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    seen_at: i64,
};

export fn refusal() void {
    const changed = sql.updateFor(User, @TypeOf(.{
        .set = .{ .seen_at = .now },
        .where = .{ .id = 1 },
    }));
    _ = changed;
}
