//! What a store has to answer, and the shapes it answers in.
//!
//! A `Jobs` never names a store type: it is handed one, and asks it these
//! seven questions through whatever methods it has, the way `nilo.Idempotent`
//! asks a Space for `getInto` and `putIfAbsent` rather than for `nilo_cache`
//! ([ADR 0193](../docs/adr/0193-a-request-answered-once-is-answered-the-same-way-again.md)).
//! That is what keeps `job/` importing `nilo_core` and nothing else while
//! `job.Table` sits on a `nilo_sql` Db: the Db type arrives as a parameter,
//! and the layering step never sees an import
//! ([ADR 0198](../docs/adr/0198-a-queue-is-a-table-in-the-database-you-already-have.md)).
//!
//! The contract, in one place so a third store — somebody's Redis, say — has
//! a list to write against:
//!
//! | | |
//! |---|---|
//! | `push(scope, kind, payload, Enqueue) !?Id` | queue one; `null` when `unique` already has a row queued or running |
//! | `claim(scope, now, lease_until) !?Claimed` | take the next due row, or one whose lease ran out, marking it running and counting the attempt |
//! | `done(scope, id) !void` | it worked |
//! | `retry(scope, id, run_at, err) !void` | it failed and will be tried again then |
//! | `dead(scope, id, err) !void` | it failed for the last time |
//! | `release(scope, id) !void` | put it back untouched — the server is going |
//! | `stats(scope) !Stats` | how many are waiting, running and dead |
//!
//! Two more are optional, and a `Jobs` refuses a call that its store does
//! not carry rather than faking it: `pushIn(tx, scope, …)` for a store that
//! can join a transaction, and `ready()` for one that can be down.

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
    /// A key that at most one queued-or-running row of this kind may carry.
    unique: ?[]const u8 = null,
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
