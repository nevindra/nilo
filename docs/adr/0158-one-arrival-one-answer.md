# One arrival, one answer

`/deals/:id` reads a `sql.Uuid`. `?actor=<uuid>` refused one:

```
error: nilo: the field `actor: ?Uuid` of the `Query(FeedQuery)` on route
"/api/activity" is not something a query value can become.
  A query param arrives as text, so a field is a `nilo.Str`, a number, a `bool`,
  or an enum — optionally wrapped in `?` when it may be absent.
```

Both values are text off the same request line, of the same type, converted by
the same function.

## The gap was where a mechanism stopped

`convert.zig` said so in its own comment, and the sentence was true:

> A type that parses itself is deliberately not on this list, and the gap is
> where it stops rather than what it is: `nilo_parse` makes a type a path param
> (ADR 0142), and a path param does not come through here.

That is an accurate account of *how* the code was arranged and not an argument
about what a query parameter is. `tryConvert` — the function `convertible`
promises about — has handled the case since ADR 0142, ahead of its own switch:

```zig
if (comptime parsesItself(P)) {
    out.* = P.nilo_parse(text) orelse return .not_that_type;
    return null;
}
```

So the work existed and `convertible` was one clause short of reaching it. The
same is true of `reasonFor` and `sayWhy`, which already word the failure with
the type's own name.

**This is the second time a requirement written as a mechanism read as a
blocker** ([ADR 0063](./0063-a-handlers-stack-is-per-connection.md) is the
account of the first). "Where `nilo_parse` stops" is a sentence about a call
graph. "One arrival cannot mean two things" is a sentence about the feature, and
only the second one is checkable against what the caller sees.

## What it does now

```zig
if (parsesItself(Inner)) return true;
```

A `Query(T)` field and a `Form(T)` field may be any type that parses itself,
which is the same set a path param takes. Their refusal messages gained the case.

The scale that made it worth doing rather than noting: the port that reported it
has 145 `uuid` columns and a `?owner=`-style filter on most list endpoints —
about forty of its 267 operations, each carrying a `uuidOf` helper and answering
422 where a path parameter of the same type answers 400.

## What is deliberately unchanged

**The JSON body.** The old comment raised it as the risk and answered it in the
same breath: `std.json` fills a body, not this file. A body field of such a type
is `std.json`'s question — `jsonParse` — and this decision does not touch it.

## The alternative that was rejected

**Sniffing for any type with a `parse` method.** `parse_marker`'s own comment
argues this and the argument stands: it would promote somebody's existing struct
into a query field without asking, and change what a program that already
compiles means. The declaration is written on purpose, and this widens where a
written one is honoured rather than widening what counts as one.

## Consequences

- One clause in `convertible`, two message strings, and two assertions in
  `convert.zig`'s existing test. The conversion path itself is untouched.
- `sql.Timestamp` becomes usable as a query field the moment it declares
  `nilo_parse`, which is [ADR 0159](./0159-what-a-server-prints-it-can-read.md).
- `bound.canFail` now answers true for such a field, so a `Bound(Query(T))`
  reports "did not fit" where it used to report nothing. That is the same
  sentence the slot already gave every other convertible field.
