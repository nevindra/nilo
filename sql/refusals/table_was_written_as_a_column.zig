//! The old name written as `.handle` rather than as `"handle"`. It is not a
//! column any more, which is the whole reason `.was` exists.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .was = .{ .email = .handle },
    };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{User});
}
