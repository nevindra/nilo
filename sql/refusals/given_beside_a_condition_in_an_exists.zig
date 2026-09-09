//! Inside a subquery a `sql.given` drops the whole `EXISTS`, because dropping
//! one term of it would leave the subquery asking whether any joined row
//! exists at all — which excludes every partner with no capabilities. So it
//! cannot sit beside a condition that is always there: the two would want
//! opposite things from one absent value.

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
        .where = .{ .exists = .{.{
            .in = Capability,
            .where = .{
                .partner_id = @as(i64, 1),
                .capability = sql.given(@as(?[]const u8, null)),
            },
        }} },
    }));
    _ = found;
}
