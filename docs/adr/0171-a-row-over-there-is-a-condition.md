# A row over there is a condition

The line this module holds is *one table, conditions that filter rows*
([ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md)), and
past it the answer is `db.raw`. Joins, aggregates, `GROUP BY` and subqueries
were one line in the roadmap under **Not decided**, all four together, because
they were all downstream of the same question.

They are not all the same question. `EXISTS` belongs on this side of the line
and the other three do not, and the difference is stateable rather than a
matter of taste.

## Why an EXISTS is a condition and a join is not

Two properties decide it, and they are the two the line was drawn to protect.

**The column list does not change.** The answer is still rows of this Row. A
join changes the column list, and then the Row stops describing the answer —
which is exactly the argument
[ADR 0058](./0058-a-set-operation-over-one-table-is-a-condition.md) made about
a set operation: *a Row fixes the column list.*

**The row count does not change.** `EXISTS` is a yes or no per row of this
table. A join to a one-to-many multiplies the rows on this side, and then
`.limit = 20` no longer means twenty of the thing the caller is listing. That
one is worse than it sounds: the query still runs, the page still renders, and
the pagination is wrong in a way that shows up as *some rows never appear*.

A third thing is not a reason but is worth writing down, because the roadmap
gave it as the objection: **the two Dialects agree here.** The roadmap's line
was *a join is where dialects disagree most*, and it is true and it is about
joins. `EXISTS (SELECT 1 FROM … WHERE …)` is the same eight words in Postgres
and SQLite, and the test that says so is in `statement.zig`.

So the line moved to where those two properties actually hold, rather than
blurring. Joins, aggregates and `GROUP BY` are still refused, and now for a
reason that is written down instead of shared with something that did not
belong in the group.

## The shape

```zig
db.select(Partner, c, .{ .where = .{
    .name = .{ .icontains = search },
    .exists = .{
        .{ .in = PartnerCapability, .where = .{ .capability = cap } },
    },
} });
```

**A list rather than a single test, and it is not for symmetry with `.any`.** A
struct cannot carry the same field twice, so a bare test could never become two
— and a filter page narrowing on two capabilities is the ordinary case. The
entries are ANDed, `.not_exists` is `NOT EXISTS`, and both nest inside `.any`,
which is what keeps ADR 0058's closure argument true.

## The correlation is read out of the schema

This is the part that decides whether the feature costs anything. The join is
not written at the call site. It comes from the child Row's own `.references`:

```zig
pub const nilo_table = .{
    .name = "partner_capabilities",
    .key = .{ .partner_id, .capability },
    .references = .{ .partner_id = .{ Partner, .id } },
};
```

`table.oneReference` already checks that harder than anything else here: the
target has to be a Row, the target column has to be one of its columns, and the
two Zig types have to be the same. **The check that makes this join safe was
already running**, for the migration tool, and this is its second reader. So the
call site gains no vocabulary and the module gains no check.

Three answers, and the two that are not one match are different mistakes:

- **One reference.** That is the join.
- **None.** The schema has not said how the two tables relate. A Refusal that
  says to add the `.references`, or to write `.on = .<column>`.
- **Two or more.** The schema has said it twice — `created_by` and `updated_by`
  both pointing at `staff` is the ordinary shape of this. Which one joins is a
  question about what the query *means*, and guessing would answer a different
  question, correctly, forever. A Refusal naming both columns.

`.on = .<column>` is the escape hatch, for a Row over a view (which has no
foreign keys, [ADR 0056](./0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md))
and for the two-reference case. It names the child's column and joins to the
outer Row's key — and a composite key there is a Refusal, because one column
cannot match two.

### The alternative that was rejected

A fourth marker word on the Row — `.related = …`. `table.zig` sets the bar for a
fourth word explicitly: *a caller with a case and a check that runs while
compiling*. The case exists and the check would be real, and it still loses,
because `.references` already carries the fact. Two words for one fact is where
drift starts, which is the same argument ADR 0058 used to reject a two-Row set
operation API.

## What it cost to build

One field on `where.Param`: `of: ?type`, the Row a parameter's column belongs
to. Null for every parameter a statement over one table writes. Without it the
type of a value inside the subquery would be looked up on the outer Row — which
answers with a column that happens to share a name, or refuses a column that is
really there. `where.ParamType` is the one function that reads it, so the five
places in `db.zig` that used to write `ColumnType(Row, param.column)` cannot
disagree about which Row that is.

And two fields on the walker's `State`: the table every column inside the
subquery is qualified with, and the Row its type comes from. They are on the
State rather than threaded through six signatures because they have to move
together — a qualifier out of step with the Row writes a column of one table and
binds it as a column of another, and that compiles.

## Against ADR 0018's four axes

- **Allocations per request: zero.** The subquery is comptime string
  concatenation and its values come out of the same parameter tuple.
- **Memory per idle connection: zero.** Nothing here is on a connection.
- **Throughput and p99: zero on nilo's side.** One statement, one round trip,
  the same as the query it replaces. What changes is what the database does,
  and that is the caller's plan.
- **Binary size: zero for a program that writes no `.exists`.** All of it is
  comptime.

**Unmeasured, and said out loud:** what an `EXISTS` costs the *database*
against the `db.raw` a caller writes today is not benchmarked here, because it
is the same SQL. If the two ever diverge, `bench/result/sql.md` is where the
number goes.

## What is still refused

A test against the **same table**. Both sides would be written as the same
relation, so every column in the subquery is ambiguous, and telling them apart
needs an alias. That is `db.raw`, and it is a Refusal that says so.

An `.exists` with an empty `.where`. It would ask only whether any row over
there is joined to this one, which the join column already answers without a
subquery.

## Consequences

- `exists` and `not_exists` join `any` as reserved column names. A Row with a
  column called either is refused by name, which is the same trade `any` made.
- The roadmap's *Not decided* entry narrows from four things to three. Joins,
  nested rows and aggregates are still there; subqueries came off, and the entry
  now says which property a fourth would have to keep.
- `table.foreignKeysOf` is public: the references a Row declares, with no
  Dialect involved. Asking `descOf` would have spent a `columnType` on every
  column of the table, which can refuse, in the middle of a question that has
  nothing to do with column types.
