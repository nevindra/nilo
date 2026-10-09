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

**`every`'s period is read while compiling, and `0` and anything over a hundred years (`job.max_every_ms`) are refused.** A zero period is a tick that is always due, which keeps a worker busy for ever; a number past a hundred years is seconds or microseconds written where milliseconds go, and the bound keeps the clock arithmetic far inside an `i64` (`Schedule.next` also saturates, for a `Schedule` built by hand). The rejected alternative is a runtime check with an error: a schedule is a `pub const` on the job, so there is no caller to hand an error to. For the same reason an exponential `retry.backoff` with `from_ms = 0` is refused: doubling zero is zero, which is `fixed_ms = 0` written as a growing wait.

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

**A schedule is UTC unless `.in` names a zone, and a zone is data compiled in for the zones a program names.**

```zig
pub const schedule = job.cron("0 3 * * *").in("Asia/Jakarta");
```

`.in` is a comptime method on what `job.cron` returns, so every schedule that does not use it is unchanged. `Tick.run_at` and every stored time stay UTC microseconds; the zone only decides how the five fields are read. A name that is not an IANA zone is a Refusal that names it, and offers the right spelling when a case-insensitive match exists. `job.every(...).in(...)` is a Refusal too: an interval is elapsed time, and no wall clock changes how long ten minutes is. So is a second `.in`.

**The data is IANA's, vendored, and costs a program only the zones it names.** `job/tzdata/` holds one TZif file per zone (344 files, 51 KB in the repository, about 150 bytes each), compiled with the host's `zic -b slim -r @1767225600`: the slim form, which keeps only what the footer cannot derive, and a cut-off at 2026-01-01 UTC, because a schedule only ever computes future ticks. A link (`Asia/Saigon`) is a name in a generated table that points at its zone's file; no file is duplicated. `job/tzdata/refresh.py` downloads a release, verifies its signature against the pinned key (`gpg`, in a throwaway keyring), runs `zic` and writes the table, and `docs/releasing.md` says when. The file for the zone a schedule names is chosen while compiling (`@embedFile` behind a comptime `if`), so a zone nobody names is not in the binary, and no file is read at run time. The release is `job.tzdata_version`.

**It is read by our own code, while compiling.** `job/tz.zig` parses the version 2 and 3 64-bit block into transitions and offset types, and the POSIX TZ footer (RFC 9636 section 3.3) into rules: `Jn`, `n` and `Mm.w.d` dates, quoted names, all-year daylight time, and hours from -167 to 167 (Jerusalem `/26`, Nuuk `/-1`, Gaza `/50`, Cairo and Santiago `/24`). A file whose footer disagrees with its last transition is a compile error, because a schedule built on it would run at the wrong hour for ever. `mktime`, `localtime` and the host's zoneinfo are never used. Checked against Python's `zoneinfo` for all 344 zones over five years (5,033,408 sampled moments), the only differences were `America/Winnipeg` and `America/Inuvik`, which the host's older tzdata did not yet know had changed (2026d and 2026e).

**The next tick is found on the wall clock and converted to UTC by us.** The walk goes through the zone's stretches of one offset in order and, inside each, steps the wall clock with the same five bitsets a UTC schedule uses, so ticks come out strictly increasing in real time even across a repeated hour. Two kinds of schedule differ in what a skipped or repeated hour means to them:

- **An interval-like schedule has an hour field of exactly `*`** (`*/15 * * * *`, `30 * * * *`). A wall time inside a skipped hour has no tick, and a repeated hour ticks on both passes. Nothing is declared, because there is nothing to decide: "every quarter hour" means every quarter hour.
- **Every other schedule is a fixed time** (`0 2 * * *`, `0 9,17 * * *`, `0 */2 * * *`). "At 02:30" has no 02:30 one night a year and two of them another, so the job declares `skipped` (`.run_late` or `.skip`) and `repeated` (`.first`, `.second` or `.both`), with no default, the way `overlap` and `missed` are. `.run_late` reads the skipped wall time with the offset from before the gap, so 02:30 in Berlin's spring gap runs at 03:30 CEST (RFC 5545 section 3.3.5, and Temporal's "compatible" disambiguation). A tick `.skip` drops never existed, so it is not a `missed` one.

**A fixed-time schedule declares only if its zone can meet a window.** `Cron.needs` works it out while compiling from the zone's own data: the explicit transitions after the cut-off and the footer's switches for the nine years after the last of those, each a stretch of wall-clock minutes (`[t + before, t + after)` for a clock put forward, `[t + after, t + before)` for one put back), tested against the schedule's minute, hour and month sets. Nothing is hard-coded at 02:00: windows sit anywhere from 21:00 to 04:00 and are 30 (Lord Howe), 60 or 120 (Troll) minutes wide, Cairo, Beirut and the Azores skip at 00:00 so `0 0 * * *` there declares, `30 2 * * *` in Lord Howe does not (its window is `[02:00, 02:30)`), and a transition that changes no offset (Winnipeg in November 2026) is neither. Asia/Jakarta never asks. A declaration that is not needed is accepted, because a later release of the data may need it; the day fields are left out of the test on purpose, so a declaration does not appear and vanish with the calendar.

**It stays fresh by a check and by an escape hatch.** `zig build tzdata-check -Dnetwork` (off `test`, like `fetch-check`) fails when IANA lists a release newer than `job.tzdata_version`. `-Dtzdata=<dir>` builds `nilo_job` against the directory `refresh.py --out <dir>` wrote, so a short-notice rule change (Kazakhstan 2024 gave 29 days, Manitoba in 2026e about 33) does not wait for a nilo release. The data is a module of its own, `nilo_tzdata`, imported only by `nilo_job`: the build swaps its root and nothing else, `job.zig` names no path into it, and it imports only `std`, so the layering has one more name in `job`'s row and no new row.

**What it costs**, measured on the tree at `2622234` plus this change, stripped `ReleaseFast`, `x86_64-linux-gnu`, a program that asks one schedule for its next tick ([the run](../../bench/result/job.md#a-schedule-in-a-time-zone)):

| | bytes | a tick |
|---|---|---|
| a UTC schedule, before | 227,064 | 0.9 us |
| a UTC schedule, after | 227,080 (+16) | 0.9 us |
| the same, `.in("Europe/Berlin")` | 233,320 (+6,256) | 2.6 us |
| three zones | 234,136 (+816 for the two more) | |

A program with no zone pays 16 bytes and the `job` release program is byte-identical. The first zone pays for the walk (about 6 KB) and the file; each zone after it its file (about 150 bytes) and its calls. Neither an allocation per request nor memory per idle connection moves: `nilo_job` is not in the request path, `next` allocates nothing, and it runs once a tick.

## What was rejected

- **UTC, and only UTC**, which this ADR said first: a time zone is a table of rules that changes twice a year and a dependency to carry it, and `0 20 * * *` with a comment is 03:00 Jakarta. What moved it is that the table is not a dependency (a compiled-in file per zone, read by about 500 lines of our own code), that its cost is paid only for the zones a program names, and that the comment does not scale: it is right for half the year in any zone with daylight time, `0 2 * * *` in Berlin cannot be written in UTC at all, and the people most likely to meet the gap are the ones running a nightly job in their own zone. The todo entry "A schedule is UTC" closes.
- **Reading the host's zoneinfo at run time.** Go's `time.LoadLocation` does exactly this, and a scratch container has none: the schedule would compile and then fail, or worse run in UTC, on the machine that matters. Run-time file reads are also not checkable while compiling, which is the one property that makes a schedule a type.
- **Embedding the whole database.** Go's `time/tzdata` adds about 450 KB to a binary that imports it, for one zone's worth of use. Here the file for a zone is chosen at comptime and the others are not analysed.
- **chrono-tz's tables.** It generates a transition table for 1800 to 2100 with no footer, so a schedule asked about 2101 has no rule, its tables are large, and its data was at 2025b when this was written, which is the staleness this ADR's check and `-Dtzdata` exist to prevent. The footer is what makes a slim file small and correct for ever.
- **Skipping a gap and running a fixed job twice in a fold, which is what robfig/cron and Kubernetes' CronJob do.** A job at 02:30 does not run on the night 02:30 does not exist, and runs twice on the night it happens twice. Both are defensible, neither is right for everybody, and both were picked for the caller. Here the caller picks, and an interval is not forced to pick at all.
- **croner's rule that a fixed time is a schedule with a single value in its hour field.** `0 9,17 * * *` would be treated as an interval and so would never be told about a skipped hour; here the line is cronie's `HR_STAR` idea, an hour field of exactly `*`, and everything else is a fixed time that declares if its zone can meet a window.
- **gocron's dedupe by wall time.** A job that is "the same" when its wall time repeats skips an hourly job's second pass of the repeated hour, which is the one run an hourly job is owed.
- **tokio-cron-scheduler's offset frozen at creation.** The offset is read once, so a schedule created in winter runs an hour off all summer.
- **Resolving a wall time through `mktime` with `tm_isdst = -1`.** What it does with a skipped or a repeated time is unspecified, differs between libcs, and needs a libc and the host's zoneinfo.
- **A default for `skipped` and `repeated`**, the same argument as the defaults for `overlap` and `missed`. `.run_late` and `.first` are what RFC 5545 and Temporal's "compatible" pick, and they are the pair `next` reads for a bare `Schedule`, but a report that silently did not run for the night the clocks moved is the failure that argues against a default.
- **Declaring always, or never.** Always makes Jakarta write two lines that mean nothing; never means a schedule that meets a window is decided by a constant nobody read. `Cron.needs` makes the compiler say when it matters.

jiff (Rust), Temporal (JavaScript), croner (JavaScript and Rust), cronie, Go's `time` and RFC 9636 were read for the policies above; none of them is used.

## Consequences

- `job.Schedule`, `job.cron`, `job.every`, `job.Overlap`, `job.Missed`,
  `job.Skipped`, `job.Repeated` and `job.tzdata_version` exist; `job/cron.zig`
  is the parser and carries its own tests, `job/tz.zig` reads a zone, and
  `job/tzdata/` is the data and the script that refreshes it.
- Eleven Refusals in `job_refusals`: a schedule without `overlap`, one without
  `missed`, a cron field out of range, a scheduled job with a field that has
  no default (nobody pushes a scheduled job, so nobody fills one in), an
  unknown zone, one that differs only in case, `.in` on `every`, `.in` twice,
  a zoned job without `skipped`, one without `repeated`, and a `skipped` that
  is not a `job.Skipped`.
- The roadmap entry closes, and the `every(ms, f)` refusal in ADR 028 stands
  unchanged, since this is the "built on top later" it left room for.
