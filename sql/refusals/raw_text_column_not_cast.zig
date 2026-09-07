//! A text column asked for as itself in a statement nilo did not write. The
//! Dialect adds `::text` to every `SELECT` list this module builds, and to
//! none that a caller builds — so the driver hands over the wire format and
//! `nilo_read` keeps those bytes as if they were the digits
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
    _ = db.raw(Invoice, &run, "SELECT id, total FROM invoices", .{}) catch {};
}
