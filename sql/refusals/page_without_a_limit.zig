//! A page with no ceiling is the whole table, and the `count(*) OVER ()` it
//! paid for answers what `rows.len` already says. `db.select` is the call for
//! every row that matched.

const sql = @import("nilo_sql");

const Order = struct {
    pub const nilo_table = .{ .name = "orders", .key = .id };

    id: i64,
    status: []const u8,
};

export fn refusal() void {
    const found = sql.pageFor(Order, @TypeOf(.{ .order = .{ .id = .asc } }));
    _ = found;
}
