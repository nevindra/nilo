//! `Range: bytes=…` — asking for part of a file rather than all of it.
//!
//! What it is for is a video being scrubbed, an audio file being seeked, and
//! a download being resumed. A file is already in memory (ADR 0010), so
//! answering one is a slice and two headers; all the work is in reading the
//! header correctly, and in refusing to guess when it does not make sense.
//!
//! RFC 9110 §14 is unusually forgiving here, and this leans on that: a
//! `Range` that cannot be understood **is ignored**, and the whole file goes
//! out with a 200. That is a correct answer to every request, which is why
//! nothing in this file returns an error.

const std = @import("std");

/// What to do about the `Range` header on a request.
pub const Answer = union(enum) {
    /// Send the whole file, 200. No `Range`, or one there is no sense to be
    /// made of, or one asking for more pieces than zfast will assemble.
    whole,
    /// Send `part`, 206, with a `Content-Range`.
    part: Part,
    /// 416, with a `Content-Range` naming the size the client got wrong.
    unsatisfiable,
};

/// A half-open-in-HTTP's-sense range: both ends included, as the header
/// writes them.
pub const Part = struct {
    start: u64,
    /// Included, so a one-byte range has `start == last`.
    last: u64,

    pub fn len(self: Part) u64 {
        return self.last - self.start + 1;
    }

    pub fn slice(self: Part, bytes: []const u8) []const u8 {
        const from: usize = @intCast(self.start);
        const to: usize = @intCast(self.last + 1);
        return bytes[from..to];
    }
};

/// Read a `Range` header against a file of `total` bytes.
///
/// `if_range` is the `If-Range` header, which means "only honour my range if
/// the file is still the one I started with". Comparing it to the file's
/// ETag is the caller's job — pass the result.
pub fn parse(header: ?[]const u8, total: u64, if_range_matches: bool) Answer {
    const raw = header orelse return .whole;
    if (!if_range_matches) return .whole;

    // `bytes` is the only unit anybody implements, and a unit zfast does not
    // know is a request to ignore the header rather than to fail.
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return .whole;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw[0..eq], " \t"), "bytes")) return .whole;

    const list = std.mem.trim(u8, raw[eq + 1 ..], " \t");
    if (list.len == 0) return .whole;

    // More than one range is legal and wants a `multipart/byteranges` body.
    // Nothing sends it — a browser scrubbing a video sends one — and
    // assembling one is a body format's worth of code for a case that does
    // not arrive. Ignoring the header and sending the whole file is a
    // correct answer, so that is what happens.
    if (std.mem.indexOfScalar(u8, list, ',') != null) return .whole;

    // A file with no bytes has no part of it to send, and `bytes */0` is not
    // something to say to anybody.
    if (total == 0) return .whole;

    const dash = std.mem.indexOfScalar(u8, list, '-') orelse return .whole;
    const before = std.mem.trim(u8, list[0..dash], " \t");
    const after = std.mem.trim(u8, list[dash + 1 ..], " \t");

    if (before.len == 0) {
        // `-500`: the last 500 bytes. Asking for the last zero bytes is the
        // one suffix form that means nothing, and the RFC says 416.
        const wanted = number(after) orelse return .whole;
        if (wanted == 0) return .unsatisfiable;
        const from = if (wanted >= total) 0 else total - wanted;
        return .{ .part = .{ .start = from, .last = total - 1 } };
    }

    const start = number(before) orelse return .whole;
    // Past the end of the file is the one thing worth a 416: the client has
    // the wrong idea about how big this is, and telling it so is useful.
    if (start >= total) return .unsatisfiable;

    if (after.len == 0) return .{ .part = .{ .start = start, .last = total - 1 } };

    const last = number(after) orelse return .whole;
    if (last < start) return .whole;
    return .{ .part = .{ .start = start, .last = @min(last, total - 1) } };
}

/// A digits-only number. `std.fmt.parseInt` would accept `+5`, `-5` and
/// `0x10`, none of which a range is allowed to be.
fn number(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// `bytes 0-99/1000` — the `Content-Range` of a 206.
pub fn contentRange(buf: []u8, part: Part, total: u64) []const u8 {
    return std.fmt.bufPrint(buf, "bytes {d}-{d}/{d}", .{ part.start, part.last, total }) catch
        unreachable; // the longest this can be is three u64s and five bytes
}

/// `bytes */1000` — the `Content-Range` of a 416, which carries no range at
/// all and exists only to say how big the file actually is.
pub fn unsatisfiableRange(buf: []u8, total: u64) []const u8 {
    return std.fmt.bufPrint(buf, "bytes */{d}", .{total}) catch unreachable;
}

/// The longest either of the two above can be: `bytes ` plus three 20-digit
/// numbers plus two separators.
pub const max_content_range = 6 + 20 * 3 + 2;

// ---- tests ----

const testing = std.testing;

fn wants(header: ?[]const u8, total: u64) Answer {
    return parse(header, total, true);
}

test "no Range header means the whole file" {
    try testing.expectEqual(Answer.whole, wants(null, 1000));
}

test "a range with both ends" {
    const answer = wants("bytes=0-99", 1000);
    try testing.expectEqual(@as(u64, 0), answer.part.start);
    try testing.expectEqual(@as(u64, 99), answer.part.last);
    try testing.expectEqual(@as(u64, 100), answer.part.len());
}

test "an open-ended range runs to the end of the file" {
    const answer = wants("bytes=900-", 1000);
    try testing.expectEqual(@as(u64, 900), answer.part.start);
    try testing.expectEqual(@as(u64, 999), answer.part.last);
}

test "a suffix range counts back from the end" {
    const answer = wants("bytes=-500", 1000);
    try testing.expectEqual(@as(u64, 500), answer.part.start);
    try testing.expectEqual(@as(u64, 999), answer.part.last);
}

test "a suffix bigger than the file is the whole file, as a range" {
    // Still a 206 rather than a 200: the client asked for a range and this
    // is the range it asked for, all of which happens to exist.
    const answer = wants("bytes=-5000", 1000);
    try testing.expectEqual(@as(u64, 0), answer.part.start);
    try testing.expectEqual(@as(u64, 999), answer.part.last);
}

test "an end past the file is clamped rather than refused" {
    const answer = wants("bytes=990-5000", 1000);
    try testing.expectEqual(@as(u64, 990), answer.part.start);
    try testing.expectEqual(@as(u64, 999), answer.part.last);
}

test "one byte" {
    const answer = wants("bytes=7-7", 1000);
    try testing.expectEqual(@as(u64, 1), answer.part.len());
    try testing.expectEqualStrings("h", answer.part.slice("abcdefghij"));
}

test "a start past the end of the file is the one thing worth a 416" {
    try testing.expectEqual(Answer.unsatisfiable, wants("bytes=1000-", 1000));
    try testing.expectEqual(Answer.unsatisfiable, wants("bytes=2000-3000", 1000));
    // The last zero bytes of anything.
    try testing.expectEqual(Answer.unsatisfiable, wants("bytes=-0", 1000));
}

test "anything that cannot be understood is ignored, and the whole file goes out" {
    const nonsense = [_][]const u8{
        "bytes=abc-def", // not numbers
        "bytes=0x10-",   // not decimal
        "bytes=+5-10",   // not digits
        "bytes=99-10",   // backwards
        "items=0-99",    // a unit nobody has
        "bytes=",        // nothing asked for
        "0-99",          // no unit at all
        "bytes 0-99",    // no `=`
    };
    for (nonsense) |header| {
        try testing.expectEqual(Answer.whole, wants(header, 1000));
    }
}

test "more than one range is ignored, because zfast does not assemble multipart" {
    try testing.expectEqual(Answer.whole, wants("bytes=0-99,200-299", 1000));
}

test "a file with no bytes has no range worth talking about" {
    try testing.expectEqual(Answer.whole, wants("bytes=0-99", 0));
    try testing.expectEqual(Answer.whole, wants("bytes=-1", 0));
}

test "If-Range not matching means the file changed, so send all of it" {
    // The client is resuming a download of something that is no longer what
    // it was. Byte 900 of the new file is not byte 900 of the old one.
    try testing.expectEqual(Answer.whole, parse("bytes=900-", 1000, false));
}

test "whitespace around the parts is tolerated" {
    const answer = wants("bytes = 10 - 19 ", 1000);
    try testing.expectEqual(@as(u64, 10), answer.part.start);
    try testing.expectEqual(@as(u64, 19), answer.part.last);
}

test "the Content-Range headers say what they should" {
    var buf: [max_content_range]u8 = undefined;
    try testing.expectEqualStrings(
        "bytes 0-99/1000",
        contentRange(&buf, .{ .start = 0, .last = 99 }, 1000),
    );
    try testing.expectEqualStrings("bytes */1000", unsatisfiableRange(&buf, 1000));
}
