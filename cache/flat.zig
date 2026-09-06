//! What a `Space` may hold, decided while compiling.
//!
//! A cache entry outlives the call that wrote it — that is the entire point of
//! one — and in a language with no garbage collector that makes **a pointer
//! the one thing it cannot keep**. Storing `Cart{ .name = "…" }` would store
//! eight bytes of address, and reading it back a minute later would hand a
//! handler an address belonging to a request that ended. Go's cache stores
//! `interface{}` and gets away with it because a collector is holding the
//! other end.
//!
//! So a value is one of two things, and **which one it is decides the shape of
//! `get`** rather than being a flag the caller sets:
//!
//! | the value | how it is stored | what `get` looks like |
//! |---|---|---|
//! | flat — no pointer anywhere in it | the bytes of the value | `get(key) ?V` |
//! | `[]const u8` | the bytes themselves | `get(key, buf) ?[]const u8` |
//!
//! A flat value needs no buffer from anybody, because its size is known while
//! compiling and it comes back by value. Bytes need one, because their size is
//! not — and the buffer is the caller's, which is what keeps the whole module
//! free of an allocator.
//!
//! Anything else is refused by name, with the field that did it
//! ([ADR 0138](../docs/adr/0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)).

const std = @import("std");

/// The largest value an entry can hold, being what the slot's 16-bit length
/// can say. A flat value over it is refused while compiling; a `[]const u8`
/// over it is `error.TooLarge`.
pub const max_value = std.math.maxInt(u16);

/// Which of the two shapes a `Space` has. Read from the value type, never
/// chosen.
pub const Kind = enum { flat, bytes };

/// `.bytes` for `[]const u8`, `.flat` for anything with no pointer in it, and
/// a Refusal naming the field for everything else.
pub fn kindOf(comptime V: type, comptime what: []const u8) Kind {
    if (V == []const u8 or V == []u8) return .bytes;
    ensureFlat(V, what, what);
    if (@sizeOf(V) > max_value) @compileError(std.fmt.comptimePrint(
        "nilo: a cached {s} is {d} bytes, and a cache entry holds at most {d}.\n" ++
            "  The length is stored in 16 bits so that four ways of a bucket are one" ++
            " cache line, which is what keeps a lookup to one line touched (ADR 0138).\n" ++
            "  Something this size wants a `Space` of `[]const u8` and an encoding" ++
            " of your own, or it wants to be smaller.",
        .{ what, @sizeOf(V), max_value },
    ));
    return .flat;
}

/// Walk the type and stop at the first thing that could not survive being
/// copied into a ring and back out a minute later. `path` names where it was
/// found, so `Cart.lines[0].label` reads as itself rather than as "a pointer".
fn ensureFlat(comptime V: type, comptime what: []const u8, comptime path: []const u8) void {
    switch (@typeInfo(V)) {
        .int, .float, .bool, .@"enum" => {},
        .array => |a| ensureFlat(a.child, what, path ++ "[0]"),
        .vector => |v| ensureFlat(v.child, what, path ++ "[0]"),
        .optional => |o| ensureFlat(o.child, what, path ++ ".?"),
        .@"struct" => |s| for (s.fields) |f| ensureFlat(f.type, what, path ++ "." ++ f.name),
        .@"union" => |u| {
            if (u.tag_type == null) @compileError(
                "nilo: a cached " ++ what ++ " cannot keep `" ++ path ++
                    "`, which is an untagged union.\n" ++
                    "  Reading one back means knowing which field was written, and an" ++
                    " untagged union does not carry that. Give it a tag.",
            );
            for (u.fields) |f| ensureFlat(f.type, what, path ++ "." ++ f.name);
        },
        .pointer => @compileError(
            "nilo: a cached " ++ what ++ " cannot keep `" ++ path ++
                "`, which is a pointer.\n" ++
                "  A cache entry outlives the call that wrote it and the memory behind" ++
                " a pointer does not, so reading it back would hand a handler an" ++
                " address that is nobody's any more.\n" ++
                "  Store the bytes inline as a `[N]u8`, or encode the value yourself" ++
                " and use a `Space` of `[]const u8`.",
        ),
        .void => @compileError(
            "nilo: a cached " ++ what ++ " cannot keep `" ++ path ++
                "`, which is `void`.\n" ++
                "  A cache of nothing answers every question with the same silence." ++
                " If the question is whether a key is present, cache a `bool`.",
        ),
        else => @compileError(
            "nilo: a cached " ++ what ++ " cannot keep `" ++ path ++ "`, which is a " ++
                @tagName(@typeInfo(V)) ++ ".\n" ++
                "  A cache entry is bytes copied into a ring and copied back out, so" ++
                " what it holds has to be a value with no pointer in it.\n" ++
                "  Encode it yourself and use a `Space` of `[]const u8`.",
        ),
    }
}

/// The value's bytes, for a flat V. A plain copy rather than a `@bitCast`,
/// because padding inside a struct is not a bit pattern anybody promised and
/// a copy does not care.
pub fn asBytes(comptime V: type, value: *const V) []const u8 {
    return @as([*]const u8, @ptrCast(value))[0..@sizeOf(V)];
}

/// The value's bytes, to be written into. The same view as `asBytes` with the
/// const taken off, so a read can land in the caller's value rather than in a
/// buffer on the way to it.
pub fn asWritableBytes(comptime V: type, value: *V) []u8 {
    return @as([*]u8, @ptrCast(value))[0..@sizeOf(V)];
}

/// And back. `bytes` is unaligned — it points into a ring — which is exactly
/// why this is a copy and not a cast.
pub fn fromBytes(comptime V: type, bytes: []const u8) V {
    std.debug.assert(bytes.len == @sizeOf(V));
    var value: V = undefined;
    @memcpy(@as([*]u8, @ptrCast(&value))[0..@sizeOf(V)], bytes);
    return value;
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

test "a struct of numbers, enums and arrays is flat" {
    const Cart = struct {
        owner: u64,
        items: u16,
        currency: enum { idr, usd },
        label: [16]u8,
        discount: ?f32,
    };
    try testing.expectEqual(Kind.flat, comptime kindOf(Cart, "Cart"));
}

test "a slice of bytes is the other shape" {
    try testing.expectEqual(Kind.bytes, comptime kindOf([]const u8, "page"));
}

test "a flat value survives the trip through bytes" {
    const Cart = struct { owner: u64, items: u16, label: [4]u8 };
    const before: Cart = .{ .owner = 42, .items = 3, .label = "cart".* };

    // Through an unaligned position, which is what a ring hands back.
    var ring: [64]u8 = undefined;
    const at = 7;
    @memcpy(ring[at..][0..@sizeOf(Cart)], asBytes(Cart, &before));

    const after = fromBytes(Cart, ring[at..][0..@sizeOf(Cart)]);
    try testing.expectEqual(before.owner, after.owner);
    try testing.expectEqual(before.items, after.items);
    try testing.expectEqualStrings(&before.label, &after.label);
}
