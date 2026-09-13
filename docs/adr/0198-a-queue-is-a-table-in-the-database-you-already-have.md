# 0198 — a queue is a table in the database you already have

**Status:** accepted
**Amends:** [ADR 0070](./0070-a-fitting-borrows-the-loop.md),
[ADR 0139](./0139-an-in-process-cache-and-a-redis-client-are-two-modules.md)

## Context

The ordinary API has four jobs that are not requests: send the welcome email
after the user is created, retry it when the mail provider is down, send the
reminder tomorrow, and run the report at three in the morning. `app.spawn`
and `nilo.sleep` cover "every so often" ([ADR 0086](./0086-work-that-is-not-a-request-belongs-to-the-server.md))
and nothing else: a fiber that fails has only the log to fail to, and a
process that restarts loses whatever the fiber was holding.

Every framework in the comparison ships something for this, and they split
on one question — **where the rows live.** Sidekiq, BullMQ and Celery put
them in Redis. Oban, Que, Solid Queue and pg-boss put them in the database
the application already has. The second group exists because the first
group's users kept hitting the same two things: an order committed whose
email job was lost, or an email job run whose order was rolled back; and a
second service to run, watch and pay for.

## Decision

**`nilo_job`, and its queue is a table in the caller's `nilo_sql` database.**
The row is a `nilo_table` Row like any other, the caller migrates it beside
their own, and a claim is one statement:

```sql
UPDATE nilo_jobs SET state = 'running', lease_until = $2, attempts = attempts + 1
WHERE id = (SELECT id FROM nilo_jobs
            WHERE (state = 'queued' AND run_at <= $1) OR (state = 'running' AND lease_until <= $1)
            ORDER BY run_at LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING …
```

Four things fall out of that, and each of them is something a Redis-backed
queue has to build:

- **`pushIn(&tx, …)`.** The job row is inserted in the transaction that
  inserts the order, so the two commit together or not at all. The outbox
  pattern, for free, because the outbox *is* the queue.
- **Several instances.** `SKIP LOCKED` is what lets ten servers share one
  table with no coordinator — and it is the third reason for a Redis that
  [ADR 0139](./0139-an-in-process-cache-and-a-redis-client-are-two-modules.md)
  said nobody had brought. The answer turned out to be the database rather
  than a second process.
- **A restart loses nothing.** The row is where it was.
- **A worker that dies mid-run.** The second arm of the `WHERE` is a lease:
  a `running` row whose `lease_until` has passed is taken by whoever asks
  next. **At least once**, and the guide says so on its first page: `run` is
  written to be safe to call twice.

SQLite gets the same statement without `FOR UPDATE SKIP LOCKED`, which it
does not have and does not need — one writer is already serial
([ADR 0074](./0074-one-writer-is-not-a-setting-it-is-the-database.md)). Both
databases are production stores here; what differs is that on SQLite the
number of workers is the number of jobs running at once and not the number
of claims running at once, since every claim is a write.

**`unique` is a unique index, not a check.** `(kind, unique_key)` is unique
and a finished row has its key set to NULL, so "at most one queued or
running" is the database's promise. `insertOrIgnore` answers null when the
row is already there. It is what makes a schedule seed itself on ten
instances at once and come out as one row.

**A job is a struct.** Its fields are the payload, written as JSON at `push`
and parsed back into the tick's own `nilo.Run`; `run` is the work, and every
pointer argument after the Run is a service the queue was handed at `open`.
A `Str` may sit in a payload because it is copied at `push` rather than
carried, which is the first of the two things `docs/guide/background.md`
says must not travel into spawned work; the second, a fail function, cannot
be called because `run` is handed a Run and not a Ctx.

## Where it sits

A Fitting, and the second one ([ADR 0070](./0070-a-fitting-borrows-the-loop.md)).
It borrows the loop to wait on and owns no destination: the store is a type
parameter. `job.Table(Db)` takes the caller's Db type and calls `insert`,
`update` and `rawOne` on it, so `job/` imports `nilo_core` and nothing else,
and `zig build layering` holds that. `job/live.zig` is the one root that
names `nilo_sql`, for the reason `fetch/deadline.zig` names `nilo_http` — the
thing it tests is the table, and only a database has one.

The entry condition is met the way `nilo_fetch` meets it: the worker loop is
written against `std.Io` — `Group.concurrent`, `sleep`, `checkCancel` — and
`zig build test-job` runs it under `std.Io.Threaded` with `job.Memory` as
its store and no Engine anywhere. Under the server the same loop runs on
zio's `Io`, handed over in `nilo_start`, and `app.spawn(Jobs.serve, …)` is
what starts it.

**`job.Memory` is a queue and not a cache**, and the difference is one line:
a full `Memory` answers `error.QueueFull` and a full `nilo_cache` writes over
the oldest entry. The first is right for a queue and the second for a cache,
which is why `nilo_job` does not sit on `nilo_cache` for its rows. It *does*
take a `cache.Space` for the two things that may be forgotten: a status for
a route to poll, and a `.within` window in front of a `unique` key. Both are
duck-typed the way `nilo.Idempotent` takes its Space
([ADR 0193](./0193-a-request-answered-once-is-answered-the-same-way-again.md)),
so `nilo_cache` is not an import either.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes:

- **Allocations per request: none on a route that does not push.** A route
  that does pays the JSON of the payload out of the request arena — the one
  allocation it already has — and one `INSERT`. Held by the existing test in
  `http/app.zig`, which touches no route that pushes.
- **Memory per idle connection: none.** A worker is a fiber per process, and
  a fiber holds its stack at its high-water mark
  ([ADR 0063](./0063-a-handlers-stack-is-per-connection.md)): `workers = 4`
  is four of those plus whatever each `run` touches, paid once. The Run each
  worker holds is an arena reset per row.
- **Throughput and p99: none on the request path.** Off it, one claim per
  worker per `poll_ms`: 354 µs of Postgres or 55 µs of SQLite a second per
  idle worker on the two-core box in [`bench/result/job.md`](../../bench/result/job.md),
  which is where `poll_ms = 1_000` comes from.
- **Binary size:** paid only by a program that imports it. `nilo_http` never
  names it. *Not yet measured; the stripped `ReleaseFast` number owes its line
  in ADR 0018's running total.*

## What was rejected

- **Redis as the store.** Two clients exist in Zig and both are alpha with no
  pub/sub (ADR 0139). More to the point, a queue over Redis cannot join the
  transaction that made the work, and that is the bug the database-backed
  queues were written to close. A third store written against
  `job/contract.zig` is nine methods, and the list is there for whoever
  brings the deployment.
- **A file of its own.** A queue in a file is a database with one table and
  none of the tooling; SQLite is that with the tooling.
- **`nilo_cache` as the memory store.** Above. A queue that forgets has lost
  somebody's email.
- **Exactly-once.** It is at-least-once plus an idempotent `run`, everywhere,
  and a module that claimed otherwise would be claiming something about the
  caller's mail provider. `nilo.Idempotent` is the same position on the
  inbound side.
- **A Service rather than a Fitting.** It holds no connection of its own; it
  is handed a store. Making it a Service would have made `job.Table` import
  `nilo_sql`, which is sideways, and the layering step would have refused it
  correctly.

## Consequences

- `job/` is a module with `job.Jobs`, `job.Memory`, `job.Table(Db)`, and the
  schedule types of [ADR 0199](./0199-a-schedule-is-a-type-that-makes-the-caller-choose.md).
- A row in `layers`, `shipped_roots` and `.paths`; `test-job` on `test`,
  `test-job-sql` on `test-sql`, `refusals-job` with twelve entries,
  `bench-job`.
- `docs/roadmap.md` loses "A schedule, rather than a loop around a sleep"
  and "a queue" from the modules that do not exist, and gains a section for
  this one.
- **Under `app.start(io)` followed by `listen()`, the workers run on the
  caller's `Io`** — the same thing that is true of every Service's
  `nilo_start` under that order (ADR 0079, ADR 0086), and worse here because
  a worker sleeps: on `std.Io.Threaded` that is a thread held for `poll_ms`.
  The roadmap carries it as the module's first known gap.
