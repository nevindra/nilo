//! The converter nilo made me write.
//!
//! `guide/services.md` gives two rules and they are both right. **A service
//! takes `[]const u8`, not `Str`** — a service that never names the request
//! type cannot accidentally store one. And **a read hands back a copy in the
//! request arena**, because another thread can delete the row between a handler
//! returning and nilo writing the response.
//!
//! On one flat struct that is two `dupe` calls and the guide shows them inline.
//! On a document with an optional `meta`, a list of `sections` each holding a
//! list of `lines`, and a list of `tags`, it is the same walk written three
//! times — in, out, and at the boundary where `Str` becomes `[]const u8` — and
//! three hand-written walks of one shape is three places to forget a field.
//!
//! So it is written once, by reflection, and the three uses differ only in
//! which allocator and whether the bytes are duplicated:
//!
//! | | |
//! |---|---|
//! | at the handler boundary | `into(Incoming(Text), arena, body, .borrow)` — `Str` → `[]const u8`, structure only |
//! | into the store | `into(Incoming(Text), row_arena, incoming, .own)` — the deep copy a row owns |
//! | back out of the store | `into(Doc, arena, row.doc, .own)` — under the lock, into the request |
//!
//! `.borrow` allocates for the *slices* and not for the strings, which is what
//! makes the extra walk at the boundary cheap: the bytes are already in the
//! request arena, and the request is what they have to outlive.
//!
//! Whether a framework whose central claim is "your types are the contract"
//! should ship this rather than leaving it to every application is a question
//! for `DX.md`, not for this file.

const std = @import("std");
const nilo = @import("nilo_http");
const Allocator = std.mem.Allocator;

pub const How = enum {
    /// The bytes already live long enough. Copy the shape, point at them.
    borrow,
    /// The bytes have to outlive where they came from. Copy them too.
    own,
};

/// Build a `Target` out of anything with the same field names, turning every
/// `Str` into the `[]const u8` underneath it on the way.
pub fn into(comptime Target: type, gpa: Allocator, source: anytype, comptime how: How) Allocator.Error!Target {
    const Source = @TypeOf(source);
    if (Source == Target and Target != []const u8) {
        // Identical shapes still need walking when the bytes must be owned.
        if (how == .borrow) return source;
    }

    // Text, from either side of the boundary. A `Str` is a struct with a
    // `view()`; a `[]const u8` is already the bytes.
    if (Target == []const u8) {
        const bytes = switch (@typeInfo(Source)) {
            .@"struct" => source.view(),
            else => source,
        };
        return if (how == .own) try gpa.dupe(u8, bytes) else bytes;
    }

    return switch (@typeInfo(Target)) {
        .optional => |o| if (isNull(source)) null else try into(o.child, gpa, unwrap(source), how),

        .@"struct" => blk: {
            var out: Target = undefined;
            inline for (@typeInfo(Target).@"struct".fields) |f| {
                @field(out, f.name) = try into(f.type, gpa, @field(source, f.name), how);
            }
            break :blk out;
        },

        .pointer => |p| blk: {
            if (p.size != .slice) @compileError("copy.into: " ++ @typeName(Target) ++ " is a pointer that is not a slice");
            const items = try gpa.alloc(p.child, source.len);
            for (items, source) |*dst, src| dst.* = try into(p.child, gpa, src, how);
            break :blk items;
        },

        // An int, a float, a bool, an enum: the same type on both sides.
        else => source,
    };
}

fn isNull(source: anytype) bool {
    return switch (@typeInfo(@TypeOf(source))) {
        .optional => source == null,
        .null => true,
        else => false,
    };
}

fn unwrap(source: anytype) @typeInfo(@TypeOf(source)).optional.child {
    return source.?;
}

// ---- tests ----

const Text = []const u8;

fn Pair(comptime T: type) type {
    return struct { name: T, notes: []const T = &.{} };
}

test "a nested shape crosses the boundary in one call" {
    const arena = std.testing.allocator;

    const source: Pair(Text) = .{ .name = "wati", .notes = &.{ "satu", "dua" } };
    const copied = try into(Pair(Text), arena, source, .own);
    defer {
        arena.free(copied.name);
        for (copied.notes) |n| arena.free(n);
        arena.free(copied.notes);
    }

    try std.testing.expectEqualStrings("wati", copied.name);
    try std.testing.expectEqual(@as(usize, 2), copied.notes.len);
    try std.testing.expectEqualStrings("dua", copied.notes[1]);
    // Owned means owned: a different pointer, not the same one.
    try std.testing.expect(copied.name.ptr != source.name.ptr);
}

test "borrowing copies the shape and not the bytes" {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);

    const source: Pair(Text) = .{ .name = "budi", .notes = &.{"tiga"} };
    const copied = try into(Pair(Text), fba.allocator(), source, .borrow);

    try std.testing.expectEqual(source.name.ptr, copied.name.ptr);
}

test "an optional that is null stays null" {
    const Holder = struct { meta: ?Pair(Text) };
    const copied = try into(Holder, std.testing.allocator, Holder{ .meta = null }, .own);
    try std.testing.expectEqual(@as(?Pair(Text), null), copied.meta);
}
