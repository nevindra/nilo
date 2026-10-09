# JSON

**How a type is spelled on the wire is set by a marker on the type itself, and the JSON writer, the JSON reader and the API document all read that same marker, so they can never disagree about a field.**

**Guide:** [JSON shapes of your own](../guide/responses.md#json-field-names-and-union-tags) · **Reference:** [JSON shapes](../reference/handlers.md#json-shapes)

The code is `http/json.zig` (`write`, `covers`, `isByteSlice`, `writesItsOwnScalar`), `http/jsonmark.zig` (`Mark`, `checkTag`, `checkRenames`, `wire`, `wireNames`, `documentOf`, `parseFor`) and `http/openapi.zig` (`schemaWithin`, `toldOf`).

## Overview

```
              nilo_json (.tag, .rename_all, .rename, .unknown_fields, .misfit)
                         |
        Mark.of(T) ── checkTag, checkRenames ── comptime refusal
                         |
     write(value) ───────┼─────────── schemaWithin(T) (the document)
     covers(T)?           \
      /        \           `-- jsonmark.wire(name, mark): one answer,
  generated    std.json         read by both the writer and the schema
   writer       (fallback,
                 a leaf's
                 own value)

  a body field reads back through jsonParseFor(@This()),
  which hands the token to nilo_parse and refuses if there is none
```

nilo writes a struct with its own generated writer (the struct is "covered") unless something stops the walk: a shape `covers` does not recognise, nesting deeper than eight levels, or a type that writes its own JSON without saying anything about it (a "wall"). A wall's whole value is handed to `std.json`, which does not read `nilo_json`, so a marked struct that would end up inside a wall is rejected. A type that writes its own JSON and declares, with `nilo_openapi`, that it is a single scalar is a "leaf" instead: `std.json.Stringify.value` writes only that value, and the generated writer keeps writing the object around it. A type that declares it is a document of another type (`nilo_json_of`) is written and described as that type, using the generated writer when the inner type is covered.

## Rules

1. **A struct's fields, an enum's values and a union's variants can be renamed for the wire**, with `.rename_all` (a naming case for all of them) or `.rename` (one name at a time, which takes priority over the case). [ADR 148](../adr/148-a-field-name-is-a-spelling-too.md), [ADR 168](../adr/168-one-field-can-be-spelled-on-its-own.md)
2. **`.lowercase` and `.UPPERCASE` join words and drop the underscore; the other four cases keep it.** There is no `.snake_case`, because a Zig name is already snake case; asking for it is a compile error, not a silent no-op. [ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)
3. **Two names that would end up as the same wire key are rejected**, and the error names both and which cases would keep them apart. `checkRenames` checks an enum's values and a union's variants; when the marker has `.rename`, it checks every field the whole marker produces. [ADR 072](../adr/072-two-renamed-names-that-collide-are-refused.md), [ADR 168](../adr/168-one-field-can-be-spelled-on-its-own.md)
4. **A rename only applies when writing.** `std.json` parses a request body and reads the fields by their Zig names, so a renamed struct used as a body, a form or a query string is a compile error naming the route. This is checked eight levels deep, like `covers`. [ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)
5. **A type that writes its own JSON without declaring anything is a wall**: its whole value goes to `std.json`. A marked struct nested inside one is rejected, instead of silently losing its renames. [ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)
6. **A type that writes its own JSON and declares a scalar with `nilo_openapi` is a leaf.** `sql.Uuid`, `sql.Timestamp`, `sql.AsText` and `id.Uuid` are all leaves, so a Row holding one can still rename its other fields, and it is faster too (measured 250 ns down to 165 ns on a row with three uuids). [ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)
7. **A type that declares it is a document of another type (`nilo_json_of`) and has a `value` field of that type is written and described as that type**, using the generated writer instead of handing the whole value to `std.json`. `sql.Json(T)` is the first such type. [ADR 163](../adr/163-a-document-is-its-value.md)
8. **A byte slice or `Str` that is not valid UTF-8 is written as an array of byte values**, the same as `std.json` does with those bytes. The document still describes the field as a string, because the type is text even when one value is not. [ADR 096](../adr/096-a-byte-that-is-not-text-is-not-a-string.md)
    A float that is not finite (infinity, NaN) is written as `null`, never as `inf` or `"nan"`, which `std.json` would write, on the generated writer and on the fallback alike (a type with its own `jsonStringify` that names `*std.json.Stringify` is the exception, and the author's). [ADR 096](../adr/096-a-byte-that-is-not-text-is-not-a-string.md) **A float is spelled the way serde_json 1.0.150 spells it, not the way `std.json` does**, on the generated writer and on every fallback alike, `nilo.writeJson` and `nilo.jsonAlloc` included: the shortest digits that read back as the same bits, a decimal exponent from -5 to 15 positional with an integral value keeping `.0` (`0.0`, `1.0`, `1000000000000000.0`), anything outside scientific with an explicit sign (`1e+16`, `1e-7`, `5e-324`), an `f32` from its own digits (`1.1`) with the range -6 to 12. The output is bounded at 24 bytes an `f64`, where `std.json` writes `f64::MAX` as 309 digits. Reading is unchanged: a body `1` still fills an `f64`. [ADR 096](../adr/096-a-byte-that-is-not-text-is-not-a-string.md)
9. **One function, `json.isByteSlice`, decides what counts as a byte slice.** The writer, `typed.contentTypeFor` and `openapi.schemaWithin` all use it, so a `[:0]const u8` is never a string to one and a list to another. [ADR 081](../adr/081-one-file-decides-what-counts-as-text.md)
10. **The walk that works out a type's shape stops at eight levels on both sides**: `coversWithin` for the writer and `schemaWithin` for the document, so they never disagree about what is too deep. [ADR 081](../adr/081-one-file-decides-what-counts-as-text.md)
11. **A body field is read back the same way it is written.** A type with `nilo_parse` adds `pub const jsonParse = nilo.jsonParseFor(@This());` and is read from the single string or number token `nilo_parse` already accepts. A body containing such a type without a reader is rejected, naming the route. [ADR 166](../adr/166-a-body-field-that-parses-itself.md)
12. **A type can describe what input it expects with `nilo_expects`**, and every place a value can arrive (path, query, form, body) uses it; see [request-input](request-input.md) for the wider conversion rules this is part of. [ADR 166](../adr/166-a-body-field-that-parses-itself.md)
13. **A struct can skip the keys a body has that it has no field for**, with `.unknown_fields = .ignore`. It is per type, so a strict parent still refuses its own keys and a tolerant one still has its strict child refuse; on a union it goes on the variant's payload. A skipped value is held to 64 levels, a repeated known key is still a 400, the document says `additionalProperties: true` for it and nothing for any other struct, and a payload under an externally tagged union stays strict because `std.json` reads it. [ADR 168](../adr/168-one-field-can-be-spelled-on-its-own.md)
14. **A body type can answer JSON of the wrong shape with a 422**, with `.misfit = 422`. Text that is not JSON, an empty body and one nested past 64 levels stay a 400; everything said after the body has been read as JSON (a missing field, a wrong kind, an unknown or repeated key, a body that is not an object) keeps its sentence and takes the 422, under `Bound(T)` too. It is the body type's alone, 422 is the only value, and the document lists the 422 beside the 400. [ADR 251](../adr/251-json-that-does-not-fit-can-be-a-422.md)

## Decisions

| ADR | What it decides |
|---|---|
| [072](../adr/072-two-renamed-names-that-collide-are-refused.md) | An enum's values or a union's variants that collide under `rename_all` are rejected, naming both |
| [081](../adr/081-one-file-decides-what-counts-as-text.md) | `json.isByteSlice` is the only answer to "is this text", and the depth limit is shared |
| [096](../adr/096-a-byte-that-is-not-text-is-not-a-string.md) | A byte slice that is not valid UTF-8 is written as an array of byte values, like `std.json`; a float is `null` when not finite and is spelled the way serde_json spells it |
| [148](../adr/148-a-field-name-is-a-spelling-too.md) | `rename_all` on a struct's fields, the wall and leaf split, and the rejection on the read side |
| [163](../adr/163-a-document-is-its-value.md) | `nilo_json_of`: a type that names a document is written and described as that document |
| [166](../adr/166-a-body-field-that-parses-itself.md) | A body field is read through `jsonParseFor`, backed by `nilo_parse`; `nilo_expects` |
| [168](../adr/168-one-field-can-be-spelled-on-its-own.md) | `.rename`: one field named on its own, alongside `.rename_all`; `.unknown_fields = .ignore` |
| [251](../adr/251-json-that-does-not-fit-can-be-a-422.md) | `.misfit = 422`: a body type answers JSON of the wrong shape with a 422, and text that is not JSON stays a 400 |
| [278](../adr/278-a-json-answer-is-written-in-one-buffer-and-copied-once.md) | An answer is written into a buffer the thread keeps and copied into the arena once; a scalar field is one reservation |

Related topics: the tagged-union encoding and the API document built from the same markers are [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md); the wider conversion rules, including `nilo_parse` and `nilo_expects` outside a JSON body, are [request-input](request-input.md); the response wrappers a JSON value is sent through (`?T`, `Status`, `Response`) and types that write something other than JSON are [responses](responses.md).

## Open questions

- **`std.json` is not consistent about invalid UTF-8.** A byte slice that is not UTF-8 is written as an array of byte values, matching `std.json`, but `std.json` itself only does that in `writeString`; `writeAll` always writes a string. That mismatch predates this rule and is carried over rather than fixed; it is noted as its own gap in [ADR 081](../adr/081-one-file-decides-what-counts-as-text.md).
- **`std.unicode.utf8ValidateSlice` is much slower on non-ASCII text** (up to 19 times a short ASCII payload at one kilobyte), and nobody has needed a vectorised validator yet. Recorded in [ADR 096](../adr/096-a-byte-that-is-not-text-is-not-a-string.md) as a roadmap entry with a number behind it.
