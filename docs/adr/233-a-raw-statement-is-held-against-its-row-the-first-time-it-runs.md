# A raw statement is held against its Row the first time it runs

**Status:** accepted
**Topic:** [sql-raw](../design/sql-raw.md)
**Extends:** [ADR 051](051-a-statement-that-is-a-constant-can-be-prepared-once.md)

A raw statement's text is comptime, and `rawcheck` holds its `SELECT` list
against the Row while compiling: how many columns, and the name of each one
that plainly has a name ([ADR 051](051-a-statement-that-is-a-constant-can-be-prepared-once.md)).
That is all a comptime pass can do, and when it is unsure it passes: a name
is claimed only for a bare path or an `AS name`, an unquoted one is folded to
lower case as Postgres does, and text it cannot finish (an unterminated quote)
is not read at all. What a column *is* belongs to the
database: its type, and whether it can be NULL. ADR 051 left the type to
`db.checking`, and `db.checking` holds tables, not statements, so for a raw
statement nothing held either. The type was found by the first row that read
it, and the NULL by nothing at all.

nodeflux-os asked for it as item 94, after the data bugs of its port turned out
to live in raw statements. The one that took a page down was a feed: a
`LEFT JOIN LATERAL` reading the title of an event's subject into a field that
was not optional. It worked on every row until the day a subject was deleted,
and then the whole feed was a 500.

## Decision

**The first time a raw statement runs in a process, the Wire is asked what the
statement answers without running it, and the answer is held against the Row.**
Every call after that costs one atomic load.

- **In a test binary a misfit fails the statement** with `error.QueryFailed`,
  and the warning says what does not fit and how to fix it. The suite is where
  the mistake is cheap, and every raw statement a test reaches is checked there.
- **In a server it is a warning, once, and the statement runs.** A column that
  *may* be NULL still has every row that is not, and a page that worked
  yesterday does not stop today because a check found out what could happen.
- **No option turns it off**, for the reason `checkSchema` has none: a switch
  that turns a check off is a place to hide from what it found.

```
nilo_sql: `db.raw` into feed.Card does not fit what the statement answers:
  column 3 fills `title`, which is not optional, and comes from the side of an
  outer join that may find nothing, where it is NULL. Make the field optional,
  or `coalesce` the column.
  column 5 fills `n`, which reads int4, and the statement answers int8 there.
  Cast the column in the statement, or change the field's type.
  The statement: SELECT …
```

It is `db.raw`, `rawOne`, `rawExactlyOne`, `rawOrdered`, `rawPage` and
`rawPageOrdered`; a paged statement's `count(*) OVER ()` is held to `i64` like
a column. The `{order}` an `Ordering` fills changes nothing a column is, so an
ordered statement is checked once whatever order the request chose.

### Why at the first run and not while starting

A startup check would need the list of raw statements, and there is no list:
Zig cannot enumerate the call sites of a function, and a registry built by the
calls themselves is empty until they run. A statement also cannot be described
before there is a connection, and a raw statement has no table for
`db.checking` to be given. So the check sits where the statement is: in the
call, behind a flag of its own.

The flag is one per statement, Row and call, and it is a `var` in a struct the
call declares. **That struct has to name what it is for.** Zig gives a struct
declared in a generic function one type for every instantiation that captures
the same values, so a struct that named none was one flag for the whole
program, and the first raw statement to run was the only one ever checked. The
Fake-backed test that asks two statements in a row is what caught it.

**The flag stays set only once `describe` has answered.** It used to be taken
before the question was asked, so a first run that met a table a migration had
not made yet, or a pool with nothing in it, spent the one check and left the
statement unchecked for the life of the process. A `describe` that fails puts
the flag back, and the next run asks again; that costs a round trip only while
the statement beside it is failing too. The warning that it could not be asked
is said once per statement, however often it is asked again.

### The types: what the driver will read, not what the table accepts

On Postgres the types are the OIDs the statement's description answers with,
which is what pg.zig reads before every statement it binds; one more round trip
turns them into names. A domain is named by the type under it, because that is
what arrives. A type in the string category, and an enum, is marked
**textual**: pg.zig asks for a type it has no decoder for in binary, and a
string's binary form is its text, so a text field reads a `citext`, a domain
over `text` or an enum's label whatever the type is called.

The list a field is held to is `Dialect.reads`, not `Dialect.accepts`.
`accepts` is about a table a Row both reads and writes, and lets an `i32` stand
over an `int8` column, which the Postgres Wire reads range-checked. `reads`
takes a number column as wide as the field or narrower, and no wider: a
narrower one widens without a value that can fail to fit, and a wider one is a
read that works until the day a value passes the field. That is the mistake a
raw statement makes most: `count(*)` is `int8`, `sum` of an `int8` is
`numeric`, and neither is safe in the field it usually goes into. A text
column (`Decimal`, `Interval`, an `AsText` type) is `text` in `reads`, because
a raw statement asks for it as `::text` ([ADR 124](124-a-raw-statement-cannot-cast-what-it-did-not-write.md)).

On SQLite the type is the **affinity** of the column's declared type, by
SQLite's own substring rule, and nothing for an expression. zqlite converts on
the way out, so very little fails there; what is caught is the read that
answers wrong without failing: a `Str` over an `INTEGER` column hands back the
digits, a number over a `TEXT` column hands back zero.

### The NULLs: the plan says which join's far side a column came from

Postgres does not say which columns of an answer may be NULL. The description
has a type and a source column, and a `NOT NULL` column read through the far
side of a `LEFT JOIN` still names its table. **The plan says it.** `EXPLAIN
(VERBOSE, FORMAT JSON)` lists every node's output as the expressions it
computes and every join's type, so a column the top of the plan hands on from
the inner side of a `Left` join, the outer side of a `Right`, or either side of
a `Full` is NULL on the rows that found nothing. `sql/plan.zig` reads it, and
is tested on plans a server answered.

The plan has to be one that holds for every value. So the statement is
prepared under a name, with `plan_cache_mode = force_generic_plan` set for the
transaction, and explained with every parameter NULL. A custom plan could use
the value to drop a join; a generic one cannot. The name is dropped before the
transaction is rolled back, since a `PREPARE` outlives a rollback and, behind a
pooler in transaction mode, a statement sent after the `ROLLBACK` is a
transaction of its own that may reach another server connection and leave the
name behind. A transaction the `EXPLAIN` aborted refuses the `DEALLOCATE`, and
it is sent again after the `ROLLBACK`, on the same connection. Five round
trips, planning only, once.

**Only what is certain is said.** The planner has already turned an outer join
into an inner one wherever a condition throws the NULLs away (`WHERE s.id >
$1`), so a join still `Left` in the plan is one whose NULLs reach the answer,
and `($1 IS NULL OR s.id = $1)`, which keeps them, stays `Left`. An expression
is not judged, and `coalesce` is one. A column renamed by a subquery or a CTE
scan is not followed. A `UNION` is read by position, because an `Append` names
its columns after its first branch. A column a `LATERAL` repeats from its outer
row (`e.kind` inside it, the same `e.kind` beside it) is judged by the side
that always has a row. In every doubtful case the answer is "cannot say", which
is read as "not NULL": a column missed is a check that did less, and a column
wrongly called NULL fails a statement that works.

### What is not checked

- **A raw statement inside a transaction.** `describe` takes a connection of
  its own. A transaction holding SQLite's writer, or the last connection of a
  small pool, would wait on itself; running it on the transaction's connection
  would put a failed prepare inside somebody's transaction. The same statement
  outside one is checked, and most are.
- **`db.composed`.** Its text is the request's, so a flag per statement would
  be a flag per request.
- **A NULL that is in the table rather than made by a join.** The plan's scans
  name their tables, so a nullable column could be found; but a nullable column
  is read into a non-optional field on purpose under `WHERE x IS NOT NULL`,
  and that condition stays a filter on the scan, which the join rule never has
  to read. Calling that column NULL would fail a correct statement. It fails at
  the row, as before, with the message ADR 050 wrote for it.
- **NULLs on SQLite.** It has no plan that names a join's far side.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | None after the first call of each statement: one atomic load. The first allocates the description, the plan's text and its parsed tree in the Scope's arena. |
| Memory per idle connection | Zero. Nothing is kept on an HTTP connection; on a database connection the prepared name is dropped before it goes back. |
| Throughput and p99 | None after the first call. The first call of each statement pays five round trips on Postgres, planning only, and one prepare on SQLite. |
| Binary size | +0 on a program with no raw statement, and on `hello` and `rest`, which have none. On a program whose one route is a `db.raw`: **+30,864 B** on Postgres (the plan reader, the two catalogue reads and the warning) and **+10,816 B** on SQLite, stripped `ReleaseFast`, against the same programs built from the commit before. Each raw statement after the first adds a flag and a call, +368 B over what it cost before ([`bench/result/sql.md`](../../bench/result/sql.md#17-what-holding-a-raw-statement-against-its-row-costs-the-binary)). |

## What was rejected

**Declaring which branch of a `UNION` may be NULL**, a marker on the Row. The
plan already says it per branch, and Postgres refuses branches whose types
differ, so the marker would be the programmer's guess about something the
database can answer.

**Reading `LEFT JOIN` out of the SQL text while compiling.** Whether a join is
still outer after planning is the planner's decision, and a text reader cannot
see `WHERE s.id > $1` turn it inner. It would refuse correct statements, which
is the one thing a check like this cannot do.

**Failing the statement in a server too.** The column is NULL on some rows and
the rows are not here yet. A server that refuses a page that works, because a
check found what *could* happen, has moved the outage earlier and made it
certain.

**An option to turn it off**, or to make the server fail as well. The first is
a place to hide; the second is the paragraph above.

**`accepts` for the types**, which is what `checkSchema` holds a table to. It
lets an `i32` stand over an `int8`, which is the one mistake a raw statement
makes most. **Exact widths** were the first version of `reads`; once the Wire
read any integer column into any integer field range-checked, refusing an
`int4` into an `i64` was a check failing a statement that could not fail.

**`std.json` for the plan.** It was the first version and it cost +88,496 B on the Postgres program: an array hash map per object and a float parser for every number, to read four string keys. A reader of its own that skips numbers unread took it to +35,184, and moving the once-only half of the check out of the generic call to +30,864.

**Checking every call.** The description does not change while the process
runs, except under a migration, and a migration is `db.checking`'s and the
stale-plan retry's (ADR 051).

## Consequences

- A Wire owes `describe(arena, sql, nulls)`, answering `?[]const
  wire.Described`; null is "cannot say", which the Fake answers unless a test
  sets `described`. A Dialect owes `reads`.
- `checkSchema`'s `accepts` still lets an `i32` field stand over an `int8`
  column. The Postgres Wire reads it range-checked, so a typed read of that
  Row fails only at a row whose value does not fit, with the column named.
