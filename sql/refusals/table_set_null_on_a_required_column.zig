//! The database is told to write a null into a column the Row cannot hold one
//! in. The first cascading delete would be a row nothing can read.

const sql = @import("nilo_sql");

const Org = struct {
    pub const nilo_table = .{ .name = "orgs", .key = .id };

    id: i64,
    name: []const u8,
};

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .references = .{ .org_id = .{ Org, .id, .set_null } },
    };

    id: i64,
    org_id: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{ Org, User });
}
