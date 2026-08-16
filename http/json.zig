//! Writing a response as JSON.
//!
//! `std.json` is what this falls back to, and for a while it was all there
//! was. What it costs is not obvious from reading it: it writes a JSON string
//! a byte at a time, through the writer, checking each one for something that
//! needs escaping. On the ~1KB payload that is nilo's primary metric that
//! came to 1038ns — more than everything else the request does put together.
//!
//! So the shapes a handler actually returns get a writer of their own,
//! generated while compiling from the type:
//!
//! - Every constant part of the output — the braces, the quoted field names,
//!   the colons and commas — is one comptime string. A struct of four fields
//!   is four `writeAll`s of a literal, not a writer call per punctuation mark.
//! - A string is scanned 32 bytes at a time for the three things JSON cannot
//!   carry as-is, and the run in between is written whole. Almost every string
//!   has none at all, which makes it one scan and one `writeAll`.
//!
//! 1038ns → 126ns on that payload, 75ns → 22ns on a small one.
//!
//! **The output is byte-for-byte what `std.json` would have written.** That is
//! not a hope: `covers` decides while compiling which types this path is
//! allowed to touch, anything else goes to `std.json` unchanged, and the tests
//! at the bottom hold the two against each other value by value. A float goes
//! to `std.json` field by field rather than being reimplemented — how it
//! chooses between `12.5` and `1.25e1` is not worth copying.

const std = @import("std");
const Str = @import("nilo_core").Str;

/// Serialise `value` as JSON. Uses the generated writer when the type is one
/// it covers, and `std.json` when it is not — decided while compiling, so
/// there is no runtime branch either way.
pub fn write(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    if (comptime covers(T)) return writeValue(T, w, value);
    return std.json.Stringify.value(value, .{}, w);
}

/// Whether the generated writer handles `T`. Deliberately narrow: a type
/// this does not recognise is `std.json`'s to write, and the cost of being
/// wrong here is a response that differs from what nilo used to send.
///
/// Answerable only while compiling — it reads the types of a struct's fields —
/// so call it as `comptime covers(T)`.
pub fn covers(comptime T: type) bool {
    if (T == Str) return true;
    if (T == []const u8 or T == []u8) return true;
    return switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float => true,
        // An enum with a writer of its own is not just its tag name.
        .@"enum" => !hasDecl(T, "jsonStringify"),
        .optional => |o| covers(o.child),
        // `std.json` writes a `[N]u8` as a *string*, not as a list of numbers:
        // `[3]u8{ 1, 2, 3 }` comes out as three escaped characters in quotes.
        // Rather than reproduce that rule and its edges, an array of bytes is
        // left to it.
        .array => |a| a.child != u8 and covers(a.child),
        .pointer => |p| p.size == .slice and covers(p.child),
        .@"struct" => |s| covered: {
            // A tuple is a JSON array to std.json, and reading that back off
            // the type is more care than the shape deserves; a type that
            // writes itself has the last word on how it looks.
            if (s.is_tuple) break :covered false;
            if (hasDecl(T, "jsonStringify")) break :covered false;
            for (s.fields) |f| {
                if (!covers(f.type)) break :covered false;
            }
            break :covered true;
        },
        else => false,
    };
}

fn writeValue(comptime T: type, w: *std.Io.Writer, value: T) std.Io.Writer.Error!void {
    if (T == Str) return writeString(w, value.view());
    if (T == []const u8 or T == []u8) return writeString(w, value);

    switch (@typeInfo(T)) {
        .bool => return w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => return w.printInt(value, 10, .lower, .{}),
        // Left to std.json on purpose — see the header comment.
        .float, .comptime_float => return std.json.Stringify.value(value, .{}, w),
        .@"enum" => return writeString(w, @tagName(value)),
        .optional => return if (value) |payload|
            writeValue(@TypeOf(payload), w, payload)
        else
            w.writeAll("null"),

        .array, .pointer => {
            try w.writeByte('[');
            for (value, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeValue(@TypeOf(item), w, item);
            }
            return w.writeByte(']');
        },

        .@"struct" => |s| {
            if (s.fields.len == 0) return w.writeAll("{}");
            inline for (s.fields, 0..) |f, i| {
                // The brace or comma, the quoted name and the colon are one
                // string settled while compiling.
                try w.writeAll(comptime (if (i == 0) "{\"" else ",\"") ++ f.name ++ "\":");
                try writeValue(f.type, w, @field(value, f.name));
            }
            return w.writeByte('}');
        },

        else => comptime unreachable,
    }
}

/// A JSON string. Only three things need escaping — a quote, a backslash, and
/// anything below a space — so the run of bytes up to the next one of those is
/// found 32 at a time and written whole.
///
/// Public because the logger writes JSON lines of its own and a request path
/// is a stranger's text: a newline in one would forge a log line. One escaper
/// rather than two is what keeps that true in both places.
pub fn writeString(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var at: usize = 0;
    while (nextEscape(text, at)) |i| {
        try w.writeAll(text[at..i]);
        at = i + 1;
        try w.writeAll(switch (text[i]) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            // The rest of the control characters have no short form.
            else => {
                try w.print("\\u{x:0>4}", .{text[i]});
                continue;
            },
        });
    }
    try w.writeAll(text[at..]);
    return w.writeByte('"');
}

const lanes = 32;
const Chunk = @Vector(lanes, u8);

/// The next byte at or after `from` that a JSON string cannot carry as it is.
fn nextEscape(text: []const u8, from: usize) ?usize {
    const quote: Chunk = @splat('"');
    const backslash: Chunk = @splat('\\');
    const space: Chunk = @splat(0x20);

    var i = from;
    while (i + lanes <= text.len) : (i += lanes) {
        const block: Chunk = text[i..][0..lanes].*;
        // Below a space covers every control character, including the ones
        // with a short escape.
        const hits = (block == quote) | (block == backslash) | (block < space);
        const bits: u32 = @bitCast(hits);
        if (bits != 0) return i + @ctz(bits);
    }
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '"' or c == '\\' or c < 0x20) return i;
    }
    return null;
}

fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

// ---- tests ----
//
// Every one of these asserts the same thing: that what this file writes is
// exactly what std.json would have written. That is the whole contract — the
// speed is only allowed to exist because the bytes are identical.

const testing = std.testing;

/// Assert the generated writer and std.json produce the same bytes, and that
/// this type is actually on the fast path (a test that silently fell back
/// would pass while proving nothing).
fn expectSame(value: anytype) !void {
    comptime std.debug.assert(covers(@TypeOf(value)));

    var mine: std.Io.Writer.Allocating = .init(testing.allocator);
    defer mine.deinit();
    try write(&mine.writer, value);

    var theirs: std.Io.Writer.Allocating = .init(testing.allocator);
    defer theirs.deinit();
    try std.json.Stringify.value(value, .{}, &theirs.writer);

    try testing.expectEqualStrings(theirs.written(), mine.written());
}

test "scalars come out the way std.json writes them" {
    try expectSame(@as(u32, 0));
    try expectSame(@as(u32, 7));
    try expectSame(@as(i32, -42));
    try expectSame(@as(u64, std.math.maxInt(u64)));
    try expectSame(@as(i64, std.math.minInt(i64)));
    try expectSame(@as(u8, 255));
    try expectSame(true);
    try expectSame(false);
}

test "floats are left to std.json rather than reimplemented" {
    try expectSame(@as(f64, 12.5));
    try expectSame(@as(f64, 0));
    try expectSame(@as(f64, -0.125));
    try expectSame(@as(f32, 1.5));
    try expectSame(@as(f64, 1e300));
    try expectSame(@as(f64, 1234567890.0));
}

test "a string with nothing to escape, and one with everything" {
    try expectSame(@as([]const u8, ""));
    try expectSame(@as([]const u8, "wati"));
    try expectSame(@as([]const u8, "quote\" backslash\\ slash/"));
    try expectSame(@as([]const u8, "newline\n return\r tab\t"));
    try expectSame(@as([]const u8, "backspace\x08 formfeed\x0c"));
    try expectSame(@as([]const u8, "control\x00\x01\x0b\x0e\x1f end"));
    try expectSame(@as([]const u8, "café ☕ emoji 🎉"));
}

test "an escape lands on every offset of a block boundary" {
    // The scan works 32 bytes at a time, so a quote just before, on, and just
    // after a boundary are three different paths through it.
    var buf: [80]u8 = undefined;
    for (0..72) |at| {
        @memset(&buf, 'x');
        buf[at] = '"';
        try expectSame(@as([]const u8, buf[0..72]));
    }
    // And one long run with no escape at all, which is the common case.
    @memset(&buf, 'x');
    try expectSame(@as([]const u8, &buf));
}

test "a Str goes out as a plain JSON string" {
    var lifetime = @import("nilo_core").Lifetime{};
    try expectSame(Str.fromRequest("wati sari", &lifetime));
    try expectSame(Str.fromRequest("with a \" in it", &lifetime));
    try expectSame(struct { name: Str, id: u32 }{
        .name = Str.fromRequest("wati", &lifetime),
        .id = 7,
    });
}

test "structs, nesting, optionals and enums" {
    try expectSame(struct {}{});
    try expectSame(struct { id: u32, name: []const u8 }{ .id = 7, .name = "wati" });
    try expectSame(struct { a: ?u32, b: ?u32 }{ .a = null, .b = 3 });
    try expectSame(struct { kind: enum { free, paid } }{ .kind = .paid });
    try expectSame(struct {
        outer: u32,
        inner: struct { deep: struct { x: bool } },
    }{ .outer = 1, .inner = .{ .deep = .{ .x = true } } });
    try expectSame(struct { maybe: ?struct { x: u8 } }{ .maybe = .{ .x = 2 } });
}

test "lists" {
    try expectSame(@as([]const u32, &.{}));
    try expectSame(@as([]const u32, &.{ 1, 2, 3 }));
    try expectSame(@as([]const []const u8, &.{ "a", "b\"c" }));
    try expectSame([3]u32{ 1, 2, 3 });
    // An array of bytes is a string to std.json, not a list, so it is left to
    // it rather than guessed at.
    comptime std.debug.assert(!covers([3]u8));
    const User = struct { id: u32, name: []const u8 };
    try expectSame(@as([]const User, &.{
        .{ .id = 1, .name = "wati" },
        .{ .id = 2, .name = "sari" },
    }));
}

test "the primary metric's own payload" {
    const bio = "A systems nerd who writes Zig before breakfast. " ** 19;
    try expectSame(struct {
        id: u32,
        name: []const u8,
        email: []const u8,
        bio: []const u8,
    }{ .id = 7, .name = "Routed Tester", .email = "tester@example.dev", .bio = bio });
}

test "a type that writes itself is left alone, and so is a tuple" {
    // Both have to fall back, or this file would be deciding how they look.
    const Custom = struct {
        n: u32,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.n);
        }
    };
    comptime std.debug.assert(!covers(Custom));
    comptime std.debug.assert(!covers(struct { u32, u32 }));
    comptime std.debug.assert(!covers(union(enum) { a: u32 }));
    // A struct holding one of those falls back with it.
    comptime std.debug.assert(!covers(struct { inner: Custom }));

    // And the fallback still produces std.json's own output.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, Custom{ .n = 5 });
    try testing.expectEqualStrings("5", out.written());
}
