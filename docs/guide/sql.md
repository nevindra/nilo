# Talking to a database

`nilo_sql` is a second module. You import it separately, and a project that
never imports it links none of it — not the driver, not TLS, nothing.

```zig
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");
```

**Ask for it in `build.zig` first**, with one field beside the two you already
pass:

```zig
const nilo = b.dependency("nilo", .{
    .target = target,
    .optimize = optimize,
    .sql = true,          // ← fetches pg.zig and zqlite; without it, this module refuses to build
});
```

That flag exists because the drivers are 11 MB and most projects want neither.
Leaving it out and importing `nilo_sql` anyway is a compile error saying this
in one sentence, rather than a missing module or a mysterious `pg` — see
[ADR 0075](../adr/0075-a-lazy-dependency-is-a-request.md), which is also the
account of why `.lazy = true` on its own was not enough.

The idea is the same one the HTTP half runs on, pointed at a database: **the
struct you already wrote is the contract, and the compiler is the check.**

There are two databases behind that one idea. **`sql.Db` is Postgres and
`sql.Sqlite(…)` is SQLite**, and everything in this guide is written once and
works against either — the same Rows, the same conditions, the same
transactions. This page says Postgres throughout because that is the longer
story; [SQLite](#sqlite) says what changes, and it is one line of wiring and
five things SQLite refuses.

## A table is a struct

<!-- compiles -->
```zig
const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: nilo.Str,
    name: nilo.Str,
    age: i32,
    orders: i32,
    created_at: sql.Timestamp,
};
```

The table name is written out, never guessed. `User` → `users` looks clever
until `Category`, and every framework that guesses ends up shipping a list of
irregular nouns.

`.name = "app.users"` is a schema and a table, quoted as two identifiers and
introspected in that schema. A bare name is whatever `search_path` resolves
to, which is what it has always meant. One dot, with something on either side
— anything else is a compile error, because `a.b.c` names a relation nobody
created and Postgres would only say so at run time.

`.key` names the column that identifies a row, and defaults to `id` when
there is a field called that.

### Money

`sql.Decimal` reads a `numeric` column, and it holds **text**:

<!-- compiles: body -->
```zig
const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .key = .id };

    id: i64,
    total: sql.Decimal,        // numeric
};

const invoice = (try db.find(Invoice, c, 1)).?;
const total = invoice.total.text;                    // "1234.56"
_ = try db.insert(Invoice, c, .{ .total = sql.Decimal{ .text = "9.99" } });
```

There is no `.add` and no `.round`, which is the same line `sql.Timestamp`
holds: **a type here carries a value and knows how to write itself; it does
not calculate.** Decimal arithmetic is a library and a bigger one than it
looks — rounding modes alone are a standard. What this owes you is that the
digits which went in are the digits that come out, which a live test checks
with a value twenty-nine significant digits wide.

Comparisons are numeric, not textual: `.{ .total = .{ .gt = sql.Decimal{ .text = "50" } } }`
finds `100.00` and not `9.99`.

**In a JSON body it is a string**, `"1234.56"` rather than `1234.56`. A bare
number is exact on the wire and stops being exact in the consumer, where
`JSON.parse` answers a double — the `f64` the column type was chosen to avoid,
handed over silently on the far side of the network. A string arrives intact
([ADR 0050](../adr/0050-a-numeric-is-digits-and-a-string-in-json.md)). It is
also the only form that can carry `nan` and `inf`, which Postgres allows and
JSON has no number syntax for.

Unlike `sql.Json(T)` it **streams**: in a `Borrowed` row the field is a plain
`[]const u8`, so `db.stream` still allocates nothing per row.

### Lists

An array column is a plain Zig slice, with nothing wrapped round it:

<!-- compiles -->
```zig
const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    tags: []const nilo.Str,    // text[]
    scores: ?[]const i32,      // integer[], and the column may be null
    owners: []const sql.Uuid,  // uuid[]
};
```

Reading one is a Zig `for` and nothing else:

<!-- compiles: body -->
```zig
const ticket = (try db.find(Ticket, c, 1)).?;
for (ticket.tags) |tag| std.log.info("{s}", .{tag.view()});
```

`[]const u8` is text and was spoken for long before arrays were, so a list of
text is `[]const Str` or `[]const []const u8` and never `[]const u8`. Writing
one is the shape you would write anyway:

<!-- compiles: body -->
```zig
_ = try db.insert(Ticket, c, .{ .tags = &.{ "urgent", "billing" }, .scores = null });
```

Two things about arrays that Postgres allows and a Zig slice cannot hold:

- **A NULL among the elements.** Any Postgres array may have one, and there is
  no column definition that forbids it. Read into `[]const Str` that fails the
  request; read the column as `[]const ?nilo.Str` and the nulls come through.
- **More than one dimension.** A column declared `integer[]` will happily
  store `ARRAY[[1,2],[3,4]]`. A slice is one deep, so that fails the request
  too.

Both used to take the process down inside the driver
([ADR 0051](../adr/0051-an-array-is-a-slice-and-a-slice-is-one-deep.md)).

`[]const sql.Uuid` is `uuid[]`, and it reads, writes and works as an `.in`
list — which is what stops an N+1 on a page that attaches children to its rows
([ADR 0145](../adr/0145-a-raw-parameter-is-converted-the-way-a-rows-is.md)).

An array is judged **exactly** at startup: an `int4[]` column reads into a
`[]const i32`, and not into a `[]const i64` the way a scalar `int4` reads into
an `i64`. And a Row that reads an array cannot be `db.stream`ed, for the same
reason a `Json` column cannot — see [Streaming](#streaming-a-result-set-too-big-to-hold).

### A column type of your own

The types above are the ones this module chose to know about, and Postgres has
hundreds more — `interval`, `inet`, `money`, `tsvector`, everything an
extension installs. The list is not closed:

<!-- compiles: body -->
```zig
const Money = sql.AsText("money");

const Sale = struct {
    pub const nilo_table = .{ .name = "sales", .key = .id };

    id: i64,
    amount: Money,           // money
};

const sale = (try db.find(Sale, c, 1)).?;
const shown = sale.amount.text;    // "$1,234.56", as Postgres printed it
```

`sql.Interval` and `sql.Inet` are two of those written out for you, and
`sql.Decimal` is a third — there is no special case underneath any of them.

A type that wants **structure** rather than text writes the protocol itself.
Three declarations make anything a column type:

```zig
const Cents = struct {
    value: i64,

    pub const nilo_column = "numeric";

    pub fn nilo_read(text: []const u8, arena: std.mem.Allocator) !Cents {
        … parse "12.34" into 1234 …
    }

    pub fn nilo_write(self: Cents, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{d}.{d:0>2}", .{ … });
    }
};
```

It travels as the text Postgres prints — `"amount"::text` on the way out,
`$1::numeric` on the way in — which is the one representation every Postgres
type has, and it is why this module does not need to know what your type is
([ADR 0055](../adr/0055-a-column-type-can-come-from-outside-this-module.md)).
The column is checked against the table at startup like any other, and the
type works everywhere a column type works: conditions, `.set`, `insert`, a
batch.

Two mistakes stop at compile time — one of `nilo_read`/`nilo_write` without
the other, and both without a `nilo_column`. One thing is still closed: an
**array** of one is not read, the same boundary `[]const sql.Decimal` has
always had.

## The query is a constant

<!-- compiles -->
```zig
fn listAdults(db: *sql.Db, c: *nilo.Ctx) ![]User {
    return db.select(User, c, .{
        .where = .{ .age = .{ .gt = 18 } },
        .order = .{ .created_at = .desc },
        .limit = 10,
    });
}
```

That compiles to this, before the program runs:

```sql
SELECT "id", "email", "age", "created_at" FROM "users"
WHERE "age" > $1 ORDER BY "created_at" DESC LIMIT 10
```

Exactly one thing reaches run time and it is the `18`. Which table, which
columns, which operators, how many parameters — all settled while compiling,
and all a compile error when wrong:

```
$ zig build
error: nilo: User has no column `agee`, asked for in a condition.
       Did you mean `age`?
```

Note the `limit`. A literal is baked into the SQL, which also gives Postgres
a number to plan with. A limit held in a variable becomes a parameter
instead. That is the same rule read strictly, not an inconsistency: `10`
written in the source is shape, and shape is settled early.

## Conditions

Different fields are ANDed, because that is what a struct is. Several
operators on one field are ANDed too, so a range needs no `between` and no
second idea.

```zig
.where = .{
    .age = .{ .gte = 18, .lt = 65 },
    .email = .{ .like = "%@example.dev" },
    .deleted_at = null,                      // IS NULL
    .any = .{                                // OR, bracketed
        .{ .role = "admin" },
        .{ .verified = true },
    },
}
```

`.any` rather than `.or` because `or` is a Zig keyword and would have to be
written `.@"or"`. The cost is that `any` becomes a reserved column name, and
a Row with a column called that is refused by name rather than quietly
misread.

`.in` takes a list and compiles to `= ANY($1)` — **one** parameter, so the
statement stays a constant no matter how long the list is. Its negation is
`.not_in`, which is `<> ALL($1)` and costs the same one parameter;
`.not_like` and `.not_ilike` are the other two. `.distinct_from` and
`.not_distinct_from` are the null-safe pair — see below.

### A null is written, never held

`.deleted_at = null` above is `IS NULL` because the compiler can see the
null. This is not:

```zig
const maybe: ?[]const u8 = c.query.handle;      // may or may not be there
.where = .{ .handle = maybe }                   // ✗ compile error
```

The two readings are two different statements — `"handle" = $1` and
`"handle" IS NULL` — and which one is right depends on a value that arrives
after the statement is already a constant. Sending `= $1` with NULL in it is
legal SQL and *never true*, so the query would run, match nothing and report
nothing at all.

Usually what you meant is SQL's null-safe comparison, and that **is** one
statement:

```zig
.where = .{ .handle = .{ .not_distinct_from = maybe } }   // ✓
```

`IS NOT DISTINCT FROM` is `=` with null treated as an ordinary value: two
nulls match, and null against anything else does not. It takes an optional
where nothing else does, and the reason is the same rule read the other way
— the statement is the same six words whether the value turns out to be null
or not, so nothing about its shape waits for run time. `.distinct_from` is
the negation, and it finds the null rows that `<>` silently drops.

Where the two cases really are two different queries, write the branch:

```zig
const found = if (maybe) |handle|
    try db.select(User, c, .{ .where = .{ .handle = handle } })
else
    try db.select(User, c, .{ .where = .{ .handle = null } });
```

Only the value you write is judged. A `?[]const u8` column compared against a
plain `[]const u8` is an ordinary condition, and so is every `.set` and every
`insert` — `SET handle = $1` with NULL in it means exactly one thing
([ADR 0044](../adr/0044-a-condition-holds-a-value-not-a-maybe.md)).

## A filter nobody set

A search box that is empty is not a search for nothing. `.status = null` asks
for the rows whose status is null; a filter nobody set wants **no condition on
status at all**, which is the opposite — one matches a handful of rows and the
other matches every one.

`sql.given` is that, and it is a word rather than an optional so the two stay
tellable apart
([ADR 0183](../adr/0183-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)):

<!-- compiles: body -->
```zig
// search: ?[]const u8 and least_age: ?i32, straight off the query string.
const found = try db.page(User, c, .{
    .where = .{
        .email = .{ .icontains = sql.given(search) },
        .age = .{ .gte = sql.given(least_age) },
    },
    .order = .{ .id = .asc },
    .limit = 20,
});
```

```sql
($1 IS NULL OR "email" ILIKE …) AND ($2 IS NULL OR "age" >= $2)
```

**One statement whatever the screen is set to**, so one parameter list and one
prepared plan. The alternative — a statement per combination of filters — is
four for two filters and sixteen for four, each with its own parameter tuple.
Postgres folds `$1 IS NULL` away while it is planning with the actual values,
which it does for the first five executions and for as long after that as the
custom plan wins, so a filter that *is* set plans as if the guard were not
written.

Inside an `.exists` it drops the **whole subquery**, not the term:

<!-- compiles: body -->
```zig
// capability: ?nilo.Str — the dropdown nobody has touched yet.
const partners = try db.page(Partner, c, .{
    .where = .{ .exists = .{
        .{ .in = PartnerCapability, .where = .{ .capability = sql.given(capability) } },
    } },
    .order = .{ .name = .asc },
    .limit = 20,
});
```

With the term dropped instead, the subquery would ask whether the partner has
*any* capability row — which quietly excludes every partner that has none. For
the same reason a `sql.given` cannot sit beside a condition that is always there
in one `.exists`; write a second entry.

It is refused inside `.any` (OR reverses what dropping a term means), on `.in`
and `not_distinct_from`, on a value that is not optional, and **in the condition
of an `UPDATE` or a `DELETE`** — there a term that may not be there is the whole
table.

## Wiring it up

<!-- compiles -->
```zig
pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var db = sql.Db.init(gpa, "postgres://app:secret@localhost/shop", .{});
    defer db.deinit();
    db.checking(&.{ User, Order });     // optional, see below

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.provide(&db);
    try app.get("/adults", listAdults);
    try app.listen(.{});
}
```

`init` opens nothing. It cannot: the pool has to dial, dialling needs the
event loop, and the loop does not exist until `listen()` starts it. So the
pool is built inside `listen()`, before the first connection is accepted.

That has a consequence worth relying on: **your server starts with Postgres
switched off.** Working on an endpoint that never touches the database does
not mean starting a database first. The first request that *does* touch it
gets `error.Disconnected`, which is the truth.

Set `.connect_on_init = 2` if you would rather find out at startup — in
production, that is usually what you want.

### If the database is on the same box, do not use TCP

This is the largest performance number in the whole module and it is a
connection string rather than anything in your code:

<!-- compiles: body -->
```zig
// 458,000 req/s with a real query per request
var db = sql.Db.init(gpa,
    "postgres://app:secret@%2Fvar%2Frun%2Fpostgresql%2F.s.PGSQL.5432/shop", .{});
```

Measured on one box, same server, same query: a Docker published port serves
197k requests a second, loopback TCP 359k, **a unix socket 458k** — and p99
halves. The cost is conntrack and netfilter, paid per packet, twice a round
trip ([`bench/result/sql.md`](../../bench/result/sql.md)).

Two things about the spelling, because both are easy to get wrong:

- The host is the **full socket path**, `/var/run/postgresql/.s.PGSQL.5432`,
  not the directory libpq wants.
- **Percent-encode the slashes** — `%2F` — or the URL parser will not keep them
  in the host field. Getting it wrong is `error.Unexpected`.

A container reaching a database on the host does this by mounting the socket
directory; `sql/docker-compose.yml` shows the other direction.

## SQLite

Swap two lines and the rest of this page is unchanged:

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

### The one question it makes you answer

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

### One writer, and readers beside it

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

### Losing power

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

### What SQLite will not do

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
([ADR 0078](../adr/0078-a-uuid-is-whatever-the-database-stores.md)).

**A `sql.Json(T)` column, an enum column and `.in` are not on it either**, and
for a while they were on it in practice without being written down: SQLite has
no `jsonb` and no enum type, so each of the three binds as text, and `.in` binds
its whole list as one JSON array that `json_each` reads. Your Row and your
condition are the same on both
([ADR 0119](../adr/0119-the-sqlite-write-path-is-compiled.md)). `.in` is the
one that costs something here — one arena allocation per condition, on SQLite
only — because the array has to be written out where Postgres sends a native
one.

The schema check is weaker here too, and by exactly as much as SQLite is. A
column's declared type is free text — `VARCHAR(255)`, `NVARCHAR` and `CLOB` are
all one thing to the database — so the check catches a `Str` field over an
`INTEGER` column and does not catch an `i32` over a column holding values too
big for it.

### Two things about the filename

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

### What it costs

523,352 bytes to a program that names `sql.Sqlite`, and **zero to one that does
not** — the driver is fetched lazily and `sql/sqlite.zig` is only analysed when
something names it, so a Postgres-only binary carries no SQLite at all. A pool
connection holds 28 KiB when opened and grows towards `cache_size` as it
touches pages; the 2 MiB default bought nothing at either shape that was
measured, so lowering `cache_kib` is close to free for a service that scans.

## Reading

<!-- compiles: body -->
```zig
const all   = try db.select(User, c, .{ .where = .{ .age = .{ .gt = 18 } } });
const maybe = try db.one(User, c, .{ .where = .{ .id = id } });
```

`one` returns `?User`, so a handler that returns `!?User` answers **404**
when there is nothing — and the OpenAPI document says so, because the `?`
already meant that. Two modules that never import each other, agreeing,
because they read the same struct you wrote.

It compiles its own `LIMIT 1`, so a condition on a column that is not unique
costs one row rather than every match. Writing a `.limit` beside it is a
compile error: the ceiling belongs to the call.

A lookup by key is the same thing with the condition already filled in:

<!-- compiles -->
```zig
fn show(db: *sql.Db, c: *nilo.Ctx, id: i64) !?User {
    return db.find(User, c, id);
}
```

That is a whole endpoint. The column comes from the Row's `.key`, so it is
not written out at every call site, and `?User` is the 404. A struct where
the key goes is a compile error pointing at `one` — `find` takes the value
itself.

Every call takes the `Ctx`. Not to read the request: for the request arena,
which is where the rows go. They live exactly as long as the response that
carries them, and nothing is freed by hand.

## Counting

<!-- compiles: body -->
```zig
const total = try db.count(User, c, .{ .where = .{ .age = .{ .gt = 18 } } });
const taken = try db.exists(User, c, .{ .where = .{ .email = email } });
```

`count` answers a `usize` and `exists` a `bool`. Both take a condition and
nothing else — there is nothing to sort and nothing to narrow in an answer
one row wide, so `.order` and `.limit` are compile errors rather than clauses
quietly dropped. A `count` with no condition counts the table.

`exists` is `SELECT EXISTS(…)` rather than a count compared against zero, so
the database stops at the first matching row instead of counting every one of
them to settle a question the first one settles.

The condition goes through the same walker `select` uses, so a column
misspelled in either is the same compile error.

## A page and its total

A trimmed list has to say what it trimmed. `db.page` answers both numbers out
of one statement:

<!-- compiles: body -->
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

**The round trip is the smaller half of why.** A `db.count` beside a
`db.select` is two statements against a table somebody else can write between,
so the screen says *"20 of 47"* while holding 20 of 46 and nothing says so.
`count(*) OVER ()` rides on the page and cannot come apart from it
([ADR 0185](../adr/0185-a-page-knows-what-it-left-out.md)). It costs one integer
read per statement rather than per row: the window function answers the same
number on every row, so only the first is read.

`.limit` and `.order` are both required. With no ceiling this is the whole
table and the total is `rows.len`; with no order, Postgres owes the `LIMIT`
nothing, so two requests for the same page can hold one row twice and miss
another. `.lock` is refused — `FOR UPDATE` and a window function cannot be in
one statement. `tx.page` is the same call inside a transaction.

`db.count` is still the call when you want a total and no rows.

## Why writing the limit out is worth it

A `.limit` written as a literal is baked into the SQL, and that buys two
things. Postgres gets a number to plan with, which `LIMIT $2` does not give
it. And nilo knows before the first row arrives how many can possibly come,
so the list they go into is built once at that size.

Measured over a 32-byte row: **one** allocation with the limit written out,
the same at ten rows and at a hundred thousand. Without it, 2, 3, 5 and 9 at
ten, a hundred, a thousand and a hundred thousand — the list doubling its way
there, and each doubling abandons the buffer before it, because a request
arena has no way to take one back.

The ceiling is not a promise about how many rows arrive. Asking for a
thousand and getting three reserves room for a thousand, and the difference is
held until the request ends. The number you wrote is believed.

What it actually asks the `Ctx` for is two calls — `arena()` and `str()` — so
what it takes is a **Scope**, and a `*Ctx` is one
([ADR 0041](../adr/0041-a-module-sits-where-the-loop-puts-it.md)). Where there
is no request there is `nilo.Run`, which owns an arena and a lifetime of its
own:

<!-- compiles: body -->
```zig
var run = nilo.Run.init(gpa);
defer run.deinit();

const adults = try db.select(User, &run, .{ .where = .{ .age = .{ .gt = 18 } } });
```

Same query, same rows, no server in the process.

**A `Run` is an arena and a lifetime. What it is not is a connection.** The
pool is opened by `nilo_start`, and until something calls it every query answers
`error.Disconnected` — so a script, a migration, or a test needs one more line
than the snippet above
([ADR 0079](../adr/0079-there-is-a-phase-before-the-server.md)):

<!-- compiles: body -->
```zig
var threaded: std.Io.Threaded = .init(gpa, .{});   // std's own, not the Engine
defer threaded.deinit();
try db.nilo_start(threaded.io(), .off);                  // the pool is open from here

var run = nilo.Run.init(gpa);
defer run.deinit();
```

Inside a program that also serves, `app.start(io)` is the same thing for every
service the App holds at once — the phase after the pool and before the server:

<!-- compiles: body -->
```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();

try app.provide(&db);
try app.start(threaded.io());        // services checked, pools open, schema checked

var run = nilo.Run.init(gpa);
defer run.deinit();
_ = try db.exec(&run, schema_sql, .{});

try app.listen(.{ .port = 8080 });   // does not open them a second time
```

**A SQLite application needs this and most Postgres ones do not**: there is no
server to have created the tables somewhere else, so `zig build run` on a fresh
machine has to do it.

## Writing

<!-- compiles: body -->
```zig
const made = try db.insert(User, c, .{ .email = "a@b.c", .age = 30 });
// made.id is the generated key

const changed = try db.update(User, c, .{
    .set = .{ .age = 31 },
    .where = .{ .id = made.id },
});

const gone = try db.delete(User, c, .{ .where = .{ .id = made.id } });
```

`insert` names a **subset** of the columns, because the ones the database
fills in — a generated key, a `DEFAULT now()` — are exactly the ones you have
nothing to say about. What comes back is the whole row, via `RETURNING`, so
there is no second query to fetch what the database just had in its hand.

`update` and `delete` answer with the number of rows they touched, and both
**require** a condition. An update with no `.where` rewrites the table and a
delete with none empties it; each is reached by leaving something out rather
than by writing something down, so each is a compile error:

```
error: nilo: an update on User with no condition.
       That rewrites every row in the table. If it is meant, `db.raw` says
       so where somebody reading the code can see it.
```

### Many rows at once

A loop of `db.insert` is a round trip per row, and inside a transaction it is
a round trip per row holding a pool connection. `insertMany` is one statement:

<!-- compiles -->
```zig
const Line = struct { sku: nilo.Str, qty: i32 };

fn receive(db: *sql.Db, c: *nilo.Ctx, body: []const Line) ![]Item {
    return db.insertMany(Item, c, body);
}
```

The rows come back in the order they were sent. `tx.insertMany` is the same
call inside a transaction.

The rows are a slice of a **named** struct rather than a tuple of literals,
because the statement is compiled from the element type. What it compiles to
is one array parameter per column:

```sql
INSERT INTO "items" ("sku", "qty")
SELECT * FROM unnest($1::text[], $2::int4[])
RETURNING "id", "sku", "qty"
```

Two placeholders for any number of rows, which is what keeps the statement a
constant — the `VALUES ($1,$2),($3,$4),…` most libraries generate has the
batch size *in* it, so the SQL would be rebuilt per call and Postgres would
plan it again for every distinct size
([ADR 0053](../adr/0053-a-batch-is-one-array-per-column.md)).

It is one statement, so a batch that violates a constraint stores **none** of
its rows — usually what was wanted, and the opposite of a loop of inserts with
nothing around it. An empty batch runs the statement, stores nothing and
answers with nothing.

Two columns cannot be batched, and both say so at compile time: a list column,
because `unnest` would flatten it into one row per element, and an enum that
has not declared what its Postgres type is called.

`updateMany` is the same trick joined against the table rather than selected
into it:

```zig
const Change = struct { id: i64, qty: i32 };
const changed = try db.updateMany(Item, c, changes);
```

```sql
UPDATE "items" AS t SET "qty" = v."qty"
FROM unnest($1::int8[], $2::int4[]) AS v("id", "qty")
WHERE t."id" = v."id"
RETURNING t."id", t."sku", t."qty"
```

Each row carries the Row's **key** and is found by it — that is why there is
no `.where` to write, and why a batch that does not carry the key is a compile
error. A key the table does not have matches nothing, so an answer shorter
than the batch tells you which landed.

Two things it does not promise, and both are properties of a join rather than
choices: the **order** rows come back in is the planner's, and a batch naming
the same key twice changes that row once, from whichever of the two Postgres
reached. Where either matters, `db.update` in a loop is the honest shape.

### Giving back the rows instead of the count

A `PATCH` endpoint changes a row and answers with it. Written with `update`
that is two round trips, and the second one may read what somebody else
changed in between:

<!-- compiles -->
```zig
fn rename(db: *sql.Db, c: *nilo.Ctx, id: i64, body: Rename) !?User {
    return db.updateReturningOne(User, c, .{
        .set = .{ .name = body.name },
        .where = .{ .id = id },
    });
}
```

`updateReturning` is the same statement answering with the slice, for a `.where`
that means to match many rows. `deleteReturning` is the other half, for a delete
that has to report or log what it took. The clause they add is the `SELECT` list
this module already writes, so none of them costs a statement the compiler did
not settle.

**`updateReturningOne` is the unwrap, not a narrower statement**
([ADR 0179](../adr/0179-a-statement-with-a-key-in-it-has-a-single-row-answer.md)).
The `.where` is yours: an `UPDATE` matching several rows updates all of them, and
this hands back the first. What it saves is `if (changed.len == 0) null else
changed[0]` at every call site — and `!?User` is already a 404 in the typed
layer, so the handler above is the whole endpoint.

`db.rawOne` is the same shape for a statement you wrote yourself. **It adds no
`LIMIT 1`**, unlike `db.one`: this module did not write the statement and has
nowhere honest to put one.

### Writing a row that may already be there

The shape everybody writes first is a caught error and a second statement:

```zig
const user = db.insert(User, c, .{ .email = email, .name = name }) catch |err| switch (err) {
    error.AlreadyExists => try db.updateReturning(User, c, .{ … }),   // two round trips
    else => return err,
};
```

That is two round trips, and there is a window between them: two requests can
both fail the insert, both run the update, and the second one wins whatever
order they arrive in. `ON CONFLICT` is one statement and has no window.

<!-- compiles: body -->
```zig
// Leave the row that is there alone. `null` means it was already there.
const made = try db.insertOrIgnore(User, c, .{ .email = email }, .email);

// Or write these values over it. Either way a row comes back.
const user = try db.insertOrUpdate(User, c, .{
    .email = email,
    .name = name,
}, .email);
```

The last argument is the **conflict target**: the column the database has a
unique constraint or index on, written the way a key is. For a constraint
spanning two columns it is a tuple, `.{ .tenant_id, .email }`. It is not
required to be the Row's key — an email is the ordinary case and is usually
not — and nothing on this side can check that a constraint exists, because a
constraint is not a column and a Row cannot name one. Postgres refuses the
statement if there is none.

**When it *is* the key, write `.key`**
([ADR 0186](../adr/0186-a-key-is-named-once.md)):

<!-- compiles: body -->
```zig
_ = try tx.insertOrIgnore(UserTag, c, .{ .user_id = id, .tag = tag_name }, .key);
```

A join table already names its composite key in `nilo_table`, and spelling the
tuple again at the call site is two copies that can disagree — a key that gains
a column and a call site that does not is a statement conflicting on the *old*
columns, which inserts a duplicate where it used to ignore one. A Row that also
has a column called `key` is a compile error naming both readings.

**They are two calls rather than one call with an option**, because the answer
is a different shape. `DO NOTHING` stores no row, and `RETURNING` on a row
that was not stored gives nothing back — so `insertOrIgnore` returns `?User`
where `insertOrUpdate` returns `User`. It is the same reason `one` is not
`select` with a flag.

`insertOrUpdate` sets every column you passed **except the conflict target and
the key**. The target is the value the two rows were matched on. The key is
left out because a caller passing `.id` is filling in the insert half — nobody
means "renumber the row that is already there", and Postgres would do it
quietly, along with every foreign key pointing at that row. If that leaves
nothing to set, the compiler says so and names the call you wanted:

```
error: nilo: `db.insertOrUpdate` on User has nothing to set.
       Every column it was given is either the conflict target or the key
       `id`, and the update half writes neither.
       `db.insertOrIgnore` is the statement with nothing to set, and says so.
```

## Transactions

<!-- compiles: body -->
```zig
var tx = try db.begin(c, .{});
defer tx.deinit();                  // rolls back unless committed

const order = try tx.insert(Order, c, .{ .user_id = user.id, .total = 4200 });
_ = try tx.update(User, c, .{ .set = .{ .orders = user.orders + 1 }, .where = .{ .id = user.id } });

try tx.commit();
```

`tx` carries the same calls `db` does, all down the one connection it holds.
The `defer` is not decoration: a connection returned to the pool inside an
open transaction is a connection the *next* request runs inside a stranger's
transaction. `deinit` rolls back on every path out, including the ones nobody
wrote.

Forgetting it is caught in Debug by a counter checked at `db.deinit()`.

### Giving a statement a deadline

`timeout_ms` on the pool bounds how long you wait *for a connection*. It stops
the moment you get one, so a query that turns out to be expensive runs until
somebody notices. `tx.deadline` bounds the statements themselves:

<!-- compiles: body -->
```zig
var tx = try db.begin(c, .{});
defer tx.deinit();

try tx.deadline(2_000);             // milliseconds, one round trip

const rows = tx.select(Report, c, .{ .where = .{ .month = month } }) catch |err| switch (err) {
    error.TimedOut => return nilo.fail.status(504, "that report is taking too long", .{}),
    else => return err,
};
try tx.commit();
```

Postgres undoes it when the transaction ends, whichever way it ends, so the
connection goes back to the pool carrying nothing.

**Only a transaction has one.** A deadline is always a second command — SQL
has no way to attach one to a statement in the same message — so it has to
travel down the same connection as the statement it bounds. `db.select` takes
whichever connection is free and hands it straight back, so there is nothing
to set one on ([ADR 0047](../adr/0047-a-deadline-needs-a-connection-you-hold.md)).

For a floor under *everything*, including the queries that are not in a
transaction, set it beside the database rather than in your code:

```sql
ALTER ROLE app SET statement_timeout = '30s';
```

### Saying what the transaction is, on the `BEGIN`

<!-- compiles: body -->
```zig
var tx = try db.begin(c, .{ .isolation = .serializable, .read_only = true });
```

Both ride on the `BEGIN` itself — `BEGIN ISOLATION LEVEL SERIALIZABLE READ
ONLY` — so neither costs a round trip. `.isolation` is `.read_committed`,
`.repeatable_read` or `.serializable`; leaving it out means whatever the
server is set to, which is usually read committed and is not always, because
`ALTER ROLE … SET default_transaction_isolation` exists. A transaction that
has to be read-committed can say so rather than hope.

`.read_only = true` is worth writing on a report or an export: Postgres can
skip work, and a write nobody meant to make is refused by the server instead
of quietly happening.

### Holding the rows you read

The read-modify-write every service ends up writing is a race unless the read
holds what it matched:

<!-- compiles: body -->
```zig
var tx = try db.begin(c, .{});
defer tx.deinit();

const held = try tx.select(Item, c, .{ .where = .{ .id = id }, .lock = .update });
if (held[0].qty == 0) return nilo.fail.conflict("out of stock", .{});
_ = try tx.update(Item, c, .{ .set = .{ .qty = held[0].qty - 1 }, .where = .{ .id = id } });

try tx.commit();
```

```sql
SELECT "id", "sku", "qty" FROM "items" WHERE "id" = $1 FOR UPDATE
```

Four locks, and they are four jobs:

| | |
|---|---|
| `.update` | hold the rows, and wait for anyone already holding them |
| `.update_nowait` | hold them, or fail at once with `error.Locked` |
| `.update_skip_locked` | hold whatever nobody else has, and leave the rest out |
| `.share` | hold against a writer; other readers may hold them too |

`.update_skip_locked` is how a work queue is written. Several workers run the
same statement and no two of them ever get the same row:

<!-- compiles: body -->
```zig
const batch = try tx.select(Job, c, .{
    .where = .{ .state = .pending },
    .order = .{ .id = .asc },
    .limit = 10,
    .lock = .update_skip_locked,
});
```

`find` takes a key rather than options, so it has no `.lock`; a locked read of
one row is `tx.one(Row, c, .{ .where = .{ .id = id }, .lock = .update })`.

**Outside a transaction a `.lock` will not compile**, and the reason is that
the wrong version works. Postgres wraps a lone statement in a transaction of
its own and ends it immediately, so the lock is taken and dropped before you
read the first row — the SQL is fine, the promise is gone, and the race you
wrote it to stop happens anyway under load:

```
error: nilo: `db.select` on Item was given a `.lock`, and there is no
       transaction to hold it.
```

### Undoing one statement without losing the transaction

A statement that fails inside a transaction aborts **all** of it: everything
after it answers `25P02` until somebody rolls the whole thing back. A
savepoint is the way to try something and carry on.

<!-- compiles: body -->
```zig
var tx = try db.begin(c, .{});
defer tx.deinit();

for (tags) |tag| {
    var sp = try tx.savepoint();
    defer sp.deinit();                       // undoes it, unless released

    if (tx.insert(Tag, c, .{ .name = tag })) |_| {
        try sp.release();                    // keep it
    } else |err| switch (err) {
        error.AlreadyExists => sp.rollback(), // that tag was there; next one
        else => return err,
    }
}

try tx.commit();
```

`deinit` undoes, `release` keeps, `rollback` undoes now — the same trio a `Tx`
has, one level in.

**This is what a nested transaction is.** Postgres has no nested `BEGIN`, and
libraries that offer one are writing savepoints underneath; nilo writes them
where you can see them, because the two do not behave the same way. An inner
"commit" is not durable — it only means the outer transaction may still commit
it.

One rule comes from Postgres rather than from nilo: undoing or dropping a
savepoint destroys every savepoint taken after it. A `defer sp.deinit()` on
one of those sends nothing rather than asking the server to release a mark it
no longer has, so nesting them is safe to write.

## Streaming a result set too big to hold

<!-- compiles -->
```zig
fn exportUsers(db: *sql.Db, c: *nilo.Ctx) !void {
    var s = try c.stream(200, "text/csv");

    var rows = try db.stream(User, c, .{});
    defer rows.close();

    while (try rows.next()) |u| try s.print("{d},{s}\n", .{ u.id, u.email });
    try s.finish();
}
```

A million rows runs flat. Postgres sends them all without being asked, but
they are read off the socket as they arrive, so memory stays bounded by the
read buffer and TCP carries the rest. No cursor needed.

The rows come back as `sql.Borrowed(User)`, which is `User` with every `Str`
replaced by `[]const u8`. That is deliberate and it is the type telling you
the truth: the text points into the buffer the rows arrive in and is invalid
after the next `next()`. A `Str` means *text that lives as long as the
request*, with no asterisk, so text that does not is not called one. Copy it
if you need to keep it.

`defer rows.close()` is required. A result set walked away from half-read
costs a connection — and unlike a transaction, which is rolled back when the
request ends, nothing else will ever close this one. Forgetting it is caught
in Debug by the same counter that watches transactions.

Two kinds of column cannot be streamed, and each is a compile error rather
than a footnote: a `sql.Json(T)`, and an **array**. The rule behind both is one
sentence — **a streamed row holds only what the read buffer already holds.**
A borrowed row allocates nothing, which is what makes a million of them run
flat; parsing a document costs one allocation per row, and so does building a
slice out of a run of length-prefixed elements. Read either with `select`, or
leave the column out of the Row being streamed — a Json column read as
`[]const u8` streams as bytes you can parse where you need them.

## Past one table

Joins, aggregates, subqueries, `HAVING`, window functions, CTEs — none of
them. The line is one sentence, **one table, conditions that filter rows**,
and past it the answer is `raw`:

<!-- compiles: body -->
```zig
const Tally = struct {
    // A view. `raw` never reads the name, but a Row names a relation.
    pub const nilo_table = .{ .name = "country_tally" };

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
rule. It gives up the compile-time column check and nothing else; the
`SELECT` list has to line up with the struct's fields by position.

It is still a **Row**, so it still carries a `nilo_table` — `raw` never reads
the name, because it did not write the statement, but the type is the same one
every other call takes and there is no second kind of struct to learn. A join
that answers with a shape no table has is what a view is for.

### A statement that answers with nothing

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
builder, and joins and aggregates are where databases disagree most. A
boundary you can state in a sentence is worth more than one further out,
because you can predict what it does without opening this page.

### Set operations are conditions, not a second idea

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

([ADR 0058](../adr/0058-a-set-operation-over-one-table-is-a-condition.md).)

### Several statements at once

There is no pipelining, and the reason is measured rather than assumed: **a
round trip to Postgres is 24 µs and the query inside it is about 2**, so
latency is the cost and concurrency is what hides it. A server here serves
**215,000 requests a second with a real query in every one**, because a
waiting fiber frees its thread
([ADR 0059](../adr/0059-a-round-trip-is-not-the-cost-worth-chasing.md)).

Where several statements really do have to land together, SQL already does it
in one round trip and `db.raw` reaches it:

<!-- compiles: body -->
```zig
const Revoked = struct {
    pub const nilo_table = .{ .name = "audit", .key = .id };

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

## When a Row and its table disagree

<!-- compiles: body -->
```zig
db.checking(&.{ User, Order });
```

Each Row is compared against the table it names, once, while the server
starts. A column that is missing, or is `text` where the struct says `i32`,
stops startup with a line naming it — instead of becoming a 500 at three in
the morning on whichever request reached it first.

A table that is not there at all is **one** line rather than one per column,
because the mistake is one mistake:

```
nilo_sql: nilo: User reads table "users", and the database has no table by
that name
```

which is usually a migration that has not run.

Set `.schema_mismatch_is_fatal = false` to log and carry on.

### The arena is cheaper than the stack

Worth knowing before you write a handler that needs a scratch buffer, because
it is the opposite of the usual Zig advice:

```zig
fn report(db: *sql.Db, c: *nilo.Ctx) ![]const u8 {
    var buf: [64 * 1024]u8 = undefined;               // ✗ per connection
    const buf = try c.arena().alloc(u8, 64 * 1024);   // ✓ per request
```

A connection waiting for its next request is a **suspended fiber**, and a
suspended fiber holds its stack at the deepest point it ever reached. So a
64 KiB stack buffer is 64 KiB held for as long as that connection stays open —
measured one byte per byte, from 8 KiB to 128 KiB
([ADR 0063](../adr/0063-a-handlers-stack-is-per-connection.md)). The arena is
reset after every request.

It applies to the database path too, and that is where the number came from: a
route that reads one row and answers JSON holds **17,022 bytes** per idle
connection against **8,749** for one that returns a constant. Most of the
difference is how deep the driver's protocol code goes, and none of it is
something the query did.

### A second database

The Service registry is keyed by type, so `*sql.Db` is *the* database and a
second one had nowhere to live. `sql.Named` gives it a type of its own:

<!-- compiles -->
```zig
const Replica = sql.Named("replica");

fn listing(rdb: *Replica, c: *nilo.Ctx) ![]Product {     // may be stale
    return rdb.select(Product, c, .{ .order = .{ .name = .asc } });
}

fn buy(db: *sql.Db, c: *nilo.Ctx) !Order {               // must not be
    return db.insert(Order, c, .{ .user_id = 1, .total = 4200 });
}
```

Two names are two types and two types are two services, so both are
`app.provide`d and both are checked at `listen()` like any other. **Which
pool a statement takes is in the argument list**, which is where you can see
it without leaving the line.

Nothing routes anything, and that is deliberate. A reader that sent writes to
the primary and reads to a replica would need health checking, lag awareness
and read-after-write safety — three background tasks this module does not
have, and the last one fails *silently*
([ADR 0060](../adr/0060-a-second-database-is-a-second-type.md)). Writing
`*Replica` in a signature is you saying "stale is fine here", once, on
purpose.

It is not only for replicas: a reporting warehouse, a second tenant, a
database somebody else owns. `sql.Named("")` is a compile error, because the
name is the whole mechanism.

There is no query cache and there will not be one. The speed case is the
strong half — a round trip is 24 µs and the query inside it is 2 — but
invalidation cannot be right from here, because this module sees only the
writes that go through it. Hold the value in a Service of your own, where the
rule for when it goes stale is a rule you know.

### Statements are prepared, and you did nothing to ask for it

Every statement this module sends is settled while compiling, so there is a
fixed set of them and each one is kept prepared on the connection it went
down. The second time a connection sends it, Postgres skips Parse and
Describe.

It is worth about **12 µs a query** — 30% of a key lookup, 14% of a page with
a sort and a range
([ADR 0057](../adr/0057-a-statement-that-is-a-constant-can-be-prepared-once.md)).
A fixed saving, so the cheap queries a service runs most of are the ones it
helps most. Nothing in your code changes.

`db.raw` is in it too. Its text is comptime, so its name is derived the same
way ([ADR 0148](../adr/0148-a-raw-statement-is-counted-while-compiling.md)).

**Turn it off behind pgbouncer in transaction mode.**

<!-- compiles: body -->
```zig
var db = sql.Db.init(gpa, url, .{ .prepared = false });
```

A transaction-mode pooler hands out a different server connection per
transaction, so a statement prepared on one is missing on the next. The
failure is loud — Postgres says the prepared statement does not exist — which
is why the default is the fast one rather than the safe one.

### Seeing the statements a request sent

One line per request tells you a page is slow. What was slow *in* it is the
statements, and `db.watching` is how they are shown:

<!-- compiles: body -->
```zig
db.watching(sql.logging);       // one debug line per statement
```

Set it before `listen()`. `sql.logging` writes the duration, the row count and
the text at debug level; anything narrower is a function of your own:

<!-- compiles -->
```zig
fn slowOnes(sent: sql.Sent) void {
    if (sent.micros < 50_000) return;
    std.log.warn("slow query: {d}us, {s}", .{ sent.micros, sent.sql });
}
```

`db.watching(slowOnes)`, and nothing else changes. A `sql.Sent` carries the
statement, the name it is kept prepared under, how long the database took, how
many rows moved, and whether it failed. **Not the
values it bound** — those are the interesting half and they are also somebody's
password, so putting them in a log is a decision rather than a default
([ADR 0137](../adr/0137-a-statement-can-be-watched.md)).

A statement that failed carries one thing more: `sent.problem`, which is what
the database said about refusing it.

<!-- compiles -->
```zig
fn whyItFailed(sent: sql.Sent) void {
    const said = sent.problem orelse return;
    std.log.warn("{s} [{s}] on {s}: {s}", .{
        said.message, said.code, said.constraint, sent.sql,
    });
}
```

`message` always says something. When the driver refused the statement before
it left the process — a value it will not bind — there is no server message, so
the Zig error's own name goes there instead. `code` is the SQLSTATE, `23505`
for a duplicate key; `severity`, `detail`, `hint` and `constraint` are the rest
of what Postgres knew. Fields a database does not answer are empty rather than
null, because SQLite has no SQLSTATE and does not invent one
([ADR 0146](../adr/0146-a-statement-that-failed-says-what-the-database-said.md)).

It lives in the request's arena, so keeping one past the request means copying
it. **`detail` is usually the values that collided**, which is worth knowing
before you log it. None of it ever reaches the client.

A `Db` nobody is watching pays one null test per statement, and a watched one
pays two clock reads at 15ns each.

### Views, and the one thing a check cannot know

A Row can name a **view** or a **materialized view** instead of a table, and
everything works the same way — reading it, checking it, `db.raw` past it.

One half of the check is skipped there, and it has to be: Postgres does not
track `NOT NULL` through a view, so every column of one reads as nullable
whatever its source column was. Checking that would flag every non-optional
field of a Row over a view, so the column's **type** is compared and its
nullability is left alone
([ADR 0056](../adr/0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md)).

### Columns the database fills in

An identity key, a sequence default and a generated column all work with
nothing said about them, because an insert names a **subset** of the Row's
columns and `RETURNING` is not optional:

<!-- compiles: body -->
```zig
const Auto = struct {
    pub const nilo_table = .{ .name = "auto", .key = .id };

    id: i64,               // GENERATED ALWAYS AS IDENTITY
    label: nilo.Str,
    slug: ?nilo.Str,       // GENERATED ALWAYS AS (label || '-x') STORED
};

const made = try db.insert(Auto, c, .{ .label = "alpha" });
// made.id is the database's, made.slug is "alpha-x"
```

A batch is the same: the arrays hold only the columns that were written. Note
that a generated column carries no `NOT NULL` unless one was written, so the
Row reads it as an optional.

A Row can say three more things about its table, and they are the subject of
[the next section](#making-the-tables). Everything past those three — a check
constraint, a partial index, a trigger — is written where you write the rest of
your DDL. The half that reaches a handler is already done either way: a unique
violation is `error.AlreadyExists` and a 409.

## Making the tables

Three words in the marker, and no more:

<!-- compiles -->
```zig
const Org = struct {
    pub const nilo_table = .{ .name = "orgs", .key = .id };

    id: i64,
    name: nilo.Str,
};

const Member = struct {
    pub const nilo_table = .{
        .name = "members",
        .key = .id,
        .unique = .{.{ .columns = .{.email}, .ignoring_case = true }},
        .index = .{ .created_at, .{ .org_id, .created_at } },
        .references = .{ .org_id = .{ Org, .id, .cascade } },
    };

    id: i64,
    org_id: i64,
    email: nilo.Str,
    created_at: sql.Timestamp,
};
```

`.unique` and `.index` take one column (`.email`), several as one constraint
(`.{ .org_id, .created_at }`), or the named form when there is something to say
about it. `.ignoring_case` is the one modifier, and it is `lower("email")` on
Postgres and `COLLATE NOCASE` on SQLite — the case where two people sign up as
`Wati@` and `wati@` and the plain unique takes both.

`.references` is keyed by the column doing the pointing and it names the **Row**
rather than a table, so renaming the table moves the key with it. A third entry
says what happens on delete: `.cascade`, `.restrict` or `.set_null`. The two
sides have to hold the same type, and a `.set_null` on a column the Row cannot
hold a null in is a compile error — both are things the database would find at
the first insert, in a message about a cast.

You do not say whether the key is generated. An integer key is
`GENERATED BY DEFAULT AS IDENTITY` on Postgres and
`INTEGER PRIMARY KEY AUTOINCREMENT` on SQLite; anything else — a `sql.Uuid`, a
slug — is a key your insert fills. That is a rule rather than a word, because
there is no case where you want the other one.

### Creating them

<!-- compiles: body -->
```zig
try sql.migrate.createMissing(&db, &run, &.{User});
```

One `CREATE TABLE IF NOT EXISTS` per Row plus its indexes, all in one
transaction. **The order comes from the references, not from your list**:
foreign keys are written inline, which is the only shape SQLite has, so `orgs`
is created before `members` whichever way round you wrote them. Two tables
pointing at each other is a compile error naming both, with the way out in it.

Run it again and nothing happens, which is what a boot needs. This is for a
test, a fixture, or a single-file SQLite application — it creates what is
missing and never alters what is there.

### Changing them

The other half is a diff, and **it needs no database on either side**:

<!-- compiles: body -->
```zig
const before = sql.snapshot.empty(sql.Db.Dialect);   // or snapshot.zon, read back
const desired = comptime sql.migrate.tablesOf(sql.Db.Dialect, &.{User});

const change = try sql.migrate.plan(gpa, sql.Db.Dialect, desired, before);
```

`desired` is your types. `before` is `migrations/snapshot.zon`, a file you
commit, which is what the last diff believed the schema was. Two files, so this
runs on a plane — and two branches that both generate conflict in **git**,
which is a conflict worth having, rather than at deploy.

`change.steps` is what to run, each with its `sql` and a line of `why`.
`change.problems` is what the diff will not write, and **all of them come back
rather than the first**: a type change on SQLite, which has no `ALTER COLUMN`,
and any foreign-key change on a table that already exists, because the
one-statement form takes an `ACCESS EXCLUSIVE` lock and scans the table. The
problem spells out the `ADD CONSTRAINT … NOT VALID` then `VALIDATE CONSTRAINT`
pair to write instead.

A renamed column is written in the type, not asked at a prompt:

<!-- compiles -->
```zig
const Renamed = struct {
    pub const nilo_table = .{
        .name = "members",
        .key = .id,
        .was = .{ .email = "handle" },
    };

    id: i64,
    email: nilo.Str,
};
```

Every other tool guesses that a dropped `handle` and a new `email` are the same
column, then asks you at a prompt. The answer is in your head; putting it in the
type means the same code produces the same migration for you, for CI and for the
next person.

### Applying them

<!-- compiles: body -->
```zig
const chain = try sql.migrate.chainOf(run.arena(), &.{});

try sql.migrate.ensureLedger(&db, &run);
const ran = try sql.migrate.applyPending(&db, &run, chain);
```

`nilo_migrations` is an ordinary Row. One version is one transaction: take the
advisory lock, check whether this version is already there, run every step,
write the row, commit. It is skipped when it was already applied, which is what
nine of ten replicas booting together get — **the lock is not decoration**, and
it is the part a hand-written runner usually leaves out.

Each version's hash is taken over its own steps chained onto the one before it,
so editing a migration that has already run moves that version and every version
after it. `sql.migrate.drift` is what asks the database whether anybody has.

The hash is not a field on the version. `chainOf` works the whole list out in
one pass, because a hash somebody can type in is a hash somebody can type in
wrong, and a wrong one makes the drift check look like it is working.

A version is a *list* of steps, and one of them can be SQL you wrote. That is
the shape expand and contract needs: add the column, backfill it, tighten it to
`NOT NULL`, all in one version and one transaction. An `up`/`down` pair has
nowhere to put the middle one.

There is no `down`. A migration that has run against production data cannot be
undone by a statement written before anybody knew what the data was: dropping
the column you just added does not bring back what was in it. Forward-only, and
`reset` for a laptop.

### Refusing to serve a database that is behind

<!-- compiles: body -->
```zig
try sql.migrate.expect(&db, &run, 7);
```

One query, before `listen()`. This catches one incident shape and it is a common
one: the code went out before the migration did, and every request touching the
new column answers 500 until somebody notices.

A database *ahead* of the binary is allowed and only logged — that is the
ordinary middle of a two-stage deploy. `sql.migrate.standing` is the same
question as a value if you would rather decide yourself.

### Your own `db` command

Everything above is callable, but nobody wants to call it. `sql.cli` is the
commands, so your project's migration tool is one small file:

```zig
const std = @import("std");
const sql = @import("nilo_sql");
const manifest = @import("migrations/manifest.zig");

const Db = sql.Sqlite(.{ .threading = .in_fiber });
const Tool = sql.cli.Tool(Db, &.{ User, Org });

pub fn main(init: std.process.Init) !u8 {
    var buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const out = &fw.interface;
    defer out.flush() catch {};

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const req = sql.cli.parse(argv[1..]) catch |err| return sql.cli.explain(out, err);

    var db = Db.init(init.gpa, "app.db", .{ .size = 1 });
    defer db.deinit();
    try db.nilo_start(init.io, .off);

    return Tool.run(init.gpa, init.io, out, req, &db, manifest.versions);
}
```

nilo owns the parsing, the dispatch and every sentence that comes back. You own
the allocator, the connection string and the `Db` type, because those are the
three things nilo cannot guess.

Add it to your `build.zig` as an executable and you have five commands:

```console
$ db check                       # do the Rows and the migrations agree? Exit 1 if not
$ db generate --name add_nickname
$ db status                      # what this database has, and what is waiting
$ db migrate                     # apply it
$ db verify                      # has an applied version been edited since?
```

`generate` and `check` never open the database. They diff your Rows against
`migrations/snapshot.zon`, which is why they run on a laptop with nothing
installed and in CI with no service container.

**The exit code is the whole API for CI.** `0` did what was asked. `1` you have
something to do. `2` the command line was wrong. `db check` in a pipeline needs
no output parsing at all.

Removing a field is the one thing `generate` will not do quietly:

```console
$ db generate --name drop_nickname
Nothing written. Some of this loses data that nothing brings back:

  drop users.nickname, which no field reads
    ALTER TABLE "users" DROP COLUMN "nickname"

The rest of the version is fine. Run it again with `--drop` when you have read
the above, and the generated file in migrations/ will say that you did.
```

The generated file is Zig you can read, and it is exactly what runs: those
steps, in that order, in one transaction. Add a `.kind = .data` step by hand
where the backfill goes, and `generate` will never take it away again.

**One file to write before the first run.** The tool imports
`migrations/manifest.zig` and `generate` is what writes it, so it needs to exist
before the first build. Create it with `head` at 0 and an empty list — the
reference has the seven lines — and from then on the tool owns it.

[ADR 0153](../adr/0153-a-migration-is-a-diff-against-a-snapshot.md) is the
design, including why a version is one `.zig` file and not a `.sql` one.

## Errors

The module raises nine, and they read:

| | |
|---|---|
| `error.AlreadyExists` | a unique violation — **409** by default |
| `error.ForeignKeyViolated` | a row this statement names is not there, or a row it removes is still named by another. No default |
| `error.NotNullViolated` | a `NOT NULL` column was sent a null — 500 |
| `error.CheckViolated` | a `CHECK` said no |
| `error.ConstraintViolated` | whatever is left — an exclusion constraint, a `RESTRICT` |
| `error.Locked` | a `.lock = .update_nowait` found a row somebody else holds. No default |
| `error.Disconnected` | the database went away, or was never there |
| `error.TimedOut` | a statement ran past the `tx.deadline` you set |
| `error.QueryFailed` | anything else. The server's text is logged, never sent |

Only the first has a default answer, and that is on purpose. A duplicate
email on a signup is a 409; the same code inside a background import is not
an HTTP answer at all; on a table used to win a race it is the expected
outcome. The module does not know which request it is inside, so it hands you
an error that reads and lets you decide:

<!-- compiles: body -->
```zig
const made = db.insert(User, c, .{ .email = email }) catch |err| switch (err) {
    error.AlreadyExists => return nilo.fail.conflict("{s} is already taken", .{email}),
    else => return err,
};
```

**`ForeignKeyViolated` has no default for the same reason, and it is the one
worth knowing about.** It is the only constraint failure that is routinely a
race rather than a bug: a delete guarded by a count is right up until somebody
adds a child row between the two statements.

<!-- compiles: body -->
```zig
_ = db.delete(User, c, .{ .where = .{ .id = id } }) catch |err| switch (err) {
    error.ForeignKeyViolated => return nilo.fail.conflict(
        "{s} placed an order a moment ago and can no longer be deleted. " ++
            "Deactivate them instead.",
        .{name},
    ),
    else => return err,
};
```

**And when the name is not enough, `sql.problem(c)` is what the database
actually said** ([ADR 0184](../adr/0184-a-failure-belongs-to-the-call-that-caused-it.md)).
A table with two unique indexes on it raises one error for both; the
`constraint` field is what says which:

```zig
const said = sql.problem(c) orelse return err;
if (std.mem.eql(u8, said.constraint, "users_email_key")) {
    return nilo.fail.conflict("that email is already listed", .{});
}
```

It answers for the last statement **this fiber** ran, and null when it worked.
Read it in the `catch`: it lives as long as the request does, and the next
statement replaces it. `db.watching` is the other end of the same information
and is for logging every statement rather than branching on one.

## It is not an ORM

The word promises object-relational mapping, Zig has no objects, and every
mechanism that earns the name is refused: no change tracking, which costs a
copy of every row; no lazy relations, which are queries nobody wrote; no
identity map, which is a lifetime problem in a language with no garbage
collector.

A name is a promise, and `orm` would promise a `.save()` that is never going
to exist.

Migrations *are* here, and they are the one thing above that is not a query:
[Making the tables](#making-the-tables). They are not an ORM feature either —
nothing tracks a change or writes a statement you did not ask for.

---

The reasoning behind all of it is in
[ADR 0039](../adr/0039-the-shape-of-a-query-is-settled-while-compiling.md),
and how it was wired to a real driver is in
[ADR 0040](../adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md).
The whole surface on one page is in [the reference](../reference.md#nilo_sql).
