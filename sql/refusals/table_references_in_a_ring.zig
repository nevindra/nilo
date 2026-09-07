//! Two tables pointing at each other. A foreign key is written inline, which
//! is the only shape SQLite has, so neither can be created first.

const sql = @import("nilo_sql");

const Org = struct {
    pub const nilo_table = .{
        .name = "orgs",
        .key = .id,
        .references = .{ .owner_id = .{ User, .id } },
    };

    id: i64,
    owner_id: i64,
};

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .references = .{ .org_id = .{ Org, .id } },
    };

    id: i64,
    org_id: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{ Org, User });
}
