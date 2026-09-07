# A raw statement cannot cast what it did not write

A port reading a `date` column through `db.raw` got this out of a test asserting
the real value:

```
====== expected this output: =========
2026-10-01
======== instead found this: =========
  &*
```

Nothing errored. `2026-10-01` is day 9770 since 2000-01-01, which Postgres sends
as the four bytes `0x00 0x00 0x26 0x2A`, and those four bytes were kept in the
arena as if they were text. The afternoon before finding it was spent suspecting
pg.zig.

## Why it happened

A **text column** — `Decimal`, `Interval`, `Inet`, and anything a project
declares with `AsText` ([ADR 0055](./0055-a-column-that-travels-as-text.md)) — is
read as the text the database printed. That is true because the Dialect puts the
cast in the `SELECT` list:

```zig
pub fn readAs(comptime quoted: []const u8, comptime T: type) []const u8 {
    return if (comptime types.asText(T) != null) quoted ++ "::text" else quoted;
}
```

`WireRead` says so in its own comment, and the comment is right about every
statement nilo writes. `db.raw` is the one where the caller writes the list, and
there nothing adds the cast. The driver hands over whatever wire format it chose
and `nilo_read` dupes those bytes.

**This is the only silent wrong answer in the module.** Every other mistake
`db.raw` can carry is a compile error or a `QueryFailed`. `Decimal` is
`AsText("numeric")`, so it is money as much as it is dates.

## What it does now

`rawcheck.zig` already reads the `SELECT` list while compiling, for the column
count and the column names of
[ADR 0148](./0148-a-raw-statement-is-counted-while-compiling.md). It now also
reads what each column *is*, and refuses two shapes:

- **a bare column** — `total`, `i.total`, `"total due"`, with or without an
  `AS` alias — where the Row's field is a text column;
- **a `*`**, where the Row has a text column anywhere in it.

Both are shapes that cannot have a cast in them. The message names the column,
the field, and what to write instead, taking the spelling from the Dialect
itself so the suggestion and the SQL nilo writes cannot drift:

```
nilo: column 2 of the statement handed to `db.raw` is `total`, and field 2 of
Invoice is a `numeric` column read as text.
  A text column arrives as the text the database printed. nilo adds that cast to
  every statement it writes; this one it did not write, so `total` comes back in
  the wire format and is kept as if it were digits — a `date` becomes four
  characters and nothing fails. Ask for it as `total::text AS "total"`.
```

## What is deliberately not refused

**Any expression at all.** `total::text`, `coalesce(total::text, '0')`,
`to_char(at, 'YYYY-MM-DD')`, a literal — all pass unexamined. Deciding whether
an expression ends in a cast means parsing SQL, and `rawcheck.zig`'s own header
states the rule it cannot break: *refusing a statement that works is the one
outcome this file must not have*. A bare column and a `*` are the two cases
where no reading of SQL is required to be certain.

The blind spot that leaves is a wrong cast — `total::int` filling a `Decimal`.
That is `db.checking`'s half, and ADR 0148 already argues why closing one half
is worth doing without the other.

## The alternatives that were rejected

**A sentence in the reference instead.** It was the fallback the report itself
offered, and it is what the repository has been wrong with before: the rule is
invisible from the call site, the failure looks like a driver bug, and a
paragraph nobody runs is the thing that rots (`CLAUDE.md` says so about itself).
The reference gained the sentence as well, but it is not the mechanism.

**Refusing on Postgres only.** On SQLite the cast is a no-op — a `Decimal`
column there is TEXT holding digits — so a bare column genuinely works. Refusing
uniformly costs a SQLite-only caller one `CAST(… AS TEXT)` that does nothing,
and buys the property that a raw statement written against one Wire compiles
against the other. A refusal that fires on one dialect and not the other is a
program that compiles in the test suite and fails in production, which is worse
than a no-op cast.

**Adding the cast for the caller.** nilo would have to rewrite somebody else's
SQL, which is the whole thing `db.raw` exists not to do.

## Consequences

- Two refusal files and two rows in `sql_refusals`. The 59 there become 61.
- `rawcheck.scan` gained `exprs` and `starred`; `assertList` gained the Dialect
  as its first argument, so the suggestion it prints comes from `readAs`.
- No run-time cost anywhere: every byte of this is comptime.
- A statement that was silently wrong now fails to compile. That is a break for
  anybody who had one, and the break is the point — the alternative is the four
  characters.
