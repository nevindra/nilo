# Protobuf messages

**`nilo_proto` reads and writes protobuf as plain Zig structs: you declare the field numbers on the type you already wrote, and it decodes and encodes it.**

**Reference:** [`nilo_proto`](../reference/proto.md#nilo_proto), [`proto.decode`](../reference/proto.md#protodecode-and-protomerge), [`proto.encode`](../reference/proto.md#protoencode), [the `wire` table](../reference/proto.md#the-wire-table) · **Design:** [Protobuf](../design/proto.md)

It is for the other end of a contract you did not write: an OpenTelemetry Collector sending OTLP, a gRPC client whose service is defined in a `.proto` file, a queue whose messages are protobuf. It is a tool module with no event loop and no allocator of its own, and it imports nothing, so `zig test proto/proto.zig` runs all of it ([ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)).

```zig
const proto = @import("nilo_proto");
```

and one line in `build.zig`, beside the `nilo_http` one:

```zig
.{ .name = "nilo_proto", .module = nilo.module("nilo_proto") },
```

## A message is a struct with a `wire` table

<!-- compiles -->
```zig
const proto = @import("nilo_proto");

const HelloRequest = struct {
    pub const wire = .{ .name = 1 };
    name: []const u8 = "",
};

const HelloReply = struct {
    pub const wire = .{ .message = 1, .served_at_ms = .{ 2, .fixed64 } };
    message: []const u8 = "",
    served_at_ms: u64 = 0,
};

fn sayHello(arena: std.mem.Allocator, request: HelloRequest) !HelloReply {
    return .{
        .message = try std.fmt.allocPrint(arena, "hello, {s}", .{request.name}),
        .served_at_ms = @intCast(nilo.nowMillis()),
    };
}
```

**A handler whose argument is a message reads it, and one that returns a message writes it**, in protobuf to a client that sent protobuf and in JSON to one that sent JSON ([Requests](./requests.md#protobuf-and-other-formats)). `proto.decode` and `proto.encode` below are for everywhere else: a queue, a file, or a handler that wants the bytes.

**The number is on the type and the Zig type is the protobuf type.** `.name = 1` on a `[]const u8` is a string, `.served_at_ms = .{ 2, .fixed64 }` on a `u64` is a `fixed64` rather than a `uint64`. The table says only what the type cannot: a field number, and for a number the encoding it travels as.

**Every field has to be in the table, or the program does not compile.** A forgotten field, a number used twice, a type protobuf has no word for (a `u16`) and a oneof that is not optional are each an error naming the field and the line to write. There is no way to ship a message that silently drops a field.

## Reading what arrives

**`proto.decode(T, arena, bytes)` returns a `T`.** Strings and bytes in it point into `bytes`, so they cost nothing and live as long as the input does. Repeated fields are allocated from `arena`: inside a request that is `c.arena()`, and there is nothing to free.

**A field the type does not declare is skipped.** A newer sender is read by an older receiver, and a field you do not care about costs one step over it. They are not kept: decode and encode again and they are gone.

**Bad bytes are an error, never a crash.** `error.Truncated`, `error.InvalidUtf8`, `error.WrongWireType`, `error.TooDeep` and the rest are listed in the [reference](../reference/proto.md#errors), and a handler turns any of them into the 400 its caller deserves.

## Strings, bytes and UTF-8

**`[]const u8` is a string, and a string is checked to be UTF-8**, as every conforming parser checks it. A trace id or a hash is bytes and says so:

<!-- compiles -->
```zig
const proto = @import("nilo_proto");

const Span = struct {
    pub const wire = .{ .trace_id = .{ 1, .bytes }, .name = 2 };
    trace_id: []const u8 = "",
    name: []const u8 = "",
};
```

A trace id forgotten as a string fails the first time one holds a byte over 0x7f. The other mistake, a string forgotten as bytes, would let invalid text in without a word, so the default is the one that is loud.

## Repeated fields, optional fields and oneofs

<!-- compiles -->
```zig
const proto = @import("nilo_proto");

const Point = struct {
    pub const wire = .{ .label = 1, .xs = 2, .weight = 3, .shape = 4 };
    label: []const u8 = "",
    xs: []const i64 = &.{},
    weight: ?f64 = null,
    shape: ?union(enum) {
        pub const wire = .{ .circle = 5, .square = 6 };
        circle: f64,
        square: f64,
    } = null,
};
```

- **`[]const X` is repeated.** Numbers are written packed, which is what proto3 does, and both packed and unpacked are read. `.xs = .{ 2, .unpacked }` writes proto2's one key a number for a peer that needs it.
- **`?f64` is proto3 `optional`**: present exactly when it was on the wire, so zero and absent are different. A plain `f64` is left out when it is zero.
- **`?union(enum)` with its own `wire` is a oneof.** Its numbers sit on its members, and `null` is none of them.
- **A `map<K, V>` is `[]const proto.Entry(K, V)`.** That is what it is on the wire.

## An enum is open unless it says otherwise

**A proto3 enum keeps a number the program has not heard of**, so a sender with a newer version never breaks you. Write `enum(i32)` with a `_` member:

<!-- compiles -->
```zig
const proto = @import("nilo_proto");

const Severity = enum(i32) { unspecified = 0, info = 9, warn = 13, err = 17, _ };

const Event = struct {
    pub const wire = .{ .severity = 1 };
    severity: Severity = .unspecified,
};
```

An enum without the `_` is a closed enum, which is proto2's: a number it does not name is dropped and the field keeps its value. That is a choice about what an unknown value means, and the type is where it is made.

## Writing a message

**`proto.encode(T, gpa, value)` is one allocation of exactly the right size.** For a buffer of your own, ask for the size and write into it:

<!-- compiles -->
```zig
const proto = @import("nilo_proto");

const Ping = struct {
    pub const wire = .{ .seq = 1 };
    seq: u64 = 0,
};

fn frame(buf: []u8, seq: u64) ![]u8 {
    const ping: Ping = .{ .seq = seq };
    if (proto.encodedSize(Ping, ping) > buf.len) return error.NoSpaceLeft;
    return proto.encodeInto(Ping, buf, ping);
}
```

Fields are written in number order, so equal values are equal bytes: a hash of a message means something.

## Merging and concatenating

**Two encodings back to back are one message**, and a field that occurs twice is merged the way the specification says: a scalar takes the last value, a repeated field appends, a message merges field by field. `proto.merge(T, arena, &value, more_bytes)` applies bytes on top of a value you already hold.

## What it costs

**Decoding allocates about once for every 100 KB of input**: the slices of repeated fields are cut exactly from one block, whose unused end goes back to the arena, so a 160 KB request is two allocator calls rather than one a message. The whole of a logs pipeline built on it runs within 0.4% to 2.6% of a decoder written by hand to stream the same fields into columns ([`bench/result/proto.md`](../../bench/result/proto.md)). A program that speaks no protobuf links none of it.

## When a hand-written decoder is the better tool

**`proto.Reader` is the wire without the types**, for a receiver that wants a stream of rows and never a tree of structs: it reads keys, varints and length delimited fields, skips what it does not want, and refuses what the generic decoder refuses. The generic one is the right start. Reach for the reader when you have measured and the tree is what costs.

## What it does not do

- **proto2.** No required fields, no declared defaults, no extensions.
- **The well-known types.** `Timestamp` is a struct with `seconds` and `nanos`; write it.
- **A `.proto` compiler, JSON or reflection.** The types are the schema.
- **gRPC.** The call, its framing and its status codes are [`nilo_http`'s](./grpc.md); this is the message inside it.
