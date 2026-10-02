# A schedule is a type that makes the caller choose

**Status:** accepted
**Topic:** [job](../design/job.md)
**Extends:** [ADR 028](./028-a-spawned-fiber-belongs-to-the-server.md) (the schedule it said could be built on top)

## Context

ADR 028 refused `app.every(ms, f)` with one sentence: it bakes in policy.
What happens when a tick overruns the next one, whether a missed tick is
dropped or caught up, whether the first tick is at zero or at `ms` — none of
those has an answer that is right for everybody, and an `every` that picked
them quietly would be a schedule that surprises somebody at three in the
morning. It ended with: *a schedule can be built on top later without taking
the primitive back.*

`docs/todo.md` then carried "A schedule, rather than a loop around a
sleep" as Not decided, waiting on somebody who had written the loop twice.
The queue of [ADR 160](./160-a-queue-is-a-table-in-the-database-you-already-have.md)
is where it got written the second time: a schedule is a job whose next row
the clock pushes, and every one of ADR 028's three policies had to be
decided to write `pushNext`.

## Decision

**A scheduled job declares `schedule`, `overlap` and `missed`, and the last
two have no default.**

```zig
const Nightly = struct {
    pub const nilo_job = "nightly-report";
    pub const retry: job.Retry = .none;
    pub const schedule = job.cron("0 3 * * *");
    pub const overlap: job.Overlap = .skip;     // or .queue
    pub const missed: job.Missed = .drop;       // or .catch_up

    pub fn run(self: Nightly, scope: *nilo.Run, db: *Db) !void { … }
};
```

A scheduled job without `overlap` or `missed` is a Refusal that names the
two choices and says why neither is chosen for you. That is exactly the shape
ADR 028 said would be worth having, and the refusals are the sentence in
that ADR turned into a build step.

The three policies, and how each is a row rather than a timer:

- **The next tick is a row**, pushed with `unique = "schedule"`, so ten
  instances seeding the same schedule at start-up produce one row
  (ADR 160's unique index). Whoever claims it runs it. There is no leader.
- **The schedule is re-seeded once a minute**, because the next tick is
  pushed in a statement of its own after the last one is marked done, and
  nothing else puts it back when that statement does not happen: a crash
  between the two, a database error on the push, or a `cancel` of the queued
  tick leaves a kind with no row, and seeding used to be `serve`'s start-up
  alone, so the schedule stayed dead until a restart. Every worker loop (and
  `runOneAt`, so `drain` heals too) calls `seedAt` again when a minute has
  passed since it last ran, whichever caller wins a `cmpxchg` on the time it
  last ran, so one insert per scheduled kind per minute across all workers
  and one atomic load per loop; a queue with no scheduled kind pays nothing,
  and a queue nobody seeded is left alone. Seeding is idempotent (a kind
  with a queued or running tick inserts nothing, the unique key), which is
  why this needs no new store method. The interval is a constant, not an
  option: it is how long a silent schedule is tolerated, and nobody has
  asked for another number.
- **`overlap`** decides *when* the next row is pushed. `.queue` pushes it
  when the tick is claimed, so another worker may take it while this one is
  still running. The running tick first gives up the schedule's unique key
  through the store's `unkey`, and the successor takes it, so a schedule
  always has exactly one keyed row and seeding after a restart stays
  idempotent. As first built it pushed under the key the running tick still
  held, so the push collided and `.queue` behaved exactly like `.skip`; a key
  per tick was rejected because a restart could then seed a second chain. `.skip` pushes it when the tick finishes, so a tick that
  falls inside a run has no row and does not happen — and the next is
  computed from the clock at the end of the run, not from the tick that was
  skipped.
- **`missed`** decides what a claim does with a row whose `run_at` is old —
  the process was down, or every worker was busy. `.catch_up` runs it once.
  `.drop` runs it only if it is not yet later than its own successor: a tick
  claimed after the next tick was due is forgotten and the schedule moves
  on. "Later than its own successor" is the whole definition, so a job late
  by ten seconds under a daily schedule still runs and one late by a day does
  not.
- **The first tick is the next one the clock says**, and that is the answer
  to ADR 028's third question: nothing runs at zero because nothing ran
  before, and `every(600_000)` first fires ten minutes after the worker
  started rather than at start-up. A program that wants a run at start-up
  pushes one.

**`retry` has no default either**, on the same argument, and it applies to
every job rather than only scheduled ones. How many times an email is tried
is a promise about that email, and a default nobody read is not one.
`.none` is one attempt; the Refusal shows the exponential form.

**The schedule is parsed while compiling.** `job.cron("0 25 * * *")` is a
compile error naming the field and its range, and so is a sixth field or a
backwards range. So is a date that never comes: `0 0 31 2 *` passed every
field's range, and `next` then looped for minutes and reached `unreachable`,
stalling a worker at seeding. When either day field starts with `*` the two
must both match, as in Vixie and cronie (`*/2` counts too, not only a bare
`*`), and when both are restricted either may; `next` is bounded by 400 years
of calendar rather than by a count of turns, and answers `Cron.never` past
it. A schedule read from a config file at start-up would be a
schedule the compiler cannot check, which is the one property that makes
this a type rather than a string.

**UTC, and only UTC.** A time zone is a table of rules that changes twice a
year and a dependency to carry it. `0 20 * * *` with a comment is 03:00
Jakarta; `docs/todo.md` carries the gap.

## What was rejected

- **Pushing the successor before marking the tick done**, so a crash cannot
  fall between the two. For `.skip` the running tick still holds the
  schedule's key, so the successor collides with it and is dropped, which is
  the bug `.queue`'s early push exists to avoid. **Done-and-push as one
  transaction** would heal it without a timer but is a new store method every
  hand-written store must implement; the re-seed covers the crash and the
  cancel as well, and costs an insert a minute.

- **Defaults for `overlap` and `missed`.** The whole of ADR 028's objection.
  `.skip` and `.drop` are the safer pair and would be the defaults if there
  were any, and a report that silently did not run for the night the process
  was down is the failure that argues against them.
- **A schedule as a fiber with a sleep**, the shape the roadmap entry
  sketched. It cannot survive a restart without a row, cannot elect one of
  several instances without a row, and cannot tell a missed tick from a late
  one without a row. Once the row exists, the fiber is the worker that
  already runs everything else.
- **`@tagName`-style spelling — `.{ .daily = .{ .at = "03:00" } }` — instead
  of cron.** Prettier for the three common cases and unable to say the fourth,
  and every operator who has to read it already knows what `0 3 * * 1-5`
  means. The five-field grammar is the one that is documented everywhere.
- **Seconds as a sixth field.** A schedule finer than a minute is a loop
  around `nilo.sleep`, which already exists and is the right shape for it.

## Consequences

- `job.Schedule`, `job.cron`, `job.every`, `job.Overlap` and `job.Missed`
  exist; `job/cron.zig` is the parser and carries its own tests.
- Four Refusals in `job_refusals`: a schedule without `overlap`, one without
  `missed`, a cron field out of range, and a scheduled job with a field that
  has no default (nobody pushes a scheduled job, so nobody fills one in).
- The roadmap entry closes, and the `every(ms, f)` refusal in ADR 028 stands
  unchanged — this is the "built on top later" it left room for.
