//! `.any` given one condition rather than a list of them. Written this way it
//! reads as "role is admin OR …" with nothing on the other side, and the outer
//! braces that would have held the alternatives are missing.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    role: []const u8,
};

export fn refusal() void {
    const found = sql.selectFor(User, @TypeOf(.{
        .where = .{ .any = .{ .role = "admin" } },
    }));
    _ = found;
}
