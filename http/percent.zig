//! Percent-decoding for path params and query values.
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

const std = @import("std");

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
