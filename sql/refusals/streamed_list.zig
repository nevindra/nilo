//! A Row with a list column, handed to `stream`. The same refusal a `Json`
//! column gets and for the same reason: a borrowed row allocates nothing,
//! which is what makes a million-row export run flat, and an array has to be
//! built per row — it arrives as a run of length-prefixed elements, so there
//! is no slice in the read buffer to point at.

const sql = @import("nilo_sql");

const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    tags: []const []const u8,
};

export fn refusal() void {
    const Rows = sql.Db.Streamed(Ticket);
    _ = Rows;
}
