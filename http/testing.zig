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
//!     var app = nilo.App.init(testing.allocator);
//!     defer app.deinit();
//!     try app.get("/report.csv", report);
//!
//!     var client = nilo.testing.Client.init(testing.allocator, .{});
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

const app_mod = @import("app.zig");
const App = app_mod.App;
const bulkhead = @import("bulkhead.zig");
const fail = @import("fail.zig");
const str_mod = @import("nilo_core");

/// Whether the optimize-mode warning has already been given. One process
/// builds one nilo, so the answer is the same for every test in it.
var said_the_mode = false;

pub const Options = struct {
    /// The response buffer. A request whose answer does not fit gets a
    /// truncated one rather than a failure, so turn this up for a stream
    /// that produces a lot.
    response_bytes: usize = 64 * 1024,

    /// The address these requests appear to come from — what `c.peer()`
    /// answers, and what `c.clientIp()` falls back to.
    ///
    /// There is no socket here, so without this every request in a test
    /// arrives from nowhere. Middleware that counts requests per address,
    /// or refuses some of them, needs two different clients to be two
    /// different addresses before there is anything to test.
    client_address: []const u8 = "",
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
    /// The interim response that came before the final one, without its blank
    /// line — `HTTP/1.1 100 Continue` — or null if there was none.
    ///
    /// A real client reads one and keeps waiting, which is what the fields
    /// above do too: `status` is the final status whether or not an interim
    /// arrived. This is here so a test can assert the interim was sent, and so
    /// that one arriving cannot be mistaken for the answer (ADR 0094).
    interim: ?[]const u8 = null,

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

    /// The `n`th header of this name, counting from zero.
    ///
    /// `header` answers with the first, which is right for every header
    /// except the one a response is supposed to send more than one of — see
    /// `setCookie` below, and `http1.repeats`.
    pub fn headerAt(self: Answer, name: []const u8, n: usize) ?[]const u8 {
        var seen: usize = 0;
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = lines.next(); // the status line
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
            if (seen == n) return std.mem.trim(u8, line[colon + 1 ..], " \t");
            seen += 1;
        }
        return null;
    }

    /// How many headers of this name the response carries.
    pub fn headerCount(self: Answer, name: []const u8) usize {
        var n: usize = 0;
        while (self.headerAt(name, n) != null) n += 1;
        return n;
    }

    /// The whole `Set-Cookie` line that sets the cookie called `name`,
    /// attributes and all — or null if the response sets no such cookie.
    ///
    /// A response may set several, so asking by name is the only way to ask
    /// (ADR 0030).
    pub fn setCookie(self: Answer, name: []const u8) ?[]const u8 {
        var n: usize = 0;
        while (self.headerAt("Set-Cookie", n)) |line| : (n += 1) {
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (std.mem.eql(u8, line[0..equals], name)) return line;
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
    peer: bulkhead.Peer = .{},

    pub fn init(gpa: std.mem.Allocator, options: Options) !Client {
        // The one warning `listen()` gives that a test can also earn, and the
        // place it is worth most: a suite that runs in both optimize modes
        // and passes neither through to `b.dependency` is the case ADR 0084
        // was written about. Once per process, because a suite makes one of
        // these per test and the answer cannot change between them.
        if (!said_the_mode) {
            said_the_mode = true;
            app_mod.warnIfBuiltDifferently();
        }

        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .buffer = try gpa.alloc(u8, options.response_bytes),
            .peer = try bulkhead.Peer.from(options.client_address),
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

    /// A POST that says what its body is — which a form has to, because
    /// `application/x-www-form-urlencoded` and `multipart/form-data` are told
    /// apart by nothing else (ADR 0031).
    ///
    /// ```zig
    /// const answer = try client.postWith(
    ///     &app,
    ///     "/sign-in",
    ///     "application/x-www-form-urlencoded",
    ///     "email=wati%40example.dev&password=hunter2",
    /// );
    /// ```
    pub fn postWith(
        self: *Client,
        app: *App,
        path: []const u8,
        content_type: []const u8,
        body: []const u8,
    ) !Answer {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        try text.print(
            self.gpa,
            "POST {s} HTTP/1.1\r\nHost: test\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ path, content_type, body.len, body },
        );
        return self.send(app, text.items);
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
        //
        // **`checkServices` is deliberately not here** (ADR 0079). It was, for
        // an afternoon, and it refused a test that drives an App to fetch
        // `/openapi.json` and never touches the routes whose services are
        // missing — which is a fair thing to write and not a mistake. The
        // complaint it was answering was that nothing named the type; that is
        // answered where the route actually needs one, in `typed.zig`, which
        // has no false positive to have. `app.checkServices()` is public for a
        // test that wants the whole gate.
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
            // And nobody to post to it: a `receive` answers out of the fixed
            // buffer it was handed and never parks.
            .off,
            self.peer,
        );
        // One request, then everything it allocated goes — exactly as a
        // connection does between requests.
        self.lifetime.end();
        defer _ = self.arena.reset(.retain_capacity);

        return parse(out.buffered(), keep_alive);
    }
};

fn parse(raw: []const u8, keep_alive: bool) !Answer {
    // A 100 is a response that is not the answer: the client reads it, drops
    // it and goes on waiting (RFC 9110 §15.2). Doing that here rather than in
    // every caller is what keeps `answer.status` meaning the same thing before
    // and after a request carried `Expect: 100-continue`.
    //
    // 100 by name rather than 1xx, because the other one nilo sends is a 101
    // and that *is* the answer — the connection stops being HTTP under it.
    var rest = raw;
    var interim: ?[]const u8 = null;
    if (std.mem.startsWith(u8, rest, "HTTP/1.1 100 ")) {
        const ends = std.mem.indexOf(u8, rest, "\r\n\r\n") orelse return error.NoHead;
        interim = rest[0..ends];
        rest = rest[ends + 4 ..];
    }

    const split = std.mem.indexOf(u8, rest, "\r\n\r\n") orelse return error.NoHead;
    const raw_final = rest;
    const head = rest[0..split];
    const first_line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const line = head[0..first_line_end];

    // `HTTP/1.1 200 OK` — the status is between the two spaces.
    const after_version = (std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadStatusLine) + 1;
    const digits_end = std.mem.indexOfScalarPos(u8, line, after_version, ' ') orelse line.len;
    const status = std.fmt.parseInt(u16, line[after_version..digits_end], 10) catch return error.BadStatusLine;

    var answer = Answer{
        // `raw` is everything that went on the wire, interim included, because
        // a test asking for the raw bytes is asking what the client saw.
        .raw = raw,
        .head = head,
        .body = raw_final[split + 4 ..],
        .status = status,
        .keep_alive = keep_alive,
        .chunked = false,
        .interim = interim,
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
