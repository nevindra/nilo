//! The protobuf wire format, with no types in it: varints, keys, length
//! delimited bytes, and the two ends of a buffer (ADR 245).
//!
//! `Reader` is public from `nilo_proto` because a hand-written decoder is a
//! real choice, not a failure of the generic one: a receiver that wants a
//! stream of rows and never a tree of structs reads the wire directly and
//! still gets the same refusals for the same bytes.
//!
//! **The reader keeps its position in the struct and returns a value, so a
//! caller's `var r: Reader` stays in registers.** The slow half of a varint
//! takes the buffer and an index and answers with both, which keeps the
//! address of `r` out of the call and the fast half small enough to inline
//! everywhere. That is the whole of the difference between this and the
//! reader the spike started from, and it is measured in
//! `bench/result/proto.md`.
//!
//! **The writer fills its buffer from the back.** A length prefix is only
//! known once the message after it is written, and writing back to front
//! makes that the distance the position just moved, so a nested message is
//! written once and never sized a second time (prost sizes every level again,
//! which is quadratic in depth).

const std = @import("std");

/// Every way a byte string fails to be a message, named. The decoder returns
/// one of these for any input and never panics (`proto.zig` holds the loop
/// that checks it).
pub const Error = error{
    /// The input ended inside a field.
    Truncated,
    /// A varint ran past ten bytes or past 64 bits.
    VarintTooLong,
    /// A key with field number 0, a wire type of 6 or 7, or more than 32 bits.
    InvalidKey,
    /// A known field arrived with a wire type its type cannot have.
    WrongWireType,
    /// A string field that is not UTF-8.
    InvalidUtf8,
    /// Messages nested deeper than the limit, prost's recursion limit by
    /// default (`max_depth`).
    TooDeep,
    /// An end-group with no start, or for another group.
    UnexpectedEndGroup,
    OutOfMemory,
};

/// prost's default recursion limit, kept equal so both refuse the same input.
pub const max_depth: u32 = 100;

pub const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    len = 2,
    start_group = 3,
    end_group = 4,
    fixed32 = 5,
    _,
};

pub const Key = struct { number: u32, wire: WireType };

/// How many bytes `v` takes as a varint.
pub inline fn varintLen(v: u64) usize {
    return (70 - @clz(v | 1)) / 7;
}

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub inline fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub inline fn more(r: *const Reader) bool {
        return r.pos < r.buf.len;
    }

    pub inline fn varint(r: *Reader) Error!u64 {
        const buf = r.buf;
        const i = r.pos;
        if (i >= buf.len) return error.Truncated;
        const b0 = buf[i];
        if (b0 < 0x80) {
            r.pos = i + 1;
            return b0;
        }
        const out = try varintSlow(buf, i);
        r.pos = out.pos;
        return out.value;
    }

    pub inline fn key(r: *Reader) Error!Key {
        return splitKey(try r.varint());
    }

    pub inline fn fixed64(r: *Reader) Error!u64 {
        if (r.buf.len - r.pos < 8) return error.Truncated;
        const v = std.mem.readInt(u64, r.buf[r.pos..][0..8], .little);
        r.pos += 8;
        return v;
    }

    pub inline fn fixed32(r: *Reader) Error!u32 {
        if (r.buf.len - r.pos < 4) return error.Truncated;
        const v = std.mem.readInt(u32, r.buf[r.pos..][0..4], .little);
        r.pos += 4;
        return v;
    }

    /// The payload of a length delimited field, borrowed from the input.
    pub inline fn bytes(r: *Reader) Error![]const u8 {
        const n = try r.varint();
        if (n > r.buf.len - r.pos) return error.Truncated;
        const len: usize = @intCast(n);
        const out = r.buf[r.pos..][0..len];
        r.pos += len;
        return out;
    }

    /// Step over a field this reader does not know. `depth_left` bounds the
    /// groups a field can nest, the way prost bounds them.
    pub fn skip(r: *Reader, k: Key, depth_left: u32) Error!void {
        switch (k.wire) {
            .varint => _ = try r.varint(),
            .fixed64 => _ = try r.fixed64(),
            .fixed32 => _ = try r.fixed32(),
            .len => _ = try r.bytes(),
            .start_group => {
                if (depth_left == 0) return error.TooDeep;
                while (true) {
                    const inner = try r.key();
                    if (inner.wire == .end_group) {
                        if (inner.number != k.number) return error.UnexpectedEndGroup;
                        return;
                    }
                    try r.skip(inner, depth_left - 1);
                }
            },
            .end_group => return error.UnexpectedEndGroup,
            _ => return error.InvalidKey,
        }
    }
};

pub inline fn splitKey(v: u64) Error!Key {
    if (v > std.math.maxInt(u32)) return error.InvalidKey;
    const wire: u3 = @truncate(v);
    if (wire > 5) return error.InvalidKey;
    const number: u32 = @intCast(v >> 3);
    if (number == 0) return error.InvalidKey;
    return .{ .number = number, .wire = @fromBackingInt(@intCast(wire)) };
}

pub const Varint = struct { value: u64, pos: usize };

/// A varint whose first byte has its continuation bit set, read from `i`.
/// With ten bytes in hand it is a straight run with no bounds check per
/// byte; near the end of the buffer it is the checked loop.
pub fn varintSlow(buf: []const u8, start: usize) Error!Varint {
    var i = start;
    var result: u64 = 0;
    var shift: u6 = 0;
    if (buf.len - i >= 10) {
        while (true) : (i += 1) {
            const b = buf[i];
            if (shift == 63) {
                // The tenth byte may carry one bit and no continuation.
                if (b > 1) return error.VarintTooLong;
                return .{ .value = result | (@as(u64, b) << 63), .pos = i + 1 };
            }
            result |= @as(u64, b & 0x7f) << shift;
            if (b < 0x80) return .{ .value = result, .pos = i + 1 };
            shift += 7;
        }
    }
    while (true) : (i += 1) {
        if (i >= buf.len) return error.Truncated;
        const b = buf[i];
        if (shift == 63) {
            if (b > 1) return error.VarintTooLong;
            return .{ .value = result | (@as(u64, b) << 63), .pos = i + 1 };
        }
        result |= @as(u64, b & 0x7f) << shift;
        if (b < 0x80) return .{ .value = result, .pos = i + 1 };
        shift += 7;
    }
}

/// Fills `buf` from its end toward its start. `pos` is where the bytes
/// written so far begin, so the length of a message just written is the
/// distance the position moved.
pub const Writer = struct {
    buf: []u8,
    pos: usize,

    pub inline fn varint(w: *Writer, value: u64) void {
        const n = varintLen(value);
        w.pos -= n;
        var p = w.pos;
        var v = value;
        while (v >= 0x80) : (v >>= 7) {
            w.buf[p] = @as(u8, @truncate(v)) | 0x80;
            p += 1;
        }
        w.buf[p] = @truncate(v);
    }

    pub inline fn key(w: *Writer, number: u32, wire: WireType) void {
        w.varint((@as(u64, number) << 3) | @backingInt(wire));
    }

    pub inline fn raw(w: *Writer, b: []const u8) void {
        w.pos -= b.len;
        @memcpy(w.buf[w.pos..][0..b.len], b);
    }

    pub inline fn fixed64(w: *Writer, v: u64) void {
        w.pos -= 8;
        std.mem.writeInt(u64, w.buf[w.pos..][0..8], v, .little);
    }

    pub inline fn fixed32(w: *Writer, v: u32) void {
        w.pos -= 4;
        std.mem.writeInt(u32, w.buf[w.pos..][0..4], v, .little);
    }
};

/// Whether `b` is UTF-8, which a protobuf string must be.
///
/// std's check has a vector fast path for ASCII and then walks the last
/// partial chunk a byte at a time through its state table. Strings in a
/// telemetry or RPC message are 5 to 40 bytes, so that tail is most of the
/// work. Here a string of up to 16 bytes is two overlapping 8-byte loads, a
/// longer one is 64 bytes a turn, then 16, and one overlapping load at the end, and only
/// a string with a byte of 0x80 or more reaches std's validator, started at
/// the chunk it was found in (every byte before it is ASCII, so that is a
/// character boundary).
pub fn validUtf8(b: []const u8) bool {
    if (b.len <= 16) {
        if (b.len >= 8) {
            const lo = std.mem.readInt(u64, b[0..8], .little);
            const hi = std.mem.readInt(u64, b[b.len - 8 ..][0..8], .little);
            if ((lo | hi) & 0x8080808080808080 == 0) return true;
            return std.unicode.utf8ValidateSlice(b);
        }
        if (b.len >= 4) {
            const lo = std.mem.readInt(u32, b[0..4], .little);
            const hi = std.mem.readInt(u32, b[b.len - 4 ..][0..4], .little);
            if ((lo | hi) & 0x80808080 == 0) return true;
            return std.unicode.utf8ValidateSlice(b);
        }
        var acc: u8 = 0;
        for (b) |c| acc |= c;
        if (acc < 0x80) return true;
        return std.unicode.utf8ValidateSlice(b);
    }
    const V = @Vector(16, u8);
    var i: usize = 0;
    // Four chunks a turn: one branch for 64 bytes of ASCII.
    while (i + 64 <= b.len) : (i += 64) {
        const x: V = b[i..][0..16].*;
        const y: V = b[i + 16 ..][0..16].*;
        const z: V = b[i + 32 ..][0..16].*;
        const w: V = b[i + 48 ..][0..16].*;
        if (@reduce(.Or, (x | y) | (z | w)) >= 0x80) return std.unicode.utf8ValidateSlice(b[i..]);
    }
    while (i + 16 <= b.len) : (i += 16) {
        const chunk: V = b[i..][0..16].*;
        if (@reduce(.Or, chunk) >= 0x80) return std.unicode.utf8ValidateSlice(b[i..]);
    }
    if (i < b.len) {
        const tail: V = b[b.len - 16 ..][0..16].*;
        if (@reduce(.Or, tail) >= 0x80) return std.unicode.utf8ValidateSlice(b[i..]);
    }
    return true;
}

const testing = std.testing;

test "a varint is read at every length and refused past ten bytes" {
    const cases = [_]struct { bytes: []const u8, value: u64 }{
        .{ .bytes = &.{0x00}, .value = 0 },
        .{ .bytes = &.{0x7f}, .value = 127 },
        .{ .bytes = &.{ 0x80, 0x01 }, .value = 128 },
        .{ .bytes = &.{ 0xac, 0x02 }, .value = 300 },
        .{ .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 }, .value = std.math.maxInt(u64) },
    };
    for (cases) |c| {
        var r: Reader = .init(c.bytes);
        try testing.expectEqual(c.value, try r.varint());
        try testing.expect(!r.more());
        // The same bytes with room behind them take the unchecked run.
        var padded: [16]u8 = @splat(0);
        @memcpy(padded[0..c.bytes.len], c.bytes);
        var p: Reader = .init(&padded);
        try testing.expectEqual(c.value, try p.varint());
        try testing.expectEqual(c.bytes.len, p.pos);
    }
    var long: Reader = .init(&.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02 });
    try testing.expectError(error.VarintTooLong, long.varint());
    var cut: Reader = .init(&.{ 0x80, 0x80 });
    try testing.expectError(error.Truncated, cut.varint());
}

test "varintLen agrees with the bytes a writer produces" {
    var buf: [10]u8 = undefined;
    for ([_]u64{ 0, 1, 127, 128, 16383, 16384, 1 << 35, 1 << 62, 1 << 63, std.math.maxInt(u64) }) |v| {
        var w: Writer = .{ .buf = &buf, .pos = buf.len };
        w.varint(v);
        try testing.expectEqual(varintLen(v), buf.len - w.pos);
        var r: Reader = .init(buf[w.pos..]);
        try testing.expectEqual(v, try r.varint());
    }
}

test "validUtf8 agrees with std on every length, ASCII and not" {
    var prng = std.Random.DefaultPrng.init(0x7f3a);
    const rng = prng.random();
    var buf: [80]u8 = undefined;
    for (0..4000) |_| {
        const n = rng.uintLessThan(usize, buf.len + 1);
        // Mostly ASCII, with an occasional high byte or a real sequence.
        for (buf[0..n]) |*c| c.* = if (rng.uintLessThan(u8, 40) == 0) rng.int(u8) else rng.uintLessThan(u8, 0x80);
        if (n >= 3 and rng.boolean()) {
            const at = rng.uintLessThan(usize, n - 2);
            @memcpy(buf[at..][0..3], "\xe2\x82\xac");
        }
        try testing.expectEqual(std.unicode.utf8ValidateSlice(buf[0..n]), validUtf8(buf[0..n]));
    }
}

test "a stray end-group and a group that closes the wrong number are refused" {
    var r: Reader = .init(&.{ 0x0c, 0x00 }); // end-group of field 1 with no start
    try testing.expectError(error.UnexpectedEndGroup, r.skip(try r.key(), 10));
    var q: Reader = .init(&.{ 0x0b, 0x14 }); // start-group 1, end-group 2
    try testing.expectError(error.UnexpectedEndGroup, q.skip(try q.key(), 10));
    var ok: Reader = .init(&.{ 0x0b, 0x10, 0x05, 0x0c }); // group 1 holding a varint
    try ok.skip(try ok.key(), 10);
    try testing.expect(!ok.more());
}
