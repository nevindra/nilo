//! The WebSocket frame, as bytes (RFC 6455 §5, ADR 057, ADR 281).
//!
//! What the server in `http/websocket.zig` and the client in `nilo_fetch` both
//! have to agree about, written once: how a frame header is read and written,
//! how a payload is masked, which headers are refused, what a close frame
//! carries and what text is allowed to be. **None of it reads or writes a
//! socket**, which is what lets `zig test core/core.zig` hold the whole of
//! RFC 6455 §5.2 as a table of byte strings and what lets `nilo_fetch`, a
//! Fitting that may not name `nilo_http` (ADR 038), have a WebSocket client
//! without a second copy of the framing.
//!
//! Which end sent a frame is the only thing the two sides disagree about: a
//! client masks every frame it sends and a server masks none (RFC 6455
//! §5.3), so `Frame.wellFormed` takes the sender and `writeHeader` and
//! `writeMaskedHeader` are two functions rather than one with a flag.
//!
//! **The masking is the one hot loop in here and it moved without changing**
//! (ADR 046): a vector XOR against the key tiled to 128, 32, 8 and 4 bytes, in
//! one pass that copies as it goes. It sits in this file as it sat in the
//! server's, inlined into the same compilation unit, and the instructions
//! per message are on the record in `bench/result/http.md`.

const std = @import("std");

/// The string every WebSocket handshake in the world hashes against. It has
/// no meaning; it is there so that a server which merely echoes the key
/// cannot be mistaken for one that speaks the protocol (RFC 6455 §1.3).
const handshake_salt = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// The answer to `Sec-WebSocket-Key`: SHA-1 of the key and a fixed string,
/// base64'd. It proves nothing about anybody; it proves the server on the
/// other end knows what protocol it is speaking. A server writes it and a
/// client checks it, so it is here.
pub fn accept(key: []const u8) [28]u8 {
    var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(handshake_salt);
    sha.final(&hash);

    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &hash);
    return out;
}

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,

    pub fn isControl(self: Opcode) bool {
        return @backingInt(self) & 0x8 != 0;
    }
};

/// Why a connection is being closed. The numbers are RFC 6455 §7.4.1's, and
/// the ones either end actually sends.
pub const Close = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported = 1003,
    /// Text that was not valid UTF-8.
    invalid_payload = 1007,
    policy = 1008,
    too_big = 1009,
    internal = 1011,
    _,
};

/// The most a control frame can carry (RFC 6455 §5.5): a ping's tag, or a
/// close's two bytes of code and a reason in what is left.
pub const max_control = 125;

/// The longest header a server writes can be: two bytes and a 64-bit length.
/// A server never masks, so there are no four bytes of key on the end of it.
pub const max_header = 10;

/// The longest header a client writes: the above and four bytes of key.
pub const max_masked_header = max_header + 4;

/// The bytes that go in front of an unmasked frame (a server's), written into
/// `into` and returned as the part of it that counts.
///
/// Public because a `Room` builds this **once** for a message and every
/// connection in the room writes the same bytes. A server frame carries no
/// mask and no per-connection anything, so there is nothing in a header worth
/// building a thousand times (ADR 035, ADR 046).
pub fn writeHeader(into: *[max_header]u8, opcode: Opcode, len: u64) []u8 {
    into[0] = 0x80 | @as(u8, @backingInt(opcode)); // FIN, no reserved bits

    // A server never masks. The mask exists to stop a hostile page making a
    // browser send bytes that a proxy would read as a request, and only a
    // browser is in that position.
    if (len < 126) {
        into[1] = @intCast(len);
        return into[0..2];
    }
    if (len <= std.math.maxInt(u16)) {
        into[1] = 126;
        std.mem.writeInt(u16, into[2..4], @intCast(len), .big);
        return into[0..4];
    }
    into[1] = 127;
    std.mem.writeInt(u64, into[2..10], len, .big);
    return into[0..10];
}

/// The bytes that go in front of a masked frame (a client's): the header
/// `writeHeader` writes with the mask bit set, and the four bytes of `key`
/// after the length. The payload that follows has to be XORed with the same
/// key (`maskInto`); a key reused from one frame to the next is the thing
/// RFC 6455 §5.3 forbids, so the caller draws a fresh one for every frame.
pub fn writeMaskedHeader(into: *[max_masked_header]u8, opcode: Opcode, len: u64, key: [4]u8) []u8 {
    const bare = writeHeader(into[0..max_header], opcode, len);
    into[1] |= 0x80;
    @memcpy(into[bare.len..][0..4], &key);
    return into[0 .. bare.len + 4];
}

/// Which end of the connection wrote a frame, which decides whether it has to
/// be masked.
pub const Sender = enum { client, server };

/// One frame header, as it was found on the wire. `reserved` and `masked`
/// are carried rather than judged, because `headerFrom` is pure and every
/// refusal belongs to the connection that has a close frame to send.
pub const Frame = struct {
    fin: bool,
    reserved: bool,
    masked: bool,
    opcode: Opcode,
    len: u64,
    mask: [4]u8,
    /// How many bytes of the stream this header took.
    size: usize,

    /// Whether this header is one `from` is allowed to send (RFC 6455
    /// §5.1, §5.2, §5.5), judged on the header alone.
    ///
    /// - **No reserved bit.** They are for extensions negotiated in the
    ///   handshake, and neither end here negotiates one, so a frame setting a
    ///   bit is talking to a peer that is not there.
    /// - **A client masks and a server does not.** An unmasked frame from a
    ///   client is a broken client or something that is not one, and a masked
    ///   frame from a server is a proxy being asked to read a client's bytes.
    /// - **The shortest form that holds the length**, and the 64-bit form with
    ///   its top bit clear. A header read loosely here is one a proxy in front
    ///   may read strictly, which is how a frame is smuggled past it.
    /// - **A control frame is one small whole frame**, because it may arrive
    ///   in the middle of somebody else's message.
    pub fn wellFormed(self: Frame, from: Sender) bool {
        if (self.reserved) return false;
        if (self.masked != (from == .client)) return false;
        const wide = self.size - 2 - @as(usize, if (self.masked) 4 else 0);
        if (wide == 2 and self.len < 126) return false;
        if (wide == 8 and (self.len <= 0xffff or self.len >> 63 != 0)) return false;
        if (self.opcode.isControl() and (self.len > max_control or !self.fin)) return false;
        return true;
    }
};

/// How long a header is, from its first two bytes. The rest of it is a
/// length in one of three widths and, from a client, four bytes of key.
pub fn headerSize(lead: [2]u8) usize {
    const extra: usize = switch (@as(u7, @truncate(lead[1]))) {
        126 => 2,
        127 => 8,
        else => 0,
    };
    return 2 + extra + @as(usize, if (lead[1] & 0x80 != 0) 4 else 0);
}

/// Read a frame header out of bytes already in hand, or null when there
/// are not yet enough of them to say.
///
/// Pure: no reader, no socket, no refusals. That is what lets the whole of
/// RFC 6455 §5.2 be checked against a table of byte strings instead of
/// through a connection, and it is why the fast path in the server is three
/// lines.
pub fn headerFrom(bytes: []const u8) ?Frame {
    if (bytes.len < 2) return null;
    const lead: [2]u8 = bytes[0..2].*;
    const size = headerSize(lead);
    if (bytes.len < size) return null;

    const short: u7 = @truncate(lead[1]);
    const masked = lead[1] & 0x80 != 0;
    return .{
        .fin = lead[0] & 0x80 != 0,
        .reserved = lead[0] & 0x70 != 0,
        .masked = masked,
        .opcode = @fromBackingInt(@intCast(@as(u4, @truncate(lead[0])))),
        .len = switch (short) {
            126 => std.mem.readInt(u16, bytes[2..4], .big),
            127 => std.mem.readInt(u64, bytes[2..10], .big),
            else => short,
        },
        .mask = if (masked) bytes[size - 4 ..][0..4].* else .{ 0, 0, 0, 0 },
        .size = size,
    };
}

/// Whether `bytes` may be a text message or a close reason: UTF-8, which is
/// what RFC 6455 §5.6 defines text to be. One rule for both ends, so a
/// message one of them accepts is a message the other would have sent.
pub fn validText(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes);
}

/// Whether a close frame's payload is one RFC 6455 §5.5.1 allows: nothing at
/// all, or two bytes of code and a reason in UTF-8.
///
/// One byte is neither. A code outside the ranges the registry hands out is
/// one nobody can act on, and 1005 and 1006 in particular only ever mean
/// something locally: an end that puts either on the wire is reporting
/// something it cannot have observed.
pub fn closeIsWellFormed(payload: []const u8) bool {
    if (payload.len == 0) return true;
    if (payload.len < 2) return false;

    const code = std.mem.readInt(u16, payload[0..2], .big);
    const known = switch (code) {
        1000...1003, 1007...1014 => true,
        // 3000-3999 belong to libraries and 4000-4999 to applications, and
        // neither is this end's business to second-guess.
        3000...4999 => true,
        else => false,
    };
    if (!known) return false;
    return validText(payload[2..]);
}

/// The most of `reason` that fits beside a close code, cut on a character
/// boundary.
///
/// 123 is what is left of a control frame's 125 once the code has had its
/// two, and a reason cut through the middle of a multi-byte character is a
/// close frame the other end is entitled to refuse, which would turn saying
/// goodbye politely into the crash it was meant to avoid.
pub fn reasonFits(reason: []const u8) usize {
    if (reason.len <= max_control - 2) return reason.len;
    var n: usize = max_control - 2;
    // A continuation byte is 10xxxxxx. Back up to the one that starts the
    // character it belongs to.
    while (n > 0 and reason[n] & 0xc0 == 0x80) n -= 1;
    return n;
}

/// The payload of a close frame: `code`, then as much of `reason` as fits.
pub fn closePayload(into: *[max_control]u8, code: Close, reason: []const u8) []u8 {
    std.mem.writeInt(u16, into[0..2], @backingInt(code), .big);
    const room = reasonFits(reason);
    @memcpy(into[2..][0..room], reason[0..room]);
    return into[0 .. 2 + room];
}

/// The widths the unmasking steps down through. The key is four bytes, so
/// every one of them tiles it exactly, and LLVM splits each into whatever
/// registers the target actually has.
///
/// 128 is where the throughput stopped improving when ADR 046 measured it:
/// 2.4× a single 32-byte tile on a 16 KiB message, with 256 worth another 6%
/// and twice the unrolled code. The smaller steps are not an afterthought:
/// a chat line is forty bytes and would otherwise fall straight past the wide
/// tile into a byte-at-a-time tail almost as long as the message.
const unmask_tiers = [_]usize{ 128, 32, 8, 4 };

/// Undo the client's masking, in place. `offset` is how far into the message
/// these bytes are, so the key lines up across a payload read in pieces.
pub fn unmask(data: []u8, key: [4]u8, offset: usize) void {
    unmaskInto(data, data, key, offset);
}

/// Undo the client's masking out of `src` and into `dst`, which may be the
/// same slice. `offset` is how far into the message these bytes are, so the
/// key lines up across a payload that arrived in pieces.
///
/// The obvious loop (one XOR per byte, `key[i % 4]`) is what the RFC
/// describes, and it runs at about a fourteenth of the speed of copying the
/// same bytes. For a 16 KiB message that was the entire cost of receiving
/// one: 6.4µs, against 0.5µs to send the same message back. Since the key
/// repeats every four bytes, the whole thing is one XOR against a repeating
/// pattern, which is a vector operation rather than a loop.
///
/// **Copying and unmasking are the same pass**, which is the second half of
/// that finding (ADR 046): the bytes arrive in the connection's read buffer
/// and have to reach the handler's, and doing the XOR on the way costs
/// nothing over the move itself. Reading them and then unmasking them where
/// they landed is two walks over the same cache lines for one result.
///
/// XOR is its own inverse, so this is also the client's masking: `maskInto`.
pub fn unmaskInto(dst: []u8, src: []const u8, key: [4]u8, offset: usize) void {
    std.debug.assert(dst.len == src.len);

    // Where these bytes sit in the message decides which byte of the key
    // lines up with the first of them.
    var rotated: [4]u8 = undefined;
    inline for (0..4) |k| rotated[k] = key[(k +% offset) & 3];

    // Widest first, and each step only entered if there is work its size for
    // it, so a 16 KiB message never touches the narrow loops and a forty-byte
    // one never builds the wide pattern.
    var i: usize = 0;
    inline for (unmask_tiers) |lanes| {
        if (dst.len - i >= lanes) {
            const pattern: @Vector(lanes, u8) = std.simd.repeat(lanes, @as(@Vector(4, u8), rotated));
            while (i + lanes <= dst.len) : (i += lanes) {
                const block: @Vector(lanes, u8) = src[i..][0..lanes].*;
                dst[i..][0..lanes].* = block ^ pattern;
            }
        }
    }
    // Three bytes at the most.
    while (i < dst.len) : (i += 1) dst[i] = src[i] ^ rotated[i & 3];
}

/// Mask `src` into `dst` for the wire, which is `unmaskInto` by another name:
/// the client's side of RFC 6455 §5.3 and the server's undoing of it are one
/// function, and the name says which a call site means.
pub const maskInto = unmaskInto;

const testing = std.testing;

/// RFC 6455 §5.3 transformed-octet-i, written the way the RFC writes it:
/// one byte at a time, no cleverness. Every test masks with this and lets
/// `unmask` undo it, so what is being checked is agreement with the spec.
///
/// Masking with `unmask` itself, which is what these tests used to do, is
/// no check at all. XOR is its own inverse, so a completely broken `unmask`
/// still round-trips against itself, and every test here passed.
fn maskLikeTheRfc(data: []u8, key: [4]u8, offset: usize) void {
    for (data, offset..) |*byte, i| byte.* ^= key[i % 4];
}

test "unmask agrees with the RFC at every length around a vector boundary" {
    // The lanes are what a length has to be checked against: one short of a
    // block, exactly a block, one past it, and the same around two blocks,
    // and around the eight- and four-byte steps that clear up the tail.
    const lengths = [_]usize{ 0, 1, 2, 3, 4, 5, 7, 8, 9, 11, 12, 13, 15, 16, 31, 32, 33, 39, 40, 63, 64, 65, 127, 1000 };
    const key = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };

    var original: [1000]u8 = undefined;
    for (&original, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    for (lengths) |len| {
        // And at every alignment of the key, which is what `offset` decides
        // when a payload arrives in more than one piece.
        for (0..4) |offset| {
            var masked: [1000]u8 = undefined;
            @memcpy(masked[0..len], original[0..len]);
            maskLikeTheRfc(masked[0..len], key, offset);

            unmask(masked[0..len], key, offset);
            try testing.expectEqualSlices(u8, original[0..len], masked[0..len]);
        }
    }
}

test "unmasking into somewhere else agrees with unmasking in place" {
    // The pass that receive actually takes: out of the read buffer and into
    // the handler's, with the XOR done on the way. It has to agree with the
    // in-place one byte for byte, at every length and every key alignment.
    const lengths = [_]usize{ 0, 1, 3, 4, 7, 8, 15, 16, 31, 32, 33, 40, 65, 500 };
    const key = [4]u8{ 0x9a, 0x11, 0xc3, 0x04 };

    var original: [500]u8 = undefined;
    for (&original, 0..) |*b, i| b.* = @truncate(i *% 17 +% 3);

    for (lengths) |len| {
        for (0..4) |offset| {
            var masked: [500]u8 = undefined;
            @memcpy(masked[0..len], original[0..len]);
            maskLikeTheRfc(masked[0..len], key, offset);

            var landed: [500]u8 = undefined;
            unmaskInto(landed[0..len], masked[0..len], key, offset);
            try testing.expectEqualSlices(u8, original[0..len], landed[0..len]);
        }
    }
}

test "masking for the wire is what the RFC says, at every length and key alignment" {
    // The client's direction, checked against the byte-at-a-time loop rather
    // than against `unmask`, for the reason `maskLikeTheRfc` gives.
    const key = [4]u8{ 0xde, 0xad, 0xbe, 0xef };
    var original: [300]u8 = undefined;
    for (&original, 0..) |*b, i| b.* = @truncate(i *% 13 +% 1);

    for ([_]usize{ 0, 1, 4, 5, 31, 32, 33, 129, 300 }) |len| {
        for (0..4) |offset| {
            var expected = original;
            maskLikeTheRfc(expected[0..len], key, offset);
            var wire: [300]u8 = undefined;
            maskInto(wire[0..len], original[0..len], key, offset);
            try testing.expectEqualSlices(u8, expected[0..len], wire[0..len]);
        }
    }
}

test "unmask picks up mid-message where the previous piece left off" {
    // The property `offset` exists for: two calls over halves of a payload
    // must produce what one call over the whole of it does.
    const key = [4]u8{ 0x01, 0x02, 0x03, 0x04 };
    var whole: [70]u8 = undefined;
    for (&whole, 0..) |*b, i| b.* = @truncate(i);
    var split = whole;

    maskLikeTheRfc(&whole, key, 0);
    maskLikeTheRfc(&split, key, 0);

    unmask(&whole, key, 0);
    // 33 is deliberately not a multiple of four or of the vector width.
    unmask(split[0..33], key, 0);
    unmask(split[33..], key, 33);

    try testing.expectEqualSlices(u8, &whole, &split);
}

test "a header is read out of the bytes in hand, or not read at all" {
    // Pure, so the whole of RFC 6455 §5.2 is a table rather than a
    // connection. Nothing here refuses anything: that is the connection's
    // job, and it needs a close frame to do it with.
    try testing.expect(headerFrom("") == null);
    try testing.expect(headerFrom("\x81") == null);
    // Announced as masked, and the four bytes of key have not arrived.
    try testing.expect(headerFrom("\x81\x85\x37\xfa") == null);

    const short = headerFrom("\x81\x85\x37\xfa\x21\x3d").?;
    try testing.expect(short.fin);
    try testing.expect(!short.reserved);
    try testing.expect(short.masked);
    try testing.expectEqual(Opcode.text, short.opcode);
    try testing.expectEqual(@as(u64, 5), short.len);
    try testing.expectEqual([4]u8{ 0x37, 0xfa, 0x21, 0x3d }, short.mask);
    try testing.expectEqual(@as(usize, 6), short.size);

    // 126 means the length is the next two bytes, and the header is 8 long.
    const medium = headerFrom("\x82\xfe\xea\x60\x01\x02\x03\x04").?;
    try testing.expectEqual(Opcode.binary, medium.opcode);
    try testing.expectEqual(@as(u64, 60_000), medium.len);
    try testing.expectEqual(@as(usize, 8), medium.size);

    // 127 means eight bytes of length, and a header of 14.
    const long = headerFrom(
        "\x02\xff\x00\x00\x00\x01\x00\x00\x00\x00\x0a\x0b\x0c\x0d",
    ).?;
    try testing.expect(!long.fin);
    try testing.expectEqual(@as(u64, 1 << 32), long.len);
    try testing.expectEqual(@as(usize, 14), long.size);

    // An unmasked frame is four bytes shorter and carries no key. It is a
    // header that parses and a frame that will be refused.
    const bare = headerFrom("\x89\x00").?;
    try testing.expect(!bare.masked);
    try testing.expectEqual(@as(usize, 2), bare.size);
    try testing.expect(bare.opcode.isControl());

    // Any of the three reserved bits.
    try testing.expect(headerFrom("\xc1\x80\x00\x00\x00\x00").?.reserved);
    try testing.expect(headerFrom("\xa1\x80\x00\x00\x00\x00").?.reserved);
    try testing.expect(headerFrom("\x91\x80\x00\x00\x00\x00").?.reserved);
}

test "a header is well formed for the end that sent it, and for no other" {
    const masked_text = headerFrom("\x81\x85\x37\xfa\x21\x3d").?;
    try testing.expect(masked_text.wellFormed(.client));
    try testing.expect(!masked_text.wellFormed(.server));

    const bare_text = headerFrom("\x81\x05").?;
    try testing.expect(bare_text.wellFormed(.server));
    try testing.expect(!bare_text.wellFormed(.client));

    // A reserved bit, from either end.
    try testing.expect(!headerFrom("\xc1\x05").?.wellFormed(.server));

    // The sixteen-bit form for a length the seven-bit form holds, and the
    // sixty-four-bit form for one the sixteen-bit form holds.
    try testing.expect(!headerFrom("\x81\x7e\x00\x7d").?.wellFormed(.server));
    try testing.expect(headerFrom("\x81\x7e\x00\x7e").?.wellFormed(.server));
    try testing.expect(!headerFrom("\x81\x7f\x00\x00\x00\x00\x00\x00\xff\xff").?.wellFormed(.server));
    try testing.expect(!headerFrom("\x81\x7f\x80\x00\x00\x00\x00\x00\x00\x00").?.wellFormed(.server));
    try testing.expect(headerFrom("\x81\x7f\x00\x00\x00\x00\x00\x01\x00\x00").?.wellFormed(.server));

    // A control frame is whole and small.
    try testing.expect(!headerFrom("\x09\x00").?.wellFormed(.server)); // ping, no FIN
    try testing.expect(!headerFrom("\x89\x7e\x00\x7e").?.wellFormed(.server)); // 126 bytes
    try testing.expect(headerFrom("\x89\x7d").?.wellFormed(.server)); // 125 bytes
}

test "a header written is a header read back, masked or not" {
    var bare_buf: [max_header]u8 = undefined;
    for ([_]u64{ 0, 5, 125, 126, 60_000, 65_535, 65_536, 1 << 40 }) |len| {
        const bare = writeHeader(&bare_buf, .binary, len);
        const read = headerFrom(bare).?;
        try testing.expectEqual(len, read.len);
        try testing.expectEqual(bare.len, read.size);
        try testing.expect(read.fin and !read.masked and read.wellFormed(.server));
        try testing.expectEqual(Opcode.binary, read.opcode);

        var key: [4]u8 = .{ 9, 8, 7, 6 };
        var masked_buf: [max_masked_header]u8 = undefined;
        const masked = writeMaskedHeader(&masked_buf, .text, len, key);
        const back = headerFrom(masked).?;
        try testing.expectEqual(len, back.len);
        try testing.expectEqual(masked.len, back.size);
        try testing.expectEqual(bare.len + 4, masked.len);
        try testing.expect(back.masked and back.wellFormed(.client));
        try testing.expectEqual(key, back.mask);
        key[0] = 0;
    }
}

test "a close payload carries a code and a reason, and the reason is cut on a character" {
    var buf: [max_control]u8 = undefined;
    const plain = closePayload(&buf, .normal, "bye");
    try testing.expectEqualSlices(u8, "\x03\xe8bye", plain);
    try testing.expect(closeIsWellFormed(plain));

    // 62 two-byte characters is 124 bytes, one more than fits beside a code.
    var long: [124]u8 = undefined;
    for (0..62) |i| long[i * 2 ..][0..2].* = "\xc3\xa9".*;
    const cut = closePayload(&buf, .going_away, &long);
    try testing.expectEqual(@as(usize, 2 + 122), cut.len);
    try testing.expect(closeIsWellFormed(cut));
}

test "a close payload is well formed only with a code the registry hands out" {
    try testing.expect(closeIsWellFormed(""));
    try testing.expect(!closeIsWellFormed("\x03"));
    try testing.expect(closeIsWellFormed("\x03\xe8"));
    // 1005 and 1006 are for the local end to report, never to send.
    try testing.expect(!closeIsWellFormed("\x03\xed"));
    try testing.expect(!closeIsWellFormed("\x03\xee"));
    try testing.expect(closeIsWellFormed("\x0b\xb8"));
    try testing.expect(!closeIsWellFormed("\x03\xe8\xff"));
}

test "the handshake answer is the one every client checks" {
    // The example from RFC 6455 §1.3, which every implementation is tested
    // against and which pins the salt, the hash and the encoding at once.
    const answer = accept("dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &answer);
}
