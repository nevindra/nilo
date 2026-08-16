# A view is a table that cannot say what is not null

The schema check read `information_schema.columns`, which was the obvious
source and wrong in three separate ways. None of the three had a test, because
every fixture in the suite was an ordinary table owned by the role running it.

- **A materialized view is not in `information_schema.columns` at all.** It is
  not in the SQL standard, so the standard's catalog does not describe it. A
  Row over one was reported as *no such table* — and with
  `schema_mismatch_is_fatal` at its default, that is a server refusing to start
  over a relation sitting right there.
- **`information_schema` shows only the columns the current role holds a
  privilege on.** A deployment that grants `SELECT` on some columns and not
  others gets *no such column* for the rest: a check failing on a correct
  schema, which is the fastest way to teach somebody to switch the check off.
- **A view's columns are all nullable, whatever their source columns were.**
  Postgres does not track `NOT NULL` through a view and never has. So a Row
  over a view reported one `unexpected_null` per non-optional field, which is
  every field anybody would write.

The third is the interesting one, because the check was *reading the answer
correctly*. The database said nullable. It was the question that was wrong.

## What was decided

**`pg_catalog` instead of `information_schema`, and nullability gets a third
answer.**

```sql
SELECT a.attname,
       t.typname,
       CASE WHEN c.relkind IN ('v', 'm') THEN 'UNKNOWN'
            WHEN a.attnotnull THEN 'NO'
            ELSE 'YES' END
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
WHERE n.nspname = COALESCE($1, current_schema())
  AND c.relname = $2
  AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
  AND a.attnum > 0
  AND NOT a.attisdropped
ORDER BY a.attnum
```

`wire.Column.nullable` is now `?bool`, and `null` means *the database does not
know*. The check skips it: the **type** is still compared, because a view does
know that, and only the nullability is left alone.

Three answers rather than two is the honest shape. `true` would flag correct
code; `false` would claim something nobody checked. There is no bool that means
"unknown", and encoding one as a default is how a check ends up lying.

The five relation kinds accepted are an ordinary table, a partitioned table, a
view, a materialized view and a foreign table. An index and a sequence are
relations too and are not things a Row reads.

## Why leaving `information_schema` is safe

It is the portable catalog, and this query lives in the **Postgres Dialect**,
which is the one place portability is not a property to protect — a second
Dialect writes its own `introspect` and always was going to. The seam was fitted
for exactly this ([ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md)).

One behaviour changed that nothing in the suite covers: a **domain** type now
reports the domain's own name where `udt_name` reported the base type's. That
is arguably more correct and is certainly different; it is written here rather
than discovered by whoever first uses one.

## Sequences, identity columns and generated columns already worked

The checklist had these as a third item and they turned out to need no code at
all, which is worth recording because the reason is a design that was made for
something else.

```zig
const Auto = struct {
    pub const nilo_table = .{ .name = "auto", .key = .id };

    id: i64,               // GENERATED ALWAYS AS IDENTITY
    label: []const u8,
    slug: ?[]const u8,     // GENERATED ALWAYS AS (label || '-x') STORED
};

const made = try db.insert(Auto, c, .{ .label = "alpha" });
// made.id is the database's; made.slug is "alpha-x"
```

**An insert names a subset of the Row's columns and `RETURNING` is not
optional** ([ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md)),
and those two together are the whole of what an identity key or a generated
column needs. A batch works the same way: the arrays hold only the columns that
were written.

One thing is worth knowing rather than guessing: a generated column carries no
`NOT NULL` unless one was written, so the Row reads it as an optional and the
check agrees. Live tests hold both halves.

## Indexes, constraints and foreign keys are refused, not deferred

This is a decision rather than a gap, and the reason is one sentence: **a Row
names its columns and its key, and nothing else about the table is sayable.**

- The check cannot notice a *missing* index, because a Row never said there
  should be one.
- Nothing could generate one, for the same reason.
- Adding a way to say it — `pub const nilo_indexes = …` — is annotation, and
  the first line of this project's README is that nothing is annotated
  anywhere. A Row is a struct that happens to be a table; a Row carrying a
  DDL description is a migration file with Zig syntax.

The place that work belongs is a migration tool, which is a CLI rather than a
server and is undecided for three reasons that have nothing to do with Zig
(`docs/roadmap.md`). Until then, indexes and constraints are written where
every other DDL statement is written, and a unique constraint violated is
already `error.AlreadyExists` with a 409 by default — the half that reaches a
handler is done.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes:

- **Allocations per request.** None. The introspection runs once per Row at
  startup, in a scratch arena, and never again.
- **Memory per idle connection.** Nothing.
- **Throughput and p99.** Nothing on the request path. The startup query is
  cheaper than the one it replaces — `information_schema.columns` is a view
  over several catalog joins with privilege filtering on top.
- **Binary size.** +0 stripped ReleaseFast on every example.

## Consequences

- A Row over a view is checked for its column types and not for nullability,
  and that is stated in the reference rather than left to be discovered.
- A driver now has three things to say about a column instead of two. The Fake
  says all three.
- The next relation kind Postgres adds is a one-character change to a `WHERE`
  clause rather than a second query.
