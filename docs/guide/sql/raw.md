# Past one table

What `nilo_sql` writes for you stops at one table and conditions that filter
rows. This page is the way past it — `raw`, and the three shapes it takes —
and it follows [reading](./reading.md).

Joins, aggregates, subqueries, `HAVING`, window functions, CTEs — none of
them. The line is one sentence, **one table, conditions that filter rows**,
and past it the answer is `raw`:

<!-- compiles: body -->
```zig
const Tally = struct {
    // A view. `raw` never reads the name, but a Row names a relation.
    pub const nilo_table = .{ .name = "country_tally" };

    country: nilo.Str,
    n: i64,
};

const tally = try db.raw(Tally, c,
    "SELECT u.country, count(*)::bigint AS n FROM users u " ++
    "JOIN orders o ON o.user_id = u.id GROUP BY u.country",
    .{},
);
```

`raw` still fills your struct, still uses the arena, still follows the `Str`
rule. It gives up the compile-time column check and nothing else; the
`SELECT` list has to line up with the struct's fields by position.

It is still a **Row**, so it still carries a `nilo_table` — `raw` never reads
the name, because it did not write the statement, but the type is the same one
every other call takes and there is no second kind of struct to learn. A join
that answers with a shape no table has is what a view is for.

## A statement that answers with nothing

`CREATE TABLE`, `CREATE INDEX`, `PRAGMA`, `VACUUM`, `ANALYZE`, a `DELETE` you
wrote by hand — nothing is selected, so there is no struct to fill. That is
`db.exec`, and it answers with the number of rows it changed:

```zig
_ = try db.exec(&run,
    \\CREATE TABLE IF NOT EXISTS accounts (
    \\  id    INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    \\  email TEXT NOT NULL UNIQUE COLLATE NOCASE
    \\)
, .{});
```

**A SQLite application needs this and a Postgres one usually doesn't**: there's
no server to have run the DDL somewhere else, so creating the table is your job
at startup. `tx.exec` is the same call inside a transaction.

The line is drawn there because a builder's dialect surface grows with the
builder, and joins and aggregates are where databases disagree most. A
boundary you can state in a sentence is worth more than one further out,
because you can predict what it does without opening this guide.

## Set operations are conditions, not a second idea

`UNION`, `INTERSECT` and `EXCEPT` combine two selects with the same column
list — and a Row *is* the column list, so over one table all three are
boolean algebra on the `WHERE` clause:

| SQL | here |
|---|---|
| `… WHERE a UNION … WHERE b` | `.where = .{ .any = .{ .{ a }, .{ b } } }` |
| `… WHERE a INTERSECT … WHERE b` | `.where = .{ a, b }` — fields are ANDed |
| `… WHERE a EXCEPT … WHERE b` | `.where = .{ a, not_b }` |

There is no group `NOT`, and none is needed: every leaf has a negation
(`.ne`, `.distinct_from`, `.not_in`, `.not_like`, and the comparisons negate
each other), De Morgan holds in SQL's three-valued logic, and `.any` nests
inside itself. So `NOT (x AND y)` is `.any = .{ .{ not_x }, .{ not_y } }` and
`NOT (x OR y)` is `.{ not_x, not_y }`.

Over **two** tables, a set operation belongs to the schema rather than to the
call site — write a view and put a Row over it, which has worked since views
were readable:

```sql
CREATE VIEW all_orders AS
  SELECT id, total, placed_at FROM current_orders
  UNION ALL
  SELECT id, total, placed_at FROM archived_orders;
```

([ADR 0058](../../adr/0058-a-set-operation-over-one-table-is-a-condition.md).)

## Several statements at once

There is no pipelining, and the reason is measured rather than assumed: **a
round trip to Postgres is 24 µs and the query inside it is about 2**, so
latency is the cost and concurrency is what hides it. A server here serves
**215,000 requests a second with a real query in every one**, because a
waiting fiber frees its thread
([ADR 0059](../../adr/0059-a-round-trip-is-not-the-cost-worth-chasing.md)).

Where several statements really do have to land together, SQL already does it
in one round trip and `db.raw` reaches it:

<!-- compiles: body -->
```zig
const Revoked = struct {
    pub const nilo_table = .{ .name = "audit", .key = .id };

    id: i64,
};

_ = try db.raw(Revoked, c,
    "WITH gone AS (DELETE FROM sessions WHERE user_id = $1 RETURNING id) " ++
    "INSERT INTO audit (kind, ref) SELECT 'session_revoked', id FROM gone " ++
    "RETURNING ref AS id",
    .{user_id},
);
```

Atomic without a transaction, which saves the `BEGIN` and the `COMMIT` too.
Many rows of the same shape is `db.insertMany`, which was always one
statement.
