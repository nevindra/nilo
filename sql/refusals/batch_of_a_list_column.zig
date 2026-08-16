//! A batch insert naming a column that is itself a list. A batch sends one
//! array per column and `unnest` flattens what it is given, so a `text[]`
//! column would come back one element per row rather than one array per row —
//! silently, and only in production, which is why it stops here.

const sql = @import("nilo_sql");

const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    tags: []const []const u8,
};

const Line = struct { tags: []const []const u8 };

export fn refusal() void {
    _ = sql.insertManyFor(Ticket, Line);
}
