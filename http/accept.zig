//! What an `Accept` header says about one media type.
//!
//! One reader answering one question, because that is what the callers ask.
//! `static`'s single-page fallback needs to know whether a request could be a
//! navigation — a browser opening a URL puts `text/html` at the front of its
//! list, and a `<script src>` sends `*/*` — and that difference is what
//! separates answering a deep link from answering a missing asset with a page
//! (ADR 0109).
//!
//! Nothing is allocated and nothing is collected. The header is walked once
//! and what comes back is one of four answers about the one type the caller
//! named. A caller who wants the whole list in preference order wants a
//! different function, and nobody has needed one: content negotiation over
//! several offers is a separate feature and is not this.
//!
//! **Four answers rather than a `bool`, because a missing header is not a
//! refusal.** A client that says nothing has not asked for HTML and has not
//! ruled it out, and the two callers here treat those differently. Collapsing
//! them is what makes `*/*` from a `fetch()` look like a browser opening a
//! page, which is the bug ADR 0109 is about.
//!
//! Quality values are read only far enough to tell zero from anything else.
//! `q=0` is a refusal and is the one part of the grammar with an effect a
//! caller can observe here; ranking two types the caller did not ask about is
//! work with nothing to spend it on.

const std = @import("std");

/// What the header said about the type the caller named.
pub const Answer = enum {
    /// The header named this type, or its subtype wildcard (`text/*`), and
    /// did not give it `q=0`.
    named,
    /// The header said `*/*` and nothing more specific. Anything will do,
    /// this type included — which is what a `<script>`, an `<img>` and most
    /// of `fetch()` send.
    anything,
    /// There is no `Accept` header, or it is empty. The client expressed no
    /// preference at all.
    unsaid,
    /// The header named other types and not this one, or named this one with
    /// `q=0`.
    refused,
};

/// What `header` says about `kind`, which is a media type written out:
/// `"text/html"`, `"application/json"`.
///
/// The type is `comptime` because splitting it at the slash is then free and
/// because a caller asking about a type it assembled at run time has a
/// different problem than this function solves.
pub fn asks(header: ?[]const u8, comptime kind: []const u8) Answer {
    const slash = comptime std.mem.indexOfScalar(u8, kind, '/') orelse @compileError(
        "nilo: a media type is a type and a subtype with a slash between them, " ++
            "like \"text/html\" — got \"" ++ kind ++ "\"",
    );
    const wanted_type = comptime kind[0..slash];
    const wanted_sub = comptime kind[slash + 1 ..];
    comptime if (wanted_sub.len == 0 or std.mem.eql(u8, wanted_sub, "*")) @compileError(
        "nilo: asks() answers about one media type, so the subtype cannot be a " ++
            "wildcard — got \"" ++ kind ++ "\"",
    );

    const text = std.mem.trim(u8, header orelse return .unsaid, " \t");
    if (text.len == 0) return .unsaid;

    // The most specific entry that matches is the one that decides, which is
    // RFC 9110 §12.5.1's rule: `text/html;q=0` beside `*/*` is a refusal of
    // HTML and an acceptance of everything else.
    var best: u2 = 0;
    var best_q: u16 = 0;

    var entries = std.mem.splitScalar(u8, text, ',');
    while (entries.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (entry.len == 0) continue;

        const semi = std.mem.indexOfScalar(u8, entry, ';') orelse entry.len;
        const media = std.mem.trim(u8, entry[0..semi], " \t");
        const params = entry[@min(semi + 1, entry.len)..];

        const rank: u2 = rank: {
            if (eqlIgnoreCase(media, kind)) break :rank 3;
            if (media.len == wanted_type.len + 2 and
                media[media.len - 2] == '/' and media[media.len - 1] == '*' and
                eqlIgnoreCase(media[0..wanted_type.len], wanted_type)) break :rank 2;
            if (std.mem.eql(u8, media, "*/*")) break :rank 1;
            break :rank 0;
        };
        if (rank == 0) continue;

        const q = quality(params);
        // A second entry at the same specificity does not replace the first
        // unless it wants the type more, so `text/html;q=0, text/html` reads
        // as an acceptance. Nothing sends that; the rule is here so the walk
        // does not depend on which end it started from.
        if (rank > best or (rank == best and q > best_q)) {
            best = rank;
            best_q = q;
        }
    }

    if (best == 0) return .refused;
    if (best_q == 0) return .refused;
    return if (best == 1) .anything else .named;
}

/// The `q` in a media type's parameters, in thousandths. 1000 when there is
/// none, which is what the grammar says an unqualified entry means.
///
/// Only the distance from zero is ever read, so a malformed value is worth
/// no argument: anything that is not a number the grammar allows is treated
/// as the default rather than as a refusal, because refusing on a typo would
/// hide a page from a client that asked for one.
fn quality(params: []const u8) u16 {
    var rest = params;
    while (rest.len > 0) {
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const param = std.mem.trim(u8, rest[0..semi], " \t");
        rest = rest[@min(semi + 1, rest.len)..];

        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const name = std.mem.trim(u8, param[0..eq], " \t");
        if (name.len != 1 or (name[0] != 'q' and name[0] != 'Q')) continue;

        const value = std.mem.trim(u8, param[eq + 1 ..], " \t\"");
        return thousandths(value);
    }
    return 1000;
}

/// `"0"`, `"0.5"`, `"1"`, `"1.000"` → 0, 500, 1000, 1000.
fn thousandths(text: []const u8) u16 {
    if (text.len == 0) return 1000;
    if (text[0] != '0' and text[0] != '1') return 1000;

    var out: u16 = if (text[0] == '1') 1000 else 0;
    if (text.len == 1 or text[1] != '.') return out;

    var place: u16 = 100;
    for (text[2..]) |byte| {
        if (place == 0) break;
        if (byte < '0' or byte > '9') return 1000;
        out += @as(u16, byte - '0') * place;
        place /= 10;
    }
    return @min(out, 1000);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

const testing = std.testing;

test "a browser opening a page names text/html" {
    const chrome = "text/html,application/xhtml+xml,application/xml;q=0.9," ++
        "image/avif,image/webp,image/apng,*/*;q=0.8";
    try testing.expectEqual(Answer.named, asks(chrome, "text/html"));
}

test "a script tag asking for anything is not asking for html" {
    try testing.expectEqual(Answer.anything, asks("*/*", "text/html"));
}

test "a request with no Accept header has said nothing either way" {
    try testing.expectEqual(Answer.unsaid, asks(null, "text/html"));
    try testing.expectEqual(Answer.unsaid, asks("", "text/html"));
    try testing.expectEqual(Answer.unsaid, asks("   ", "text/html"));
}

test "a client that asked for JSON has refused html" {
    try testing.expectEqual(Answer.refused, asks("application/json", "text/html"));
    try testing.expectEqual(Answer.named, asks("application/json", "application/json"));
}

test "a subtype wildcard names the type" {
    try testing.expectEqual(Answer.named, asks("text/*", "text/html"));
    try testing.expectEqual(Answer.refused, asks("image/*", "text/html"));
}

test "the most specific entry decides, so html at q=0 beside a wildcard is a refusal" {
    try testing.expectEqual(Answer.refused, asks("text/html;q=0, */*", "text/html"));
    try testing.expectEqual(Answer.anything, asks("text/html;q=0, */*", "application/json"));
}

test "a quality of zero on the wildcard refuses everything it covered" {
    try testing.expectEqual(Answer.refused, asks("*/*;q=0", "text/html"));
}

test "the type is matched without regard to case, which is what a header is" {
    try testing.expectEqual(Answer.named, asks("TEXT/HTML", "text/html"));
    try testing.expectEqual(Answer.named, asks("Text/Html;Q=0.9", "text/html"));
}

test "whitespace and empty entries are walked past" {
    try testing.expectEqual(Answer.named, asks("  , text/html ; q=0.9 ,, */*;q=0.1", "text/html"));
}

test "a malformed quality is the default rather than a refusal" {
    try testing.expectEqual(Answer.named, asks("text/html;q=banana", "text/html"));
    try testing.expectEqual(Answer.named, asks("text/html;q=", "text/html"));
}

test "a parameter that is not q is walked past" {
    try testing.expectEqual(Answer.named, asks("text/html;level=1;q=0.5", "text/html"));
    try testing.expectEqual(Answer.refused, asks("text/html;level=1;q=0", "text/html"));
}

test "quality is read as thousandths, and only zero changes an answer" {
    try testing.expectEqual(@as(u16, 0), thousandths("0"));
    try testing.expectEqual(@as(u16, 0), thousandths("0.000"));
    try testing.expectEqual(@as(u16, 1), thousandths("0.001"));
    try testing.expectEqual(@as(u16, 500), thousandths("0.5"));
    try testing.expectEqual(@as(u16, 1000), thousandths("1"));
    try testing.expectEqual(@as(u16, 1000), thousandths("1.000"));
}
