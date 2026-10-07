//! A client for the HTTP/2 connection, written the way the ones measured write:
//! preface, SETTINGS, then frames, all into one buffer the connection reads as
//! if from a socket, and the frames it wrote back, decoded.
//!
//! Test support, shared by `h2conn.zig`'s own tests and by `behaviour.zig`,
//! which runs the same requests over both framings and expects the same
//! answer (ADR 259). It sits above the App's core, since it names `App`, and
//! `http_above_core` in build.zig says so.

const std = @import("std");
const h2 = @import("h2.zig");
const hpack = @import("hpack.zig");
const h2conn = @import("h2conn.zig");
const App = @import("app.zig").App;

const testing = std.testing;
const serveConnection = h2conn.serveConnection;

/// A client written the way the ones measured write: preface, SETTINGS, then
/// frames, all into one buffer the connection reads as if from a socket.
pub const TestClient = struct {
    buf: std.Io.Writer.Allocating,

    pub fn init() !TestClient {
        var c: TestClient = .{ .buf = .init(testing.allocator) };
        try c.buf.writer.writeAll(h2.preface);
        try h2.writeSettings(&c.buf.writer, &.{});
        return c;
    }

    pub fn deinit(c: *TestClient) void {
        c.buf.deinit();
    }

    pub fn w(c: *TestClient) *std.Io.Writer {
        return &c.buf.writer;
    }

    pub fn headersFor(c: *TestClient, stream: u31, path: []const u8, extra: []const hpack.Field, end_stream: bool) !void {
        var block: std.Io.Writer.Allocating = .init(testing.allocator);
        defer block.deinit();
        try hpack.writeInt(&block.writer, 0x80, 7, 3); // :method POST
        try hpack.writeInt(&block.writer, 0x80, 7, 6); // :scheme http
        try hpack.writeLiteral(&block.writer, ":path", path);
        try hpack.writeLiteral(&block.writer, ":authority", "localhost");
        try hpack.writeLiteral(&block.writer, "content-type", "application/grpc");
        try hpack.writeLiteral(&block.writer, "te", "trailers");
        for (extra) |f| try hpack.writeLiteral(&block.writer, f.name, f.value);
        try h2.writeHeaderBlock(c.w(), stream, block.written(), end_stream, h2.default_max_frame);
    }

    pub fn message(c: *TestClient, stream: u31, bytes: []const u8, compressed: bool) !void {
        try h2.writeHeader(c.w(), 5 + bytes.len, .data, h2.Flags.end_stream, stream);
        try c.w().writeByte(if (compressed) 1 else 0);
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(bytes.len), .big);
        try c.w().writeAll(&len);
        try c.w().writeAll(bytes);
    }

    /// `message`, over as many DATA frames as a message larger than one
    /// frame takes.
    pub fn messageInFrames(c: *TestClient, stream: u31, bytes: []const u8, compressed: bool) !void {
        var framed_: std.Io.Writer.Allocating = .init(testing.allocator);
        defer framed_.deinit();
        try framed_.writer.writeByte(if (compressed) 1 else 0);
        try framed_.writer.writeInt(u32, @intCast(bytes.len), .big);
        try framed_.writer.writeAll(bytes);
        var rest = framed_.written();
        while (rest.len > 0) {
            const n = @min(rest.len, 16_000);
            try h2.writeHeader(c.w(), n, .data, if (n == rest.len) h2.Flags.end_stream else 0, stream);
            try c.w().writeAll(rest[0..n]);
            rest = rest[n..];
        }
    }

    pub fn call(c: *TestClient, stream: u31, path: []const u8, bytes: []const u8) !void {
        try c.headersFor(stream, path, &.{}, false);
        try c.message(stream, bytes, false);
    }
};

pub const Frame = struct { head: h2.Header, payload: []const u8 };

/// What the server wrote, frame by frame, header blocks decoded.
pub const Answer = struct {
    arena: std.heap.ArenaAllocator,
    frames: std.ArrayList(Frame) = .empty,
    decoder: hpack.Decoder,

    pub fn deinit(self: *Answer) void {
        self.decoder.deinit();
        self.arena.deinit();
    }

    pub fn of(t: h2.Type, self: *const Answer, stream: u31) []const Frame {
        var out: std.ArrayList(Frame) = .empty;
        for (self.frames.items) |f| if (f.head.type == t and f.head.stream == stream)
            out.append(@constCast(&self.arena).allocator(), f) catch unreachable;
        return out.items;
    }

    pub fn fields(self: *Answer, block: []const u8) ![]const hpack.Field {
        var out: std.ArrayList(hpack.Field) = .empty;
        _ = try self.decoder.decode(block, self.arena.allocator(), &out, 1 << 20);
        return out.items;
    }

    pub fn value(fs: []const hpack.Field, name: []const u8) ?[]const u8 {
        for (fs) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }

    /// The trailers of a call: its last HEADERS frame's fields.
    pub fn trailers(self: *Answer, stream: u31) ![]const hpack.Field {
        const hs = of(.headers, self, stream);
        if (hs.len == 0) return error.NoHeaders;
        return self.fields(hs[hs.len - 1].payload);
    }

    pub fn message(self: *Answer, stream: u31) ![]const u8 {
        var all: std.ArrayList(u8) = .empty;
        for (of(.data, self, stream)) |f| try all.appendSlice(self.arena.allocator(), f.payload);
        if (all.items.len < 5) return error.NoMessage;
        return all.items[5..];
    }

    pub fn goaway(self: *const Answer) ?h2.ErrorCode {
        for (self.frames.items) |f| if (f.head.type == .goaway)
            return @enumFromInt(std.mem.readInt(u32, f.payload[4..8], .big));
        return null;
    }

    pub fn rst(self: *const Answer, stream: u31) ?h2.ErrorCode {
        for (self.frames.items) |f| if (f.head.type == .rst_stream and f.head.stream == stream)
            return @enumFromInt(std.mem.readInt(u32, f.payload[0..4], .big));
        return null;
    }
};

pub fn converse(app: *App, client: *TestClient) !Answer {
    var in: std.Io.Reader = .fixed(client.buf.written());
    return converseFrom(app, &in);
}

pub fn converseFrom(app: *App, in: *std.Io.Reader) !Answer {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    serveConnection(app.grpcHost(), in, &out.writer, .off, .off, .{});
    return answerOf(out.written());
}

/// The frames in what a connection wrote.
pub fn answerOf(written: []const u8) !Answer {
    var answer_: Answer = .{ .arena = .init(testing.allocator), .decoder = .init(testing.allocator) };
    const a = answer_.arena.allocator();
    var rest = try a.dupe(u8, written);
    while (rest.len >= h2.header_len) {
        const head = h2.Header.parse(rest[0..h2.header_len]);
        const end = h2.header_len + head.len;
        try answer_.frames.append(a, .{ .head = head, .payload = rest[h2.header_len..end] });
        rest = rest[end..];
    }
    return answer_;
}


/// One ordinary request, as a client writes it.
pub const Request = struct {
    method: []const u8 = "GET",
    path: []const u8 = "/",
    /// Regular fields, in the order written, after the four pseudo-headers.
    fields: []const hpack.Field = &.{},
    body: []const u8 = "",
    /// HEADERS that do not end the stream although there is no body to send
    /// after them yet: a request whose client is still to send it.
    open: bool = false,
    /// The body split across DATA frames of at most this many bytes.
    frame: usize = 16_000,
    /// The client's SETTINGS_INITIAL_WINDOW_SIZE, when it is not the default,
    /// with the WINDOW_UPDATEs a client reading the answer would send after
    /// it, so the answer is written across several of them.
    window: ?u32 = null,
};

/// What came back for one stream: the final head, the body, the trailers, and
/// the interim statuses before the head. Borrowed from `answer`.
pub const Exchange = struct {
    answer: Answer,
    status: u16,
    headers: []const hpack.Field,
    body: []const u8,
    trailers: []const hpack.Field,
    interim: []const u16,

    pub fn deinit(self: *Exchange) void {
        self.answer.deinit();
    }

    pub fn header(self: *const Exchange, name: []const u8) ?[]const u8 {
        return Answer.value(self.headers, name);
    }
};

pub fn requestOn(c: *TestClient, stream: u31, req: Request) !void {
    var block: std.Io.Writer.Allocating = .init(testing.allocator);
    defer block.deinit();
    try hpack.writeLiteral(&block.writer, ":method", req.method);
    try hpack.writeInt(&block.writer, 0x80, 7, 6); // :scheme http
    try hpack.writeLiteral(&block.writer, ":path", req.path);
    try hpack.writeLiteral(&block.writer, ":authority", "localhost");
    for (req.fields) |f| try hpack.writeLiteral(&block.writer, f.name, f.value);
    const bodiless = req.body.len == 0 and !req.open;
    try h2.writeHeaderBlock(c.w(), stream, block.written(), bodiless, h2.default_max_frame);
    var rest = req.body;
    while (rest.len > 0) {
        const n = @min(rest.len, req.frame);
        try h2.writeHeader(c.w(), n, .data, if (n == rest.len) h2.Flags.end_stream else 0, stream);
        try c.w().writeAll(rest[0..n]);
        rest = rest[n..];
    }
}

/// What the connection answered on `stream`, decoded, or an error if there is
/// no head to read.
pub fn exchangeOf(answer: Answer, stream: u31) !Exchange {
    var self = answer;
    var interim: std.ArrayList(u16) = .empty;
    var final: ?[]const hpack.Field = null;
    var trailers: []const hpack.Field = &.{};
    for (Answer.of(.headers, &self, stream)) |f| {
        const fields = try self.fields(f.payload);
        if (final != null) {
            trailers = fields;
            continue;
        }
        const status = try std.fmt.parseInt(u16, Answer.value(fields, ":status") orelse return error.NoStatus, 10);
        if (status >= 100 and status < 200) {
            try interim.append(self.arena.allocator(), status);
            continue;
        }
        final = fields;
    }
    const fields = final orelse return error.NoHeaders;
    var all: std.ArrayList(u8) = .empty;
    for (Answer.of(.data, &self, stream)) |f| try all.appendSlice(self.arena.allocator(), f.payload);
    var headers: std.ArrayList(hpack.Field) = .empty;
    for (fields) |f| if (f.name.len > 0 and f.name[0] != ':') try headers.append(self.arena.allocator(), f);
    return .{
        .answer = self,
        .status = try std.fmt.parseInt(u16, Answer.value(fields, ":status").?, 10),
        .headers = headers.items,
        .body = all.items,
        .trailers = trailers,
        .interim = interim.items,
    };
}

/// One request on a connection of its own, and its answer.
pub fn roundTrip(app: *App, req: Request) !Exchange {
    var client = try TestClient.init();
    defer client.deinit();
    if (req.window) |window| try h2.writeSettings(client.w(), &.{.{ .initial_window_size, window }});
    try requestOn(&client, 1, req);
    if (req.window != null) {
        try h2.writeWindowUpdate(client.w(), 0, 100_000);
        try h2.writeWindowUpdate(client.w(), 1, 100_000);
    }
    return exchangeOf(try converse(app, &client), 1);
}
