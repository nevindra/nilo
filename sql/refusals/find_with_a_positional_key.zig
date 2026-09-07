//! A `db.find` on a composite key written as a tuple.
//!
//! A tuple is positional, and both columns of `(tenant_id, id)` are `i64` — so
//! the two written the other way round is a statement that compiles, runs,
//! finds the wrong row and reports nothing. Named fields make it a Refusal
//! here, which is the whole reason every option in this module is a struct.

const sql = @import("nilo_sql");

const Seat = struct {
    pub const nilo_table = .{ .name = "seats", .key = .{ .tenant_id, .id } };

    tenant_id: i64,
    id: i64,
    label: []const u8,
};

export fn refusal() void {
    _ = sql.findFor(Seat, @TypeOf(.{ @as(i64, 1), @as(i64, 2) }));
}
