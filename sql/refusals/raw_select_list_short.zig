//! A `SELECT` list with fewer columns than the Row it fills. `db.raw` fills
//! by position, so a short list leaves the last fields reading a column that
//! is not there — which used to be a panic in ReleaseSafe on the first row
//! ([ADR 0134](../../docs/adr/0134-a-select-list-shorter-than-the-row-is-refused.md))
//! and is now counted while compiling (ADR 0148).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Person = struct {
    pub const nilo_table = .{ .name = "people", .key = .id };

    id: i64,
    email: nilo.Str,
    age: i32,
};

export fn refusal() void {
    var run = nilo.Run.init(std.heap.page_allocator);
    var db = sql.Db.init(std.heap.page_allocator, "postgres://x/y", .{});
    _ = db.raw(Person, &run, "SELECT id, email FROM people", .{}) catch {};
}
