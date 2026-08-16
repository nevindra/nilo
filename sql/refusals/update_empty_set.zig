//! `.set` written out and left empty. Refused separately from a missing
//! `.set` because the mistake is a different one: the braces make it look
//! like a decision was made.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    age: i32,
};

export fn refusal() void {
    const found = sql.updateFor(User, @TypeOf(.{ .set = .{}, .where = .{ .id = 1 } }));
    _ = found;
}
