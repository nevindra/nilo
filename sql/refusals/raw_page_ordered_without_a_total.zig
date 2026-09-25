//! `db.rawPageOrdered` over a statement with an `{order}` hole and no
//! `count(*) OVER ()` on the end of its list. It is `db.rawPage`'s check,
//! held on the call that also takes the request's order
//! ([ADR 205](../../docs/adr/205-a-raw-statement-can-carry-its-total.md)).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Card = struct {
    pub const nilo_table = .projection;

    id: i64,
    title: []const u8,
};

const Sort = sql.Ordering(Card, .{ .id = .id, .title = "lower(title)" });

export fn refusal() void {
    var run = nilo.Run.init(std.heap.page_allocator);
    var db = sql.Db.init(std.heap.page_allocator, "postgres://x/y", .{});
    _ = db.rawPageOrdered(
        Card,
        &run,
        "SELECT id, title FROM tickets {order} LIMIT 20",
        .{},
        Sort.by(&.{.{ .key = .id }}),
    ) catch {};
}
