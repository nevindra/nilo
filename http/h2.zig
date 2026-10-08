//! HTTP/2 frames (RFC 9113 §4, §6), as far as a gRPC server reads and writes
//! them ([ADR 220](../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md)).
//!
//! The vocabulary and nothing else: what a frame header is, what the types,
//! flags, settings and error codes are called, and how to write the frames
//! this side sends. What a connection does with them is `h2conn.zig`'s. Like
//! `hpack.zig` this takes no Engine and no IO beyond a `std.Io.Writer`, so
//! `zig test http/h2.zig` runs the whole of it.

const std = @import("std");

/// Headers that belong to one HTTP/1.1 connection rather than to a request,
/// which HTTP/2 forbids (§8.2.2), plus `te`, which means something else in
/// HTTP/1.1.
pub fn hopByHop(name: []const u8) bool {
    // By length first: a name is compared with the one or two of its size,
    // where a list of six was six compares for every field of every request.
    return switch (name.len) {
        2 => std.mem.eql(u8, name, "te"),
        7 => std.mem.eql(u8, name, "upgrade"),
        10 => std.mem.eql(u8, name, "connection") or std.mem.eql(u8, name, "keep-alive"),
        16 => std.mem.eql(u8, name, "proxy-connection"),
        17 => std.mem.eql(u8, name, "transfer-encoding"),
        else => false,
    };
}

/// What a client sends before anything else, so a server knows it is not
/// talking to HTTP/1.1 (§3.4). h2c with prior knowledge begins with this.
pub const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// The fixed nine bytes in front of every frame.
pub const header_len = 9;

pub const Type = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
    _,
};

pub const Flags = struct {
    pub const end_stream: u8 = 0x1;
    pub const ack: u8 = 0x1;
    pub const end_headers: u8 = 0x4;
    pub const padded: u8 = 0x8;
    pub const priority: u8 = 0x20;
};

/// §7. A connection error goes out in a GOAWAY; a stream error in a
/// RST_STREAM.
pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    connect_error = 0xa,
    enhance_your_calm = 0xb,
    inadequate_security = 0xc,
    http_1_1_required = 0xd,
    _,
};

pub const Setting = enum(u16) {
    header_table_size = 0x1,
    enable_push = 0x2,
    max_concurrent_streams = 0x3,
    initial_window_size = 0x4,
    max_frame_size = 0x5,
    max_header_list_size = 0x6,
    _,
};

/// The size every frame may be until the peer says more (§6.5.2), and the
/// size this side never raises: a larger frame is a larger buffer, and gRPC
/// messages are split across frames anyway.
pub const default_max_frame = 16_384;
/// The window every stream and the connection start with (§6.9.2).
pub const default_window = 65_535;
/// The largest a flow-control window may grow (§6.9.1).
pub const max_window = std.math.maxInt(u31);

pub const Header = struct {
    len: u24,
    type: Type,
    flags: u8,
    stream: u31,

    pub fn parse(bytes: *const [header_len]u8) Header {
        return .{
            .len = std.mem.readInt(u24, bytes[0..3], .big),
            .type = @fromBackingInt(@intCast(bytes[3])),
            .flags = bytes[4],
            // The reserved top bit is ignored on receipt (§4.1).
            .stream = @intCast(std.mem.readInt(u32, bytes[5..9], .big) & 0x7fff_ffff),
        };
    }

    pub fn has(self: Header, flag: u8) bool {
        return self.flags & flag != 0;
    }
};

pub fn writeHeader(w: *std.Io.Writer, len: usize, t: Type, flags: u8, stream: u31) std.Io.Writer.Error!void {
    var bytes: [header_len]u8 = undefined;
    std.mem.writeInt(u24, bytes[0..3], @intCast(len), .big);
    bytes[3] = @backingInt(t);
    bytes[4] = flags;
    std.mem.writeInt(u32, bytes[5..9], stream, .big);
    try w.writeAll(&bytes);
}

pub fn writeSettings(w: *std.Io.Writer, settings: []const struct { Setting, u32 }) std.Io.Writer.Error!void {
    try writeHeader(w, settings.len * 6, .settings, 0, 0);
    for (settings) |s| {
        var bytes: [6]u8 = undefined;
        std.mem.writeInt(u16, bytes[0..2], @backingInt(s[0]), .big);
        std.mem.writeInt(u32, bytes[2..6], s[1], .big);
        try w.writeAll(&bytes);
    }
}

pub fn writeSettingsAck(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeHeader(w, 0, .settings, Flags.ack, 0);
}

pub fn writePingAck(w: *std.Io.Writer, opaque_data: *const [8]u8) std.Io.Writer.Error!void {
    try writeHeader(w, 8, .ping, Flags.ack, 0);
    try w.writeAll(opaque_data);
}

pub fn writeWindowUpdate(w: *std.Io.Writer, stream: u31, increment: u31) std.Io.Writer.Error!void {
    try writeHeader(w, 4, .window_update, 0, stream);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, increment, .big);
    try w.writeAll(&bytes);
}

pub fn writeRstStream(w: *std.Io.Writer, stream: u31, code: ErrorCode) std.Io.Writer.Error!void {
    try writeHeader(w, 4, .rst_stream, 0, stream);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @backingInt(code), .big);
    try w.writeAll(&bytes);
}

pub fn writeGoaway(w: *std.Io.Writer, last_stream: u31, code: ErrorCode) std.Io.Writer.Error!void {
    try writeHeader(w, 8, .goaway, 0, 0);
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], last_stream, .big);
    std.mem.writeInt(u32, bytes[4..8], @backingInt(code), .big);
    try w.writeAll(&bytes);
}

/// A header block as one HEADERS frame and as many CONTINUATION frames as
/// `max_frame` makes it (§6.10). END_STREAM goes on the HEADERS frame, where
/// §8.1 puts it, whatever follows.
pub fn writeHeaderBlock(w: *std.Io.Writer, stream: u31, block: []const u8, end_stream: bool, max_frame: u32) std.Io.Writer.Error!void {
    var rest = block;
    var first = true;
    while (true) {
        const n = @min(rest.len, max_frame);
        const last = n == rest.len;
        var flags: u8 = 0;
        if (last) flags |= Flags.end_headers;
        if (first and end_stream) flags |= Flags.end_stream;
        try writeHeader(w, n, if (first) .headers else .continuation, flags, stream);
        try w.writeAll(rest[0..n]);
        rest = rest[n..];
        first = false;
        if (last) return;
    }
}

const testing = std.testing;

test "a frame header reads back what was written, and the reserved bit is ignored" {
    var buf: [header_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHeader(&w, 16_384, .data, Flags.end_stream, 7);
    var h = Header.parse(&buf);
    try testing.expectEqual(@as(u24, 16_384), h.len);
    try testing.expectEqual(Type.data, h.type);
    try testing.expect(h.has(Flags.end_stream));
    try testing.expectEqual(@as(u31, 7), h.stream);

    buf[5] |= 0x80;
    h = Header.parse(&buf);
    try testing.expectEqual(@as(u31, 7), h.stream);
}

test "a header block larger than a frame goes out as HEADERS then CONTINUATION, END_STREAM on the first" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHeaderBlock(&w, 1, "abcdefghij", true, 4);
    const out = w.buffered();
    const first = Header.parse(out[0..9]);
    try testing.expectEqual(Type.headers, first.type);
    try testing.expect(first.has(Flags.end_stream));
    try testing.expect(!first.has(Flags.end_headers));
    const second = Header.parse(out[13..22]);
    try testing.expectEqual(Type.continuation, second.type);
    try testing.expect(!second.has(Flags.end_stream));
    const third = Header.parse(out[26..35]);
    try testing.expect(third.has(Flags.end_headers));
    try testing.expectEqual(@as(u24, 2), third.len);
}
