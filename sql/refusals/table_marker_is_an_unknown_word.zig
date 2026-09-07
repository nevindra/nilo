//! A word in the marker that is not `.projection`. There is exactly one, and
//! a near miss is a typo rather than a new kind of Row
//! ([ADR 0155](../../docs/adr/0155-a-row-that-owns-no-table.md)).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Rollup = struct {
    pub const nilo_table = .view;

    at: i64,
    kind: nilo.Str,
};

export fn refusal() void {
    var run = nilo.Run.init(std.heap.page_allocator);
    var db = sql.Db.init(std.heap.page_allocator, "postgres://x/y", .{});
    _ = db.select(Rollup, &run, .{}) catch {};
}
