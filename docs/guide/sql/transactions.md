# Transactions

**A `Tx` holds one connection until it ends, and it rolls back on every path out of the handler unless you commit it.**

**Reference:** [`Tx`](../../reference/sql.md#tx), [locked reads](../../reference/sql.md#lock-holding-the-rows-a-read-matched), [savepoints](../../reference/sql.md#savepoints) · **Design:** [The SQL runtime](../../design/sql-runtime.md)

This page covers deadlines, isolation, row locks and savepoints. The statements you run inside a transaction are the same ones [reading](./reading.md) and [writing](./writing.md) describe.

<!-- compiles: body -->
```zig
var tx = try db.begin(c, .{});
defer tx.deinit();                  // rolls back unless committed

const order = try tx.insert(Order, c, .{ .user_id = user.id, .total = 4200, .status = "new" });
_ = try tx.update(User, c, .{ .set = .{ .orders = .{ .plus = 1 } }, .where = .{ .id = user.id } });

try tx.commit();
```

`.{ .plus = 1 }` becomes `SET "orders" = "orders" + $1`: the database adds one to whatever the row holds when the statement runs. If you write `.orders = user.orders + 1` instead, you send a number this handler read earlier. Two requests that read the same number then both write the same answer, and one order goes uncounted. That is a lost update, and a transaction alone does not stop it. See [Locking the rows you read](#locking-the-rows-you-read).

`tx` has the same calls as [`db`](../../reference/sql.md#db), and all of them go down the one connection it holds.

**The `defer tx.deinit()` is required.** If a connection went back to the pool with a transaction still open, the *next* request would run inside that stranger's transaction. `deinit` rolls back on every path out, including the ones nobody wrote. In Debug, a forgotten `deinit` is caught by a counter checked at `db.deinit()`.

## Giving a statement a deadline

**`tx.deadline` limits how long the statements themselves may run.** `timeout_ms` on the pool only limits how long you wait *for a connection*. It stops counting the moment you get one, so an expensive query runs until somebody notices.

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

Postgres undoes the setting when the transaction ends, however it ends, so the connection goes back to the pool clean.

**Only a transaction can have a deadline.** A deadline is always a separate command, because SQL cannot attach one to a statement in the same message. So it has to go down the same connection as the statement it limits. `db.select` takes whichever connection is free and hands it straight back, so there is nothing to set a deadline on ([ADR 043](../../adr/043-a-deadline-needs-a-connection-you-hold.md)).

**A route's [`nilo.deadline`](../../reference/middleware.md#nilodeadline) bounds every `db.` and `tx.` call made with its `*Ctx`, outside a transaction too**, because nilo keeps that one on its own side instead of sending it to the database. A call that runs out of time is `error.TimedOut`, and one made after the time is up is not sent at all. Postgres is sent no cancel, so the statement keeps running until it finds the socket closed, and a write the deadline cut off may still have committed; `tx.deadline` is what stops a statement inside the database ([reference](../../reference/sql.md#a-routes-deadline)).

For a limit on *every* query, including the ones outside a transaction, set it on the database role instead of in your code:

```sql
ALTER ROLE app SET statement_timeout = '30s';
```

## Isolation level and read-only

<!-- compiles: body -->
```zig
var tx = try db.begin(c, .{ .isolation = .serializable, .read_only = true });
```

**Both options go on the `BEGIN` itself** (`BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY`), so neither costs a round trip.

`.isolation` is `.read_committed`, `.repeatable_read` or `.serializable`. If you leave it out you get whatever the server is set to. That is usually read committed, but not always, because `ALTER ROLE … SET default_transaction_isolation` exists. A transaction that needs read committed should say so.

`.read_only = true` is worth writing on a report or an export. Postgres can skip some work, and an accidental write is rejected by the server instead of quietly happening.

## Retrying a rolled-back transaction

**When the database rolls a transaction back, you get `error.RolledBack`, and the fix is to run the whole transaction again.** Under `.repeatable_read` or `.serializable`, two transactions that touch the same rows cannot both win: Postgres rolls one back with a serialization failure (`40001`). A deadlock (`40P01`) ends the same way at any level. Nothing the transaction did was kept.

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

`RolledBack` can come from any statement, `COMMIT` included, which is why the example catches it in both places. It is the only error where sending the same thing again is the right move. Every other error means something is wrong with the statement, and retrying will not help. When a handler returns `RolledBack`, the client gets a 503, which tells it the same thing: send the request again.

A migration that changes a column's type while a server is running can also cause this. Each connection kept the old plan for its prepared statements ([ADR 051](../../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)), and Postgres now rejects that plan. Outside a transaction, nilo prepares the statement again and the caller never notices. Inside a transaction, the transaction is already aborted, so the answer is `RolledBack`, and the next attempt prepares the statement fresh.

## Locking the rows you read

**A read-modify-write is a race unless the read locks the rows it matched.** Every service ends up writing one:

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

`tx.one` returns `?Item`, so an id that is not there becomes a 404, rather than `held[0]` on an empty slice, which would panic.

When the decision fits in the `WHERE`, one statement does the same job with no lock and no transaction:

<!-- compiles: body -->
```zig
const taken = try db.update(Item, c, .{
    .set = .{ .qty = .{ .minus = 1 } },
    .where = .{ .id = id, .qty = .{ .gt = 0 } },
});
if (taken == 0) return nilo.fail.conflict("out of stock", .{});
```

The row is checked and changed in one statement, so two requests cannot both take the last item. Use the lock when the decision needs more than a condition can express.

### Optimistic locking with a version column

**A form somebody keeps open for ten minutes cannot hold a lock that long.** The edit screen read the row, the user typed, and meanwhile somebody else saved. Holding the row for those ten minutes would keep a connection busy and block every other writer. Instead, the row carries a version number, and the save names the version it read:

<!-- compiles -->
```zig
const Page = struct {
    pub const nilo_table = .{ .name = "pages", .key = .id };

    id: i64,
    body: nilo.Str,
    version: i32,
};

fn savePage(db: *sql.Db, c: *nilo.Ctx, page_id: i64, read_version: i32, body: nilo.Str) !Page {
    return try db.updateReturningOne(Page, c, .{
        .set = .{ .body = body, .version = .{ .plus = 1 } },
        .where = .{ .id = page_id, .version = read_version },
    }) orelse return nilo.fail.conflict("somebody saved this page after you opened it", .{});
}
```

The check and the write are one statement, so two saves of the same version cannot both succeed. The second finds that `version` has already moved, changes nothing, and the handler answers 409 instead of overwriting the first save. The id is in the condition next to the version, so [`updateReturningOne`](../../reference/sql.md#db) still targets exactly one row. A page that was deleted in the meantime also answers 409 here; if the screen needs to tell the two apart, call `db.find` after the miss.

### Lock modes

There are four locks, for four different jobs:

| | |
|---|---|
| `.update` | lock the rows, and wait for anyone already holding them |
| `.update_nowait` | lock them, or fail at once with `error.Locked` |
| `.update_skip_locked` | lock whatever nobody else holds, and leave the rest out |
| `.share` | lock against writers; other readers may lock them too |

`.update_skip_locked` is how you write a work queue. Several workers run the same statement, and no two of them ever get the same row:

<!-- compiles: body -->
```zig
const batch = try tx.select(Job, c, .{
    .where = .{ .state = .pending },
    .order = .{ .id = .asc },
    .limit = 10,
    .lock = .update_skip_locked,
});
```

`find` takes a key rather than options, so it has no `.lock`. A locked read of one row is `tx.one(Row, c, .{ .where = .{ .id = id }, .lock = .update })`.

### A lock needs a transaction

**Outside a transaction, a `.lock` does not compile, because the wrong version would appear to work.** Postgres wraps a single statement in its own transaction and ends it immediately, so the lock is taken and released before you read the first row. The SQL is valid, the lock protects nothing, and the race you wrote it to prevent still happens under load:

```
error: nilo: `db.select` on Item was given a `.lock`, and there is no
       transaction to hold it.
```

## Savepoints

**A failed statement inside a transaction aborts all of it, and a savepoint is how you undo just that one statement.** After a failure, every later statement answers `error.QueryFailed` (Postgres's `25P02`) until the whole transaction is rolled back, and **`tx.commit()` answers `error.QueryFailed` too**: the transaction is rolled back and nothing in it was kept. So catching a statement's error and carrying on is a mistake:

```zig
_ = tx.insert(Tag, c, .{ .name = tag }) catch |err| switch (err) {
    error.AlreadyExists => {},   // the transaction is already aborted here
    else => return err,
};
try tx.commit();                 // error.QueryFailed, and the other inserts are gone
```

On Postgres, a `COMMIT` sent after a failure is answered `ROLLBACK` with no error. nilo rejects the commit instead of reporting a success that did not happen. SQLite would carry on after the failed statement, but nilo holds it to Postgres's rule, so a handler tested against SQLite fails the same way.

When the only failure you expect is a duplicate, [`insertOrIgnore`](../../reference/sql.md#upserts) does it in one statement and nothing fails. A savepoint is for the other failures, the ones no upsert can avoid:

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

`deinit` undoes, `release` keeps, and `rollback` undoes now. They are the same three calls a `Tx` has, one level down.

**A savepoint is what a nested transaction really is.** Postgres has no nested `BEGIN`, and libraries that offer one write savepoints underneath. nilo shows the savepoints, because they do not behave like a transaction: an inner "commit" is not durable, it only means the outer transaction may still commit it.

One rule comes from Postgres, not from nilo: rolling back or releasing a savepoint destroys every savepoint taken after it. A `defer sp.deinit()` on one of those later savepoints then sends nothing, instead of asking the server to release a savepoint it no longer has, so nesting them is safe.
