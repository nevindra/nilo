//! The key is optional. A key identifies a row, so there is no row for it to
//! be null on — and a `NULL` primary key is a table neither database would
//! create.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: ?i64,
    email: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{User});
}
