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
/// A type missing from here is not a bug that hides: it prints its file name,
/// which is wrong in the same visible way `str.Str` was. `refusals/` is where
/// that gets noticed.
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
    .{ "typed.Headers", "nilo.Headers" },
    .{ "typed.Header", "nilo.Header" },
    .{ "http1.Header", "nilo.Header" },
    .{ "http1.Method", "nilo.Method" },
    .{ "patch.Patch", "nilo.Patch" },
    .{ "middleware.Middleware", "nilo.Middleware" },
    .{ "middleware.Next", "nilo.Next" },
    .{ "bulkhead.Mutex", "nilo.Mutex" },
    .{ "fail.Failure", "nilo.Failure" },
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
        // than being a number that happened to be enough once.
        @setEvalBranchQuota(64 * (name.len + 1) + 4_000);
        var out: []const u8 = name;
        for (ours) |pair| {
            if (std.mem.indexOf(u8, out, pair[0]) == null) continue;
            out = replaced(out, pair[0], pair[1]);
        }
        return out;
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

test "the same name twice is rewritten twice" {
    try testing.expectEqualStrings(
        "main.Pair(nilo.Str,nilo.Str)",
        comptime textOf("main.Pair(str.Str,str.Str)"),
    );
}
