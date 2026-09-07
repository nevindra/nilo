//! Two sides of a foreign key holding different types. The database finds this
//! at the first insert, in a message about a cast rather than about a design.

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
        .references = .{ .org_id = .{ Org, .id } },
    };

    id: i64,
    org_id: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{ Org, User });
}
