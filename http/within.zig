//! A number inside a range, as a type, whole or real
//! ([ADR 167](../docs/adr/167-a-whole-number-inside-a-range-is-a-type.md)).
//!
//! ```zig
//! const ListQuery = struct {
//!     limit: nilo.Within(1, 200) = .of(50),
//!     offset: u32 = 0,
//! };
//! ```
//!
//! `?limit=500` is a 400 — `?limit has to be a whole number from 1 to 200,
//! not "500"` — and the document says `minimum: 1, maximum: 200`, so a
//! client generated from it refuses the same value before sending it. Both
//! come from the type, which is the only place nilo reads a contract from.
//!
//! **A bound written with a point makes it a real number**: `Within(0.0, 1.0)`
//! holds an `f64`, read the way a `f64` field is (no `nan`, no `inf`, no hex
//! float), and the document says `type: number` with the same `minimum` and
//! `maximum`. The kind is read off the bounds, so a real range needs no
//! second name.
//!
//! **A type rather than a marker, because a bound is not a validation.**
//! `convert.Reason`'s comment refuses a validation language on purpose:
//! whether an age is plausible is the application's question. But a `u8`
//! already refuses 300 and a `u32` already refuses `-1`, and nobody calls
//! either a validation — the type has a range and the text did not fit it.
//! This is that, with the range chosen rather than inherited from a width.
//! It is read everywhere a `u8` is read: a path param, a query value, a form
//! field, and a JSON body (ADR 166), with one sentence for all four.
//!
//! **The value is read as `.value`**, which is the cost. The number inside is
//! the narrowest integer that holds a whole range, so `Within(1, 200)` is a `u8` and
//! `Within(0, 100_000)` is a `u17`; handing it to a `LIMIT` is `q.limit.value`
//! rather than `q.limit`. Zig has no way to give a struct the arithmetic of
//! its one field, and a type that hid the wrapper would be one nilo could not
//! read a range off.
//!
//! `.of(50)` rather than `.{ .value = 50 }` for the default, because the
//! default is checked against the range while compiling — a default the
//! request could not have sent is the one value the bound would never catch.

const std = @import("std");
const convert = @import("convert.zig");
const mark = @import("jsonmark.zig");

/// A number from `min` to `max`, both inclusive: whole when both bounds are
/// whole (`Within(1, 200)`), real when either is written with a point
/// (`Within(0.0, 1.0)`).
///
/// **The kind of number is read off the bounds**, which is what the author
/// already wrote: `Within(1, 200)` is a `u8` and `Within(0.5, 2.0)` is an
/// `f64`, so there is no second name and no third argument to get out of
/// step with the bounds (ADR 167). A real one refuses `nan`, `inf` and a
/// hex float the way a `f64` field does (ADR 084), and a value that
/// overflows an `f64`.
pub fn Within(comptime min: anytype, comptime max: anytype) type {
    const real = comptime checkBounds(min, max);
    return struct {
        const Self = @This();

        /// The narrowest integer that holds a whole range, or `f64` for a
        /// real one.
        pub const Number = if (real) f64 else std.math.IntFittingRange(min, max);

        pub const lowest: Number = min;
        pub const highest: Number = max;

        /// What a nilo compile error calls this type (ADR 074).
        pub const nilo_type_name = std.fmt.comptimePrint("nilo.Within({d}, {d})", .{ min, max });

        /// What a 400 asks for, in place of the type's name.
        pub const nilo_expects = std.fmt.comptimePrint(
            "a {s} from {d} to {d}",
            .{ if (real) "number" else "whole number", min, max },
        );

        /// The bounds, for the document to say (`openapi.zig` reads it by
        /// name).
        pub const nilo_within = .{ .min = min, .max = max };

        /// A number on the wire, and said so, so that a response carrying
        /// one is written by nilo's own writer around it (ADR 148).
        pub const nilo_openapi = .{ .type = if (real) "number" else "integer" };

        value: Number,

        /// A value known while compiling, the default a field falls back
        /// to, checked against the range here rather than never.
        pub fn of(comptime n: anytype) Self {
            if (n < min or n > max) @compileError(std.fmt.comptimePrint(
                "nilo: `Within({d}, {d}).of({d})` is outside its own range.\n" ++
                    "  A default is the one value a request never sends, so it is the one " ++
                    "the bound would never catch, which is why it is checked here.",
                .{ min, max, n },
            ));
            return .{ .value = n };
        }

        /// The digits, read the way a `u32` (or an `f64`) is read from
        /// request text (`+7`, `1_0`, `nan` and `0x1p3` are not numbers
        /// here either), and refused outside the range with the same null a
        /// bad number gets (ADR 113).
        pub fn nilo_parse(text: []const u8) ?Self {
            if (comptime real) {
                if (!convert.spelledAsNumber(text, true, true)) return null;
                const x = std.fmt.parseFloat(f64, text) catch return null;
                // `1e999` is well spelled and is infinity once read.
                if (!std.math.isFinite(x) or x < min or x > max) return null;
                return .{ .value = x };
            }
            if (!convert.spelledAsNumber(text, min < 0, false)) return null;
            const n = std.fmt.parseInt(i128, text, 10) catch return null;
            if (n < min or n > max) return null;
            return .{ .value = @intCast(n) };
        }

        /// The third arrival, a JSON body: the same digits, as a number or
        /// as text (ADR 166).
        pub const jsonParse = mark.parseFor(Self);

        pub fn jsonStringify(self: Self, jw: anytype) !void {
            try jw.write(self.value);
        }
    };
}

/// Whether the bounds are real numbers, and a sentence for anything else.
fn checkBounds(comptime min: anytype, comptime max: anytype) bool {
    comptime {
        for (.{ min, max }) |bound| {
            const B = @TypeOf(bound);
            if (B != comptime_int and B != comptime_float) @compileError(
                "nilo: `Within` takes numbers for its bounds: a bound has to be a number.\n" ++
                    "  One of them is a " ++ @typeName(B) ++ ". Write them as literals: `Within(1, 200)` for whole numbers, " ++
                    "`Within(0.0, 1.0)` for real ones.",
            );
            if (B == comptime_float and !std.math.isFinite(@as(f64, bound))) @compileError(
                "nilo: `Within` has a bound that is not a finite number.\n" ++
                    "  A range with no end is the type itself: write `f64`.",
            );
        }
        if (min > max) @compileError(std.fmt.comptimePrint(
            "nilo: `Within({d}, {d})` has its bounds the wrong way round: nothing is at least {d} and at most {d}.\n" ++
                "  The lower bound comes first: `Within({d}, {d})`.",
            .{ min, max, min, max, max, min },
        ));
        return @TypeOf(min) == comptime_float or @TypeOf(max) == comptime_float;
    }
}

// ---- tests ----

const testing = std.testing;

test "the range decides the integer, and a value inside it is the number" {
    const Page = Within(1, 200);
    try testing.expectEqual(u8, Page.Number);
    try testing.expectEqual(u17, Within(0, 100_000).Number);
    try testing.expectEqual(i4, Within(-5, 5).Number);

    try testing.expectEqual(@as(u8, 50), Page.nilo_parse("50").?.value);
    try testing.expectEqual(@as(u8, 1), Page.nilo_parse("1").?.value);
    try testing.expectEqual(@as(u8, 200), Page.nilo_parse("200").?.value);
    try testing.expectEqual(@as(u8, 50), Page.of(50).value);
}

test "outside the range is null, and so is anything that is not the digits" {
    const Page = Within(1, 200);
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("0"));
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("201"));
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("-1"));
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("+7"));
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("1_0"));
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("fifty"));
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse(""));
    // Far past any width, which `parseInt` would refuse on its own — the
    // answer is the same null rather than an error nilo has no word for.
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("99999999999999999999999999999999999999999"));

    // A signed range reads a minus sign, because the range has one.
    const Delta = Within(-5, 5);
    try testing.expectEqual(@as(i4, -3), Delta.nilo_parse("-3").?.value);
    try testing.expectEqual(@as(?Delta, null), Delta.nilo_parse("-6"));
}

test "what a 400 asks for names the range, and the type names itself" {
    try testing.expectEqualStrings("a whole number from 1 to 200", Within(1, 200).nilo_expects);
    try testing.expectEqualStrings("nilo.Within(1, 200)", Within(1, 200).nilo_type_name);
    try testing.expectEqual(@as(comptime_int, 1), Within(1, 200).nilo_within.min);
    try testing.expectEqual(@as(comptime_int, 200), Within(1, 200).nilo_within.max);
}

test "in a JSON body it is the number, in and out" {
    const Page = Within(1, 200);
    const Body = struct { limit: Page = .of(50) };

    const parsed = try std.json.parseFromSlice(Body, testing.allocator, "{\"limit\":20}", .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u8, 20), parsed.value.limit.value);

    const absent = try std.json.parseFromSlice(Body, testing.allocator, "{}", .{});
    defer absent.deinit();
    try testing.expectEqual(@as(u8, 50), absent.value.limit.value);

    try testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(Body, testing.allocator, "{\"limit\":500}", .{}));
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Body, testing.allocator, "{\"limit\":true}", .{}));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(Body{ .limit = .of(7) }, .{}, &out.writer);
    try testing.expectEqualStrings("{\"limit\":7}", out.written());
}

test "a range written with a point is a real number, inclusive at both ends" {
    const Ratio = Within(0.0, 1.0);
    try testing.expectEqual(f64, Ratio.Number);
    try testing.expectEqual(@as(f64, 0.0), Ratio.nilo_parse("0").?.value);
    try testing.expectEqual(@as(f64, 1.0), Ratio.nilo_parse("1").?.value);
    try testing.expectEqual(@as(f64, 1.0), Ratio.nilo_parse("1.0").?.value);
    try testing.expectEqual(@as(f64, 0.25), Ratio.nilo_parse("0.25").?.value);
    try testing.expectEqual(@as(f64, 0.5), Ratio.nilo_parse("5e-1").?.value);
    try testing.expectEqual(@as(?Ratio, null), Ratio.nilo_parse("1.0000001"));
    try testing.expectEqual(@as(?Ratio, null), Ratio.nilo_parse("-0.0000001"));
    try testing.expectEqual(@as(f64, 0.5), Ratio.of(0.5).value);

    // One bound with a point is enough, and a whole number is a real one.
    try testing.expectEqual(f64, Within(1, 2.5).Number);
    try testing.expectEqual(@as(f64, 2.0), Within(1, 2.5).nilo_parse("2").?.value);
    try testing.expectEqual(@as(f64, -1.5), Within(-2.0, 2.0).nilo_parse("-1.5").?.value);
}

test "a real range refuses nan, infinity, a hex float and what is not spelled as a number" {
    const Ratio = Within(0.0, 1.0);
    for ([_][]const u8{ "nan", "NaN", "inf", "-inf", "infinity", "1e999", "0x1p-1", "+0.5", "0_5", ".5", "5.", "half", "" }) |text| {
        try testing.expectEqual(@as(?Ratio, null), Ratio.nilo_parse(text));
    }
}

test "what a 400 asks for names a real range, and the document says number" {
    try testing.expectEqualStrings("a number from 0.5 to 2", Within(0.5, 2.0).nilo_expects);
    try testing.expectEqualStrings("a whole number from 1 to 200", Within(1, 200).nilo_expects);
    try testing.expectEqualStrings("number", Within(0.0, 1.0).nilo_openapi.type);
    try testing.expectEqualStrings("integer", Within(0, 1).nilo_openapi.type);
}

test "in a JSON body a real range reads a number or text, and refuses outside it" {
    const Ratio = Within(0.0, 1.0);
    const Body = struct { score: Ratio = .of(0.5) };

    const parsed = try std.json.parseFromSlice(Body, testing.allocator, "{\"score\":0.75}", .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(f64, 0.75), parsed.value.score.value);

    const whole = try std.json.parseFromSlice(Body, testing.allocator, "{\"score\":1}", .{});
    defer whole.deinit();
    try testing.expectEqual(@as(f64, 1.0), whole.value.score.value);

    try testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(Body, testing.allocator, "{\"score\":1.5}", .{}));
    try testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(Body, testing.allocator, "{\"score\":\"nan\"}", .{}));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(Body{ .score = .of(0.25) }, .{}, &out.writer);
    try testing.expectEqualStrings("{\"score\":0.25}", out.written());
}
