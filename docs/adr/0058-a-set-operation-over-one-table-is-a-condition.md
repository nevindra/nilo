# A set operation over one table is a condition

`UNION`, `INTERSECT`, `EXCEPT` and common table expressions were the last two
lines under **Reading** in the Drizzle checklist. Neither is built, and neither
is a gap. This is the record of why, because "we did not get to it" and "there
is nothing here to get to" are different answers and only one of them is true.

## Set operations

A set operation combines two `SELECT`s **with the same column list**. A Row
fixes the column list, so there are exactly two cases and they are not close to
each other.

### Both sides are the same Row: it is already a condition

Over one table, all three operations are boolean algebra on the `WHERE` clause,
and the module can already write all of it.

| SQL | nilo |
|---|---|
| `… WHERE a UNION … WHERE b` | `.where = .{ .any = .{ .{ a }, .{ b } } }` |
| `… WHERE a INTERSECT … WHERE b` | `.where = .{ a, b }` — different fields are ANDed |
| `… WHERE a EXCEPT … WHERE b` | `.where = .{ a, not_b }` |

The first two are obvious. The third is the one worth writing down, because
"there is no `NOT`" is the objection and it is wrong:

- **Every leaf has a negation.** `.ne` and `.distinct_from` against `=`,
  `.not_in`, `.not_like`, `.not_ilike`, and the comparisons negate each other.
- **De Morgan holds in SQL's three-valued logic.** `NOT (a OR b)` and
  `NOT a AND NOT b` agree on `NULL` as well as on `TRUE` and `FALSE`, so the
  rewrite is not an approximation.
- **AND is a struct and OR is `.any`, and `.any` nests inside itself.** That
  last one is what makes the rewrite always terminate, and it now has a test
  in `sql/where.zig` rather than being a property nobody checked.

So `NOT (x AND y)` is `.any = .{ .{ not_x }, .{ not_y } }`, `NOT (x OR y)` is
`.{ not_x, not_y }`, and any combination of the two is reached by applying
those twice. **The algebra is closed**, which is the whole claim.

One difference is real and is in nilo's favour: `UNION` deduplicates and
`.any` does not. Over one table with a key, every row appears once anyway, so
the `DISTINCT` is a sort Postgres does not need to do. `UNION ALL` is the
operation that was meant.

### Two different Rows: it is a view, and reading a view already works

The genuine case is an archive table, or a partition read whole:
`current_orders UNION ALL archived_orders`. Postgres has two features for
exactly that, and **a Row may name either of them** as of
[ADR 0056](./0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md):

```sql
CREATE VIEW all_orders AS
  SELECT id, total, placed_at FROM current_orders
  UNION ALL
  SELECT id, total, placed_at FROM archived_orders;
```

```zig
const AllOrders = struct {
    pub const nilo_table = .{ .name = "all_orders", .key = .id };
    id: i64,
    total: sql.Decimal,
    placed_at: sql.Timestamp,
};
```

Every read, the schema check and `db.raw` work against it unchanged. A
partitioned table is the same answer with the planner doing better.

The alternative — an API taking two Rows and a set operator — was rejected on
three counts. It cannot be spelled well in Zig (`union` is a keyword and a
two-Row call does not extend to three). The set operation belongs to the
*schema* rather than to the call site, so writing it at every call site is
where the drift starts. And the database does it better: a view is planned as
one statement, with the conditions pushed into both branches.

## Common table expressions

Four things get called a CTE and they have four different answers.

1. **Readability of a long query.** `db.raw`. This module writes statements
   whose shape it settled while compiling; a query long enough to want naming
   is one it did not write.
2. **An optimizer fence.** `MATERIALIZED` is a hint about how Postgres should
   run a statement, and nothing in this module has an opinion about that.
   `db.raw`.
3. **`WITH RECURSIVE` — a tree or a graph walk.** Irreducible, and the only
   one of the four that no other shape reaches. It is also squarely
   [ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md)'s
   territory: a self-referencing query has a shape that depends on a
   termination condition, and the row it answers with is a Row plus a depth
   column that no struct declared. `db.raw` into a purpose-written struct is
   the answer, and it is a good one.
4. **A data-modifying CTE** — `WITH gone AS (DELETE … RETURNING …) INSERT INTO
   audit SELECT … FROM gone`. This is the "several statements in one round
   trip" line wearing a different hat, and it is answered in
   [ADR 0059](./0059-a-round-trip-is-not-the-cost-worth-chasing.md).

None of the four is a query this module could have written on its own, and
that is the test — not whether the feature is useful.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes:
nothing, on all four. No code was added; one test was.

## Consequences

- `.any` nesting is now a tested property rather than an accident of the
  recursion, because the reachability argument above depends on it.
- A user asking for `UNION` gets pointed at `.any` or at a view, and both
  answers are in the guide.
- If a second Dialect ever arrives that cannot express one of the leaf
  negations, the algebra stops being closed and this ADR is the thing that
  has to change.
