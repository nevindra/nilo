# Work that runs later, again, or on a schedule

**`nilo_job` runs work outside a request (later, again after a failure, or on a schedule), and its queue is a table in the database you already have.**

**Reference:** [`nilo_job`](../reference/job.md#nilo_job) · **Design:** [Jobs](../design/job.md)

`nilo_job` is for the four things an ordinary API does that are not requests: send the welcome email after the user is created, try again when the mail provider is down, send the reminder tomorrow, and run the report at three in the morning. A job is a struct of yours; the queue is a table in the database you already have; a worker is a fiber the server owns ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).

It is a **Fitting**, like `nilo_fetch`: it borrows the event loop and owns no destination. The store is handed to it (a `job.Table` over your `sql.Db`, or `job.Memory` for a test), so the module imports `nilo_core` and nothing else, and a program with no queue in it links no worker loop.

**It runs a job at least once, so write `run` to be safe to call twice.** A worker that dies halfway through a row leaves a lease that runs out, and another worker takes the row. So `run` must be safe to call twice, the way a webhook handler already is. If you read one sentence on this page before the rest, read this one.

```zig
const job = @import("nilo_job");
```

and in `build.zig`, beside `nilo_http`:

```zig
.{ .name = "nilo_job", .module = nilo.module("nilo_job") },
```

## A complete example

**A job is a struct: its fields are the payload, `retry` says what a failure means, and `run` is the work.**

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

The queue is a type built from the jobs it can run, the store it runs on, and the services a `run` may ask for:

```zig
const Jobs = job.Jobs(.{
    .kinds = .{ SendWelcome, Nightly },
    .store = job.Table(Db),
    .deps = struct { db: *Db },
});
```

In `main`, the table is migrated alongside your own tables, and the queue is registered as a service and started as a fiber:

<!-- compiles: body -->
```zig
try sql.migrate.createMissing(db, &run, .{ .tables = &.{ User, Jobs.Row } });

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

`push` writes the struct as JSON into one row and returns the row's id. When the row is due, a worker claims it, parses the JSON back into a `SendWelcome`, and calls `run` with a `nilo.Run` belonging to that tick, plus every later pointer argument looked up in `deps` by type. `email` is a `Str` borrowed from the request, and that is fine: it is copied at `push`, not carried.

| | |
|---|---|
| `job.Jobs(.{ .kinds, .store, .deps, .status })` | the queue, as a type |
| `Jobs.open(gpa, &store, deps, settings)` | the value a handler holds |
| `Jobs.openWith(gpa, &store, deps, settings, space)` | the same, with the `.status` Space |
| `Jobs.Row` | the store's table, for `createMissing` and `db.checking` |
| `jobs.push(c, value, .{})` | `Id`, or `?Id` when `.unique` is given |
| `jobs.pushIn(&tx, c, value, .{})` | the same, inside a transaction you hold |
| `jobs.cancel(c, id)` | `bool`: a `queued` row removed before it runs; false once a worker holds it |
| `jobs.stats(c)` | how many are `queued`, `running` and `dead` |
| `jobs.status(id)` | `?job.Status` from the `.status` Space, when there is one |
| `jobs.progress(id, n)` | how far a run has got, stored in the same Space |
| `jobs.deadOnes(c)` | the rows that failed for the last time, newest first |
| `jobs.retryDead(c, id)` | queue one of them again from its first attempt |
| `Jobs.serve` | the worker loop, for `app.spawn` |
| `jobs.serveOn(io)` | the same loop on an `Io` of yours, for a worker process |
| `jobs.drain(&run)` | run everything due, here and now, for a test |
| `jobs.drainAt(&run, now)` | the same, as if it were `now`; this is how a test moves the clock |
| `jobs.runOne(&run)` / `runOneAt(&run, now)` | one row, or `false` |
| `jobs.seed(&run)` / `seedAt(&run, now)` | queue every schedule's next tick, for a test that drains |

## Defining a job

**Three declarations on a job are read while compiling, and a missing one is a Refusal that tells you what to write.**

**`nilo_job` is the name the row carries.** It is at most sixty-four bytes and must be unique across the `kinds`: two jobs with one name is a compile error naming both types. The name lets a binary that knows the kind claim a row that a different binary pushed. A row whose kind this program has no job for is put back untouched, with a warning, for the program that does.

**`retry` has no default.** How many times an email is tried is a promise about that email, and a default nobody read is not a promise ([ADR 161](../adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md)).

| | |
|---|---|
| `.none` | one attempt, and a failure is final |
| `.{ .times = 3 }` | four attempts in all, back to back |
| `.{ .times = 3, .backoff = .{ .fixed_ms = 30_000 } }` | thirty seconds between each |
| `.{ .times = 5, .backoff = .{ .exponential = .{ .from_ms = 1_000, .to_ms = 3_600_000 } } }` | 1s, 2s, 4s, … and never more than an hour |

**A hundred rows that failed together should not come back together.** A downstream outage fails every row that touches it at once, and a wait that is the same for all of them retries all of them at the same instant, and again at the next doubling, for as long as the outage lasts. An exponential backoff takes a jitter: `.{ .exponential = .{ .from_ms = 1_000, .to_ms = 3_600_000, .jitter = .full } }` waits anywhere from none to the doubled time, evenly, and `.equal` waits between half and the whole. The default is `.none`, which waits exactly what the table says, so a kind written before the option existed behaves as it did. A `.fixed_ms` takes none, being a promise: to spread a fixed wait, give `.exponential` the same `from_ms` and `to_ms`. The `Backoff` is `nilo_core`'s, the same one `nilo_fetch`'s [retry](./fetch.md#retrying) waits by ([ADR 271](../adr/271-a-retry-is-the-callers-numbers-and-nilos-mechanism.md)), and `job.Backoff` is that type.

An exponential backoff with `.from_ms = 0` is a compile error: doubling zero is zero, so it would be `.fixed_ms = 0` in a shape that looks like a growing wait.

A row past its last retry is **dead**: it stays in the table with the name of the error that killed it, `stats` counts it, `deadOnes` lists it, and `retryDead` is the only way to run it again. Nothing is deleted for you: `sweepDead(c, before)` on the store (`job.Table` and `job.Memory` both have it) deletes the dead rows older than a moment, from a scheduled job of your own, and on `job.Memory` it is what stops a long run of failures filling every slot and answering `QueueFull`.

**Some failures should be final on the first attempt.** A reset socket or a 429 may succeed ten seconds later; a 4xx saying *invalid from address* will be the same 4xx in an hour, yet both come back through the same error set. `final` is the error set that makes a `run` dead at once, whatever `retry` says ([ADR 179](../adr/179-a-run-can-say-its-failure-is-final.md)):

```zig
pub const retry: job.Retry = .{ .times = 5, .backoff = .{ .exponential = .{ .from_ms = 10_000, .to_ms = 3_600_000 } } };
pub const final = error{ Rejected, NoSuchAddress };
```

The row keeps the error's own name, so `deadOnes` says `Rejected`, not a generic queue word. A timeout is never final, because the next attempt may finish. On a kind whose `retry` is `.none` the set would change nothing, so it is refused.

**`run` takes the value, a `*nilo.Run`, and pointers.** The value is the struct as it was pushed. The Run is the tick's Scope: an arena reset when the tick ends, and what you pass to `db` and `fetch`. Every parameter after those two is a pointer, found in `deps` by its type: `db: *Db` is filled from the `db` field, and a pointer type nobody put in `deps` is a compile error naming the job and the field to add. A `run` that asks for a `*nilo.Ctx` is refused the same way, because a job runs outside any request and a fail function would have nobody to fail to.

**A `run` can also take a `job.Tick`, by value, to know which tick it is.** The rule is the same one a handler's argument list follows: a pointer is a service, a value is the tick. It carries the row's `id`, which attempt this is (`attempts`, `1` the first time), when the row was due (`run_at`), and whether this is the last attempt `retry` allows (`last`). The worker already has all of it from the claim, so asking costs nothing ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)):

```zig
pub fn run(self: SendWelcome, scope: *nilo.Run, tick: job.Tick, mail: *Mailer) !void {
    const via = if (tick.last) mail.fallback else mail.primary;
    std.log.info("welcome row {d}, attempt {d}", .{ tick.id, tick.attempts });
    try via.send(scope, self.email, "Welcome");
}
```

`last` is about the count only: a failure the kind lists in `final` is dead on whichever attempt it happens, and the tick cannot know which error is coming. A `*job.Tick` is refused, with a message naming the rule.

**A payload holds no pointers.** A `*T` field is a compile error naming the field: the row is JSON read back on a worker, possibly in another process, where an address means nothing. Carry the id and look it up in `run`. Text is fine, as a `Str` or a `[]const u8`, and so are numbers, enums, optionals, arrays, slices and structs of those; what comes back lives in the tick's arena. Every field of a *scheduled* job needs a default, because nobody pushes a scheduled job, so nobody fills the fields in.

**`timeout_ms` is optional**, per kind, and overrides the queue's:

```zig
pub const timeout_ms = 300_000;   // this report takes a while
```

Past it the run is cancelled, counted as a failed attempt named `TimedOut`, and retried or marked dead according to the job's `retry`. The longest of the queue's `timeout_ms` and each kind's own is also the lease: a worker that dies holding a row gives it up after that long, plus a second.

## Pushing a job

**The last argument to `push` is the options, and `.{}` is the ordinary call.**

| Field | |
|---|---|
| `after_ms` | run no sooner than this many milliseconds from now |
| `at` | run no sooner than this moment, in microseconds since the epoch. Use one of the two, not both |
| `unique` | a key of up to 64 bytes that at most one queued-or-running row of this kind may carry. The result becomes `?Id`, null when a row already carries the key. Never empty: `.unique = ""` is a compile error and an empty key built at run time is `error.EmptyUniqueKey`, because it is nearly always a value that went missing |
| `within` | a `cache.Space` of `job.Mark` checked before `unique`, for "at most one of these every thirty seconds" |

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

**`unique` is enforced by a unique index, not by a check.** The table has a unique index over `(kind, unique_key)`, and a row that finishes has its key set to NULL, so "at most one queued or running" is guaranteed by the database, not by a read followed by a write. Ten servers pushing the same key at once get one row between them.

**A queued row can be cancelled.** Say the user closed the export dialog, or unsubscribed before the nudge went out: `jobs.cancel(c, id)` deletes the row while it is still `queued` and returns `true`. Once a worker has claimed it the answer is `false` and the run finishes, because nothing interrupts a `run`, and a half-cancelled row would be worse. It is one statement, so a worker claiming at the same instant either got the row or did not. The `unique` key goes with the row, so "move it to tomorrow" is a cancel followed by a push ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)):

<!-- compiles -->
```zig
fn postpone(jobs: *Jobs, c: *nilo.Ctx, row: job.Id, user_id: i64, email: nilo.Str) !void {
    if (!try jobs.cancel(c, row)) return nilo.fail.conflict("that reminder is already going out", .{});
    _ = try jobs.push(c, SendWelcome{ .user_id = user_id, .email = email }, .{
        .after_ms = 24 * 60 * 60 * 1_000,
    });
}
```

**`.within` is a cheaper version of the same guarantee**, for when a duplicate costs an extra run, not a wrong one. The Space remembers the key for its TTL, a second push inside that window is answered by the cache and never reaches the table, and a restart forgets it. A `.within` without a `.unique` is a compile error, because the window needs a key to remember. A push the store refuses (the queue is full, the database errors) gives its window back, so retrying it is not answered `null` for the rest of the TTL.

### Pushing in a transaction

**A job row can commit together with your own rows:**

<!-- compiles: body -->
```zig
var tx = try db.begin(c, .{});
defer tx.deinit();

const user = try tx.insert(User, c, .{ .email = form.email, .password = form.password });
_ = try jobs.pushIn(&tx, c, SendWelcome{ .user_id = user.id, .email = user.email }, .{});

try tx.commit();
```

If the commit fails, there is no job; if the job is pushed, the user exists. That is the outbox pattern without a separate outbox, and it is why the queue is a table and not Redis ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)). `pushIn` on a `job.Memory` is a compile error, because a row in memory has nothing to commit with, and so is `pushIn` with `.within`, because a cache cannot roll back.

**A row pushed in a transaction has no status until a worker takes it**, because the `status` Space cannot roll back with the transaction: a `queued` written at `pushIn` would outlive a rollback as the status of a row that never existed. A poll right after the commit reads null, and then `running` once a worker has the row.

**A `push` wakes a worker; a `pushIn` cannot.** The row does not exist until the commit, so a worker woken at the `pushIn` would find nothing and go back to sleep. Call `jobs.wake()` after `tx.commit()` and the row starts at once; otherwise the next poll finds it, a second later at the default ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).

### Pushing from inside a job

**A pipeline is a `run` that pushes the next job, and for that it asks for the queue itself: `jobs: *Jobs`.** Examples are download, then process, then notify; or a welcome now and a nudge three days later. The queue is a dependency like any other, with one catch. `Jobs` does not exist yet while its own `.deps` is being read, so a struct with a `*Jobs` field is a `dependency loop` in the compiler's words. Write `.deps` as a function of the queue type instead, and nilo passes it the finished type ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)):

```zig
fn deps(comptime Queue: type) type {
    return struct { db: *Db, jobs: *Queue };
}

const Jobs = job.Jobs(.{
    .kinds = .{ Download, Process },
    .store = job.Table(Db),
    .deps = deps,
});

const Download = struct {
    pub const nilo_job = "download";
    pub const retry: job.Retry = .{ .times = 3, .backoff = .{ .fixed_ms = 30_000 } };

    file: i64,

    pub fn run(self: Download, scope: *nilo.Run, db: *Db, jobs: *Jobs) !void {
        try fetchInto(scope, db, self.file);
        _ = try jobs.push(scope, Process{ .file = self.file }, .{});
    }
};
```

The queue is a dependency of its own jobs, so it is opened once it has an address:

```zig
var jobs: Jobs = undefined;
jobs = .open(gpa, &table, .{ .db = &db, .jobs = &jobs }, .{ .workers = 4 });
```

Everything else works as before: `Jobs.Deps` is the struct the function returned, a pushed kind still has to be in `.kinds`, and a `run` asking for a service the struct does not have is the same compile error naming the job. The one difference is *where* that error appears when `.deps` is a function: at the first `open`, not at the `job.Jobs(…)` line, because only then does the queue type exist to check a `run` against. The compiler's trace points back to it. The nudge three days later is the same call with `.after_ms`.

## At-least-once delivery

**A job's `run` can be called more than once, so it must be safe to repeat.** The claim is one statement, and the second half of its `WHERE` is the lease:

```sql
UPDATE nilo_jobs SET state = 'running', lease_until = $2, attempts = attempts + 1
WHERE id = (SELECT id FROM nilo_jobs
            WHERE kind = ANY($3)
              AND ((state = 'queued' AND run_at <= $1) OR (state = 'running' AND lease_until <= $1))
            ORDER BY priority, run_at LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING …
```

A `running` row whose lease has passed is a row whose worker died (the process was killed, or the machine went away), and whoever asks next takes it again. So `run` is called *at least* once. A `run` that finds its work already done the second time is expected, not a bug to work around: for example an email keyed by `user_id` that the provider deduplicates, an `insertOrIgnore` instead of an `insert`, or an `UPDATE … WHERE state = 'pending'`. `nilo.Idempotent` takes the same position for incoming requests ([Answering once](./idempotency.md)).

The queue never promises exactly once because it cannot: that would be a promise about your mail provider. For the one case where the work is a write to the queue's own database there is a narrower promise, [below](#a-run-that-writes-to-the-same-database).

## A run that writes to the same database

**A run that takes the Db's transaction commits its writes and its `done` together, or neither.** Plain at-least-once has one hole for a job whose work is a write to the same database: `run` returns, and `done` is a statement of its own, so a process that dies between the two does the write again when the lease runs out. Ask for the transaction by pointer and the worker closes the hole ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)):

<!-- compiles -->
```zig
const Credit = struct {
    pub const nilo_table = .{ .name = "credits", .key = .id };

    id: i64,
    user_id: i64,
    cents: i64,
};

const Grant = struct {
    pub const nilo_job = "grant-credit";
    pub const retry: job.Retry = .{ .times = 3, .backoff = .{ .fixed_ms = 5_000 } };
    // Declared because the queue's `timeout_ms` is not a number about this
    // job. On SQLite it is also how long the transaction may hold the writer.
    pub const timeout_ms: u32 = 5_000;

    user_id: i64,
    cents: i64,

    pub fn run(self: Grant, scope: *nilo.Run, tx: *Db.Tx) !void {
        _ = try tx.insert(Credit, scope, .{ .user_id = self.user_id, .cents = self.cents });
    }
};

const GrantJobs = job.Jobs(.{ .kinds = .{Grant}, .store = job.Table(Db) });

fn drainGrants(run: *nilo.Run, jobs: *GrantJobs) !void {
    _ = try jobs.drain(run);
}
```

The worker begins the transaction, calls `run` with it, and when `run` returns it writes the row's `done` **inside the same transaction** and commits. A crash before the commit leaves neither the credit nor the `done`, and the row is claimed again when the lease passes. The `done` is fenced on the claim like every other write about a row ([At-least-once delivery](#at-least-once-delivery)): if the lease lapsed mid-run and a second worker holds the row now, the `done` matches nothing, the transaction is **rolled back**, and the first worker's credit never exists. The worker that holds the row is the one whose writes count.

**A failed run rolls everything back first.** Whatever `run` wrote is gone, and then the failure is recorded as for any kind: `retry` or `dead`, outside the transaction, never in it. A COMMIT that errors is a failed attempt like any other; if it had landed anyway, the row is `done` and the retry that follows matches nothing.

**This is not exactly once.** What commits together is the run's writes to the queue's own database and its `done`. The run itself is still at least once: a call to a mail provider or a payment API made inside it can happen twice, because a crash after the call and before the commit repeats it. For an effect outside the database the answer is an idempotency key, and the row's id is a stable one: `Tick.id` is the same on every retry and every re-claim of the row. [`nilo_fetch`](./fetch.md#retrying) sends a key of yours as it is and retries under it:

<!-- compiles -->
```zig
const Payment = struct {
    pub const nilo_table = .{ .name = "payments", .key = .id };

    id: i64,
    user_id: i64,
    cents: i64,
};

const Charge = struct {
    pub const nilo_job = "charge";
    pub const retry: job.Retry = .{ .times = 4, .backoff = .{ .fixed_ms = 30_000 } };
    pub const timeout_ms: u32 = 20_000;

    user_id: i64,
    cents: i64,

    pub fn run(self: Charge, scope: *nilo.Run, tick: job.Tick, tx: *Db.Tx, client: *fetch.Client) !void {
        // The same on attempt one and attempt four, so the provider charges once.
        var key: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&key, "charge-{d}", .{tick.id});
        const res = try client.postJson(scope, "https://payments.example.com/v1/charges", .{ .cents = self.cents }, .{
            .headers = &.{.{ .name = "Idempotency-Key", .value = name }},
        });
        if (!res.ok()) return error.Declined;
        _ = try tx.insert(Payment, scope, .{ .user_id = self.user_id, .cents = self.cents });
    }
};

const ChargeJobs = job.Jobs(.{ .kinds = .{Charge}, .store = job.Table(Db), .deps = struct { client: *fetch.Client } });

fn drainCharges(run: *nilo.Run, jobs: *ChargeJobs) !void {
    _ = try jobs.drain(run);
}
```

A `mint_key` on the target would not do here: it mints a key for each call, so each attempt of the job would carry a new one. The key has to come from something the attempts share.

**What it costs.** A connection is held for the whole `run`, and BEGIN and COMMIT are two more round trips, paid by a transactional run and nobody else. A kind that takes no transaction costs nothing more than before. Because each such run pins a connection and a claim needs one too, **a queue with a transactional kind refuses to start** (`error.PoolTooSmall` from `nilo_start` and `serveOn`) when `workers` is not smaller than the Db's `size`. On SQLite there is one writer, so the transaction holds every write in the program, claims and requests included, for as long as the run takes. That is why a transactional kind on SQLite has to declare its own `pub const timeout_ms`: how long the writer may be held is a number its author writes, and a plain `workers` above one buys no concurrency for it.

**Four mistakes are compile errors.** A `run` that takes a transaction on `job.Memory`, which has nothing to commit with (test such a kind on SQLite, where `:memory:` is a database in the process); a transaction of a different Db than the queue's; and a `run` that takes both the transaction and the `*Db`, because the worker holds one connection and a statement on the pool waits for another, which with every worker in that position is a deadlock; and, on SQLite, a transactional kind with no `pub const timeout_ms` of its own, because there that is how long the transaction may hold the writer. A `*Jobs` beside the transaction is fine, and `jobs.pushIn(tx, scope, …)` is how a transactional run queues the next job so that it commits with the run's writes. A plain `jobs.push` from inside such a run takes a second connection and commits at once, whatever happens to the transaction after.

**The worker ends the transaction, not `run`.** A `run` that calls `tx.commit()` itself has kept its writes before the `done` could join them, so the worker logs a warning and writes `done` on its own, which is plain at-least-once again. Return from `run` and let the worker commit; return an error and it rolls back.

## Scheduled jobs

**A job with a `schedule` runs on the clock and nobody pushes it.** It must also declare two more things, and neither has a default ([ADR 161](../adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md)):

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
| `job.cron("0 3 * * *")` | `minute hour day month weekday`, UTC unless `.in` names a zone, parsed while compiling. `*`, lists, ranges and `*/n`; a date that never comes (`0 0 31 2 *`) is a compile error. When either day field starts with `*`, the day must match both |
| `job.every(600_000)` | every ten minutes from whenever the worker started, for when it does not matter which ten. Milliseconds, read while compiling: `0` and a period over a hundred years are compile errors |

A field out of range, a sixth field or a backwards range is a compile error naming the field.

**A schedule is UTC unless you name a zone.** `job.cron("0 3 * * *").in("Asia/Jakarta")` is three in the morning in Jakarta, whatever the server's clock says, and the row's `run_at` is still the UTC instant. The zone is spelled as the IANA database spells it (`Europe/Berlin`, `America/Argentina/Buenos_Aires`), and a name nobody has data for is a compile error that offers the right spelling when the case is the only difference. The data for the zones you name is compiled into the program (about 150 bytes each, none for a zone you do not name), and nothing is read from the machine it runs on, so it works the same in a scratch container. `job.every(...)` has no zone: ten minutes is ten minutes on any clock.

A wall clock does two awkward things a year, and a schedule that names a time has to say what it wants:

```zig
const Report = struct {
    pub const nilo_job = "berlin-report";
    pub const retry: job.Retry = .none;
    pub const schedule = job.cron("0 2 * * *").in("Europe/Berlin");
    pub const overlap: job.Overlap = .skip;
    pub const missed: job.Missed = .drop;
    pub const skipped: job.Skipped = .run_late;
    pub const repeated: job.Repeated = .first;

    pub fn run(self: Report, scope: *nilo.Run, db: *Db) !void { … }
};
```

| | |
|---|---|
| `skipped = .run_late` | on the night the clocks go forward and 02:00 does not exist, run once, late: the wall time is read with the offset from before the gap, so 02:30 runs at 03:30 |
| `skipped = .skip` | no tick that night. A tick that never existed is not a `missed` one |
| `repeated = .first` | on the night the clocks go back and 02:00 happens twice, run on the first pass only |
| `repeated = .second` | on the second pass only |
| `repeated = .both` | on both |

You declare them **only when your schedule can land there**, and the compiler works that out from the zone's own data, not from a guess that it is always 02:00: `0 3 * * *` in Berlin, `0 9,17 * * *` and anything in Asia/Jakarta need nothing, `0 2 * * *` in Berlin needs both, and `0 0 * * *` in Cairo needs `skipped` because Cairo's clocks go forward at midnight. A schedule whose hour field is exactly `*` (`*/15 * * * *`, `30 * * * *`) is read as an interval, never asks, and does what "every quarter hour" says: nothing in the hour that does not exist, and both passes of the one that happens twice. Neither declaration has a default, for the reason `overlap` and `missed` have none.

The zone data is IANA's, release `job.tzdata_version`. Governments change rules on short notice, so a dependent can build against a newer release without waiting for nilo: run `python3 -I job/tzdata/refresh.py --out /some/dir` from a nilo checkout and pass `-Dtzdata=/some/dir` (or `.tzdata = "/some/dir"` to `b.dependency("nilo", …)`).

**`overlap`** decides what happens when the previous run is still going when the next tick is due:

| | |
|---|---|
| `.skip` | do not start another. The tick that falls inside a run does not happen, and the next is calculated from the clock when the run ends |
| `.queue` | start it anyway, on another worker |

**`missed`** decides what happens to a tick whose time has passed, because the process was down or every worker was busy:

| | |
|---|---|
| `.drop` | forget it. A tick that is later than its own successor is not run; one that is only late is |
| `.catch_up` | run it once, then continue from the clock |

A schedule is stored as a row: the next tick is pushed with the unique key `"schedule"`, so ten instances seeding the same schedule at startup produce one row, and whichever worker claims it runs it. There is no leader, a restart loses no tick, and **the first tick is the next one on the clock**: `every(600_000)` first fires ten minutes after the worker started. A program that wants a run at startup pushes one.

**A schedule that lost its row is queued again within a minute.** The next tick is pushed after the last one is marked done, so a crash between the two, a database error on the push or a `cancel` of the queued tick would leave a schedule with nothing to run. Every worker therefore seeds again once a minute, and since a kind with a queued or running tick inserts nothing, the cost is one insert per scheduled kind per minute for the whole process. `drain` does the same, once `seed` or `serve` has run ([ADR 161](../adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md)).

A tick that fails is retried according to the job's `retry` like any other row, and the schedule's next tick is pushed regardless. A tick that dies is dead like any other row.

## Choosing a store

**`job.Table(Db)`** is the queue in your database. `Db` is your `sql.Db` or `sql.Sqlite(…)` type. The Row it carries is a `nilo_table` like yours, named `nilo_jobs`, migrated alongside your own with `createMissing` or the `db` command, and checked by `db.checking(.{ .tables = &.{ …, Jobs.Row } })` at startup. Both databases are production stores here. On SQLite every claim is a write, so `workers` is the number of claims in flight as well as the number of jobs: four is right, and forty just queues up for the single writer.

**`job.Memory`** is the same contract inside this process, for a test, or for a program that can lose its queue on restart and accepts that:

```zig
var store = try job.Memory.open(gpa, .{ .bytes = 1 << 20 });
defer store.deinit();
```

It is a queue, not a cache: a full `Memory` returns `error.QueueFull` instead of overwriting the oldest row, which is why the module is not built on `nilo_cache`. `.max_payload` (4 KiB) is the largest row it holds.

**`Settings`**, passed to `open`:

| Field | Default | |
|---|---|---|
| `workers` | 4 | rows running at once in this process. Each is a fiber, and a fiber holds its stack at its high-water mark for its whole life ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)), so this cost is per worker, not per row |
| `poll_ms` | 1,000 | how long a worker with nothing to do waits before asking again, **when nothing wakes it first**. A `push` from this process wakes a worker itself, so this is only the delay for a row *another* process pushed, and the cost of an idle queue: one claim per worker per interval ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)) |
| `timeout_ms` | 60,000 | how long one run may take, for a kind that sets no `timeout_ms` of its own. Also the lease |

A third store needs ten methods, listed in `job/contract.zig`, for whoever brings that deployment.

## Monitoring the queue

**`stats`** returns the three counts; a health page that wants to know the queue is not backing up reads `queued` there. **`nilo_ready`** is what [`app.health`](./deploying.md#health-checks) asks: not ready before `listen()`, not ready when the store says so, and not ready when `serve` has been started and no worker is alive.

**A status a route can poll** is a `cache.Space` of `job.Status`, named on the type and passed in at `openWith`:

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

`jobs.status(id)` then returns `.{ .state, .attempts, .progress }` for as long as the Space remembers the row (`queued`, `running`, `done` or `dead`) and null once it has forgotten. For a route answering "is my export ready?" that is the right behaviour. It is deliberately a cache and not the table: a status is the one thing here that may be forgotten, and a poll every second should not be a query every second.

**The status Space is per instance.** With several instances on one table, a row pushed on one and run on another stays `queued` in the first instance's Space until its TTL, and the instance that ran it says `running` and `done`. That is a property of a cache that is not shared, and the way round it is a route that asks the instance that holds the Space, or the table through `stats`.

**`progress` is the run's own number, stored in the same Space.** A `run` that asks for its `job.Tick` and for `*Jobs` calls `jobs.progress(tick.id, n)` as it goes (rows imported, a percentage, a step; the kind decides what the number means), and the route polling `status(id)` reads it next to the state ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)):

```zig
pub fn run(self: Import, scope: *nilo.Run, tick: job.Tick, db: *Db, jobs: *Jobs) !void {
    var done: u32 = 0;
    while (try self.nextBatch(scope)) |batch| {
        try db.insertMany(Row, scope, batch);
        done += @intCast(batch.len);
        jobs.progress(tick.id, done);
    }
}
```

The number starts over with every attempt and is kept when the row is `done`, so the last poll reads "done, 4,000 rows". Each call is a `get` and a `put` on the Space and does not touch the table, so a run can report after every batch instead of every thousand.

**Dead jobs** are listed newest first with the error's name, and `retryDead` puts one back at attempt one. It refuses a row of a scheduled kind with `error.Scheduled`, because that tick's successor is already queued, and the revived row has no unique key: a newer row pushed under the same key can run beside it. An operator's routes:

<!-- compiles -->
```zig
fn dead(c: *nilo.Ctx, jobs: *Jobs) ![]job.Dead {
    return jobs.deadOnes(c);
}

fn retry(c: *nilo.Ctx, jobs: *Jobs, row: u64) !void {
    if (!try jobs.retryDead(c, row)) return nilo.fail.notFound("no dead job {d}", .{row});
}
```

**The log** records every failure as a `warn` with the kind, the row, the error's name, the attempt and the wait before the next one. A row that dies is logged with its attempt count. A claim that cannot reach the store is an `err`, and the worker sleeps `poll_ms` and tries again.

## Running workers without a server

**A worker process that serves no HTTP calls `serveOn` with an `Io` of its own.** `serve` runs the workers on the `Io` the server passed in `nilo_start`, and stops when the server does: `error.Canceled` is the shutdown, as for every fiber ([Work that is not a request](./background.md)). Without a server:

```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();

try db.nilo_start(threaded.io(), .none);
try jobs.nilo_start(threaded.io(), .none);
try jobs.serveOn(threaded.io());   // returns when cancelled
```

Cancelling it is up to you: there is no signal handler here, because the one in `nilo_http` belongs to the server.

**A CLI is set up the same way**: a `Db`, a `Jobs`, maybe a `fetch.Client`, on one `Io.Threaded` and no `App` anywhere. A push from it wakes its own workers, the same as in a server. What it does not see immediately is a row pushed by a *second* process on the same table: that row is found by the poll, or by a `jobs.wake()` that the second process cannot make. Two processes on one queue is what `poll_ms` is for.

## Testing

**A queue over `job.Memory` needs no database, no server and no `Io`, and `drain` runs everything due on the calling thread.** A job that takes a `*Db` still needs one, and an in-memory SQLite file is what `nilo_sql`'s own tests use:

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

`drain` and `runOne` take a `*nilo.Run` and refuse a `*Ctx` while compiling: a job run under a request could call a fail function.

**A test moves the clock with `drainAt`.** `drain` runs what is due now; `drainAt(&run, now)` runs what would be due if it were `now`, in microseconds since the epoch. Every read of the clock inside a tick (whether a row is due, when a failed run is retried, when a schedule's next tick is) reads that number. So the reminder for tomorrow, the third attempt of a backoff, and the report at three in the morning are each one call, not a sleep ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)):

```zig
test "the nudge goes out three days later and not before" {
    const t = nilo.nowMicros();
    _ = try jobs.push(&run, Nudge{ .user_id = 7 }, .{ .after_ms = 3 * 24 * 60 * 60 * 1_000 });
    try testing.expectEqual(@as(usize, 0), try jobs.drainAt(&run, t + 2 * day));
    try testing.expectEqual(@as(usize, 1), try jobs.drainAt(&run, t + 3 * day + std.time.us_per_s));
}

test "the report runs at three, and again the next day" {
    try jobs.seedAt(&run, ten_in_the_morning);
    const three = Nightly.schedule.next(ten_in_the_morning);
    try testing.expectEqual(@as(usize, 0), try jobs.drainAt(&run, three - 1));
    try testing.expectEqual(@as(usize, 1), try jobs.drainAt(&run, three));
    try testing.expectEqual(@as(usize, 1), try jobs.drainAt(&run, three + day));
}
```

`seedAt` does what `serve` does at start (queue every schedule's next tick), for a test that drains instead of serving. A retry's wait is stepped through the same way: a kind with `.exponential = .{ .from_ms = 100, … }` that fails at `t` runs again at `drainAt(&run, t + 100 * ms)`, not at `t + 99 * ms`, and the third attempt at `t + 300 * ms`. `push` takes `.at` for the row side of the same arithmetic.

`drain` itself is `drainAt` at the moment it was called, and reads the clock once: what is due is decided against that one reading, so a schedule of `every(1)` under a slow tick cannot keep a drain running for as long as the ticks take.

## What it costs

Against [ADR 017](../adr/017-the-trade-budget-has-four-axes.md)'s axes, with the numbers in [`bench/result/job.md`](../../bench/result/job.md):

**Per request, nothing on a route that does not push.** A route that does push pays for the payload's JSON out of the request arena (the one allocation it already has) and one `INSERT`: 10 µs on SQLite, 0.9 ms on Postgres across a Docker port.

**Per idle worker, one claim per `poll_ms`**: 55 µs of SQLite or 354 µs of Postgres a second, which is 0.035% of one connection and where the default comes from. A claim that takes a row is 140 µs and 1.2 ms. **Per push, one atomic and one futex wake**, which removes the whole of `poll_ms` from the delay of a row this process pushed ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).

**Per connection, nothing.** A worker is a fiber per process, and its stack is paid once and held at the high-water mark of whatever `run` touches.

**Per row, a `job.Tick` is built whether or not the `run` asks for it** (three words and a bool on the worker's stack), plus a tag test on the clock each of the three or four times a tick reads it, which is what lets `drainAt` pass a test's number to every one of them ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).

## What it will not do

**It is not a priority queue with numbers**: a kind says `.high`, `.normal` or `.low`, and among equals rows come out in `run_at` order ([ADR 214](../adr/214-a-job-says-how-urgent-it-is.md)). It is not a workflow engine, not a rate limiter for a kind (`nilo.Gate` inside `run` does that), and not exactly once. Each of those is in [`docs/todo.md`](../todo.md) under `nilo_job`, with what it is waiting for.

## See also

- [The reference](../reference/job.md#nilo_job): the whole API as a list.
- [Work that is not a request](./background.md): the fiber underneath, for work that is a loop and not a row.
- [Transactions](./sql/transactions.md): what `pushIn` joins.
- [A cache in this process](./cache.md): the Space a status lives in.
- [ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md): why a table and not Redis; [ADR 161](../adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md): why `overlap` and `missed` have no default.
