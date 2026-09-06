# A `Timestamp` is checked against the column it is bound into

`sql.Timestamp` carries `pub const nilo_column = "timestamptz"`, which is a
Postgres type name, and `acceptsSqlite` routed **every** type carrying a
declared column name to `TEXT`, `VARCHAR` or `CLOB`. `WireWrite` answers `i64`
for a `Timestamp` whatever the Dialect is.

So the two halves disagreed, and the disagreement pointed the wrong way:

- `created_at INTEGER` — the column that matches what is actually bound, and
  the one anybody would write — **failed the startup check**, and
  `schema_mismatch_is_fatal` defaults to true, so the server did not start.
- `created_at TEXT` — the column that passed — stores microseconds as **digits
  in a text column**, because TEXT affinity converts an integer on the way in.
  `ORDER BY` then sorts them as text, and no SQLite date function reads them
  as a time.

A check that refuses the correct schema and accepts the one that silently
corrupts the ordering is worse than no check, and this one had been in the
module since the second Dialect landed.

## What it does

One branch in `acceptsSqlite`, above the declared-name one:

```zig
if (Inner == types.Timestamp) return &.{
    "INTEGER", "INT", "BIGINT", "NUMERIC", "DATETIME", "TIMESTAMP",
};
```

Every name in that list keeps an integer an integer. SQLite derives affinity
from the declared type by substring: the three carrying `INT` are INTEGER
affinity, and `NUMERIC`, `DATETIME` and `TIMESTAMP` fall through to NUMERIC,
which stores an integer as an integer. `DATETIME` and `TIMESTAMP` are in the
list because they are what somebody writing the table by hand reaches for, and
they are correct — not as a courtesy.

`TEXT` is now refused, and that is the point of the change rather than a side
effect.

## `Timestamp` is the only row that needed this

The other three types the two databases store differently are all *sent* as
text on SQLite, and each says so with a form declaration the write path reads:
`uuid_form`, `json_form` and `enum_form`
([ADR 0078](0078-a-uuid-is-whatever-the-database-stores.md),
[ADR 0119](0119-the-sqlite-write-path-is-compiled.md)). A user type reached
through `nilo_column`/`nilo_read`/`nilo_write` is text by definition
([ADR 0055](0055-a-column-type-can-come-from-outside-this-module.md)).

`Timestamp` is the one that is not, so it is the one row the table was missing
— which is what the gap said, and it is worth stating that it is now complete
rather than merely longer.

## What was rejected

**A `time_form` beside `uuid_form`.** The shape the roadmap sketched, and the
shape three declarations above it already have. A Dialect would say `.micros`
or `.text`, and SQLite would store RFC 3339 — which is genuinely nicer to read
in a database file, and is what many SQLite schemas hold.

It is not here because of what it costs: reading it back means **parsing** RFC
3339, and `Timestamp` today can only write it. A parser is a new surface with
its own correctness questions — offsets, fractional digits, leap seconds spelled
`:60` — for a column this module already round-trips exactly. And a `time_form`
whose two Dialects both answer `.micros` is a knob with one setting.

The gap was written down as *the check disagrees with the write*, and the
cheapest true fix is to make the check agree. Storing time as text on SQLite is
a separate feature, and if somebody wants it, `sql.AsText("timestamptz")`
already reaches it without this module choosing for them.

**Accepting both INTEGER and TEXT.** It would keep every existing schema
starting, at the price of going on accepting the one that sorts wrongly — which
is the failure this is about.

**Widening `nilo_column` into a per-Dialect name.** A bigger change than the
problem: the declared name is a *Postgres* name and every other consumer of it
is right about that.

## What it costs

Nothing at run time — the list is comptime and the check runs once per Row at
startup. No allocation, no binary growth beyond six string literals.

## Who has to change something

**A program on SQLite whose timestamp column is declared `TEXT` will now be
told so at startup**, and it is being told about a column whose contents were
already wrong for sorting. The fix is `INTEGER`, plus a migration reading the
digits back out — the values in it are microseconds, written as text.

`bench/sql.zig` was one of these: it declared `created_at` as a plain `i64` to
get past the check, with a comment recording the symptom and leaving the cause.
It reads a `sql.Timestamp` on both arms now, so the two `db.find` figures it
publishes compare the same work.
