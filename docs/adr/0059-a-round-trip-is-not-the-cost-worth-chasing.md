# A round trip is not the cost worth chasing

"Several statements in one round trip" was the last line under **Writing** in
the Drizzle checklist. Answering it needed a number nobody had, and getting
that number turned out to be the most useful thing in this cycle — because it
is also the answer to the question the whole module is judged on: **does the
database layer become the bottleneck of the application built on it?**

## What a round trip costs

`bench/sql.zig` gained a third shape, `SELECT 1` — as close to a bare round
trip as the extended protocol reaches. One connection, 20,000 rounds,
Postgres 16 in Docker over loopback:

| prepared, one connection | ns/query |
|---|---|
| a bare round trip (`SELECT 1`) | 23,915 |
| a key lookup | 26,212 |
| a page with a sort | 81,829 |

**The round trip is 91% of a key lookup.** The query itself — plan, execute,
one row over the wire — is about 2.3 µs. Everything else is two syscalls, two
process wakeups and the kernel's loopback path.

`/usr/bin/time -v` on the whole bench says the same thing from the other side:
**6.79 s wall for 0.88 s of CPU, and 264,046 voluntary context switches for
~264,000 queries.** One blocking wait per query, 87% of the time spent in it.

That reframes the question. Making the statement cheaper is chasing 9% of the
cost. What matters is what the process does during the other 91%.

## Which is the real question

If a Postgres read **suspends the fiber**, 24 µs is latency and the server's
capacity is bounded by the pool. If it **blocks the OS thread**, capacity is
bounded by threads, and every application on this module is capped at roughly
`threads ÷ 24 µs` — which is the failure mode
[ADR 0014](./0014-handlers-must-not-block-the-thread.md) names and the
reason `nilo_start` exists at all.

Reading the source says it suspends: pg.zig holds an `Io.net.Stream` and reads
through the `Io` it was handed, which under the engine is zio's. **That is an
argument.** `bench/sql_server.zig` is the measurement — a ReleaseFast server
whose every request is a `db.find`, with `/health` beside it as the control.

wrk, 4 threads, 16-core box with the load generator and Postgres on it too:

| connections | req/s | p50 | p99 |
|---|---|---|---|
| 8 | 113,150 | 70 µs | 94 µs |
| 16 | 149,246 | 104 µs | 160 µs |
| 64 | 207,121 | 281 µs | 940 µs |
| 128 | 214,059 | 555 µs | 1.68 ms |
| 256 | 213,193 | 1.15 ms | 3.99 ms |

**215,000 requests a second, every one of them a real query.** One blocked
thread would cap at 1 ÷ 24 µs ≈ 41,000. It is five times past that at the
knee and holds flat to 256 connections rather than collapsing, which is the
shape of a system waiting on a pool rather than one thrashing on threads.

The control route, `/health`, serves 1,135,000 a second on the same binary.

### Where the CPU goes, which is not where it looks

Sampled during the c=128 run:

| | req/s | server CPU | per request |
|---|---|---|---|
| `/health` | 1,135,223 | 6.96 cores | **6.13 µs** |
| `/people/:id` | 215,577 | 4.70 cores | **21.8 µs** |

A query adds **15.7 µs of server-side CPU**, and the machine as a whole sits
at 45% system and 20% softirq with 21% in user code. The 64 Postgres backends
take about eight cores between them; the nilo server takes 4.7 and does not
appear in the top twenty processes. **Nothing in the measurement is nilo
running out of anything** — the ceiling is Postgres and the kernel's network
path, on a box where all three programs are competing for the same cores.

## What was decided

**Pipelining is refused, and the reason is the numbers above rather than the
effort.**

- **pg.zig has no pipelining API**, and adding one means Parse/Bind/Execute
  sequencing before a single `Sync` — wire-protocol work inside the driver,
  not inside nilo. `sql/postgres.zig` is the only file allowed to name pg.zig
  ([ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md)) and
  it cannot reach that far down.
- **The shape that actually matters is already one round trip.** Many rows in
  one statement is `db.insertMany`
  ([ADR 0053](./0053-a-batch-is-one-array-per-column.md)), and that is what a
  service does at volume. Drizzle's own `db.batch()` is not available on its
  Postgres drivers either, for the same reason.
- **What it would buy is latency for one request, not capacity.** The load
  test is already 5× past the thread-blocked cap; the 24 µs it would remove
  sits inside a p50 of 281 µs at the knee. Spending the module's one driver
  seam on it would be spending it on the axis that is not short.
- **Where a caller genuinely needs several statements to land together, SQL
  already has the answer and it needs no driver support**: a data-modifying
  CTE through `db.raw`.

  ```sql
  WITH gone AS (DELETE FROM sessions WHERE user_id = $1 RETURNING id)
  INSERT INTO audit (kind, ref) SELECT 'session_revoked', id FROM gone
  ```

  One statement, one round trip, atomic without a transaction — which is two
  round trips saved rather than one.

The door is left open in one place only: **if pg.zig ever grows pipelining,
`BEGIN`/`COMMIT` is where to spend it.** A transaction holding one statement
is three round trips for 2 µs of work, and those two are the round trips
nilo sends rather than the caller.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes:
nothing on any of them. Two measurement programs were added and no module code
changed. `bench-sql-server` is installed rather than run, because it wants a
load generator pointed at it.

## Consequences

- The claim "a Postgres wait costs a fiber, not a thread" is a measurement in
  the repository rather than a reading of somebody else's source. It was the
  load-bearing one and it had never been checked.
- **The server's own cost per request is now two numbers, 6.13 µs without a
  query and 21.8 µs with.** The gap is where a future optimisation pass looks,
  and most of it is syscalls rather than anything comptime can remove.
- `bench/sql.zig` leaves its table behind so `bench/sql_server.zig` reads the
  same one.
