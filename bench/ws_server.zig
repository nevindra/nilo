//! What a WebSocket connection costs while nobody is typing.
//!
//! [ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md) measured
//! memory per idle connection for **HTTP** keep-alive and found two things: a
//! floor — 8,767 bytes then, 4,669 since
//! [ADR 0071](../docs/adr/0071-where-a-connection-waits-is-what-it-costs.md) —
//! and a handler that adds every byte of stack it ever touched. Neither number
//! was ever taken for a WebSocket, and the WebSocket path differs in one way
//! that should matter: a socket is parked somewhere the request loop's idle
//! release never reaches, so it should hold its 8 KB + 4 KB of connection
//! buffers where an idle HTTP connection holds neither.
//!
//! That is an argument. This is the measurement, and `bench/ws_idle.py` is
//! what drives it:
//!
//! ```
//! zig build bench-ws-server -Doptimize=ReleaseFast
//! python3 bench/ws_idle.py
//! ```
//!
//! ## Five routes, because a number needs something standing next to it
//!
//! - `/health` — HTTP, a constant `[]const u8`, no `Ctx`, no upgrade. The
//!   floor ADR 0063 already published, re-taken on this binary so the
//!   WebSocket rows are compared against a number from the same run rather
//!   than a number from another document.
//! - `/ws/small` — upgrade, the default 16 KiB ceiling, echo. The ordinary
//!   socket.
//! - `/ws/big` — the same asking for 64 KiB. Against `/ws/small` with the same
//!   small message, this asks whether *declaring* a big ceiling costs
//!   anything, which `VmRSS` says it should not: pages are counted when they
//!   are touched, and a 6-byte message touches one of them.
//! - `/ws/deep` — 64 KiB of stack touched once inside the loop, before the
//!   first `receive`. ADR 0063's `/deep/:id` control, on this path, and the
//!   one cost the framework still cannot give back: the frame holding it is
//!   live for as long as the loop is.
//! - `/ws/idle` — nothing is ever sent to it. What the handshake alone costs,
//!   with no message to touch anything.
//!
//! `IDLE_MS` sets `Options.idle_ms` and **defaults to 0 here, which is not the
//! framework's default of 30,000.** A ping every thirty seconds wakes every
//! fiber in the measurement and would be measuring the keepalive; 0 waits
//! forever, which is what a settled `VmRSS` reading needs. Set it to 30000 to
//! measure the keepalive on purpose.

const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

/// Read once in `main`. A global rather than a service because a service is a
/// pointer in a registry and this is a benchmark measuring bytes.
var idle_ms: u32 = 0;

/// The control, and the same handler `bench/sql_server.zig` uses for it: a
/// constant, no `Ctx`, no upgrade.
fn health() []const u8 {
    return "alive\n";
}

/// The ordinary socket: the loop from `examples/chat/main.zig` with the room
/// taken out, so what is left is the framing and nothing else. The buffer is
/// not here any more — it belongs to the executor and this socket borrows one
/// while a message is arriving (`http/scratch.zig`).
fn wsSmall(c: *nilo.Ctx) !void {
    return c.upgradeWith(echo, {}, .{ .idle_ms = idle_ms });
}

/// The loop all four routes share bar `/ws/deep`, which needs a stack of its
/// own to be the control it is.
fn echo(socket: *nilo.Socket) !void {
    while (try socket.receive()) |message| {
        try socket.send(message.kind, message.data);
    }
}

/// The same, asking for a ceiling sixteen times higher. Under the old shape
/// that was 64 KiB on the handler's stack for the life of the connection;
/// under this one it is a bigger buffer borrowed while a message is in flight,
/// and the two rows of the table say what the difference is worth.
fn wsBig(c: *nilo.Ctx) !void {
    return c.upgradeWith(echo, {}, .{ .idle_ms = idle_ms, .max_message = 64 * 1024 });
}

/// 64 KiB touched on the handler's own stack and then finished with. The
/// control that keeps the rest honest: it is the one cost the framework still
/// cannot give back, because the frame holding it stays live for as long as
/// the loop does (ADR 0063).
fn wsDeep(c: *nilo.Ctx) !void {
    return c.upgradeWith(deepEcho, {}, .{ .idle_ms = idle_ms });
}

fn deepEcho(socket: *nilo.Socket) !void {
    var pad: [64 * 1024]u8 = undefined;
    @memset(&pad, 0x5a);
    std.mem.doNotOptimizeAway(&pad);
    while (try socket.receive()) |message| {
        try socket.send(message.kind, message.data);
    }
}

/// Upgraded and then never spoken to. The floor: what the handshake leaves
/// resident before any message has borrowed anything.
fn wsIdle(c: *nilo.Ctx) !void {
    return c.upgradeWith(echo, {}, .{ .idle_ms = idle_ms });
}

/// `READ_BUFFER` and `WRITE_BUFFER`, which are the control on the whole
/// exercise: if an idle socket costs what it costs because it is holding the
/// connection's two buffers, then the number has to move a page for a page
/// when they are resized, and if it does not then the cause is somewhere else.
fn bytesFrom(init: std.process.Init, name: []const u8, default: usize) usize {
    const text = init.minimal.environ.getPosix(name) orelse return default;
    return std.fmt.parseInt(usize, text, 10) catch default;
}

pub fn main(init: std.process.Init) !void {
    if (init.minimal.environ.getPosix("IDLE_MS")) |text| {
        idle_ms = std.fmt.parseInt(u32, text, 10) catch 0;
    }

    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    // No logger and no CORS, for the reason `bench/main.zig` gives: anything
    // installed here is measured.
    try app.get("/health", health);
    try app.get("/ws/small", wsSmall);
    try app.get("/ws/big", wsBig);
    try app.get("/ws/deep", wsDeep);
    try app.get("/ws/idle", wsIdle);

    try app.listen(.{
        .port = 8789,
        .read_buffer = bytesFrom(init, "READ_BUFFER", 8 * 1024),
        .write_buffer = bytesFrom(init, "WRITE_BUFFER", 4 * 1024),
    });
}
