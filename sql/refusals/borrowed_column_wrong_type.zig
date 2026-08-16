//! Two Rows over one column disagreeing about what is in it. One of them is
//! wrong about the table, and which one it is cannot be worked out from here
//! — so both are named.

const sql = @import("zfast_sql");

const User = struct {
    pub const zfast_table = .{ .name = "users", .key = .id };

    id: i64,
    age: i32,
};

const UserCard = struct {
    pub const zfast_table = User;

    id: i64,
    age: []const u8,
};

export fn refusal() void {
    const found = sql.selectFor(UserCard, @TypeOf(.{}));
    _ = found;
}
