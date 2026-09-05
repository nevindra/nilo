//! The name of a type as the person reading the message knows it.
//!
//! `@typeName` spells a type with the file it was declared in, and nilo's
//! files are not files anybody using nilo has opened. A resolver that handed
//! back the wrong type was told it returned `str.Str` — a true sentence about
//! a source tree the reader does not have, and one that sends them looking
//! for a `str` they never imported. Their import line says `nilo`, so that
//! is the name the message uses.
//!
//! **A type says its own name, and a type of the reader's cannot.** This used
//! to be a table of `file.Type` substrings, which matched on the reader's file
//! name exactly as readily as on nilo's: an application with `src/room.zig` in
//! it was told its `Room` was `nilo.Room`, which is this file's own failure
//! running backwards ([ADR 0122](../docs/adr/0122-a-type-says-its-own-name.md)).
//! Nothing in a name can tell the two apart — `@typeName` spells a type as its
//! path from *its own module's root*, so a project rooted at `src/main.zig`
//! spells a sibling's type `room.Room`, byte for byte what nilo spells its own.
//!
//! So nilo's own types carry `pub const nilo_type_name`, and this file reads
//! it. It imports nothing but `std`, which is what makes it impossible for a
//! type to be unnameable here because of an import cycle.

const std = @import("std");

/// The declaration a nilo type names itself with.
pub const marker = "nilo_type_name";

/// What to call `T` in a message. Every type name nilo's own compile errors
/// print goes through here.
pub fn of(comptime T: type) []const u8 {
    comptime {
        return ours(T) orelse @typeName(T);
    }
}

/// nilo's name for `T`, or null for a type this framework did not declare —
/// which is the reader's own type, and already carries the file they wrote it
/// in.
///
/// The wrappers are taken apart rather than printed, because `?nilo.Str` and
/// `[]nilo.Header` are what a message wants and `@typeName` would spell the
/// child with its file in front. A wrapper around somebody else's type comes
/// back null, so `?u32` is left to `@typeName` and stays exactly what it was.
fn ours(comptime T: type) ?[]const u8 {
    comptime {
        if (declared(T)) |name| return name;
        return switch (@typeInfo(T)) {
            .optional => |o| if (ours(o.child)) |inner| "?" ++ inner else null,
            .pointer => |p| switch (p.size) {
                .one => if (ours(p.child)) |inner|
                    (if (p.is_const) "*const " else "*") ++ inner
                else
                    null,
                // A sentinel is part of how a slice is spelled and this does
                // not try to reproduce it, so `[:0]nilo.Str` — which nothing
                // has ever produced — keeps its own name rather than being
                // spelled wrong.
                .slice => if (p.sentinel() == null) (if (ours(p.child)) |inner|
                    (if (p.is_const) "[]const " else "[]") ++ inner
                else
                    null) else null,
                else => null,
            },
            else => null,
        };
    }
}

/// The name a type gives itself, for the types that can hold a declaration at
/// all. A pointer, an integer or a function type cannot, which is why this
/// answers null for them rather than refusing to compile.
fn declared(comptime T: type) ?[]const u8 {
    comptime {
        return switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => if (@hasDecl(T, marker))
                @field(T, marker)
            else
                null,
            else => null,
        };
    }
}

/// Whether nilo names `T` itself.
///
/// The question `http.zig`'s suite asks of every type this module exports, so
/// that a new one shipped without a name is a compile error rather than a
/// message naming a file the reader never imported (ADR 0095).
pub fn covers(comptime T: type) bool {
    comptime {
        return ours(T) != null;
    }
}

const testing = std.testing;

/// Stand-ins for a nilo type and a reader's, since this file imports neither
/// half of the framework and both halves are one declaration apart.
const OurRoom = struct {
    pub const nilo_type_name = "nilo.Room";
};
const TheirRoom = struct {};

test "a nilo type is named the way the import line names it" {
    try testing.expectEqualStrings("nilo.Room", comptime of(OurRoom));
    try testing.expect(comptime covers(OurRoom));
}

test "a type of the reader's own keeps the file they wrote it in" {
    // The whole of ADR 0122 in two lines: these two types are spelled the same
    // way by `@typeName` in a real project, and only one of them is nilo's.
    try testing.expectEqualStrings(@typeName(TheirRoom), comptime of(TheirRoom));
    try testing.expect(!comptime covers(TheirRoom));
    try testing.expectEqualStrings("u32", comptime of(u32));
    try testing.expect(!comptime covers(u32));
}

test "a wrapper around a nilo type is taken apart, and one around anybody else's is not" {
    try testing.expectEqualStrings("?nilo.Room", comptime of(?OurRoom));
    try testing.expectEqualStrings("[]const nilo.Room", comptime of([]const OurRoom));
    try testing.expectEqualStrings("[]nilo.Room", comptime of([]OurRoom));
    try testing.expectEqualStrings("*const nilo.Room", comptime of(*const OurRoom));

    // Somebody else's type inside a wrapper is left alone, spelling and all.
    try testing.expectEqualStrings(@typeName(?TheirRoom), comptime of(?TheirRoom));
    try testing.expectEqualStrings("?u32", comptime of(?u32));
    try testing.expectEqualStrings("[]const u8", comptime of([]const u8));
    try testing.expectEqualStrings(@typeName([:0]const u8), comptime of([:0]const u8));
}

test "a type that cannot hold a declaration is left to @typeName" {
    // A function type is the one nilo exports that this is true of —
    // `Middleware` — and it is a stated gap rather than an oversight.
    const F = *const fn (u32) void;
    try testing.expectEqualStrings(@typeName(F), comptime of(F));
    try testing.expect(!comptime covers(F));
}
