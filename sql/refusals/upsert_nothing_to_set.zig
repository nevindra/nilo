//! Every column an `insertOrUpdate` was given is either the conflict target
//! or the key, so the update half has nothing left to write. The statement it
//! was actually asking for is `insertOrIgnore`, which says so in its name and
//! in its return type.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.insertOrUpdateFor(User, @TypeOf(.{ .id = 1, .email = "a@b.c" }), .email);
    _ = found;
}
