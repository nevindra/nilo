//! Percent-encoding and -decoding, RFC 3986.
//!
//! **This is in Core because two layers need it**
//! ([ADR 0066](../docs/adr/0066-percent-is-needed-by-two-layers.md)). The App
//! layer decodes: every path param and every query value goes through here on
//! the way in. A Service encodes: signing a URL is a canonical form built out
//! of escaped pieces. A Service may not import `nilo_http` — that is sideways,
//! and `zig build layering` refuses it — so an encoder written up there would
//! have been a second encoder written down here instead.
//!
//! It is the easier half of the question `convert.zig` is still waiting on
//! (roadmap, *Where `convert` belongs*), and it does not answer it. What has
//! kept that file in the App layer is that it reaches the Bulkhead to say a
//! request failed. **Neither direction here can fail**: an encoder has nothing
//! to reject, and the decoder is written not to. There is no failure to hand
//! upward, so this move settles nothing about `convert`.
//!
//! ## Decoding
//!
//! **When this runs matters more than how.** Decoding happens *after* the
//! router has matched, never before: `%2F` decodes to `/`, so decoding the
//! target first would turn `/files/a%2Fb` into three segments and let a
//! request reach a route it does not actually name. Matching on the raw
//! path and decoding each captured value on its own keeps an encoded slash
//! as what the client meant it to be — one character of data.
//!
//! A `%` that is not followed by two hex digits is left as a literal `%`
//! rather than rejected. Servers that are strict here mostly succeed at
//! turning a harmless URL into a 400.
//!
//! ## Encoding
//!
//! Two of the rules are behaviour rather than options, because the failure
//! each one prevents is silent:
//!
//! - **A space is always `%20` and never `+`.** The `+` convention belongs to
//!   HTML form bodies, which this direction does not write; a signature
//!   computed over `+` where the service expected `%20` is rejected with no
//!   hint as to which byte did it. There is no parameter here that can produce
//!   a `+`, which is the point — a caller cannot reach the wrong answer.
//! - **Hex digits are uppercase.** `%2f` is the same character to a decoder
//!   and a different string to anything that signs one. Same reasoning: not a
//!   parameter. A caller in `http/` that wants lowercase is a new decision with
//!   an argument of its own.
//!
//! One thing does vary, and it is the only character whose meaning depends on
//! where it sits: whether `/` is a separator or data. That is `Set`.
//!
//! **A path is encoded once.** Some AWS services build a canonical URI by
//! encoding it twice and S3 does not. That is a trap for whoever is signing
//! rather than for this file, and it is written here because here is where
//! they will be reading.
//!
//! There is no allocating encoder, because no caller wants one. `decode` has
//! one because the request path decodes into an arena it does not own the
//! sizing of; whoever encodes is assembling a canonical string into a buffer
//! it has already measured, or writing it straight out.

const std = @import("std");

// ---- decoding ----

/// Whether `raw` has anything to decode. The common case — it does not —
/// answers in one scan and allocates nothing.
pub fn needed(raw: []const u8, plus_as_space: bool) bool {
    return scan(raw, plus_as_space).anything;
}

/// What one pass over `raw` learns: whether there is anything to do at all,
/// and how long the result will be if there is.
const Shape = struct {
    anything: bool,
    decoded_len: usize,
};

/// The single pass the three questions below used to take three of. Deciding
/// whether to decode, measuring the result and decoding it were a scan each,
/// and the first two are the same walk.
fn scan(raw: []const u8, plus_as_space: bool) Shape {
    var escapes: usize = 0;
    var plus = false;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '%' and escapeAt(raw, i) != null) {
            escapes += 1;
            i += 3;
            continue;
        }
        if (plus_as_space and raw[i] == '+') plus = true;
        i += 1;
    }
    return .{
        .anything = escapes > 0 or plus,
        // Each escape is three bytes in and one out.
        .decoded_len = raw.len - escapes * 2,
    };
}

/// The decoded form of `raw`, allocated from `gpa` only when there is
/// something to decode; otherwise `raw` is handed straight back.
///
/// `plus_as_space` is for query values: `?q=a+b` means "a b" because HTML
/// forms have encoded it that way since 1995. It must stay off for path
/// params, where a `+` is a plain `+`.
pub fn decode(gpa: std.mem.Allocator, raw: []const u8, plus_as_space: bool) ![]const u8 {
    const shape = scan(raw, plus_as_space);
    if (!shape.anything) return raw;
    // Sized from the pass that has just been made, so the allocation is
    // exactly right: a buffer freed at a different length than it was taken at
    // is a bug the debug allocator catches and a release one does not.
    const buf = try gpa.alloc(u8, shape.decoded_len);
    return decodeInto(buf, raw, plus_as_space);
}

/// How many bytes `raw` decodes to. A `+` is one byte either way, so
/// `plus_as_space` does not come into it.
pub fn decodedLen(raw: []const u8) usize {
    return scan(raw, false).decoded_len;
}

/// The byte a `%XX` at `i` stands for, or null if there is no complete
/// escape there.
fn escapeAt(raw: []const u8, i: usize) ?u8 {
    if (raw[i] != '%' or i + 2 >= raw.len) return null;
    const hi = hex(raw[i + 1]) orelse return null;
    const lo = hex(raw[i + 2]) orelse return null;
    return hi << 4 | lo;
}

/// Decode into a caller-supplied buffer of at least `raw.len` bytes, and
/// return the part of it that was used.
pub fn decodeInto(dst: []u8, raw: []const u8, plus_as_space: bool) []u8 {
    std.debug.assert(dst.len >= decodedLen(raw));
    var w: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (w += 1) {
        if (escapeAt(raw, i)) |byte| {
            dst[w] = byte;
            i += 3;
        } else {
            dst[w] = if (plus_as_space and raw[i] == '+') ' ' else raw[i];
            i += 1;
        }
    }
    return dst[0..w];
}

fn hex(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

// ---- encoding ----

/// Which characters survive as themselves. Everything else becomes `%XX`.
///
/// Both sets start from RFC 3986's *unreserved* set — `A-Z`, `a-z`, `0-9`,
/// `-`, `.`, `_`, `~` — and differ over `/` alone. Note what is **not** in
/// there: `!`, `*`, `'`, `(` and `)` are reserved and get escaped, which is
/// the difference between this and the `encodeURIComponent` a caller may be
/// arriving from.
pub const Set = enum {
    /// `/` is data and becomes `%2F`. What a query value wants, and what a
    /// canonical query string is built out of: a slash inside a value is a
    /// character somebody typed rather than structure.
    unreserved,
    /// `/` is a separator and stays as it is. What a path wants, and what
    /// SigV4 calls a canonical URI.
    path,
};

fn safe(ch: u8, set: Set) bool {
    return switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        '/' => set == .path,
        else => false,
    };
}

/// Uppercase, and not an option — see the header.
const upper_hex = "0123456789ABCDEF";

/// How many bytes `raw` encodes to. Every byte becomes one or three, so this
/// is a count rather than an estimate and a caller can size exactly.
pub fn encodedLen(raw: []const u8, set: Set) usize {
    var escapes: usize = 0;
    for (raw) |ch| {
        if (!safe(ch, set)) escapes += 1;
    }
    // Each escape is one byte in and three out.
    return raw.len + escapes * 2;
}

/// Encode into a caller-supplied buffer of at least `encodedLen` bytes, and
/// return the part of it that was used.
pub fn encodeInto(dst: []u8, raw: []const u8, set: Set) []u8 {
    std.debug.assert(dst.len >= encodedLen(raw, set));
    var w: usize = 0;
    for (raw) |ch| {
        if (safe(ch, set)) {
            dst[w] = ch;
            w += 1;
        } else {
            dst[w] = '%';
            dst[w + 1] = upper_hex[ch >> 4];
            dst[w + 2] = upper_hex[ch & 0xf];
            w += 3;
        }
    }
    return dst[0..w];
}

/// Encode straight out, for a caller assembling something longer a piece at a
/// time — a canonical request, a URL being built. It saves the measuring pass
/// and the buffer in between, which is why it is here rather than an
/// allocating encoder. A run of characters that need no escape goes out in one
/// call rather than one per byte.
pub fn encodeWrite(w: *std.Io.Writer, raw: []const u8, set: Set) std.Io.Writer.Error!void {
    var at: usize = 0;
    for (raw, 0..) |ch, i| {
        if (safe(ch, set)) continue;
        try w.writeAll(raw[at..i]);
        try w.writeAll(&[_]u8{ '%', upper_hex[ch >> 4], upper_hex[ch & 0xf] });
        at = i + 1;
    }
    try w.writeAll(raw[at..]);
}

const testing = std.testing;

fn decoded(raw: []const u8, plus_as_space: bool) ![]const u8 {
    return decode(testing.allocator, raw, plus_as_space);
}

test "text with nothing to decode is handed back untouched" {
    const raw = "wati";
    const out = try decoded(raw, true);
    try testing.expect(out.ptr == raw.ptr); // the same bytes, not a copy
}

test "percent escapes become their bytes" {
    const out = try decoded("wati%20sari", false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("wati sari", out);

    const utf8 = try decoded("caf%C3%A9", false);
    defer testing.allocator.free(utf8);
    try testing.expectEqualStrings("café", utf8);

    const lower = try decoded("%2f%3F%26", false);
    defer testing.allocator.free(lower);
    try testing.expectEqualStrings("/?&", lower);
}

test "plus is a space in a query and a plus in a path" {
    const query = try decoded("a+b", true);
    defer testing.allocator.free(query);
    try testing.expectEqualStrings("a b", query);

    // Nothing to do at all, so the same bytes come back.
    const path = "a+b";
    try testing.expect((try decoded(path, false)).ptr == path.ptr);
}

test "a broken escape stays literal rather than becoming a 400" {
    // And costs nothing: a `%` that is not the start of a real escape leaves
    // nothing to decode, so the same bytes come back rather than a copy of
    // them. `needed` used to say yes to any `%` at all and hand back an
    // identical copy — correct, and an allocation for no reason on a URL with
    // a stray percent sign in it.
    for ([_][]const u8{ "100%", "50%2", "%zz", "%2", "%" }) |raw| {
        try testing.expect(!needed(raw, false));
        const out = try decoded(raw, false);
        try testing.expectEqual(raw.ptr, out.ptr);
        try testing.expectEqualStrings(raw, out);
    }

    // Broken and valid together: only the valid one decodes, and that one does
    // need a buffer of its own.
    const both = try decoded("%zz%20", false);
    defer testing.allocator.free(both);
    try testing.expectEqualStrings("%zz ", both);
}

test "an encoded slash survives as data" {
    // The reason decoding happens after routing: had this run first, the
    // router would have seen two segments where the client sent one.
    const out = try decoded("a%2Fb", false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a/b", out);
}

test "a slash is a separator in a path and a character in a query" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("a/b", encodeInto(&buf, "a/b", .path));
    try testing.expectEqualStrings("a%2Fb", encodeInto(&buf, "a/b", .unreserved));
}

test "an escape is uppercase, because what it would break says nothing" {
    // `%2f` decodes to the same character and signs to a different string, so
    // the failure it causes arrives as a rejected signature with no clue in it.
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("%2F%3F%26", encodeInto(&buf, "/?&", .unreserved));
    try testing.expectEqualStrings("caf%C3%A9", encodeInto(&buf, "café", .path));
}

test "a space is an escape and never a plus" {
    // The `+` this file decodes on the way in has no encoder on the way out,
    // and that is deliberate: there is no argument that produces one.
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("a%20b", encodeInto(&buf, "a b", .path));
    try testing.expectEqualStrings("a%20b", encodeInto(&buf, "a b", .unreserved));
    try testing.expectEqualStrings("a%2Bb", encodeInto(&buf, "a+b", .path));
}

test "the unreserved set is four punctuation marks and no others" {
    var buf: [64]u8 = undefined;
    const survives = "AZaz09-._~";
    try testing.expectEqualStrings(survives, encodeInto(&buf, survives, .unreserved));
    // The ones a caller arriving from `encodeURIComponent` expects to survive
    // and that RFC 3986 does not spare.
    try testing.expectEqualStrings("%21%2A%27%28%29", encodeInto(&buf, "!*'()", .unreserved));
}

test "every byte survives being encoded and decoded" {
    for ([_]Set{ .unreserved, .path }) |set| {
        var byte: u8 = 0;
        while (true) : (byte += 1) {
            const raw = [_]u8{byte};

            var encoded_buf: [3]u8 = undefined;
            const encoded = encodeInto(&encoded_buf, &raw, set);
            // The measured length is the written length, so a caller sizing a
            // buffer from `encodedLen` cannot be one byte short.
            try testing.expectEqual(encodedLen(&raw, set), encoded.len);

            var decoded_buf: [3]u8 = undefined;
            try testing.expectEqualStrings(&raw, decodeInto(&decoded_buf, encoded, false));

            if (byte == 255) break;
        }
    }
}

test "writing an encoded value out matches encoding it into a buffer" {
    const raw = "wati sari/caf%C3%A9?a=b&c=d+e";
    for ([_]Set{ .unreserved, .path }) |set| {
        var into: [128]u8 = undefined;
        const expected = encodeInto(&into, raw, set);

        var out: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&out);
        try encodeWrite(&w, raw, set);
        try testing.expectEqualStrings(expected, w.buffered());
    }
}
