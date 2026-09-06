# A `SELECT` list shorter than the Row is refused

`db.raw` is the way past *one table, conditions that filter rows*
([ADR 0039](0039-the-shape-of-a-query-is-settled-while-compiling.md)): a join,
an aggregate, a window function. It keeps the arena, the `Str` rule and the row
filling, and **the one thing it gives up is the compile-time column check**.
That is what its doc says and it is the honest trade.

It was giving up something else nobody wrote down. `fill` walks the Row's
fields and asks the Wire for column `i` of each; pg.zig's `Row.get` is

```zig
const value = self.values[col];
```

with no bound on `col`. So a `SELECT` list shorter than the Row — a column
dropped from a hand-written join, a `RETURNING` that lost a field — is an
out-of-range index rather than an error: **a panic in ReleaseSafe, which takes
the whole process down for one request, and undefined in ReleaseFast.**

That is the failure [ADR 0008](0008-no-recover-middleware.md) says nilo cannot
recover from, reached from an ordinary typo in a query. This module already
refuses two others of exactly that kind — `enumOf` for a tag the Zig enum
lacks, and `arrayFits` for an array shape pg.zig asserts on — and the argument
is the same one.

## What it does

The Wire owes one more answer, `width(rows)`, and `fill` compares it against
`columnsOf(Row).len` before reading a column. Short is a `QueryFailed` with a
warning naming both numbers and the Row.

```
nilo_sql: a statement answered with 2 column(s), and shop.Person reads 4 by
position. A `SELECT` list has to name at least the Row's columns, in the Row's
order.
```

## A wider list is not refused

Only *shorter* is a refusal. `SELECT *` into a narrow Row is an ordinary thing
to write, the first N columns are exactly what it means, and nothing about it
is out of range. Refusing it would break working programs to enforce a
tidiness nobody asked for.

What this does not catch is a list of the right length in the wrong order.
Nothing can: the types would have to disagree for the driver to notice, and
when they do, the driver already says so. `db.raw` gives up the compile-time
check, and this restores the half that was a crash rather than the half that
was a mistake.

## Asked on the first row, because the two drivers disagree about when

The first draft asked before pulling any row, which is where a check belongs
and which works on Postgres: pg.zig has `number_of_columns` out of the
`RowDescription` before the first `next`.

It made eight SQLite tests fail. zqlite's `Stmt.columnCount` is
`sqlite3_data_count`, which answers **0 until the statement has been stepped
onto a row** — so every generated `INSERT … RETURNING` was refused against a
result set that had not started yet. `sqlite3_column_count` is the one settled
by preparing, and zqlite does not expose it.

Asking after the first `next` is the one moment both drivers can answer, and it
costs nothing to be there: **a result set with no rows in it has no column for
anybody to read past.** The first row is pulled out of the loop so the question
is asked once per statement rather than once per row.

This is the second time a number was taken from a driver without checking what
the driver meant by it, and the first — `connect_on_init`
([ADR 0062](0062-a-pool-that-dialled-itself-whatever-it-was-told.md)) — was
found by re-measuring rather than by reading. This one was found by the suite,
in one run, because both Wires are compiled by `zig build test-sql`
([ADR 0119](0119-the-sqlite-write-path-is-compiled.md)).

## What it costs

**One `usize` compare per statement**, against a comptime constant, plus one
call into the Wire — a field read on Postgres and a `sqlite3_data_count` on
SQLite. Nothing allocated, nothing per row, nothing per connection.

**The loop is one shape rather than two.** Pulling the first row out of the
`while` is what keeps the check off the per-row path; the rows after it run the
code they always ran.

**Binary**: a warning string and a compare, in a module a program that does not
import `nilo_sql` never links at all.

## What was rejected

**Refusing at compile time.** There is nothing to read: `db.raw`'s text arrives
at run time, which is the whole reason it exists.

**Binding `sqlite3_column_count` ourselves.** It would answer before the first
row and make the check uniform. It also means reaching past zqlite into the C
API for a number the caller can have by pulling the row it was going to pull
anyway. `postgres.zig` reaches past pg.zig twice and both are documented as
costs; this one buys nothing.

**Refusing a wider list.** Above.

**Checking inside `readColumn`.** One compare per column per row instead of one
per statement, to catch the same mistake later.
