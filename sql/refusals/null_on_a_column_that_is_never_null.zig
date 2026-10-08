//! `.age = null` on a column that cannot be null. It is `IS NULL`, which no
//! row of a `NOT NULL` column satisfies: the query runs, answers nothing and
//! reports no error, the silent shape
//! [ADR 040](../../docs/adr/040-a-condition-holds-a-value-not-a-maybe.md)
//! refuses for `= NULL`.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    age: i32,
    deleted_at: ?i64,
};

export fn refusal() void {
    const found = sql.selectFor(User, @TypeOf(.{
        .where = .{ .age = null },
    }));
    _ = found;
}
