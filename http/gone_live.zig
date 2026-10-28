//! A client that leaves while its handler waits, seen over real sockets
//! ([ADR 287](../docs/adr/287-a-handler-can-ask-whether-its-client-is-still-there.md)).
//!
//! What an in-memory buffer cannot show is the thing this feature reads: the
//! kernel's account of the peer's end of a socket. A `close()`, a reset and a
//! `shutdown(SHUT_WR)` look the same to a reader of bytes and different to
//! `poll(2)` with `POLLRDHUP`, so each is done here to a real connection
//! while a handler is parked, and the test asserts what the handler learned
//! and how soon.
//!
//! **Every wait is bounded and the giving-up path sets something**: a
//! handler that never learns leaves its flag unset and the test fails at its
//! bound, and the server's handlers sleep ten seconds at most, so a test
//! that stops early never waits one out. Servers are `testing.Live`, whose
//! listener is started with `io.concurrent` (ADR 056, ADR 244).

const std = @import("std");
const builtin = @import("builtin");
const nilo = @import("http.zig");
const bulkhead = @import("bulkhead.zig");

const testing = std.testing;

const Linger = extern struct { onoff: i32, linger: i32 };

/// What the handler under test saw. Atomics, because the handler runs on one
/// of the server's threads and the assertions on the test's.
var entered: std.atomic.Value(bool) = .init(false);
var finished: std.atomic.Value(bool) = .init(false);
/// 0 nothing yet, 1 `.elapsed`, 2 `.gone`.
var outcome: std.atomic.Value(u8) = .init(0);
var ended_ns: std.atomic.Value(u64) = .init(0);
var presence_during: std.atomic.Value(u8) = .init(255);
var presence_after: std.atomic.Value(u8) = .init(255);
var units: std.atomic.Value(u32) = .init(0);

fn reset() void {
    entered.store(false, .release);
    finished.store(false, .release);
    outcome.store(0, .release);
    ended_ns.store(0, .release);
    presence_during.store(255, .release);
    presence_after.store(255, .release);
    units.store(0, .release);
}

fn record(w: bulkhead.Waited) void {
    outcome.store(if (w == .gone) 2 else 1, .release);
    ended_ns.store(bulkhead.monotonicNanos(), .release);
}

/// Sleeps ten seconds unless the client goes.
fn sleeper(c: *nilo.Ctx) anyerror!void {
    entered.store(true, .release);
    const w = try c.sleepUnlessGone(10_000);
    record(w);
    presence_after.store(@intFromEnum(c.presence()), .release);
    finished.store(true, .release);
    if (w == .gone) return error.ClientGone;
    try c.sendText(200, "late");
}

/// Sleeps 400 ms unless the client goes, and answers.
fn brief(c: *nilo.Ctx) anyerror!void {
    entered.store(true, .release);
    std.Io.sleep(c.io(), .fromMilliseconds(100), .awake) catch {};
    presence_during.store(@intFromEnum(c.presence()), .release);
    const w = try c.sleepUnlessGone(300);
    record(w);
    presence_after.store(@intFromEnum(c.presence()), .release);
    finished.store(true, .release);
    try c.sendText(200, "answered");
}

fn feed(c: *nilo.Ctx) anyerror!void {
    var events = try c.events();
    entered.store(true, .release);
    while (events.live()) try events.sleep(10_000);
    outcome.store(2, .release);
    ended_ns.store(bulkhead.monotonicNanos(), .release);
    finished.store(true, .release);
}

fn pause(ms: u64) void {
    const ts: std.os.linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = std.os.linux.nanosleep(&ts, null);
}

/// The kind of function the feature is for: a long loop on a worker, polling
/// between units of work.
fn search() u32 {
    var n: u32 = 0;
    while (n < 1_000) : (n += 1) {
        if (nilo.gone()) return n;
        pause(5);
    }
    return n;
}

fn searcher(c: *nilo.Ctx) anyerror!void {
    entered.store(true, .release);
    const n = nilo.blocking(search, .{});
    units.store(n, .release);
    ended_ns.store(bulkhead.monotonicNanos(), .release);
    finished.store(true, .release);
    try c.sendText(200, "done");
}

fn waitFor(flag: *const std.atomic.Value(bool), ms: u64) bool {
    var waited: u64 = 0;
    while (waited < ms) : (waited += 5) {
        if (flag.load(.acquire)) return true;
        pause(5);
    }
    return flag.load(.acquire);
}

fn connect(live: *nilo.testing.Live) !std.Io.net.Stream {
    const io = live.clientIo();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(live.port) };
    return address.connect(io, .{ .mode = .stream });
}

fn send(stream: std.Io.net.Stream, io: std.Io, bytes: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = stream.writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn shutdownWrite(stream: std.Io.net.Stream) void {
    _ = std.os.linux.shutdown(stream.socket.handle, std.os.linux.SHUT.WR);
}

fn resetOnClose(stream: std.Io.net.Stream) void {
    const linger: Linger = .{ .onoff = 1, .linger = 0 };
    _ = std.os.linux.setsockopt(stream.socket.handle, std.os.linux.SOL.SOCKET, std.os.linux.SO.LINGER, std.mem.asBytes(&linger), @sizeOf(Linger));
}

fn since(t_ns: u64) u64 {
    return (ended_ns.load(.acquire) -| t_ns) / std.time.ns_per_ms;
}

fn start(app: *nilo.App) !*nilo.testing.Live {
    std.testing.log_level = .err;
    return nilo.testing.Live.start(std.heap.smp_allocator, app, .{ .threads = 1 });
}

test "a closed tab on a keep-alive request is learned within a bound" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    reset();
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();
    try app.get("/sleep", sleeper);
    const live = try start(&app);
    defer live.stop() catch {};
    const io = live.clientIo();

    var stream = try connect(live);
    try send(stream, io, "GET /sleep HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(waitFor(&entered, 3_000));
    pause(100);
    const left = bulkhead.monotonicNanos();
    stream.close(io);

    try testing.expect(waitFor(&finished, 3_000));
    try testing.expectEqual(@as(u8, 2), outcome.load(.acquire));
    // A hang-up is seen as it arrives, not at the next write or timer.
    try testing.expect(since(left) < 1_000);
    try testing.expectEqual(@as(u8, @intFromEnum(nilo.Presence.gone)), presence_after.load(.acquire));
}

test "a reset is gone at once" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    reset();
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();
    try app.get("/sleep", sleeper);
    const live = try start(&app);
    defer live.stop() catch {};
    const io = live.clientIo();

    var stream = try connect(live);
    try send(stream, io, "GET /sleep HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    try testing.expect(waitFor(&entered, 3_000));
    pause(100);
    const left = bulkhead.monotonicNanos();
    resetOnClose(stream);
    stream.close(io);

    try testing.expect(waitFor(&finished, 3_000));
    try testing.expectEqual(@as(u8, 2), outcome.load(.acquire));
    try testing.expect(since(left) < 1_000);
}

test "a client that half-closed after Connection: close is waiting, and still gets its answer" {
    // The hazard the todo entry names: a read-side EOF is not a client
    // leaving. It sent everything, said it was done, and reads the answer.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    reset();
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();
    try app.get("/brief", brief);
    const live = try start(&app);
    defer live.stop() catch {};
    const io = live.clientIo();

    var stream = try connect(live);
    defer stream.close(io);
    try send(stream, io, "GET /brief HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    shutdownWrite(stream);

    var in_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var whole: std.Io.Writer.Allocating = .init(testing.allocator);
    defer whole.deinit();
    _ = reader.interface.streamRemaining(&whole.writer) catch {};

    try testing.expect(std.mem.startsWith(u8, whole.written(), "HTTP/1.1 200"));
    try testing.expect(std.mem.endsWith(u8, whole.written(), "answered"));
    try testing.expectEqual(@as(u8, @intFromEnum(nilo.Presence.half_closed)), presence_during.load(.acquire));
    // The sleep ran its course: a half-close did not end it.
    try testing.expectEqual(@as(u8, 1), outcome.load(.acquire));
}

test "a client that half-closes after a keep-alive request is gone, which is the rule" {
    // ADR 287: a FIN from a client that did not say it was finished is a
    // closed tab. The same bytes with Connection: close are the test above.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    reset();
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();
    try app.get("/sleep", sleeper);
    const live = try start(&app);
    defer live.stop() catch {};
    const io = live.clientIo();

    var stream = try connect(live);
    defer stream.close(io);
    try send(stream, io, "GET /sleep HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(waitFor(&entered, 3_000));
    pause(100);
    const left = bulkhead.monotonicNanos();
    shutdownWrite(stream);
    try testing.expect(waitFor(&finished, 3_000));
    try testing.expectEqual(@as(u8, 2), outcome.load(.acquire));
    try testing.expect(since(left) < 1_000);
}

test "bytes sent behind the request do not hide a hang-up" {
    // `MSG_PEEK` would return the pipelined bytes and say nothing of the
    // FIN behind them; `POLLRDHUP` is not masked. The bytes arrive while the
    // handler sleeps, which is the case the armed poll cannot see, so the
    // hang-up is found by the slice, within a second and a little.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    reset();
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();
    try app.get("/sleep", sleeper);
    const live = try start(&app);
    defer live.stop() catch {};
    const io = live.clientIo();

    var stream = try connect(live);
    try send(stream, io, "GET /sleep HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(waitFor(&entered, 3_000));
    pause(100);
    try send(stream, io, "GET /sleep HTTP/1.1\r\nHost: t\r\n\r\n");
    pause(50);
    const left = bulkhead.monotonicNanos();
    stream.close(io);
    try testing.expect(waitFor(&finished, 4_000));
    try testing.expectEqual(@as(u8, 2), outcome.load(.acquire));
    try testing.expect(since(left) < 2_500);
}

test "an event stream whose client closed ends at the next wake, not the next write" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    reset();
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();
    try app.get("/feed", feed);
    const live = try start(&app);
    defer live.stop() catch {};
    const io = live.clientIo();

    var stream = try connect(live);
    // A half-close on a response that never ends is leaving, even from a
    // client that said Connection: close.
    try send(stream, io, "GET /feed HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    try testing.expect(waitFor(&entered, 3_000));
    pause(100);
    const left = bulkhead.monotonicNanos();
    stream.close(io);
    try testing.expect(waitFor(&finished, 3_000));
    try testing.expect(since(left) < 1_000);
}

test "a function on a blocking worker learns the client left, and one outside a request is never gone" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try testing.expect(!nilo.gone());

    reset();
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();
    try app.get("/search", searcher);
    const live = try start(&app);
    defer live.stop() catch {};
    const io = live.clientIo();

    var stream = try connect(live);
    try send(stream, io, "GET /search HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(waitFor(&entered, 3_000));
    pause(100);
    const left = bulkhead.monotonicNanos();
    stream.close(io);
    try testing.expect(waitFor(&finished, 5_000));
    // The worker stopped long before its thousand units (five seconds), and
    // within a poll or two of the abort.
    try testing.expect(units.load(.acquire) < 100);
    try testing.expect(since(left) < 500);
}

test "asking whether the client is there adds nothing to what a connection holds" {
    // ADR 287: a route that does not ask pays nothing, and that includes the
    // frame of a connection that is only waiting for its next request
    // (ADR 062). The question is the kernel's, asked when asked, so neither
    // struct gained a field. The numbers are those of the commit before,
    // read off `@sizeOf` there (bench/result/http.md).
    // Debug and ReleaseSafe carry the loop's own list-membership checks in
    // a completion, so the figure is for the modes the suite runs in.
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    // `Wake` holds the loop's completion, whose size is the backend's:
    // io_uring and epoll on Linux, kqueue on macOS.
    const wake: usize = switch (builtin.os.tag) {
        .linux => 528,
        .macos => 472,
        else => return error.SkipZigTest,
    };
    try testing.expectEqual(wake, @sizeOf(@import("engine/zio.zig").Wake));
    try testing.expectEqual(@as(usize, 328), @sizeOf(@import("fail.zig").InFlight));
}
