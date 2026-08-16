//! An insert naming a column the Row does not read. The near miss is what
//! makes this worth stopping for: `emial` is a 500 on somebody's signup
//! page everywhere else, and a compile error here.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
};

export fn refusal() void {
    const found = sql.insertFor(User, @TypeOf(.{ .emial = "a@b.c", .age = 30 }));
    _ = found;
}
