# A list of Str is a parameter too

`docs/reference.md` line 2311 has said this since lists landed:

> a slice: an array column, with no wrapper. `[]const Str` is `text[]`,
> `[]const i32` is `int4[]` […] `[]const u8` is text, so a list of text is
> `[]const Str` or `[]const []const u8`.

As a **column** both spellings work. As a **`db.raw` parameter** only the second
did, and the first stopped inside nilo:

```
sql/db.zig:2642:12: error: expected type '…!?[]const []const u8',
found '?[]const str.Str'
    return value;
           ^~~~~
```

That is a type error naming a line of nilo's, two types, and no call site — the
shape [ADR 0015](./0015-error-messages-are-a-feature.md) exists to prevent. A
reader who followed the reference got told nilo was broken.

## What was actually missing

`forWire` handles a scalar `Str` — added when the guide's own sign-in snippet
turned out not to compile (ADR 0083) — and it handles a list of `Uuid`, added by
[ADR 0145](./0145-a-value-nilo-holds-is-a-value-nilo-converts.md). A list of
`Str` fell between them and reached `return value;` unconverted.

The wire type was never the missing half. `WireList([]const core.Str)` has
answered `[]const []const u8` all along, and a test has asserted it since ADR
0145. Only the conversion was absent.

```zig
if (comptime Item == core.Str or Item == ?core.Str) return strList(To, value, c);
```

**One allocation, for the slice headers, and none for the text.** Each element
is a view onto text somebody else owns, which outlives the statement by the rule
that made it a `Str`. That is what `uuidList` does with sixteen bytes, for the
same reason.

## Why `strList` rather than one shared list converter

`uuidList` and `strList` differ in one line — `&item.bytes` against
`item.view()` — and merging them means a comptime switch inside a function
whose body is that switch. Two twenty-line functions that each say what they do
beat one that says "it depends".

## The alternative that was rejected

**A Refusal naming the spelling instead**, which is the cheaper half of the ask:
tell the caller to write `[]const []const u8`. It would have been the right
answer if the two spellings meant different things. They do not — the reference
says so, the column path already treats them as the same, and refusing one of
them is asking a reader to remember which of two equivalent things a particular
call site takes.

## Consequences

- One branch and one function in `sql/db.zig`, plus a test asserting the
  elements point at the caller's own text rather than at a copy.
- `.in = &.{ a, b }` over `Str` values works for the same reason: it is the
  same funnel.
- Nothing changes for a caller who wrote `[]const []const u8`.
