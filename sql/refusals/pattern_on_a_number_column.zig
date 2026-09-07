//! A pattern operator on a column that holds no text.
//!
//! Postgres will make this comparison by casting the number to text first, so
//! `.{ .contains = "1" }` on an `i32` column matches 1, 10, 100, 21 and 31 —
//! an answer that is wrong and raises nothing. A pattern matches text, and the
//! column has to be some.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    age: i32,
};

export fn refusal() void {
    _ = sql.selectFor(User, @TypeOf(.{
        .where = .{ .age = .{ .contains = @as([]const u8, "1") } },
    }));
}
