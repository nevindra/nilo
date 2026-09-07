//! A Row with a column named `exists`. One word cannot mean both a column and
//! *a matching row in another table*, which is the same argument the reserved
//! `any` already makes for OR.

const sql = @import("nilo_sql");

const Flag = struct {
    pub const nilo_table = .{ .name = "flags", .key = .id };

    id: i64,
    exists: bool,
};

export fn refusal() void {
    _ = sql.selectFor(Flag, @TypeOf(.{ .where = .{ .id = 1 } }));
}
