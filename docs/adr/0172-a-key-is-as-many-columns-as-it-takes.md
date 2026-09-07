# A key is as many columns as it takes

`row.keyOf` answered one column name. `statement.find` wrote one `=` against
it, `updateMany` joined on it, and `ddl.columnClause` put `PRIMARY KEY` on it.
So a table keyed `(tenant_id, id)` had no `db.find` and no batch update at all,
and reached `db.one` with the condition written out at every call site.

**That is not an edge case.** Every multi-tenant table is keyed that way, and so
is every join table — `(partner_id, capability)`, `(user_id, role_id)`. The
roadmap entry said *Waiting on: ready* and named a caller whose join tables are
exactly that shape.

## The spelling

```zig
pub const nilo_table = .{ .name = "seats", .key = .{ .tenant_id, .id } };
```

A tuple of column names, which is **the spelling `conflictColumns` already
reads** for an upsert target. One way to name a set of columns in this
repository, not two. `.key = .id` still means what it meant, and `.key = .{.id}`
is the same key written the long way — it still reaches the callers that can
only mean one column, so the two spellings are one key rather than two shapes.

## The call site

```zig
db.find(Seat, c, .{ .tenant_id = tenant, .id = id })
```

**A struct rather than a tuple, and that is the whole DX argument.** A tuple
would be positional, and both columns of `(tenant_id, id)` are `i64` — so the
two written the other way round is a statement that compiles, runs, finds the
wrong row and reports nothing. Named fields make it a Refusal at `zig build`,
which is what every other option struct in this module already buys.

Three Refusals go with it, and each is a statement that would otherwise have
run:

- **A column left out.** It would match every row sharing the rest of the key,
  and `LIMIT 1` would answer with whichever the database reached first — right
  most of the time, and wrong under exactly the load nobody reproduces.
- **A tuple where the key goes**, for the reason above.
- **A column that is not part of the key.** A find identifies one row by its
  key; narrowing on another column is `db.one`, and the message names it.

The conditions are numbered in the **key's** order rather than the caller's, so
two call sites writing the fields the other way round compile to one statement
and prepare under one name.

## The DDL is where the shape actually changes

`keyColumn(quoted, type, generated)` writes `PRIMARY KEY` onto one column, and
there is nowhere on a column to say *and that one too*. So a key of several
columns is a **table constraint**: its columns are written as ordinary
`NOT NULL` columns and `PRIMARY KEY ("tenant_id", "id")` goes on the end. Both
databases take the same text, which is why this needed no Dialect declaration.

The order is the marker's, and it is not decoration: it is the order of the
index the constraint creates, and therefore which prefix of the key a lookup can
use.

**A composite key is never generated**, and that is a rule rather than a
limitation. A sequence fills in one column; a key spanning two is made of values
the program already holds — a tenant and an id, two sides of a join — so there
is nothing for the database to invent. On SQLite it matters more than it
sounds: `INTEGER PRIMARY KEY` there is the rowid alias
([ADR 0115](./0115-an-integer-primary-key-is-the-rowid.md)), so writing it on
one column of a composite key would be a second, contradicting key.

## The snapshot format changed, and this is the notice

`table.Desc.key: []const u8` became `Desc.keys: []const []const u8`, so the
`.zon` snapshot says `.keys`. **A file written by an older `generate` no longer
parses.** The fix is `db generate`, which rewrites it from the types — the same
thing that fixes every other snapshot disagreement, and a loud recoverable
failure rather than a quiet wrong one.

The alternative was keeping `key` beside a new `keys` so old files kept
parsing. That is two fields saying the same thing for the ordinary Row, with a
sentinel deciding which to believe, and it is the shape that goes wrong the
first time somebody reads the wrong one.

## Against ADR 0018's four axes

Zero on all four. `keysOf` answers a comptime slice, the extra `AND` is comptime
string concatenation, and nothing about it exists at run time. The parameter
tuple grows by one field per key column, which is a statement carrying one more
`i64` — the same cost as a condition on one more column, because it is one.

## Consequences

- `row.keyOf` is now a Refusal on a composite key rather than a silent first
  column. Picking `tenant_id` out of `(tenant_id, id)` and calling it the key
  would find the wrong row and report nothing.
- `upserting` leaves **every** key column out of the `DO UPDATE SET` list, where
  it used to leave out the first. That was a real hole: on a composite key the
  second column was being written to the value it was matched on.
- `updateMany` joins on one `AND` per key column, which is the whole of what a
  composite key costs a batch.
- A key naming the same column twice is refused. `PRIMARY KEY (id, id)` is a
  syntax error from the database rather than from here.
