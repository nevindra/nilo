# A filter that is absent is not a filter that is null

[ADR 0044](0044-a-condition-holds-a-value-not-a-maybe.md) refuses an optional in a
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
run time, which is the thing ADR 0044 refused. The report said so itself: *"it
is deliberately not a request to make `.eq` take an optional."*

It compiles to the guard a hand-written statement uses:

```sql
($1 IS NULL OR "name" ILIKE '%' || $1 || '%')
```

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
`$2::text IS NULL OR` in front of it. Nothing about `Statement` changes, so no
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
([ADR 0171](0171-a-row-over-there-is-a-condition.md)), and guarding the term
*inside* it is wrong:

```sql
EXISTS (SELECT 1 FROM pc WHERE pc.partner_id = p.id AND ($2 IS NULL OR pc.capability = $2))
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

## Against ADR 0018's four axes

- **Allocations per request: zero.** The wrapper is a struct holding an
  optional, passed by value into the same tuple every other parameter goes
  into.
- **Memory per idle connection: zero.**
- **Throughput: zero on nilo's side**, and the parameter binds as an optional
  where it would have bound as a value — the same branch `not_distinct_from`
  has had since ADR 0044. What it costs the *database* is the section above.
- **Binary size: one statement rather than 2ᵏ**, which is the axis that decided
  the design.

## Consequences

- `db.select`, `db.one`, `db.page`, `db.count`, `db.exists` and `db.stream` take
  it. `db.update`, `db.updateReturning`, `db.delete` and `db.deleteReturning` do
  not.
- With [ADR 0185](0185-a-page-knows-what-it-left-out.md) the ordinary list
  endpoint is one typed call: an optional search, an optional `EXISTS`, a page
  and its total. The report filed the two together for that reason.
- `Param` carries `droppable`, which is what `statement.zig` reads to refuse the
  update and the delete. It is set in `State.take` rather than at the six call
  sites that build parameters, so no operator has to remember it.
