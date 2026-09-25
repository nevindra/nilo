//! An upsert conflicting on a column whose only unique ignores case.
//!
//! That unique is an index on `lower(email)` on Postgres and a `COLLATE
//! NOCASE` one on SQLite. `ON CONFLICT ("email")` names the plain column, and
//! neither database counts the folded index as a match, so the statement is
//! refused the first time it runs.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .unique = .{.{ .columns = .{.email}, .ignoring_case = true }},
    };

    id: i64,
    email: []const u8,
    name: []const u8,
};

export fn refusal() void {
    const stmt = sql.insertOrIgnoreFor(User, @TypeOf(.{ .email = "a@b.c", .name = "Ada" }), .email);
    _ = stmt;
}
