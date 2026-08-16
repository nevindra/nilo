//! Finding delimiters in a run of bytes, a block at a time.
//!
//! Three places in nilo walk text looking for a handful of particular bytes:
//! the request head (newlines and colons), the query string (`&` and `=`), and
//! a JSON string (the characters that have to be escaped). All three used to do
//! it with `std.mem.indexOfScalar` per delimiter per line or per pair, which is
//! a pass that restarts — with its own preamble — every few bytes.
//!
//! What is here instead is one idea: load a block, compare it against the byte,
//! and read the positions off the resulting bitmask. Two delimiters cost two
//! compares against one load rather than two passes, and a question like "is
//! there a colon anywhere in this line" becomes an `and` on the mask instead of
//! a walk over the matches.
//!
//! Finding the end of a request head went 183ns → 51ns on a browser's head this
//! way, and parsing it 303ns → 163ns.

const std = @import("std");

/// How many bytes are looked at per load. 32 is what
/// `std.simd.suggestVectorLength(u8)` reports on x86-64 with AVX2, and the
/// masks below are `u32` to match it.
pub const lanes = 32;

pub const Block = @Vector(lanes, u8);

/// The positions of `byte` in `buf[at..]`, as a bitmask: bit *k* is set when
/// `buf[at + k] == byte`. Bits past the end of `buf` are always clear, so a
/// tail shorter than a block needs no separate path in the caller.
///
/// The tail is where the care is. Copying it into a padded block first — the
/// obvious way — costs a `memset` and a `memcpy` every time, and every string
/// has a tail. So when there is at least one whole block to stand on, the last
/// one is loaded from `buf.len - lanes`, overlapping bytes already looked at,
/// and the bits belonging to those are shifted off.
pub fn positionsOf(buf: []const u8, at: usize, byte: u8) u32 {
    const mask: Block = @splat(byte);
    if (at + lanes <= buf.len) {
        const block: Block = buf[at..][0..lanes].*;
        return @bitCast(block == mask);
    }
    if (buf.len >= lanes) {
        const from = buf.len - lanes;
        const block: Block = buf[from..][0..lanes].*;
        const bits: u32 = @bitCast(block == mask);
        return bits >> @intCast(at - from);
    }
    // Shorter than one block in total, so there is no whole block to overlap
    // with. A bare "GET / HTTP/1.1", or a query string like "page=3".
    var bits: u32 = 0;
    for (buf[at..], 0..) |ch, k| {
        if (ch == byte) bits |= @as(u32, 1) << @intCast(k);
    }
    return bits;
}

/// How many times `byte` occurs in `buf`.
pub fn countOf(buf: []const u8, byte: u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += lanes) {
        n += @popCount(positionsOf(buf, i, byte));
    }
    return n;
}

/// The bits of `mask` that fall strictly before position `bit`.
pub fn below(bit: u5) u32 {
    return (@as(u32, 1) << bit) - 1;
}

const testing = std.testing;

test "positions are found at every offset, and never past the end" {
    // Every length either side of a block boundary, with the byte at every
    // position in it — this is the arithmetic that decides whether a colon
    // belongs to one header line or the next.
    var buf: [80]u8 = undefined;
    for (1..buf.len) |len| {
        for (0..len) |at| {
            @memset(buf[0..len], 'x');
            buf[at] = ':';
            const text = buf[0..len];

            // Walked block by block, the mask must find it exactly once and
            // report the right absolute position.
            var found: ?usize = null;
            var hits: usize = 0;
            var i: usize = 0;
            while (i < text.len) : (i += lanes) {
                var bits = positionsOf(text, i, ':');
                while (bits != 0) : (bits &= bits - 1) {
                    hits += 1;
                    if (found == null) found = i + @ctz(bits);
                }
            }
            try testing.expectEqual(@as(usize, 1), hits);
            try testing.expectEqual(at, found.?);
            try testing.expectEqual(@as(usize, 1), countOf(text, ':'));
        }
    }
}

test "a byte that is not there is not found" {
    var buf: [100]u8 = undefined;
    @memset(&buf, 'x');
    for (0..buf.len) |len| {
        const text = buf[0..len];
        try testing.expectEqual(@as(usize, 0), countOf(text, ':'));
        var i: usize = 0;
        while (i < text.len) : (i += lanes) {
            try testing.expectEqual(@as(u32, 0), positionsOf(text, i, ':'));
        }
    }
}

test "counting agrees with std.mem.count on every length" {
    var buf: [200]u8 = undefined;
    for (0..buf.len) |len| {
        for (buf[0..len], 0..) |*ch, i| ch.* = if (i % 7 == 0) '&' else 'a';
        const text = buf[0..len];
        try testing.expectEqual(std.mem.count(u8, text, "&"), countOf(text, '&'));
    }
}

test "positionsOf reads the same bytes as a plain loop, on mixed content" {
    const text = "GET /a?x=1&y=2 HTTP/1.1\r\nHost: a:b\r\nX: y\r\n\r\n" ** 3;
    for ([_]u8{ '\n', ':', '&', '=', 'z' }) |byte| {
        var i: usize = 0;
        while (i < text.len) : (i += lanes) {
            var bits = positionsOf(text, i, byte);
            // Every set bit is really that byte...
            var seen: usize = 0;
            var copy = bits;
            while (copy != 0) : (copy &= copy - 1) {
                const at = i + @ctz(copy);
                try testing.expect(at < text.len);
                try testing.expectEqual(byte, text[at]);
                seen += 1;
            }
            // ...and every one of that byte in range is a set bit.
            const upto = @min(i + lanes, text.len);
            var expected: usize = 0;
            for (text[i..upto]) |ch| {
                if (ch == byte) expected += 1;
            }
            try testing.expectEqual(expected, seen);
            bits = 0;
        }
    }
}
