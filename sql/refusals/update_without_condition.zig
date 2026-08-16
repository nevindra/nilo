//! An update with nothing to narrow it. This is legal SQL that rewrites
//! every row in the table, and it is reached by leaving something out rather
//! than by writing something down — the same rule `delete` follows.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    age: i32,
};

export fn refusal() void {
    const found = sql.updateFor(User, @TypeOf(.{ .set = .{ .age = 31 } }));
    _ = found;
}
