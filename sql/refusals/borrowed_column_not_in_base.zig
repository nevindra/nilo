//! A narrower Row reading a column the Row it borrows from does not have.
//! This is the check that makes borrowing worth the overload: written out
//! longhand the same typo would have survived until a live Postgres saw it.

const sql = @import("zfast_sql");

const User = struct {
    pub const zfast_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
};

const UserCard = struct {
    pub const zfast_table = User;

    id: i64,
    emial: []const u8,
};

export fn refusal() void {
    const found = sql.selectFor(UserCard, @TypeOf(.{}));
    _ = found;
}
