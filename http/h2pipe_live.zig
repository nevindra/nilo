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
/// What a client reads before it gives the window back.
const update_batch: usize = 32 * 1024;

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
    /// Give the server back every DATA byte it sends as it arrives, as a
    /// client that reads an answer does, so its windows never close.
    owed_conn: usize = 0,
    owed_stream: [8]usize = [_]usize{0} ** 8,
    autowindow: bool = false,
    /// Keep the bytes of every DATA frame in `body`. A test that counts them
    /// by stream does not need them.
    keep_body: bool = true,
    /// Per stream, for a client with several: what came back for each, and
    /// in which order the streams ended.
    seen: [8]Seen = [_]Seen{.{}} ** 8,
    order: u32 = 0,
    /// The first of streams 1, 3 and 5 to end, and what every stream had
    /// delivered at that moment.
    first_end: u31 = 0,
    first_end_bytes: [8]usize = [_]usize{0} ** 8,
    /// The error code of the GOAWAY that ended a `pump`.
    goaway_code: ?u32 = null,
    /// A client that reads slowly: this long after each DATA frame.
    slow_ms: u32 = 0,

    const Seen = struct {
        status: ?u16 = null,
        bytes: usize = 0,
        ended_at: u32 = 0,
        /// What stream 1 had delivered when this one ended.
        other_bytes_then: usize = 0,
        reset: bool = false,
    };

    fn ends(self: *Wire, stream: u31) void {
        if (stream >= self.seen.len) return;
        self.order += 1;
        self.seen[stream].ended_at = self.order;
        self.seen[stream].other_bytes_then = self.seen[1].bytes;
        if (self.first_end == 0 and stream != 7) {
            self.first_end = stream;
            for (&self.first_end_bytes, self.seen) |*to, from| to.* = from.bytes;
        }
    }

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
                    // The arena owns the list's memory as well as the strings.
                    var scratch: std.heap.ArenaAllocator = .init(self.a);
                    defer scratch.deinit();
                    _ = try self.decoder.decode(payload, scratch.allocator(), &fields, 1 << 16);
                    for (fields.items) |f| if (std.mem.eql(u8, f.name, ":status")) {
                        self.status = try std.fmt.parseInt(u16, f.value, 10);
                        if (head.stream < self.seen.len) self.seen[head.stream].status = self.status;
                    };
                    if (head.has(h2.Flags.end_stream)) {
                        self.finished = true;
                        self.ends(head.stream);
                    }
                },
                .data => {
                    if (self.slow_ms != 0) bulkhead.sleep(self.slow_ms) catch {};
                    if (self.keep_body) try self.body.appendSlice(self.a, payload);
                    if (head.stream < self.seen.len) self.seen[head.stream].bytes += payload.len;
                    if (head.has(h2.Flags.end_stream)) {
                        self.finished = true;
                        self.ends(head.stream);
                    }
                    if (self.autowindow and payload.len > 0 and head.stream < self.seen.len) {
                        // Given back in batches, as a client does: a window
                        // update for every frame is a flood of small writes.
                        self.owed_conn += payload.len;
                        self.owed_stream[head.stream] += payload.len;
                        if (self.owed_conn >= update_batch) {
                            try h2.writeWindowUpdate(w, 0, @intCast(self.owed_conn));
                            self.owed_conn = 0;
                        }
                        if (self.owed_stream[head.stream] >= update_batch) {
                            try h2.writeWindowUpdate(w, head.stream, @intCast(self.owed_stream[head.stream]));
                            self.owed_stream[head.stream] = 0;
                        }
                        try w.flush();
                    }
                },
                .rst_stream => {
                    self.reset_by_server = true;
                    if (head.stream < self.seen.len) self.seen[head.stream].reset = true;
                },
                .ping => if (head.has(h2.Flags.ack)) {
                    self.pongs += 1;
                },
                .goaway => {
                    self.goaway_code = std.mem.readInt(u32, payload[4..8], .big);
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

// ---- an answer written in pieces, through the outbound pipe (stage 6.2) ----

var stalled_failed: std.atomic.Value(bool) = .init(false);
var live_dir: ?*bulkhead.Dir = null;
var huge_bytes: []const u8 = &.{};

fn patternByte(i: usize) u8 {
    return @intCast(i % 251);
}

const big_len: usize = 4 * 1024 * 1024;

/// Four megabytes of a pattern, four kilobytes at a time.
fn bigStream(c: *nilo.Ctx) anyerror!void {
    var out = try c.stream(200, "application/octet-stream");
    var chunk: [4096]u8 = undefined;
    var at: usize = 0;
    while (at < big_len) {
        for (&chunk, 0..) |*b, i| b.* = patternByte(at + i);
        out.writeAll(&chunk) catch |err| {
            stalled_failed.store(true, .release);
            return err;
        };
        at += chunk.len;
    }
    try out.finish();
}

fn pong(c: *nilo.Ctx) anyerror!void {
    try c.sendText(200, "pong");
}

/// One slice of eight megabytes, which is one piece lent whole.
fn hugePiece(c: *nilo.Ctx) anyerror!void {
    var out = try c.stream(200, "application/octet-stream");
    try out.writeAll(huge_bytes);
    try out.finish();
}

fn smallStream(c: *nilo.Ctx) anyerror!void {
    var out = try c.stream(200, "text/plain");
    try out.writeAll("small");
    try out.finish();
}

fn bigFile(c: *nilo.Ctx) anyerror!void {
    const file = try live_dir.?.openFile("big.bin");
    return c.sendFile(.{ .file = file, .content_type = "application/octet-stream" });
}

fn writeGet(w: *std.Io.Writer, stream: u31, path: []const u8) !void {
    var block_buf: [256]u8 = undefined;
    var block: std.Io.Writer = .fixed(&block_buf);
    try block.writeByte(0x20);
    try hpack.writeInt(&block, 0x80, 7, 2); // :method GET
    try hpack.writeInt(&block, 0x80, 7, 6); // :scheme http
    try hpack.writeLiteral(&block, ":path", path);
    try hpack.writeLiteral(&block, ":authority", "localhost");
    try h2.writeHeaderBlock(w, stream, block.buffered(), true, h2.default_max_frame);
}

test "a large streamed answer and a file reach a client that reads them, byte for byte, in frames" {
    live.hush();
    reset();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var where = try live.SocketDir.init(gpa, "h2pipe-out.sock");
    defer where.deinit(gpa);

    const file_len: usize = 8 * 1024 * 1024;
    {
        const bytes = try gpa.alloc(u8, file_len);
        defer gpa.free(bytes);
        for (bytes, 0..) |*b, i| b.* = patternByte(i);
        try where.tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = bytes });
    }
    var dir_buf: [128]u8 = undefined;
    var dir = try bulkhead.Dir.open(try where.tmp.path(&dir_buf, ""));
    defer dir.close();
    live_dir = &dir;
    defer live_dir = null;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/stream", bigStream);
    try app.get("/file", bigFile);

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
    var in_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    const w = &writer.interface;
    const fd = stream.socket.handle;

    var wire = Wire.init(gpa);
    defer wire.deinit();
    wire.autowindow = true;
    try w.writeAll(h2.preface);
    try h2.writeSettings(w, &.{});
    try w.flush();
    try wire.pump(&reader.interface, w, fd, 100);

    try writeGet(w, 1, "/stream");
    try writeGet(w, 3, "/file");
    try w.flush();
    const until = bulkhead.monotonicNanos() + 20 * std.time.ns_per_s;
    while ((wire.seen[1].ended_at == 0 or wire.seen[3].ended_at == 0) and bulkhead.monotonicNanos() < until)
        try wire.pump(&reader.interface, w, fd, 500);

    try testing.expectEqual(@as(?u16, 200), wire.seen[1].status);
    try testing.expectEqual(@as(?u16, 200), wire.seen[3].status);
    try testing.expectEqual(big_len, wire.seen[1].bytes);
    try testing.expectEqual(file_len, wire.seen[3].bytes);
    // The two answers were interleaved on one connection, so their bytes are
    // not told apart in `body`: what each carried is checked by its length,
    // and the pattern by the sum of both, which only the right bytes make.
    var sum: u64 = 0;
    for (wire.body.items) |b| sum += b;
    var expected: u64 = 0;
    for (0..big_len) |i| expected += patternByte(i);
    for (0..file_len) |i| expected += patternByte(i);
    try testing.expectEqual(expected, sum);
    try testing.expect(!wire.reset_by_server);
}

test "a client that stops reading is cut off at the write deadline, its stream reset, and the connection serves the next" {
    live.hush();
    reset();
    stalled_failed.store(false, .release);
    var debug: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug.allocator();
    defer testing.expect(debug.deinit() == .ok) catch @panic("a streamed answer left memory behind");
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var where = try live.SocketDir.init(gpa, "h2pipe-stalled.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/stream", bigStream);
    try app.get("/pong", pong);

    var serving: live.Serving = .{ .app = &app, .path = where.path, .write_timeout_ms = 400 };
    const thread = try std.Thread.spawn(.{}, live.Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    try serving.waitUntilUp(io);

    var stream = try live.connect(io, where.path);
    defer stream.close(io);
    var out_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    var in_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    const w = &writer.interface;
    const fd = stream.socket.handle;

    var wire = Wire.init(gpa);
    defer wire.deinit();
    wire.keep_body = false;
    try w.writeAll(h2.preface);
    try h2.writeSettings(w, &.{});
    try w.flush();
    try wire.pump(&reader.interface, w, fd, 100);

    // The client asks for a stream four megabytes long, reads the 65,535
    // bytes the window allows, and sends no WINDOW_UPDATE for the stream.
    try writeGet(w, 1, "/stream");
    // The connection's own window is opened, so what the stream cannot do is
    // not the connection's doing, and a second stream can.
    try h2.writeWindowUpdate(w, 0, 1 << 20);
    try w.flush();
    const started = bulkhead.monotonicNanos();
    try wire.pump(&reader.interface, w, fd, 150);
    try testing.expectEqual(@as(usize, h2.default_window), wire.seen[1].bytes);
    try testing.expect(!stalled_failed.load(.acquire));

    try writeGet(w, 3, "/pong");
    try w.flush();
    // Waited for with the reads the test would otherwise be doing, until the
    // server has acted on its deadline.
    while (!wire.seen[1].reset and bulkhead.monotonicNanos() < started + 5 * std.time.ns_per_s)
        try wire.pump(&reader.interface, w, fd, 100);
    const waited_ms = (bulkhead.monotonicNanos() - started) / std.time.ns_per_ms;

    try testing.expect(wire.seen[1].reset);
    // Not before the limit, and not long after it.
    try testing.expect(waited_ms >= 300 and waited_ms < 3_000);
    try testing.expectEqual(@as(?u16, 200), wire.seen[3].status);
    try testing.expectEqual(@as(usize, 4), wire.seen[3].bytes);
    for (0..100) |_| {
        if (stalled_failed.load(.acquire)) break;
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    // The call that was waiting to write was woken with an error.
    try testing.expect(stalled_failed.load(.acquire));
    // The connection is still good: it answers a PING.
    try h2.writeHeader(w, 8, .ping, 0, 0);
    try w.writeAll("12345678");
    try w.flush();
    for (0..20) |_| {
        if (wire.pongs > 0) break;
        try wire.pump(&reader.interface, w, fd, 100);
    }
    try testing.expectEqual(@as(u32, 1), wire.pongs);
}

test "a small answer on a connection does not wait for a large one that is being written beside it" {
    live.hush();
    reset();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const huge_len: usize = 8 * 1024 * 1024;
    const bytes = try gpa.alloc(u8, huge_len);
    defer gpa.free(bytes);
    @memset(bytes, 'h');
    huge_bytes = bytes;
    defer huge_bytes = &.{};

    var where = try live.SocketDir.init(gpa, "h2pipe-fair.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/huge", hugePiece);
    try app.get("/small", smallStream);

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
    var in_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    const w = &writer.interface;
    const fd = stream.socket.handle;

    var wire = Wire.init(gpa);
    defer wire.deinit();
    wire.keep_body = false;
    wire.autowindow = true;
    try w.writeAll(h2.preface);
    // Windows the huge answer cannot be held back by, so what orders the two
    // is the connection's turns and nothing the client does.
    try h2.writeSettings(w, &.{.{ .initial_window_size, 1 << 30 }});
    try h2.writeWindowUpdate(w, 0, (1 << 30) - h2.default_window);
    try w.flush();
    try wire.pump(&reader.interface, w, fd, 100);

    try writeGet(w, 1, "/huge");
    try writeGet(w, 3, "/small");
    try w.flush();
    const until = bulkhead.monotonicNanos() + 20 * std.time.ns_per_s;
    while ((wire.seen[1].ended_at == 0 or wire.seen[3].ended_at == 0) and bulkhead.monotonicNanos() < until)
        try wire.pump(&reader.interface, w, fd, 500);

    try testing.expectEqual(huge_len, wire.seen[1].bytes);
    try testing.expectEqual(@as(usize, 5), wire.seen[3].bytes);
    // The small answer ended while the large one was far from over: it
    // took its turn between the large one's.
    try testing.expect(wire.seen[3].ended_at < wire.seen[1].ended_at);
    try testing.expect(wire.seen[3].other_bytes_then < huge_len / 2);
    if (std.c.getenv("NILO_PIPE_REPORT") != null)
        std.debug.print("\nsmall answer ended after {d} of {d} bytes of the large one\n", .{ wire.seen[3].other_bytes_then, huge_len });
}

test "three streamed answers and a whole one share a connection window of the default size, and all of them finish" {
    live.hush();
    reset();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const huge_len: usize = 4 * 1024 * 1024;
    const bytes = try gpa.alloc(u8, huge_len);
    defer gpa.free(bytes);
    @memset(bytes, 'h');
    huge_bytes = bytes;
    defer huge_bytes = &.{};

    var where = try live.SocketDir.init(gpa, "h2pipe-share.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/huge", hugePiece);
    try app.get("/pong", pong);

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
    var in_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    const w = &writer.interface;
    const fd = stream.socket.handle;

    var wire = Wire.init(gpa);
    defer wire.deinit();
    wire.keep_body = false;
    wire.autowindow = true;
    try w.writeAll(h2.preface);
    // The streams' windows are wide; the connection's stays at its default
    // and is given back as the client reads, so it is the one thing the
    // streams share and the one thing that is short.
    try h2.writeSettings(w, &.{.{ .initial_window_size, 1 << 30 }});
    try w.flush();
    try wire.pump(&reader.interface, w, fd, 100);

    try writeGet(w, 1, "/huge");
    try writeGet(w, 3, "/huge");
    try writeGet(w, 5, "/huge");
    try writeGet(w, 7, "/pong");
    try w.flush();
    const until = bulkhead.monotonicNanos() + 30 * std.time.ns_per_s;
    while ((wire.seen[1].ended_at == 0 or wire.seen[3].ended_at == 0 or wire.seen[5].ended_at == 0 or wire.seen[7].ended_at == 0) and
        bulkhead.monotonicNanos() < until)
        try wire.pump(&reader.interface, w, fd, 500);

    // None reset, none cut short.
    try testing.expect(!wire.reset_by_server);
    for ([_]usize{ 1, 3, 5 }) |id| try testing.expectEqual(huge_len, wire.seen[id].bytes);
    try testing.expectEqual(@as(usize, 4), wire.seen[7].bytes);
    // The whole answer did not wait for the streamed ones.
    for ([_]usize{ 1, 3, 5 }) |id| try testing.expect(wire.seen[7].ended_at < wire.seen[id].ended_at);
    // When the first streamed answer ended the others had had their turns:
    // had the first in the table taken every WINDOW_UPDATE, they would have
    // had nothing.
    for ([_]usize{ 1, 3, 5 }) |id| {
        if (id == wire.first_end) continue;
        try testing.expect(wire.first_end_bytes[id] > huge_len / 2);
    }
}

test "a large lend that keeps moving is not cut at the write limit, however long it takes" {
    live.hush();
    reset();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const huge_len: usize = 4 * 1024 * 1024;
    const bytes = try gpa.alloc(u8, huge_len);
    defer gpa.free(bytes);
    @memset(bytes, 'h');
    huge_bytes = bytes;
    defer huge_bytes = &.{};

    var where = try live.SocketDir.init(gpa, "h2pipe-moving.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/huge", hugePiece);

    // A write limit of a third of a second, and a client that takes the
    // answer at a pace that needs several times that, a frame at a time.
    var serving: live.Serving = .{ .app = &app, .path = where.path, .write_timeout_ms = 300 };
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
    var in_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    const w = &writer.interface;
    const fd = stream.socket.handle;

    var wire = Wire.init(gpa);
    defer wire.deinit();
    wire.keep_body = false;
    wire.autowindow = true;
    wire.slow_ms = 4;
    try w.writeAll(h2.preface);
    try h2.writeSettings(w, &.{});
    try w.flush();
    try wire.pump(&reader.interface, w, fd, 100);

    try writeGet(w, 1, "/huge");
    try w.flush();
    const started = bulkhead.monotonicNanos();
    const until = started + 30 * std.time.ns_per_s;
    while (wire.seen[1].ended_at == 0 and !wire.seen[1].reset and bulkhead.monotonicNanos() < until)
        try wire.pump(&reader.interface, w, fd, 500);
    const took_ms = (bulkhead.monotonicNanos() - started) / std.time.ns_per_ms;

    try testing.expect(!wire.seen[1].reset);
    try testing.expectEqual(huge_len, wire.seen[1].bytes);
    // Long enough for the limit to have passed more than once.
    try testing.expect(took_ms > 900);
}

test "a client with a window of one byte that answers each byte with two updates is a flood, though it is sent data" {
    live.hush();
    reset();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var where = try live.SocketDir.init(gpa, "h2pipe-onebyte.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/stream", bigStream);

    var serving: live.Serving = .{ .app = &app, .path = where.path };
    const thread = try std.Thread.spawn(.{}, live.Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    try serving.waitUntilUp(io);

    var stream = try live.connect(io, where.path);
    defer stream.close(io);
    var out_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    var in_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    const w = &writer.interface;
    const fd = stream.socket.handle;

    var wire = Wire.init(gpa);
    defer wire.deinit();
    wire.keep_body = false;
    try w.writeAll(h2.preface);
    try h2.writeSettings(w, &.{.{ .initial_window_size, 1 }});
    try w.flush();
    try wire.pump(&reader.interface, w, fd, 100);

    try writeGet(w, 1, "/stream");
    try w.flush();
    // One byte of the stream's window, one of the connection's, for each
    // byte it was sent: the loop feeds itself with no flood count if a frame
    // of one byte earns the updates that follow it. Stopped by the GOAWAY, or
    // after a number of bytes no flood count would have let by.
    var given: usize = 0;
    var away = false;
    for (0..4000) |_| {
        wire.pump(&reader.interface, w, fd, 50) catch |err| switch (err) {
            error.SentAway => {
                away = true;
                break;
            },
            else => return err,
        };
        while (given < wire.seen[1].bytes) : (given += 1) {
            try h2.writeWindowUpdate(w, 1, 1);
            try h2.writeWindowUpdate(w, 0, 1);
        }
        w.flush() catch break;
        if (given > 2500) break;
    }
    try testing.expect(away);
    try testing.expectEqual(@as(?u32, @intFromEnum(h2.ErrorCode.enhance_your_calm)), wire.goaway_code);
    try testing.expect(wire.seen[1].bytes < 1500);
}
