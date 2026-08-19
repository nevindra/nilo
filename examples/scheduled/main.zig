//! Work that is not a request. `zig build run-scheduled`, then
//! `curl localhost:8787/hits` a few times and watch the log summarise every
//! five seconds. Ctrl-C and the summary stops with the server.
//!
//! There are two ways to start a fiber of your own and the difference is
//! *when*, not what. `nilo.spawn` is now, and needs a server already running
//! — a handler calling it is the case it was built for. `app.spawn` is "when
//! there is one", registered beside the routes, which is what a program that
//! wants a ticker from the moment it serves actually needs.

const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;

/// Something for the ticker to have an opinion about.
///
/// Handlers really do run at the same time on several threads, so shared
/// mutable state needs a lock — and `nilo.Mutex` rather than
/// `std.Thread.Mutex`, because blocking the thread also stops every other
/// request sharing it, possibly including the one holding the lock.
const Hits = struct {
    lock: nilo.Mutex = .{},
    total: u64 = 0,
    /// What `total` was at the last summary, so the ticker can report the
    /// difference rather than the running total.
    reported: u64 = 0,

    fn record(self: *Hits) !void {
        try self.lock.lock();
        defer self.lock.unlock();
        self.total += 1;
    }

    fn sinceLast(self: *Hits) !u64 {
        try self.lock.lock();
        defer self.lock.unlock();
        const delta = self.total - self.reported;
        self.reported = self.total;
        return delta;
    }
};

/// The shape of every one of these: a loop around a wait that can say stop.
///
/// `nilo.sleep` parks this fiber without holding the thread it is on, so the
/// other requests sharing that thread carry on. It fails with
/// `error.Canceled` when the shutdown grace period ends — the fiber is owned
/// by the server exactly as a connection is — and that is the signal to
/// return. Nothing else ends this loop.
///
/// It may not fail, because there is no request to answer and nobody to
/// answer it: an error has nowhere to go but the log.
fn summarise(hits: *Hits) void {
    while (true) {
        nilo.sleep(5_000) catch return;

        const delta = hits.sinceLast() catch return;
        // A `std.log` call brings its format machinery onto the stack of
        // whatever fiber it is inlined into, and a suspended fiber holds its
        // stack at the high-water mark for as long as it lives (ADR 0071).
        // Here that is one fiber for the whole process rather than one per
        // connection, which is the difference between a cost and a budget.
        std.log.info("{d} request(s) in the last five seconds", .{delta});
    }
}

fn hit(hits: *Hits) ![]const u8 {
    try hits.record();
    return "counted\n";
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    var hits: Hits = .{};
    try app.provide(&hits);

    try app.get("/hits", hit);

    // Registered, not started. There is no server yet — `nilo.spawn` here
    // would answer `error.NoServer`, correctly — so the App remembers it and
    // starts it once the port is taken and before the first connection is
    // accepted.
    try app.spawn(summarise, .{&hits});

    try app.listen(.{});
}

test "the summary reports the difference, and reports nothing twice" {
    // No lock is taken here, because nothing else is running: this is the
    // arithmetic on its own, which is the half of a ticker worth a test
    // without a server. The half that needs one is held by `http/live.zig`.
    var hits: Hits = .{ .total = 7 };
    try std.testing.expectEqual(@as(u64, 7), hits.total - hits.reported);

    hits.reported = hits.total;
    try std.testing.expectEqual(@as(u64, 0), hits.total - hits.reported);
}
