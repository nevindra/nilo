//! Driving one request into an App, for a test that has no server.
//!
//! Most handlers need none of this: a handler is an ordinary function, so a
//! test calls it and looks at what came back. That stops working the moment
//! a handler *writes* its answer rather than returning one — a stream has to
//! have somewhere to write to (ADR 0020) — and it was already awkward for
//! anything that wanted to check a header or a status.
//!
//! ```zig
//! test "the report streams its rows" {
//!     var app = zfast.App.init(testing.allocator);
//!     defer app.deinit();
//!     try app.get("/report.csv", report);
//!
//!     var client = zfast.testing.Client.init(testing.allocator, .{});
//!     defer client.deinit();
//!
//!     const answer = try client.get(&app, "/report.csv");
//!     try testing.expectEqual(@as(u16, 200), answer.status);
//!     try testing.expect(answer.chunked);
//! }
//! ```
//!
//! Nothing here belongs in a running server, and none of it is on the
//! request path.

const std = @import("std");

const App = @import("app.zig").App;
const fail = @import("fail.zig");
const str_mod = @import("str.zig");

pub const Options = struct {
    /// The response buffer. A request whose answer does not fit gets a
    /// truncated one rather than a failure, so turn this up for a stream
    /// that produces a lot.
    response_bytes: usize = 64 * 1024,
};

/// One answer, taken apart far enough to ask questions of.
pub const Answer = struct {
    /// Everything, exactly as it went on the wire.
    raw: []const u8,
    /// The status line and headers, without the blank line after them.
    head: []const u8,
    /// What follows the head. For a chunked response this is still framed —
    /// use `text` for the bytes a client would see.
    body: []const u8,
    status: u16,
    /// Whether the connection may carry another request.
    keep_alive: bool,
    /// Whether the body arrived in chunks, which is what a stream does.
    chunked: bool,

    /// The value of a response header, or null if it is not there.
    pub fn header(self: Answer, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = lines.next(); // the status line
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
        }
        return null;
    }

    /// The body as the client sees it: chunk framing removed if there was
    /// any, and the bytes as they are otherwise.
    pub fn text(self: Answer, into: []u8) ![]const u8 {
        if (!self.chunked) {
            if (self.body.len > into.len) return error.NoRoom;
            @memcpy(into[0..self.body.len], self.body);
            return into[0..self.body.len];
        }
        var written: usize = 0;
        var rest = self.body;
        while (true) {
            const crlf = std.mem.indexOf(u8, rest, "\r\n") orelse return error.BadChunk;
            const size = std.fmt.parseInt(usize, rest[0..crlf], 16) catch return error.BadChunk;
            if (size == 0) return into[0..written];
            const start = crlf + 2;
            if (start + size > rest.len) return error.BadChunk;
            if (written + size > into.len) return error.NoRoom;
            @memcpy(into[written..][0..size], rest[start..][0..size]);
            written += size;
            rest = rest[start + size + 2 ..];
        }
    }
};

/// A stand-in for a client on the other end of a connection.
pub const Client = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    lifetime: str_mod.Lifetime = .{},
    in_flight: fail.InFlight = .{},
    buffer: []u8,

    pub fn init(gpa: std.mem.Allocator, options: Options) !Client {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .buffer = try gpa.alloc(u8, options.response_bytes),
        };
    }

    pub fn deinit(self: *Client) void {
        self.gpa.free(self.buffer);
        self.arena.deinit();
    }

    pub fn get(self: *Client, app: *App, path: []const u8) !Answer {
        return self.request(app, "GET", path, "");
    }

    pub fn post(self: *Client, app: *App, path: []const u8, body: []const u8) !Answer {
        return self.request(app, "POST", path, body);
    }

    pub fn request(
        self: *Client,
        app: *App,
        method: []const u8,
        path: []const u8,
        body: []const u8,
    ) !Answer {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        try text.print(
            self.gpa,
            "{s} {s} HTTP/1.1\r\nHost: test\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ method, path, body.len, body },
        );
        return self.send(app, text.items);
    }

    /// The whole request, written out. For a version, a header or a shape
    /// the helpers above do not cover.
    pub fn send(self: *Client, app: *App, raw_request: []const u8) !Answer {
        // What `listen()` would have done. Idempotent, so calling it once
        // per request costs nothing after the first.
        try app.resolveChains();

        var in = std.Io.Reader.fixed(raw_request);
        var out = std.Io.Writer.fixed(self.buffer);
        const keep_alive = app.handleRequest(
            self.arena.allocator(),
            &self.lifetime,
            &self.in_flight,
            &in,
            &out,
            // There is no socket here, so there is nothing to time out.
            .off,
        );
        // One request, then everything it allocated goes — exactly as a
        // connection does between requests.
        self.lifetime.end();
        defer _ = self.arena.reset(.retain_capacity);

        return parse(out.buffered(), keep_alive);
    }
};

fn parse(raw: []const u8, keep_alive: bool) !Answer {
    const split = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.NoHead;
    const head = raw[0..split];
    const first_line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const line = head[0..first_line_end];

    // `HTTP/1.1 200 OK` — the status is between the two spaces.
    const after_version = (std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadStatusLine) + 1;
    const digits_end = std.mem.indexOfScalarPos(u8, line, after_version, ' ') orelse line.len;
    const status = std.fmt.parseInt(u16, line[after_version..digits_end], 10) catch return error.BadStatusLine;

    var answer = Answer{
        .raw = raw,
        .head = head,
        .body = raw[split + 4 ..],
        .status = status,
        .keep_alive = keep_alive,
        .chunked = false,
    };
    if (answer.header("Transfer-Encoding")) |te| {
        answer.chunked = std.ascii.indexOfIgnoreCase(te, "chunked") != null;
    }
    return answer;
}

// ---- tests ----

const testing = std.testing;

fn plain(c: *@import("ctx.zig").Ctx) anyerror!void {
    try c.setStaticHeader("X-Note", "hello");
    try c.sendText(201, "body text");
}

fn streamed(c: *@import("ctx.zig").Ctx) anyerror!void {
    var body = try c.stream(200, "text/plain");
    try body.writeAll("one ");
    try body.flush();
    try body.writeAll("two");
    try body.finish();
}

test "an ordinary answer is taken apart into status, headers and body" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/thing", plain);

    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/thing");
    try testing.expectEqual(@as(u16, 201), answer.status);
    try testing.expectEqualStrings("hello", answer.header("X-Note").?);
    try testing.expectEqualStrings("text/plain", answer.header("content-type").?);
    try testing.expect(answer.header("X-Absent") == null);
    try testing.expectEqualStrings("body text", answer.body);
    try testing.expect(answer.keep_alive);
    try testing.expect(!answer.chunked);
}

test "a chunked answer reassembles into what the handler wrote" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/stream", streamed);

    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/stream");
    try testing.expect(answer.chunked);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("one two", try answer.text(&buf));
}

test "a client can be used for more than one request" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/thing", plain);

    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    for (0..3) |_| {
        const answer = try client.get(&app, "/thing");
        try testing.expectEqual(@as(u16, 201), answer.status);
    }
}
