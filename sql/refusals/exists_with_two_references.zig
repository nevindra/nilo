//! An `.exists` over a Row that points at the same table from two columns.
//!
//! A record with `created_by` and `updated_by` both pointing at `staff` is the
//! ordinary shape of this, and which of them joins is a question about what the
//! query means. Guessing would answer a different question, correctly, forever.

const sql = @import("nilo_sql");

const Staff = struct {
    pub const nilo_table = .{ .name = "staff", .key = .id };

    id: i64,
    name: []const u8,
};

const Record = struct {
    pub const nilo_table = .{
        .name = "records",
        .key = .id,
        .references = .{
            .created_by = .{ Staff, .id },
            .updated_by = .{ Staff, .id },
        },
    };

    id: i64,
    created_by: i64,
    updated_by: i64,
    title: []const u8,
};

export fn refusal() void {
    _ = sql.selectFor(Staff, @TypeOf(.{ .where = .{ .exists = .{
        .{ .in = Record, .where = .{ .title = @as([]const u8, "x") } },
    } } }));
}
