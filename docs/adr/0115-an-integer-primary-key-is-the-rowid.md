# 0115 — an INTEGER PRIMARY KEY is the rowid, not a column that may be null

**Status:** accepted
**Amends:** [ADR 0056](./0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md)

## Context

The most ordinary SQLite table there is stopped the server:

```
INTEGER PRIMARY KEY            -> 1 problem(s)
INTEGER PRIMARY KEY NOT NULL   -> 0 problem(s)
nilo_sql: nilo: Event.id is not optional, but events.id may be null
```

`schema_mismatch_is_fatal` defaults to **true**, so that first line is
`nilo_start` returning `error.SchemaMismatch` against a table that is correct.
The first spelling is what every SQLite tutorial, every migration tool and
SQLite's own documentation writes.

The cause is one reading of one column. SQLite reports `notnull = 0` in
`pragma_table_info` for an `INTEGER PRIMARY KEY`, and it means *there is no NOT
NULL clause here* rather than *this may be null* — the column is an alias for
the rowid, which never is. `dialect.SQLite.introspect` read anything that was
not `notnull = 1` as nullable, `schema.compare` reported `unexpected_null`
against a Row whose `id` is an `i64`, and the server refused to start.

`dialect.zig` twice calls a check that fails on a correct schema "the fastest
way to teach somebody to switch it off". This was one.

**It survived because the suite's own fixture walks around it.** `accounts_ddl`
in `sql/db.zig` says `id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL`, and the
redundant `NOT NULL` makes the one SQLite schema-check test pass. A fixture
written in the spelling nobody uses is a test of a path nobody takes.

## Decision

**The introspection query answers `NO` for a column that is the rowid**, and it
decides that by SQLite's own rule rather than by an approximation:

```sql
WHEN i.pk = 1 AND upper(i.type) = 'INTEGER'
     AND (SELECT count(*) FROM pragma_table_info(?1) k
          WHERE k.pk > 0) = 1 THEN 'NO'
```

Each of the three conditions is load-bearing:

- **`pk = 1` and exactly one primary-key column.** A rowid table's *composite*
  key may hold a NULL in any of its columns — the long-standing quirk — so
  `PRIMARY KEY (tenant_id, id)`, which is what every multi-tenant schema is,
  has to keep answering `YES`.
- **The declared type is exactly `INTEGER`.** Not INTEGER *affinity*: `INT
  PRIMARY KEY` and `BIGINT PRIMARY KEY` share the affinity, are not aliases,
  and really do accept a NULL. SQLite's rule is the spelling, which is both
  narrower and simpler than the affinity rule the roadmap entry proposed.
- **Not a view**, which the branch above already answered. The rowid test sits
  *behind* the view test so a view over an aliased column keeps answering
  `UNKNOWN` (ADR 0056).

A non-integer primary key keeps the old answer, and that is right: SQLite
really does allow NULLs in a `TEXT PRIMARY KEY`.

**`sqlite.Wire.columnsOf` now qualifies every occurrence of
`pragma_table_info`, not the first.** The query names it twice, and the rewrite
that put the schema in front of whichever came first in the text would have
asked the attached database for the columns and `main` for the key — one
question answered by two databases.

## What was rejected

**Matching INTEGER affinity**, which is what the roadmap entry suggested and
what a reader reaches for first. It says `NO` for `INT PRIMARY KEY`, which
accepts a NULL, so it trades a check that fires wrongly for a check that
silently does not fire. The exact spelling costs nothing and is the actual rule.

**Asking `pragma_index_list` whether a `pk`-origin index exists**, which would
make the rule exact for `PRIMARY KEY (id DESC)` as well — not an alias, and this
answers `NO` for it. It is a second table-valued function to schema-qualify for
one exotic spelling, and the error it leaves is a check that does not fire
rather than one that fires wrongly. Written down here rather than built.

**Making `schema_mismatch_is_fatal` default to false**, which would have turned
this failure into a warning. That is treating the symptom, and it gives up the
property the check exists for.

## What it costs

One correlated subquery over `pragma_table_info`, **once per Row while the
server starts**. Nothing per request, nothing per connection, nothing at run
time. `columnsOf` deliberately keeps no plan for this statement.

The rewrite buffer in `columnsOf` went from 512 to 1,024 bytes of stack, on a
function that runs at startup.

## What holds it

`sql/sqlite.zig` asks `dialect.SQLite.introspect` directly, across five
spellings: the alias inline and as a one-column tuple, an ordinary column
beside it, `INT PRIMARY KEY`, a composite key, and a view. `sql/db.zig` has the
end-to-end half — `checkSchema` answering zero problems for the table that used
to stop the server.

The negative half is one layer down on purpose: `checkSchema` reports a problem
with `std.log.err`, and the test runner counts a logged error as a failure.
That is the same reason `db.wireOf` warns rather than errs.
