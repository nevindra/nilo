//! A column named as text where every other part of this module names one as
//! `.<name>`. Text would compile and would not be checked against the Row.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .unique = .{.{"email"}},
    };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{User});
}
