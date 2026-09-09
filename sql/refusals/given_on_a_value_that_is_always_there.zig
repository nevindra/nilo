//! A value that is always there is an ordinary condition, and wrapping it here
//! compiles to a guard that is never taken — a statement that is harder for
//! the planner and no more capable.

const sql = @import("nilo_sql");

const Partner = struct {
    pub const nilo_table = .{ .name = "partners", .key = .id };

    id: i64,
    name: []const u8,
};

const Capability = struct {
    pub const nilo_table = .{
        .name = "partner_capabilities",
        .key = .{ .partner_id, .capability },
        .references = .{ .partner_id = .{ Partner, .id } },
    };

    partner_id: i64,
    capability: []const u8,
};

export fn refusal() void {
    const found = sql.selectFor(Partner, @TypeOf(.{
        .where = .{ .name = sql.given(@as([]const u8, "wati")) },
    }));
    _ = found;
}
