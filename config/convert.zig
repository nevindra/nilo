//! Turning one environment value into the type a Config asked for.
//!
//! The App has a converter of its own (`http/convert.zig`) and this is
//! deliberately not it. [ADR 038](../docs/adr/038-a-module-sits-where-the-loop-puts-it.md)
//! named that file "the interesting refusal" and left the question open for
//! whoever turned up as its second caller — and the answer this module gives
//! is that it is *not* that caller (ADR 039). Sharing it would mean naming
//! `nilo_core` for `Str`, and a tool module that cannot run under a plain
//! `zig test` is in the wrong layer. What is here is the same four reasons
//! against `[]const u8` instead, in forty lines.
//!
//! The wording is allowed to be its own, and that is not the oversight it
//! looks like. `http/convert.zig` keeps one copy of its sentences because a
//! handler shows a field's failure *next to* a 400 from the endpoint beside
//! it, and two spellings of one mistake is what somebody files a bug about.
//! Config is never next to anything: it is written to stderr once, before
//! the socket opens, by a process that is about to exit.

const std = @import("std");

/// Why one environment value could not become the type that was asked for.
///
/// Four, and it stays four. nilo's job stops at "this did not convert to a
/// `u16`"; whether the port is one this machine may bind is the program's
/// own question, and a reason set that grew to answer it would be a
/// validation language wearing a smaller name.
pub const Reason = enum {
    /// Nothing was set under this name, and the field has no default and is
    /// not a `?T`.
    missing,
    /// An int or a float that `std.fmt` would not read.
    not_a_number,
    not_true_or_false,
    not_a_choice,
};

/// Whether an environment value can become a `T` at all — text, a number, a
/// `bool`, an enum, or any of those wrapped in `?`.
///
/// Asked while compiling, by whoever is about to promise a field can be
/// filled from the environment. A field this answers false for is a Refusal
/// rather than a failure at startup.
pub fn convertible(comptime T: type) bool {
    const Inner = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    if (Inner == []const u8) return true;
    return switch (@typeInfo(Inner)) {
        .int, .float, .bool, .@"enum" => true,
        else => false,
    };
}

/// Turn one environment value into the type the Config asked for: null when
/// it worked and `out` holds the value, a Reason when it did not.
///
/// The reason comes back through the return value and the value through a
/// pointer rather than the other way round, because that is what makes a
/// struct's worth of outcomes one `[N]?Reason` array. A union carrying each
/// field's own type would need a different shape per field, which is exactly
/// what a Read cannot hold.
pub fn tryConvert(comptime P: type, text: []const u8, out: *P) ?Reason {
    if (P == []const u8) {
        out.* = text;
        return null;
    }

    switch (@typeInfo(P)) {
        .int => out.* = std.fmt.parseInt(P, text, 10) catch return .not_a_number,
        .float => out.* = std.fmt.parseFloat(P, text) catch return .not_a_number,
        .bool => out.* = boolFrom(text) orelse return .not_true_or_false,
        .@"enum" => out.* = std.meta.stringToEnum(P, text) orelse return .not_a_choice,
        else => comptime unreachable,
    }
    return null;
}

/// What a `P` would have taken, in the words the messages use.
///
/// Built once while compiling and stored in the table `Read` carries, so
/// that reporting a failure reads a string rather than walking the type
/// again. It is also the whole of what the message needs beyond the name and
/// the text that arrived, which is why there is no per-type function pointer
/// here the way there is in `http/bound.zig`.
pub fn expectedOf(comptime T: type) []const u8 {
    const P = comptime unwrap(T);
    if (P == []const u8) return "text";
    return switch (@typeInfo(P)) {
        .int => "a whole number",
        .float => "a number",
        .bool => "true or false",
        .@"enum" => "one of " ++ enumChoices(P),
        else => comptime unreachable,
    };
}

/// The type inside a `?T`, or `T` itself.
pub fn unwrap(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

fn boolFrom(text: []const u8) ?bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return null;
}

/// How many backwards branches a comptime loop over a type's fields may take,
/// sized off the input: a fixed number per field, one per byte of every name
/// (a byte at a time is how names get upper-cased, compared and joined), and a
/// floor. `names` is a struct's or an enum's `field_names`.
///
/// Called by every comptime loop in this module that walks user fields or
/// their names, because a quota raised in a callee raises the caller's whole
/// evaluation and the default 1000 ran out at about 330 characters of field
/// names (ADR 126). The factors are deliberately generous: the cost of too
/// many is nothing, and the cost of too few is a message from inside nilo.
pub fn budget(comptime names: []const [:0]const u8) u32 {
    comptime {
        // Adding the sizes up is itself a loop over the fields.
        @setEvalBranchQuota(1000 + 2 * names.len);
        var n: u32 = 2000;
        for (names) |name| n += 100 + 20 * @as(u32, @intCast(name.len));
        return n;
    }
}

/// The names an enum's values answer to, for the message that says what was
/// expected. Built once at compile time.
pub fn enumChoices(comptime E: type) []const u8 {
    comptime {
        const names = @typeInfo(E).@"enum".field_names;
        @setEvalBranchQuota(budget(names));
        var out: []const u8 = "";
        for (names, 0..) |name, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ name;
        }
        return out;
    }
}

const testing = std.testing;

test "the types an environment value can become" {
    try testing.expect(convertible([]const u8));
    try testing.expect(convertible(u16));
    try testing.expect(convertible(f64));
    try testing.expect(convertible(bool));
    try testing.expect(convertible(enum { a, b }));
    try testing.expect(convertible(?u16));
    try testing.expect(convertible(?[]const u8));

    try testing.expect(!convertible([]const []const u8));
    try testing.expect(!convertible(struct { a: u32 }));
    try testing.expect(!convertible([4]u8));
}

test "text that fits becomes the value" {
    var port: u16 = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert(u16, "8080", &port));
    try testing.expectEqual(@as(u16, 8080), port);

    var ratio: f64 = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert(f64, "1.5", &ratio));
    try testing.expectEqual(@as(f64, 1.5), ratio);

    var on: bool = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert(bool, "true", &on));
    try testing.expectEqual(true, on);

    var url: []const u8 = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert([]const u8, "postgres://", &url));
    try testing.expectEqualStrings("postgres://", url);

    const Level = enum { debug, info, warn };
    var level: Level = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert(Level, "warn", &level));
    try testing.expectEqual(Level.warn, level);
}

test "text that does not fit says why, and leaves failing to the caller" {
    var port: u16 = undefined;
    try testing.expectEqual(Reason.not_a_number, tryConvert(u16, "soon", &port).?);
    // In range for the text and out of range for the type is the same
    // answer: `std.fmt` would not read it into a `u16`.
    try testing.expectEqual(Reason.not_a_number, tryConvert(u16, "70000", &port).?);

    var on: bool = undefined;
    try testing.expectEqual(Reason.not_true_or_false, tryConvert(bool, "yes", &on).?);
    try testing.expectEqual(Reason.not_true_or_false, tryConvert(bool, "1", &on).?);

    const Level = enum { debug, info, warn };
    var level: Level = undefined;
    try testing.expectEqual(Reason.not_a_choice, tryConvert(Level, "verbose", &level).?);

    // Text is text, so there is nothing that can fail — including the empty
    // string, which is what `PORT=` in a shell actually sets.
    var url: []const u8 = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert([]const u8, "", &url));
    try testing.expectEqualStrings("", url);
}

test "an empty value is not a missing one" {
    // `DATABASE_URL=` is set. Only a name nothing was set under is missing,
    // and that answer is `Read`'s to give rather than this file's — which is
    // why `.missing` is in the Reason set and never returned here.
    var port: u16 = undefined;
    try testing.expectEqual(Reason.not_a_number, tryConvert(u16, "", &port).?);
}

test "what a field would have taken is settled while compiling" {
    try testing.expectEqualStrings("text", comptime expectedOf([]const u8));
    try testing.expectEqualStrings("a whole number", comptime expectedOf(u16));
    try testing.expectEqualStrings("a number", comptime expectedOf(f64));
    try testing.expectEqualStrings("true or false", comptime expectedOf(bool));
    try testing.expectEqualStrings(
        "one of debug, info, warn",
        comptime expectedOf(enum { debug, info, warn }),
    );

    // An optional is worded as the thing inside it: `?u16` not being set is
    // not a failure at all, so the only sentence it can need is the one
    // about text that would not convert.
    try testing.expectEqualStrings("a whole number", comptime expectedOf(?u16));
}

test "the choices an enum offers are listed in order" {
    try testing.expectEqualStrings("red, green, blue", comptime enumChoices(enum { red, green, blue }));
}

const ManyValues = blk: {
    @setEvalBranchQuota(1_000_000);
    var names: [1200][:0]const u8 = undefined;
    var values: [1200]u16 = undefined;
    for (&names, &values, 0..) |*n, *v, i| {
        n.* = std.fmt.comptimePrint("a_value_{d}", .{i});
        v.* = i;
    }
    break :blk @Enum(u16, .exhaustive, &names, &values);
};

test "an enum of 1200 values lists them all without a quota of the caller's" {
    const text = comptime enumChoices(ManyValues);
    try testing.expect(std.mem.startsWith(u8, text, "a_value_0, "));
    try testing.expect(std.mem.endsWith(u8, text, "a_value_1199"));
}
