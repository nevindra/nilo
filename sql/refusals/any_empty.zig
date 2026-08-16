//! `.any` with no alternatives in it. An empty OR matches nothing, so the
//! whole query would answer with no rows for a reason no reader could see.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    role: []const u8,
};

export fn refusal() void {
    const found = sql.selectFor(User, @TypeOf(.{ .where = .{ .any = .{} } }));
    _ = found;
}
