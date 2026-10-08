//! What a type says about itself, worked out once while compiling (ADR 245).
//!
//! `specsOf(T)` reads a message type's `wire` table and fields and returns one
//! `Spec` for every field number it reads or writes, or stops the build with a
//! sentence saying which field is wrong and what to write instead. Everything
//! the decoder and the encoder do at run time is a loop over these, unrolled,
//! so a mistake in a type can only ever be a compile error and a type that
//! compiles cannot reach a branch the module has no code for.
//!
//! The error text is held by `zig build refusals-proto` (ADR 026), one file a
//! check in `proto/refusals/`, so each begins with `nilo: ` and says which
//! field of which type.

const std = @import("std");
const wire = @import("wire.zig");

const WireType = wire.WireType;

/// How a field travels when its Zig type allows more than one way.
pub const Encoding = enum { default, string, bytes, fixed64, fixed32, sfixed64, sfixed32, sint64, sint32 };

pub const Kind = enum { scalar, message, repeated };

pub const Scalar = enum {
    bool,
    int32,
    int64,
    uint32,
    uint64,
    sint32,
    sint64,
    fixed32,
    fixed64,
    sfixed32,
    sfixed64,
    float,
    double,
    enumeration,
    string,
    bytes,
};

pub fn scalarWire(comptime s: Scalar) WireType {
    return switch (s) {
        .bool, .int32, .int64, .uint32, .uint64, .sint32, .sint64, .enumeration => .varint,
        .fixed64, .sfixed64, .double => .fixed64,
        .fixed32, .sfixed32, .float => .fixed32,
        .string, .bytes => .len,
    };
}

/// One field number and what it fills.
pub const Spec = struct {
    /// The struct field this number fills.
    field: []const u8,
    number: u32,
    kind: Kind,
    /// For a scalar, and for the elements of a repeated scalar.
    scalar: Scalar = .bool,
    /// For a oneof: which member of the union, else empty.
    member: []const u8 = "",
    /// For `.repeated`: whether the elements are messages.
    elem_message: bool = false,
    /// For a repeated number: whether it is written as one run (proto3's
    /// default) or one key a number. Both are read either way.
    packed_run: bool = true,
    /// A scalar or string whose type is `?X`: proto3 `optional`, present
    /// exactly when it was on the wire.
    optional: bool = false,

    pub fn isText(s: Spec) bool {
        return s.scalar == .string or s.scalar == .bytes;
    }

    /// A repeated field whose elements may arrive as one length delimited
    /// run.
    pub fn packable(s: Spec) bool {
        return s.kind == .repeated and !s.elem_message and !s.isText();
    }
};

pub fn hasWire(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union" => @hasDecl(T, "wire"),
        else => false,
    };
}

pub fn isMessage(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and hasWire(T);
}

pub fn Unwrapped(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

fn isOneof(comptime T: type) bool {
    const U = Unwrapped(T);
    return @typeInfo(U) == .@"union" and hasWire(U);
}

fn isRepeated(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child != u8,
        else => false,
    };
}

fn entryNumber(comptime owner: []const u8, comptime name: []const u8, comptime e: anytype) u32 {
    const E = @TypeOf(e);
    const n = if (E == comptime_int) e else if (@typeInfo(E) == .@"struct" and @typeInfo(E).@"struct".is_tuple and e.len >= 2 and @TypeOf(e[0]) == comptime_int) e[0] else @compileError(
        "nilo: `" ++ owner ++ ".wire." ++ name ++ "` must be a field number (`." ++ name ++ " = 1`) " ++
            "or a number and an encoding (`." ++ name ++ " = .{ 1, .fixed64 }`).",
    );
    if (n < 1 or n > 536_870_911) @compileError(
        "nilo: `" ++ owner ++ "." ++ name ++ "` has field number " ++ std.fmt.comptimePrint("{d}", .{n}) ++
            ", and a field number is between 1 and 536,870,911.",
    );
    if (n >= 19_000 and n <= 19_999) @compileError(
        "nilo: `" ++ owner ++ "." ++ name ++ "` uses " ++ std.fmt.comptimePrint("{d}", .{n}) ++
            ", and 19,000 to 19,999 are reserved by protobuf itself.",
    );
    return n;
}

const Options = struct { encoding: Encoding = .default, unpacked: bool = false };

/// The words after the number: at most one encoding and `.unpacked`.
fn entryOptions(comptime owner: []const u8, comptime name: []const u8, comptime e: anytype) Options {
    var o: Options = .{};
    if (@TypeOf(e) == comptime_int) return o;
    inline for (e, 0..) |item, i| {
        if (i == 0) continue;
        const word = @tagName(item);
        if (std.mem.eql(u8, word, "unpacked")) {
            o.unpacked = true;
        } else {
            if (o.encoding != .default) @compileError("nilo: `" ++ owner ++ ".wire." ++ name ++
                "` names two encodings. A field travels one way.");
            o.encoding = std.meta.stringToEnum(Encoding, word) orelse @compileError(
                "nilo: `" ++ owner ++ ".wire." ++ name ++ "` says `." ++ word ++ "`, which is not an encoding. " ++
                    "They are .fixed64, .fixed32, .sfixed64, .sfixed32, .sint64, .sint32, .bytes and .string, " ++
                    "and `.unpacked` for a repeated number.",
            );
        }
    }
    return o;
}

/// Whether an enum is closed: declared exhaustive, so a number it does not
/// name is not one of its values (proto2's enum). Open is the proto3 rule.
pub fn isClosedScalar(comptime Z: type) bool {
    return @typeInfo(Z) == .@"enum" and @typeInfo(Z).@"enum".mode == .exhaustive;
}

/// The scalar a Zig type and an encoding make, or a sentence saying why not.
fn scalarOf(comptime owner: []const u8, comptime name: []const u8, comptime T: type, comptime enc: Encoding) Scalar {
    const where = "nilo: `" ++ owner ++ "." ++ name ++ "` ";
    const wrong = struct {
        fn f(comptime what: []const u8) noreturn {
            @compileError(where ++ what);
        }
    }.f;
    switch (T) {
        bool => return switch (enc) {
            .default => .bool,
            else => wrong("is a bool, which travels as a varint and takes no encoding."),
        },
        i32 => return switch (enc) {
            .default => .int32,
            .sint32 => .sint32,
            .sfixed32 => .sfixed32,
            else => wrong("is an i32: its encodings are `.sint32` and `.sfixed32`, or none for int32."),
        },
        i64 => return switch (enc) {
            .default => .int64,
            .sint64 => .sint64,
            .sfixed64 => .sfixed64,
            else => wrong("is an i64: its encodings are `.sint64` and `.sfixed64`, or none for int64."),
        },
        u32 => return switch (enc) {
            .default => .uint32,
            .fixed32 => .fixed32,
            else => wrong("is a u32: its encoding is `.fixed32`, or none for uint32."),
        },
        u64 => return switch (enc) {
            .default => .uint64,
            .fixed64 => .fixed64,
            else => wrong("is a u64: its encoding is `.fixed64`, or none for uint64."),
        },
        f32 => return switch (enc) {
            .default => .float,
            else => wrong("is an f32, a protobuf float, which is always four bytes and takes no encoding."),
        },
        f64 => return switch (enc) {
            .default => .double,
            else => wrong("is an f64, a protobuf double, which is always eight bytes and takes no encoding."),
        },
        []const u8 => return switch (enc) {
            .default, .string => .string,
            .bytes => .bytes,
            else => wrong("is text or bytes: write `.bytes` for bytes, or nothing for a string."),
        },
        else => {},
    }
    switch (@typeInfo(T)) {
        .@"enum" => |e| {
            if (e.tag_type != i32) wrong("is an enum whose tag is not i32, and a protobuf enum is an int32. " ++
                "Declare it `enum(i32)`.");
            if (enc != .default) wrong("is an enum, which travels as a varint and takes no encoding.");
            if (e.mode == .exhaustive and e.field_names.len == 0) wrong("is an enum with no values.");
            return .enumeration;
        },
        .pointer => |p| if (p.size == .slice and p.child == u8 and !p.attrs.@"const")
            wrong("is `[]u8`; a decoded string borrows the input, so write `[]const u8`."),
        else => {},
    }
    wrong("has type `" ++ @typeName(T) ++ "`, which is not a protobuf type. A field is a bool, an integer " ++
        "(i32, i64, u32 or u64), a float, a `[]const u8`, an `enum(i32)`, a struct with a `wire` table, a slice of " ++
        "any of those, or a `?union(enum)` with a `wire` table for a oneof.");
}

/// Every field number a message reads and writes, in the order of its struct
/// fields.
pub fn specsOf(comptime T: type) []const Spec {
    return comptime blk: {
        @setEvalBranchQuota(1_000_000);
        const owner = @typeName(T);
        if (!hasWire(T)) @compileError("nilo: `" ++ owner ++ "` is used as a message but declares no field " ++
            "numbers. Add `pub const wire = .{ .field_name = 1, ... };` to it.");
        if (@typeInfo(T) != .@"struct") @compileError("nilo: `" ++ owner ++ "` is a union with a `wire` table, " ++
            "and a union is only a oneof: put it in a message as `?" ++ owner ++ "`.");
        const info = @typeInfo(T).@"struct";
        const table = T.wire;
        var specs: []const Spec = &.{};

        for (@typeInfo(@TypeOf(table)).@"struct".field_names) |listed| {
            if (!@hasField(T, listed)) @compileError("nilo: `" ++ owner ++ ".wire` numbers `" ++ listed ++
                "`, and `" ++ owner ++ "` has no field of that name.");
        }

        for (info.field_names, info.field_types) |fname, FT| {
            if (isOneof(FT)) {
                if (@typeInfo(FT) != .optional) @compileError("nilo: make `" ++ owner ++ "." ++ fname ++
                    "` optional (`?" ++ @typeName(FT) ++ "`): a oneof that is not on the wire is none of its members.");
                if (@hasField(@TypeOf(table), fname)) @compileError("nilo: `" ++ owner ++ "." ++ fname ++
                    "` is a oneof, so its numbers belong on its members in `" ++ @typeName(Unwrapped(FT)) ++
                    ".wire`, not in `" ++ owner ++ ".wire`.");
                const U = Unwrapped(FT);
                const utable = U.wire;
                for (@typeInfo(@TypeOf(utable)).@"struct".field_names) |listed| {
                    if (!@hasField(U, listed)) @compileError("nilo: `" ++ @typeName(U) ++ ".wire` numbers `" ++
                        listed ++ "`, and the union has no member of that name.");
                }
                for (@typeInfo(U).@"union".field_names, @typeInfo(U).@"union".field_types) |mname, MT| {
                    if (!@hasField(@TypeOf(utable), mname)) @compileError("nilo: oneof member `" ++ @typeName(U) ++
                        "." ++ mname ++ "` has no field number. Add it to `" ++ @typeName(U) ++ ".wire`, like `." ++
                        mname ++ " = 1`.");
                    const e = @field(utable, mname);
                    const n = entryNumber(@typeName(U), mname, e);
                    const opts = entryOptions(@typeName(U), mname, e);
                    if (opts.unpacked) @compileError("nilo: oneof member `" ++ @typeName(U) ++ "." ++ mname ++
                        "` says `.unpacked`, which is for a repeated number, and a oneof member is never repeated.");
                    if (isMessage(MT)) {
                        if (opts.encoding != .default) @compileError("nilo: oneof member `" ++ @typeName(U) ++ "." ++
                            mname ++ "` is a message, which takes no encoding.");
                        specs = specs ++ &[_]Spec{.{ .field = fname, .number = n, .kind = .message, .member = mname }};
                    } else {
                        if (isRepeated(MT)) @compileError("nilo: oneof member `" ++ @typeName(U) ++ "." ++ mname ++
                            "` is repeated, and protobuf does not allow a repeated field in a oneof.");
                        const s = scalarOf(@typeName(U), mname, MT, opts.encoding);
                        specs = specs ++ &[_]Spec{.{ .field = fname, .number = n, .kind = .scalar, .scalar = s, .member = mname }};
                    }
                }
                continue;
            }
            if (!@hasField(@TypeOf(table), fname)) @compileError("nilo: `" ++ owner ++ "." ++ fname ++
                "` has no field number. Add it to `" ++ owner ++ ".wire`, like `." ++ fname ++ " = 1`.");
            const e = @field(table, fname);
            const n = entryNumber(owner, fname, e);
            const opts = entryOptions(owner, fname, e);
            const enc = opts.encoding;
            if (@typeInfo(FT) == .optional and isRepeated(Unwrapped(FT))) @compileError("nilo: `" ++ owner ++
                "." ++ fname ++ "` is an optional slice, and a repeated field is never absent, only empty. Drop the `?`.");
            if (isRepeated(FT)) {
                const C = @typeInfo(FT).pointer.child;
                if (isMessage(C)) {
                    if (enc != .default) @compileError("nilo: `" ++ owner ++ "." ++ fname ++
                        "` is a repeated message, which takes no encoding.");
                    if (opts.unpacked) @compileError("nilo: `" ++ owner ++ "." ++ fname ++
                        "` says `.unpacked`, which is for a repeated number; a repeated message is never packed.");
                    specs = specs ++ &[_]Spec{.{ .field = fname, .number = n, .kind = .repeated, .elem_message = true }};
                } else {
                    if (@typeInfo(C) == .optional) @compileError("nilo: `" ++ owner ++ "." ++ fname ++
                        "` is a slice of optionals, and a repeated field has no holes. Drop the `?`.");
                    const s = scalarOf(owner, fname, C, enc);
                    if (opts.unpacked and (s == .string or s == .bytes)) @compileError("nilo: `" ++ owner ++ "." ++
                        fname ++ "` says `.unpacked`, which is for a repeated number; repeated text is never packed.");
                    specs = specs ++ &[_]Spec{.{ .field = fname, .number = n, .kind = .repeated, .scalar = s, .packed_run = !opts.unpacked }};
                }
            } else {
                if (opts.unpacked) @compileError("nilo: `" ++ owner ++ "." ++ fname ++
                    "` says `.unpacked`, which is for a repeated number, and this field is not repeated.");
                const U = Unwrapped(FT);
                if (isMessage(U)) {
                    if (enc != .default) @compileError("nilo: `" ++ owner ++ "." ++ fname ++
                        "` is a message, which takes no encoding.");
                    specs = specs ++ &[_]Spec{.{ .field = fname, .number = n, .kind = .message }};
                } else {
                    const s = scalarOf(owner, fname, U, enc);
                    specs = specs ++ &[_]Spec{.{ .field = fname, .number = n, .kind = .scalar, .scalar = s, .optional = @typeInfo(FT) == .optional }};
                }
            }
        }

        for (specs, 0..) |a, i| for (specs[i + 1 ..]) |b| if (a.number == b.number) @compileError(
            "nilo: `" ++ owner ++ "` gives field number " ++ std.fmt.comptimePrint("{d}", .{a.number}) ++
                " to both `" ++ a.field ++ (if (a.member.len > 0) "." ++ a.member else "") ++ "` and `" ++ b.field ++
                (if (b.member.len > 0) "." ++ b.member else "") ++ "`. A number names one field.",
        );
        const out = specs[0..specs.len].*;
        break :blk &out;
    };
}

/// The same specs in field number order, which is the order the encoder
/// writes them, so one message always encodes to the same bytes.
pub fn sortedSpecs(comptime T: type) []const Spec {
    return comptime blk: {
        const src = specsOf(T);
        var out: [src.len]Spec = src[0..src.len].*;
        std.sort.insertion(Spec, &out, {}, struct {
            fn less(_: void, a: Spec, b: Spec) bool {
                return a.number < b.number;
            }
        }.less);
        const done = out;
        break :blk &done;
    };
}

/// The wire type a spec's value is read with: a repeated number's packed run
/// is `.len`.
pub fn specWire(comptime s: Spec, comptime packed_run: bool) WireType {
    return switch (s.kind) {
        .message => .len,
        .scalar => scalarWire(s.scalar),
        .repeated => if (s.elem_message) .len else if (packed_run) .len else scalarWire(s.scalar),
    };
}

pub fn repeatedCount(comptime T: type) usize {
    return comptime blk: {
        var n: usize = 0;
        for (specsOf(T)) |s| {
            if (s.kind == .repeated) n += 1;
        }
        break :blk n;
    };
}

/// Where spec `i` sits among the message's repeated fields.
pub fn repeatedIndex(comptime T: type, comptime i: usize) usize {
    return comptime blk: {
        var n: usize = 0;
        for (specsOf(T)[0..i]) |s| {
            if (s.kind == .repeated) n += 1;
        }
        break :blk n;
    };
}

/// What a one byte key stands for in the decoder's table.
pub const Fast = struct {
    spec: u8,
    /// A repeated number read as a run.
    packed_run: bool,
};

pub const no_action: u8 = 0xff;

pub fn FastTable(comptime T: type) type {
    return struct {
        /// The actions a one byte key can name: every field number under 16,
        /// each with the wire types it is read with.
        pub const actions: []const Fast = blk: {
            var out: []const Fast = &.{};
            for (specsOf(T), 0..) |s, i| {
                if (s.number >= 16) continue;
                if (s.kind == .repeated and s.packable()) {
                    out = out ++ &[_]Fast{ .{ .spec = i, .packed_run = false }, .{ .spec = i, .packed_run = true } };
                } else {
                    out = out ++ &[_]Fast{.{ .spec = i, .packed_run = false }};
                }
            }
            break :blk out;
        };

        /// The first key byte (number << 3 | wire) to an index in `actions`.
        pub const table: [128]u8 = blk: {
            var t: [128]u8 = @splat(no_action);
            for (actions, 0..) |a, ai| {
                const s = specsOf(T)[a.spec];
                const w = specWire(s, a.packed_run and s.packable());
                t[(s.number << 3) | @backingInt(w)] = ai;
            }
            break :blk t;
        };

        /// For the counting pass: a repeated field's key byte to
        /// `1 + index * 2 + packed`, and 0 for anything else.
        pub const counts: [128]u8 = blk: {
            var t: [128]u8 = @splat(0);
            for (specsOf(T), 0..) |s, i| {
                if (s.number >= 16 or s.kind != .repeated) continue;
                const ri = repeatedIndex(T, i);
                const w = specWire(s, false);
                t[(s.number << 3) | @backingInt(w)] = 1 + ri * 2;
                if (s.packable()) t[(s.number << 3) | @backingInt(WireType.len)] = 1 + ri * 2 + 1;
            }
            break :blk t;
        };
    };
}

/// A message with every field at its default: the field's own default value
/// where it declares one, protobuf's zero otherwise.
pub fn defaults(comptime T: type) T {
    comptime _ = specsOf(T);
    var v: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, FT, attrs| {
        if (attrs.defaultValue(FT)) |d| {
            @field(v, name) = d;
        } else {
            @field(v, name) = zero(FT);
        }
    }
    return v;
}

pub fn zero(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .bool => false,
        .int, .float => 0,
        .@"enum" => |e| if (e.mode == .exhaustive) @fromBackingInt(@intCast(e.field_values[0])) else @fromBackingInt(@intCast(0)),
        .optional => null,
        .pointer => if (T == []const u8) "" else &.{},
        .@"struct" => defaults(T),
        else => @compileError("nilo: a protobuf field of type `" ++ @typeName(T) ++ "` has no zero value."),
    };
}

/// A map entry, which is how a `map<K, V>` travels: a repeated message with
/// the key at 1 and the value at 2. Write a map as `[]const proto.Entry(K, V)`
/// (ADR 245).
pub fn Entry(comptime K: type, comptime V: type) type {
    return EntryOf(K, V, .default, .default);
}

/// An `Entry` whose key or value needs an encoding, as `map<sint64, fixed64>`
/// does.
pub fn EntryOf(comptime K: type, comptime V: type, comptime key_encoding: Encoding, comptime value_encoding: Encoding) type {
    return struct {
        pub const wire = .{ .key = .{ 1, key_encoding }, .value = .{ 2, value_encoding } };
        key: K = zero(K),
        value: V = zero(V),
    };
}
