//! `updateReturningOne` with a `.where` on a column nothing makes unique.
//!
//! The call answers with one row and the `UPDATE` changes every row the
//! condition matches, so a `PATCH` written this way rewrote every user sharing
//! the address and reported one. The key, or a unique, held with `=`, is what
//! makes "one" true of the statement rather than of the answer (ADR 146).

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    name: []const u8,
};

export fn refusal() void {
    const changed = sql.updateReturningOneFor(User, @TypeOf(.{
        .set = .{ .name = "Ada" },
        .where = .{ .email = "ada@example.dev" },
    }));
    _ = changed;
}
