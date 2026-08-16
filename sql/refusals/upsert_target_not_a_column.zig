//! The conflict target names a column the Row does not read. Postgres would
//! answer with its own message about a column that does not exist, at run
//! time, on whichever request got there first — and the near miss is right
//! there in the Row.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.insertOrIgnoreFor(User, @TypeOf(.{ .email = "a@b.c" }), .emial);
    _ = found;
}
