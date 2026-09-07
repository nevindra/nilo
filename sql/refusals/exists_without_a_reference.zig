//! An `.exists` over a Row that declares no `.references` back.
//!
//! The join is read out of the schema rather than written at the call site,
//! which is what makes the whole feature cost no new vocabulary — and what
//! makes a schema that has not said how the two tables relate a Refusal rather
//! than a guess. `.on = .<column>` is the way out when the foreign key is not
//! declared (ADR 0171).

const sql = @import("nilo_sql");

const Partner = struct {
    pub const nilo_table = .{ .name = "partners", .key = .id };

    id: i64,
    name: []const u8,
};

const Capability = struct {
    pub const nilo_table = .{ .name = "partner_capabilities", .key = .id };

    id: i64,
    partner_id: i64,
    capability: []const u8,
};

export fn refusal() void {
    _ = sql.selectFor(Partner, @TypeOf(.{ .where = .{ .exists = .{
        .{ .in = Capability, .where = .{ .capability = @as([]const u8, "vision") } },
    } } }));
}
