# One file decides what counts as text

Three files ask whether a type is a run of bytes. `json.zig` asks to decide
whether to write a JSON string or a list; `typed.contentTypeFor` asks to decide
between `text/plain` and `application/json`; `openapi.schemaWithin` asks to
decide between `type: string` and an array schema.

Two of them asked by exact type — `T == []const u8 or T == []u8` — and one asked
`p.child == u8`. So they disagreed, and what they disagreed about was not exotic:

```
covers(struct { name: [:0]const u8 }) = true
nilo : {"name":[104,101,108,108,111]}
std  : {"name":"hello"}
```

with `openapi` correctly writing `type: string` for the same field.

**`json.isByteSlice` is the one answer, and the other two call it.**

## Why this is the same failure as ADR 0076, backwards

[ADR 0076](./0076-a-type-that-writes-its-own-json-says-so.md) was about a `Uuid`
documented as an object and sent as a string. This is a `[:0]const u8`
documented as a string and sent as an array — the same failure running the other
way round, and worse in one respect: there, the document was wrong about a type
the application wrote; here, the *response* was wrong, and a generated client
told to expect a string received a list of numbers.

`typed.contentTypeFor` missed it a third time and labelled the response
`application/json` where a `[]const u8` would have been `text/plain`.

`[:0]const u8` is what `@tagName` returns, what `allocPrintSentinel` returns,
and what any field crossing a C boundary is spelled as. A handler is as likely
to have one in hand as a plain slice.

## Why the tests did not catch it

`expectSame` holds this file's output against `std.json`'s value by value, and
it never asked about this shape — every case in the file was a type somebody sat
down and wrote. **The test that finds this is one that walks a type nobody
thought of**, which is why the new case starts from `@tagName`'s return type
rather than from a struct invented for the test.

## The depth ceiling, which was the same walk with a different ending

`covers` recursed through `.pointer` with no floor, so an ordinary JSON tree — a
comment with replies, a category with children — did not come out wrong. It
failed to compile:

```
http/json.zig:94:52: error: evaluation exceeded 1000 backwards branches
        .pointer => |p| p.size == .slice and covers(p.child),
```

with the message in nilo's own file and its advice wrong: raising the branch
quota buys more recursion, not an answer.

**`max_depth = 8`, and the ceiling answers false**, which sends the value to
`std.json` — the correct answer rather than a degraded one, because `std.json`
recurses over a *value* at run time rather than over a type while compiling. So
the fallback this had fallen off is the one that works.

Eight, because `openapi.schemaWithin` caps the same walk at eight
([ADR 0081](./0081-a-ceiling-that-is-reached-is-said-out-loud.md)). The two
files walk the same types, and disagreeing about how deep is another way for a
response and its description to come apart — which is what the first half of
this ADR is about.

Unlike `schemaWithin`'s ceiling, this one is not said out loud, and that is the
distinction ADR 0081 draws rather than a hole in it: reaching the schema ceiling
changes what the reader is *told*, so it has to be visible. Reaching this one
changes which of two writers runs, and both write the same bytes.

## What it costs

Nothing at run time in either half. `isByteSlice` and the depth argument are
both answered while compiling, and the value they decide between is the same
generated writer as before.

What the byte-slice half *gains* is small and real: a struct holding a
`[:0]const u8` used to send its whole self to `std.json` — `covers` is answered
for the entire value — so a response with one such field paid `std.json`'s
byte-at-a-time string writer for every other field too.

## What it does not fix

`std.json` writes a byte slice as a string **only when it is valid UTF-8**, and
as an array of numbers when it is not. `writeString` always writes a string. So
the "byte-for-byte what `std.json` would have written" contract has been untrue
for invalid UTF-8 since before this change, for `[]const u8` as much as for the
sentinel spellings, and this ADR extends the same behaviour rather than
correcting it. It is written into the roadmap as its own gap; conflating it with
this one would have made a two-line fix into an argument about what a server
should do with bytes that are not text.
