//! What the gRPC listener has to be true for, whatever a stranger sends it
//! ([ADR 220](../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md)).
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
//! - Nothing sent on a stream after its END_STREAM or its RST_STREAM.
//!
//! And the one every fuzzer has, under the safety checks of `ReleaseSafe`:
//! it does not crash, and it does not leak.
//!
//! The route behind the listener is a stub rather than an App, for the same
//! reason `fuzz.zig` drives `http1` rather than the server: what is being
//! fuzzed is the translation, and an App would put a router and a thousand
//! allocations between the input and the property. `grpc.Host` is the seam
//! the App already goes through, so the stub is the same door.
//!
//! `zig build fuzz -- --frames` generates inputs for it; `zig build test`
//! replays the corpus at the bottom.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");
const fail = @import("fail.zig");
const framing = @import("framing.zig");
const grpc = @import("grpc.zig");
const h2 = @import("h2.zig");
const hpack = @import("hpack.zig");
const core = @import("nilo_core");

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
    grpc.serveConnection(stub(gpa, &stop), &in, &out.writer, .off, .off, .{});
    answerHolds(gpa, bytes, out.written()) catch |err| {
        dumpAnswer(out.written());
        return err;
    };
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

/// Three routes, so an answer can be each shape the listener writes: `/e…`
/// echoes the message back, `/f…` fails with text, `/c…` answers with a
/// header and a trailer of its own. Anything else is no route.
fn stub(gpa: std.mem.Allocator, stop: *const bulkhead.Stop) grpc.Host {
    const Stub = struct {
        fn routes(_: *anyopaque, path: []const u8) bool {
            return path.len > 1 and (path[1] == 'e' or path[1] == 'f' or path[1] == 'c');
        }

        fn limit(_: *anyopaque, _: []const u8) usize {
            return 1024;
        }

        fn handle(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: *core.Lifetime,
            _: *fail.InFlight,
            in: *std.Io.Reader,
            collected: *framing.Collected,
            _: bulkhead.Peer,
            _: u64,
        ) void {
            const request = in.buffered();
            const end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return;
            const body = request[end + 4 ..];
            const path_at = "POST ".len;
            const which = if (request.len > path_at + 1) request[path_at + 1] else 'e';
            var to: framing.Framing = .{ .http2 = collected };
            switch (which) {
                'f' => to.whole(404, "text/plain", "no such", false, true, &.{}, .{}) catch {},
                'c' => to.whole(200, "application/grpc", body, false, true, &.{.{ .name = "X-Kind", .value = "own" }}, .{
                    .list = &.{.{ .name = "x-checked", .value = "yes" }},
                }) catch {},
                else => to.whole(200, "application/grpc", body, false, true, &.{}, .{}) catch {},
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

// ---- the property ----

const not_h2 = "HTTP/1.1 505 HTTP Version Not Supported\r\ncontent-length: 0\r\nconnection: close\r\n\r\n";

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

    // Streams whose last frame has been sent, and the block being assembled.
    var ended: std.AutoHashMapUnmanaged(u31, void) = .empty;
    var block: std.ArrayList(u8) = .empty;
    var block_stream: ?u31 = null;

    var rest = got;
    var first = true;
    while (rest.len > 0) {
        if (rest.len < h2.header_len) return error.TornFrame;
        const head = h2.Header.parse(rest[0..h2.header_len]);
        if (rest.len - h2.header_len < head.len) return error.TornFrame;
        const payload = rest[h2.header_len..][0..head.len];
        rest = rest[h2.header_len + head.len ..];

        if (head.len > h2.default_max_frame) return error.FrameTooLarge;
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
                if (ended.contains(head.stream)) return error.SentAfterTheStreamEnded;
            },
            else => return error.FrameTypeThisSideNeverSends,
        }

        switch (head.type) {
            .headers, .continuation => {
                try block.appendSlice(a, payload);
                if (head.has(h2.Flags.end_headers)) {
                    var fields: std.ArrayList(hpack.Field) = .empty;
                    _ = decoder.decode(block.items, a, &fields, std.math.maxInt(u32)) catch return error.BlockDoesNotDecode;
                    block = .empty;
                    block_stream = null;
                } else block_stream = head.stream;
                if (head.type == .headers and head.has(h2.Flags.end_stream)) try ended.put(a, head.stream, {});
            },
            .data => if (head.has(h2.Flags.end_stream)) try ended.put(a, head.stream, {}),
            .rst_stream => try ended.put(a, head.stream, {}),
            else => {},
        }
    }
    if (block_stream != null) return error.HeaderBlockUnfinished;
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
            wholeCall(random, &w, next) catch return w.buffered();
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
/// writes one, its block sometimes split across a CONTINUATION.
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

test "the gRPC listener holds its properties over every input we know of" {
    for (corpus) |input| try checkOne(testing.allocator, input);
}

test "the corpus's ordinary call is answered, so the property is looking at an answer" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(call);
    var stop: bulkhead.Stop = .{};
    grpc.serveConnection(stub(testing.allocator, &stop), &in, &out.writer, .off, .off, .{});
    // SETTINGS, the ACK of the client's, HEADERS, DATA with "hi", trailers.
    try testing.expect(std.mem.indexOf(u8, out.written(), "\x00\x00\x00\x00\x02hi") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "grpc-status\x010") != null);
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
        grpc.serveConnection(stub(testing.allocator, &stop), &in, &out.writer, .off, .off, .{});
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
