//! HTTP/1.1 parser: request line, headers, keep-alive, and reading or
//! discarding a body — Content-Length or chunked.
//!
//! The hot path is zero-copy: the whole head (request line + headers) is
//! waited for until it is complete in the reader's buffer, its end is
//! found once, and then it is parsed in place. `Request` only holds
//! slices into that buffer — not a single byte is copied and nothing is
//! allocated.
//!
//! This layer only ever sees `std.Io.Reader`/`std.Io.Writer`, so it has
//! no idea which Engine is underneath it.

const std = @import("std");

pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    PATCH,
    OPTIONS,
    other,
};

pub fn methodFrom(name: []const u8) Method {
    return std.meta.stringToEnum(Method, name) orelse .other;
}

pub const ParseError = error{
    BadRequestLine,
    BadHeader,
    UnsupportedVersion,
};

pub const Request = struct {
    /// Slices into the reader's buffer. Valid until the next read from the
    /// same connection (including `discardBody`) — after that the contents
    /// may be overwritten. Longer lifetimes come from the request arena and
    /// `Str` (ADR 0004).
    method: []const u8 = "",
    target: []const u8 = "",

    /// 0 for HTTP/1.0, 1 for HTTP/1.1.
    minor_version: u1 = 1,
    keep_alive: bool = true,
    content_length: u64 = 0,
    chunked: bool = false,
};

/// Read one complete request head from the reader and parse it in place.
/// The body is not read yet; call `discardBody` afterwards.
///
/// `error.HeadTooLong` means the head does not fit in the reader's buffer
/// — answer with 431. `error.EndOfStream` before the first byte is a
/// keep-alive connection the client closed: a normal way home.
pub fn readRequest(in: *std.Io.Reader) !Request {
    const head = try readHead(in);
    var r = Request{};
    try parseHead(head, &r);
    in.toss(head.len);
    return r;
}

/// Discard a request body nobody read, so the keep-alive connection is
/// clean for the next request.
///
/// `limit` bounds a chunked body only: a Content-Length body announces its
/// own size up front, while a chunked one could otherwise be streamed at us
/// forever by a client that has worked out we will sit here reading it.
pub fn discardBody(in: *std.Io.Reader, r: *const Request, limit: u64) !void {
    if (r.chunked) return discardChunkedBody(in, limit);
    if (r.content_length > 0) try in.discardAll64(r.content_length);
}

// ---- chunked transfer encoding ----
//
// `5\r\nhello\r\n0\r\n\r\n` — a size in hex, that many bytes, repeat, and a
// zero-sized chunk ends it. What comes after the last chunk is trailers:
// headers held back until the body was finished. zfast reads them only far
// enough to get past them, because a trailer arrives after the handler has
// already been given the body, so there is nothing left to do with it.

/// Read a chunked body into one contiguous slice from `gpa`.
pub fn readChunkedBody(in: *std.Io.Reader, gpa: std.mem.Allocator, limit: usize) ![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    while (true) {
        const size = try readChunkSize(in);
        if (size == 0) break;
        if (size > limit - body.items.len) return error.BodyTooLarge;
        const dst = try body.addManyAsSlice(gpa, @intCast(size));
        try in.readSliceAll(dst);
        try endOfChunk(in);
    }
    try skipTrailers(in);
    return body.items;
}

pub fn discardChunkedBody(in: *std.Io.Reader, limit: u64) !void {
    var seen: u64 = 0;
    while (true) {
        const size = try readChunkSize(in);
        if (size == 0) break;
        seen += size;
        if (seen > limit) return error.BodyTooLarge;
        try in.discardAll64(size);
        try endOfChunk(in);
    }
    try skipTrailers(in);
}

/// The size line of a chunk. Anything after a `;` is a chunk extension —
/// nobody sends them, but the size in front of one is still a valid size.
fn readChunkSize(in: *std.Io.Reader) !u64 {
    const line = takeLine(in) catch return error.BadChunk;
    const end = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
    const digits = std.mem.trim(u8, line[0..end], " \t");
    if (digits.len == 0) return error.BadChunk;
    return std.fmt.parseInt(u64, digits, 16) catch error.BadChunk;
}

/// A chunk's data is followed by its own CRLF. Anything else means the
/// stream and the sizes have drifted apart, and everything read after that
/// point would be someone else's bytes.
fn endOfChunk(in: *std.Io.Reader) !void {
    const line = takeLine(in) catch return error.BadChunk;
    if (line.len != 0) return error.BadChunk;
}

fn skipTrailers(in: *std.Io.Reader) !void {
    while (true) {
        // A client that closes straight after the last chunk has still
        // sent a complete body; there is nothing to gain by failing here.
        const line = takeLine(in) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (line.len == 0) return;
    }
}

fn takeLine(in: *std.Io.Reader) ![]const u8 {
    const raw = try in.takeDelimiterInclusive('\n');
    return trimCR(raw[0 .. raw.len - 1]);
}

pub const Header = struct { name: []const u8, value: []const u8 };

/// Headers the framework writes itself. A response carrying two of any of
/// these is not merely untidy — a duplicated `Content-Length` is the
/// classic request-smuggling bug — so `Ctx.setHeader` refuses them.
pub fn isReservedHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-type") or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "connection");
}

/// Iterate every header in a head (the request line is skipped), for
/// layers that need all the headers, not just the ones the parser uses.
pub const HeaderIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub const Pair = Header;

    pub fn from(head: []const u8) HeaderIterator {
        var lines = std.mem.splitScalar(u8, head, '\n');
        _ = lines.next(); // the request line
        return .{ .lines = lines };
    }

    pub fn next(self: *HeaderIterator) ?Pair {
        const line = trimCR(self.lines.next() orelse return null);
        if (line.len == 0) return null;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        return .{
            .name = line[0..colon],
            .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
        };
    }
};

/// Wait until one complete head (up to the blank line) is in the buffer,
/// then return a slice of it without copying and without advancing the
/// reader. The caller decides when to `in.toss(head.len)`.
pub fn readHead(in: *std.Io.Reader) ![]const u8 {
    while (true) {
        const buf = in.buffered();
        if (findEndOfHead(buf)) |end| return buf[0..end];
        if (buf.len >= in.buffer.len) return error.HeadTooLong;
        try in.fillMore();
    }
}

/// The index just past the blank line that ends the head, if it is
/// complete. Accepts CRLF as well as a bare LF.
fn findEndOfHead(buf: []const u8) ?usize {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, buf, i, '\n')) |nl| {
        if (nl + 1 < buf.len and buf[nl + 1] == '\n') return nl + 2;
        if (nl + 2 < buf.len and buf[nl + 1] == '\r' and buf[nl + 2] == '\n') return nl + 3;
        i = nl + 1;
    }
    return null;
}

pub fn parseHead(head: []const u8, r: *Request) ParseError!void {
    var lines = std.mem.splitScalar(u8, head, '\n');

    const first = trimCR(lines.next() orelse return error.BadRequestLine);
    try parseRequestLine(first, r);

    while (lines.next()) |raw| {
        const line = trimCR(raw);
        if (line.len == 0) return;
        try applyHeader(line, r);
    }
}

pub fn parseRequestLine(line: []const u8, r: *Request) ParseError!void {
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadRequestLine;
    const sp2 = std.mem.indexOfScalarPos(u8, line, sp1 + 1, ' ') orelse return error.BadRequestLine;

    const method = line[0..sp1];
    const target = line[sp1 + 1 .. sp2];
    const version = line[sp2 + 1 ..];
    if (method.len == 0 or target.len == 0) return error.BadRequestLine;

    if (std.mem.eql(u8, version, "HTTP/1.1")) {
        r.minor_version = 1;
        r.keep_alive = true;
    } else if (std.mem.eql(u8, version, "HTTP/1.0")) {
        r.minor_version = 0;
        r.keep_alive = false;
    } else {
        return error.UnsupportedVersion;
    }

    r.method = method;
    r.target = target;
}

pub fn applyHeader(line: []const u8, r: *Request) ParseError!void {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
    const name = line[0..colon];
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

    // Ordered by how often they show up; the name length is checked first
    // so the case-insensitive compare almost always runs just once.
    switch (name.len) {
        "connection".len => if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) {
                r.keep_alive = false;
            } else if (std.ascii.eqlIgnoreCase(value, "keep-alive")) {
                r.keep_alive = true;
            }
        },
        "content-length".len => if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            r.content_length = std.fmt.parseInt(u64, value, 10) catch return error.BadHeader;
        },
        "transfer-encoding".len => if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) r.chunked = true;
        },
        else => {},
    }
}

pub fn statusPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Content Too Large",
        422 => "Unprocessable Content",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        else => "",
    };
}

/// Assemble a whole response as a compile-time constant — for responses
/// with fixed contents, this turns writing one into a single `writeAll`
/// with no formatting.
pub fn staticResponse(
    comptime status: u16,
    comptime phrase: []const u8,
    comptime content_type: []const u8,
    comptime body: []const u8,
    comptime keep_alive: bool,
) []const u8 {
    return std.fmt.comptimePrint(
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n{s}",
        .{ status, phrase, content_type, body.len, if (keep_alive) "keep-alive" else "close", body },
    );
}

/// The cold path, for responses whose contents are only known at runtime.
/// `extra` are headers a handler or middleware added; the framework's own
/// three go out first and `extra` may not repeat them.
pub fn writeResponse(
    out: *std.Io.Writer,
    status: u16,
    phrase: []const u8,
    content_type: []const u8,
    body: []const u8,
    keep_alive: bool,
    extra: []const Header,
) !void {
    try writeHead(out, status, phrase, content_type, body.len, keep_alive, extra);
    try out.writeAll(body);
    try out.flush();
}

/// The response to a HEAD: the head has to be byte-for-byte what a GET
/// would have produced — including the `Content-Length` naming the length
/// of the body it would have sent — but the body itself does not follow.
pub fn writeResponseHeadOnly(
    out: *std.Io.Writer,
    status: u16,
    phrase: []const u8,
    content_type: []const u8,
    body_len: usize,
    keep_alive: bool,
    extra: []const Header,
) !void {
    try writeHead(out, status, phrase, content_type, body_len, keep_alive, extra);
    try out.flush();
}

fn writeHead(
    out: *std.Io.Writer,
    status: u16,
    phrase: []const u8,
    content_type: []const u8,
    body_len: usize,
    keep_alive: bool,
    extra: []const Header,
) !void {
    try out.print(
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n",
        .{ status, phrase, content_type, body_len, if (keep_alive) "keep-alive" else "close" },
    );
    for (extra) |h| try out.print("{s}: {s}\r\n", .{ h.name, h.value });
    try out.writeAll("\r\n");
}

fn trimCR(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

const testing = std.testing;

test "a plain HTTP/1.1 GET defaults to keep-alive" {
    var in = std.Io.Reader.fixed("GET /hello HTTP/1.1\r\nHost: example\r\n\r\n");
    const r = try readRequest(&in);
    try testing.expectEqualStrings("GET", r.method);
    try testing.expectEqualStrings("/hello", r.target);
    try testing.expect(r.keep_alive);
    try testing.expectEqual(@as(u64, 0), r.content_length);
}

test "HTTP/1.0 defaults to close, keep-alive when asked for" {
    var in = std.Io.Reader.fixed("GET / HTTP/1.0\r\n\r\n");
    const r = try readRequest(&in);
    try testing.expect(!r.keep_alive);

    var in2 = std.Io.Reader.fixed("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
    const r2 = try readRequest(&in2);
    try testing.expect(r2.keep_alive);
}

test "Connection: close turns keep-alive off" {
    var in = std.Io.Reader.fixed("GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
    const r = try readRequest(&in);
    try testing.expect(!r.keep_alive);
}

test "Content-Length is read and the body is discarded" {
    var in = std.Io.Reader.fixed("POST /send HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloGET");
    const r = try readRequest(&in);
    try testing.expectEqualStrings("POST", r.method);
    try testing.expectEqual(@as(u64, 5), r.content_length);
    try discardBody(&in, &r, 1024);
    try testing.expectEqualStrings("GET", try in.take(3));
}

test "two requests back to back on one connection" {
    var in = std.Io.Reader.fixed("GET /one HTTP/1.1\r\n\r\nGET /two HTTP/1.1\r\nConnection: close\r\n\r\n");
    const r1 = try readRequest(&in);
    try testing.expectEqualStrings("/one", r1.target);
    const r2 = try readRequest(&in);
    try testing.expectEqualStrings("/two", r2.target);
    try testing.expect(!r2.keep_alive);
}

test "bare LF line endings are still accepted" {
    var in = std.Io.Reader.fixed("GET / HTTP/1.1\nHost: example\n\n");
    const r = try readRequest(&in);
    try testing.expectEqualStrings("GET", r.method);
}

test "a head with no end does not produce a half parse" {
    // With Reader.fixed the buffer is exactly the size of the data, so a
    // head that never ends is detected as a full buffer. On a real
    // connection with a roomy buffer, the same case ends in
    // error.EndOfStream when the client closes.
    var in = std.Io.Reader.fixed("GET / HTTP/1.1\r\nHost: example\r\n");
    try testing.expectError(error.HeadTooLong, readRequest(&in));
}

test "a chunked body is reassembled" {
    var in = std.Io.Reader.fixed(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n1\r\n \r\n5\r\nworld\r\n0\r\n\r\nGET",
    );
    const r = try readRequest(&in);
    try testing.expect(r.chunked);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try readChunkedBody(&in, arena.allocator(), 1024);
    try testing.expectEqualStrings("hello world", body);
    // The connection is left exactly at the next request.
    try testing.expectEqualStrings("GET", try in.take(3));
}

test "chunk extensions and trailers are stepped over" {
    var in = std.Io.Reader.fixed(
        "4;name=value\r\nzfas\r\n0\r\nX-Checksum: abc\r\n\r\nNEXT",
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("zfas", try readChunkedBody(&in, arena.allocator(), 1024));
    try testing.expectEqualStrings("NEXT", try in.take(4));
}

test "a chunked body nobody read is discarded so the connection survives" {
    var in = std.Io.Reader.fixed(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "3\r\nabc\r\n0\r\n\r\nGET /next HTTP/1.1\r\n\r\n",
    );
    const r = try readRequest(&in);
    try discardBody(&in, &r, 1024);
    const next = try readRequest(&in);
    try testing.expectEqualStrings("/next", next.target);
}

test "a chunked body over the limit is refused rather than swallowed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var in = std.Io.Reader.fixed("5\r\nhello\r\n0\r\n\r\n");
    try testing.expectError(error.BodyTooLarge, readChunkedBody(&in, arena.allocator(), 4));

    var discarding = std.Io.Reader.fixed("5\r\nhello\r\n0\r\n\r\n");
    try testing.expectError(error.BodyTooLarge, discardChunkedBody(&discarding, 4));
}

test "a size that is not hex, or data that does not end where it said" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var bad_size = std.Io.Reader.fixed("zz\r\nhello\r\n0\r\n\r\n");
    try testing.expectError(error.BadChunk, readChunkedBody(&bad_size, arena.allocator(), 1024));

    // Says 5 bytes, then does not put a CRLF where one has to be. Trusting
    // the size past that point would hand the next request someone else's
    // bytes — the shape of a smuggled request.
    var drifted = std.Io.Reader.fixed("5\r\nhelloXX\r\n0\r\n\r\n");
    try testing.expectError(error.BadChunk, readChunkedBody(&drifted, arena.allocator(), 1024));
}

test "a broken request line" {
    var r = Request{};
    try testing.expectError(error.BadRequestLine, parseRequestLine("GET /", &r));
    try testing.expectError(error.UnsupportedVersion, parseRequestLine("GET / HTTP/2.0", &r));
    try testing.expectError(error.UnsupportedVersion, parseRequestLine("GET / HTTP/1.1 x", &r));
}

test "a header with no colon" {
    var r = Request{};
    try testing.expectError(error.BadHeader, applyHeader("Host no-colon", &r));
}

test "staticResponse and writeResponse produce the same bytes" {
    const fixed = comptime staticResponse(200, "OK", "text/plain", "hello\n", true);
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try writeResponse(&out, 200, "OK", "text/plain", "hello\n", true, &.{});
    try testing.expectEqualStrings(fixed, out.buffered());
}

test "writeResponseHeadOnly matches writeResponse's head but sends no body" {
    var full_buf: [256]u8 = undefined;
    var full = std.Io.Writer.fixed(&full_buf);
    try writeResponse(&full, 200, "OK", "text/plain", "hello\n", true, &.{});

    var head_buf: [256]u8 = undefined;
    var head = std.Io.Writer.fixed(&head_buf);
    try writeResponseHeadOnly(&head, 200, "OK", "text/plain", "hello\n".len, true, &.{});

    try testing.expectEqualStrings(full.buffered()[0 .. full.buffered().len - "hello\n".len], head.buffered());
}

test "extra headers go out after the framework's own" {
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try writeResponse(&out, 200, "OK", "text/plain", "hi", true, &.{
        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
        .{ .name = "Vary", .value = "Origin" },
    });
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n" ++
            "Connection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\nVary: Origin\r\n\r\nhi",
        out.buffered(),
    );
}

test "the framework's own headers are reserved" {
    try testing.expect(isReservedHeader("Content-Length"));
    try testing.expect(isReservedHeader("content-type"));
    try testing.expect(isReservedHeader("CONNECTION"));
    try testing.expect(!isReservedHeader("Vary"));
}
