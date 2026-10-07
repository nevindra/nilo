//! The tests of a request body read through its pipe that need a server
//! actually running
//! ([ADR 260](../docs/adr/260-a-request-on-http2-runs-from-its-headers.md)).
//!
//! `h2conn.zig`'s own tests feed a connection one buffer, so a client in them
//! cannot be *held* by a window: whatever it wrote, it wrote before the server
//! looked. What flow control is for, a client that sends faster than the
//! handler reads being made to wait, needs a client that reads the server's
//! WINDOW_UPDATEs and sends only what they allow, against a handler that
//! stops reading. That is what these are.
//!
//! The server is the second listener, on a unix socket, as in
//! `grpc_live.zig`, whose helpers these use. The client is frames written by
//! hand over std's own socket. Compiled only into a build with HTTP/2 in it.

const std = @import("std");
const nilo = @import("http.zig");
const h2 = @import("h2.zig");
const hpack = @import("hpack.zig");
const live = @import("grpc_live.zig");
const bulkhead = @import("bulkhead.zig");

const testing = std.testing;

/// An allocator that says how much it has handed out and how much it had out
/// at most, from any thread: what a connection holds is the difference between
/// two readings of it.
const Meter = struct {
    child: std.mem.Allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *Meter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn grew(self: *Meter, by: usize) void {
        const now = self.live.fetchAdd(by, .acq_rel) + by;
        _ = self.peak.fetchMax(now, .acq_rel);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(ctx));
        const got = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.grew(len);
        return got;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Meter = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ra)) return false;
        self.moved(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(ctx));
        const got = self.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.moved(memory.len, new_len);
        return got;
    }

    fn moved(self: *Meter, from: usize, to: usize) void {
        if (to > from) self.grew(to - from) else _ = self.live.fetchSub(from - to, .acq_rel);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Meter = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
        _ = self.live.fetchSub(memory.len, .acq_rel);
    }

    /// Start counting the peak from what is out now.
    fn mark(self: *Meter) usize {
        const now = self.live.load(.acquire);
        self.peak.store(now, .release);
        return now;
    }
};

var gate_open: std.atomic.Value(bool) = .init(false);
var handler_woke: std.atomic.Value(bool) = .init(false);
var handler_took: std.atomic.Value(usize) = .init(0);

fn reset() void {
    gate_open.store(false, .release);
    handler_woke.store(false, .release);
    handler_took.store(0, .release);
}

/// A handler that is slower than the client: it does not look at its body
/// until the test says so, and then reads it in small pieces.
fn hold(c: *nilo.Ctx) anyerror!void {
    var incoming = try c.bodyStream();
    for (0..1_000) |_| {
        if (gate_open.load(.acquire)) break;
        try nilo.sleep(5);
    }
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (try incoming.read(&buf)) |part| total += part.len;
    handler_took.store(total, .release);
    var text: [20]u8 = undefined;
    try c.sendText(200, std.fmt.bufPrint(&text, "{d}", .{total}) catch unreachable);
}

/// A handler that waits for a body that does not come.
fn wait(c: *nilo.Ctx) anyerror!void {
    const got = c.body() catch |err| {
        handler_woke.store(true, .release);
        return err;
    };
    try c.sendText(200, got.view());
}

/// What the client has seen, and what it may still send.
const Wire = struct {
    a: std.mem.Allocator,
    decoder: hpack.Decoder,
    conn_window: i64 = h2.default_window,
    stream_window: i64 = h2.default_window,
    /// Increments the server gave the stream, which are what the handler's
    /// reads earned.
    stream_credit: i64 = 0,
    status: ?u16 = null,
    body: std.ArrayList(u8) = .empty,
    finished: bool = false,
    reset_by_server: bool = false,
    pongs: u32 = 0,

    fn init(a: std.mem.Allocator) Wire {
        return .{ .a = a, .decoder = hpack.Decoder.init(a) };
    }

    fn deinit(self: *Wire) void {
        self.decoder.deinit();
        self.body.deinit(self.a);
    }

    /// Read what the server has sent for `wait_ms`, or until it has nothing
    /// more at the moment.
    fn pump(self: *Wire, r: *std.Io.Reader, w: *std.Io.Writer, fd: std.posix.fd_t, wait_ms: i32) !void {
        while (true) {
            if (r.bufferedLen() == 0) {
                var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
                if ((try std.posix.poll(&fds, wait_ms)) == 0) return;
            }
            const head = h2.Header.parse(try r.takeArray(h2.header_len));
            const payload = try r.take(head.len);
            switch (head.type) {
                .settings => if (!head.has(h2.Flags.ack)) {
                    try h2.writeSettingsAck(w);
                    try w.flush();
                },
                .window_update => {
                    const n: i64 = std.mem.readInt(u32, payload[0..4], .big) & 0x7fff_ffff;
                    if (head.stream == 0) self.conn_window += n else {
                        self.stream_window += n;
                        self.stream_credit += n;
                    }
                },
                .headers => {
                    var fields: std.ArrayList(hpack.Field) = .empty;
                    defer fields.deinit(self.a);
                    var scratch: std.heap.ArenaAllocator = .init(self.a);
                    defer scratch.deinit();
                    _ = try self.decoder.decode(payload, scratch.allocator(), &fields, 1 << 16);
                    for (fields.items) |f| if (std.mem.eql(u8, f.name, ":status")) {
                        self.status = try std.fmt.parseInt(u16, f.value, 10);
                    };
                    if (head.has(h2.Flags.end_stream)) self.finished = true;
                },
                .data => {
                    try self.body.appendSlice(self.a, payload);
                    if (head.has(h2.Flags.end_stream)) self.finished = true;
                },
                .rst_stream => self.reset_by_server = true,
                .ping => if (head.has(h2.Flags.ack)) {
                    self.pongs += 1;
                },
                .goaway => {
                                    return error.SentAway;
                },
                else => {},
            }
        }
    }
};

fn writeOpenRequest(w: *std.Io.Writer, stream: u31, path: []const u8) !void {
    var block_buf: [256]u8 = undefined;
    var block: std.Io.Writer = .fixed(&block_buf);
    // This client has read the server's table size of 0 and acknowledged it,
    // so its first block says so (RFC 7541 §4.2).
    try block.writeByte(0x20);
    try hpack.writeLiteral(&block, ":method", "POST");
    try hpack.writeInt(&block, 0x80, 7, 6); // :scheme http
    try hpack.writeLiteral(&block, ":path", path);
    try hpack.writeLiteral(&block, ":authority", "localhost");
    try h2.writeHeaderBlock(w, stream, block.buffered(), false, h2.default_max_frame);
}

/// One DATA frame of `n` bytes of `fill`, `end` ending the stream.
fn writeData(w: *std.Io.Writer, stream: u31, n: usize, end: bool) !void {
    const chunk = [_]u8{'u'} ** 16_000;
    try h2.writeHeader(w, n, .data, if (end) h2.Flags.end_stream else 0, stream);
    try w.writeAll(chunk[0..n]);
}

test "an upload faster than its handler is held to its window, stalls, and then completes" {
    live.hush();
    reset();
    var meter: Meter = .{ .child = std.heap.smp_allocator };
    const gpa = meter.allocator();
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var where = try live.SocketDir.init(std.heap.smp_allocator, "h2pipe-hold.sock");
    defer where.deinit(std.heap.smp_allocator);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.post("/hold", hold);

    var serving: live.Serving = .{ .app = &app, .path = where.path };
    const thread = try std.Thread.spawn(.{}, live.Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    try serving.waitUntilUp(io);

    var stream = try live.connect(io, where.path);
    defer stream.close(io);
    var out_buf: [32 * 1024]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    var in_buf: [32 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    const w = &writer.interface;
    const fd = stream.socket.handle;

    var wire = Wire.init(std.heap.smp_allocator);
    defer wire.deinit();
    try w.writeAll(h2.preface);
    try h2.writeSettings(w, &.{});
    try w.flush();
    try wire.pump(&reader.interface, w, fd, 100);

    const before = meter.mark();
    try writeOpenRequest(w, 1, "/hold");

    // Sent faster than the handler reads: everything the windows allow, and
    // then the client has to stop.
    const total: usize = 8 * 1024 * 1024;
    var sent: usize = 0;
    const stall_deadline = bulkhead.monotonicNanos() + 400 * std.time.ns_per_ms;
    while (bulkhead.monotonicNanos() < stall_deadline) {
        const room: i64 = @min(wire.conn_window, wire.stream_window);
        if (room > 0) {
            const n: usize = @intCast(@min(@as(i64, 16_000), room));
            try writeData(w, 1, n, false);
            try w.flush();
            sent += n;
            wire.conn_window -= @intCast(n);
            wire.stream_window -= @intCast(n);
        }
        try wire.pump(&reader.interface, w, fd, 20);
    }
    // The handler has read nothing, so the stream was given nothing back:
    // what was sent is the window, and it was held to it.
    try testing.expectEqual(@as(usize, h2.default_window), sent);
    try testing.expectEqual(@as(i64, 0), wire.stream_credit);
    try testing.expectEqual(@as(i64, 0), wire.stream_window);
    const held = meter.live.load(.acquire) -| before;
    try testing.expect(held <= h2.default_window + 16 * 1024);

    // The handler reads, and the rest flows as its reads earn the window.
    gate_open.store(true, .release);
    while (sent < total) {
        const room: i64 = @min(wire.conn_window, wire.stream_window);
        if (room > 0) {
            const n: usize = @intCast(@min(@as(i64, @intCast(total - sent)), @min(@as(i64, 16_000), room)));
            try writeData(w, 1, n, sent + n == total);
            try w.flush();
            sent += n;
            wire.conn_window -= @intCast(n);
            wire.stream_window -= @intCast(n);
        } else try wire.pump(&reader.interface, w, fd, 1_000);
        if (wire.reset_by_server) return error.Reset;
    }
    while (!wire.finished) try wire.pump(&reader.interface, w, fd, 3_000);

    try testing.expectEqual(@as(?u16, 200), wire.status);
    try testing.expectEqual(total, handler_took.load(.acquire));
    var expected: [20]u8 = undefined;
    try testing.expectEqualStrings(std.fmt.bufPrint(&expected, "{d}", .{total}) catch unreachable, wire.body.items);
    // An upload of eight megabytes never held more than a few windows of it
    // in the process, at its peak.
    const peak = meter.peak.load(.acquire) -| before;
    try testing.expect(peak <= 3 * h2.default_window);
    if (std.c.getenv("NILO_UPLOAD_REPORT") != null)
        std.debug.print("\nupload of {d} bytes through a stalled reader: held {d} while stalled, peak {d} bytes above idle\n", .{ total, held, peak });
}

test "a stream reset, and a connection closed, while the handler waits for the body wake it and leave nothing behind" {
    live.hush();
    reset();
    var debug: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug.allocator();
    defer testing.expect(debug.deinit() == .ok) catch @panic("a request body left memory behind");
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var where = try live.SocketDir.init(std.heap.smp_allocator, "h2pipe-reset.sock");
    defer where.deinit(std.heap.smp_allocator);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.post("/wait", wait);

    var serving: live.Serving = .{ .app = &app, .path = where.path };
    const thread = try std.Thread.spawn(.{}, live.Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    try serving.waitUntilUp(io);

    // The stream is reset: the handler wakes, and the connection serves on.
    {
        var stream = try live.connect(io, where.path);
        defer stream.close(io);
        var out_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &out_buf);
        var in_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &in_buf);
        const w = &writer.interface;
        var wire = Wire.init(std.heap.smp_allocator);
        defer wire.deinit();
        try w.writeAll(h2.preface);
        try h2.writeSettings(w, &.{});
        try writeOpenRequest(w, 1, "/wait");
        try writeData(w, 1, 100, false);
        try w.flush();
        try wire.pump(&reader.interface, w, stream.socket.handle, 150);
        try testing.expect(!handler_woke.load(.acquire));
        try h2.writeRstStream(w, 1, .cancel);
        try h2.writeHeader(w, 8, .ping, 0, 0);
        try w.writeAll("12345678");
        try w.flush();
        for (0..50) |_| {
            if (wire.pongs > 0 and handler_woke.load(.acquire)) break;
            try wire.pump(&reader.interface, w, stream.socket.handle, 100);
        }
        try testing.expect(handler_woke.load(.acquire));
        try testing.expectEqual(@as(u32, 1), wire.pongs);
    }

    // The connection is closed under a handler that is still waiting.
    handler_woke.store(false, .release);
    {
        var stream = try live.connect(io, where.path);
        var out_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &out_buf);
        const w = &writer.interface;
        try w.writeAll(h2.preface);
        try h2.writeSettings(w, &.{});
        try writeOpenRequest(w, 1, "/wait");
        try writeData(w, 1, 100, false);
        try w.flush();
        std.Io.sleep(io, .fromMilliseconds(150), .awake) catch {};
        try testing.expect(!handler_woke.load(.acquire));
        stream.close(io);
        for (0..100) |_| {
            if (handler_woke.load(.acquire)) break;
            std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        }
        try testing.expect(handler_woke.load(.acquire));
    }
}
