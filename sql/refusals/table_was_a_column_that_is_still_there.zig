//! A rename whose old name is still a column of the Row. Both cannot be true:
//! a rename leaves one column, so one of the two fields should go.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .was = .{ .email = "handle" },
    };

    id: i64,
    email: []const u8,
    handle: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{User});
}
