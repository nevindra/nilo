# nilo_sql

**`nilo_sql` talks to Postgres and SQLite through one API: a Row is a struct that names its table, and every statement is fixed while compiling.**

**Guide:** [Talking to a database](../guide/sql/README.md), [Tables](../guide/sql/tables.md), [Reading](../guide/sql/reading.md), [Writing](../guide/sql/writing.md), [Transactions](../guide/sql/transactions.md), [Raw SQL](../guide/sql/raw.md), [SQLite](../guide/sql/sqlite.md), [Migrations](../guide/sql/migrations.md) · **Design:** [The query builder](../design/sql-query.md), [The SQL runtime](../design/sql-runtime.md), [SQL column types](../design/sql-types.md), [Raw statements](../design/sql-raw.md), [Migrations](../design/sql-migrations.md)

## `nilo_sql`

A separate module, imported on its own. A project that never imports it links none of it ([ADR 037](../adr/037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)).

**Two databases, one API.** `sql.Db` is Postgres and `sql.Sqlite(…)` is SQLite. Everything else on this page is written once and works against either. [SQLite](#sqlite) says what it takes to open one and lists the five things it refuses.

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
| `.unread = .{ .created_at = sql.Timestamp }` | columns the table has that this Row does not read, each with its type. This is for the response Row that leaves out its timestamps. The columns are in the table, the migration diff and `db.checking`. `.where`, `.order`, `.set`, `.default`, `.index` and an insert's values can name them, on this Row and on every Row that borrows it. They are in no `SELECT` list of this Row, and a narrower Row reads one by carrying it as a field. One that is not optional needs a `.default` or `.filled`. Not allowed as a `.key`, or as a name the Row also reads ([ADR 234](../adr/234-a-table-row-may-declare-a-column-it-does-not-read.md)) |
| `pub const nilo_table = Other` | a narrower Row: the same table as `Other`, fewer columns, checked against it while compiling |
| `pub const nilo_table = .projection` | a Row with no table at all: the shape `db.raw` fills. See below |
| `pub const nilo_beside = .{ .attachments }` | fields **beside** the columns: on the Row, in its JSON and its API document, and in no statement. See below |
| `pub const nilo_through = .{ .customer_name = .{ .customer_id, .name } }` | on a narrower Row: a field that is a column of another table, reached through the reference columns listed before it. Flat in the response, where a parent is nested. `.{ .path = .{ … }, .otherwise = v }` reads `v` where the path does not reach a row, and `.{ .path = .{ … }, .join = .inner }` leaves that row out. See [`nilo_through`](#nilo_through) |
| `pub const nilo_via = .{ .approver = .approver_id }` | on a narrower Row: which column a parent or a list of children follows, when the schema has several or none. See [A parent, children, a group](#a-parent-children-a-group) |
| `pub const nilo_aggregate = .{ .n = .count, .owed = .{ .sum = .amount } }` | on a narrower Row: the computed fields, which make the Row one row per group. An entry may carry a `.where`. See [A parent, children, a group](#a-parent-children-a-group) |
| `pub const nilo_children = .{ .lines = .{ .order = .{ .position = .asc } }, .n = .{ .count = Line } }` | on a narrower Row: a children field's `.order` and `.where`, and a count, a max or a min over the rows pointing back. See [A parent, children, a group](#a-parent-children-a-group) |

#### `.projection`: a Row with no table

**A result shaped like no table (a window function, a CTE, a join no reference names) is read into a `.projection` Row** ([ADR 125](../adr/125-a-row-that-owns-no-table.md)):

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

It has every column type, reader and conversion an ordinary Row has, but no table. So `db.select`, `db.find`, `db.insert` and the migrator all reject it while compiling, naming the type and saying it is a projection. It is for `db.raw` and `db.exec`. Before this, the only way to write such a shape was to give it a `.name` pointing at a real table it did not match, which compiled and then gave no warning when somebody used `db.select` on it.

#### `nilo_beside`: fields that are not columns

**`nilo_beside` names fields the program adds to a Row that no column holds**, such as a comment's attached files, read in a second statement or supplied by a service ([ADR 178](../adr/178-a-row-can-carry-a-field-no-column-holds.md)):

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

To the JSON writer and the API document the field is an ordinary typed field. It is in no statement:

- no `SELECT` list reads it, and `db.raw` counts the statement's columns against the columns only;
- every read leaves it at its declared default, for the caller to fill;
- `db.checking` does not look for it, and a Row borrowing a table does not need to find it there.

A `.where`, an `.order`, a `.set`, an insert or a `.key` naming it is rejected by name, and so is a name the Row does not have or a field with no default. **For a list the database can build, `sql.Json(T)` is still the better choice**: `jsonb_agg` in the statement, one round trip, and the document says `T`.

### `Db`

```zig
var db = sql.Db.init(gpa, "postgres://…", .{});
defer db.deinit();
db.checking(.{ .tables = &.{ User, Order } });   // optional
db.expecting(manifest.head);      // optional
db.watching(sql.logging);         // optional
try app.provide(&db);
```

`init` opens nothing. The pool is built by `listen()`, which is the only moment there is an event loop to dial through. So a server starts with its database switched off, and the first request that needs it gets `error.Disconnected`.

**Call `db.checking` once.** A second call, with the same schema or another, makes the boot fail with `error.CheckedTwice` rather than replacing the first list. A program whose tables are owned by several files joins them into one `sql.Schema` (`.tables = a.tables ++ b.tables`), the same value `createMissing` and the migrations tool are given ([ADR 192](../adr/192-a-db-with-no-schema-check-says-so-or-is-told.md)).

#### `db.expecting`

**`db.expecting(version)` refuses to serve a database whose migration ledger is behind `version`.** It is checked once at boot, after the work `app.before` registered has run and before the first request ([ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)). `db.checking` runs at the same point, so a `createMissing` or a migration in `before` runs first and the check reads what it made.

It is a call rather than an option because an option is read on every boot and links the migration module into every program with a `Db`, measured at 17,296 bytes. A program that never calls it links none of it.

#### `db.watching` and `sql.Sent`

**`db.watching(f)` calls `f` with a `sql.Sent` after every statement.** A `Sent` holds:

- the statement text;
- the plan name it is kept under (including a `db.raw` statement's; null for `db.exec`, a request-chosen `ORDER BY`, a `Composed` and a `Db` with `prepared = false`);
- how long the database took, how many rows moved, and whether it failed;
- `route`, the `operationId` of the route whose request sent it (null under a `Run`).

**It does not hold the bound values**, because they are somebody's password as often as they are an id ([ADR 108](../adr/108-a-statement-can-be-watched.md)). `sql.logging` is a ready-made watcher that writes a debug line. A `Db` nobody watches pays one null check per statement.

A statement that failed also carries `sent.problem`: the database's own `message`, its SQLSTATE `code`, `severity`, `detail`, `hint` and the `constraint` that was violated ([ADR 117](../adr/117-a-statement-that-failed-says-what-the-database-said.md)). A field the database does not report is empty rather than null; SQLite has no SQLSTATE and none is invented. When the driver rejected the statement before it left the process, `message` is the Zig error's name. That is the case this exists for: before, `error.QueryFailed` was all a program could see. It lives in the request's arena, so a watcher that keeps one past the request must copy it, and it never reaches the client ([ADR 024](../adr/024-every-failure-answers-as-json.md)).

**`sql.problem(c)` returns the same struct to the call that failed**, instead of to a watcher of every call. See [Errors](#errors).

#### `db.poolStats`

**`db.poolStats()` says how full the pool is, and costs nothing until it is called** ([ADR 279](../adr/279-a-pool-says-how-full-it-is.md)). It returns a `?sql.PoolStats`:

- `size`, `available`, `missing` and `in_use`: the connections the pool was sized for, idle, not dialled yet (or lost and waiting for the reconnector), and lent to a statement. `size - missing` is how many are open, and the four are read under the pool's lock, so they agree with each other at that moment and not an instant later;
- `waited`, `dropped` and `statements`: since the process started, how many times a statement looked for a connection and found none (a waiter woken to find its connection taken looks again and counts again), how many connections were thrown away because a statement left them mid-conversation, and how many statements were sent. These are pg.zig's own counters, kept for the process and not for the pool, so two Postgres `Db`s in one program add up.

It is null before `listen()` has opened the pool and on SQLite, which has no pool of connections. A program that never calls it pays no byte and nothing on a statement's way; a call is one short hold of the pool's lock and one render of pg.zig's counters into 1,024 bytes of stack.

`in_use` over statements a second is how long a statement holds a connection (Little's law on the pool), which with `db.watching`'s time for the whole call says how much of it was waiting. A pool whose `missing` stays high after the first second is still being dialled one connection at a time (set `connect_on_init`, [ADR 115](../adr/115-a-boot-dials-the-connection-its-work-needs.md)); one whose `in_use` stays at `size` while the database is idle wants a larger `size`, or a handler that holds its connection for less.

#### `db.explain`

**`db.explain(Row, c, options)` takes what `db.select` takes and returns the plan of that statement with its values bound**, one line of the plan per line of text: `EXPLAIN (ANALYZE, BUFFERS)` on Postgres, which runs the read, and `EXPLAIN QUERY PLAN` on SQLite. It is for tests and developers. A children statement is not included ([ADR 232](../adr/232-a-read-can-show-its-plan.md)).

`db.rawExplain(c, sql, values)` is the same for a raw statement, and `db.rawExplainOrdered(c, sql, values, order)` for one with the `{order}` hole. Both run inside a transaction that is rolled back, so the plan of an `UPDATE` keeps no row it changed. On a test database of a few rows, assert on the plan's structure (a `SubPlan` is there, no `Join`) rather than on which index it chose.

#### Starting, checking and stopping: `nilo_start`, `nilo_check`, `nilo_stop`, `nilo_ready`

**`listen()` calls these for you; call them yourself only when driving a `Db` without an App.**

- `db.nilo_start(io, limits)` is what `listen()` calls first. A program starting a `Db` by hand passes `.none` (`.off` is the older spelling of the same value), and then the pool's waits have no bound. It opens the pool and nothing more.
- `db.nilo_check(io)` is what `listen()` calls next, once the work `app.before` registered has run. The `checking` list is compared against the live tables and the `expecting` version against the ledger, and if either disagrees the boot fails, and so does a `Db` on which `checking` was called twice. A program driving a `Db` by hand calls it after its own boot work, or calls `db.checkSchema(rows)` directly for the tables alone ([ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)).
- `db.nilo_stop()` is the other half, and `listen()` calls it too: after the last connection is cut off and before the Engine's loop is torn down, so the pool lets go of the loop it was built on ([ADR 121](../adr/121-a-service-is-stopped-before-the-loop-is.md)). **A `Db` cannot be used after `listen()` returns.** A program driving one by hand calls `deinit` as before.
- `db.nilo_ready(scope)` is what `app.health` asks: it sends `SELECT 1` down the pool and returns the reason when it did not come back. So a server started with `connect_on_init = 0` over a database that is down shows a 503 on its health page, not a 200 over an empty pool ([ADR 154](../adr/154-a-health-route-asks-the-services.md)). An `s3` Store answers the same question with whether it started.

#### The connection URL

**Reach a database on the same machine over its unix socket**: `postgres://app:secret@%2Fvar%2Frun%2Fpostgresql%2F.s.PGSQL.5432/shop`, the full socket path with the slashes percent-encoded. Same server and same query: 197k req/s across a Docker published port, 359k over loopback TCP, 458k over the socket, with p99 halved ([`bench/result/sql.md`](../../bench/result/sql.md)).

**The URL is read the way libpq reads it, and a parameter the driver would not act on is rejected by name.**

- Supported: `user`, `password`, `dbname`, `host` and `port` as query parameters, `sslmode` (`disable`, `require`, `verify-full`), `sslrootcert` with `verify-full` (`system` for the platform's store), `application_name` and `fallback_application_name`, `connect_timeout` in seconds, `keepalives`, `keepalives_idle`, `keepalives_interval`, `keepalives_count`, and `client_encoding=UTF8`.
- `options`, handed to the server in every connection's startup message and read there like `postgres -c`: `?options=-c%20statement_timeout%3D30s` is a ceiling on every statement of the pool with no round trip, and Neon's `options=endpoint%3D…` names the endpoint.
- **With no `sslmode`, a host other than this machine is `require`** and one on it is `disable` ([ADR 241](../adr/241-a-postgres-url-without-sslmode-is-encrypted-unless-it-stays-on-this-machine.md)). This machine is no host, `localhost`, `127.0.0.0/8`, `::1` or a unix socket path; a name that merely resolves to loopback is not looked up and gets `require`. `require` refuses a server that offers no TLS, and it encrypts without checking who answered: `verify-full` (with `sslrootcert` for a private CA) checks that too, and stays opt-in. A database that is meant to be plaintext says `?sslmode=disable`.
- `pgbouncer=true`, and `pool_mode=transaction` or `statement`, turn `Opts.prepared` off for that `Db`, at one Parse more per statement.
- Ignored with one `warn` line, because the driver does it already or nothing observable changes: `sslsni=1`, `gssencmode=disable`, `channel_binding=prefer`, `target_session_attrs=any`.
- Everything else is rejected with a line naming the parameter, the reason, and the list above. `sslmode=prefer` is the most common, because it would fall back to plaintext and pg.zig does not. `tcp_user_timeout` is the other: libpq sets a socket option with it, pg.zig cannot, and `connect_timeout` is what bounds the login.

A query string is split before it is percent-decoded, so `password=p%26w` is `p&w`.

#### `Opts`

| `Opts` | |
|---|---|
| `size` | connections held open. Default 10. This is the setting with a real curve behind it: 8 → 133k req/s, 16 → 148k, 32 → 180k, 64 → 206k, with p99 best at 32. Each one is a Postgres backend and a slot against `max_connections` |
| `connect_on_init` | how many to dial during `listen()`. Default 0, which dials one anyway (for the schema check, the version guard and `app.before`, all of which run before the first request) and opens the rest when needed; that one is allowed to fail ([ADR 115](../adr/115-a-boot-dials-the-connection-its-work-needs.md)). Set it to `size` when driving a `Db` from a `std.Io.Threaded` |
| `timeout_ms` | how long a caller waits for a free connection, answered `error.TimedOut`; 0 is no bound. **A Scope with a deadline (a `*Ctx` on a route with [`nilo.deadline`](./middleware.md#nilodeadline)) also bounds the wait and the statement by the time it has left**, and a statement from a request whose time has passed is not sent; see [A route's deadline](#a-routes-deadline) (ADR 105). Default 10,000. Also bounded on SQLite since [ADR 107](../adr/107-a-wait-for-a-connection-has-a-bound.md), where it needs the Engine to enforce it |
| `schema_mismatch_is_fatal` | whether a Row that disagrees with its table stops startup. Default true |
| `unchecked` | set it when this `Db` has no `checking` list on purpose. Default false, and then a `Db` that starts without `checking` ever being called warns once that the Rows will be checked by the first request that reads them ([ADR 192](../adr/192-a-db-with-no-schema-check-says-so-or-is-told.md)) |
| `prepared` | whether a statement is kept prepared on the connection it was sent on. Default true |

#### A test suite with the database down

**If the database is not running, lower `std.testing.log_level` in the test.** A `Db` that cannot connect logs at `warn` and returns the error ([ADR 145](../adr/145-a-suite-whose-database-is-down-is-not-a-suite-that-failed.md)), but pg.zig logs its own connect failure at `err`. The Zig test runner counts a logged `err` as a failed test, so a suite that skipped 95 tests on purpose still exits 1.

```zig
test "…" {
    const previous = std.testing.log_level;
    std.testing.log_level = .warn;
    defer std.testing.log_level = previous;
    …
}
```

`std.testing.log_level` is a plain `pub var` the runner compares against on every line. **`std_options` in a tested file is never read**, and this is worth knowing before spending an afternoon on it: the root of a test build is the compiler's own `test_runner.zig`, which declares `std_options` itself. A copy in your file is dead code that seems to work whenever the build runner caches the step and skips the binary.

#### A second database: `sql.Named`

**`sql.Named("replica")` is a second `Db` type**, so a second database is a second service, and which pool a statement uses is written in the handler's argument list. Nothing routes between them automatically: an automatic reader needs health checking, lag awareness and read-after-write safety, and the last one fails silently ([ADR 054](../adr/054-a-second-database-is-a-second-type.md)). `sql.Named("")` is a Refusal. There is no query cache, because a module that sees only its own writes cannot invalidate one correctly.

#### Prepared statements

**Every statement this module sends is a comptime constant, so it is kept prepared on its connection** under a name derived from its own text. That saves **30% of a key lookup and 14% of a page with a sort**, about 12 µs either way ([ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)). `db.raw` is prepared too, since its text is comptime ([ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)). Set `.prepared = false` behind a **connection pooler in transaction mode** (pgbouncer), which hands out a different server connection per transaction.

#### Views and columns the database fills

A Row may name a **view** or a **materialized view** as well as a table. The column types are checked there; nullability is not, because Postgres does not track `NOT NULL` through a view. **A primary key is not checked for nullability on SQLite either**: `id TEXT PRIMARY KEY` is a key the Row reads as a plain `Str`, because SQLite lets a rowid table hold a NULL there only as a legacy quirk. A NULL that is actually read is `error.QueryFailed` with the column named, and a table nilo creates writes `NOT NULL` on every key column ([ADR 050](../adr/050-a-view-or-a-rowid-alias-is-not-a-nullable-column.md)). An identity key and a generated column, which the Row reads as optional, need nothing declared: an insert names a subset of the Row's columns and `RETURNING` brings the rest back. A sequence or any other default on another column, set up outside the marker, is named in `.filled` so an insert may leave it out ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)).

#### Schema in the marker: `.default`, `.unique`, `.index`, `.references`

**A Row declares four things about its schema: `.default`, `.unique`, `.index` and `.references`** ([ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md), which amends the older rule that it may declare none, and [ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md), which adds `.default`). Only the Row that names a table may declare them. Nothing needs to enforce that, because the language does: a borrowed Row's marker is a `type`, and a type has nowhere to write `.unique`.

The line is drawn where the compiler stops being able to check. `CHECK (age > 18)` is text nilo cannot read, so you write it by hand in a step, and **nilo never touches what it did not create**. A column the Row reads as a Zig enum is the one check constraint the marker does write, because the allowed words come from the type. See [Migrations](#migrations).

### SQLite

**The same `Db`, over a file instead of a server.** Everything after this section (Rows, queries, batches, upserts, conditions, streaming, transactions) is the same code and the same types. What changes is the five things SQLite refuses, listed at the end.

```zig
const Db = sql.Sqlite(.{ .threading = .{ .hop = nilo } });

var db = Db.init(gpa, "/var/lib/app/shop.db", .{});
defer db.deinit();
try app.provide(&db);
```

#### `threading`

**`threading` has no default, and the compiler will not let you leave it out.** SQLite is a library reading a file, not a server on a socket, so there is no wait for the event loop to park on and the choice cannot be made for you ([ADR 064](../adr/064-a-file-has-no-socket-to-wait-on.md)):

| | |
|---|---|
| `.{ .hop = nilo }` | hand each statement to the Engine's thread pool and park the fiber, on a worker of its own (`nilo.blockingReserved`) so a statement holding its connection never queues behind a slow call. Costs a few microseconds per statement; **no statement can stall an executor thread**. The value is `nilo` itself, passed in because `sql/` may not import `nilo_http` |
| `.in_fiber` | run it on the fiber that asked. Faster when every statement is a cached lookup; a slow one holds a thread that serves other connections |

Which is the better default has not been measured, and it is an open question in [`docs/todo.md`](../todo.md) for this module. When in doubt, use `.hop`: its bad case is a few microseconds, and `.in_fiber`'s is a stalled thread.

#### `sqlite.Options`

| `sqlite.Options` | |
|---|---|
| `threading` | above. **No default** |
| `busy_timeout_ms` | how long to wait for a lock another *process* holds before returning `error.Locked`. Default 5,000 |
| `cache_kib` | `PRAGMA cache_size`, or null for SQLite's 2,000 KiB. **A ceiling, not an allocation**: a connection holds 28 KiB when opened and grows towards this as pages are touched ([`bench/result/sql.md`](../../bench/result/sql.md) §9) |
| `synchronous` | `.normal` (the default and WAL's recommended setting: the database cannot corrupt, but a power cut can lose recent transactions) or `.full`. `OFF` is not offered |

`wire.OpenOpts` is the same struct both drivers take, so `size`, `timeout_ms` and the rest are written the same way. **`size` is one writer and `size - 1` readers**, and that is how the database works, not a setting: SQLite allows one writer at a time, so writes queue on a single connection and reads run beside them under WAL ([ADR 065](../adr/065-one-writer-is-not-a-setting-it-is-the-database.md)). `connect_on_init` is ignored, because a file is either opened or not.

#### Connections and the file name

Every connection is set up with `journal_mode = WAL` and `foreign_keys = ON`. The first keyword of a statement decides which connection it takes: `SELECT` and `PRAGMA` take a reader, everything else takes the writer. That is exact for everything this module generates, and a **guess for `db.raw`**, whose text is yours. A `raw` that writes but looks like a read lands on a read-only connection and fails loudly. That holds in memory too: a reader is opened read-only and with `query_only = ON`, because SQLite's URI `mode=memory` overrides the open flag.

The URL is a path, or SQLite's URI form. **`:memory:` is one database for the whole pool and private to it**: `open` gives it a shared-cache name no other pool in the process has, so two tests that both open `:memory:` cannot see each other, and it is gone when the pool closes. The shared form `file:name?mode=memory&cache=shared` is SQLite's own and left as written: one database per name across every pool that opens it, living as long as a connection to it does. **An empty URL is refused at `open`** with `error.EmptyDatabaseUrl`.

`sql.SqliteNamed("cache", .{…})` is the second-database form, just as `sql.Named` is for Postgres. `sql.sqlite.version` is the bundled SQLite's version string. The amalgamation is vendored by the driver, so this is the version the build pinned, not the one on the machine.

#### What SQLite refuses

**These are rejected while compiling, with a message naming the dialect:**

| | why |
|---|---|
| `insertMany`, `updateMany` | no `unnest` and no array parameter. SQLite's batch form grows its own statement text, which breaks the rule this module is built on. Write one row at a time inside one transaction; that is cheap here, because there is no round trip per statement |
| `.lock` | writers are serialised by a lock over the whole database, so there is no row to hold against anybody |
| `tx.deadline` | needs the database to enforce it, and there is no server. `sqlite3_interrupt` aborts the whole connection rather than one statement. `busy_timeout_ms` covers the case that actually happens |
| a list column | no array type. A list belongs in its own table, or in a TEXT column your own code encodes |
| `.isolation` other than `.serializable` | SQLite gives every transaction a snapshot and serialises the writers. There is no weaker level to ask for |
| `.gt`, `.gte`, `.lt`, `.lte`, `.order`, `.after`, `sum`, `avg`, `min` or `max` over a `sql.Decimal` | the column is TEXT, so it compares as text (`"100.00"` sorts before `"9.99"`) and a sum is added in floating point. Equality and `.in` still work. Store an integer of the smallest unit ([ADR 049](../adr/049-a-column-type-can-come-from-outside-this-module.md)) |

A `sql.Uuid` is **not** on that list; it was removed from it in [ADR 067](../adr/067-a-value-is-whatever-the-database-stores.md). SQLite has no uuid type, so a UUID is stored as the thirty-six hyphenated characters in a TEXT column. That is what the schema check always asked for, and it makes the id readable in `sqlite3` and lets you type `WHERE public = '…'`. Postgres still sends sixteen bytes. Your Row says `public: sql.Uuid` either way.

**`.in`, a `sql.Json(T)` column and an enum column are not on the list either**, though until [ADR 067](../adr/067-a-value-is-whatever-the-database-stores.md) all three behaved as if they were: each read correctly and failed to *compile* on the way in, inside the driver. SQLite has neither a `jsonb` nor an enum type, so a document and an enum both bind as text, and `.in` binds its whole list as one JSON array that `json_each` takes apart. That keeps the statement a constant on a database with no array parameter. `.in` is the only one of the three with a cost: **one arena allocation per condition, on SQLite only**, because the array has to be written out where Postgres sends a native one.

So **code that batches does not port between the two dialects**, and the compiler says so instead of hiding it. The schema check is weaker too, by exactly as much as SQLite is: a column's declared type is free text and what is enforced is one of five affinities. It catches a `Str` field over an `INTEGER` column, but not an `i32` over a column holding values that do not fit. **A number is read only out of a number**: an integer or a bool field reading text or a `REAL`, and a float field reading text, is `error.QueryFailed` with a line naming the column, where it used to read 0, cut the `REAL` to an integer, or take the year out of a `CURRENT_TIMESTAMP`. A bool is true for anything but 0, as `WHERE flag` says ([ADR 067](../adr/067-a-value-is-whatever-the-database-stores.md)).

#### Binary size

SQLite costs **523,352 bytes** in a program that uses it and **zero** in one that does not. Both drivers live in one module, but `sql/sqlite.zig` is only compiled when something names it, so a Postgres-only binary carries no amalgamation at all.

### Queries

**Every query takes the Row, a [Scope](./core.md#scope) and an options struct written where it is used.** The Scope is the `*Ctx` inside a handler and a `*nilo.Run` anywhere else. Every query compiles its SQL to a constant.

The Scope is why this module names no App: `arena()` and `str()` were the only things it ever asked a `Ctx` for, so a query runs the same in a CLI as in a request ([ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)).

| | |
|---|---|
| `db.select(User, c, .{ … })` | `![]User` |
| `db.one(User, c, .{ … })` | `!?User`: a handler returning this answers 404, and the API document says so. Adds its own `LIMIT 1`, so a `.limit` beside it is refused |
| `db.find(User, c, id)` | `!?User`: the same, on the column the Row's `.key` names. Takes the key itself, not a condition |
| `db.page(User, c, .{ .where = …, .order = …, .limit = 20 })` | `!Page(User)`: `.rows` and `.total`, in one statement. `.limit` and `.order` are required; see [`db.page`](#dbpage) |
| `db.count(User, c, .{ .where = … })` | `!usize`. `.where` only, and optional: no condition counts the whole table |
| `db.exists(User, c, .{ .where = … })` | `!bool`: `SELECT EXISTS(…)`, so it stops at the first match |
| `db.insert(User, c, .{ .email = … })` | `!User`: the stored row, generated key included. Takes a subset of the columns. Each column it leaves out must be filled by something: the key by a sequence, a `.default`, `null` on an optional field, or `.filled`. An insert that leaves out a column nothing fills is a Refusal naming it. Not checked on a `.managed = false` Row ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)) |
| `db.insertMany(User, c, rows)` | `![]User`: a whole batch in one statement, returned in the order it was sent. `rows` is a `[]const Line`, where `Line` is a named struct of the columns being written; see [A batch](#a-batch) |
| `db.insertOrIgnore(User, c, .{ … }, .key)` | `!?User`: the stored row, or `null` when one was already there. `ON CONFLICT … DO NOTHING`. `.key` is the Row's own key; a column name is for a unique index that is not the key |
| `db.insertOrUpdate(User, c, .{ … }, .email)` | `!User`: the stored row, or the existing row with these values written over it. `ON CONFLICT … DO UPDATE` sets every column it was given **except the Row's key and the conflict target**, so an `.id` passed for the insert never replaces the key of the row already there. A call left with nothing to set is a Refusal pointing at `insertOrIgnore` |
| `db.update(User, c, .{ .set = …, .where = … })` | `!usize`: rows changed. Both `.set` and `.where` are required |
| `db.updateMany(User, c, rows)` | `![]User`: a whole batch in one statement, each row found by the Row's key. No `.where`: the join is the condition; see [A batch](#a-batch) |
| `db.updateReturning(User, c, .{ .set = …, .where = … })` | `![]User`: the rows as they are now. One statement, where an update followed by a select would be two and a race |
| `db.updateReturningOne(User, c, .{ .set = …, .where = … })` | `!?User`: the same, for a `.where` holding the key or a unique with `=`, so a PATCH endpoint is one call and null is its 404. Any other `.where` does not compile |
| `db.delete(User, c, .{ .where = … })` | `!usize`: rows deleted. `.where` is required |
| `db.deleteReturning(User, c, .{ .where = … })` | `![]User`: the rows that were removed |
| `db.deleteReturningOne(User, c, .{ .where = … })` | `!?User`: removes the one row the key or a unique identifies; this is how a one-time token is used up |
| `db.stream(User, c, .{ … })` | rows one at a time; see [Streaming](#streaming) |
| `db.raw(User, c, sql, .{ … })` | `![]User`: a statement this module does not write for you. `sql` is **comptime**: the `SELECT` list is counted against the Row's fields, each column that plainly has a name is checked against the field in its position, and the statement is kept prepared like every other ([ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)). The first time it runs in a process, the database is asked each column's type and whether an outer join can make it NULL, and the answer is checked against the Row: a mismatch is `error.QueryFailed` in a test binary and a warning in a server. Every raw call does this except `tx`'s and `composed` ([ADR 233](../adr/233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md)) |
| `db.rawOne(User, c, sql, .{ … })` | `!?User`: the same, for a statement whose `WHERE` holds a key. **No `LIMIT 1` is added**; see [below](#rawone-updatereturningone-deletereturningone) |
| `db.rawExactlyOne(Totals, c, sql, .{ … })` | `!Totals`: `rawOne` for a statement that always returns exactly one row, such as an aggregate with no `GROUP BY` or a `RETURNING` on a keyed write. No row is `error.QueryFailed`, not a zero-filled Row ([ADR 206](../adr/206-a-statement-that-always-answers-answers-a-row.md)) |
| `db.rawPage(Line, c, sql, .{ … })` | `!Page(Line)`: a raw statement read as a page. The `SELECT` list is the Row's columns followed by `count(*) OVER ()`, which becomes `.total`. You write the `ORDER BY` and `LIMIT`. A list exactly the Row's width is a Refusal. An empty page past the last row is asked again from row one to get its total, so the statement's own `OFFSET` must be one placeholder used nowhere else, `OFFSET $3` or `$3::int` ([ADR 205](../adr/205-a-raw-statement-can-carry-its-total.md)) |
| `db.raw([]const u8, c, sql, .{ … })` | `![][]const u8`: the first column of every row, with no Row and no marker. `i64`, `?bool`, a `Str`: anything one column can be read as. `rawOne` is the same, unwrapped. Two columns read into a single value is a Refusal ([ADR 125](../adr/125-a-row-that-owns-no-table.md)) |
| `db.liveColumns(c, schema, table)` | `![]const sql.Column`: what the database says the table has (`name`, `udt`, `nullable`). Empty for a table that does not exist. What `checkSchema` and `migrate.addMissingColumns` read |
| `db.rawOrdered(User, c, sql, .{ … }, order)` | `![]User`: a raw statement containing `{order}`, where the whole `ORDER BY` that an `sql.Ordering` chose at run time is written. See [`sql.Ordering`](#sqlordering-an-order-chosen-at-run-time) |
| `db.rawPageOrdered(Line, c, sql, .{ … }, order)` | `!Page(Line)`: `rawPage` and `rawOrdered` together. The list ends in `count(*) OVER ()` and the statement holds `{order}`, so a list sorted by its column headings reads its rows and its total in one statement, not two with the `WHERE` pasted into both ([ADR 205](../adr/205-a-raw-statement-can-carry-its-total.md)) |
| `db.compose(c)` | `sql.Composed`: an empty statement built at run time in the Scope's arena, writing placeholders the way this Db's dialect does (`$n`, or `?n` on SQLite). `sql.Composed.init(arena, sql.Spelling.of(Dialect))` builds one where no Db is in scope ([ADR 208](../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md)) |
| `db.composed(User, c, stmt, .{ … })` | `![]User`: a statement built at run time from pieces that cannot carry an arbitrary string. A `sql.Composed` holds only literals (`text`, comptime), checked identifiers (`ident`, `qualified`) and parameters (`param`, `number`). Filled by position and width-checked at run time; its tuple is counted against its placeholders (`error.ParamCountMismatch`) and its spelling against the Db (`error.WrongDialect`); not prepared. For a query engine that turns a model into SQL. Use `raw` for everything that can be written while compiling ([ADR 208](../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md)) |
| `db.composedOne(User, c, stmt, .{ … })` | `!?User`: the same, unwrapped |
| `db.exec(c, sql, .{ … })` | `!usize`: a statement that returns *nothing*, and the number of rows it changed. `CREATE TABLE`, `CREATE INDEX`, `PRAGMA`, `VACUUM`. No Row, because none is being filled ([ADR 067](../adr/067-a-value-is-whatever-the-database-stores.md)). `sql` is run-time text and is sent as written |
| `db.checkSchema(&.{ User, Order })` | `!usize`: compare these Rows against the live tables now, on a connection of its own, and log what disagrees at `err` (`warn` under `.schema_mismatch_is_fatal = false`, since nothing is then refusing to start). Two catalog queries however many Rows there are. Returns the number of problems. What `nilo_check` runs for the `checking` list; for a program that drives a `Db` without an App |
| `db.nilo_check(io)` | `!void`: the schema check and the version guard, run by `listen()` after `before` ([ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)) |
| `db.begin(c, .{})` | `!Tx`. `.{ .isolation = …, .read_only = … }` goes on the `BEGIN`; see [`Tx`](#tx) |

#### Raw parameters: `$1`, `$2`

**A raw statement's parameters are `$1`, `$2`, … on every database.** The text is rewritten for the dialect while compiling (`?1`, `?2` on SQLite), so a `$2` that appears before `$1` binds the second value on both, and a statement naming `$3` but given two values is a Refusal. `exec` takes its text at run time and sends it as written ([ADR 204](../adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)).

#### Set operations and round trips

**Set operations are conditions.** Over one table, `UNION` is `.any = .{ .{ a }, .{ b } }`, `INTERSECT` is `.{ a, b }` and `EXCEPT` is `.{ a, not_b }`. Every condition has a negation and `.any` nests, so every combination can be written. Over two tables it is a view, and a Row may name one ([ADR 052](../adr/052-a-set-operation-over-one-table-is-a-condition.md)).

There is no pipelining. A round trip is 24 µs and the query inside it is 2, and a server here serves 215,000 requests a second with a query in every one, because a waiting fiber frees its thread ([ADR 053](../adr/053-a-round-trip-is-not-the-cost-worth-chasing.md)). Statements that must land together go in a data-modifying CTE through `db.raw`.

#### Casting to text in a raw statement

**nilo does not add casts to a statement you wrote.** `Decimal`, `Interval`, `Inet` and any `AsText` column travel as the text the database printed, and nilo adds the `::text` (or `CAST(… AS TEXT)`) that makes that true to the SELECT list *it* writes. A `db.raw` list is yours, so nilo adds nothing to it, and the driver would return a `numeric` the reader cannot parse: at run time, on one route, with no compile error anywhere near it.

So `db.raw` rejects it while compiling: a bare column, or a `*`, in the position of an as-text field is a Refusal naming the column, the field and the field's column type ([ADR 124](../adr/124-a-raw-statement-cannot-cast-what-it-did-not-write.md)). The fix is to write the cast yourself, and the message says so:

```zig
const rows = try db.raw(Invoice, c, "SELECT id, total::text FROM invoices", .{});
```

An aliased expression such as `sum(amount)::text AS total` is already an expression, not a column path, so it passes. The check only rejects the form that could only ever be wrong.

#### `rawOne`, `updateReturningOne`, `deleteReturningOne`

**`rawOne` and `updateReturningOne` unwrap the result; they do not narrow the statement** ([ADR 146](../adr/146-a-statement-with-a-key-in-it-has-a-single-row-answer.md)). A statement whose `WHERE` holds a primary key returns one row or none, and what the handler wants is `!?T`, since `?Row` is already a 404 in the typed layer. So this:

```zig
const found = try db.raw(Card, c, card_sql, .{id});
return if (found.len > 0) found[0] else null;
```

becomes `return db.rawOne(Card, c, card_sql, .{id});`.

**Unlike `db.one`, `rawOne` adds no `LIMIT 1`.** This module did not write the statement and has no safe place to put one: a `LIMIT` after a `UNION ALL` or inside a CTE means something else. A statement that matches many rows still costs every one of them, and this returns the first.

`updateReturningOne` and `deleteReturningOne` go further, because the builder wrote their `WHERE` and can read it: **a `.where` that could match more than one row does not compile.** It must hold every column of the key, or of one `.unique`, with `=` to a value that is always present. Writing every matching row and returning only the first would hide the others.

All three exist on a `Tx` too.

#### `db.page`

**`db.page` is a `select` that also returns how many rows the condition matched before `.limit` cut it** ([ADR 150](../adr/150-a-page-knows-what-it-left-out.md)):

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

**A `db.count` next to a `db.select` is two statements, and somebody else can write to the table between them**, so the total and the rows can disagree without any warning. A window function on the page cannot disagree. It costs one integer read per statement, not per row, and a condition that matches nothing returns no rows and a total of zero.

**A page past the last row still has its total.** The window has no row to ride on there, so an empty page that skipped rows sends one `db.count` with the same `.where`. No other page does.

`.limit` and `.order` are both required, and `.lock` is refused:

- with no limit this is the whole table, and the total is just `rows.len`;
- with no order Postgres does not keep `LIMIT` stable, so two requests for the same page can return one row twice and miss another;
- `FOR UPDATE` next to a window function is a run-time error from Postgres.

`tx.page` is the same call inside a transaction. `sql.Page(Row)` is the result type, for a handler that returns one.

**The total costs a pass over every row the condition matches**, before the limit: 124 ms against 0.024 ms for the same twenty rows of a million ([ADR 150](../adr/150-a-page-knows-what-it-left-out.md)). A list that shows no total is `db.feed`.

#### `db.feed`

**`db.feed` is a `select` that also says whether any row came after the ones it returned**, for a "load more" button or an endless scroll ([ADR 150](../adr/150-a-page-knows-what-it-left-out.md#a-feed-counts-nothing)):

```zig
const found = try db.feed(Order, c, .{
    .order = .{ .created_at = .desc, .id = .desc },
    .after = .{ .created_at = last.created_at, .id = last.id },
    .limit = 20,
});
// found.rows is []Order, found.more says whether there is a next screen.
```

```sql
SELECT "id", "created_at", … FROM "orders"
  WHERE ("created_at", "id") < ($1, $2) ORDER BY "created_at" DESC, "id" DESC LIMIT 21
```

**It counts nothing.** It reads one row past `.limit` and drops it; that row is `more`. `.limit` and `.order` are required and `.lock` is refused, as on a page. `tx.feed` is the same call inside a transaction, and `sql.Feed(Row)` is the result type, `{"rows":[…],"more":true}` from a handler.

**`.after` is a cursor: the last row seen, as the value of each column `.order` sorts by.** The rows after it are one row comparison, which an index over the same columns answers with a seek, so a deep screen costs what the first does, where `.offset` reads every row it skips. The first screen has no cursor, so it is the same call without `.after`. `db.select` and `db.explain` take `.after` too. Each of these is a compile error, because each is a cursor that skips or repeats rows:

- `.after` naming other columns than `.order`, or in another order, or beside an order the request chose;
- an order that runs both ways, since a row comparison runs one way (write that condition with `.any` in `.where`, which cannot seek);
- a direction that says where NULLs go, or a column that may be null, since a comparison with a NULL in it is true of nothing;
- an order that does not end in the table's key, since two rows sharing every sorted column stand at one cursor;
- `.after` on `db.page`, which counts every match and skips by `OFFSET`.

### A batch

#### `insertMany`

**`insertMany` sends one array per column and lets Postgres `unnest` them, so the statement text is a constant and the batch size is data** ([ADR 047](../adr/047-a-batch-is-one-array-per-column.md)). One round trip whatever the size, one allocation per column, and, because it is one statement, a batch that violates a constraint stores none of its rows.

```zig
const Line = struct { sku: Str, qty: i32 };
const stored = try db.insertMany(Item, c, lines);   // lines: []const Line
```

The rows are a slice of a **named** struct, because the statement is compiled from the element type. Two kinds of column cannot be batched, and both are rejected while compiling: a list column, because `unnest` would flatten it, and an enum that has not declared `nilo_column`, because the cast has to name a type that exists in the database.

#### `updateMany`

**`updateMany` is the reverse: the batch is joined against the table instead of selected into it.** Each row of the batch carries the Row's **key**, which is how it is found and the one field the struct must have. Every other field it carries is set.

```zig
const Change = struct { id: i64, qty: i32 };
const changed = try db.updateMany(Item, c, changes);   // []const Change
```

A key the table does not have matches nothing, so if the result is shorter than the batch, that tells you which rows were not found. Two things are not promised, both because a join is a join: the **order** is whatever the planner chooses, and a batch naming one key twice changes that row once. Use `db.update` in a loop where either matters.

### Upserts

**The last argument is the conflict target: the column the database has a unique constraint on, written the way a key is.** `.{ .tenant_id, .email }` for one spanning two columns. **On a table this program builds, it must be the key or a `.unique` from the marker**, as a set, and a unique that ignores case does not count. Anything else does not compile, instead of being rejected by the database at run time (ADR 151). A `.managed = false` table is not checked.

There are two calls rather than one option, because the results differ: `DO NOTHING` stores no row and `RETURNING` then returns none, so `insertOrIgnore` returns `?User` and `insertOrUpdate` returns `User`.

`insertOrUpdate` sets **every column you passed except the conflict target and the Row's key**. The target is what the rows were matched on; the key identifies the row that is already there, and `"id" = EXCLUDED."id"` would renumber it. A call that leaves nothing to set is a compile error that points you to `insertOrIgnore`.

### Options

| | |
|---|---|
| `.where` | a condition; see [Conditions](#conditions). On a narrower Row it may name a column of the table that the Row does not carry, bound as the table's column type ([ADR 218](../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)) |
| `.order` | `.{ .created_at = .desc }`, one column per field. `.asc_nulls_last` and its three siblings say where NULLs go, which the two databases otherwise disagree about. A narrower Row that is not grouped may order by any column of its table, whether it carries it or not, so a tiebreak column does not have to be sent to the client; a grouped Row is a Refusal there, since the column has no single value per group. Where a `.limit` or an `.offset` cuts the answer (and always on `db.page` and `db.one`), the table's key is added at the end, running the way the order's last term runs (`.created_at = .desc` ends in `"id" DESC`; an `sql.Ordering` keeps an ascending one), unless the order names it already, so rows the order ties are never repeated or skipped from one page to the next ([ADR 150](../adr/150-a-page-knows-what-it-left-out.md#a-page-ends-in-the-key)). An `.order` over a `Decimal`, `Interval` or `Inet` column sorts by the value on Postgres (the column is answered under `col#`, so the name in `ORDER BY` reaches the column and not its printing, ADR 049); on SQLite a `Decimal` cannot be ordered at all. Or a value of an `sql.Ordering`, for an order the request chose; see [`sql.Ordering`](#sqlordering-an-order-chosen-at-run-time) |
| `.limit` / `.offset` | a literal is written into the SQL; a variable becomes a parameter. A literal limit is also the row ceiling, so the result list is allocated once. **A variable that is negative is `error.QueryFailed` before it is sent**, on both databases, with a line naming the field: SQLite reads `LIMIT -1` as no limit, so `?limit=-1` would otherwise have answered with the whole table. `.offset` with no `.limit` runs on SQLite, written `LIMIT -1 OFFSET …` |
| `.after` | a cursor, the last row seen: `.{ .created_at = last.created_at, .id = last.id }` over the same columns as `.order`, which must run one way and end in the key. One row comparison an index seeks on ([`db.feed`](#dbfeed)) |
| `.set` | update only: columns to new values, or `.{ .views = .{ .plus = 1 } }` for arithmetic on the column's own value. A bare `null` on a nullable column is `= NULL`, with no `@as(?T, null)` needed, while in `.where` the same null is `IS NULL`. `.title = sql.given(maybe)` is `COALESCE($1, "title")`, which keeps the column when the value is null; it is refused on an optional column. `.updated_at = .now` is the database's clock on a `sql.Timestamp` (the moment the transaction began on Postgres, the moment the statement runs on SQLite), and `.start_date = .today` its date (`CURRENT_DATE`) on a `sql.Date`, with nothing bound for either. A column read as text takes the word its column type names: `.today` on `sql.AsText("date")`, `.now` on `sql.AsText("timestamptz")`. Using either on the other's column type is a Refusal |

### Conditions

**Different fields are combined with AND. Several operators on one field are ANDed too.**

| | |
|---|---|
| `.id = 7` | `"id" = $1` |
| `.age = .{ .gt = 18, .lt = 65 }` | `"age" > $1 AND "age" < $2` |
| `.eq` `.ne` `.gt` `.gte` `.lt` `.lte` | each also takes `.now` on a `sql.Timestamp` or `sql.AsText("timestamptz")` column (an `AsText("timestamp")` has no zone, so the session's would decide what `now()` means in it, and `.now` is a Refusal there) and `.today` on a `sql.Date` or `sql.AsText("date")` one, the database's clock with nothing bound: `.due_date = .{ .lt = .today }`, and `.due_date = .today` for `=`. Either can be moved by a number written out: `.closed_at = .{ .gte = .{ .today = -90 } }` is `CURRENT_DATE - 90` (`date('now', '-90 days')` on SQLite), and `.occurred_at = .{ .gt = .{ .now = .{ .days = -90 } } }` is `now() - interval '90 days'`. **`.today` is not the same day on both databases**: on Postgres it is `CURRENT_DATE` in the session's time zone, on SQLite it is the day in UTC, so between midnight UTC and midnight in Jakarta they name different days. When the two must agree, compare against a `sql.Date` you computed (`sql.Date.utcOf(sql.Timestamp.now())`). `.today` moves by days; `.now` names one of `.days`, `.hours`, `.minutes`, `.seconds`, and a bare number or a month is a Refusal |
| `.ieq` / `.not_ieq` | equality that ignores case: `lower("email") = lower($1)` on Postgres and `"email" COLLATE NOCASE = ?1 COLLATE NOCASE` on SQLite. This is the expression a `.unique` with `.ignoring_case` indexes, so the lookup uses that index. An `_` is a plain character here, where `.ilike` would read it as a wildcard. Text only |
| `.like` / `.ilike` | and `.not_like` / `.not_ilike`. **These do not escape the text you give them**; use the next row instead. On SQLite `.ilike` is written `LIKE`, because that database's `LIKE` already ignores ASCII case, and `.like` is a Refusal there naming `.ilike`, for the same reason as `.contains` ([ADR 055](../adr/055-the-second-dialect-is-the-test-of-the-seam.md)) |
| `.contains` `.starts_with` `.ends_with` | the statement builds *and* escapes the pattern, so `%` and `_` in a search term match themselves. `i` in front ignores case (`.icontains`), `not_` in front negates: twelve in all. On SQLite the case-sensitive half is a Refusal, because its `LIKE` ignores ASCII case and cannot be told not to. `.istarts_with` on SQLite binds the escaped pattern whole, one arena allocation, so a unique with `.ignoring_case` serves it as a range. On Postgres `.istarts_with` is `lower(col) LIKE lower($1) || '%'` and a case-folding unique is built over `lower(col) text_pattern_ops`, which serves the prefix as a range too; a case-folding unique made before that keeps its old index, and the prefix scans until it is dropped and made again ([ADR 140](../adr/140-the-database-escapes-the-pattern-it-is-going-to-match.md)) |
| `.in = &.{ 1, 2, 3 }` | `= ANY($1)`: one parameter, so the statement stays a constant |
| `.not_in = &.{ 1, 2, 3 }` | `<> ALL($1)`: also one parameter |
| `.stage = .{ .in = sql.given(stages) }` | `("stage" = ANY($1) OR $1 IS NULL)`: a multi-select that may be absent. Null drops the term; a list, empty or not, is used as the list. See [`sql.given`](#sqlgiven-a-filter-that-may-be-absent) |
| `.deleted_at = null` | `IS NULL` |
| `.deleted_at = .{ .ne = null }` | `IS NOT NULL` |
| `.handle = .{ .not_distinct_from = maybe }` | `IS NOT DISTINCT FROM $1`: `=` with null treated as a value. **The only operator that accepts an optional**; `.distinct_from` is its negation |
| `.status = sql.given(maybe)` | `("status" = $1 OR $1 IS NULL)`: the term applies when the filter has a value and is skipped when it does not. See [`sql.given`](#sqlgiven-a-filter-that-may-be-absent) |
| `.any = .{ .{ … }, .{ … } }` | OR, in brackets. Not `.or`, which is a keyword, so `any` is a reserved column name |
| `.exists = .{ .{ .in = Other, .where = .{ … } } }` | `EXISTS (SELECT 1 FROM …)`, joined on the `.references` either Row declares (`Other`'s pointing at this table, or this Row's pointing at `Other`'s). `.on = .<column of Other>` or `.via = .<column of this Row>` says which when the schema has two. Either one can also name a join that no `.references` covers, and then the named column is joined to the other side's key: `.via = .deal_id` is `deals.id = <this table>.deal_id` with nothing declared on either Row, which is how you reach a table another part of the program owns. `.not_exists` negates; both are reserved column names, and both can be nested inside `.any`. With no `.where`, `.{ .in = Other }` asks whether any row of `Other` points at this one; that form is refused when the key is this Row's own, where `.<column> = null` asks the question |
| `.across = .{ .columns = .{ .code, .name }, .icontains = q }` | `("code" ILIKE … $1 … OR "name" ILIKE … $1 …)`: one condition met by any of the columns, with **one parameter** used on each. A tuple of entries is several conditions, ANDed; `across` is a reserved column name too. **A negated operator (`.not_icontains`, `.ne`, `.not_in`) does not compile inside one**: ORed it kept a row one column matched, so write one condition a column |

A column that does not exist is a compile error naming the closest match.

#### Null in a condition

**A null must be written literally in the condition; it cannot come from a variable.** The two `null` rows above are `IS NULL` because the compiler can see the null. An optional that *might* be null is a compile error, because whether the statement says `= $1` or `IS NULL` would then depend on a value that arrives after the statement is fixed, and `= NULL` is never true in SQL, so the query would run and return nothing. Use `.not_distinct_from` (one statement that means what you wanted) or branch ([ADR 040](../adr/040-a-condition-holds-a-value-not-a-maybe.md)). The null-safe pair is the exception because its statement does **not** change when the value is null: `"handle" IS NOT DISTINCT FROM $1` is the same six words either way, so nothing is left to decide at run time. **A literal null on a column that is never null is a Refusal too**: `.age = null` is `IS NULL`, which no row of a `NOT NULL` column satisfies, and `.age = .{ .ne = null }` is `IS NOT NULL`, which every row does, so the query would run and say nothing. Make the field `?i32` if the column can be null.

#### `sql.given`: a filter that may be absent

**An absent filter is not the same as a null one.** `.status = null` asks for the rows whose status is null. A screen with a search box and three dropdowns wants *no condition on status at all* when the dropdown is empty, which is the opposite. `sql.given` means that, and it is a word rather than an optional so the two cannot be confused ([ADR 149](../adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)):

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

**One statement to write, one parameter list, and a text cut for each call.** The guard is what your code compiles to, and the text that is sent leaves it out: a term whose value is there is written alone (`("status" = $1)`), and one whose value is not is written as a test that is always true on the same placeholder (`($1::text IS NULL)` on Postgres, `(?1 IS NULL)` on SQLite). A plan made before any value is bound, which is every SQLite plan and Postgres's generic one, therefore has no `OR` to stop on and seeks an index: 69 ms against 0.055 ms on 500,000 rows on SQLite, and about 0.13 ms a call faster on Postgres than sending the guard unnamed. The cut is chosen from constant pieces, so nothing from the request is written into the SQL. Each combination of filters is prepared under a name of its own, for up to **three** `sql.given` in one statement, so a connection keeps at most eight texts of one call; a statement with more runs unnamed, and one that is also ordered by a request (`sql.Ordering`) is unnamed as it always was ([ADR 149](../adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)). The statement types this page lists (`sql.Select` and the rest) show the guard, not the text a call sends.

Inside an `.exists` it drops the **whole subquery**, not one term of it. With only the term dropped, the subquery would ask whether *any* joined row exists, which would exclude every row that has none. For the same reason it cannot sit next to an always-present condition in one `.exists`; write a second entry.

**A list can be given too**, and absent and empty stay different. A filter bar's multi-select sends no `?stage=` for *no filter* and a list for *these stages*, so `.stage = .{ .in = sql.given(q.stages) }` drops the term when `q.stages` is null and keeps it when it is a list. An empty list still means *no row matches* for `.in`, and *every row* for `.not_in`. On SQLite the list is one JSON parameter, and `json_each(NULL)` returns no rows, next to a guard that already skipped the term.

Five things are Refusals, each with its own message: a `sql.given` inside `.any` (OR reverses what dropping means), on `not_distinct_from` (which already takes an optional), on a value that is not optional, next to a fixed condition in one `.exists`, and in the condition of an `UPDATE` or a `DELETE`, where a term that may be dropped would mean the whole table.

#### `.across`: one search over several columns

**A search box over several columns is `.across`, and a `sql.given` on it guards the whole bracket** ([ADR 172](../adr/172-one-condition-over-several-columns-is-one-parameter.md)). The refusal inside `.any` is about one absent alternative among present ones. The same absent value on every column is one condition, and it is written as one:

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

The parameter is bound once and used on every column, so the plan and the parameter list are the same however the box is set. The operators are the ones a single column takes (`.eq`, `.gt`, `.icontains`, several ANDed), and the columns must all read as one Zig type, optional or not. Four things are Refusals: a `sql.given` next to a fixed operator in one entry (write a second entry), one column (use an ordinary condition), columns of two types (use two conditions in `.any`), and a column the Row does not have.

### `sql.Ordering`: an order chosen at run time

**`sql.Ordering` lets the request choose the sort order from a fixed set the server declares.** `.order = .{ .created_at = .desc }` is fixed while compiling. A list screen sorted by its column headings (`?order=due:desc,title`) chooses at run time ([ADR 165](../adr/165-an-order-chosen-at-run-time-from-a-closed-set.md)):

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

**No string from the request reaches the statement.** Each key is a column of the Row, checked and quoted while compiling, and the type holds one SQL fragment per key per direction. A value is a list of at most `keys` terms, and writing the clause means writing those fragments in order. `Sort.by(&.{ … })` takes its terms while compiling and refuses none, or more than there are keys, there; terms that arrive at run time go through `Sort.fromTerms(terms)`, which answers `null` for the same two cases. The request decides *which* fragments, never *what* they say. A key is an enum literal for a column, `.{ .column = …, .nulls = .first | .last }` for one that says where NULLs go, or a string for SQL you write yourself.

**It parses itself.** `?order=due:desc,title` reads straight into a query field (`key[:asc|:desc]`, comma-separated). An undeclared key, a direction that is neither, an empty term, or more terms than keys is a 400 with the type's own message (`?order has to be an ordering by due or title, each with an optional :asc or :desc, comma-separated, not "height"`), and the API document describes the field as text. When absent, the field takes its default, which is the list's own order.

#### `db.rawOrdered` and `db.rawPageOrdered`

**A column key can order a typed statement; an expression key only a raw one.** `db.select`, `db.one`, `db.page` and `db.stream` accept an ordering in `.order` when every key names a column, and reject one with a string key, because a statement nilo writes orders only by columns it checked. `db.rawOrdered` takes your statement with `{order}` where the whole clause goes, and accepts either kind of key:

```zig
const rows = try db.rawOrdered(CommitmentRow, c,
    \SELECT … FROM commitments c WHERE c.state = $1 {order} LIMIT $2 OFFSET $3
, .{ state, limit, offset }, q.value.order);
```

You place the `{order}` yourself, for the same reason `rawOne` adds no `LIMIT 1`: appending to somebody else's SQL is exactly what `db.raw` avoids. It can go anywhere an `ORDER BY` clause is legal, including inside an `OVER (PARTITION BY … {order})` as well as at the end, which is how a grouped and capped list is ranked by the order the request chose using a single `{order}`. `db.rawPageOrdered` is the same call for a statement whose list ends in `count(*) OVER ()`, read as a `Page` the way `rawPage` reads one. All three exist on a `Tx`.

#### Cost and refusals

**What it costs.** The text is assembled per request, so an ordered statement is **not prepared**: Parse, Bind and Execute on every call, the ~12 µs a prepared name saves ([ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)), plus one arena allocation for the text, sized while compiling. A statement whose `.order` is a literal is unchanged. Where a `.limit` or an `.offset` cuts it, the clause ends in the table's key after the terms the request chose, unless one of them already orders by it, so tied rows page evenly ([ADR 150](../adr/150-a-page-knows-what-it-left-out.md#a-page-ends-in-the-key)).

Four things are Refusals: a key naming a column the Row does not have, an ordering declared for another Row, an expression key given to a typed statement, and a raw statement with no `{order}` in it.

### `.exists`: a condition on another table

```zig
db.select(Partner, c, .{ .where = .{
    .name = .{ .icontains = search },
    .exists = .{
        .{ .in = PartnerCapability, .where = .{ .capability = cap } },
    },
} });
```

**The join comes from the schema; you do not write it here.** It comes from a `.references` that one of the two Rows declares: either the other Row's, pointing at this table, or this Row's own, pointing at the other's. That reference is already checked while compiling: the target must be a Row the tool knows, the target column one of its columns, and the two Zig types the same. A key over two columns joins on both, because joining on the first alone would run, read correctly and answer a broader question than the schema asked. So the query in the other direction, from the child asking about its parent, is the same line with the Rows swapped ([ADR 175](../adr/175-an-exists-reads-the-reference-from-either-side.md)):

```zig
db.select(Staff, c, .{ .where = .{
    .exists = .{ .{ .in = Department, .where = .{ .name = .{ .icontains = q } } } },
} });
// EXISTS (SELECT 1 FROM "departments"
//         WHERE "departments"."id" = "staff"."department_id" AND …)
```

If neither Row declares a reference, that is a compile error saying so. If the schema declares it **twice**, that is a compile error naming the columns, because which one joins changes what the query means. `.on = .<column>` names a column of the inner Row, and `.via = .<column>` a column of the Row the statement is over. They are two different words so the two directions cannot be confused, and using both at once is refused. Two tables that point at each other count as the twice case too. `.on` is also how you join to a Row over a view, and `.via` how you join to a parent that is a view.

The entries are a list because a struct cannot have the same field twice, and filtering on two capabilities is common. They are ANDed.

**With no `.where`, an entry asks whether any row points back.** `.{ .in = Other }` is only allowed when the reference is `Other`'s, pointing at this table. When the reference is this Row's own column, write `.<column> = null` (or `.ne = null`) instead.

**An `EXISTS` is a condition, not a join**, and [ADR 218](../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md) says why: it changes neither the column list nor the row count, so the Row still describes the result and `.limit` still means what you expect. A join the Row declares keeps both too; that is [a parent](#a-parent-children-a-group).

### A key of several columns

```zig
pub const nilo_table = .{ .name = "seats", .key = .{ .tenant_id, .id } };
```

```zig
const seat = try db.find(Seat, c, .{ .tenant_id = tenant, .id = id });
```

**A composite key is passed as named fields, not a tuple**, because two `i64` key columns written in the wrong order would find the wrong row and report nothing. Leaving one out, adding a column that is not part of the key, and passing a tuple are all compile errors. `updateMany` joins on every key column, and `CREATE TABLE` writes a `PRIMARY KEY (…)` constraint rather than a clause on one column.

### A parent, children, a group

**A narrower Row can carry more than its table's columns, and every read accepts it unchanged** ([ADR 218](../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)). The guide page is [Parents, children and aggregates](../guide/sql/shapes.md).

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
| `n: i64`, named in `nilo_children` with `.{ .count = C }` | **a count** of the rows of `C`'s table pointing at this one | a correlated `(SELECT count(*) …)` in the same statement, one per row returned |
| `m: ?T`, named in `nilo_children` with `.{ .max = .{ C, .col } }` or `.min` | **the largest or smallest** `col` of those rows | the same subquery with `max` or `min` |
| `f: T` or `f: ?T`, named in `nilo_through` with `.{ .ref_id, …, .col }` | **a column of another table**, read flat: `customer_name` where a parent would be `customer: { name }` | one `JOIN` per reference on the path (`LEFT JOIN` when one may be null), under `"#t/ref_id"`, shared by every field that goes the same way |
| a field named in `nilo_aggregate` | **an aggregate** of the rows in its group | `count`, `sum`, `min`, `max`, `avg` in the same statement; every other field is a `GROUP BY` key, and a parent or a field read `.through` a reference adds the referenced row's key to the group, so two customers with one name are two groups |

#### How the join is found

**The link comes from the schema.** One `.references` between the two tables is the join; none, or several, is a compile error until `nilo_via` names the column. `nilo_via` may name a column no reference covers, and then it joins the other table's key. A parent must be `?P` exactly when its column may be null; the opposite mismatch is refused as well.

**Conditions and orders go through the field.** `.where = .{ .customer = .{ .name = "Acme" } }`, `.order = .{ .customer = .{ .name = .asc } }`, and in a `sql.Ordering` the path is a tuple, `.{ .customer, .name }`. On a grouped Row, a term on a column becomes a `WHERE` and a term on an aggregate a `HAVING`, and a grouped Row's condition may name any column of its table.

#### `nilo_through`

**A `nilo_through` field acts as a column everywhere except the table itself.** `.where = .{ .customer_name = "Acme" }` and `.order = .{ .customer_name = .asc }` name it directly, a count joins only the references its condition reads, and on a grouped Row it is a key of the group. It is optional exactly when a reference on the path or the column itself may be null, and the opposite mismatch is refused as well. It may sit on a parent's Row, and the Row that names its table refuses it ([ADR 235](../adr/235-a-column-of-another-table-may-be-read-flat.md)).

**A row the path does not reach reads null, or what the entry says.** `.otherwise = v` is `COALESCE(column, v)` in the answer, the condition, the order and the group alike, and the field has the column's own type. `.join = .inner` makes every join on the path an inner join, so the row is left out, a count joins it whatever its condition reads, and every field through the same reference is held to never null. These are refused: `.otherwise` on a column that is never null, `.join = .inner` over references that are never null, `.join = .left`, and `.join = .inner` inside a parent that may be missing.

#### `nilo_aggregate`

**What an aggregate field's type must be:**

| `nilo_aggregate` | field |
|---|---|
| `.count`, `.{ .count = .col }`, `.{ .count_distinct = .col }` | `i64` |
| `.{ .sum = .col }` | `i64` over whole numbers, `f64` over floating ones, the column's type over a number carried as text |
| `.{ .min = .col }`, `.{ .max = .col }` | the column's type; over a `bool`, `Uuid`, `Bytes` or `Json` column it does not compile, on either database |
| `.{ .avg = .col }` | `f64` |

The field is optional exactly when the result can be null: over a nullable column, for `sum`, `min`, `max` and `avg` with a `.where`, or for `sum`, `min`, `max` and `avg` on a Row with no keys.

**An entry's `.where` filters only the rows that aggregate reads**, as `FILTER (WHERE …)` on both databases: `.idr = .{ .sum = .amount, .where = .{ .currency = "IDR" } }`. To count the matching rows, count a column that is never null: `.{ .count = .id, .where = … }`. A column with a one-column `.references` can also reach into the row it points at, `.where = .{ .state_id = .{ .category = .done } }`, and that table is joined once under `"#f.state_id"` (`LEFT JOIN` when the reference may be null). **The way can nest**: a reference of the row it reached leads on, so `.where = .{ .org_unit_id = .{ .customer_id = .{ .kind = .government } } }` joins `org_units` under `"#f.org_unit_id"` and `customers` under `"#f.org_unit_id.customer_id"`, and an outer join anywhere on the path makes every join after it outer. A value of the column's own enum is accepted wherever an enum literal is, so `.not_in = &finished`, with `finished` a `[_]Category`, reads the same as `.not_in = .{ .done, .cancelled }`.

#### `nilo_children`

**`nilo_children`**, keyed by field:

| entry | on a field | writes |
|---|---|---|
| `.{ .order = .{ .position = .asc } }` | `[]const C` | `ORDER BY "#k"."key", <the terms>, <C's key>` in the children's statement; columns of `C`'s table |
| `.{ .where = .{ … } }` | `[]const C` | a `WHERE` on the children's statement |
| `.{ .count = C }`, `.{ .count = C, .where = .{ … } }` | `i64` | `(SELECT count(*) FROM <C's table> AS "#c" WHERE "#c".<reference> = <this row's key> [AND …])` |
| `.{ .max = .{ C, .col } }`, `.{ .min = .{ C, .col } }`, either with a `.where` | `?` the column's type | the same subquery, with `max("#c"."col")` in place of `count(*)`; null for a row nothing points back at |

A count, a max and a min can be ordered by and used in `.where` like a column, can sit on a parent's Row too, and follow `nilo_via` keyed by their own field. A grouped Row refuses them.

**The `.where` of an aggregate or a `nilo_children` entry is written with its values in it**, because it is part of the Row, not of a request: a value is `=`, `null` is `IS NULL`, and an operator struct takes `.eq`, `.ne`, `.gt`, `.gte`, `.lt`, `.lte`, `.in` and `.not_in`, over columns of the table the entry reads, and through a reference as above. For an aggregate the reached table is joined into the statement; for a count, max or min it is joined inside the subquery under `"#c.<column>"`; for a children list it is joined into the children's statement. `.now` and `.today`, moved or not, are the database's clock here too. Anything else is refused, and the message lists the allowed words.

#### Which calls accept these Rows

| Call | a parent | children | a count of children | a group | no keys |
|---|---|---|---|---|---|
| `select`, `one`, `page` | ✓ | ✓ | ✓ | ✓ (a page counts groups) | refused |
| `find` | ✓ | ✓ | ✓ | refused | refused |
| `count`, `exists` | ✓ | ✓ | ✓ | ✓ (counts groups) | refused |
| `stream` | ✓ | refused | ✓ | ✓ | refused |
| `exactlyOne` | | | | | ✓ |

#### `db.exactlyOne`

| Call | Returns |
|---|---|
| `db.exactlyOne(Totals, c, .{ .where = … })` | `!Totals`: a Row whose every field is an aggregate, over the rows matched. Always exactly one row, whatever matched; a `sum` over no rows is null |
| `sql.exactlyOneFor(Row, Options)`, `sql.childrenFor(Row, "field")` | the statements behind `exactlyOne` and a children field, while compiling |

Refused: a parent or children on the Row that describes the table itself, children of children, children through a reference of several columns, a `.limit` on children, a count on a grouped Row, a `.lock`, a write, and `db.raw` into a Row with a parent or children. `db.raw` fills a through field, an aggregate or a count by position like any other column. Children take two statements, which see one snapshot only inside a `Tx`.

### Streaming

**For a result set too big to hold in memory.** Rows come back as `sql.Borrowed(User)`: `User` with every `Str` replaced by `[]const u8`, because the text points into the buffer the rows arrive in and is gone at the next `next()`.

```zig
var rows = try db.stream(User, c, .{});
defer rows.close();                       // required
while (try rows.next()) |u| try s.print("{d},{s}\n", .{ u.id, u.email });
```

**Closing a stream early is cheap, whatever is left.** Postgres has already sent the rest, so `close` reads up to 1 MiB of it off the socket and keeps the connection. Past that it gives the connection back to be closed and dialled again, one connect in place of the rest ([ADR 238](../adr/238-a-stream-let-go-early-reads-a-megabyte-of-what-is-left.md)).

### `Tx`

```zig
var tx = try db.begin(c, .{});
defer tx.deinit();          // rolls back unless committed
_ = try tx.insert(Order, c, .{ … });
try tx.commit();
```

**A `tx` has every read and write call above, all sent down the one connection it holds**: `select`, `one`, `exactlyOne`, `find`, `page`, `feed`, `count`, `exists`, `insert`, `insertMany`, `insertOrIgnore`, `insertOrUpdate`, `update`, `updateMany`, `updateReturning`, `updateReturningOne`, `delete`, `deleteReturning`, `deleteReturningOne`, `raw`, `rawOne`, `rawExactlyOne`, `rawOrdered`, `rawPage`, `rawPageOrdered`, `exec`, `compose`, `composed` and `composedOne`. Not `stream`: an open result set keeps the connection busy, so nothing else in the transaction could run until it closed. Forgetting the `defer` is caught in Debug by a counter checked at `db.deinit()`.

**The type is written `sql.Db.Tx`**, which only matters when a function of yours *takes* one: `fn append(self: *Bus, tx: *sql.Db.Tx, …)`. Every example here starts with `var tx = try db.begin(…)` and lets Zig infer it, so you only need the name when something is handed a transaction somebody else opened. It belongs to `Db` rather than to the module because a transaction belongs to the pool it came from; `sql.Tx` does not exist.

| | |
|---|---|
| `db.begin(c, .{ .isolation = …, .read_only = … })` | both go on the `BEGIN` itself, so neither costs a round trip. `.isolation` is `.read_committed`, `.repeatable_read` or `.serializable`; if left out, it is whatever the server is set to |
| `db.begin(c, .{ .rebuilding = true })` | SQLite only: foreign keys are off for the transaction and checked once before the COMMIT, which returns `error.ForeignKeyViolated` for a row pointing at nothing. This is what rebuilding a table needs, and what `migrate.apply` asks for on a version that drops a table. A compile error on Postgres |
| `tx.deadline(ms)` | a time limit on every statement after it, for the life of this transaction. `error.TimedOut` past it. 0 is the shortest, 1 ms, and a number past `maxInt(i32)` is sent as that |
| `tx.savepoint()` | `!Savepoint`: a mark that part of the transaction can be undone back to; see [Savepoints](#savepoints) |
| `tx.feed(Order, c, .{ … })` | `!Feed(Order)`: `db.feed` down this transaction's connection, the rows plus whether any came after them; see [`db.feed`](#dbfeed) |
| `tx.rawPageOrdered(Line, c, sql, .{ … }, order)` | `!Page(Line)`: `db.rawPageOrdered` down this transaction's connection, a statement holding `{order}` and ending in `count(*) OVER ()`; see [`db.rawOrdered` and `db.rawPageOrdered`](#dbrawordered-and-dbrawpageordered) |

#### A route's deadline

**A `*Ctx` whose route has a [`nilo.deadline`](./middleware.md#nilodeadline) passes it to every `db.` call and every `tx.` statement**, with nothing written at the call: `error.TimedOut` when the time left runs out while the call waits for a connection (or SQLite's writer) or for the database's answer, and no statement sent at all when it has already run out ([ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)). A `nilo.Run` has no deadline and is unchanged. The bound is on the caller's side only: **no cancel request goes to Postgres**, so it finishes the statement until it finds the socket closed, and the connection that was waiting is closed rather than reused; and a statement that SQLite is already running is not interrupted (`busy_timeout_ms` bounds its lock waits). `commit` and `rollback` are not bounded, since a cleanup path is not cancellable ([ADR 082](../adr/082-a-cleanup-path-is-not-cancellable.md)), and rows read after the call returned (a `db.stream`'s) are not bounded. A route with no deadline pays nothing on its stack for this; one with a deadline touches 192 bytes more while the call is armed. A connection cut off mid-statement is replaced, never handed to the next caller out of step. **A write cut off by the deadline may still have committed on Postgres**, because the server is not told: a request that is retried needs an idempotency key. Only the cancellation reads as `TimedOut`; an error the database gave (a unique violation, a syntax error) comes back as itself.

#### `tx.deadline`

```zig
var tx = try db.begin(c, .{});
defer tx.deinit();
try tx.deadline(2_000);                   // one round trip
const rows = try tx.select(Report, c, .{ .where = … });
```

**Only a transaction can have a deadline**, by design ([ADR 043](../adr/043-a-deadline-needs-a-connection-you-hold.md)). A deadline is always a separate command, so it has to go down the same connection as the statement it limits. `db.select` takes whichever connection is free and returns it straight away, so there is nothing to set one on. Postgres removes it when the transaction ends, however it ends. For a limit on everything, set it on the role: `ALTER ROLE app SET statement_timeout = '30s'`.

#### `.lock`: holding the rows a read matched

**A read inside a transaction can hold the rows it matched until the transaction ends**, which is what makes read-modify-write safe.

| | |
|---|---|
| `.lock = .update` | hold every matching row against other writers, waiting for anyone already holding it |
| `.lock = .update_nowait` | the same, except a row somebody else holds fails at once with `error.Locked` |
| `.lock = .update_skip_locked` | the same, except a row somebody else holds is left out of the result, which is how a work queue reads |
| `.lock = .share` | hold against writers, and let other readers hold it too |

```zig
var tx = try db.begin(c, .{});
defer tx.deinit();
const held = try tx.select(Item, c, .{ .where = .{ .id = id }, .lock = .update });
_ = try tx.update(Item, c, .{ .set = .{ .qty = held[0].qty - 1 }, .where = .{ .id = id } });
try tx.commit();
```

`find` has no `.lock`, because it takes a key rather than options, so a locked read of one row is `tx.one(Row, c, .{ .where = .{ .id = id }, .lock = .update })`.

**A `.lock` outside a transaction is a compile error.** Postgres wraps a single statement in a transaction of its own and ends it immediately, so the lock would be taken and released before the handler read a row. The statement would work, but without the guarantee it was written for ([ADR 048](../adr/048-contention-is-what-a-transaction-is-for.md)).

#### Savepoints

| | |
|---|---|
| `tx.savepoint()` | `!Savepoint`: set a mark |
| `sp.deinit()` | undo everything since the mark, unless it was released. For a `defer` |
| `sp.release()` | `!void`: keep the work, and drop the mark |
| `sp.rollback()` | undo the work now; the transaction continues |

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

**A savepoint is how you nest a transaction.** Postgres has no nested `BEGIN`, and an inner "commit" is not durable: it only means the outer transaction may still commit it. It costs a round trip, which is worth it in one important case: a statement that fails inside a transaction aborts all of it, so without a mark there is no way to try something and continue.

Undoing or releasing a savepoint destroys every savepoint taken after it, which is Postgres's rule. A `defer sp.deinit()` on one of those sends nothing, instead of asking the server to release a mark it no longer has.

### Types

| | |
|---|---|
| a number | an integer of up to 64 bits, signed, or unsigned up to 32; `f32` or `f64`. A column wider than the field is read range-checked: `i32` over `int8` reads until a value does not fit, and that row is `error.QueryFailed` naming the column. `u64`, `usize`, anything past 64 bits and a float other than 32 or 64 bits are Refusals, since neither database stores them. A list holds `i16`, `i32`, `i64`, `f32` or `f64` |
| `sql.Timestamp` | **`nilo.Timestamp`, re-exported** ([ADR 057](../adr/057-percent-is-needed-by-two-layers.md)): microseconds since the epoch, written as RFC 3339 in JSON, from 0001-01-01 to 9999-12-31 with a moment before 1970 included; a value outside that reads from the column but fails to write as JSON (an error, never `null`, ADR 127). `timestamptz` on Postgres, and only that: a `timestamp` column is refused at startup with the `ALTER` that converts it, because Postgres moves a zoneless value by the session's zone wherever it meets `now()`. `infinity` and `-infinity` are `error.QueryFailed` (ADR 067). On SQLite it is an `INTEGER` holding those microseconds, **which SQLite's date functions do not read as a date**: `strftime('%m', paid_at)` is NULL, and a Row field filled from it fails the query. Divide first, `strftime('%m', paid_at / 1000000, 'unixepoch')`, or work the month out in Zig ([Dates out of a Timestamp](../guide/sql/sqlite.md#dates-from-a-timestamp)). `.now()`, `.fromSeconds(s)`, `.seconds()`, `.nilo_parse(text)` |
| `sql.UnixMillis`, `sql.UnixSeconds` (`sql.Unix(.millis)`, `sql.Unix(.seconds)`) | **a moment kept as a plain count in an integer column**, the unit in the type: `count: i64`, `int8` on Postgres and `INTEGER` on SQLite, and nothing is converted on a read or a write. For a schema that already stores Unix milliseconds or seconds, which `sql.Timestamp` (microseconds) would read as a date in 1970 with no error. The check refuses a `timestamptz`, a `date` or a `TEXT` column under one; **an `INTEGER` has no unit, so one holding microseconds under `UnixMillis` passes**, and that is on the schema. JSON is the number both ways. `.toTimestamp()` (one saturating multiply) and `.fromTimestamp(t)` (one floor division) cross to `sql.Timestamp`, and `.now()` is the clock in the unit. `.now` and `.default = .now` are for `sql.Timestamp` only (ADR 067) |
| `sql.Date` | **`nilo.Date`, re-exported** (ADR 057): a calendar day: `days` since 1970-01-01, written as `2026-09-17` in JSON and described as `format: date`. `date` on Postgres, `TEXT` on SQLite, and **read from the column rather than from a `::text`**, so a `db.raw` reading one needs no cast. `.fromDays(n)`, `.nilo_parse(text)`, `.utcOf(ts)`, `.atMidnightUtc()`. A day is not a moment: a due date read into a `timestamptz` gets a midnight, a midnight has a time zone, and the date then shifts by a day for a reader in Jakarta ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)). It holds a value and does no calendar arithmetic (no `.addDays`, no `.weekday`), and the two conversions it does offer are named for the zone they assume. A day before 1970 is normal and prints normally; the range is 0001-01-01 to 9999-12-31, which is what four digits can write and what `nilo_parse` reads back. Postgres has no year 0, so `0000-01-01` is refused by the parser and by the writer, and a `date` outside the range reads fine but fails to write as JSON (an error, never `null`, ADR 127). `.atMidnightUtc()` is `error.OutOfRange` for a day whose midnight does not fit in an `i64` of microseconds (about year 294,000 on) |
| `sql.Uuid` | `nilo_id`'s [`Uuid`](./id.md#nilo_id), re-exported: the same type either import gives you. `uuid` |
| `sql.Json(T)` | a `T` stored as `jsonb`, parsed per row into the request arena. Not available in `db.stream`, which allocates nothing. In a response it is written and described as the `T` itself (a **document**, `nilo_json_of = T` beside `value: T`), so a Row with one can still use `rename_all` ([ADR 163](../adr/163-a-document-is-its-value.md)). **It is also the intended way to put a list on a row**: a `db.raw` projection with `COALESCE(jsonb_agg(jsonb_build_object(…)), '[]'::jsonb) AS labels` read into `labels: sql.Json([]const Label)` is one statement, where a list of labels per row was a round trip per row, and the document says `Label`. **The column is parsed by `std.json` using the field names as written**: a `rename_all` on `T` changes the response, not the column, so a `jsonb_build_object` uses `content_type` and the response says `contentType` |
| `sql.Decimal` | a `numeric`, held as its digits. `.text` is the value; there is no arithmetic. Written into JSON as a **string**, so a consumer's `JSON.parse` cannot round it into an `f64` ([ADR 049](../adr/049-a-column-type-can-come-from-outside-this-module.md)). Ordering, `.gt` and its siblings, `.after` and `sum`, `avg`, `min`, `max` over one are Postgres-only; SQLite refuses them while compiling |
| `sql.Interval`, `sql.Inet` | an `interval` and an `inet`, held as the text Postgres prints. `.text` is the value |
| `sql.Bytes` | bytes rather than text: `bytea` on Postgres, `BLOB` on SQLite. `.bytes` is the value, and `sql.Bytes.of(hash)` writes one. The slice a read returns lives in the request arena, the way a `Str` does. Use this instead of `sql.AsText("bytea")`, which goes through hex printing and costs a conversion each way ([ADR 141](../adr/141-bytes-are-a-type-not-a-second-protocol.md)) |
| `sql.AsText("money")` | any Postgres type at all, held as its text: the way out of this table. A column type of your own is any struct or enum with `nilo_column`, `nilo_read(text, arena)` and `nilo_write(arena)`; see [below](#a-column-type-of-your-own) |
| a slice | an array column, with no wrapper: `[]const Str` is `text[]`, `[]const i32` is `int4[]`, `?[]const i32` a nullable one, `[]const ?i32` one whose elements may be NULL ([ADR 045](../adr/045-an-array-is-a-slice-and-a-slice-is-one-deep.md)). `[]const u8` is text, so a list of text is `[]const Str` or `[]const []const u8`. `[]const sql.Uuid` is `uuid[]`, in both directions and as an `.in` list ([ADR 116](../adr/116-a-raw-parameter-is-converted-the-way-a-rows-is.md)). Not available in `db.stream` |
| an enum | read from `text`, a `varchar` or a Postgres enum. A value the Zig enum does not have fails the request. Add `pub const nilo_column = "user_role"` to it and the column is checked at startup (its type name, and on Postgres its values too, so a label the Zig enum lacks or a tag the type lacks is reported before the first request instead of by it), and it can be batched. On a table this program builds, a plain enum is a `text` column and its tags become that column's `CHECK`. An enum that names its own type is the database's to extend with `ALTER TYPE`, and nilo writes none of its values; it only reads them back at startup and says which side is behind |

#### A column type of your own

**Any struct or enum with these three declarations is a column type**, so the list above is not closed:

```zig
const Cents = struct {
    value: i64,

    pub const nilo_column = "numeric";

    pub fn nilo_read(text: []const u8, arena: std.mem.Allocator) !Cents { … }
    pub fn nilo_write(self: Cents, arena: std.mem.Allocator) ![]const u8 { … }
};
```

It travels as the text Postgres prints (`"col"::text` on the way out, `$1::numeric` on the way in), which is the one representation every Postgres type has, including types that come with an extension ([ADR 049](../adr/049-a-column-type-can-come-from-outside-this-module.md)). The column is checked at startup like any other, and the type works everywhere a column type does: conditions, `.set`, `insert`, a batch.

`sql.AsText(name)` does all of that for a type that is just its text, and `sql.Decimal`, `sql.Interval` and `sql.Inet` are three instances of it. A column that needs its precision in the DDL writes `sql.AsText("numeric(14,3)")`: the digits round-trip either way, and `numeric`'s binary form is a base-10000 digit vector this module has no reason to parse.

Two mistakes are compile errors: having one of `nilo_read`/`nilo_write` without the other, and having both without a `nilo_column`. **An array of a custom type is not read**: `[]const Decimal` is not supported, as before.

#### `Timestamp.nilo_parse`

**A `Timestamp` can read back what it prints.** `Timestamp.nilo_parse(text)` returns `?Timestamp`, and it is the same declaration that lets a type be a path param or a query field ([ADR 113](../adr/113-a-path-param-can-parse-itself.md)). So a keyset cursor the server printed in the previous response is an ordinary typed argument ([ADR 127](../adr/127-what-a-server-prints-it-can-read.md)):

```zig
const Page = struct { after: ?sql.Timestamp = null, limit: u32 = 50 };

fn feed(db: *Db, c: *nilo.Ctx, page: nilo.Query(Page)) ![]Event { … }
```

It accepts an offset (`2026-08-16T16:30:00+07:00` is the same moment as `2026-08-16T09:30:00Z`) and fractional seconds, truncated at microseconds because that is the column's resolution. It rejects a local time with no zone, because that is not an instant. The writer always prints six fractional digits (`2026-08-16T09:30:00.700000Z`), so a cursor handed back to `.after` keeps its microseconds. The round trip is what is tested: whatever `writeRfc3339` prints, `nilo_parse` reads back to the same microsecond.

#### Array columns

**An array column's element type must match exactly**: an `int4[]` reads into a `[]const i32` and not into a `[]const i64`, because the driver picks its element decoder from the array's own type. An array containing a NULL read into a non-optional element, or an array with more than one dimension, fails the request, not the process. A list column holds `i16`, `i32`, `i64`, `f32`, `f64`, `bool`, text or `sql.Uuid`; a list of `Timestamp`, `Date`, `Decimal`, `Bytes` or `Json` does not compile where its Row is read.

### Errors

| | |
|---|---|
| `error.AlreadyExists` | a unique violation (`23505`). **409** by default |
| `error.ForeignKeyViolated` | `23503`: a row this statement names does not exist, or a row it removes is still referenced by another. No default status: a 409 for a delete that lost a race, a 400 for an insert naming a parent that never existed |
| `error.NotNullViolated` | `23502`. 500: a Row and a table that disagree |
| `error.CheckViolated` | `23514`: a `CHECK` somebody wrote on purpose, so the endpoint that hit it usually knows what it means |
| `error.ConstraintViolated` | the rest of class 23: an exclusion constraint, a `RESTRICT` |
| `error.Disconnected` | the database went away, or was never there. **503** by default |
| `error.RolledBack` | the database rolled the whole transaction back: a serialization failure (`40001`) under `.repeatable_read` or `.serializable`, a deadlock (`40P01`), or a plan whose result a running migration changed. Nothing in it was kept, and the fix is to run the whole transaction again. **503** by default |
| `error.TimedOut` | a statement ran past `tx.deadline`, or a wait for a free connection ran out of `timeout_ms`, on Postgres as on SQLite (`timeout_ms = 0` is no bound). No default status: what a deadline means is for the handler to decide |
| `error.Locked` | a `.lock = .update_nowait` found a row somebody else holds. No default status: a held row is a 409, a 503 or a retry depending on the endpoint |
| `error.QueryFailed` | anything else, including a statement or a `tx.commit()` in a transaction an earlier failed statement aborted, and an `update` or `delete` whose condition was left empty by the values it was given. The server's own words are on `Sent.problem` for a watcher and in the log; they never reach the client ([ADR 117](../adr/117-a-statement-that-failed-says-what-the-database-said.md)) |

Both drivers return the same error for the same failure. SQLite's extended result codes identify the three constraint errors above directly, which is what lets a handler tested against SQLite branch on what Postgres will send it.

#### `sql.problem`

**`sql.problem(c)` tells you what the error name cannot: *which* unique index fired** ([ADR 117](../adr/117-a-statement-that-failed-says-what-the-database-said.md)):

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

It returns a `sql.Problem` (`code`, `constraint`, `detail`, `message`) for the last statement **this fiber** ran, and null when it succeeded. It belongs to the call, not to the `Db`, which is one Service shared by every request in flight: it is bound to the fiber, every statement clears it, and a Scope other than the one the failure happened under gets null instead of another request's error. Read it in the `catch`: it lives as long as the request does, and the next statement replaces it.

`db.watching` is unchanged and is still the way to see *every* statement. The two answer different questions.

#### `sql.violated`

**`sql.violated(c, Row, .{ .email })` asks the same question with the constraint named by its columns**, which is the form to branch on:

```zig
error.AlreadyExists => if (sql.violated(c, Staff, .{.email}))
    return nilo.fail.conflict("that address is already on the staff", .{})
else
    return err,
```

The columns are checked while compiling against the key and every `.unique` the marker declares, in any order, so renaming or dropping a unique is a build error wherever a handler branches on it. It accepts both databases' formats: Postgres reports the constraint's name, `staff_email_key`, and SQLite the columns, `staff.email`. A primary key nobody named is `<table>_pkey` on Postgres, with the table's part cut at a character so the whole is 63 bytes: a table of 62 bytes has a key called after its first 58. `Problem.constraint` on SQLite is the text after `constraint failed:` for the same reason. A foreign key is not accepted, because SQLite does not say which one failed.

### `sql.Replays`: the answers two instances share

**`sql.Replays(Db, options)` is the store `nilo.Idempotent` takes in place of a `cache.Space` when more than one instance has to answer a key once** ([ADR 268](../adr/268-an-answer-kept-for-a-retry-is-a-row-when-instances-share-a-database.md)). A type, whose instance is a service:

<!-- compiles -->
```zig
const SharedReplays = sql.Replays(Db, .{ .name = "orders", .ttl_s = 86_400, .max_bytes = 16 << 10 });
```

| Option | |
|---|---|
| `.name` | which store this is, in the table it shares with others; required. Two stores with different names cannot read each other's keys |
| `.ttl_s` | seconds an answer is kept; 0 is until `sweep` deletes it. The in-flight marker lives two minutes whatever this says |
| `.max_bytes` | the largest answer kept, default 4,096; `Idempotent` refuses less than 256. A larger answer is sent and not kept |
| `.table` | the table, default `nilo_replays` |

| | |
|---|---|
| `SharedReplays.Row` | the table, for `migrate.createMissing`, a migration and `db.checking`. Nothing creates it: `space` (text) and `slot` (bytea) are the key, `value` is bytea, `expires_at` is microseconds since the epoch, indexed |
| `SharedReplays.open(&db)` | the store, to `app.provide`. It holds a pointer to the `Db` and nothing else |
| `putIfAbsentFor(scope, slot, value, ttl_s) !bool` | the claim: true when the key is now yours. A free key, or a row that has run out; false when somebody holds it. Atomic in the database, so two instances racing for one key get one `true` |
| `put(scope, slot, value) !void`, `putFor(…, ttl_s)` | store over whatever is there, for the store's `ttl_s` or the one given |
| `getInto(scope, slot, out) !?[]const u8` | the value, or null for a key nobody wrote, one that ran out, and a value longer than `out` |
| `del(scope, slot) !bool` | forget a key; true when there was a row |
| `sweep(scope) !usize` | delete this store's rows that have run out, and say how many. Nothing calls it: run it from a [scheduled job](../guide/background.md) |
| `takes_scope` | `true`, which tells `Idempotent` to call every method with the Scope first and to treat a failure as a database's. A `cache.Space` does not have it |

`slot` longer than 1,024 bytes or a value longer than `max_bytes` is `error.TooLarge`. Every other error is the `Db`'s, and `Idempotent` turns it into a 503 at the claim (the handler does not run) and a logged `warn` after the handler ran. A `Cached` over this type is a compile error: a page is read on every GET, which is a cache's job. Three more are refused while compiling: a type that is not a `Db`, an empty `name`, and a `max_bytes` of 0. The guide is [Once across instances](../guide/idempotency.md#once-across-instances-sqlreplays); the cost is in [`bench/result/sql.md`](https://github.com/nevindra/nilo/blob/main/bench/result/sql.md) §27.

### Migrations

**Migrations read the schema words in the marker and turn them into SQL.** The API is `sql.migrate`, `sql.table`, `sql.ddl` and `sql.snapshot`, and a program that never names one links none of it: 0 bytes on `zig build size-sql`, both probes ([`bench/result/sql.md` §10](../../bench/result/sql.md)).

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

#### The marker's schema words

| in the marker | what it means |
|---|---|
| `.default = .{ .created_at = .now }` | what the database writes when an insert leaves the column out. `.now` is the only special word, and only on a `sql.Timestamp`; anything else is a literal of the column's own Zig type, which must coerce or it does not compile. A column with its own words (an enum) takes one of them the way a column value is written: `.draft`, not `"draft"`. A default the database has to compute, such as `DEFAULT (lower(x))`, is still written as a step, and one on a generated key is a Refusal |
| `.filled = .{ .number, .created_at }` | columns the database fills by means the marker cannot express: a `DEFAULT` written in a step, `gen_random_uuid()`, a trigger. Produces no DDL; it lets an insert leave them out. `.filled = .created_at` for one. A column also in `.default`, the integer key a sequence fills, and a name that is not a column are each a Refusal ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)) |
| `.unique = .{ .email }` | one column. `.{ .{ .tenant_id, .name } }` is one constraint over two |
| `.{ .columns = .{.email}, .ignoring_case = true }` | the named form. `.ignoring_case` is `lower(...)` on Postgres and `COLLATE NOCASE` on SQLite, and it is a Refusal on a column that is not text. The lookup it serves is `.email = .{ .ieq = address }`, which folds both sides the same way |
| `.name = "users_one_account_per_address"` | what the constraint is called, on a `.unique`, an `.index` or a `.references`. **The name is the error message**: Postgres reports a violation by constraint name and nothing else, so this is the difference between a sentence and a list of columns. Text rather than `.a_word`, because that is what the database prints |
| `.index = .{ .created_at }` | the same three forms, without uniqueness |
| `.{ .created_at = .desc }` | one column of an index in descending order. `.asc` is the default and need not be written; a direction on a `.unique` is a Refusal, since a unique index is not read in order |
| `.where = .{ .deleted_at = null }` | a partial index. The same grammar a `db.select` condition uses, not a string: `null` is `IS NULL`, `.{ .ne = null }` is `IS NOT NULL`, a literal is `=` and `.{ .ne = lit }` is `<>`. A name that is not a column is a Refusal and a literal of the wrong type does not compile. An index over an expression, such as `lower(btrim(site))`, is still a step |
| `.references = .{ .org_id = .{ Org, .id } }` | keyed by the column that points, and it names the **Row** rather than a table, so renaming the table moves the key with it. A third entry says what happens on delete: `.cascade`, `.restrict` or `.set_null` |
| `.{ "orgs", .id, .cascade }` | the same key with the table named as text, for a program whose files may not import each other's Rows. **The type check still happens**: it runs against the Row list the tool was given, and a table no Row in that list claims is a Refusal ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)) |
| `.epic = .{ .columns = .{ .epic_id, .department_id }, .to = .{ WorkEpic, .{ .id, .department_id } } }` | a foreign key over two columns. This is how a rule like "the Epic has to be on the same board" is written once, instead of in a `.data` step and two `.unique` entries. Keyed by a label rather than a column, because a Zig field name cannot be a tuple. `.to` takes a Row or a name, and `.on_delete` and `.name` go in the same entry. A composite key is written as a table constraint; a one-column key stays inline, so nothing generated before this changed |
| `.tags = &.{ "a", "b" }` | an array column's default, written as a list. Each element goes through the column's own element type, and a comma, a brace, a quote, a backslash or an apostrophe inside one is escaped so it does not change how many elements there are ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)) |
| `.check = .{ .users_seats_are_positive = "seats > 0" }` | a `CHECK`, keyed by the name it gets in the database. **nilo does not read the body**: it writes it, hashes it, and notices when the hash changes. So a changed body is one drop and one create, and a name the types no longer have is a drop. Written inside the `CREATE TABLE`, so SQLite accepts it; changing one there takes the same rebuild every other table constraint needs ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)) |
| `.users_state_is_known = .{ .words_of = .state }` | names the `CHECK` an enum column already generates, instead of `users_state_check`. Changing that name is a migration: the constraint in the database still has the old one |
| `.trigger = .{ .users_touch = .{ .when = …, .run = … } }` | a trigger, in two halves, because nilo writes `ON "users"` between them. The table is the one thing the marker already knows, and a second copy of it would stop matching the day the table is renamed. Both databases create, replace and drop one |
| `.was = .{ .email = "handle" }` | this column used to have that name. The old name is text, because it is no longer a column |
| `.managed = false` | somebody else builds this table. `plan`, `createMissing` and `generate` skip it entirely |

#### Enum columns

**A column the Row reads as a Zig enum needs nothing declared.** It is a `text` column with `CHECK ("state" IN ('draft', 'live', 'archived'))` next to it, named `users_state_check` unless `.check` gave it another name, and the values are in the snapshot, so adding a tag to the enum is a migration rather than an insert the database rejects. An enum that names its own database type with `pub const nilo_column = "user_role"` belongs to the database: its values are added with `ALTER TYPE`, and nilo neither writes them nor checks them at startup.

#### `.managed = false`

**`.managed = false` is for a table this program reads but does not own.** A foreign key is checked against the Rows the tool was given, whether it names a Row or the table as text. So `comments.author_staff_id` cannot point at `staff` without a `Staff` Row in that list. But a Row in the list is part of the schema the diff sees, so the tool would emit `CREATE TABLE staff` for a table that has existed for a year and whose real definition has twenty columns this program never needed. One word fixes that:

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

Everything else about the Row is unchanged: `.references` may point at it, `db.checking` still compares it against the live schema, and every statement reads it the same way. Only who *builds* it changes ([ADR 130](../adr/130-a-table-this-program-reads-and-does-not-build.md)). The word is written into `migrations/snapshot.zon`, where `managed: true` writes nothing and `managed: false` writes a line, so a program that starts or stops building a table shows up as a change in a reviewed file.

#### Constraint names

**An unnamed constraint follows Postgres' own naming convention**, so a schema nilo generates and one written by hand look the same: `users_email_key`, `users_org_id_created_at_idx`, `users_org_id_fkey`, `users_state_check`.

**Every name is limited to 63 bytes, whatever the database.** Postgres shortens a longer name on the way in and reports it in a `NOTICE` that nothing here reads. That would leave the snapshot holding a name the database does not have, and two constraints whose first 63 bytes match would collide on the second `CREATE`. So a name over the limit is a compile error: for a name you gave, it says "make it shorter"; for a derived one, "give the entry a `.name`". SQLite has no limit but is held to the same 63, because a schema that compiles for one database and silently loses a name on the other defeats the point of one type describing both. Two entries that end up with the same name are a Refusal too.

#### Generated keys

**An integer key is generated; any other key is supplied.** That is a rule, not a word in the marker: `id: i64` becomes `GENERATED BY DEFAULT AS IDENTITY` on Postgres and `INTEGER PRIMARY KEY AUTOINCREMENT` on SQLite, and `id: sql.Uuid` becomes a `NOT NULL PRIMARY KEY` the insert has to fill.

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

**`sql.Schema` is one value, given to `db.checking`, `cli.Tool`, `createMissing`, `addMissingColumns` and the diff alike**, so they cannot drift apart ([ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)). `.tables` is every Row, in any order. The other three lists belong to the schema rather than to a table, and each defaults to empty:

| | |
|---|---|
| `.extensions` | names. `CREATE EXTENSION IF NOT EXISTS "x"`; `DROP EXTENSION` when the name is removed, marked destructive. A Refusal on SQLite |
| `.functions` | `.{ .name, .body }`, where the body is the **whole** `CREATE OR REPLACE FUNCTION <name> …` statement; a Refusal if it starts with anything else. New or changed is that one statement; removed is `DROP FUNCTION IF EXISTS`. A Refusal on SQLite |
| `.views` | `.{ .name, .body }`, where the body is the `SELECT`. nilo writes `CREATE VIEW "name" AS` in front, and a body that starts with `CREATE` is a Refusal. Changed is a drop and a create, removed is a drop |

**The tool decides the order**: extensions, functions, tables ordered by their references, each table's indexes and triggers, then views. A stale view is dropped before any table changes and a new one created after every table has, so a view that reads a column about to be removed is never in the way. In the snapshot an extension is its name, and a function or a view is a name and a hash, like a check.

#### Creating tables

```zig
try sql.migrate.createMissing(&db, &run, schema);
```

**`createMissing` runs one `CREATE TABLE IF NOT EXISTS` per Row plus its indexes, in one transaction.** Before them come the schema's extensions and functions, and after them its views, each in the form that is safe to run again (`CREATE OR REPLACE VIEW` on Postgres, which has no `IF NOT EXISTS` for a view, and `IF NOT EXISTS` on SQLite). **The order is worked out while compiling**, not taken from the list: foreign keys are written inline, which is the only form SQLite has, so `orgs` is created before `users` whichever order they are listed in, and a view after any view its text names. Two tables pointing at each other is a compile error naming both, and so are two tables giving an index the same name. **An index over a column the table does not have yet is left to `addMissingColumns`**, which makes it with the column: `createMissing` reads the columns of each table that has an index before it begins, so the two calls in that order stay the boot order when a new field has a unique.

It is for a test, a fixture or a single-file SQLite application. It is not a migration: it creates what is missing and never alters what is there.

**`addMissingColumns` is the next step**, for the same program once it has shipped and added a field. It runs one `ALTER TABLE … ADD COLUMN` per column a table lacks, from the same `Desc` the create reads, in one transaction, and returns how many were added. A column goes in with its `REFERENCES`, and every unique and index over it follows. A required column with no default is `error.NeedsBackfill`, with the statement in the log and nothing sent; a new column in a foreign key of several columns is `error.NeedsVersion` on SQLite, which writes one only with its table; a table that does not exist is skipped ([ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)).

```zig
try sql.migrate.createMissing(&db, &run, .{ .tables = &.{ Download, Segment } });
_ = try sql.migrate.addMissingColumns(&db, &run, .{ .tables = &.{ Download, Segment } });
```

| | |
|---|---|
| `migrate.createMissing(db, scope, schema)` | the above |
| `migrate.addMissingColumns(db, scope, schema)` | `!usize`: the columns added |
| `migrate.desiredOf(D, schema)` | comptime: the `Desired` half of a diff (every table as the types describe it, in create order, and the schema's other three lists) |
| `migrate.tablesOf(D, schema)` | comptime: just the tables, as `[]const Table` |
| `migrate.missingOf(D, schema)` | comptime: just the table statements |
| `ddl.createTable(D, Row)` | comptime: one `CREATE TABLE`, as text |

#### The diff

```zig
const change = try sql.migrate.plan(arena, Db.Dialect, desired, before);
```

`desired` is `migrate.desiredOf(D, schema)`, the types. `before` is a `snapshot.Doc`, which is `migrations/snapshot.zon` read back. **Both halves are files, so a diff needs no database**, and two branches that both generate a migration conflict in git rather than at deploy.

**`Plan.steps` is what to run, in order**, each with its `kind`, its `sql` and a line of `why`. `Plan.problems` is what the diff will not write, and **every problem is collected, not just the first**. Three things are refused on purpose:

- a column that changed in a way SQLite cannot follow (its type, its nullability, its default or an enum's values), since SQLite has neither `ALTER COLUMN` nor a way to replace a constraint;
- any foreign-key change on a table that already exists, on both dialects, except a key of one column on a column the table did not have: the diff writes it with the column (`ADD COLUMN … REFERENCES …`, one `add_column` step), and on SQLite a `.default` beside it is a `Problem`, since SQLite takes `REFERENCES` only on a column that defaults to NULL. The rest is refused because the one-statement form takes an `ACCESS EXCLUSIVE` lock and scans the table. The `Problem` spells out the `ADD CONSTRAINT … NOT VALID` then `VALIDATE CONSTRAINT` pair to write instead.
- on SQLite, a required column with no `.default`, and a column added with `.default = .now` to a table that exists: SQLite refuses a default it works out per row on a table with rows, so the version would fail at the deploy. The `Problem` names the rebuild to write, or says to ship the field optional and fill it in a step. `addMissingColumns` answers `error.NeedsVersion` for the same column on a table with rows ([ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)).

**A column that changed three ways gets one `Problem` naming all three**, because it needs one rewrite, not three.

**A `Problem` is accepted by name.** `Problem.key(gpa)` is `table.column@xxxxxxxx` (or `table@xxxxxxxx`), eight hex digits of a SHA-256 over the table, the column and the text; `acceptable()` is false for the one about the snapshot's dialect. `Options.accept` (`db generate --accept a,b`) records the named Problems as handled by a step the person wrote: it writes a version, possibly with no steps, and the snapshot becomes the types as they are. All standing Problems must be named together, a name matching none holds the version back (`Outcome.stray_accept`), and `Outcome.unaccepted` lists what was not named. `Plan.isEmpty()` is no steps and no Problems. `Plan.unaccepted` and `Plan.strayAccepts` are the two lists ([ADR 270](../adr/270-a-problem-is-accepted-by-name.md)).

`Plan.destructive()` and `Plan.needsBackfill()` are the two questions a command asks before writing a file. `Plan.unnamed(gpa, names)` is the targets of destructive steps that `names` leaves out, and `Plan.stray(gpa, names)` is the names that match no destructive step; `generate` writes only when both are empty. A destructive step's `target` is `orders`, `orders.note` or `extension:pgcrypto`. A `change_type` is destructive unless the type widens (`int4` to `int8`, `float4` to `float8`, an integer into `numeric`, `varchar` into `text`). A column added `NOT NULL` **with a `.default` needs no backfill**, which ADR 123 named as the one moment a default really matters.

#### The ledger, and applying

```zig
const chain = try sql.migrate.chainOf(arena, manifest.versions);
const ran = try sql.migrate.applyPending(&db, &run, chain);
```

**A `Version` is a number, a name and its steps, and it holds no hash.** A hash a caller can fill in is a hash a caller can fill in wrong, and a wrong one would make the drift check useless. `chainOf` is the only thing that computes one: it walks the list once and returns a `Chain`, which is the versions plus a hash each, with `.head()`, `.headHash()` and `.len()`.

The hash is **chained**: each one covers the version before it, so editing version 3 changes the hash of 3 and of everything after it, and `migrate.drift` finds the edit by looking at the head instead of walking every version. It is computed over the SQL, not the file bytes, so reformatting a generated file does not look like tampering, while changing a statement does.

**`nilo_migrations` is an ordinary Row, `migrate.Applied`, and its columns are a contract**, because a program in another language may have to write a row into it ([ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)):

| Column | Postgres | SQLite | What it holds |
|---|---|---|---|
| `version` | `int8 PRIMARY KEY` | `INTEGER PRIMARY KEY` | the number in the file name. Supplied, never generated |
| `name` | `text NOT NULL` | `TEXT NOT NULL` | the rest of the file name, `a-z`, `0-9` and `_` |
| `hash` | `text NOT NULL` | `TEXT NOT NULL` | 64 hex characters: SHA-256 of the steps, chained onto the version before |
| `applied_at` | `timestamptz NOT NULL` | `INTEGER NOT NULL` | when. SQLite holds microseconds since the epoch (ADR 067) |
| `ms` | `int8 NOT NULL` | `INTEGER NOT NULL` | how long it took. `0` is allowed and means nobody timed it |

`migrate.expect` reads the highest `version`; `migrate.drift` compares `hash` against what the steps hash to now. A row with the right `version` and a wrong `hash` is what `verify` is for.

`apply` is one transaction, begun `READ COMMITTED` on Postgres whatever the role's default is: take the advisory lock, check whether this version is already there, run every step, insert the row, commit. It returns `false` when the version had already been applied, which is what nine of ten replicas booting together get.

`migrate.applyPending(&db, &run, chain)` applies the whole list, in order, one transaction each, and returns how many ran. That is the in-process runner a single-file SQLite application calls from `app.before`, inside `listen()`. It creates the ledger if it is missing and reads it once: a version recorded under a different hash stops it before anything runs (`error.SchemaDrift`), and a version already recorded is skipped without a transaction. On SQLite a version that drops a table begins with `.rebuilding`, so a table rebuild's `DROP` does not cascade into the rows pointing at it; any other version keeps foreign keys on, so a `DELETE` of a parent cascades. `migrate.ensureLedger` is the first half on its own, under the same lock. A ledger that is already there is one catalog read and nothing more, so `expect` and `applyPending` boot under a role that may read and write rows and may create nothing.

`migrate.drift(&db, &run, chain)` returns which applied versions have been edited since they ran: a `Drift` per version with what the ledger recorded and what the steps hash to now.

**The lock matters.** The migration lock is polled: `pg_try_advisory_xact_lock` is asked for inside the transaction and released by the commit, so ten replicas starting at once run the migration once. A replica that is not granted it asks again after a 200 ms `pg_sleep`, rather than waiting in a blocking statement, which deadlocks with a concurrent index build (`CREATE INDEX CONCURRENTLY`); a replica that was waiting sees the release up to 200 ms late. SQLite has no advisory lock and needs none: it only ever has one writer.

**A version may run outside a transaction.** `Version.transactional = false` runs its steps one at a time on one held connection (`db.begin(c, .{ .transaction = false })`, Postgres only) and writes the ledger row after the last; a failure leaves no row and the version runs whole again, so its steps must be repeatable. `Step.index` is the quoted, qualified name of the index a step builds: before the step, an index of that name that `pg_index` calls invalid is dropped (`DROP INDEX CONCURRENTLY IF EXISTS`) with a `warn` line. On SQLite the version is `error.NotTransactional`. `Options.concurrently` (`db generate --concurrently a_idx,b_key`) names indexes on tables that exist; `Plan.splitOutside` cuts the plan into `inside` and `outside` steps, `generate` writes the second as `<name>_concurrently` after the first, and `Outcome.outside_file`, `.inside`, `.outside` and `.loose` (names matching no index) report it. The steps run with `lock_timeout` at 0 (a build waits for older transactions without blocking them), and the connection's own value is put back after. The migration lock is asked for and polled on both paths (`Dialect.advisoryLock`, `sessionLock`, `lock_pause`) ([ADR 269](../adr/269-an-index-on-a-big-table-is-built-outside-a-transaction.md)).

**A step waits at most `Version.lock_timeout_ms` for a table's lock**, 5,000 unless the version file says otherwise, on Postgres. `apply` sets it for the transaction after the advisory lock, so waiting for another replica is not bounded by it. A step that waits longer fails with `error.Locked`, one `warn` line names the version and the step, and nothing is kept. `.lock_timeout_ms = 0` waits for good, and the `.sql` twin writes `SET LOCAL lock_timeout = <ms>;` after its `BEGIN`. The number is not in the hash. A step that reads or rewrites every row while it holds the table (`SET NOT NULL`, a new `CHECK`, a type change such as `int4` to `int8`) says so in its `why` ([ADR 240](../adr/240-a-migration-waits-five-seconds-for-a-table.md)).

A version is a **list of steps**, and `Kind.data` is the kind the diff never produces. `Kind.rename_index` and `Kind.rename_constraint` are what the diff writes for an index, unique or foreign key over a column `.was` renamed, on Postgres, so the key is renamed with its column and not dropped and made again. That is what makes expand and contract possible: the backfill goes between the `add_column` that made the column and the `change_null` that tightens it, in one transaction, in one version.

#### Refusing to serve a database that is behind

```zig
db.expecting(manifest.head);
```

**One query, run by `listen()` on the pool it just opened, that refuses to start when the database is behind the code.** Almost nothing else has this check, and it catches one specific incident: the code went out before the migration did, and every request that touches the new column returns 500 until somebody notices. `sql.migrate.expect(&db, &run, manifest.head)` is the same check as a call, for a script with a `Run` in hand.

A database *ahead* of the binary is allowed and only logged. That is the normal middle of a two-stage deploy, and refusing it would make expand and contract impossible.

`migrate.standing(db, scope, want)` is the same query as a value (`.at`, `.want` and a `.verdict()` of `.level`, `.ahead` or `.behind`), for a program that would rather decide itself than be refused.

#### The files

```zig
const state = try sql.migrations.read(gpa, io, dir, Db.Dialect);
const out = try sql.migrations.generate(gpa, io, dir, Db.Dialect, desired, .{
    .name = "add_nickname",
});
```

**`read` opens a `migrations/` directory and returns the snapshot it holds and every version file in it, sorted.** `generate` runs the diff and writes three files: `NNNN_name.zig`, then `manifest.zig`, then `snapshot.zon`. **The order matters**: a run that dies halfway leaves a snapshot that is still behind, so the next run generates the same version again instead of skipping it. `generate` refuses a directory left in that state, where the snapshot is older than the newest version file, with `migrations.Error.SnapshotBehind`: planning against it would write the same steps again as the next version. It refuses the other direction too, a snapshot newer than the newest version file (a file deleted or lost in a merge), with `migrations.Error.SnapshotAhead`: the number the snapshot records is spent.

`check` is `generate` with nothing written: the same `Plan`, so CI and the person at the keyboard see one answer. It also names any `.sql` twin that has gone stale, which is the one thing it reports that is not in the `Plan`.

An `Outcome` says which of three things happened. `isEmpty()` means the Rows and the migrations already agree. `wasHeld()` means the version was not written: the diff reported a `Problem`, or something in it loses data that `Options.drop` did not name (`.unnamed`), or `Options.drop` named something it does not drop (`.stray`). Otherwise it wrote the file named in `.file`.

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
| `migrations.audit(gpa, state, versions)` | where the directory, the manifest and the snapshot disagree: a version file the manifest lost, a number that is not its file's, a duplicate, a snapshot ahead of or behind the newest file |
| `migrations.sqlTwin(gpa, file)` | `0007_name.zig` → `0007_name.sql` |
| `migrations.checkName(name)` | `a-z`, `0-9` and `_`, or `error.BadName` |

#### The `.sql` twin

**Every version file has a `.sql` twin next to it**, written by the same `generate` and regenerated whenever the `.zig` is ([ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)):

```
migrations/0007_work_items_get_a_priority.zig
migrations/0007_work_items_get_a_priority.sql
```

It holds the version's statements in order, each with its `why` above it as a comment, wrapped in `BEGIN`/`COMMIT`, with the ledger table created if missing and the ledger row at the end. Its first line is the dialect's `script_stop_on_error`, `\set ON_ERROR_STOP on` or `.bail on`, so `psql` or `sqlite3` stops at the first failed step and exits non-zero: it is a script for that shell, not SQL for a driver. `psql -f`, a CI job with no Zig toolchain, or somebody on a jump host can bring a database up to date with it, and `db.expecting(manifest.head)` still accepts the result and `verify` still checks the hash. **It is an output only**: nilo reads the `.zig` and never this file, and a version somebody else writes in SQL is not picked up.

The twin's hash is chained onto the version before it, so it is written from the compiled manifest: `Options.versions`, which `db generate` passes from what `Tool.run` was given. One case cannot be written: `--baseline` rewriting a version 1 whose `before` or `after` hold hand-written steps, because those are Zig that nothing has compiled yet. The `Outcome` reports it with `twins_deferred`, and `db check` asks for the file after the rebuild.

#### The generated block

**A version file is one `.zig` file holding a list of steps**, because a prepared statement is one statement and nilo prepares everything it sends (ADR 051). Splitting a `.sql` file into statements would need a lexer that understands `;` inside a string literal and inside `$$…$$`, and getting that slightly wrong runs three quarters of a migration. The list is already split. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md) has the full argument, including what the layout costs.

**Only one declaration in that file is generated.** The rest is yours, and it survives a rerun ([ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)):

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

`before` exists as well as `after` because a generated step can *need* a hand-written object: a `CREATE EXTENSION citext` has to run before the column whose type comes from it. `migrations.generated_begin` and `generated_end` are the two marker lines, matched as whole lines; a file that has lost one is refused with `error.NoGeneratedBlock` instead of being rewritten.

#### The commands

```zig
const Tool = sql.cli.Tool(Db, .{ .tables = &.{ User, Org } });
return Tool.run(gpa, io, out, try sql.cli.parse(argv[1..]), &db, manifest.versions);
```

**A project's migration tool is a ten-line `main`.** `sql.cli` handles argument parsing, dispatch and **every message a person reads**. The caller provides the allocator, the connection string and the `Db` type, because nobody else knows them. `run` takes a `Db` that is already started and returns an exit code instead of calling `std.process.exit`.

| Command | What it does |
|---|---|
| `generate --name <snake_case> [--drop <what>,…] [--baseline]` | diff the Rows against the snapshot and write the next version. No database |
| `check` | the same diff, written nowhere, plus any stale `.sql` twin. Exit 1 when they disagree. No database |
| `status [--sql]` | which versions this database has. `--sql` prints the waiting statements |
| `migrate` | apply what is waiting, one transaction per version, behind the lock |
| `verify` | has an applied version been edited since it ran? |

Every command takes `--dir <path>`, which defaults to `migrations`. There is no `down`: `generate` is forward-only by design, and the usage text says so where somebody will look for it.

**The exit code is the API for CI.** `0`: it did what was asked. `1`: the caller has something to do (a diff `check` found, a version `generate` held back, drift against the ledger, versions waiting). `2`: the command line was wrong. A CI job can branch on these without reading any output.

**`--drop` names exactly what it drops**, which is what stops a renamed field from becoming a dropped column: `--drop users.nickname,notes,extension:pgcrypto`. `generate` writes nothing at all when a step loses data that is not named, or when a name matches nothing: it prints each loss with its statement, then the command with the names filled in, and exits 1. Run that command and the generated file records it, in a `// Written with --drop …` line at the top and as `.destructive = true` on each step. A bare `--drop` names nothing.

`status` marks a version `edited` rather than `applied` when its file no longer hashes to what ran. It is the command people type first, so it has to stop saying everything is fine.

**`--baseline` is for porting a schema**, which means writing one version over and over rather than many versions. It ignores the snapshot, diffs the Rows against nothing, and rewrites version 1 in place along with the manifest and the snapshot, keeping everything outside the file's generated block. It is the only thing here that overwrites an existing file, so it refuses in three cases: a version it is not re-deriving is in the directory, `--name` disagrees with the existing version 1, or the file has no generated block. Each message names the files, and nothing is written.

#### Starting a migrations directory

**Write `manifest.zig` by hand once, before the first `generate`.** `generate` writes `manifest.zig` and the tool imports it, so the first build needs one to exist:

```zig
const std = @import("std");
const migrate = @import("nilo_sql").migrate;

pub const head: i64 = 0;
pub const versions: []const migrate.Version = &.{};

pub fn chain(gpa: std.mem.Allocator) !migrate.Chain {
    return migrate.chainOf(gpa, versions);
}
```

From then on it belongs to the tool: every `generate` rewrites it, and it is never edited by hand.
