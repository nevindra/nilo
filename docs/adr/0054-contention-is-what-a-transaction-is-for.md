# Contention is what a transaction is for, so it takes more than begin and commit

A `Tx` was one connection and five verbs. That is enough for *all of this or
none of it*, which is the half of a transaction a single-writer program needs,
and it is not enough to write anything that contends. Three things were
missing, and they are missing together rather than one at a time:

- **A read that holds what it read.** `SELECT … FOR UPDATE` — without it, the
  read-modify-write every service writes is a race, and it is a race that
  passes every test on a laptop.
- **A level to see the rest of the world at.** Read committed is the default,
  and a transaction that reads a row twice and decides something from both
  reads needs more than that.
- **A way back out of one statement.** A failed statement inside a transaction
  aborts *all* of it: Postgres answers every statement after it with `25P02`
  until somebody rolls the whole thing back. A handler that wanted to try
  something and carry on had no way to.

The roadmap called these Next 1, alongside the upsert and the batch, and the
sentence there was: *a `Tx` today is one connection and five verbs, which is
not enough to write anything that actually contends.*

## What was decided

**Three additions, and each one is a shape the compiler already checks.**

### The `BEGIN` carries what the transaction is

```zig
var tx = try db.begin(c, .{ .isolation = .serializable, .read_only = true });
defer tx.deinit();
```

```sql
BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY
```

`opts` is comptime, so the whole statement is a constant this module assembled
while compiling and **asking for either costs no round trip at all**. The
alternative — a `SET TRANSACTION` behind the `BEGIN` — is one extra message
per transaction for something Postgres will take as part of the first.

`.read_committed` is a value rather than something spelled by leaving the
option out, because leaving it out means *whatever the server is set to* and
`ALTER ROLE … SET default_transaction_isolation` is a thing a DBA does. A
transaction that has to be read-committed can now say so.

### A read can hold the rows it read

```zig
const held = try tx.select(Item, c, .{
    .where = .{ .id = id },
    .lock = .update,
});
```

Four modes and they are four jobs, not eight spellings: `.update` (hold and
wait), `.update_nowait` (hold, or `error.Locked` at once), `.update_skip_locked`
(hold whatever nobody else has — a work queue), `.share` (hold against a
writer, not against another reader). `FOR NO KEY UPDATE` and `FOR KEY SHARE`
are left out: they exist to reduce contention *between foreign keys*, which is
a tuning answer rather than a shape, and `db.raw` writes one where it has been
measured to matter.

The clause goes last, after `LIMIT` and `OFFSET`, because the rows it holds
are the rows that came back.

### A savepoint is what a nested transaction actually is

```zig
var sp = try tx.savepoint();
defer sp.deinit();                       // undoes it, unless released

if (tx.insert(Tag, c, .{ .name = name })) |_| {
    try sp.release();
} else |err| switch (err) {
    error.AlreadyExists => sp.rollback(),   // it was already there; carry on
    else => return err,
}
```

The trio mirrors `Tx`'s one level in — `deinit` undoes unless something kept
it, `release` keeps, `rollback` undoes now — so a reader who knows how a
transaction ends knows how a savepoint does.

**Postgres has no nested `BEGIN`, and every library that offers one is writing
savepoints underneath.** nilo writes them where they can be seen, because the
two do not behave the same way: an inner "commit" is not durable, it only means
the outer transaction may still commit it. A name that promised otherwise would
be the one thing this module refuses to do (`sql.zig`, *it is not an ORM*).

## Why `db.begin(c, .{})` rather than a second name

This breaks every existing call. The alternative was `beginWith`, and it was
rejected for being a second name for one call: every other call in this module
takes a Row, a Scope and a struct written where it is used, and `begin` was
already the odd one out. One `.{}` at a call site is a smaller price than a
name a reader has to learn is the same thing.

## Why a lock outside a transaction is a Refusal

```
nilo: `db.select` on User was given a `.lock`, and there is no transaction to
hold it.
```

**What makes this worth refusing is that the wrong version works.** Postgres
wraps a lone statement in a transaction of its own and ends it immediately, so
`SELECT … FOR UPDATE` on a pooled connection with no `Tx` around it runs,
answers, and drops the lock before the handler reads a row. Nothing fails,
nothing is logged, and the read-modify-write it was written to protect races
anyway — under load, in production, after passing every test.

The statement is legal SQL. It is the promise that is missing, and a missing
promise with correct syntax is exactly the class of mistake a compiler can hold
([ADR 0027](./0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).
`db.stream` is refused for the same reason and gets a different sentence: there
is no `tx.stream` to move it to, because a result set held open keeps its
connection busy and nothing else in the transaction could run until it closed.

## Two things the driver had to be taught

**`55P03` is `error.Locked`.** A `NOWAIT` that found the row held is the answer
the statement was written to get, not a failure — the same argument that gave
`TimedOut` a name in [ADR 0047](./0047-a-deadline-needs-a-connection-you-hold.md).
A handler that cannot tell it from a broken statement has half a feature. No
default status: a held row is a 409 for one endpoint, a 503 for another, and a
retry with `.update_skip_locked` for a third.

**A savepoint undo has to `revive` first.** This is the same pg.zig behaviour
ADR 0047 documented, met from the other side: Postgres answers a failed
statement inside a transaction with ReadyForQuery `E`, pg.zig maps that to
`.fail`, and `canQuery` then refuses everything — including the one command
that recovers the session. Rolling back to a savepoint is *the* thing a caller
does because the last statement failed, so it is the path that finds the
connection in that state. Without the `revive`, the feature does not work at
all on the only path it exists for.

## A stale savepoint handle does nothing rather than something wrong

Undoing or dropping a savepoint destroys every savepoint taken after it — that
is Postgres's rule, not a choice made here. So:

```zig
var outer = try tx.savepoint();
defer outer.deinit();
var inner = try tx.savepoint();
defer inner.deinit();
outer.rollback();                // `inner` is gone from the server now
```

`inner`'s `defer` must send nothing. A `ROLLBACK TO SAVEPOINT` for a mark the
server no longer has is an error, inside a transaction, which aborts the whole
thing — a `defer` written correctly would have destroyed the transaction it was
protecting. `Tx.sp_live` is the highest number this module will still send SQL
for, and a handle above it is stale rather than wrong.

Numbers count up and are never reused, so a savepoint taken inside a loop is a
fresh mark each time round rather than one that shadows the last.

**There is no leak trap on a savepoint, unlike a transaction and a stream.**
Both of those count connections that never go back to the pool; an abandoned
savepoint holds nothing — the `Tx` owns the connection and ends it either way.
What abandoning one costs is that the work it marked is kept rather than
undone, which is a bug in the handler's logic rather than a resource nobody can
reclaim, and a Debug-only panic is the wrong shape for that.

## Where the seam put each piece

A Dialect writes SQL; a Wire speaks a protocol. The three additions landed on
different sides of that, and the line is worth stating because it was not
obvious:

- **`FOR UPDATE` is the Dialect's**, because it is part of a `SELECT`. It joins
  the contract as `lock(mode) ?[]const u8`, and a Dialect with no row lock
  answers null and gets a Refusal naming it — the same shape as `noListForm`.
  SQLite is the test that is coming, and it has no row lock at all.
- **The isolation level and the savepoint are the Wire's**, because they are
  properties of the transaction rather than of any statement — the same side
  `BEGIN`, `COMMIT`, `ROLLBACK` and `tx.deadline` were already on. Both are
  comptime at every call, so a Wire that cannot express one refuses it while
  compiling rather than at the first request.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes:

- **Allocations per request.** None. A lock is text in a statement that was
  already a constant; a savepoint's statement is `bufPrint`ed into a stack
  buffer, the way `tx.deadline`'s is.
- **Memory per idle connection.** Nothing. `Tx` grew two `u32`s, and a `Tx`
  exists only while a handler holds one.
- **Throughput and p99.** The `BEGIN` options are free — one message either
  way. A savepoint is one round trip and it is the caller's to spend; the
  alternative on its only path is losing the whole transaction.
- **Binary size.** +0 stripped ReleaseFast on every example, because no example
  imports `nilo_sql` ([ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)).

## Consequences

- `wire.Error` gained a fifth member. It is meant to be short, and the bar it
  had to clear is the one `TimedOut` cleared: the caller asked a question that
  has this answer.
- A write inside a read-only transaction is `QueryFailed` with the server's
  message in the log, not an error of its own. It is a bug in the handler
  rather than an outcome to handle — the exception is a connection that turns
  out to be a read replica, and if read replicas land this is the line to
  revisit.
- `sql/refusals/` needed `nilo_http`, because some mistakes are only reachable
  through a call that takes a Scope. Faking one would have been testing the
  fake.
- `SELECT … FOR UPDATE`, savepoints and an isolation level came off Next 1
  together. What is left of that item is nothing.
