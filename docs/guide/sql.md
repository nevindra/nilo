# Talking to Postgres

`nilo_sql` is a second module. You import it separately, and a project that
never imports it links none of it — not the driver, not TLS, nothing.

```zig
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");
```

The idea is the same one the HTTP half runs on, pointed at a database: **the
struct you already wrote is the contract, and the compiler is the check.**

## A table is a struct

```zig
const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: nilo.Str,
    age: i32,
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

```zig
const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .key = .id };

    id: i64,
    total: sql.Decimal,        // numeric
};

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

```zig
const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    tags: []const nilo.Str,    // text[]
    scores: ?[]const i32,      // integer[], and the column may be null
};

for (ticket.tags) |tag| { … tag.view() … }
```

`[]const u8` is text and was spoken for long before arrays were, so a list of
text is `[]const Str` or `[]const []const u8` and never `[]const u8`. Writing
one is the shape you would write anyway:

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

An array is judged **exactly** at startup: an `int4[]` column reads into a
`[]const i32`, and not into a `[]const i64` the way a scalar `int4` reads into
an `i64`. And a Row that reads an array cannot be `db.stream`ed, for the same
reason a `Json` column cannot — see [Streaming](#streaming-a-result-set-too-big-to-hold).

### A column type of your own

The types above are the ones this module chose to know about, and Postgres has
hundreds more — `interval`, `inet`, `money`, `tsvector`, everything an
extension installs. The list is not closed:

```zig
const Money = sql.AsText("money");

const Sale = struct {
    pub const nilo_table = .{ .name = "sales", .key = .id };

    id: i64,
    amount: Money,           // money
};

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

## Wiring it up

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

## Reading

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

The condition goes through the same walker `select` uses, which is the point:
a page and its total are one condition written once, and a column misspelled
in either is the same compile error.

```zig
const where = .{ .status = "open" };
const total = try db.count(Order, c, .{ .where = where });
const page  = try db.select(Order, c, .{ .where = where, .order = .{ .id = .asc }, .limit = 20 });
```

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

```zig
var run = nilo.Run.init(gpa);
defer run.deinit();

const adults = try db.select(User, &run, .{ .where = .{ .age = .{ .gt = 18 } } });
```

Same query, same rows, no server in the process. That is the whole of what a
migration script or a nightly job needs from this module.

## Writing

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

```zig
fn rename(db: *sql.Db, c: *nilo.Ctx, id: i64, body: Rename) !?User {
    const changed = try db.updateReturning(User, c, .{
        .set = .{ .name = body.name },
        .where = .{ .id = id },
    });
    return if (changed.len == 0) null else changed[0];
}
```

`deleteReturning` is the other half, for a delete that has to report or log
what it took. Both answer with a slice, because nothing in a condition says
how many rows it matches — the single-row shape is the length check above.
The clause they add is the `SELECT` list this module already writes, so
neither costs a statement the compiler did not settle.

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

```zig
var tx = try db.begin(c, .{});
defer tx.deinit();

for (tags) |name| {
    var sp = try tx.savepoint();
    defer sp.deinit();                       // undoes it, unless released

    if (tx.insert(Tag, c, .{ .name = name })) |_| {
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

```zig
const tally = try db.raw(Report, c,
    "SELECT u.country, count(*)::bigint AS n FROM users u " ++
    "JOIN orders o ON o.user_id = u.id GROUP BY u.country",
    .{},
);
```

`raw` still fills your struct, still uses the arena, still follows the `Str`
rule. It gives up the compile-time column check and nothing else; the
`SELECT` list has to line up with the struct's fields by position.

The line is drawn there because a builder's dialect surface grows with the
builder, and joins and aggregates are where databases disagree most. A
boundary you can state in a sentence is worth more than one further out,
because you can predict what it does without opening this page.

## When a Row and its table disagree

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

`db.raw` is the one exception, and it has to be: its text arrives at run time,
so there is no bound on how many names there would be.

**Turn it off behind pgbouncer in transaction mode.**

```zig
var db = sql.Db.init(gpa, url, .{ .prepared = false });
```

A transaction-mode pooler hands out a different server connection per
transaction, so a statement prepared on one is missing on the next. The
failure is loud — Postgres says the prepared statement does not exist — which
is why the default is the fast one rather than the safe one.

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

**Indexes, unique constraints, foreign keys and check constraints are not
here, and that is a decision.** A Row names its columns and its key and
nothing else about the table, so nothing here can check or generate one — and
a Row that could say it would be a migration file with Zig syntax. Write them
where you write the rest of your DDL. The half that reaches a handler is
already done: a unique violation is `error.AlreadyExists` and a 409.

## Errors

The module raises six, and they read:

| | |
|---|---|
| `error.AlreadyExists` | a unique violation — **409** by default |
| `error.Locked` | a `.lock = .update_nowait` found a row somebody else holds. No default |
| `error.ConstraintViolated` | foreign key, check or not-null — 500 |
| `error.Disconnected` | the database went away, or was never there |
| `error.TimedOut` | a statement ran past the `tx.deadline` you set |
| `error.QueryFailed` | anything else. The server's text is logged, never sent |

Only the first has a default answer, and that is on purpose. A duplicate
email on a signup is a 409; the same code inside a background import is not
an HTTP answer at all; on a table used to win a race it is the expected
outcome. The module does not know which request it is inside, so it hands you
an error that reads and lets you decide:

```zig
const made = db.insert(User, c, .{ .email = email }) catch |err| switch (err) {
    error.AlreadyExists => return nilo.fail.conflict("{s} is already taken", .{email}),
    else => return err,
};
```

## It is not an ORM

The word promises object-relational mapping, Zig has no objects, and every
mechanism that earns the name is refused: no change tracking, which costs a
copy of every row; no lazy relations, which are queries nobody wrote; no
identity map, which is a lifetime problem in a language with no garbage
collector.

A name is a promise, and `orm` would promise a `.save()` that is never going
to exist.

Migrations are not here and are not implied. Nothing in the design forecloses
them.

---

The reasoning behind all of it is in
[ADR 0039](../adr/0039-the-shape-of-a-query-is-settled-while-compiling.md),
and how it was wired to a real driver is in
[ADR 0040](../adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md).
The whole surface on one page is in [the reference](../reference.md#nilo_sql).
