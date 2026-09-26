//! `db.rawPage` over SQLite's `LIMIT <offset>, <count>`, which puts the
//! offset where the second ask a page past its last row needs cannot find it
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
    const skip: i64 = 40;
    const take: i64 = 20;
    _ = db.rawPage(Line, &run, "SELECT id, email, count(*) OVER () FROM people ORDER BY id LIMIT $1, $2", .{ skip, take }) catch {};
}
