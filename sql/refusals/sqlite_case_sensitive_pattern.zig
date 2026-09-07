//! `contains` on SQLite, whose `LIKE` folds ASCII case and cannot be told not
//! to by a statement.
//!
//! `PRAGMA case_sensitive_like` is a property of the connection, so honouring
//! this would make the answer depend on how the database was opened rather
//! than on what the query says. The Refusal names `icontains`, which is the
//! operator that means what this database actually does (ADR 0061).

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    _ = sql.statement.select(sql.dialect.SQLite, User, @TypeOf(.{
        .where = .{ .email = .{ .contains = @as([]const u8, "a") } },
    }));
}
