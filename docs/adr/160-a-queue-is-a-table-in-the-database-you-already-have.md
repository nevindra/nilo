# A queue is a table in the database you already have

**Status:** accepted
**Topic:** [job](../design/job.md)

## Context

The ordinary API has four jobs that are not requests: send the welcome email after the user is created, retry it when the mail provider is down, send the reminder tomorrow, and run the report at three in the morning. `app.spawn` and `nilo.sleep` cover "every so often" ([ADR 028](./028-a-spawned-fiber-belongs-to-the-server.md)) and nothing else: a fiber that fails has only the log to fail to, and a process that restarts loses whatever the fiber was holding.

Every framework in the comparison ships something for this, and they split on one question, where the rows live. Sidekiq, BullMQ and Celery put them in Redis. Oban, Que, Solid Queue and pg-boss put them in the database the application already has. The second group exists because the first group's users kept hitting the same two things: an order committed whose email job was lost, or an email job run whose order was rolled back, and a second service to run, watch and pay for.

Four things a real caller needed did not fall out of the table alone. **fdm**, a download manager running in the same process as its own workers, felt the poll interval as user-visible latency: with `poll_ms` at its default of a second, queuing a download and waiting for the first byte took half a second on average, and the fix (`poll_ms = 100`) meant sixteen workers polling the store ten times a second each while there is nothing to do. **A pipeline** (download, then process, then notify) is the first thing a queue is for, and it did not compile: a queue naming itself in its own `.deps` is a dependency loop the compiler reports pointing at nothing nilo wrote. **A retrying job did not know which attempt it was** ("on the last attempt, use the fallback provider", a progress figure a route can poll), and **a test could not move the clock** to assert a backoff waited the doubled time or a cron schedule fired at three, so the module's own tests got by on real two-millisecond sleeps. And **there was no way to take a queued row back**: a user closing an export dialog, or unsubscribing before a nudge went out, left the row to run anyway; the caller that needed it pushes a reminder a day ahead and wants to move it when the date moves.

## Decision

### The queue is a table, and a claim is one statement

**`nilo_job`, and its queue is a table in the caller's `nilo_sql` database.** The row is a `nilo_table` Row like any other, the caller migrates it beside their own, and a claim is one statement:

```sql
UPDATE nilo_jobs SET state = 'running', lease_until = $2, attempts = attempts + 1
WHERE id = (SELECT id FROM nilo_jobs
            WHERE (state = 'queued' AND run_at <= $1) OR (state = 'running' AND lease_until <= $1)
            ORDER BY run_at LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING …
```

Four things fall out of that, each of them something a Redis-backed queue has to build: **`pushIn(&tx, …)`**, the job row inserted in the transaction that inserts the order, so the two commit together or not at all, the outbox pattern for free because the outbox *is* the queue; **several instances**, `SKIP LOCKED` letting ten servers share one table with no coordinator, the answer turning out to be the database rather than a second process ([ADR 110](./110-an-in-process-cache-and-a-redis-client-are-two-modules.md)); **a restart that loses nothing**, the row is where it was; and **a worker that dies mid-run**, the second arm of the `WHERE` being a lease, a `running` row whose `lease_until` has passed taken by whoever asks next. This is **at least once**, and the guide says so on its first page: `run` is written to be safe to call twice. Transactional completion, below, narrows that for the one write the queue can see.

SQLite gets the same statement without `FOR UPDATE SKIP LOCKED`, which it does not have and does not need, one writer already being serial ([ADR 065](./065-one-writer-is-not-a-setting-it-is-the-database.md)). Both databases are production stores here; what differs is that on SQLite the number of workers is the number of jobs running at once and not the number of claims running at once, since every claim is a write.

**`unique` is a unique index, not a check.** `(kind, unique_key)` is unique and a finished row has its key set to NULL, so "at most one queued or running" is the database's promise; `insertOrIgnore` answers null when the row is already there, which is what makes a schedule seed itself on ten instances at once and come out as one row.

**A job is a struct.** Its fields are the payload, written as JSON at `push` and parsed back into the tick's own `nilo.Run`; `run` is the work, and every pointer argument after the Run is a service the queue was handed at `open`. A `Str` may sit in a payload because it is copied at `push` rather than carried, the first of two things `docs/guide/background.md` says must not travel into spawned work; the second, a fail function, cannot be called because `run` is handed a Run and not a Ctx.

### A push wakes a worker

**A `push` wakes one worker, and `poll_ms` is what finds a row nobody woke anybody for.** A `Jobs` carries a counter, `wakes`. A worker reads it before it asks the store, and when the store answers "nothing" it sleeps on `io.futexWaitTimeout` with the value it read and `poll_ms` as the timeout; `push` bumps the counter after the store has the row and wakes one waiter with `io.futexWake`. The order is what makes the wake lossless: a push that lands between the empty claim and the sleep has already changed the word the worker is about to sleep on, so the wait returns at once.

One worker per push, not all of them, because a row is one unit of work and waking every worker for it is empty claims against the store; `wake()`, the public one, wakes every waiter and is for a row nilo did not see arrive, pushed by another process, or by `pushIn` under a transaction that has since committed (a wake called before the commit finds nothing, so the doc comment says to call it after). A row due later does not wake anybody: `push` with `.after_ms` or `.at` in the future leaves the poll to find it. `serveOn` with no `nilo_start` before it, the worker process with no server, takes the `Io` it runs on as the one a wake goes through, so the shape every CLI has works without a line.

### A job can push the next one

**`.deps` may be a struct, or a function of the queue type**, `fn (comptime Queue: type) type`, called once `@This()` exists inside `Jobs(…)`, answering the same struct of pointers a plain `.deps` gives:

```zig
fn deps(comptime Queue: type) type {
    return struct { db: *Db, jobs: *Queue };
}

const Jobs = job.Jobs(.{ .kinds = .{ Download, Process }, .store = job.Table(Db), .deps = deps });

const Download = struct {
    pub const nilo_job = "download";
    file: i64,

    pub fn run(self: Download, scope: *nilo.Run, db: *Db, jobs: *Jobs) !void {
        try fetchInto(scope, db, self.file);
        _ = try jobs.push(scope, Process{ .file = self.file }, .{});
    }
};
```

A queue naming a `*Jobs` in its own `.deps`, or in a `run`'s argument list that `Jobs(…)` checks while resolving `.deps`, is a dependency loop: the type has no value yet at the point the check would read it. Writing `.deps` as a function breaks the loop by deferring what it can: the fields other than the queue itself, and everything a `run` asks for, move behind a private declaration, `late_checked`, named from `open`, `openWith`, `push`, `serve`, `serveOn`, `drain` and `runOne`, analysed once however many name it, and after the queue's own declaration has its value, which is the moment the loop is gone. A queue whose `.deps` is a struct keeps every check in the body of `job.Jobs(…)`, as before. `depField`, which finds the field of `Deps` a `run`'s argument asked for, writes its own Refusal rather than reaching `unreachable`, so a `run` asking for something `.deps` has not got is refused wherever the check runs, the checks in the body, at `open` when deferred, or at the call if neither was reached.

### A tick knows which one it is, and a test can move the clock

**`job.Tick` is a value a `run` may ask for beside its deps**: `id`, `attempts`, `run_at`, and `last` (`attempts == retry.times + 1`), all of them already in the worker's hand from the claim, so asking costs nothing. `checkRun` recognises the parameter by its type, the same rule `http/typed.zig` reads a handler's argument list by: after the job and the Run, a pointer is a service and a value is the tick. A `*job.Tick` is refused naming the rule, since left to the deps lookup it would be told (correctly, but pointing the wrong way) that `.deps` has no `*job.Tick`.

**The `status` Space says `running` while a row runs, and says nothing for a row `pushIn` wrote.** `executeKind` notes `running` with the attempt once the payload has parsed and before `run` is called, so a route polling `status(id)` sees what the guide promised (one Space `put` per run, and none with no Space). `pushIn` notes nothing: it cannot see the caller's commit, so a `queued` written there would outlive a rollback as the status of a row that never existed. A row pushed in a transaction has no status until a worker takes it. The Space is per instance, like the cache it is: a row pushed on one instance and run on another stays `queued` in the first instance's Space until its TTL.

**A push that fails gives its `.within` window back.** The window is reserved with `putIfAbsent` before the store push, because two pushers agree on one winner only through it; a push the store then refuses (`QueueFull`, a database error) deletes the key again, so the retry is not answered `null` for the whole window with nothing queued. The window type needs a `del`, which every `cache.Space` has, and a type without one is refused naming it. A push answered `null` by the unique row keeps the window: something is queued.

**A failure that might not happen next time is not final.** A payload that cannot be read because the tick's arena is out of memory is retried by the kind's `retry` like a failed `run`, and not sent dead; only the parse errors that say this binary cannot read the payload are final. `job.Memory`'s claim copies the row into a buffer taken from the arena before the row is touched and allocates nothing under its lock, so a claim that runs out of memory leaves the row queued with its attempt unspent, and `deadOnes` counts under the lock, allocates outside it, and fills at most what it counted.

**Progress goes into the `status` Space that already holds the state.** `job.Status` gains `progress: u32`, `jobs.progress(id, n)` writes it beside `state` and `attempts`, and a route polling `jobs.status(id)` reads it; the number means what the kind says it means, rows or a percentage or a step, and it is reset by every change of state except `done`, which keeps the run's last figure. A queue with no Space does nothing here, as `status` does nothing there.

**`drainAt(&run, now)` and `runOneAt(&run, now)`**, with `drain` and `runOne` as the same calls at `core.nowMicros()`, are what let a test move time without sleeping: whether a row is due, whether a schedule's tick is later than its successor, when a failed run retries, when the next tick is, are all one read of a private `Clock` (`.wall` under a worker, `.fixed` under `drainAt`), passed down `execute`. `seed(&run)` and `seedAt(&run, now)` are the seeding `serve` does at start, made callable, since a test of a schedule has to put the first tick in the table before moving the clock to it. `drain` now reads the clock once rather than per row, so a drain that used to run as long as its ticks did (a schedule of `every(1)` staying due against a slow tick) finishes against one reading of what was due at that moment.

### A row is finished by whoever still holds it

**`done`, `retry`, `dead` and `release` match `state = 'running' AND attempts = ?`, the `attempts` the claim returned, and answer `false` when the row is no longer this worker's**, which the worker logs at `warn` and otherwise ignores. The lease is how a crashed worker's row comes back, so it is also how a slow one's does, and a worker whose lease lapsed used to requeue, free or kill the row a second worker held by matching on `id` alone: an audit reproduced three runs of one row. `attempts` is the fence because every claim bumps it, so it names the claim and costs no column. A store also has `unkey`, the same fence, which takes a running row's unique key off it and leaves it running; an `Overlap.queue` tick is what calls it ([ADR 161](./161-a-schedule-is-a-type-that-makes-the-caller-choose.md)). The rejected alternative is a lease token column: a second value to carry for what `attempts` already says.

**The two calls that finish a row take the time, and `Enqueue` can carry it.** `done(scope, id, attempts, now)` and `dead(scope, id, attempts, err, now)` write `finished_at` from the clock `drainAt` was given, where a store read the wall clock and a test that moved the clock saw `finished_at` stay in the real present. `Enqueue.now` is the same reading for a push, and a store writes it as `created_at` (null reads the wall clock, and a `Jobs` always sets it). `job.Table` had written `created_at` as the row's `run_at`; it is the time of the push. `job.Memory` keeps no finished row, but a dead one it stamps with `finished_at`, which is what `sweepDead(scope, before)` reads on both stores: `sweep` takes `done` rows only, because a dead row is the record of a failure, and a `Memory` whose dead rows are never swept fills up and answers `QueueFull` to a push with nothing wrong.

**An empty `.unique` is `error.EmptyUniqueKey`, and `retryDead` of a scheduled kind is `error.Scheduled`.** An empty key is nearly always a missing value formatted into one: `job.Table` folded every such push into the first row and `job.Memory` folded none, so the two stores disagreed on what the same call meant. `jobs.push` and both stores refuse it, and `.unique = ""` written out is a compile error. A dead row of a kind with a `schedule` is not revived, because its successor tick was queued when it died and reviving it would run the kind on two chains for good; the store decides it on the row it would revive (`retryDead(scope, id, now, scheduled)` takes the scheduled kinds), changes nothing, and a stopped schedule comes back through the re-seed. Both add to `Jobs.Error`, and a store of your own follows them in `job/contract.zig`.

### A queued row can be taken back

**`jobs.cancel(scope, id) !bool` deletes a row while it is `queued`, and answers `false` for one that is running, finished or absent.** It is one statement on the table, `DELETE … WHERE id = ? AND state = 'queued'`, and one slot flip under the lock in memory, so a worker claiming the row in the same instant either got it or did not.

```zig
if (!try jobs.cancel(c, row)) return nilo.fail.conflict("already going out", .{});
_ = try jobs.push(c, SendWelcome{ … }, .{ .after_ms = day });
```

A running row is not interrupted: nothing here reaches into a `run`, and a cancel answering `true` on a row half done would be the worse outcome, a mail half sent or an export half written with nobody told. `false` is the honest answer, and a caller who wants "stop it" writes the check into the job's own `run`, where the meaning of stopping is known. The `unique` key goes with the row, since it is deleted rather than marked, so a cancel and a push under the same key is how "move it to tomorrow" is written. It is optional on the store, the way `pushIn` and `ready` are: a `Jobs` over a store with no `cancel` refuses the call while compiling, naming the store, rather than faking a `false`. `job.Memory` and `job.Table` both carry it, and the `status` Space, when there is one, forgets a row a cancel removed.

### A run can commit with its `done`

**A `run` that takes `*Db.Tx` has its database writes and the row's `done` committed together, or neither: transactional completion.** Plain at-least-once has one hole for a job whose work is a write to the same database. `run` returns and `done` is a statement of its own, so a process that dies between the two writes twice when the lease runs out. `Db` is the type `job.Table(Db)` was built over, and `*Db.Tx` is recognised in a `run`'s argument list by its shape (a pointer to a struct that commits and rolls back), the way `Tick` is recognised by its type: it is not a dep and is never looked up in `.deps`. `job/` reaches the Db through the store type (`Table.Tx`, `Table.Database`), never an import.

The worker's path for such a kind, in `executeKind`:

1. **Begin inside the run's deadline.** `call` begins the transaction (`store.begin(scope)`, the Db's own `begin(scope, .{})`) on the worker's stack and passes `&tx` for the parameter, so the wait for a connection counts against `timeout_ms`, and a failure to begin is the run's failure.
2. **On success, `done` inside the transaction, then commit.** `store.doneIn(tx, scope, id, attempts, now)` is `done` under the same fence (`state = 'running' AND attempts = ?`). If it matches zero rows, the lease lapsed and a second worker holds the row, so the worker **rolls back** and logs at `warn` as `settled` does: the writes of the run that lost the claim never exist. If it matched, `tx.commit()`. Only then the bookkeeping that follows any `done` (`note`, and `pushNext` for a scheduled kind), outside the transaction.
3. **A failed run rolls back fully, then takes the existing paths unchanged.** `going`/`release` per [ADR 243](./243-a-run-cut-off-by-a-shutdown-goes-back-whatever-the-statement-said.md), `failedAttempt` with its fenced `retry`/`dead`, each a separate statement outside the transaction. The failure is never written inside the job's transaction: a statement that failed in Postgres has already aborted it, and one that has not would commit the run's partial writes with the error.
4. **A store error from `doneIn`, or a COMMIT that errors, is a failed attempt** through `failedAttempt`. If a COMMIT errored after it had landed (the connection dropped as the answer came back) the row is `done`, the fenced `retry` or `dead` matches nothing, and the worker logs it at `warn` and does no harm: the work was written once. A run that swallows a statement error leaves the transaction aborted in Postgres, and that is this path too.
5. **Cleanup stays under cancel protection.** The `doneIn`, the COMMIT and every rollback happen after `swapCancelProtection(.blocked)`, with the rest of what the worker writes about a row (ADR 243), and after `callTask` has returned, so a run cancelled by the timeout or the shutdown has stopped using the transaction before it is ended. A cancelled or timed-out run rolls back; one that returned success despite the cancellation commits, as it would have been recorded `done`. The `overlap = .queue` `unkey` and `pushNext`, and the `missed = .drop` path, happen before the run, outside any transaction, and are unchanged.

**What the promise is.** The job's writes to the queue's own database and its `done` commit together, or neither does. **It is not exactly once:** the run is still at least once, and an email or a payment call made inside it can happen twice if the process dies after the call and before the commit. For an effect outside the database the answer is an idempotency key of the caller's, and `Tick.id` is a stable one across retries and re-claims. A `pushIn(tx, …)` from the run queues the next job in the same transaction; a plain `push` from inside takes a second connection and commits at once.

**Refusals, while compiling** (`job/refusals/`):

- A `run` that takes a transaction on a store with no `begin` and `doneIn` (`job.Memory`) is refused naming the store, saying to test such a kind on SQLite, where `:memory:` is a database in the process. A transaction of a Db other than the store's is refused as well.
- A `run` that takes both `*Db.Tx` and `*Db`: the worker holds one connection for the transaction and a statement on the pool waits for another, so with every worker in that position the pool is empty and nobody finishes. `*Jobs` stays allowed, for `pushIn`.
- On SQLite, a transactional kind that does not declare its own `pub const timeout_ms`. SQLite has one writer ([ADR 065](./065-one-writer-is-not-a-setting-it-is-the-database.md)), `BEGIN IMMEDIATE` takes it, and the transaction then holds every write in the program (claims, other jobs, requests) for the run. How long is a number the kind's author writes, and the queue's default is not that number.

**At start, a queue with a transactional kind refuses to start** (`error.PoolTooSmall` from `nilo_start`, and from `serveOn`, which `serve` logs at `err` where the program is refusing to start) **when `workers` is not smaller than the Db's pool size** (`opts.size`, as `Table.poolSize` reports it). Each such run pins a connection from `begin` to the commit and a claim needs one too, so with every worker inside a run the rest cannot claim and none can write its `done`. On SQLite the pool is a writer and `size - 1` readers with a floor of two, and it is the one writer that limits a transactional kind, not the count: the same comparison is kept because it is one rule to learn, and `workers` above one buys no concurrency for such a kind.

### Where it sits

A Fitting, and the second one ([ADR 061](./061-a-fitting-borrows-the-loop.md)). It borrows the loop to wait on and owns no destination: the store is a type parameter. `job.Table(Db)` takes the caller's Db type and calls `insert`, `update` and `rawOne` on it, so `job/` imports `nilo_core` and nothing else, and `zig build layering` holds that. `job/live.zig` is the one root that names `nilo_sql`, for the reason `fetch/deadline.zig` names `nilo_http`: the thing it tests is the table, and only a database has one.

The entry condition is met the way `nilo_fetch` meets it: the worker loop is written against `std.Io` (`Group.concurrent`, `sleep`, `checkCancel`, and now `futexWaitTimeout`/`futexWake`), and `zig build test-job` runs it under `std.Io.Threaded` with `job.Memory` as its store and no Engine anywhere. Under the server the same loop runs on zio's `Io`, handed over in `nilo_start`, and `app.spawn(Jobs.serve, …)` is what starts it.

**`job.Memory` is a queue and not a cache**, and the difference is one line: a full `Memory` answers `error.QueueFull` and a full `nilo_cache` writes over the oldest entry. The first is right for a queue and the second for a cache, which is why `nilo_job` does not sit on `nilo_cache` for its rows. It *does* take a `cache.Space` for the two things that may be forgotten, a status for a route to poll and a `.within` window in front of a `unique` key, both duck-typed the way `nilo.Idempotent` takes its Space ([ADR 155](./155-a-request-answered-once-is-answered-the-same-way-again.md)), so `nilo_cache` is not an import either.

## What was rejected

**Redis as the store.** Two clients exist in Zig and both are alpha with no pub/sub. A queue over Redis cannot join the transaction that made the work, which is the bug the database-backed queues were written to close. A third store written against `job/contract.zig` is ten methods, the list there for whoever brings the deployment.

**A file of its own.** A queue in a file is a database with one table and none of the tooling; SQLite is that with the tooling.

**`nilo_cache` as the memory store.** A queue that forgets has lost somebody's email.

**Exactly-once.** It is at-least-once plus an idempotent `run`, everywhere, and a module claiming otherwise would be claiming something about the caller's mail provider. `nilo.Idempotent` is the same position on the inbound side. Transactional completion keeps it: it is a narrower promise about the writes in one database, and the word stays out of the docs.

**river's completion** (`JobCompleteTx`, [job_complete_tx.go at f1d9692](https://github.com/riverqueue/river/blob/f1d9692/job_complete_tx.go) and PR #1219). It marks the row done inside the caller's transaction, but fences on the state alone and commits even when the update matched nothing, so a worker whose lease lapsed and was re-claimed still commits its writes beside the second worker's: the case the fence exists for. Here a `done` that matches zero rows is a rollback, not a silent no-op.

**sqlxmq's "exactly-once"** ([README.md at 79cbd30](https://github.com/Diggsey/sqlxmq/blob/79cbd30/README.md#L52-L55)). The handler's writes and the delete of the message share a transaction, which is the same idea, but the delete is unfenced and the README calls the result exactly-once, a claim about the handler's every effect. Fenced here, and the word is refused.

**gue's failure committed in the job's transaction** ([job.go at 294381d](https://github.com/vgarvardt/gue/blob/294381d/job.go#L133-L160)). The handler's error is recorded in the same transaction as its partial writes and committed, so a failed job leaves half its work behind with the error beside it. A failed run here rolls back fully, and the failure is a separate statement outside the transaction.

**underway's savepoint variant** ([worker.rs at f00ebb1](https://github.com/maxcountryman/underway/blob/f00ebb1/src/worker.rs#L809-L888)). It runs the handler in a savepoint and records a failure in the same transaction after rolling back to it. The fenced completion, which this follows, is right; the failure written in the same transaction is not taken, because the transaction is the thing a failed statement has already poisoned on Postgres, and the extra savepoint is a round trip every transactional run pays for a case the plain path handles.

**Holding the row lock for the whole run, with no lease** (gue and neoq: one long transaction per job). The queue would depend on the connection staying up instead of on a lease, a crashed worker's row would stay locked until the server noticed the connection was gone, and one long transaction per job holds back vacuum. The lease with a fenced `done` keeps the claim a short statement of its own and the row's lock out of the run.

**Refusing it on SQLite outright.** SQLite is a production store here, and a job whose work is a write to the same file is the most common one. The cost is stated instead: the writer is held for the run, so the kind declares its `timeout_ms`.

**A `*Db` and a `*Db.Tx` in one `run`.** Allowed, with a warning in the docs, it deadlocks a full pool. Refused while compiling instead.

**A Service rather than a Fitting.** It holds no connection of its own; it is handed a store. Making it a Service would have made `job.Table` import `nilo_sql`, sideways, and the layering step would have refused it correctly.

**A single claimer handing rows to workers over a channel**, to take fifteen writers off the SQLite lock as well as fix the latency. The lock was never measured as a cost, and the wake is one atomic and one syscall against a redesign of the loop; the counter does not stand in the way of this if the lock ever shows up in a number.

**Idle backoff, doubling the sleep when a claim comes back empty, to a cap.** With a wake in place the poll is already the fallback for another process, and doubling it would make that process's rows slower to start on a quiet queue for no saving the default does not already give.

**`std.Io.Event`** for the wake. A boolean with a `reset` is a race between two workers, the second to wake finding it already reset or resetting it under the first; a counter has no reset.

**Waking inside `pushIn`.** The row is not visible until the caller's transaction commits, so the woken worker claims nothing and the real wake never comes.

**A type-erased `*job.Queue`** that any `run` could ask for, breaking the `.deps` loop without a function. It loses the check that a pushed kind is in `.kinds`, since the erased queue does not know its kinds, so a job could push a kind nobody listed and the row would sit in the table forever.

**Detecting the `.deps` struct shape and refusing it in nilo's own words.** `.deps = struct { jobs: *Jobs }` loops while the *argument* is being evaluated, before `Jobs(…)` runs a line, so there is nowhere for nilo to stand and say "write a function"; the message stays the compiler's.

**Running the deferred `.deps`-function checks in a container-level `comptime` block** inside the returned struct. Whether such a block is analysed as its own unit after the call returns, or inline while the type is being built (where it would loop), is a property of the compiler this repository has not measured, and a check whose timing is a guess may loop on the case it exists for.

**A `Settings` clock**, `fn () i64` read everywhere `nowMicros` was, for the test-time problem. It reaches `push` too, which `drainAt` does not need to; a push in a test can already say `.at`, and a clock on the queue is a clock the *store* does not share, since `Table.done` writes `finished_at` from the wall regardless. A parameter on the two calls a test makes was the whole of what the tests wanted.

**A `Tick` handed to every `run`**, as a third fixed parameter after the Run. Every existing `run` would change for a value most never read, and the argument-list rule this module borrowed from the server already says how a run asks for what it wants.

**Progress on the row.** A column written per call to `progress` is an `UPDATE` per call, and a run reporting every hundred rows would write the table as fast as it reads its input; the Space is a cache and may forget, the right promise for a progress bar, as the guide already says of `status`.

**A `cancelled` state**, rather than deleting the row. A fifth state to explain, a sweep to reap it, and a rule about whether a cancelled row still holds its `unique` key.

**Cancelling a running row**, by marking it and having the worker check between steps. The worker has no steps to check between, a `run` is one function, and a flag the job's own `run` reads is a flag the job can read from anywhere; nilo has nothing to add there.

**A required `cancel` on the store contract.** A third store, somebody's Redis, might genuinely have no way to delete a queued entry atomically against a claim, and a `cancel` that lied would be worse than one that refused.

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes:

| Axis | Cost |
|---|---|
| Allocations per request | None on a route that does not push. A route that does pays the JSON of the payload out of the request arena (the allocation it already has) and one `INSERT`, held by the existing test in `http/app.zig` that touches no route which pushes. `cancel` is one `DELETE` or one walk of the slots in memory, paid by the route that asks |
| Memory per idle connection | None. A worker is a fiber per process holding its stack at its high-water mark ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)): `workers = 4` is four of those plus whatever each `run` touches, paid once, with the Run each worker holds an arena reset per row. The wake counter is 4 bytes on the `Jobs`, not on a connection. A `Tick` is three words and a bool built on the worker's stack whether or not a `run` asks for it |
| Throughput and p99 | None on the request path. `job.Memory`'s claim takes `max_kind + max_payload` bytes (4,160 by default) from the tick's arena even when nothing is due, reset with the tick; the status `running` is one Space `put` per run. Off it: one claim per worker per `poll_ms` (354 µs of Postgres or 55 µs of SQLite a second per idle worker on the two-core box in [`bench/result/job.md`](../../bench/result/job.md), where `poll_ms = 1_000` comes from); one `fetchAdd` and one `futexWake` per `push`; one `comptime` branch in `Jobs(…)` for a `.deps` function, with `call` building the same argument tuple through the same lookup; one tag test on the `Clock` per read of it, three or four a tick; `progress` is one Space `get` and `put`, only when called |
| Binary size | Paid only by a program that imports it. `nilo_http` never names it. Not yet measured; the stripped `ReleaseFast` number owes its line in ADR 017's running total. Transactional completion is comptime: a program with no kind that takes a transaction compiles none of it (the slot is an empty struct, `checkPool` is a `return`) |

Transactional completion, against the same four, paid only by a kind that asks for it: **allocations per request**, none, since no request is involved and the worker's transaction lives on its stack and the tick's arena; **memory per idle connection**, none, since a worker is a fiber and a transaction lives only while its run does; **throughput and p99**, two more round trips (BEGIN and COMMIT) per transactional run and nothing on the request path, plus the pool connection held for the whole run; and on SQLite the one writer, held up to the kind's declared `timeout_ms`, so every other write in the program waits.

What a `.deps` function moves is where a Refusal arrives: for a queue whose `.deps` is a function, a `run` with the wrong second argument is reported at the first `open` rather than at the `job.Jobs(…)` line, with the compiler's "referenced by" trace pointing back. Every program calls `open`, so nothing ships unchecked.

## Consequences

- `job/` is a module with `job.Jobs`, `job.Memory`, `job.Table(Db)`, `job.Tick`, and the schedule types of [ADR 161](./161-a-schedule-is-a-type-that-makes-the-caller-choose.md).
- A row in `layers`, `shipped_roots` and `.paths`; `test-job` on `test`, `test-job-sql` on `test-sql`, `refusals-job`, `bench-job`.
- **Under `app.start(io)` followed by `listen()`, the workers run on the caller's `Io`**, the same as every Service's `nilo_start` under that order, and worse here because a worker sleeps: on `std.Io.Threaded` that is a thread held for `poll_ms`. `docs/todo.md` carries a worker started under `app.start(io)` and never `listen()`ed as a gap of its own (nobody stops it; there is no signal handler in this module).
- A `run` that takes the Db's transaction commits its writes with its `done`, in `job/job.zig` (`completeIn`) and `job/table.zig` (`begin`, `doneIn`); held by the transactional tests in `job/live.zig` on both databases, including a lease that lapses mid-run and a transaction that commits nothing, and by four rows in the job refusals table.
- A failure a `run` can mark as not worth retrying is [ADR 179](./179-a-run-can-say-its-failure-is-final.md); how urgently a row is claimed and what a worker will and will not take are [ADR 214](./214-a-job-says-how-urgent-it-is.md) and [ADR 215](./215-a-worker-claims-only-what-it-can-run.md).
