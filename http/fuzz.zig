//! What the parser has to be true for, whatever a stranger sends it.
//!
//! Every other test in this repo checks an input somebody thought of. This
//! file checks properties instead, against inputs nobody thought of: the
//! request head is the one piece of nilo that is fed directly by whoever
//! opens a connection, so it is the piece where "we never tried that" is
//! not a defence.
//!
//! Two of the three checks are differential — the fast implementation
//! against a byte-at-a-time one written the obvious way. That matters more
//! than "it does not crash". Where a head *ends* is where the next request
//! begins, so two implementations disagreeing about it is request
//! smuggling; and `Content-Length` and `Transfer-Encoding` are the two
//! fields a smuggled request is built out of.
//!
//! **A refusal added to `http1` is added to the reference here in the same
//! commit**, or the two disagree on purpose and the fuzzer reports it as a
//! bug — on whichever later commit's seed happens to reach that shape. That
//! is how `Name : value` went from a 400 in `http1` to a CI failure two
//! commits on, with the parser untouched in between.
//!
//! ## How to run it
//!
//! `zig build test` runs the corpus below — every input this has ever
//! caught, plus every nasty case anybody wrote down. That is the
//! regression half, and it is cheap.
//!
//! `zig build fuzz` generates inputs and runs them through the same
//! targets: `-Diterations=`, `-Dseed=` (printed, so a failure is
//! reproducible). It is not coverage-guided — it mixes random bytes with
//! heads built to be nearly valid and then damaged, because a coverage
//! fuzzer's own first problem is that random bytes are never a valid head.
//!
//! `zig build test --fuzz` is the coverage-guided one, and it does not
//! work on Zig 0.16.0: `lib/compiler/test_runner.zig:566` fails to compile
//! in fuzz mode, in std's own code, for any project (a five-line file with
//! nothing of ours in it reproduces it). The targets are written as
//! `std.testing.fuzz` targets anyway, so the day that is fixed this
//! becomes coverage-guided for free.

const std = @import("std");
const builtin = @import("builtin");
const http1 = @import("http1.zig");

const testing = std.testing;

/// Where the one thing here that allocates gets its memory.
///
/// `std.testing.allocator` refuses to compile outside a test, and half of
/// the point of this file is that `zig build fuzz` — an ordinary program —
/// runs exactly the same checks as `zig build test`. Under a test it is
/// still the leak-checking one, because that is where a leak should be
/// reported.
fn scratch() std.mem.Allocator {
    return if (builtin.is_test) testing.allocator else std.heap.page_allocator;
}

// ---- target 1: where the head ends ----

/// The same question `findEndOfHead` answers, asked one byte at a time.
///
/// This is the oracle, so it is written to be obviously right rather than
/// fast: no blocks, no bitmasks, no resuming.
fn refEndOfHead(buf: []const u8) ?usize {
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] != '\n') continue;
        if (i + 1 < buf.len and buf[i + 1] == '\n') return i + 2;
        if (i + 2 < buf.len and buf[i + 1] == '\r' and buf[i + 2] == '\n') return i + 3;
    }
    return null;
}

/// A head is found in the same place however it arrives.
///
/// `readHead` is called again every time more bytes turn up, and it does
/// not rescan what it has already seen — it resumes three bytes back, so
/// that a `\r\n\r\n` split across two reads is still found. Three is the
/// kind of number that is right until it is off by one, and being off by
/// one here means a server that finds a head boundary a client did not
/// intend. So the arrival is replayed a byte at a time, and the resumed
/// answer has to be the from-scratch answer at every prefix.
fn headBoundaryHoldsHoweverItArrives(bytes: []const u8) !void {
    var scanned: usize = 0;
    var n: usize = 0;
    while (n <= bytes.len) : (n += 1) {
        const prefix = bytes[0..n];
        const resumed = http1.findEndOfHead(prefix, scanned);
        const fresh = refEndOfHead(prefix);

        if (resumed) |at| {
            // Found: it must be where the reference says, and inside the
            // bytes that have actually arrived.
            try testing.expectEqual(fresh, at);
            try testing.expect(at <= prefix.len);
            return;
        }
        // Not found: the reference must not have found one either. This is
        // the direction that matters — a missed boundary is a head that
        // swallows the request behind it.
        try testing.expectEqual(@as(?usize, null), fresh);
        scanned = prefix.len -| 3;
    }
}

// ---- target 2: what the head says ----

/// `parseHead`, written the slow obvious way: split on newlines, trim one
/// carriage return, look at each line on its own.
fn refParseHead(head: []const u8, r: *http1.Request) http1.ParseError!void {
    var first_line = true;
    var rest = head;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const raw = if (nl) |at| rest[0..at] else rest;
        rest = if (nl) |at| rest[at + 1 ..] else "";

        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (first_line) {
            try refParseRequestLine(line, r);
            first_line = false;
            continue;
        }
        if (line.len == 0) return refFinish(r); // the blank line ends the head
        try refApplyHeader(line, r);
    }
    // A head that is only a request line, and no newline after it.
    if (first_line) try refParseRequestLine(head, r);
    return refFinish(r);
}

/// The one rule about a head rather than about a line in it. A second `Host`
/// is caught as it goes past; that there was never a first one is only
/// knowable once the head has ended, which is why this is separate.
fn refFinish(r: *http1.Request) http1.ParseError!void {
    if (r.minor_version == 1 and !r.has_host and r.authority.len == 0) return error.BadHeader;
    // HTTP/1.0 has no `Transfer-Encoding` (RFC 9112 §6.1): answered, then closed.
    if (r.minor_version == 0 and r.chunked) r.keep_alive = false;
}

/// A byte no line may carry where it is: any control but tab, and in the
/// request line tab as well. `line` has had its one CR taken off already, so
/// a CR left in it is one that did not end it. Checked a byte at a time over
/// the line, where `http1` finds them in blocks as it finds the newlines.
fn refStray(line: []const u8, tab_allowed: bool) bool {
    for (line) |c| {
        if (c == '\t') {
            if (!tab_allowed) return true;
        } else if (c < 0x20 or c == 0x7F) return true;
    }
    return false;
}

fn refParseRequestLine(line: []const u8, r: *http1.Request) http1.ParseError!void {
    if (refStray(line, false)) return error.BadRequestLine;
    // Two spaces, and the second one is what the version starts after.
    // Counting them says that in a different way from looking for the
    // second one, which is the point of a reference implementation — and
    // getting it wrong was this harness's first catch, in itself: written
    // as a plain split, `GET /x` came out as an unsupported version
    // instead of a malformed request line.
    if (std.mem.count(u8, line, " ") < 2) return error.BadRequestLine;
    var parts = std.mem.splitScalar(u8, line, ' ');
    const method = parts.first();
    const target = parts.next().?;
    const version = parts.rest();
    if (method.len == 0 or target.len == 0) return error.BadRequestLine;
    // The rest of the line is the version, spaces and all — which is what
    // makes `GET / HTTP/1.1 x` malformed rather than accepted.
    if (std.mem.eql(u8, version, "HTTP/1.1")) {
        r.minor_version = 1;
        r.keep_alive = true;
    } else if (std.mem.eql(u8, version, "HTTP/1.0")) {
        r.minor_version = 0;
        r.keep_alive = false;
    } else if (std.mem.startsWith(u8, version, "HTTP/") and version.len == 8 and
        std.ascii.isDigit(version[5]) and std.ascii.isDigit(version[7]) and version[6] == '.')
    {
        // Spelled like a version and not spoken: a 505 and not a 400.
        return error.UnsupportedVersion;
    } else return error.BadRequestLine;
    // A method is a token, checked with the grammar's own switch where
    // `http1` compares a block against its runs.
    if (!http1.headerNameOk(method)) return error.BadRequestLine;
    r.method = method;
    r.target = target;
    try refSplitTarget(r);
}

/// The absolute-form split, done the other way round: find `://` anywhere in
/// the target and check what is in front of it, where `http1.absoluteForm`
/// matches the two schemes as prefixes and never searches. A target with
/// `://` further in — `http://a/b://c` — is what tells the two apart, and it
/// is the reason this is written from the separator rather than from the
/// scheme.
fn refSplitTarget(r: *http1.Request) http1.ParseError!void {
    const target = r.target;
    if (target[0] == '/') return;

    const sep = std.mem.indexOf(u8, target, "://") orelse return refOtherForm(target, r.method);
    const scheme = target[0..sep];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return refOtherForm(target, r.method);

    const rest = target[sep + 3 ..];
    var cut: usize = rest.len;
    for (rest, 0..) |ch, i| {
        if (ch == '/' or ch == '?' or ch == '#') {
            cut = i;
            break;
        }
    }

    const authority = rest[0..cut];
    if (authority.len == 0) return error.BadRequestLine;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.BadRequestLine;
    try refAuthority(authority, false);

    r.authority = authority;
    if (cut == rest.len) {
        r.target = "/";
        return;
    }
    if (rest[cut] != '/') return error.BadRequestLine;
    r.target = rest[cut..];
}

/// What a target that is not origin-form and not an `http` absolute-form may
/// still be (RFC 9112 §3.2): `*` for an OPTIONS and `host:port` for a CONNECT,
/// and nothing else, where `http1` writes the same as one chain of ifs.
fn refOtherForm(target: []const u8, method: []const u8) http1.ParseError!void {
    if (std.mem.eql(u8, target, "*")) {
        if (std.mem.eql(u8, method, "OPTIONS")) return;
        return error.BadRequestLine;
    }
    if (!std.mem.eql(u8, method, "CONNECT")) return error.BadRequestLine;
    try refAuthority(target, true);
}

/// A host and maybe a port, taken apart from the front: a bracketed
/// IP-literal first when there is one, where `http1.authorityOk` finds the
/// port from the back.
fn refAuthority(text: []const u8, port_required: bool) http1.ParseError!void {
    const reg_name = "-._~!$&'()*+,;=%";
    var rest: []const u8 = undefined;
    if (text.len > 0 and text[0] == '[') {
        const close = std.mem.indexOfScalar(u8, text, ']') orelse return error.BadRequestLine;
        const inside = text[1..close];
        if (inside.len == 0) return error.BadRequestLine;
        for (inside) |c| {
            if (std.ascii.isAlphanumeric(c) or c == ':') continue;
            if (std.mem.indexOfScalar(u8, reg_name, c) == null) return error.BadRequestLine;
        }
        rest = text[close + 1 ..];
    } else {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse text.len;
        const host = text[0..colon];
        if (host.len == 0) return error.BadRequestLine;
        for (host) |c| {
            if (std.ascii.isAlphanumeric(c)) continue;
            if (std.mem.indexOfScalar(u8, reg_name, c) == null) return error.BadRequestLine;
        }
        rest = text[colon..];
    }
    if (rest.len == 0) {
        if (port_required) return error.BadRequestLine;
        return;
    }
    if (rest[0] != ':') return error.BadRequestLine;
    for (rest[1..]) |c| if (!std.ascii.isDigit(c)) return error.BadRequestLine;
}

fn refApplyHeader(line: []const u8, r: *http1.Request) http1.ParseError!void {
    if (refStray(line, true)) return error.BadHeader;
    // obs-fold (RFC 9112 §5.2), refused in `http1` in the same commit.
    if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) return error.BadHeader;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
    if (colon == 0) return error.BadHeader;
    // No whitespace between the field name and the colon (RFC 9112 §5.1),
    // which `http1` refuses since it was made a 400 there — a `Name : value`
    // one side reads and the other drops is a framing disagreement. The
    // fuzzer found the reference still lenient two commits later, on a seed
    // CI derived from a commit that never touched the parser.
    if (line[colon - 1] == ' ' or line[colon - 1] == '\t') return error.BadHeader;
    const name = line[0..colon];
    if (!http1.headerNameOk(name)) return error.BadHeader;
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

    if (std.ascii.eqlIgnoreCase(name, "host")) {
        if (r.has_host) return error.BadHeader;
        r.has_host = true;
        // What a host can be spelled with; empty is legal (RFC 9112 §3.2).
        if (value.len > 0) refAuthority(value, false) catch return error.BadHeader;
    } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
        // A list, split every time, where `http1` answers the two common
        // whole values before splitting. `close` anywhere wins; `keep-alive`
        // opens only what HTTP/1.0 had closed.
        var close = false;
        var keep = false;
        var options = std.mem.splitScalar(u8, value, ',');
        while (options.next()) |raw| {
            const option = std.mem.trim(u8, raw, " \t");
            if (std.ascii.eqlIgnoreCase(option, "close")) close = true;
            if (std.ascii.eqlIgnoreCase(option, "keep-alive")) keep = true;
        }
        if (close) {
            r.keep_alive = false;
        } else if (keep and r.minor_version == 0) {
            r.keep_alive = true;
        }
        if (std.ascii.findIgnoreCase(value, "upgrade") != null) r.upgrade = true;
    } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
        if (r.chunked) return error.BadHeader;
        if (value.len == 0) return error.BadHeader;
        for (value) |c| if (!std.ascii.isDigit(c)) return error.BadHeader;
        const n = std.fmt.parseInt(u64, value, 10) catch return error.BadHeader;
        if (r.has_content_length and n != r.content_length) return error.BadHeader;
        r.content_length = n;
        r.has_content_length = true;
    } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
        if (r.chunked) return error.BadHeader;
        // The obvious way round: split forwards and keep whatever came last,
        // where `http1` takes the last comma and reads from there. Two
        // spellings of "the final coding", which is the pair worth having.
        var codings = std.mem.splitScalar(u8, value, ',');
        var last: []const u8 = "";
        var count: usize = 0;
        while (codings.next()) |coding| {
            last = std.mem.trim(u8, coding, " \t");
            count += 1;
        }
        // Anything but `chunked` last is a coding nilo cannot decode, which
        // RFC 9112 §6.1 makes a 400 rather than a request with no body, and a
        // coding in front of a final `chunked` is a 501.
        if (!std.ascii.eqlIgnoreCase(last, "chunked")) return error.BadHeader;
        if (count > 1) return error.UnsupportedTransferEncoding;
        if (r.has_content_length) return error.BadHeader;
        r.chunked = true;
    }
}

/// The fast parser and the obvious one agree about every field a request
/// is framed by, and about which heads are refused.
///
/// `content_length` and `chunked` are the two this is really about: a
/// front end and a back end that disagree about how long a body is are
/// how a request gets smuggled past the one doing the checking.
fn parsedTheSameAsTheObviousWay(head: []const u8) !void {
    var fast: http1.Request = .{};
    var slow: http1.Request = .{};

    const fast_err = http1.parseHead(head, &fast);
    const slow_err = refParseHead(head, &slow);

    if (fast_err) |_| {
        slow_err catch |e| {
            std.debug.print("fast accepted, reference refused with {t}\n", .{e});
            return error.ParsersDisagree;
        };
    } else |fast_e| {
        if (slow_err) |_| {
            std.debug.print("fast refused with {t}, reference accepted\n", .{fast_e});
            return error.ParsersDisagree;
        } else |slow_e| {
            try testing.expectEqual(slow_e, fast_e);
            return; // both refused it, and for the same reason
        }
    }

    try testing.expectEqualStrings(slow.method, fast.method);
    try testing.expectEqualStrings(slow.target, fast.target);
    try testing.expectEqualStrings(slow.authority, fast.authority);
    try testing.expectEqual(slow.minor_version, fast.minor_version);
    try testing.expectEqual(slow.keep_alive, fast.keep_alive);
    try testing.expectEqual(slow.content_length, fast.content_length);
    try testing.expectEqual(slow.has_content_length, fast.has_content_length);
    try testing.expectEqual(slow.has_host, fast.has_host);
    try testing.expectEqual(slow.chunked, fast.chunked);
    try testing.expectEqual(slow.upgrade, fast.upgrade);

    // Zero-copy means exactly that: what a `Str` will point at has to be
    // inside the head it came from, or the request outlives its own bytes.
    try expectInside(head, fast.method);
    try expectInside(head, fast.target);
    // Including the two an absolute-form target produces. `App` moves these
    // onto a copy of the head by their offset into it, so one pointing
    // anywhere else is a slice it would rebase into somebody else's memory.
    try expectInside(head, fast.authority);
}

fn expectInside(haystack: []const u8, part: []const u8) !void {
    if (part.len == 0) return;
    const base = @intFromPtr(haystack.ptr);
    const at = @intFromPtr(part.ptr);
    try testing.expect(at >= base);
    try testing.expect(at + part.len <= base + haystack.len);
}

// ---- target 3: the whole head, through the reader ----

/// What the server really calls, over bytes that arrive as one lump.
///
/// Nothing is asserted about *which* answer comes back — a fuzzer's input
/// is mostly nonsense and being refused is the right answer to nonsense.
/// What is asserted is that a request which parsed is one the server can
/// then act on: the head was consumed exactly, and the slices point into
/// the buffer rather than past it.
fn readAndConsumeExactly(bytes: []const u8) !void {
    var in: std.Io.Reader = .fixed(bytes);
    const before = in.seek;

    const r = http1.readRequest(&in) catch return;

    const head_len = in.seek - before;
    try testing.expect(head_len <= bytes.len);
    try expectInside(bytes, r.method);
    try expectInside(bytes, r.target);

    // A head ends at a blank line, so the shortest possible one is `\r\n`
    // after a request line. Zero would mean the reader was left where it
    // started, and the next read would parse the same bytes again.
    try testing.expect(head_len > 0);
}

// ---- target 4: a chunked body cannot exceed its limit ----

/// `max_body` is a memory bound, and a chunked body is the shape that
/// tests it: the size arrives as text, in hex, one chunk at a time, from
/// the client. If a body longer than the limit can be assembled, the limit
/// is decoration.
/// Read into an arena, because that is what the server does. `gpa` is a
/// parameter, but nothing about `readChunkedBody` is written for a general
/// allocator: a chunk that fails halfway leaves what it had, and an empty
/// body comes back as a slice that was never allocated. Both are correct
/// against a request arena and neither survives being freed one at a time
/// — which is how this check first went off, on `0\r\n\r\n`.
fn chunkedBodyStaysUnderItsLimit(bytes: []const u8) !void {
    const limit: usize = 64;
    var arena = std.heap.ArenaAllocator.init(scratch());
    defer arena.deinit();

    var in: std.Io.Reader = .fixed(bytes);
    const body = http1.readChunkedBody(&in, arena.allocator(), limit) catch return;
    try testing.expect(body.len <= limit);
}

// ---- the targets, as one call ----

/// Every property above, over one input. Called by the corpus tests below
/// and by `zig build fuzz`, so the two drivers cannot drift apart.
///
/// A failing property prints the input that caused it, escaped, ready to
/// be pasted into the corpus. A fuzzer that finds a bug and does not say
/// which bytes found it has produced a rumour.
pub fn checkOne(bytes: []const u8) !void {
    check(bytes) catch |err| {
        dump(bytes);
        return err;
    };
}

fn check(bytes: []const u8) !void {
    try headBoundaryHoldsHoweverItArrives(bytes);
    try parsedTheSameAsTheObviousWay(bytes);
    try readAndConsumeExactly(bytes);
    try chunkedBodyStaysUnderItsLimit(bytes);
}

/// The input, as a Zig string literal, so that a failure can be moved into
/// the corpus by copying the line.
pub fn dump(bytes: []const u8) void {
    std.debug.print("    seed(\"", .{});
    for (bytes) |b| switch (b) {
        '\r' => std.debug.print("\\r", .{}),
        '\n' => std.debug.print("\\n", .{}),
        '"' => std.debug.print("\\\"", .{}),
        '\\' => std.debug.print("\\\\", .{}),
        0x20...0x21, 0x23...0x5b, 0x5d...0x7e => std.debug.print("{c}", .{b}),
        else => std.debug.print("\\x{x:0>2}", .{b}),
    };
    std.debug.print("\"),  // {d} bytes\n", .{bytes.len});
}

// ---- the corpus ----
//
// Hand-written, and every one of them is a shape that has broken an HTTP
// parser somewhere. A `std.testing.Smith` input is a length-prefixed
// stream rather than plain text, so each entry is encoded for it — see
// `seed`.

/// One corpus entry: a `u32` little-endian length, then the bytes, which
/// is what `Smith.slice` reads when it is replaying a recorded input
/// rather than being driven by a fuzzer.
///
/// The prefix is built inside an explicit `comptime` block. Written as
/// `std.mem.toBytes(@as(u32, text.len))` it compiles, and every entry
/// comes out with `0xaa` where the length should be — the undefined-memory
/// pattern — so the whole corpus decodes to nothing and the suite stays
/// green while testing air. That is what the test below is for.
fn seed(comptime text: []const u8) []const u8 {
    const prefix = comptime p: {
        var out: [4]u8 = undefined;
        std.mem.writeInt(u32, &out, @as(u32, text.len), .little);
        break :p out;
    };
    return prefix ++ text;
}

const corpus = [_][]const u8{
    // Ordinary, and the two framings.
    seed("GET / HTTP/1.1\r\nHost: h\r\n\r\n"),
    seed("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello"),
    seed("POST /x HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"),

    // Both framings at once, which is the classic smuggling pair.
    seed("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n"),
    seed("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n"),
    seed("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n"),
    seed("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n"),
    seed("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked, identity\r\n\r\n"),
    seed("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:\tchunked \r\n\r\n"),

    // A last coding nilo cannot decode, which RFC 9112 §6.1 makes a 400
    // rather than a request framed as having no body at all. The bytes after
    // the head are there on purpose: what used to happen to them is that the
    // next request on this connection was parsed out of them.
    seed("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip\r\n\r\nGET /next HTTP/1.1\r\nHost: h\r\n\r\n"),
    seed("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked, gzip\r\n\r\n"),
    seed("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: xchunked\r\n\r\n"),
    seed("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: \r\n\r\n"),

    // The authority. HTTP/1.1 wants exactly one and HTTP/1.0 wants none, and
    // a repeat is refused even when the two agree (RFC 9112 §3.2).
    seed("GET / HTTP/1.1\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: a\r\nHost: a\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nhOsT: h\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost:\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHostname: h\r\n\r\n"),
    seed("GET / HTTP/1.0\r\n\r\n"),
    seed("GET / HTTP/1.0\r\nHost: a\r\nHost: b\r\n\r\n"),

    // Line endings, which is where a boundary is agreed or not.
    seed("GET / HTTP/1.1\nHost: h\n\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\n\n"),
    seed("GET / HTTP/1.1\nHost: h\n\r\n"),
    seed("GET / HTTP/1.1\r\r\nHost: h\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\n\r"),
    seed("GET / HTTP/1.1\r\nHost: h\r\n"),
    seed("GET / HTTP/1.1"),
    seed("\r\n\r\n"),
    seed("\n\n"),
    seed(""),

    // The head boundary landing on a block edge, since the scan reads a
    // block at a time and the interesting index is the last one in it. These
    // are the one group left without a `Host`: their offsets are the whole
    // point, and a header line in front of the blank one would move every one
    // of them. What they are for is where the head *ends*, which is asked
    // before anything is parsed.
    seed("GET /aaaaaaaaaaaaaaaaaaaaaaaaaa HTTP/1.1\r\n\r\n"),
    seed("GET /aaaaaaaaaaaaaaaaaaaaaaaaaaa HTTP/1.1\r\n\r\n"),
    seed("GET /aaaaaaaaaaaaaaaaaaaaaaaaaaaa HTTP/1.1\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\nX: " ++ &@as([60]u8, @splat('a')) ++ "\r\n\r\n"),

    // Request lines that are not.
    seed("GET/HTTP/1.1\r\n\r\n"),
    seed("GET  HTTP/1.1\r\n\r\n"),
    seed(" / HTTP/1.1\r\n\r\n"),
    seed("GET / \r\n\r\n"),
    seed("GET / HTTP/1.1 extra\r\n\r\n"),
    seed("GET / HTTP/2.0\r\n\r\n"),
    seed("GET / HTTP/1.9\r\n\r\n"),
    seed("gEt / http/1.1\r\n\r\n"),
    seed("GET  / HTTP/1.1\r\n\r\n"),

    // Header lines that are not.
    seed("GET / HTTP/1.1\r\nHost: h\r\nNoColon\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\n: novalue\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\nContent-Length:\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\nContent-Length: -1\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\nContent-Length: +5\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\nContent-Length: 0x10\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\nContent-Length: 18446744073709551616\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\nContent-Length: 5 5\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\ncOnTeNt-LeNgTh: 5\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\nConnection: Upgrade, keep-alive\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\nConnection: close, keep-alive\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\n Connection: close\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\nContent-Length : 5\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\nHost\t: h\r\n\r\n"),
    // What CI's seed found at input 300 of a million: the reference parser
    // taking `Content-Length : …` after `http1` had been made to refuse it.
    seed("PATCH http://x/y HTTP/1.0\nHost: 18446744073709551615\nCookie: close\nContent-Length : identity, chunked\nContent-Length : 5\nTransfer-Enco\rding: localhost:8787\nCookie: 007\nUpgrade:  \n\nffffffffffffffff\nhello\n0\n\n"),

    // Bytes a text protocol is not supposed to contain.
    seed("GET / HTTP/1.1\r\nHost: h\r\nX\x00: y\r\n\r\n"),
    seed("GET /\x00 HTTP/1.1\r\nHost: h\r\n\r\n"),
    seed("\xff\xfe\xfd\xfc\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost: h\r\nX: \xc3\x28\r\n\r\n"),

    // What llhttp refused and nilo accepted, or framed another way, on its
    // first million inputs (ADR 231): the first input of each kind.
    seed("GET\x09 /a/b/c HTTP/1.0\nX-Forwarded-For: 18446744073709551615\n\n5\nhello\n0\n\n"),
    seed("OPTIONS http://x/y HTTP/1.1\nContent_Length: chunked\nX-Forwarded-For: \x09gzip\nCon,nection: +7\n\n5\nhello\n0\n\n"),
    seed("PUT ///////\x0f//////////////////////////////// HTTP/1.0\n\n5\nhello\n0\n\n"),
    seed("POST /%2e%2e/ HTTP/1.0\nContent_Length: keep-\x00alive, Upgrade\nContent_Length: chunked\nContent_Length: +7\n\nffffffffffffffff\nhello\n0\n\n"),
    seed("HEAD http://x/y HTTP/1.0\r\nX-Forwarded-For:\r 5, 6\r\n\r\n 5\r\nhello\r\n0\r\n\r\n"),
    seed("POST / HTTP/1.0\r\nConnection: keep-alive, Upgrade\r\n\r\nx\r\nhello\r\n0\r\n\r\n"),
    seed("OPTIONS \x00x?a=1&b=2 HTTP/1.0\n\n"),
    seed("DELETE /x?a=1&b\xff=2 HTTP/1.0\r\n\r\n-1\r\nhello\r\n0\r\n\r\n"),
    seed("PUT / HTTP/1.0\nConnection localhost:8787\n\nhello"),
    seed("PATCH /a/b/c HTTP/1.1\r\nUpgrade: chunked\r\nUpgrade: 5, 6\r\nHost: keep-aliv\r, Upgrade\r\nUpgrade: localhost:8787\r\n\r\n\r\nhello\r\n0\r\n\r\n"),
    seed("OPTIONS /x?a=1&b=\r HTTP/1.0\r\nContent_Length: 18446744073709551615\r\n\r\nx\r\nhello\r\n0\r\n\r\n"),
    seed("GET ////////////////////////////////////\x09//// HTTP/1.0\n\n5\nhello\n0\n\n"),
    seed("PATCH /a/b/c HTTP/1.1\n\rX-Forwarded-For:  \nCookie: 5, 6\nHost: \x09gzip\nCookie: -1\n\nhello"),
    seed("HEAD http://\x00x/y HTTP/1.0\r\n\r\n"),
    seed("POST h;tp://x/y HTTP/1.0\n\nhello"),
    seed("\rGET /a/b/c HTTP/1.1\r\nAccept-Encoding: keep-alive, Upgrade\r\nHost: 18446744073709551615\r\n\r\nhello"),

    seed("GET http:/.x/y HTTP/1.0\n\n"),
    seed("PATCH http://|/y HTTP/1.1\r\n\r\nhello"),
    seed("HEAD ht:tp://x/y HTTP/1.0\r\nContent-Length: 007\r\nHost: \r\n\r\n"),

    // Chunk sizes, which arrive as attacker-chosen hex.
    seed("0\r\n\r\n"),
    seed("ffffffffffffffff\r\nx\r\n0\r\n\r\n"),
    seed("-1\r\n\r\n"),
    seed("5;ext=1\r\nhello\r\n0\r\n\r\n"),
    seed("5\r\nhello"),
    seed("\r\n\r\n0\r\n\r\n"),
};

test "the parser holds its properties over every input we know of" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &corpus });
}

/// The `std.testing.fuzz` shape of `checkOne`. A fuzzer fills the buffer;
/// a corpus entry is replayed into it.
fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const n = smith.slice(&buf);
    try checkOne(buf[0..n]);
}

// A corpus entry is only worth having if the thing that reads it agrees
// with the thing that wrote it. This is the check that the length prefix
// is the encoding `Smith` expects — without it, every entry above could
// have been silently replayed as an empty input and the suite would still
// be green.
test "a corpus entry arrives at the target as the bytes it was written as" {
    var smith: std.testing.Smith = .{ .in = seed("GET /x HTTP/1.1\r\n\r\n") };
    var buf: [512]u8 = undefined;
    const n = smith.slice(&buf);
    try testing.expectEqualStrings("GET /x HTTP/1.1\r\n\r\n", buf[0..n]);
}

// The properties are only worth having if they can fail. Each of these
// hands the check a case it must reject, so that a check which quietly
// stopped checking is caught here rather than by nobody.
test "the differential checks fail when the two sides really differ" {
    // The reference reads the same head as the parser does, so the way to
    // make them disagree is to hand the reference a different head.
    var slow: http1.Request = .{};
    try refParseHead("GET / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\n", &slow);
    try testing.expectEqual(@as(u64, 5), slow.content_length);

    var also: http1.Request = .{};
    try testing.expectError(error.BadHeader, refParseHead("GET / HTTP/1.1\r\nHost: h\r\nNoColon\r\n\r\n", &also));

    // And the whole-head rule really is one the reference applies, or every
    // entry in the corpus above would be refused by one side only.
    var hostless: http1.Request = .{};
    try testing.expectError(error.BadHeader, refParseHead("GET / HTTP/1.1\r\n\r\n", &hostless));

    // And the oracle really does find a boundary where one is.
    try testing.expectEqual(@as(?usize, 18), refEndOfHead("GET / HTTP/1.1\r\n\r\n"));
    try testing.expectEqual(@as(?usize, null), refEndOfHead("GET / HTTP/1.1\r\n"));
}
