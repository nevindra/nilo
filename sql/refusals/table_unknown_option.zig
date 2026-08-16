//! The marker was given `.primary` instead of `.key`. A field it does not
//! know would otherwise be ignored in silence, and the Row would look as if
//! it had said which column identifies a row when it had not.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .primary = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.selectFor(User, @TypeOf(.{}));
    _ = found;
}
