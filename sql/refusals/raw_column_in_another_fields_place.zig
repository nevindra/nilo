//! Two columns of the same type, the other way round from the Row's fields.
//! `db.raw` fills by position, so both decode cleanly and every row answers
//! wrong — there is no run-time symptom at all. On a schema with 145 `uuid`
//! columns that is the mistake worth catching while compiling (ADR 0148).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Person = struct {
    pub const nilo_table = .{ .name = "people", .key = .id };

    id: i64,
    owner_id: i64,
};

export fn refusal() void {
    var run = nilo.Run.init(std.heap.page_allocator);
    var db = sql.Db.init(std.heap.page_allocator, "postgres://x/y", .{});
    _ = db.raw(Person, &run, "SELECT owner_id, id FROM people", .{}) catch {};
}
