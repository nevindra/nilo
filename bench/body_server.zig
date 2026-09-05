//! What a request body costs while it is arriving, with two controls beside it.
//!
//! `c.body()` used to take the announced `Content-Length` out of the request
//! arena before it read a byte, so a client that promised a megabyte and sent
//! one byte a minute held a megabyte for as long as it kept trickling. This
//! server is what puts a number on both halves of the change: what the growth
//! costs a body that arrives normally, and what a body that never finishes
//! holds while it does not.
//!
//! Four routes, each removing a layer from the one above:
//!
//! - `/health` — a constant `[]const u8`, no `Ctx`, no body. The floor, and
//!   the same route `bench/sql_server.zig` and `bench/fetch_server.zig` use
//!   for the same reason.
//! - `/drop` — a POST whose handler never asks for the body. nilo still reads
//!   it, to leave the connection clean for the next request, and it never
//!   holds it. The control that says how much of a reading is the *read*
//!   rather than the holding.
//! - `/echo` — a POST that calls `c.body()` and answers its length. The route
//!   the question is about.
//! - `/stream` — a POST that reads the same body through `c.bodyStream()` into
//!   a fixed buffer. The shape that never had the problem, so it is the floor
//!   the other one is trying to reach.
//!
//! ```
//! zig build -Doptimize=ReleaseFast bench-body-server
//! ./zig-out/bin/nilo-bench-body-server
//!
//! # what a body that arrives normally costs
//! ./bench/bench.sh   # after pointing it at a POST, or use bench/body_load.lua
//! wrk -t4 -c64 -d10s -s bench/body_load.lua http://127.0.0.1:8792/echo
//!
//! # what a body that never finishes holds, which is the number this exists for
//! python3 bench/slowloris.py --port 8792 --path /echo
//! ```

const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

/// The floor: no `Ctx`, no body, no allocation.
fn health() []const u8 {
    return "alive\n";
}

/// The body arrives and nobody asks for it. nilo discards it so the
/// connection is clean, which is a read and not a hold.
fn drop(c: *nilo.Ctx) !void {
    try c.sendText(200, "dropped\n");
}

/// The route the question is about: the whole body, in the request arena.
fn echo(c: *nilo.Ctx) !void {
    const body = try c.body();
    var buf: [32]u8 = undefined;
    try c.sendText(200, std.fmt.bufPrint(&buf, "{d}\n", .{body.view().len}) catch unreachable);
}

/// The same bytes through the reader that never allocated: the ceiling is the
/// buffer, and a client that stops sending holds only that.
fn streamed(c: *nilo.Ctx) !void {
    var incoming = try c.bodyStream();
    var buf: [16 * 1024]u8 = undefined;
    var seen: usize = 0;
    while (try incoming.read(&buf)) |part| seen += part.len;

    var out: [32]u8 = undefined;
    try c.sendText(200, std.fmt.bufPrint(&out, "{d}\n", .{seen}) catch unreachable);
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.get("/health", health);
    try app.post("/drop", drop);
    try app.post("/echo", echo);
    try app.post("/stream", streamed);

    // A port of its own, so this can run beside the other bench servers.
    try app.listen(.{ .port = 8792 });
}

test "the body routes are ordinary handlers" {
    try std.testing.expectEqualStrings("alive\n", health());
}
