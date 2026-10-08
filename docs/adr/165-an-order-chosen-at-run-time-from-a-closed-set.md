# An order chosen at run time, from a closed set

**Status:** accepted
**Topic:** [sql-query](../design/sql-query.md)

`.order = .{ .created_at = .desc }` is settled while compiling, and
`Direction`'s doc comment says why: *a sort chosen at run time is two
statements.* [ADR 036](036-the-shape-of-a-query-is-settled-while-compiling.md) is the whole of
the module's claim — the text exists before the program does — and
[ADR 051](051-a-statement-that-is-a-constant-can-be-prepared-once.md) is
what that buys: a plan name derived from the text, so the set of names a
program can ever use is fixed when it is built.

The port's list screens are ordered from their headings, tiered —
`?order=due:asc,title:desc` — over fifteen columns the server declares. Two
statements is thirty; three tiers over fifteen is twenty thousand. So it wrote
the one thing ADR 036 allows, a constant with the choice inside it:

```sql
CASE WHEN $13::text = 'due:asc'  THEN c.due_date END ASC  NULLS LAST,
CASE WHEN $13::text = 'due:desc' THEN c.due_date END DESC NULLS LAST,
…
```

Ninety-six terms on the flagship list, with three text parameters saying
which of them are live. It is correct, Postgres plans it, and it is a page of
SQL nobody will read, to say what `ORDER BY c.due_date ASC NULLS LAST` says
in six words. It also only plans well while the plan is custom: under a
generic plan nothing folds, and every row is sorted on ninety-six expressions.

## The other reading of "two statements"

The sentence was written about the *text*, and the property it protects is
narrower than the text: **no run-time string reaches the statement.** A
condition's value is a parameter; a column name is a Zig field name; nothing
the request sent is ever concatenated into SQL. That property survives a
statement whose pieces are constants and whose *selection* is the request's.

```zig
const Sort = sql.Ordering(Commitment, .{
    .due = .{ .column = .due_at, .nulls = .last },
    .title = .title,
    .value = "c.value_currency, c.value_minor",   // the caller's own SQL
});

fn list(db: *sql.Db, c: *nilo.Ctx, q: nilo.Query(struct {
    order: Sort = Sort.by(&.{.{ .key = .due }}),
})) !sql.Page(Commitment) {
    return db.page(Commitment, c, .{ .order = q.value.order, .limit = 20 });
}
```

An `Ordering` declares the keys once — a column of the Row, checked and quoted
by the Dialect, or the caller's own SQL — and builds a table of fragments
while compiling: one per key per direction, `"due_at" DESC NULLS LAST`. A
value of the type is a list of at most `keys` terms, each a key and a
direction. Writing the clause is writing those fragments in order. The
request decides *which*; it never decides *what*.

**It parses itself.** `?order=due:desc,title` reads straight into the query
field through `nilo_parse` ([ADR 113](113-a-path-param-can-parse-itself.md)),
so a key that is not declared, a direction that is not `asc` or `desc`, an
empty term and more terms than keys are all the 400 a bad number gets — in
the type's own words, since it says what it expects
([ADR 166](166-a-body-field-that-parses-itself.md)). Absent is the field's
default, which is the list's own order. The document says the field is text.

**A column key orders a typed statement; an expression is for a raw one.**
`db.select`, `db.one` and `db.page` take an `Ordering` in `.order` when every
key names a column, and refuse one whose key is text — a statement nilo writes
orders by columns it checked. `db.rawOrdered` takes the caller's statement
with `{order}` where the whole clause goes, and either kind of key:

```zig
const rows = try db.rawOrdered(CommitmentRow, c,
    \\SELECT … FROM commitments c WHERE c.state = $1 {order} LIMIT $2 OFFSET $3
, .{ state, limit, offset }, q.value.order);
```

The hole is the caller's, for the reason `db.rawOne` gives for not adding a
`LIMIT`: appending to somebody else's SQL is the thing `db.raw` exists not to
do. A statement with no hole, or two, is a Refusal.

**The Row travels with the ordering.** The keys were checked against one Row's
columns, so the type carries it (`nilo_ordering`), and a statement on another
Row is refused — the check said nothing about that one.

## What it gives up

**The plan name.** A statement whose text is assembled per request is not a
constant, and the set of texts is (2·keys)^tiers — fixed when the program is
built, which is ADR 051's condition, and thirty thousand for the port's
flagship list, which a cache on every pooled connection cannot hold and which
a request can enumerate. So an ordered statement runs unnamed: Parse, Bind
and Execute on every call, the 12 µs ADR 051 measured a name to be worth, on
a read that is usually the widest in the program. `db.raw` paid the same
until ADR 051, and the port's CASE ladder was paying more in the planner.

**One arena allocation** for the text, sized while compiling: the head, the
widest clause the ordering can write, and the tail.

## What was not done

**Preparing under a name derived from the chosen terms.** The set is finite,
so ADR 051's letter allows it. Its reason does not: a cache that grows with
the requests a client chooses to send is the cache ADR 051 refused for
`db.raw`, with the difference that this one is bounded — at thirty thousand
plans per connection. A single-tier ordering over fifteen keys would be
thirty, which a cache could hold; the type does not know how many tiers a
request will send, and a rule that depends on that is a rule somebody finds
out about from a connection's memory.

**Generating the CASE ladder.** It keeps the constant and the name, and it
keeps the ninety-six expressions per row under a generic plan. The port
measured it as working and described it as unreadable, and the second is a
cost this module's users pay every time they open the statement.

**Sniffing the request's column names against the Row.** The request could
say `?order=due_at:desc` and nilo could check it against the Row's fields at
run time. That would be a run-time string reaching the statement — checked,
but reaching — and the check would be a second place the Row's columns are
compared against text, at run time, with a 400 where the other check has a
compile error. The closed set is declared, the way everything else here is.

## Against ADR 017's four axes

- **Allocations per request: one**, for the text, on a statement that asked
  for a run-time order. A statement that did not is untouched — `textOf`
  returns the constant.
- **Memory per idle connection: zero.**
- **Throughput: the unnamed statement, ~12 µs** at one request in flight
  (ADR 051's figure). Not re-measured; the shape is `db.raw` before
  ADR 051, which is where the number comes from.
- **Binary size: nothing** for a program that declares no `Ordering`. One
  that does carries the fragment table, which is `keys × 6` short strings.

## Consequences

- `sql.Ordering(Row, keys)`, `.by(terms)`, `.fromTerms(terms)`, `nilo_parse`,
  `.write(D, w)`. **`.by` takes its terms while compiling** (`comptime terms`)
  and refuses none and more than there are keys there, where a `std.debug.assert`
  checked it at run time: out of bounds in ReleaseFast, and for none a statement
  whose key tiebreak began with a comma. Terms that arrive at run time go through
  `.fromTerms`, which answers null for the same two cases, as `nilo_parse` does
  for text. A key said twice (`?order=title,title:desc`) is not refused: both
  databases take `ORDER BY x ASC, x DESC`, and the first decides.
  `db.select`, `db.one`, `db.page`, `db.stream` and their `tx` forms take one
  in `.order`; `db.rawOrdered` and `tx.rawOrdered` take one beside the values.
- `statement.Statement` has `ordered` and `tail`. A statement that is not
  ordered has `tail = ""` and is exactly what it was.
- Six Refusals: a key naming a column the Row lacks, an ordering for another
  Row, an expression key on a typed statement, a raw statement with no
  `{order}`, and `.by` with no terms or with more than there are keys.
- The port's `platform/listsort.zig` — the CASE ladder and its `clause` —
  goes, and the flagship list is one statement.
- The mechanism is used a second time by [ADR 149](149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md):
  a statement holding a `sql.given` is cut into constant pieces and written per
  call, and one that is also ordered writes its cut head, the order and the tail
  in the one allocation (`db.splicedGuards`). The fixed cost of an ordered
  statement being unnamed is unchanged; a statement that is cut and not ordered
  is named per combination of its guards, up to three of them.
