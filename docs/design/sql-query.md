# The query builder

**A query is a struct of options over a Row, and everything about its shape is decided before the program runs; only the values arrive with the request.**
How to write one is the guide ([`guide/sql/reading.md`](../guide/sql/reading.md), [`guide/sql/writing.md`](../guide/sql/writing.md)); every option and its type is the reference ([`reference/sql.md#queries`](../reference/sql.md#queries), [`#conditions`](../reference/sql.md#conditions)).
The code is `sql/where.zig` (conditions, `sql.given`, `.across`, `.exists`), `sql/ordering.zig` (`sql.Ordering`), `sql/shape.zig` (a parent, children, a group), `sql/statement.zig` (batches, upserts, the comptime budget) and `sql/dialect.zig` (the SQL each database gets).

## How the pieces fit

```
   Row (nilo_table, nilo_aggregate,        .{ .where = …, .order = …,
        .references)                             .limit = … }
        │                                              │
        └───────────────────────┬──────────────────────┘
                                 ▼
                  comptime: the Dialect writes the SQL
                  (table, columns, joins, clause text, all fixed)
                                 ▼
                  runtime: the Wire binds the values, runs it
                                 ▼
                     Row, [Row], Page(Row) or ?Row back,
                            in the request's Scope
```

Everything past the first arrow is a `const`. What the request supplies is a value for a parameter, a direction chosen from a closed set, or which of a fixed set of Refusals fires while compiling; nothing it sends is ever concatenated into the statement.

## The rule in force

1. **The shape of a query is settled while compiling, and only its values are not.** Which table, which columns, which operators, which order: all fixed before the binary exists, so what reaches the socket is a constant plus its parameters. [ADR 036](../adr/036-the-shape-of-a-query-is-settled-while-compiling.md)
2. **A struct of options, not a chain of calls.** `db.select(Row, c, .{ .where = …, .order = …, .limit = … })`; there is no `.where()` that returns a second type to call `.limit()` on, because a chain's failure prints the tower rather than a field name. [ADR 036](../adr/036-the-shape-of-a-query-is-settled-while-compiling.md)
3. **An optional in a condition is a Refusal, judged by the written value's type.** `.where` reads `?T` as ambiguous between `= $1` and `IS NULL` and refuses it at `zig build`; `.set` and an insert take one without complaint, because a write has only ever meant one statement. [ADR 040](../adr/040-a-condition-holds-a-value-not-a-maybe.md)
4. **`sql.given` drops a term, never sends it as null.** An absent filter removes the whole clause behind a guard the database folds away on its own plan; it takes a list on `.in` and `.not_in`, where null drops the term and an empty list is still the list; it is refused inside `.any`, beside a fixed condition of `.exists`, and in the condition of an `UPDATE` or `DELETE`; in an update's `.set` it keeps the column instead, `COALESCE($n, "column")`, on a column that is not optional. An `UPDATE` or `DELETE` whose condition a request emptied, an empty `.not_in` or a pattern of empty text, is refused at run time before it is sent. [ADR 149](../adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)
5. **One condition tested across several columns takes its parameter once.** `.across` ORs the same operator over the named columns and binds the value a single time, so a search box costs one placeholder and one plan entry whichever fields are set. [ADR 172](../adr/172-one-condition-over-several-columns-is-one-parameter.md)
6. **`.exists` reads the join out of whichever Row declares the reference.** The inner Row's own column is named with `.on`, the outer Row's with `.via`; two references, none, or both `.on` and `.via` together are refused rather than guessed. [ADR 175](../adr/175-an-exists-reads-the-reference-from-either-side.md)
7. **A narrower Row may say it has a parent, children, or is a group, and the call site does not change.** A field typed as another Row is joined and read into it; a `[]const` field of one is read by a second statement, matched to its parent by position; `nilo_aggregate` makes the Row one row per group, with `WHERE` and `HAVING` split by what each condition names. [ADR 218](../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)
8. **`UNION`, `INTERSECT` and `EXCEPT` over one table are boolean algebra on `WHERE`, not a keyword.** `.any` is the `OR`, an ordinary struct is the `AND`, and every leaf's negation gives the `EXCEPT`; over two different Rows the union is a database view, read like any other table. [ADR 052](../adr/052-a-set-operation-over-one-table-is-a-condition.md)
9. **The database escapes the pattern it is about to match.** `contains`, `starts_with` and `ends_with` build and escape `%` and `_` inside the statement itself, so the caller's text binds unchanged and costs nothing; SQLite has no case-sensitive `LIKE`, so `contains` there is a Refusal naming `icontains`. [ADR 140](../adr/140-the-database-escapes-the-pattern-it-is-going-to-match.md)
10. **A batch is one array per column, not one placeholder per row.** `db.insertMany` and `db.updateMany` compile to `unnest($1::t[], …)`, two placeholders whatever the batch size; a list column, or an enum with no `nilo_column` name, cannot be batched. [ADR 047](../adr/047-a-batch-is-one-array-per-column.md)
11. **`DO NOTHING` is asked for no key it does not need.** A pure join table with a composite key and no `id` can still `insertOrIgnore`, because the branch that would name a key is pruned while compiling for the one upsert that writes no `SET`. [ADR 114](../adr/114-do-nothing-has-no-key-to-leave-out.md)
12. **A conflict target is named once, and has a constraint behind it.** On a managed table it is the key or a declared `.unique`, not one that ignores case. `.key` at the call site reads the tuple the Row already declared on `nilo_table`, rather than spelling it again; `key` as an ordinary column name is refused only where a conflict target is what the position means. [ADR 151](../adr/151-a-key-is-named-once.md)
13. **A run-time order chooses among constants it never writes.** `sql.Ordering(Row, keys)` builds every fragment while compiling; the request picks by an enum value it parses itself, and the statement runs unnamed once its clause depends on the request, because the set of possible texts is no longer the fixed one a plan name assumes. [ADR 165](../adr/165-an-order-chosen-at-run-time-from-a-closed-set.md)
14. **A page answers its own total in the same statement as its rows.** `db.page` reads `count(*) OVER ()` alongside the page, so the count and the rows are one snapshot rather than two queries a write can land between; `.order` and `.limit` are required, and `.lock` is refused beside a window function. [ADR 150](../adr/150-a-page-knows-what-it-left-out.md)
15. **A comptime walk over a wide Row gets a budget sized to it.** `statement.budget` raises the evaluation quota ahead of every builder by the Row's width and the values written, so a twenty-column table with seventeen written compiles where the default quota did not. [ADR 169](../adr/169-a-statement-pays-for-the-width-of-its-row.md)

## Decisions

| ADR | What it decides |
|---|---|
| [036](../adr/036-the-shape-of-a-query-is-settled-while-compiling.md) | The query is an options struct compiled against a Row; no chain of calls, no ORM mechanisms |
| [040](../adr/040-a-condition-holds-a-value-not-a-maybe.md) | An optional in a condition is a Refusal, because it hides a choice between two statements |
| [047](../adr/047-a-batch-is-one-array-per-column.md) | A batch writes an array per column through `unnest`, not a `VALUES` list sized to the call |
| [052](../adr/052-a-set-operation-over-one-table-is-a-condition.md) | `UNION`/`INTERSECT`/`EXCEPT` over one table are conditions; over two Rows, a view |
| [114](../adr/114-do-nothing-has-no-key-to-leave-out.md) | `DO NOTHING` does not ask a keyless join table to name one |
| [140](../adr/140-the-database-escapes-the-pattern-it-is-going-to-match.md) | `contains`/`starts_with`/`ends_with` build and escape the pattern inside the statement |
| [149](../adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md) | `sql.given` drops a term rather than sending it null, and where it may not be used |
| [150](../adr/150-a-page-knows-what-it-left-out.md) | `db.page` answers rows and total from one statement |
| [151](../adr/151-a-key-is-named-once.md) | `.key` reads the conflict target off `nilo_table` instead of repeating it |
| [165](../adr/165-an-order-chosen-at-run-time-from-a-closed-set.md) | `sql.Ordering` lets a request choose an order among constants fixed while compiling |
| [169](../adr/169-a-statement-pays-for-the-width-of-its-row.md) | The comptime budget a statement builder gets, sized to the Row it is building against |
| [172](../adr/172-one-condition-over-several-columns-is-one-parameter.md) | `.across` binds one value and tests it against several named columns |
| [175](../adr/175-an-exists-reads-the-reference-from-either-side.md) | `.exists` reads its join off either Row's own declared reference, named `.on` or `.via` |
| [218](../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md) | A narrower Row may declare a parent, children, or be a group, without a `.join` at the call site |

Beside this topic: [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) is the four axes every rule above is measured against; [ADR 013](../adr/013-handlers-must-not-block-the-thread.md) is why a query exists as a typed call rather than a hand-written one run through `nilo.blocking`; [ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md) (sql-runtime) is what a constant statement buys and what ADR 165 gives up by writing one that is not; [ADR 023](../adr/023-a-failure-mode-belongs-in-the-return-type.md) and [ADR 004](../adr/004-http-errors-via-fail-functions.md) (errors) are how `?Row` and `error.AlreadyExists` become an HTTP answer; [ADR 055](../adr/055-the-second-dialect-is-the-test-of-the-seam.md) (sql-runtime) is why a Dialect may refuse a shape rather than emit the wrong SQL, which `contains` and `.exists` both lean on.

## Open

- **Two numbers ADR 036 owes and has not measured.** Throughput of `db.select` against hand-written pg.zig, held to ADR 017's 10% bar, and pg.zig's `read_buffer` sizing for the row-heavy queries this module produces. Recorded as owed in [ADR 036](../adr/036-the-shape-of-a-query-is-settled-while-compiling.md).
- **Whether a Row's `jsonStringify` on `Timestamp` and `Uuid` costs enough to matter.** `covers()` sends such a type through `std.json` rather than the generated writer, and ADR 036 defers the question of whether this module may reach into nilo's JSON writer until `zig build profile` says it is over the 10% bar.
