//! A table name with more than one dot. `schema.table` has a meaning and
//! `a.b.c` has none — Postgres would look for a relation nobody created, and
//! only at run time.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "db.app.users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    _ = sql.selectFor(User, @TypeOf(.{}));
}
