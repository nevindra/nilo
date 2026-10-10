# SQLite

**The same code runs on SQLite after changing two lines; this page covers what is different: the threading choice, one writer at a time, and the features SQLite rejects at compile time.**

**Reference:** [SQLite](../../reference/sql.md#sqlite) · **Design:** [The SQL runtime](../../design/sql-runtime.md), [SQL column types](../../design/sql-types.md)

Everything in [Talking to a database](./README.md) is written once and runs against Postgres or SQLite.

## Switching to SQLite

**Change two lines and the rest of the guide stays the same:**

<!-- compiles: body -->
```zig
const Db = sql.Sqlite(.{ .threading = .{ .hop = nilo } });

var db = Db.init(gpa, "/var/lib/app/shop.db", .{ .size = 5 });
defer db.deinit();
db.checking(.{ .tables = &.{ User, Order } });
try app.provide(&db);
```

Your handlers do not change at all. They still take `db: *Db` and call `db.find`, `db.select`, `db.begin`. The driver was always behind a common interface, and SQLite is the second one to use it.

[`examples/sqlite/`](../../../examples/sqlite/main.zig) is a whole program on one file: tables created at startup, a page with a parent, a customer with their children, a report of grouped Rows, and a transaction. Run it with `zig build run-sqlite`.

## Choosing `.threading`

**`.threading` has no default, and leaving it out is a compile error that explains why.** This is deliberate, and the reason is worth thirty seconds.

Everything else nilo talks to is on a socket. When a request waits for Postgres, the fiber parks and its thread serves somebody else; that is what the event loop is for. **SQLite is not on a socket.** It is a library reading a file, so a statement is a function call that returns when it is done, and there is no wait for the loop to park on. Somebody has to decide what happens to the thread in the meantime, and only you know what your statements look like:

```zig
.threading = .{ .hop = nilo }   // hand it to the Engine's thread pool
.threading = .in_fiber          // run it right here
```

`.hop` costs a few microseconds per statement, and **no statement can stall a thread that is serving other connections**. `.in_fiber` skips that cost, and it is faster while every statement is a primary-key lookup from the page cache. But the day one of them scans a big table, every connection on that executor thread waits behind it.

**Use `.hop` unless you have measured otherwise.** Its worst case costs microseconds; the other one's is a stalled thread. (The whole `nilo` module is passed in because `sql/` is not allowed to import the server. That is the layering rule, and a build step enforces it.)

## One writer, several readers

**`.size = 5` means one writer and four readers.** That comes from SQLite, not from a setting: one connection may write at a time, and under WAL, which every connection here is set up with, readers carry on while it writes.

So writes queue. They wait on a lock that *parks the fiber* instead of holding its thread (the one thing the event loop is still useful for here), so a write that has to wait simply waits, rather than returning a `SQLITE_BUSY` you have to handle. If a write waits for five seconds you get `error.Locked`. `busy_timeout_ms` sets that number, and it can only be reached when **another process** uses the same file, since inside one process there is exactly one writer and it waits its turn.

The first keyword of a statement decides which connection it goes to: `SELECT`, `PRAGMA` and `EXPLAIN` go to a reader, everything else goes to the writer. For every statement this module writes, that is exact. For `db.raw` it is a guess, and the guess is made safe by opening readers read-only: a `raw` statement that writes but looks like a read fails loudly instead of reading a stale snapshot.

## Durability after a power cut

**Every connection uses `synchronous = NORMAL`: the database cannot be corrupted, but a power cut can lose the most recent transactions.** That is what SQLite recommends for applications. If losing a committed transaction is not acceptable, it is one setting:

```zig
sql.Sqlite(.{ .threading = .{ .hop = nilo }, .synchronous = .full })
```

That is not free, and the difference is an `fsync`, not anything in SQLite or nilo. On the machine `bench/result/sql.md` §9.5 ran on, it made each autocommitted insert 54× slower. Measure it on your own disk before deciding.

`OFF` is not offered. It is the setting where corruption is possible, and no default here should let you reach it by accident.

## What SQLite does not support

**Each of these is a compile error that names the dialect, not a surprise at run time:**

| | |
|---|---|
| `db.insertMany`, `db.updateMany` | SQLite has no array parameter, and its batch form grows the statement text with the batch, so the statement would no longer be a constant. Write one row at a time inside one `db.begin`; there is no network round trip per statement, so it is cheaper than it sounds |
| `.lock = .update` | writers are serialised by a lock over the whole database. There is no row to lock against anybody |
| `tx.deadline(ms)` | a deadline has to be enforced by the database, and there is no server. `busy_timeout_ms` covers the case that actually happens |
| a `[]const T` column | there is no array type. A list belongs in its own table, or in a TEXT column your own code encodes |
| `.isolation` below `.serializable` | SQLite gives every transaction a snapshot and serialises the writers. There is nothing weaker to ask for |
| `.like`, `.not_like`, `.contains`, `.starts_with`, `.ends_with` | SQLite's `LIKE` ignores ASCII case and a statement cannot turn that off, so a case-sensitive match would depend on how the file was opened. Each Refusal names the case-insensitive version (`.ilike`, `.icontains`), which is what this database does ([ADR 055](../../adr/055-the-second-dialect-is-the-test-of-the-seam.md)) |
| `.gt`, `.gte`, `.lt`, `.lte`, `.order`, `.after`, `sum`, `avg`, `min` or `max` over a `sql.Decimal` | the column is TEXT, so it compares as text and `"100.00"` sorts before `"9.99"`, and a sum is added in floating point. Equality and `.in` still work. Store an integer of the smallest unit, cents in an `i64` ([ADR 049](../../adr/049-a-column-type-can-come-from-outside-this-module.md)) |

**Two answers differ at run time rather than refusing to compile.** SQLite has no four-byte float, so an `f32` field reads a `REAL` column and is refused (`QueryFailed`) only when the value does not survive the narrowing: `0.5` reads, `0.1` does not. Postgres refuses a `float8` into an `f32` whatever it holds; declare the field `f64` to read the same on both.

**So a program that uses batches does not compile against both databases.** The shared interface fails loudly instead of quietly doing something else. Know this before you plan a migration assuming that swapping the line at the top is free.

One operator goes the other way. `.ilike` is Postgres's word for what SQLite's `LIKE` already does (ignore ASCII case), so on SQLite it is written `LIKE`, the same swap `icontains` makes. It used to be written `ILIKE` on both and failed with a syntax error here, so nothing could have depended on that. `.like` also went the other way for a while: it compiled here and ignored case, on this database only. A program that used it and wanted case-insensitive matching now writes `.ilike`, which is the one letter the Refusal names.

### Types that work on both

**A `sql.Uuid` is supported.** SQLite has no uuid type, so a uuid is stored as the thirty-six hyphenated characters in a TEXT column, which is what `sqlite3` shows you and what `WHERE public = '…'` takes. Postgres still sends sixteen bytes. Your Row says `public: sql.Uuid` either way, and neither the insert nor the read changes ([ADR 067](../../adr/067-a-value-is-whatever-the-database-stores.md)).

**A `sql.Json(T)` column, an enum column and `.in` are supported too.** For a while they worked in practice without being documented. SQLite has no `jsonb` and no enum type, so each of the three binds as text, and `.in` binds its whole list as one JSON array that `json_each` reads. Your Row and your conditions are the same on both ([ADR 067](../../adr/067-a-value-is-whatever-the-database-stores.md)). `.in` is the one that costs something here: one arena allocation per condition, on SQLite only, because the array has to be written out where Postgres sends a native one.

### A weaker schema check

**The schema check is weaker on SQLite, by exactly as much as SQLite's types are.** A column's declared type is free text (`VARCHAR(255)`, `NVARCHAR` and `CLOB` are all the same to the database), so the check catches a `Str` field over an `INTEGER` column but not an `i32` over a column holding values too big for it.

## Raw SQL on SQLite

**A raw statement's text is yours, and two things trip up a program written from the Postgres examples.** The [raw SQL page](./raw.md#what-sqlite-does-differently) has the longer list.

**`$1`, `$2`, … mean the same here.** SQLite's own numbered placeholder is `?1`, and `$name` there is a named parameter numbered by first appearance, so `WHERE ($2 IS NULL OR x = $2)` with no `$1` before it used to take the *first* value. nilo rewrites `$n` as `?n` while compiling, for every call that takes comptime text, so a statement written for Postgres binds by number here too and one text works on both ([ADR 204](../../adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)). `db.exec` takes run-time text and sends it as written; its statements are DDL, which has no parameters.

### Dates from a Timestamp

**A `sql.Timestamp` is stored as an INTEGER of microseconds since the epoch, and SQLite's date functions read seconds.** So a report by month divides first and names the epoch:

<!-- compiles: body -->
```zig
const MonthLine = struct {
    pub const nilo_table = .projection;

    month: nilo.Str,
    orders: i64,
};

const by_month = try db.raw(MonthLine, c,
    "SELECT strftime('%Y-%m', created_at / 1000000, 'unixepoch') AS month, count(*) " ++
    "FROM orders GROUP BY 1 ORDER BY 1",
    .{},
);
```

`date(created_at / 1000000, 'unixepoch')` is the day. `created_at >= strftime('%s', 'now', '-30 days') * 1000000` is a time window compared in the column's own unit, so the index on the column is still used. On Postgres the first one is written `to_char(date_trunc('month', created_at), 'YYYY-MM')`; a `nilo.Str` field takes either.

## The database filename

**`:memory:` is a fresh database for the pool that opens it, and for nobody else.** Its writer and readers see one database, and a second `Db` on `:memory:`, in the next test or one running beside it, gets an empty one of its own. It is gone when the pool closes. That is the spelling a test wants, and it needs no name:

```zig
":memory:"                               // one database per pool, private to it
"file:cache?mode=memory&cache=shared"    // one database per name, for pools that mean to share
```

The second form is SQLite's own, and nilo leaves it alone: every pool in the process that opens the same name opens the same database, which lives as long as a connection to it does. Two tests that reuse a name see each other's rows, so reach for it only when sharing is the point. **An empty URL is refused** at `open`, because it is far more often a setting that was never set than a choice.

**A test of WAL, locking or `Locked` has to use a file.** An in-memory database answers `memory` to `journal_mode = WAL` and has no other process to hold a lock. A reader refuses a write in both: on a file through the read-only flag, and in memory through `query_only`, because SQLite's URI `mode=memory` overrides the flag.

## What it costs

**523,352 bytes for a program that uses `sql.Sqlite`, and zero for one that does not.** The driver is fetched lazily and `sql/sqlite.zig` is only compiled when something uses it, so a Postgres-only binary carries no SQLite at all. A pool connection holds 28 KiB when opened and grows towards `cache_size` as it touches pages. The 2 MiB default made no difference in either workload that was measured, so lowering `cache_kib` costs almost nothing for a service that scans.
