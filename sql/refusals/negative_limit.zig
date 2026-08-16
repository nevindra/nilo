//! A negative limit. It counts rows, so there is no number of them below
//! zero, and Postgres would answer this at run time with a syntax error
//! carrying none of the context this message has.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.selectFor(User, @TypeOf(.{ .limit = -1 }));
    _ = found;
}
