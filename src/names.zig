//! The name of a type as the person reading the message knows it.
//!
//! `@typeName` spells a type with the file it was declared in, and zfast's
//! files are not files anybody using zfast has opened. A resolver that handed
//! back the wrong type was told it returned `str.Str` — a true sentence about
//! a source tree the reader does not have, and one that sends them looking
//! for a `str` they never imported. Their import line says `zfast`, so that
//! is the name the message uses.
//!
//! Only zfast's own types are rewritten. A type of the reader's own already
//! carries the name of the file they wrote it in, which is exactly where they
//! want to be sent.

const std = @import("std");

/// Every zfast type a message can print, under the name `zfast.zig` exports
/// it by. A generic is listed without its parentheses so that
/// `typed.Response([]const u8)` comes out as `zfast.Response([]const u8)`.
///
/// A type missing from here is not a bug that hides: it prints its file name,
/// which is wrong in the same visible way `str.Str` was. `refusals/` is where
/// that gets noticed.
const ours = [_][2][]const u8{
    .{ "str.Str", "zfast.Str" },
    .{ "ctx.Ctx", "zfast.Ctx" },
    .{ "app.App", "zfast.App" },
    .{ "app.Group", "zfast.Group" },
    .{ "typed.Response", "zfast.Response" },
    .{ "typed.Status", "zfast.Status" },
    .{ "typed.Query", "zfast.Query" },
    .{ "form.Form", "zfast.Form" },
    .{ "form.Upload", "zfast.Upload" },
    .{ "redirect.Redirect", "zfast.Redirect" },
    .{ "cookie.Cookie", "zfast.Cookie" },
    .{ "typed.Headers", "zfast.Headers" },
    .{ "typed.Header", "zfast.Header" },
    .{ "http1.Header", "zfast.Header" },
    .{ "http1.Method", "zfast.Method" },
    .{ "patch.Patch", "zfast.Patch" },
    .{ "middleware.Middleware", "zfast.Middleware" },
    .{ "middleware.Next", "zfast.Next" },
    .{ "bulkhead.Mutex", "zfast.Mutex" },
    .{ "fail.Failure", "zfast.Failure" },
};

/// What to call `T` in a message. Every type name zfast's own compile errors
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

test "a zfast type is named the way the import line names it" {
    try testing.expectEqualStrings("zfast.Str", comptime textOf("str.Str"));
    try testing.expectEqualStrings("zfast.Ctx", comptime textOf("ctx.Ctx"));
}

test "a name is rewritten wherever it appears, not only at the front" {
    try testing.expectEqualStrings("[]zfast.Header", comptime textOf("[]http1.Header"));
    try testing.expectEqualStrings(
        "zfast.Response([]const u8)",
        comptime textOf("typed.Response([]const u8)"),
    );
    try testing.expectEqualStrings(
        "zfast.Patch(zfast.Str)",
        comptime textOf("patch.Patch(str.Str)"),
    );
}

test "a type of the reader's own is left where they wrote it" {
    try testing.expectEqualStrings("main.Order", comptime textOf("main.Order"));
    try testing.expectEqualStrings("u32", comptime textOf("u32"));
    // The file is theirs even when the type inside it is not.
    try testing.expectEqualStrings(
        "main.Page(zfast.Str)",
        comptime textOf("main.Page(str.Str)"),
    );
}

test "the same name twice is rewritten twice" {
    try testing.expectEqualStrings(
        "main.Pair(zfast.Str,zfast.Str)",
        comptime textOf("main.Pair(str.Str,str.Str)"),
    );
}
