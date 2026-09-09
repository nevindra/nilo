# A leaf that says what it is can be carried

[ADR 0181](0181-a-field-name-is-a-spelling-too.md) shipped `rename_all` on a
struct's fields, and closed the way it could be silently wrong: a renamed struct
whose value falls back to `std.json` is a compile error, because `std.json` does
not read the marker.

The refusal was right. It also meant **no response in the product that asked for
the feature could use it.**

## What the refusal actually caught

`covers` answers false for any struct holding a type with its own
`jsonStringify`. Four of those are nilo's own — `sql.Uuid`, `sql.Timestamp`,
`sql.AsText` (so `Interval`, `Inet`, `Decimal`) and `id.Uuid`.

The reporting port has **145 `uuid` columns across 59 tables**, so every key in
the product is a uuid and every response holds at least one. All ten of the
response structs ADR 0181 was written for were out. They tried the change and
reverted it.

```zig
const WithUuid = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };
    id: sql.Uuid,
    full_name: []const u8,
};
```

```
error: nilo: `t.WithUuid` renames its fields, and this value goes to `std.json`,
       which does not read the marker (ADR 0181).
```

Take the `id` out and the same struct sends `fullName`.

## The line was in the wrong place

`covers` asked *does this type write its own JSON?* and treated yes as a wall.
The better question is *does it write its own JSON **and say what that JSON
looks like**?* — because a type that says so has already promised the shape this
writer needs:

```zig
pub const nilo_openapi = .{ .type = "string", .format = "uuid" };
```

`openapi.toldOf` accepts four values for `type`: `"string"`, `"integer"`,
`"number"`, `"boolean"`. **A marker is a promise that the value is one scalar
with nothing nested in it**, which is exactly the promise needed to keep writing
the punctuation on both sides of it. So a type carrying both declarations is a
**leaf**: `writeValue` hands the value itself to `std.json` and goes on writing
the object around it.

`jsonStringify` alone is still a wall, and that is the same line ADR 0076 drew
for the document. A type that writes itself and never says what it wrote is a
shape neither the writer nor the schema can describe, and it stays `std.json`'s
whole value.

## The output does not move, and that is checked rather than hoped

The leaf is written by `std.json.Stringify.value` — the same call the whole
value used to go through, on the same value. So this file's contract, that its
output is byte-for-byte what `std.json` would have written, holds by
construction rather than by care. The spike asserts it before it times anything.

## What it is worth

`spike/leaf_json/`, ReleaseFast, on a 305-byte contact row with three uuids and
four strings — one row of the list this was reported from:

| | ns |
|---|---|
| **A** `std.json`, whole value — before | 244–254 |
| **B** generated writer, leaf to `std.json` — after | 161–169 |
| **C** control: the same struct with the uuids already text | 102–121 |

**33% off a response that was paying `std.json`'s byte-at-a-time string
escaping for every string in it because of one field.** Row C is the ceiling:
what is left of B over it is the three `jsonStringify` calls, which is the leaf
itself and is not going anywhere.

This is the same finding ADR 0085 recorded for unions, reached from the other
side. `covers` is answered for the *whole* value, so every type it refuses is
paid for by every string beside it.

## Against ADR 0018's four axes

- **Allocations per request: zero.** Nothing here allocates; both paths write
  into the response writer.
- **Memory per idle connection: zero.**
- **Throughput: a saving.** The numbers above. Nothing gets slower: a type that
  was covered before is covered now, by the same code.
- **Binary size: a generated writer where there was a `std.json` call.** For a
  type that holds no leaf, unchanged. For one that does, the generated writer
  for the struct is emitted where the `std.json` reflection for it used to be —
  measured at ±0 on the two release binaries, which do not carry one.

## Consequences

- `rename_all` is usable on the responses it was asked for, which is what
  reopened item 46 in the first place.
- Every response holding a `sql.Uuid` or a `sql.Timestamp` gets the generated
  writer, whether or not it renames anything. That is the larger half of the
  change by request count and nobody asked for it.
- The three refusals ADR 0181 added all still fire. The fallback refusal now
  fires for a genuinely narrower set — a tuple, an array of bytes, an untagged
  union, a type that writes itself and says nothing, anything past eight deep.
- A type outside nilo gets this by writing the same two declarations, which is
  the contract ADR 0046 already offers and this is its second reader.
