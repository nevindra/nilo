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

/// The positions of the control bytes in `buf[at..]`, as `positionsOf` gives
/// them: everything below 0x20, and DEL. Tab, CR and LF are in it, because
/// which of those a line may hold depends on where they are, and the request
/// head's walk already has the masks to tell (ADR 231).
pub fn controlsOf(buf: []const u8, at: usize) u32 {
    return classOf(buf, at, controlBlock, isControl);
}

fn controlBlock(block: Block) u32 {
    const low: u32 = @bitCast(block < @as(Block, @splat(0x20)));
    const del: u32 = @bitCast(block == @as(Block, @splat(0x7F)));
    return low | del;
}

fn isControl(ch: u8) bool {
    return ch < 0x20 or ch == 0x7F;
}

/// The positions of the bytes in `buf[at..]` that are not a letter, a digit
/// or `-`, which is what nearly every header name is spelled with.
///
/// A header name is a `token` (RFC 9110 §5.6.2), and testing a block for the
/// whole of `tchar` is nine compares where this is three. So a name is
/// tested with this, and only a byte it flags is looked up in `isTokenByte`:
/// an `X_Custom`'s underscore, or a byte that is not a token at all. On a
/// browser's head that was 158ns against 170ns for the nine (ADR 231).
pub fn unusualNameBytesOf(buf: []const u8, at: usize) u32 {
    return classOf(buf, at, unusualBlock, isUnusual);
}

fn unusualBlock(block: Block) u32 {
    const folded = block | @as(Block, @splat(0x20)); // an upper-case letter as its lower-case one
    const letter: u32 = @bitCast(folded -% @as(Block, @splat('a')) <= @as(Block, @splat('z' - 'a')));
    const digit: u32 = @bitCast(block -% @as(Block, @splat('0')) <= @as(Block, @splat(9)));
    const dash: u32 = @bitCast(block == @as(Block, @splat('-')));
    return ~(letter | digit | dash);
}

fn isUnusual(ch: u8) bool {
    return !(std.ascii.isAlphanumeric(ch) or ch == '-');
}

/// `tchar`, as RFC 9110 §5.6.2 lists it.
pub fn isTokenByte(ch: u8) bool {
    return switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// `positionsOf` for a class of bytes rather than one: the same three ways of
/// loading a block, with the class tested by `inBlock` on a whole one and by
/// `isOne` on a buffer too short to have one.
fn classOf(
    buf: []const u8,
    at: usize,
    comptime inBlock: fn (Block) u32,
    comptime isOne: fn (u8) bool,
) u32 {
    if (at + lanes <= buf.len) return inBlock(buf[at..][0..lanes].*);
    if (buf.len >= lanes) {
        const from = buf.len - lanes;
        return inBlock(buf[from..][0..lanes].*) >> @intCast(at - from);
    }
    var bits: u32 = 0;
    for (buf[at..], 0..) |ch, k| {
        if (isOne(ch)) bits |= @as(u32, 1) << @intCast(k);
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
    const text = repeat("GET /a?x=1&y=2 HTTP/1.1\r\nHost: a:b\r\nX: y\r\n\r\n", 3);
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

test "a class of bytes is found at every offset the way a plain loop finds it" {
    // Every length either side of a block boundary, so all three loads are
    // taken, over bytes chosen to sit on each side of every range edge.
    const edges = [_]u8{ 0x00, 0x09, 0x0A, 0x0D, 0x1F, 0x20, 0x21, '"', '#', '\'', '(', ')', '*', ',', '-', '.', '/', '0', '9', ':', '@', 'A', 'Z', '[', ']', '^', '_', '`', 'a', 'z', '{', '|', '}', '~', 0x7F, 0x80, 0xC1, 0xDA, 0xFF };
    var buf: [80]u8 = undefined;
    for (1..buf.len) |len| {
        for (buf[0..len], 0..) |*ch, k| ch.* = edges[(k * 7 + len) % edges.len];
        const text = buf[0..len];
        var i: usize = 0;
        while (i < text.len) : (i += lanes) {
            var want_controls: u32 = 0;
            var want_unusual: u32 = 0;
            for (text[i..@min(i + lanes, text.len)], 0..) |ch, k| {
                if (isControl(ch)) want_controls |= @as(u32, 1) << @intCast(k);
                if (isUnusual(ch)) want_unusual |= @as(u32, 1) << @intCast(k);
            }
            try testing.expectEqual(want_controls, controlsOf(text, i));
            try testing.expectEqual(want_unusual, unusualNameBytesOf(text, i));
        }
    }
}

test "every byte a name is tested for first is a token byte, and the rest are looked up" {
    // `unusualNameBytesOf` may flag a token byte (`_`), since `isTokenByte`
    // decides it after; it must never pass one that is not a token.
    var tokens: usize = 0;
    for (0..256) |b| {
        const ch: u8 = @intCast(b);
        const block: Block = @splat(ch);
        if (unusualBlock(block) == 0) try testing.expect(isTokenByte(ch));
        if (isTokenByte(ch)) tokens += 1;
    }
    // 62 letters and digits and 15 symbols.
    try testing.expectEqual(@as(usize, 77), tokens);
}

/// `s` written `n` times over, at compile time: what `s ** n` said before
/// Zig 0.17 took the operator away.
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    // A comptime-known constant, so that `&built` is a pointer into the
    // binary and the call is as good at runtime as `**` was.
    const built = comptime blk: {
        @setEvalBranchQuota(10 * n + 1000);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        break :blk final;
    };
    return &built;
}
