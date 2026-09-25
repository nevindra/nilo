//! `deleteReturningOne` with the key compared by a range rather than `=`.
//!
//! Naming the key is not the same as holding it: `.id = .{ .gt = 10 }` is
//! every row past the tenth, and the delete takes all of them while the call
//! hands back one (ADR 146).

const sql = @import("nilo_sql");

const Session = struct {
    pub const nilo_table = .{ .name = "sessions", .key = .id };

    id: i64,
    token: []const u8,
};

export fn refusal() void {
    const gone = sql.deleteReturningOneFor(Session, @TypeOf(.{
        .where = .{ .id = .{ .gt = 10 } },
    }));
    _ = gone;
}
