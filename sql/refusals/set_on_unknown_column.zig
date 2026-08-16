//! `.set` naming a column the Row does not read. Same check as a condition
//! on one, and deliberately the same message: where the typo was written
//! should not change how it reads.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    age: i32,
};

export fn refusal() void {
    const found = sql.updateFor(User, @TypeOf(.{ .set = .{ .aeg = 31 }, .where = .{ .id = 1 } }));
    _ = found;
}
