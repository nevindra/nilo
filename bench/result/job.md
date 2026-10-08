# nilo_job

What a claim costs on each store, which is the number the module's `poll_ms`
default rests on, and what a push costs a handler.

Machine: Intel Xeon Platinum 8255C @ 2.50GHz, **2 vCPUs**, 7 GiB, Ubuntu,
kernel 6.8.0. Zig 0.16.0, ReleaseFast. Commit `8714f7f` plus the module.
Postgres 17 (timescaledb-ha) in Docker, reached across a **published port** —
the same transport `bench/result/sql.md` warns halves a Postgres figure
against a unix socket. SQLite in memory, `.in_fiber`.

`zig build bench-job` is the program; `DATABASE_URL=… zig build bench-job`
adds the Postgres row.

## The numbers

Three runs, one connection, single-threaded, 1,000 rounds each. Per call.

| store | empty claim | claim that takes a row | push |
|---|---|---|---|
| `job.Memory` | 3 µs | 4 µs | 6 µs |
| `job.Table` on SQLite | 52–57 µs | 140–141 µs | 10–11 µs |
| `job.Table` on Postgres | 354–363 µs | 1,171–1,216 µs | 885–899 µs |

**Empty** is the table with no due row — what an idle worker asks every
`poll_ms`. **Taking** is the same statement finding one of a thousand due
rows and moving it to `running`. **Push** is one `INSERT` (with the unique
index in place), what a handler pays.

## What they decided

**`poll_ms = 1_000` stays.** An idle worker costs 354 µs of Postgres a second
on this box — 0.035% of one connection — or 55 µs of SQLite. Four workers are
four of those. That is cheap enough that the default is chosen for latency
rather than for load: a job pushed while every worker is asleep starts within
a second, and a program that wants faster sets it lower with a number to
weigh against.

**A claim is one statement, and it stays one.** The `UPDATE … WHERE id =
(SELECT … FOR UPDATE SKIP LOCKED) RETURNING` shape costs a round trip per
row; the alternative — claim a batch of ten and run them in turn — would cut
the per-row cost by most of the Postgres figure, at the price of ten rows held
by one worker that may die. That is a Next entry in `docs/todo.md` rather
than the default, because the number that decides it is a busy queue's
throughput under several workers, which one connection cannot measure.

**`job.Memory` scans.** 3–6 µs is a linear pass over roughly 3,800 fixed slots
under a spin lock, which is fine for the test and small-program store it is;
a heap would make it 200 ns and would be an allocation-free heap somebody has
to write. Not until a program has a memory queue big enough to notice.

## What is not here, and the ranked levers

## What the claim's index has to be, 2026-09-23

ADR 214 added `ORDER BY priority, run_at` and widened the table's index to
`(state, priority, run_at)` on the reasoning that an index matching the sort
serves it. Measured, on Postgres 16 in Docker, a `nilo_jobs`-shaped table:

| queued rows | index | buffers | time |
|---|---|---|---|
| 200 000 future-dated, 1 due | `(state, priority, run_at)` | 988 | 7.9 ms |
| 200 000 future-dated, 1 due | `(state, run_at)` | 7 | **0.065 ms** |
| the same plus 50 000 due | `(state, priority, run_at)` | 2 132 | 20.2 ms |
| the same plus 50 000 due | `(state, run_at)` | 615 | **12.4 ms** |

With `priority` in front of `run_at`, `run_at <= $1` stops being a range bound
and becomes a filter inside each priority, so the scan walks every future-dated
queued row — the scheduled next ticks, the `after_ms` pushes, the backoff
retries — before it reaches a due one. A queue holding work for later is the
normal case, not the pathological one.

The wide index does not even pay in the regime it was meant for: with a real
backlog it is still slower, because the narrow index finds the due set first
and a top-N heapsort orders it, which is cheap for `LIMIT 1`.

The index stayed `(state, run_at)`. The lesson is the ordinary one about
composite indexes — an equality column may precede a range column, a second
sort column may not — and it was not caught by reading, because the claim was
only ever run against tables whose rows were all due.

1. **Several workers against one Postgres.** Everything above is one
   connection. The claim under contention — eight workers, SKIP LOCKED doing
   its job — is the number that would decide batching, and it wants a box with
   cores (`bench/result/cache.md` is the account of what two cores cannot
   ask).
2. **A unix socket.** `sql.md` measured 133% between a Docker port and a
   socket for the same statement; the Postgres row here is the slow transport.
3. **The push through a handler**, with the JSON of the payload and the arena
   in the way, against `/health` beside it as a control — `bench/sql_server.zig`
   is the shape. Nothing above touches the request path, so the 1-allocation
   test in `http/app.zig` is what holds that number for now.
