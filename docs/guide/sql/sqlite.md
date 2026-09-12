# SQLite

Everything in [Talking to a database](./README.md) is written once and runs
against Postgres or SQLite. This page is what changes: one line of wiring,
the one question SQLite makes you answer, and the five things it refuses.

Swap two lines and the rest of the guide is unchanged:

<!-- compiles: body -->
```zig
const Db = sql.Sqlite(.{ .threading = .{ .hop = nilo } });

var db = Db.init(gpa, "/var/lib/app/shop.db", .{ .size = 5 });
defer db.deinit();
db.checking(&.{ User, Order });
try app.provide(&db);
```

Your handler does not change at all — it still takes `db: *Db` and calls
`db.find`, `db.select`, `db.begin`. That is the point: the driver was always
behind a seam, and SQLite is the second thing to come through it.

## The one question it makes you answer

`.threading` has **no default**, and leaving it out is a compile error that
explains itself. That is deliberate, and the reason is worth thirty seconds.

Everything else nilo talks to is on a socket. When a request waits for
Postgres, the fiber parks and its thread goes and serves somebody else — that
is what the whole event loop is for. **SQLite is not on a socket.** It is a
library reading a file, so a statement is a function call that returns when it
returns, and there is no wait for the loop to park on. Somebody has to decide
what happens to the thread meanwhile, and nobody but you knows what your
statements look like:

```zig
.threading = .{ .hop = nilo }   // hand it to the Engine's thread pool
.threading = .in_fiber          // run it right here
```

`.hop` costs a few microseconds per statement and **no statement can stall a
thread that is serving other connections**. `.in_fiber` skips that cost, and is
faster when every statement is a primary-key lookup out of the page cache —
until the day one of them scans a big table, at which point every connection
assigned to that executor thread waits behind it.

**Take `.hop` unless you have measured otherwise.** Its bad case is
microseconds; the other one's is a stalled thread. (`nilo` — the whole module
— is the payload because `sql/` is not allowed to import the server. That is
the layering rule, and it is a build step rather than a convention.)

## One writer, and readers beside it

`.size = 5` is **one writer and four readers**, and that is SQLite rather than
a knob: one connection may write at a time, and under WAL — which every
connection here is primed with — readers carry on while it does.

So writes queue. They queue on a lock that *parks the fiber* rather than
holding its thread, which is the one thing the event loop is still good for
here, and a write that waits is a wait rather than a `SQLITE_BUSY` you have to
interpret. If two of them queue for five seconds you get `error.Locked` —
`busy_timeout_ms` is the number, and it is only reachable from **another
process** on the same file, since inside one process there is exactly one
writer and it takes its turn.

Which connection a statement travels down is decided by its first keyword:
`SELECT` and `PRAGMA` take a reader, everything else takes the writer. For
every statement this module writes that is exact. For `db.raw` it is a guess,
and the guess is made safe by opening readers read-only — a `raw` that writes
and looks like a read is refused loudly instead of reading a stale snapshot.

## Losing power

Every connection gets `synchronous = NORMAL`, which is what SQLite recommends
for application use: the database **cannot corrupt**, and what a power cut can
lose is the most recent transactions. If losing a committed transaction is not
survivable, it is one word:

```zig
sql.Sqlite(.{ .threading = .{ .hop = nilo }, .synchronous = .full })
```

That is not free and the gap is an `fsync` rather than anything in SQLite or
nilo — on the machine `bench/result/sql.md` §9.5 ran on it was 54× per
autocommitted insert. Measure it on yours before deciding; the number belongs
to your disk.

`OFF` is not offered. It is the setting where corruption is possible, and no
default here should make it reachable by accident.

## What SQLite will not do

Five things, each a compile error that names the dialect rather than a runtime
surprise:

| | |
|---|---|
| `db.insertMany` | SQLite has no array parameter, and the batch form it does have grows the statement text with the batch — which stops it being a constant. Write a row at a time inside one `db.begin`; there is no round trip to pay per statement, so it is cheaper than it sounds |
| `.lock = .update` | writers are serialised by a lock over the whole database. There is no row to hold against anybody |
| `tx.deadline(ms)` | a deadline has to be enforced by the database, and there is no server. `busy_timeout_ms` covers the case that actually happens |
| a `[]const T` column | no array type. A list belongs in its own table, or in a TEXT column your own code encodes |
| `.isolation` below `.serializable` | SQLite gives every transaction a snapshot and serialises the writers. There is nothing weaker to ask for |

**So a program that batches does not compile against both.** That is the seam
refusing rather than quietly doing something else, and it is worth knowing
before you plan a migration on the assumption that swapping the line at the top
is free.

A `sql.Uuid` is **not** on that list. SQLite has no uuid type, so one travels as
the thirty-six hyphenated characters into a TEXT column — which is what
`sqlite3` shows you and what `WHERE public = '…'` takes. Postgres still sends
sixteen bytes. Your Row says `public: sql.Uuid` either way, and neither the
insert nor the read changes
([ADR 0078](../../adr/0078-a-uuid-is-whatever-the-database-stores.md)).

**A `sql.Json(T)` column, an enum column and `.in` are not on it either**, and
for a while they were on it in practice without being written down: SQLite has
no `jsonb` and no enum type, so each of the three binds as text, and `.in` binds
its whole list as one JSON array that `json_each` reads. Your Row and your
condition are the same on both
([ADR 0119](../../adr/0119-the-sqlite-write-path-is-compiled.md)). `.in` is the
one that costs something here — one arena allocation per condition, on SQLite
only — because the array has to be written out where Postgres sends a native
one.

The schema check is weaker here too, and by exactly as much as SQLite is. A
column's declared type is free text — `VARCHAR(255)`, `NVARCHAR` and `CLOB` are
all one thing to the database — so the check catches a `Str` field over an
`INTEGER` column and does not catch an `i32` over a column holding values too
big for it.

## Two things about the filename

A **bare `:memory:` is refused when you open it.** A pool of them would be
several separate empty databases: writes going to one, reads finding nothing.
The shared form is one database and is what to write:

```zig
"file:test?mode=memory&cache=shared"     // lives as long as a connection to it
```

And **a test that cares about read-only enforcement has to use a file.**
SQLite's URI `mode=` takes precedence over the flags a connection is opened
with, so a reader on an in-memory database can write, where the same reader on
a file cannot.

## What it costs

523,352 bytes to a program that names `sql.Sqlite`, and **zero to one that does
not** — the driver is fetched lazily and `sql/sqlite.zig` is only analysed when
something names it, so a Postgres-only binary carries no SQLite at all. A pool
connection holds 28 KiB when opened and grows towards `cache_size` as it
touches pages; the 2 MiB default bought nothing at either shape that was
measured, so lowering `cache_kib` is close to free for a service that scans.
