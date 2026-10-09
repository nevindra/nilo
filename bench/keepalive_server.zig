//! Which executor a keep-alive connection lives on, and for how long.
//!
//! A connection is served, start to finish, by the executor it was dealt to
//! (ADR 199) and nothing ever closes a keep-alive connection from this side,
//! so a client that keeps one stays where it was put. This server is what
//! makes that visible: every answer names the OS thread that produced it, and
//! `/work` spends a chosen number of microseconds of CPU first, so a thread's
//! CPU time says how much of the load it carried.
//!
//! - `/tid`: the thread id, no work. The control.
//! - `/work/:us`: spin for `us` microseconds, then the thread id.
//!
//! `PORT`, `THREADS` and `MAX_REQUESTS` (connection cap, 0 = off) come from
//! the environment. `bench/keepalive.py` is the client.
//!
//! ```
//! zig build bench-keepalive-server -Dtarget=x86_64-linux-gnu
//! PORT=8801 THREADS=4 taskset -c 0-3 ./zig-out/bin/nilo-bench-keepalive-server
//! ```

const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn tid(c: *nilo.Ctx) !void {
    var buf: [16]u8 = undefined;
    try c.sendText(200, std.fmt.bufPrint(&buf, "{d}\n", .{std.os.linux.gettid()}) catch unreachable);
}

fn work(c: *nilo.Ctx, us: u32) !void {
    const until = nowNs() + @as(u64, us) * 1000;
    while (nowNs() < until) std.atomic.spinLoopHint();
    return tid(c);
}

fn envInt(init: std.process.Init, name: []const u8, default: u32) u32 {
    const text = init.minimal.environ.getPosix(name) orelse return default;
    return std.fmt.parseInt(u32, text, 10) catch default;
}

pub fn main(init: std.process.Init) !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.get("/tid", tid);
    try app.get("/work/:us", work);

    try app.listen(.{
        .port = @intCast(envInt(init, "PORT", 8801)),
        .threads = @intCast(envInt(init, "THREADS", 0)),
        .max_requests_per_connection = envInt(init, "MAX_REQUESTS", 0),
    });
}
