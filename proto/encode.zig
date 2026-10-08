//! Writing a message from the same struct that reads one (ADR 245).
//!
//! **A message is sized once and written once.** `encodedSize` walks the
//! value and answers the exact byte count, so a caller can allocate a buffer
//! the right size the first time, or check that a frame fits, before a byte is
//! written. `encodeInto` then fills that buffer from the end toward the start
//! (`wire.Writer`), which is what makes a nested message's length prefix free:
//! it is the distance the position moved while writing the message. prost
//! sizes each nested message again at every level, which is quadratic in
//! depth, and a decoder's `TooDeep` at 100 levels is the same shape of limit.
//!
//! **Fields are written in field number order**, whatever order the struct
//! declares them, so one value is always one byte string. Proto3's rules: a
//! scalar at its zero value is left out, a `?X` scalar (proto3 `optional`) and
//! a message that is present are always written, and an active oneof member is
//! written even when it is zero, because being the member is the information.
//! A repeated number is written packed unless its `wire` entry says
//! `.unpacked`.

const std = @import("std");
const wire = @import("wire.zig");
const schema = @import("schema.zig");

const Allocator = std.mem.Allocator;
const Writer = wire.Writer;
const Spec = schema.Spec;
const varintLen = wire.varintLen;

/// `v` encoded, in memory `gpa` owns: one allocation of exactly the size.
pub fn encode(comptime T: type, gpa: Allocator, v: T) error{OutOfMemory}![]u8 {
    const out = try gpa.alloc(u8, encodedSize(T, v));
    return encodeInto(T, out, v) catch unreachable;
}

/// `v` encoded into the start of `buf`; the bytes are the front of `buf`, as
/// many as `encodedSize` says. `error.NoSpaceLeft` before anything is written
/// if `buf` is short.
pub fn encodeInto(comptime T: type, buf: []u8, v: T) error{NoSpaceLeft}![]u8 {
    const n = encodedSize(T, v);
    if (buf.len < n) return error.NoSpaceLeft;
    var w: Writer = .{ .buf = buf[0..n], .pos = n };
    writeMessage(T, &w, v);
    std.debug.assert(w.pos == 0);
    return buf[0..n];
}

/// How many bytes `v` encodes to.
pub fn encodedSize(comptime T: type, v: T) usize {
    const specs = comptime schema.specsOf(T);
    var n: usize = 0;
    inline for (specs) |s| {
        const F = @FieldType(T, s.field);
        const fv = @field(v, s.field);
        const key_len = comptime varintLen(@as(u64, s.number) << 3);
        if (comptime s.member.len > 0) {
            const U = schema.Unwrapped(F);
            if (fv) |u| {
                if (u == @field(std.meta.Tag(U), s.member)) {
                    const mv = @field(u, s.member);
                    if (comptime s.kind == .message) {
                        const l = encodedSize(@TypeOf(mv), mv);
                        n += key_len + varintLen(l) + l;
                    } else {
                        n += key_len + payloadLen(s.scalar, mv);
                    }
                }
            }
        } else switch (comptime s.kind) {
            .scalar => {
                if (comptime s.optional) {
                    if (fv) |x| n += key_len + payloadLen(s.scalar, x);
                } else if (!isZero(s.scalar, fv)) {
                    n += key_len + payloadLen(s.scalar, fv);
                }
            },
            .message => {
                const M = schema.Unwrapped(F);
                const maybe: ?M = fv;
                if (maybe) |m| {
                    const l = encodedSize(M, m);
                    n += key_len + varintLen(l) + l;
                }
            },
            .repeated => {
                const C = @typeInfo(F).pointer.child;
                if (comptime s.elem_message) {
                    for (fv) |e| {
                        const l = encodedSize(C, e);
                        n += key_len + varintLen(l) + l;
                    }
                } else if (comptime s.isText()) {
                    for (fv) |e| n += key_len + payloadLen(s.scalar, e);
                } else if (comptime s.packed_run) {
                    if (fv.len > 0) {
                        var l: usize = 0;
                        for (fv) |e| l += payloadLen(s.scalar, e);
                        n += key_len + varintLen(l) + l;
                    }
                } else {
                    for (fv) |e| n += key_len + payloadLen(s.scalar, e);
                }
            },
        }
    }
    return n;
}

/// Write `v` ending at `w.pos`, last field first.
fn writeMessage(comptime T: type, w: *Writer, v: T) void {
    const specs = comptime schema.sortedSpecs(T);
    inline for (0..specs.len) |j| {
        const s = comptime specs[specs.len - 1 - j];
        const F = @FieldType(T, s.field);
        const fv = @field(v, s.field);
        if (comptime s.member.len > 0) {
            const U = schema.Unwrapped(F);
            if (fv) |u| {
                if (u == @field(std.meta.Tag(U), s.member)) {
                    const mv = @field(u, s.member);
                    if (comptime s.kind == .message) {
                        writeNested(@TypeOf(mv), w, mv, s.number);
                    } else {
                        writePayload(s.scalar, w, mv);
                        w.key(s.number, comptime schema.scalarWire(s.scalar));
                    }
                }
            }
        } else switch (comptime s.kind) {
            .scalar => {
                if (comptime s.optional) {
                    if (fv) |x| {
                        writePayload(s.scalar, w, x);
                        w.key(s.number, comptime schema.scalarWire(s.scalar));
                    }
                } else if (!isZero(s.scalar, fv)) {
                    writePayload(s.scalar, w, fv);
                    w.key(s.number, comptime schema.scalarWire(s.scalar));
                }
            },
            .message => {
                const M = schema.Unwrapped(F);
                const maybe: ?M = fv;
                if (maybe) |m| writeNested(M, w, m, s.number);
            },
            .repeated => {
                const C = @typeInfo(F).pointer.child;
                if (comptime s.elem_message) {
                    var i = fv.len;
                    while (i > 0) {
                        i -= 1;
                        writeNested(C, w, fv[i], s.number);
                    }
                } else if (comptime s.isText()) {
                    var i = fv.len;
                    while (i > 0) {
                        i -= 1;
                        writePayload(s.scalar, w, fv[i]);
                        w.key(s.number, .len);
                    }
                } else if (comptime s.packed_run) {
                    if (fv.len > 0) {
                        const end = w.pos;
                        var i = fv.len;
                        while (i > 0) {
                            i -= 1;
                            writePayload(s.scalar, w, fv[i]);
                        }
                        w.varint(end - w.pos);
                        w.key(s.number, .len);
                    }
                } else {
                    var i = fv.len;
                    while (i > 0) {
                        i -= 1;
                        writePayload(s.scalar, w, fv[i]);
                        w.key(s.number, comptime schema.scalarWire(s.scalar));
                    }
                }
            },
        }
    }
}

fn writeNested(comptime M: type, w: *Writer, m: M, number: u32) void {
    const end = w.pos;
    writeMessage(M, w, m);
    w.varint(end - w.pos);
    w.key(number, .len);
}

/// The 64 bits a number travels as, before it is cut to a varint or a fixed
/// width.
inline fn scalarBits(comptime sc: schema.Scalar, value: anytype) u64 {
    return switch (sc) {
        .bool => @intFromBool(value),
        .int32 => @bitCast(@as(i64, value)),
        .int64 => @bitCast(value),
        .uint32 => value,
        .uint64 => value,
        .sint32 => (@as(u32, @bitCast(value)) << 1) ^ @as(u32, @bitCast(value >> 31)),
        .sint64 => (@as(u64, @bitCast(value)) << 1) ^ @as(u64, @bitCast(value >> 63)),
        .fixed32 => value,
        .fixed64 => value,
        .sfixed32 => @as(u32, @bitCast(value)),
        .sfixed64 => @bitCast(value),
        .float => @as(u32, @bitCast(value)),
        .double => @bitCast(value),
        .enumeration => @bitCast(@as(i64, @backingInt(value))),
        .string, .bytes => unreachable,
    };
}

inline fn isZero(comptime sc: schema.Scalar, value: anytype) bool {
    return switch (sc) {
        .string, .bytes => value.len == 0,
        else => scalarBits(sc, value) == 0,
    };
}

inline fn payloadLen(comptime sc: schema.Scalar, value: anytype) usize {
    return switch (comptime schema.scalarWire(sc)) {
        .varint => varintLen(scalarBits(sc, value)),
        .fixed64 => 8,
        .fixed32 => 4,
        .len => varintLen(value.len) + value.len,
        else => unreachable,
    };
}

inline fn writePayload(comptime sc: schema.Scalar, w: *Writer, value: anytype) void {
    switch (comptime schema.scalarWire(sc)) {
        .varint => w.varint(scalarBits(sc, value)),
        .fixed64 => w.fixed64(scalarBits(sc, value)),
        .fixed32 => w.fixed32(@truncate(scalarBits(sc, value))),
        .len => {
            w.raw(value);
            w.varint(value.len);
        },
        else => unreachable,
    }
}
