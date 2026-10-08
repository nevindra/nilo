//! `Sort.by` with nothing to order by. It was a `std.debug.assert` at run time,
//! which ReleaseFast does not check, and the statement it wrote ended its
//! `ORDER BY` in a comma.

const sql = @import("nilo_sql");

const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    created_at: i64,
};

const Sort = sql.Ordering(Ticket, .{ .created = .created_at });

export fn refusal() void {
    const found = sql.selectFor(Ticket, @TypeOf(.{ .order = Sort.by(&.{}) }));
    _ = found;
}
