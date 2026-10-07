//! nilo_proto: protobuf for plain Zig structs, and nothing else (ADR 245).
//!
//! A **tool module**, the sixth: pure functions over bytes, no event loop, and
//! it imports nothing, which is why `zig test proto/proto.zig` runs the whole
//! of it (ADR 038, ADR 039). It is the codec ADR 220 said a caller brings:
//! gRPC's transport is `http/h2conn.zig`, and the message inside a call is this.
//!
//! **Your types are the contract, and the compiler is the check.** A message
//! is a struct that declares its field numbers next to its fields:
//!
//! ```zig
//! const proto = @import("nilo_proto");
//!
//! const KeyValue = struct {
//!     pub const wire = .{ .key = 1, .value = 2 };
//!     key: []const u8 = "",
//!     value: ?AnyValue = null,
//! };
//!
//! const kv = try proto.decode(KeyValue, arena, bytes);
//! const out = try proto.encode(KeyValue, gpa, kv);
//! ```
//!
//! Nothing is generated and nothing is annotated beyond the `wire` table. A
//! `.proto` file is not read: the types are the schema, and a field that is
//! not in the type is skipped on the way in and never written on the way out.
//!
//! **A field's Zig type is its protobuf type.**
//!
//! | Zig | protobuf | notes |
//! |---|---|---|
//! | `bool` | bool | |
//! | `i32` `i64` `u32` `u64` | int32 int64 uint32 uint64 | `.sint32` `.sint64` `.sfixed32` `.sfixed64` `.fixed32` `.fixed64` in the table |
//! | `f32` `f64` | float double | |
//! | `[]const u8` | string | UTF-8 checked; `.bytes` in the table for bytes |
//! | `enum(i32)` | an open proto3 enum | exhaustive means closed, below |
//! | a struct with `wire` | a message | `?S` when presence matters |
//! | `?X` of a scalar or text | proto3 `optional` | present exactly when it was on the wire |
//! | `[]const X` | repeated | numbers are packed; `.unpacked` in the table |
//! | `?union(enum)` with `wire` | a oneof | its numbers live on its members |
//! | `[]const proto.Entry(K, V)` | `map<K, V>` | a map is a repeated entry, which is how it travels |
//!
//! **`[]const u8` is a string unless it says `.bytes`**, so it is checked to be
//! UTF-8 as prost and every conforming parser checks it. The loud default is
//! on purpose: a binary id forgotten as a string fails on the first request,
//! while a string forgotten as bytes would let invalid text through in silence.
//! The check is `wire.validUtf8`, two loads for a string of up to 16 bytes.
//!
//! **An enum is open unless it is exhaustive.** A proto3 enum keeps a number
//! the program does not know, so `enum(i32)` with a `_` member does. Declare it
//! without the `_` and it is proto2's closed enum: a number it does not name is
//! not stored, the field keeps what it had, and a repeated one drops the
//! element. Nothing is stored in an unknown-fields set; the message simply does
//! not know it.
//!
//! **Unknown fields are skipped**, groups included, so a newer sender is read
//! by an older receiver. They are not kept, so decoding and encoding again
//! loses them, which is what a receiver that writes its own message wants.
//!
//! **A field that occurs twice is merged the way the specification says**: a
//! scalar takes the last value, a repeated field appends, a message merges
//! field by field, and a oneof member replaces another member but merges into
//! itself. That is what makes two concatenated encodings decode as one, and
//! `merge` applies bytes on top of a value you already hold.
//!
//! **Memory is the arena's and one slab.** Strings and bytes borrow the input.
//! A repeated field is one exact slice, counted before it is filled; the slices
//! come from a single block sized from the input and its unused end is given
//! back, so a request of 500 records is a handful of allocator calls rather
//! than one a record (`bench/result/proto.md`). The decoded value lives as long
//! as the input and the arena both.
//!
//! **Encoding sizes a message once.** `encodedSize` is exact, `encodeInto`
//! writes into a buffer of your own (an HTTP/2 frame, a pooled buffer), and
//! `encode` is one allocation of exactly that size. Fields are written in
//! number order, so equal values are equal bytes.
//!
//! Every mistake in a type is a compile error written as a sentence naming the
//! field and the fix, held by `zig build refusals-proto` (ADR 026). Every
//! mistake in the bytes is an `Error`, and the decoder never panics on input.
//!
//! **What it does not do:** proto2 (required, defaults, extensions), the
//! well-known types (`Timestamp`, `Any`: write the two-field struct), JSON,
//! reflection, a `.proto` compiler, and services. Streaming a message through a
//! `Reader` of your own is `proto.Reader`, which is also what a hand-written
//! decoder that never builds a struct reads with.

const std = @import("std");

pub const wire = @import("wire.zig");
const schema = @import("schema.zig");
const decoder = @import("decode.zig");
const encoder = @import("encode.zig");

pub const Error = wire.Error;
/// prost's recursion limit, kept equal so both refuse the same input.
pub const max_depth = wire.max_depth;
pub const WireType = wire.WireType;
pub const Key = wire.Key;
pub const Reader = wire.Reader;
/// What a `wire` entry may say after the field number.
pub const Encoding = schema.Encoding;
pub const Entry = schema.Entry;
pub const EntryOf = schema.EntryOf;
/// A message with every field at its default.
pub const defaults = schema.defaults;
pub const Options = decoder.Options;
pub const decode = decoder.decode;
pub const decodeWith = decoder.decodeWith;
pub const merge = decoder.merge;
pub const mergeWith = decoder.mergeWith;
pub const encode = encoder.encode;
pub const encodeInto = encoder.encodeInto;
pub const encodedSize = encoder.encodedSize;
pub const varintLen = wire.varintLen;
pub const validUtf8 = wire.validUtf8;

// ---------------------------------------------------------------------------

const testing = std.testing;

const Inner = struct {
    pub const wire = .{ .name = 1, .tags = 2 };
    name: []const u8 = "",
    tags: []const []const u8 = &.{},
};

const Mood = enum(i32) { calm = 0, busy = 1, _ };

const Choice = union(enum) {
    pub const wire = .{ .text = 11, .number = 12, .inner = 13 };
    text: []const u8,
    number: i64,
    inner: Inner,
};

const Outer = struct {
    pub const wire = .{
        .id = .{ 1, .fixed64 },
        .count = 2,
        .delta = .{ 3, .sint32 },
        .blob = .{ 4, .bytes },
        .ratio = 5,
        .inner = 6,
        .inners = 7,
        .numbers = 8,
        .mood = 9,
        .flag = 10,
    };
    id: u64 = 0,
    count: u32 = 0,
    delta: i32 = 0,
    blob: []const u8 = "",
    ratio: f64 = 0,
    inner: ?Inner = null,
    inners: []const Inner = &.{},
    numbers: []const i64 = &.{},
    mood: Mood = .calm,
    flag: bool = false,
    choice: ?Choice = null,
};

fn arenaFor(state: *std.heap.ArenaAllocator) std.mem.Allocator {
    return state.allocator();
}

test "a message written from a struct reads back as the same struct" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const original: Outer = .{
        .id = 0xdead_beef_0000_0001,
        .count = 300,
        .delta = -2,
        .blob = &.{ 0xff, 0x00, 0xfe },
        .ratio = 1.5,
        .inner = .{ .name = "one", .tags = &.{ "a", "bc" } },
        .inners = &.{ .{ .name = "x" }, .{ .name = "y", .tags = &.{"z"} } },
        .numbers = &.{ -1, 0, 1 << 40 },
        .mood = @enumFromInt(7),
        .flag = true,
        .choice = .{ .number = -5 },
    };
    const bytes = try encode(Outer, arena, original);
    try testing.expectEqual(bytes.len, encodedSize(Outer, original));
    const back = try decode(Outer, arena, bytes);

    try testing.expectEqual(original.id, back.id);
    try testing.expectEqual(original.count, back.count);
    try testing.expectEqual(original.delta, back.delta);
    try testing.expectEqualSlices(u8, original.blob, back.blob);
    try testing.expectEqual(original.ratio, back.ratio);
    try testing.expectEqualStrings("one", back.inner.?.name);
    try testing.expectEqual(@as(usize, 2), back.inner.?.tags.len);
    try testing.expectEqualStrings("bc", back.inner.?.tags[1]);
    try testing.expectEqual(@as(usize, 2), back.inners.len);
    try testing.expectEqualStrings("z", back.inners[1].tags[0]);
    try testing.expectEqualSlices(i64, original.numbers, back.numbers);
    try testing.expectEqual(@as(i32, 7), @intFromEnum(back.mood));
    try testing.expect(back.flag);
    try testing.expectEqual(@as(i64, -5), back.choice.?.number);
}

test "a value decoded and encoded again is the same bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const first = try encode(Outer, a, .{
        .count = 9,
        .inner = .{ .name = "n", .tags = &.{ "p", "q" } },
        .numbers = &.{ 1, 2, 3 },
        .choice = .{ .inner = .{ .name = "deep" } },
    });
    const second = try encode(Outer, a, try decode(Outer, a, first));
    try testing.expectEqualSlices(u8, first, second);
}

test "fields are written in number order whatever order the struct declares" {
    const Backwards = struct {
        pub const wire = .{ .c = 3, .a = 1, .b = 2 };
        c: u32 = 0,
        b: u32 = 0,
        a: u32 = 0,
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes = try encode(Backwards, arena_state.allocator(), .{ .a = 1, .b = 2, .c = 3 });
    try testing.expectEqualSlices(u8, &.{ 0x08, 1, 0x10, 2, 0x18, 3 }, bytes);
}

test "an unknown field is skipped, a group among them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // field 99 varint, field 98 group holding a varint, then name = "ok".
    const bytes = [_]u8{
        0x98, 0x06, 0x01, // 99: varint 1
        0x93, 0x06, 0x08, 0x05, 0x94, 0x06, // 98: start group, field 1 = 5, end group
        0x0a, 0x02, 'o', 'k',
    };
    const v = try decode(Inner, arena_state.allocator(), &bytes);
    try testing.expectEqualStrings("ok", v.name);
}

test "an unknown field of every wire type is skipped on both passes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // Unknown 20 as varint, fixed64, len, fixed32; then a known tag; then a
    // two byte key for field 100.
    const bytes = [_]u8{
        0xa0, 0x01, 0x07, // 20: varint
        0xa1, 0x01, 1, 2, 3, 4, 5, 6, 7, 8, // 20: fixed64
        0xa2, 0x01, 0x02, 'x', 'y', // 20: len
        0xa5, 0x01, 1, 2, 3, 4, // 20: fixed32
        0x12, 0x01, 'a', // tags[0] = "a"
        0xa0, 0x06, 0x01, // 100: varint
        0x12, 0x01, 'b', // tags[1] = "b"
    };
    const v = try decode(Inner, arena_state.allocator(), &bytes);
    try testing.expectEqual(@as(usize, 2), v.tags.len);
    try testing.expectEqualStrings("b", v.tags[1]);
}

test "a string that is not UTF-8 is refused, and the same bytes as bytes are not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes = [_]u8{ 0x0a, 0x01, 0xff };
    try testing.expectError(error.InvalidUtf8, decode(Inner, arena_state.allocator(), &bytes));
    const Raw = struct {
        pub const wire = .{ .b = .{ 1, .bytes } };
        b: []const u8 = "",
    };
    const v = try decode(Raw, arena_state.allocator(), &bytes);
    try testing.expectEqualSlices(u8, &.{0xff}, v.b);
}

test "a repeated string with one bad element is refused whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes = [_]u8{ 0x12, 0x01, 'a', 0x12, 0x02, 0xc3, 0x28 };
    try testing.expectError(error.InvalidUtf8, decode(Inner, arena_state.allocator(), &bytes));
}

test "a known field with the wrong wire type is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // name (field 1) sent as a varint; a message field sent as a varint; a
    // packed number sent as fixed32.
    try testing.expectError(error.WrongWireType, decode(Inner, a, &.{ 0x08, 0x01 }));
    try testing.expectError(error.WrongWireType, decode(Outer, a, &.{ 0x30, 0x01 }));
    try testing.expectError(error.WrongWireType, decode(Outer, a, &.{ 0x45, 1, 2, 3, 4 }));
}

test "malformed input is a named error, never a panic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectError(error.Truncated, decode(Inner, a, &.{ 0x0a, 0x05, 'a' }));
    try testing.expectError(error.Truncated, decode(Inner, a, &.{0xff}));
    try testing.expectError(error.Truncated, decode(Inner, a, &.{0x0a}));
    try testing.expectError(error.Truncated, decode(Outer, a, &.{ 0x09, 1, 2, 3 }));
    try testing.expectError(error.Truncated, decode(Outer, a, &.{ 0x42, 0x03, 0x01, 0x02, 0x80 }));
    try testing.expectError(error.VarintTooLong, decode(Inner, a, &.{ 0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02 }));
    try testing.expectError(error.InvalidKey, decode(Inner, a, &.{ 0x00, 0x00 }));
    try testing.expectError(error.InvalidKey, decode(Inner, a, &.{ 0x0e, 0x00 }));
    try testing.expectError(error.InvalidKey, decode(Inner, a, &.{ 0x0f, 0x00 }));
    try testing.expectError(error.UnexpectedEndGroup, decode(Inner, a, &.{ 0x64, 0x00 }));
    // A length that claims more than the input has, on a field this type
    // does not know, so only the skip can notice.
    try testing.expectError(error.Truncated, decode(Inner, a, &.{ 0xa2, 0x01, 0x7f, 'x' }));
}

test "a message field sent twice is merged, and a repeated field inside it appends" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const first = try encode(Outer, a, .{ .inner = .{ .name = "first", .tags = &.{"t1"} } });
    const second = try encode(Outer, a, .{ .inner = .{ .tags = &.{"t2"} } });
    const both = try std.mem.concat(a, u8, &.{ first, second });
    const v = try decode(Outer, a, both);
    try testing.expectEqualStrings("first", v.inner.?.name);
    try testing.expectEqual(@as(usize, 2), v.inner.?.tags.len);
    try testing.expectEqualStrings("t2", v.inner.?.tags[1]);
}

test "a scalar that occurs twice takes the last value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const v = try decode(Outer, arena_state.allocator(), &.{ 0x10, 0x05, 0x10, 0x09 });
    try testing.expectEqual(@as(u32, 9), v.count);
}

test "merge applies bytes on top of a value that is already there" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v: Inner = .{ .name = "keep", .tags = &.{ "old1", "old2" } };
    try merge(Inner, a, &v, try encode(Inner, a, .{ .tags = &.{"new"} }));
    try testing.expectEqualStrings("keep", v.name);
    try testing.expectEqual(@as(usize, 3), v.tags.len);
    try testing.expectEqualStrings("old1", v.tags[0]);
    try testing.expectEqualStrings("new", v.tags[2]);
}

test "a oneof member replaces another member and merges into itself" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = try encode(Outer, a, .{ .choice = .{ .text = "t" } });
    const inner1 = try encode(Outer, a, .{ .choice = .{ .inner = .{ .tags = &.{"a"} } } });
    const inner2 = try encode(Outer, a, .{ .choice = .{ .inner = .{ .tags = &.{"b"} } } });
    const v = try decode(Outer, a, try std.mem.concat(a, u8, &.{ text, inner1, inner2 }));
    try testing.expectEqual(@as(usize, 2), v.choice.?.inner.tags.len);
    const w = try decode(Outer, a, try std.mem.concat(a, u8, &.{ inner1, text }));
    try testing.expectEqualStrings("t", w.choice.?.text);
}

test "an active oneof member is written even when it is zero" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bytes = try encode(Outer, a, .{ .choice = .{ .number = 0 } });
    try testing.expectEqualSlices(u8, &.{ 0x60, 0x00 }, bytes);
    try testing.expectEqual(@as(i64, 0), (try decode(Outer, a, bytes)).choice.?.number);
}

test "packed and unpacked repeated numbers both read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // field 8 unpacked twice, then packed [3, 4].
    const bytes = [_]u8{ 0x40, 0x01, 0x40, 0x02, 0x42, 0x02, 0x03, 0x04 };
    const v = try decode(Outer, a, &bytes);
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3, 4 }, v.numbers);
}

test "a repeated number is written packed, or one key a number when it says so" {
    const Two = struct {
        pub const wire = .{ .fast = 1, .slow = .{ 2, .unpacked }, .zig = .{ 3, .sint32, .unpacked } };
        fast: []const u32 = &.{},
        slow: []const u32 = &.{},
        zig: []const i32 = &.{},
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v: Two = .{ .fast = &.{ 1, 2 }, .slow = &.{ 1, 2 }, .zig = &.{ -1, 1 } };
    const bytes = try encode(Two, a, v);
    try testing.expectEqualSlices(u8, &.{ 0x0a, 0x02, 1, 2, 0x10, 1, 0x10, 2, 0x18, 1, 0x18, 2 }, bytes);
    const back = try decode(Two, a, bytes);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, back.fast);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, back.slow);
    try testing.expectEqualSlices(i32, &.{ -1, 1 }, back.zig);
}

test "repeated fixed width numbers and floats round trip, packed" {
    const Fx = struct {
        pub const wire = .{ .a = .{ 1, .fixed64 }, .b = .{ 2, .sfixed32 }, .c = 3, .d = 4, .e = 5 };
        a: []const u64 = &.{},
        b: []const i32 = &.{},
        c: []const f32 = &.{},
        d: []const f64 = &.{},
        e: []const bool = &.{},
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v: Fx = .{
        .a = &.{ 1, std.math.maxInt(u64) },
        .b = &.{ -5, 5, 0 },
        .c = &.{ 1.5, -0.0 },
        .d = &.{ 2.25, std.math.inf(f64) },
        .e = &.{ true, false, true },
    };
    const bytes = try encode(Fx, a, v);
    const back = try decode(Fx, a, bytes);
    try testing.expectEqualSlices(u64, v.a, back.a);
    try testing.expectEqualSlices(i32, v.b, back.b);
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, -0.0))), @as(u32, @bitCast(back.c[1])));
    try testing.expectEqualSlices(f64, v.d, back.d);
    try testing.expectEqualSlices(bool, v.e, back.e);
}

test "a packed run cut in the middle of a number is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const Fx = struct {
        pub const wire = .{ .a = .{ 1, .fixed64 } };
        a: []const u64 = &.{},
    };
    try testing.expectError(error.Truncated, decode(Fx, arena_state.allocator(), &.{ 0x0a, 0x05, 1, 2, 3, 4, 5 }));
}

test "proto3 optional is present exactly when it was written, zero or not" {
    const Opt = struct {
        pub const wire = .{ .sum = 1, .name = 2, .n = 3 };
        sum: ?f64 = null,
        name: ?[]const u8 = null,
        n: ?i32 = null,
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const none = try encode(Opt, a, .{});
    try testing.expectEqual(@as(usize, 0), none.len);
    try testing.expectEqual(@as(?f64, null), (try decode(Opt, a, none)).sum);
    const zeros = try encode(Opt, a, .{ .sum = 0, .name = "", .n = 0 });
    try testing.expectEqualSlices(u8, &.{ 0x09, 0, 0, 0, 0, 0, 0, 0, 0, 0x12, 0x00, 0x18, 0x00 }, zeros);
    const back = try decode(Opt, a, zeros);
    try testing.expectEqual(@as(?f64, 0), back.sum);
    try testing.expectEqualStrings("", back.name.?);
    try testing.expectEqual(@as(?i32, 0), back.n);
}

test "a map is a repeated entry, and reads what another writer sent" {
    const Tags = struct {
        pub const wire = .{ .labels = 1, .sizes = 2 };
        labels: []const Entry([]const u8, []const u8) = &.{},
        sizes: []const EntryOf(u32, i64, .default, .sint64) = &.{},
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // map<string,string> {"k":"v"} then {"": ""} (an empty entry), as another
    // writer sends them; and map<uint32, sint64> {7: -3}.
    const bytes = [_]u8{
        0x0a, 0x06, 0x0a, 0x01, 'k', 0x12, 0x01, 'v',
        0x0a, 0x00,
        0x12, 0x04, 0x08, 0x07, 0x10, 0x05,
    };
    const v = try decode(Tags, a, &bytes);
    try testing.expectEqual(@as(usize, 2), v.labels.len);
    try testing.expectEqualStrings("k", v.labels[0].key);
    try testing.expectEqualStrings("v", v.labels[0].value);
    try testing.expectEqualStrings("", v.labels[1].key);
    try testing.expectEqual(@as(i64, -3), v.sizes[0].value);
    try testing.expectEqualSlices(u8, &bytes[0..8].*, (try encode(Tags, a, .{ .labels = v.labels[0..1] })));
}

test "a closed enum drops a number it does not name and keeps the rest" {
    const Level = enum(i32) { off = 0, low = 1, high = 2 };
    const Closed = struct {
        pub const wire = .{ .one = 1, .many = 2 };
        one: Level = .low,
        many: []const Level = &.{},
        pick: ?union(enum) {
            pub const wire = .{ .level = 3 };
            level: Level,
        } = null,
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // one = 9 (unknown, ignored), many = [2, 7, 1] packed, pick = 8 (ignored).
    const v = try decode(Closed, a, &.{ 0x08, 0x09, 0x12, 0x03, 0x02, 0x07, 0x01, 0x18, 0x08 });
    try testing.expectEqual(Level.low, v.one);
    try testing.expectEqual(@as(usize, 2), v.many.len);
    try testing.expectEqual(Level.high, v.many[0]);
    try testing.expectEqual(Level.low, v.many[1]);
}

test "an open enum keeps a number it does not name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const v = try decode(Outer, arena_state.allocator(), &.{ 0x48, 0x2a });
    try testing.expectEqual(@as(i32, 42), @intFromEnum(v.mood));
}

test "nesting is allowed to 100 levels and refused at 101" {
    const Node = struct {
        pub const wire = .{ .child = 1 };
        child: []const @This() = &.{},
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var bytes: []const u8 = &.{};
    for (0..101) |level| {
        var w: std.ArrayList(u8) = .empty;
        try w.append(a, 0x0a);
        var lenbuf: [10]u8 = undefined;
        var lw: wire.Writer = .{ .buf = &lenbuf, .pos = lenbuf.len };
        lw.varint(bytes.len);
        try w.appendSlice(a, lenbuf[lw.pos..]);
        try w.appendSlice(a, bytes);
        bytes = w.items;
        if (level == 99) _ = try decode(Node, a, bytes);
    }
    try testing.expectError(error.TooDeep, decode(Node, a, bytes));
    _ = try decodeWith(Node, a, bytes, .{ .max_depth = 101 });
    try testing.expectError(error.TooDeep, decodeWith(Node, a, bytes, .{ .max_depth = 99 }));
}

test "a recursion bomb of groups is refused, not followed to the bottom" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // 5,000 start-group keys for field 1 in a row, then nothing.
    const bomb = [_]u8{0x0b} ** 5000;
    try testing.expectError(error.TooDeep, decode(Test0, arena_state.allocator(), &bomb));
}

const Test0 = struct {
    pub const wire = .{ .a = 2 };
    a: u32 = 0,
};

test "a decoded string borrows the input instead of copying it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes = [_]u8{ 0x0a, 0x02, 'h', 'i' };
    const v = try decode(Inner, arena_state.allocator(), &bytes);
    try testing.expectEqual(@intFromPtr(&bytes[2]), @intFromPtr(v.name.ptr));
}

test "a repeated field is one exact slice, and a request is a handful of allocator calls" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var list: std.ArrayList(Inner) = .empty;
    for (0..300) |i| try list.append(a, .{ .name = "n", .tags = if (i % 3 == 0) &.{ "x", "y" } else &.{} });
    const bytes = try encode(Outer, a, .{ .inners = list.items });

    var counting: CountingAllocator = .{ .inner = testing.allocator };
    var scratch = std.heap.ArenaAllocator.init(counting.allocator());
    defer scratch.deinit();
    const v = try decode(Outer, scratch.allocator(), bytes);
    try testing.expectEqual(@as(usize, 300), v.inners.len);
    try testing.expectEqual(@as(usize, 2), v.inners[0].tags.len);
    try testing.expectEqual(@as(usize, 0), v.inners[1].tags.len);
    // Not one allocator call a message: the slices come out of one block.
    try testing.expect(scratch.queryCapacity() > 0);
    try testing.expect(counting.calls <= 6);
}

const CountingAllocator = struct {
    inner: std.mem.Allocator,
    calls: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.inner.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(m, alignment, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(m, alignment, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(m, alignment, ra);
    }
};

test "a failing allocator is OutOfMemory, never a half read value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes = try encode(Outer, arena_state.allocator(), .{ .inners = &.{ .{ .name = "a" }, .{ .name = "b" } } });
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, decode(Outer, failing.allocator(), bytes));
}

test "encodeInto refuses a buffer that is short, and fills the front of one that is long" {
    var small: [3]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, encodeInto(Inner, &small, .{ .name = "hello" }));
    var big: [32]u8 = @splat(0xee);
    const out = try encodeInto(Inner, &big, .{ .name = "hi" });
    try testing.expectEqualSlices(u8, &.{ 0x0a, 0x02, 'h', 'i' }, out);
    try testing.expectEqual(@intFromPtr(&big), @intFromPtr(out.ptr));
    try testing.expectEqual(@as(u8, 0xee), big[4]);
}

test "a string with a field that has a default keeps it when the field is absent" {
    const Greeter = struct {
        pub const wire = .{ .greeting = 1, .times = 2 };
        greeting: []const u8 = "hello",
        times: u32 = 3,
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const v = try decode(Greeter, arena_state.allocator(), &.{});
    try testing.expectEqualStrings("hello", v.greeting);
    try testing.expectEqual(@as(u32, 3), v.times);
}

test "a message with a field above 15 reads through the two byte key path" {
    const Wide = struct {
        pub const wire = .{ .low = 1, .high = 300, .many = 2047, .nums = 16 };
        low: u32 = 0,
        high: []const u8 = "",
        many: []const []const u8 = &.{},
        nums: []const u32 = &.{},
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v: Wide = .{ .low = 1, .high = "h", .many = &.{ "a", "b" }, .nums = &.{ 5, 6, 7 } };
    const bytes = try encode(Wide, a, v);
    const back = try decode(Wide, a, bytes);
    try testing.expectEqual(@as(u32, 1), back.low);
    try testing.expectEqualStrings("h", back.high);
    try testing.expectEqual(@as(usize, 2), back.many.len);
    try testing.expectEqualSlices(u32, &.{ 5, 6, 7 }, back.nums);
}

test "a message with no fields skips everything, and a slice of them is counted" {
    const Empty = struct {
        pub const wire = .{};
    };
    const Holder = struct {
        pub const wire = .{ .items = 1 };
        items: []const Empty = &.{},
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = try decode(Empty, a, &.{ 0x08, 0x01, 0x12, 0x01, 'x' });
    const v = try decode(Holder, a, &.{ 0x0a, 0x00, 0x0a, 0x02, 0x08, 0x01, 0x0a, 0x00 });
    try testing.expectEqual(@as(usize, 3), v.items.len);
    const bytes = try encode(Holder, a, v);
    try testing.expectEqualSlices(u8, &.{ 0x0a, 0x00, 0x0a, 0x00, 0x0a, 0x00 }, bytes);
}

test "a key written in more bytes than it needs is the same key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // Field 2 (count), key 0x10 written as 0x90 0x00.
    const v = try decode(Outer, arena_state.allocator(), &.{ 0x90, 0x00, 0x05 });
    try testing.expectEqual(@as(u32, 5), v.count);
}

test "random bytes and damaged messages are refused or read, and never panic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fixed_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer fixed_state.deinit();
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rng = prng.random();

    const real = try encode(Outer, fixed_state.allocator(), .{
        .id = 77,
        .count = 300,
        .delta = -9,
        .blob = "bytes",
        .ratio = 2.5,
        .inner = .{ .name = "inner", .tags = &.{ "a", "bb", "ccc" } },
        .inners = &.{ .{ .name = "x" }, .{ .name = "y", .tags = &.{"z"} } },
        .numbers = &.{ 1, -2, 300, 1 << 40 },
        .mood = @enumFromInt(3),
        .flag = true,
        .choice = .{ .inner = .{ .name = "deep", .tags = &.{"t"} } },
    });

    var buf: [256]u8 = undefined;
    for (0..20_000) |iteration| {
        _ = arena_state.reset(.retain_capacity);
        const n = rng.uintLessThan(usize, buf.len + 1);
        switch (iteration % 4) {
            // Pure noise.
            0 => rng.bytes(buf[0..n]),
            // The real message cut anywhere.
            1 => @memcpy(buf[0..@min(n, real.len)], real[0..@min(n, real.len)]),
            // The real message with a few bytes changed.
            2 => {
                @memcpy(buf[0..real.len], real);
                for (0..1 + rng.uintLessThan(usize, 4)) |_| buf[rng.uintLessThan(usize, real.len)] = rng.int(u8);
            },
            // Noise made of small bytes, so keys, lengths and groups line up
            // often enough to get past the first field.
            else => for (buf[0..n]) |*c| {
                c.* = rng.uintLessThan(u8, 24);
            },
        }
        const len = switch (iteration % 4) {
            1 => @min(n, real.len),
            2 => real.len,
            else => n,
        };
        const bytes = buf[0..len];
        if (decode(Outer, a, bytes)) |v| {
            // What was read must be what encoding says it is.
            const again = try encode(Outer, a, v);
            _ = decode(Outer, a, again) catch |e| return e;
        } else |_| {}
        if (decode(Inner, a, bytes)) |_| {} else |_| {}
    }
}

test {
    _ = wire;
    _ = schema;
    _ = decoder;
    _ = encoder;
    _ = @import("conformance.zig");
}
