//! `.in` takes a list, and a list that may be absent is the empty list —
//! which `.in` already reads as *no row matches*. There is no term to drop.

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
        .where = .{ .id = .{ .in = sql.given(@as(?[]const i64, null)) } },
    }));
    _ = found;
}
