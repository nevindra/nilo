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
const scan = @import("scan.zig");
const bulkhead = @import("bulkhead.zig");

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
    /// Whether `Connection` mentions an upgrade — so this connection may stop
    /// being HTTP and start being read by something else (ADR 0022).
    ///
    /// Deliberately looser than `websocket.isUpgrade`, which also insists on
    /// `Upgrade: websocket`: what this answers is "might this connection be
    /// read from again", and the only wrong answer is a false negative.
    upgrade: bool = false,
};

/// Whether anything is going to read from the connection again while this
/// request is being answered — a body, or a protocol taking the socket over.
///
/// `App` uses it to decide whether the head has to be copied out of the
/// connection's buffer, which is where every `Str` from it points.
pub fn readsMore(r: *const Request) bool {
    return r.content_length > 0 or r.chunked or r.upgrade;
}

/// Read one complete request head from the reader and parse it in place.
/// The body is not read yet; call `discardBody` afterwards.
///
/// `error.HeadTooLong` means the head does not fit in the reader's buffer
/// — answer with 431. `error.EndOfStream` before the first byte is a
/// keep-alive connection the client closed: a normal way home.
pub fn readRequest(in: *std.Io.Reader) !Request {
    const head = try readHead(in, .off);
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
pub fn readChunkSize(in: *std.Io.Reader) !u64 {
    const line = takeLine(in) catch return error.BadChunk;
    const end = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
    const digits = std.mem.trim(u8, line[0..end], " \t");
    if (digits.len == 0) return error.BadChunk;
    return std.fmt.parseInt(u64, digits, 16) catch error.BadChunk;
}

/// A chunk's data is followed by its own CRLF. Anything else means the
/// stream and the sizes have drifted apart, and everything read after that
/// point would be someone else's bytes.
pub fn endOfChunk(in: *std.Io.Reader) !void {
    const line = takeLine(in) catch return error.BadChunk;
    if (line.len != 0) return error.BadChunk;
}

pub fn skipTrailers(in: *std.Io.Reader) !void {
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
///
/// `Transfer-Encoding` is on the list for the same reason and is worse: a
/// response that announces chunked framing zfast is not applying is read by
/// the client as a chunk size, and everything after that is somebody's
/// guess. It is written only by `writeStreamHead`.
pub fn isReservedHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-type") or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
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
///
/// Two different waits happen in here and they want very different limits,
/// which is why the deadlines come in rather than being set by the caller.
/// Until the first byte arrives the client is merely idle — a browser
/// holding a keep-alive connection open is doing nothing wrong, and it may
/// do it for a minute. From the first byte on, the clock is the header
/// deadline: an absolute one, shared by every read, because a client
/// sending a byte at a time satisfies any per-read limit forever
/// (ADR 0023). The caller arms the idle limit; this arms the switch.
pub fn readHead(in: *std.Io.Reader, deadlines: bulkhead.Deadlines) ![]const u8 {
    // Where the search got to last time round. Without it, a client that
    // dribbles the head in a byte at a time makes the server rescan
    // everything it has already seen on every single read: an 8 KB head
    // delivered that way costs ~33 million byte comparisons instead of
    // 8 thousand. That is not a slow server, that is a lever.
    //
    // `buffered()` is a logical view — `fillMore` may shuffle the bytes to
    // the front of the buffer, but it moves the start with them, so an
    // index into it stays pointing at the same byte.
    var scanned: usize = 0;
    var counting = false;
    while (true) {
        const buf = in.buffered();
        if (findEndOfHead(buf, scanned)) |end| return buf[0..end];
        // Back up by one less than the longest delimiter, so one split
        // across two reads is still found.
        scanned = buf.len -| 3;
        if (buf.len >= in.buffer.len) return error.HeadTooLong;
        // Something arrived and it was not a whole head, so this client is
        // now mid-request rather than idle. Armed once: re-arming per read
        // would restart the deadline every time a byte turned up, which is
        // the bug this is here to prevent.
        if (!counting and buf.len > 0) {
            deadlines.armHeader();
            counting = true;
        }
        try in.fillMore();
    }
}

// ---- walking the head ----
//
// A head is a run of lines, and the two bytes that matter in it are '\n' and
// ':'. Both are found the same way: load a block, compare it against the
// byte, and read the positions off the resulting bitmask. That is one pass
// over the bytes for however many delimiters are wanted, where a call to
// `std.mem.indexOfScalar` per line per delimiter is a pass that restarts —
// with its own preamble — every few bytes.
//
// The heads this is measured against are 121 bytes with 6 headers and 556
// with 13. On the second one, finding the end went 183ns -> 51ns and parsing
// 303ns -> 163ns.

const lanes = scan.lanes;
const blockAt = scan.positionsOf;

/// The index just past the blank line that ends the head, if it is
/// complete. Accepts CRLF as well as a bare LF. Starts at `from`, which
/// the caller advances as the head arrives in pieces.
fn findEndOfHead(buf: []const u8, from: usize) ?usize {
    var i: usize = from;
    while (i < buf.len) : (i += lanes) {
        var newlines = blockAt(buf, i, '\n');
        while (newlines != 0) : (newlines &= newlines - 1) {
            const nl = i + @ctz(newlines);
            if (nl + 1 < buf.len and buf[nl + 1] == '\n') return nl + 2;
            if (nl + 2 < buf.len and buf[nl + 1] == '\r' and buf[nl + 2] == '\n') return nl + 3;
        }
    }
    return null;
}

/// Parse a head in one pass, finding the end of each line and the colon
/// inside it together. Nothing is scanned twice and there is no split
/// iterator: by the time a line's newline comes up, where its name ends is
/// already known.
///
/// The colons are handled as a mask rather than walked. For each line, the
/// colons falling inside it are isolated with a shift and an AND, which
/// answers both questions at once — whether there is one at all, which is
/// what makes a malformed line an error, and where the first one is, which
/// is what names the header. Walking them instead cost 36ns on a small head
/// and 70ns on a browser's, because a header *value* is full of colons and
/// none of them is interesting.
pub fn parseHead(head: []const u8, r: *Request) ParseError!void {
    var line_start: usize = 0;
    // Where this line's first colon is. 0 stands for "none yet" — a line
    // cannot begin with one, so the position is free to be the sentinel.
    var colon: usize = 0;
    var first_line = true;

    var i: usize = 0;
    while (i < head.len) : (i += lanes) {
        // One block, two compares. The colons cost a compare, not a pass.
        var newlines = blockAt(head, i, '\n');
        // Colons not yet accounted to a line. Cleared as each line claims its
        // own, so what is left over at the end of the block belongs to the
        // line still open — which is how a header spanning two blocks works.
        var unclaimed = blockAt(head, i, ':');

        while (newlines != 0) : (newlines &= newlines - 1) {
            const bit = @ctz(newlines);
            const nl_at = i + bit;

            const below: u32 = (@as(u32, 1) << @intCast(bit)) - 1;
            const mine = unclaimed & below;
            unclaimed &= ~below;
            if (colon == 0 and mine != 0) colon = i + @ctz(mine);

            var end = nl_at;
            if (end > line_start and head[end - 1] == '\r') end -= 1;

            if (first_line) {
                try parseRequestLine(head[line_start..end], r);
                first_line = false;
            } else {
                if (end == line_start) return; // the blank line ends the head
                if (colon == 0 or colon >= end) return error.BadHeader;
                // Two of the three headers that matter begin with `c` and one
                // with `t`, so one compare throws out Host, Accept,
                // User-Agent and the rest before their name is even measured.
                switch (head[line_start] | 0x20) {
                    'c', 't' => try applyHeaderAt(head, line_start, colon, end, r),
                    else => {},
                }
            }

            line_start = nl_at + 1;
            colon = 0;
        }
        if (colon == 0 and unclaimed != 0) colon = i + @ctz(unclaimed);
    }

    // A head with no blank line in it — which `readHead` never produces, but
    // a caller parsing a fragment can. Whatever is left is one more line.
    if (line_start < head.len or first_line) {
        const line = trimCR(head[@min(line_start, head.len)..]);
        if (first_line) return parseRequestLine(line, r);
        if (line.len == 0) return;
        return applyHeader(line, r);
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

/// Only three header names change how the request is read. Every other
/// one is still checked for a colon — a line without one is malformed and
/// is not going to be quietly accepted — but nothing past the name is
/// touched, because the parser has no use for it.
///
/// The name length is looked at before the name itself, so a request full
/// of `Accept`, `Cookie` and `User-Agent` costs one integer compare each
/// rather than three case-insensitive string compares and a trim.
pub fn applyHeader(line: []const u8, r: *Request) ParseError!void {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
    return applyHeaderAt(line, 0, colon, line.len, r);
}

/// `applyHeader`, for a caller that already knows where the name ends —
/// which `parseHead` does, because its one pass found the colon on the way
/// past. `from`, `colon` and `end` are indices into `buf`.
fn applyHeaderAt(buf: []const u8, from: usize, colon: usize, end: usize, r: *Request) ParseError!void {
    const name = buf[from..colon];

    switch (name.len) {
        "connection".len => {
            if (!std.ascii.eqlIgnoreCase(name, "connection")) return;
            const value = headerValue(buf, colon, end);
            if (std.ascii.eqlIgnoreCase(value, "close")) {
                r.keep_alive = false;
            } else if (std.ascii.eqlIgnoreCase(value, "keep-alive")) {
                r.keep_alive = true;
            } else if (std.ascii.indexOfIgnoreCase(value, "upgrade") != null) {
                // Only reached by a value that is neither of the two ordinary
                // ones, so the substring search is not on the common path. A
                // handshake sends `Upgrade` or `keep-alive, Upgrade`; both land
                // here, and neither changes what keep-alive already was.
                r.upgrade = true;
            }
        },
        "content-length".len => {
            if (!std.ascii.eqlIgnoreCase(name, "content-length")) return;
            r.content_length = std.fmt.parseInt(u64, headerValue(buf, colon, end), 10) catch
                return error.BadHeader;
        },
        "transfer-encoding".len => {
            if (!std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return;
            if (std.ascii.indexOfIgnoreCase(headerValue(buf, colon, end), "chunked") != null) r.chunked = true;
        },
        else => {},
    }
}

fn headerValue(buf: []const u8, colon: usize, end: usize) []const u8 {
    return std.mem.trim(u8, buf[colon + 1 .. end], " \t");
}

pub fn statusPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        206 => "Partial Content",
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
        416 => "Range Not Satisfiable",
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

/// A status defined to carry no body at all, whatever the handler passed.
///
/// These are not "a response that happens to be empty" — RFC 9112 §6.3 ends
/// them at the blank line regardless of what the head says, so writing
/// `Content-Length: 0` is not a harmless nicety. On a 204 it is forbidden
/// outright (§6.2); on a 304 it is worse than that, because it announces
/// that the resource the client already holds is empty.
pub fn bodyless(status: u16) bool {
    return status == 204 or status == 304 or (status >= 100 and status < 200);
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
    // A body under a bodyless status would be read as the start of the next
    // request on this connection, which is how a response-splitting bug
    // begins. The head already said there is none.
    if (!bodyless(status)) try out.writeAll(body);
    try out.flush();
}

// ---- writing a body whose length is not known yet ----

/// The head of a streamed response. No `Content-Length`, because the point
/// is that nobody knows it yet; instead one of the two ways HTTP has of
/// saying where a body stops.
///
/// `chunked` is for an HTTP/1.1 client: each piece is framed with its own
/// length and a zero-length one ends the body, so the connection survives to
/// carry another request. HTTP/1.0 has no such framing, and the only thing
/// left to mark the end of the body with is the end of the connection — so
/// there `chunked` is false, `keep_alive` must be false with it, and the
/// pieces go out unframed (ADR 0020).
pub fn writeStreamHead(
    out: *std.Io.Writer,
    status: u16,
    phrase: []const u8,
    content_type: []const u8,
    chunked: bool,
    keep_alive: bool,
    extra: []const Header,
) !void {
    try writeStatusLine(out, status, phrase);
    try out.print("Content-Type: {s}\r\n", .{content_type});
    if (chunked) try out.writeAll("Transfer-Encoding: chunked\r\n");
    try out.print("Connection: {s}\r\n", .{if (keep_alive) "keep-alive" else "close"});
    for (extra) |h| try out.print("{s}: {s}\r\n", .{ h.name, h.value });
    try out.writeAll("\r\n");
}

/// One chunk: its length in hex, the bytes, and a CRLF of its own.
///
/// A zero-length chunk is the one that ends a body, so writing an empty one
/// here would end the response early. There is nothing to say, so nothing is
/// said.
pub fn writeChunkHeader(out: *std.Io.Writer, len: usize) !void {
    std.debug.assert(len > 0);
    try out.print("{x}\r\n", .{len});
}

pub fn endChunk(out: *std.Io.Writer) !void {
    try out.writeAll("\r\n");
}

/// The zero-length chunk that ends a chunked body, and the empty trailer
/// section after it.
pub fn writeLastChunk(out: *std.Io.Writer) !void {
    try out.writeAll("0\r\n\r\n");
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

/// The whole first line, assembled at compile time for every status the
/// framework knows. A response then starts with one `writeAll` of a
/// constant instead of formatting an integer and pasting three pieces
/// together — and the status and its phrase cannot drift apart, because
/// there is only one of them.
fn statusLine(comptime status: u16) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 {d} {s}\r\n", .{ status, statusPhrase(status) });
}

fn writeStatusLine(out: *std.Io.Writer, status: u16, phrase: []const u8) !void {
    switch (status) {
        inline 200, 201, 204, 206, 301, 302, 304, 400, 401, 403, 404, 405, 409, 413, 416, 422, 429, 431, 500, 501, 503 => |s| {
            return out.writeAll(comptime statusLine(s));
        },
        else => return out.print("HTTP/1.1 {d} {s}\r\n", .{ status, phrase }),
    }
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
    try writeStatusLine(out, status, phrase);
    if (bodyless(status)) {
        // No Content-Length: see `bodyless`. Content-Type still goes out on
        // a 304, which is describing a representation the client already
        // has, but not on a 204, where there is no representation at all.
        if (status == 304) try out.print("Content-Type: {s}\r\n", .{content_type});
        try out.print("Connection: {s}\r\n", .{if (keep_alive) "keep-alive" else "close"});
    } else {
        try out.print(
            "Content-Type: {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n",
            .{ content_type, body_len, if (keep_alive) "keep-alive" else "close" },
        );
    }
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

// The head is walked 32 bytes at a time, and the colons inside a block are
// accounted to lines by mask arithmetic. Everything below is a way for that
// arithmetic to be wrong — a colon claimed by the wrong line, or one lost
// because it fell on the far side of a block boundary.

test "a line with no colon is refused, whatever the line before it had" {
    // The danger the mask creates: the first line's colon vouching for the
    // second. `Host: x` has one, `Broken` does not, and both are in the same
    // 32-byte block.
    var r = Request{};
    try testing.expectError(
        error.BadHeader,
        parseHead("GET / HTTP/1.1\r\nHost: x\r\nBroken\r\n\r\n", &r),
    );

    // The same, on a line that would have been skipped by the first-byte
    // filter anyway — being uninteresting is not the same as being allowed.
    var r2 = Request{};
    try testing.expectError(
        error.BadHeader,
        parseHead("GET / HTTP/1.1\r\nAccept no-colon\r\n\r\n", &r2),
    );
}

test "a colon is found wherever it falls against a block boundary" {
    // A header name of every length from short to well past 32 bytes, so its
    // colon lands before, on and after each boundary the scan steps over.
    for (1..80) |name_len| {
        const gpa = testing.allocator;
        const name = try gpa.alloc(u8, name_len);
        defer gpa.free(name);
        @memset(name, 'x');
        name[0] = 'C'; // survives the first-byte filter, so it is really read

        const head = try std.mem.concat(gpa, u8, &.{
            "GET / HTTP/1.1\r\n", name, ": v\r\nConnection: close\r\n\r\n",
        });
        defer gpa.free(head);

        var r = Request{};
        try parseHead(head, &r);
        // The Connection header is behind the long one, so reading it at all
        // proves the long line was accounted for correctly.
        try testing.expect(!r.keep_alive);
    }
}

test "colons in a value do not stand in for the next line's" {
    var r = Request{};
    try parseHead(
        "GET / HTTP/1.1\r\nHost: example.dev:8080\r\n" ++
            "If-Modified-Since: Mon, 01 Jan 2024 00:00:00 GMT\r\n" ++
            "Content-Length: 7\r\n\r\n",
        &r,
    );
    try testing.expectEqual(@as(u64, 7), r.content_length);

    // A value full of colons followed by a line with none is still refused.
    var r2 = Request{};
    try testing.expectError(
        error.BadHeader,
        parseHead("GET / HTTP/1.1\r\nX: a:b:c:d:e\r\nNope\r\n\r\n", &r2),
    );
}

test "the headers that matter are read at any position in a long head" {
    // Pushed past several block boundaries by padding in front, so the three
    // interesting headers are found in the middle of the scan rather than at
    // a convenient offset.
    const gpa = testing.allocator;
    for ([_]usize{ 0, 1, 7, 15, 30, 31, 32, 33, 63, 100 }) |pad| {
        const filler = try gpa.alloc(u8, pad);
        defer gpa.free(filler);
        @memset(filler, 'y');

        const head = try std.mem.concat(gpa, u8, &.{
            "POST / HTTP/1.1\r\nX-Pad: ", filler,
            "\r\nContent-Length: 1234\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n",
        });
        defer gpa.free(head);

        var r = Request{};
        try parseHead(head, &r);
        try testing.expectEqual(@as(u64, 1234), r.content_length);
        try testing.expect(!r.keep_alive);
        try testing.expect(r.chunked);
    }
}

test "the fused parser agrees with a plain line-by-line one" {
    // The parser this replaced, kept as the thing to be held against — a
    // rewrite that is faster and subtly different is worse than a slow one.
    const plain = struct {
        fn parse(head: []const u8, r: *Request) ParseError!void {
            var lines = std.mem.splitScalar(u8, head, '\n');
            const first = trimCR(lines.next() orelse return error.BadRequestLine);
            try parseRequestLine(first, r);
            while (lines.next()) |raw| {
                const line = trimCR(raw);
                if (line.len == 0) return;
                try applyHeader(line, r);
            }
        }
    }.parse;

    const heads = [_][]const u8{
        "GET / HTTP/1.1\r\n\r\n",
        "GET /users/7 HTTP/1.1\r\nHost: example.dev\r\nUser-Agent: wrk\r\n" ++
            "Accept: */*\r\nAccept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n",
        "GET / HTTP/1.0\r\n\r\n",
        "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
        "GET / HTTP/1.1\nHost: x\n\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length:  42  \r\n\r\n",
        "GET / HTTP/1.1\r\nConnection: close\r\n\r\n",
        "GET / HTTP/1.1\r\nCONNECTION: CLOSE\r\n\r\n",
        "GET / HTTP/1.1\r\nCookie: a=1; b=2\r\nConnection: close\r\n\r\n",
        "GET / HTTP/1.1\r\nX: a:b:c\r\nConnection: close\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 3\r\n\r\n",
        // Malformed, so both have to refuse it.
        "GET / HTTP/1.1\r\nBroken\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nBroken\r\n\r\n",
        // No blank line at all, which only a caller parsing a fragment does.
        "GET / HTTP/1.1\r\nHost: x\r\n",
        "GET / HTTP/1.1",
    };

    for (heads) |head| {
        var mine = Request{};
        var theirs = Request{};
        const my_err = parseHead(head, &mine);
        const their_err = plain(head, &theirs);

        if (their_err) |_| {
            try my_err;
            try testing.expectEqualStrings(theirs.method, mine.method);
            try testing.expectEqualStrings(theirs.target, mine.target);
            try testing.expectEqual(theirs.minor_version, mine.minor_version);
            try testing.expectEqual(theirs.keep_alive, mine.keep_alive);
            try testing.expectEqual(theirs.content_length, mine.content_length);
            try testing.expectEqual(theirs.chunked, mine.chunked);
        } else |expected| {
            try testing.expectError(expected, my_err);
        }
    }
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

test "a 204 carries neither Content-Length nor Content-Type" {
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try writeResponse(&out, 204, "No Content", "text/plain", "", true, &.{
        .{ .name = "Allow", .value = "GET, HEAD" },
    });
    try testing.expectEqualStrings(
        "HTTP/1.1 204 No Content\r\nConnection: keep-alive\r\nAllow: GET, HEAD\r\n\r\n",
        out.buffered(),
    );
}

test "a 304 keeps its Content-Type but drops the Content-Length" {
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try writeResponse(&out, 304, "Not Modified", "text/css; charset=utf-8", "", true, &.{
        .{ .name = "ETag", .value = "\"abc\"" },
    });
    try testing.expectEqualStrings(
        "HTTP/1.1 304 Not Modified\r\nContent-Type: text/css; charset=utf-8\r\n" ++
            "Connection: keep-alive\r\nETag: \"abc\"\r\n\r\n",
        out.buffered(),
    );
}

test "a body handed to a bodyless status is dropped rather than framed wrong" {
    // Nothing in zfast does this, but a handler reaching for `c.send(204, …)`
    // with contents would otherwise leave bytes on the connection that the
    // next request would be read out of.
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try writeResponse(&out, 204, "No Content", "text/plain", "leftovers", true, &.{});
    try testing.expect(std.mem.endsWith(u8, out.buffered(), "\r\n\r\n"));
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "leftovers") == null);
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
