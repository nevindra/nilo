# An answer kept for a retry is a row when instances share a database

**Status:** accepted
**Topic:** [idempotency](../design/idempotency.md)
**Extends:** [ADR 155](./155-a-request-answered-once-is-answered-the-same-way-again.md),
whose `Idempotent` asked its store for six declarations and found them on a
`nilo_cache` Space; this is the store the instances share.
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 038](./038-a-module-sits-where-the-loop-puts-it.md),
[ADR 160](./160-a-queue-is-a-table-in-the-database-you-already-have.md),
[ADR 110](./110-an-in-process-cache-and-a-redis-client-are-two-modules.md).

## Context

`Idempotent` answers once per key per process, because the store it was given is a `cache.Space` in memory. A retry the balancer sends to a second instance finds nothing there and runs the handler again, and a rolling deploy is two instances while it lasts. For the case the header exists for, a payment retried after a timeout, that is the double charge arriving through the feature, with nothing logged. ADR 155 said so and left the door open: `Idempotent` names no cache, it asks its store for `getInto`, `putIfAbsentFor`, `put`, `del`, `max_bytes` and `Held`, and a type of the caller's own over a shared store has them.

What was missing was that type, and the question ADR 038 asks of any new work: which module, and what may it import. A program that wants this has a database already (the same argument that made the queue a table, [ADR 160](./160-a-queue-is-a-table-in-the-database-you-already-have.md)), so the store is a row in it. Redis is the other answer and ADR 110 already gave the reason it is a separate module with a client nobody has written here.

## Decision

### `sql.Replays(Db, options)` is a type, and its instance is a service

```zig
const Replays = sql.Replays(Db, .{ .name = "orders", .ttl_s = 86_400, .max_bytes = 16 << 10 });

try sql.migrate.createMissing(&db, &run, .{ .tables = &.{Replays.Row} });
var replays = Replays.open(&db);
try app.provide(&replays);

fn placeOrder(key: nilo.Idempotent(Replays, .{ .by = account }), body: NewOrder, …) !nilo.Status(201, Order)
```

The type is what `Idempotent` is given in place of a `cache.Space`; the handler is otherwise the one it was. The table is the caller's to create, the way `job.Table`'s is: `Replays.Row` goes into `createMissing`, into a migration beside the program's own rows, and into `db.checking(.{ .tables = … })`, and nothing here creates it. It is `(space, slot)` as its key, `value` as `bytea`, and `expires_at` in microseconds, indexed for the sweep. `name` is the `space` column, so two stores share one table the way two Spaces share one Store, and `.table` renames the table for the program that wants two.

**Where it lives: `sql/replays.zig`, in `nilo_sql`.** ADR 038 asks whether it needs the event loop (it borrows it, through the Db it is handed, and holds the destination: a Service), and what it may import (`nilo_core` for the clock, which `sql/` already names; `nilo_http` never, and it does not need to, because `Idempotent` reads its store by name). Three things put it here and not in a module of its own:

- **Whoever uses it has `nilo_sql`.** A store over a `Db` is only useful to a program that has one, and the `Db` is `nilo_sql`'s. A separate Fitting would be a second import for a program that already made the first, and would not run without `nilo_sql` either.
- **It has no variant without a database.** `job/` is a Fitting taking the caller's Db type because the queue has `job.Memory` and runs without `nilo_sql` (ADR 160); an idempotency store with no database is a `cache.Space`, which exists. Taking the Db as a type parameter would have been indirection for a seam nothing crosses. It still takes the Db as a parameter, as `sql.Db`, `sql.Sqlite(…)` and a named one are different types, and that is the only generality it keeps.
- **A module costs more than this is.** A row in `layers`, `shipped_roots` and `.paths`, a program in `bench/release/` that `bench/release.py` refuses to run without, a refusals table and step (there are nine, one a module), a reference page and a guide page, for about two hundred lines that call four methods of a `Db`.

### The contract grew one declaration: `takes_scope`

A `cache.Space` is called as `put(key, value)`. A statement needs the request's Scope to allocate the row it reads into, and can fail the way a database does, so a store that declares `pub const takes_scope = true` is called with the Scope first (`put(scope, key, value)`) and may return an error. `http/idempotent.zig` has four small functions (`claim`, `read`, `keep`, `release`) that call either shape and map every failure but `TooLarge` to one `error.Unavailable`, logged once at `warn` with the driver's name for it, so `typed.zig` handles two errors and not whatever a driver can say. A store that takes a scope has no `Held` (it reads into the buffer `Idempotent` hands it, an arena allocation of `max_bytes` as before, never stack); everything else `checkSpace` asked for it still asks.

**`Cached` refuses a store that takes a scope**, naming the reason: a page is read on every GET, which is a cache's job and not a round trip.

### The claim is atomic in the database

Two instances receiving the same key at once must not both run the handler. `putIfAbsentFor` is two statements, each atomic, the second only when the first found the key taken:

1. `INSERT … ON CONFLICT (space, slot) DO NOTHING`. A free key is inserted and the caller holds it. A key somebody holds, expired or not, answers no row.
2. `UPDATE … SET value, expires_at WHERE space, slot, expires_at <= now`. It runs only after (1) found a row, and takes a row that has run out. Of two instances reaching the same expired row, one updates it, and the other, re-reading the row after the first commits, finds it live and changes nothing.

The primary key is where racing instances meet, in Postgres by its lock and in SQLite by having one writer ([ADR 065](./065-one-writer-is-not-a-setting-it-is-the-database.md)). The loser's re-read of the row is Postgres's `READ COMMITTED`, its default; a role that defaults to `REPEATABLE READ` makes the loser's `UPDATE` fail with a serialization error instead, which is `error.Unavailable` and a 503 (the retry then finds the winner's marker), so it is safe and not quiet. A test claims one key sixteen times at once from two pools and counts one winner, then does it again on an expired row.

**The first design was one statement, `ON CONFLICT DO UPDATE … WHERE <expired>`, and it was measured and dropped.** `DO UPDATE` row-locks the conflicting row before it evaluates the `WHERE`, and a row lock writes WAL, so a retry that found its marker paid a commit to be told no: 1,674 µs against 54 µs for the two-statement form on the same Postgres 18 (`bench/result/sql.md` §27). A retry that finds its marker is the request this table exists for.

### What the other states do

- **In flight.** The marker (kind, status 0, the fingerprint) is the value `putIfAbsentFor` stores, for `marker_ttl_s` (two minutes) and not the store's `ttl_s`, as in ADR 155. The second instance's claim finds it, reads it, sees `in_flight` and answers 409, or a different fingerprint and answers 422. The answer put over it lives `ttl_s`.
- **Expiry.** `expires_at` is written and compared in this instance's wall-clock microseconds. A read ignores an expired row, a claim takes one. Nothing reaps a key that never comes back: `sweep(scope)` deletes this store's expired rows, and the guide says to call it from a scheduled job, as `job.Table.sweep` is. The two instances' clocks must agree to well within the two minutes of the marker, which NTP does.
- **The handler fails.** The claim is released with `del`, as before, so the retry runs. If the `del` itself fails (the database went away between claim and failure), the marker is left to its two minutes and the failure is logged: the retry is told 409 for that long and then runs.
- **The database does not answer at the claim.** The request is refused with a **503** naming the header and the handler does not run: running it unclaimed is the double charge. The client retries, and a key that was never claimed claims on the next try. It fails closed because the feature exists for the case where the cost of running twice is higher than the cost of not running yet.
- **The database does not answer at the put of the answer.** The handler has run and its answer is made, so it is sent. The marker is left, and a retry is told 409 until it expires and then runs the handler again. It is not deleted: deleting is the same call that just failed, and a retry running at once is the double run.
- **The answer is longer than `max_bytes`, or a key longer than 1,024 bytes.** `error.TooLarge`, as for a Space: the key is a 400 before the handler, the answer is sent and not kept.

### What this does not do

**It does not make the handler's own write and the answer commit together.** The marker, the handler's writes and the answer are separate transactions. A handler whose database write commits and whose process then dies before the answer is put leaves a marker, and a retry meets a 409 for two minutes and then runs the handler again, which will find its own earlier write. Exactly-once with the handler's effect needs the claim in the handler's transaction, which holds a row lock and a pooled connection for the length of the handler and moves the 409 from "answered at once" to "waits on the lock". That is a different trade, and the position of ADR 160 holds here too: at least once plus an idempotent write, with the key making the second run rare rather than impossible.

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes, on the route that asks and nowhere else:

| Axis | Cost |
|---|---|
| Allocations per request | A route without the argument runs the code it ran, and `the request path stays inside its allocation budget` passes unchanged. On an `Idempotent` route over this store, the arena allocations ADR 155 counted are still there (the encoded answer, the `max_bytes` read buffer on a replay, the joined key under `.by`), and each statement allocates its Row and its copy of the value out of the same arena; a fresh request makes two statements and a replay two, the claim and the read |
| Memory per idle connection | None. Nothing is on the stack: the store reads into an arena buffer, and `Held` is not declared for a store that takes a scope. A store is one pointer to a `Db` |
| Throughput and p99 | Nothing off the route. On it, Postgres 18 on localhost, defaults: a claim of a free key 1.0 ms, the put of the answer 1.6 ms (both commits), a claim of a taken key 54 µs, a read 44 µs, a `del` 1.6 ms. A fresh request pays about 2.6 to 3.3 ms before its handler; a replay or a 409 about 100 µs. With `synchronous_commit = off` for the role the same calls are tens of microseconds. `bench/result/sql.md` §27 has the run, the machine and what it did not measure |
| Binary size | A program that does not name `sql.Replays` links none of it: `replays.zig` is analysed only when something names it. `Idempotent` gains two small functions and a branch per call, folded away for a `Space`. Not measured as a stripped `ReleaseFast` delta; ADR 017's running total owes the line |

## What was rejected

- **A Fitting of its own taking the Db as a type**, the shape of `job.Table(Db)`. Right for the queue, which has an in-memory store and runs without `nilo_sql`; here every user has `nilo_sql` and the in-memory case is a `cache.Space`. It would have cost a module's wiring for a seam nothing crosses. If a program ever wants this over a database that is not `nilo_sql`'s, the contract is the six declarations and `takes_scope`, and the type is written against it without changing `Idempotent`.
- **In `job/`.** `job.Table` has the same Db contract, but a replay store is not a queue and a program using it would import a queue to get a key-value table.
- **In `nilo_cache`.** ADR 110: an in-process cache and a client for a shared store are two modules, because the failure modes differ (a call that can fail and wait, against a spin lock that cannot), and `nilo_cache` is the layer that runs under a plain `zig test`.
- **In `http/`.** `nilo_http` names no store (ADR 155) and may not import `nilo_sql`.
- **One statement for the claim**, `DO UPDATE … WHERE`. Measured above: 31 times the cost for the request that mostly matters.
- **A read first, then a write only when the key is free** (a `SELECT` before the `INSERT`). Two instances both read "free" and both insert; the second is stopped by the key and has lost its claim silently unless it also reads who won, which is a third statement and no gain over `DO NOTHING`.
- **A `FOR UPDATE` transaction around the handler**, so the marker is a lock and a crash rolls it back. It holds a pooled connection and a row lock for the length of the handler (seconds, for a payment), makes a concurrent retry wait where it should be told 409, and does not exist on SQLite in any useful form.
- **Failing open when the database does not answer at the claim**, running the handler unclaimed and logging. For a cache that is right (`Cached` runs the handler on a key too long for its Space). For a payment it is the feature failing in the one case it is for.
- **Deleting the marker when the put of the answer fails.** It makes the retry run at once; leaving it makes the retry wait two minutes. The first is the double run the key exists to prevent.
- **Reaping expired rows on the claim.** A `DELETE` on every claim is a write on the path that most wants to be a read; the sweep is the caller's, on a schedule, like `job.Table.sweep`.

## Consequences

- `sql/replays.zig`: `Replays(Db, Options)` with `Row`, `open`, `putIfAbsentFor`, `put`, `putFor`, `getInto`, `del`, `sweep` and `takes_scope`. Re-exported as `sql.Replays`.
- `http/idempotent.zig`: `isScoped`, `claim`, `read`, `keep`, `release`, `KeepError`; `checkSpace` asks for `Held` only of a store that does not take a scope. `http/typed.zig` calls them, and answers 503 for `error.Unavailable`. `http/cached.zig` refuses a store that takes a scope.
- Three refusals in `sql/refusals/` (not a Db, no name, `max_bytes` of 0) and two in `refusals/` (a store with no `del`, a `Cached` over a store that takes a scope).
- Tests: `http/behaviour.zig` holds the `Idempotent` half against a fake that takes a scope (two Apps, one store, a 503, a failed put, a released claim); `sql/replays.zig` holds the table against SQLite in memory and, when `DATABASE_URL` reaches one, Postgres with two pools: the sixteen-way race on a free key and on an expired one, the same key reaching two instances at once with a handler that works for 300 ms (one 201, one 409, and a replay after), and a failed handler freeing the key for the other instance.
- The todo entry *`Idempotent` answers once per key per process* is closed. A note on the Redis variant stays where ADR 110 put it.
