//! A batch update whose rows do not carry the key. Every row in a batch is
//! found by its key — the join is the condition, and there is no `.where` to
//! write instead — so a batch that does not carry one has nothing to find.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
};

const Change = struct { email: []const u8, age: i32 };

export fn refusal() void {
    _ = sql.updateManyFor(User, Change);
}
