//! `.limit` typed `.limti`. An option a query does not know would otherwise
//! be ignored, and the query would answer with every row while looking as
//! though it had been told to stop at ten.

const sql = @import("zfast_sql");

const User = struct {
    pub const zfast_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.selectFor(User, @TypeOf(.{ .limti = 10 }));
    _ = found;
}
