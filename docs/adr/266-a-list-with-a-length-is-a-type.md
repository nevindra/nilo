# A list with a length is a type

**Status:** accepted
**Topic:** [request-input](../design/request-input.md)
**Extends:** [ADR 193](./193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md),
whose `Text` is the answer for a string's length; this is the answer for how
many a list holds.
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 084](./084-a-number-in-a-request-is-not-a-zig-literal.md),
[ADR 132](./132-a-query-parameter-or-a-form-field-that-is-a-list.md),
[ADR 167](./167-a-whole-number-inside-a-range-is-a-type.md),
[ADR 166](./166-a-body-field-that-parses-itself.md).

## Context

`Within` bounds a number and `Text` bounds a string, and nothing bounds a
list. `orders` opened its placing handler with `if (incoming.lines.len == 0)
return fail.unprocessable("an order needs at least one line", .{})`, and the
document said nothing about it, so a generated client could not refuse the
empty order before sending it. go-playground has `min=1,max=5` on a slice,
zod has `.min(1).max(5)` on an array, and a migrant looks for the same.

## Decision

**`nilo.Many(Item, .{ .min = 1, .max = 5 })`** is a struct holding a
`[]const Item` as `.value`, with `len()` forwarded and `.of(&.{…})` for a
default checked against the count while compiling. `min` and `max` are both
optional, at least one is required, and both are inclusive.

```zig
const NewPost = struct { tags: nilo.Many(nilo.Str, .{ .min = 1, .max = 5 }) };
```

**It reads where a list is read: a JSON body and a form.** In a body the
array is read exactly as a `[]const Item` is (`json.innerRead`, so a number
inside is spelled as a query's is, ADR 084), then counted; the count is
checked after the whole list is read, so a list that is too long is reported
as that and not cut short. In a form the values sent under one name are
collected as ADR 132 collects them, then counted, and an empty group is a
count of none. The sentence is the same in both and in `Bound`:

```
"tags" has to be a list of 1 to 5 items, not a list of 7
```

A bad element is named by position, as it is in a plain list (`"tags[2]"`),
and `Bound` collects the count beside every other field (a `wrong_kind`
outcome whose kind is `a list of 7`, so no new Reason was needed). The
document says `{"type":"array","items":<the element's schema>,"minItems":1,
"maxItems":5}`, read off the type by name (`nilo_many`), the way `nilo_within`
and `nilo_text` are.

**A query string is not one of them, and says so while compiling.** `?tag=a,b`
is the one place a list has two spellings (ADR 132) and the document there
is `style: form, explode: false`; a count in the type would promise a bound
the generated parameter cannot carry. A `Many` in a `Query(T)` is a Refusal
naming the field and pointing at the plain slice.

## The name

`Many` because it says how many, not what: `List`, `Array` and `Slice` name
the container, which the field already is, and `Items` collides with the
OpenAPI keyword of the same name in a document that also says `items`.
`Bounded` and `Sized` say that something is limited and not that it is a
list, which `Within` and `Text` already say for the other two. Alongside
`Within(1, 5)` and `Text(.{ .max = 30 })`, `Many(Str, .{ .max = 5 })` reads
as a sentence. The options struct is `Text`'s, not `Within`'s two positional
numbers, because the element type is the first argument and a bound pair
after it reads `Many(Str, 1, 5)` with nothing saying which is which.

## What was not done

**Reusing `Within` for a slice.** `Within(1, 5)` on a `[]const T` field
reads as a range of values, not a count of them, and its `.value` is a number
in every other use. One name for two meanings is the ambiguity a type was
meant to remove.

**A marker on the struct** (`nilo_bounds = .{ .tags = .{ .max = 5 } }`),
refused by ADR 167 for the reason it gives: a marker is the first word of a
validation language and names a field the compiler would then have to check
exists.

**Reading a `Many` from a query string.** Above.

## Against ADR 017's four axes

- **Allocations per request:** none beyond the slice a plain `[]const Item`
  already allocates; a route that names no `Many` compiles none of this.
- **Memory per idle connection:** none; the type is a slice and a length,
  built in the handler's frame.
- **Throughput and p99:** one comparison after the list is read; nothing was
  measured because nothing is added to a request that did not ask.
- **Binary size:** a program that names no `Many` carries nothing (a type is
  instantiated where it is written); one that does carries a `jsonParse` per
  distinct element type, as a plain `[]const Item` field does.

## Consequences

- `http/many.zig`: `nilo.Many`, `nilo_many`, `nilo_wrap`, `fitsCount`,
  `itemOf`.
- `http/ctx.zig`: the body's diagnosis (`fits`, `describeField`,
  `collectBadBody`, `expectedOf`, `hasInsides`) knows a `Many`.
- `http/form.zig`, `http/bound.zig`: a form collects and counts one, and a
  binding words its element's failure as any list's.
- `http/openapi.zig`: `Schema.limited`.
- `http/typed.zig`: a `Many` in a `Query(T)` is a Refusal.
- Five Refusals under `refusals/many_*`: bounds reversed, no bound, a list
  of bytes, a default outside the bound, and a query.
- A `Many` is a document of its slice (`nilo_json_of`, ADR 163), so a
  response carrying one is written by nilo's own writer as the array, and
  `rename_all`, `.rename` and `.skip` inside its items apply as for a plain
  slice (ADR 148).
