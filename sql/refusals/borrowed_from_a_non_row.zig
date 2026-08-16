//! A Row borrowing its table from a type that has no table to lend. The
//! marker takes either a table of its own or another Row, and `Settings` is
//! neither.

const sql = @import("nilo_sql");

const Settings = struct { theme: []const u8 };

const UserCard = struct {
    pub const nilo_table = Settings;

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.selectFor(UserCard, @TypeOf(.{}));
    _ = found;
}
