//! `db.rawPage` over a statement whose `OFFSET` is arithmetic. A page past
//! its last row has no row to carry `count(*) OVER ()`, so the same
//! statement is asked again with the offset at 0, and that means finding the
//! offset among the values
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
    const page: i64 = 2;
    _ = db.rawPage(
        Line,
        &run,
        "SELECT id, email, count(*) OVER () FROM people ORDER BY id LIMIT 20 OFFSET ($1 - 1) * 20",
        .{page},
    ) catch {};
}
