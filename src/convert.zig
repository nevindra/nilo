//! Turning one piece of request text into the type a handler asked for.
//!
//! A path param, a query value and a form field all arrive as bytes and all
//! end up as a `u32`, a `Str`, a `bool` or an enum. They also all have to say
//! the same thing when the text does not fit, which is why this is one module
//! rather than three copies: `?page has to be a whole number, not "soon"` and
//! `"age" has to be a whole number, not "soon"` differ in the label and in
//! nothing else.
//!
//! `label` is comptime, so the message is assembled while compiling and the
//! failure path formats one runtime value.

const std = @import("std");
const fail = @import("fail.zig");
const str_mod = @import("str.zig");

const Str = str_mod.Str;

/// Whether request text can become a `T` at all — a `Str`, a number, a
/// `bool`, an enum, or any of those wrapped in `?`.
///
/// Asked while compiling, by whoever is about to promise a field can be
/// filled from a request. Answering here rather than at each call site is
/// what keeps `Query(T)` and `Form(T)` agreeing on what a field may be.
pub fn convertible(comptime T: type) bool {
    const Inner = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    if (Inner == Str) return true;
    return switch (@typeInfo(Inner)) {
        .int, .float, .bool, .@"enum" => true,
        else => false,
    };
}

/// Turn one piece of request text into the type the handler asked for.
/// `label` is how it is named back to the client — `:id` for a path param,
/// `?page` for a query one, `"email"` for a form field — so the same message
/// serves all three.
pub fn convert(comptime P: type, s: Str, comptime label: []const u8) !P {
    if (P == Str) return s;

    const text = s.view();
    return switch (@typeInfo(P)) {
        .int => std.fmt.parseInt(P, text, 10) catch
            return fail.badRequest(label ++ " has to be a whole number, not \"{s}\"", .{text}),
        .float => std.fmt.parseFloat(P, text) catch
            return fail.badRequest(label ++ " has to be a number, not \"{s}\"", .{text}),
        .bool => boolFrom(text) orelse
            return fail.badRequest(label ++ " has to be true or false, not \"{s}\"", .{text}),
        .@"enum" => std.meta.stringToEnum(P, text) orelse
            return fail.badRequest(
                label ++ " is not one of the known choices ({s}): \"{s}\"",
                .{ comptime enumChoices(P), text },
            ),
        else => comptime unreachable,
    };
}

fn boolFrom(text: []const u8) ?bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return null;
}

/// The names an enum's values answer to, for the message that says what was
/// expected. Built once at compile time.
pub fn enumChoices(comptime E: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ f.name;
        }
        return out;
    }
}

const testing = std.testing;

fn given(bytes: []const u8) Str {
    return Str.static(bytes);
}

test "the types request text can become" {
    try testing.expect(convertible(Str));
    try testing.expect(convertible(u32));
    try testing.expect(convertible(f64));
    try testing.expect(convertible(bool));
    try testing.expect(convertible(enum { a, b }));
    try testing.expect(convertible(?u32));
    try testing.expect(convertible(?Str));

    try testing.expect(!convertible([]const u8));
    try testing.expect(!convertible(struct { a: u32 }));
    try testing.expect(!convertible([4]u8));
}

test "text that fits becomes the value" {
    try testing.expectEqual(@as(u32, 42), try convert(u32, given("42"), "?page"));
    try testing.expectEqual(@as(f64, 1.5), try convert(f64, given("1.5"), "?ratio"));
    try testing.expectEqual(true, try convert(bool, given("true"), "?on"));
    try testing.expectEqualStrings("hi", (try convert(Str, given("hi"), "?q")).view());

    const Sort = enum { newest, oldest };
    try testing.expectEqual(Sort.oldest, try convert(Sort, given("oldest"), "?sort"));
}

test "text that does not fit fails with the label in it" {
    var in_flight = fail.InFlight{};
    in_flight.startRequest("GET", "/x");
    const bulkhead = @import("bulkhead.zig");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(error.Failed, convert(u32, given("soon"), "?page"));
    try testing.expectEqualStrings(
        "?page has to be a whole number, not \"soon\"",
        in_flight.failure.message(),
    );

    const Sort = enum { newest, oldest };
    try testing.expectError(error.Failed, convert(Sort, given("sideways"), "\"sort\""));
    try testing.expectEqualStrings(
        "\"sort\" is not one of the known choices (newest, oldest): \"sideways\"",
        in_flight.failure.message(),
    );
}

test "the choices an enum offers are listed in order" {
    try testing.expectEqualStrings("red, green, blue", comptime enumChoices(enum { red, green, blue }));
}
