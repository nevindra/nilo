//! `FOR UPDATE` and a window function cannot be in one statement — Postgres
//! refuses it at run time, on whichever request got there first. A page is a
//! read; the rows to hold are the ones a `tx.select` came back with.

const sql = @import("nilo_sql");

const Order = struct {
    pub const nilo_table = .{ .name = "orders", .key = .id };

    id: i64,
    status: []const u8,
};

export fn refusal() void {
    const found = sql.pageFor(Order, @TypeOf(.{
        .order = .{ .id = .asc },
        .limit = 20,
        .lock = sql.Lock.update,
    }));
    _ = found;
}
