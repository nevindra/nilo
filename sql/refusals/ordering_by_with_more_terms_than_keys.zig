//! `Sort.by` with more terms than the ordering has keys. A tier past the last
//! key repeats one, and the array that holds the terms is exactly that long:
//! the run-time assert guarding it was out of bounds in ReleaseFast.

const sql = @import("nilo_sql");

const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    created_at: i64,
};

const Sort = sql.Ordering(Ticket, .{ .created = .created_at });

export fn refusal() void {
    const found = sql.selectFor(Ticket, @TypeOf(.{
        .order = Sort.by(&.{ .{ .key = .created }, .{ .key = .created, .direction = .desc } }),
    }));
    _ = found;
}
