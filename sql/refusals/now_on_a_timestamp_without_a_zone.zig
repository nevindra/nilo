//! `.now` written into a `timestamp` column read as text.
//!
//! A `timestamp` has no zone, so `now()` meets it through the session's
//! TimeZone: a session in Asia/Jakarta stores and compares seven hours off a
//! session in UTC, and nothing in the statement says so. `.now` goes in a
//! `timestamptz`, which keeps the instant (ADR 067).

const sql = @import("nilo_sql");

const Card = struct {
    pub const nilo_table = .{ .name = "work_items", .key = .id };

    id: i64,
    seen_at: sql.AsText("timestamp"),
};

export fn refusal() void {
    _ = sql.updateFor(Card, @TypeOf(.{
        .set = .{ .seen_at = .now },
        .where = .{ .id = @as(i64, 7) },
    }));
}
