# 0077 — a lifetime has no rendering in JSON

**Status:** accepted
**Amends:** [ADR 0017](./0017-the-api-description-comes-from-the-signatures.md)

## Context

Two gaps in the generated document, found by the same application and both
about a shape nilo could describe and did not.

**One shape arrived twice.** The `Str`-in / `Text`-out rule is nilo's own
([ADR 0004](./0004-request-arena-and-the-str-type.md)): a body holds `Str`,
which dies with the request, and a row holds `[]const u8`, which does not. On a
shape more than one level deep that means writing the generic twice —
`Meta(Str)` and `Meta(Text)` — and both landed in `components/schemas` as
`Meta_Str` and `Meta_Text`, **byte-identical**. A generated client got four
types where two would do, and no field of any of them differed, because what
separates the two instantiations is a Zig lifetime and a lifetime has no
rendering in JSON.

**And a `union(enum)` had a derivable shape and got `{}`.** As a body it is a
compile error in nilo's own words, which is right — nothing in the type says
which arm arrived. As a *return type* it compiles and serialises correctly,
`{"link":{"url":"…"}}`, externally tagged, exactly what `std.json` does. The
document said `"schema": {}`. So the wire format was well defined and the
document declined to describe it, which is the one shape `guide/openapi.md`'s
"a type with no JSON shape is `{}`" was not meant to cover.

## Decision

**Two named shapes that differ only by a lifetime are one component.**

The rule is deliberately narrow. It fires when both names are the same stem
under a `_Str` / `_Text` suffix *and* the two schemas render the same all the
way down — every field name, every field's requiredness, every field's type,
recursively. Anything else keeps its own name: `Page_Order` and `Page_User`
share field names and are not the same shape, and nothing in this change can
merge them.

The pair is written under the stem, so a client gets `Meta` rather than one of
`Meta_Str` and `Meta_Text` standing in for both. A `$ref` to either name
resolves to it.

That needed a stronger comparison than the one already there. `sameShape`
compares field names, which is all it has to do — its job is telling two
*different* types that rendered to one name apart. Merging says the two are
interchangeable to a client, which is a claim about every field's type as well,
so `rendersTheSame` walks the whole schema. Both are kept: they answer different
questions and conflating them is how a merge would eventually be wrong.

**A `union(enum)` is a `oneOf` of one-key objects**, which is what `std.json`
writes. An *untagged* union stays `{}` — nothing in the type says which arm is
live, so nothing can — and that is now the only union that gets it.

## What was rejected

**Merging any two schemas that render identically.** This is what the finding
literally asked for and it is too strong: two unrelated types that happen to
have the same field names and types today are one component under this rule, and
they stop being one the day somebody adds a field to one of them — so a client
regenerated after an unrelated change finds a type has split in two. Tying it to
the `_Str`/`_Text` pair means the merge is about the thing that is actually the
same value, which is what makes it stable.

**Naming the merged shape `Meta_Str`** and pointing `Meta_Text` at it. Cheaper,
and it publishes the lifetime — the thing this whole ADR is about there being no
JSON for — as the name a client sees.

**Refusing a `union(enum)` in the return position**, which is the other honest
answer to the second gap. It breaks working programs to fix a document, and the
shape is derivable, so deriving it is strictly better.

## What it costs

Nothing on any of the four axes. Both changes are comptime data and a writer
that runs once in `listen()`; nothing moved onto the request path. `Schema`
gained one variant, `Components` gained one array of slices, and neither exists
at run time in a program that does not call `docs()`.

The document gets *smaller* where the first rule fires — one fewer component per
merged pair — and gains a `oneOf` where the second does.
