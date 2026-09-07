//! `SELECT *` into a Row with a text column in it. A `*` is a column nobody
//! named, so nobody could have cast it either — and unlike the count, which
//! only the database can settle, this half is answerable while compiling
//! ([ADR 0154](../../docs/adr/0154-a-raw-statement-cannot-cast-what-it-did-not-write.md)).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .key = .id };

    id: i64,
    total: sql.Decimal,
};

export fn refusal() void {
    var run = nilo.Run.init(std.heap.page_allocator);
    var db = sql.Db.init(std.heap.page_allocator, "postgres://x/y", .{});
    _ = db.raw(Invoice, &run, "SELECT * FROM invoices", .{}) catch {};
}
