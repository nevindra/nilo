# A field name is a spelling too

`rename_all` renamed an enum tag and a union variant. `json.zig` wrote `f.name`
for a struct field, and the test at the bottom of that file said so in its own
title: *a tag and a case together rename the variant but not its fields*. That
was a decision, and this reverses half of it.

## What the line cost

A Row is snake_case because Postgres is. A wire is camelCase because the browser
is. Between the two, in one ported context: **10 response structs, 77 fields, 5
mapping functions written out field by field, 3 more mapped inline in handlers
and 5 arena loops** — and the whole job of all of it was `full_name` becoming
`fullName`.

```zig
fn contactDto(row: rows.Contact) ContactDTO {
    return .{ .id = row.id, .partnerId = row.partner_id, .fullName = row.full_name, … };
}
```

**Nothing holds a Row field against the DTO field carrying it**, and that is the
part that is not about typing. A column added to a Row reaches the wire only if
somebody remembers a second file; the response that quietly lacks it compiles,
validates, and generates a client that has never heard of it.

## What was added

```zig
const Contact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    id: Uuid,
    full_name: Str,
    partner_id: Uuid,
};
```

Opt-in per struct, on the marker that already existed. `json.write` reads it and
`openapi.schemaWithin` reads the same one, so the document promises the keys the
server sends. That second half is not optional: ADR 0076 is this failure
recorded once already, when a `Uuid` went out as 36 characters and was described
as an object with a `bytes` field.

**It costs nothing per request.** The name is a comptime string either way, and
it is written as part of the same `writeAll` the punctuation is in — a renamed
struct writes exactly as much as a plain one, which is the sentence the enum arm
has made since ADR 0085.

## The marker is per type, not inherited

A struct's `rename_all` renames that struct's fields and nothing else. A union's
renames its *variants*, and a payload struct's own marker is what renames the
payload's fields — so the pre-existing test keeps its title and its assertion,
and a nested struct that says nothing keeps its own spelling. Two markers, each
about its own type, is a rule that can be read off one declaration.

## One direction, and the other one is a Refusal

The caller asked for the write side only, and gave the reason: `std.json` chooses
the parser for a body, so an input struct would need `jsonParseFor`, and **one
mechanism working in one direction beats two that can disagree about one field.**

That leaves a way to be silently wrong, so it is closed while compiling. A struct
that renames its fields, used as a request body, a form or a query string, is a
compile error naming the route — because that route would document `fullName` and
answer 400 to a client that sent it. The check walks eight deep, the same ceiling
`covers` and `schemaWithin` have, so a renamed struct nested inside a body is
caught too.

A *union* is not this and neither is an enum: both read back through
`jsonParseFor`, which is the supported way in (ADR 0085). Only a struct has no
reader, and only a struct is refused. `parseFor` on a renamed struct gets a
sentence of its own saying so, because that is where somebody trying it lands.

The second Refusal is the collision `checkRenames` already held for enums and
unions, now true of fields: `.lowercase` joins the words, so `full_name` and
`fullname` land on one key, an object carries that key twice, and a reader takes
whichever it met last. A mistake that corrupts the wire rather than failing.

## The third Refusal is the fallback, and it is the one that would have been missed

`covers` errs narrow on purpose: **one shape it does not recognise sends the
whole value to `std.json`** — a tuple, an array of bytes, an untagged union, a
type with its own `jsonStringify`, anything nested more than eight deep.
`std.json` does not read `nilo_json`.

So `struct { rename_all = .camelCase; full_name: []const u8, avatar_hash: [16]u8 }`
would have gone out as `full_name` while `openapi.schemaWithin` — which has no
such narrowing and describes the struct's fields either way — promised
`fullName`. No error, on one response, for whoever added the sixteenth byte.

`json.write` asks before it hands the value over: a rename-marked struct anywhere
inside a value that falls back is a compile error naming the type. The check
reuses `renamedFieldsWithin`, the same walk the incoming refusal uses, because
the two questions are one question asked in two directions.

## Against ADR 0018's four axes

- **Allocations per request: zero.** Comptime strings.
- **Memory per idle connection: zero.**
- **Throughput: zero.** `mark.of(T)` is answered while compiling and `mark.wire`
  produces a literal. The generated writer emits the same `writeAll` count as
  before; only the bytes in the literal differ.
- **Binary size: unchanged for a type that says nothing**, and a renamed one
  carries the same total length of key literals it would have carried had they
  been written that way by hand.

## Consequences

- `wireNames(T)` answers for a struct as well as an enum and a union, so the
  reader, the writer and the document all ask one function what a name is.
- `checkTag` compares the tag's key against the payload field's **wire** name,
  because that is the one that would collide.
- The five mapping functions and the arena loops in the report have nothing left
  to do.
