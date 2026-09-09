//! `LIMIT` without `ORDER BY` takes whichever rows the planner reached first,
//! and that can differ between two requests for the same page — so one row is
//! on both pages and another is on neither. It compiles, it passes, and the
//! list is wrong.

const sql = @import("nilo_sql");

const Order = struct {
    pub const nilo_table = .{ .name = "orders", .key = .id };

    id: i64,
    status: []const u8,
};

export fn refusal() void {
    const found = sql.pageFor(Order, @TypeOf(.{ .limit = 20 }));
    _ = found;
}
