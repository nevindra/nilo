//! A single `.exists` test written bare rather than in the list.
//!
//! A struct cannot carry the same field twice, so a bare test could never
//! become two — and a filter page narrowing on two capabilities is the
//! ordinary case rather than the exotic one. The same argument `.any` makes.

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
    _ = sql.selectFor(Partner, @TypeOf(.{ .where = .{
        .exists = .{ .in = Capability, .where = .{ .capability = @as([]const u8, "vision") } },
    } }));
}
