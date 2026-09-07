//! A `db.find` given a column that exists and is not part of the key.
//!
//! A find identifies one row by its key. Narrowing on another column is a
//! condition, and the call that takes one is `db.one` — so the message names
//! it rather than listing the key again.

const sql = @import("nilo_sql");

const Seat = struct {
    pub const nilo_table = .{ .name = "seats", .key = .{ .tenant_id, .id } };

    tenant_id: i64,
    id: i64,
    label: []const u8,
};

export fn refusal() void {
    _ = sql.findFor(Seat, @TypeOf(.{ .tenant_id = @as(i64, 1), .label = "a" }));
}
