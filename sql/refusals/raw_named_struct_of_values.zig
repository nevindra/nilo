//! A `Uuid` handed to `db.raw` in a struct with named fields rather than in a
//! tuple. nilo converts a raw parameter by position (ADR 0145), and a named
//! struct is bound by `:name` — a spelling only sqlite has — so there is no
//! position to convert against. Left alone it would reach the driver as a Zig
//! struct, which is what this whole path exists to stop.

const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Doc = struct {
    pub const nilo_table = .{ .name = "docs", .key = .id };

    id: i64,
    owner: sql.Uuid,
};

export fn refusal() void {
    var run = nilo.Run.init(@import("std").heap.page_allocator);
    var db = sql.Db.init(@import("std").heap.page_allocator, "postgres://x/y", .{});
    _ = db.raw(Doc, &run, "SELECT id, owner FROM docs WHERE owner = :owner", .{
        .owner = sql.Uuid.nil,
    }) catch {};
}
