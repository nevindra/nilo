//! `.key` as a conflict target means the columns the Row's `nilo_table`
//! already declares (ADR 0186). This Row also has a column called `key`, so
//! the word would mean two things at one call site — and picking either one
//! silently is how a statement ends up conflicting on the wrong columns.

const sql = @import("nilo_sql");

const ApiKey = struct {
    pub const nilo_table = .{ .name = "api_keys", .key = .id };

    id: i64,
    key: []const u8,
};

export fn refusal() void {
    const found = sql.insertOrIgnoreFor(ApiKey, @TypeOf(.{ .key = "abc" }), .key);
    _ = found;
}
