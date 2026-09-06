//! base64url, the way a JWT spells it: `-` and `_` for the last two
//! characters, and no `=` on the end.
//!
//! Padding is not part of the encoding a JWT uses, and this accepts it
//! anyway. Not out of generosity — a token that arrived with padding is a
//! token some other library produced, and refusing it here would send the
//! reader looking for a bug in their signature rather than in their encoder.
//! What is *not* accepted is the standard alphabet: `+` and `/` in a segment
//! mean the producer used base64 rather than base64url, and quietly decoding
//! it would make a signature check pass on bytes the issuer never signed.

const std = @import("std");

pub const Error = error{NotBase64Url};

/// How many bytes `decode` will write. This answers from the *length* alone:
/// the alphabet is checked by `decode`, which is where a standard-base64
/// segment is caught.
pub fn sizeOf(text: []const u8) Error!usize {
    const trimmed = std.mem.trimEnd(u8, text, "=");
    return std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(trimmed) catch
        return error.NotBase64Url;
}

/// `out` has to be `sizeOf(text)` bytes.
pub fn decode(out: []u8, text: []const u8) Error!void {
    const trimmed = std.mem.trimEnd(u8, text, "=");
    std.base64.url_safe_no_pad.Decoder.decode(out, trimmed) catch return error.NotBase64Url;
}

/// The two together, onto `gpa`. The caller frees it.
pub fn keep(gpa: std.mem.Allocator, text: []const u8) (Error || error{OutOfMemory})![]u8 {
    const out = try gpa.alloc(u8, try sizeOf(text));
    errdefer gpa.free(out);
    try decode(out, text);
    return out;
}

test "the url alphabet decodes and the standard one does not" {
    const gpa = std.testing.allocator;

    // 0xfb 0xff encodes as "-_8" in url-safe and "+/8" in standard.
    const url = try keep(gpa, "-_8");
    defer gpa.free(url);
    try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0xff }, url);

    try std.testing.expectError(error.NotBase64Url, keep(gpa, "+/8"));
}

test "padding a JWT should not have is accepted rather than argued with" {
    const gpa = std.testing.allocator;
    const padded = try keep(gpa, "AQAB");
    defer gpa.free(padded);
    const unpadded = try keep(gpa, "AQAB");
    defer gpa.free(unpadded);
    try std.testing.expectEqualSlices(u8, unpadded, padded);

    const with_pad = try keep(gpa, "-_8=");
    defer gpa.free(with_pad);
    try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0xff }, with_pad);
}

test "a segment that is not base64 at all is refused" {
    // `sizeOf` answers from the length, so this is `decode`'s refusal.
    try std.testing.expectError(error.NotBase64Url, keep(std.testing.allocator, "!!!!"));
    // A length no base64 string can have, which `sizeOf` does catch.
    try std.testing.expectError(error.NotBase64Url, sizeOf("A"));
}
