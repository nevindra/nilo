# A raw statement can carry its total

**Status:** accepted
**Topic:** [sql-raw](../design/sql-raw.md)
**Extends:** [ADR 150](./150-a-page-knows-what-it-left-out.md) (a page is
one statement with `count(*) OVER ()` on it),
[ADR 051](./051-a-statement-that-is-a-constant-can-be-prepared-once.md)

## Context

`db.page` answers the rows and the total in one statement, because two
statements against a table somebody else can write between disagree with
nothing saying so (ADR 150). It composes the statement, so it is one table
and conditions that filter rows.

Every list screen in an application is a page, and most of them are a join:
the object and the name of whoever owns it, the invoice and its customer.
That is past one table, so it is `raw`, and `raw` had no page. The
application wrote two statements with one `WHERE` pasted into both, which is
the disagreement ADR 150 closed, reopened at the first join.

## Decision

**`db.rawPage(Row, c, sql, values)` reads the caller's statement as a page:
the Row's columns, and the total from the column after the last of them.**

The statement is the caller's, and so is the window: `count(*) OVER ()` goes
on the end of the `SELECT` list, where `db.page` would have written it. The
list is counted while compiling as the Row's fields and one more, the names
of the Row's own columns are checked as `raw` checks them, and a list
exactly the Row's width is a Refusal that says what to add. The total is
read once per statement from the same `filling` that reads `db.page`'s, so
a statement matching nothing is an empty page and a total of zero. A
`Page(Row)` comes back, the same type `db.page` answers, so a handler that
returns one is described the same way. `tx.rawPage` is the same inside a
transaction.

The `ORDER BY` and the `LIMIT` are the caller's to write, for the reason
`db.page` requires both.

**Past the last row, the same statement is asked again from its first.** The
window rides on the rows, so an empty page has no total, and nilo cannot write
a count of a statement it did not write ([ADR 150](./150-a-page-knows-what-it-left-out.md)
counts a typed page instead). What it can do is send the same text with the
offset at 0 and, where the limit is a placeholder of its own, the limit at 1:
the window on that one row is the total. The same text is the same prepared
plan, and only a page that came back empty with a non-zero offset, or a limit
of zero, sends it. To find the offset, the statement's own `OFFSET`, the one
outside every bracket, has to be one placeholder (`$3`, `$3::int` and
`$3 ROWS` are all that) used nowhere else in the text, with the values a
tuple. An `OFFSET` written as a number other than 0, as arithmetic, or with a
placeholder shared by another clause is a Refusal that says to work the number
out in Zig; SQLite's `LIMIT a, b` is one that says to write `LIMIT … OFFSET`.
A statement with no `OFFSET` skips nothing, so empty means nothing matched.

**`db.rawPageOrdered(Row, c, sql, values, order)` is the same page with the
request's order.** It takes the `{order}` hole and the `sql.Ordering` value
`db.rawOrdered` takes
([ADR 165](./165-an-order-chosen-at-run-time-from-a-closed-set.md)), and holds
the statement to both checks: the list is the Row's fields and one more, and
the hole is there exactly once. The flagship list of a product is the one whose
order is chosen from its headings, and without this it was `rawOrdered` for the
rows and a second statement for the total with the `WHERE` pasted in again,
which is the disagreement this ADR closed, reopened by the order. It runs
unnamed, for the reason `rawOrdered` does: its text differs per request.
`tx.rawPageOrdered` is the same inside a transaction.

## What was rejected

**Appending the window to the caller's text.** Adding text to a statement
this module did not write is the thing `raw` exists not to do: after a
`UNION ALL` or inside a CTE the window would mean something else, and
`rawOne` declined a `LIMIT 1` on the same grounds (ADR 146).

**A `nilo_beside`-like field the module fills.** The total is not a field of
a row, it is a fact about the statement, and every row would carry a copy of
it. `Page(Row)` already has the right shape.

**`rawPage` taking the `{order}` hole itself, with the ordering optional.**
One call for two shapes would decide at compile time whether to look for the
hole by whether an argument was passed, and `rawPage` over a statement with no
hole would then have two meanings. `rawOrdered` already set the pattern of a
second name, and the reader of a call site sees which one it is.

**Reading the total from a column named `total`.** A name is a convention,
and the module counts columns by position everywhere else. The position
after the last field is the one place the total can be with no name.

**Answering zero past the last row, and documenting it.** That was this
ADR's position, inherited from `count(*) OVER ()`, until item 97: a request
for rows 200 onward of a list that shrank to 150 read as "nothing matches".

**A count statement the caller writes beside the page.** It is the `WHERE`
pasted into two statements that this ADR was written to end, kept for the one
case where it would run.

**Refusing a statement nilo cannot re-ask, rather than answering zero for it.**
Taken, for the offset: the refusals cost a caller one `$n` and one line of Zig,
and a total that is silently wrong past the end is the thing being closed.

## What it costs

One `i64` read per statement, not per row, which is what `db.page` pays.
A page that comes back empty after skipping rows sends the statement once more,
reading one row where the limit is its own placeholder; no other page does.
The values are copied into a tuple of run-time fields for that second ask, on
the caller's stack. Eight refusals: two for the missing total, and six for a
page nilo could not ask again: an offset written out, written as arithmetic,
shared with another clause, or handed over as something other than a number,
values in a named struct, and `LIMIT a, b`. `rawPageOrdered` adds the per-request text `rawOrdered`
already pays, one arena allocation sized while compiling, and no plan name.

## Consequences

- `sql/db.zig`: `rawPage` and `rawPageOrdered` on `Db` and `Tx`.
- `sql/rawcheck.zig`: `assertPaged`, and `paging`, which finds the offset and
  the limit.
- `sql/refusals/raw_page_without_a_total.zig`,
  `raw_page_ordered_without_a_total.zig`, and the six `raw_page_offset_*`,
  `raw_page_limit_with_a_comma.zig` and `raw_page_values_named.zig` beside
  them.
- `examples/sqlite/` lists invoices with it.
