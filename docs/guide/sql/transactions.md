# Transactions

A `Tx` holds a connection until it ends, and it ends however the handler
leaves — committed, rolled back, or abandoned. Deadlines, isolation, row
locks and savepoints are all here; the statements inside one are the ones
[reading](./reading.md) and [writing](./writing.md) describe.

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
to set one on ([ADR 0047](../../adr/0047-a-deadline-needs-a-connection-you-hold.md)).

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

## Holding the rows you read

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

## Undoing one statement without losing the transaction

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
