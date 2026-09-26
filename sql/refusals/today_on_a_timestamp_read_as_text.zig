//! `.today` written into a `timestamptz` column read as text.
//!
//! A column read as text takes the clock its column type names (ADR 181):
//! the database writes the value either way, so `sql.AsText("date")` takes
//! `.today` and `sql.AsText("timestamptz")` takes `.now`. This one is an
//! instant, and `.today` would be midnight in whatever zone the session is in.

const sql = @import("nilo_sql");

const Card = struct {
    pub const nilo_table = .{ .name = "work_items", .key = .id };

    id: i64,
    seen_at: sql.AsText("timestamptz"),
};

export fn refusal() void {
    _ = sql.updateFor(Card, @TypeOf(.{
        .set = .{ .seen_at = .today },
        .where = .{ .id = @as(i64, 7) },
    }));
}
