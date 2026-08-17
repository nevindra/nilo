//! arsip — a document archive, built to find out what nilo is like to use.
//!
//! ```
//! zig build run
//!
//! OP='X-Operator: wati'
//!
//! curl -H "$OP" -X PUT localhost:8801/v1/folders/kantor -d '{"name":"Kantor","visibility":"team"}'
//! curl -H "$OP" localhost:8801/v1/folders
//!
//! # a body with an optional struct, a list of structs, and a list inside each
//! curl -H "$OP" -X POST localhost:8801/v1/folders/kantor/docs -d '{
//!   "title": "Laporan Q3",
//!   "kind": "invoice",
//!   "meta":  {"author":"wati","type":"invoice","pages":12},
//!   "tags":  ["penting","2026"],
//!   "sections": [{"heading":"Ringkasan","lines":["Naik 12%","Biaya turun"]}]
//! }'
//!
//! # and what it says when three fields are wrong at once
//! curl -H "$OP" -X POST localhost:8801/v1/folders/kantor/docs \
//!      -d '{"title":"x","kind":"gold","visibility":"loud"}'
//!
//! curl -H "$OP" 'localhost:8801/v1/docs?kind=invoice&sort=title&per_page=2'
//! curl -H "$OP" localhost:8801/v1/docs/1
//! curl -H "$OP" localhost:8801/v1/docs/1/raw
//!
//! curl -H "$OP" -X PATCH localhost:8801/v1/docs/1 -d '{"visibility":"public"}'
//! curl -H "$OP" -X PATCH localhost:8801/v1/docs/1 -d '{"meta":null}'    # empty it
//! curl -H "$OP" -X PATCH localhost:8801/v1/docs/1 -d '{"title":null}'   # 400: it keeps that
//!
//! curl -H "$OP" -X POST localhost:8801/v1/docs/1/advance -d '{"to":"review"}'
//! curl -H "$OP" -X POST localhost:8801/v1/docs/1/advance -d '{"to":"draft"}'   # 409
//!
//! curl localhost:8801/v1/docs                             # 401: no operator
//! curl -H "$OP" localhost:8801/v1/curate/report           # 403: not a curator
//! curl -H 'X-Operator: bu-sri' localhost:8801/v1/curate/report
//!
//! curl localhost:8801/openapi.json | jq '.components.schemas | keys'
//! ```

const std = @import("std");
const nilo = @import("nilo_http");
const handlers = @import("handlers.zig");
const Archive = @import("archive.zig").Archive;
const Settings = @import("settings.zig").Settings;

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

fn health() struct { status: []const u8, milestone: u8 } {
    return .{ .status = "ok", .milestone = 1 };
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();

    var archive: Archive = .init(gpa);
    defer archive.deinit();
    try app.provide(&archive);

    // Two services of different shapes. `*const Settings` and `*Settings` are
    // different types and are looked up as such, so a read-only service says
    // so in the signature of every handler that takes one.
    const limits: Settings = .{};
    try app.provide(&limits);

    try app.use(nilo.logger.with(.{ .request_id = true }));

    try app.get("/health", health);
    try handlers.mount(app.group("/v1"));

    app.docs(.{
        .title = "arsip",
        .version = "0.1.0",
        .description = "A document archive, and a stress test of nilo's DX.",
    });

    try app.listen(.{ .port = 8801 });
}

test {
    _ = @import("domain.zig");
    _ = @import("copy.zig");
    _ = @import("archive.zig");
    _ = @import("handlers.zig");
    _ = @import("intake.zig");
    _ = @import("settings.zig");
    _ = @import("wire.zig");
}
