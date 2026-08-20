//! The name of a type as the person reading the message knows it.
//!
//! `@typeName` spells a type with the file it was declared in, and nilo's
//! files are not files anybody using nilo has opened. A resolver that handed
//! back the wrong type was told it returned `str.Str` — a true sentence about
//! a source tree the reader does not have, and one that sends them looking
//! for a `str` they never imported. Their import line says `nilo`, so that
//! is the name the message uses.
//!
//! Only nilo's own types are rewritten. A type of the reader's own already
//! carries the name of the file they wrote it in, which is exactly where they
//! want to be sent.

const std = @import("std");

/// Every nilo type a message can print, under the name `nilo.zig` exports
/// it by. A generic is listed without its parentheses so that
/// `typed.Response([]const u8)` comes out as `nilo.Response([]const u8)`.
///
/// A type missing from here prints its file name, which is wrong in the same
/// visible way `str.Str` was. **What notices is a test in `http.zig`** that
/// walks every type the module exports and fails on any this table does not
/// cover (ADR 0095).
///
/// That used to say `refusals/` was where it got noticed, and it was not: the
/// table had fallen fifteen types behind the exports and no refusal had ever
/// been written against any of them. A refusal proves one message is right and
/// says nothing about the ones nobody thought of.
const ours = [_][2][]const u8{
    .{ "str.Str", "nilo.Str" },
    .{ "ctx.Ctx", "nilo.Ctx" },
    .{ "app.App", "nilo.App" },
    .{ "app.Group", "nilo.Group" },
    .{ "typed.Response", "nilo.Response" },
    .{ "typed.Status", "nilo.Status" },
    .{ "typed.Query", "nilo.Query" },
    .{ "form.Form", "nilo.Form" },
    .{ "form.Upload", "nilo.Upload" },
    .{ "redirect.Redirect", "nilo.Redirect" },
    .{ "cookie.Cookie", "nilo.Cookie" },
    .{ "cookie.SameSite", "nilo.SameSite" },
    .{ "typed.Headers", "nilo.Headers" },
    .{ "typed.Header", "nilo.Header" },
    .{ "http1.Header", "nilo.Header" },
    .{ "http1.Method", "nilo.Method" },
    .{ "patch.Patch", "nilo.Patch" },
    .{ "middleware.Middleware", "nilo.Middleware" },
    .{ "middleware.Next", "nilo.Next" },
    .{ "bulkhead.Mutex", "nilo.Mutex" },
    .{ "bulkhead.Gate", "nilo.Gate" },
    .{ "bulkhead.Options", "nilo.Options" },
    .{ "bulkhead.Dir", "nilo.Dir" },
    .{ "limits.Limits", "nilo.Limits" },
    .{ "scope.Scope", "nilo.Scope" },
    .{ "scope.Run", "nilo.Run" },
    .{ "fail.Failure", "nilo.Failure" },
    .{ "bound.Bound", "nilo.Bound" },
    .{ "session.Session", "nilo.Session" },
    .{ "filebody.FileBody", "nilo.FileBody" },
    .{ "stream.Stream", "nilo.Stream" },
    .{ "stream.Events", "nilo.Events" },
    .{ "stream.Event", "nilo.Event" },
    .{ "body.Body", "nilo.Body" },
    .{ "websocket.Socket", "nilo.Socket" },
    .{ "room.Room", "nilo.Room" },
};

/// What to call `T` in a message. Every type name nilo's own compile errors
/// print goes through here.
pub fn of(comptime T: type) []const u8 {
    return textOf(@typeName(T));
}

/// The same, for a name already in hand.
pub fn textOf(comptime name: []const u8) []const u8 {
    comptime {
        // A generic's name carries its arguments, so the string being walked
        // is as long as the type is nested. The quota tracks the input rather
        // than being a number that happened to be enough once — **and the
        // table, which is the half it used to miss.** Every row scans the whole
        // name, so the work is length times rows; growing `ours` from 20 to 35
        // (ADR 0095) broke callers in three files that had not changed a
        // character, with the failure landing inside `std.mem` where nothing
        // names this one.
        @setEvalBranchQuota(64 * (name.len + 1) * ours.len + 8_000);
        var out: []const u8 = name;
        for (ours) |pair| {
            if (std.mem.indexOf(u8, out, pair[0]) == null) continue;
            out = replaced(out, pair[0], pair[1]);
        }
        return out;
    }
}

/// Whether this table rewrites `name` at all.
///
/// The question `http.zig`'s suite asks of every type it exports, and it is a
/// separate entry point because asking it through `textOf` means paying for the
/// rewrite — a fresh concatenated string per replacement, once per export,
/// which runs the comptime branch budget out well before the module does
/// (ADR 0095).
///
/// **The caller owns the branch budget.** Unlike `textOf` this sets none of its
/// own: it is called once per export in a single `inline for`, and a per-call
/// quota sized for one short name lowers a budget the walk has already spent.
pub fn covers(comptime name: []const u8) bool {
    comptime {
        for (ours) |pair| {
            if (std.mem.indexOf(u8, name, pair[0]) != null) return true;
        }
        return false;
    }
}

fn replaced(comptime in: []const u8, comptime from: []const u8, comptime to: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var rest: []const u8 = in;
        while (std.mem.indexOf(u8, rest, from)) |at| {
            out = out ++ rest[0..at] ++ to;
            rest = rest[at + from.len ..];
        }
        return out ++ rest;
    }
}

const testing = std.testing;

test "a nilo type is named the way the import line names it" {
    try testing.expectEqualStrings("nilo.Str", comptime textOf("str.Str"));
    try testing.expectEqualStrings("nilo.Ctx", comptime textOf("ctx.Ctx"));
}

test "a name is rewritten wherever it appears, not only at the front" {
    try testing.expectEqualStrings("[]nilo.Header", comptime textOf("[]http1.Header"));
    try testing.expectEqualStrings(
        "nilo.Response([]const u8)",
        comptime textOf("typed.Response([]const u8)"),
    );
    try testing.expectEqualStrings(
        "nilo.Patch(nilo.Str)",
        comptime textOf("patch.Patch(str.Str)"),
    );
}

test "a type of the reader's own is left where they wrote it" {
    try testing.expectEqualStrings("main.Order", comptime textOf("main.Order"));
    try testing.expectEqualStrings("u32", comptime textOf("u32"));
    // The file is theirs even when the type inside it is not.
    try testing.expectEqualStrings(
        "main.Page(nilo.Str)",
        comptime textOf("main.Page(str.Str)"),
    );
}

test "covers answers for exactly the names textOf would rewrite" {
    // `covers` sets no quota of its own, so a caller that asks it many times
    // sets one — which is the whole of what "the caller owns the budget" costs.
    @setEvalBranchQuota(50_000);
    try testing.expect(comptime covers("str.Str"));
    try testing.expect(comptime covers("[]http1.Header"));
    try testing.expect(comptime covers("main.Page(str.Str)"));
    try testing.expect(!comptime covers("main.Order"));
    try testing.expect(!comptime covers("u32"));
    // The fifteen that were missing. Listed by hand here as well as walked by
    // `http.zig`'s test, because this is the file somebody edits when they add
    // a row and the assertion should be next to the table (ADR 0095).
    inline for ([_][]const u8{
        "bound.Bound",      "session.Session", "filebody.FileBody",
        "bulkhead.Dir",     "stream.Stream",   "stream.Events",
        "stream.Event",     "body.Body",       "websocket.Socket",
        "room.Room",        "limits.Limits",   "bulkhead.Gate",
        "bulkhead.Options", "scope.Run",       "cookie.SameSite",
    }) |name| {
        try testing.expect(comptime covers(name));
    }
}

test "the same name twice is rewritten twice" {
    try testing.expectEqualStrings(
        "main.Pair(nilo.Str,nilo.Str)",
        comptime textOf("main.Pair(str.Str,str.Str)"),
    );
}
