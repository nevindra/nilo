//! `sql.given` drops its term when the value is null, and what stands between
//! a `DELETE` and the whole table is not something to leave to a value that
//! may not arrive. With no id this is `DELETE FROM partners`, and it compiles.

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
    const found = sql.deleteFor(Partner, @TypeOf(.{
        .where = .{ .id = sql.given(@as(?i64, null)) },
    }));
    _ = found;
}
