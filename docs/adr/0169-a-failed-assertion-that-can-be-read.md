# A failed assertion that can be read

`std.testing.expectEqual` prints both sides with `{any}`, and `{any}` is the
specifier that means *do not call the type's own formatter*. So a `Uuid` prints
as sixteen decimal numbers and a `[]const u8` prints as its bytes. On the schema
that reported this — 145 uuid columns — nearly every row a test asserts on comes
out as noise, and a failure you cannot read is a failure you re-run with print
statements.

The port filed it last and said so: they had almost not filed it at all. Their
reasoning was that `std.testing` prints with `{any}`, `{any}` skips custom
formatters by design, and therefore nobody can fix it. The first two facts are
right and the conclusion does not follow — **"the layer below cannot fix it" is
not "nobody can"**, and `nilo.testing` already exists, one layer up, holding the
`Refusals` that made their refusal tests readable in the first place.

## What it does now

```zig
errdefer std.debug.print("row: {f}\n", .{nilo.testing.show(row)});
```

`show` renders a value as JSON into whatever writer is formatting it, because
that is the rendering nilo already has for every type it carries and did not
have to invent: `Uuid.jsonStringify` writes text, `Str` writes a string, a
`Timestamp` writes RFC 3339, a `Decimal` its digits rather than a float.
Nothing is allocated. For an actual `[]const u8`,
`std.fmt.allocPrint(gpa, "{f}", .{show(v)})` is the ordinary spelling and needs
nothing from here.

## Why a renderer and not an `expectEqual`

The first shape built here **was** `expectEqualJson`, and the caller who
reported the problem argued it down. Three reasons, and the second is the one
that decides it:

1. **An `expectEqual` of nilo's own pulls the rest of the assertion surface
   behind it.** Once it exists, `expectEqualDeep`, `expectEqualSlices` and
   `expectError` are all asked for; every one nilo does not have looks like a
   gap, and every one it does have has to follow `std.testing`. That is an
   unbounded surface to have taken on for a printing problem.
2. **It would not have helped the failure this was reported from.** That was an
   `expectError` that found a payload — not two values that differed — and an
   equality helper has nothing to say about it. A renderer works there, in
   `expect`, and in the `std.debug.print` somebody reaches for while poking
   about, which is where it gets used most.
3. **What a person wants from a failed test is to read the row**, not to be
   given a verdict. `try testing.expect(x)` plus one line that prints the row is
   enough, and it asks nilo to know nothing about the shape of the assertion.

The lost property is real and worth naming: comparing the *rendering* would have
made equality deep for free, where `std.testing.expectEqual` compares a slice by
pointer and length. `std.testing.expectEqualDeep` is the answer to that and is
not nilo's to reimplement.

## The alternatives that were rejected

**`expectEqualJson`, which is what was built first.** Argued down above, by the
caller it was built for.

**Returning `![]const u8` rather than a formatter.** That is what was asked for,
and a formatter turned out to be strictly more: it needs no allocator and no
`defer free`, so it fits inside a `std.debug.print` unchanged, and the string
version is one `allocPrint` away for anybody who wants to search in it.

**Nothing, on the grounds that it is `std`'s to fix.** `{any}` behaving that way
is deliberate, so there is nothing there to fix. A layer that has a rendering for
these types and does not offer it is choosing the unreadable output too.

## Consequences

- One public function and one public type in `http/testing.zig`, plus two
  tests. Nothing on any measured axis: it is test-only and no running server can
  reach it.
- Nothing is allocated. It writes into the writer that is already formatting it.
- A type that cannot be serialised to JSON will not compile here, which is
  honest: the readable message *is* the JSON.
- A `sql.Json(T)` column nests JSON inside the JSON. That reads well and the
  output is **not** meant to be parsed back — it is for a person reading a
  failure, and saying so is cheaper than a quoting rule nobody wants.
