//! The tests of a gRPC listener that need a server actually running
//! ([ADR 220](../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md)).
//!
//! `h2conn.zig`'s own tests drive a connection through in-memory buffers, and
//! there every call runs inline: `bulkhead.spawn` answers `error.NoServer`
//! outside an Engine. What only a running server reaches is the half the
//! design rests on, a call on a fiber of its own handing its answer back to
//! the connection's fiber through the waker, and two calls on one connection
//! in flight at once. That is what these are for.
//!
//! The gRPC listener is the second one, on a unix socket beside a plain port
//! the kernel chose. `boundPort()` answers for the first listener only, and a
//! server that has answered it has bound every listener, so the socket file is
//! there to connect to by then. The client is frames written by hand over
//! std's own socket, with no zio on this side.
//!
//! Compiled only into a build with gRPC in it, the way `tls_live.zig` is.

const std = @import("std");
const nilo = @import("http.zig");
const h2 = @import("h2.zig");
const hpack = @import("hpack.zig");

const testing = std.testing;

fn hush() void {
    std.testing.log_level = .err;
}

fn echo(c: *nilo.Ctx) anyerror!void {
    const body = try c.body();
    try c.send(200, "application/grpc", body.view());
}

/// Held long enough that a second call on the same connection arrives while
/// this one is still running, which is what shows the two are not served one
/// after the other.
fn slowEcho(c: *nilo.Ctx) anyerror!void {
    try nilo.sleep(50);
    return echo(c);
}

const Serving = struct {
    app: *nilo.App,
    path: []const u8,
    write_timeout_ms: u32 = 30_000,
    body_timeout_ms: u32 = 30_000,
    body_grace_ms: u32 = 10_000,
    body_min_rate: u32 = 8 * 1024,
    bound: std.atomic.Value(bool) = .init(true),

    fn run(self: *Serving) void {
        var buf: [std.Io.net.UnixAddress.max_len + 8]u8 = undefined;
        const beside = std.fmt.bufPrint(&buf, "unix:{s}", .{self.path}) catch unreachable;
        self.app.tryListen(.{
            .port = 0,
            .threads = 2,
            .stop_on_signal = false,
            .write_timeout_ms = self.write_timeout_ms,
            .body_timeout_ms = self.body_timeout_ms,
            .body_grace_ms = self.body_grace_ms,
            .body_min_rate = self.body_min_rate,
            .also = &.{.{ .address = beside, .grpc = true }},
        }) catch {
            self.bound.store(false, .release);
        };
    }

    /// Bounded, for the reason every wait in `live.zig` is.
    fn waitUntilUp(self: *const Serving, io: std.Io) !void {
        for (0..300) |_| {
            if (self.app.boundPort() != null) return;
            if (!self.bound.load(.acquire)) return error.ServerNeverCameUp;
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
        }
        return error.ServerNeverCameUp;
    }
};

const SocketDir = struct {
    tmp: nilo.testing.TmpDir,
    path: [:0]u8,

    fn init(gpa: std.mem.Allocator, name: []const u8) !SocketDir {
        var tmp = nilo.testing.tmpDir();
        errdefer tmp.cleanup();
        return .{
            .tmp = tmp,
            .path = try tmp.pathAlloc(gpa, name),
        };
    }

    fn deinit(self: *SocketDir, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        self.tmp.cleanup();
    }
};

fn writeCall(w: *std.Io.Writer, stream: u31, path: []const u8, message: []const u8) !void {
    var block_buf: [256]u8 = undefined;
    var block: std.Io.Writer = .fixed(&block_buf);
    try hpack.writeInt(&block, 0x80, 7, 3); // :method POST
    try hpack.writeInt(&block, 0x80, 7, 6); // :scheme http
    try hpack.writeLiteral(&block, ":path", path);
    try hpack.writeLiteral(&block, ":authority", "localhost");
    try hpack.writeLiteral(&block, "content-type", "application/grpc");
    try hpack.writeLiteral(&block, "te", "trailers");
    try h2.writeHeaderBlock(w, stream, block.buffered(), false, h2.default_max_frame);

    try h2.writeHeader(w, 5 + message.len, .data, h2.Flags.end_stream, stream);
    var prefix: [5]u8 = .{ 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, prefix[1..5], @intCast(message.len), .big);
    try w.writeAll(&prefix);
    try w.writeAll(message);
}

/// What one call came back with.
const Call = struct {
    message: std.ArrayList(u8) = .empty,
    status: ?[]const u8 = null,
    /// Where in the connection's frames this call's trailers arrived.
    finished_at: usize = 0,
};

/// Read frames until every stream in `calls` has its trailers, decoding
/// headers as they come. The socket has a receive timeout on it, so a server
/// that never answers fails here rather than leaving the suite waiting; std's
/// reader takes the `EAGAIN` that timeout produces for a programmer's mistake
/// and panics, so the failure is a crashed test rather than a failed one.
fn readAnswers(a: std.mem.Allocator, r: *std.Io.Reader, w: *std.Io.Writer, calls: []Call) !void {
    var decoder = hpack.Decoder.init(a);
    defer decoder.deinit();
    var frames: usize = 0;
    var open = calls.len;
    while (open > 0) {
        const head = h2.Header.parse(try r.takeArray(h2.header_len));
        const payload = try r.take(head.len);
        frames += 1;
        switch (head.type) {
            .settings => if (!head.has(h2.Flags.ack)) {
                try h2.writeSettingsAck(w);
                try w.flush();
            },
            .data => {
                const call = &calls[(head.stream - 1) / 2];
                try call.message.appendSlice(a, payload);
            },
            .headers => {
                var fields: std.ArrayList(hpack.Field) = .empty;
                _ = try decoder.decode(payload, a, &fields, 1 << 16);
                const call = &calls[(head.stream - 1) / 2];
                for (fields.items) |f| if (std.mem.eql(u8, f.name, "grpc-status")) {
                    call.status = f.value;
                };
                if (head.has(h2.Flags.end_stream)) {
                    call.finished_at = frames;
                    open -= 1;
                }
            },
            .goaway => return error.SentAway,
            .rst_stream => return error.Reset,
            else => {},
        }
    }
}

fn connect(io: std.Io, path: []const u8) !std.Io.net.Stream {
    const address = try std.Io.net.UnixAddress.init(path);
    const stream = try address.connect(io);
    const limit: std.posix.timeval = .{ .sec = 5, .usec = 0 };
    try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&limit));
    return stream;
}

test "a gRPC listener answers a unary call on a running server, beside a plain port" {
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var where = try SocketDir.init(gpa, "grpc.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.post("/test.Echo/Say", echo);

    var serving: Serving = .{ .app = &app, .path = where.path };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    try serving.waitUntilUp(io);

    var stream = try connect(io, where.path);
    defer stream.close(io);
    var out_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    var in_buf: [32 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);

    try writer.interface.writeAll(h2.preface);
    try h2.writeSettings(&writer.interface, &.{});
    try writeCall(&writer.interface, 1, "/test.Echo/Say", "over a real socket");
    try writer.interface.flush();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var calls: [1]Call = .{.{}};
    try readAnswers(arena.allocator(), &reader.interface, &writer.interface, &calls);
    try testing.expectEqualStrings("0", calls[0].status.?);
    try testing.expectEqualStrings("over a real socket", calls[0].message.items[5..]);
}

fn hi(c: *nilo.Ctx) anyerror!void {
    try c.sendText(200, "hi there");
}

fn connectTcp(io: std.Io, port: u16) !std.Io.net.Stream {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    const limit: std.posix.timeval = .{ .sec = 5, .usec = 0 };
    try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&limit));
    return stream;
}

/// One HTTP/1.1 request that asks to be closed after, and what came back
/// whole: the connection ends, so a short read is the end of the answer.
fn getAndClose(io: std.Io, stream: *std.Io.net.Stream, out: []u8) ![]const u8 {
    return getWith(io, stream, out, "");
}

/// The same with `extra` header lines, each ending in CRLF.
fn getWith(io: std.Io, stream: *std.Io.net.Stream, out: []u8, extra: []const u8) ![]const u8 {
    var out_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    var in_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    try writer.interface.writeAll("GET /hi HTTP/1.1\r\nHost: t\r\nConnection: close\r\n");
    try writer.interface.writeAll(extra);
    try writer.interface.writeAll("\r\n");
    try writer.interface.flush();
    const n = try reader.interface.readSliceShort(out);
    return out[0..n];
}

test "one plain port answers HTTP/1.1 and an HTTP/2 gRPC call, and a listener that set .grpc answers HTTP/1.1 too" {
    // ADR 259, stage 5.2: the first bytes choose, on every plain listener.
    // The first listener here is a plain TCP port the kernel chose, the
    // second a unix socket with `.grpc` set, which used to answer an
    // HTTP/1.1 client with a 505 and chooses nothing now.
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var where = try SocketDir.init(gpa, "grpc-one-port.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.post("/test.Echo/Say", echo);
    try app.get("/hi", hi);

    var serving: Serving = .{ .app = &app, .path = where.path };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    try serving.waitUntilUp(io);
    const port = app.boundPort().?;

    var answer: [1024]u8 = undefined;

    // HTTP/1.1 on the port.
    {
        var stream = try connectTcp(io, port);
        defer stream.close(io);
        const got = try getAndClose(io, &stream, &answer);
        try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 "));
        try testing.expect(std.mem.endsWith(u8, got, "hi there"));
    }

    // `Upgrade: h2c` is ignored: an HTTP/1.1 request, answered as one.
    {
        var stream = try connectTcp(io, port);
        defer stream.close(io);
        const got = try getWith(io, &stream, &answer, "Upgrade: h2c\r\nHTTP2-Settings: AAMAAABkAARAAAAAAAIAAAAA\r\n");
        try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 "));
        try testing.expect(std.mem.endsWith(u8, got, "hi there"));
    }

    // HTTP/2 with prior knowledge on the same port, the preface split across
    // two writes with a pause between them: a preface seen in pieces is one.
    {
        var stream = try connectTcp(io, port);
        defer stream.close(io);
        var out_buf: [1024]u8 = undefined;
        var writer = stream.writer(io, &out_buf);
        var in_buf: [32 * 1024]u8 = undefined;
        var reader = stream.reader(io, &in_buf);

        try writer.interface.writeAll(h2.preface[0..9]);
        try writer.interface.flush();
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
        try writer.interface.writeAll(h2.preface[9..]);
        try h2.writeSettings(&writer.interface, &.{});
        try writeCall(&writer.interface, 1, "/test.Echo/Say", "on the shared port");
        try writer.interface.flush();

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var calls: [1]Call = .{.{}};
        try readAnswers(arena.allocator(), &reader.interface, &writer.interface, &calls);
        try testing.expectEqualStrings("0", calls[0].status.?);
        try testing.expectEqualStrings("on the shared port", calls[0].message.items[5..]);
    }

    // HTTP/1.1 on the listener that set `.grpc`.
    {
        var stream = try connect(io, where.path);
        defer stream.close(io);
        const got = try getAndClose(io, &stream, &answer);
        try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 "));
        try testing.expect(std.mem.endsWith(u8, got, "hi there"));
    }
}

test "two calls on one connection run at once, and the quick one is not held behind the slow one" {
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var where = try SocketDir.init(gpa, "grpc-two.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.post("/test.Echo/Slow", slowEcho);
    try app.post("/test.Echo/Say", echo);

    var serving: Serving = .{ .app = &app, .path = where.path };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    try serving.waitUntilUp(io);

    var stream = try connect(io, where.path);
    defer stream.close(io);
    var out_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    var in_buf: [32 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);

    try writer.interface.writeAll(h2.preface);
    try h2.writeSettings(&writer.interface, &.{});
    // The slow one first, so served in order the quick one would finish last.
    try writeCall(&writer.interface, 1, "/test.Echo/Slow", "slow");
    try writeCall(&writer.interface, 3, "/test.Echo/Say", "quick");
    try writer.interface.flush();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var calls: [2]Call = .{ .{}, .{} };
    try readAnswers(arena.allocator(), &reader.interface, &writer.interface, &calls);
    try testing.expectEqualStrings("0", calls[0].status.?);
    try testing.expectEqualStrings("0", calls[1].status.?);
    try testing.expectEqualStrings("slow", calls[0].message.items[5..]);
    try testing.expectEqualStrings("quick", calls[1].message.items[5..]);
    try testing.expect(calls[1].finished_at < calls[0].finished_at);
}

/// How many handlers are running right now, and the most there have been.
var inside: std.atomic.Value(u32) = .init(0);
var most_inside: std.atomic.Value(u32) = .init(0);

fn countedSlow(c: *nilo.Ctx) anyerror!void {
    const now = inside.fetchAdd(1, .acq_rel) + 1;
    _ = most_inside.fetchMax(now, .acq_rel);
    defer _ = inside.fetchSub(1, .acq_rel);
    try nilo.sleep(100);
    try c.send(200, "application/grpc", "");
}

test "rapid reset: a call the client cancels still counts against the cap until its handler returns" {
    // CVE-2023-44487. A client opens a call and resets it at once, over and
    // over: the stream is gone from the client's count, and a server that
    // forgets it as well has started a handler for every one of them.
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var where = try SocketDir.init(gpa, "grpc-reset.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.post("/test.Echo/Slow", countedSlow);

    var serving: Serving = .{ .app = &app, .path = where.path };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    try serving.waitUntilUp(io);

    var stream = try connect(io, where.path);
    defer stream.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    var in_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);

    const nilo_h2conn = @import("h2conn.zig");
    const burst = nilo_h2conn.max_streams + 50;
    try writer.interface.writeAll(h2.preface);
    try h2.writeSettings(&writer.interface, &.{});
    var id: u31 = 1;
    for (0..burst) |_| {
        try writeCall(&writer.interface, id, "/test.Echo/Slow", "");
        try h2.writeRstStream(&writer.interface, id, .cancel);
        id += 2;
    }
    // Answered after everything above has been read, so every refusal the
    // burst earned is on the wire in front of it.
    try h2.writeHeader(&writer.interface, 8, .ping, 0, 0);
    try writer.interface.writeAll("rapidrst");
    try writer.interface.flush();

    var refused: usize = 0;
    while (true) {
        const head = h2.Header.parse(try reader.interface.takeArray(h2.header_len));
        const payload = try reader.interface.take(head.len);
        if (head.type == .rst_stream and
            std.mem.readInt(u32, payload[0..4], .big) == @intFromEnum(h2.ErrorCode.refused_stream)) refused += 1;
        if (head.type == .goaway) return error.SentAway;
        if (head.type == .ping and head.has(h2.Flags.ack)) break;
    }
    try testing.expect(most_inside.load(.acquire) <= nilo_h2conn.max_streams);
    try testing.expect(refused >= burst - nilo_h2conn.max_streams);
}

test "a client that holds its window at zero is let go of once the write limit passes" {
    // The zero-window attack: ask for an answer, then never let it be sent.
    // What the answer holds is the call's arena and a place in the cap, so
    // the connection goes when `write_timeout_ms` says a write has waited
    // long enough, as an HTTP/1.1 write that never drains does.
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var where = try SocketDir.init(gpa, "grpc-window.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.post("/test.Echo/Say", echo);

    var serving: Serving = .{ .app = &app, .path = where.path, .write_timeout_ms = 300 };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    try serving.waitUntilUp(io);

    var stream = try connect(io, where.path);
    defer stream.close(io);
    var out_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    var in_buf: [32 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);

    try writer.interface.writeAll(h2.preface);
    try h2.writeSettings(&writer.interface, &.{.{ .initial_window_size, 0 }});
    try writeCall(&writer.interface, 1, "/test.Echo/Say", "an answer with nowhere to go");
    try writer.interface.flush();

    // Everything until the server closes; the socket's own five-second
    // receive limit is what fails this if it never does.
    const started = std.Io.Clock.awake.now(io);
    var data_frames: usize = 0;
    while (true) {
        const head = h2.Header.parse(reader.interface.takeArray(h2.header_len) catch break);
        _ = reader.interface.take(head.len) catch break;
        if (head.type == .data) data_frames += 1;
    }
    const took = started.durationTo(std.Io.Clock.awake.now(io));
    try testing.expectEqual(@as(usize, 0), data_frames);
    // Not before the limit, which is what says the close was the limit's.
    try testing.expect(took.toMilliseconds() >= 250);
    try testing.expect(took.toMilliseconds() < 3000);
}

test "a zero window is let go of on time however often the client sends a frame" {
    // The same attack, with a frame every 100 ms. Each one used to start the
    // write limit again, so the answer and its place in the cap were held for
    // as long as the client kept typing.
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var where = try SocketDir.init(gpa, "grpc-trickle.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.post("/test.Echo/Say", echo);

    var serving: Serving = .{ .app = &app, .path = where.path, .write_timeout_ms = 300 };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    try serving.waitUntilUp(io);

    var stream = try connect(io, where.path);
    defer stream.close(io);
    var out_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    var in_buf: [32 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);

    try writer.interface.writeAll(h2.preface);
    try h2.writeSettings(&writer.interface, &.{.{ .initial_window_size, 0 }});
    try writeCall(&writer.interface, 1, "/test.Echo/Say", "an answer with nowhere to go");
    try writer.interface.flush();

    const started = std.Io.Clock.awake.now(io);
    // Twenty frames of a type nobody knows, 100 ms apart: two seconds of a
    // client that is plainly still there. A write that fails is the server
    // having gone, which is the point.
    for (0..20) |_| {
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
        h2.writeHeader(&writer.interface, 0, @enumFromInt(0x20), 0, 0) catch break;
        writer.interface.flush() catch break;
    }
    while (true) {
        const head = h2.Header.parse(reader.interface.takeArray(h2.header_len) catch break);
        _ = reader.interface.take(head.len) catch break;
    }
    const took = started.durationTo(std.Io.Clock.awake.now(io));
    try testing.expect(took.toMilliseconds() < 1500);
}

test "a call whose message never finishes arriving is cancelled, and the connection goes on" {
    // HEADERS with no END_STREAM, then only PINGs: a client that is there
    // and never sends what it owes. The call gets the bound a chunked body
    // does, grace plus the most it may be at the slowest rate, and then an
    // RST_STREAM; the connection answers the next call as usual.
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var where = try SocketDir.init(gpa, "grpc-owed.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.post("/test.Echo/Say", echo);

    // 300 ms of grace, and a rate so high the megabyte adds nothing: the
    // call has 300 ms to finish arriving. The PINGs keep `body_timeout_ms`
    // from being the limit that fires.
    var serving: Serving = .{
        .app = &app,
        .path = where.path,
        .body_grace_ms = 300,
        .body_min_rate = 1 << 30,
    };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    try serving.waitUntilUp(io);

    var stream = try connect(io, where.path);
    defer stream.close(io);
    var out_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    var in_buf: [32 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);

    try writer.interface.writeAll(h2.preface);
    try h2.writeSettings(&writer.interface, &.{});
    var block_buf: [256]u8 = undefined;
    var block: std.Io.Writer = .fixed(&block_buf);
    try hpack.writeInt(&block, 0x80, 7, 3); // :method POST
    try hpack.writeInt(&block, 0x80, 7, 6); // :scheme http
    try hpack.writeLiteral(&block, ":path", "/test.Echo/Say");
    try hpack.writeLiteral(&block, ":authority", "localhost");
    try hpack.writeLiteral(&block, "content-type", "application/grpc");
    try h2.writeHeaderBlock(&writer.interface, 1, block.buffered(), false, h2.default_max_frame);
    try writer.interface.flush();

    for (0..10) |_| {
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
        try h2.writeHeader(&writer.interface, 8, .ping, 0, 0);
        try writer.interface.writeAll("12345678");
        try writer.interface.flush();
    }

    var cancelled: ?h2.ErrorCode = null;
    while (cancelled == null) {
        const head = h2.Header.parse(try reader.interface.takeArray(h2.header_len));
        const payload = try reader.interface.take(head.len);
        if (head.type == .goaway) return error.SentAway;
        if (head.type == .rst_stream and head.stream == 1)
            cancelled = @enumFromInt(std.mem.readInt(u32, payload[0..4], .big));
    }
    try testing.expectEqual(h2.ErrorCode.cancel, cancelled.?);

    // The connection is still good for the next call.
    try writeCall(&writer.interface, 3, "/test.Echo/Say", "and this one");
    try writer.interface.flush();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var decoder = hpack.Decoder.init(arena.allocator());
    defer decoder.deinit();
    var status: ?[]const u8 = null;
    while (true) {
        const head = h2.Header.parse(try reader.interface.takeArray(h2.header_len));
        const payload = try reader.interface.take(head.len);
        if (head.type != .headers or head.stream != 3) continue;
        var fields: std.ArrayList(hpack.Field) = .empty;
        _ = try decoder.decode(payload, arena.allocator(), &fields, 1 << 16);
        for (fields.items) |f| if (std.mem.eql(u8, f.name, "grpc-status")) {
            status = try arena.allocator().dupe(u8, f.value);
        };
        if (head.has(h2.Flags.end_stream)) break;
    }
    try testing.expectEqualStrings("0", status.?);
}
