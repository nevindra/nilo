# A whole number inside a range is a type

**Status:** accepted
**Topic:** [request-input](../design/request-input.md)

huma writes `limit int` with the tag
`query:"limit" default:"50" minimum:"1" maximum:"200"`, and both the refusal
and the document come from the tag. `nilo.Query(T)` had the default and not
the bounds, so every list endpoint in the port opened with

```zig
if (q.value.limit < 1 or q.value.limit > 200) return nilo.fail.unprocessable("limit must be between 1 and 200", .{});
if (q.value.offset < 0) return nilo.fail.unprocessable("offset must be at least 0", .{});
```

and the document said nothing about either. Two lines is not much. The
document not saying it is the half that matters, because the client is
generated from it — and it is the same two lines on the thirty-odd list
operations still to port.

## Why not a marker

The obvious spelling is a tag's: `pub const nilo_bounds = .{ .limit = .{ .min
= 1, .max = 200 } }` on the query struct. `convert.Reason`'s comment is the
argument against it, and it stands: nilo's job stops at "this did not convert
to a `u32`"; whether the age is plausible is the application's question, and a
reason set that grew to answer it would be a validation language wearing a
smaller name. A marker of bounds is the first word of that language.

But a `u8` already refuses 300, and a `u32` already refuses `-1` — the second
line above was never needed on an unsigned field — and nobody calls either a
validation. **The type has a range, and the text did not fit it.** What was
missing was a way to choose the range rather than inherit it from a width.

## `nilo.Within(min, max)`

```zig
const ListQuery = struct {
    limit: nilo.Within(1, 200) = .of(50),
    offset: u32 = 0,
};
```

A struct holding the narrowest integer that fits the range — `u8` here,
`u17` for `Within(0, 100_000)` — that parses itself
([ADR 113](113-a-path-param-can-parse-itself.md)): the digits, read the way
a `u32` is read from request text, refused outside the range with the null a
bad number gets. So it is read wherever a `u8` is read — a path param, a query
value, a form field, and since [ADR 166](166-a-body-field-that-parses-itself.md)
a JSON body — with one sentence for all four, in the type's own words:

```
?limit has to be a whole number from 1 to 200, not "500"
```

The document says `{"type":"integer","minimum":1,"maximum":200}`, read off the
type by name (`nilo_within`). A client generated from it refuses the same
value before sending it, which is the half the two lines could never do.

**And an integer says the range of its type.** It refuses `-1` on a `u32` and
256 on a `u8` with a 400, so the document may promise both ends — a promise
the signature settles, which is the only kind this document makes. A `u32` is
`minimum: 0, maximum: 4294967295`, an `i8` is `-128` to `127`, and a `u64` or
`i64` states its full range because the reader takes the token's digits
exactly (ADR 084), so a number past 2^53 is not rounded. `Bounds` is an
`i128`, so a `u128` states `minimum: 0` and no `maximum` rather than a wrong
one.

## What it costs the caller

**`.value`.** The integer is inside a struct, so handing it to a `LIMIT` is
`q.value.limit.value`. Zig has no way to give a struct the arithmetic of its
one field, and a type that hid the wrapper would be one nilo could not read a
range off. The port's two lines were at the top of every handler; the
`.value` is at the one place the number is used.

**`.of(50)` for the default**, rather than `.{ .value = 50 }`. The default is
the one value a request never sends, so it is the one the bound would never
catch — `.of` checks it against the range while compiling, and a default
outside it is a Refusal. `Within(200, 1)` is the other.

## What was not done

**`minimum`/`maximum` on `nilo_openapi`.** `Told`'s comment refuses it, and
the refusal is right: a marker is a claim, and a type that *claimed* a range
it did not hold would put a promise in the document nobody enforces. The
bounds here are read off a type that enforces them, which is a different
thing from letting any type declare them.

**Leaving the upper bound of an integer's width out.** This said `minimum: 0`
and not `maximum: 255`, on the ground that 256 on a `u8` is a field that
should have been wider and a document full of `maximum: 4294967295` is noise.
It was reversed because the server does refuse 256 on a `u8` with a 400, so a
document that stays silent is looser than the server, and a generated client
with a `u8` field cannot refuse the value before sending it. The noise is the
price of the document being as strict as the server.

## Against ADR 017's four axes

Nothing per request: the range check is the same comparison the two lines
made. Nothing per connection. Nothing in the binary for a program that names
no `Within`; one that does carries a `nilo_parse` per distinct range.

## Consequences

- `nilo.Within(min, max)`, `.of(n)`, `.value`, `.lowest`, `.highest`.
- Every integer in every generated document carries its type's `minimum` and `maximum`.
  A test that compared the document byte for byte on such a field has one
  more key in it.
- Two Refusals: bounds the wrong way round, and a default outside them.
- The port's two lines go from every list handler, and the document says
  what the handler holds.
