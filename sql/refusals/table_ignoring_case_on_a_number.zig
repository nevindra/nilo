//! `.ignoring_case` on a column that has no case. Both databases would take
//! the clause and neither would do anything with it, which is the shape of
//! mistake that is only found the day two rows collide.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .unique = .{.{ .columns = .{.age}, .ignoring_case = true }},
    };

    id: i64,
    age: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{User});
}
