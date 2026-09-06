# 0119 — the SQLite write path is compiled, and three columns fell out of it

**Status:** accepted
**Amends:** [ADR 0061](./0061-the-second-dialect-is-the-test-of-the-seam.md),
[ADR 0078](./0078-a-uuid-is-whatever-the-database-stores.md)

## Context

A method on a generic struct is analysed only where it is called. So the
methods of `DbOf(sqlite.Wire(…), dialect.SQLite, "")` were compiled wherever
somebody called them — and in this repository, almost nobody did.

- `sql.Sqlite`'s only caller was `bench/sql.zig`, which reads a Row of `i64`,
  `Str` and `i32`, and which is **not on `zig build test`**.
- `sql/live.zig` is Postgres only.
- `sql/sqlite.zig` drives `run`, `exec` and `begin` on the Wire rather than
  going through `db.zig`.
- `sql/db.zig`'s own SQLite tests, added by ADR 0078, cover a `Uuid` and
  `db.exec`.

**So the SQLite arms of `WireWrite`, `forWire` and `Values` had never been
compiled at all**, for any column type past a scalar and text. That is not one
gap among several. It is the reason for three of them, and each was a compile
error four frames inside somebody else's driver:

```
zig-pkg/zqlite-…/src/conn.zig:430:9: error: cannot bind value of type []const i64
referenced by: _bind__anon → bind__anon → … → db.select
```

**`.in` and `.not_in`, and three documents said they worked.**
`dialect.SQLite.list_form` is `.json_each` and `where.zig` has written
`"id" IN (SELECT value FROM json_each(?1))` since the second Dialect landed —
and nothing anywhere turned the list into the JSON text that statement reads.
`WireWrite` mapped a list column to a native Zig slice whatever the Dialect
was; it branched on `D.uuid_form` and on nothing else. The claim that it worked
is in `sql/dialect.zig`'s header, in ADR 0061, and in the guide's five-row table
of *what SQLite will not do*, which does not list it. That is the operator every
real schema uses, in the state this module refuses everywhere else: a promise
with a driver's compile error behind it.

**A `Json(T)` column and an enum column, for the same reason.** `WireWrite`
handed the driver the `Json(T)` wrapper struct and the Zig enum itself, and
zqlite's `_bind` takes an integer, a float, a bool, a `[]const u8` and its own
`Blob`. Both columns *read* correctly, because `WireRead` maps them to
`[]const u8` and the text path works — so a Row carrying one compiled for
`db.select` and stopped compiling at `db.insert`. `acceptsSqlite` answers
`TEXT` for both, so the startup check said they were fine.

Which is ADR 0078's finding arriving twice more. That ADR added `uuid_form`
because the read half and the write half disagreed about one column; the same
disagreement was sitting under two more, unfound because nothing compiled them.

## Decision

**A handler naming every `Db` and `Tx` call, over a real in-memory SQLite
database, on `zig build test`.** `touchEverything`'s shape — the route that
exists so that no statement in this module is uncompiled — extended to the
Wire that had none. Its Row carries a `Uuid`, a `Timestamp`, a `Json(T)` and an
enum, which are every column type that binds as something other than itself.

Then the three things it found:

**`dialect.ValueForm` — `json_form` and `enum_form`, the two rows `uuid_form`
should have been followed by.** Postgres declares `.native` for both: `jsonb`
is a column type pg.zig writes any struct into through `std.json`, and a
Postgres enum is a column type it binds a Zig enum to. SQLite declares `.text`
for both, because it has neither type and `acceptsSqlite` has always said TEXT
for both. `WireWrite` reads the Dialect and answers `[]const u8`; `forWire`
reads the answer back off `To`, which is how the conversion stays in one place
— the arrangement ADR 0078 made for `Uuid`, and the reason the Dialect is not
threaded into `forWire`. A tag is `@tagName`, which is a constant in the
binary; a document is written into the request arena.

`assertDialect` owes both, like every other piece.

**`.in` is written as JSON.** `Values` answers `[]const u8` rather than
`[]const F` for a list parameter when `D.list_form == .json_each`, and
`jsonList` fills it: each element through `forWire` into a slice in the request
arena, then `std.json` over that slice. Converting first is what makes a list
of `Str`, of `Uuid` or of tags come out as what the column holds rather than as
whatever Zig would stringify the struct as.

## What was rejected

**Making `.in` a Refusal on SQLite and correcting the three documents**, which
is the other half of the choice and is what `.lock`, `insertMany` and
`tx.deadline` already do. It is the honest answer for something that cannot
work, and this can: `json_each` is SQLite's own idiom, `where.zig` had already
written the SQL, and `list_form` had already been given a fourth value
specifically so the statement stays a constant on a database with no array type
(ADR 0061). Refusing it would have thrown away work that was ninety per cent
done in order to make three documents true by subtraction.

**One `binds` declaration on the Dialect covering both json and enum**, since
the two move together — both are "the driver takes only scalars and text". They
move together for these two Dialects, which is not a reason to write down that
they always will. Both are storage questions, exactly as `uuid_form` is:
Postgres has the types and SQLite does not.

**Threading the Dialect into `forWire`.** `WireWrite` already decided, and
`forWire` reading the decision off `To` keeps one answer in one place.

**Fixing the `Timestamp` disagreement while here.** `WireWrite` answers `i64`
whatever the Dialect, `acceptsSqlite` routes it to TEXT, and the column that
matches what is bound fails the startup check. It is real and it is a `time_form`
beside `uuid_form` — a design, not a branch — and it stays its own roadmap
entry. The test declares the column the way that passes the check and says so.

## What it costs

**One arena allocation per `.in` on SQLite**, plus the slice of converted
elements — so two, on a statement inside a request that was already going to
allocate. Nothing per row. Nothing on Postgres, which keeps binding a native
array.

A `Json(T)` on SQLite costs the document written out, which is the same
allocation reading one already pays and the same one a Postgres batch pays per
row. An enum costs nothing: `@tagName` is a constant.

Nothing on any path a Postgres program takes. Every branch added is comptime
and keyed on a Dialect declaration.

## What holds it

Two tests in `sql/db.zig`, both against a real in-memory database:

- every `Db` and `Tx` call, over a Row carrying all four awkward column types,
  with `checkSchema` agreeing about all eight columns;
- `.in` and `.not_in` over a number, text, a tag and a `Uuid`, each asserting
  the **rows that came back** rather than that the call compiled — because the
  JSON being accepted and the JSON being read are different claims. An empty
  list matches nothing, which is what `json_each('[]')` does and what
  `= ANY('{}')` does on Postgres.

`.lock`, `insertMany`, `updateMany` and `tx.deadline` stay compile errors here
and are left out of the handler. That is the seam refusing rather than lying,
which is ADR 0061's whole point and is worth knowing before somebody plans a
migration on the assumption that swapping the Dialect is free.
