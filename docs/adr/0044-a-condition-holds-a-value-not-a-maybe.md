# A condition holds a value, not a maybe

[ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md) says the
shape of a query is settled while compiling and only its values are not. This
is the one place that rule had a hole in it, and the hole answered wrongly and
in silence.

Two conditions that look the same are two different statements:

```zig
.where = .{ .handle = null }     -- "handle" IS NULL
.where = .{ .handle = "ada" }    -- "handle" = $1
```

`IS NULL` is not `= NULL` with a null in it. `= NULL` is *unknown* in SQL,
never true, so it matches no rows — which `where.zig` already knew, and which
is why a written-out `null` compiles to `IS NULL` and why
`refusals/compared_with_null.zig` refuses `.{ .gt = null }`.

What neither of those covered is the shape a service actually writes:

```zig
const maybe: ?[]const u8 = filterFromTheQueryString(c);
try db.select(User, c, .{ .where = .{ .handle = maybe } });
```

That compiled. It took the parameter path, sent `"handle" = $1` with NULL in
it, and answered nothing — no error, no log line, no wrong row to notice. It
was found while writing a test for something else, by an assertion that
expected 1 and got 0.

The reason it is not merely a bug is that **which of the two statements is
right depends on a value that does not exist yet.** The statement is a
constant before the program runs; the optional answers during it. There is no
moment when both are true.

## What was decided

**An optional in a condition is a Refusal.** By type, not by value: `?T`
where a condition takes a value stops at `zig build`, whether or not the
optional happens to be null at the call site.

```
nilo: the condition on `handle` was given a ?[]const u8.
  Which SQL that is — `= $1` or `IS NULL` — is shape, and shape is settled
  while compiling. An optional only answers at run time, and a null one sends
  `= NULL`, which is never true in SQL: the query runs, matches nothing, and
  says nothing.
  Branch where the two statements differ: `if (maybe) |value| … else …`, with
  `.handle = null` on the null side.
```

The caller writes the branch, which is two statements because it is two
statements:

```zig
if (maybe) |handle|
    try db.select(User, c, .{ .where = .{ .handle = handle } })
else
    try db.select(User, c, .{ .where = .{ .handle = null } });
```

**It is the written value's type that is judged, never the column's.** A
`?[]const u8` column compared against a plain `[]const u8` is an ordinary
condition and stays one — that is what each half of the branch above
produces. The rule bites exactly where the ambiguity is.

**Writes are untouched.** `.set = .{ .handle = maybe }` and
`db.insert(User, c, .{ .handle = maybe })` keep working, because `SET handle
= $1` with NULL in it is not ambiguous at all: it is how a column is set to
NULL, and there is only ever one statement. The Refusal lives in `where.zig`,
which is the file both reads and conditions go through and neither write
does.

## Why not the alternatives

**Read a null optional as `IS NULL`.** The obvious kindness, and it is the
one thing this module must not do: it makes one statement mean two different
things depending on a parameter. Everything ADR 0039 buys is downstream of a
statement being a constant — the comptime column check, the placeholder
count, `EXPLAIN` telling the truth about the query the server actually sends,
the ability to cache a prepared statement by the statement's own identity.
Trading all of that for the shape that saves four lines is not a trade, and
it would be the only place in the module where reading the source does not
tell you what SQL was sent.

**Refuse it at run time instead — return an error when the optional is
null.** A condition that fails on some requests and not others, discovered
by whichever user first leaves a filter blank. The compiler already knows
the type; a check that runs later than it needs to is a worse version of the
same check.

**A separate operator, `.{ .eq_or_null = maybe }`.** Honest about there
being two statements, and it still produces one that means either. It also
adds a word to the condition language for a case a two-line `if` already
covers, and the condition language is small on purpose.

**Leave it and document it.** It was documented — as a known gap, in the
roadmap, for exactly one session. A silent wrong answer is the failure mode
this module spends its whole compile-time budget avoiding, and a paragraph
nobody reads is not a fix. It is the same argument
[ADR 0027](./0027-the-rule-about-error-messages-is-held-by-a-build-step.md)
made about error messages: a rule that is only a paragraph erodes the first
afternoon somebody is in a hurry.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes,
all four are zero: the check is a `@typeInfo` at comptime and there is no run
time to spend. What it costs is a compile that used to succeed —
`sql/db.zig`'s own `touchEverything` had the shape, which is how it was
already proven that the module compiled the mistake happily.

`refusals/optional_in_a_condition.zig` holds the message, and
`where.zig`'s `assertNotOptional` holds the reasoning.
