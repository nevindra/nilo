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
const mark = @import("jsonmark.zig");

/// Serialise `value` as JSON. Uses the generated writer when the type is one
/// it covers, and `std.json` when it is not — decided while compiling, so
/// there is no runtime branch either way.
pub fn write(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    if (comptime covers(T)) return writeValue(T, w, value);
    comptime refuseRenameOnTheFallback(T);
    return std.json.Stringify.value(value, .{}, w);
}

/// A struct that renames its fields cannot be written by `std.json`, which does
/// not read the marker
/// ([ADR 0181](../docs/adr/0181-a-field-name-is-a-spelling-too.md)).
///
/// **The fallback is the hole this closes.** `covers` errs narrow on purpose:
/// one field it does not recognise — an array of bytes, an untagged union, a
/// tuple, a type with its own `jsonStringify`, anything past eight deep — sends
/// the whole value to `std.json`. A renamed struct anywhere in that value would
/// then go out spelled the way it is written, while `openapi.schemaWithin`
/// promised the renamed keys, and nothing would fail.
///
/// So it is a compile error rather than a quiet disagreement, which is the same
/// answer ADR 0076 reached for a type that writes its own JSON and describes its
/// fields.
fn refuseRenameOnTheFallback(comptime T: type) void {
    comptime {
        const Renamed = mark.renamedFieldsWithin(T) orelse return;
        @compileError(
            "nilo: `" ++ @import("names.zig").of(Renamed) ++ "` renames its fields, and this " ++
                "value goes to `std.json`, which does not read the marker (ADR 0181).\n" ++
                "  `covers` sends the whole value to `std.json` when one shape in it is not " ++
                "nilo's to write: a tuple, an array of bytes, an untagged union, a type with " ++
                "its own `jsonStringify`, or anything nested more than eight deep.\n" ++
                "  The keys would go out spelled as they are written while the API description " ++
                "promised the renamed ones. Take `rename_all` off, or take out the shape that " ++
                "cannot be written here.",
        );
    }
}

/// Whether `T` writes its own JSON **and says what that JSON looks like** —
/// `jsonStringify` beside a `nilo_openapi` naming a scalar
/// ([ADR 0182](../docs/adr/0182-a-leaf-that-says-what-it-is-can-be-carried.md)).
///
/// Such a type is a **leaf**: the generated writer hands the value itself to
/// `std.json` and keeps writing the object around it, rather than giving up on
/// the whole response. `sql.Uuid`, `sql.Timestamp`, `sql.AsText` and `id.Uuid`
/// are all one, which is what makes the difference: a product whose every key
/// is a uuid had no response this file could write at all, so `rename_all` was
/// refused on every one of them (ADR 0181) and the fast writer never ran.
///
/// **`nilo_openapi` is the gate rather than `jsonStringify` alone**, and the
/// two halves are the same sentence read twice. A marker may only name
/// `"string"`, `"integer"`, `"number"` or `"boolean"` (`openapi.toldOf`), so a
/// type carrying one has already promised its JSON is a single scalar with
/// nothing nested inside it — which is exactly the promise this needs to keep
/// writing the punctuation on both sides of it. A type that writes its own
/// JSON and says nothing about it stays `std.json`'s whole value, as it was.
fn writesItsOwnScalar(comptime T: type) bool {
    comptime {
        if (!hasDecl(T, "jsonStringify")) return false;
        if (!hasDecl(T, "nilo_openapi")) return false;
        const said = T.nilo_openapi;
        if (!@hasField(@TypeOf(said), "type")) return false;
        // Read here rather than deferred to `openapi.zig`, which is the file
        // that owns the refusal: a marker with a `type` this does not know is
        // left to `std.json` exactly as it was, so a badly written one changes
        // no byte and still gets its own sentence the moment it reaches a
        // document.
        for ([_][]const u8{ "string", "integer", "number", "boolean" }) |kind| {
            if (std.mem.eql(u8, said.type, kind)) return true;
        }
        return false;
    }
}

/// Whether the generated writer handles `T`. Deliberately narrow: a type
/// this does not recognise is `std.json`'s to write, and the cost of being
/// wrong here is a response that differs from what nilo used to send.
///
/// Answerable only while compiling — it reads the types of a struct's fields —
/// so call it as `comptime covers(T)`.
pub fn covers(comptime T: type) bool {
    return coversWithin(T, 0);
}

/// How far into nested types to follow before answering no.
///
/// **A type holding a list of its own type has no bottom to recurse to** — a
/// comment with replies, a category with children — and `covers` used to walk
/// one until the compiler gave up, with a message in nilo's own file whose
/// advice (raise the branch quota) buys more recursion rather than an answer.
/// Answering false at the ceiling sends the value to `std.json`, which writes
/// it correctly: its recursion is over a *value* at run time rather than over a
/// type while compiling, so the fallback this fell off is the one that works.
///
/// Eight, the same as `openapi.schemaWithin`'s and for the same reason
/// (ADR 0081). The two walk the same types and disagreeing about how deep is
/// how a response and its description come apart.
const max_depth = 8;

fn coversWithin(comptime T: type, comptime depth: usize) bool {
    if (depth >= max_depth) return false;
    // Asked first, and before the depth of anything inside it matters: a leaf
    // is written by `std.json` whole, so what its fields look like is not this
    // walk's business (ADR 0182).
    if (writesItsOwnScalar(T)) return true;
    // Reading the marker is what checks it, and this is the line that makes the
    // check happen at all: a `.tag` on a struct describes nothing and would
    // otherwise sit there doing nothing in silence.
    if (mark.marked(T)) _ = mark.of(T);
    if (T == Str) return true;
    // **Any slice of bytes is text**, not a list of numbers — the reading
    // `std.json` and `openapi.schemaWithin` both already give it. Named by
    // exact type this used to miss `[:0]const u8`, which is what `@tagName`
    // returns and what a field crossing a C boundary is spelled as: it fell
    // through to the `.pointer` arm and went out as `[104,101,108,108,111]`
    // while the generated document said `type: string`.
    if (isByteSlice(T)) return true;
    return switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float => true,
        // An enum with a writer of its own is not just its tag name.
        .@"enum" => !hasDecl(T, "jsonStringify"),
        .optional => |o| coversWithin(o.child, depth + 1),

        // A tagged union, in both encodings.
        //
        // Externally tagged — `{"metrics":{…}}` — is what `std.json` writes and
        // what this used to hand to it. Covering it here changes no byte and is
        // worth 258ns → 90ns on a 374-byte payload, because `covers` is
        // answered for the *whole* value: one union field anywhere sent the
        // entire response to `std.json`, strings included.
        //
        // Internally tagged — `{"signal":"metrics",…}` — is what the type asks
        // for with `nilo_json`, and `std.json` has no way to write it at all
        // (ADR 0085). An empty variant is only writable in that encoding: there
        // is a name to send and no object to put it in.
        .@"union" => |u| covered: {
            if (hasDecl(T, "jsonStringify")) break :covered false;
            // Nothing in an untagged union says which arm is live, so nothing
            // can write it. Same reading `openapi.zig` gives it (ADR 0077).
            if (u.tag_type == null) break :covered false;
            // Reading the marker is also what checks it, so a `.tag` on the
            // wrong shape is refused the moment the type reaches a response.
            const tagged = if (mark.of(T)) |m| m.tag != null else false;
            for (u.fields) |f| {
                if (f.type == void) {
                    if (!tagged) break :covered false;
                    continue;
                }
                if (!coversWithin(f.type, depth + 1)) break :covered false;
            }
            break :covered true;
        },
        // `std.json` writes a `[N]u8` as a *string*, not as a list of numbers:
        // `[3]u8{ 1, 2, 3 }` comes out as three escaped characters in quotes.
        // Rather than reproduce that rule and its edges, an array of bytes is
        // left to it.
        .array => |a| a.child != u8 and coversWithin(a.child, depth + 1),
        .pointer => |p| p.size == .slice and coversWithin(p.child, depth + 1),
        .@"struct" => |s| covered: {
            // A tuple is a JSON array to std.json, and reading that back off
            // the type is more care than the shape deserves; a type that
            // writes itself has the last word on how it looks.
            if (s.is_tuple) break :covered false;
            if (hasDecl(T, "jsonStringify")) break :covered false;
            for (s.fields) |f| {
                if (!coversWithin(f.type, depth + 1)) break :covered false;
            }
            break :covered true;
        },
        else => false,
    };
}

fn writeValue(comptime T: type, w: *std.Io.Writer, value: T) std.Io.Writer.Error!void {
    // A leaf writes itself, and `std.json` is what calls it — so the bytes are
    // the ones this file's contract promises, and the object around it stays
    // this file's to write (ADR 0182).
    if (comptime writesItsOwnScalar(T)) return std.json.Stringify.value(value, .{}, w);
    if (T == Str) return writeText(w, value.view());
    if (comptime isByteSlice(T)) return writeText(w, value);

    switch (@typeInfo(T)) {
        .bool => return w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => return w.printInt(value, 10, .lower, .{}),
        // Left to std.json on purpose — see the header comment.
        .float, .comptime_float => return std.json.Stringify.value(value, .{}, w),
        // A tag name is a Zig identifier, so it can never need escaping and the
        // quotes around it belong in the same literal as the name. That is what
        // makes `rename_all` free: the spelling is settled while compiling, so
        // a renamed enum writes exactly as much as a plain one.
        .@"enum" => |e| {
            if (e.is_exhaustive) switch (value) {
                inline else => |tag| return w.writeAll(
                    comptime "\"" ++ mark.wire(@tagName(tag), mark.of(T)) ++ "\"",
                ),
            };
            // A non-exhaustive enum can hold a value no field names, which is
            // `@tagName`'s to answer rather than a switch's.
            return writeString(w, @tagName(value));
        },
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

        .@"union" => {
            const m = comptime mark.of(T);
            const key = comptime if (m) |said| said.tag else null;
            switch (value) {
                inline else => |payload, active| {
                    const arm = comptime mark.wire(@tagName(active), m);
                    const Payload = @TypeOf(payload);

                    if (comptime key) |k| {
                        // Internally tagged: the discriminator and the
                        // variant's own fields share one object, so the arm is
                        // written flat rather than nested. An empty variant is
                        // the whole object.
                        if (Payload == void) {
                            return w.writeAll(comptime "{\"" ++ k ++ "\":\"" ++ arm ++ "\"}");
                        }
                        try w.writeAll(comptime "{\"" ++ k ++ "\":\"" ++ arm ++ "\"");
                        // The payload's *own* marker names its fields, not the
                        // union's — a union's `rename_all` renames variants and
                        // stops there, which is the line `a tag and a case
                        // together rename the variant but not its fields` holds
                        // (ADR 0085, ADR 0181).
                        const inner = comptime mark.of(Payload);
                        inline for (@typeInfo(Payload).@"struct".fields) |f| {
                            try w.writeAll(comptime ",\"" ++ mark.wire(f.name, inner) ++ "\":");
                            try writeValue(f.type, w, @field(payload, f.name));
                        }
                        return w.writeByte('}');
                    }

                    // Externally tagged: one object, one key, the variant's
                    // name — byte for byte what `std.json` writes.
                    try w.writeAll(comptime "{\"" ++ arm ++ "\":");
                    try writeValue(Payload, w, payload);
                    return w.writeByte('}');
                },
            }
        },

        .@"struct" => |s| {
            if (s.fields.len == 0) return w.writeAll("{}");
            // What the type said its keys are spelled as
            // ([ADR 0181](../docs/adr/0181-a-field-name-is-a-spelling-too.md)).
            // Null for the types that said nothing, which is nearly all of them
            // and costs the same as it always did: the name is settled while
            // compiling either way, so a renamed struct writes exactly as much
            // as a plain one.
            const m = comptime mark.of(T);
            inline for (s.fields, 0..) |f, i| {
                // The brace or comma, the quoted name and the colon are one
                // string settled while compiling.
                try w.writeAll(comptime (if (i == 0) "{\"" else ",\"") ++
                    mark.wire(f.name, m) ++ "\":");
                try writeValue(f.type, w, @field(value, f.name));
            }
            return w.writeByte('}');
        },

        else => comptime unreachable,
    }
}

/// A run of bytes as JSON: a string when it is text, and the array of numbers
/// `std.json` writes when it is not.
///
/// **JSON has no way to carry a byte that is not text.** A `[]const u8` holding
/// `\xff` was written inside quotes and the response was not valid JSON — the
/// one place left where this file's contract, that the output is byte-for-byte
/// what `std.json` would have written, was untrue
/// ([ADR 0121](../docs/adr/0121-a-byte-that-is-not-text-is-not-a-string.md)).
/// `std.json` asks `utf8ValidateSlice` first and falls back to `[104,101]`, so
/// that is what this asks and that is what this writes.
///
/// The cost is the validation, the same function `std.json` calls: a
/// 32-byte-at-a-time scan that only walks UTF-8 past the first byte over 0x7f,
/// so ASCII is one vector pass.
fn writeText(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return writeByteArray(w, text);
    return writeString(w, text);
}

/// The bytes as a JSON array of numbers, which is what `std.json` writes for a
/// `[]const u8` it cannot call a string.
fn writeByteArray(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (bytes, 0..) |b, i| {
        if (i > 0) try w.writeByte(',');
        try w.printInt(b, 10, .lower, .{});
    }
    return w.writeByte(']');
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

/// Whether `T` is a run of bytes and therefore text: `[]const u8`, `[]u8`, and
/// every sentinel-terminated or aligned spelling of the two.
///
/// Public because three layers have to give the same answer to it — this file
/// writes the bytes, `typed.contentTypeFor` labels them and
/// `openapi.schemaWithin` describes them — and the last of those reading
/// `p.child == u8` while the first read the exact type is how a response and
/// its own description came to disagree.
pub fn isByteSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
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

test "a run of bytes that is not text is a list of numbers, not a string" {
    // JSON has no way to carry a byte that is not text, and `std.json` answers
    // that by writing the array instead. Written inside quotes, as this used
    // to, the response is simply not valid JSON (ADR 0121).
    try expectSame(@as([]const u8, "\xff"));
    try expectSame(@as([]const u8, "caf\xe9")); // latin-1, not UTF-8
    try expectSame(@as([]const u8, "\xc3")); // a lead byte with nothing after it
    try expectSame(@as([]const u8, "ok\x80bad"));
    try expectSame(@as([]const u8, "\xed\xa0\x80")); // a surrogate half
    // A quote inside bytes that are not text: the array wins, so nothing is
    // escaped at all.
    try expectSame(@as([]const u8, "\xff\"\n"));
    // And the whole of it stays true one type over.
    var lifetime = @import("nilo_core").Lifetime{};
    try expectSame(Str.fromRequest("\xff", &lifetime));
    try expectSame(struct { name: []const u8, id: u32 }{ .name = "\xfe\xff", .id = 7 });
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

test "a sentinel-terminated string is a string, not a list of its bytes" {
    // `[:0]const u8` is what `@tagName` returns, what `allocPrintSentinel`
    // returns, and what a field crossing a C boundary is spelled as. Named by
    // exact type, `covers` missed all three: the value went out as
    // `[104,101,108,108,111]` while `openapi.schemaWithin` — reading the same
    // type as `p.child == u8` — described it as a string.
    try expectSame(@as([:0]const u8, "hello"));
    try expectSame(@as([:0]const u8, ""));
    try expectSame(@as([:0]const u8, "with a \" in it"));
    try expectSame(struct { name: [:0]const u8, id: u32 }{ .name = "wati", .id = 7 });
    try expectSame(@as([]const [:0]const u8, &.{ "a", "b" }));

    // A mutable one, and the plain pair that always worked.
    var buf = [_:0]u8{ 'h', 'i' };
    try expectSame(@as([:0]u8, &buf));
    try expectSame(@as([]const u8, "hello"));
    try expectSame(@as([]u8, buf[0..2]));
}

test "a type that holds a list of itself is std.json's to write" {
    // `covers` recursed through `.pointer` with no floor, so an ordinary JSON
    // tree — a comment with replies, a category with children — did not come
    // out wrong: it failed to compile, with a message in this file whose
    // advice was to raise the branch quota, which buys more recursion rather
    // than an answer. Eight deep and then no, the same ceiling
    // `openapi.schemaWithin` has (ADR 0081).
    const Comment = struct {
        body: []const u8,
        replies: []const @This(),
    };
    comptime std.debug.assert(!covers(Comment));

    // And the fallback is not a degraded answer — it is the correct one,
    // because `std.json` recurses over a value at run time rather than over a
    // type while compiling.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, Comment{
        .body = "top",
        .replies = &.{.{ .body = "under", .replies = &.{} }},
    });
    try testing.expectEqualStrings(
        \\{"body":"top","replies":[{"body":"under","replies":[]}]}
    , out.written());

    // A shape that is merely deep rather than endless is still on the fast
    // path, so the ceiling has not quietly swallowed ordinary types.
    try expectSame(struct { a: struct { b: struct { c: struct { d: u32 } } } }{
        .a = .{ .b = .{ .c = .{ .d = 1 } } },
    });
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
    // Nothing in an untagged union says which arm is live, so nothing can
    // write it — the same reading `openapi.zig` gives it (ADR 0077).
    comptime std.debug.assert(!covers(union { a: u32, b: bool }));
    // A struct holding one of those falls back with it.
    comptime std.debug.assert(!covers(struct { inner: Custom }));

    // And the fallback still produces std.json's own output.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, Custom{ .n = 5 });
    try testing.expectEqualStrings("5", out.written());
}

/// What `write` produced, for a type whose whole point is *not* being what
/// `std.json` would have written. `expectSame` is the right check for every
/// other shape here and the wrong one for these.
fn expectJson(expected: []const u8, value: anytype) !void {
    comptime std.debug.assert(covers(@TypeOf(value)));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, value);
    try testing.expectEqualStrings(expected, out.written());
}

test "a union that says nothing is written the way std.json writes it" {
    const Link = union(enum) { url: []const u8, id: u32 };
    try expectSame(Link{ .url = "https://example.dev" });
    try expectSame(Link{ .id = 9 });

    // And so is one nested in a struct, which is the shape that used to send
    // the whole response to std.json.
    const Held = struct { name: []const u8, link: Link };
    try expectSame(Held{ .name = "wati", .link = .{ .id = 9 } });
}

test "a union that says its tag writes the tag beside the variant's own fields" {
    const Condition = union(enum) {
        pub const nilo_json = .{ .tag = "signal" };

        metrics: struct { metric_name: []const u8, threshold: f64 },
        logs: struct { query: []const u8, count_over: u32 },
    };

    try expectJson(
        \\{"signal":"metrics","metric_name":"system.cpu.utilization","threshold":0.9}
    , Condition{ .metrics = .{ .metric_name = "system.cpu.utilization", .threshold = 0.9 } });

    try expectJson(
        \\{"signal":"logs","query":"level:error","count_over":5}
    , Condition{ .logs = .{ .query = "level:error", .count_over = 5 } });
}

test "a variant carrying nothing is the tag on its own" {
    const Step = union(enum) {
        pub const nilo_json = .{ .tag = "step" };

        queued,
        running: struct { pid: u32 },
    };

    // Written out rather than as `Step.queued`, which is the *tag* enum's
    // field and would be a different type entirely.
    try expectJson(
        \\{"step":"queued"}
    , Step{ .queued = {} });
    try expectJson(
        \\{"step":"running","pid":41}
    , Step{ .running = .{ .pid = 41 } });
}

test "a tag and a case together rename the variant but not its fields" {
    const Channel = union(enum) {
        pub const nilo_json = .{ .tag = "kind", .rename_all = .@"kebab-case" };

        web_hook: struct { target_url: []const u8 },
        discord_dm: struct { user_id: u32 },
    };

    // The variant is renamed because it is a value on the wire. `target_url`
    // is a field name and is left alone, which is the line this cut draws.
    try expectJson(
        \\{"kind":"web-hook","target_url":"https://example.dev/hook"}
    , Channel{ .web_hook = .{ .target_url = "https://example.dev/hook" } });
    try expectJson(
        \\{"kind":"discord-dm","user_id":7}
    , Channel{ .discord_dm = .{ .user_id = 7 } });
}

test "an enum that says its case comes out in it, and one that does not is its tag name" {
    const Agg = enum {
        pub const nilo_json = .{ .rename_all = .SCREAMING_SNAKE_CASE };

        avg,
        rate_per_second,
    };
    try expectJson("\"AVG\"", Agg.avg);
    try expectJson("\"RATE_PER_SECOND\"", Agg.rate_per_second);

    const Plain = enum { avg, rate_per_second };
    try expectSame(Plain.rate_per_second);
}

test "a renamed enum inside a struct is renamed there too" {
    const Severity = enum {
        pub const nilo_json = .{ .rename_all = .UPPERCASE };

        info,
        critical,
    };
    const Alert = struct { id: u32, severity: Severity };

    try expectJson(
        \\{"id":3,"severity":"CRITICAL"}
    , Alert{ .id = 3, .severity = .critical });
}

test "a struct that says its case sends its field names in it" {
    // What this replaces, counted in one caller's port: 10 response structs, 77
    // fields, 5 mapping functions written out field by field and 5 arena loops,
    // and the whole job of all of it was `full_name` becoming `fullName`
    // (ADR 0181).
    const Contact = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };

        id: u32,
        full_name: []const u8,
        partner_id: u32,
        email_address: ?[]const u8,
    };

    try expectJson(
        \\{"id":7,"fullName":"Wati","partnerId":3,"emailAddress":null}
    , Contact{ .id = 7, .full_name = "Wati", .partner_id = 3, .email_address = null });

    // A field with no underscore in it is untouched, which is most of them.
    const Plain = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };
        id: u32,
        name: []const u8,
    };
    try expectJson(
        \\{"id":1,"name":"Sari"}
    , Plain{ .id = 1, .name = "Sari" });

    // And a struct that says nothing is still byte-for-byte std.json's, which
    // is the contract this whole file rests on.
    try expectSame(struct { full_name: []const u8 }{ .full_name = "Wati" });
}

test "a renamed struct nested inside another is renamed where it sits" {
    const Partner = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };
        partner_id: u32,
        display_name: []const u8,
    };
    // The outer struct says nothing, so its own fields are written as they are
    // — the marker is per type rather than inherited, which is the same rule a
    // union's `rename_all` already follows about its payload's fields.
    const Page = struct {
        total_count: u32,
        items: []const Partner,
    };

    try expectJson(
        \\{"total_count":2,"items":[{"partnerId":1,"displayName":"Wati"},{"partnerId":2,"displayName":"Sari"}]}
    , Page{ .total_count = 2, .items = &.{
        .{ .partner_id = 1, .display_name = "Wati" },
        .{ .partner_id = 2, .display_name = "Sari" },
    } });
}

test "every case a struct can ask for, on one field" {
    const Lower = struct {
        pub const nilo_json = .{ .rename_all = .lowercase };
        not_found: u32,
    };
    const Upper = struct {
        pub const nilo_json = .{ .rename_all = .UPPERCASE };
        not_found: u32,
    };
    const Pascal = struct {
        pub const nilo_json = .{ .rename_all = .PascalCase };
        not_found: u32,
    };
    const Screaming = struct {
        pub const nilo_json = .{ .rename_all = .SCREAMING_SNAKE_CASE };
        not_found: u32,
    };
    const Kebab = struct {
        pub const nilo_json = .{ .rename_all = .@"kebab-case" };
        not_found: u32,
    };

    try expectJson("{\"notfound\":1}", Lower{ .not_found = 1 });
    try expectJson("{\"NOTFOUND\":1}", Upper{ .not_found = 1 });
    try expectJson("{\"NotFound\":1}", Pascal{ .not_found = 1 });
    try expectJson("{\"NOT_FOUND\":1}", Screaming{ .not_found = 1 });
    try expectJson("{\"not-found\":1}", Kebab{ .not_found = 1 });
}

test "the payload of a tagged variant is renamed by its own marker, not by the union's" {
    // The line ADR 0085 drew and ADR 0181 kept: a union's `rename_all` renames
    // variants, and a payload's own marker is what renames the payload's
    // fields. Two markers, each about its own type.
    const Inner = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };
        target_url: []const u8,
    };
    const Channel = union(enum) {
        pub const nilo_json = .{ .tag = "kind", .rename_all = .@"kebab-case" };

        web_hook: Inner,
        discord_dm: struct { user_id: u32 },
    };

    try expectJson(
        \\{"kind":"web-hook","targetUrl":"https://example.dev/hook"}
    , Channel{ .web_hook = .{ .target_url = "https://example.dev/hook" } });

    // The variant whose payload says nothing keeps its own spelling, which is
    // what the pre-existing test at the top of this pair asserts.
    try expectJson(
        \\{"kind":"discord-dm","user_id":7}
    , Channel{ .discord_dm = .{ .user_id = 7 } });
}

test "a union with a variant the writer cannot touch falls back whole" {
    const Custom = struct {
        n: u32,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.n);
        }
    };
    // One arm out of reach takes the union with it, exactly as one field does
    // for a struct — `covers` errs narrow on purpose.
    comptime std.debug.assert(!covers(union(enum) { a: u32, b: Custom }));

    // A union that writes itself is left alone whatever its arms are.
    const Writes = union(enum) {
        a: u32,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.a);
        }
    };
    comptime std.debug.assert(!covers(Writes));
}

/// A stand-in for the four types item 46 was actually about — `sql.Uuid`,
/// `sql.Timestamp`, `sql.AsText` and `id.Uuid`. Spelled out here rather than
/// imported because `http/` may not name `sql/`, and the contract between them
/// is two declarations by name and nothing else (ADR 0046, ADR 0076).
const Key = struct {
    bytes: [4]u8,

    pub const nilo_openapi = .{ .type = "string", .format = "uuid" };

    pub fn jsonStringify(self: Key, jw: anytype) !void {
        var text: [8]u8 = undefined;
        for (self.bytes, 0..) |b, i| {
            _ = std.fmt.bufPrint(text[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
        }
        try jw.write(&text);
    }
};

test "a type that writes its own JSON and says what it looks like is a leaf, not a wall" {
    // The whole of ADR 0182: this used to answer false, and one such field
    // anywhere sent the entire response to `std.json`.
    comptime std.debug.assert(covers(Key));
    comptime std.debug.assert(covers(struct { id: Key, name: []const u8 }));
    comptime std.debug.assert(covers(struct { id: ?Key, ids: []const Key }));

    // And every one of them is still byte-for-byte what `std.json` writes,
    // which is the contract at the top of this file.
    try expectSame(Key{ .bytes = .{ 0xde, 0xad, 0xbe, 0xef } });
    try expectSame(struct { id: Key, name: []const u8 }{
        .id = .{ .bytes = .{ 1, 2, 3, 4 } },
        .name = "wati",
    });
    try expectSame(struct { id: ?Key, name: []const u8 }{ .id = null, .name = "wati" });
}

test "a leaf that says nothing about its JSON still takes the value with it" {
    // The line is `nilo_openapi`, not `jsonStringify`. A type that writes
    // itself and never says what it wrote is the shape this file cannot
    // describe, so it stays `std.json`'s whole value exactly as it was.
    const Quiet = struct {
        n: u32,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.n);
        }
    };
    comptime std.debug.assert(!covers(Quiet));
    comptime std.debug.assert(!covers(struct { inner: Quiet }));

    // Nor does a marker naming a shape that is not a scalar — there is no such
    // marker today, and if there ever is one this file has to keep writing the
    // punctuation around a value it cannot see the end of.
    const Object = struct {
        n: u32,
        pub const nilo_openapi = .{ .type = "object" };
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.n);
        }
    };
    comptime std.debug.assert(!covers(Object));
}

test "a struct of keys can say how its fields are spelled" {
    // Item 46, reopened: every response in the reporting product holds at
    // least one `sql.Uuid`, so `rename_all` was refused on every one of them
    // while the document promised the renamed keys (ADR 0181, ADR 0182).
    const Contact = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };

        id: Key,
        full_name: []const u8,
        partner_id: Key,
    };

    try expectJson(
        "{\"id\":\"01020304\",\"fullName\":\"Wati\",\"partnerId\":\"0a0b0c0d\"}",
        Contact{
            .id = .{ .bytes = .{ 1, 2, 3, 4 } },
            .full_name = "Wati",
            .partner_id = .{ .bytes = .{ 10, 11, 12, 13 } },
        },
    );
}
