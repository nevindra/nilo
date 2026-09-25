//! `sql.given` in a `.set`, on a column that may be NULL.
//!
//! A given in a `.set` is `COALESCE($n, "column")`: null keeps what the row
//! holds. On a column that may be NULL, null is also a value somebody can
//! mean, so a `PATCH` that asked to clear the nickname would answer 200 and
//! keep the old one.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    nickname: ?[]const u8,
};

export fn refusal() void {
    const nickname: ?[]const u8 = null;
    const changed = sql.updateFor(User, @TypeOf(.{
        .set = .{ .nickname = sql.given(nickname) },
        .where = .{ .id = 1 },
    }));
    _ = changed;
}
