# Raw statements

**`db.raw` is the way past *one table, conditions that filter rows*: a join, an aggregate, a window function, and it keeps the arena, the `Str` rule and the row filling, giving up only the compile-time column check.**
How to write one is the guide ([`guide/sql/raw.md`](../guide/sql/raw.md)); the calls and their signatures are the reference ([`reference/sql.md#queries`](../reference/sql.md#queries), [`reference/sql.md#a-row-that-owns-no-table`](../reference/sql.md#a-row-that-owns-no-table)).
The code is `sql/db.zig` (`raw`, `rawOne`, `rawExactlyOne`, `rawOrdered`, `rawPage`, `rawPageOrdered`, `compose`, `composed`, `composedOne`, and their `Tx` twins), `sql/rawcheck.zig` (everything checked while compiling) and `sql/composed.zig` (`Composed`, built only from pieces that cannot carry a string).

## How the pieces fit

```
  comptime SQL text                    run-time pieces (sql.Composed)
  (raw, rawOne, rawExactlyOne,           .text(comptime literal)
   rawOrdered, rawPage, and Tx)          .ident(name)   -> checked, quoted
        │                                .param(n)      -> dialect's $n / ?n
        │  rawcheck, while compiling:          │
        │  column count vs. the Row,           │  checkComposed, at run time:
        │  a text column not cast,             │  dialect match, param count
        │  $n respelled for the dialect        │  against the value tuple
        ▼                                       ▼
  db.raw / rawOne / rawExactlyOne / rawPage    db.composed / composedOne
        │                                       │
        └───────────────────┬───────────────────┘
                             ▼
              fill(): same Str rule, same arena,
              same run-time width guard (ADR 106)
                             │
             Row  │  a scalar (ADR 125)  │  Page(Row) (ADR 205)
```

`db.exec` sits outside this: its text is read at run time and sent as written, for the DDL and `PRAGMA` calls that have no Row to check against.

## The rule in force

1. **A `SELECT` list shorter than the Row is a refusal, not a crash.** `fill` compares the Wire's `width(rows)` against `columnsOf(Row).len` before reading a column; short is `error.QueryFailed` naming both numbers. Asked after the first row is pulled, because SQLite's column count answers zero before a statement is stepped. [ADR 106](../adr/106-a-select-list-shorter-than-the-row-is-refused.md)
2. **A wider list is not refused.** `SELECT *` into a narrower Row is an ordinary way to write one, and the first N columns are exactly what it means. [ADR 106](../adr/106-a-select-list-shorter-than-the-row-is-refused.md)
3. **A raw parameter converts the way a Row's column does.** `rawValuesOf` runs each tuple field through the same `forWire` a typed statement uses, so a `Uuid` binds sixteen bytes and a `[]const Str` list binds the way a column of one does, with nothing allocated for a field that needed no conversion. [ADR 116](../adr/116-a-raw-parameter-is-converted-the-way-a-rows-is.md)
4. **A raw statement cannot cast a column it did not write.** `rawcheck` reads what each column of the `SELECT` list *is* and refuses a bare column, or a `*`, where the matching field is a text column (`Decimal`, `Interval`, an `AsText` type): those are the two shapes that cannot carry the `::text` cast nilo adds to every statement it composes itself. Any expression, including a correct cast, passes unexamined. [ADR 124](../adr/124-a-raw-statement-cannot-cast-what-it-did-not-write.md)
5. **A Row may say it owns no table.** `pub const nilo_table = .projection;` marks a shape that is not a table, for a join, a rollup or a search across several; `db.raw`, `tx.raw` and `db.composed` fill one, and everything that writes its own `FROM` (`select`, `insert`, `db.checking`, migrations) refuses it by name through the one funnel, `row.ownerOf`. [ADR 125](../adr/125-a-row-that-owns-no-table.md)
6. **A single column needs no Row at all.** `db.raw`, `db.rawOne`, `tx.raw` and `tx.rawOne` take a column type in place of a Row (`[]const u8`, `i64`, a `Str`, or an optional of one), read through the same `readColumn` a Row's field goes through; a two-column list into a scalar is a refusal (`assertOne`), the same way a short list is (`assertList`). [ADR 125](../adr/125-a-row-that-owns-no-table.md)
7. **A statement with a key answers `!?Row`, with no `LIMIT` added.** `rawOne` is the unwrap `db.one` gives a typed select, not a cheaper statement: `raw` did not write the `WHERE`, so there is nowhere honest to put a `LIMIT 1`, and a condition matching several rows still costs every one of them. `updateReturningOne` and `deleteReturningOne` refuse a `.where` that does not hold the key or a unique with `=`, because a write of every matching row answered with one hides the rest. [ADR 146](../adr/146-a-statement-with-a-key-in-it-has-a-single-row-answer.md)
8. **A statement that always answers, answers a Row, not an optional.** `rawExactlyOne` is for an aggregate with no `GROUP BY`, a `RETURNING` on a keyed write, a `SELECT` of constants: it answers the Row, or `error.QueryFailed` when the statement came back with none, never a zero-filled default that would hide the disagreement. [ADR 206](../adr/206-a-statement-that-always-answers-answers-a-row.md)
9. **A raw `$n` is respelled for the dialect, and counted, while compiling.** `rawcheck.spelled` rewrites `$1`, `$2`, … to the Dialect's own spelling (identity on Postgres, `?1`, `?2` on SQLite) in every call that takes comptime text; `assertParams` refuses a gap in the numbering or a tuple with fewer values than the highest `$n`. `db.exec`'s run-time text is sent as written and gets neither. [ADR 204](../adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)
10. **A raw statement can carry its own total.** `db.rawPage` and `tx.rawPage` append `count(*) OVER ()` after the Row's own columns, checked while compiling as the Row's width plus one, and answer the same `Page(Row)` a typed `db.page` does; `rawPageOrdered` is the same with the request's `{order}` in it. [ADR 205](../adr/205-a-raw-statement-can-carry-its-total.md)
11. **A statement composed at run time is built only from pieces that cannot carry a string.** `Composed.text` takes `comptime piece: []const u8`, so a run-time slice does not compile; `.ident` checks a run-time name against the grammar of an identifier and quotes it, refusing anything else; `.param(n)` writes the dialect's own placeholder. There is no method that takes a run-time string as SQL. [ADR 208](../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md)
12. **`db.composed` checks what the text isn't there to check while compiling.** A `Composed` spelled for the other dialect is `error.WrongDialect`; a value tuple that does not match the highest `param` written is `error.ParamCountMismatch`. It runs unnamed, giving up the plan name and the comptime column count that `raw` keeps. [ADR 208](../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md)

## Decisions

| ADR | What it decides |
|---|---|
| [106](../adr/106-a-select-list-shorter-than-the-row-is-refused.md) | A short `SELECT` list is a run-time refusal instead of an out-of-range read |
| [116](../adr/116-a-raw-parameter-is-converted-the-way-a-rows-is.md) | A raw parameter goes through the same conversion a column's value does |
| [124](../adr/124-a-raw-statement-cannot-cast-what-it-did-not-write.md) | A bare column or `*` against a text column is refused while compiling |
| [125](../adr/125-a-row-that-owns-no-table.md) | `.projection` for a Row with no table, and a column type in place of a Row |
| [146](../adr/146-a-statement-with-a-key-in-it-has-a-single-row-answer.md) | `rawOne`, the unwrap with no `LIMIT` added; `updateReturningOne` and `deleteReturningOne`, which change the one row the condition pins |
| [204](../adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md) | `$n` respelled and counted for the dialect, while compiling |
| [205](../adr/205-a-raw-statement-can-carry-its-total.md) | `rawPage` and `rawPageOrdered`, a raw statement that answers a `Page(Row)` |
| [206](../adr/206-a-statement-that-always-answers-answers-a-row.md) | `rawExactlyOne` for a statement that cannot honestly answer with no rows |
| [208](../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md) | `Composed`, a run-time statement built from text, checked names and parameters only |

Beside this topic: what `db.raw` is a way past, one table and conditions that filter rows, is [ADR 036](../adr/036-the-shape-of-a-query-is-settled-while-compiling.md) (sql-query); why a raw statement is prepared and named at all is [ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md) (sql-runtime); the page a typed `db.page` writes, which `rawPage` matches the shape of, is [ADR 150](../adr/150-a-page-knows-what-it-left-out.md) (sql-query); the column types a raw or composed statement reads and binds are sql-types' own ADRs, among them [ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md).

## Open

- **A raw statement into `db.stream`.** `db.stream` builds its own `SELECT`, so a projection has nothing to stream from today; [ADR 125](../adr/125-a-row-that-owns-no-table.md) calls this a gap rather than a decision, and does not rule it out.
- **`Composed` reading enough SQL to add a builder's conditions or joins.** Named and declined in [ADR 208](../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md), not on the roadmap: the module's line is one table and conditions that filter rows, and a query engine is past it on purpose.
