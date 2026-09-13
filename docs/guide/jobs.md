# Work that runs later, again, or on a schedule

`nilo_job` is for the four things an ordinary API does that are not
requests: send the welcome email after the user is created, try it again
when the mail provider is down, send the reminder tomorrow, and run the
report at three in the morning. A job is a struct of yours; the queue is a
table in the database you already have; a worker is a fiber the server owns
([ADR 0198](../adr/0198-a-queue-is-a-table-in-the-database-you-already-have.md)).

It is a **Fitting**, like `nilo_fetch`: it borrows the event loop and owns
no destination. The store is handed to it — a `job.Table` over your
`sql.Db`, or `job.Memory` for a test — so the module imports `nilo_core`
and nothing else, and a program with no queue in it links no worker loop.

**It is at least once.** A worker that dies halfway through a row leaves a
lease that runs out, and another worker takes the row. So `run` is written
to be safe to call twice, the way a webhook handler already is. That is the
one sentence on this page worth reading before the rest.

```zig
const job = @import("nilo_job");
```

and in `build.zig`, beside `nilo_http`:

```zig
.{ .name = "nilo_job", .module = nilo.module("nilo_job") },
```

## The whole of it

A job is a struct. Its fields are the payload, `retry` says what a failure
means, and `run` is the work:

```zig
const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .{
        .times = 5,
        .backoff = .{ .exponential = .{ .from_ms = 1_000, .to_ms = 3_600_000 } },
    };

    user_id: i64,
    email: Str,

    pub fn run(self: SendWelcome, scope: *nilo.Run, db: *Db) !void {
        const user = try db.find(User, scope, self.user_id) orelse return;
        try sendMail(scope, user.email, "Welcome");   // yours
    }
};
```

The queue is a type built from the jobs it can run, the store it runs on,
and the services a `run` may ask for:

```zig
const Jobs = job.Jobs(.{
    .kinds = .{ SendWelcome, Nightly },
    .store = job.Table(Db),
    .deps = struct { db: *Db },
});
```

In `main`, the table is migrated beside your own rows, and the queue is a
service and a fiber:

<!-- compiles: body -->
```zig
try sql.migrate.createMissing(db, &run, &.{ User, Jobs.Row });

table = job.Table(Db).open(db);
jobs = .open(gpa, &table, .{ .db = db }, .{ .workers = 4 });
try app.provide(&jobs);
try app.spawn(Jobs.serve, .{&jobs});
```

And in a handler, the push:

<!-- compiles -->
```zig
fn register(c: *nilo.Ctx, db: *Db, jobs: *Jobs, body: SignIn) !void {
    const user = try db.insert(User, c, .{ .email = body.email, .password = body.password });
    _ = try jobs.push(c, SendWelcome{ .user_id = user.id, .email = user.email }, .{});
}
```

`push` writes the struct as JSON into one row and returns the row's id. A
worker claims the row when it is due, parses the JSON back into a
`SendWelcome`, and calls `run` with a `nilo.Run` of the tick's own and
every pointer after it looked up in `deps` by type. `email` is a `Str`
borrowed from the request, and that is fine: it is copied at `push`, not
carried.

| | |
|---|---|
| `job.Jobs(.{ .kinds, .store, .deps, .status })` | the queue, as a type |
| `Jobs.open(gpa, &store, deps, settings)` | the value a handler holds |
| `Jobs.openWith(gpa, &store, deps, settings, space)` | the same, with the `.status` Space |
| `Jobs.Row` | the store's table, for `createMissing` and `db.checking` |
| `jobs.push(c, value, .{})` | `Id`, or `?Id` when `.unique` is given |
| `jobs.pushIn(&tx, c, value, .{})` | the same, inside a transaction you hold |
| `jobs.stats(c)` | how many are `queued`, `running` and `dead` |
| `jobs.status(id)` | `?job.Status` from the `.status` Space, when there is one |
| `jobs.deadOnes(c)` | the rows that failed for the last time, newest first |
| `jobs.retryDead(c, id)` | queue one of them again from its first attempt |
| `Jobs.serve` | the worker loop, for `app.spawn` |
| `jobs.serveOn(io)` | the same loop on an `Io` of yours, for a worker process |
| `jobs.drain(&run)` | run everything due, here, now — for a test |
| `jobs.runOne(&run)` | one row, or `false` |

## A job is a struct

Three things on it are read while compiling, and each one missing is a
Refusal that says what to write.

**`nilo_job` is the name the row carries.** Sixty-four bytes at most, unique
across the `kinds` — two jobs with one name is a compile error naming both
types — and it is what lets a binary that knows the kind claim a row a
different binary pushed. A row whose kind this program has no job for is
put back untouched, with a warning, for the program that does.

**`retry` has no default.** How many times an email is tried is a promise
about that email, and a default nobody read is not one
([ADR 0199](../adr/0199-a-schedule-is-a-type-that-makes-the-caller-choose.md)).

| | |
|---|---|
| `.none` | one attempt, and a failure is final |
| `.{ .times = 3 }` | four attempts in all, back to back |
| `.{ .times = 3, .backoff = .{ .fixed_ms = 30_000 } }` | thirty seconds between each |
| `.{ .times = 5, .backoff = .{ .exponential = .{ .from_ms = 1_000, .to_ms = 3_600_000 } } }` | 1s, 2s, 4s, … and never past an hour |

A row past its last retry is **dead**: it stays in the table with the name of
the error that killed it, `stats` counts it, `deadOnes` lists it, and
`retryDead` is the one way it runs again. Nothing is deleted for you.

**`run` takes the value, a `*nilo.Run`, and pointers.** The value is the
struct as it was pushed. The Run is the tick's Scope — an arena reset when
the tick ends, and the thing you hand to `db` and `fetch`. Every parameter
after those two is a pointer, found in `deps` by its type: `db: *Db` is
answered by the `db` field, and a pointer type nobody put in `deps` is a
compile error naming the job and the field to add. A `run` that asks for a
`*nilo.Ctx` is refused the same way, because a job runs outside any request
and a fail function would have nobody to fail to.

**A payload holds no pointer.** A `*T` field is a compile error naming
the field: the row is JSON read back on a worker, possibly in another
process, and an address means nothing there — carry the id and look it up
in `run`. Text is fine, as a `Str` or a `[]const u8`, and so are numbers,
enums, optionals, arrays, slices and structs of those; what comes back is
in the tick's arena. Every field of a *scheduled* job has a default,
because nobody pushes a scheduled job and so nobody fills one in.

**`timeout_ms` is optional**, per kind, and overrides the queue's:

```zig
pub const timeout_ms = 300_000;   // this report takes a while
```

Past it the run is cancelled, counted as a failed attempt named `TimedOut`,
and retried or dead by the job's `retry`. The longest `timeout_ms` across
the kinds is also the lease: a worker that dies holding a row gives it up
after that long, plus a second.

## Pushing

The last argument to `push` is the options, and `.{}` is the ordinary call:

| Field | |
|---|---|
| `after_ms` | run no sooner than this many milliseconds from now |
| `at` | run no sooner than this moment, in microseconds since the epoch. One of the two, not both |
| `unique` | a key of up to 64 bytes that at most one queued-or-running row of this kind may carry. The answer becomes `?Id`, null when a row already carries it |
| `within` | a `cache.Space` of `job.Mark` put in front of `unique`, for "at most one of these every thirty seconds" |

<!-- compiles -->
```zig
fn remind(c: *nilo.Ctx, jobs: *Jobs, user: User) !void {
    var key: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&key, "remind:{d}", .{user.id});

    // Tomorrow, and only once however many times this route is hit today.
    if (try jobs.push(c, SendWelcome{ .user_id = user.id, .email = user.email }, .{
        .after_ms = 24 * 60 * 60 * 1_000,
        .unique = name,
    })) |_| {} else {
        // already queued — nothing to do
    }
}
```

**`unique` is a unique index, not a check.** The table has a unique index
over `(kind, unique_key)`, and a row that finishes has its key set to NULL,
so "at most one queued or running" is the database's promise rather than a
read followed by a write. Ten servers pushing the same key at once get one
row between them.

**`.within` is the cheaper version of the same promise**, for when a miss
costs a second run and not a wrong one: the Space remembers the key for its
TTL, a second push inside the window is answered by the cache and never
reaches the table, and a restart forgets. A `.within` without a `.unique`
is a compile error, because the window has to remember something.

### In a transaction

The row is a row, so it can commit with yours:

<!-- compiles: body -->
```zig
var tx = try db.begin(c, .{});
defer tx.deinit();

const user = try tx.insert(User, c, .{ .email = form.email, .password = form.password });
_ = try jobs.pushIn(&tx, c, SendWelcome{ .user_id = user.id, .email = user.email }, .{});

try tx.commit();
```

If the commit fails, there is no job; if the job is pushed, the user exists.
That is the outbox pattern with no outbox, and it is the reason the queue is
a table rather than a Redis
([ADR 0198](../adr/0198-a-queue-is-a-table-in-the-database-you-already-have.md)).
`pushIn` on a `job.Memory` is a compile error — a row in memory has nothing
to commit with — and so is `pushIn` with `.within`, because a cache cannot
roll back.

## At least once

The claim is one statement, and the second half of its `WHERE` is the lease:

```sql
UPDATE nilo_jobs SET state = 'running', lease_until = $2, attempts = attempts + 1
WHERE id = (SELECT id FROM nilo_jobs
            WHERE (state = 'queued' AND run_at <= $1) OR (state = 'running' AND lease_until <= $1)
            ORDER BY run_at LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING …
```

A `running` row whose lease has passed is a row whose worker died — the
process was killed, the machine went — and it is taken again by whoever
asks next. `run` is therefore called *at least* once, and a `run` that has
already done its work the second time round is the design rather than a
bug to work around: an email keyed by `user_id` that the provider
deduplicates, an `insertOrIgnore` rather than an `insert`, an `UPDATE …
WHERE state = 'pending'`. `nilo.Idempotent` is the same position on the
inbound side ([Answering once](./idempotency.md)).

The queue never promises exactly once because it cannot: that would be a
claim about your mail provider.

## A schedule

A job with a `schedule` runs on the clock and nobody pushes it. It also has
to say two more things, and neither has a default
([ADR 0199](../adr/0199-a-schedule-is-a-type-that-makes-the-caller-choose.md)):

```zig
const Nightly = struct {
    pub const nilo_job = "nightly-report";
    pub const retry: job.Retry = .none;
    pub const schedule = job.cron("0 3 * * *");
    pub const overlap: job.Overlap = .skip;
    pub const missed: job.Missed = .drop;

    pub fn run(self: Nightly, scope: *nilo.Run, db: *Db) !void { … }
};
```

| | |
|---|---|
| `job.cron("0 3 * * *")` | `minute hour day month weekday`, UTC, parsed while compiling. `*`, lists, ranges and `*/n` |
| `job.every(600_000)` | every ten minutes from whenever the worker started, for when it does not matter which ten |

A field out of range, a sixth field or a backwards range is a compile error
naming the field. **UTC only**: a program in Jakarta writes `0 20 * * *`
with a comment, and `docs/roadmap.md` carries the gap.

**`overlap`** is what happens when the previous run is still running when
the next tick is due:

| | |
|---|---|
| `.skip` | do not start another. The tick that falls inside a run does not happen, and the next is computed from the clock when the run ends |
| `.queue` | start it anyway, on another worker |

**`missed`** is what happens to a tick whose time has passed — the process
was down, or every worker was busy:

| | |
|---|---|
| `.drop` | forget it. A tick that is later than its own successor is not run; one that is merely late is |
| `.catch_up` | run it once, then continue from the clock |

A schedule is a row: the next tick is pushed with the unique key
`"schedule"`, so ten instances seeding the same schedule at start-up produce
one row, and whichever worker claims it runs it. There is no leader, a
restart loses no tick, and **the first tick is the next one the clock
says** — `every(600_000)` first fires ten minutes after the worker started.
A program that wants a run at start-up pushes one.

A tick that fails is retried by the job's `retry` like any other row, and
the schedule's next tick is pushed regardless. A tick that dies is dead
like any other row.

## The store

**`job.Table(Db)`** is the queue in your database. `Db` is your `sql.Db`
or `sql.Sqlite(…)` type; the Row it carries is a `nilo_table` like yours,
named `nilo_jobs`, migrated beside your own with `createMissing` or the
`db` command, and checked by `db.checking(&.{ …, Jobs.Row })` at startup.
Both databases are production stores here. What differs on SQLite is that
every claim is a write, so `workers` is the number of claims in flight as
well as the number of jobs — four is right, forty is a queue for the
writer.

**`job.Memory`** is the same contract in this process, for a test or for a
program that can lose its queue at a restart and says so:

```zig
var store = try job.Memory.open(gpa, .{ .bytes = 1 << 20 });
defer store.deinit();
```

It is a queue and not a cache: a full `Memory` answers `error.QueueFull`
rather than writing over the oldest row, which is why the module does not
sit on `nilo_cache`. `.max_payload` (4 KiB) is the largest row it holds.

**`Settings`**, given to `open`:

| Field | Default | |
|---|---|---|
| `workers` | 4 | rows running at once in this process. Each is a fiber, and a fiber holds its stack at its high-water mark for the life of it ([ADR 0063](../adr/0063-a-handlers-stack-is-per-connection.md)), so this is paid per worker rather than per row |
| `poll_ms` | 1,000 | how long a worker with nothing to do waits before asking again. One claim per worker per interval: the cost of an idle queue, and the latency of a pushed row when every worker is asleep |
| `timeout_ms` | 60,000 | how long one run may take, for a kind that names no `timeout_ms` of its own. Also the lease |

A third store is nine methods, listed in `job/contract.zig` for whoever
brings the deployment.

## Watching it

**`stats`** is the three counts, and a health page that wants to know the
queue is not backing up reads `queued` there. **`nilo_ready`** is what
[`app.health`](./deploying.md#knowing-whether-it-is-ready) asks:
not ready before `listen()`, not ready when the store says so, and not
ready when `serve` has been started and no worker is alive.

**A status a route can poll** is a `cache.Space` of `job.Status` named on
the type and handed in at `openWith`:

```zig
const Statuses = cache.Space("job-status", job.Status, .{ .ttl_s = 600 });

const Jobs = job.Jobs(.{
    .kinds = .{SendWelcome},
    .store = job.Table(Db),
    .deps = struct { db: *Db },
    .status = Statuses,
});

jobs = .openWith(gpa, &table, .{ .db = &db }, .{}, Statuses.open(&store));
```

`jobs.status(id)` then answers `.{ .state, .attempts }` for as long as the
Space remembers the row — `queued`, `running`, `done` or `dead` — and null
once it has forgotten, which for a route answering "is my export ready?"
is the right shape. It is a cache and not the table on purpose: a status is
the one thing here that may be forgotten, and a poll every second should
not be a query every second.

**The dead ones** are listed newest first with the error's name, and
`retryDead` puts one back at attempt one. An operator's route:

<!-- compiles -->
```zig
fn dead(c: *nilo.Ctx, jobs: *Jobs) ![]job.Dead {
    return jobs.deadOnes(c);
}

fn retry(c: *nilo.Ctx, jobs: *Jobs, row: u64) !void {
    if (!try jobs.retryDead(c, row)) return nilo.fail.notFound("no dead job {d}", .{row});
}
```

**The log** carries every failure as a `warn` with the kind, the row, the
error's name, the attempt and the wait before the next; a row that dies
says so with its attempt count; a claim that cannot reach the store is an
`err`, and the worker sleeps `poll_ms` and asks again.

## A worker with no server in it

`serve` runs the workers on the `Io` the server handed over in
`nilo_start`, and stops when the server does — `error.Canceled` is the
shutdown, as it is for every fiber
([Work that is not a request](./background.md)). A worker process that
serves no HTTP calls `serveOn` with an `Io` of its own instead:

```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();

try db.nilo_start(threaded.io(), .off);
try jobs.nilo_start(threaded.io(), .off);
try jobs.serveOn(threaded.io());   // returns when cancelled
```

Cancelling it is yours: there is no signal handler here, because the one in
`nilo_http` belongs to the server.

## Testing

A queue over `job.Memory` needs no database, no server and no `Io`, and
`drain` runs everything due on the thread it is called from. A job that
takes a `*Db` still needs one, and a SQLite file in memory is the one
`nilo_sql`'s own tests use:

```zig
test "signing up queues a welcome, and the welcome finds the user" {
    var store = try job.Memory.open(testing.allocator, .{ .bytes = 1 << 20 });
    defer store.deinit();
    var jobs: Jobs = .open(testing.allocator, &store, .{ .db = &db }, .{});

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();

    _ = try jobs.push(&run, SendWelcome{ .user_id = 7, .email = .static("a@b.c") }, .{});
    try testing.expectEqual(@as(usize, 1), try jobs.drain(&run));
    try testing.expectEqual(@as(u64, 0), (try jobs.stats(&run)).queued);
}
```

`drain` and `runOne` take a `*nilo.Run` and refuse a `*Ctx` while
compiling: a job that ran under a request would be a job that could call a
fail function.

## What it costs

Against [ADR 0018](../adr/0018-the-trade-budget-has-three-axes.md)'s axes,
with the numbers in [`bench/result/job.md`](../../bench/result/job.md):

**Per request, nothing on a route that does not push.** A route that does
pays the JSON of the payload out of the request arena — the one allocation
it already has — and one `INSERT`: 10 µs on SQLite, 0.9 ms on Postgres
across a Docker port.

**Per idle worker, one claim per `poll_ms`**: 55 µs of SQLite or 354 µs of
Postgres a second, which is 0.035% of one connection and where the default
comes from. A claim that takes a row is 140 µs and 1.2 ms.

**Per connection, nothing.** A worker is a fiber per process, and its stack
is paid once and held at the high-water mark of whatever `run` touches.

## What it will not do

Not a priority queue: rows come out in `run_at` order and nothing else. Not
a workflow engine, not a rate limiter for a kind — `nilo.Gate` inside `run`
is that — and not exactly once. Not a time zone. Each of those is in
[`docs/roadmap.md`](../roadmap.md#nilo_job-work-that-runs-later-again-or-on-a-schedule)
with what it is waiting for.

## See also

- [The reference](../reference.md#nilo_job) — the surface as a list.
- [Work that is not a request](./background.md) — the fiber underneath,
  for work that is a loop rather than a row.
- [Transactions](./sql/transactions.md) — what `pushIn` joins.
- [A cache in this process](./cache.md) — the Space a status lives in.
- [ADR 0198](../adr/0198-a-queue-is-a-table-in-the-database-you-already-have.md)
  — why a table and not a Redis; [ADR 0199](../adr/0199-a-schedule-is-a-type-that-makes-the-caller-choose.md)
  — why `overlap` and `missed` have no default.
