# Protobuf is read from the struct that declares it, with no `.proto` file and no generated code

**Status:** accepted
**Topic:** [proto](../design/proto.md)
**Extends:** [ADR 220](./220-grpc-is-served-over-h2c-behind-a-flag.md) (it said the codec was the caller's to bring; this is the one nilo brings, as a module the caller imports)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 026](./026-the-rule-about-error-messages-is-held-by-a-build-step.md) (every compile error is a file), [ADR 038](./038-a-module-sits-where-the-loop-puts-it.md) (a tool module names nothing), [ADR 242](./242-a-release-is-measured-against-the-one-before-it.md) (a program in `bench/release/`)

## Context

ADR 220 put gRPC behind a flag and left the message to the caller: "the codec is solved and is the caller's to bring", pointing at zig-protobuf. Porting photon's OTLP receiver to nilo showed what that leaves. A receiver for OpenTelemetry has seven message types it reads and none it writes, and a generator turns a 3,000 line `.proto` tree into several thousand lines of Zig, a second build step and a type per message that is not the type the program wanted. photon wrote the codec the nilo way instead: a struct per message, the field numbers on the struct, and the compiler checking both. It was measured against a decoder written by hand, which was the bar the codec had to clear: within 10% end to end, and it passed at 1 to 9% behind. The decision was to move it into nilo once the generic variant passed, and to close the rest of the gap on the way.

The questions were the shape of the declaration, where it sits in the layers, and how close to a hand-written decoder a generic one can get.

## Decision

**`nilo_proto` is a tool module that reads and writes protobuf from plain structs.** A message is a struct with a `pub const wire` naming each field's number; the Zig type decides the protobuf type, and the table says only what the type cannot (an encoding, `.unpacked`). `proto.decode(T, arena, bytes)` returns a `T`, `proto.encode(T, gpa, v)` returns bytes, and nothing is generated and no `.proto` file is read.

### Where it sits

**The Tools layer, importing nothing** ([ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)). It is pure functions over bytes: the allocator and the input are arguments, so `zig test proto/proto.zig` runs the whole suite with no module graph. `nilo_http` names it in `http/otlp.zig`, which only `app.trace` reaches ([ADR 247](./247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)), and in `http/message.zig`, which only a route with a message in its signature reaches ([ADR 256](./256-a-body-is-read-as-what-its-type-says.md)), so a program that neither speaks protobuf nor traces links none of it. A gRPC method is an ordinary route whose argument is the request message and whose return type is the answer; a handler that wants the bytes still calls `proto.decode` itself.

### The types

- **`[]const u8` is a string and is checked to be UTF-8; `.bytes` opts out.** A binary id forgotten as a string fails on the first request. A string forgotten as bytes would let invalid text in without a word, which is why the loud default is the one chosen.
- **`enum(i32)` with `_` is open, and without it closed.** Proto3 keeps an unknown number; proto2's closed enum drops it and leaves the field alone. The spike refused an exhaustive enum; accepting it is the same one-line declaration a caller already makes about what an unknown number means.
- **`?X` on a scalar is proto3 `optional`**, present exactly when written. The spike refused it and sent callers to a one-member oneof; OTLP's histograms (`optional double sum`) are the first place that fails.
- **`?union(enum)` with its own `wire` is a oneof**, its numbers on its members.
- **A repeated number is packed on the way out, `.unpacked` for the peer that needs the other, and both are read.**
- **A map is `[]const proto.Entry(K, V)`.** That is what it is on the wire, and nilo does not choose a hash map for the caller. `proto.EntryOf` takes the encodings a `map<sint64, fixed64>` needs.
- **Unknown fields are skipped, groups included, and not kept.** A merge follows the specification: a scalar takes the last value, a repeated field appends, a message merges, and a oneof member replaces another but merges into itself. Nesting is bounded at 100, prost's limit, and the decoder returns a named error for every malformed input and never panics.
- **Every mistake in a type is a compile error naming the field**, one file each in `proto/refusals/` (26 of them, held by `zig build refusals-proto`).

### How the decoder gets near a hand-written one

The hand-written decoder was photon's variant a: it reads each field off the wire straight into column builders and builds no message at all. The generic variant b builds the tree and a loop then walks it. On the 70 KB loadgen request pinned to one core of a Ryzen 7 9700X, the spike's decoder took 280 ns a row to a's 247, 13% more. What closed it, in the order they were found (`bench/result/proto.md`):

1. **A one byte key finds its field in a 128-entry table.** The spike compared every declared number in turn for every field. The table is built while compiling from the specs of the type, maps `number << 3 | wire type` to the field to fill, and a miss (a key of two bytes, an unknown field, a wrong wire type) takes the general path. The varint reader's slow half takes the buffer and an index and returns both, which keeps the reader in registers. Decoding alone went from 105 to 80 ns a row.
2. **A repeated field is counted before it is filled**, so its slice is exact and never grown. This stays, and it is the floor: the count pass over a `LogRecord` is 15 ns a record, 6% of the request, which a streaming decoder does not pay. A single pass into a scratch stack would save most of it at the price of a second copy of every element and a stack discipline across nested messages; it was not built, and what would settle it is a caller for whom the last 2% matters.
3. **The slices come from one block.** An arena allocation in 0.16 is a compare-and-swap loop, and the spike asked for one a message. The decoder asks the arena for a block of three times the input (the decoded tree is 1.8 to 2.6 times it, measured on seven requests) and carves exact slices out of it, and gives the unused end back. Arena calls for the 1,000-row request went from 1,039 to 38 (variant a: 35). **This changed no time at all** (79.5 against 79.7 ns a row decoding), and it stays because the allocation count is the hard axis and a decoder given a general-purpose allocator pays for a call.
4. **The UTF-8 check has a short-string path.** std's validator handles the last partial vector chunk byte by byte, and a string in a message is 5 to 40 bytes: two overlapping loads cover up to 16 bytes, 64-byte steps cover the rest, and only a byte of 0x80 or more reaches std. In isolation it is 1.5 to 4 times faster up to 16 bytes and level beyond. **End to end it also moved nothing**, because the check is off the critical path. It stays because it is measured faster and costs 40 lines, and it is the first thing to drop if somebody wants the module smaller.

Interleaved, pinned, both sides ReleaseFast the same afternoon, the whole request (decode, mapping, columns, sealed frame) against variant a: **+0.4% on the 500 row request (min, median +0.8%), -0.2% on the 1,000 row fixture (median 0.0%), +2.6% on the 37 row one**, against +13.0%, +11.3% and +14.3% for the spike's decoder. The floor of the method is on the other axis: with nothing downstream, decoding into a tree and summing it is 73% over streaming the same fields, because the tree is built and read and the stream is read once. photon's request does 160 ns a row of other work with the result, which is what makes the difference 0.4%.

### How it encodes

**A message is sized once and written once.** `encodedSize` is exact, `encodeInto` fills a caller's buffer, and `encode` is one allocation of that size. The writer fills the buffer from the back, so a length prefix is the distance the position moved and no nested message is sized again; prost sizes every level again, which is quadratic in depth. Fields come out in number order, so equal values are equal bytes. Photon's prost fixtures decode and encode back to the same bytes.

## What it costs

The four axes ([ADR 017](./017-the-trade-budget-has-four-axes.md)):

- **Allocations per request:** nothing that exists changes, since nothing in `http/` names the module. A decode makes about one allocator call for every 100 KB of input (two for the 160 KB request in `bench-proto`, three for the 320 KB fixture) where the spike made one a message.
- **Memory per idle connection:** unchanged; the module is not linked.
- **Throughput and p99:** not on the request path. Against a hand-written decoder the whole pipeline is within 0.4% to 2.6%, above.
- **Binary size:** a program that does not import it pays nothing. The release program (`bench/release/proto.zig`: seven message types, decode and encode) is 261,656 bytes stripped `ReleaseFast` against 229,384 for a program that does nothing, so **32,272 bytes** for those types. Each message type is the code for its own fields.

It costs one row in `layers` and in `shipped_roots`, a `.paths` entry, a program in `bench/release/`, a refusals table of 26 files and a design, guide and reference page. `bench/release.py` needs valgrind, which the machine this was written on does not have, so the instruction count is the next release's to take.

## What was rejected

**zig-protobuf, or any generator, as the supported path.** It remains a fine choice when a `.proto` file is the contract and the types are many (nilo reads and writes bytes and never looks inside them). It is rejected as nilo's answer because it puts a second source of truth, a build step and a type the program did not choose between the caller and a message, and the idea nilo rests on is that the type already written is the contract.

**Parsing a `.proto` file at compile time with `@embedFile`.** It would keep one schema, and it would need a parser for the language (imports, options, services) to produce types the caller then cannot add a method to. The struct is shorter than the file for a receiver that reads seven messages.

**A per-field annotation instead of a `wire` table.** Zig has no field attributes; a `nilo_field_name = 1` declaration per field puts the numbers away from each other, and the table is one place to read a message's whole layout.

**Keeping unknown fields.** It costs a list per message and an allocation on every decode, for a case (a proxy passing a message through) that `proto.Reader` already serves by copying the bytes it did not name.

**A growable list per repeated field in place of the count pass.** It allocates as it grows and copies at the end, and the count pass over a message is 15 ns a record. Not measured against, and not built; it reads as a loss on the allocation axis and a gain of at most 6% in time.

**A hash map for `map<K, V>`.** It would put an allocation and a hash function on every map field, and a lookup over a handful of entries is a scan. The entries are there for the caller to put in the map they want.

**A decode that returns an error where it meets an unknown enum number.** That is the proto3 rule broken for the sake of a closed type: an older receiver would reject a newer sender's message for a field it does not read.
