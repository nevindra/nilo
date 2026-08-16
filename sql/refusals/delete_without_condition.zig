//! A delete with nothing to narrow it. This is legal SQL that empties the
//! table, and it is reached by leaving something out rather than by writing
//! something down — so it is refused here and has to be said out loud with
//! `db.raw` if it is meant.

const sql = @import("zfast_sql");

const User = struct {
    pub const zfast_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.deleteFor(User, @TypeOf(.{}));
    _ = found;
}
