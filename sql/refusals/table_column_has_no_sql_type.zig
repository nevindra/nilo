//! A field the dialect cannot name a column type for. Reading such a Row is
//! already refused; creating a table for one has to be refused in the same
//! words, because the answer is the same four ways out.

const sql = @import("nilo_sql");

const Point = struct { x: f64, y: f64 };

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    place: Point,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{User});
}
