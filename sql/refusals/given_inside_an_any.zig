//! `.any` is OR, so an alternative that is not there makes the condition match
//! *fewer* rows. Everywhere else a term that drops widens the answer, which is
//! what a filter nobody set has to do — one word cannot mean both.

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
        .where = .{ .any = .{
            .{ .name = sql.given(@as(?[]const u8, null)) },
            .{ .id = @as(i64, 1) },
        } },
    }));
    _ = found;
}
