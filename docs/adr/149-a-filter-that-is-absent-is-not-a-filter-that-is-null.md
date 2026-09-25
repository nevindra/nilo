# A filter that is absent is not a filter that is null

**Status:** accepted
**Topic:** [sql-query](../design/sql-query.md)

[ADR 040](040-a-condition-holds-a-value-not-a-maybe.md) refuses an optional in a
condition, and the reason holds: a null reaching `= $1` sends `= NULL`, which is
never true in SQL. The query runs, matches nothing, and says nothing.

Nobody is asking for that back. What could not be spelled is a different
question.

## Two questions, one syntax

`.status = null` means *the rows whose status is nothing*. What a screen with a
search box and three dropdowns needs is *no condition on status at all* — and
those are opposites: the first matches a handful of rows, the second matches
every one.

The refusal's advice is to branch. What that costs, in the reporting port:

```zig
pub const Filter = struct {
    search: ?nilo.Str = null,
    capability: ?Capability = null,
    limit: ?i32 = null,
    offset: ?i32 = null,
};
```

**Two optional filters is four arms**, and each arm repeats the `.order`, the
`.limit`, the `.offset` and the `db.count` beside the `db.select` — the pairing
§"Counting" exists to make hard to get wrong. So the query stayed `db.raw`,
which is the escape hatch covering for a gap rather than carrying hard SQL.

And **every paging list in that product narrows on optional filters.** That is
what a filter *is* on a screen with a search box; the typed surface stopped at
the first one.

## `sql.given`, and why it is a word rather than an optional

```zig
.where = .{
    .name = .{ .icontains = sql.given(filter.search) },
    .status = sql.given(filter.status),
}
```

A word, because the two questions above have to stay tellable apart. Making
`.eq` take an optional would give one syntax two meanings decided by a value at
run time, which is the thing ADR 040 refused. The report said so itself: *"it
is deliberately not a request to make `.eq` take an optional."*

It compiles to the guard a hand-written statement uses:

```sql
("name" ILIKE '%' || $1 || '%' OR $1 IS NULL)
```

**Amended: the term comes first, and as first written it did not.** This ADR
shipped `($1 IS NULL OR "name" ILIKE …)`, with comptime tests asserting that
string and no live test running one. pg.zig sends a `Parse` with no parameter
types, so Postgres types each parameter at its first use — and `$1 IS NULL` is
a null test on an unknown, which fixes nothing. Every guard shape was *could
not determine data type of parameter $1* (`42P08`) from the database on the
first request, found by the port whose list endpoint is the example above. The
port's own hand-written guard had always been `$2::text IS NULL`, and a cast
was the fix it proposed; the order is the better one, because it needs no type
name — an enum column has none this module can write — and means the same
thing, `OR` being commutative in three-valued logic. `sql/live.zig` runs each
shape against Postgres now: text, a number, a pattern, a `timestamptz`, a
`uuid`, an enum and an `EXISTS`. The lesson is in
[`history.md`](../history.md#tests-that-could-not-fail).

## One statement, and the alternative that was rejected

The report suggested **two comptime plans and a runtime pick**. With `k`
optional filters that is 2ᵏ statements — and not only 2ᵏ strings: each variant
has its own parameter list, so it has its own values tuple, so `fill` is
instantiated 2ᵏ times per call site, with the Row's whole read loop inside it.
Four filters on one screen is sixteen copies of that, sixteen prepared
statements per connection, and a plan cache that thrashes as somebody clicks the
dropdowns.

The guard is one statement, one parameter list, one prepared name, one plan
entry, and **the same SQL the port already writes by hand** — its `db.raw` has a
`$2::text IS NULL OR` in front of it (the cast is what a hand-written guard
needs on Postgres; the amendment above is how the generated one does without). Nothing about `Statement` changes, so no
consumer of one has to learn that it might be a set of statements.

**What the guard costs is the planner, and it is smaller than it looks.**
`plan_cache_mode` defaults to `auto`: Postgres plans a prepared statement as a
custom plan for its first five executions, substituting the actual parameter
values, and keeps doing so while the custom plan beats the generic one by more
than the planning cost. With `$1` null, `$1 IS NULL` folds to true and the whole
disjunct disappears; with `$1` set it folds to false and `false OR EXISTS(…)`
simplifies back to a plain `EXISTS`, which Postgres then pulls up into a
semi-join. So on a custom plan the guarded statement plans to what the 2ᵏ
version would have compiled. It is on a *generic* plan that the guard blocks an
index, and for this shape the generic plan is exactly the one the cost
comparison rejects. `SET plan_cache_mode = force_custom_plan` is the lever if a
particular query disagrees.

## Inside an `EXISTS` the guard goes round the outside

The port's capability filter is an `.exists` over a second table
([ADR 218](218-a-row-may-carry-its-parent-its-children-or-a-sum.md)), and guarding the term
*inside* it is wrong:

```sql
EXISTS (SELECT 1 FROM pc WHERE pc.partner_id = p.id AND (pc.capability = $2 OR $2 IS NULL))
```

With `$2` null that asks whether the partner has **any** capability row, which
excludes every partner that has none. It compiles, it passes, and the list is
missing rows — the shape of every item in the report.

So a `sql.given` inside an `.exists` drops the whole subquery, and the guard is
written around it. That leaves one case that could mean either thing, and it is
a Refusal rather than a guess: **a `sql.given` beside a condition that is always
there.** Write a second `.exists` for the fixed one.

## Three more Refusals

- **Inside `.any`.** `.any` is OR, so an alternative that is not there makes the
  condition match *fewer* rows. Everywhere else a term that drops widens the
  answer, which is what a filter nobody set has to do. One word cannot mean
  both.
- **In the condition of an `UPDATE` or a `DELETE`.** `.where = .{ .id =
  sql.given(maybe) }` is `DELETE FROM people` on the day `maybe` is null. The
  two refusals that already stand between those statements and the whole table
  exist because it is reached by leaving something out; this would be a third
  way to leave it out, decided at run time.
- **On `not_distinct_from` and on `.in`.** The first already takes an optional
  and treats null as an ordinary value, so there is no term to drop. The second
  takes a list, and a list that may be absent is the empty list, which `.in`
  already reads as *no row matches*.

And one on the way in: `sql.given` handed something that is not an optional is
refused, because a value that is always there is an ordinary condition and the
guard around it would never be taken.

## A condition a request emptied is refused at run time

`sql.given` is refused in an `UPDATE` or a `DELETE` because what narrows one
of those must not depend on a value that may not arrive. Two operators reach
the same place by a value that does arrive. `.not_in` with an empty list is
`"id" <> ALL('{}')`, true of every row, so "delete everything except these"
empties the table the day the list is empty. A pattern built from empty text,
`.contains = ""`, is `LIKE '%%'`, true of every row with the column. Neither
can be seen while compiling.

So `update`, `delete` and their returning forms ask `where.filtersNothing`
before they send anything, and a condition that narrows nothing with the
values it was given is refused as `error.QueryFailed` with a line naming the
call. The terms of a struct are ANDed, so one term that narrows is enough to
send it: `.{ .tenant_id = t, .id = .{ .not_in = keep } }` with `keep` empty is
the tenant's rows, which is what it says. The alternatives of `.any` are ORed,
so one alternative that narrows nothing is enough to refuse. An empty `.in`
narrows to nothing and a negated pattern of empty text is true of no row, so
neither is refused. The walk is unrolled while compiling, so a condition with
no list and no pattern in it costs nothing. A read is not checked: an empty
filter that returns every row is a slow page, not lost data.

The compile-time half moved with it. The "no condition" Refusal used to count
parameters, so `.where = .{ .deleted_at = null }`, which is `IS NULL` and binds
nothing, was refused as though the `.where` were empty. It asks whether the
condition wrote any SQL now.

## In a `.set`, the same word keeps the column

A PATCH body is a struct of optionals, and each field the client left out is a
column the handler must not touch. Written with `db.update`, that was the 2ᵏ
arms again, one per combination of fields present, or a `db.raw`.

`sql.given` in a `.set` is the same word asking the same question, *was a
value handed over*, with the answer written where an assignment goes:

```sql
UPDATE "drafts" SET "title" = COALESCE($1, "title"), "words" = COALESCE($2, "words") WHERE "id" = $3
```

One statement and one parameter list, like the guard. The parameter binds as
an optional and is not marked `droppable`, because nothing drops: the
assignment is always in the statement and only its value is kept. Postgres
types `$1` from the column beside it inside the `COALESCE`, so no cast is
needed, and `sql/live.zig` runs it. A body with every field absent still
matches its row and writes each column back as it was; the count says one
row changed, and a trigger on the table fires.

**It is refused on a column that may be NULL.** There, null is a value too:
`{"nickname": null}` means *clear it*, and `COALESCE` cannot tell that from
the field being absent, so the request would answer 200 and keep the old
nickname. Telling the two apart needs a second value per field, which a
`?T` does not carry. Until a caller needs it, the column is set with a plain
`.nickname = value` in an update of its own.

## Against ADR 017's four axes

- **Allocations per request: zero.** The wrapper is a struct holding an
  optional, passed by value into the same tuple every other parameter goes
  into.
- **Memory per idle connection: zero.**
- **Throughput: zero on nilo's side**, and the parameter binds as an optional
  where it would have bound as a value — the same branch `not_distinct_from`
  has had since ADR 040. What it costs the *database* is the section above.
- **Binary size: one statement rather than 2ᵏ**, which is the axis that decided
  the design.

## Consequences

- `db.select`, `db.one`, `db.page`, `db.count`, `db.exists` and `db.stream` take
  it. `db.update`, `db.updateReturning`, `db.delete` and `db.deleteReturning` do
  not take it in their condition; the updates take it in their `.set`, on a
  column that is not optional.
- With [ADR 150](150-a-page-knows-what-it-left-out.md) the ordinary list
  endpoint is one typed call: an optional search, an optional `EXISTS`, a page
  and its total. The report filed the two together for that reason.
- `Param` carries `droppable`, which is what `statement.zig` reads to refuse the
  update and the delete. It is set in `State.take` rather than at the six call
  sites that build parameters, so no operator has to remember it.
