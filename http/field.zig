//! Whether a field of a request may be left out, and what it is then.
//!
//! **One rule, asked by every reader and every describer** (ADR 011, ADR 030):
//! a field with a default may be absent and is its default; a `?T` may be
//! absent and is null; any other field is the client's to send. The same three
//! sentences hold in a query string, a form and a JSON body, nested as deep as
//! the body goes, and the API description says the same thing.
//!
//! It used to be written out in six places (`form.fill`, `form.fillCollecting`,
//! `typed.queryValue`, `typed.queryValueCollecting`, `ctx.collectBadBody` and
//! `ctx.describeObject`), and they drifted: a query and a form read an absent
//! `?T` as null while `std.json` refused it in a body, and `openapi.zig` and the
//! sentence listing what an endpoint takes both said a default was the only
//! way to be optional. A rule held in six copies is six chances for the next
//! change to reach five of them.
//!
//! Decided while compiling, so there is no cost at run time: a `FieldRule` is a
//! namespace of constants and one function that returns a constant.
//!
//! `Patch(T)` is not an optional, and asks nothing different of this: it is
//! optional by the `= .absent` its author writes, a default like any other, and
//! what "absent" is there is the third answer `?T` cannot give (ADR 025).

const std = @import("std");

/// The rule for one field of a struct, read off its type and its attributes.
pub fn FieldRule(comptime F: type, comptime attrs: std.lang.Type.Struct.FieldAttributes) type {
    return struct {
        /// The field's type with the `?` taken off, for the conversion that
        /// reads what arrived.
        pub const Inner = switch (@typeInfo(F)) {
            .optional => |o| o.child,
            else => F,
        };

        /// Whether a request may leave the field out: it has a default, or it
        /// is a `?T`. What stays is the field the client has to send.
        pub const may_be_absent: bool = attrs.defaultValue(F) != null or @typeInfo(F) == .optional;

        /// What the field is when the request left it out: its default, or
        /// null. Asking it of a field that has to be sent is a compile error,
        /// because there is no value to answer with.
        pub fn absent() F {
            if (comptime attrs.defaultValue(F)) |default| return default;
            if (comptime @typeInfo(F) == .optional) return null;
            @compileError("nilo: a field that may not be absent has no value to be when it is");
        }
    };
}

const testing = std.testing;

fn attrsOf(comptime T: type, comptime i: usize) std.lang.Type.Struct.FieldAttributes {
    return @typeInfo(T).@"struct".field_attrs[i];
}

test "a field is optional by its default or by its ?, and by nothing else" {
    const T = struct {
        sent: u32,
        defaulted: u32 = 7,
        maybe: ?u32,
        maybe_defaulted: ?u32 = 3,
        text: []const u8,
    };
    const sent = FieldRule(u32, attrsOf(T, 0));
    const defaulted = FieldRule(u32, attrsOf(T, 1));
    const maybe = FieldRule(?u32, attrsOf(T, 2));
    const maybe_defaulted = FieldRule(?u32, attrsOf(T, 3));
    const text = FieldRule([]const u8, attrsOf(T, 4));

    try testing.expect(!sent.may_be_absent);
    try testing.expect(!text.may_be_absent);
    try testing.expect(defaulted.may_be_absent);
    try testing.expect(maybe.may_be_absent);
    try testing.expect(maybe_defaulted.may_be_absent);

    try testing.expectEqual(@as(u32, 7), defaulted.absent());
    try testing.expectEqual(@as(?u32, null), maybe.absent());
    // A default wins over the null a `?` would have been.
    try testing.expectEqual(@as(?u32, 3), maybe_defaulted.absent());

    try testing.expect(maybe.Inner == u32);
    try testing.expect(sent.Inner == u32);
}
