//! What an HTTP/2 connection has to be true for, whatever a stranger sends it
//! ([ADR 220](../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md),
//! [ADR 259](../docs/adr/259-http2-is-a-framing-of-every-request.md)).
//!
//! `fuzz.zig` holds the HTTP/1.1 parser to its properties; this holds the
//! other thing a stranger feeds directly, a connection speaking HTTP/2. The
//! input is the whole of what a client sends, preface and all, and the
//! property is about what comes back:
//!
//! - Not the preface: the one 505 an HTTP/1.1 client can read, or nothing.
//! - Otherwise whole frames and nothing else, starting with this side's
//!   SETTINGS, none larger than the peer allows until it says more.
//! - Every frame on the stream it belongs on: SETTINGS, PING and GOAWAY on
//!   0, an answer on a stream the client opened.
//! - A header block uninterrupted (§6.10) and one a decoder reads.
//! - Nothing sent on a stream after its END_STREAM or its RST_STREAM, bar one
//!   RST_STREAM with NO_ERROR, which is how a server that has answered a
//!   request it will not read the rest of says so (RFC 9113 §8.1).
//! - An answer's first block on a stream is a `:status` ahead of every other
//!   field, an interim one (1xx) never ends the stream, a later block carries
//!   no pseudo-header, and no block carries a field HTTP/2 forbids (§8.2).
//!
//! - Every DATA frame the pipes write is within the 16,384 bytes the default
//!   allows, whatever the client raised its maximum to: a piece a handler lends
//!   is cut where a frame ends, and no route here lends more than one frame.
//!
//! What a stranger feeds it is gRPC calls and ordinary requests: any method,
//! with a body or without one, with the fields that make a request malformed
//! and the ones that make it a call. Two of the routes answer in pieces, one
//! of them a stream with a trailer and one a file, so a connection is also
//! asked to write while a call waits on a window, a reset, a zero window, a
//! GOAWAY and the end of the connection (stage 6.2, ADR 260).
//!
//! And the one every fuzzer has, under the safety checks of `ReleaseSafe`:
//! it does not crash, and it does not leak.
//!
//! The route behind the listener is a stub rather than an App, for the same
//! reason `fuzz.zig` drives `http1` rather than the server: what is being
//! fuzzed is the translation, and an App would put a router and a thousand
//! allocations between the input and the property. `h2conn.Host` is the seam
//! the App already goes through, so the stub is the same door.
//!
//! `zig build fuzz -- --frames` generates inputs for it; `zig build test`
//! replays the corpus at the bottom.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");
const fail = @import("fail.zig");
const framing = @import("framing.zig");
const h2conn = @import("h2conn.zig");
const h2 = @import("h2.zig");
const hpack = @import("hpack.zig");
const core = @import("nilo_core");
const room_file = @import("room.zig");
const stream_file = @import("stream.zig");

/// Run each call on a thread of its own, as a test does, so the generated
/// inputs reach a request whose handler is running while its body arrives
/// (`h2conn.Fallback`). A generator run from the command line would otherwise
/// reach the inline fallback, which runs a call only once its stream has
/// ended.
pub fn useThreads() void {
    h2conn.fallback = .threads;
}

/// Run one input through a connection and check what came back. A failure
/// prints the input as a corpus line first, the way `fuzz.checkOne` does.
pub fn checkOne(gpa: std.mem.Allocator, bytes: []const u8) !void {
    check(gpa, bytes) catch |err| {
        dump(bytes);
        return err;
    };
}

fn check(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(bytes);
    var stop: bulkhead.Stop = .{};
    var room = try room_file.Room.initWith(gpa, .{});
    defer room.deinit();
    feed = &room;
    defer feed = null;
    // Posts arrive while the frames are read, from a thread of their own.
    var done: std.atomic.Value(bool) = .init(false);
    const poster = try std.Thread.spawn(.{}, post, .{ &room, &done });
    h2conn.serveConnection(stub(gpa, &stop), &in, &out.writer, .off, .off, .{});
    done.store(true, .release);
    poster.join();
    answerHolds(gpa, bytes, out.written()) catch |err| {
        dumpAnswer(out.written());
        return err;
    };
}

/// Says things into the room until the connection is done, a few of them
/// large enough to need more than one frame.
fn post(room: *room_file.Room, done: *const std.atomic.Value(bool)) void {
    var n: u32 = 0;
    while (!done.load(.acquire)) : (n +%= 1) {
        if (n % 37 == 0) {
            const big = [_]u8{'p'} ** 20_000;
            room.sayText(&big) catch {};
        } else room.print("post {d}", .{n}) catch {};
        std.Thread.yield() catch {};
    }
}

/// What came back, a frame a line, so a failure says which frame broke it.
fn dumpAnswer(got: []const u8) void {
    std.debug.print("  the answer:\n", .{});
    var rest = got;
    while (rest.len >= h2.header_len) {
        const head = h2.Header.parse(rest[0..h2.header_len]);
        const len = @min(head.len, rest.len - h2.header_len);
        std.debug.print("    {t} flags 0x{x:0>2} stream {d} len {d}: {x}\n", .{ head.type, head.flags, head.stream, head.len, rest[h2.header_len..][0..@min(len, 32)] });
        rest = rest[h2.header_len + len ..];
    }
}

/// The input as a Zig string literal, ready to be pasted into the corpus.
pub fn dump(bytes: []const u8) void {
    std.debug.print("    \"", .{});
    for (bytes) |b| std.debug.print("\\x{x:0>2}", .{b});
    std.debug.print("\",  // {d} bytes\n", .{bytes.len});
}

// ---- the route behind it ----

/// Five routes, so an answer can be each shape the listener writes: `/e…`
/// echoes the message back, `/f…` fails with text, `/c…` answers with a
/// header and a trailer of its own, `/g…` answers HTTP in text with a header
/// HTTP/2 forbids and one it does not, as a HEAD would and as a GET would, and
/// `/n…` has no body, `/t…` streams five pieces of different sizes and a
/// trailer, and `/d…` sends a file read from `/dev/zero`, a buffer at a time.
/// Anything else is no route to a gRPC call, and an
/// ordinary request is answered whatever it names.
fn stub(gpa: std.mem.Allocator, stop: *const bulkhead.Stop) h2conn.Host {
    const Stub = struct {
        /// What `/d` reads, which is as long as it is asked to and needs no
        /// file of the fuzzer's own to leave behind.
        const zero_length = 40_000;

        fn routes(_: *anyopaque, path: []const u8) bool {
            return path.len > 1 and (path[1] == 'e' or path[1] == 'f' or path[1] == 'c');
        }

        fn limit(_: *anyopaque, _: []const u8, _: []const u8) usize {
            return 1024;
        }

        fn handle(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: *core.Lifetime,
            _: *fail.InFlight,
            arrived: framing.Call,
            collected: *framing.Collected,
            _: bulkhead.Peer,
            _: u64,
        ) void {
            const which = if (arrived.target.len > 1) arrived.target[1] else 'e';
            var to: framing.Framing = .{ .http2 = collected };
            // A request that was not over when it started reads what is left
            // of it through the pipe, whole, or, on `/s`, a few bytes at a
            // time, which is a handler slower than its client.
            var body = arrived.body;
            if (arrived.inbox) |pipe| {
                if (which == 's') {
                    var total: usize = 0;
                    var tiny: [7]u8 = undefined;
                    while (true) {
                        const n = pipe.reader.readSliceShort(&tiny) catch break;
                        total += n;
                        if (n < tiny.len) break;
                    }
                    body = std.fmt.allocPrint(arena, "{d}", .{total}) catch "";
                    to.whole(200, "text/plain", body, false, false, true, &.{}, .{}) catch {};
                    return;
                }
                body = pipe.whole(1024) catch "";
            }
            switch (which) {
                't' => streamed(&to, arrived.method),
                'v' => evented(&to, arena, arrived.method),
                'd' => filed(&to, arrived.method),
                'g' => to.whole(200, "text/plain", "hello", false, std.mem.eql(u8, arrived.method, "HEAD"), true, &.{
                    .{ .name = "Connection", .value = "close" },
                    .{ .name = "X-Seen", .value = "yes" },
                }, .{ .list = &.{.{ .name = "x-checked", .value = "yes" }} }) catch {},
                'n' => to.whole(204, "", "", false, false, true, &.{}, .{}) catch {},
                'f' => to.whole(404, "text/plain", "no such", false, false, true, &.{}, .{}) catch {},
                'c' => to.whole(200, "application/grpc", body, false, false, true, &.{.{ .name = "X-Kind", .value = "own" }}, .{
                    .list = &.{.{ .name = "x-checked", .value = "yes" }},
                }) catch {},
                else => to.whole(200, "application/grpc", body, false, false, true, &.{}, .{}) catch {},
            }
        }
    };
    return .{
        .ptr = @ptrCast(@constCast(stop)),
        .gpa = gpa,
        .stop = stop,
        .max_body = 1024,
        .ceiling = 1024,
        .body_limit = Stub.limit,
        .routes = Stub.routes,
        .handle = Stub.handle,
    };
}

/// Five pieces: one of a byte, one of a buffer's worth, one that is a
/// pattern written many times, one that is empty, one that is a slice of the
/// handler's own, and then a trailer. A write that fails ends the handler, as
/// a real one's would.
fn streamed(to: *framing.Framing, method: []const u8) void {
    const head_only = std.mem.eql(u8, method, "HEAD");
    to.streamHead(200, "text/plain", .{ .chunked = false, .ends_connection = false, .bodyless = head_only }, null, true, &.{}) catch return;
    if (!head_only) {
        const big = [_]u8{'x'} ** 12_000;
        to.piece(false, "a", &.{""}, 0) catch return;
        to.piece(false, big[0..4096], &.{""}, 0) catch return;
        to.piece(false, "", &.{"-="}, 3000) catch return;
        to.piece(false, "", &.{""}, 0) catch return;
        to.piece(false, "tail", &.{ big[0..8000], "end" }, 1) catch return;
    }
    to.end(false, .{ .list = &.{.{ .name = "x-sum", .value = "ok" }} }) catch return;
}

/// The room `/v` listens to while `check` runs, with a thread posting to it as
/// the frames are read (stage 6.3).
var feed: ?*room_file.Room = null;

/// An event stream handed to the connection: the head, then whatever the room
/// is told, written by the connection's own fiber under both windows. Without
/// a room (a replay that did not set one up) it is a short answer.
fn evented(to: *framing.Framing, arena: std.mem.Allocator, method: []const u8) void {
    const room = feed orelse {
        to.whole(200, "text/plain", "no room", false, false, true, &.{}, .{}) catch {};
        return;
    };
    const link = to.eventLink() orelse return;
    const events = arena.create(stream_file.Http2Events) catch return;
    events.* = .{ .link = link };
    const head_only = std.mem.eql(u8, method, "HEAD");
    if (!head_only) {
        _ = room.sitAfter(&events.seated, events.bell(), true, "", &.{}) catch {
            to.whole(503, "text/plain", "full", false, false, true, &.{}, .{}) catch {};
            return;
        };
    }
    var shape = to.streamShape(null);
    shape.bodyless = head_only;
    to.streamHead(200, stream_file.Events.content_type, shape, null, true, &.{}) catch {
        events.leave();
        return;
    };
    if (head_only) {
        to.end(false, .{}) catch {};
        return;
    }
    to.handOverEvents(.{
        .state = events,
        .step = stream_file.Http2Events.stepErased,
        .leave = stream_file.Http2Events.leaveErased,
        .keepalive_ms = 20,
    }) catch events.leave();
}

/// A file: the head, and `/dev/zero` read into frames through the pipe. A
/// HEAD is the head alone.
fn filed(to: *framing.Framing, method: []const u8) void {
    var dir = bulkhead.Dir.open("/dev") catch return;
    defer dir.close();
    const file = dir.openFile("zero") catch return;
    defer file.close();
    var none: [0]u8 = undefined;
    var reader = file.reader(&none);
    if (std.mem.eql(u8, method, "HEAD")) {
        to.head(200, "application/octet-stream", 40_000, true, &.{}) catch {};
        return;
    }
    _ = to.file(200, "application/octet-stream", &reader, 40_000, true, &.{}) catch {};
}

// ---- the property ----

const not_h2 = "HTTP/1.1 505 HTTP Version Not Supported\r\ncontent-length: 0\r\nconnection: close\r\n\r\n";

/// The largest frame this client has said it will take: its last
/// SETTINGS_MAX_FRAME_SIZE (RFC 9113 §6.5.2), or the default. A server may
/// fill a frame to it, and a stream written in pieces does.
fn clientMaxFrame(sent: []const u8) usize {
    var limit: usize = h2.default_max_frame;
    var rest = sent[h2.preface.len..];
    while (rest.len >= h2.header_len) {
        const head = h2.Header.parse(rest[0..h2.header_len]);
        if (rest.len - h2.header_len < head.len) break;
        const payload = rest[h2.header_len..][0..head.len];
        rest = rest[h2.header_len + head.len ..];
        if (head.type != .settings or head.stream != 0 or head.has(h2.Flags.ack)) continue;
        var at: usize = 0;
        while (at + 6 <= payload.len) : (at += 6) {
            if (std.mem.readInt(u16, payload[at..][0..2], .big) != 5) continue;
            const v = std.mem.readInt(u32, payload[at + 2 ..][0..4], .big);
            if (v >= h2.default_max_frame and v <= 16_777_215) limit = v;
        }
    }
    return limit;
}

fn answerHolds(gpa: std.mem.Allocator, sent: []const u8, got: []const u8) !void {
    if (!std.mem.startsWith(u8, sent, h2.preface)) {
        if (got.len == 0 or std.mem.eql(u8, got, not_h2)) return;
        return error.NotH2AnsweredWithFrames;
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var decoder: hpack.Decoder = .init(gpa);
    defer decoder.deinit();

    // Streams whose last frame has been sent, those whose final head has,
    // and the block being assembled.
    var ended: std.AutoHashMapUnmanaged(u31, void) = .empty;
    var headed: std.AutoHashMapUnmanaged(u31, void) = .empty;
    var reset: std.AutoHashMapUnmanaged(u31, void) = .empty;
    var block: std.ArrayList(u8) = .empty;
    var block_stream: ?u31 = null;
    var block_owner: u31 = 0;
    var block_ends = false;

    const allowed_frame = clientMaxFrame(sent);
    var rest = got;
    var first = true;
    while (rest.len > 0) {
        if (rest.len < h2.header_len) return error.TornFrame;
        const head = h2.Header.parse(rest[0..h2.header_len]);
        if (rest.len - h2.header_len < head.len) return error.TornFrame;
        const payload = rest[h2.header_len..][0..head.len];
        rest = rest[h2.header_len + head.len ..];

        if (head.len > allowed_frame) return error.FrameTooLarge;
        if (first and !(head.type == .settings and !head.has(h2.Flags.ack))) return error.SettingsNotFirst;
        first = false;

        // §6.10: nothing may come between a HEADERS without END_HEADERS and
        // the CONTINUATION that finishes it, on any stream.
        if (block_stream) |open| {
            if (head.type != .continuation or head.stream != open) return error.HeaderBlockInterrupted;
        } else if (head.type == .continuation) return error.ContinuationWithoutHeaders;

        switch (head.type) {
            .settings, .ping, .goaway => if (head.stream != 0) return error.ConnectionFrameOnAStream,
            .window_update => {},
            .headers, .continuation, .data, .rst_stream => {
                if (head.stream % 2 != 1) return error.AnswerOnAStreamTheClientDidNotOpen;
                const closing = head.type == .rst_stream and head.len == 4 and
                    std.mem.readInt(u32, payload[0..4], .big) == 0 and !reset.contains(head.stream);
                if (ended.contains(head.stream) and !closing) return error.SentAfterTheStreamEnded;
            },
            else => return error.FrameTypeThisSideNeverSends,
        }

        switch (head.type) {
            .headers, .continuation => {
                if (head.type == .headers) {
                    block_owner = head.stream;
                    block_ends = head.has(h2.Flags.end_stream);
                }
                try block.appendSlice(a, payload);
                if (head.has(h2.Flags.end_headers)) {
                    var fields: std.ArrayList(hpack.Field) = .empty;
                    _ = decoder.decode(block.items, a, &fields, std.math.maxInt(u32)) catch return error.BlockDoesNotDecode;
                    const interim = try answerBlockHolds(fields.items, headed.contains(block_owner), block_ends);
                    if (!interim) try headed.put(a, block_owner, {});
                    block = .empty;
                    block_stream = null;
                } else block_stream = head.stream;
                if (head.type == .headers and head.has(h2.Flags.end_stream)) try ended.put(a, head.stream, {});
            },
            .data => if (head.has(h2.Flags.end_stream)) try ended.put(a, head.stream, {}),
            .rst_stream => {
                try ended.put(a, head.stream, {});
                try reset.put(a, head.stream, {});
            },
            else => {},
        }
    }
    if (block_stream != null) return error.HeaderBlockUnfinished;
}

/// One decoded block of an answer: the first on a stream is `:status` and
/// nothing else a pseudo-header, an interim one does not end the stream, a
/// later one has no pseudo-header at all, and every name is lowercase and not
/// one HTTP/2 forbids (§8.1, §8.2.1, §8.2.2). True when the block was interim.
fn answerBlockHolds(fields: []const hpack.Field, headed: bool, ends: bool) !bool {
    var interim = false;
    for (fields, 0..) |f, i| {
        for (f.name) |ch| if (std.ascii.isUpper(ch)) return error.UppercaseFieldName;
        if (h2.hopByHop(f.name)) return error.ConnectionFieldInAnswer;
        const pseudo = f.name.len > 0 and f.name[0] == ':';
        if (headed) {
            if (pseudo) return error.PseudoHeaderInTrailers;
            continue;
        }
        if (i == 0) {
            if (!std.mem.eql(u8, f.name, ":status")) return error.AnswerDoesNotStartWithStatus;
            interim = f.value.len == 3 and f.value[0] == '1';
        } else if (pseudo) return error.PseudoHeaderBesidesStatus;
    }
    if (!headed and (fields.len == 0)) return error.AnswerDoesNotStartWithStatus;
    if (interim and ends) return error.InterimAnswerEndsTheStream;
    return interim;
}

// ---- generating something worth checking ----

/// A connection's worth of frames, nearly valid: the preface, SETTINGS, and
/// mostly whole calls, with a frame a server gets wrong between them, the
/// flags, lengths and stream numbers of which are the damage. One input in
/// three then has a byte changed or is cut short. A connection that is sent
/// away at its second frame tests one refusal, so most of them are not.
pub fn generate(random: std.Random, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (random.uintLessThan(u8, 20) != 0) w.writeAll(h2.preface) catch return w.buffered();
    settings(random, &w) catch return w.buffered();

    var next: u31 = 1;
    const steps = 1 + random.uintLessThan(u8, 8);
    for (0..steps) |_| {
        if (random.uintLessThan(u8, 3) != 0) {
            switch (random.uintLessThan(u8, 6)) {
                0, 1 => wholeRequest(random, &w, next) catch return w.buffered(),
                2, 3 => splitRequest(random, &w, next) catch return w.buffered(),
                else => wholeCall(random, &w, next) catch return w.buffered(),
            }
            next +|= 2;
            continue;
        }
        const stream: u31 = switch (random.uintLessThan(u8, 8)) {
            0 => 0,
            1 => next + 1,
            2 => next -| 2,
            3 => random.int(u31),
            else => next,
        };
        oneFrame(random, &w, stream) catch return w.buffered();
        if (random.boolean()) next +|= 2;
    }

    const made = w.buffered();
    if (random.uintLessThan(u8, 3) != 0 or made.len == 0) return made;
    const at = random.uintLessThan(usize, made.len);
    buf[at] = switch (random.uintLessThan(u8, 3)) {
        0 => buf[at] ^ (@as(u8, 1) << random.int(u3)),
        1 => 0xff,
        else => 0,
    };
    return if (random.uintLessThan(u8, 4) == 0) made[0..at] else made;
}

/// The client's SETTINGS: values a client sends, mostly, and one in eight
/// anything at all, which is how a window past 2^31 or a frame size of 0
/// arrives.
fn settings(random: std.Random, w: *std.Io.Writer) !void {
    const count = random.uintLessThan(u8, 4);
    try h2.writeHeader(w, @as(usize, count) * 6, .settings, 0, 0);
    for (0..count) |_| {
        var bytes: [6]u8 = undefined;
        const Pair = struct { u16, u32 };
        const sane = [_]Pair{ .{ 1, 4096 }, .{ 2, 0 }, .{ 3, 100 }, .{ 4, 65_535 }, .{ 4, 0 }, .{ 4, 1 }, .{ 5, 16_384 }, .{ 5, 1 << 20 }, .{ 6, 8192 } };
        const pair: Pair = if (random.uintLessThan(u8, 8) != 0)
            sane[random.uintLessThan(usize, sane.len)]
        else
            .{ random.intRangeAtMost(u16, 1, 9), random.int(u32) };
        std.mem.writeInt(u16, bytes[0..2], pair[0], .big);
        std.mem.writeInt(u32, bytes[2..6], pair[1], .big);
        try w.writeAll(&bytes);
    }
}

/// HEADERS and a DATA that ends the stream: one call, the way a client
/// writes one, its block sometimes split across a CONTINUATION. One in three
/// inputs' steps is `wholeRequest` instead, below.
fn wholeCall(random: std.Random, w: *std.Io.Writer, stream: u31) !void {
    var block_buf: [256]u8 = undefined;
    const block = headerBlock(random, &block_buf);
    if (random.uintLessThan(u8, 4) == 0 and block.len > 1) {
        const cut = 1 + random.uintLessThan(usize, block.len - 1);
        try h2.writeHeader(w, cut, .headers, 0, stream);
        try w.writeAll(block[0..cut]);
        try h2.writeHeader(w, block.len - cut, .continuation, h2.Flags.end_headers, stream);
        try w.writeAll(block[cut..]);
    } else {
        try h2.writeHeader(w, block.len, .headers, h2.Flags.end_headers, stream);
        try w.writeAll(block);
    }
    const len = random.uintLessThan(u8, 24);
    try h2.writeHeader(w, 5 + @as(usize, len), .data, h2.Flags.end_stream, stream);
    try w.writeByte(0);
    try w.writeInt(u32, len, .big);
    for (0..len) |_| try w.writeByte(random.int(u8));
}

/// An ordinary request, the way a browser or curl writes one: any method, its
/// fields, and either nothing after them (END_STREAM on the HEADERS) or a body
/// with no message prefix in front of it, sometimes in two DATA frames.
fn wholeRequest(random: std.Random, w: *std.Io.Writer, stream: u31) !void {
    var block_buf: [320]u8 = undefined;
    const block = requestBlock(random, &block_buf);
    const bodiless = random.boolean();
    try h2.writeHeader(w, block.len, .headers, h2.Flags.end_headers | if (bodiless) h2.Flags.end_stream else 0, stream);
    try w.writeAll(block);
    if (bodiless) return;
    const len = random.uintLessThan(u8, 24);
    const first = if (len > 1 and random.boolean()) random.uintLessThan(u8, len) else len;
    try h2.writeHeader(w, first, .data, if (first == len) h2.Flags.end_stream else 0, stream);
    for (0..first) |_| try w.writeByte(random.int(u8));
    if (first == len) return;
    try h2.writeHeader(w, len - first, .data, h2.Flags.end_stream, stream);
    for (0..len - first) |_| try w.writeByte(random.int(u8));
}

/// A request whose body is still to come when its HEADERS are read, so its
/// handler is running while DATA arrives: the pieces sometimes with another
/// stream's frames between them, the end sometimes a reset, sometimes an empty
/// DATA that ends it, sometimes never.
fn splitRequest(random: std.Random, w: *std.Io.Writer, stream: u31) !void {
    var block_buf: [320]u8 = undefined;
    const block = requestBlock(random, &block_buf);
    try h2.writeHeader(w, block.len, .headers, h2.Flags.end_headers, stream);
    try w.writeAll(block);
    const pieces = random.uintLessThan(u8, 4);
    for (0..pieces) |i| {
        if (random.uintLessThan(u8, 4) == 0) try oneFrame(random, w, stream +| 2);
        const len = random.uintLessThan(u8, 40);
        const last = i + 1 == pieces and random.boolean();
        try h2.writeHeader(w, len, .data, if (last) h2.Flags.end_stream else 0, stream);
        for (0..len) |_| try w.writeByte(random.int(u8));
        if (last) return;
    }
    switch (random.uintLessThan(u8, 4)) {
        0 => try h2.writeRstStream(w, stream, .cancel),
        1 => try h2.writeHeader(w, 0, .data, h2.Flags.end_stream, stream),
        else => {},
    }
}

const request_paths = [_][]const u8{ "/g.x", "/g.x", "/s.x", "/e.x", "/f.x", "/n", "/c.x", "/t.x", "/t.x", "/t.x", "/v.x", "/v.x", "/d.x", "/d.x", "/missing", "*", "", "/a b", "/g?x=1" };
const request_methods = [_][]const u8{ "GET", "GET", "POST", "HEAD", "PUT", "DELETE", "OPTIONS", "CONNECT", "BREW", "" };

/// A request's fields as an ordinary client writes them, with the ones that
/// make it malformed turning up now and then: a method that is not a token, no
/// `:scheme`, a `connection` field, `te: gzip`, a `content-length` that is not
/// the body's, a field name in capitals, a pseudo-header after a regular one.
fn requestBlock(random: std.Random, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const method = request_methods[random.uintLessThan(usize, request_methods.len)];
    hpack.writeLiteral(&w, ":method", method) catch {};
    if (random.uintLessThan(u8, 12) != 0) w.writeAll("\x86") catch {};
    const path = request_paths[random.uintLessThan(usize, request_paths.len)];
    hpack.writeLiteral(&w, ":path", path) catch {};
    if (random.boolean()) hpack.writeLiteral(&w, ":authority", "example.test") catch {};
    if (random.boolean()) hpack.writeLiteral(&w, "content-type", if (random.boolean()) "text/plain" else "application/json") catch {};
    if (random.uintLessThan(u8, 3) == 0) {
        hpack.writeLiteral(&w, "cookie", "a=1") catch {};
        hpack.writeLiteral(&w, "cookie", "b=2") catch {};
    }
    switch (random.uintLessThan(u8, 14)) {
        0 => hpack.writeLiteral(&w, "connection", "close") catch {},
        1 => hpack.writeLiteral(&w, "te", "gzip") catch {},
        2 => hpack.writeLiteral(&w, "te", "trailers") catch {},
        3 => hpack.writeLiteral(&w, "content-length", "3") catch {},
        4 => hpack.writeLiteral(&w, "content-length", "x") catch {},
        5 => hpack.writeLiteral(&w, "X-Upper", "1") catch {},
        6 => hpack.writeLiteral(&w, "expect", "100-continue") catch {},
        7 => hpack.writeLiteral(&w, ":scheme", "http") catch {},
        8 => hpack.writeLiteral(&w, "transfer-encoding", "chunked") catch {},
        else => {},
    }
    const made = w.buffered();
    if (random.uintLessThan(u8, 16) == 0 and made.len > 0) buf[random.uintLessThan(usize, made.len)] = random.int(u8);
    return made;
}

const paths = [_][]const u8{ "/e.S/M", "/e.S/M", "/e.S/M", "/f.S/M", "/f.S/M", "/c.S/M", "/c.S/M", "/x.S/M", "/x.S/M", "", "/e\r\nx: y" };

fn oneFrame(random: std.Random, w: *std.Io.Writer, stream: u31) !void {
    switch (random.uintLessThan(u8, 10)) {
        0, 1, 2 => {
            // HEADERS, most often a whole call's, split sometimes.
            var block_buf: [256]u8 = undefined;
            const block = headerBlock(random, &block_buf);
            var flags: u8 = 0;
            if (random.uintLessThan(u8, 3) == 0) flags |= h2.Flags.end_stream;
            const split = random.uintLessThan(u8, 4) == 0 and block.len > 1;
            if (!split) flags |= h2.Flags.end_headers;
            if (random.uintLessThan(u8, 8) == 0) flags |= h2.Flags.priority;
            const cut = if (split) random.uintLessThan(usize, block.len) else block.len;
            const priority: []const u8 = if (flags & h2.Flags.priority != 0) "\x00\x00\x00\x00\x10" else "";
            try h2.writeHeader(w, priority.len + cut, .headers, flags, stream);
            try w.writeAll(priority);
            try w.writeAll(block[0..cut]);
            if (split and random.uintLessThan(u8, 4) != 0) {
                try h2.writeHeader(w, block.len - cut, .continuation, h2.Flags.end_headers, stream);
                try w.writeAll(block[cut..]);
            }
        },
        3, 4 => {
            // DATA: a gRPC message, its prefix sometimes lying.
            const len = random.uintLessThan(u8, 24);
            const says: u32 = if (random.uintLessThan(u8, 4) == 0) random.int(u32) else len;
            const compressed: u8 = if (random.uintLessThan(u8, 6) == 0) 1 else 0;
            const padded = random.uintLessThan(u8, 8) == 0;
            var flags: u8 = if (random.uintLessThan(u8, 3) != 0) h2.Flags.end_stream else 0;
            if (padded) flags |= h2.Flags.padded;
            try h2.writeHeader(w, 5 + @as(usize, len) + @as(usize, if (padded) 3 else 0), .data, flags, stream);
            if (padded) try w.writeByte(2);
            try w.writeByte(compressed);
            try w.writeInt(u32, says, .big);
            for (0..len) |_| try w.writeByte(random.int(u8));
            if (padded) try w.writeAll("\x00\x00");
        },
        5 => try h2.writeRstStream(w, stream, @enumFromInt(random.uintLessThan(u32, 14))),
        6 => {
            const ack: u8 = if (random.boolean()) h2.Flags.ack else 0;
            try h2.writeHeader(w, 8, .ping, ack, stream);
            try w.writeAll("12345678");
        },
        7 => {
            const increment: u31 = switch (random.uintLessThan(u8, 3)) {
                0 => 0,
                1 => h2.max_window,
                else => random.int(u16),
            };
            try h2.writeWindowUpdate(w, stream, increment);
        },
        8 => {
            // A CONTINUATION nobody asked for, or a SETTINGS ACK.
            if (random.boolean()) {
                try h2.writeHeader(w, 1, .continuation, h2.Flags.end_headers, stream);
                try w.writeByte(0x82);
            } else try h2.writeHeader(w, 0, .settings, h2.Flags.ack, 0);
        },
        else => {
            // PRIORITY, GOAWAY or a type nobody has defined, which is ignored.
            const t: h2.Type = switch (random.uintLessThan(u8, 3)) {
                0 => .priority,
                1 => .goaway,
                else => @enumFromInt(0x20 + random.uintLessThan(u8, 8)),
            };
            const len = random.uintLessThan(u8, 10);
            try h2.writeHeader(w, len, t, random.int(u8), stream);
            for (0..len) |_| try w.writeByte(random.int(u8));
        },
    }
}

/// A request's fields: the four a call needs, in the static table where it
/// has them, then something else. Sometimes a byte of it is anything at all,
/// which is how a table size update or a Huffman string turns up.
fn headerBlock(random: std.Random, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    // :method POST, :scheme http.
    if (random.uintLessThan(u8, 8) != 0) w.writeAll("\x83\x86") catch {};
    const path = paths[random.uintLessThan(usize, paths.len)];
    // :path, a literal with the static table's name.
    w.writeByte(0x04) catch {};
    hpack.writeInt(&w, 0, 7, @intCast(path.len)) catch {};
    w.writeAll(path) catch {};
    if (random.uintLessThan(u8, 10) != 0) {
        hpack.writeLiteral(&w, "content-type", if (random.uintLessThan(u8, 8) != 0) "application/grpc" else "text/plain") catch {};
    }
    switch (random.uintLessThan(u8, 10)) {
        0 => hpack.writeLiteral(&w, "grpc-encoding", if (random.boolean()) "gzip" else "br") catch {},
        1 => hpack.writeLiteral(&w, "grpc-timeout", if (random.boolean()) "1S" else "99999999999H") catch {},
        2 => hpack.writeLiteral(&w, "connection", "close") catch {},
        3 => w.writeAll("\x3f\xe1\x1f") catch {}, // a table size update, after a field
        else => {},
    }
    const made = w.buffered();
    if (random.uintLessThan(u8, 12) == 0 and made.len > 0) buf[random.uintLessThan(usize, made.len)] = random.int(u8);
    return made;
}

// ---- the corpus ----
//
// Inputs that reach a corner, written as bytes. A line `dump` printed goes
// here, and is checked by every `zig build test` after.

const call =
    h2.preface ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++
    // HEADERS, END_HEADERS: POST, http, :path /e.S/M, content-type application/grpc.
    frame(0x01, 0x04, "\x83\x86\x04\x06/e.S/M" ++ "\x00\x0ccontent-type\x10application/grpc") ++
    // DATA, END_STREAM: a two-byte message.
    frame(0x00, 0x01, "\x00\x00\x00\x00\x02hi");

/// HEADERS on stream 1 with `flags`, after the preface and an empty SETTINGS.
fn request(comptime block: []const u8, comptime flags: u8) []const u8 {
    return h2.preface ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++ frame(0x01, flags, block);
}

/// SETTINGS_INITIAL_WINDOW_SIZE of 0: nothing a call writes can be sent.
const no_window = "\x00\x04\x00\x00\x00\x00";

/// `request`, with a second SETTINGS frame of the client's between its
/// preface and its request.
fn requestAfter(comptime more: []const u8, comptime block: []const u8, comptime flags: u8) []const u8 {
    return h2.preface ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++ frame0(0x04, more) ++ frame(0x01, flags, block);
}

const streamed_get = request("\x82\x86\x04\x04/t.x", 0x05);
const file_get = request("\x82\x86\x04\x04/d.x", 0x05);
/// Pings behind the request, each a turn of the connection's loop, which is
/// where a post that has arrived is noticed and written.
const pings = ("\x00\x00\x08\x06\x00\x00\x00\x00\x00" ++ "12345678") ** 400;
const events_get = request("\x82\x86\x04\x04/v.x", 0x05) ++ pings;

/// A frame on the connection, stream 0.
fn frame0(comptime t: u8, comptime payload: []const u8) []const u8 {
    comptime {
        var head: [h2.header_len]u8 = undefined;
        std.mem.writeInt(u24, head[0..3], payload.len, .big);
        head[3] = t;
        head[4] = 0;
        std.mem.writeInt(u32, head[5..9], 0, .big);
        const out = head ++ payload;
        return out;
    }
}

/// A frame on stream 1, its length counted rather than written by hand.
fn frame(comptime t: u8, comptime flags: u8, comptime payload: []const u8) []const u8 {
    comptime {
        var head: [h2.header_len]u8 = undefined;
        std.mem.writeInt(u24, head[0..3], payload.len, .big);
        head[3] = t;
        head[4] = flags;
        std.mem.writeInt(u32, head[5..9], 1, .big);
        const out = head ++ payload;
        return out;
    }
}

const corpus = [_][]const u8{
    "",
    "GET / HTTP/1.1\r\nHost: h\r\n\r\n",
    h2.preface[0..10],
    h2.preface,
    call,
    // The same call to a route that fails, and to no route at all.
    replace(call, "/e.S/M", "/f.S/M"),
    replace(call, "/e.S/M", "/x.S/M"),
    replace(call, "/e.S/M", "/c.S/M"),
    // Its HEADERS without END_HEADERS and nothing after: a block never finished.
    replace(call, "\x01\x04\x00\x00\x00\x01", "\x01\x00\x00\x00\x00\x01"),
    // The call on stream 2, which a client may not open.
    replace(call, "\x00\x00\x00\x01\x83", "\x00\x00\x00\x02\x83"),
    // DATA on a call already answered, which once drew an RST_STREAM after
    // the stream's END_STREAM, one for every frame the client sent.
    call ++ frame(0x00, 0x01, "\x00\x00\x00\x00\x00"),
    // Ordinary requests: a GET with nothing after its HEADERS, the same with
    // a body and a `content-length` that is not its length, a HEAD, a CONNECT,
    // and one with the `te` a request may not carry.
    request("\x82\x86\x04\x04/g.x", 0x05),
    request("\x82\x86\x04\x04/g.x\x0f\x0d\x01\x35", 0x04) ++ frame(0x00, 0x01, "hello"),
    request("\x83\x86\x04\x04/e.x\x0f\x0d\x01\x35", 0x04) ++ frame(0x00, 0x01, "hello"),
    request("\x00\x07:method\x04HEAD\x86\x04\x04/g.x", 0x05),
    request("\x00\x07:method\x07CONNECT\x00\x0a:authority\x01h", 0x05),
    request("\x82\x86\x04\x04/g.x\x00\x02te\x04gzip", 0x05),
    // A request still being sent when it starts: its body in three pieces, the
    // handler reading it in sevens (`/s`), one cut off by a reset, and one
    // told a length it does not keep.
    request("\x83\x86\x04\x04/s.x", 0x04) ++ frame(0x00, 0x00, "abcdefghij") ++ frame(0x00, 0x00, "klm") ++ frame(0x00, 0x01, "n"),
    request("\x83\x86\x04\x04/s.x", 0x04) ++ frame(0x00, 0x00, "abcdefghij") ++ frame(0x03, 0x00, "\x00\x00\x00\x08"),
    request("\x83\x86\x04\x04/s.x\x0f\x0d\x01\x32", 0x04) ++ frame(0x00, 0x00, "abc") ++ frame(0x00, 0x01, "defgh"),
    request("\x83\x86\x04\x04/e.x\x00\x06expect\x0c100-continue", 0x04) ++ frame(0x00, 0x00, "abc") ++ frame(0x00, 0x01, "def"),
    request("\x82\x86\x04\x04/g.x\x00\x06cookie\x03a=1\x00\x06cookie\x03b=2\x00\x06expect\x0c100-continue", 0x04) ++ frame(0x00, 0x01, ""),
    // Answers written in pieces, through the pipe: a stream with a trailer,
    // the same for a HEAD, a file, and each of them with a client window of
    // nothing (the call waits, and the connection ending wakes it), with a
    // reset behind the request, and with a GOAWAY behind it.
    streamed_get,
    request("\x00\x07:method\x04HEAD\x86\x04\x04/t.x", 0x05),
    file_get,
    request("\x00\x07:method\x04HEAD\x86\x04\x04/d.x", 0x05),
    requestAfter(no_window, "\x82\x86\x04\x04/t.x", 0x05),
    requestAfter(no_window, "\x82\x86\x04\x04/d.x", 0x05) ++ frame(0x03, 0x00, "\x00\x00\x00\x08"),
    requestAfter(no_window, "\x82\x86\x04\x04/t.x", 0x05) ++ frame0(0x07, "\x00\x00\x00\x01\x00\x00\x00\x00"),
    requestAfter("\x00\x04\x00\x00\x00\x01", "\x82\x86\x04\x04/t.x", 0x05) ++ frame(0x08, 0x00, "\x00\x00\x00\x01"),
    streamed_get ++ frame(0x03, 0x00, "\x00\x00\x00\x08"),
    file_get ++ frame0(0x08, "\x00\x00\x40\x00"),
    // An event stream with posts arriving as the frames are read, on its own,
    // as a HEAD, with a window of nothing, reset, and with a GOAWAY behind it.
    events_get,
    request("\x00\x07:method\x04HEAD\x86\x04\x04/v.x", 0x05),
    requestAfter(no_window, "\x82\x86\x04\x04/v.x", 0x05),
    requestAfter(no_window, "\x82\x86\x04\x04/v.x", 0x05) ++ frame(0x03, 0x00, "\x00\x00\x00\x08"),
    events_get ++ frame(0x03, 0x00, "\x00\x00\x00\x08"),
    events_get ++ frame0(0x07, "\x00\x00\x00\x01\x00\x00\x00\x00"),
    request("\x82\x86\x04\x04/v.x", 0x04) ++ frame(0x08, 0x00, "\x00\x00\x00\x00"),
    // A stream whose answer is written while the client is still sending, or
    // sending frames the protocol forbids: a reset or a frame after its
    // END_STREAM is what these once drew, and a reset reached a call that had
    // not begun to answer before it, which then answered.
    request("\x00\x07:method\x04HEAD\x86\x04\x04/t.x", 0x04) ++ frame(0x00, 0x00, "abc") ++ frame(0x00, 0x01, "") ++ frame(0x00, 0x00, "more"),
    streamed_get ++ frame(0x08, 0x00, "\x00\x00\x00\x00"),
    request("\x82\x86\x04\x04/t.x", 0x04) ++ frame(0x08, 0x00, "\x7f\xff\xff\xff"),
    request("\x82\x86\x04\x04/d.x", 0x04) ++ frame(0x08, 0x00, "\x00\x00\x00\x00"),
    // A frame whose length runs past the end of the input.
    h2.preface ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++ "\x00\x40\x00\x00\x00\x00\x00\x00\x01",
};

fn replace(comptime in: []const u8, comptime from: []const u8, comptime to: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000);
        const at = std.mem.indexOf(u8, in, from).?;
        return in[0..at] ++ to ++ in[at + from.len ..];
    }
}

const testing = std.testing;

test "the HTTP/2 connection holds its properties over every input we know of" {
    for (corpus) |input| try checkOne(testing.allocator, input);
}

test "the corpus's ordinary call is answered, so the property is looking at an answer" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(call);
    var stop: bulkhead.Stop = .{};
    h2conn.serveConnection(stub(testing.allocator, &stop), &in, &out.writer, .off, .off, .{});
    // SETTINGS, the ACK of the client's, HEADERS, DATA with "hi", trailers.
    try testing.expect(std.mem.indexOf(u8, out.written(), "\x00\x00\x00\x00\x02hi") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "grpc-status\x010") != null);
}

test "the corpus's streamed answer and file are written in pieces, so the property is looking at them" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(streamed_get);
    var stop: bulkhead.Stop = .{};
    h2conn.serveConnection(stub(testing.allocator, &stop), &in, &out.writer, .off, .off, .{});
    // The pieces, in order, and the trailer after the last.
    const got = out.written();
    const at = std.mem.indexOf(u8, got, "a") orelse return error.NoPieces;
    try testing.expect(at > 0);
    try testing.expect(std.mem.indexOf(u8, got, "x-sum") != null);

    var file: std.Io.Writer.Allocating = .init(testing.allocator);
    defer file.deinit();
    var in_file: std.Io.Reader = .fixed(file_get);
    h2conn.serveConnection(stub(testing.allocator, &stop), &in_file, &file.writer, .off, .off, .{});
    var answer = try @import("h2test.zig").answerOf(file.written());
    defer answer.deinit();
    var bytes: usize = 0;
    for (@import("h2test.zig").Answer.of(.data, &answer, 1)) |f| bytes += f.head.len;
    try testing.expectEqual(@as(usize, 40_000), bytes);
}

test "the corpus's event stream is written what the room is told as the frames are read, so the property is looking at it" {
    var seen = false;
    for (0..200) |_| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(events_get);
        var stop: bulkhead.Stop = .{};
        var room = try room_file.Room.initWith(testing.allocator, .{});
        defer room.deinit();
        feed = &room;
        defer feed = null;
        var done: std.atomic.Value(bool) = .init(false);
        const poster = try std.Thread.spawn(.{}, post, .{ &room, &done });
        h2conn.serveConnection(stub(testing.allocator, &stop), &in, &out.writer, .off, .off, .{});
        done.store(true, .release);
        poster.join();
        try answerHolds(testing.allocator, events_get, out.written());
        if (std.mem.indexOf(u8, out.written(), "data: post ") != null) {
            seen = true;
            break;
        }
    }
    try testing.expect(seen);
}

// A generator that stopped producing calls would leave every property above
// holding over nothing. So a fixed seed's run counts what the answers were,
// and each shape has to turn up.
test "generated inputs hold the property, and reach answered calls, failed ones and GOAWAY" {
    var prng = std.Random.DefaultPrng.init(0x297);
    var buf: [4096]u8 = undefined;
    var answered: usize = 0;
    var failed: usize = 0;
    var sent_away: usize = 0;
    for (0..2000) |_| {
        const input = generate(prng.random(), &buf);
        try checkOne(testing.allocator, input);

        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(input);
        var stop: bulkhead.Stop = .{};
        h2conn.serveConnection(stub(testing.allocator, &stop), &in, &out.writer, .off, .off, .{});
        const got = out.written();
        if (std.mem.indexOf(u8, got, "grpc-status\x010") != null) answered += 1;
        if (std.mem.indexOf(u8, got, "grpc-status\x015") != null or std.mem.indexOf(u8, got, "grpc-status\x0212") != null) failed += 1;
        if (std.mem.indexOf(u8, got, "\x00\x00\x08\x07\x00\x00\x00\x00\x00") != null) sent_away += 1;
    }
    try testing.expect(answered >= 20);
    try testing.expect(failed >= 20);
    try testing.expect(sent_away >= 20);
}

// The property is only worth having if it can fail. Each of these is an
// answer it must refuse.
test "the property refuses an answer that breaks a rule" {
    const a = testing.allocator;
    const settings_frame = "\x00\x00\x00\x04\x00\x00\x00\x00\x00";
    try testing.expectError(error.NotH2AnsweredWithFrames, answerHolds(a, "GET", settings_frame));
    try testing.expectError(error.TornFrame, answerHolds(a, h2.preface, settings_frame[0..5]));
    try testing.expectError(error.SettingsNotFirst, answerHolds(a, h2.preface, "\x00\x00\x00\x06\x00\x00\x00\x00\x00"));
    try testing.expectError(error.ConnectionFrameOnAStream, answerHolds(a, h2.preface, settings_frame ++ "\x00\x00\x00\x04\x01\x00\x00\x00\x01"));
    try testing.expectError(error.AnswerOnAStreamTheClientDidNotOpen, answerHolds(a, h2.preface, settings_frame ++ "\x00\x00\x01\x01\x05\x00\x00\x00\x02\x88"));
    try testing.expectError(error.SentAfterTheStreamEnded, answerHolds(a, h2.preface, settings_frame ++
        "\x00\x00\x01\x01\x05\x00\x00\x00\x01\x88" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x01"));
    try testing.expectError(error.HeaderBlockInterrupted, answerHolds(a, h2.preface, settings_frame ++
        "\x00\x00\x01\x01\x00\x00\x00\x00\x01\x88" ++ "\x00\x00\x00\x04\x01\x00\x00\x00\x00"));
    try testing.expectError(error.BlockDoesNotDecode, answerHolds(a, h2.preface, settings_frame ++ "\x00\x00\x01\x01\x04\x00\x00\x00\x01\xff"));
}
