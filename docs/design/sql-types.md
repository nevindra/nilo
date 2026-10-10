# SQL column types

**A column type is whatever the database actually stores, checked while compiling against the Dialect it is used with, and a type this module has never heard of can still declare itself as one.**

**Guide:** [A table is a struct](../guide/sql/tables.md) · **Reference:** [Types](../reference/sql.md#types), [A column type of your own](../reference/sql.md#a-column-type-of-your-own)

The code is `sql/types.zig` (the shipped types, `AsText`), `sql/wire.zig` (`Bytes`, `assertWire`'s list of what a Wire must provide, `readList`), `sql/dialect.zig` (`accepts`, `acceptsSqlite`, the storage-form declarations), `sql/db.zig` (`forWire`) and `sql/table.zig` (the marker, `nilo_beside`, a composite `.key`).

## Overview

```
  a Row's field type
        │
        ├── a scalar, Str, an enum ──────────► accepts / acceptsSqlite: exact per Dialect
        ├── []const T (a slice) ─────────────► one array column, one allocation per row
        ├── sql.Uuid, sql.Timestamp, sql.Date,
        │   sql.Decimal, sql.Bytes ──────────► shipped types; storage form declared on
        │                                       the Dialect (UuidForm, ValueForm, …)
        └── nilo_column + nilo_read + nilo_write
                                              ► a column type this module never heard of;
                                                travels as text Postgres prints, whoever
                                                wrote the three declarations

  every value, on the way in: forWire(To, value, c) reads the Dialect's declared
  form and the destination type, and a NULL into a non-optional column is
  error.QueryFailed on both Wires, not a zero or an empty string
```

## Rules

1. **A list column is a plain Zig slice, with no wrapper.** `[]const i32` is `int4[]`, `?[]const i32` is a nullable column, `[]const ?i32` is one whose elements may be null, and `[]const Str` or `[]const []const u8` is a list of text. An array's element type must match exactly, with none of the widening a scalar column gets. Reading one costs one allocation per row, or two when the elements are `Str`. Not available in `db.stream`, and an array of a declared column type such as `Decimal` cannot be read. [ADR 045](../adr/045-an-array-is-a-slice-and-a-slice-is-one-deep.md)
2. **A column type this module does not know is defined by a protocol, not a list.** Any struct or enum with `nilo_column`, `nilo_read(text, arena)` and `nilo_write(arena)` is a column type, whoever wrote it. It travels as the text Postgres prints, in both directions (`"col"::text` out, `$1::name` in), because text is the one representation every Postgres type guarantees, including those added by extensions. Having only half of the read/write pair, or both without `nilo_column`, is a compile error. [ADR 049](../adr/049-a-column-type-can-come-from-outside-this-module.md)
3. **`sql.AsText(name)` is the simplest use of that protocol**, and `sql.Decimal`, `sql.Interval` and `sql.Inet` are built on it. `Decimal` stores its digits as text and does no arithmetic: no `.add`, no `.round`. It is written to JSON as a string, so a consumer's `JSON.parse` cannot round it into an `f64`. [ADR 049](../adr/049-a-column-type-can-come-from-outside-this-module.md)
4. **When the two databases store a column differently, its storage form is declared on the Dialect, and `WireWrite`/`forWire` read the Dialect, not just the field type.** `sql.Uuid` is `.bytes` on Postgres and `.text` on SQLite. `sql.Json(T)` and enum columns are `.native` on Postgres and `.text` on SQLite. `sql.Timestamp` goes to an integer type on SQLite (`INTEGER`, `INT`, `BIGINT`, `NUMERIC`, `DATETIME`, `TIMESTAMP`), never `TEXT`. On Postgres it is `timestamptz` and nothing else, since a zoneless `timestamp` meets `now()` through the session's zone, and `infinity` is refused by name. On SQLite, `.in`/`.not_in` are written as `json_each` over a JSON-encoded list instead of being bound as a native array, a number is read only out of a stored number, and a NaN is refused before SQLite binds it as NULL. [ADR 067](../adr/067-a-value-is-whatever-the-database-stores.md)
5. **Binary data is a type, not a second protocol.** `sql.Bytes { bytes }` is `bytea` on Postgres and `BLOB` on SQLite. It is kept separate from text because both are the same Zig type read in two different, non-interchangeable ways (`sqlite3_column_text` versus `sqlite3_column_blob`). `sql.AsText("bytea")` still compiles but is now the wrong choice: it round-trips through hex. [ADR 141](../adr/141-bytes-are-a-type-not-a-second-protocol.md)
6. **A NULL in a column the Row says is not optional is rejected on both Wires**, as `error.QueryFailed` with a `warn` naming the column index and the Zig type, never silently turned into zero or an empty string. The startup check catches a nullable table column; this catches the cases it cannot, such as a view or a `Db` nobody called `checking` on. [ADR 094](../adr/094-a-null-is-refused-by-both-wires-or-by-neither.md)
7. **A key can span several columns.** `.key = .{ .tenant_id, .id }` is a tuple of column names, the same form `conflictColumns` already uses. At the call site it is a struct (`db.find(Seat, c, .{ .tenant_id = t, .id = id })`), never a tuple, so two columns of the same type cannot be swapped by mistake and still compile. Leaving out a key column, passing a tuple, or naming a column that is not part of the key are all compile errors. A composite key is never generated. [ADR 139](../adr/139-a-key-is-as-many-columns-as-it-takes.md)
8. **A value converts into a nullable column; an error union does not.** A column type's `nilo_write` returns `!T`, and `!T` does not convert into `!?T` by itself. `forWire` fixes this by putting `try` before the value, so the payload is a plain value again and Zig converts it into the optional slot like every other branch. [ADR 164](../adr/164-a-value-coerces-into-a-nullable-column-and-an-error-union-does-not.md)
9. **A Row can have a field that no column holds.** `nilo_beside` names fields that are on the Row, in its JSON and in its document, but never in a statement: no `SELECT` list reads one, no `.where`/`.order`/`.set`/insert may use one, the migrator ignores it, and every read leaves it at its default for you to fill from another source. [ADR 178](../adr/178-a-row-can-carry-a-field-no-column-holds.md)

## Decisions

| ADR | What it decides |
|---|---|
| [045](../adr/045-an-array-is-a-slice-and-a-slice-is-one-deep.md) | A list column is a plain slice, checked exactly against the array's element type |
| [049](../adr/049-a-column-type-can-come-from-outside-this-module.md) | The `nilo_column`/`nilo_read`/`nilo_write` protocol, text on the wire, and `AsText` as its simplest use |
| [067](../adr/067-a-value-is-whatever-the-database-stores.md) | Storage form is declared per Dialect (`Uuid`, `Json`/enum, `Timestamp`, `.in`), not assumed from the field type |
| [094](../adr/094-a-null-is-refused-by-both-wires-or-by-neither.md) | A NULL in a non-optional field is `QueryFailed` on both Wires, never a zero or empty string |
| [139](../adr/139-a-key-is-as-many-columns-as-it-takes.md) | `.key` is a tuple of column names; the call site uses a named struct, never positions |
| [141](../adr/141-bytes-are-a-type-not-a-second-protocol.md) | `sql.Bytes`, kept separate from text because the two Wires read binary and text columns differently |
| [164](../adr/164-a-value-coerces-into-a-nullable-column-and-an-error-union-does-not.md) | `forWire` unwraps a column type's error union with `try` so its payload converts into an optional column |
| [178](../adr/178-a-row-can-carry-a-field-no-column-holds.md) | `nilo_beside`: a field on the Row, in the JSON and the document, but in no statement |

Related topics: [ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md), whose topic is [sql-migrations](sql-migrations.md), decides the marker's two kinds of word and also holds the rule for `sql.Date`: read from the column instead of a `::text` cast, stored as a day count on Postgres and ten ISO characters on SQLite. A document field's own JSON shape (`sql.Json(T)` as a document rather than a wrapped value) is [ADR 163](../adr/163-a-document-is-its-value.md). A type that can also be parsed from a path or query param, which is what lets `Timestamp` round-trip a keyset cursor, is [ADR 113](../adr/113-a-path-param-can-parse-itself.md) and [ADR 127](../adr/127-what-a-server-prints-it-can-read.md). A moment kept as a Unix-seconds or Unix-milliseconds integer is `sql.UnixSeconds` or `sql.UnixMillis`, the unit in the type, decided in [ADR 067](../adr/067-a-value-is-whatever-the-database-stores.md). A view's columns answering `UNKNOWN` and being skipped by the startup check is [ADR 050](../adr/050-a-view-or-a-rowid-alias-is-not-a-nullable-column.md). The trade-off budget every one of these ADRs is measured against is [ADR 017](../adr/017-the-trade-budget-has-four-axes.md).

## Open questions

- **Storing `Timestamp` as text on SQLite.** Reading RFC 3339 text back needs a parser, which now exists (`Timestamp.nilo_parse`, built for ADR 127), but no `time_form` has been built. A program that wants text timestamps on SQLite today uses `sql.AsText("timestamptz")`. Recorded in [ADR 067](../adr/067-a-value-is-whatever-the-database-stores.md) and open in [`docs/todo.md`](../todo.md).
- **An array of a declared column type**, such as `[]const Decimal`. It is not checked by `accepts` and cannot be read; writing one works through `arrayOf`. Named as still unsupported in [ADR 049](../adr/049-a-column-type-can-come-from-outside-this-module.md).
