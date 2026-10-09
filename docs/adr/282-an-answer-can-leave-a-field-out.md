# An answer can leave a field out

**Status:** accepted
**Topic:** [json](../design/json.md)
**Extends:** [ADR 148](./148-a-field-name-is-a-spelling-too.md) (what the marker can say about a field, and that the writer, the reader and the document all read it), [ADR 168](./168-one-field-can-be-spelled-on-its-own.md) (the marker's entries, checked where it is written)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 023](./023-a-failure-mode-belongs-in-the-return-type.md) (the document promises what the types settle), [ADR 278](./278-a-json-answer-is-written-in-one-buffer-and-copied-once.md) (the generated writer a type must stay on)
**Found by:** a downstream port of a Go service, whose answers leave out a key that is null or an empty list (`omitempty`) and whose clients read the difference between a missing key and `null`

## Context

The generated writer writes every field a struct has, an optional that is empty as `null` and a list that is empty as `[]`. A server that must not send a key, because its clients treat a present `null` differently from an absent key or because the key is noise on every row, had one way to say so: a `jsonStringify` on the type, written field by field. A type with its own `jsonStringify` is not `covers`-able, so the whole response left the generated writer for `std.json`, and `std.json` does not read `nilo_json`, so a `rename_all` on the same type turned into a compile error (ADR 148). The cost of leaving one key out was the writer, the renames and the document.

This is Go's `omitempty` and serde's `skip_serializing_if`. Both are per field, and both are a tag or an attribute on the field. Zig has neither: a field has no annotation a library can read (its attributes are alignment and a default), which is why the marker is a declaration on the struct that names its fields as text (`.skip`, `.rename`).

## Decision

**A struct can leave a field out of an answer when it is empty, with two entries in its `nilo_json`.**

```zig
const Page = struct {
    pub const nilo_json = .{ .omit_null = true, .omit_empty = &.{"root_attributes"} };

    id: u32,
    title: ?[]const u8,                 // left out when null
    root_attributes: []const Attribute, // left out when empty
    tags: []const []const u8,           // written, as [] when empty
};
```

- **`.omit_null = true`** leaves out every optional field of the struct that is null. It is type-wide because the case it serves is a rule about the whole shape (every optional is absent when it has no value), and listing every optional would be the long way to say it. `false` is refused: it is what every type does already.
- **`.omit_empty = &.{"name", …}`** names the slice fields left out when they hold nothing. It is a list and not type-wide because an empty list is often a fact (`"items": []` says the search found nothing) where a null is usually the absence of one, and nothing in the type tells the two apart. A text field is a slice, so `""` can be named too.

Both are the marker's, so they read where the marker is read, at compile time, and **the writer, the document and the refusals agree because one function answers for all three** (`jsonmark.omittable`).

**The fast writer applies it, and a type that uses it stays `covers`-able.** The commas are the part that needs care. For a struct with no omission the brace or comma in front of each key is a string settled while compiling (ADR 278). Once a field can go, which field opens the object depends on the value, so a struct with at least one omittable field is written with one `bool` at run time (nothing written yet) that picks the brace or the comma, and an object with nothing written is `{}`. A first, a middle, a last and an every-field omission are tests. In an internally tagged variant the tag is always written first, so every payload field takes a comma and an omission cannot misplace one. A struct with no omission compiles to the loop it always did: the branch is `if (comptime mark.omitsAny(T, m))`.

**The `std.json` fallback does not honour it, and a type that would reach it is refused**, the answer ADR 148 gave for `rename_all` and `skip` and for the same reason: a value `covers` sends to `std.json` (a tuple, an array of bytes, an untagged union, a type with its own `jsonStringify`, anything past eight levels) would send the `null` the document said would be absent, and nothing would fail. `jsonmark.unwritableWithin` is `renamedFieldsWithin` plus the omissions, asked only where an answer is written. A form or a query string is not refused for it, because omitting is only what an answer does.

**The document lists a field that may be absent as not required.** The response schema listed every field as required since commit fe51c44 (the writer sends every field, so a client need not null-check). A field the type may leave out comes off that list; an optional left out under `.omit_null` is still described as `anyOf` string or null, since a hand-built value elsewhere may carry the null.

**It means nothing when a body is read, and says so.** An optional or a list with a default already reads from a body that leaves its key out (`field.zig`: a `?T` or a field with a default may be absent), and `.omit_null` and `.omit_empty` are statements about what is written. The same struct used as a body keeps the rule it had, in the reader and in the request schema's `required`, and is not refused.

**Compile errors, where the marker is written**: `.omit_null` that is not `true`, that is on something other than a struct, or on a struct with no written optional field; `.omit_empty` that is not a list of text, that names a field the struct does not have, a field that is not a slice (an optional is `.omit_null`'s, a number is never empty), a field twice, or a field `.skip` already leaves out. The marker's empty-entry message and its list of what it can say name both.

### Cost, on the four axes

- **Allocations per request**: none added. The omission is a branch on a value already in hand; `test "the request path stays inside its allocation budget"` holds.
- **Memory per idle connection**: none. Nothing is kept.
- **Throughput and p99**: a type that does not use the option compiles to the same writer, because the choice is made while compiling. A type that does pays one `bool` and one comparison per omittable field, which is below the cost of the `null` or `[]` it no longer writes. Not measured as a number (the writer is ADR 278's and this adds no path to it); `bench/release.py` is the place if a module's figures move.
- **Binary size**: the second branch of the struct writer is compiled for a type that uses the option and for no other.

## What was rejected

**Go's per-field tag (`json:"x,omitempty"`).** Zig cannot spell it: a field carries no annotation a library reads, and a marker that wrote one in a string would be parsed at compile time to say what a list of names already says in plain Zig.

**A type-wide `omit_empty`.** It would drop `"items": []` from a response where the empty list is the answer, and a client that distinguishes the two could not be written. It also has no way to say "this list but not that one".

**A list for `omit_null` as well (`.omit_null = &.{"nickname"}`).** It is the uniform shape and was the closest second. A type where one optional is sent as `null` and another is left out is rare, a client of such a type is unusual, and the list costs the common case a line of names that drift when a field is added. A type that needs the split writes the field it keeps as a non-optional or splits the struct.

**Teaching the `std.json` fallback to omit.** `FiniteJson` would have to read the marker, and the fallback is the place nilo does not own the walk (ADR 148). A compile error costs the user a sentence and shows them the shape that is out of reach.

**A runtime option on the answer (`nilo.json(value, .{ .omit_null = true })`).** The document is written from the types and could not know it, which is the reason ADR 168 gave for the type owning `.unknown_fields`.
