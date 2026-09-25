# Past one table

What `nilo_sql` writes for you is one table, the parents its references
point at, the children that point back, and sums by group
([a Row with more in it](./shapes.md)). This page is the way past that:
`raw`, and the three shapes it takes. It follows [reading](./reading.md).

A join through a condition rather than a reference, `DISTINCT`, window
functions, CTEs, unions, an aggregate over an expression: none of them. Past
what a Row can declare, the answer is `raw`:

<!-- compiles: body -->
```zig
const Tally = struct {
    // A shape no table has: `raw` fills it, and nothing builds or checks it.
    pub const nilo_table = .projection;

    country: nilo.Str,
    n: i64,
};

const tally = try db.raw(Tally, c,
    "SELECT u.country, count(*)::bigint AS n FROM users u " ++
    "JOIN orders o ON o.user_id = u.id GROUP BY u.country",
    .{},
);
```

`raw` still fills your struct, still uses the arena, still follows the `Str`
rule. The `SELECT` list is counted against the struct's fields while
compiling, and a column that plainly has a name is held against the field in
its position ([ADR 051](../../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md));
what it gives up is nilo writing the text, and nothing else.

It is still a **Row**, so it still carries a `nilo_table`, and
`.projection` is the one that says it owns no table. Naming a table it does
not have would put it in front of the schema check and the migrator, which
would look for `country_tally` and find nothing. A Row that *is* a table's
columns, or a view's, names it as usual, and `raw` fills that one the same
way.

**And the Row can carry what the program adds to it.** A line on a page
sometimes holds a field no column has — a comment and its files, read in a
second statement or handed over by a service. `nilo_beside` names such
fields: they are on the Row, in its JSON and in its document, and in no
statement, so the `SELECT` list is counted against the columns and a read
leaves them at their default for you to fill
([ADR 178](../../adr/178-a-row-can-carry-a-field-no-column-holds.md)):

<!-- compiles: body -->
```zig
// Attachment: the file's Row, and attachmentsOf(c, id) the second read.
const Line = struct {
    pub const nilo_table = .projection;
    pub const nilo_beside = .{.attachments};

    id: i64,
    body: nilo.Str,
    attachments: []const Attachment = &.{},
};

const lines = try db.raw(Line, c, "SELECT id, body FROM comments ORDER BY id", .{});
for (lines) |*line| line.attachments = try attachmentsOf(c, line.id);
```

A list the **database** can build is still `sql.Json(T)` with `jsonb_agg`
in the statement — one round trip, and the document says `T`. The column is
parsed by `std.json` into `T`'s field names **as written**: a `rename_all`
on `T` spells the response and not the column, so the `jsonb_build_object`
names `content_type` and the wire says `contentType`, from one type.

## What a parameter may be

The values are a tuple, one per placeholder, and the placeholders are `$1`,
`$2`, … in the text: `$n` is the `n`th value, wherever in the statement it
appears, and a `$n` written twice is one value. The text is comptime, so the
count is checked while compiling: a statement naming `$3` and handed two
values is a Refusal, not a run-time error on one database and a silent NULL
on the other ([ADR 204](../../adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)).

A parameter is anything a column takes, converted the way a Row's field is
written: an integer or a float, a `bool`, `[]const u8`, a `nilo.Str` as it
is (no `.bytes()`), an enum (its tag name goes), `sql.Timestamp` (its
microseconds), `sql.Date`, `sql.Uuid`, `sql.Json(T)`, `sql.Bytes`. A
literal `1` or `"open"` is fine in the tuple; a comptime value is given a
run-time type before it goes.

**An optional binds NULL when it is null**, and that is how a filter a
screen may or may not have set reaches a statement you wrote. The
`IS NULL` guard is the `sql.given` of raw SQL, spelled where the database
can see it:

<!-- compiles: body -->
```zig
const Open = struct {
    pub const nilo_table = .projection;

    id: i64,
    name: nilo.Str,
};

const found = try db.raw(Open, c,
    "SELECT o.id, u.name FROM orders o JOIN users u ON u.id = o.user_id " ++
    "WHERE o.status = 'open' AND ($1 IS NULL OR u.name ILIKE $1) ORDER BY o.id",
    .{search},
);
```

With `search` absent, `$1` is NULL, the first arm is true and every open
order comes back; with it set, the second arm filters. One statement, one
plan, and the same text on both databases.

A list written where it is used, `&.{ 1, 2, 3 }`, binds as an array for
`= ANY($1)`, which is Postgres's shape and not SQLite's; a named struct of
values is left to the driver, which is zqlite's `:name` binding
([ADR 116](../../adr/116-a-raw-parameter-is-converted-the-way-a-rows-is.md)).

## One column, no Row

A statement that answers one column — a name off the catalogue, an id, a
count — has no shape worth a struct. Hand `raw` the column's type instead of
a Row and it reads column one of every row
([ADR 125](../../adr/125-a-row-that-owns-no-table.md)):

<!-- compiles: body -->
```zig
const names = try db.raw([]const u8, c, "SELECT name FROM pragma_table_info('downloads')", .{});
const newest = try db.rawOne(i64, c, "SELECT max(id) FROM comments", .{});
```

`[]const u8`, `i64`, `?bool`, a `nilo.Str` — any one thing a column can be
read as, or an optional of one — and the value goes through the same read a
Row's field does, so a `Str` is the Scope's and a slice is kept in the
arena. `rawOne` is the same with the unwrap done. A `SELECT` list of two
into a scalar is a compile error, the way a short list into a Row is: the
statement is still counted.

## Reporting statements

Aggregates are most of what a dashboard reads. A count, a sum, a min, a
max or an average over a column, grouped by columns and parents, is a
[grouped Row](./shapes.md#a-group), and a total over everything is
`db.exactlyOne`. What is left for `raw` is a report those cannot say: a
`FILTER`, a `coalesce`, an expression inside the aggregate, a join no
reference names. Three shapes come up, and each has a call:

**A statement that always has one row.** `SELECT count(*), sum(total) FROM
invoices` answers one row whatever is in the table, and so does `RETURNING`
on a keyed write. `rawOne` would hand back a `?Row` for a null that cannot
happen; `rawExactlyOne` answers the Row, and a statement that answered with
none is `error.QueryFailed` rather than a zero-filled struct
([ADR 206](../../adr/206-a-statement-that-always-answers-answers-a-row.md)):

<!-- compiles: body -->
```zig
const Totals = struct {
    pub const nilo_table = .projection;

    invoices: i64,
    open: i64,
    paid: i64,
};

const totals = try db.rawExactlyOne(Totals, c,
    "SELECT count(*), count(*) FILTER (WHERE status = 'open'), " ++
    "coalesce(sum(total) FILTER (WHERE status = 'paid'), 0)::bigint FROM invoices",
    .{},
);
```

**A line per group.** A `GROUP BY` answers zero or more rows, so it is
`raw` and a slice, and the Row is the shape of one line. `coalesce` the
sums: `sum` over no rows is NULL, and a field that is not `?i64` refuses
one.

**A paged join.** A join the schema names is [a parent](./shapes.md#a-parent),
and `db.page` pages it. One it does not, or one with a condition in its `ON`,
is this. `db.page` reads the rows and the total in one statement by putting
`count(*) OVER ()` on the `SELECT` list, and a list screen that joins two
tables that way wants the same thing. `rawPage` reads your statement as a
page: the Row's columns, then the window as one more column on the end,
which becomes `.total`. The `ORDER BY` and the `LIMIT` are yours, for the
reason `db.page` requires both
([ADR 205](../../adr/205-a-raw-statement-can-carry-its-total.md)):

<!-- compiles: body -->
```zig
const Line = struct {
    pub const nilo_table = .projection;

    id: i64,
    customer: nilo.Str,
    total: i64,
};

const page = try db.rawPage(Line, c,
    "SELECT i.id, u.name AS customer, i.total, count(*) OVER () " ++
    "FROM invoices i JOIN users u ON u.id = i.user_id " ++
    "WHERE ($1 IS NULL OR u.name ILIKE $1) " ++
    "ORDER BY i.id LIMIT 20 OFFSET $2",
    .{ search, id },
);
```

`page.rows` and `page.total` are what `db.page` answers, and a handler that
returns the `Page(Line)` is described the same way in the document. A
`SELECT` list exactly the Row's width, with no window on the end, is a
Refusal that says what to add.

A list sorted from its headings is `db.rawPageOrdered`: the same statement
with `{order}` where the `ORDER BY` goes, and the `sql.Ordering` value the
request chose as the last argument, the way [`rawOrdered`](./reading.md)
takes it. The rows and the total still come from one statement, so the count
cannot disagree with the page it is printed under.

**Dates in a `GROUP BY` are where the two databases part.** A
`sql.Timestamp` is microseconds since the epoch. Postgres stores it as
`timestamptz` and `date_trunc('month', issued_at)` reads it. SQLite stores
the integer, so a month is `strftime('%Y-%m', issued_at / 1000000,
'unixepoch')`; the [SQLite page](./sqlite.md#dates-out-of-a-timestamp) has
the recipe. Read the group key into a `nilo.Str` and the two spellings fill
the same Row.

## A statement that answers with nothing

`CREATE TABLE`, `CREATE INDEX`, `PRAGMA`, `VACUUM`, `ANALYZE`, a `DELETE` you
wrote by hand — nothing is selected, so there is no struct to fill. That is
`db.exec`, and it answers with the number of rows it changed:

```zig
_ = try db.exec(&run,
    \\CREATE TABLE IF NOT EXISTS accounts (
    \\  id    INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    \\  email TEXT NOT NULL UNIQUE COLLATE NOCASE
    \\)
, .{});
```

**A SQLite application needs this and a Postgres one usually doesn't**: there's
no server to have run the DDL somewhere else, so creating the table is your job
at startup. `tx.exec` is the same call inside a transaction.

The line is drawn there because a builder's dialect surface grows with the
builder, and the statements past it are where databases disagree most. What
the Row can declare is a join the schema already names and a grouping its
fields already say; anything else would be a second query language, and a
boundary you can state in a sentence is worth more than one further out.

## A statement the program cannot write while compiling

`db.raw`'s text is comptime, and the case it refuses is a program assembling
SQL out of run-time strings. One kind of program has no finite set of
statements to write: a query engine, where the tables, the columns and the
aggregates come out of a model that is data. What it never needs is a
run-time *string* in a statement — only names and values — so that is what
`sql.Composed` lets it write, and nothing else
([ADR 208](../../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md)):

<!-- compiles: body -->
```zig
const Line = struct {
    pub const nilo_table = .projection;
    key: ?[]const u8,
    total: i64,
};

var s = db.compose(c);           // spelled for this Db's dialect
try s.text("SELECT ");
try s.ident(dimension);          // a name out of the model; not a name → error.NotAnIdentifier
try s.text(", sum(");
try s.ident(measure);
try s.text(") FROM ");
try s.ident(rollup);
try s.text(" WHERE bucket >= ");
try s.param(1);
try s.text(" AND bucket < ");
try s.param(2);
try s.text(" GROUP BY 1 LIMIT ");
try s.number(limit);

const rows = try db.composed(Line, c, s, .{ from, to });
```

`text` is `comptime`, so a slice that arrived at run time does not compile,
and a `$1` inside it is a Refusal — a placeholder is `param(1)`;
`ident` checks that a name is letters, digits and `_` and writes it quoted;
`param` writes the `n`th placeholder the way the dialect spells it — `$n` on
Postgres, `?n` on SQLite. A statement built where no `Db` is in scope is
`sql.Composed.init(arena, sql.Spelling.of(Dialect))`, and `db.composed`
refuses one spelled for the other dialect. A `Composed` is filled by position
like a `raw` statement, with the run-time width check and the same value
conversion, and its values are counted against its placeholders at run time
(`error.ParamCountMismatch`) the way `raw`'s are while compiling. It runs
unnamed — its text is the model's, not the program's. Reach for `raw`
whenever the statement can be written down.

## What SQLite does differently

The text of a raw statement is yours, so the dialect is yours to write in.
Four things to know when the file is SQLite:

- **`$1`, `$2`, … are the same text on both.** SQLite's own numbered
  placeholder is `?1`, and a `$name` there is a *named* parameter indexed by
  first appearance, so `$2` written before `$1` used to bind the first value.
  nilo respells `$n` as `?n` while compiling for every call that takes
  comptime text, which is `raw`, `rawOne`, `rawExactlyOne`, `rawPage`,
  `rawOrdered`, `rawPageOrdered` and the `Tx` versions
  ([ADR 204](../../adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)).
  `exec` takes its text at run time and sends it as written: write `?1`
  there, or a bare `?`, or a statement with no parameters, which is what
  DDL is.
- **A `Timestamp` is an INTEGER of microseconds**, not a datetime SQLite's
  date functions read directly. Divide by a million and say `'unixepoch'`:
  `strftime('%Y-%m', issued_at / 1000000, 'unixepoch')`. A `Date` is its
  ten characters of text, which `date()` and `strftime` read as they are.
- **Casts are spelled `CAST(x AS INTEGER)`**, and `::bigint` is Postgres.
  A `count(*)` is already an integer on both; a `sum` over an INTEGER
  column is too, and `coalesce(sum(total), 0)` needs no cast.
- **`ILIKE` is Postgres.** SQLite's `LIKE` ignores case for ASCII already,
  and `COLLATE NOCASE` on the column is the durable spelling. `FILTER
  (WHERE …)` on an aggregate and `count(*) OVER ()` both work on the SQLite
  nilo links.

## Set operations are conditions, not a second idea

`UNION`, `INTERSECT` and `EXCEPT` combine two selects with the same column
list — and a Row *is* the column list, so over one table all three are
boolean algebra on the `WHERE` clause:

| SQL | here |
|---|---|
| `… WHERE a UNION … WHERE b` | `.where = .{ .any = .{ .{ a }, .{ b } } }` |
| `… WHERE a INTERSECT … WHERE b` | `.where = .{ a, b }` — fields are ANDed |
| `… WHERE a EXCEPT … WHERE b` | `.where = .{ a, not_b }` |

There is no group `NOT`, and none is needed: every leaf has a negation
(`.ne`, `.distinct_from`, `.not_in`, `.not_like`, and the comparisons negate
each other), De Morgan holds in SQL's three-valued logic, and `.any` nests
inside itself. So `NOT (x AND y)` is `.any = .{ .{ not_x }, .{ not_y } }` and
`NOT (x OR y)` is `.{ not_x, not_y }`.

Over **two** tables, a set operation belongs to the schema rather than to the
call site — write a view and put a Row over it, which has worked since views
were readable:

```sql
CREATE VIEW all_orders AS
  SELECT id, total, placed_at FROM current_orders
  UNION ALL
  SELECT id, total, placed_at FROM archived_orders;
```

([ADR 052](../../adr/052-a-set-operation-over-one-table-is-a-condition.md).)

## Several statements at once

There is no pipelining, and the reason is measured rather than assumed: **a
round trip to Postgres is 24 µs and the query inside it is about 2**, so
latency is the cost and concurrency is what hides it. A server here serves
**215,000 requests a second with a real query in every one**, because a
waiting fiber frees its thread
([ADR 053](../../adr/053-a-round-trip-is-not-the-cost-worth-chasing.md)).

Where several statements really do have to land together, SQL already does it
in one round trip and `db.raw` reaches it:

<!-- compiles: body -->
```zig
const Revoked = struct {
    pub const nilo_table = .projection;

    id: i64,
};

_ = try db.raw(Revoked, c,
    "WITH gone AS (DELETE FROM sessions WHERE user_id = $1 RETURNING id) " ++
    "INSERT INTO audit (kind, ref) SELECT 'session_revoked', id FROM gone " ++
    "RETURNING ref AS id",
    .{user_id},
);
```

Atomic without a transaction, which saves the `BEGIN` and the `COMMIT` too.
Many rows of the same shape is `db.insertMany`, which was always one
statement.
