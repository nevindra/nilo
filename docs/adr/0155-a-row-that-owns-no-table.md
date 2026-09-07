# A Row that owns no table

`db.raw` is the way past one table: joins, aggregates, `UNION ALL`, window
functions. The Row it fills is therefore often a shape no table has. It was
still made to name one:

```
nilo: activity.rows.Event is not a Row — it has no `nilo_table`.
  Add `pub const nilo_table = .{ .name = "<table>" };` to it, or `= <OtherRow>`
  to read the same table as another Row.
```

Six of one port's twelve Rows were projections: a `UNION ALL` over two tables, a
`GROUP BY` rollup, a search across seven tables, three cards each joining four.
Every one of them named a table it did not represent so that `assertRow` would
pass, with a comment above it saying the name was decoration. **That is a lie in
the source with a note attached**, which is the worst kind — and the note is
only in the source, so nothing else in the program knows.

## What it does now

```zig
const TimelineRow = struct {
    pub const nilo_table = .projection;

    at: sql.Timestamp,
    kind: Str,
};
```

`db.raw` and `tx.raw` fill one. Everything that writes its own SQL refuses it by
name, because everything that writes its own SQL has to put a table after
`FROM`: `select`, `find`, `count`, `insert`, `update`, `delete`, `db.checking`,
and the migration tool.

**One funnel, and it was already there.** `row.ownerOf` is what every question
about a table goes through — `tableOf`, `keyOf`, `qualifiedOf`, and all of
`table.zig` — so the refusal is one branch at the top of it rather than a check
in nine places.

## The refusal gets sharper, not looser

This is the half worth saying out loud, because a new word in a marker usually
means one fewer thing checked. Today, with a projection spelling a table's name
to get past `assertRow`:

```zig
db.checking(&.{TimelineRow})   // compiles, and goes looking for `events.body`
```

It asks a live database for columns of a table the Row was never about, and
answers with a mismatch nobody can act on. With `.projection` that call is a
compile error naming the Row.

## The word

One word, and a near miss is a typo rather than a Row nobody has implemented
yet — so `.view`, `.derived`, `.query` are all refused with the same message
naming the one that exists. That is the same shape `readSpec` already gives a
misspelt `.unique`.

`.projection` rather than `.view`, because a database view *is* a table as far
as every statement here is concerned: `SELECT` from it, `db.checking` it, and
nilo would be right to. What this word means is the opposite — there is no
relation of any kind behind this shape.

## The alternatives that were rejected

**No marker at all: let `db.raw` take any struct.** It is the smallest change
and it gives up the thing the marker buys, which is that a plain struct handed
to `select` is refused by name rather than by a missing field three frames in
(`isRow`'s own comment). It would also make `db.raw` the one call in the module
with no opinion about what it fills.

**A wrapper type — `Projection(T)`.** A second type to declare and unwrap at
every call site, to say something the Row can say about itself in one line. The
markers in this repository are declarations on the caller's own type precisely
so that nothing has to be wrapped (ADR 0039).

**Inferring it from the absence of a table name.** `pub const nilo_table = .{}`
is a marker with a typo in it far more often than it is a projection.

## Consequences

- `row.isProjection` is public; `ownerOf` refuses one; `assertRow` still passes
  it, which is what lets `db.raw` fill it.
- Two refusal files and two rows in `sql_refusals`.
- Six Rows in the port that reported this stop naming a table they are not.
- `db.stream` refuses a projection too, and that is a gap rather than a
  decision: it builds its own `SELECT`, so there is nothing for it to stream
  from. A raw stream would take one, and nothing here rules that out.
