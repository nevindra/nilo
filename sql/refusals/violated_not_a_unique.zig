//! `sql.violated` asked about a column nothing makes unique.
//!
//! It answers whether the last statement broke the key or a `.unique`, and it
//! can only name one the marker declares: that is what lets it accept both
//! Postgres's constraint name and SQLite's column list. A column with no
//! unique over it cannot have been what an `AlreadyExists` was about, so the
//! branch is dead code, usually because the unique was renamed or dropped
//! (ADR 117).

const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id, .unique = .{.{ .columns = .{.email} }} };

    id: i64,
    email: []const u8,
    handle: []const u8,
};

export fn refusal() void {
    var run: nilo.Run = undefined;
    _ = sql.violated(&run, User, .{.handle});
}
