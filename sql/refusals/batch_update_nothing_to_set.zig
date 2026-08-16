//! A batch update carrying the key and nothing else. Every row would be found
//! and then left exactly as it was, which is a round trip with no effect —
//! and is reached by leaving a column out rather than by writing one down.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

const Change = struct { id: i64 };

export fn refusal() void {
    _ = sql.updateManyFor(User, Change);
}
