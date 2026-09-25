//! `.ieq` on a column that holds no text.
//!
//! Equality that ignores case folds both sides with `lower(…)`, and Postgres
//! will fold a number by casting it to text first — so the comparison runs,
//! compares the digits it happens to print, and raises nothing. There is no
//! case in a number to ignore; `.eq` is the comparison meant.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    age: i32,
};

export fn refusal() void {
    _ = sql.selectFor(User, @TypeOf(.{
        .where = .{ .age = .{ .ieq = @as([]const u8, "1") } },
    }));
}
