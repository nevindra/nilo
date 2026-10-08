//! Reading a message into a plain struct (ADR 245).
//!
//! Everything here is a loop over `schema.specsOf(T)` that the compiler
//! unrolls, so a message type costs the code for its own fields and nothing
//! else, and no run-time table, reflection or allocation exists beyond what
//! the input needs. What it does and why:
//!
//! **One table load finds the field.** A key is a varint, and for a field
//! number under 16 it is one byte: `number << 3 | wire type`. The decoder
//! reads that byte and indexes a 128-entry table built while compiling, whose
//! entry is the field to fill (or 0xff for anything that is not exactly a
//! known field with a wire type it can take). A hit is a jump and the field's
//! own code with the wire type already checked; a miss falls to the general
//! path, which decodes the whole key and compares the declared numbers one by
//! one. The spike compared every number in turn for every field.
//!
//! **A repeated field is counted before it is filled**, so its slice is
//! exactly as long as it needs to be and is never grown or copied. That is the
//! second pass over a message that has any repeated field; a message with none
//! is read once. The counting pass is its own loop with its own table: it only
//! steps over fields, and it steps over a nested message by its length
//! without looking inside.
//!
//! **Those slices are carved from a slab, not asked of the allocator one at a
//! time.** An `ArenaAllocator` call is a compare-and-swap loop in 0.16, and a
//! request of 500 records asked for 500 of them. The decoder asks the arena
//! for one block sized from the input, hands exact slices out of it, and gives
//! the unused tail of the last block back. Arena calls for the 1,000 row
//! request in `bench/result/proto.md` went from 1,039 to 38 (a hand-written
//! decoder: 35). It changed no time there: it is the allocation count, the
//! hard axis, that it holds.
//!
//! **Strings and bytes borrow the input**, so a decoded message lives exactly
//! as long as the bytes it was read from and the arena together.
//!
//! **Nothing here panics on input.** Every length is checked against what is
//! left before it is used, a count is never taken on trust from a length, and
//! nesting is bounded by `Options.max_depth` the way prost bounds it.

const std = @import("std");
const wire = @import("wire.zig");
const schema = @import("schema.zig");

const Allocator = std.mem.Allocator;
const Error = wire.Error;
const Reader = wire.Reader;
const WireType = wire.WireType;
const Key = wire.Key;
const Spec = schema.Spec;

pub const Options = struct {
    /// How deep messages may nest before `error.TooDeep`. prost's limit by
    /// default, so both refuse the same input.
    max_depth: u32 = wire.max_depth,
};

/// Read one `T` from `bytes`. Text and bytes in the result borrow `bytes`;
/// repeated fields are allocated from `arena`.
pub fn decode(comptime T: type, arena: Allocator, bytes: []const u8) Error!T {
    return decodeWith(T, arena, bytes, .{});
}

pub fn decodeWith(comptime T: type, arena: Allocator, bytes: []const u8, options: Options) Error!T {
    var v: T = comptime schema.defaults(T);
    try mergeWith(T, arena, &v, bytes, options);
    return v;
}

/// Apply the fields in `bytes` on top of `v`: protobuf's merge. A scalar that
/// is present replaces the old one, a repeated field is appended to, and a
/// message field is merged into field by field.
pub fn merge(comptime T: type, arena: Allocator, v: *T, bytes: []const u8) Error!void {
    return mergeWith(T, arena, v, bytes, .{});
}

pub fn mergeWith(comptime T: type, arena: Allocator, v: *T, bytes: []const u8, options: Options) Error!void {
    var d: Decoder = .{ .arena = arena, .slab_size = std.math.clamp(bytes.len *| 3, 1024, 1 << 18) };
    try mergeMessage(T, &d, v, bytes, options.max_depth);
    d.finish();
}

/// Hands out the slices of repeated fields, exactly sized, from blocks the
/// arena gave it.
const Decoder = struct {
    arena: Allocator,
    slab_size: usize,
    block: ?[]align(16) u8 = null,
    used: usize = 0,

    const slab_align: std.mem.Alignment = .@"16";

    fn slice(d: *Decoder, comptime C: type, n: usize) Error![]C {
        if (@sizeOf(C) == 0) return @as([*]C, @ptrFromInt(@alignOf(C)))[0..n];
        const size = std.math.mul(usize, n, @sizeOf(C)) catch return error.OutOfMemory;
        if (@alignOf(C) <= 16 and size <= d.slab_size / 2) {
            if (d.carve(C, n, size)) |got| return got;
            d.trim();
            d.block = try d.arena.alignedAlloc(u8, slab_align, d.slab_size);
            d.used = 0;
            return d.carve(C, n, size).?;
        }
        return d.arena.alloc(C, n);
    }

    fn carve(d: *Decoder, comptime C: type, n: usize, size: usize) ?[]C {
        const block = d.block orelse return null;
        const start = std.mem.alignForward(usize, d.used, @alignOf(C));
        if (start > block.len or block.len - start < size) return null;
        d.used = start + size;
        return @as([*]C, @ptrCast(@alignCast(block.ptr + start)))[0..n];
    }

    /// Give back what the last block did not use. An arena takes back the
    /// tail of its newest allocation; another allocator may say no.
    fn trim(d: *Decoder) void {
        const block = d.block orelse return;
        if (d.used == 0) {
            d.arena.free(block);
        } else if (d.used < block.len) {
            _ = d.arena.resize(block, d.used);
        }
        d.block = null;
    }

    fn finish(d: *Decoder) void {
        d.trim();
    }
};

fn mergeMessage(comptime T: type, d: *Decoder, v: *T, bytes: []const u8, depth_left: u32) Error!void {
    const specs = comptime schema.specsOf(T);
    const repeated = comptime schema.repeatedCount(T);
    var fill: [repeated]usize = undefined;

    if (comptime repeated > 0) {
        var counts: [repeated]usize = @splat(0);
        try countPass(T, bytes, depth_left, &counts);
        inline for (specs, 0..) |s, i| {
            if (comptime s.kind == .repeated) {
                const ri = comptime schema.repeatedIndex(T, i);
                const C = @typeInfo(@FieldType(T, s.field)).pointer.child;
                const old = @field(v.*, s.field);
                fill[ri] = old.len;
                if (counts[ri] > 0) {
                    const fresh = try d.slice(C, old.len + counts[ri]);
                    @memcpy(fresh[0..old.len], old);
                    @field(v.*, s.field) = fresh;
                }
            }
        }
    }

    try readFields(T, d, v, bytes, depth_left, &fill);

    // A closed enum drops the numbers it does not name, so what was counted
    // may be more than what was kept.
    inline for (specs, 0..) |s, i| {
        if (comptime s.kind == .repeated and s.scalar == .enumeration and !s.elem_message) {
            const C = @typeInfo(@FieldType(T, s.field)).pointer.child;
            if (comptime schema.isClosedScalar(C)) {
                const ri = comptime schema.repeatedIndex(T, i);
                @field(v.*, s.field) = @field(v.*, s.field)[0..fill[ri]];
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Pass one: how many of each repeated field.
// ---------------------------------------------------------------------------

fn countPass(comptime T: type, buf: []const u8, depth_left: u32, counts: []usize) Error!void {
    const specs = comptime schema.specsOf(T);
    const F = schema.FastTable(T);
    var pos: usize = 0;
    while (pos < buf.len) {
        var c: u8 = 0;
        var number: u32 = undefined;
        var kind: WireType = undefined;
        const kb = buf[pos];
        if (kb < 0x80) {
            if (kb < 8) return error.InvalidKey;
            pos += 1;
            number = kb >> 3;
            kind = @fromBackingInt(@intCast(kb & 7));
            c = F.counts[kb];
        } else {
            const out = try wire.varintSlow(buf, pos);
            const k = try wire.splitKey(out.value);
            pos = out.pos;
            number = k.number;
            kind = k.wire;
            inline for (specs, 0..) |s, i| {
                if (comptime s.kind == .repeated) {
                    if (number == s.number) {
                        const ri = comptime schema.repeatedIndex(T, i);
                        if (kind == schema.specWire(s, false)) {
                            c = 1 + ri * 2;
                        } else if (comptime s.packable()) {
                            if (kind == .len) c = 1 + ri * 2 + 1;
                        }
                    }
                }
            }
        }
        switch (kind) {
            .varint => {
                if (pos >= buf.len) return error.Truncated;
                if (buf[pos] < 0x80) {
                    pos += 1;
                } else {
                    pos = (try wire.varintSlow(buf, pos)).pos;
                }
                if (c != 0) counts[(c - 1) >> 1] += 1;
            },
            .fixed64 => {
                if (buf.len - pos < 8) return error.Truncated;
                pos += 8;
                if (c != 0) counts[(c - 1) >> 1] += 1;
            },
            .fixed32 => {
                if (buf.len - pos < 4) return error.Truncated;
                pos += 4;
                if (c != 0) counts[(c - 1) >> 1] += 1;
            },
            .len => {
                if (pos >= buf.len) return error.Truncated;
                var n: u64 = buf[pos];
                if (n < 0x80) {
                    pos += 1;
                } else {
                    const out = try wire.varintSlow(buf, pos);
                    n = out.value;
                    pos = out.pos;
                }
                if (n > buf.len - pos) return error.Truncated;
                const len: usize = @intCast(n);
                if (c != 0) {
                    if (c & 1 == 1) {
                        // An odd value is one element; an even one is a run.
                        counts[(c - 1) >> 1] += 1;
                    } else {
                        counts[(c - 1) >> 1] += try packedCount(T, c, buf[pos..][0..len]);
                    }
                }
                pos += len;
            },
            .start_group, .end_group, _ => {
                var r: Reader = .{ .buf = buf, .pos = pos };
                try r.skip(.{ .number = number, .wire = kind }, depth_left);
                pos = r.pos;
            },
        }
    }
}

/// How many numbers a packed run holds. `c` names the repeated field, and
/// what it is decides how the run is cut.
fn packedCount(comptime T: type, c: u8, payload: []const u8) Error!usize {
    const specs = comptime schema.specsOf(T);
    const ri = (c - 1) >> 1;
    inline for (specs, 0..) |s, i| {
        if (comptime s.kind == .repeated and s.packable()) {
            if (ri == comptime schema.repeatedIndex(T, i)) {
                switch (comptime schema.scalarWire(s.scalar)) {
                    .varint => {
                        var n: usize = 0;
                        for (payload) |b| n += @intFromBool(b < 0x80);
                        if (payload.len > 0 and payload[payload.len - 1] >= 0x80) return error.Truncated;
                        return n;
                    },
                    .fixed64 => {
                        if (payload.len % 8 != 0) return error.Truncated;
                        return payload.len / 8;
                    },
                    .fixed32 => {
                        if (payload.len % 4 != 0) return error.Truncated;
                        return payload.len / 4;
                    },
                    else => unreachable,
                }
            }
        }
    }
    unreachable;
}

// ---------------------------------------------------------------------------
// Pass two: every field.
// ---------------------------------------------------------------------------

fn readFields(comptime T: type, d: *Decoder, v: *T, buf: []const u8, depth_left: u32, fill: []usize) Error!void {
    const specs = comptime schema.specsOf(T);
    const F = schema.FastTable(T);
    var r: Reader = .init(buf);
    while (r.pos < buf.len) {
        if (comptime F.actions.len > 0) {
            const kb = buf[r.pos];
            if (kb < 0x80) {
                const a = F.table[kb];
                if (a != schema.no_action) {
                    r.pos += 1;
                    switch (a) {
                        inline 0...F.actions.len - 1 => |ai| try applyField(T, F.actions[ai].spec, F.actions[ai].packed_run, d, v, &r, depth_left, fill),
                        else => unreachable,
                    }
                    continue;
                }
            }
        }
        // A key of two bytes or more, a field this type does not know, or a
        // known one with a wire type it cannot take.
        const k = try r.key();
        var known = false;
        inline for (specs, 0..) |s, i| {
            if (!known and k.number == s.number) {
                known = true;
                if (k.wire == comptime schema.specWire(s, false)) {
                    try applyField(T, i, false, d, v, &r, depth_left, fill);
                } else if (comptime s.packable()) {
                    if (k.wire != .len) return error.WrongWireType;
                    try applyField(T, i, true, d, v, &r, depth_left, fill);
                } else return error.WrongWireType;
            }
        }
        if (!known) try r.skip(k, depth_left);
    }
}

fn applyField(
    comptime T: type,
    comptime si: usize,
    comptime packed_run: bool,
    d: *Decoder,
    v: *T,
    r: *Reader,
    depth_left: u32,
    fill: []usize,
) Error!void {
    const s = comptime schema.specsOf(T)[si];
    const F = @FieldType(T, s.field);

    if (comptime s.member.len > 0) {
        const U = schema.Unwrapped(F);
        const M = @FieldType(U, s.member);
        if (comptime s.kind == .message) {
            const payload = try r.bytes();
            if (depth_left == 0) return error.TooDeep;
            // A member merges into itself and replaces any other.
            if (@field(v.*, s.field)) |*current| {
                if (current.* == @field(std.meta.Tag(U), s.member)) {
                    return mergeMessage(M, d, &@field(current.*, s.member), payload, depth_left - 1);
                }
            }
            var fresh: M = comptime schema.defaults(M);
            try mergeMessage(M, d, &fresh, payload, depth_left - 1);
            @field(v.*, s.field) = @unionInit(U, s.member, fresh);
        } else if (comptime schema.isClosedScalar(M)) {
            if (try readClosed(M, r)) |e| @field(v.*, s.field) = @unionInit(U, s.member, e);
        } else {
            @field(v.*, s.field) = @unionInit(U, s.member, try readScalar(s.scalar, M, r));
        }
        return;
    }

    switch (comptime s.kind) {
        .scalar => {
            const Z = schema.Unwrapped(F);
            if (comptime schema.isClosedScalar(Z)) {
                if (try readClosed(Z, r)) |e| @field(v.*, s.field) = e;
            } else {
                @field(v.*, s.field) = try readScalar(s.scalar, Z, r);
            }
        },
        .message => {
            const payload = try r.bytes();
            if (depth_left == 0) return error.TooDeep;
            const M = schema.Unwrapped(F);
            if (comptime @typeInfo(F) == .optional) {
                if (@field(v.*, s.field) == null) @field(v.*, s.field) = comptime schema.defaults(M);
                try mergeMessage(M, d, &@field(v.*, s.field).?, payload, depth_left - 1);
            } else {
                try mergeMessage(M, d, &@field(v.*, s.field), payload, depth_left - 1);
            }
        },
        .repeated => {
            const ri = comptime schema.repeatedIndex(T, si);
            const C = @typeInfo(F).pointer.child;
            const items: []C = @constCast(@field(v.*, s.field));
            if (comptime s.elem_message) {
                const payload = try r.bytes();
                if (depth_left == 0) return error.TooDeep;
                const slot = &items[fill[ri]];
                slot.* = comptime schema.defaults(C);
                fill[ri] += 1;
                try mergeMessage(C, d, slot, payload, depth_left - 1);
            } else if (comptime packed_run) {
                var run: Reader = .init(try r.bytes());
                while (run.pos < run.buf.len) try pushScalar(s.scalar, C, items, &fill[ri], &run);
            } else {
                try pushScalar(s.scalar, C, items, &fill[ri], r);
            }
        },
    }
}

inline fn pushScalar(comptime sc: schema.Scalar, comptime C: type, items: []C, at: *usize, r: *Reader) Error!void {
    if (comptime schema.isClosedScalar(C)) {
        if (try readClosed(C, r)) |e| {
            items[at.*] = e;
            at.* += 1;
        }
    } else {
        items[at.*] = try readScalar(sc, C, r);
        at.* += 1;
    }
}

/// A closed enum's value, or null where the number is not one it names.
inline fn readClosed(comptime E: type, r: *Reader) Error!?E {
    const raw: i32 = @bitCast(@as(u32, @truncate(try r.varint())));
    return std.enums.fromInt(E, raw);
}

/// One value, the wire type having been checked by whoever chose this field.
inline fn readScalar(comptime sc: schema.Scalar, comptime Z: type, r: *Reader) Error!Z {
    return switch (sc) {
        .bool => (try r.varint()) != 0,
        .int32 => @bitCast(@as(u32, @truncate(try r.varint()))),
        .int64 => @bitCast(try r.varint()),
        .uint32 => @truncate(try r.varint()),
        .uint64 => try r.varint(),
        .sint32 => blk: {
            const u: u32 = @truncate(try r.varint());
            break :blk @bitCast((u >> 1) ^ (0 -% (u & 1)));
        },
        .sint64 => blk: {
            const u = try r.varint();
            break :blk @bitCast((u >> 1) ^ (0 -% (u & 1)));
        },
        .fixed32 => try r.fixed32(),
        .fixed64 => try r.fixed64(),
        .sfixed32 => @bitCast(try r.fixed32()),
        .sfixed64 => @bitCast(try r.fixed64()),
        .float => @bitCast(try r.fixed32()),
        .double => @bitCast(try r.fixed64()),
        .enumeration => @fromBackingInt(@intCast(@as(i32, @bitCast(@as(u32, @truncate(try r.varint())))))),
        .string => blk: {
            const b = try r.bytes();
            if (!wire.validUtf8(b)) return error.InvalidUtf8;
            break :blk b;
        },
        .bytes => try r.bytes(),
    };
}
