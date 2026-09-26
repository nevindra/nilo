//! `db.rawPage` with its values in a struct with named fields, over a
//! statement with an `OFFSET $n`. The offset is found by position, and a
//! named struct has none
//! ([ADR 205](../../docs/adr/205-a-raw-statement-can-carry-its-total.md)).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Line = struct {
    pub const nilo_table = .projection;

    id: i64,
    email: nilo.Str,
};

export fn refusal() void {
    var run = nilo.Run.init(std.heap.page_allocator);
    var db = sql.Db.init(std.heap.page_allocator, "postgres://x/y", .{});
    const Values = struct { offset: i64 };
    _ = db.rawPage(
        Line,
        &run,
        "SELECT id, email, count(*) OVER () FROM people ORDER BY id LIMIT 20 OFFSET $1",
        Values{ .offset = 40 },
    ) catch {};
}
