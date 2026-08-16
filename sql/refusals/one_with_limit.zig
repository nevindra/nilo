//! A `.limit` written on a `db.one`. The call answers with one row or with
//! none and compiles its own `LIMIT 1`, so a second ceiling is either the
//! same number said twice or a disagreement the module would have to pick a
//! winner for. Neither is worth guessing at run time.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.oneFor(User, @TypeOf(.{ .where = .{ .id = 1 }, .limit = 5 }));
    _ = found;
}
