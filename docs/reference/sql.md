# nilo_sql

One page of [the reference](./README.md): Postgres and SQLite: a Row, a Db, queries, a Tx, migrations.

## `nilo_sql`

A second module, imported separately. A project that never imports it links
none of it ([ADR 037](../adr/037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)).

**Two databases, one API.** `sql.Db` is Postgres and `sql.Sqlite(…)` is SQLite;
everything on the rest of this page is written once and works against either.
[SQLite](#sqlite) says what it takes to open one and lists the five things it
refuses.

```zig
const sql = @import("nilo_sql");
```

### A Row

```zig
const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: nilo.Str,
    age: i32,
    created_at: sql.Timestamp,
};
```

| | |
|---|---|
| `.name` | the table, **written out**. Never guessed from the type name. `"app.users"` is a schema and a table; a bare name is whatever `search_path` resolves to |
| `.key` | the column that identifies a row. Defaults to `id` when there is a field of that name |
| `.managed = false` | this program reads the table and does not build it; the migrator leaves it alone. See [Migrations](#migrations) |
| `pub const nilo_table = Other` | a narrower Row: the same table as `Other`, fewer columns, checked against it while compiling |
| `pub const nilo_table = .projection` | a Row that owns no table at all — the shape `db.raw` fills. See below |
| `pub const nilo_beside = .{ .attachments }` | the fields **beside** the columns: on the Row, in its JSON and its document, and in no statement. See below |
| `pub const nilo_via = .{ .approver = .approver_id }` | on a narrower Row: which column a parent or a list of children follows, when the schema has several or none. See [A parent, children, a group](#a-parent-children-a-group) |
| `pub const nilo_aggregate = .{ .n = .count, .owed = .{ .sum = .amount } }` | on a narrower Row: the fields that are computed, which makes the Row one row per group. An entry may carry a `.where`. See [A parent, children, a group](#a-parent-children-a-group) |
| `pub const nilo_children = .{ .lines = .{ .order = .{ .position = .asc } }, .n = .{ .count = Line } }` | on a narrower Row: a children field's `.order` and `.where`, and a count of the rows pointing back. See [A parent, children, a group](#a-parent-children-a-group) |

#### A Row that owns no table

A window function, a CTE or a join no reference names comes back in a shape no table has.
`.projection` is a Row that says so
([ADR 125](../adr/125-a-row-that-owns-no-table.md)):

<!-- compiles -->
```zig
const Busiest = struct {
    pub const nilo_table = .projection;

    email: Str,
    documents: i64,
};

comptime {
    _ = Busiest;
}
```

It has every column type, every reader and every conversion an ordinary Row has,
and no table, so `db.select`, `db.find`, `db.insert` and the migrator all refuse
it while compiling, naming the type and saying it is a projection. `db.raw` and
`db.exec` are what it is for. Before this the only way to spell such a shape was
to give it a `.name` that pointed at a real table it did not match, which
compiled and then said nothing when somebody wrote `db.select` against it.

#### A field beside the columns

A Row that is the response sometimes carries what the program adds to it —
a comment line and its files, read in a second statement or handed over by
a service. `nilo_beside` names those fields
([ADR 178](../adr/178-a-row-can-carry-a-field-no-column-holds.md)):

<!-- compiles -->
```zig
const Attachment = struct { id: i64, filename: Str };

const CommentLine = struct {
    pub const nilo_table = .projection;
    pub const nilo_beside = .{.attachments};

    id: i64,
    body: Str,
    attachments: []const Attachment = &.{},
};

comptime {
    _ = CommentLine;
}
```

The field is an ordinary typed field to the JSON writer and the document, and
it is in no statement: no `SELECT` list reads it and `db.raw` counts the
statement's columns against the columns; every read leaves it at the default
it declares, for the caller to fill; `db.checking` does not look for it; a
Row borrowing a table need not find it there. A `.where`, an `.order`, a
`.set`, an insert or a `.key` naming it is refused by name, and so is a name
the Row lacks or a field with no default. **For a list the database can
build, `sql.Json(T)` is still the shape** — `jsonb_agg` in the statement,
one round trip, and the document says `T`.

### `Db`

```zig
var db = sql.Db.init(gpa, "postgres://…", .{});
defer db.deinit();
db.checking(.{ .tables = &.{ User, Order } });   // optional
db.expecting(manifest.head);      // optional
db.watching(sql.logging);         // optional
try app.provide(&db);
```

`db.expecting(version)` refuses to serve a database whose migration ledger is
behind `version`, checked once at boot, after the work `app.before` registered
has run and before the first request
([ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)). The
same is true of `db.checking`: a `createMissing` or a migration in `before`
runs first, and the check reads what it made.
A call rather than an option because an option is read on every boot and
links the migration module into every program with a `Db`, measured at
17,296 bytes; a program that never calls this links none of it.

`db.watching(f)` calls `f` with a `sql.Sent` after every statement — the text,
the plan name it is kept under (a `db.raw` statement's included; null for
`db.exec`, a request-chosen `ORDER BY`, a `Composed` and a `Db` with
`prepared = false`), how long the database took, how many rows moved,
whether it failed, and `route`, the `operationId` of the route whose request
sent it (null under a `Run`). **Not the values it bound**, which are somebody's
password as often as they are an id
([ADR 108](../adr/108-a-statement-can-be-watched.md)). `sql.logging` is a
ready-made one that writes a debug line. A `Db` nobody watches pays one null
test per statement.

A statement that failed also carries `sent.problem`: the database's own
`message`, its SQLSTATE `code`, `severity`, `detail`, `hint` and the
`constraint` that was violated
([ADR 117](../adr/117-a-statement-that-failed-says-what-the-database-said.md)).
Fields a given database does not answer are empty rather than null — SQLite has
no SQLSTATE and does not invent one. When the driver refused the statement
before it left the process, `message` is the Zig error's name, which is the case
this exists for: `error.QueryFailed` used to be the whole of what a program
could see. It lives in the request's arena, so a watcher keeping one past the
request copies it, and it still never reaches the client
([ADR 024](../adr/024-every-failure-answers-as-json.md)).

`db.explain(Row, c, options)` takes what `db.select` takes and answers the plan
of that statement with its values bound, one line of the plan per line of text:
`EXPLAIN (ANALYZE, BUFFERS)` on Postgres, which runs the read, and
`EXPLAIN QUERY PLAN` on SQLite. For a test and a developer; a children
statement is not in it ([ADR 232](../adr/232-a-read-can-show-its-plan.md)).

**`sql.problem(c)` is the same struct asked for from the other end** — by the
call that failed rather than by an observer of every call. See
[Errors](#errors).

`db.nilo_start(io, limits)` is what `listen()` calls; a program starting a `Db`
by hand passes `.none` — `.off` is the older spelling of the same value — and
the pool's waits are bounded by nothing. It opens the pool and nothing more.
`db.nilo_check(io)` is what `listen()` calls next, once the work `app.before`
registered has run: the `checking` list is held against the live tables and
the `expecting` version against the ledger, and either disagreeing is a boot
that fails. A program driving a `Db` by hand calls it after its own boot
work, or `db.checkSchema(rows)` directly for the tables alone
([ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)).
`db.nilo_stop()` is the other half, and `listen()` calls that too — after the
last connection is cut off and before the Engine's loop is torn down, so the
pool lets go of the loop it was built on
([ADR 121](../adr/121-a-service-is-stopped-before-the-loop-is.md)). **A `Db`
is not usable after `listen()` returns.** A program driving one by hand calls
`deinit` as it always did.

`db.nilo_ready(scope)` is what `app.health` asks: `SELECT 1` down the pool,
and the reason when it did not come back — so a server started with
`connect_on_init = 0` over a database that is down is a 503 on its health
page rather than a 200 over an empty pool
([ADR 154](../adr/154-a-health-route-asks-the-services.md)). An `s3` Store
answers the same question with whether it started.

`init` opens nothing. The pool is built by `listen()`, which is the only
moment there is an event loop to dial through — so a server starts with its
database switched off, and the first request that needs it gets
`error.Disconnected`.

**A database on the same box should be reached over its unix socket** —
`postgres://app:secret@%2Fvar%2Frun%2Fpostgresql%2F.s.PGSQL.5432/shop`, the
full socket path with the slashes percent-encoded. Same server and same query:
197k req/s across a Docker published port, 359k over loopback TCP, 458k over
the socket, with p99 halved ([`bench/result/sql.md`](../../bench/result/sql.md)).

**The URL is read the way libpq reads it, and a parameter the driver would
not act on is refused by name.** Carried: `user`, `password`, `dbname`, `host`
and `port` as query forms, `sslmode` (`disable`, `require`, `verify-full`),
`sslrootcert` beside `verify-full` (`system` for the platform's store),
`application_name` and `fallback_application_name`, `connect_timeout` in
seconds, `tcp_user_timeout` in milliseconds, and `keepalives`,
`keepalives_idle`, `keepalives_interval`, `keepalives_count`. Dropped with one
`warn` line, because the driver does it already or nothing observable changes:
`pgbouncer`, `pool_mode`, `sslsni=1`, `gssencmode=disable`,
`channel_binding=prefer`, `target_session_attrs=any`. Everything else is
refused with a line naming the parameter, why, and that list — `sslmode=prefer`
first among them, because it would fall back to plaintext and pg.zig does not.
A query string is split before it is percent-decoded, so `password=p%26w` is
`p&w`.

| `Opts` | |
|---|---|
| `size` | connections held open. Default 10. The knob with a real curve behind it: 8 → 133k req/s, 16 → 148k, 32 → 180k, 64 → 206k, with p99 best at 32. Each one is a Postgres backend and a slot against `max_connections` |
| `connect_on_init` | how many to dial during `listen()`. Default 0, which dials one anyway — for the schema check, the version guard and `app.before`, all of which run before the first request — and fills the rest lazily; the one is allowed to fail ([ADR 115](../adr/115-a-boot-dials-the-connection-its-work-needs.md)). Set it to `size` when driving a `Db` from a `std.Io.Threaded` |
| `timeout_ms` | how long a caller waits for a free connection. Default 10,000. Bounded on SQLite too since [ADR 107](../adr/107-a-wait-for-a-connection-has-a-bound.md), where it needs the Engine to enforce it |
| `schema_mismatch_is_fatal` | whether a Row that disagrees with its table stops startup. Default true |
| `unchecked` | say so when this `Db` has no `checking` list on purpose. Default false, and then a `Db` that starts with `checking` never called warns once that the Rows will be checked by the first request that reads them ([ADR 192](../adr/192-a-db-with-no-schema-check-says-so-or-is-told.md)) |
| `prepared` | whether a statement is kept prepared on the connection it went down. Default true |

**A suite whose database is not running: turn the log level down, and do it with
`std.testing.log_level`.** A `Db` that cannot dial says so at `warn` and returns
the error ([ADR 145](../adr/145-a-suite-whose-database-is-down-is-not-a-suite-that-failed.md)),
but pg.zig logs its own connect failure at `err` — and the Zig test runner counts
a logged `err` as a failed test, so a suite that skipped 95 tests exactly as it
meant to still exits 1.

```zig
test "…" {
    const previous = std.testing.log_level;
    std.testing.log_level = .warn;
    defer std.testing.log_level = previous;
    …
}
```

`std.testing.log_level` is a plain `pub var` the runner compares against on every
line. **`std_options` in a tested file is never consulted** and this is the thing
to know before spending an afternoon on it: the root of a test build is the
compiler's own `test_runner.zig`, which declares `std_options` itself, so a copy
in your file is dead code that appears to work whenever the build runner caches
the step and skips the binary.

`sql.Named("replica")` is a **second `Db` type**, so a second database is a
second service and which pool a statement takes is written in the handler's
argument list. Nothing routes between them: an automatic reader needs health
checking, lag awareness and read-after-write safety, and the last fails
silently ([ADR 054](../adr/054-a-second-database-is-a-second-type.md)).
`sql.Named("")` is a Refusal. There is no query cache — invalidation cannot
be right from a module that sees only its own writes.

Every statement this module sends is a comptime constant, so it is kept
prepared on its connection under a name derived from its own text — worth
**30% of a key lookup and 14% of a page with a sort**, ~12 µs either way
([ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)).
`db.raw` is prepared too, since its text is comptime
([ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)). Set
`.prepared = false` behind a **connection pooler in transaction mode**
(pgbouncer), which hands out a different server connection per transaction.

A Row may name a **view** or a **materialized view** as well as a table. The column types are checked there; nullability is not, because Postgres does not track `NOT NULL` through a view ([ADR 050](../adr/050-a-view-or-a-rowid-alias-is-not-a-nullable-column.md)). An identity key and a generated column, which the Row reads as optional, need nothing said about them: an insert names a subset of the Row's columns and `RETURNING` brings the rest back. A sequence or any other default on another column, written outside the marker, is named in `.filled` so an insert may leave it out ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)).

A Row says four things about its schema: `.default`, `.unique`, `.index` and
`.references` ([ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md),
which amends the older refusal that it may say none, and
[ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md), which adds the
first). Only the Row that names a table may say them, and nothing enforces that
because the language does — a borrowed Row's marker is a `type`, and there is
nowhere on a type to write `.unique`. Where the line falls is where the compiler
stops being able to check: `CHECK (age > 18)` is a text nilo cannot read, so it
is written by hand in a step, and **nilo never touches what it did not create**.
A column the Row reads as a Zig enum is the one check constraint the marker does
write, because the words are the type's. See [Migrations](#migrations).

### SQLite

The same `Db`, over a file instead of a server. Everything below this section —
Rows, queries, batches, upserts, conditions, streaming, transactions — is the
same code and the same types; what changes is the five things SQLite refuses,
listed at the end.

```zig
const Db = sql.Sqlite(.{ .threading = .{ .hop = nilo } });

var db = Db.init(gpa, "/var/lib/app/shop.db", .{});
defer db.deinit();
try app.provide(&db);
```

`threading` **has no default and the compiler will not let you leave it out**.
SQLite is a library reading a file rather than a server on a socket, so there
is no wait for the event loop to park on and the choice cannot be made for you
([ADR 064](../adr/064-a-file-has-no-socket-to-wait-on.md)):

| | |
|---|---|
| `.{ .hop = nilo }` | hand each statement to the Engine's thread pool and park the fiber, on a worker of its own (`nilo.blockingReserved`) so a statement holding its connection never queues behind a slow call. Costs a few microseconds per statement; **no statement can stall an executor thread**. The payload is `nilo` itself, passed in because `sql/` may not import `nilo_http` |
| `.in_fiber` | run it on the fiber that asked. Faster when every statement is a cached lookup; a slow one holds a thread that serves other connections |

Which is the better default is unmeasured and is an open question in
[`docs/roadmap.md`](../roadmap.md) for this module. When in doubt take `.hop`: its bad case is a few microseconds and
`.in_fiber`'s is a stalled thread.

| `sqlite.Options` | |
|---|---|
| `threading` | above. **No default** |
| `busy_timeout_ms` | how long to wait for a lock another *process* holds before answering `error.Locked`. Default 5,000 |
| `cache_kib` | `PRAGMA cache_size`, or null for SQLite's 2,000 KiB. **A ceiling, not an allocation**: a connection holds 28 KiB opened and grows towards this as pages are touched ([`bench/result/sql.md`](../../bench/result/sql.md) §9) |
| `synchronous` | `.normal` (the default, WAL's recommended setting — the database cannot corrupt, a power cut can lose recent transactions) or `.full`. `OFF` is not offered |

`wire.OpenOpts` is the same struct both drivers take, so `size`, `timeout_ms`
and the rest are written the same way. **`size` is one writer and `size - 1`
readers**, and that is the database rather than a setting: SQLite allows one
writer at a time, so writes queue on a single connection and reads run beside
them under WAL ([ADR 065](../adr/065-one-writer-is-not-a-setting-it-is-the-database.md)).
`connect_on_init` is ignored — a file is opened or it is not.

Every connection is primed with `journal_mode = WAL` and `foreign_keys = ON`.
Which connection a statement takes is decided by its first keyword: `SELECT`
and `PRAGMA` take a reader, everything else takes the writer. That is exact for
everything this module generates and a **guess for `db.raw`**, whose text is
yours — a `raw` that writes and looks like a read lands on a read-only
connection and fails loudly. On a file. Not in memory, where SQLite's URI
`mode=` overrides the open flags and the backstop is absent.

The url is a path, or SQLite's URI form. **A bare `:memory:` is refused at
`open`**, because a pool of them is several separate empty databases; the
shared form `file:name?mode=memory&cache=shared` is one, and lives only as
long as a connection to it does.

`sql.SqliteNamed("cache", .{…})` is the second-database form, exactly as
`sql.Named` is for Postgres. `sql.sqlite.version` is the bundled SQLite's
version string — the amalgamation is vendored by the driver, so it is what the
build pinned rather than what the machine had.

**What SQLite refuses, while compiling, naming the dialect:**

| | why |
|---|---|
| `insertMany`, `updateMany` | no `unnest` and no array parameter. The batch form SQLite has grows its own statement text, which is the rule this module is built on. Write a row at a time inside one transaction — cheap here, because there is no round trip to pay per statement |
| `.lock` | writers are serialised by a lock over the whole database, so there is no row to hold against anybody |
| `tx.deadline` | needs the database to enforce it, and there is no server. `sqlite3_interrupt` aborts the whole connection rather than one statement. `busy_timeout_ms` covers the case that actually happens |
| a list column | no array type. A list belongs in its own table, or in a TEXT column your own code encodes |
| `.isolation` other than `.serializable` | SQLite gives every transaction a snapshot and serialises the writers. There is no weaker level to ask for |

A `sql.Uuid` is **not** on that list, and only stopped being on it in
[ADR 067](../adr/067-a-value-is-whatever-the-database-stores.md). SQLite has no
uuid type, so one travels as the thirty-six hyphenated characters into a TEXT
column — which is what the schema check has always asked for, and what makes
`sqlite3` show the id and `WHERE public = '…'` typeable. Postgres still sends
sixteen bytes. Your Row says `public: sql.Uuid` either way.

**Nor are `.in`, a `sql.Json(T)` column or an enum column**, though until
[ADR 067](../adr/067-a-value-is-whatever-the-database-stores.md) all three behaved as
if they were: each read correctly and failed to *compile* on the way in, from
inside the driver. SQLite has neither a `jsonb` nor an enum type, so a document
and a tag both bind as text, and `.in` binds its whole list as one JSON array
that `json_each` takes apart — which is what keeps the statement a constant on
a database with no array parameter. `.in` is the only one of the three that
costs anything: **one arena allocation per condition, on SQLite alone**,
because the array has to be written where Postgres sends a native one.

So **code that batches is not portable between the two dialects**, and that is
the seam refusing rather than lying. The schema check is weaker too, by exactly
as much as SQLite is: a column's declared type is free text and what is
enforced is one of five affinities, so it catches a `Str` field over an
`INTEGER` column and does not catch an `i32` over a column holding values that
do not fit.

SQLite costs **523,352 bytes** to a program that names it and **zero** to one
that does not — both drivers live in one module, but `sql/sqlite.zig` is
analysed only when something names it, so a Postgres-only binary carries no
amalgamation at all.

### Queries

Every one takes the Row, a [Scope](./core.md#scope) — the `*Ctx` inside a handler, a
`*nilo.Run` anywhere else — and a struct written where it is used. All of them
compile their SQL to a constant.

The Scope is why this module names no App: `arena()` and `str()` were the only
things it ever asked a `Ctx` for, so a query runs the same in a CLI as in a
request ([ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)).

| | |
|---|---|
| `db.select(User, c, .{ … })` | `![]User` |
| `db.one(User, c, .{ … })` | `!?User` — a handler returning this answers 404, and the document says so. Carries its own `LIMIT 1`, so a `.limit` beside it is refused |
| `db.find(User, c, id)` | `!?User` — the same, on the column the Row's `.key` names. Takes the key itself, not a condition |
| `db.page(User, c, .{ .where = …, .order = …, .limit = 20 })` | `!Page(User)` — `.rows` and `.total`, in one statement. `.limit` and `.order` are required; see below |
| `db.count(User, c, .{ .where = … })` | `!usize`. `.where` only, and optional — no condition counts the table |
| `db.exists(User, c, .{ .where = … })` | `!bool` — `SELECT EXISTS(…)`, so it stops at the first match |
| `db.insert(User, c, .{ .email = … })` | `!User` — the stored row, generated key included. A subset of the columns: what it leaves out has to be filled by something, the key a sequence fills, a `.default`, `null` on an optional field, or `.filled`, and an insert that leaves out a column nothing fills is a Refusal naming it. Not checked on a `.managed = false` Row ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)) |
| `db.insertMany(User, c, rows)` | `![]User` — a whole batch in one statement, back in the order it was sent. `rows` is a `[]const Line`, `Line` a named struct of the columns being written; see below |
| `db.insertOrIgnore(User, c, .{ … }, .key)` | `!?User` — the stored row, or `null` when one was already there. `ON CONFLICT … DO NOTHING`. `.key` is the Row's own key; a column name is for a unique index that is not the key |
| `db.insertOrUpdate(User, c, .{ … }, .email)` | `!User` — stored, or the existing row with these values written over it. `ON CONFLICT … DO UPDATE` |
| `db.update(User, c, .{ .set = …, .where = … })` | `!usize` — rows changed. Both halves required |
| `db.updateMany(User, c, rows)` | `![]User` — a whole batch in one statement, found by the Row's key. No `.where`: the join is the condition; see below |
| `db.updateReturning(User, c, .{ .set = …, .where = … })` | `![]User` — the rows as they now are. One statement where an update and a select are two and a race |
| `db.updateReturningOne(User, c, .{ .set = …, .where = … })` | `!?User` — the same for a `.where` holding the key or a unique with `=`, so a PATCH endpoint is one call and null is its 404. Any other `.where` does not compile |
| `db.delete(User, c, .{ .where = … })` | `!usize` — rows deleted. `.where` required |
| `db.deleteReturning(User, c, .{ .where = … })` | `![]User` — the rows that were removed |
| `db.deleteReturningOne(User, c, .{ .where = … })` | `!?User` — the one row the key or a unique pins, removed; what a one-time token is |
| `db.stream(User, c, .{ … })` | rows one at a time; see below |
| `db.raw(User, c, sql, .{ … })` | `![]User` — a statement this module will not write. `sql` is **comptime**: the `SELECT` list is counted against the Row's fields and each column that plainly has a name is checked against the field in its position, and the statement is kept prepared like every other ([ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)) |
| `db.rawOne(User, c, sql, .{ … })` | `!?User` — the same, for a statement whose `WHERE` holds a key. **No `LIMIT 1` is added**; see below |
| `db.rawExactlyOne(Totals, c, sql, .{ … })` | `!Totals`: `rawOne` for a statement that has one row by construction: an aggregate with no `GROUP BY`, a `RETURNING` on a keyed write. No row is `error.QueryFailed`, not a zero-filled Row ([ADR 206](../adr/206-a-statement-that-always-answers-answers-a-row.md)) |
| `db.rawPage(Line, c, sql, .{ … })` | `!Page(Line)`: a raw statement read as a page: the Row's columns, then `count(*) OVER ()` as one more column on the end of the `SELECT` list, which becomes `.total`. The `ORDER BY` and `LIMIT` are yours to write. A list exactly the Row's width is a Refusal ([ADR 205](../adr/205-a-raw-statement-can-carry-its-total.md)) |
| `db.raw([]const u8, c, sql, .{ … })` | `![][]const u8` — column one of every row, with no Row and no marker. `i64`, `?bool`, a `Str`: any one thing a column can be read as. `rawOne` the same, unwrapped. A list of two columns into a scalar is a Refusal ([ADR 125](../adr/125-a-row-that-owns-no-table.md)) |
| `db.liveColumns(c, schema, table)` | `![]const sql.Column` — what the database says the table has, `name`, `udt`, `nullable`. Empty for a table that is not there. What `checkSchema` and `migrate.addMissingColumns` read |
| `db.rawOrdered(User, c, sql, .{ … }, order)` | `![]User` — a raw statement with `{order}` in it, where the whole `ORDER BY` an `sql.Ordering` chose at run time is written. See *An order chosen at run time* below |
| `db.rawPageOrdered(Line, c, sql, .{ … }, order)` | `!Page(Line)` — `rawPage` and `rawOrdered` at once: the list ends in `count(*) OVER ()` and the statement holds `{order}`, so a list sorted from its headings reads its rows and its total in one statement rather than two with the `WHERE` pasted into both ([ADR 205](../adr/205-a-raw-statement-can-carry-its-total.md)) |
| `db.compose(c)` | `sql.Composed` — an empty composed statement in the Scope's arena, spelling its placeholders the way this Db's dialect does (`$n`, or `?n` on SQLite). `sql.Composed.init(arena, sql.Spelling.of(Dialect))` builds one where no Db is in scope ([ADR 208](../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md)) |
| `db.composed(User, c, stmt, .{ … })` | `![]User` — a statement composed at run time from pieces that cannot carry a string: `sql.Composed` is literals (`text`, comptime), checked identifiers (`ident`, `qualified`) and parameters (`param`, `number`), and nothing else. Filled by position, width-checked at run time, its tuple counted against its placeholders (`error.ParamCountMismatch`) and its spelling against the Db (`error.WrongDialect`), unnamed. For a query engine that turns a model into SQL; `raw` for everything that can be written while compiling ([ADR 208](../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md)) |
| `db.composedOne(User, c, stmt, .{ … })` | `!?User` — the same, unwrapped |
| `db.exec(c, sql, .{ … })` | `!usize` — a statement that answers with *nothing*, and the rows it changed. `CREATE TABLE`, `CREATE INDEX`, `PRAGMA`, `VACUUM`. No Row, because none is being filled ([ADR 067](../adr/067-a-value-is-whatever-the-database-stores.md)). `sql` is run-time text and is sent as written |
| `db.checkSchema(&.{ User, Order })` | `!usize`: hold these Rows against the live tables now, on a connection of its own, and say what disagrees at `err`. The count is how many problems. What `nilo_check` runs for the `checking` list; for a program that drives a `Db` with no App |
| `db.nilo_check(io)` | `!void`: the schema check and the version guard, run by `listen()` after `before` ([ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)) |
| `db.begin(c, .{})` | `!Tx`. `.{ .isolation = …, .read_only = … }` rides on the `BEGIN`; see below |

**A raw statement's parameters are `$1`, `$2`, … on every database.** The
text is respelled for the dialect while compiling (`?1`, `?2` on SQLite),
so a `$2` that appears before `$1` binds the second value on both, and a
statement naming `$3` and handed two values is a Refusal. `exec` takes its
text at run time and sends it as written
([ADR 204](../adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)).

**Set operations are conditions.** Over one table `UNION` is
`.any = .{ .{ a }, .{ b } }`, `INTERSECT` is `.{ a, b }` and `EXCEPT` is
`.{ a, not_b }` — every leaf has a negation and `.any` nests, so the boolean
algebra is closed. Over two tables it is a view, and a Row may name one
([ADR 052](../adr/052-a-set-operation-over-one-table-is-a-condition.md)).
There is no pipelining: a round trip is 24 µs, the query inside it is 2, and
a server here serves 215,000 requests a second with a query in every one
because a waiting fiber frees its thread
([ADR 053](../adr/053-a-round-trip-is-not-the-cost-worth-chasing.md)).
Statements that must land together are a data-modifying CTE through `db.raw`.

**A statement you wrote is one nilo does not cast.** `Decimal`, `Interval`,
`Inet` and any `AsText` column travel as the text the database printed, and the
`::text` (or `CAST(… AS TEXT)`) that makes that true is added to the SELECT list
*nilo* writes. A `db.raw` list is yours, so nilo adds nothing to it and the
driver hands back a `numeric` the reader cannot parse — at run time, on one
route, with no compile error anywhere near it. So `db.raw` now refuses it while
compiling: a bare column, or a `*`, in the position of an as-text field is a
Refusal naming the column, the field and the field's column type
([ADR 124](../adr/124-a-raw-statement-cannot-cast-what-it-did-not-write.md)).
Writing the cast yourself is the fix, and the message says so:

```zig
const rows = try db.raw(Invoice, c, "SELECT id, total::text FROM invoices", .{});
```

An aliased expression — `sum(amount)::text AS total` — is already an expression
rather than a column path, so it passes. What the check refuses is the shape
that could only ever be wrong.

**`rawOne` and `updateReturningOne` are the unwrap, not a narrower statement**
([ADR 146](../adr/146-a-statement-with-a-key-in-it-has-a-single-row-answer.md)).
A statement whose `WHERE` holds a primary key answers with one row or none, and
what the handler wants is `!?T` — `?Row` is already a 404 in the typed layer. So
this:

```zig
const found = try db.raw(Card, c, card_sql, .{id});
return if (found.len > 0) found[0] else null;
```

becomes `return db.rawOne(Card, c, card_sql, .{id});`.

**Unlike `db.one`, no `LIMIT 1` is added.** This module did not write the
statement and has nowhere honest to put one — a `LIMIT` after a `UNION ALL` or
inside a CTE means something else. A statement that matches many rows still
costs every one of them and this hands back the first.

`updateReturningOne` and `deleteReturningOne` go further, because the builder
wrote their `WHERE` and can read it: **a `.where` that could match more than
one row does not compile.** It has to hold every column of the key, or of one
`.unique`, with `=` to a value that is always there. A write of every matching
row answered with the first would hide the others.

All three exist on a `Tx` too.

**`db.page` is a `select` carrying the count the condition matched before the
`.limit` cut it** ([ADR 150](../adr/150-a-page-knows-what-it-left-out.md)):

```zig
const found = try db.page(Order, c, .{
    .where = .{ .status = "open" },
    .order = .{ .id = .asc },
    .limit = 20,
    .offset = 40,
});
// found.rows is []Order, found.total is every order that matched.
```

```sql
SELECT "id", "status", count(*) OVER () FROM "orders"
  WHERE "status" = $1 ORDER BY "id" ASC LIMIT 20 OFFSET $2
```

**A `db.count` beside a `db.select` is two statements against a table somebody
else can write between**, so the total and the rows can disagree with nothing
saying so. A window function rides on the page and cannot. It costs one integer
read per statement rather than per row, and a condition matching nothing answers
with no rows and a total of zero.

`.limit` and `.order` are both required, and `.lock` is refused. With no ceiling
this is the whole table and the total is `rows.len`; with no order Postgres owes
the `LIMIT` nothing, so two requests for the same page can hold one row twice and
miss another; and `FOR UPDATE` beside a window function is a run-time error from
Postgres. `tx.page` is the same call inside a transaction. `sql.Page(Row)` is the
answer's type, for a handler returning one.

A page too deep for `OFFSET` to stay fast wants
[the keyset form](../guide/sql/reading.md#the-keyset-form-of-a-deep-page)
instead — a condition the caller writes by hand rather than a call here, and
without `db.page`'s running total.

### A batch

`insertMany` sends one array per column and lets Postgres `unnest` them, so
the statement text is a constant and the batch size is data
([ADR 047](../adr/047-a-batch-is-one-array-per-column.md)). One round trip
whatever the size, one allocation per column, and — because it is one
statement — a batch that violates a constraint stores none of its rows.

```zig
const Line = struct { sku: Str, qty: i32 };
const stored = try db.insertMany(Item, c, lines);   // lines: []const Line
```

The rows are a slice of a **named** struct, because the statement is compiled
from the element type. Two columns cannot be batched and both say so at
compile time: a list column, because `unnest` would flatten it, and an enum
that has not declared `nilo_column`, because the cast has to name a type that
lives in the database.

`updateMany` is the mirror, joined against the table instead of selected into
it. Each row of the batch carries the Row's **key**, which is what it is found
by and the one field the struct must have; every other field it carries is
set.

```zig
const Change = struct { id: i64, qty: i32 };
const changed = try db.updateMany(Item, c, changes);   // []const Change
```

A key the table does not have matches nothing, so a shorter answer than the
batch is how you tell which landed. Two things it does not promise, both
because a join is a join: the **order** is the planner's, and a batch naming
one key twice changes that row once. `db.update` in a loop is the answer where
either matters.

### Upserts

The last argument is the conflict target — the column the database has a
unique constraint on, written the way a key is. `.{ .tenant_id, .email }` for
one spanning two columns. **On a table this program builds it has to be the key
or a `.unique` in the marker**, as a set, and one that ignores case does not
count; anything else does not compile, where the database would refuse it at
run time (ADR 151). A table `.managed = false` is not checked.

Two calls rather than one option, because the answers differ:
`DO NOTHING` stores no row and `RETURNING` then yields none, so ignoring
returns `?User` and updating returns `User`.

`insertOrUpdate` sets **every column you passed except the conflict target and
the Row's key**. The target is what the rows were matched on; the key
identifies the row that is already there, and `"id" = EXCLUDED."id"` would
renumber it. A call where that leaves nothing to set is a compile error
pointing at `insertOrIgnore`.

### Options

| | |
|---|---|
| `.where` | a condition; see below |
| `.order` | `.{ .created_at = .desc }`, one column per field. `.asc_nulls_last` and its three siblings say where NULLs go, which the two databases otherwise disagree about. A narrower Row that is not grouped may name any column of its table, carried or not, so a tiebreak need not go on the wire; a grouped one is a Refusal there, since the column has no single value per group. Or a value of an `sql.Ordering` for an order the request chose; see below |
| `.limit` / `.offset` | a literal is baked into the SQL; a variable becomes a parameter. A literal limit is also the row ceiling, so the result list is allocated once |
| `.set` | update only: columns to new values, or `.{ .views = .{ .plus = 1 } }` for arithmetic on the column's own value. A bare `null` on a nullable column is `= NULL` — no `@as(?T, null)` needed — where in `.where` the same null is `IS NULL`. `.title = sql.given(maybe)` is `COALESCE($1, "title")`, the column kept when the value is null, refused on an optional column. `.updated_at = .now` is the database's clock on a `sql.Timestamp`, and `.start_date = .today` its date (`CURRENT_DATE`) on a `sql.Date`, nothing bound for either. Each on the other's column type is a Refusal |

### Conditions

Different fields are ANDed. Several operators on one field are ANDed too.

| | |
|---|---|
| `.id = 7` | `"id" = $1` |
| `.age = .{ .gt = 18, .lt = 65 }` | `"age" > $1 AND "age" < $2` |
| `.eq` `.ne` `.gt` `.gte` `.lt` `.lte` | each also takes `.now` on a `sql.Timestamp` column and `.today` on a `sql.Date` one, the database's clock with nothing bound: `.due_date = .{ .lt = .today }`, and `.due_date = .today` for `=` |
| `.ieq` / `.not_ieq` | equality that ignores case: `lower("email") = lower($1)` on Postgres and `"email" COLLATE NOCASE = ?1 COLLATE NOCASE` on SQLite, the expression a `.unique` with `.ignoring_case` indexes, so the lookup uses it. An `_` is a character here, where `.ilike` would read it as a wildcard. Text only |
| `.like` / `.ilike` | and `.not_like` / `.not_ilike`. **These do not escape the text you give them**; the row below is the one to reach for. On SQLite `.ilike` is spelled `LIKE`, because that database's `LIKE` already folds ASCII case — and `.like` is a Refusal there naming `.ilike`, for the reason `.contains` is ([ADR 055](../adr/055-the-second-dialect-is-the-test-of-the-seam.md)) |
| `.contains` `.starts_with` `.ends_with` | the pattern is built *and* escaped by the statement, so `%` and `_` in a search term match themselves. `i` in front folds case (`.icontains`), `not_` in front negates — twelve in all. On SQLite the case-sensitive half is a Refusal: its `LIKE` folds ASCII case and cannot be told not to |
| `.in = &.{ 1, 2, 3 }` | `= ANY($1)` — one parameter, so the statement stays a constant |
| `.not_in = &.{ 1, 2, 3 }` | `<> ALL($1)` — one parameter likewise |
| `.stage = .{ .in = sql.given(stages) }` | `("stage" = ANY($1) OR $1 IS NULL)` — a multi-select that may be absent: null drops the term, and a list, empty or not, is the list. See below |
| `.deleted_at = null` | `IS NULL` |
| `.deleted_at = .{ .ne = null }` | `IS NOT NULL` |
| `.handle = .{ .not_distinct_from = maybe }` | `IS NOT DISTINCT FROM $1` — `=` with null treated as a value. **The one operator an optional may reach**; `.distinct_from` is its negation |
| `.status = sql.given(maybe)` | `("status" = $1 OR $1 IS NULL)` — the term is in the statement when the filter carried a value and out of it when it did not. See below |
| `.any = .{ .{ … }, .{ … } }` | OR, bracketed. Not `.or`, which is a keyword — so `any` is a reserved column name |
| `.exists = .{ .{ .in = Other, .where = .{ … } } }` | `EXISTS (SELECT 1 FROM …)`, joined on the `.references` either Row declares — `Other`'s pointing at this table, or this Row's pointing at `Other`'s. `.on = .<column of Other>` or `.via = .<column of this Row>` says which when the schema says it twice. Either one also names a join no `.references` covers at all, and then the column named is joined to the other side's key: `.via = .deal_id` is `deals.id = <this table>.deal_id` with nothing declared on either Row, which is the way through a table another part of the program owns. `.not_exists` negates; both are reserved column names, and both nest inside `.any` |
| `.across = .{ .columns = .{ .code, .name }, .icontains = q }` | `("code" ILIKE … $1 … OR "name" ILIKE … $1 …)` — one condition, whichever of the columns meets it, and **one parameter** named on each. A tuple of entries is several, ANDed; `across` is a reserved column name too |

A column that does not exist is a compile error naming the near miss.

**A null is written, never held.** The two lines above are `IS NULL` because
the compiler can see the null. An optional that *might* be null is a compile
error, because whether the statement says `= $1` or `IS NULL` would then
depend on a value that arrives after the statement is a constant — and
`= NULL` is never true in SQL, so the query would run and answer nothing.
Reach for `.not_distinct_from` — one statement that means what you wanted —
or branch
([ADR 040](../adr/040-a-condition-holds-a-value-not-a-maybe.md)). The
null-safe pair is the exception because its statement does **not** change
when the value turns out to be null: `"handle" IS NOT DISTINCT FROM $1` is
the same six words either way, so nothing is left until run time.

**And a filter that is absent is a different question from one that is null.**
`.status = null` asks for the rows whose status is nothing; a screen with a
search box and three dropdowns wants *no condition on status at all*, which is
the opposite. `sql.given` is that, and it is a word rather than an optional so
the two stay tellable apart
([ADR 149](../adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)):

```zig
const found = try db.page(Partner, c, .{
    .where = .{
        .name = .{ .icontains = sql.given(filter.search) },
        .exists = .{
            .{ .in = PartnerCapability, .where = .{ .capability = sql.given(filter.capability) } },
        },
    },
    .order = .{ .name = .asc },
    .limit = 20,
});
```

```sql
("name" ILIKE … OR $1 IS NULL) AND (EXISTS (SELECT 1 FROM …) OR $2 IS NULL)
```

**One statement, one parameter list and one prepared plan however the screen is
set**, which is what the guard buys over a statement per combination of filters.
Postgres folds `$1 IS NULL` away while a custom plan is in use — which is the
first five executions and for as long after that as the custom plan wins — so
the term that *is* set plans as if the guard were not written. `SET
plan_cache_mode = force_custom_plan` is the lever if one query disagrees.

Inside an `.exists` it drops the **whole subquery**, not one term of it: with the
term dropped the subquery would ask whether *any* joined row exists, which
excludes every row that has none. For the same reason it cannot sit beside a
condition that is always there in one `.exists` — write a second entry.

**A list takes one too**, and absent and empty stay two answers. A filter bar's
multi-select sends no `?stage=` for *no filter* and a list for *these stages*,
so `.stage = .{ .in = sql.given(q.stages) }` drops the term when `q.stages` is
null and keeps it when it is a list; an empty list is still `.in`'s *no row
matches*, and `.not_in`'s *every row*. On SQLite the list is one JSON
parameter, and `json_each(NULL)` is no rows beside a guard that already said
the term is not there.

Five things are Refusals, each with its own sentence: a `sql.given` inside
`.any` (OR reverses what dropping means), on `not_distinct_from` (which takes
an optional already), on a value that is not optional, beside a fixed condition
in one `.exists`, and in the condition of an `UPDATE` or a `DELETE` — where a
term that may not be there is the whole table.

**A search box over several columns is `.across`, and a `sql.given` on it
guards the bracket** ([ADR 172](../adr/172-one-condition-over-several-columns-is-one-parameter.md)).
The refusal inside `.any` is about one absent alternative among present ones;
the same absent value on every column is one condition, and it is written as
one:

```zig
.where = .{
    .product_id = sql.given(f.product_id),
    .across = .{ .columns = .{ .code, .name, .trademark }, .icontains = sql.given(q) },
},
```

```sql
("product_id" = $1 OR $1 IS NULL)
AND (("code" ILIKE … $2 … OR "name" ILIKE … $2 … OR "trademark" ILIKE … $2 …) OR $2 IS NULL)
```

The parameter is taken once and named on every column, so the plan and the
parameter list are the same however the box is set. The operators are a
column's own — `.eq`, `.gt`, `.icontains`, several ANDed — and the columns
have to read as one Zig type, optional or not. Four things are Refusals: a
`sql.given` beside a fixed operator in one entry (write a second entry), one
column (an ordinary condition), columns of two types (two conditions, in
`.any`), and a column the Row lacks.

### An order chosen at run time

`.order = .{ .created_at = .desc }` is settled while compiling. A list screen
sorted from its headings — `?order=due:desc,title` — chooses at run time, and
the choice is from a set the server declares
([ADR 165](../adr/165-an-order-chosen-at-run-time-from-a-closed-set.md)):

```zig
const Sort = sql.Ordering(Commitment, .{
    .due = .{ .column = .due_at, .nulls = .last },
    .title = .title,
});

fn list(db: *sql.Db, c: *nilo.Ctx, q: nilo.Query(struct {
    order: Sort = Sort.by(&.{.{ .key = .due }}),
})) !sql.Page(Commitment) {
    return db.page(Commitment, c, .{ .order = q.value.order, .limit = 20 });
}
```

```sql
SELECT … FROM "commitments" ORDER BY "due_at" DESC NULLS LAST, "title" ASC LIMIT 20
```

**No run-time string reaches the statement.** Each key is a column of the Row,
checked and quoted while compiling, and the type holds one fragment per key per
direction; a value is a list of at most `keys` terms, and writing the clause is
writing those fragments in order. The request decides *which*, never *what*. A
key is an enum literal for a column, `.{ .column = …, .nulls = .first | .last }`
for one that says where NULLs go, or a string for SQL of the caller's own.

**It parses itself.** `?order=due:desc,title` reads straight into a query field
(`key[:asc|:desc]`, comma-separated). A key not declared, a direction that is
neither, an empty term or more terms than keys is a 400 in the type's own
words — `?order has to be an ordering by due or title, each with an optional
:asc or :desc, comma-separated, not "height"` — and the document says the
field is text. Absent is the field's default, which is the list's own order.

**A column key orders a typed statement; an expression is for a raw one.**
`db.select`, `db.one`, `db.page` and `db.stream` take one in `.order` when
every key names a column, and refuse one with a string key — a statement nilo
writes orders by columns it checked. `db.rawOrdered` takes the caller's
statement with `{order}` where the whole clause goes, and either kind of key:

```zig
const rows = try db.rawOrdered(CommitmentRow, c,
    \SELECT … FROM commitments c WHERE c.state = $1 {order} LIMIT $2 OFFSET $3
, .{ state, limit, offset }, q.value.order);
```

The hole is yours, for the reason `rawOne` adds no `LIMIT 1`: appending to
somebody else's SQL is what `db.raw` exists not to do. It goes anywhere an
`ORDER BY` clause is legal — inside an `OVER (PARTITION BY … {order})` as
well as at the end, which is how a grouped and capped list ranks by the order
the request chose with the one hole. `db.rawPageOrdered` is the same call for
a statement whose list ends in `count(*) OVER ()`, read as a `Page` the way
`rawPage` reads one. All three exist on a `Tx`.

**What it costs.** The text is assembled per request, so an ordered statement
runs **unnamed** — Parse, Bind and Execute on every call, the ~12 µs a prepared
name is worth ([ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md))
— and one arena allocation for the text, sized while compiling. A statement
whose `.order` is a literal is exactly what it was.

Four things are Refusals: a key naming a column the Row lacks, an ordering
declared for another Row, an expression key handed to a typed statement, and a
raw statement with no `{order}` in it.

### A row in another table

```zig
db.select(Partner, c, .{ .where = .{
    .name = .{ .icontains = search },
    .exists = .{
        .{ .in = PartnerCapability, .where = .{ .capability = cap } },
    },
} });
```

**The join is read out of the schema, not written here.** It comes from a
`.references` one of the two Rows declares — the other Row's, pointing at this
table, or this Row's own, pointing at the other's — which is already checked
while compiling: the target has to be a Row the tool knows, the target column
one of its columns, and the two Zig types the same. A key over two columns
joins on both of them, because joining on the first alone would run, read
correctly and answer a wider question than the schema asked. So the query the
other way round,
from the child asking about its parent, is the same line with the Rows
swapped
([ADR 175](../adr/175-an-exists-reads-the-reference-from-either-side.md)):

```zig
db.select(Staff, c, .{ .where = .{
    .exists = .{ .{ .in = Department, .where = .{ .name = .{ .icontains = q } } } },
} });
// EXISTS (SELECT 1 FROM "departments"
//         WHERE "departments"."id" = "staff"."department_id" AND …)
```

Neither Row declaring one is a compile error saying so, and a schema that
says it **twice** is a compile error naming the columns: which of them joins
is a question about what the query means. `.on = .<column>` names a column of
the Row inside, and `.via = .<column>` a column of the Row the statement is
over — two words so the two directions cannot be read as each other, and both
at once is refused. Two tables that point at each other are the twice case
too. `.on` is also the way in for a Row over a view, and `.via` for a parent
that is one.

The entries are a list because a struct cannot carry the same field twice, and
narrowing on two capabilities is the ordinary case. They are ANDed.

**An `EXISTS` is a condition rather than a join**, and
[ADR 218](../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md) says why: it
changes neither the column list nor the row count, so the Row still describes
the answer and `.limit` still means what you think. A join the Row declares
keeps both too, and is [a parent](#a-parent-children-a-group).

### A key of several columns

```zig
pub const nilo_table = .{ .name = "seats", .key = .{ .tenant_id, .id } };
```

```zig
const seat = try db.find(Seat, c, .{ .tenant_id = tenant, .id = id });
```

Named fields rather than a tuple: two `i64` key columns written the other way
round would find the wrong row and report nothing. Leaving one out, adding a
column that is not part of the key, and passing a tuple are all compile errors.
`updateMany` joins on every column, and `CREATE TABLE` writes a
`PRIMARY KEY (…)` constraint rather than a clause on one column.

### A parent, children, a group

A narrower Row can carry more than its table's columns, and every read takes it unchanged ([ADR 218](../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)). The guide page is [a Row with more in it](../guide/sql/shapes.md).

```zig
const OrderCard = struct {
    pub const nilo_table = Order;
    pub const nilo_via = .{ .approver = .approver_id };
    id: i64,
    customer: CustomerName,        // a parent: JOIN, through the one reference to customers
    approver: ?StaffName,          // an optional parent: LEFT JOIN, because approver_id may be null
    lines: []const LineBrief,      // children: one more statement for every row at once
};

const ByCustomer = struct {
    pub const nilo_table = Order;
    pub const nilo_aggregate = .{ .orders = .count, .revenue = .{ .sum = .total } };
    customer: CustomerName,        // a key of the group
    orders: i64,
    revenue: i64,
};
```

| A field | is | read by |
|---|---|---|
| `p: P` or `p: ?P`, `P` a Row of another table | **a parent**: the row a reference of this table points at | a `JOIN` (`LEFT JOIN` for `?P`) in the same statement, aliased by the field's name |
| `cs: []const C`, `C` a Row of a table pointing here | **children**: every row pointing at this one, in `C`'s key order unless `nilo_children` gives an `.order` | a second statement, `unnest(…) WITH ORDINALITY` on Postgres and `json_each(…)` on SQLite, for all the rows at once |
| `n: i64`, named in `nilo_children` with `.{ .count = C }` | **a count** of the rows of `C`'s table pointing at this one | a correlated `(SELECT count(*) …)` in the same statement, one per row answered |
| a field named in `nilo_aggregate` | **an aggregate** of the rows in its group | `count`, `sum`, `min`, `max`, `avg` in the same statement; every other field is a `GROUP BY` key |

**The link is the schema's.** One `.references` between the two tables is the join; none, or several, is a compile error until `nilo_via` names the column. `nilo_via` may name a column no reference covers, and then it joins the other table's key. A parent is `?P` exactly when its column may be null; the other way round is refused as well.

**Conditions and orders go through the field.** `.where = .{ .customer = .{ .name = "Acme" } }`, `.order = .{ .customer = .{ .name = .asc } }`, and in a `sql.Ordering` the path is a tuple, `.{ .customer, .name }`. On a grouped Row a term on a column is a `WHERE` and a term on an aggregate a `HAVING`, and a grouped Row's condition may name any column of its table.

**What an aggregate reads as:**

| `nilo_aggregate` | field |
|---|---|
| `.count`, `.{ .count = .col }`, `.{ .count_distinct = .col }` | `i64` |
| `.{ .sum = .col }` | `i64` over whole numbers, `f64` over floating ones, the column's type over a text-carried number |
| `.{ .min = .col }`, `.{ .max = .col }` | the column's type |
| `.{ .avg = .col }` | `f64` |

Optional exactly when the answer can be null: a nullable column, `sum`, `min`, `max` and `avg` with a `.where`, or `sum`, `min`, `max` and `avg` on a Row with no keys.

**An entry's `.where` narrows only what that aggregate reads**, as `FILTER (WHERE …)` on both databases: `.idr = .{ .sum = .amount, .where = .{ .currency = "IDR" } }`. Rows that match are counted through a column that is never null, `.{ .count = .id, .where = … }`.

**`nilo_children`**, keyed by field:

| entry | on a field | writes |
|---|---|---|
| `.{ .order = .{ .position = .asc } }` | `[]const C` | `ORDER BY "#k"."key", <the terms>, <C's key>` in the children's statement; columns of `C`'s table |
| `.{ .where = .{ … } }` | `[]const C` | a `WHERE` on the children's statement |
| `.{ .count = C }`, `.{ .count = C, .where = .{ … } }` | `i64` | `(SELECT count(*) FROM <C's table> AS "#c" WHERE "#c".<reference> = <this row's key> [AND …])` |

A count may be ordered by and named in `.where` like a column, sits on a parent's Row too, and follows `nilo_via` keyed by its own field. A grouped Row refuses one.

**The `.where` of an aggregate or of a `nilo_children` entry is written with its values in it**, because it is part of the Row rather than of a request: a value is `=`, `null` is `IS NULL`, and an operator struct takes `.eq`, `.ne`, `.gt`, `.gte`, `.lt`, `.lte`, `.in` and `.not_in`, over columns of the table the entry reads. Anything else is refused and names the words.

| Call | a parent | children | a count of children | a group | no keys |
|---|---|---|---|---|---|
| `select`, `one`, `page` | ✓ | ✓ | ✓ | ✓ (a page counts groups) | refused |
| `find` | ✓ | ✓ | ✓ | refused | refused |
| `count`, `exists` | ✓ | ✓ | ✓ | ✓ (counts groups) | refused |
| `stream` | ✓ | refused | ✓ | ✓ | refused |
| `exactlyOne` | | | | | ✓ |

| Call | Returns |
|---|---|
| `db.exactlyOne(Totals, c, .{ .where = … })` | `!Totals`: a Row whose every field is an aggregate, over the rows matched. Exactly one row, whatever matched; a `sum` over none is null |
| `sql.exactlyOneFor(Row, Options)`, `sql.childrenFor(Row, "field")` | the statements behind `exactlyOne` and a children field, while compiling |

Refused: a parent or children on the Row that describes the table, children of children, children through a reference of several columns, a `.limit` on children, a count on a grouped Row, a `.lock`, a write, and `db.raw` into a shaped Row. Children are two statements, one snapshot only inside a `Tx`.

### Streaming

For a result set too big to hold. Rows come back as `sql.Borrowed(User)` —
`User` with every `Str` replaced by `[]const u8`, because the text points
into the buffer the rows arrive in and dies at the next `next()`.

```zig
var rows = try db.stream(User, c, .{});
defer rows.close();                       // required
while (try rows.next()) |u| try s.print("{d},{s}\n", .{ u.id, u.email });
```

### `Tx`

```zig
var tx = try db.begin(c, .{});
defer tx.deinit();          // rolls back unless committed
_ = try tx.insert(Order, c, .{ … });
try tx.commit();
```

`tx` carries every read and write call above — `select`, `one`, `exactlyOne`,
`find`, `page`, `count`, `exists`, `insert`, `insertMany`, `insertOrIgnore`,
`insertOrUpdate`, `update`, `updateMany`, `updateReturning`,
`updateReturningOne`, `delete`, `deleteReturning`, `deleteReturningOne`,
`raw`, `rawOne`, `rawExactlyOne`, `rawOrdered`, `rawPage`, `exec`, `compose`,
`composed` and `composedOne` — all down the one connection it holds. Not
`stream`: a result set held open keeps the connection busy, so nothing else in
the transaction could run until it closed. Forgetting the `defer` is caught in Debug by a counter
asserted at `db.deinit()`.

**The type is spelled `sql.Db.Tx`**, which only matters when a function of
yours *takes* one — `fn append(self: *Bus, tx: *sql.Db.Tx, …)`. Every example
here starts with `var tx = try db.begin(…)` and infers it, so the name never
had to be written down until something wanted to be handed a transaction
somebody else opened. It hangs off `Db` rather than off the module because a
transaction belongs to the pool it came out of; `sql.Tx` does not exist.

| | |
|---|---|
| `db.begin(c, .{ .isolation = …, .read_only = … })` | both ride on the `BEGIN` itself, so neither costs a round trip. `.isolation` is `.read_committed`, `.repeatable_read` or `.serializable`; left out means whatever the server is set to |
| `db.begin(c, .{ .rebuilding = true })` | SQLite only: foreign keys off for the transaction and checked once before the COMMIT, which answers `error.ForeignKeyViolated` for a row pointing at nothing. What rebuilding a table needs, and what `migrate.apply` asks for. A compile error on Postgres |
| `tx.deadline(ms)` | bound every statement after it, for the life of this transaction. `error.TimedOut` past it |
| `tx.savepoint()` | `!Savepoint` — a mark one part of the transaction can be undone back to; see below |

```zig
var tx = try db.begin(c, .{});
defer tx.deinit();
try tx.deadline(2_000);                   // one round trip
const rows = try tx.select(Report, c, .{ .where = … });
```

**Only a transaction has one**, and that is the design
([ADR 043](../adr/043-a-deadline-needs-a-connection-you-hold.md)): a deadline
is always a second command, so it has to go down the same connection as the
statement it bounds. `db.select` takes whichever connection is free and gives
it straight back, so there is nothing to set one on. Postgres undoes it when
the transaction ends, however it ends. For a floor under everything, set it on
the role: `ALTER ROLE app SET statement_timeout = '30s'`.

#### Holding the rows a read matched

A read inside a transaction can hold what it matched until that transaction
ends, which is what makes read-modify-write safe.

| | |
|---|---|
| `.lock = .update` | hold every matching row against another writer, waiting for anyone already holding it |
| `.lock = .update_nowait` | the same, except a row somebody else holds fails at once with `error.Locked` |
| `.lock = .update_skip_locked` | the same, except a row somebody else holds is left out of the answer — a work queue |
| `.lock = .share` | hold against a writer, and let other readers hold it too |

```zig
var tx = try db.begin(c, .{});
defer tx.deinit();
const held = try tx.select(Item, c, .{ .where = .{ .id = id }, .lock = .update });
_ = try tx.update(Item, c, .{ .set = .{ .qty = held[0].qty - 1 }, .where = .{ .id = id } });
try tx.commit();
```

`find` has no `.lock` — it takes a key rather than options — so a locked read
of one row is `tx.one(Row, c, .{ .where = .{ .id = id }, .lock = .update })`.

**A `.lock` outside a transaction is a compile error.** Postgres wraps a lone
statement in a transaction of its own and ends it immediately, so the lock
would be taken and dropped before the handler read a row: the statement works,
and the promise it was written for is missing
([ADR 048](../adr/048-contention-is-what-a-transaction-is-for.md)).

#### Savepoints

| | |
|---|---|
| `tx.savepoint()` | `!Savepoint` — put a mark down |
| `sp.deinit()` | undo everything since the mark, unless it was released. For a `defer` |
| `sp.release()` | `!void` — keep the work, and drop the mark |
| `sp.rollback()` | undo the work now; the transaction carries on |

```zig
var sp = try tx.savepoint();
defer sp.deinit();

if (tx.insert(Tag, c, .{ .name = name })) |_| {
    try sp.release();
} else |err| switch (err) {
    error.AlreadyExists => sp.rollback(),   // it was already there; carry on
    else => return err,
}
```

**This is what a nested transaction is** — Postgres has no nested `BEGIN`, and
an inner "commit" is not durable; it only means the outer transaction may
still commit it. It earns its round trip on one path and that path matters: a
statement that fails inside a transaction aborts all of it, so without a mark
there is no way to try something and carry on.

Undoing or dropping a savepoint destroys every savepoint taken after it, which
is Postgres's rule. A `defer sp.deinit()` on one of those sends nothing rather
than asking the server to release a mark it no longer has.

### Types

| | |
|---|---|
| `sql.Timestamp` | microseconds since the epoch, written as RFC 3339 in JSON. `timestamptz` on Postgres; on SQLite an `INTEGER` holding those microseconds, **which SQLite's date functions do not read as a date**: `strftime('%m', paid_at)` is NULL, and a Row field filled from it fails the query. Divide first, `strftime('%m', paid_at / 1000000, 'unixepoch')`, or work the month out in Zig ([Dates out of a Timestamp](../guide/sql/sqlite.md#dates-out-of-a-timestamp)). `.now()`, `.fromSeconds(s)`, `.seconds()`, `.nilo_parse(text)` |
| `sql.Date` | a calendar day: `days` since 1970-01-01, written as `2026-09-17` in JSON and described as `format: date`. `date` on Postgres, `TEXT` on SQLite, and **read out of the column rather than out of a `::text`**, so a `db.raw` reading one needs no cast. `.fromDays(n)`, `.nilo_parse(text)`, `.utcOf(ts)`, `.atMidnightUtc()`. A day is not a moment: a due date read into a `timestamptz` gets a midnight, a midnight has a zone, and the date then moves by a day for a reader in Jakarta ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)). It carries a value and does not calculate — no `.addDays`, no `.weekday` — and the two conversions it does offer are named for the zone they assume. A day before 1970 is ordinary and prints normally; the range is year 0 to 9999, which is what four digits spell and what `nilo_parse` reads back |
| `sql.Uuid` | `nilo_id`'s [`Uuid`](./id.md#nilo_id), re-exported — the same type either import gives you. `uuid` |
| `sql.Json(T)` | a `T` stored as `jsonb`, parsed per row into the request arena. Not available in `db.stream`, which allocates nothing. In a response it is written and described as the `T` — a **document**, `nilo_json_of = T` beside `value: T` — so a Row with one can still `rename_all` ([ADR 163](../adr/163-a-document-is-its-value.md)). **It is also the intended shape for a list on a row**: a `db.raw` projection with `COALESCE(jsonb_agg(jsonb_build_object(…)), '[]'::jsonb) AS labels` read into `labels: sql.Json([]const Label)` is one statement where a list of labels per row was a round trip per row, and the document says `Label`. **The column is parsed by `std.json` into the field names as written** — a `rename_all` on `T` spells the response, not the column, so a `jsonb_build_object` names `content_type` and the wire says `contentType` |
| `sql.Decimal` | a `numeric`, held as its digits. `.text` is the value; there is no arithmetic. Writes itself into JSON as a **string**, so a consumer's `JSON.parse` cannot round it into an `f64` ([ADR 049](../adr/049-a-column-type-can-come-from-outside-this-module.md)) |
| `sql.Interval`, `sql.Inet` | an `interval` and an `inet`, held as the text Postgres prints. `.text` is the value |
| `sql.Bytes` | bytes rather than text: `bytea` on Postgres, `BLOB` on SQLite. `.bytes` is the value, `sql.Bytes.of(hash)` writes one. The slice a read hands back lives in the request arena, the way a `Str` does. This is what to reach for instead of `sql.AsText("bytea")`, which goes through hex printing and costs a conversion each way ([ADR 141](../adr/141-bytes-are-a-type-not-a-second-protocol.md)) |
| `sql.AsText("money")` | any Postgres type at all, held as its text — the door out of this table. A column type of your own is any struct or enum with `nilo_column`, `nilo_read(text, arena)` and `nilo_write(arena)`; see below |
| a slice | an array column, with no wrapper: `[]const Str` is `text[]`, `[]const i32` is `int4[]`, `?[]const i32` a nullable one, `[]const ?i32` one whose elements may be NULL ([ADR 045](../adr/045-an-array-is-a-slice-and-a-slice-is-one-deep.md)). `[]const u8` is text, so a list of text is `[]const Str` or `[]const []const u8`. `[]const sql.Uuid` is `uuid[]`, in both directions and as an `.in` list ([ADR 116](../adr/116-a-raw-parameter-is-converted-the-way-a-rows-is.md)). Not available in `db.stream` |
| an enum | read out of `text`, a `varchar` or a Postgres enum. A value the Zig enum does not have fails the request. Add `pub const nilo_column = "user_role"` to it and the column is checked at startup — its type name, and on Postgres its values too, so a label the Zig enum lacks or a tag the type lacks is reported before the first request rather than by it — and can be batched. On a table this program builds, a plain enum is a `text` column and its tags become that column's `CHECK`; one that names its own type is the database's to grow with `ALTER TYPE`, and nilo writes none of its words — it only reads them back at startup and says which side is behind |

#### A column type of your own

The list above is what this module chose to know about, and it is not closed.
A struct or an enum carrying three declarations is a column type:

```zig
const Cents = struct {
    value: i64,

    pub const nilo_column = "numeric";

    pub fn nilo_read(text: []const u8, arena: std.mem.Allocator) !Cents { … }
    pub fn nilo_write(self: Cents, arena: std.mem.Allocator) ![]const u8 { … }
};
```

It travels as the text Postgres prints — `"col"::text` on the way out,
`$1::numeric` on the way in — which is the one representation every Postgres
type has, including the ones that arrive with an extension
([ADR 049](../adr/049-a-column-type-can-come-from-outside-this-module.md)).
The column is judged at startup like any other, and the type works everywhere
a column type does: conditions, `.set`, `insert`, a batch.

`sql.AsText(name)` is the whole of that for a type that is just the text, and
`sql.Decimal`, `sql.Interval` and `sql.Inet` are three instances of it. A column
that wants its precision in the DDL writes `sql.AsText("numeric(14,3)")`: the
digits round-trip either way, and `numeric`'s binary form is a base-10000 digit
vector this module has no reason to parse.

**A `Timestamp` reads back what it prints.** `Timestamp.nilo_parse(text)` is
`?Timestamp`, and it is the same declaration that makes a type a path param
and a query field ([ADR 113](../adr/113-a-path-param-can-parse-itself.md)) — so a keyset
cursor the server printed one request ago is an ordinary typed argument
([ADR 127](../adr/127-what-a-server-prints-it-can-read.md)):

```zig
const Page = struct { after: ?sql.Timestamp = null, limit: u32 = 50 };

fn feed(db: *Db, c: *nilo.Ctx, page: nilo.Query(Page)) ![]Event { … }
```

It takes an offset — `2026-08-16T16:30:00+07:00` is the same moment as
`2026-08-16T09:30:00Z` — and fractional seconds, truncated at microseconds
because that is the resolution the column has. It refuses a bare local time with
no zone, because that is not an instant. The round trip is the property that is
tested: what `writeRfc3339` prints, `nilo_parse` reads back to the same
microsecond.

Two mistakes stop at compile time: one of `nilo_read`/`nilo_write` without the
other, and both without a `nilo_column`. **An array of one is not read** —
`[]const Decimal` is the same boundary it always was.

An array column is judged **exactly**: an `int4[]` reads into a `[]const i32`
and not into a `[]const i64`, because the driver picks its element decoder off
the array's own type. An array with a NULL in it read into a non-optional
element, or an array more than one dimension deep, fails the request rather
than the process.

### Errors

| | |
|---|---|
| `error.AlreadyExists` | a unique violation (`23505`). **409** by default |
| `error.ForeignKeyViolated` | `23503` — a row this statement names is not there, or a row it removes is still named by another. No default status: a 409 for a delete that lost a race, a 400 for an insert naming a parent that never existed |
| `error.NotNullViolated` | `23502`. 500: a Row and a table that disagree |
| `error.CheckViolated` | `23514` — a `CHECK` somebody wrote on purpose, so the endpoint that tripped it usually knows what it means |
| `error.ConstraintViolated` | the rest of class 23 — an exclusion constraint, a `RESTRICT` |
| `error.Disconnected` | the database went away, or was never there. **503** by default |
| `error.RolledBack` | the database rolled the whole transaction back: a serialization failure (`40001`) under `.repeatable_read` or `.serializable`, a deadlock (`40P01`), or a plan a running migration changed the answer of. Nothing in it was kept, and running the whole transaction again is the answer. **503** by default |
| `error.TimedOut` | a statement ran past `tx.deadline`. No default status — what a deadline means is the handler's to decide |
| `error.Locked` | a `.lock = .update_nowait` found a row somebody else is holding. No default status — a held row is a 409, a 503 or a retry depending on the endpoint |
| `error.QueryFailed` | anything else, including a statement or a `tx.commit()` on a transaction an earlier failed statement aborted, and an `update` or `delete` whose condition the values it was given emptied. The server's own words are on `Sent.problem` for a watcher and in the log; they never reach the client ([ADR 117](../adr/117-a-statement-that-failed-says-what-the-database-said.md)) |

Both Wires answer the same word for the same failure. SQLite's extended result
codes name the three above natively, which is what lets a handler tested against
SQLite branch on what Postgres will send it.

**`sql.problem(c)` is what the name cannot carry** — *which* unique index fired
([ADR 117](../adr/117-a-statement-that-failed-says-what-the-database-said.md)):

```zig
db.delete(Staff, c, .{ .where = .{ .id = id } }) catch |err| switch (err) {
    error.ForeignKeyViolated => return nilo.fail.conflict(
        "{s} was given something to do a moment ago and can no longer be deleted.",
        .{name},
    ),
    else => return err,
};
```

```zig
const said = sql.problem(c) orelse return err;
if (std.mem.eql(u8, said.constraint, "staff_email_key")) …
```

It answers a `sql.Problem` — `code`, `constraint`, `detail`,
`message` — for the last statement **this fiber** ran, and null when it worked.
It belongs to the call rather than to the `Db`, which is one Service shared by
every request in flight: it is bound to the fiber, every statement clears it, and
a Scope that is not the one the failure happened under gets null rather than
somebody else's row. Read it in the `catch` — it lives as long as the request
does, and the next statement replaces it.

`db.watching` is unchanged and is still the way to see *every* statement. The two
answer different questions.

**`sql.violated(c, Row, .{ .email })` is the same question with the constraint
named by its columns**, which is the form to branch on:

```zig
error.AlreadyExists => if (sql.violated(c, Staff, .{.email}))
    return nilo.fail.conflict("that address is already on the staff", .{})
else
    return err,
```

The columns are checked while compiling against the key and every `.unique`
the marker declares, in any order, so a unique that is renamed or dropped is a
build error wherever a handler branches on it. It accepts both databases'
spellings: Postgres reports the constraint's name, `staff_email_key`, and
SQLite the columns, `staff.email`. `Problem.constraint` on SQLite is the text
after `constraint failed:` for the same reason. A foreign key is not accepted,
because SQLite does not say which one failed.

### Migrations

The marker words above are the schema half; this is what reads them. It
is `sql.migrate`, `sql.table`, `sql.ddl` and `sql.snapshot`, and a program that
never names one links none of it — 0 bytes on `zig build size-sql`, both probes
([`bench/result/sql.md` §10](../../bench/result/sql.md)).

```zig
const Org = struct {
    pub const nilo_table = .{ .name = "orgs", .key = .id };

    id: i64,
    name: []const u8,
};

const State = enum { draft, live, archived };

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .default = .{ .created_at = .now, .state = .draft, .seats = 1, .tags = &.{} },
        .unique = .{
            .{ .columns = .{.email}, .ignoring_case = true,
               .name = "users_one_account_per_address" },
        },
        .index = .{
            .created_at,
            .{ .columns = .{ .org_id, .{ .created_at = .desc } },
               .where = .{ .deleted_at = null } },
        },
        .references = .{ .org_id = .{ Org, .id, .cascade } },
        .check = .{
            .users_seats_are_positive = "seats > 0",
            .users_state_is_known = .{ .words_of = .state },
        },
        .trigger = .{
            .users_touch = .{
                .when = "BEFORE UPDATE",
                .run = "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
            },
        },
        .was = .{ .email = "handle" },
    };

    id: i64,
    org_id: i64,
    email: []const u8,
    nickname: ?[]const u8,
    state: State,
    seats: i32,
    tags: []const []const u8,
    created_at: sql.Timestamp,
    deleted_at: ?sql.Timestamp,
};
```

| in the marker | what it says |
|---|---|
| `.default = .{ .created_at = .now }` | what the database writes when an insert leaves the column out. `.now` is the one word, and only on a `sql.Timestamp`; everything else is a literal of the column's own Zig type, which has to coerce or it does not compile. A column with words of its own takes one of them the way a column is written: `.draft`, not `"draft"`. A default the database has to work out — `DEFAULT (lower(x))` — is still a step, and one on a generated key is a Refusal |
| `.filled = .{ .number, .created_at }` | columns the database fills by means the marker cannot say: a `DEFAULT` written in a step, `gen_random_uuid()`, a trigger. Renders no DDL; it lets an insert leave them out. `.filled = .created_at` for one. A column also in `.default`, the integer key a sequence fills, and a name that is not a column are each a Refusal ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)) |
| `.unique = .{ .email }` | one column. `.{ .{ .tenant_id, .name } }` is one constraint over two |
| `.{ .columns = .{.email}, .ignoring_case = true }` | the named form. `.ignoring_case` is `lower(...)` on Postgres and `COLLATE NOCASE` on SQLite, and it is a Refusal on a column that is not text. The lookup it serves is `.email = .{ .ieq = address }`, which folds both sides the same way |
| `.name = "users_one_account_per_address"` | what the constraint is called, on a `.unique`, an `.index` or a `.references`. **The name is the error message**: Postgres reports a violation by constraint name and nothing else, so this is the difference between a sentence and a column list. Text rather than `.a_word`, because that is what the database prints |
| `.index = .{ .created_at }` | the same three shapes, without the uniqueness |
| `.{ .created_at = .desc }` | one column of an index read downwards. `.asc` is the default and needs no saying; a direction on a `.unique` is a Refusal, since a unique index is not read in order |
| `.where = .{ .deleted_at = null }` | a partial index. The same grammar a `db.select` condition uses, not a string: `null` is `IS NULL`, `.{ .ne = null }` is `IS NOT NULL`, a literal is `=` and `.{ .ne = lit }` is `<>`. A name that is not a column is a Refusal and a literal of the wrong type does not compile. An index over an expression — `lower(btrim(site))` — is still a step |
| `.references = .{ .org_id = .{ Org, .id } }` | keyed by the column doing the pointing, and it names the **Row** rather than a table, so renaming the table moves the key with it. A third entry says what happens on delete: `.cascade`, `.restrict` or `.set_null` |
| `.{ "orgs", .id, .cascade }` | the same key with the table named as text, for a program whose files may not import each other's Rows. **The type check is not given up**: it runs against the Row list the tool was given, and a table no Row in that list claims is a Refusal ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)) |
| `.epic = .{ .columns = .{ .epic_id, .department_id }, .to = .{ WorkEpic, .{ .id, .department_id } } }` | a foreign key over two columns, which is how "the Epic has to be on the same board" gets said once instead of in a `.data` step and two `.unique` entries. Keyed by a label rather than a column, because a Zig field name cannot be a tuple. `.to` takes a Row or a name, and `.on_delete` and `.name` belong in the same entry. A composite key is written as a table constraint; a one-column key stays inline, so nothing generated before this changed |
| `.tags = &.{ "a", "b" }` | an array column's default, written as a list. Each element goes through the column's own element type, and a comma, a brace, a quote, a backslash or an apostrophe inside one is escaped so it does not change how many elements there are ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)) |
| `.check = .{ .users_seats_are_positive = "seats > 0" }` | a `CHECK`, keyed by the name it goes into the database under. **nilo does not read the body**: it writes it, hashes it, and notices when the hash moves — so a changed body is one drop and one create, and a name the types no longer have is a drop. Written inside the `CREATE TABLE`, so SQLite takes it; changing one there is the same rebuild every other table constraint needs ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)) |
| `.users_state_is_known = .{ .words_of = .state }` | the same word, naming the `CHECK` an enum column already generates, instead of `users_state_check`. Moving that name is a migration: the constraint in the database still has the old one |
| `.trigger = .{ .users_touch = .{ .when = …, .run = … } }` | a trigger, in two halves, because nilo writes `ON "users"` between them. The table is the one thing the marker already knows, and a second copy of it stops matching the day the table is renamed. Both databases create, replace and drop one |
| `.was = .{ .email = "handle" }` | this column used to be called that. The old name is text, because it is not a column any more |
| `.managed = false` | somebody else builds this table. `plan`, `createMissing` and `generate` skip it entirely |

A column the Row reads as a **Zig enum** needs nothing said about it: it is a
`text` column with `CHECK ("state" IN ('draft', 'live', 'archived'))` beside it,
named `users_state_check` unless `.check` gave it another, and the words are in
the snapshot — so adding a tag to the enum is a migration rather than an insert
the database refuses. An enum
that names its own database type with `pub const nilo_column = "user_role"` is
the database's: its words are added with `ALTER TYPE`, and nilo neither writes
them nor judges them at startup.

**`.managed = false` is for the table this program reads and does not own.** A
foreign key is checked against the Rows the tool was given, whether it names a
Row or the table as text, so `comments.author_staff_id` cannot say it points at
`staff` without a `Staff` Row in that list — and a Row in the list is part of
the schema the diff sees, so the tool emits `CREATE TABLE staff` for a table
that has existed for a year and whose real definition has twenty columns this
program never needed. One word settles it:

<!-- compiles -->
```zig
const Staff = struct {
    pub const nilo_table = .{ .name = "staff", .managed = false };

    id: i64,
    email: Str,
};

comptime {
    _ = Staff;
}
```

Everything else about the Row is unchanged — `.references` may point at it,
`db.checking` still holds it against the live schema, and every statement reads
it the same way. What changes is only who *builds* it
([ADR 130](../adr/130-a-table-this-program-reads-and-does-not-build.md)). The
word is written into `migrations/snapshot.zon`, where `managed: true` is silence
and `managed: false` is a line, so a program that starts or stops building a
table is a visible change in a reviewed file.

A name nobody gives follows Postgres' own convention, so a schema nilo
generates and one somebody wrote by hand look the same: `users_email_key`,
`users_org_id_created_at_idx`, `users_org_id_fkey`, `users_state_check`.

**Every name is checked at 63 bytes, whatever the database is.** Postgres cuts
a longer one down on the way in and says so in a `NOTICE` nothing here reads,
which leaves the snapshot holding a name the database does not have and two
constraints whose first 63 bytes agree colliding on the second `CREATE`. So a
name over the limit is a compile error — the given one says "make it shorter",
the derived one says "give the entry a `.name`". SQLite has no limit and is
held to the same 63, because a schema that compiles for one database and
quietly loses a name on the other is the opposite of what one type describing
both is for. Two entries that end up with the same name are a Refusal too.

**A key that is an integer is generated and one that is not is supplied.** That
is a rule rather than a word in the marker: `id: i64` becomes
`GENERATED BY DEFAULT AS IDENTITY` on Postgres and
`INTEGER PRIMARY KEY AUTOINCREMENT` on SQLite, and `id: sql.Uuid` becomes a
`NOT NULL PRIMARY KEY` the insert has to fill.

#### The schema

```zig
pub const schema = sql.Schema{
    .extensions = &.{"pgcrypto"},
    .functions = &.{
        .{ .name = "set_updated_at", .body = @embedFile("sql/set_updated_at.sql") },
    },
    .tables = &.{ Org, User, Post },
    .views = &.{
        .{ .name = "sku_catalogue", .body = @embedFile("sql/sku_catalogue.sql") },
    },
};
```

One value, and the one value `db.checking`, `cli.Tool`, `createMissing`,
`addMissingColumns` and the diff are all given — so the three cannot drift
([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)).
`.tables` is every Row, in any order. The other three lists hang off the
schema rather than off a table, and each has a default of none:

| | |
|---|---|
| `.extensions` | names. `CREATE EXTENSION IF NOT EXISTS "x"`; `DROP EXTENSION` when the name leaves, marked destructive. A Refusal on SQLite |
| `.functions` | `.{ .name, .body }`, the body the **whole** `CREATE OR REPLACE FUNCTION <name> …` statement — a Refusal if it opens with anything else. New or moved is that one statement; gone is `DROP FUNCTION IF EXISTS`. A Refusal on SQLite |
| `.views` | `.{ .name, .body }`, the body the `SELECT` — nilo writes `CREATE VIEW "name" AS` in front, and a body that opens `CREATE` is a Refusal. Moved is a drop and a create, gone is a drop |

**The tool owns the order**: extensions, functions, tables by reference, each
table's indexes and triggers, then views. A stale view is dropped before any
table moves and a new one made after every table has, so a view that reads a
column about to go is never in the way. In the snapshot an extension is its
name and a function or a view is a name and a hash, the way a check is.

#### Creating tables

```zig
try sql.migrate.createMissing(&db, &run, schema);
```

One `CREATE TABLE IF NOT EXISTS` per Row plus its indexes, in one transaction —
and before them the schema's extensions and functions, after them its views,
each in the form that may already have run (`CREATE OR REPLACE VIEW` on
Postgres, which has no `IF NOT EXISTS` for a view, and `IF NOT EXISTS` on
SQLite). **The order is worked out while compiling**, not from the list:
foreign keys are written inline, which is the only shape SQLite has, so `orgs`
is created before `users` whichever way round they are written. Two tables
pointing at each other is a compile error naming both.

This is for a test, a fixture or a single-file SQLite application. It is not a
migration: it creates what is missing and never alters what is there.

`addMissingColumns` is the step after it, for the same program once it has
shipped and added a field: one `ALTER TABLE … ADD COLUMN` per column a table
lacks, from the same `Desc` the create reads, in one transaction, and how many
were added. A required column with no default is `error.NeedsBackfill` with
the statement in the log and nothing sent; a table that is not there is
skipped ([ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)).

```zig
try sql.migrate.createMissing(&db, &run, .{ .tables = &.{ Download, Segment } });
_ = try sql.migrate.addMissingColumns(&db, &run, .{ .tables = &.{ Download, Segment } });
```

| | |
|---|---|
| `migrate.createMissing(db, scope, schema)` | the above |
| `migrate.addMissingColumns(db, scope, schema)` | `!usize` — the columns added |
| `migrate.desiredOf(D, schema)` | comptime: the `Desired` half of a diff — every table as the types describe it, in create order, and the schema's other three lists |
| `migrate.tablesOf(D, schema)` | comptime: just the tables, as `[]const Table` |
| `migrate.missingOf(D, schema)` | comptime: just the table statements |
| `ddl.createTable(D, Row)` | comptime: one `CREATE TABLE`, as text |

#### The diff

```zig
const change = try sql.migrate.plan(arena, Db.Dialect, desired, before);
```

`desired` is `migrate.desiredOf(D, schema)` — the types. `before` is a
`snapshot.Doc`, which is `migrations/snapshot.zon` read back. **Both halves are
files, so a diff needs no database**, and two branches that both generate
conflict in git rather than at deploy.

`Plan.steps` is what to run, in order, each with its `kind`, its `sql` and a
line of `why`. `Plan.problems` is what the diff will not write, and **every one
of them is collected rather than the first being returned**. Two are refused on
purpose: a column that moved in a way SQLite cannot follow — its type, its
nullability, its default or an enum's words, since SQLite has neither
`ALTER COLUMN` nor a way to replace a constraint — and any foreign-key change on
a table that already exists, on both dialects, because the one-statement form
takes an `ACCESS EXCLUSIVE` lock and scans the table. The `Problem` spells out
the `ADD CONSTRAINT … NOT VALID` then `VALIDATE CONSTRAINT` pair to write
instead. **A column that moved three ways gets one `Problem` naming all three**,
because what it needs is one rewrite and not three.

`Plan.destructive()` and `Plan.needsBackfill()` are the two questions a command
asks before writing a file out. `Plan.unnamed(gpa, names)` is the destructive
steps' targets that `names` leaves out, and `Plan.stray(gpa, names)` is the
names no destructive step has; both empty is what lets `generate` write. A
destructive step's `target` is `orders`, `orders.note` or `extension:pgcrypto`.
A `change_type` is destructive unless the type widens (`int4` to `int8`,
`float4` to `float8`, an integer into `numeric`, `varchar` into `text`). A column added `NOT NULL` **with a `.default`
needs no backfill**, which is the case ADR 123 named as the one moment a
default is load-bearing.

#### The ledger, and applying

```zig
const chain = try sql.migrate.chainOf(arena, manifest.versions);
const ran = try sql.migrate.applyPending(&db, &run, chain);
```

A `Version` is a number, a name and its steps, and **it holds no hash** — a hash
a caller can fill in is a hash a caller can fill in wrong, and a wrong one turns
the drift check into decoration. `chainOf` is the only thing that computes one:
it walks the list once and hands back a `Chain`, which is the versions plus a
hash each, with `.head()`, `.headHash()` and `.len()`.

The hash is **chained**: each one is taken over the version before it, so editing
version 3 moves the hash of 3 and of everything after it, and `migrate.drift`
finds the edit by looking at the head rather than by walking the lot. It is over
the SQL rather than over the file bytes, so reformatting a generated file does
not read as tampering and changing a statement does.

`nilo_migrations` is an ordinary Row — `migrate.Applied` — and **its columns are
a contract**, because a program in another language may have to write a row into
it ([ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)):

| Column | Postgres | SQLite | What it holds |
|---|---|---|---|
| `version` | `int8 PRIMARY KEY` | `INTEGER PRIMARY KEY` | the number in the file name. Supplied, never generated |
| `name` | `text NOT NULL` | `TEXT NOT NULL` | the rest of the file name, `a-z`, `0-9` and `_` |
| `hash` | `text NOT NULL` | `TEXT NOT NULL` | 64 hex characters: SHA-256 of the steps, chained onto the version before |
| `applied_at` | `timestamptz NOT NULL` | `INTEGER NOT NULL` | when. SQLite holds microseconds since the epoch (ADR 067) |
| `ms` | `int8 NOT NULL` | `INTEGER NOT NULL` | how long it took. `0` is allowed and means nobody timed it |

`migrate.expect` reads the highest `version`; `migrate.drift` compares `hash`
against what the steps hash to now. A row with the right `version` and a wrong
`hash` is what `verify` is for. `apply`
is one transaction: take the advisory lock, check whether this version is
already there, run every step, insert the row, commit. It answers `false` when
the version had already been applied, which is what nine of ten replicas booting
together get.

`migrate.applyPending(&db, &run, chain)` is the whole list, in order, one
transaction each, answering how many ran. That is the in-process runner a
single-file SQLite application calls from `app.before`, inside `listen()`. It
makes the ledger if it is not there and reads it once: a version recorded under
another hash stops it before anything runs, `error.SchemaDrift`, and a version
already recorded is skipped without a transaction. On SQLite each version
begins with `.rebuilding`, so a table rebuild's `DROP` does not cascade into the
rows pointing at it. `migrate.ensureLedger` is the first half on its own, under
the same lock.
`migrate.drift(&db, &run, chain)` answers which applied versions have been
edited since — a `Drift` per version with what the ledger recorded and what the
steps hash to now.

**The lock is not decoration.** `pg_advisory_xact_lock` is taken inside the
transaction and released by the commit, so ten replicas starting at once run the
migration once. SQLite has no advisory lock and needs none: one writer is the
database.

A version is a **list of steps**, and `Kind.data` is the one the diff never
produces. That is what makes expand and contract expressible — the backfill goes
between the `add_column` that made the column and the `change_null` that
tightens it, in one transaction, in one version.

#### Refusing to serve a database that is behind

```zig
db.expecting(manifest.head);
```

One query, run by `listen()` on the pool it just opened. **This is the check
almost nothing has**, and it catches one incident shape: the code went out
before the migration did, and every request that touches the new column
answers 500 until somebody notices. `sql.migrate.expect(&db, &run,
manifest.head)` is the same check as a call, for a script with a `Run` in
hand.

A database *ahead* of the binary is allowed and only logged. That is the
ordinary middle of a two-stage deploy, and refusing it would make expand and
contract impossible.

`migrate.standing(db, scope, want)` is the same query as a value — `.at`,
`.want` and a `.verdict()` of `.level`, `.ahead` or `.behind` — for a program
that would rather decide than be refused.

#### The files

```zig
const state = try sql.migrations.read(gpa, io, dir, Db.Dialect);
const out = try sql.migrations.generate(gpa, io, dir, Db.Dialect, desired, .{
    .name = "add_nickname",
});
```

`read` opens a `migrations/` directory and hands back the snapshot it holds and
every version file in it, sorted. `generate` runs the diff and writes three
files: `NNNN_name.zig`, then `manifest.zig`, then `snapshot.zon`. **In that
order, and it matters** — a run that dies halfway leaves a snapshot that is
still behind, and the next run generates the same version again rather than
skipping it.

`check` is `generate` with nothing written: the same `Plan`, so CI and the
person at the keyboard are looking at one answer. It also names any `.sql` twin
that has gone stale, which is the one thing it reports that is not in the
`Plan`.

**Every version file has a `.sql` twin beside it**, written by the same
`generate` and regenerated whenever the `.zig` is
([ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)):

```
migrations/0007_work_items_get_a_priority.zig
migrations/0007_work_items_get_a_priority.sql
```

It is the version's statements in order, each with its `why` above it as a
comment, wrapped in `BEGIN`/`COMMIT`, with the ledger table created if it is not
there and the ledger row on the end. `psql -f`, a CI job with no toolchain or
somebody on a jump host can bring a database to head with it, and
`db.expecting(manifest.head)` still serves the result and `verify` still holds
the hash. **It is an output**: nilo reads the `.zig` and never this, and a
version written in SQL by somebody else is not picked up.

The twin's hash is chained onto the version before it, so it is written from the
compiled manifest — `Options.versions`, which `db generate` passes from what
`Tool.run` was given. One case cannot be written: `--baseline` rewriting a
version 1 whose `before` or `after` hold hand-written steps, because those are
Zig nothing has compiled yet. The `Outcome` says so with `twins_deferred`, and
`db check` asks for the file after the rebuild.

An `Outcome` says which of three things happened. `isEmpty()` means the Rows and
the migrations already agree. `wasHeld()` means the version was not written:
the diff reported a `Problem`, or something in it loses data that
`Options.drop` did not name (`.unnamed`), or `Options.drop` named something it
does not drop (`.stray`). Anything
else wrote the file named in `.file`.

| | |
|---|---|
| `migrations.read(gpa, io, dir, D)` | the snapshot and the version list on disk |
| `migrations.check(gpa, io, dir, D, desired)` | the `Plan`, written nowhere |
| `migrations.generate(gpa, io, dir, D, desired, opts)` | the `Plan`, written out |
| `migrations.renderVersion(gpa, n, name, steps, opts)` | one version file, as text |
| `migrations.renderManifest(gpa, entries, opts)` | the manifest, as text |
| `migrations.spliceGenerated(gpa, old, steps)` | the same file with only its generated block replaced |
| `migrations.renderSql(gpa, D, version, name, hash, source)` | one `.sql` twin, as text |
| `migrations.writeSql(gpa, io, dir, D, versions, entries)` | every twin, written; how many changed |
| `migrations.staleSql(gpa, io, dir, D, versions, entries)` | the twins that are missing or out of date, by name |
| `migrations.sqlTwin(gpa, file)` | `0007_name.zig` → `0007_name.sql` |
| `migrations.checkName(name)` | `a-z`, `0-9` and `_`, or `error.BadName` |

A version file is **one `.zig` file holding a list of steps**, because a
prepared statement is one statement and nilo prepares everything it sends
(ADR 051). Splitting a `.sql` file into statements means a lexer that knows
about `;` inside a string literal and inside `$$…$$`, and getting it subtly
wrong runs three quarters of a migration. The list is already split.
[ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md) is the
argument, including what the layout costs.

**Only one declaration in that file is generated.** The rest is the caller's,
and it survives a rerun
([ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)):

```zig
pub const before: []const migrate.Step = &.{};   // yours, runs first
pub const after: []const migrate.Step = &.{};    // yours, runs last

pub const version: migrate.Version = .{
    .number = 1,
    .name = "schema",
    .steps = before ++ generated ++ after,
};

// nilo:generated begin
const generated: []const migrate.Step = &.{ … };
// nilo:generated end
```

`before` exists as well as `after` because a generated step can *need* a
hand-written object: a `CREATE EXTENSION citext` has to run before the column
whose type comes from it. `migrations.generated_begin` and `generated_end` are
the two marker lines, matched whole; a file that has lost one is refused with
`error.NoGeneratedBlock` rather than rewritten.

#### The commands

```zig
const Tool = sql.cli.Tool(Db, .{ .tables = &.{ User, Org } });
return Tool.run(gpa, io, out, try sql.cli.parse(argv[1..]), &db, manifest.versions);
```

A project's migration tool is a `main` of ten lines. `sql.cli` owns argument
parsing, dispatch and **every sentence a person reads**; the caller owns the
allocator, the connection string and the `Db` type, because nobody else knows
them. `run` takes a `Db` that is already started and hands back an exit code
rather than calling `std.process.exit`.

| Command | What it does |
|---|---|
| `generate --name <snake_case> [--drop <what>,…] [--baseline]` | diff the Rows against the snapshot and write the next version. No database |
| `check` | the same diff, written nowhere, plus any stale `.sql` twin. Exit 1 when they disagree. No database |
| `status [--sql]` | which versions this database has. `--sql` prints the waiting statements |
| `migrate` | apply what is waiting, one transaction per version, behind the lock |
| `verify` | has an applied version been edited since it ran? |

Every command takes `--dir <path>`, which defaults to `migrations`. There is no
`down`; `generate` is forward-only by design, and the usage text says so where
somebody will ask.

**The exit code is the API for CI.** `0` did what was asked. `1` the caller has
something to do — a diff `check` found, a version `generate` held back, drift
against the ledger, versions waiting. `2` the command line was wrong. A CI job
branches on those without reading a word.

`--drop` is what stands between a renamed field and a dropped column, and it
**names what it drops**: `--drop users.nickname,notes,extension:pgcrypto`.
`generate` writes nothing at all when a step loses data that is not named, or
when a name matches nothing: it prints each loss with its statement, then the
command with the names filled in, and exits 1. Run that and the generated file
records it, in a `// Written with --drop …` line at the top and as
`.destructive = true` on each step. A bare `--drop` names nothing.

`status` marks a version `edited` rather than `applied` when its file no longer
hashes to what ran. It is the command people type first, so it is the one that
has to stop saying everything is fine.

**`--baseline` is for porting a schema**, which is one version written over and
over rather than many versions. It ignores the snapshot, diffs the Rows against
nothing, and rewrites version 1 in place along with the manifest and the
snapshot, keeping everything outside the file's generated block. It is the only
thing here that writes over a file that already exists, so it refuses three
ways: a version it is not re-deriving is in the directory, `--name` disagrees
with the version 1 already there, or the file has no generated block. Each
message names the files, and nothing is written.

#### Starting a migrations directory

`generate` writes `manifest.zig`, and the tool imports it — so the first build
needs one before the first `generate` can run. Write it once:

```zig
const std = @import("std");
const migrate = @import("nilo_sql").migrate;

pub const head: i64 = 0;
pub const versions: []const migrate.Version = &.{};

pub fn chain(gpa: std.mem.Allocator) !migrate.Chain {
    return migrate.chainOf(gpa, versions);
}
```

From then on it is the tool's file, rewritten by every `generate` and never
edited by hand.
