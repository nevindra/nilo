//! A projection handed to a call that writes its own SQL. `db.select` has to
//! put a table after `FROM`, and a Row that says `.projection` has said there
//! is not one
//! ([ADR 0155](../../docs/adr/0155-a-row-that-owns-no-table.md)).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Timeline = struct {
    pub const nilo_table = .projection;

    at: i64,
    kind: nilo.Str,
};

export fn refusal() void {
    var run = nilo.Run.init(std.heap.page_allocator);
    var db = sql.Db.init(std.heap.page_allocator, "postgres://x/y", .{});
    _ = db.select(Timeline, &run, .{}) catch {};
}
