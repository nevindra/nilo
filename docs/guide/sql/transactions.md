# Transactions

A `Tx` holds a connection until it ends, and it ends however the handler
leaves — committed, rolled back, or abandoned. Deadlines, isolation, row
locks and savepoints are all here; the statements inside one are the ones
[reading](./reading.md) and [writing](./writing.md) describe.

<!-- compiles: body -->
```zig
var tx = try db.begin(c, .{});
defer tx.deinit();                  // rolls back unless committed

const order = try tx.insert(Order, c, .{ .user_id = user.id, .total = 4200, .status = "new" });
_ = try tx.update(User, c, .{ .set = .{ .orders = .{ .plus = 1 } }, .where = .{ .id = user.id } });

try tx.commit();
```

`.{ .plus = 1 }` is `SET "orders" = "orders" + $1`: the database adds one to
whatever the row holds when the statement runs. Writing
`.orders = user.orders + 1` instead sends a number this handler read earlier,
and two requests that read the same number both write the same answer, so
one order goes uncounted. That is a lost update, and a transaction does not
stop it on its own. See [Holding the rows you read](#holding-the-rows-you-read).

`tx` carries the same calls `db` does, all down the one connection it holds.
The `defer` is not decoration: a connection returned to the pool inside an
open transaction is a connection the *next* request runs inside a stranger's
transaction. `deinit` rolls back on every path out, including the ones nobody
wrote.

Forgetting it is caught in Debug by a counter checked at `db.deinit()`.

## Giving a statement a deadline

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
to set one on ([ADR 043](../../adr/043-a-deadline-needs-a-connection-you-hold.md)).

For a floor under *everything*, including the queries that are not in a
transaction, set it beside the database rather than in your code:

```sql
ALTER ROLE app SET statement_timeout = '30s';
```

## Saying what the transaction is, on the `BEGIN`

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

## When the database rolls it back for you

Under `.repeatable_read` or `.serializable`, two transactions that touch the
same rows cannot both win. Postgres rolls one of them back with a
serialization failure (`40001`). A deadlock (`40P01`) ends the same way under
any level. Both come back as **`error.RolledBack`**. Nothing the transaction
did was kept, and running the whole transaction again is the fix:

<!-- compiles -->
```zig
fn takeOne(db: *sql.Db, c: *nilo.Ctx, id: i64) !void {
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        var tx = try db.begin(c, .{ .isolation = .serializable });
        defer tx.deinit();

        const item = try tx.one(Item, c, .{ .where = .{ .id = id } }) orelse
            return nilo.fail.notFound("no item {d}", .{id});
        if (tx.update(Item, c, .{ .set = .{ .qty = item.qty - 1 }, .where = .{ .id = id } })) |_| {
            tx.commit() catch |err| switch (err) {
                error.RolledBack => if (attempt < 3) continue else return err,
                else => return err,
            };
            return;
        } else |err| switch (err) {
            error.RolledBack => if (attempt < 3) continue else return err,
            else => return err,
        }
    }
}
```

It can arrive from any statement, `COMMIT` included, which is why both are
caught. `RolledBack` is the only error a statement returns where sending the
same thing again is the right move. Every other error means something is
wrong with the statement, and retrying it will not help. When a handler
returns `RolledBack`, the client gets a 503, which tells it the same thing:
send the request again.

A migration that changes a column's type while a server is running is the
other way to get here. Each connection kept the old plan for its statements
([ADR 051](../../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)),
and Postgres refuses that plan now. Outside a transaction, nilo prepares the
statement again and the caller never sees it. Inside one, the transaction is
already aborted, so the answer is `RolledBack`, and the next attempt prepares
the statement fresh.

## Holding the rows you read

The read-modify-write every service ends up writing is a race unless the read
holds what it matched:

<!-- compiles: body -->
```zig
var tx = try db.begin(c, .{});
defer tx.deinit();

const held = try tx.one(Item, c, .{ .where = .{ .id = id }, .lock = .update }) orelse
    return nilo.fail.notFound("no item {d}", .{id});
if (held.qty == 0) return nilo.fail.conflict("out of stock", .{});
_ = try tx.update(Item, c, .{ .set = .{ .qty = held.qty - 1 }, .where = .{ .id = id } });

try tx.commit();
```

```sql
SELECT "id", "sku", "qty" FROM "items" WHERE "id" = $1 LIMIT 1 FOR UPDATE
```

`tx.one` answers `?Item`, so an id that is not there is a 404 rather than
`held[0]` on an empty slice, which is a panic.

When the decision fits in the `WHERE`, one statement does the same job with
no lock and no transaction:

<!-- compiles: body -->
```zig
const taken = try db.update(Item, c, .{
    .set = .{ .qty = .{ .minus = 1 } },
    .where = .{ .id = id, .qty = .{ .gt = 0 } },
});
if (taken == 0) return nilo.fail.conflict("out of stock", .{});
```

The row is checked and changed in one statement, so two requests cannot both
take the last one. The lock is for the case where the decision needs more than
a condition can say.

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

## Undoing one statement without losing the transaction

A statement that fails inside a transaction aborts **all** of it. Every
statement after it answers `error.QueryFailed` (Postgres's `25P02`) until
somebody rolls the whole thing back, and **`tx.commit()` answers
`error.QueryFailed` too**: the transaction is rolled back, and nothing in it
was kept. So catching a statement's error and carrying on is a mistake:

```zig
_ = tx.insert(Tag, c, .{ .name = tag }) catch |err| switch (err) {
    error.AlreadyExists => {},   // the transaction is already aborted here
    else => return err,
};
try tx.commit();                 // error.QueryFailed, and the other inserts are gone
```

On Postgres, a `COMMIT` sent after that point is answered `ROLLBACK` with
no error. nilo refuses the commit instead of reporting a success that did
not happen. SQLite would carry on after the failed statement, but nilo holds
it to Postgres's rule, so a handler tested against SQLite fails the same way.

When the only failure you expect is a duplicate, `insertOrIgnore` is one
statement and nothing fails. A savepoint is for the other failures, the ones
no upsert can write around:

<!-- compiles: body -->
```zig
var tx = try db.begin(c, .{});
defer tx.deinit();

for (lines) |line| {
    var sp = try tx.savepoint();
    defer sp.deinit();                       // undoes it, unless released

    if (tx.insert(Order, c, line)) |_| {
        try sp.release();                    // keep it
    } else |err| switch (err) {
        // The user on this line is not there. Skip the line, keep the rest.
        error.ForeignKeyViolated => sp.rollback(),
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
