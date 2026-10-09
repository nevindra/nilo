//! What a store has to answer, and the shapes it answers in.
//!
//! A `Jobs` never names a store type: it is handed one, and asks it these
//! ten questions through whatever methods it has, the way `nilo.Idempotent`
//! asks a Space for `getInto` and `putIfAbsentFor` rather than for `nilo_cache`
//! ([ADR 155](../docs/adr/155-a-request-answered-once-is-answered-the-same-way-again.md)).
//! That is what keeps `job/` importing `nilo_core` and nothing else while
//! `job.Table` sits on a `nilo_sql` Db: the Db type arrives as a parameter,
//! and the layering step never sees an import
//! ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
//!
//! The contract, in one place so a third store — somebody's Redis, say — has
//! a list to write against:
//!
//! | | |
//! |---|---|
//! | `push(scope, kind, payload, Enqueue) !?Id` | queue one; `null` when `unique` already has a row queued or running; `error.EmptyUniqueKey` for a `unique` of length zero, which is a value that went missing and would fold every such push into one row |
//! | `claim(scope, comptime kinds, now, lease_until) !?Claimed` | take the most urgent due row **of these kinds**, or one whose lease ran out, marking it running and counting the attempt. Urgency first, then how long it has been due; a kind not in the list is left where it is, for the binary that knows it (ADR 215) |
//! | `done(scope, id, attempts, now) !bool` | it worked, at `now` (the clock the queue reads, so a test that moves it sees `finished_at` move with it) |
//! | `retry(scope, id, attempts, run_at, err) !bool` | it failed and will be tried again then |
//! | `dead(scope, id, attempts, err, now) !bool` | it failed for the last time, at `now` |
//! | `release(scope, id, attempts) !bool` | put it back untouched: the server is going |
//! | `unkey(scope, id, attempts) !bool` | a running row stops holding its `unique` key and goes on running, so a successor can be queued under the same key: what a schedule with `overlap = .queue` needs (ADR 161) |
//! | `stats(scope) !Stats` | how many are waiting, running and dead |
//! | `deadOnes(scope) ![]Dead` | the dead rows, newest first |
//! | `retryDead(scope, id, now, comptime scheduled) !bool` | queue a dead row again from the first attempt; `error.Scheduled` when its kind is one of `scheduled`, decided on the row it would revive, changing nothing (a dead tick's successor is already queued, so reviving it would run the kind on two chains) |
//!
//! **The four calls about a held row are fenced on the claim.** `attempts` is
//! the number `claim` returned in `Claimed`, and a call changes the row only
//! while it is still `running` at that number, answering `true`. A worker
//! whose lease lapsed finds the row claimed again at a higher number, so its
//! late answer matches nothing and answers `false`: it must not requeue, free
//! or kill what a second worker now holds. `false` is not an error, and a
//! `Jobs` logs it at `warn` and carries on (ADR 160).
//!
//! Three more are optional, and a `Jobs` refuses a call that its store does
//! not carry rather than faking it: `pushIn(tx, scope, …)` for a store that
//! can join a transaction, `ready()` for one that can be down, and
//! `cancel(scope, id) !bool` for one that can take a queued row back
//! ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
//!
//! **Transactional completion is one more optional group**, for a store whose
//! rows share a database with the caller's own: `Tx`, the transaction type a
//! `run` asks for by pointer; `begin(scope) !Tx`; and `doneIn(tx, scope, id,
//! attempts, now) !bool`, `done` written inside that transaction under the
//! same fence, so the run's writes and the row's `done` commit together or
//! not at all. A kind whose `run` takes a `*Tx` over a store without them is
//! a compile error naming the store. A store may also say `poolSize() u32`,
//! which a queue with such a kind compares to its workers at start, and
//! `single_writer`, a `bool` that makes such a kind declare its own
//! `timeout_ms`.

/// The number a store gives a row. Whatever the store's own key is, it fits
/// in here — a `bigint` does, and so does a counter.
pub const Id = u64;

/// Where a row is.
pub const State = enum {
    queued,
    running,
    done,
    dead,

    /// A `text` column on both databases rather than a Postgres enum type:
    /// the table is created by the caller's migration like any other Row, and
    /// a `CREATE TYPE` the migration would also have to own is a second thing
    /// to keep in step for four words.
    pub const nilo_column = "text";
};

/// What `push` says beyond the payload.
pub const Enqueue = struct {
    /// When it may first run, in microseconds since the epoch.
    run_at: i64,
    /// When it is being pushed, in the same unit and the clock the queue
    /// reads, for `created_at`. Null reads the wall clock: a caller that
    /// drives a store directly need not say, and a `Jobs` always does.
    now: ?i64 = null,
    /// A key that at most one queued-or-running row of this kind may carry.
    /// Never empty: an empty key is a missing value formatted into one, and
    /// every such push would collapse into the first.
    unique: ?[]const u8 = null,
    /// Which due row a free worker takes first.
    priority: Priority = .normal,
};

/// Which due row a free worker takes first, when more than one is due.
///
/// Workers are few and a long job holds one for as long as it runs, so a
/// queue that only orders by `run_at` lets a backfill pushed at nine o'clock
/// stand in front of every small job pushed after it. That is the whole
/// problem this names: not that the backfill is slow, but that it is *in
/// front*.
///
/// A kind declares it beside its `timeout_ms`, because how urgent a kind is
/// belongs to the kind rather than to each call site:
///
/// ```zig
/// pub const priority: job.Priority = .high;
/// ```
///
/// The numbers run the other way round on purpose: `high` is 0 so the claim
/// can order `priority, run_at` ascending and use the same index shape the
/// table already declares. Nobody writes the number.
pub const Priority = enum(i16) {
    high = 0,
    normal = 1,
    low = 2,
};

/// One row a worker has taken.
///
/// `kind` and `payload` are in the Scope's arena, so they live as long as the
/// tick that claimed them and no longer.
pub const Claimed = struct {
    id: Id,
    kind: []const u8,
    payload: []const u8,
    /// Counting this one. `1` the first time a row is run.
    attempts: u32,
    /// When it was due, for a schedule deciding whether it is too late.
    run_at: i64,
};

/// How the queue is doing.
pub const Stats = struct {
    queued: u64,
    running: u64,
    dead: u64,
};

/// A row that failed for the last time, as `deadOnes` lists it.
pub const Dead = struct {
    id: Id,
    kind: []const u8,
    attempts: u32,
    /// The error's name, and nothing else: an error has no message once it
    /// has left the fiber it happened on.
    err: []const u8,
};

/// Wider than any store needs so the number is one number everywhere: a
/// kind name in `job.Memory` is a fixed field, and 64 is what `Jobs` refuses
/// past while compiling.
pub const max_kind = 64;

/// The same, for a unique key.
pub const max_unique = 64;

/// And for the error name a row keeps. `@errorName` of anything in std fits.
pub const max_error = 64;
