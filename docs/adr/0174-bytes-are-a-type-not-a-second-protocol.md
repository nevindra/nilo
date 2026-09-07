# Bytes are a type, not a second protocol

Nothing anywhere answered `bytea`. `Postgres.accepts` gave `text`, `varchar`,
`bpchar`, `char` and `name` for a `[]const u8`, so a Row could not read one.
SQLite was the same the other way round: `acceptsSqlite` already listed `BLOB`
among what a byte slice may read out of, and nothing could ever *write* one,
because `WireWrite` sent a `[]const u8` as text and zqlite needs its `Blob`
wrapper to do anything else.

A file hash, a sealed token, a signature, an encoded document. The roadmap
called it *the most ordinary column this module cannot name*, and it was right.

The way out was `sql.AsText("bytea")` through Postgres's hex printing, which
costs a conversion each way — and which nothing anywhere pointed at.

## Why it looked like a protocol problem

The roadmap's blocker was real and was about the wrong thing:

> The `nilo_column`/`nilo_read`/`nilo_write` protocol
> ([ADR 0055](./0055-a-column-type-can-come-from-outside-this-module.md)) is
> text on the wire by definition, so bytes want a second protocol beside it
> rather than another instance of it.

Both halves are true. The conclusion does not follow, because **the protocol is
for a column type this module has never heard of**, declared by whoever owns it.
Bytes are not that. There is one binary column, both databases have it, and
this module knows perfectly well what it is.

So it is one more type both Wires know by name, the way `Uuid` and `Timestamp`
already are. No new mechanism — one more row in each of the tables that already
exist.

## The type

```zig
pub const Bytes = struct { bytes: []const u8 };
```

```zig
const Doc = struct {
    pub const nilo_table = .{ .name = "docs", .key = .id };

    id: i64,
    digest: sql.Bytes,
};
```

**It lives in `wire.zig` rather than `types.zig`**, because both Wires have to
name it and `postgres.zig` imports that file and not this one. `sql.Bytes` is
the same type under the name a Row writes.

**The type has to survive as far as the Wire, which is the one thing that could
not be skipped.** Text and bytes are the same Zig type and two different
columns, so `WireRead` flattening a `Bytes` to `[]const u8` would leave the Wire
unable to tell which read to make — and on SQLite the two reads are
`sqlite3_column_text` and `sqlite3_column_blob`, which are not interchangeable.
Asking for a BLOB as text makes SQLite convert the column in place, which
changes what a pointer taken earlier points at and reads the bytes as though
they were characters.

## What each side needed

**Postgres: a cast, and nothing else.** pg.zig binds a `[]const u8` and
Postgres infers `text` for the parameter, so without `::bytea` an insert is
*column is of type bytea but expression is of type text* — at run time, from
the database, about a statement that looks right. `readAs` deliberately does
**not** add `::text` for this one type: that is the cast every other declared
column gets, and here it would hand back Postgres's `\x…` hex printing and lose
the point of the column.

**SQLite: the wrapper zqlite compares by identity.** `zqlite.Blob` is a struct
holding a slice, and a structurally identical type of nilo's would bind as text
and store the bytes in a TEXT column that reads back looking almost right. So
`sqlite.zig` — the only file allowed to name zqlite — converts the parameter
tuple before binding, once at the top of `stmtOn` rather than at the four
`bind` calls under it. It answers the caller's own tuple type when nothing needs
converting, which is every statement carrying no binary column, so this costs
nothing to the programs that do not use one.

## What it costs

**One arena copy per row that reads one**, which is the same one copy a text
column already pays. What the Wire hands back points into the driver's read
buffer and dies at the next row, so a `Bytes` that outlives the read is a
`Bytes` that was copied. There is no version of this that is free, and saying
so is better than a name that promises otherwise — the same rule `Str` follows.

Against ADR 0018's other three axes: zero. Nothing on a connection, nothing on
the request path for a program with no such column, and the whole of the
dialect half is comptime.

## What is verified, and what is not

**Verified against a real database**: the SQLite half, end to end, in
`sql/migrate_live.zig`. A value holding a NUL in the middle, a byte no UTF-8
decoder accepts, and a `%` goes in and comes back byte for byte — through
`RETURNING` and through a separate `find` — and the generated `BLOB` column
passes the startup check against itself.

**Not verified against a real database**: the Postgres half. The read is
pg.zig's own `[]const u8` for a `bytea` column, which its test suite covers,
and the write is the `::bytea` cast. Both are the same shape `Uuid` already
takes. It is written down here rather than left implied, because a claim with
no run behind it is what this repository has been wrong about four times.

## Consequences

- `types.isBytes` is asked **before** `declaredColumn` and before the pointer
  branch in every `accepts`, because both of those answer `text` for it — which
  is the whole reason a binary column could not be named until this type
  existed.
- A batch sends `bytea[]`, so `insertMany` carries the column on Postgres. On
  SQLite a batch is already a Refusal for every column type.
- `sql.AsText("bytea")` still works and is now the wrong answer. The reference
  says which to reach for.
