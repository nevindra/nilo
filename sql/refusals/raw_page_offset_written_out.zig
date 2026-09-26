//! `db.rawPage` over a statement with its offset written into the text. The
//! second ask a page past its last row needs is the same statement with the
//! offset at 0, and a number in the text cannot be set
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
    _ = db.rawPage(Line, &run, "SELECT id, email, count(*) OVER () FROM people ORDER BY id LIMIT 20 OFFSET 40", .{}) catch {};
}
