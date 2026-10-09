# Jobs

**A job is a struct whose `run` does the work later, on a worker, outside any request, and the queue it waits in is a table in the database the program already uses.**

**Guide:** [Work that runs later](../guide/jobs.md) · **Reference:** [`nilo_job`](../reference/job.md)

The code is `job/job.zig` (`Jobs`, `Tick`, the worker loop), `job/table.zig` and `job/memory.zig` (the two stores), `job/cron.zig` (the schedule parser) and `job/contract.zig` (what a store must provide).

## Overview

```
  caller ──push(scope, Kind{...})──► nilo_jobs (a Row, migrated beside the caller's own)
                                            │
                              claim: one statement, most urgent due row first
                                            │
                                       worker fiber
                                            │
                          run(self, *nilo.Run, ...deps, ?Tick)
                               │                    │
                            success               failure
                            state = done      final? ─ dead now
                                               otherwise ─ retry (backoff) or dead

  schedule: a cron/every next-tick row, unique = "schedule" ──┘ (claimed like any other)
  jobs.cancel(id): deletes a queued row before a claim reaches it
```

A push wakes one waiting worker through a futex counter. `poll_ms` only matters for a row this process did not see being added (another process's push, or a push inside a transaction that has since committed).

## Rules

1. **The queue is a table, `nilo_jobs`: a `nilo_table` Row you migrate alongside your own tables**, not a separate service. Claiming a job is one `UPDATE ... RETURNING` statement, so `pushIn` inside the transaction that created the work gives you the outbox pattern for free. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
2. **Claiming uses `FOR UPDATE SKIP LOCKED` on Postgres and a plain write on SQLite.** SQLite needs no skipping because its single writer already runs one claim at a time; there, the worker count is how many claims run at once, not how many jobs. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
3. **Delivery is at least once, everywhere.** A worker that dies mid-run leaves a lease that expires, so `run` must be safe to call twice. Nothing here promises exactly once. The one narrowing is rule 14. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
4. **A `.deps` written as `fn (comptime Queue: type) type` lets a job push the next one** without a dependency loop, by delaying the checks that would otherwise read a type that does not exist yet. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
5. **`job.Tick` (`id`, `attempts`, `run_at`, `last`) costs nothing to ask for**, because the worker already has all of it from the claim. `drainAt`/`runOneAt` read one `Clock` value instead of the wall clock, which is how a test moves time forward without sleeping. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
6. **`jobs.cancel(scope, id)` deletes a row only while it is `queued`**, and returns `false` for one that is running, finished or missing. A running job is never interrupted, because nilo has no way into a `run` that is in progress. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
7. **`retry` has no default**, for any kind, and it applies before `final` is checked. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
8. **`pub const final = error{...}` lists the failures that make a job dead on any attempt**, whatever `retry.times` says. A timeout is never final, because it means the run did not finish, not that it cannot succeed. [ADR 179](../adr/179-a-run-can-say-its-failure-is-final.md)
9. **A scheduled kind must declare `overlap` and `missed`; neither has a default.** The next tick is a row pushed with `unique = "schedule"`, so several instances seeding the same schedule create one row, and whichever claims it runs it. There is no leader. Every worker seeds again once a minute (idempotent, so one insert per kind per minute), which is what brings back a schedule whose row was lost to a crash, a failed push or a `cancel`. [ADR 161](../adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md)
10. **`job.cron(...)` is parsed while compiling, and only in UTC.** A field out of range, or a schedule without `overlap`/`missed`, is a Refusal that names what is missing, instead of a default nobody noticed. [ADR 161](../adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md)
11. **`priority` belongs to the kind, not the call site.** There are three levels (`high` is 0, `normal` is the default), and a claim orders by `priority` then `run_at` ascending, using the same `(state, run_at)` index instead of a wider one that would stop `run_at` from being used as a range. [ADR 214](../adr/214-a-job-says-how-urgent-it-is.md)
12. **A worker only claims the kinds it knows** (`kind = ANY($3)` on Postgres, a list of placeholders on SQLite). A row of a kind this binary does not run stays `queued` for the binary that does, instead of being released and re-claimed in an endless retry loop. [ADR 215](../adr/215-a-worker-claims-only-what-it-can-run.md)
13. **A run the shutdown cut off goes back to the queue, whatever the statement said.** The worker asks the fiber, not the error: a failure with a cancellation pending (nilo_sql answers a cut-off statement `QueryFailed`, ADR 223) releases the row with its attempt given back, and every store write after a run (`done`, `retry`, `dead`, `release`) runs with cancellation held off, as cleanup. [ADR 243](../adr/243-a-run-cut-off-by-a-shutdown-goes-back-whatever-the-statement-said.md)
14. **A `run` that takes the Db's `*Db.Tx` commits its database writes and its `done` together, or neither (transactional completion).** The worker begins the transaction, writes the fenced `done` inside it with the store's `doneIn`, and commits; a `done` that matches nothing rolls the transaction back, and a failed run rolls it back before `retry` or `dead` is written outside it. A transactional run pins a connection for its whole length, so a queue with one refuses to start with as many workers as connections; on SQLite it holds the one writer, so the kind declares its own `timeout_ms`. The run is still at least once: only the writes in the queue's own database commit with `done`. A `job.Memory` queue, a `run` taking both `*Db.Tx` and `*Db`, and a transaction of another Db are Refusals. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)

## Decisions

| ADR | What it decides |
|---|---|
| [160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md) | What the queue is, how claiming, pushing and waking work, `.deps` as a function, `Tick`, `cancel`, and transactional completion |
| [161](../adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md) | `schedule`, `overlap` and `missed` as required declarations, cron parsed at compile time, UTC only |
| [179](../adr/179-a-run-can-say-its-failure-is-final.md) | `final`, an error set listing the failures no retry can fix |
| [214](../adr/214-a-job-says-how-urgent-it-is.md) | `priority`: three levels on the kind, and why the claim's index is not widened for it |
| [215](../adr/215-a-worker-claims-only-what-it-can-run.md) | A claim is limited to the kinds this program declares, so other programs' rows are left alone |
| [243](../adr/243-a-run-cut-off-by-a-shutdown-goes-back-whatever-the-statement-said.md) | A run a shutdown cut off goes back to the queue whatever its statement answered; what the worker writes about a row after a run cannot be interrupted |

Related topics: why `app.spawn`/`nilo.sleep` alone were rejected for recurring work is [ADR 028](../adr/028-a-spawned-fiber-belongs-to-the-server.md) (engine); why the store is your own database and not a Redis client is [ADR 110](../adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md) (cache); the same at-least-once position for incoming requests is [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md) (idempotency); why SQLite's claim needs no `SKIP LOCKED` is [ADR 065](../adr/065-one-writer-is-not-a-setting-it-is-the-database.md) (sql-runtime).

## Open questions

- **Whether a job kind can limit how many of it run at once.** A per-kind limit enforced by the claim itself, instead of a `nilo.Gate` inside `run` that still ties up a worker while it waits. In [the todo list](../todo.md).
- **Whether a job has a result.** `status(id)` says `done` and nothing about the outcome. A `pub const Result = T` plus a `result` column is sketched, not built. [The todo list](../todo.md).
- **Schedules are UTC only.** Time zones would be a dependency this module has not taken on. [The todo list](../todo.md).
- **A worker started with `app.start(io)` and never `listen()`ed has nothing to stop it.** This module installs no signal handler; a worker binary is expected to write the four lines that catch `SIGTERM` itself. [The todo list](../todo.md).
- **`stats` is three numbers for the whole queue**, not the per-kind counts or queue age an operator's dashboard would want. [The todo list](../todo.md).
- **`job.Memory` scans its slots under a spin lock**, 3 to 6 microseconds per claim. Fine for tests; not measured at a size anyone would notice. [The todo list](../todo.md).
