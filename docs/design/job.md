# Jobs

**A job is a struct whose `run` does the work later, on a worker, outside any request, and the queue it waits in is a table in the database the program already has.** How to use it is the guide ([`guide/jobs.md`](../guide/jobs.md)); every name and signature is the reference ([`reference/job.md`](../reference/job.md)). The code is `job/job.zig` (`Jobs`, `Tick`, the worker loop), `job/table.zig` and `job/memory.zig` (the two stores), `job/cron.zig` (the schedule parser) and `job/contract.zig` (what a store must answer to).

## How the pieces fit

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

A push wakes the one worker waiting on a futex counter; `poll_ms` only matters for a row this process never saw arrive (another process's push, or one made inside a transaction that has since committed).

## The rule in force

1. **The queue is a table, `nilo_jobs`, a `nilo_table` Row the caller migrates beside their own**, not a second service. A claim is one `UPDATE ... RETURNING` statement, so `pushIn` inside the transaction that made the work is the outbox pattern for free. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
2. **A claim uses `FOR UPDATE SKIP LOCKED` on Postgres and a plain write on SQLite**, which needs no skipping because one writer is already serial; on SQLite the worker count is the number of claims running at once, not the number of jobs. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
3. **This is at least once, everywhere.** A worker that dies mid-run leaves a lease to expire, and `run` is written to be safe to call twice; nothing here claims exactly-once. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
4. **A `.deps` written as `fn (comptime Queue: type) type` lets a job push the next one** without a dependency loop, by deferring the checks that would otherwise read a type with no value yet. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
5. **`job.Tick` (`id`, `attempts`, `run_at`, `last`) is free to ask for** because everything in it was already in the worker's hand at the claim; `drainAt`/`runOneAt` read one `Clock` value instead of the wall, which is how a test moves time without sleeping. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
6. **`jobs.cancel(scope, id)` deletes a row only while it is `queued`** and answers `false` for one running, finished or absent; a running row is never interrupted, because nilo has no way into a `run` in flight. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
7. **`retry` has no default**, on every kind, and applies before `final` is even asked. [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)
8. **`pub const final = error{...}` names the failures that are dead on any attempt**, whatever `retry.times` says; a timeout is never final, since it says the run did not finish rather than that it cannot succeed. [ADR 179](../adr/179-a-run-can-say-its-failure-is-final.md)
9. **A scheduled kind must declare `overlap` and `missed`, with no defaults for either.** The next tick is a row pushed with `unique = "schedule"`, so several instances seeding the same schedule produce one row and whichever claims it runs it; there is no leader. [ADR 161](../adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md)
10. **`job.cron(...)` is parsed while compiling, and only in UTC.** A field out of range, or a schedule with no `overlap`/`missed`, is a Refusal naming the gap rather than a default nobody read. [ADR 161](../adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md)
11. **`priority` is a fact about the kind, not the call site**: three levels (`high` is 0, `normal` is the default), and a claim orders `priority` then `run_at` ascending, both on the same `(state, run_at)` index rather than a wider one that would make `run_at` stop being a range bound. [ADR 214](../adr/214-a-job-says-how-urgent-it-is.md)
12. **A worker's claim asks only for the kinds it knows** (`kind = ANY($3)`, bound, on Postgres; a run of placeholders on SQLite), so a row of a kind this binary does not run stays `queued` for the binary that does, rather than being released and re-claimed into a retry spiral. [ADR 215](../adr/215-a-worker-claims-only-what-it-can-run.md)
13. **A run the shutdown cut off goes back to the queue, whatever the statement said.** The worker asks the fiber, not the error: a failure with a cancellation pending (nilo_sql answers a cut-off statement `QueryFailed`, ADR 223) releases the row with its attempt given back, and every store write after a run (`done`, `retry`, `dead`, `release`) runs with cancellation held off, as cleanup. [ADR 232](../adr/232-a-run-cut-off-by-a-shutdown-goes-back-whatever-the-statement-said.md)

## Decisions

| ADR | What it decides |
|---|---|
| [160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md) | What the queue is, how a claim, a push and a wake work, `.deps` as a function, `Tick`, and `cancel` |
| [161](../adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md) | `schedule`, `overlap` and `missed` as required declarations, cron parsed at compile time, UTC only |
| [179](../adr/179-a-run-can-say-its-failure-is-final.md) | `final`, an error set naming the failures no retry can fix |
| [214](../adr/214-a-job-says-how-urgent-it-is.md) | `priority`, three levels on the kind, and why the claim's index is not widened to hold it |
| [215](../adr/215-a-worker-claims-only-what-it-can-run.md) | A claim is bound to the kinds this program declared, so a foreign row is left alone rather than churned |
| [232](../adr/232-a-run-cut-off-by-a-shutdown-goes-back-whatever-the-statement-said.md) | A run a shutdown cut off goes back to the queue whatever its statement answered; what the worker writes about a row after a run cannot be interrupted |

Beside this topic: why `app.spawn`/`nilo.sleep` alone were refused for recurring work is [ADR 028](../adr/028-a-spawned-fiber-belongs-to-the-server.md) (engine); why the store is the caller's own database rather than a Redis client is [ADR 110](../adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md) (cache); the same at-least-once position held on the inbound side of a request is [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md) (idempotency); why SQLite's claim needs no `SKIP LOCKED` is [ADR 065](../adr/065-one-writer-is-not-a-setting-it-is-the-database.md) (sql-runtime).

## Open

- **Whether a job may say how many of it run at once.** A per-kind concurrency ceiling the claim itself respected, rather than a `nilo.Gate` inside `run` that still holds a worker while it waits; on the record in [the roadmap](../roadmap.md).
- **Whether a job has a result.** `status(id)` says `done` and nothing about what came of it; a `pub const Result = T` and a `result` column is the shape sketched, unbuilt; [the roadmap](../roadmap.md).
- **A schedule is UTC only.** A time zone is a dependency this module has not taken on; [the roadmap](../roadmap.md).
- **A worker started under `app.start(io)` and never `listen()`ed is a worker nobody stops.** There is no signal handler in this module; a worker binary is expected to write the four lines that catch `SIGTERM` itself; [the roadmap](../roadmap.md).
- **`stats` is three numbers for the whole queue**, not the per-kind counts or queue age an operator's dashboard would want; [the roadmap](../roadmap.md).
- **`job.Memory` scans its slots under a spin lock**, 3 to 6 microseconds a claim; fine for a test, unmeasured at a size anybody would notice; [the roadmap](../roadmap.md).
