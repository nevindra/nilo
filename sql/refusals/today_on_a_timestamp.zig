//! `.today` written into a `sql.Timestamp`.
//!
//! `.today` is the day the statement runs, `CURRENT_DATE`, and a timestamp
//! column would take it as midnight in whatever zone the session happens to
//! be in: an instant nobody chose. The instant is `.now`, and the day is a
//! `sql.Date` column.

const sql = @import("nilo_sql");

const Card = struct {
    pub const nilo_table = .{ .name = "work_items", .key = .id };

    id: i64,
    seen_at: sql.Timestamp,
};

export fn refusal() void {
    _ = sql.updateFor(Card, @TypeOf(.{
        .set = .{ .seen_at = .today },
        .where = .{ .id = @as(i64, 7) },
    }));
}
