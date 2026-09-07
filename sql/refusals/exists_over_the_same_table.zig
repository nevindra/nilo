//! An `.exists` whose Row reads the table the statement is already over.
//!
//! Both sides would be written as the same relation, so every column in the
//! subquery would be ambiguous. Telling them apart needs an alias, which is
//! `db.raw`.

const sql = @import("nilo_sql");

const Partner = struct {
    pub const nilo_table = .{
        .name = "partners",
        .key = .id,
        .references = .{ .parent_id = .{ @This(), .id } },
    };

    id: i64,
    parent_id: i64,
    name: []const u8,
};

export fn refusal() void {
    _ = sql.selectFor(Partner, @TypeOf(.{ .where = .{ .exists = .{
        .{ .in = Partner, .where = .{ .name = @as([]const u8, "acme") } },
    } } }));
}
