//! A foreign key pointing at a table name rather than at the Row that owns
//! the table. The Row is what makes renaming the table move this with it.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .references = .{ .org_id = .{ "orgs", .id } },
    };

    id: i64,
    org_id: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{User});
}
