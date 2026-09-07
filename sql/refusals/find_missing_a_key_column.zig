//! A `db.find` on a Row keyed by two columns that names only one of them.
//!
//! Leaving one out is not a narrower find. The statement would match every row
//! that shares the rest of the key, and its `LIMIT 1` would then answer with
//! whichever the database reached first — a row that is right most of the time
//! and wrong under exactly the load nobody reproduces.

const sql = @import("nilo_sql");

const Seat = struct {
    pub const nilo_table = .{ .name = "seats", .key = .{ .tenant_id, .id } };

    tenant_id: i64,
    id: i64,
    label: []const u8,
};

export fn refusal() void {
    _ = sql.findFor(Seat, @TypeOf(.{ .id = @as(i64, 7) }));
}
