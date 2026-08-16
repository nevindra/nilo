//! An insert with no columns. A row made entirely of defaults is a real
//! thing to want and `db.raw` with `DEFAULT VALUES` is how to say it; written
//! this way it is far more likely the values were left out by accident.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.insertFor(User, @TypeOf(.{}));
    _ = found;
}
