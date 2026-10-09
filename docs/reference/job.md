# nilo_job

**`nilo_job` runs work later, again, or on a schedule, from a queue stored as a table in the database you already have.**

**Guide:** [Work that runs later, again, or on a schedule](../guide/jobs.md) · **Design:** [Jobs](../design/job.md)

## `nilo_job`

Work that runs later, again, or on a schedule: a queue whose rows live in a table in the database the program already has, and a worker loop the server owns. Like `nilo_fetch`, it is a **Fitting**: it borrows the event loop and is handed its store ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)). Delivery is **at least once**, so write `run` to be safe to call twice; the one exception to repeat work is a `run` that takes the Db's transaction, whose database writes commit with its `done`.

```zig
const job = @import("nilo_job");

const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .{ .times = 5, .backoff = .{ .exponential = .{ .from_ms = 1_000, .to_ms = 3_600_000 } } };

    user_id: i64,
    email: Str,

    pub fn run(self: SendWelcome, scope: *nilo.Run, db: *Db) !void { … }
};

const Jobs = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Table(Db), .deps = struct { db: *Db } });

try sql.migrate.createMissing(&db, &run, .{ .tables = &.{ User, Jobs.Row } });
var table = job.Table(Db).open(&db);
var jobs: Jobs = .open(gpa, &table, .{ .db = &db }, .{});
try app.provide(&jobs);
try app.spawn(Jobs.serve, .{&jobs});

fn register(c: *nilo.Ctx, jobs: *Jobs, body: SignIn) !void {
    _ = try jobs.push(c, SendWelcome{ .user_id = 7, .email = body.email }, .{});
}
```

### Job declarations

**A job is a struct.** Its fields are the payload: written as JSON at `push`, and parsed back into the tick's own `Run`. A `Str` may be a field, because it is copied, not carried. These declarations are read while compiling:

| | |
|---|---|
| `pub const nilo_job = "…"` | the name stored in the row. Required; at most 64 bytes; unique across the `kinds` |
| `pub const retry: job.Retry` | required, no default: `.none`, or `.{ .times, .backoff }` with `.{ .fixed_ms }` or `.{ .exponential = .{ .from_ms, .to_ms, .jitter } }`, `.jitter` being `.none` (the default), `.full` or `.equal`. `job.Backoff` and `job.Jitter` are `nilo_core`'s ([ADR 271](../adr/271-a-retry-is-the-callers-numbers-and-nilos-mechanism.md)); `job.Retry.delayMs(failed)` is the un-jittered ceiling and `jitteredMs(failed, random)` what a worker schedules by |
| `pub fn run(self, scope: *nilo.Run, …) !void` | the work: the job by value, the Run, then any service by pointer, looked up in `.deps` by type, and `tick: job.Tick` by value if it wants to know which tick it is ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)) |
| `pub const final = error{ … }` | optional: the failures that are **final**. A `run` failing with one of these is dead on that attempt whatever `retry` says, and the row keeps the error's name; a timeout is never final. A Refusal on a kind whose `retry` is `.none` ([ADR 179](../adr/179-a-run-can-say-its-failure-is-final.md)) |
| `pub const timeout_ms` | optional, overrides the queue's. Also the lease. **Required on SQLite for a kind whose `run` takes a transaction**, because there it is how long the one writer is held ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)) |
| `pub const priority: job.Priority` | optional: `.high`, `.normal` (the default) or `.low`. A free worker takes the most urgent **due** row, and among equals the one that has been due longest ([ADR 214](../adr/214-a-job-says-how-urgent-it-is.md)). A number here is a Refusal naming the three levels |
| `pub const schedule`, `overlap`, `missed`, and in a time zone `skipped` and `repeated` | for a job that runs on the clock: see [Schedules](#schedules-jobcron-and-jobevery) |

**A `run` that takes the Db's transaction, `tx: *Db.Tx`, commits its writes and the row's `done` together, or neither** (transactional completion, [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)). `Db` is the type the queue's `job.Table(Db)` was built over; a `*Db.Tx` is not looked up in `.deps`. The worker begins the transaction, calls `run`, writes `done` inside it under the claim's fence, and commits; a `done` that matches nothing (the lease lapsed and another worker holds the row) rolls back, and a failed run rolls back before its failure is recorded outside the transaction as usual. The run itself is still at least once. A transaction pins a connection for the whole run. Refused while compiling: a transaction on `job.Memory`, a transaction of another Db, a `run` that takes both `*Db.Tx` and `*Db`, and on SQLite a kind with no `timeout_ms` of its own. A queue with such a kind refuses to start (`error.PoolTooSmall` from `nilo_start` and `serveOn`) when `workers` is not smaller than the Db's `size`. `jobs.pushIn(tx, scope, …)` from inside it queues a job that commits with the run.

A field that is a `*T` is a Refusal naming the field. A `run` that asks for a `*Ctx`, a `*job.Tick`, or a pointer type nobody put in `.deps` is a Refusal naming the job.

### `job.Tick`

What a `run` that asks for one receives:

| Field | |
|---|---|
| `id` | the row's id, for `jobs.progress` and `jobs.status` |
| `attempts` | including this one: `1` the first time |
| `run_at` | when the row was due, in microseconds since the epoch |
| `last` | whether this is the last attempt `retry` allows. This is about the count only: a failure in `final` is dead on any attempt |

### `job.Jobs(.{ … })`

| | |
|---|---|
| `.kinds` | a tuple of job types. Pushing a job that is not listed is a Refusal |
| `.store` | `job.Table(Db)`, `job.Memory`, or anything that implements the contract in `job/contract.zig` |
| `.deps` | optional: a struct of pointers a `run` may ask for by type, or a `fn (comptime Jobs: type) type` that returns one, for a `run` that asks for `*Jobs` to push the next job ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)). A function of any other shape is a Refusal |
| `.status` | optional: a `cache.Space` of `job.Status` kept per row, for a route to poll |

### `Jobs` calls

| | |
|---|---|
| `Jobs.open(gpa, &store, deps, settings)` | the queue. Use `openWith(…, space)` when `.status` names a Space. When `.deps` names `*Jobs`, open it once it has an address: `var jobs: Jobs = undefined; jobs = .open(…, .{ .jobs = &jobs, … }, .{})` |
| `Jobs.Deps` | the struct of pointers `open` takes: `.deps` as written, or what `.deps(Jobs)` returned |
| `Jobs.Row` | the store's table, for `createMissing` and `db.checking`; `void` for `job.Memory` |
| `jobs.push(c, value, opts)` | `!Id`, or `!?Id` when `opts` has `.unique`: null when a row already has the key. A `.unique` that is empty is `error.EmptyUniqueKey` on both stores, and a Refusal when it is written as `""` |
| `jobs.pushIn(&tx, c, value, opts)` | the same inside a transaction you hold. A Refusal on `job.Memory`, and with `.within`. It wakes no worker, because the row does not exist until the commit, so call `wake` after committing. It notes nothing in the `status` Space either, because the Space cannot roll back with the transaction: a row pushed here has no status until a worker takes it |
| `jobs.wake()` | wakes every idle worker, for a row nilo did not see arrive: another process's, or one `pushIn` wrote in a transaction that has since committed. A `push` wakes one worker by itself ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)) |
| `jobs.stats(c)` | `Stats`: `queued`, `running`, `dead` |
| `jobs.status(id)` | `?job.Status`: `state`, `attempts` and `progress`, from the Space, for as long as it remembers. `running` from the moment a worker has the row and its payload reads. The Space is per instance |
| `jobs.progress(id, n)` | writes `n` into the Space's `progress` for the row, from inside a `run` that has a `job.Tick` and a `*Jobs`. Reset by every change of state except `done`, which keeps it. Does nothing without a Space ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)) |
| `jobs.cancel(c, id)` | `bool`: deletes a `queued` row before it runs, along with its `unique` key; `false` when the row is running, finished or absent. It is one statement, so a claim at the same instant either wins or loses completely. A Refusal on a store with no `cancel` ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)) |
| `jobs.deadOnes(c)` | `[]Dead`: `id`, `kind`, `attempts`, `err`, newest first |
| `jobs.retryDead(c, id)` | `bool`: queued again from attempt one; `false` when there is no dead row with that id. **`error.Scheduled` when the row is of a kind with a `schedule`**, and nothing changes: its successor tick is already queued, so reviving it would run the kind on two chains for good. **The revived row runs without its unique key**, which was cleared when it died, so a newer row pushed under the same key can run beside it; a caller who needs the guarantee checks before reviving ([`decided.md`](../decided.md)). A store called directly takes the scheduled kinds as a fourth argument, which `jobs.retryDead` fills in |
| `Jobs.serve(&jobs)` | the worker loop, for `app.spawn`. Stops with the server |
| `jobs.serveOn(io)` | the same on an `Io` of your own, for a worker process. Returns when cancelled |
| `jobs.drain(&run)` / `jobs.runOne(&run)` | runs what is due on this thread, for a test, against one reading of the clock. A `*Ctx` is refused |
| `jobs.drainAt(&run, now)` / `jobs.runOneAt(&run, now)` | the same as if the time were `now`, in microseconds since the epoch: what is due, when a retry is, and when the next tick is all use that number. This is how a test moves the clock ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)) |
| `jobs.seed(&run)` / `jobs.seedAt(&run, now)` | queues every schedule's next tick, the way `serve` does at start, for a test that drains instead of serving. Idempotent, and called again by every worker (and by `drain`) once a minute after the first seed, so a schedule whose row was lost is queued again within the minute ([ADR 161](../adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md)) |
| `jobs.nilo_ready(scope)` | what `app.health` asks: whether the store is reachable and a worker is alive |

### Push options

`.{}` is the ordinary call:

| Field | |
|---|---|
| `after_ms` | no sooner than this many milliseconds from now |
| `at` | no sooner than this moment, in microseconds since the epoch. Not together with `after_ms` |
| `unique` | at most one queued or running row of this kind has the key. A unique index, freed when the row finishes. Never empty: an empty key is a value that went missing, and every such push would fold into the first |
| `within` | a `cache.Space` of `job.Mark` checked before `unique`: a second push within the Space's TTL never reaches the table. Needs `unique`, and a type with a `del`: a push the store refuses deletes the key again |

### `job.Settings`

Given to `open`:

| Field | Default | |
|---|---|---|
| `workers` | 4 | rows running at once in this process. Each is a fiber, with its stack held at its high-water mark ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)) |
| `poll_ms` | 1,000 | how long an idle worker waits before checking again **when nothing wakes it first**. A `push` from this process wakes a worker, so this is only the latency for a row another process pushed, and the cost of an idle queue: one claim per worker per interval ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)) |
| `timeout_ms` | 60,000 | how long one run may take, for a kind that sets no `timeout_ms`. Also the lease |

### Schedules: `job.cron` and `job.every`

([ADR 161](../adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md))

| | |
|---|---|
| `pub const schedule = job.cron("0 3 * * *")` | `minute hour day month weekday`, UTC unless `.in` names a zone, parsed while compiling. Supports `*`, lists, ranges and `*/n`; a field out of range, or a day and month that never meet, is a Refusal naming it. When either day field starts with `*`, a day must match both |
| `pub const schedule = job.cron("0 3 * * *").in("Asia/Jakarta")` | the same fields read on the wall clock of an IANA zone, spelled as IANA does and case sensitive. A comptime method: a name nobody has data for (the right case is offered if there is one), a second `.in`, and `.in` on `job.every` are Refusals. `Tick.run_at` and every stored time stay UTC. The data for the zones a program names is compiled in (about 150 bytes each), and nothing is read at run time |
| `pub const schedule = job.every(600_000)` | at a fixed interval in milliseconds, counted from when the worker started. Read while compiling: `0` (a tick always due, a worker never resting) and a period over `job.max_every_ms`, a hundred years (a mistake in the unit), are Refusals |
| `pub const overlap: job.Overlap` | required: `.skip` (a tick during a run does not happen) or `.queue` (it runs on another worker) |
| `pub const missed: job.Missed` | required: `.drop` (a tick that is later than its own successor is forgotten) or `.catch_up` (it runs once) |
| `pub const skipped: job.Skipped` | required of a fixed-time schedule in a zone that can meet an hour the clock skips: `.run_late` (the wall time is read with the offset from before the gap, so 02:30 runs at 03:30) or `.skip` (no tick that night; not a `missed` one) |
| `pub const repeated: job.Repeated` | required of a fixed-time schedule in a zone that can meet an hour the clock reads twice: `.first`, `.second` or `.both` passes |

**Which schedules declare `skipped` and `repeated`.** One whose hour field is exactly `*` (`*/15 * * * *`, `30 * * * *`) is an interval: a wall time inside a skipped hour has no tick, a repeated hour ticks on both passes, and nothing is declared. Every other schedule in a zone (`0 2 * * *`, `0 9,17 * * *`, `0 */2 * * *`) is a fixed time, and declares only if its minute, hour and month sets can meet a window that zone skips or repeats after the data's cut-off, worked out while compiling from the zone's own transitions: `0 3 * * *` in Berlin needs neither, `0 0 * * *` in Cairo needs `skipped`, `30 2 * * *` in Lord Howe needs neither, and Asia/Jakarta never asks. A declaration that is not needed is accepted. Ticks come out strictly increasing in real time.

`job.tzdata_version` is the IANA release the zone data was compiled from. `zig build tzdata-check -Dnetwork` fails when a newer one is out. `-Dtzdata=<dir>` builds `nilo_job` against the directory `python3 -I job/tzdata/refresh.py --out <dir>` wrote, for a rule change that cannot wait for a release.

The next tick is a row with the unique key `"schedule"`, so several instances seed one row and whichever claims it runs it. The first tick is the next one the clock gives; a program that wants one at start-up pushes it. Every field of a scheduled job needs a default, since nobody pushes it. Every worker seeds again once a minute, so a schedule whose row was lost (a crash between `done` and the push, a failed push, a `cancel`) is queued again within the minute.

### Stores: `job.Table` and `job.Memory`

| | |
|---|---|
| `job.Table(Db)` | the queue as a `nilo_table` Row named `nilo_jobs`, over your `sql.Db` or `sql.Sqlite(…)`. `open(&db)`. Claims with `FOR UPDATE SKIP LOCKED` on Postgres, and without it on SQLite, where a claim is a write and `workers` is the number of writers. The claim asks only for the kinds this program runs (`kind IN (…)`), so a row another binary pushed under a kind you do not declare stays queued for the binary that does ([ADR 215](../adr/215-a-worker-claims-only-what-it-can-run.md)) |
| `table.sweep(c, before)` | deletes `done` rows that finished before a moment. Nothing calls it for you |
| `table.sweepDead(c, before)` | deletes dead rows that died before a moment, and returns how many went. Separate from `sweep` because a dead row is the record of a failure. `job.Memory` has the same method, which also frees the slots a long run of failures would otherwise fill |
| `table.begin(c)`, `table.doneIn(tx, c, id, attempts, now)` | what transactional completion is made of: the Db's `begin`, and `done` written in that transaction under the same fence. A `Jobs` calls them; a store of your own that can join a transaction carries them with a `Tx` type |
| `job.Memory` | the same contract, inside this process. `open(gpa, .{ .bytes, .max_payload = 4096 })`; when full, a push returns `error.QueueFull` and never writes over a row |

### Errors

**A `run` that fails is retried according to its `retry`, and is then dead**: kept in the table with the error's name, counted by `stats`, and listed by `deadOnes`. A `run` that goes past `timeout_ms` is an attempt that failed with `TimedOut`. A shutdown that cuts a `run` off puts the row back untouched, and whichever worker starts next takes it; an `error.Canceled` that `run` returns without a shutdown, from a child future it cancelled itself, is an ordinary failure. A payload this binary cannot parse is dead at once; one that could not be read for want of memory is retried like a failed `run`. A row whose kind this binary has no job for is put back, with a warning, for the binary that does.

[`docs/guide/jobs.md`](../guide/jobs.md) covers all of it, and [`bench/result/job.md`](../../bench/result/job.md) has what a claim and a push cost on each store.

### What it does not do

**Not included:** a priority queue with numbers (a kind has one of three `priority` levels, and a push cannot override it: [ADR 214](../adr/214-a-job-says-how-urgent-it-is.md)), a workflow engine, a rate limiter per kind (use `nilo.Gate` inside `run` for that), exactly-once delivery (a transactional `run` commits its database writes with its `done`, and does nothing for an effect outside the database), or time zones.
