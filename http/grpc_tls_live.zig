//! One TLS listener offers `h2` and `http/1.1` by ALPN and serves what was
//! chosen: HTTP/2 to a client that offers `h2`, HTTP/1.1 to one that offers
//! only `http/1.1` or no ALPN at all, gRPC over TLS among the first
//! ([ADR 259](../docs/adr/259-http2-is-a-framing-of-every-request.md),
//! [ADR 220](../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md)).
//!
//! The client is tls.zig's own, the library the server runs on, because std's
//! TLS client sends no ALPN. That makes this evidence that the protocol was
//! chosen and the frames arrive, and not that two implementations agree about
//! TLS: `tls_live.zig` is where that is held, against std's client.
//!
//! Compiled only into a build with both TLS and HTTP/2 in it.

const std = @import("std");
const tls = @import("tls");
const nilo = @import("http.zig");
const h2 = @import("h2.zig");
const hpack = @import("hpack.zig");

const testing = std.testing;

const cert_path = "http/testdata/tls/localhost.pem";
const key_path = "http/testdata/tls/localhost-key.pem";

fn hush() void {
    std.testing.log_level = .err;
}

fn echo(c: *nilo.Ctx) anyerror!void {
    const body = try c.body();
    try c.send(200, "application/grpc", body.view());
}

/// The Room the event-stream tests post into, set by each before it serves.
var test_room: *nilo.Room = undefined;

fn events(c: *nilo.Ctx) anyerror!void {
    return c.eventsFrom(test_room, .{ .keepalive_ms = 0 });
}

fn hello(c: *nilo.Ctx) anyerror!void {
    try c.send(200, "text/plain", "hello over tls");
}

const Serving = struct {
    app: *nilo.App,
    bound: std.atomic.Value(bool) = .init(true),

    fn run(self: *Serving) void {
        self.app.tryListen(.{
            .port = 0,
            .threads = 1,
            .stop_on_signal = false,
            .tls = .{ .cert = cert_path, .key = key_path },
        }) catch {
            self.bound.store(false, .release);
        };
    }

    fn waitForPort(self: *const Serving, io: std.Io) !u16 {
        for (0..300) |_| {
            if (self.app.boundPort()) |port| return port;
            if (!self.bound.load(.acquire)) return error.ServerNeverCameUp;
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
        }
        return error.ServerNeverCameUp;
    }
};

/// A TCP connection with a five-second receive limit, so a server that never
/// answers fails the test (std's reader panics on the timeout, see
/// `grpc_live.zig`) rather than leaving the suite waiting.
fn connect(io: std.Io, port: u16) !std.Io.net.Stream {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    const limit: std.posix.timeval = .{ .sec = 5, .usec = 0 };
    try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&limit));
    return stream;
}

fn handshake(io: std.Io, r: *std.Io.Reader, w: *std.Io.Writer, alpn: []const []const u8) !tls.Connection {
    var rng_source: std.Random.IoSource = .{ .io = io };
    return tls.client(r, w, .{
        .rng = rng_source.interface(),
        .now = std.Io.Clock.real.now(io),
        .host = "localhost",
        // The suite's self-signed certificate: what is under test is the
        // protocol chosen, and `tls_live.zig` holds the certificate check.
        .root_ca = .empty,
        .insecure_skip_verify = true,
        .alpn_protocols = alpn,
    });
}

test "a TLS listener answers a unary gRPC call to a client that offers h2" {
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.post("/test.Echo/Say", echo);
    try app.get("/hello", hello);

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try serving.waitForPort(io);

    var stream = try connect(io, port);
    defer stream.close(io);
    var raw_in: [tls.input_buffer_len]u8 = undefined;
    var raw_out: [tls.output_buffer_len]u8 = undefined;
    var reader = stream.reader(io, &raw_in);
    var writer = stream.writer(io, &raw_out);
    var conn = try handshake(io, &reader.interface, &writer.interface, &.{ "h2", "http/1.1" });
    try testing.expectEqualStrings("h2", conn.alpn_protocol.?);

    var clear_in: [16 * 1024]u8 = undefined;
    var clear_out: [4 * 1024]u8 = undefined;
    var cr = conn.reader(&clear_in);
    var cw = conn.writer(&clear_out);
    const w = &cw.interface;

    var block_buf: [256]u8 = undefined;
    var block: std.Io.Writer = .fixed(&block_buf);
    try hpack.writeInt(&block, 0x80, 7, 3); // :method POST
    try hpack.writeInt(&block, 0x80, 7, 7); // :scheme https
    try hpack.writeLiteral(&block, ":path", "/test.Echo/Say");
    try hpack.writeLiteral(&block, ":authority", "localhost");
    try hpack.writeLiteral(&block, "content-type", "application/grpc");
    try w.writeAll(h2.preface);
    try h2.writeSettings(w, &.{});
    try h2.writeHeaderBlock(w, 1, block.buffered(), false, h2.default_max_frame);
    const message = "through tls";
    try h2.writeHeader(w, 5 + message.len, .data, h2.Flags.end_stream, 1);
    try w.writeAll(&.{ 0, 0, 0, 0, message.len });
    try w.writeAll(message);
    try w.flush();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var decoder = hpack.Decoder.init(gpa);
    defer decoder.deinit();
    var got: std.ArrayList(u8) = .empty;
    var status: ?[]const u8 = null;
    while (true) {
        const head = h2.Header.parse(try cr.interface.takeArray(h2.header_len));
        const payload = try cr.interface.take(head.len);
        if (head.stream != 1) continue;
        if (head.type == .data) try got.appendSlice(arena.allocator(), payload);
        if (head.type == .headers) {
            var fields: std.ArrayList(hpack.Field) = .empty;
            _ = try decoder.decode(payload, arena.allocator(), &fields, 1 << 16);
            for (fields.items) |f| if (std.mem.eql(u8, f.name, "grpc-status")) {
                status = f.value;
            };
            if (head.has(h2.Flags.end_stream)) break;
        }
    }
    try testing.expectEqualStrings("0", status.?);
    try testing.expectEqualStrings(message, got.items[5..]);
}

/// One TLS connection to a server that is already listening, handshaken
/// offering `alpn`, with the buffers a test reads and writes through.
const Client = struct {
    stream: std.Io.net.Stream,
    raw_in: [tls.input_buffer_len]u8 = undefined,
    raw_out: [tls.output_buffer_len]u8 = undefined,
    clear_in: [16 * 1024]u8 = undefined,
    clear_out: [4 * 1024]u8 = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    conn: tls.Connection = undefined,
    cr: tls.Connection.Reader = undefined,
    cw: tls.Connection.Writer = undefined,
    connected: bool = false,

    fn open(self: *Client, io: std.Io, port: u16, alpn: []const []const u8) !void {
        self.stream = try connect(io, port);
        self.connected = true;
        self.reader = self.stream.reader(io, &self.raw_in);
        self.writer = self.stream.writer(io, &self.raw_out);
        self.conn = try handshake(io, &self.reader.interface, &self.writer.interface, alpn);
        self.cr = self.conn.reader(&self.clear_in);
        self.cw = self.conn.writer(&self.clear_out);
    }

    fn close(self: *Client, io: std.Io) void {
        if (self.connected) self.stream.close(io);
    }
};

/// What a request answered over HTTP/1.1 starts with.
const http1_answer = "HTTP/1.1 200 ";

fn getHttp1(c: *Client) ![]const u8 {
    const w = &c.cw.interface;
    try w.writeAll("GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try w.flush();
    return c.cr.interface.take(http1_answer.len);
}

/// What an HTTP/2 answer to one `GET /hello` on stream 1 was.
const H2Answer = struct { status: []const u8, body: []const u8 };

/// Send the preface, SETTINGS and a `GET /hello` over `c`, and read the
/// answer on stream 1. With `together`, the preface and SETTINGS are one TLS
/// record and the `GET` another, and both leave in one socket write, so the
/// server's one read of the socket has the second record in it before it has
/// decrypted the first.
fn getOverH2(gpa: std.mem.Allocator, arena: std.mem.Allocator, c: *Client, together: bool) !H2Answer {
    const w = &c.cw.interface;
    var block_buf: [128]u8 = undefined;
    var block: std.Io.Writer = .fixed(&block_buf);
    try hpack.writeInt(&block, 0x80, 7, 2); // :method GET
    try hpack.writeInt(&block, 0x80, 7, 7); // :scheme https
    try hpack.writeLiteral(&block, ":path", "/hello");
    try hpack.writeLiteral(&block, ":authority", "localhost");

    var staging: [2048]u8 = undefined;
    var staged: std.Io.Writer = .fixed(&staging);
    const wire = c.conn.output;
    if (together) c.conn.output = &staged;
    try w.writeAll(h2.preface);
    try h2.writeSettings(w, &.{});
    try w.flush();
    try h2.writeHeaderBlock(w, 1, block.buffered(), true, h2.default_max_frame);
    try w.flush();
    if (together) {
        c.conn.output = wire;
        try wire.writeAll(staged.buffered());
        try wire.flush();
    }

    var decoder = hpack.Decoder.init(gpa);
    defer decoder.deinit();
    var got: std.ArrayList(u8) = .empty;
    var status: []const u8 = "";
    while (true) {
        const head = h2.Header.parse(try c.cr.interface.takeArray(h2.header_len));
        const payload = try c.cr.interface.take(head.len);
        if (head.stream != 1) continue;
        if (head.type == .data) try got.appendSlice(arena, payload);
        if (head.type == .headers) {
            var fields: std.ArrayList(hpack.Field) = .empty;
            _ = try decoder.decode(payload, arena, &fields, 1 << 16);
            for (fields.items) |f| if (std.mem.eql(u8, f.name, ":status")) {
                status = try arena.dupe(u8, f.value);
            };
        }
        if (head.has(h2.Flags.end_stream)) break;
    }
    return .{ .status = status, .body = got.items };
}

test "a TLS listener serves an ordinary GET over HTTP/2 to a client that offers h2" {
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/hello", hello);

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try serving.waitForPort(io);

    // Offered in the client's order, `http/1.1` first: the server's
    // preference is what decides, and it prefers `h2`.
    const c = try gpa.create(Client);
    defer gpa.destroy(c);
    try c.open(io, port, &.{ "http/1.1", "h2" });
    defer c.close(io);
    try testing.expectEqualStrings("h2", c.conn.alpn_protocol.?);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const answer = try getOverH2(gpa, arena.allocator(), c, false);
    try testing.expectEqualStrings("200", answer.status);
    try testing.expectEqualStrings("hello over tls", answer.body);
}

test "a second TLS record that arrived with the first is answered, not waited for on an emptied socket" {
    // tls.zig takes whatever the socket has and decrypts one record a call.
    // A connection that looked at the socket before the next record had been
    // decrypted waited for bytes that were already in its buffer, until the
    // client spoke again: one HTTP/2 connection in a thousand over TLS, and
    // the question a WebSocket over TLS had open (`Wake.held`). Here the
    // second record is made to be in the first read, every time: both leave
    // in one socket write. So the loop is not a search for a rare race, only
    // a margin against a kernel that delivered the write in two; it was
    // twenty handshakes, two seconds of a Debug suite, for the same claim.
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/hello", hello);

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try serving.waitForPort(io);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (0..3) |_| {
        const c = try gpa.create(Client);
        defer gpa.destroy(c);
        try c.open(io, port, &.{"h2"});
        defer c.close(io);
        const answer = try getOverH2(gpa, arena.allocator(), c, true);
        try testing.expectEqualStrings("200", answer.status);
        try testing.expectEqualStrings("hello over tls", answer.body);
    }
}

test "a TLS listener serves HTTP/1.1 to a client that offers only http/1.1" {
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/hello", hello);

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try serving.waitForPort(io);

    const c = try gpa.create(Client);
    defer gpa.destroy(c);
    try c.open(io, port, &.{"http/1.1"});
    defer c.close(io);
    try testing.expectEqualStrings("http/1.1", c.conn.alpn_protocol.?);
    try testing.expectEqualStrings(http1_answer, try getHttp1(c));
}

test "a TLS listener serves HTTP/1.1 to a client that offers no ALPN at all" {
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/hello", hello);

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try serving.waitForPort(io);

    const c = try gpa.create(Client);
    defer gpa.destroy(c);
    try c.open(io, port, &.{});
    defer c.close(io);
    try testing.expect(c.conn.alpn_protocol == null);
    try testing.expectEqualStrings(http1_answer, try getHttp1(c));
}

test "a client that offers only a protocol the listener does not speak gets RFC 7301's no_application_protocol alert" {
    // RFC 7301 section 3.2: a server that supports none of the protocols
    // the client advertised "SHALL respond with a fatal
    // no_application_protocol alert", and tls.zig does exactly that. So the
    // handshake of a client offering `spdy/3` alone fails, where a client
    // offering nothing is served HTTP/1.1 (the test above). Every browser
    // and HTTP client offers `http/1.1`, so this is a client that offers
    // nothing the listener speaks, not one that offers little.
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/hello", hello);

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try serving.waitForPort(io);

    const c = try gpa.create(Client);
    defer gpa.destroy(c);
    if (c.open(io, port, &.{"spdy/3"})) {
        c.close(io);
        return error.HandshakeShouldHaveFailed;
    } else |_| {
        c.close(io);
    }
}

/// Send one whole TLS record carrying `whole`, and the first `n` bytes of a
/// second, in one socket write. The server's record layer then holds a
/// header or half a payload behind a record it has decrypted, which is not
/// a record it can decrypt: the case a wait must not answer `.readable` for.
fn sendWholeThenPartial(c: *Client, whole: []const u8, n: usize) !void {
    var staging: [512]u8 = undefined;
    var staged: std.Io.Writer = .fixed(&staging);
    const wire = c.conn.output;
    c.conn.output = &staged;
    try c.cw.interface.writeAll(whole);
    try c.cw.interface.flush();
    const first = staged.end;
    try c.cw.interface.writeAll("x");
    try c.cw.interface.flush();
    c.conn.output = wire;
    try wire.writeAll(staged.buffered()[0 .. first + n]);
    try wire.flush();
}

/// Post into the room once the client has had time to be seated.
fn postLater(io: std.Io) void {
    std.Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
    test_room.print("hello", .{}) catch {};
}

fn wsLoop(socket: *nilo.Socket, room: *nilo.Room) !void {
    try room.join(socket);
    defer room.leave(socket);
    while (try socket.receive()) |message| try room.say(message.kind, message.data);
    try socket.close(.normal, "");
}

fn ws(c: *nilo.Ctx) anyerror!void {
    return c.upgrade(wsLoop, test_room);
}

/// A connection with a record split behind a whole one, and a post that has
/// to be written before the rest of it arrives. `alpn` is `h2` or
/// `http/1.1` (a WebSocket, the HTTP/1.1 shape that reads the client).
fn serveSplit(gpa: std.mem.Allocator, io: std.Io, alpn: []const u8, partial: usize) !void {
    var room = try nilo.Room.initWith(gpa, .{ .seats = 8 });
    defer room.deinit();
    test_room = &room;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/events", events);
    try app.get("/ws", ws);

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try serving.waitForPort(io);

    const c = try gpa.create(Client);
    defer gpa.destroy(c);
    try c.open(io, port, &.{alpn});
    defer c.close(io);
    const w = &c.cw.interface;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const is_h2 = std.mem.eql(u8, alpn, "h2");

    var whole: [32]u8 = undefined;
    var whole_w: std.Io.Writer = .fixed(&whole);
    if (is_h2) {
        var block_buf: [128]u8 = undefined;
        var block: std.Io.Writer = .fixed(&block_buf);
        try hpack.writeInt(&block, 0x80, 7, 2); // :method GET
        try hpack.writeInt(&block, 0x80, 7, 7); // :scheme https
        try hpack.writeLiteral(&block, ":path", "/events");
        try hpack.writeLiteral(&block, ":authority", "localhost");
        try w.writeAll(h2.preface);
        try h2.writeSettings(w, &.{});
        try w.flush();
        try h2.writeHeaderBlock(w, 1, block.buffered(), true, h2.default_max_frame);
        try w.flush();
        // The answer's head, so the stream is open and seated.
        while (true) {
            const head = h2.Header.parse(try c.cr.interface.takeArray(h2.header_len));
            _ = try c.cr.interface.take(head.len);
            if (head.stream == 1 and head.type == .headers) break;
        }
        // A PING: a frame the connection reads and answers, and nothing more.
        try h2.writeHeader(&whole_w, 8, .ping, 0, 0);
        try whole_w.writeAll("12345678");
    } else {
        try w.writeAll("GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n");
        try w.flush();
        var seen: std.ArrayList(u8) = .empty;
        while (std.mem.indexOf(u8, seen.items, "\r\n\r\n") == null) {
            const got = try c.cr.interface.peekGreedy(1);
            try seen.appendSlice(a, got);
            c.cr.interface.toss(got.len);
        }
        // A masked text frame "a", which the loop says to the room.
        try whole_w.writeAll(&.{ 0x81, 0x81, 0, 0, 0, 0, 'a' });
    }

    try sendWholeThenPartial(c, whole_w.buffered(), partial);
    const poster = try std.Thread.spawn(.{}, postLater, .{io});
    defer poster.join();

    // The post has to be heard while the second record is still incomplete.
    // The client's receive limit is five seconds, so a server stuck in a
    // read for the rest of it fails here rather than waiting.
    var seen: std.ArrayList(u8) = .empty;
    while (std.mem.indexOf(u8, seen.items, "hello") == null) {
        if (is_h2) {
            const head = h2.Header.parse(try c.cr.interface.takeArray(h2.header_len));
            const payload = try c.cr.interface.take(head.len);
            if (head.type == .data) try seen.appendSlice(a, payload);
        } else {
            const got = try c.cr.interface.peekGreedy(1);
            try seen.appendSlice(a, got);
            c.cr.interface.toss(got.len);
        }
    }
}

test "an event posted while half a TLS record is in is written at once, on a WebSocket" {
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try serveSplit(gpa, threaded.io(), "http/1.1", 12);
}

test "an event posted while a TLS record header is in is written at once, on a WebSocket" {
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try serveSplit(gpa, threaded.io(), "http/1.1", 3);
}

test "an event posted while half a TLS record is in is written at once, on HTTP/2" {
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try serveSplit(gpa, threaded.io(), "h2", 12);
}

test "an event posted while a TLS record header is in is written at once, on HTTP/2" {
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try serveSplit(gpa, threaded.io(), "h2", 3);
}
