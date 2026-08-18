# 0078 — a uuid is whatever the database stores one as

**Status:** accepted
**Amends:** [ADR 0073](./0073-a-file-has-no-socket-to-wait-on.md)

## Context

`guide/sql.md`'s SQLite section opens with a promise:

> Swap two lines and the rest of this page is unchanged. Your handler does not
> change at all.

A Row with `public: sql.Uuid` — the type `nilo_sql` exports, the one ADR 0042
moved down a layer so that generating a key and reading a column are one value —
did not build against it:

```
zig-pkg/zqlite-…/src/conn.zig:399:21: error: Pass a string slice, rather than an
array, to bind a text/blob. String arrays will be supported when
https://github.com/ziglang/zig/issues/15893#issuecomment-1925092582 is fixed
```

That is **zqlite's** `@compileError`, three layers below anything the
application wrote, naming a Zig issue. Nothing in it says `Uuid`, says SQLite is
the problem, or names a route out. In a repository whose `refusals/` directories
exist so that 129 mistakes get a message nilo wrote, this one got a message a
vendored library wrote about a compiler bug — on the most ordinary column in a
modern schema, in the module the reference recommends for public ids.

**And the two halves of `sql/` already disagreed about the column.**
`dialect.acceptsSqlite` routes a type with a `declaredColumn` — which `Uuid`
has, `"uuid"` — to `&.{ "TEXT", "VARCHAR", "CLOB" }`. So the schema check wanted
TEXT while the wire was trying to send sixteen raw bytes. Even with the bind
fixed, one of the two had to move.

The cause was one line: `WireWrite` mapped a `Uuid` to `[Uuid.byte_len]u8`, a
Zig **array**, for every Wire. pg.zig binds arrays; zqlite refuses them while
compiling.

A second thing was found beside it and is here because the fix is the same
shape. There is no migration runner — a decision, and a defensible one: a Row
cannot declare an index or a constraint, and one that could would be a migration
file in disguise. So `CREATE TABLE` is the application's job and `db.raw` was
the only door, and `raw`'s first argument is a Row:

```zig
_ = try db.raw(Account, run, "CREATE TABLE IF NOT EXISTS accounts (…)", .{});
```

Passing the Row of the table *being created*, which returns no rows and is only
there to satisfy the check. That reads like a mistake and was the recommended
path by elimination. Every SQLite application hits it, because there is no
server to have run the DDL elsewhere.

## Decision

**A `Uuid` travels as whatever its Dialect says the database stores one as.**

`dialect.UuidForm` is `.bytes` or `.text`; Postgres declares `.bytes`, SQLite
declares `.text`, and `assertDialect` now owes it like every other piece. On the
write side `WireWrite` reads the Dialect and answers `[16]u8` or `[]const u8`;
the text is kept in the Scope's arena, because the tuple the driver reads from
outlives the call that built it, which is the same reason Postgres binds an
array rather than a slice.

That meant threading the Dialect through `WireWrite`, `Values`, `BatchWrite` and
`BatchValues` — four comptime functions that took only the field type. It is a
wider signature for one type's sake, and the alternative was worse: a Wire-level
conversion would put a column type's knowledge inside a driver file, which is
the line ADR 0039 drew.

**On the read side there is no Dialect at all**, and that is deliberate.
`uuidOf` takes sixteen bytes *or* thirty-six characters, because the two lengths
cannot be confused and a Wire-specific reader would make one column read two
ways for no gain.

Text is the right shape for SQLite beyond making it compile: `sqlite3` shows the
id, `WHERE public = '…'` is typeable, and every SQLite uuid convention in the
wild is the hyphenated string.

**And `db.exec(c, sql, values) !usize`** — a statement that answers with
nothing, and the rows it changed. `CREATE TABLE`, `CREATE INDEX`, `PRAGMA`,
`VACUUM`, `ANALYZE`, a hand-written `DELETE`. It is a few lines over the Wire
call `raw` already makes, with no row filling, and it removes the one place in
this module where a caller passes a type it does not mean. `tx.exec` is the same
call inside a transaction, which is where a migration that has to be all or
nothing puts it.

## What this changed about how the module is tested

Everything in `db.zig` ran against `wire.Fake`, and that is most of the point:
the same code serves both Wires and a fake proves it with no database anywhere.
**Neither of these two could be found that way.** A fake has no opinion about
whether zqlite will bind an array, and no opinion about a call that does not
exist.

So `db.zig` gained three tests over a real in-memory SQLite database — a `Uuid`
written, read back *by* the uuid, and read out again as text to confirm the
storage form; the schema check agreeing with the wire about the same column; and
`db.exec` counting rows and running inside a transaction. They cost about a
second and they are the only tests in the file that could have caught this.

## What was rejected

**A Refusal naming the dialect**, which is what the finding asked for: five
things SQLite refuses each get a message nilo wrote, and a sixth would have been
consistent. It is the right shape for something that cannot work, and this
could — a uuid in a TEXT column is what SQLite users already do.

**Sixteen bytes in a BLOB column.** It would have kept one wire format and cost
the schema check its agreement, `sqlite3` its readability, and the id its
typeability. The bind would still have needed a slice, so it is the same change
with a worse column.

**An application-supplied column type**, which is what the application that
found this shipped: thirteen lines of `nilo_column` / `nilo_read` /
`nilo_write` storing the hyphenated text (ADR 0055). It works, and it is the
documented escape hatch used for something that should not have needed one.

## What it costs

Nothing on any of the four axes for a Postgres program: `WireWrite` answers what
it always answered, and the Dialect parameter is comptime.

A SQLite program pays one arena `dupe` of thirty-six bytes per uuid parameter,
inside a request that was already going to allocate. Twenty extra bytes per uuid
in the file, against sixteen in a BLOB, which is the price of a column a person
can read.

`zig build size-sql` is unmoved: 1,677,464 and 2,202,304, a difference of
524,840.
