# Can a JSON body be read without `std.json.Scanner`?

A prototype of one reader per request type that goes from the body's bytes straight to the caller's struct, in one pass, with no tokenizer under it. `json.parseLeaky` is already a comptime walk per type ([ADR 084](../../docs/adr/084-a-number-in-a-request-is-not-a-zig-literal.md)); what is slow is the `std.json.Scanner` it walks over, which tokenizes byte by byte. The prototype replaces the scanner and keeps the walk. Nothing here is merged and no ADR decides it.

## What is in the directory

- `0001-json-reader.patch`: the new `http/jsonread.zig` (the reader and its differential test), the two lines in `http/json.zig` that send a supported type to it and keep `parseLeakyStd` for the rest, and one line in `http/profile.zig`.

The reader handles `bool`, integers, floats, `Str`, `[]const u8`, optionals, slices, plain enums, plain structs and internally tagged unions. Strings are scanned 16 bytes at a time, and a string with an escape is handed to `std.json.Scanner` for that one token, so escape decoding stays std's. Keys are compared in place and never copied. A skipped value uses a 64-bit stack, with no recursion and no allocation. Numbers go through ADR 084's `spelledAsNumber` and `std.fmt`. A tagged union is read in one pass when its tag comes first, and found then read again otherwise. A type with its own `jsonParse`, `Patch`, maps and `std.json.Value` still take the std path.

## Base and how to apply

The patch applies to `ee40845` ("perf: read a tagged union once when its tag comes first") and to the commits after it on `unify-h1-h2`:

```
git apply spike/json-reader/0001-json-reader.patch
zig build test -Dtarget=x86_64-linux-gnu
zig build profile -Dtarget=x86_64-linux-gnu
```

**On that tree `zig build test` fails three tests**, because the prototype was measured before the tagged-union reader it sits beside was finished, and was not brought up to it:

- `jsonmark` "a tagged variant is refused the same way whether its tag opens the object or comes after its fields";
- `jsonmark` "a key inside what a variant holds is not held to the variant's keys, tag first or last";
- `behaviour` "a message read and answered as protobuf allocates no more than the same message as JSON".

Read from the test names and not traced: the first two are refusals the shipped reader makes and the prototype does not make the same way, and the third compares a message's allocations in its two spellings, a count the prototype moves on the JSON side. Each is a reason the prototype is not the change as it stands.

The profile section "one array of 1000 objects read as a body" holds the rows below. Time it the way [`bench/result/http.md`](../../bench/result/http.md#what-a-request-on-http2-costs-once-its-clocks-copies-and-passes-are-counted) says: copy each binary to one path and run it as `env -i PATH=/usr/bin taskset -c 2 ./nilo-profile`.

## What it measured

On 2026-10-08, AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `ReleaseFast`, two rounds, against the tree at `ee40845`. Per object of a thousand-object array:

| row | `ee40845` | prototype | factor |
|---|---|---|---|
| untagged | 125 ns | 45 ns | 2.8x |
| tag first | 150 ns | 58 ns | 2.6x |
| tag last | 283 ns | 130 ns | 2.2x |
| three variants | 96 ns | 40 ns | 2.4x |

A whole request with a 13-byte body went from 380 to 300 ns on the plain-struct control and from 395-406 to 327-338 on the message row. A whole request cannot move by the reader's factor, because reading the body is about 85 ns of 380.

The differential test in `jsonread.zig` mutates four valid bodies 400,000 times and reads each through the prototype and through `parseLeakyStd`, 800,000 reads in all, including a union type. No input was accepted by one reader and refused by the other, and every accepted value was equal. In the refusals, the two named different errors (`SyntaxError` against `UnexpectedToken`, for one) on bodies with two mistakes, because they stop at a different byte. The 400 sentences in `ctx.zig` were not run against it.

Stripped `ReleaseFast` size: `example-hello` +0, `example-rest` +3,504 bytes, `example-orders` +3,232. Compile time was not measured cleanly.

## What it costs and closes off

- A second JSON grammar in the repository, which has to agree with std's for ever. The differential test would have to become a build step, and a `std.json` change upstream would have to be followed here.
- `use_first` and `use_last` for duplicate struct keys are not rebuilt.
- A string borrowed from the body was not tried, because the body's lifetime is not the arena's on every path.

The open decision is the entry "A JSON body could be read 2.2 to 2.8 times faster..." in [`docs/todo.md`](../../docs/todo.md).
