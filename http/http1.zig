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
const date = @import("date.zig");

pub const Method = enum {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Method";

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
    /// A request line whose version is spelled `HTTP/d.d` and is neither 1.0
    /// nor 1.1: a 505 (RFC 9110 §15.6.6). A version that is not spelled that
    /// way is a malformed request line instead.
    UnsupportedVersion,
    /// A `Transfer-Encoding` that ends in `chunked` and names another coding
    /// before it: a 501 (RFC 9112 §6.1), because nilo decodes `chunked` and
    /// nothing else (ADR 070).
    UnsupportedTransferEncoding,
    /// A body arrived under a `Content-Encoding` nilo cannot decode, which is
    /// every one of them but `identity` and `gzip` (ADR 089). A 415
    /// rather than a 400: the request is well formed and the server cannot
    /// read what it carries.
    UnsupportedContentEncoding,
};

/// What a `Content-Encoding` header said, reduced to the three answers nilo
/// has for it.
pub const Encoding = enum {
    /// Sent as `identity`, or not sent: the bytes are the body.
    identity,
    /// `gzip`, or its old spelling `x-gzip`: inflated into the arena when the
    /// body is asked for.
    gzip,
    /// Anything else — `br`, `deflate`, `zstd`, or two codings at once — and
    /// refused with a 415 when there is a body under it.
    other,
};

/// Whether a build has a framing whose body the transport frames, which is
/// what `Request.ends_with_stream` is for. A build without it has no such
/// field, so `Request` is the struct it always was.
const transport_framed = @import("nilo_build").http2;

pub const Request = struct {
    /// Slices into the reader's buffer. Valid until the next read from the
    /// same connection (including `discardBody`) — after that the contents
    /// may be overwritten. Longer lifetimes come from the request arena and
    /// `Str` (ADR 003).
    method: []const u8 = "",
    target: []const u8 = "",
    /// The authority out of an absolute-form target — `example.com:8080` from
    /// `GET http://example.com:8080/users/7` — and empty for the origin-form
    /// every browser sends (ADR 095).
    ///
    /// It is the `Host` for this request when it is there. RFC 9112 §3.2 does
    /// not offer a choice about that: an origin server **must** ignore the
    /// `Host` header when the target names an authority, rather than reconcile
    /// the two. `Ctx.host` is where that is answered, and `finish` reads this
    /// to know the request said which host it wanted.
    authority: []const u8 = "",

    /// 0 for HTTP/1.0, 1 for HTTP/1.1.
    minor_version: u1 = 1,
    keep_alive: bool = true,
    content_length: u64 = 0,
    chunked: bool = false,
    /// Whether a `Content-Length` was actually sent, which `content_length`
    /// alone cannot say: an absent header and `Content-Length: 0` both leave
    /// it zero, and the two are not the same request. Only the framing checks
    /// in `applyHeaderAt` read it. Free in memory: it lands in padding the
    /// struct already had.
    has_content_length: bool = false,
    /// Which `Content-Encoding` the body is under. `.other` is read by
    /// `finish`, which turns it into a 415 when there is a body under it;
    /// `.gzip` is read by `Ctx.body`, which inflates (ADR 089). Free in
    /// memory for the reason `has_content_length` is: it lands in padding
    /// the struct already had.
    content_encoding: Encoding = .identity,
    /// Whether a `Host` was sent, which RFC 9112 §3.2 requires exactly one of
    /// on an HTTP/1.1 request: none is a 400 and so is a second line, even one
    /// that agrees with the first — stricter than `Content-Length`, where an
    /// identical repeat is legal.
    ///
    /// Read by `finish`, which is where the "none at all" half is answered,
    /// and by `Ctx.handshake`, which will not compare an `Origin` against a
    /// host the request did not settle. Free in memory for the same reason
    /// `has_content_length` is: it lands in padding the struct already had.
    has_host: bool = false,
    /// Whether `Connection` mentions an upgrade — so this connection may stop
    /// being HTTP and start being read by something else (ADR 021).
    ///
    /// Deliberately looser than `websocket.isUpgrade`, which also insists on
    /// `Upgrade: websocket`: what this answers is "might this connection be
    /// read from again", and the only wrong answer is a false negative.
    upgrade: bool = false,
    /// Whether the body is framed by the transport and ends where the stream
    /// does: a request on HTTP/2, whose `DATA` is read through the pipe the
    /// connection fills (ADR 260). `content_length` is then only what the
    /// client announced, when `has_content_length`, and the connection holds
    /// the `DATA` to it. Free in memory for the reason `has_content_length` is.
    ends_with_stream: if (transport_framed) bool else void = if (transport_framed) false else {},
    /// Whether the client said `Expect: 100-continue` and is holding its body
    /// back until the server answers (ADR 073). `Ctx` sends the interim
    /// response at the moment it commits to reading, and `App` reads this to
    /// know that a body it never asked for is still on the client's side.
    ///
    /// The only expectation this recognises. RFC 9110 §10.1.1 allows a 417 for
    /// any other, and nilo ignores them instead: an expectation nobody defined
    /// is one no client sends.
    expect_continue: bool = false,
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
/// `limit` bounds both framings. A chunked body could be streamed forever by
/// a client that has worked out we will sit here reading it; a Content-Length
/// body over the limit would be read in full only to be thrown away, as many
/// bytes as a stranger cared to announce — where `max_body` caps every other
/// way a body arrives (ADR 019). Both are `error.BodyTooLarge`, and the
/// caller closes the connection rather than serving the next request behind a
/// body nobody asked for.
pub fn discardBody(in: *std.Io.Reader, r: *const Request, limit: u64) !void {
    if (r.chunked) return discardChunkedBody(in, limit);
    if (r.content_length > limit) return error.BodyTooLarge;
    if (r.content_length > 0) try in.discardAll64(r.content_length);
}

// ---- chunked transfer encoding ----
//
// `5\r\nhello\r\n0\r\n\r\n` — a size in hex, that many bytes, repeat, and a
// zero-sized chunk ends it. What comes after the last chunk is trailers:
// headers held back until the body was finished. nilo reads them only far
// enough to get past them, because a trailer arrives after the handler has
// already been given the body, so there is nothing left to do with it.

/// Read a chunked body into one contiguous slice from `gpa`.
///
/// `gpa` is meant to be the request arena, and this is written as though
/// it always is: a chunk that fails partway leaves what it had allocated,
/// and a body of no chunks comes back as a slice that was never allocated
/// at all. Against an arena both are free and correct — the whole thing
/// goes when the request does. Against a general allocator the first is a
/// leak and the second panics on `free`.
pub fn readChunkedBody(in: *std.Io.Reader, gpa: std.mem.Allocator, limit: usize) ![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    while (true) {
        const size = try readChunkSize(in);
        if (size == 0) break;
        if (size > limit - body.items.len) return error.BodyTooLarge;
        const n: usize = @intCast(size);
        // **A chunk is taken as it arrives, as `readSizedBody` takes a body**
        // (ADR 083): a size is a number a stranger typed, and committing it
        // before a byte of it is here let one connection hold `max_body` on
        // the strength of eight hex digits. A page first; the rest only once
        // that page has arrived, and then exactly, because a growth heuristic
        // would round the promise up.
        const first = @min(n, sized_body_step);
        const head = try body.addManyAsSlice(gpa, first);
        try in.readSliceAll(head);
        if (n > first) {
            try body.ensureTotalCapacityPrecise(gpa, body.items.len + (n - first));
            const rest = body.addManyAsSliceAssumeCapacity(n - first);
            try in.readSliceAll(rest);
        }
        try endOfChunk(in);
    }
    try skipTrailers(in);
    return body.items;
}

/// How much of a `Content-Length` body a client has to actually deliver before
/// the rest of what it announced is committed.
///
/// **One page, and the size was settled by measurement rather than by taste.**
/// The step has to come out of memory the request arena is already holding, or
/// it costs a node of its own — and a node is a `mmap`/`munmap` pair, which on
/// this machine is worth more than the whole rest of the request. `arena_keep`
/// defaults to 16 KiB and a POST has spent a little of it on the head, so a
/// page fits and 16 KiB does not: at 16 KiB a 64 KiB body loses **21%**, and at
/// this size three interleaved pairs put it at −6.2%, +4.6% and −7.1%, which is
/// a sign change inside the harness's own spread.
/// [`bench/result/http.md`](../bench/result/http.md) has the sweep.
const sized_body_step = 4096;

/// Read a body of an announced length into one contiguous slice from `gpa`,
/// **taking the memory as the bytes arrive rather than as they are promised.**
///
/// `Content-Length` is a number a stranger typed, and committing it up front
/// let one connection hold a megabyte on the strength of a header — times the
/// default `max_connections` of 10,000, ten gigabytes
/// ([ADR 022](../docs/adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)
/// says why a per-read deadline does not catch it).
///
/// **One page of proof, then the announcement.** A client gets a page for
/// nothing and the rest only once it has delivered that, which caps the
/// amplification at 256× the default `max_body`.
///
/// **Two allocations rather than a growth loop**, because every growth past
/// the retained arena block is a fresh `mmap`/`munmap` pair — 35% of a 64 KiB
/// body, 45% of a megabyte.
/// [`bench/result/http.md`](../bench/result/http.md) has all four runs.
///
/// `gpa` is meant to be the request arena, on the same terms as
/// `readChunkedBody`: a read that fails partway leaves what it had, which
/// against an arena is free and correct.
pub fn readSizedBody(
    in: *std.Io.Reader,
    gpa: std.mem.Allocator,
    length: usize,
    deadlines: bulkhead.Deadlines,
) ![]const u8 {
    // Each run gets a deadline sized from the bytes it is waiting for, which
    // is what stops a client dribbling inside the per-read limit forever
    // (ADR 022). Two runs, so two arms: the step is bounded before the rest
    // is committed, exactly as the allocation is.
    if (length <= sized_body_step) {
        deadlines.armBodyRun(length);
        const whole = try gpa.alloc(u8, length);
        try in.readSliceAll(whole);
        return whole;
    }

    // The step first, and nothing more until it has arrived.
    var body = try gpa.alloc(u8, sized_body_step);
    deadlines.armBodyRun(sized_body_step);
    try in.readSliceAll(body);

    body = try gpa.realloc(body, length);
    deadlines.armBodyRun(length - sized_body_step);
    try in.readSliceAll(body[sized_body_step..]);
    return body;
}

pub fn discardChunkedBody(in: *std.Io.Reader, limit: u64) !void {
    var seen: u64 = 0;
    while (true) {
        const size = try readChunkSize(in);
        if (size == 0) break;
        // Checked before it is added, not after: `seen + size` on a size the
        // client chose overflows u64, which panics in a safe build and wraps
        // past the limit in a fast one. `readChunkedBody` guards the same way.
        if (size > limit - seen) return error.BodyTooLarge;
        seen += size;
        try in.discardAll64(size);
        try endOfChunk(in);
    }
    try skipTrailers(in);
}

/// The size line of a chunk. Anything after a `;` is a chunk extension:
/// nobody sends them, but the size in front of one is still a valid size.
///
/// **The line ends at CRLF and nowhere else, and an extension holds no
/// control byte.** Reading a bare LF as the end of the line let `2;\nxx\r\n`
/// end at the LF here while a front end that reads the LF as a byte of the
/// extension ends it at the CRLF, so the two frame the body at different
/// places: the TERM.EXT desync, a smuggled request's way in.
pub fn readChunkSize(in: *std.Io.Reader) !u64 {
    const line = takeChunkLine(in) catch return error.BadChunk;
    const end = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
    for (line[end..]) |c| {
        if ((c < 0x20 and c != '\t') or c == 0x7f) return error.BadChunk;
    }
    return hexOnly(line[0..end]) orelse error.BadChunk;
}

/// A chunk size, strictly `1*HEXDIG` as RFC 9112 §7.1 writes it.
///
/// `std.fmt.parseInt(…, 16)` is too generous for a stranger's framing: it
/// takes a leading `+`, and it ignores `_`, so `1_0` reads as 16. Trimming
/// spaces first — which this used to do — takes ` 5` and `5\t` as well. A
/// front end that reads any of those differently frames the body at another
/// length, which is where a smuggled request travels — the same disagreement
/// `digitsOnly` keeps a `Content-Length` from, one framing over. The checked
/// arithmetic refuses a size too long for u64 rather than wrapping it.
fn hexOnly(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var n: u64 = 0;
    for (text) |c| {
        const d = std.fmt.charToDigit(c, 16) catch return null;
        n = std.math.mul(u64, n, 16) catch return null;
        n = std.math.add(u64, n, d) catch return null;
    }
    return n;
}

/// A chunk's data is followed by its own CRLF. Anything else means the
/// stream and the sizes have drifted apart, and everything read after that
/// point would be someone else's bytes.
pub fn endOfChunk(in: *std.Io.Reader) !void {
    const line = takeChunkLine(in) catch return error.BadChunk;
    if (line.len != 0) return error.BadChunk;
}

/// How much trailer section a chunked body may carry. A line is bounded by
/// the read buffer and the number of lines was not, so a client could send
/// trailers for as long as it kept the connection. Nobody sends more than a
/// checksum or two, and nilo reads none of them.
pub const max_trailer_bytes = 8 * 1024;

pub fn skipTrailers(in: *std.Io.Reader) !void {
    var seen: usize = 0;
    while (true) {
        // A client that closes straight after the last chunk has still
        // sent a complete body; there is nothing to gain by failing here.
        const line = takeChunkLine(in) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (line.len == 0) return;
        seen += line.len + 2;
        if (seen > max_trailer_bytes) return error.BadChunk;
    }
}

/// A line of chunked framing: everything before a CRLF. A bare LF is
/// `error.BadChunk`, for `readChunkSize`'s reason; the head is the one
/// place a bare LF is still read as a line end (RFC 9112 §2.2).
fn takeChunkLine(in: *std.Io.Reader) ![]const u8 {
    const raw = try in.takeDelimiterInclusive('\n');
    if (raw.len < 2 or raw[raw.len - 2] != '\r') return error.BadChunk;
    return raw[0 .. raw.len - 2];
}

pub const Header = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Header";

    name: []const u8,
    value: []const u8,
};

/// Headers the framework writes itself. A response carrying two of any of
/// these is not merely untidy — a duplicated `Content-Length` is the
/// classic request-smuggling bug — so `Ctx.setHeader` refuses them.
///
/// `Transfer-Encoding` is on the list for the same reason and is worse: a
/// response that announces chunked framing nilo is not applying is read by
/// the client as a chunk size, and everything after that is somebody's
/// guess. It is written only by `writeStreamHead`.
pub fn isReservedHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-type") or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "connection");
}

/// Whether a field may not travel as a trailer, because what it says has to
/// be known before the content is (RFC 9110 §6.5.1): the framing, the route,
/// a request modifier, authentication, a response control, the content's own
/// format, and HTTP/2's pseudo-headers. A recipient may drop such a trailer or
/// act on it wrongly, so `Ctx.setTrailer` refuses it where it is set.
pub fn barredFromTrailer(name: []const u8) bool {
    if (name.len > 0 and name[0] == ':') return true;
    const names = [_][]const u8{
        // framing and the connection
        "content-length",
        "transfer-encoding",
        "connection",
        "keep-alive",
        "upgrade",
        "trailer",
        "te",
        // routing and request modifiers
        "host",
        "cache-control",
        "expect",
        "max-forwards",
        "pragma",
        "range",
        "if-match",
        "if-none-match",
        "if-modified-since",
        "if-unmodified-since",
        "if-range",
        // authentication
        "authorization",
        "proxy-authorization",
        "www-authenticate",
        "proxy-authenticate",
        "set-cookie",
        "cookie",
        // response controls
        "age",
        "date",
        "expires",
        "location",
        "retry-after",
        "vary",
        "warning",
        // the content's format
        "content-type",
        "content-encoding",
        "content-range",
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

/// Whether a response header described the answer a failure is replacing,
/// and so must not go out on the failure (ADR 024): a JSON 409 labelled gzip,
/// cacheable for a year, or pointing at an order that was never made.
///
/// A drop list rather than a keep list, because what a failure must keep is
/// open-ended (CORS, `Vary`, `Set-Cookie`, `Retry-After`, a request id, a
/// security header) and what describes a body is the closed set RFC 9110 §8,
/// RFC 9111 §5 and RFC 9530 name. One exception reads the value: a
/// `Cache-Control` saying `no-store` forbade keeping the answer, and a failure
/// is no more fit to keep, so that one stays.
pub fn describesAnswer(name: []const u8, value: []const u8) bool {
    const names = [_][]const u8{
        "content-encoding",    "content-language", "content-location", "content-range",
        "content-disposition", "content-digest",   "repr-digest",      "digest",
        "etag",                "last-modified",    "accept-ranges",    "expires",
        "age",                 "location",
    };
    for (names) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    if (std.ascii.eqlIgnoreCase(name, "cache-control")) {
        return std.ascii.indexOfIgnoreCase(value, "no-store") == null;
    }
    return false;
}

/// Headers a response may legitimately carry more than one of, and so the
/// ones `Ctx.setHeader` must not treat as a replacement.
///
/// Two, for two reasons. `Set-Cookie` may not be folded into one
/// comma-separated line at all (RFC 6265 §3), so replacing would deliver only
/// the last cookie set. `Vary` may be folded, but two layers each name their
/// own axis — CORS writes `Vary: Origin` and a gzipped file writes
/// `Vary: Accept-Encoding` — and replacing throws the first away, which lets a
/// shared cache hand one origin's response to another (ADR 029).
pub fn repeats(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "set-cookie") or
        std.ascii.eqlIgnoreCase(name, "vary");
}

/// The headers a browser reads as policy rather than as a description of the
/// answer, which `nilo.secure` writes as one block ([ADR 246](../docs/adr/246-the-headers-a-browser-reads-as-policy-are-one-block.md)).
///
/// `Ctx.setHeader` asks this before it compares names, so a handler that sets
/// one of these on a route behind `nilo.secure` replaces the block's line
/// rather than sending the header twice. Two `Content-Security-Policy` lines
/// are not a mistake a browser forgives: it enforces both, so the page gets
/// the intersection, which is stricter than either and is what nobody wrote.
/// A switch on the length first, because this runs on every header set while
/// a block is present and nearly every name is none of these.
pub fn isPolicyHeader(name: []const u8) bool {
    const candidates: []const []const u8 = switch (name.len) {
        15 => &.{ "x-frame-options", "referrer-policy" },
        18 => &.{"permissions-policy"},
        22 => &.{"x-content-type-options"},
        23 => &.{"content-security-policy"},
        25 => &.{"strict-transport-security"},
        26 => &.{"cross-origin-opener-policy"},
        28 => &.{ "cross-origin-resource-policy", "cross-origin-embedder-policy" },
        35 => &.{"content-security-policy-report-only"},
        else => return false,
    };
    for (candidates) |c| {
        if (std.ascii.eqlIgnoreCase(name, c)) return true;
    }
    return false;
}

/// A block of header lines, `Name: value\r\n` each, with the line for `name`
/// taken out: what a handler setting one of `nilo.secure`'s headers itself
/// leaves of the block. The block is returned as it is when it has no such
/// line, and nothing is allocated; otherwise one allocation of the rest.
pub fn withoutLine(gpa: std.mem.Allocator, block: []const u8, name: []const u8) ![]const u8 {
    var at: usize = 0;
    while (at < block.len) {
        const end = (std.mem.indexOfPos(u8, block, at, "\r\n") orelse block.len - 2) + 2;
        const line = block[at..end];
        if (line.len > name.len and line[name.len] == ':' and
            std.ascii.eqlIgnoreCase(line[0..name.len], name))
        {
            const rest = try gpa.alloc(u8, block.len - line.len);
            @memcpy(rest[0..at], block[0..at]);
            @memcpy(rest[at..], block[end..]);
            return rest;
        }
        at = end;
    }
    return block;
}

/// One entry of a response's extra headers, written. An entry with no name
/// is a block of whole lines `nilo.secure` assembled while compiling, and
/// goes out as it is; `headerNameOk` refuses an empty name, so nothing else
/// can be one ([ADR 246](../docs/adr/246-the-headers-a-browser-reads-as-policy-are-one-block.md)).
fn writeExtra(out: *std.Io.Writer, h: Header) !void {
    if (h.name.len == 0) return out.writeAll(h.value);
    try out.print("{s}: {s}\r\n", .{ h.name, h.value });
}

/// Whether a name can be written as a header field name at all — RFC 9110
/// §5.1's `token`, which is the same grammar a cookie name has.
///
/// Duplicated from `cookie.zig`'s `isTokenByte` rather than shared, and that
/// is deliberate: `cookie.zig` imports nothing but `std`, and reaching here
/// for six lines of switch would pull `bulkhead.zig` in behind it. Two copies
/// of a grammar that has not changed since 1999 is the cheaper of the two.
pub fn headerNameOk(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9' => {},
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    return true;
}

/// Whether a value can be written as a header field value — RFC 9110 §5.5's
/// `field-value`: printable ASCII, space and horizontal tab, plus `obs-text`.
///
/// **What this exists to refuse is CR and LF** (ADR 029). A response header
/// is terminated by `\r\n` and there is no escaping in this grammar, so a
/// value carrying one does not produce a broken header — it produces a
/// *second header*, and a value carrying two produces a second **response**.
/// That is the same shape `cookie.check` refuses a `;` for, one layer up.
///
/// `obs-text` — everything from 0x80 — is allowed: it is what a UTF-8 filename
/// in a `Content-Disposition` is made of, and it cannot terminate a line. NUL
/// and DEL cannot, NUL because it ends the string for anything downstream
/// written in C.
///
/// The shape this takes in an application is a `Location` built out of request
/// data: `?next=/x%0d%0aSet-Cookie:%20admin=1` sets a cookie no line of the
/// application ever wrote.
pub fn headerValueOk(value: []const u8) bool {
    for (value) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        if (ch < 0x21 or ch == 0x7F) return false;
    }
    return true;
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
/// (ADR 022). The caller arms the idle limit; this arms the switch.
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
    // Whether the first byte has been looked at for an empty line before the
    // request line (RFC 9112 §2.2). Once, so the loop's own cost is a flag.
    var leading_checked = false;
    while (true) {
        var buf = in.buffered();
        if (!leading_checked and buf.len > 0) {
            // **One empty line is dropped, not parsed**: a server expecting a
            // request line SHOULD ignore at least one before it. Tossed here
            // rather than skipped in `parseHead` so the head handed on starts
            // at the request line, which is what `HeaderIterator` and every
            // reader of a copied head assume. A CR alone is waited on: the LF
            // that makes it a line is still on its way.
            if (buf[0] == '\n') {
                in.toss(1);
                buf = in.buffered();
            } else if (buf[0] == '\r' and buf.len > 1) {
                if (buf[1] == '\n') {
                    in.toss(2);
                    buf = in.buffered();
                }
            }
            leading_checked = buf.len == 0 or buf[0] != '\r' or buf.len > 1;
            scanned = 0;
        }
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
///
/// Public for `fuzz.zig`, which checks it against a byte-at-a-time
/// reference. Where a head ends is where the next request begins, so a
/// disagreement here is request smuggling rather than a wrong answer.
pub fn findEndOfHead(buf: []const u8, from: usize) ?usize {
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
///
/// **A byte no line may carry is found the same way** (ADR 231): a control
/// byte, and a CR that does not end its line (RFC 9112 §2.2, RFC 9110 §5.5).
/// A front end that turns a bare CR into a line ending, or drops a NUL,
/// reads a header nilo does not, so these are refused rather than carried.
/// Tab is the one control a header value may hold; the request line may hold
/// none, so there it is refused too.
pub fn parseHead(head: []const u8, r: *Request) ParseError!void {
    return parseLines(head, r, true);
}

/// The fields of a request whose method and target arrived some other way,
/// which is an HTTP/2 call's: `head` is a head whose request line is empty, so
/// `HeaderIterator` reads it as it reads any other, and its fields are held
/// to every rule `parseHead` holds an HTTP/1.1 head's to, by the same loop
/// (ADR 253). `applyTarget` is the request line's half.
pub fn parseFields(head: []const u8, r: *Request) ParseError!void {
    if (head.len == 0 or head[0] != '\n') return error.BadRequestLine;
    return parseLines(head[1..], r, false);
}

/// The method and target of a request that had no request line to carry
/// them, held to what `parseRequestLine` holds a line's to: a method that is
/// a token, and a target with no space or control byte in it, which in a
/// line would have split it or been refused. A target is a path, or `*` for
/// an `OPTIONS`: the absolute and authority forms are HTTP/1.1's, and HTTP/2
/// says the authority in a field of its own (RFC 9113 §8.3.1).
pub fn applyTarget(method: []const u8, target: []const u8, r: *Request) ParseError!void {
    if (method.len == 0 or target.len == 0) return error.BadRequestLine;
    if (!tokenAt(method, 0, method.len)) return error.BadRequestLine;
    for (target) |ch| if (ch <= ' ' or ch == 0x7F) return error.BadRequestLine;
    if (target[0] != '/' and !(std.mem.eql(u8, target, "*") and std.mem.eql(u8, method, "OPTIONS")))
        return error.BadRequestLine;
    r.method = method;
    r.target = target;
}

/// `parseHead`'s loop, with or without a request line in front of the fields.
/// Comptime, so the head an HTTP/1.1 connection reads compiles to exactly the
/// loop it did before there was a second caller.
inline fn parseLines(head: []const u8, r: *Request, comptime request_line: bool) ParseError!void {
    var line_start: usize = 0;
    // Where this line's first colon is. 0 stands for "none yet" — a line
    // cannot begin with one, so the position is free to be the sentinel.
    var colon: usize = 0;
    var first_line = request_line;
    // Whether the line still open holds a byte no line may. Carried across
    // blocks for the same reason `colon` is.
    var line_bad = false;

    var i: usize = 0;
    while (i < head.len) : (i += lanes) {
        // One block, two compares. The colons cost a compare, not a pass.
        var newlines = blockAt(head, i, '\n');
        // Colons not yet accounted to a line. Cleared as each line claims its
        // own, so what is left over at the end of the block belongs to the
        // line still open — which is how a header spanning two blocks works.
        var unclaimed = blockAt(head, i, ':');
        // Stray bytes, claimed line by line the way the colons are. Tabs are
        // among them and kept apart, because only the request line refuses
        // one; they are looked for only in a block that has something stray,
        // which in a head a browser sent none has.
        const stray = strayBytes(head, i, newlines);
        var tabs: u32 = if (stray != 0) blockAt(head, i, '\t') & stray else 0;
        var bad = stray & ~tabs;

        while (newlines != 0) : (newlines &= newlines - 1) {
            const bit = @ctz(newlines);
            const nl_at = i + bit;

            const below: u32 = (@as(u32, 1) << @intCast(bit)) - 1;
            const mine = unclaimed & below;
            unclaimed &= ~below;
            if (colon == 0 and mine != 0) colon = i + @ctz(mine);
            if ((bad | if (first_line) tabs else 0) & below != 0) line_bad = true;
            bad &= ~below;
            tabs &= ~below;

            var end = nl_at;
            if (end > line_start and head[end - 1] == '\r') end -= 1;

            if (first_line) {
                if (line_bad) return error.BadRequestLine;
                try parseRequestLine(head[line_start..end], r);
                first_line = false;
            } else {
                if (end == line_start) return finish(r); // the blank line ends the head
                if (line_bad) return error.BadHeader;
                // A line that starts with whitespace is obs-fold, the
                // continuation of the header above it. RFC 9112 §5.2 lets a
                // server refuse it, and one that reads the continuation as
                // a header of its own while a front end folds it frames the
                // request differently, so it is a 400.
                if (head[line_start] == ' ' or head[line_start] == '\t') return error.BadHeader;
                // No colon (0 is the sentinel), a colon where the name
                // should be, or one past the end of the line. A field name
                // is one or more characters (RFC 9110 §5.1), so `: value`
                // is malformed and gets the same 400 as a line with no
                // colon at all — found by `fuzz.zig`, which had nilo
                // ignoring it and every reference parser refusing it.
                if (colon <= line_start or colon >= end) return error.BadHeader;
                // No whitespace between the field name and the colon (RFC 9112
                // §5.1). `Name : value` a front end reads leniently as
                // `Name: value` while nilo drops it is a framing disagreement,
                // so it is a 400 rather than a line that is quietly ignored.
                if (head[colon - 1] == ' ' or head[colon - 1] == '\t') return error.BadHeader;
                // A name is a token (RFC 9110 §5.1). `Transfer-Encoding\x0b` or
                // `Con,nection` is a line nilo would ignore while a front end
                // that strips or splits the stray byte reads it as framing.
                // Every name, not only the five read below, because which name
                // a front end makes of it is the question.
                if (!tokenAt(head, line_start, colon)) return error.BadHeader;
                // Five headers matter and between them they start with four
                // letters, so one compare throws out Accept, User-Agent and the
                // rest before their name is even measured. `e` is here for
                // `Expect` and `h` for `Host`, and both were cheap for the same
                // reason: a set of four bytes compiles to the same range test
                // and mask as a set of two.
                switch (head[line_start] | 0x20) {
                    'c', 'e', 'h', 't' => try applyHeaderAt(head, line_start, colon, end, r),
                    else => {},
                }
            }

            line_start = nl_at + 1;
            colon = 0;
            line_bad = false;
        }
        if (colon == 0 and unclaimed != 0) colon = i + @ctz(unclaimed);
        if ((bad | if (first_line) tabs else 0) != 0) line_bad = true;
    }

    // A head with no blank line in it — which `readHead` never produces, but
    // a caller parsing a fragment can. Whatever is left is one more line.
    if (line_start < head.len or first_line) {
        const line = trimCR(head[@min(line_start, head.len)..]);
        if (first_line) {
            if (line_bad) return error.BadRequestLine;
            try parseRequestLine(line, r);
        } else if (line.len > 0) {
            if (line_bad) return error.BadHeader;
            try applyHeader(line, r);
        }
    }
    return finish(r);
}

/// The control bytes in the block at `i` that no line may carry where they
/// are: every one but LF, and but a CR with an LF after it. Tab is in it;
/// the caller tells tabs apart. A CR on the last byte of `head` is let
/// through, since `trimCR` takes it off the line, and only a fragment ends
/// that way.
///
/// "Followed by an LF" is the block's own LF mask shifted down a bit, with
/// the byte past the block read for the top one, rather than a second
/// compare: three compares a block for the whole check (ADR 231).
fn strayBytes(head: []const u8, i: usize, newlines: u32) u32 {
    const controls = scan.controlsOf(head, i) & ~newlines;
    var ended = newlines >> 1;
    if (i + lanes < head.len) {
        if (head[i + lanes] == '\n') ended |= 1 << (lanes - 1);
    } else {
        ended |= @as(u32, 1) << @intCast(head.len - 1 - i);
    }
    return controls & ~(blockAt(head, i, '\r') & ended);
}

/// Whether `buf[from..to]` is a token, a block at a time. Loads past `to`
/// and masks what it does not own, so a name shorter than a block is one
/// load and one class test against the rest of its line, and only a byte
/// that is not a letter, digit or `-` is looked up in the grammar.
///
/// `inline` because it is called for every header line, where a call saves
/// registers and loads the class's constants for a check shorter than that.
/// A buffer shorter than a block, which is a request line like
/// `GET / HTTP/1.1`, is checked over the name alone rather than through the
/// scan's byte loop over all of it.
inline fn tokenAt(buf: []const u8, from: usize, to: usize) bool {
    if (from >= to) return false;
    if (buf.len < lanes) {
        for (buf[from..to]) |ch| if (!scan.isTokenByte(ch)) return false;
        return true;
    }
    var at = from;
    while (at < to) : (at += lanes) {
        var bits = scan.unusualNameBytesOf(buf, at);
        if (to - at < lanes) bits &= scan.below(@intCast(to - at));
        while (bits != 0) : (bits &= bits - 1) {
            if (!scan.isTokenByte(buf[at + @ctz(bits)])) return false;
        }
    }
    return true;
}

/// What has to be true of a head as a whole rather than of any one line in it,
/// asked once however the parse got here.
///
/// There is one such rule and it is `Host`. **RFC 9112 §3.2 requires a 400 for
/// an HTTP/1.1 request that carries none**, and serving one anyway is nilo
/// agreeing to answer a request no front end would (ADR 070). It matters a
/// layer up too: `Ctx.handshake` compares an `Origin` against this.
///
/// HTTP/1.0 is left alone — `Host` was not required until 1.1.
///
/// An absolute-form target answers the rule on its own, because it **is** the
/// authority (ADR 095). A `Host` beside one is still read and a second one is
/// still a 400.
fn finish(r: *Request) ParseError!void {
    if (r.minor_version == 1 and !r.has_host and r.authority.len == 0) return error.BadHeader;
    // HTTP/1.0 has no `Transfer-Encoding` (RFC 9112 §6.1), so a request that
    // carries one is framed by something its sender and a front end may not
    // agree on. It is answered and the connection is closed, whatever
    // `Connection` said on whichever line: asked here, so the order of the
    // headers cannot matter.
    if (r.minor_version == 0 and r.chunked) r.keep_alive = false;
    // Asked here rather than in the header arm, so the answer does not depend
    // on whether the framing headers arrived before the encoding one.
    //
    // A body nilo cannot decode is refused rather than parsed as though the
    // bytes were what they claim to be — the same failure `Transfer-Encoding`
    // used to have, one header over (ADR 089). A `Content-Encoding` on a
    // request with no body says nothing about anything and is left alone.
    if (r.content_encoding == .other and (r.chunked or r.content_length > 0)) return error.UnsupportedContentEncoding;
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
    } else if (versionShaped(version)) {
        return error.UnsupportedVersion;
    } else {
        return error.BadRequestLine;
    }

    // A method is a token (RFC 9110 §9.1). Any token, since one nobody routed
    // is a 404 or a 405, but not `GET\t` or `G,ET`: a front end that trims or
    // splits it routes a method nilo does not.
    if (!tokenAt(line, 0, sp1)) return error.BadRequestLine;

    r.method = method;
    r.target = target;
    // Origin-form is the whole of what a browser sends, and it is already a
    // path. Of the three other forms only `http(s)` absolute-form names a
    // route here, and it is turned into one; the other two are kept for the
    // one method each is defined for, and **nothing else is let through**: a
    // target that does not begin with `/` reaches the router, which has no
    // way to know the slash was never there (ADR 095).
    if (target[0] != '/') {
        if (try absoluteForm(target)) |split| {
            r.authority = split.authority;
            r.target = split.target;
        } else if (std.mem.eql(u8, target, "*")) {
            // Asterisk-form is `OPTIONS *` and nothing else (RFC 9112 §3.2.4).
            if (!std.mem.eql(u8, method, "OPTIONS")) return error.BadRequestLine;
        } else if (std.mem.eql(u8, method, "CONNECT")) {
            // Authority-form (RFC 9112 §3.2.3), a tunnel request nilo is not
            // the proxy for. It parses so it can be answered, and is never
            // routed.
            if (!authorityOk(target, true)) return error.BadRequestLine;
        } else return error.BadRequestLine;
    }
}

/// `HTTP/` DIGIT `.` DIGIT, RFC 9112 §2.3: spelled like a version, whether or
/// not nilo speaks it.
fn versionShaped(version: []const u8) bool {
    return version.len == 8 and std.mem.eql(u8, version[0..5], "HTTP/") and
        std.ascii.isDigit(version[5]) and version[6] == '.' and std.ascii.isDigit(version[7]);
}

/// `host [ ":" port ]` as RFC 3986 §3.2 spells it, with the host not empty
/// (RFC 9110 §4.2.1): an IP-literal in brackets, or a reg-name, which an
/// IPv4 address is also spelled as. `port_required` is authority-form's
/// `uri-host ":" port` (RFC 9112 §3.2.3).
fn authorityOk(authority: []const u8, port_required: bool) bool {
    var host = authority;
    // The port is after the last colon, unless that colon is inside an
    // IP-literal's brackets.
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |last| {
        if ((std.mem.lastIndexOfScalar(u8, authority, ']') orelse 0) < last) {
            for (authority[last + 1 ..]) |ch| if (!std.ascii.isDigit(ch)) return false;
            host = authority[0..last];
        } else if (port_required) return false;
    } else if (port_required) return false;
    if (host.len == 0) return false;
    if (host[0] == '[') {
        if (host.len < 3 or host[host.len - 1] != ']') return false;
        for (host[1 .. host.len - 1]) |ch| if (!regNameByte(ch) and ch != ':') return false;
        return true;
    }
    for (host) |ch| if (!regNameByte(ch)) return false;
    return true;
}

/// unreserved, sub-delims and the `%` of pct-encoded: RFC 3986 §3.2.2's
/// reg-name.
fn regNameByte(ch: u8) bool {
    return switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~' => true,
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '%' => true,
        else => false,
    };
}

/// The authority and the path out of an absolute-form target, or null for a
/// target that is not in that form.
///
/// `GET http://example.com/users/7 HTTP/1.1` is legal — **RFC 9112 §3.2.2 says
/// a server must accept it** — and a client talking to what it believes is a
/// proxy sends it. nilo handed the whole thing to the router as a path, which
/// split it into `http:`, ``, `example.com`, `users` and `7`, and matched
/// nothing: a 404 on a route that plainly exists
/// ([ADR 095](../docs/adr/095-a-target-is-read-in-the-form-it-arrived-in.md)).
///
/// The two forms left are kept for the one method each is defined for, and
/// neither is routed: **asterisk-form** (`OPTIONS *`) is a server-wide OPTIONS
/// that `serve.zig` answers without asking the router, and **authority-form**
/// (`CONNECT example.com:443`) asks for a tunnel from a proxy nilo is not,
/// answered 404. Any other target that does not begin with `/`, an `ftp://`
/// absolute-form or `admin:1/x` included, is a 400: it used to reach the router,
/// which splits on `/` and matched `admin:1/x` against `/:a/x`.
///
/// Two shapes inside absolute-form are refused rather than served:
///
/// - **Userinfo.** `http://real.example.com@evil.example.net/` names
///   `evil.example.net`, and RFC 9110 §4.2.4 says a recipient must reject a
///   userinfo subcomponent. A host somebody misreads is worse than a 400.
/// - **An empty path with a query.** `http://example.com?a=1` would have to
///   become `/?a=1`, and there is no `/` in front of that query to point at —
///   this parser copies nothing and every slice it hands back is inside the
///   head. Dropping the query silently is the alternative, and it is worse.
fn absoluteForm(target: []const u8) ParseError!?struct { authority: []const u8, target: []const u8 } {
    const scheme_len: usize = if (std.ascii.startsWithIgnoreCase(target, "http://"))
        "http://".len
    else if (std.ascii.startsWithIgnoreCase(target, "https://"))
        "https://".len
    else
        return null;

    const rest = target[scheme_len..];
    var end: usize = 0;
    while (end < rest.len and rest[end] != '/' and rest[end] != '?' and rest[end] != '#') end += 1;

    const authority = rest[0..end];
    if (authority.len == 0) return error.BadRequestLine;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.BadRequestLine;
    // It becomes the Host, so it is held to what a host can be spelled with:
    // `http://|/y` named a host no front end reads the same way (ADR 231).
    if (!authorityOk(authority, false)) return error.BadRequestLine;

    if (end == rest.len) {
        // `http://example.com`, which is a request for `/`. The slash handed
        // back is the second one of the target's own `//`, so this stays a
        // slice of the head like every other one — `App` moves these onto a
        // copy of the head by their offset into it, and a static `"/"` has no
        // offset into anything.
        return .{ .authority = authority, .target = target[scheme_len - 1 .. scheme_len] };
    }
    if (rest[end] != '/') return error.BadRequestLine;
    return .{ .authority = authority, .target = rest[end..] };
}

/// Only five header names are looked at: four change how the request is read,
/// and `Host` is counted rather than read, because RFC 9112 §3.2 makes both
/// none of it and two of it a 400. Every other one is still checked for a
/// colon — a line without one is malformed and is not going to be quietly
/// accepted — but nothing past the name is touched, because the parser has no
/// use for it.
///
/// The name length is looked at before the name itself, so a request full
/// of `Accept`, `Cookie` and `User-Agent` costs one integer compare each
/// rather than three case-insensitive string compares and a trim.
pub fn applyHeader(line: []const u8, r: *Request) ParseError!void {
    // obs-fold, refused as `parseHead` refuses it (RFC 9112 §5.2).
    if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) return error.BadHeader;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
    // A line that begins with its colon has no name — malformed, same as
    // one with no colon.
    if (colon == 0) return error.BadHeader;
    // No whitespace between the field name and the colon, the same refusal
    // `parseHead` makes on the fast path (RFC 9112 §5.1).
    if (line[colon - 1] == ' ' or line[colon - 1] == '\t') return error.BadHeader;
    if (!headerNameOk(line[0..colon])) return error.BadHeader;
    return applyHeaderAt(line, 0, colon, line.len, r);
}

/// `applyHeader`, for a caller that already knows where the name ends —
/// which `parseHead` does, because its one pass found the colon on the way
/// past. `from`, `colon` and `end` are indices into `buf`.
fn applyHeaderAt(buf: []const u8, from: usize, colon: usize, end: usize, r: *Request) ParseError!void {
    const name = buf[from..colon];

    switch (name.len) {
        "host".len => {
            // `ETag` and `Date` are the same length and reach here too; both
            // fail `eqlIgnoreCase` on their first byte.
            if (!std.ascii.eqlIgnoreCase(name, "host")) return;
            // **A second `Host` line is a 400 even when it agrees with the
            // first**, which is where this differs from `Content-Length` two
            // arms down: RFC 9112 §3.2 refuses the repeat itself rather than
            // the disagreement, because a request naming two authorities is
            // one the front end and nilo may route differently.
            if (r.has_host) return error.BadHeader;
            r.has_host = true;
            // The value is held to what a host can be spelled with (RFC 9110
            // §7.2). It was only counted, so `evil.com/reset?x=` or `a@b`
            // reached `Ctx.host` and whatever was built from it. Empty stays
            // legal: RFC 9112 §3.2 has it for a target with no authority.
            const host = headerValue(buf, colon, end);
            if (host.len > 0 and !authorityOk(host, false)) return error.BadHeader;
        },
        "expect".len => {
            // `Cookie` is the same length and reaches here too, so this arm is
            // on the path of most requests. It costs one `eqlIgnoreCase` that
            // fails on its first byte.
            if (!std.ascii.eqlIgnoreCase(name, "expect")) return;
            // The value is a comma-separated list, and `100-continue` is the
            // only member anybody has ever defined. Matching the whole value
            // rather than searching it keeps a header carrying some future
            // expectation from being read as this one.
            if (std.ascii.eqlIgnoreCase(headerValue(buf, colon, end), "100-continue")) {
                r.expect_continue = true;
            }
        },
        "connection".len => {
            if (!std.ascii.eqlIgnoreCase(name, "connection")) return;
            const value = headerValue(buf, colon, end);
            // The two values nearly every request sends, answered before the
            // list is split.
            if (std.ascii.eqlIgnoreCase(value, "keep-alive")) return keepAlive(r);
            if (std.ascii.eqlIgnoreCase(value, "close")) {
                r.keep_alive = false;
                return;
            }
            connectionList(value, r);
        },
        "content-length".len => {
            if (!std.ascii.eqlIgnoreCase(name, "content-length")) return;
            // A body framed two ways is a body the proxy in front and nilo
            // can measure differently, and the difference is where a
            // smuggled request travels (RFC 9112 §6.3). Both shapes of that
            // are refused here rather than resolved.
            if (r.chunked) return error.BadHeader;
            const n = digitsOnly(headerValue(buf, colon, end)) orelse return error.BadHeader;
            if (r.has_content_length and n != r.content_length) return error.BadHeader;
            r.content_length = n;
            r.has_content_length = true;
        },
        "content-encoding".len => {
            if (!std.ascii.eqlIgnoreCase(name, "content-encoding")) return;
            // `identity` means "these are the bytes"; `gzip` is the one
            // coding nilo inflates (ADR 089). Anything else — br, deflate,
            // zstd, two codings stacked — would reach `c.json` as a
            // compressed stream and be reported as a malformed body, which
            // is true of the bytes and useless to whoever sent them. The
            // refusal itself is `finish`'s, because whether there is a body
            // to refuse is not settled yet.
            const coding = headerValue(buf, colon, end);
            r.content_encoding = if (std.ascii.eqlIgnoreCase(coding, "identity"))
                .identity
            else if (std.ascii.eqlIgnoreCase(coding, "gzip") or std.ascii.eqlIgnoreCase(coding, "x-gzip"))
                .gzip
            else
                .other;
        },
        "transfer-encoding".len => {
            if (!std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return;
            // A second `Transfer-Encoding` line continues the first one's
            // list (RFC 9110 §5.3), so a `chunked` already seen is no longer
            // the last coding, which RFC 9112 §6.1 requires it to be.
            if (r.chunked) return error.BadHeader;
            // **A final coding that is not `chunked` is a 400**, which RFC 9112
            // §6.1 requires of a server that cannot decode it, and nilo can
            // decode exactly one. Doing nothing here instead, which is what
            // this arm used to do, left `Transfer-Encoding: gzip` framed as a
            // request with no body at all: answered immediately, with the bytes
            // the client sent as a body still in the read buffer for the next
            // request to be parsed out of. That is the fifth way the two
            // parsers ADR 070 is about can disagree, and the four it closed
            // were closed for this reason.
            //
            // **A coding in front of `chunked` is a 501** (RFC 9112 §6.1), where
            // it was read as chunked and handed to the handler as its body:
            // `gzip, chunked` was framed right and its bytes were still gzip.
            switch (chunkedState(headerValue(buf, colon, end))) {
                .lone => {},
                .stacked => return error.UnsupportedTransferEncoding,
                .not_last => return error.BadHeader,
            }
            if (r.has_content_length) return error.BadHeader;
            r.chunked = true;
        },
        else => {},
    }
}

/// A `Connection` value that is a list (RFC 9110 §7.6.1), where `close`
/// anywhere wins (RFC 9112 §9.6): `keep-alive, close` used to be read as
/// neither and kept an HTTP/1.1 connection open, and `keep-alive, Upgrade`
/// closed an HTTP/1.0 one llhttp keeps. Out of line so that the arm the two
/// common values take stays the size it was.
noinline fn connectionList(value: []const u8, r: *Request) void {
    var close = false;
    var keep = false;
    var options = std.mem.splitScalar(u8, value, ',');
    while (options.next()) |raw| {
        const option = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(option, "close")) close = true;
        if (std.ascii.eqlIgnoreCase(option, "keep-alive")) keep = true;
    }
    if (close) r.keep_alive = false else if (keep) keepAlive(r);
    // A handshake sends `Upgrade` or `keep-alive, Upgrade`. Searched for
    // rather than matched as an option, because `upgrade` is looser on
    // purpose (see the field).
    if (std.ascii.indexOfIgnoreCase(value, "upgrade") != null) r.upgrade = true;
}

/// `keep-alive` asks for what HTTP/1.1 already does, so there it changes
/// nothing, and a `close` on an earlier line stays closed. On HTTP/1.0 it is
/// what opens the connection. A `close` line *before* a `keep-alive` one on
/// HTTP/1.0 is the one order this reads as open: remembering it would be a
/// ninth byte in a `Request` whose eight fill its padding, for a request no
/// client sends.
fn keepAlive(r: *Request) void {
    if (r.minor_version == 0) r.keep_alive = true;
}

fn headerValue(buf: []const u8, colon: usize, end: usize) []const u8 {
    return std.mem.trim(u8, buf[colon + 1 .. end], " \t");
}

/// A digits-only number. `std.fmt.parseInt` accepts `+5`, `-0` and `1_0`, and
/// a `Content-Length` is none of those: RFC 9112 §6.2 says the value is
/// `1*DIGIT` and nothing else. What makes that matter rather than merely
/// being wrong is that the proxy in front (ADR 027) very likely refuses the
/// same bytes, so accepting them is nilo agreeing to read a request nobody
/// else agreed to.
///
/// A leading zero is *not* in that list. `05` is two digits and so is legal
/// ABNF, every parser reads it as 5, and refusing it would turn a request
/// everyone agrees about into a 400.
///
/// `range.zig` carries the same four lines for the same reason, and they stay
/// separate on purpose: `range.zig` has to keep running under a plain `zig
/// test http/range.zig`, which importing this file would cost it.
fn digitsOnly(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// What a `Transfer-Encoding` value says about `chunked`, which RFC 9112 §6.1
/// allows only as the **last** coding in the list. Looking for the word
/// anywhere in the value would take `xchunked` and `chunked-x` for it, and a
/// front end that reads those as a coding it does not know while nilo reads
/// them as framing is the same disagreement by another spelling.
const ChunkedState = enum {
    /// The whole value is `chunked`, the one coding nilo decodes.
    lone,
    /// `chunked` is last and something is before it.
    stacked,
    /// The last coding is something else, or nothing.
    not_last,
};

fn chunkedState(value: []const u8) ChunkedState {
    const from = if (std.mem.lastIndexOfScalar(u8, value, ',')) |c| c + 1 else 0;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[from..], " \t"), "chunked")) return .not_last;
    return if (from == 0) .lone else .stacked;
}

/// The reason phrase of a status, **the one table every status line is built
/// from**: the cold path, the compile-time lines, and the static answers in
/// `serve.zig` (`staticResponse` takes a status and reads it from here).
///
/// Every registered status, because a `fail.status(502, …)` or a
/// `Response(T)` can send any of them, and a status missing from here went out
/// as `HTTP/1.1 502 \r\n`. RFC 9112 §4 lets the phrase be empty, so a status
/// nobody registered gets none rather than a made-up one (ADR 024).
pub fn statusPhrase(status: u16) []const u8 {
    return switch (status) {
        100 => "Continue",
        101 => "Switching Protocols",
        103 => "Early Hints",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        203 => "Non-Authoritative Information",
        204 => "No Content",
        205 => "Reset Content",
        206 => "Partial Content",
        207 => "Multi-Status",
        208 => "Already Reported",
        226 => "IM Used",
        300 => "Multiple Choices",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        407 => "Proxy Authentication Required",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Content Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        417 => "Expectation Failed",
        418 => "I'm a Teapot",
        421 => "Misdirected Request",
        422 => "Unprocessable Content",
        423 => "Locked",
        424 => "Failed Dependency",
        425 => "Too Early",
        426 => "Upgrade Required",
        428 => "Precondition Required",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        451 => "Unavailable For Legal Reasons",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        505 => "HTTP Version Not Supported",
        506 => "Variant Also Negotiates",
        507 => "Insufficient Storage",
        508 => "Loop Detected",
        510 => "Not Extended",
        511 => "Network Authentication Required",
        else => "",
    };
}

/// What a response's `Connection` line says — or that there is none
/// ([ADR 197](../docs/adr/197-a-response-says-when-it-was-sent.md)).
///
/// The line carries information in two cases and none in the third. An
/// HTTP/1.1 connection is persistent unless somebody says otherwise (RFC
/// 9112 §9.3), so `keep-alive` on an HTTP/1.1 response tells the client
/// what it already assumed, and the twenty-four bytes are left off. An
/// HTTP/1.0 client assumes the opposite and has to be told it may stay; a
/// closing connection has to be announced whichever version asked.
pub const Connection = enum {
    /// HTTP/1.1, staying open: no line at all.
    implied,
    /// HTTP/1.0 asked to stay open and is being kept: `keep-alive`.
    keep_alive,
    /// Closing after this response.
    close,

    /// The line for a connection that is (or is not) being kept, given
    /// which version the request came in under.
    pub fn of(keep_alive: bool, minor_version: u1) Connection {
        if (!keep_alive) return .close;
        return if (minor_version == 0) .keep_alive else .implied;
    }

    fn write(self: Connection, out: *std.Io.Writer) !void {
        switch (self) {
            .implied => {},
            .keep_alive => try out.writeAll("Connection: keep-alive\r\n"),
            .close => try out.writeAll("Connection: close\r\n"),
        }
    }
};

/// A response assembled at compile time, in the two pieces the `Date`
/// line goes between: for responses with fixed contents, this turns
/// writing one into three `writeAll`s and no formatting.
pub const Static = struct {
    /// The status line, CRLF included.
    line: []const u8,
    /// Everything after the `Date` line: the rest of the head, and the body.
    rest: []const u8,
};

pub fn staticResponse(
    comptime status: u16,
    comptime content_type: []const u8,
    comptime body: []const u8,
    comptime connection: Connection,
) Static {
    return .{
        .line = statusLine(status),
        .rest = std.fmt.comptimePrint(
            "Content-Type: {s}\r\nContent-Length: {d}\r\n{s}\r\n{s}",
            .{ content_type, body.len, comptime connectionLine(connection), body },
        ),
    };
}

fn connectionLine(comptime connection: Connection) []const u8 {
    return switch (connection) {
        .implied => "",
        .keep_alive => "Connection: keep-alive\r\n",
        .close => "Connection: close\r\n",
    };
}

/// Put a `Static` on the wire with the `Date` it is being sent at.
pub fn writeStatic(out: *std.Io.Writer, response: Static) !void {
    try out.writeAll(response.line);
    try date.writeLine(out);
    try out.writeAll(response.rest);
}

/// Whether a handler or middleware already set a `Date`, in which case the
/// framework's is not written over it. A loop over `extra`, which is
/// empty or a few entries long on every response there is.
fn hasDate(extra: []const Header) bool {
    for (extra) |h| if (h.name.len == 4 and std.ascii.eqlIgnoreCase(h.name, "Date")) return true;
    return false;
}

fn writeDate(out: *std.Io.Writer, extra: []const Header) !void {
    if (!hasDate(extra)) try date.writeLine(out);
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
/// go out first and `extra` may not repeat them — except `Date`, which a
/// handler that sets one is trusted about, and the framework's is left off.
///
/// Written, not flushed: `settle` is the flush, and the caller makes it
/// once the response is whole. The tests here write into a fixed buffer
/// and read it back, which is why nothing in this file needs a socket.
pub fn writeResponse(
    out: *std.Io.Writer,
    status: u16,
    phrase: []const u8,
    content_type: []const u8,
    body: []const u8,
    connection: Connection,
    extra: []const Header,
) !void {
    try writeHead(out, status, phrase, content_type, body.len, connection, extra);
    // A body under a bodyless status would be read as the start of the next
    // request on this connection, which is how a response-splitting bug
    // begins. The head already said there is none.
    if (!bodyless(status)) try out.writeAll(body);
}

/// Put a finished response on the wire, unless the request after it is
/// already here.
///
/// A client that pipelines sent its next request before reading this
/// answer, so nothing is waiting on this flush: the answer goes out with
/// the next one, or with the last of the batch, in one write instead of
/// one a response. A client that does not pipeline, which is every browser
/// and every client by default, leaves the read buffer empty once its
/// request is parsed, and its answer is flushed here as it always was.
///
/// Skipping is safe because of the Engine, not because of anything the
/// caller promises: a socket read flushes what is pending before it can
/// park, so a response is never left in memory while the connection waits
/// for its client ([ADR 201](../docs/adr/201-a-response-is-flushed-before-the-connection-waits.md)).
/// The write buffer bounds the batch; a run of responses longer than it
/// drains as it fills, the way any write does.
pub fn settle(out: *std.Io.Writer, in: *const std.Io.Reader) !void {
    if (in.seek != in.end) return;
    try out.flush();
}

// ---- writing a body whose length is not known yet ----

/// The head of a streamed response: one of the three ways HTTP has of saying
/// where a body stops.
///
/// `length` is the one a handler can only use when it already knows — bytes
/// being moved out of something that counted them first. It is a
/// `Content-Length` like any other response, which is what lets a browser draw
/// a progress bar and a client ask for a `Range`
/// ([ADR 101](../docs/adr/101-a-stream-that-knows-its-length-says-so.md)).
///
/// `chunked` is the ordinary case for an HTTP/1.1 client whose handler does
/// not know: each piece is framed with its own length and a zero-length one
/// ends the body, so the connection survives to carry another request.
///
/// HTTP/1.0 has neither, and the only thing left to mark the end of the body
/// with is the end of the connection — so there both are off, `connection`
/// must be `.close` with them, and the pieces go out unframed (ADR 019).
pub fn writeStreamHead(
    out: *std.Io.Writer,
    status: u16,
    phrase: []const u8,
    content_type: []const u8,
    chunked: bool,
    length: ?u64,
    connection: Connection,
    extra: []const Header,
) !void {
    // Never both: a head carrying a length and a chunked encoding is one a
    // proxy is entitled to read either way, which is how a request smuggles.
    std.debug.assert(!(chunked and length != null));

    try writeStatusLine(out, status, phrase);
    try writeDate(out, extra);
    try out.print("Content-Type: {s}\r\n", .{content_type});
    if (length) |n| try out.print("Content-Length: {d}\r\n", .{n});
    if (chunked) try out.writeAll("Transfer-Encoding: chunked\r\n");
    try connection.write(out);
    for (extra) |h| try writeExtra(out, h);
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

/// The zero-length chunk, and a trailer section holding `trailers` (RFC 9112
/// §7.1.2). Each one was checked as a header when it was set, so it is
/// written as it is.
pub fn writeLastChunkWith(out: *std.Io.Writer, trailers: []const Header) !void {
    if (trailers.len == 0) return writeLastChunk(out);
    try out.writeAll("0\r\n");
    for (trailers) |t| {
        try out.writeAll(t.name);
        try out.writeAll(": ");
        try out.writeAll(t.value);
        try out.writeAll("\r\n");
    }
    try out.writeAll("\r\n");
}

/// The response to a HEAD: the head has to be byte-for-byte what a GET
/// would have produced — including the `Content-Length` naming the length
/// of the body it would have sent — but the body itself does not follow.
pub fn writeResponseHeadOnly(
    out: *std.Io.Writer,
    status: u16,
    phrase: []const u8,
    content_type: []const u8,
    body_len: u64,
    connection: Connection,
    extra: []const Header,
) !void {
    try writeHead(out, status, phrase, content_type, body_len, connection, extra);
}

/// The head of a response whose body is about to be sent straight from a
/// file (ADR 009).
///
/// `sendFile` takes whatever the writer already has buffered as the first
/// thing to put on the wire, so leaving the head there is what makes the
/// head and the first bytes of the file leave in one operation instead of
/// two. Flushing first would cost a syscall and, on a small file, a packet.
///
/// The caller flushes, once the body is done.
pub fn writeFileHead(
    out: *std.Io.Writer,
    status: u16,
    phrase: []const u8,
    content_type: []const u8,
    body_len: u64,
    connection: Connection,
    extra: []const Header,
) !void {
    return writeHead(out, status, phrase, content_type, body_len, connection, extra);
}

/// The whole first line, assembled at compile time for every status the
/// framework knows. A response then starts with one `writeAll` of a
/// constant instead of formatting an integer and pasting three pieces
/// together — and the status and its phrase cannot drift apart, because
/// there is only one of them.
pub fn statusLine(comptime status: u16) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 {d} {s}\r\n", .{ status, statusPhrase(status) });
}

fn writeStatusLine(out: *std.Io.Writer, status: u16, phrase: []const u8) !void {
    switch (status) {
        inline 200, 201, 204, 206, 301, 302, 303, 304, 307, 308, 400, 401, 403, 404, 405, 409, 413, 416, 422, 429, 431, 500, 501, 503 => |s| {
            return out.writeAll(comptime statusLine(s));
        },
        else => return out.print("HTTP/1.1 {d} {s}\r\n", .{ status, phrase }),
    }
}

/// `body_len` is a `u64` rather than a `usize` because a response body no
/// longer has to be something this process could hold: a file being sent
/// from disk is longer than memory on purpose (ADR 009), and on a 32-bit
/// build a `usize` would silently be the wrong number.
fn writeHead(
    out: *std.Io.Writer,
    status: u16,
    phrase: []const u8,
    content_type: []const u8,
    body_len: u64,
    connection: Connection,
    extra: []const Header,
) !void {
    try writeStatusLine(out, status, phrase);
    // `Date` is second, straight after the status line, on every response
    // that reaches here (ADR 197). The interim ones — a 100, a 101 — are
    // written elsewhere and carry none, which RFC 9110 §6.6.1 allows.
    try writeDate(out, extra);
    if (bodyless(status)) {
        // No Content-Length: see `bodyless`. Content-Type still goes out on
        // a 304, which is describing a representation the client already
        // has, but not on a 204, where there is no representation at all.
        if (status == 304 and content_type.len > 0) {
            try out.print("Content-Type: {s}\r\n", .{content_type});
        }
    } else {
        // An empty content type is how a caller says there is no body to
        // describe — a handler returning `void` under a status that is not
        // one of the bodyless ones. `Content-Length: 0` still goes out,
        // because that status *does* have a body and its length is nothing;
        // `Content-Type:` with nothing after it would be a malformed header.
        if (content_type.len > 0) try out.print("Content-Type: {s}\r\n", .{content_type});
        try out.print("Content-Length: {d}\r\n", .{body_len});
    }
    try connection.write(out);
    for (extra) |h| try writeExtra(out, h);
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
    var in = std.Io.Reader.fixed("GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    const r = try readRequest(&in);
    try testing.expect(!r.keep_alive);
}

test "Content-Length is read and the body is discarded" {
    var in = std.Io.Reader.fixed("POST /send HTTP/1.1\r\nHost: t\r\nContent-Length: 5\r\n\r\nhelloGET");
    const r = try readRequest(&in);
    try testing.expectEqualStrings("POST", r.method);
    try testing.expectEqual(@as(u64, 5), r.content_length);
    try discardBody(&in, &r, 1024);
    try testing.expectEqualStrings("GET", try in.take(3));
}

test "two requests back to back on one connection" {
    var in = std.Io.Reader.fixed("GET /one HTTP/1.1\r\nHost: t\r\n\r\nGET /two HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
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
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n" ++
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

test "a body of an announced length is taken as it arrives, not as it is promised" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Every size around the step boundary, so the loop is exercised at zero,
    // one short, exact, one over and several steps.
    for ([_]usize{ 0, 1, sized_body_step - 1, sized_body_step, sized_body_step + 1, sized_body_step * 3 + 7 }) |len| {
        const bytes = try testing.allocator.alloc(u8, len);
        defer testing.allocator.free(bytes);
        for (bytes, 0..) |*b, i| b.* = @truncate(i);

        var in = std.Io.Reader.fixed(bytes);
        try testing.expectEqualSlices(u8, bytes, try readSizedBody(&in, arena.allocator(), len, .off));
    }

    // The connection is left exactly at the next request.
    var two = std.Io.Reader.fixed("hiNEXT");
    try testing.expectEqualStrings("hi", try readSizedBody(&two, arena.allocator(), 2, .off));
    try testing.expectEqualStrings("NEXT", try two.take(4));
}

test "a client that announces more than it sends holds only what it sent" {
    // Ten megabytes announced, four bytes delivered, and 64 KiB of allocator
    // to serve it from — so the old shape, which took `content_length` out of
    // the arena before reading a byte, cannot pass this: it fails allocating
    // and never reaches the read. A slow-loris is the same request with the
    // connection left open instead of ending.
    var room: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&room);
    var arena = std.heap.ArenaAllocator.init(fixed.allocator());
    defer arena.deinit();

    var in = std.Io.Reader.fixed("slow");
    try testing.expectError(
        error.EndOfStream,
        readSizedBody(&in, arena.allocator(), 10 * 1024 * 1024, .off),
    );
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

test "a chunk line ends at CRLF and nowhere else, so an extension cannot move where it ends" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refused = [_][]const u8{
        // TERM.EXT: the LF ends the line here, and a front end that reads it
        // as a byte of the extension ends it at the CRLF two bytes on.
        "2;\nxx\r\n0\r\n\r\n",
        // A bare LF after the size, after the data, and after the last chunk.
        "3\nabc\r\n0\r\n\r\n",
        "3\r\nabc\n0\r\n\r\n",
        "3\r\nabc\r\n0\n\r\n",
        // A control byte inside an extension, a lone CR the likeliest.
        "3;a\rb\r\nabc\r\n0\r\n\r\n",
        "3;a\x00\r\nabc\r\n0\r\n\r\n",
    };
    for (refused) |body| {
        var in = std.Io.Reader.fixed(body);
        try testing.expectError(error.BadChunk, readChunkedBody(&in, arena.allocator(), 1024));
    }
    // An extension of ordinary bytes, a tab and a quoted value, is still read.
    var fine = std.Io.Reader.fixed("3;name=\"a b\";\tx\r\nabc\r\n0\r\n\r\n");
    try testing.expectEqualStrings("abc", try readChunkedBody(&fine, arena.allocator(), 1024));
}

test "a trailer section has an end, however slowly its lines arrive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Each line fits the read buffer and the number of lines did not count:
    // a client could send trailers for as long as it held the connection.
    const line = "X-Pad: 0123456789\r\n";
    const lines = max_trailer_bytes / line.len + 1;
    var wire: std.ArrayList(u8) = .empty;
    try wire.appendSlice(arena.allocator(), "3\r\nabc\r\n0\r\n");
    for (0..lines) |_| try wire.appendSlice(arena.allocator(), line);
    try wire.appendSlice(arena.allocator(), "\r\n");
    var endless = std.Io.Reader.fixed(wire.items);
    try testing.expectError(error.BadChunk, readChunkedBody(&endless, arena.allocator(), 1024));

    // A checksum or two is what a trailer is for, and it still passes.
    var few = std.Io.Reader.fixed("3\r\nabc\r\n0\r\nDigest: sha-256=x\r\n\r\n");
    try testing.expectEqualStrings("abc", try readChunkedBody(&few, arena.allocator(), 1024));
}

test "a header line that starts with whitespace is folded, and refused" {
    // obs-fold (RFC 9112 §5.2): ` folded: 2` is the header above it carried
    // on, to a front end that folds, and a header of its own to one that
    // does not. The first line after the request line gets the same answer.
    var folded = std.Io.Reader.fixed("GET / HTTP/1.1\r\nHost: t\r\nX-A: 1\r\n folded: 2\r\n\r\n");
    try testing.expectError(error.BadHeader, readRequest(&folded));
    var first = std.Io.Reader.fixed("GET / HTTP/1.1\r\n\tHost: t\r\n\r\n");
    try testing.expectError(error.BadHeader, readRequest(&first));
}

test "a chunked body nobody read is discarded so the connection survives" {
    var in = std.Io.Reader.fixed(
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "3\r\nabc\r\n0\r\n\r\nGET /next HTTP/1.1\r\nHost: t\r\n\r\n",
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

test "a chunk size that overflows u64 is refused, not a panic" {
    // `seen + size` used to add before it checked, so a size of all-ones after
    // any earlier chunk overflowed — a panic in a safe build, a wrap past the
    // limit in a fast one. Refused on the announced size now, before a read.
    var in = std.Io.Reader.fixed("1\r\na\r\nffffffffffffffff\r\n");
    try testing.expectError(error.BodyTooLarge, discardChunkedBody(&in, 1024));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reading = std.Io.Reader.fixed("ffffffffffffffff\r\n");
    try testing.expectError(error.BodyTooLarge, readChunkedBody(&reading, arena.allocator(), 1024));
}

test "a chunk size is strict hex, so a lenient one cannot smuggle a length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Each of these is a size a front end may read differently: `+5` and `1_0`
    // (which std would read as 16) and leading or trailing whitespace. Every
    // one is `BadChunk` here rather than a body framed at a length nilo and the
    // proxy disagree about.
    inline for ([_][]const u8{
        "+5\r\nhello\r\n0\r\n\r\n",
        "1_0\r\n0123456789abcdef\r\n0\r\n\r\n",
        " 5\r\nhello\r\n0\r\n\r\n",
        "5\t\r\nhello\r\n0\r\n\r\n",
        "0x5\r\nhello\r\n0\r\n\r\n",
    }) |body| {
        var in = std.Io.Reader.fixed(body);
        try testing.expectError(error.BadChunk, readChunkedBody(&in, arena.allocator(), 1024));
    }

    // Real hex still reads, upper and lower case, so this refuses the lenient
    // spellings without refusing a legitimate size.
    var lower = std.Io.Reader.fixed("a\r\n0123456789\r\n0\r\n\r\n");
    try testing.expectEqualStrings("0123456789", try readChunkedBody(&lower, arena.allocator(), 1024));
    var upper = std.Io.Reader.fixed("A\r\n0123456789\r\n0\r\n\r\n");
    try testing.expectEqualStrings("0123456789", try readChunkedBody(&upper, arena.allocator(), 1024));
}

test "a Content-Length body over the limit is refused rather than drained" {
    // The drain path used to read a Content-Length body in full whatever it
    // announced, so a body over `max_body` was read only to be thrown away.
    // Refused now, and the caller closes the connection.
    var empty = std.Io.Reader.fixed("");
    const big = Request{ .content_length = 2000, .has_content_length = true };
    try testing.expectError(error.BodyTooLarge, discardBody(&empty, &big, 1024));

    // Under the limit still drains, and leaves the next request where it is.
    var in = std.Io.Reader.fixed("helloGET /next HTTP/1.1\r\nHost: t\r\n\r\n");
    const small = Request{ .content_length = 5, .has_content_length = true };
    try discardBody(&in, &small, 1024);
    const next = try readRequest(&in);
    try testing.expectEqualStrings("/next", next.target);
}

test "whitespace between a field name and its colon is a 400, not an ignored line" {
    // RFC 9112 §5.1: a server must reject a field with whitespace before the
    // colon. Both parse paths refuse it — the fast one over a whole head, and
    // the fragment one a caller reaches directly.
    var r = Request{};
    try testing.expectError(error.BadHeader, parseHead(
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding : chunked\r\n\r\n",
        &r,
    ));
    var r2 = Request{};
    try testing.expectError(error.BadHeader, parseHead(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length : 5\r\n\r\n",
        &r2,
    ));
    var r3 = Request{};
    try testing.expectError(error.BadHeader, applyHeader("Content-Length : 5", &r3));
    var r4 = Request{};
    try testing.expectError(error.BadHeader, applyHeader("X-Any\t: 1", &r4));

    // A tidy header beside it still parses, so the check is the whitespace and
    // not the name.
    var ok = Request{};
    try parseHead("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n", &ok);
    try testing.expectEqual(@as(u64, 5), ok.content_length);
}

test "a broken request line" {
    var r = Request{};
    try testing.expectError(error.BadRequestLine, parseRequestLine("GET /", &r));
    try testing.expectError(error.UnsupportedVersion, parseRequestLine("GET / HTTP/2.0", &r));
    // Spelled like a version and not spoken is a 505; this is not spelled like
    // one at all.
    try testing.expectError(error.BadRequestLine, parseRequestLine("GET / HTTP/1.1 x", &r));
}

test "a header with no colon" {
    var r = Request{};
    try testing.expectError(error.BadHeader, applyHeader("Host no-colon", &r));
}

test "a control byte, or a CR that does not end its line, is refused in any line" {
    // Each of these is what llhttp refused and nilo read (ADR 231). A front
    // end that turns the CR into a line end, or drops the NUL, reads another
    // request.
    const request_line = [_][]const u8{
        "GET /a\x00b HTTP/1.1\r\nHost: h\r\n\r\n",
        "GET /a\tb HTTP/1.1\r\nHost: h\r\n\r\n",
        "GET\t /a HTTP/1.1\r\nHost: h\r\n\r\n",
        "\rGET /a HTTP/1.1\r\nHost: h\r\n\r\n",
        "GET /x?a=\r HTTP/1.1\r\nHost: h\r\n\r\n",
        "GET /a\x7f HTTP/1.1\r\nHost: h\r\n\r\n",
    };
    for (request_line) |head| {
        var r = Request{};
        try testing.expectError(error.BadRequestLine, parseHead(head, &r));
    }
    const header_line = [_][]const u8{
        "GET / HTTP/1.1\r\nHost: keep-aliv\r, Upgrade\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: h\r\nX-Forwarded-For:\r 5\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: h\r\nConnection: 0\x1d\r\n\r\n",
        "GET / HTTP/1.1\n\rX: y\nHost: h\n\n",
        "GET / HTTP/1.1\r\nHost: h\r\nX: a\x00b\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: h\r\nX: y\r\r\n\r\n",
    };
    for (header_line) |head| {
        var r = Request{};
        try testing.expectError(error.BadHeader, parseHead(head, &r));
    }
    // What a value may hold: a tab, and bytes past 0x7f.
    var r = Request{};
    try parseHead("GET / HTTP/1.1\r\nHost: h\r\nX: a\tb \xc3\xa9\r\n\r\n", &r);
}

test "a stray byte is found at every offset, and a CR that ends its line never is" {
    // The CR and LF that end the value fall on every position against the
    // 32-byte blocks, including the CR in one block and its LF in the next,
    // which is where the block's own LFs cannot say what follows it.
    var buf: [160]u8 = undefined;
    const front = "GET / HTTP/1.1\r\nHost: h\r\nX: ";
    const back = "\r\n\r\n";
    for (0..80) |n| {
        const head = buf[0 .. front.len + n + back.len];
        @memcpy(head[0..front.len], front);
        @memset(head[front.len..][0..n], 'a');
        @memcpy(head[front.len + n ..], back);
        var ok = Request{};
        try parseHead(head, &ok);

        for (0..n) |at| {
            head[front.len + at] = 0x01;
            var r = Request{};
            try testing.expectError(error.BadHeader, parseHead(head, &r));
            head[front.len + at] = '\r';
            try testing.expectError(error.BadHeader, parseHead(head, &r));
            head[front.len + at] = 'a';
        }
    }
}

test "a method and a header name are tokens, and anything else in one is a 400" {
    var r = Request{};
    try testing.expectError(error.BadRequestLine, parseHead("G,ET / HTTP/1.1\r\nHost: h\r\n\r\n", &r));
    try testing.expectError(error.BadRequestLine, parseHead("GE\"T / HTTP/1.1\r\nHost: h\r\n\r\n", &r));
    const names = [_][]const u8{
        "GET / HTTP/1.1\r\nHost: h\r\nCon,nection: close\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: h\r\nConnection localhost:8787\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: h\r\nX{: y\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: h\r\n" ++ "X-A-Name-Longer-Than-One-Block-Of-Bytes(: y\r\n\r\n",
    };
    for (names) |head| {
        var bad = Request{};
        try testing.expectError(error.BadHeader, parseHead(head, &bad));
    }
    // Any token: a method nobody routed, and a name nilo does not read.
    var ok = Request{};
    try parseHead("M-SEARCH / HTTP/1.1\r\nHost: h\r\nContent_Length: 5\r\nX-A-Name-Longer-Than-One-Block-Of-Bytes!: y\r\n\r\n", &ok);
    try testing.expectEqualStrings("M-SEARCH", ok.method);
    try testing.expect(!ok.has_content_length);
}

test "a target in none of the four forms is a 400, and each form is read" {
    const refused = [_][]const u8{ "h;tp://x/y", "?a=1", "a/b://c", ":80", "[::1:443", "http:/.x/y", "HTTPS:x", "http://|/y", "http://x:8o/", "http://:80/", "http://[]/" };
    for (refused) |target| {
        var r = Request{};
        var line: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "GET {s} HTTP/1.0", .{target}) catch unreachable;
        try testing.expectError(error.BadRequestLine, parseRequestLine(text, &r));
    }
    // Asterisk-form is read for OPTIONS and authority-form for CONNECT, and
    // for no other method.
    const read = [_][2][]const u8{
        .{ "OPTIONS", "*" },
        .{ "CONNECT", "example.com:443" },
        .{ "CONNECT", "[::1]:443" },
        .{ "CONNECT", "10.0.0.1:8080" },
        .{ "CONNECT", "my_host:80" },
    };
    for (read) |case| {
        var r = Request{};
        var line: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{s} {s} HTTP/1.0", .{ case[0], case[1] }) catch unreachable;
        try parseRequestLine(text, &r);
        try testing.expectEqualStrings(case[1], r.target);
    }
}

test "Connection is a list, and close anywhere in it closes" {
    const Case = struct { head: []const u8, keep_alive: bool, upgrade: bool = false };
    const cases = [_]Case{
        .{ .head = "GET / HTTP/1.1\r\nHost: h\r\nConnection: keep-alive, close\r\n\r\n", .keep_alive = false },
        .{ .head = "GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\nConnection: keep-alive\r\n\r\n", .keep_alive = false },
        .{ .head = "GET / HTTP/1.0\r\nConnection: keep-alive, Upgrade\r\n\r\n", .keep_alive = true, .upgrade = true },
        .{ .head = "GET / HTTP/1.0\r\nConnection: Upgrade,  Keep-Alive \r\n\r\n", .keep_alive = true, .upgrade = true },
        .{ .head = "GET / HTTP/1.0\r\nConnection: keep-alive\r\nConnection: close\r\n\r\n", .keep_alive = false },
        .{ .head = "GET / HTTP/1.0\r\nConnection: keep-alive, close\r\n\r\n", .keep_alive = false },
        .{ .head = "GET / HTTP/1.1\r\nHost: h\r\nConnection: TE, keep-alive\r\n\r\n", .keep_alive = true },
    };
    for (cases) |case| {
        var r = Request{};
        try parseHead(case.head, &r);
        try testing.expectEqual(case.keep_alive, r.keep_alive);
        try testing.expectEqual(case.upgrade, r.upgrade);
    }
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
        parseHead("GET / HTTP/1.1\r\nHost: t\r\nAccept no-colon\r\n\r\n", &r2),
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
            "GET / HTTP/1.1\r\nHost: t\r\n", name, ": v\r\nConnection: close\r\n\r\n",
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
        parseHead("GET / HTTP/1.1\r\nHost: t\r\nX: a:b:c:d:e\r\nNope\r\n\r\n", &r2),
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

        // The two framings take a turn each at the same offsets rather than
        // sharing one head, because a head carrying both is now refused.
        const sized = try std.mem.concat(gpa, u8, &.{
            "POST / HTTP/1.1\r\nHost: t\r\nX-Pad: ",                 filler,
            "\r\nContent-Length: 1234\r\nConnection: close\r\n\r\n",
        });
        defer gpa.free(sized);

        var r = Request{};
        try parseHead(sized, &r);
        try testing.expectEqual(@as(u64, 1234), r.content_length);
        try testing.expect(r.has_content_length);
        try testing.expect(!r.keep_alive);
        try testing.expect(!r.chunked);

        const streamed = try std.mem.concat(gpa, u8, &.{
            "POST / HTTP/1.1\r\nHost: t\r\nX-Pad: ",                       filler,
            "\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
        });
        defer gpa.free(streamed);

        var r2 = Request{};
        try parseHead(streamed, &r2);
        try testing.expect(r2.chunked);
        try testing.expect(!r2.keep_alive);
    }
}

test "a Content-Length that is not plain digits is refused" {
    // Every one of these is a number `std.fmt.parseInt` is happy to read and
    // RFC 9112 §6.2 is not, and the proxy in front is very likely to agree
    // with the RFC. `+5` came back as 5, `1_0` as 10 and `-0` as 0.
    for ([_][]const u8{ "+5", "-0", "-5", "1_0", " ", "0x10", "5 5", "٥" }) |value| {
        var r = Request{};
        var buf: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &buf,
            "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: {s}\r\n\r\n",
            .{value},
        );
        try testing.expectError(error.BadHeader, parseHead(head, &r));
    }

    // A leading zero is two digits, so it is legal and stays legal.
    for ([_]struct { []const u8, u64 }{ .{ "0", 0 }, .{ "05", 5 }, .{ "42", 42 } }) |case| {
        var r = Request{};
        var buf: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &buf,
            "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: {s}\r\n\r\n",
            .{case[0]},
        );
        try parseHead(head, &r);
        try testing.expectEqual(case[1], r.content_length);
        try testing.expect(r.has_content_length);
    }
}

test "a body framed twice is refused rather than framed either way" {
    // RFC 9112 §6.3. Whichever of the two nilo picked, a front end that
    // picked the other would have let a second request through inside this
    // one's body.
    const both_ways = [_][]const u8{
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 6\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\nContent-Length: 6\r\n\r\n",
        // Two lengths that disagree, in either order.
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 6\r\nContent-Length: 7\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 7\r\nContent-Length: 6\r\n\r\n",
        // Two `Transfer-Encoding` lines are one list, so the first `chunked`
        // was not the last coding.
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: gzip\r\n\r\n",
    };
    for (both_ways) |head| {
        var r = Request{};
        try testing.expectError(error.BadHeader, parseHead(head, &r));
    }

    // Repeating the *same* length is allowed: RFC 9110 §5.3 lets a recipient
    // treat it as the one value it agrees on.
    var same = Request{};
    try parseHead("POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 6\r\nContent-Length: 6\r\n\r\n", &same);
    try testing.expectEqual(@as(u64, 6), same.content_length);
}

test "chunked has to be the last coding, and has to be spelled that way" {
    // `xchunked` is not `chunked`. A substring search took it for one, which
    // is a front end reading an unknown coding while nilo reads framing.
    //
    // And none of these is a request with no body, which is what they used to
    // become: RFC 9112 §6.1 has a server that cannot decode the final coding
    // answer 400, and nilo can decode exactly one.
    for ([_][]const u8{ "xchunked", "chunked-x", "chunked, gzip", "gzip", "" }) |value| {
        var r = Request{};
        var buf: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &buf,
            "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: {s}\r\n\r\n",
            .{value},
        );
        try testing.expectError(error.BadHeader, parseHead(head, &r));
        try testing.expect(!r.chunked);
    }

    for ([_][]const u8{ "chunked", "CHUNKED", " chunked " }) |value| {
        var r = Request{};
        var buf: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &buf,
            "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: {s}\r\n\r\n",
            .{value},
        );
        try parseHead(head, &r);
        try testing.expect(r.chunked);
    }
}

test "an HTTP/1.1 request with no Host is a 400, and an HTTP/1.0 one is not" {
    var missing = Request{};
    try testing.expectError(error.BadHeader, parseHead("GET / HTTP/1.1\r\n\r\n", &missing));
    // A head full of other headers is no closer to having one.
    var busy = Request{};
    try testing.expectError(error.BadHeader, parseHead(
        "GET / HTTP/1.1\r\nAccept: */*\r\nUser-Agent: curl\r\nConnection: close\r\n\r\n",
        &busy,
    ));

    // `Host` was not required until 1.1, and a request that does not claim to
    // speak it is not held to it.
    var old = Request{};
    try parseHead("GET / HTTP/1.0\r\n\r\n", &old);
    try testing.expect(!old.has_host);

    var present = Request{};
    try parseHead("GET / HTTP/1.1\r\nhOsT: example.dev\r\n\r\n", &present);
    try testing.expect(present.has_host);
    // A name that merely starts the same way is a different header.
    var nearly = Request{};
    try testing.expectError(error.BadHeader, parseHead("GET / HTTP/1.1\r\nHostname: x\r\n\r\n", &nearly));
    // An empty value is still a `Host` line. Which authority it names is not
    // this layer's question; that there is exactly one of them is.
    var empty = Request{};
    try parseHead("GET / HTTP/1.1\r\nHost:\r\n\r\n", &empty);
    try testing.expect(empty.has_host);
}

test "two Host lines are a 400 even when they say the same thing" {
    // Stricter than `Content-Length`, where an identical repeat is legal:
    // RFC 9112 §3.2 refuses the repeat itself, because a request naming two
    // authorities is one the front end and nilo may route differently.
    for ([_][]const u8{
        "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nHost: a\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nAccept: */*\r\nhost: a\r\n\r\n",
        "GET / HTTP/1.0\r\nHost: a\r\nHost: b\r\n\r\n",
    }) |head| {
        var r = Request{};
        try testing.expectError(error.BadHeader, parseHead(head, &r));
    }
}

test "an absolute-form target is split into an authority and a path" {
    // What a client talking to what it believes is a proxy sends, and what
    // RFC 9112 §3.2.2 says a server must accept. The router matches on the
    // path, so the path is what it has to be handed (ADR 095).
    var r = Request{};
    try parseHead("GET http://example.com/users/7?x=1 HTTP/1.1\r\nHost: example.com\r\n\r\n", &r);
    try testing.expectEqualStrings("example.com", r.authority);
    try testing.expectEqualStrings("/users/7?x=1", r.target);

    // The port belongs to the authority, and the scheme is case-insensitive.
    var ported = Request{};
    try parseHead("GET HTTP://example.com:8080/a HTTP/1.1\r\nHost: x\r\n\r\n", &ported);
    try testing.expectEqualStrings("example.com:8080", ported.authority);
    try testing.expectEqualStrings("/a", ported.target);

    // https on a server that does not speak it is still a target it can
    // answer: the scheme says what the client believed, not what arrived.
    var secure = Request{};
    try parseHead("GET https://example.com/a HTTP/1.1\r\nHost: x\r\n\r\n", &secure);
    try testing.expectEqualStrings("example.com", secure.authority);
    try testing.expectEqualStrings("/a", secure.target);

    // No path at all is a request for `/`, and the slash handed back is one
    // of the target's own bytes rather than a literal — `App` moves these
    // onto a copy of the head by their offset into it.
    const head = "GET http://example.com HTTP/1.1\r\nHost: x\r\n\r\n";
    var bare = Request{};
    try parseHead(head, &bare);
    try testing.expectEqualStrings("example.com", bare.authority);
    try testing.expectEqualStrings("/", bare.target);
    const at = @intFromPtr(bare.target.ptr) - @intFromPtr(head.ptr);
    try testing.expect(at < head.len);
}

test "an absolute-form target answers for the Host the request never sent" {
    // RFC 9112 §3.2 has an origin server ignore `Host` in favour of the
    // target's authority, so a request carrying one and not the other is not
    // the 400 a missing `Host` otherwise is.
    var r = Request{};
    try parseHead("GET http://example.com/a HTTP/1.1\r\n\r\n", &r);
    try testing.expectEqualStrings("example.com", r.authority);
    try testing.expect(!r.has_host);

    // A `Host` beside it is still read, and a second one is still a 400 —
    // what changed is only which line can answer the rule.
    var two = Request{};
    try testing.expectError(error.BadHeader, parseHead(
        "GET http://example.com/a HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
        &two,
    ));
}

test "the two targets that are not absolute-form are kept for their own method and never routed" {
    // Asterisk-form is server-wide OPTIONS and authority-form asks for a
    // tunnel; neither names a route here, so both are left as they arrived for
    // `serve.zig`, which answers the first itself and the second with a 404.
    for ([_][2][]const u8{
        .{ "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n", "*" },
        .{ "CONNECT example.com:443 HTTP/1.1\r\nHost: x\r\n\r\n", "example.com:443" },
    }) |case| {
        var r = Request{};
        try parseHead(case[0], &r);
        try testing.expectEqualStrings(case[1], r.target);
        try testing.expectEqualStrings("", r.authority);
    }
}

test "an absolute-form target nilo cannot read without inventing bytes is a 400" {
    for ([_][]const u8{
        // Userinfo names `evil.example.net`, and a host somebody misreads is
        // worse than a refusal (RFC 9110 §4.2.4).
        "GET http://real.example.com@evil.example.net/ HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET http://user:pass@example.com/a HTTP/1.1\r\nHost: x\r\n\r\n",
        // No authority to be the host.
        "GET http:///a HTTP/1.1\r\nHost: x\r\n\r\n",
        // `/?a=1` is what this means, and there is no `/` in front of that
        // query to point at. Dropping the query quietly is the alternative.
        "GET http://example.com?a=1 HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET http://example.com#a HTTP/1.1\r\nHost: x\r\n\r\n",
    }) |head| {
        var r = Request{};
        try testing.expectError(error.BadRequestLine, parseHead(head, &r));
    }
}

test "Expect: 100-continue is read, and no other expectation is" {
    for ([_][]const u8{ "100-continue", "100-Continue", "  100-continue  " }) |value| {
        var r = Request{};
        var buf: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &buf,
            "POST / HTTP/1.1\r\nHost: t\r\nExpect: {s}\r\nContent-Length: 3\r\n\r\n",
            .{value},
        );
        try parseHead(head, &r);
        try testing.expect(r.expect_continue);
    }

    // Anything else is an expectation nobody defined, and reading one of these
    // as 100-continue would have nilo answer a question the client never
    // asked. A substring search would take all four.
    for ([_][]const u8{ "100-continue-ish", "x100-continue", "100-continue, other", "" }) |value| {
        var r = Request{};
        var buf: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &buf,
            "POST / HTTP/1.1\r\nHost: t\r\nExpect: {s}\r\nContent-Length: 3\r\n\r\n",
            .{value},
        );
        try parseHead(head, &r);
        try testing.expect(!r.expect_continue);
    }
}

test "Expect is found wherever it falls, and Cookie is not mistaken for it" {
    // `Expect` is the only header nilo reads that starts with neither `c` nor
    // `t`, so the first-byte filter in `parseHead` had to grow a third letter.
    // Padding walks it past the block boundaries that filter runs against.
    const gpa = testing.allocator;
    for ([_]usize{ 0, 1, 15, 31, 32, 33, 63, 100 }) |pad| {
        const filler = try gpa.alloc(u8, pad);
        defer gpa.free(filler);
        @memset(filler, 'y');

        const head = try std.mem.concat(gpa, u8, &.{
            "POST / HTTP/1.1\r\nHost: t\r\nX-Pad: ",                                        filler,
            "\r\nExpect: 100-continue\r\nCookie: session=abc\r\nContent-Length: 9\r\n\r\n",
        });
        defer gpa.free(head);

        var r = Request{};
        try parseHead(head, &r);
        try testing.expect(r.expect_continue);
        try testing.expectEqual(@as(u64, 9), r.content_length);
    }

    // `Cookie` is exactly as long as `Expect`, so it lands in the same arm of
    // the length switch and has to fall out of it.
    var only_cookie = Request{};
    try parseHead("POST / HTTP/1.1\r\nHost: t\r\nCookie: expect=100-continue\r\n\r\n", &only_cookie);
    try testing.expect(!only_cookie.expect_continue);
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
                if (line.len == 0) break;
                try applyHeader(line, r);
            }
            // The one rule about the head rather than about a line in it.
            return finish(r);
        }
    }.parse;

    const heads = [_][]const u8{
        "GET / HTTP/1.1\r\nHost: t\r\n\r\n",
        "GET /users/7 HTTP/1.1\r\nHost: example.dev\r\nUser-Agent: wrk\r\n" ++
            "Accept: */*\r\nAccept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n",
        "GET / HTTP/1.0\r\n\r\n",
        "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
        "GET / HTTP/1.1\nHost: x\n\n",
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 5\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length:  42  \r\n\r\n",
        "GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: t\r\nCONNECTION: CLOSE\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: t\r\nCookie: a=1; b=2\r\nConnection: close\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: t\r\nX: a:b:c\r\nConnection: close\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: 3\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: xchunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 6\r\nContent-Length: 6\r\n\r\n",
        // Malformed, so both have to refuse it.
        "GET / HTTP/1.1\r\nHost: t\r\nBroken\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nBroken\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: +5\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 6\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\nContent-Length: 6\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 6\r\nContent-Length: 7\r\n\r\n",
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
            try testing.expectEqual(theirs.has_content_length, mine.has_content_length);
            try testing.expectEqual(theirs.chunked, mine.chunked);
        } else |expected| {
            try testing.expectError(expected, my_err);
        }
    }
}

// ---- the same bytes, arriving in pieces ----
//
// Every test above hands the parser a `Reader.fixed`, where the input *is*
// the buffer and no read ever refills it. A socket is not like that: the
// head arrives across as many reads as the network cares to make, and the
// place a read ends is chosen by the sender. Everything that resumes across
// a read boundary — `readHead`'s scan, a chunk size line, a chunk's own
// CRLF, the two runs of a sized body — has a seam there, and a seam that
// reads one way whole and another way split is where a smuggled request
// travels. So the crafted heads and bodies are run again, at every split
// and at several steady trickles, against the same bytes arriving at once.

/// A connection that hands its bytes over in pieces, into a buffer of its
/// own. `first` is how much the opening read delivers and `per_read` how
/// much each one after it does — so `first = k` with an unbounded `per_read`
/// is one split at *k*, and `first = 0` with `per_read = 1` is a byte at a
/// time. Neither exceeds what the buffer has room for, which is what a
/// socket read does too.
const Pieces = struct {
    rest: []const u8,
    first: usize,
    per_read: usize,
    reader: std.Io.Reader,

    fn init(source: []const u8, first: usize, per_read: usize, buffer: []u8) Pieces {
        return .{
            .rest = source,
            .first = first,
            .per_read = per_read,
            .reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .end = 0,
                .seek = 0,
            },
        };
    }

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *Pieces = @alignCast(@fieldParentPtr("reader", r));
        if (self.rest.len == 0) return error.EndOfStream;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const want = if (self.first > 0) self.first else self.per_read;
        const n = @min(dest.len, want, self.rest.len);
        @memcpy(dest[0..n], self.rest[0..n]);
        self.rest = self.rest[n..];
        self.first = 0;
        w.advance(n);
        return n;
    }
};

/// What one request on a connection came to, with every slice copied out
/// of the reader's buffer so two of them can be held side by side after
/// the buffer has been reused. `left` is whatever followed the request —
/// where the next one would start, which is the byte that has to agree.
const Seen = struct {
    err: ?anyerror = null,
    head: []const u8 = "",
    method: []const u8 = "",
    target: []const u8 = "",
    authority: []const u8 = "",
    minor_version: u1 = 1,
    keep_alive: bool = true,
    content_length: u64 = 0,
    has_content_length: bool = false,
    chunked: bool = false,
    content_encoding: Encoding = .identity,
    has_host: bool = false,
    upgrade: bool = false,
    expect_continue: bool = false,
    body: []const u8 = "",
    left: []const u8 = "",
};

/// The two things `App` does with a body once the head is parsed: read it
/// into the arena, or step over it because nobody asked.
const Consume = enum { read, discard };

/// The limit both body paths run under here. Small, so a body over it is
/// one of the cases rather than something the wires cannot reach.
const pieces_body_limit = 64;

fn observe(in: *std.Io.Reader, arena: std.mem.Allocator, how: Consume) !Seen {
    var seen = Seen{};
    const head = readHead(in, .off) catch |err| {
        seen.err = err;
        return seen;
    };
    seen.head = try arena.dupe(u8, head);
    var r = Request{};
    parseHead(head, &r) catch |err| {
        seen.err = err;
        return seen;
    };
    in.toss(head.len);
    seen.method = try arena.dupe(u8, r.method);
    seen.target = try arena.dupe(u8, r.target);
    seen.authority = try arena.dupe(u8, r.authority);
    seen.minor_version = r.minor_version;
    seen.keep_alive = r.keep_alive;
    seen.content_length = r.content_length;
    seen.has_content_length = r.has_content_length;
    seen.chunked = r.chunked;
    seen.content_encoding = r.content_encoding;
    seen.has_host = r.has_host;
    seen.upgrade = r.upgrade;
    seen.expect_continue = r.expect_continue;

    switch (how) {
        .read => if (r.chunked) {
            seen.body = readChunkedBody(in, arena, pieces_body_limit) catch |err| {
                seen.err = err;
                return seen;
            };
        } else if (r.content_length > 0) {
            seen.body = readSizedBody(in, arena, @intCast(r.content_length), .off) catch |err| {
                seen.err = err;
                return seen;
            };
        },
        .discard => discardBody(in, &r, pieces_body_limit) catch |err| {
            seen.err = err;
            return seen;
        },
    }
    seen.left = in.allocRemaining(arena, .unlimited) catch |err| {
        seen.err = err;
        return seen;
    };
    return seen;
}

fn expectSame(want: Seen, got: Seen) !void {
    try testing.expectEqual(want.err, got.err);
    try testing.expectEqualStrings(want.head, got.head);
    try testing.expectEqualStrings(want.method, got.method);
    try testing.expectEqualStrings(want.target, got.target);
    try testing.expectEqualStrings(want.authority, got.authority);
    try testing.expectEqual(want.minor_version, got.minor_version);
    try testing.expectEqual(want.keep_alive, got.keep_alive);
    try testing.expectEqual(want.content_length, got.content_length);
    try testing.expectEqual(want.has_content_length, got.has_content_length);
    try testing.expectEqual(want.chunked, got.chunked);
    try testing.expectEqual(want.content_encoding, got.content_encoding);
    try testing.expectEqual(want.has_host, got.has_host);
    try testing.expectEqual(want.upgrade, got.upgrade);
    try testing.expectEqual(want.expect_continue, got.expect_continue);
    try testing.expectEqualStrings(want.body, got.body);
    try testing.expectEqualStrings(want.left, got.left);
}

test "a request arriving in pieces agrees with the same bytes arriving at once" {
    const gpa = testing.allocator;
    // The wires that have to be built live for the whole test; what each
    // observation copies out lives until the next wire.
    var wire_arena = std.heap.ArenaAllocator.init(gpa);
    defer wire_arena.deinit();
    const a = wire_arena.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    // A header name long enough that its colon crosses a scan block, and a
    // sized body long enough to take both of `readSizedBody`'s runs.
    const long_name = try a.alloc(u8, 70);
    @memset(long_name, 'x');
    long_name[0] = 'C';
    const long_head = try std.mem.concat(a, u8, &.{
        "GET / HTTP/1.1\r\nHost: t\r\n", long_name, ": v\r\nConnection: close\r\n\r\nNEXT",
    });
    const big_len = sized_body_step * 2 + 7;
    const big_body = try a.alloc(u8, big_len);
    for (big_body, 0..) |*b, i| b.* = 'a' + @as(u8, @intCast(i % 26));
    const big = try std.fmt.allocPrint(
        a,
        "POST /up HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n{s}NEXT",
        .{ big_len, big_body },
    );
    const over = try a.alloc(u8, pieces_body_limit + 1);
    @memset(over, 'z');
    const chunk_over = try std.fmt.allocPrint(
        a,
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n{x}\r\n{s}\r\n0\r\n\r\nNEXT",
        .{ over.len, over },
    );

    // `NEXT` after a complete request stands for the one behind it: both
    // sides have to leave the connection exactly there.
    const wires = [_][]const u8{
        "GET / HTTP/1.1\r\nHost: t\r\n\r\nNEXT",
        "GET /users/7?x=1 HTTP/1.1\r\nHost: example.dev\r\nUser-Agent: wrk\r\n" ++
            "Accept: */*\r\nAccept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\nNEXT",
        "GET / HTTP/1.1\nHost: x\n\nNEXT",
        "GET / HTTP/1.0\r\n\r\nNEXT",
        "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\nNEXT",
        "GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\nNEXT",
        "GET / HTTP/1.1\r\nHost: example.dev:8080\r\n" ++
            "If-Modified-Since: Mon, 01 Jan 2024 00:00:00 GMT\r\nContent-Length: 3\r\n\r\nabcNEXT",
        long_head,
        // Bodies of an announced length: short, across the step, and one
        // the client never finishes.
        "POST /send HTTP/1.1\r\nHost: t\r\nContent-Length: 5\r\n\r\nhelloNEXT",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length:  42  \r\n\r\n" ++ ("0123456789" ** 4) ++ "01NEXT",
        big,
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 100\r\n\r\nabc",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 6\r\nContent-Length: 6\r\n\r\nabcdefNEXT",
        // Chunked: extensions, trailers, bare LF, and the seams a chunk has.
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n1;ext=1\r\n \r\n5\r\nworld\r\n0\r\nX-Trailer: a\r\n\r\nNEXT",
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n3\nabc\n0\n\nNEXT",
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\nNEXT",
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloX\r\n0\r\n\r\nNEXT",
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffffff\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n1_0\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n 5\r\nhello\r\n0\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n",
        chunk_over,
        // Framed twice, or not at all.
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 6\r\nTransfer-Encoding: chunked\r\n\r\nabcdef",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 6\r\nContent-Length: 7\r\n\r\nabcdef",
        "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: xchunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: +5\r\n\r\n",
        // The target, the host, and the headers the rest of nilo reads.
        "GET http://example.com:8080/users/7?x=1 HTTP/1.1\r\nHost: ignored\r\n\r\nNEXT",
        "GET / HTTP/1.1\r\n\r\nNEXT",
        "GET / HTTP/1.1\r\nHost: t\r\nHost: t\r\n\r\nNEXT",
        "POST / HTTP/1.1\r\nHost: t\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\nabcNEXT",
        "GET /chat HTTP/1.1\r\nHost: t\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nNEXT",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\nhiNEXT",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Encoding: br\r\nContent-Length: 2\r\n\r\nhiNEXT",
        // Malformed lines, and a head that never ends.
        "GET / HTTP/1.1\r\nHost: t\r\nX: a:b:c:d:e\r\nNope\r\n\r\nNEXT",
        "GET / HTTP/1.1\r\nHost : t\r\n\r\nNEXT",
        "GET /\r\nHost: t\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\n",
        "GET / HTTP/1.1",
        // Two whole requests, the second with a body of its own: only the
        // first is consumed, and the second is what is left.
        "POST /a HTTP/1.1\r\nHost: t\r\nContent-Length: 3\r\n\r\nabc" ++
            "POST /b HTTP/1.1\r\nHost: t\r\nContent-Length: 2\r\n\r\nxy",
    };

    // The buffer a server reads into by default. Roomy against every wire
    // here, so a head that never ends is the client going away on both
    // sides rather than a full buffer on one.
    var buffer: [8 * 1024]u8 = undefined;
    const whole = std.math.maxInt(usize);

    for (wires) |wire| {
        for ([_]Consume{ .read, .discard }) |how| {
            var at_once = Pieces.init(wire, 0, whole, &buffer);
            const want = try observe(&at_once.reader, scratch, how);

            // Every two-way split, or every few bytes of one when the
            // wire is long enough that every byte would be a while.
            const stride = @max(1, wire.len / 256);
            var k: usize = 1;
            while (k < wire.len) : (k += stride) {
                var split = Pieces.init(wire, k, whole, &buffer);
                const got = try observe(&split.reader, scratch, how);
                expectSame(want, got) catch |err| {
                    std.debug.print("split at {d} of {d} bytes, {s}:\n{s}\n", .{ k, wire.len, @tagName(how), wire });
                    return err;
                };
            }

            // Steady trickles, including the three around a scan block.
            for ([_]usize{ 1, 2, 3, 7, 16, lanes - 1, lanes, lanes + 1 }) |per_read| {
                var trickle = Pieces.init(wire, 0, per_read, &buffer);
                const got = try observe(&trickle.reader, scratch, how);
                expectSame(want, got) catch |err| {
                    std.debug.print("{d} bytes a read, {s}:\n{s}\n", .{ per_read, @tagName(how), wire });
                    return err;
                };
            }
        }
        _ = arena.reset(.retain_capacity);
    }
}

/// The `Date` line every head in these tests carries, with the clock pinned
/// at the epoch so the bytes can be written down.
const epoch_date = "Date: Thu, 01 Jan 1970 00:00:00 GMT\r\n";

test "staticResponse and writeResponse produce the same bytes" {
    defer date.pinned = null;
    date.pinned = 0;
    const fixed = comptime staticResponse(200, "text/plain", "hello\n", .implied);
    var fixed_buf: [256]u8 = undefined;
    var fixed_out = std.Io.Writer.fixed(&fixed_buf);
    try writeStatic(&fixed_out, fixed);
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try writeResponse(&out, 200, "OK", "text/plain", "hello\n", .implied, &.{});
    try testing.expectEqualStrings(fixed_out.buffered(), out.buffered());
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++ epoch_date ++ "Content-Type: text/plain\r\nContent-Length: 6\r\n\r\nhello\n",
        out.buffered(),
    );
}

test "writeResponseHeadOnly matches writeResponse's head but sends no body" {
    defer date.pinned = null;
    date.pinned = 0;
    var full_buf: [256]u8 = undefined;
    var full = std.Io.Writer.fixed(&full_buf);
    try writeResponse(&full, 200, "OK", "text/plain", "hello\n", .implied, &.{});

    var head_buf: [256]u8 = undefined;
    var head = std.Io.Writer.fixed(&head_buf);
    try writeResponseHeadOnly(&head, 200, "OK", "text/plain", "hello\n".len, .implied, &.{});

    try testing.expectEqualStrings(full.buffered()[0 .. full.buffered().len - "hello\n".len], head.buffered());
}

test "a 204 carries neither Content-Length nor Content-Type" {
    defer date.pinned = null;
    date.pinned = 0;
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try writeResponse(&out, 204, "No Content", "text/plain", "", .implied, &.{
        .{ .name = "Allow", .value = "GET, HEAD" },
    });
    try testing.expectEqualStrings(
        "HTTP/1.1 204 No Content\r\n" ++ epoch_date ++ "Allow: GET, HEAD\r\n\r\n",
        out.buffered(),
    );
}

test "a 304 keeps its Content-Type but drops the Content-Length" {
    defer date.pinned = null;
    date.pinned = 0;
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try writeResponse(&out, 304, "Not Modified", "text/css; charset=utf-8", "", .implied, &.{
        .{ .name = "ETag", .value = "\"abc\"" },
    });
    try testing.expectEqualStrings(
        "HTTP/1.1 304 Not Modified\r\n" ++ epoch_date ++ "Content-Type: text/css; charset=utf-8\r\n" ++
            "ETag: \"abc\"\r\n\r\n",
        out.buffered(),
    );
}

test "a body handed to a bodyless status is dropped rather than framed wrong" {
    // Nothing in nilo does this, but a handler reaching for `c.send(204, …)`
    // with contents would otherwise leave bytes on the connection that the
    // next request would be read out of.
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try writeResponse(&out, 204, "No Content", "text/plain", "leftovers", .implied, &.{});
    try testing.expect(std.mem.endsWith(u8, out.buffered(), "\r\n\r\n"));
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "leftovers") == null);
}

test "extra headers go out after the framework's own" {
    defer date.pinned = null;
    date.pinned = 0;
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try writeResponse(&out, 200, "OK", "text/plain", "hi", .implied, &.{
        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
        .{ .name = "Vary", .value = "Origin" },
    });
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++ epoch_date ++ "Content-Type: text/plain\r\nContent-Length: 2\r\n" ++
            "Access-Control-Allow-Origin: *\r\nVary: Origin\r\n\r\nhi",
        out.buffered(),
    );
}

test "the Connection line is written only when it carries information" {
    // HTTP/1.1 staying open is the default and says nothing; an HTTP/1.0
    // client has to be told it may stay; a close is announced to both.
    try testing.expectEqual(Connection.implied, Connection.of(true, 1));
    try testing.expectEqual(Connection.keep_alive, Connection.of(true, 0));
    try testing.expectEqual(Connection.close, Connection.of(false, 1));
    try testing.expectEqual(Connection.close, Connection.of(false, 0));

    var buf: [256]u8 = undefined;
    const Case = struct { connection: Connection, line: ?[]const u8 };
    for ([_]Case{
        .{ .connection = .implied, .line = null },
        .{ .connection = .keep_alive, .line = "Connection: keep-alive\r\n" },
        .{ .connection = .close, .line = "Connection: close\r\n" },
    }) |case| {
        var out = std.Io.Writer.fixed(&buf);
        try writeResponse(&out, 200, "OK", "text/plain", "hi", case.connection, &.{});
        if (case.line) |line| {
            try testing.expect(std.mem.indexOf(u8, out.buffered(), line) != null);
        } else {
            try testing.expect(std.mem.indexOf(u8, out.buffered(), "Connection:") == null);
        }
    }
}

test "a Date set by the handler wins over the framework's" {
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try writeResponse(&out, 200, "OK", "text/plain", "hi", .implied, &.{
        .{ .name = "date", .value = "Sun, 06 Nov 1994 08:49:37 GMT" },
    });
    const head = out.buffered();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, head, "ate:"));
    try testing.expect(std.mem.indexOf(u8, head, "date: Sun, 06 Nov 1994 08:49:37 GMT\r\n") != null);
}

test "a stream head carries the Date and the same Connection rule" {
    defer date.pinned = null;
    date.pinned = 0;
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try writeStreamHead(&out, 200, "OK", "text/plain", true, null, .implied, &.{});
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++ epoch_date ++ "Content-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n",
        out.buffered(),
    );
}

test "a value that would end the header line early is spotted at every offset" {
    // Every offset of every length, because a check that reads all but the
    // last byte passes every example written by hand.
    var buf: [80]u8 = undefined;
    for ([_]u8{ '\r', '\n', 0, 0x7F }) |bad| {
        for (1..buf.len) |len| {
            for (0..len) |at| {
                @memset(buf[0..len], 'x');
                try testing.expect(headerValueOk(buf[0..len]));
                buf[at] = bad;
                try testing.expect(!headerValueOk(buf[0..len]));
            }
        }
    }

    // And the values an ordinary response actually carries are fine.
    for ([_][]const u8{
        "",
        "https://example.dev/welcome",
        "Origin",
        "gzip",
        "public, max-age=31536000, immutable",
        "bytes 0-99/1000",
        "session=abc; Path=/; HttpOnly; SameSite=Lax",
        "text/plain; charset=utf-8",
    }) |value| try testing.expect(headerValueOk(value));
}

test "the header names an ordinary response carries are all tokens" {
    for ([_][]const u8{
        "Vary",
        "X-Request-Id",
        "Access-Control-Allow-Origin",
        "ETag",
        "x_custom",
    }) |name| try testing.expect(headerNameOk(name));

    // The empty name, the bytes that end the name early, and the ones that
    // end the line. `X-(A)` cannot forge anything — parentheses are refused
    // because the grammar refuses them, not because they are dangerous.
    for ([_][]const u8{
        "",
        "X-A: b",
        "X A",
        "X-A\t",
        "X-A\r\nY",
        "X-A\n",
        "X-A\x00",
        "X-(A)",
    }) |name| try testing.expect(!headerNameOk(name));
}

test "the framework's own headers are reserved" {
    try testing.expect(isReservedHeader("Content-Length"));
    try testing.expect(isReservedHeader("content-type"));
    try testing.expect(isReservedHeader("CONNECTION"));
    try testing.expect(!isReservedHeader("Vary"));
}

test "the two headers a response may carry more than one of" {
    // Folding is forbidden for this one, so two cookies are two lines.
    try testing.expect(repeats("Set-Cookie"));
    try testing.expect(repeats("set-cookie"));
    // Folding is allowed for this one, and two layers each name their own
    // axis — so replacing threw one of them away (ADR 029).
    try testing.expect(repeats("Vary"));
    try testing.expect(repeats("vary"));

    // Everything else is somebody changing their mind, and the second call
    // replaces the first.
    try testing.expect(!repeats("Location"));
    try testing.expect(!repeats("ETag"));
    try testing.expect(!repeats("Cache-Control"));

    // And neither of the two is a header the framework writes itself, so both
    // go through `setHeader` like any other.
    try testing.expect(!isReservedHeader("Set-Cookie"));
    try testing.expect(!isReservedHeader("Vary"));
}

test "a header name is a token, and nothing else is one" {
    try testing.expect(headerNameOk("X-Request-Id"));
    try testing.expect(headerNameOk("ETag"));
    try testing.expect(headerNameOk("!#$%&'*+-.^_`|~"));

    // The two that would end the name early and start something else.
    try testing.expect(!headerNameOk("X-Bad: injected"));
    try testing.expect(!headerNameOk("X-Bad\r\nX-Other"));
    // A space is what separates a name from nothing at all — there is no
    // whitespace allowed before the colon (RFC 9112 §5.1), and a header line
    // with one is how a smuggled field gets past a lax parser.
    try testing.expect(!headerNameOk("X Bad"));
    try testing.expect(!headerNameOk(""));
}

test "a header value refuses the two bytes that would start a second header" {
    try testing.expect(headerValueOk("text/html; charset=utf-8"));
    try testing.expect(headerValueOk("W/\"abc-123\""));
    // Space and horizontal tab are the two whitespace bytes a value may hold.
    try testing.expect(headerValueOk("one, two\tthree"));
    try testing.expect(headerValueOk(""));
    // obs-text: deprecated, allowed, and what a UTF-8 filename is made of.
    try testing.expect(headerValueOk("attachment; filename=\"café.pdf\""));

    // The whole reason the function exists. One of these ends the header and
    // starts another; two of them end the head and start a response body.
    try testing.expect(!headerValueOk("/welcome\r\nX-Injected: 1"));
    try testing.expect(!headerValueOk("/welcome\nX-Injected: 1"));
    try testing.expect(!headerValueOk("/welcome\r"));
    try testing.expect(!headerValueOk("a\r\n\r\nHTTP/1.1 200 OK"));
    // Neither of these splits anything. Both mean the value came from
    // somewhere it should not have.
    try testing.expect(!headerValueOk("a\x00b"));
    try testing.expect(!headerValueOk("a\x7Fb"));
}

test "the redirect statuses all have a phrase, and it is written from the constant" {
    for ([_]u16{ 301, 302, 303, 307, 308 }) |status| {
        try testing.expect(statusPhrase(status).len > 0);

        var buf: [128]u8 = undefined;
        var out = std.Io.Writer.fixed(&buf);
        try writeStatusLine(&out, status, statusPhrase(status));

        var expected: [128]u8 = undefined;
        try testing.expectEqualStrings(
            try std.fmt.bufPrint(&expected, "HTTP/1.1 {d} {s}\r\n", .{ status, statusPhrase(status) }),
            out.buffered(),
        );
    }
}

/// A writer that counts how many times it put bytes on the wire, and keeps
/// them. What ADR 201 changes is how many writes a batch of responses costs,
/// which a fixed writer cannot say: its flush is a no-op.
const Wire = struct {
    buffer: [1024]u8 = undefined,
    kept: std.ArrayList(u8) = .empty,
    writes: usize = 0,
    writer: std.Io.Writer = undefined,

    fn init(self: *Wire) void {
        self.writer = .{ .vtable = &vtable, .buffer = &self.buffer };
    }

    fn deinit(self: *Wire) void {
        self.kept.deinit(testing.allocator);
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Wire = @fieldParentPtr("writer", w);
        self.writes += 1;
        self.kept.appendSlice(testing.allocator, w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.kept.appendSlice(testing.allocator, bytes) catch return error.WriteFailed;
            n += bytes.len;
        }
        for (0..splat) |_| {
            self.kept.appendSlice(testing.allocator, data[data.len - 1]) catch return error.WriteFailed;
            n += data[data.len - 1].len;
        }
        return n;
    }
};

test "a response is held while the next request is already here, and both leave in one write" {
    var wire: Wire = .{};
    wire.init();
    defer wire.deinit();

    // Two requests arrived together, the way a pipelining client sends them.
    var in = std.Io.Reader.fixed("GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    const first = try readRequest(&in);
    try testing.expectEqualStrings("/a", first.target);

    try writeResponse(&wire.writer, 200, "OK", "text/plain", "one", .implied, &.{});
    try settle(&wire.writer, &in);
    // The second request is sitting in the buffer, so nothing is waiting on
    // this answer: it stays.
    try testing.expectEqual(@as(usize, 0), wire.writes);

    const second = try readRequest(&in);
    try testing.expectEqualStrings("/b", second.target);
    try writeResponse(&wire.writer, 200, "OK", "text/plain", "two", .implied, &.{});
    try settle(&wire.writer, &in);
    // Nothing left to read: both answers go, together.
    try testing.expectEqual(@as(usize, 1), wire.writes);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, wire.kept.items, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, wire.kept.items, "\r\n\r\ntwo"));
}

test "a response to a client that sent one request and waits leaves at once" {
    var wire: Wire = .{};
    wire.init();
    defer wire.deinit();

    var in = std.Io.Reader.fixed("GET /a HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = try readRequest(&in);
    try writeResponse(&wire.writer, 200, "OK", "text/plain", "one", .implied, &.{});
    try settle(&wire.writer, &in);
    try testing.expectEqual(@as(usize, 1), wire.writes);
    try testing.expect(std.mem.endsWith(u8, wire.kept.items, "\r\n\r\none"));

    // The same for a HEAD, whose answer is a head with nothing after it.
    var again = std.Io.Reader.fixed("HEAD /a HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = try readRequest(&again);
    try writeResponseHeadOnly(&wire.writer, 200, "OK", "text/plain", 3, .implied, &.{});
    try settle(&wire.writer, &again);
    try testing.expectEqual(@as(usize, 2), wire.writes);
    try testing.expect(std.mem.endsWith(u8, wire.kept.items, "Content-Length: 3\r\n\r\n"));
}

test "a transfer coding stacked under chunked is a 501, and a final coding that is not chunked stays a 400" {
    // RFC 9112 §6.1: a coding the server does not understand is a 501. nilo
    // decodes `chunked` and nothing else, so `gzip, chunked` used to be read
    // as chunked and the handler was handed gzip bytes as its body.
    for ([_][]const u8{ "gzip, chunked", "gzip ,  chunked ", "identity, chunked", "chunked, chunked" }) |value| {
        var r = Request{};
        var buf: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &buf,
            "POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: {s}\r\n\r\n",
            .{value},
        );
        try testing.expectError(error.UnsupportedTransferEncoding, parseHead(head, &r));
        try testing.expect(!r.chunked);
    }
    // §6.3 makes a request whose last coding is not chunked a 400, and that
    // stays: the length cannot be told.
    var r = Request{};
    try testing.expectError(error.BadHeader, parseHead("POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked, gzip\r\n\r\n", &r));
}

test "an HTTP/1.0 request carrying Transfer-Encoding closes the connection after the answer" {
    // RFC 9112 §6.1: HTTP/1.0 has no Transfer-Encoding, so a message with one
    // is framed by something other than what its sender and a front end agree
    // on. It is answered and the connection is not reused, whatever
    // `Connection` asked for and in whatever order.
    for ([_][]const u8{
        "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.0\r\nConnection: keep-alive\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n",
    }) |head| {
        var r = Request{};
        try parseHead(head, &r);
        try testing.expect(r.chunked);
        try testing.expect(!r.keep_alive);
    }
    // HTTP/1.1 is untouched.
    var one_one = Request{};
    try parseHead("POST / HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n", &one_one);
    try testing.expect(one_one.keep_alive);
}

test "one empty line before the request line is skipped, and a second one is a 400" {
    // RFC 9112 §2.2: a server expecting a request line SHOULD ignore at least
    // one empty line before it. A client that ends a POST body with an extra
    // CRLF is the one this is for.
    for ([_][]const u8{ "\r\nGET /a HTTP/1.1\r\nHost: x\r\n\r\n", "\nGET /a HTTP/1.1\r\nHost: x\r\n\r\n" }) |bytes| {
        var in = std.Io.Reader.fixed(bytes);
        const r = try readRequest(&in);
        try testing.expectEqualStrings("GET", r.method);
        try testing.expectEqualStrings("/a", r.target);
        try testing.expectEqual(@as(usize, 0), in.buffered().len);
    }
    // The blank line is not part of the head handed on: what follows it is
    // the request line, so the headers are still the headers.
    var in = std.Io.Reader.fixed("\r\nGET /a HTTP/1.1\r\nHost: x\r\nAccept: y\r\n\r\n");
    const head = try readHead(&in, .off);
    var it = HeaderIterator.from(head);
    try testing.expectEqualStrings("Host", it.next().?.name);
    try testing.expectEqualStrings("Accept", it.next().?.name);

    var twice = std.Io.Reader.fixed("\r\n\r\nGET /a HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expectError(error.BadRequestLine, readRequest(&twice));
}

test "a target that does not begin with a slash is refused unless it is a form nilo has an answer for" {
    // Nothing that is not origin-form may reach the router, which splits on
    // `/` and has no idea the first one was never there: `admin:1/x` was
    // matched by `/:a/x`, and `*` by a root `/*`.
    for ([_][]const u8{ "admin:1/x", "ftp://example.com/a", "urn:isbn:1", "ht:tp://x/y", "mailto:a@b" }) |target| {
        var r = Request{};
        var line: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "GET {s} HTTP/1.1", .{target}) catch unreachable;
        try testing.expectError(error.BadRequestLine, parseRequestLine(text, &r));
    }
    // Asterisk-form is for OPTIONS and nothing else (RFC 9112 §3.2.4), and
    // authority-form for CONNECT (§3.2.3).
    var star = Request{};
    try testing.expectError(error.BadRequestLine, parseRequestLine("GET * HTTP/1.1", &star));
    try testing.expectError(error.BadRequestLine, parseRequestLine("POST * HTTP/1.1", &star));
    var authority = Request{};
    try testing.expectError(error.BadRequestLine, parseRequestLine("GET example.com:443 HTTP/1.1", &authority));
    try parseRequestLine("OPTIONS * HTTP/1.1", &star);
    try testing.expectEqualStrings("*", star.target);
    try parseRequestLine("CONNECT example.com:443 HTTP/1.1", &authority);
    try testing.expectEqualStrings("example.com:443", authority.target);
}

test "a version that is well formed and not spoken here is told apart from one that is not a version" {
    var r = Request{};
    // RFC 9110 §15.6.6: a 505 is for a version the server refuses to support.
    try testing.expectError(error.UnsupportedVersion, parseRequestLine("GET / HTTP/2.0", &r));
    try testing.expectError(error.UnsupportedVersion, parseRequestLine("GET / HTTP/0.9", &r));
    try testing.expectError(error.UnsupportedVersion, parseRequestLine("GET / HTTP/1.2", &r));
    // Not a version at all: a malformed request line.
    for ([_][]const u8{ "HTTP/1.1 x", "HTTP/2", "http/1.1", "HTTP/1.", "HTTP/11.1", "FOO/1.1", "garbage" }) |version| {
        var line: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "GET / {s}", .{version}) catch unreachable;
        try testing.expectError(error.BadRequestLine, parseRequestLine(text, &r));
    }
}

test "every status nilo can send has a reason phrase, from one table" {
    // `fail.status(502, …)` went out as `HTTP/1.1 502 \r\n`: the table stopped
    // at the statuses nilo itself sends.
    for ([_]u16{ 100, 101, 200, 201, 202, 203, 204, 205, 206, 300, 301, 302, 303, 304, 307, 308, 400, 401, 402, 403, 404, 405, 406, 407, 408, 409, 410, 411, 412, 413, 414, 415, 416, 417, 418, 421, 422, 423, 424, 425, 426, 428, 429, 431, 451, 500, 501, 502, 503, 504, 505, 506, 507, 508, 510, 511 }) |status| {
        try testing.expect(statusPhrase(status).len > 0);
        var buf: [128]u8 = undefined;
        var out = std.Io.Writer.fixed(&buf);
        try writeStatusLine(&out, status, statusPhrase(status));
        var expected: [128]u8 = undefined;
        try testing.expectEqualStrings(
            try std.fmt.bufPrint(&expected, "HTTP/1.1 {d} {s}\r\n", .{ status, statusPhrase(status) }),
            out.buffered(),
        );
    }
    try testing.expectEqualStrings("Bad Gateway", statusPhrase(502));
    try testing.expectEqualStrings("HTTP Version Not Supported", statusPhrase(505));
    // A status nobody registered has no phrase, which RFC 9112 §4 allows.
    try testing.expectEqualStrings("", statusPhrase(299));
}

test "a chunk that announces a large size and sends nothing does not grow the arena to it" {
    // The size is a number a stranger typed. `readSizedBody` takes a page
    // before it commits the rest, and a chunk is the same promise (ADR 083).
    const announced = 8 * 1024 * 1024;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var in = std.Io.Reader.fixed("800000\r\nonly a little");
    try testing.expectError(error.EndOfStream, readChunkedBody(&in, arena.allocator(), announced));
    try testing.expect(arena.queryCapacity() < announced / 8);

    // A chunk over a page that does arrive is still one contiguous body.
    const big = "a" ** 0x2801;
    var whole = std.Io.Reader.fixed("2801\r\n" ++ big ++ "\r\n0\r\n\r\n");
    const body = try readChunkedBody(&whole, arena.allocator(), 1 << 20);
    try testing.expectEqualStrings(big, body);
}

test "a Host that is not an authority is a 400" {
    // `Host` was counted and never read, so a value that is a path, carries
    // userinfo or holds a byte no host holds reached `Ctx.host` and every
    // redirect or link built from it.
    for ([_][]const u8{ "evil.com/reset?x=", "a@b", "a b", "a,b/", "http://a", "[::1", "host:80x", "a\x01b", "ex ample.com", "/" }) |host| {
        var r = Request{};
        var buf: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(&buf, "GET / HTTP/1.1\r\nHost: {s}\r\n\r\n", .{host});
        try testing.expectError(error.BadHeader, parseHead(head, &r));
    }
    for ([_][]const u8{ "example.com", "example.com:8080", "[::1]:8080", "127.0.0.1", "EXAMPLE.com" }) |host| {
        var r = Request{};
        var buf: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(&buf, "GET / HTTP/1.1\r\nHost: {s}\r\n\r\n", .{host});
        try parseHead(head, &r);
        try testing.expect(r.has_host);
    }
}

test "a field block is held to every rule a head's fields are, and parses to what the head would" {
    // What an HTTP/2 call's fields reach the App as (ADR 253). Each of these
    // is refused for the reason the same line in an HTTP/1.1 head is.
    const refused = [_]struct { []const u8, ParseError }{
        .{ "\nhost: a\r\nx-note: a\x01b\r\n\r\n", error.BadHeader },
        .{ "\nhost: a\r\nhost: b\r\n\r\n", error.BadHeader },
        .{ "\nhost: evil.com/reset\r\n\r\n", error.BadHeader },
        .{ "\nhost: a\r\nbad name: x\r\n\r\n", error.BadHeader },
        .{ "\nhost: a\r\n folded\r\n\r\n", error.BadHeader },
        .{ "\nhost: a\r\ncontent-length: 4\r\ncontent-length: 5\r\n\r\n", error.BadHeader },
        .{ "\nhost: a\r\ncontent-encoding: br\r\ncontent-length: 4\r\n\r\n", error.UnsupportedContentEncoding },
        // No host at all, which RFC 9112 §3.2 makes a 400 on HTTP/1.1.
        .{ "\ncontent-length: 4\r\n\r\n", error.BadHeader },
        // No empty request line in front: not a field block.
        .{ "host: a\r\n\r\n", error.BadRequestLine },
    };
    for (refused) |case| {
        var r = Request{};
        try testing.expectError(case[1], parseFields(case[0], &r));
    }

    const block = "\nhost: example.com\r\nx-note: a\tb\r\ncontent-encoding: gzip\r\ncontent-length: 4\r\n\r\n";
    var fields = Request{};
    try parseFields(block, &fields);
    var head = Request{};
    try parseHead("POST / HTTP/1.1" ++ block, &head);
    try testing.expectEqual(head.content_length, fields.content_length);
    try testing.expectEqual(head.content_encoding, fields.content_encoding);
    try testing.expect(fields.has_host and fields.has_content_length);
    // And `Ctx` reads its headers as it reads a head's, past the empty line.
    var it = HeaderIterator.from(block);
    try testing.expectEqualStrings("host", it.next().?.name);
    try testing.expectEqualStrings("a\tb", it.next().?.value);
}

test "a target that arrived without a request line is held to what one in a line is" {
    var r = Request{};
    try applyTarget("POST", "/pkg.Service/Method?x=1", &r);
    try testing.expectEqualStrings("/pkg.Service/Method?x=1", r.target);
    try applyTarget("OPTIONS", "*", &r);
    // A space or a control byte would have split a line or been refused in
    // it; a method that is not a token, or a form that is HTTP/1.1's alone,
    // is refused as it is there.
    for ([_][2][]const u8{
        .{ "POST", "/a b" },
        .{ "POST", "/a\tb" },
        .{ "POST", "/a\x7fb" },
        .{ "POST", "" },
        .{ "", "/" },
        .{ "PO ST", "/" },
        .{ "GET", "*" },
        .{ "GET", "http://example.com/" },
        .{ "CONNECT", "example.com:443" },
    }) |case| try testing.expectError(error.BadRequestLine, applyTarget(case[0], case[1], &r));
}
