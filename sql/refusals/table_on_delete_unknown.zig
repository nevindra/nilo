//! A fourth thing to happen on delete. There are three, and a word the
//! dialect does not have would otherwise be written into a constraint.

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
        .references = .{ .org_id = .{ Org, .id, .set_default } },
    };

    id: i64,
    org_id: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{ Org, User });
}
