//! A `.key` naming the same column twice. Each column of a key identifies a
//! different part of the row, so `(id, id)` is a key of one column written
//! twice — and the `PRIMARY KEY (id, id)` it would generate is a syntax error
//! from the database rather than from here.

const sql = @import("nilo_sql");

const Seat = struct {
    pub const nilo_table = .{ .name = "seats", .key = .{ .id, .id } };

    tenant_id: i64,
    id: i64,
};

export fn refusal() void {
    _ = sql.selectFor(Seat, @TypeOf(.{}));
}
