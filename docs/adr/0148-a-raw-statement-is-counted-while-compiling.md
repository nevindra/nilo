# A raw statement is counted while compiling

`db.raw` was the one call in the module the compiler did not check. It fills
the Row **by position**, gives up the column check, and was never prepared.
Everything else here is settled while compiling and checked again against the
database at boot.

```zig
pub fn raw(
    self: *Self,
    comptime Row: type,
    c: anytype,
    sql: []const u8,        // not comptime
    values: anytype,
) ![]Row
```

The reason on file was
[ADR 0057](0057-a-statement-that-is-a-constant-can-be-prepared-once.md)'s: its
text arrives at run time, so there is no bound on how many plan names there
would be.

That is true of the general case and false of every call site anybody has.
A caller with 398 named queries had 156 of them on `db.raw`, and **all 156 are
Zig string literals**. So is every one in this repository — the tests, the live
tests, the benches and the two marked snippets in the guide. The escape hatch
for text assembled at run time was carrying a feature nobody used, and charging
every literal call site for it.

## What changes

`sql` is `comptime`. Three things follow.

**It is prepared.** `planName(sql)` applies, which is the same 12 µs a query
every other statement in the module already gets — 24% at one request in
flight and 67% at a pool under load, because a pool connection is a serial
queue ([`bench/result/sql.md`](../../bench/result/sql.md)). On the caller
above that is 156 statements that were paying Parse and Describe every time.

**The columns are counted.** `sql/rawcheck.zig` walks the `SELECT` list at
bracket depth zero, outside quotes and comments, and compares the count to the
Row's field count. A mismatch is a compile error naming both.

**Each column that plainly has a name is checked against the field in its
position.** This is the half that matters most, and it is worth being exact
about why: a schema with 145 `uuid` columns and 106 `timestamptz` columns has
two swapped columns of the same type decode cleanly and answer wrong. There is
no run-time symptom at all.

## Why it refuses rather than reorders

The obvious move is to bind by name: read the trailing alias, match it to the
field, and fill in whatever order the `SELECT` list happens to be in. It was
rejected.

Reordering silently repairs a statement that is wrong, and the reader never
learns that their `SELECT` list and their struct disagree. Refusing puts the
disagreement in front of them, in the file they can fix, and costs no run-time
machinery at all — no permutation array, no second index per column. The
message names the column and the field:

```
nilo: column 2 of the statement handed to `db.raw` is named `email`,
and field 2 of partner.Person is `age`.
  A raw statement fills the Row by position, so the second column becomes
  the second field. Reorder the SELECT list, or alias the column:
  `… AS "age"`.
```

## What is not checked, and what that leaves

**Types.** A comptime pass has no schema, so `SELECT id, email` into
`struct { id: i64, email: Str }` is checked for shape and not for whether
`email` is really `text`. That half belongs to `db.checking`, which asks the
database, and extending it to raw statements is the other option the caller
proposed. It is not closed here and it is not blocked by this: they close
different halves and neither makes the other harder.

**Anything that cannot be counted.** A `*` in the list is uncountable by
definition, and a statement with no `SELECT` and no `RETURNING` — `SHOW
transaction_read_only` — has no list at all. Both answer "not counted" rather
than guessing, and nothing is refused on their account.

**A column with no name this file will claim.** `pg_sleep(10) IS NULL` ends in
the word `NULL`, and reading the last word of an expression as a column name
would turn working statements into compile errors. A name is taken from an
explicit `AS`, or from a column that is an identifier path and nothing else.
Everything else is nameless and only counted.

## The break

**This is a breaking change.** A program that builds SQL text at run time
cannot call `db.raw` any more, and there is no replacement. That was the
deliberate choice: a second call with the old signature would have left the
unchecked path exactly where it was, with a name suggesting it is the one to
reach for less often, and the guide would have gained a paragraph explaining
which of two nearly identical calls to use.

What a caller who assembled text at run time does instead is assemble it at
comptime — a `switch` over an enum of the orderings the application actually
supports, which is a shape that also stops the injection nobody meant to
allow. That is more code at the call site and it is code that says what the
finite set of statements is.

## Four things in this repository did have to change

The first draft of this ADR said nothing here had to. Turning the check on
refused four of its own call sites, and three of the four are worth reporting
rather than tidying away.

**`touchEverything` selected one column into a four-field Row, twice.**
`db.raw(Person, c, "SELECT 1", .{})` existed to make the call compile, not to
mean anything. Both are now written out. That is the check doing exactly its
job on the first statement it ever saw.

**Two run-time tests for [ADR 0134](0134-a-select-list-shorter-than-the-row-is-refused.md)
were written as a short literal list**, which no longer compiles. They are
`SELECT *` now, with the Fake still answering two columns for a four-field
Row. That is not a weaker test and is arguably the right one: `*` is the shape
the run-time check exists for, because how many columns it stands for is the
database's answer and no comptime pass can have it. **The two checks do not
overlap** — one catches a list you wrote, the other a list the database chose.

**And one test asserted the behaviour this ADR reverses**, that `db.raw` sends
no plan name. It now asserts the name, and a second test was added beside it
for `.prepared = false`, because the escape hatch for a pgbouncer in
transaction mode has to cover the call that only just started being prepared.
Missing that would hand somebody a "prepared statement does not exist" out of
the one call the option looked like it did not apply to.

## Consequences

- `sql/rawcheck.zig`, 18 tests, all comptime.
- `db.raw` and `tx.raw` take `comptime sql`, and both are kept prepared —
  `rawPlanOf` beside `planOf`, honouring `Opts.prepared` the same way.
- Two refusals, `raw_select_list_short` and
  `raw_column_in_another_fields_place`, and two rows in `sql_refusals`.
- No run-time cost anywhere. The scanner runs while compiling, and what it
  adds to a build is one pass over each raw statement's text.
- One more thing the compiler holds, which is the whole claim of the module
  and was true of every call but this one.
