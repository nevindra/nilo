//! nilo_job — work that runs later, again, or on a schedule.
//!
//! ```zig
//! const SendWelcome = struct {
//!     pub const nilo_job = "send-welcome";
//!     pub const retry: job.Retry = .{ .times = 5, .backoff = .{ .exponential = .{ .from_ms = 1_000, .to_ms = 3_600_000 } } };
//!
//!     user_id: u64,
//!     email: Str,
//!
//!     pub fn run(self: SendWelcome, scope: *nilo.Run, mail: *Mailer) !void {
//!         try mail.send(scope, self.email, "Welcome");
//!     }
//! };
//!
//! const Jobs = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Table(sql.Db), .deps = struct { mail: *Mailer } });
//!
//! var jobs: Jobs = .open(gpa, &table, .{ .mail = &mailer }, .{ .workers = 4 });
//! try app.provide(&jobs);
//! try app.spawn(Jobs.serve, .{&jobs});
//!
//! fn register(c: *nilo.Ctx, jobs: *Jobs, body: NewUser) !void {
//!     _ = try jobs.push(c, SendWelcome{ .user_id = 7, .email = body.email }, .{});
//! }
//! ```
//!
//! **A job is a struct: its fields are the payload and `run` is the work.**
//! What `push` stores is the struct as JSON, so a `Str` borrowed from a
//! request may sit in a payload — it is copied at `push`, not carried — and
//! what `run` is handed is the same struct parsed back into the tick's own
//! arena. The two things `nilo.spawn` warns must not travel into it
//! (`docs/guide/background.md`) cannot travel into this: a `Str` is
//! serialised, and `run` takes a `nilo.Run` rather than a `Ctx`, so there is
//! no fail function to call.
//!
//! **The queue is a table in the database the program already has**
//! ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
//! That is what makes `pushIn(&tx, …)` possible — the job row commits with
//! the order row or not at all — and what lets several instances share one
//! queue with `SKIP LOCKED` and no second service. `job.Memory` is the same
//! contract in this process for a test, or for a program that can lose its
//! queue at a restart and says so.
//!
//! **A schedule is a type that makes the caller choose**
//! ([ADR 161](../docs/adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md)):
//! whether two runs may overlap and whether a missed run is caught up are
//! declared on the job or it does not compile, which is the shape ADR 028
//! said would be worth having and `every(ms, f)` was refused for lacking.
//!
//! **At least once.** A worker that dies mid-run leaves a row whose lease
//! runs out, and another worker takes it. So `run` is written to be safe to
//! call twice — the same rule a webhook handler already lives by — and the
//! guide says so on its first page.
//!
//! ## Where it sits
//!
//! A **Fitting**: it borrows the loop and owns no destination
//! ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)). It imports
//! `nilo_core` and nothing else. The store it runs on is a type parameter,
//! so a `job.Table` over a `nilo_sql` Db never costs `job/` an import, and
//! the worker loop is written against `std.Io` — `zig build test-job` runs
//! it under `std.Io.Threaded` with no Engine, which is the layer's entry
//! condition.
//!
//! ## What it is not
//!
//! Not a workflow engine, not a rate limiter for a job kind — `nilo.Gate`
//! inside `run` is that — and not exactly-once. `docs/roadmap.md` carries
//! each of those with what it is waiting for. A kind does say how urgent it
//! is, and the claim takes the most urgent due row (ADR 214), which is as
//! far towards a priority queue as this goes: three levels, no ageing, no
//! preemption.

const std = @import("std");
const core = @import("nilo_core");

const contract = @import("contract.zig");
const cron_mod = @import("cron.zig");

pub const Memory = @import("memory.zig").Memory;
pub const Table = @import("table.zig").Table;

pub const Id = contract.Id;
pub const State = contract.State;
pub const Stats = contract.Stats;
pub const Dead = contract.Dead;
pub const Claimed = contract.Claimed;
pub const Enqueue = contract.Enqueue;
pub const Priority = contract.Priority;

/// How long to wait before trying again, as a function of how many times it
/// has already been tried.
pub const Backoff = union(enum) {
    /// The same wait every time.
    fixed_ms: u32,
    /// Doubling from `from_ms`, and never past `to_ms`.
    exponential: struct { from_ms: u32, to_ms: u32 },
};

/// What happens when `run` fails. A job says this or it does not compile:
/// the number of tries is a promise about somebody's email, and a default
/// nobody read is not one.
pub const Retry = struct {
    /// How many times to try *again* — `0` is one attempt and no more.
    times: u16,
    backoff: Backoff = .{ .fixed_ms = 0 },

    /// One attempt, and a failure is final.
    pub const none: Retry = .{ .times = 0 };

    /// The wait after the attempt numbered `failed` — `1` for the first.
    pub fn delayMs(self: Retry, failed: u32) u64 {
        return switch (self.backoff) {
            .fixed_ms => |ms| ms,
            .exponential => |e| blk: {
                var ms: u64 = e.from_ms;
                var i: u32 = 1;
                while (i < failed and ms < e.to_ms) : (i += 1) ms *= 2;
                break :blk @min(ms, e.to_ms);
            },
        };
    }
};

/// What a schedule does when its previous run is still running.
pub const Overlap = enum {
    /// Do not start another: the tick that falls inside a run is dropped,
    /// and the next one after the run ends is the next one.
    skip,
    /// Start it anyway, on another worker.
    queue,
};

/// What a schedule does with a tick that was missed — because the process
/// was down, or every worker was busy past the next tick.
pub const Missed = enum {
    /// Forget it and wait for the next.
    drop,
    /// Run once for the missed tick, then continue from the clock.
    catch_up,
};

/// When a scheduled job runs.
pub const Schedule = union(enum) {
    cron: cron_mod.Cron,
    every_ms: u64,

    /// The first moment strictly after `after_micros`.
    pub fn next(self: Schedule, after_micros: i64) i64 {
        return switch (self) {
            .cron => |c| c.next(after_micros),
            .every_ms => |ms| after_micros + @as(i64, @intCast(ms)) * std.time.us_per_ms,
        };
    }
};

/// `minute hour day month weekday`, UTC, parsed while compiling. See
/// `cron.zig` for the grammar and the refusals.
pub fn cron(comptime text: []const u8) Schedule {
    return .{ .cron = comptime cron_mod.parse(text) };
}

/// Every so often, from whenever the worker started. For "every ten
/// minutes" where it does not matter which ten.
pub fn every(ms: u64) Schedule {
    return .{ .every_ms = ms };
}

/// What a `status` Space holds about one job, small and flat so it is a
/// value in a `nilo_cache` Space rather than bytes.
pub const Status = struct {
    state: State,
    /// Counting the one in flight, when `running`.
    attempts: u32,
    /// What the run last said through `jobs.progress(tick.id, n)`: a count,
    /// a percentage, a step — the kind decides what the number means. `0`
    /// until it says anything, starts over on every retry, and is kept on
    /// a row that finished ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
    progress: u32 = 0,
};

/// Which tick this is, for a `run` that asks for one beside its deps —
/// `pub fn run(self: Export, scope: *nilo.Run, tick: job.Tick, db: *Db)`.
/// By value, the way request data is in a handler: a pointer is a service,
/// a value is the tick. Everything here was already in the worker's hand
/// when it claimed the row, so asking costs nothing
/// ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
pub const Tick = struct {
    /// The row's id — what `jobs.status` and `jobs.progress` take.
    id: Id,
    /// Counting this one: `1` the first time the row is run.
    attempts: u32,
    /// When the row was due, in microseconds since the epoch.
    run_at: i64,
    /// Whether this is the last attempt `retry` allows — `attempts` is
    /// `retry.times + 1` — for "on the last try, use the fallback
    /// provider". About the count only: a failure in `final` is dead on
    /// any attempt, and this does not know which error is coming.
    last: bool,
};

/// A value for a `.within` Space: it has nothing to say, and a `cache.Space`
/// wants a flat type rather than `void`.
pub const Mark = struct {};

/// The `Settings` a `Jobs` is opened with.
pub const Settings = struct {
    /// How many rows may run at once in this process. Each is a fiber, and a
    /// fiber holds its stack at its high-water mark for as long as it lives
    /// ([ADR 062](../docs/adr/062-where-a-connection-waits-is-what-it-costs.md)),
    /// so this is paid per worker rather than per row.
    workers: u16 = 4,
    /// How long a worker with nothing to do waits before asking the store
    /// again, **when nothing wakes it first**. A `push` from this process
    /// wakes a worker itself, so this is the latency only of a row pushed by
    /// *another* process — a second binary on the same table — and the cost
    /// of an idle queue: one query per worker per interval
    /// ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
    poll_ms: u32 = 1_000,
    /// How long one run may take, for a kind that names no `timeout_ms` of
    /// its own. Past it the run is cancelled and the row goes back to the
    /// queue; it is also the lease, so a worker that dies holding a row
    /// gives it up after this long.
    timeout_ms: u32 = 60_000,
};

/// The unique key every scheduled kind's next-tick row carries, so that a
/// second instance seeding the same schedule finds the row already there.
const schedule_key = "schedule";

/// A queue of the kinds it was told about, over the store it was given.
///
/// `options` is a struct written at the call site:
///
/// | | |
/// |---|---|
/// | `.kinds` | a tuple of job types, each with `nilo_job`, `retry` and `run` |
/// | `.store` | `job.Memory`, `job.Table(Db)`, or anything carrying the contract in `contract.zig` |
/// | `.deps` | optional: a struct of pointers a `run` may ask for by type — or a `fn (comptime Jobs: type) type` answering one, for a `run` that takes `*Jobs` (ADR 160) |
/// | `.status` | optional: a `cache.Space` of `job.Status`, kept per row for a route to poll |
pub fn Jobs(comptime options: anytype) type {
    const Options = @TypeOf(options);
    if (!@hasField(Options, "kinds")) @compileError(
        "nilo: `job.Jobs(.{ … })` was given no `.kinds`.\n" ++
            "  `.kinds = .{ SendWelcome, Nightly }` is the list of job types this queue can run.",
    );
    if (!@hasField(Options, "store")) @compileError(
        "nilo: `job.Jobs(.{ … })` was given no `.store`.\n" ++
            "  `.store = job.Table(sql.Db)` for a queue in the database, `job.Memory` for one in this process.",
    );
    const kinds_tuple = options.kinds;
    const KindsTuple = @TypeOf(kinds_tuple);
    const kinds_info = @typeInfo(KindsTuple);
    if (kinds_info != .@"struct" or !kinds_info.@"struct".is_tuple) @compileError(
        "nilo: `job.Jobs`'s `.kinds` is not a list.\n" ++
            "  Write `.kinds = .{ SendWelcome, Nightly }`, a tuple of job types.",
    );
    comptime var kinds_list: [kinds_info.@"struct".fields.len]type = undefined;
    inline for (kinds_info.@"struct".fields, 0..) |f, i| {
        if (f.type != type) @compileError(
            "nilo: `job.Jobs`'s `.kinds` holds something that is not a type at position " ++
                std.fmt.comptimePrint("{d}", .{i}) ++ ".\n" ++
                "  Every entry is a job struct: `.kinds = .{ SendWelcome, Nightly }`.",
        );
        kinds_list[i] = @field(kinds_tuple, f.name);
    }
    const kinds: [kinds_list.len]type = kinds_list;

    const Store = options.store;
    const deps_option = if (@hasField(Options, "deps")) options.deps else struct {};
    // `.deps` is a struct, or a function that makes one from the finished
    // queue type. A struct naming `*Jobs` in a field cannot be written —
    // `Jobs` does not exist while its own argument is being read, and the
    // compiler says `dependency loop` — so the function is handed `Self`
    // once there is one, and everything that reads a `run`'s signature
    // waits for the same moment, because a `run` taking `*Jobs` has the
    // same loop in it ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
    const deps_is_fn = comptime depsIsFn(@TypeOf(deps_option));
    const DepsNow: ?type = if (deps_is_fn) null else deps_option;
    const StatusSpace = if (@hasField(Options, "status")) options.status else void;

    comptime checkKinds(&kinds, DepsNow);
    comptime checkStore(Store);
    comptime checkStatus(StatusSpace);

    return struct {
        const Self = @This();

        /// What a nilo compile error calls this type (ADR 074).
        pub const nilo_type_name = "job.Jobs";

        /// The struct of pointers a `run` may ask for: `.deps` as written,
        /// or what `.deps(Jobs)` answered when it was a function.
        pub const Deps: type = if (deps_is_fn) deps_option(Self) else deps_option;

        /// The checks that read a `run`'s signature, for a queue whose
        /// `.deps` is a function: they cannot run in `Jobs(…)`'s body,
        /// where a `run` naming `*Jobs` is the loop above, so they hang off
        /// this and every entry point names it. One declaration, so a
        /// Refusal is reported once however many of them are analysed.
        const late_checked: bool = blk: {
            if (deps_is_fn) checkLate(&kinds, Deps);
            break :blk true;
        };

        /// The store's table Row, for `db.checking(.{ .tables = &.{ Jobs.Row } })` and a
        /// migration. `void` for a store that has no table.
        pub const Row = if (@hasDecl(Store, "Row")) Store.Row else void;

        /// The names as the store sees them. The claim binds these and asks
        /// only for them, so a row of a kind this program does not know is
        /// left where it is for the binary that does know it.
        pub const kind_names: [kinds.len][]const u8 = blk: {
            var out: [kinds.len][]const u8 = undefined;
            for (kinds, 0..) |K, i| out[i] = K.nilo_job;
            break :blk out;
        };

        gpa: std.mem.Allocator,
        store: *Store,
        deps: Deps,
        settings: Settings,
        statuses: if (StatusSpace == void) void else StatusSpace,
        io: ?std.Io = null,
        limits: core.Limits = .none,
        /// Set once the server is going, so a worker that has just finished
        /// a row does not claim another.
        stopping: std.atomic.Value(bool) = .init(false),
        /// Bumped by every `push` and every `wake`, and what an idle worker
        /// sleeps on. A worker reads it before it asks the store and sleeps
        /// only while it is still that number, so a push that lands between
        /// the empty answer and the sleep is not missed
        /// ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
        wakes: std.atomic.Value(u32) = .init(0),
        /// How many worker loops are alive, for the health page.
        alive: std.atomic.Value(u32) = .init(0),
        /// Whether `serve` has been called, so `nilo_ready` can tell "no
        /// worker yet" from "no worker any more".
        serving: std.atomic.Value(bool) = .init(false),

        pub const Error = error{
            /// A row was pushed with a payload the store cannot hold.
            PayloadTooLarge,
            /// `job.Memory` is full. Nothing was written over.
            QueueFull,
            OutOfMemory,
        };

        /// `status` is the opened Space when `options.status` names one, and
        /// left out otherwise: `.open(gpa, &store, deps, .{})`.
        pub fn open(
            gpa: std.mem.Allocator,
            store: *Store,
            deps: Deps,
            settings: Settings,
        ) Self {
            comptime {
                _ = late_checked;
            }
            comptime if (StatusSpace != void) @compileError(
                "nilo: this `job.Jobs` names a `.status` Space, so it is opened with `openWith` and the Space.\n" ++
                    "  `Jobs.openWith(gpa, &store, deps, settings, Statuses.open(&cache))`",
            );
            return .{ .gpa = gpa, .store = store, .deps = deps, .settings = settings, .statuses = {} };
        }

        /// `open`, plus the Space statuses are kept in.
        pub fn openWith(
            gpa: std.mem.Allocator,
            store: *Store,
            deps: Deps,
            settings: Settings,
            space: StatusSpace,
        ) Self {
            comptime {
                _ = late_checked;
            }
            comptime if (StatusSpace == void) @compileError(
                "nilo: this `job.Jobs` names no `.status` Space, so there is nothing for `openWith` to take.\n" ++
                    "  Add `.status = Statuses` to the `job.Jobs(.{ … })`, or call `open`.",
            );
            return .{ .gpa = gpa, .store = store, .deps = deps, .settings = settings, .statuses = space };
        }

        // -- as a service ---------------------------------------------------

        /// Finished when the loop exists, like every service (ADR 037). The
        /// `Io` is what `serve` runs the workers on and the limits are what
        /// bound one run in time (ADR 056).
        pub fn nilo_start(self: *Self, io: std.Io, limits: core.Limits) !void {
            self.io = io;
            self.limits = limits;
        }

        /// What `app.health` asks (ADR 154): the store, if it can be down,
        /// and whether any worker is alive once `serve` has been started.
        pub fn nilo_ready(self: *Self, scope: *core.AnyScope) ?[]const u8 {
            _ = scope;
            if (self.io == null) return "not started: `listen()` has not run";
            if (@hasDecl(Store, "ready")) {
                if (self.store.ready()) |why| return why;
            }
            if (self.serving.load(.acquire) and self.alive.load(.acquire) == 0 and self.settings.workers > 0)
                return "no worker is running";
            return null;
        }

        // -- pushing --------------------------------------------------------

        /// What `push` takes beside the job. Everything defaults, so `.{}` is
        /// the ordinary call.
        ///
        /// `.unique` makes at most one queued-or-running row carry the key;
        /// the answer is then `?Id`, null when one already did. `.within` is
        /// a `cache.Space` of `job.Mark` put in front of it, for the case
        /// "at most one of these every thirty seconds" where a miss costs a
        /// second run and not a wrong one.
        pub fn push(self: *Self, scope: anytype, value: anytype, opts: anytype) !PushAnswer(@TypeOf(opts)) {
            comptime {
                _ = late_checked;
            }
            comptime core.checkScope(@TypeOf(scope), "jobs.push");
            const K = @TypeOf(value);
            comptime assertKind(K, "push");
            const o = comptime readPush(@TypeOf(opts));
            const now = core.nowMicros();
            const run_at: i64 = if (@hasField(@TypeOf(opts), "at")) opts.at else now + @as(i64, @intCast(o.after_ms(opts))) * std.time.us_per_ms;
            const unique: ?[]const u8 = if (o.unique) opts.unique else null;

            if (o.within) {
                comptime if (!o.unique) @compileError(
                    "nilo: `jobs.push` was given `.within` and no `.unique`, and a window needs a key to hold.\n" ++
                        "  `.{ .unique = key, .within = window }` — the key is what the window remembers.",
                );
                if (!opts.within.putIfAbsent(unique.?, Mark{})) return null;
            }

            const priority: contract.Priority = if (@hasDecl(K, "priority")) K.priority else .normal;
            const bytes = try std.json.Stringify.valueAlloc(scope.arena(), value, .{});
            const id = try self.store.push(scope, K.nilo_job, bytes, .{ .run_at = run_at, .unique = unique, .priority = priority });
            if (o.unique) {
                if (id) |i| {
                    self.note(i, .queued, 0);
                    if (run_at <= now) self.wakeOne();
                }
                return id;
            }
            const i = id orelse unreachable;
            self.note(i, .queued, 0);
            // A row due later is the poll's to find; waking a worker for it
            // would be one empty claim now and the same wait after.
            if (run_at <= now) self.wakeOne();
            return i;
        }

        /// `push` inside a transaction the caller holds, for a store that can
        /// join one — so the row commits with the caller's rows or not at
        /// all. `job.Memory` refuses this while compiling.
        ///
        /// **Nothing is woken here**, because the row is not there yet: a
        /// worker woken now would claim before the commit and find nothing.
        /// Call `wake` after `tx.commit()`, or let the next poll find it.
        pub fn pushIn(self: *Self, tx: anytype, scope: anytype, value: anytype, opts: anytype) !PushAnswer(@TypeOf(opts)) {
            comptime core.checkScope(@TypeOf(scope), "jobs.pushIn");
            comptime if (!@hasDecl(Store, "pushIn")) @compileError(
                "nilo: `jobs.pushIn` was called on a queue over " ++ shortName(Store) ++ ", which cannot join a transaction.\n" ++
                    "  A row in memory has nothing to commit with. Use `push`, or a `job.Table` over the database the transaction is on.",
            );
            const K = @TypeOf(value);
            comptime assertKind(K, "pushIn");
            const o = comptime readPush(@TypeOf(opts));
            comptime if (o.within) @compileError(
                "nilo: `jobs.pushIn` was given `.within`, and a window in a cache cannot roll back with the transaction.\n" ++
                    "  Use `.unique` alone here; the table holds it.",
            );
            const now = core.nowMicros();
            const run_at: i64 = if (@hasField(@TypeOf(opts), "at")) opts.at else now + @as(i64, @intCast(o.after_ms(opts))) * std.time.us_per_ms;
            const unique: ?[]const u8 = if (o.unique) opts.unique else null;
            const priority: contract.Priority = if (@hasDecl(K, "priority")) K.priority else .normal;

            const bytes = try std.json.Stringify.valueAlloc(scope.arena(), value, .{});
            const id = try self.store.pushIn(tx, scope, K.nilo_job, bytes, .{ .run_at = run_at, .unique = unique, .priority = priority });
            if (o.unique) {
                if (id) |i| self.note(i, .queued, 0);
                return id;
            }
            const i = id orelse unreachable;
            self.note(i, .queued, 0);
            return i;
        }

        fn PushAnswer(comptime O: type) type {
            return if (@hasField(O, "unique")) ?Id else Id;
        }

        /// Wake every idle worker, for a row nilo did not see arrive: one
        /// pushed by another process, or by `pushIn` under a transaction that
        /// has since committed. A worker that is running a row is not
        /// interrupted; it asks the store when it is done, as it always did.
        ///
        /// Safe before `serve` and safe with no worker at all — the bump is
        /// kept, so the first worker to look asks the store straight away.
        pub fn wake(self: *Self) void {
            _ = self.wakes.fetchAdd(1, .release);
            if (self.io) |io| io.futexWake(u32, &self.wakes.raw, std.math.maxInt(u32));
        }

        /// One worker, for one row. Waking all of them for one push would
        /// be `workers - 1` empty claims against the store every time.
        fn wakeOne(self: *Self) void {
            _ = self.wakes.fetchAdd(1, .release);
            if (self.io) |io| io.futexWake(u32, &self.wakes.raw, 1);
        }

        const PushOpts = struct {
            unique: bool,
            within: bool,
            has_after: bool,
            fn after_ms(comptime self: @This(), opts: anytype) u64 {
                return if (self.has_after) opts.after_ms else 0;
            }
        };

        fn readPush(comptime O: type) PushOpts {
            const info = @typeInfo(O);
            if (info != .@"struct") @compileError(
                "nilo: `jobs.push`'s last argument is the options and it has to be a struct.\n" ++
                    "  `.{}` for none; `.{ .after_ms = 60_000 }`, `.{ .at = micros }`, `.{ .unique = key }`.",
            );
            for (info.@"struct".fields) |f| {
                if (!std.mem.eql(u8, f.name, "unique") and !std.mem.eql(u8, f.name, "within") and
                    !std.mem.eql(u8, f.name, "after_ms") and !std.mem.eql(u8, f.name, "at"))
                    @compileError("nilo: `jobs.push` does not know the option `." ++ f.name ++ "`.\n" ++
                        "  The options are `.after_ms`, `.at`, `.unique` and `.within`.");
            }
            if (@hasField(O, "after_ms") and @hasField(O, "at")) @compileError(
                "nilo: `jobs.push` was given both `.after_ms` and `.at`, and a row runs at one time.",
            );
            return .{
                .unique = @hasField(O, "unique"),
                .within = @hasField(O, "within"),
                .has_after = @hasField(O, "after_ms"),
            };
        }

        // -- asking -----------------------------------------------------------

        pub fn stats(self: *Self, scope: anytype) !Stats {
            comptime core.checkScope(@TypeOf(scope), "jobs.stats");
            return self.store.stats(scope);
        }

        /// What the `status` Space says about a row, or null when there is no
        /// Space, no row, or it has expired out of the Space.
        pub fn status(self: *Self, id: Id) ?Status {
            if (StatusSpace == void) return null;
            var buf: [20]u8 = undefined;
            return self.statuses.get(idKey(&buf, id));
        }

        /// How far a run has got, into the `status` Space, for the route
        /// that polls `status(id)`: `jobs.progress(tick.id, rows_done)`,
        /// from inside `run` with a `job.Tick` and a `*Jobs` beside it. The
        /// number means what the kind says it means. Nothing happens when
        /// there is no Space; a row the Space has forgotten is remembered
        /// again as `running` ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
        pub fn progress(self: *Self, id: Id, n: u32) void {
            if (StatusSpace == void) return;
            var buf: [20]u8 = undefined;
            const key = idKey(&buf, id);
            const was: Status = self.statuses.get(key) orelse .{ .state = .running, .attempts = 0 };
            self.statuses.put(key, .{ .state = was.state, .attempts = was.attempts, .progress = n });
        }

        /// The rows that failed for the last time, newest first.
        pub fn deadOnes(self: *Self, scope: anytype) ![]Dead {
            comptime core.checkScope(@TypeOf(scope), "jobs.deadOnes");
            return self.store.deadOnes(scope);
        }

        /// Queue a dead row again from its first attempt. `false` when there
        /// is no dead row with that id.
        pub fn retryDead(self: *Self, scope: anytype, id: Id) !bool {
            comptime core.checkScope(@TypeOf(scope), "jobs.retryDead");
            const did = try self.store.retryDead(scope, id, core.nowMicros());
            if (did) self.note(id, .queued, 0);
            return did;
        }

        /// Take a queued row back before it runs: the export whose dialog
        /// was closed, the nudge for somebody who has since unsubscribed.
        /// `true` when a `queued` row went; `false` when it is running,
        /// finished or absent, because a row a worker holds is that
        /// worker's to finish and nothing here interrupts a `run`. With a
        /// `unique` key, a cancel and a push is how "move it to tomorrow"
        /// is written ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
        pub fn cancel(self: *Self, scope: anytype, id: Id) !bool {
            comptime core.checkScope(@TypeOf(scope), "jobs.cancel");
            comptime if (!@hasDecl(Store, "cancel")) @compileError(
                "nilo: `jobs.cancel` was called on a queue over " ++ shortName(Store) ++ ", which has no `cancel`.\n" ++
                    "  A store that can take a queued row back declares `cancel(scope, id) !bool`; `job.Memory` and `job.Table` both do.",
            );
            const did = try self.store.cancel(scope, id);
            // The row is gone, so what the Space said about it is stale:
            // a route polling `status(id)` should hear nothing rather than
            // `queued` until the entry expires.
            if (did and StatusSpace != void and comptime @hasDecl(StatusSpace, "del")) {
                var buf: [20]u8 = undefined;
                _ = self.statuses.del(idKey(&buf, id));
            }
            return did;
        }

        // -- serving --------------------------------------------------------

        /// The worker loop, for `app.spawn(Jobs.serve, .{&jobs})`. It may not
        /// fail — there is nobody to answer — and `error.Canceled` from the
        /// loop is the shutdown, which is the one way out (ADR 028).
        pub fn serve(self: *Self) void {
            comptime {
                _ = late_checked;
            }
            const io = self.io orelse {
                std.log.scoped(.nilo_job).err("serve: not started — `listen()` or `app.start(io)` has not run, so there is no loop to run workers on", .{});
                return;
            };
            self.serveOn(io) catch {};
        }

        /// The same loop on an `Io` of the caller's, for a worker process with
        /// no server in it. Returns when cancelled.
        pub fn serveOn(self: *Self, io: std.Io) std.Io.Cancelable!void {
            comptime {
                _ = late_checked;
            }
            self.serving.store(true, .release);
            // A worker process with no server never called `nilo_start`, and
            // `wake` needs an `Io` to reach a sleeping worker through. The one
            // the workers run on is the right one.
            if (self.io == null) self.io = io;
            {
                var run: core.Run = .initIo(self.gpa, io);
                defer run.deinit();
                self.seedAt(&run, core.nowMicros()) catch |err| {
                    std.log.scoped(.nilo_job).err("seeding schedules: {t}", .{err});
                };
            }

            var group: std.Io.Group = .init;
            var started: u16 = 0;
            while (started < self.settings.workers) : (started += 1) {
                group.concurrent(io, worker, .{ self, io }) catch break;
            }
            if (started == 0) {
                // No concurrency to be had — a single-threaded `Io`. This
                // fiber is the one worker, then.
                return worker(self, io);
            }
            return group.await(io);
        }

        /// Run everything that is due, now, on this thread, and say how many.
        /// For a test: push, drain, assert. No worker, no `Io`, no deadline.
        /// `drainAt` with the clock read once: what is due is due against
        /// that one reading, so a schedule of `every(1)` cannot keep a drain
        /// going for as long as a tick takes.
        pub fn drain(self: *Self, scope: anytype) !usize {
            return self.drainAt(scope, core.nowMicros());
        }

        /// `drain` as if it were `now` — microseconds since the epoch, the
        /// unit `nilo.nowMicros` answers in and `push`'s `.at` takes. Every
        /// read of the clock inside a tick reads this number: whether a row
        /// is due, whether a schedule's tick is missed, when a failed run is
        /// tried again, when the next tick is. A test moves time by calling
        /// this with a later number, and nothing is slept
        /// ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
        pub fn drainAt(self: *Self, scope: anytype, now: i64) !usize {
            comptime core.checkScope(@TypeOf(scope), "jobs.drain");
            var n: usize = 0;
            while (try self.runOneAt(scope, now)) n += 1;
            return n;
        }

        /// Claim one due row and run it, on this thread. `false` when nothing
        /// was due.
        pub fn runOne(self: *Self, scope: anytype) !bool {
            return self.runOneAt(scope, core.nowMicros());
        }

        /// `runOne` as if it were `now`, the way `drainAt` is `drain`.
        pub fn runOneAt(self: *Self, scope: anytype, now: i64) !bool {
            comptime {
                _ = late_checked;
            }
            comptime core.checkScope(@TypeOf(scope), "jobs.runOne");
            const claimed = try self.store.claim(scope, &kind_names, now, now + self.leaseMicros()) orelse return false;
            self.execute(scope, claimed, .{ .fixed = now });
            return true;
        }

        /// Queue the next tick of every scheduled kind, the way `serve` does
        /// when it starts. For a test that drains rather than serves: seed,
        /// then `drainAt` the moment the schedule names. Seeding twice is the
        /// same rows, since a tick's key is unique.
        pub fn seed(self: *Self, scope: anytype) !void {
            return self.seedAt(scope, core.nowMicros());
        }

        /// `seed` as if it were `now`: the first tick is the first one
        /// strictly after that moment.
        pub fn seedAt(self: *Self, scope: anytype, now: i64) !void {
            comptime core.checkScope(@TypeOf(scope), "jobs.seed");
            inline for (kinds) |K| {
                if (comptime scheduled(K)) self.pushNext(K, scope, now);
            }
        }

        fn leaseMicros(self: *Self) i64 {
            // The longest any kind may run, plus a second so a run that
            // finished on its last millisecond is not also reclaimed.
            var longest: u64 = self.settings.timeout_ms;
            inline for (kinds) |K| {
                if (@hasDecl(K, "timeout_ms")) longest = @max(longest, K.timeout_ms);
            }
            return @intCast((longest + 1_000) * std.time.us_per_ms);
        }

        fn worker(self: *Self, io: std.Io) std.Io.Cancelable!void {
            _ = self.alive.fetchAdd(1, .acq_rel);
            defer _ = self.alive.fetchSub(1, .acq_rel);

            var run: core.Run = .initIo(self.gpa, io);
            defer run.deinit();

            const poll: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(self.settings.poll_ms), .clock = .awake } };
            while (!self.stopping.load(.acquire)) {
                defer run.reset();
                // A queue that is never empty is a loop that never sleeps, and
                // a cancellation is only seen at an `Io` call — so ask for it
                // here, or a busy worker would outlive the shutdown.
                try io.checkCancel();
                // Read *before* the claim. A push that lands after the store
                // said "nothing" and before the sleep bumps this, and the
                // futex below then returns at once rather than waiting out
                // the poll on a row that is already there.
                const seen = self.wakes.load(.acquire);
                const now = core.nowMicros();
                const claimed = self.store.claim(&run, &kind_names, now, now + self.leaseMicros()) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    // A claim the shutdown cut off answers `QueryFailed` with
                    // the cancellation left pending (ADR 223): leave on it,
                    // rather than log a failure and sleep into it.
                    try io.checkCancel();
                    std.log.scoped(.nilo_job).err("claim: {t}", .{err});
                    try io.sleep(poll.duration.raw, .awake);
                    continue;
                };
                if (claimed) |c| {
                    self.execute(&run, c, .wall);
                } else {
                    // Until a push wakes it or the poll runs out, whichever
                    // is first. A timeout comes back as a plain return, and
                    // so does a spurious wake — either way the loop asks the
                    // store, which is the only answer that counts.
                    try io.futexWaitTimeout(u32, &self.wakes.raw, seen, poll);
                }
            }
        }

        /// One row: parse, run, and tell the store what happened. Never
        /// fails, because there is nobody to fail to; everything it cannot
        /// handle goes to the log and the row.
        fn execute(self: *Self, scope: anytype, claimed: Claimed, clock: Clock) void {
            inline for (kinds) |K| {
                if (std.mem.eql(u8, claimed.kind, K.nilo_job)) return self.executeKind(K, scope, claimed, clock);
            }
            // A row from a binary that knows a kind this one does not. Not
            // ours to run and not ours to lose: back in the queue, where the
            // binary that pushed it will find it.
            std.log.scoped(.nilo_job).warn("row {d} is a \"{s}\", which this program has no job for; leaving it", .{ claimed.id, claimed.kind });
            self.store.release(scope, claimed.id) catch |err| {
                std.log.scoped(.nilo_job).err("releasing row {d}: {t}", .{ claimed.id, err });
            };
        }

        fn executeKind(self: *Self, comptime K: type, scope: anytype, claimed: Claimed, clock: Clock) void {
            const log = std.log.scoped(.nilo_job);
            const retry: Retry = K.retry;
            const now = clock.now();

            // Past the last retry already — a row that was reclaimed after its
            // lease ran out one time too many, which is what a crash loop
            // looks like from the table.
            if (claimed.attempts > @as(u32, retry.times) + 1) {
                self.finishDead(scope, claimed.id, K, "LeaseExpired", claimed.attempts, clock);
                return;
            }

            if (comptime scheduled(K)) {
                // A tick later than its own successor is a missed one.
                if (K.missed == .drop and K.schedule.next(claimed.run_at) <= now) {
                    self.store.done(scope, claimed.id) catch |err| log.err("row {d}: {t}", .{ claimed.id, err });
                    self.note(claimed.id, .done, claimed.attempts);
                    self.pushNext(K, scope, now);
                    return;
                }
                if (K.overlap == .queue) self.pushNext(K, scope, now);
            }

            var value = std.json.parseFromSliceLeaky(K, scope.arena(), claimed.payload, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                // A payload this binary cannot read is not going to become
                // readable by trying again.
                self.finishDead(scope, claimed.id, K, @errorName(err), claimed.attempts, clock);
                return;
            };
            // `Str.jsonParse` answers `static`, because a parser has no idea
            // which piece of work is running — so a payload `Str` held past
            // its tick would pass the Debug trap that catches the same
            // mistake in a handler. Stamped through the Scope here, the way
            // `Ctx.json` stamps a body, and it goes stale when the tick's
            // Scope is reset.
            core.stampWith(&value, scope);

            var bound: core.Limits.Bound = .idle;
            defer bound.release();
            bound.arm(self.limits, if (@hasDecl(K, "timeout_ms")) K.timeout_ms else self.settings.timeout_ms);

            const tick: Tick = .{
                .id = claimed.id,
                .attempts = claimed.attempts,
                .run_at = claimed.run_at,
                .last = claimed.attempts > retry.times,
            };
            const outcome = self.call(K, value, scope, tick);
            // Asked once: the answer is consumed, and asking is what spends
            // the deadline's own cancellation (`Bound.fired`).
            const timed_out = bound.fired();
            // The server is going when the run says so, or when it says
            // something else about a statement a cancellation cut off:
            // nilo_sql answers that `QueryFailed` and leaves the cancellation
            // pending, so the fiber is what to ask — before the protection
            // below, under which it would answer that nothing is pending.
            const going = if (outcome) |_| false else |err| !timed_out and (err == error.Canceled or self.cancelPending());
            // What the row is told from here on is cleanup, and a shutdown
            // must not stop it: a cancellation a statement handed back
            // pending (ADR 223) would fail the `done`, the `retry` or the
            // `release` below and leave the row `running` until its lease
            // is over. Held off the way nilo_sql holds off a `ROLLBACK`; the
            // cancellation stays pending for the loop, which leaves on it.
            const protected = if (self.io) |io| io.swapCancelProtection(.blocked) else null;
            defer if (self.io) |io| {
                _ = io.swapCancelProtection(protected.?);
            };
            if (outcome) |_| {
                self.store.done(scope, claimed.id) catch |err| log.err("row {d}: {t}", .{ claimed.id, err });
                self.note(claimed.id, .done, claimed.attempts);
                // The clock read again, not `now`: under a worker the next
                // tick is counted from when this one ended, which is what
                // `.skip` promises. Under `drainAt` it is the same number.
                if (comptime scheduled(K)) self.pushNext(K, scope, clock.now());
                return;
            } else |err| {
                if (going) {
                    // The row never ran to the end, so it goes back
                    // untouched; whoever starts next takes it.
                    self.stopping.store(true, .release);
                    self.store.release(scope, claimed.id) catch |e| log.err("row {d}: {t}", .{ claimed.id, e });
                    self.note(claimed.id, .queued, claimed.attempts -| 1);
                    return;
                }
                const name = if (timed_out) "TimedOut" else @errorName(err);
                // A failure the kind said is final is dead on this attempt,
                // whatever the count says; a timeout never is, because the
                // next attempt may finish
                // ([ADR 179](../docs/adr/179-a-run-can-say-its-failure-is-final.md)).
                if (claimed.attempts > retry.times or (!timed_out and isFinal(K, err))) {
                    self.finishDead(scope, claimed.id, K, name, claimed.attempts, clock);
                    return;
                }
                const again = clock.now() + @as(i64, @intCast(retry.delayMs(claimed.attempts))) * std.time.us_per_ms;
                log.warn("\"{s}\" row {d} failed with {s} on attempt {d}; again in {d}ms", .{
                    K.nilo_job, claimed.id, name, claimed.attempts, retry.delayMs(claimed.attempts),
                });
                self.store.retry(scope, claimed.id, again, name) catch |e| log.err("row {d}: {t}", .{ claimed.id, e });
                self.note(claimed.id, .queued, claimed.attempts);
            }
        }

        /// Whether this fiber has a cancellation pending, put back for the
        /// worker loop to leave on: `checkCancel` spends it to answer.
        fn cancelPending(self: *Self) bool {
            const io = self.io orelse return false;
            std.Io.checkCancel(io) catch {
                io.recancel();
                return true;
            };
            return false;
        }

        /// Whether `err` is one the kind declared final. An `inline for` over
        /// the set's names, so a kind with no `final` costs nothing here.
        fn isFinal(comptime K: type, err: anyerror) bool {
            if (comptime !@hasDecl(K, "final")) return false;
            inline for (comptime @typeInfo(K.final).error_set.?) |e| {
                if (err == @field(anyerror, e.name)) return true;
            }
            return false;
        }

        /// `warn` rather than `err`, and not because a dead row is minor: the
        /// test runner counts an `err` line as a failed run, so a module that
        /// logs `err` on a path a test takes is a module that path cannot be
        /// tested on (`sql/db.zig`'s `enumOf` has the same note). A store that
        /// cannot be written to is `err` — nothing here takes that path on
        /// purpose.
        fn finishDead(self: *Self, scope: anytype, id: Id, comptime K: type, name: []const u8, attempts: u32, clock: Clock) void {
            std.log.scoped(.nilo_job).warn("\"{s}\" row {d} is dead after {d} attempt(s): {s}", .{ K.nilo_job, id, attempts, name });
            self.store.dead(scope, id, name) catch |e| std.log.scoped(.nilo_job).err("row {d}: {t}", .{ id, e });
            self.note(id, .dead, attempts);
            // A schedule whose tick died still has a next tick.
            if (comptime scheduled(K)) self.pushNext(K, scope, clock.now());
        }

        /// `K.run` with its arguments found: the value, the Scope, the tick
        /// where a `job.Tick` is asked for, and every pointer looked up in
        /// `deps` by type.
        fn call(self: *Self, comptime K: type, value: K, scope: anytype, tick: Tick) anyerror!void {
            const params = @typeInfo(@TypeOf(K.run)).@"fn".params;
            var args: std.meta.ArgsTuple(@TypeOf(K.run)) = undefined;
            args[0] = value;
            args[1] = runOf(scope);
            inline for (params[2..], 2..) |p, i| {
                const P = p.type.?;
                if (P == Tick) {
                    args[i] = tick;
                } else {
                    args[i] = @field(self.deps, depField(shortName(K), Deps, P));
                }
            }
            const R = @typeInfo(@TypeOf(K.run)).@"fn".return_type.?;
            if (@typeInfo(R) == .error_union) {
                return @call(.auto, K.run, args);
            }
            @call(.auto, K.run, args);
        }

        /// A `run` takes a `*nilo.Run`. Under a worker the Scope is one; under
        /// `drain` in a test it is whatever the test passed, which is also one
        /// in every test written so far — and a `*Ctx` is refused here rather
        /// than coerced, because a job that ran under a request would be a
        /// job that could call a fail function.
        fn runOf(scope: anytype) *core.Run {
            const S = @TypeOf(scope);
            if (S != *core.Run) @compileError(
                "nilo: `jobs.drain` and `jobs.runOne` take a `*nilo.Run`, and were given " ++ @typeName(S) ++ ".\n" ++
                    "  A job runs outside any request, so the Scope it is handed is a Run — build one with `nilo.Run.init(gpa)`.",
            );
            return scope;
        }

        /// The next turn of a scheduled kind, queued with the same urgency
        /// as the one that just ran. Dropping it here would let a kind
        /// declare `.high`, pass every check, and run `.normal` forever —
        /// the schedule is the only path that pushes a row nobody wrote a
        /// `push` call for.
        fn pushNext(self: *Self, comptime K: type, scope: anytype, after: i64) void {
            const at = K.schedule.next(after);
            const priority: contract.Priority = if (@hasDecl(K, "priority")) K.priority else .normal;
            _ = self.store.push(scope, K.nilo_job, "{}", .{ .run_at = at, .unique = schedule_key, .priority = priority }) catch |err| {
                std.log.scoped(.nilo_job).err("queueing the next \"{s}\": {t}", .{ K.nilo_job, err });
            };
        }

        fn note(self: *Self, id: Id, state: State, attempts: u32) void {
            if (StatusSpace == void) return;
            var buf: [20]u8 = undefined;
            const key = idKey(&buf, id);
            // A row that finished keeps the last figure its run gave, so
            // "done, 4,000 rows" survives the `done`; every other change of
            // state is a run starting over, and the figure starts with it.
            const kept: u32 = if (state == .done)
                (if (self.statuses.get(key)) |was| was.progress else 0)
            else
                0;
            self.statuses.put(key, .{ .state = state, .attempts = attempts, .progress = kept });
        }

        fn idKey(buf: *[20]u8, id: Id) []const u8 {
            return std.fmt.bufPrint(buf, "{d}", .{id}) catch unreachable;
        }

        fn assertKind(comptime K: type, comptime called: []const u8) void {
            for (kinds) |Known| {
                if (Known == K) return;
            }
            @compileError(
                "nilo: `jobs." ++ called ++ "` was handed a " ++ shortName(K) ++ ", and this queue has no such job.\n" ++
                    "  A row nobody can run would sit in the table forever. Add it to `.kinds` in the `job.Jobs(.{ … })`.",
            );
        }
    };
}

fn scheduled(comptime K: type) bool {
    return @hasDecl(K, "schedule");
}

/// What time a tick reads. A worker reads the wall clock, and reads it
/// again after the run, so a `.skip` schedule counts from when the run
/// ended; `drainAt` hands every read the one number it was given, so a
/// test can say what time it is and a tick cannot drift past it
/// ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
/// One tag test per read, per row — nothing a request pays.
const Clock = union(enum) {
    wall,
    fixed: i64,

    fn now(self: Clock) i64 {
        return switch (self) {
            .wall => core.nowMicros(),
            .fixed => |t| t,
        };
    }
};

/// Whether `.deps` was written as a function of the queue type rather than
/// a struct, refusing anything that is neither in nilo's words.
fn depsIsFn(comptime T: type) bool {
    if (T == type) return false;
    const info = @typeInfo(T);
    if (info != .@"fn") @compileError(
        "nilo: `job.Jobs`'s `.deps` is a value of type " ++ @typeName(T) ++ ", and it has to be a struct of pointers, or a function that makes one.\n" ++
            "  `.deps = struct { db: *Db, mail: *Mailer }` — one field per service a `run` may ask for.",
    );
    const f = info.@"fn";
    const returns_a_type = f.return_type == null or f.return_type.? == type;
    const takes_a_type = f.params.len == 1 and (f.params[0].type == null or f.params[0].type.? == type);
    if (!returns_a_type or !takes_a_type) @compileError(
        "nilo: `job.Jobs`'s `.deps` is a function, and it does not have the shape `fn (comptime Jobs: type) type`.\n" ++
            "  A `run` that pushes the next job asks for `*Jobs`, and `Jobs` does not exist while its own `.deps` is being read, " ++
            "so the function is handed the finished type instead:\n" ++
            "  `fn deps(comptime Queue: type) type { return struct { jobs: *Queue, mail: *Mailer }; }` and `.deps = deps` (ADR 160).",
    );
    return true;
}

/// The field of `Deps` whose type is `P`, or a Refusal naming the job and
/// what its `run` asked for. The one place that message is written: the
/// checks call it while compiling and `call` calls it to build the
/// arguments, so a queue whose checks were deferred and never reached
/// still cannot run a `run` that asks for something nobody gave.
fn depField(comptime name: []const u8, comptime Deps: type, comptime P: type) []const u8 {
    for (@typeInfo(Deps).@"struct".fields) |f| {
        if (f.type == P) return f.name;
    }
    @compileError(
        "nilo: the job " ++ name ++ "'s `run` asks for a " ++ @typeName(P) ++ ", and `job.Jobs`'s `.deps` has no such thing.\n" ++
            "  A worker has no registry to look in; the deps struct is the whole of what a `run` may ask for. " ++
            "Add a field of that type to `.deps` and pass it at `open`.",
    );
}

// -- the checks -----------------------------------------------------------

/// Everything about a kind that can be checked in `Jobs(…)`'s body. `Deps`
/// is null for a queue whose `.deps` is a function: then the deps and every
/// `run`'s signature are read by `checkLate` instead, once the queue type
/// exists, because a `run` that names `*Jobs` cannot be read before it does
/// ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
fn checkKinds(comptime kinds: []const type, comptime Deps: ?type) void {
    if (kinds.len == 0) @compileError(
        "nilo: `job.Jobs`'s `.kinds` is empty, so this queue could run nothing.\n" ++
            "  Give it at least one job type.",
    );
    if (Deps) |D| checkDepsShape(D);

    for (kinds, 0..) |K, i| {
        const name = shortName(K);
        if (@typeInfo(K) != .@"struct") @compileError(
            "nilo: the job " ++ name ++ " is not a struct.\n" ++
                "  A job is a struct: its fields are the payload and `run` is the work.",
        );
        if (!@hasDecl(K, "nilo_job")) @compileError(
            "nilo: the job " ++ name ++ " has no `nilo_job`, so it has no name to be stored under.\n" ++
                "  `pub const nilo_job = \"send-welcome\";` — written out rather than taken from the type, " ++
                "because a row in the table outlives a rename.",
        );
        const job_name: []const u8 = K.nilo_job;
        if (job_name.len == 0) @compileError(
            "nilo: the job " ++ name ++ "'s `nilo_job` is empty.\n" ++
                "  A row is stored under this name, and an empty one is nothing to find it by.",
        );
        if (job_name.len > contract.max_kind) @compileError(
            "nilo: the job " ++ name ++ "'s `nilo_job` is " ++ std.fmt.comptimePrint("{d}", .{job_name.len}) ++
                " bytes, and a name is at most " ++ std.fmt.comptimePrint("{d}", .{contract.max_kind}) ++ ".\n" ++
                "  It is a column and a fixed field in `job.Memory`; a shorter one says the same thing.",
        );
        for (kinds[0..i]) |Earlier| {
            if (std.mem.eql(u8, Earlier.nilo_job, job_name)) @compileError(
                "nilo: the jobs " ++ shortName(Earlier) ++ " and " ++ name ++ " are both named \"" ++ job_name ++ "\".\n" ++
                    "  A row says which job runs it by name, so two jobs with one name is one job with two bodies.",
            );
        }

        for (@typeInfo(K).@"struct".fields) |f| checkPayload(f.type, name, name ++ "." ++ f.name);

        if (!@hasDecl(K, "retry")) @compileError(
            "nilo: the job " ++ name ++ " says nothing about `retry`, and a job that fails has to say what happens next.\n" ++
                "  `pub const retry: job.Retry = .{ .times = 3, .backoff = .{ .exponential = .{ .from_ms = 1_000, .to_ms = 60_000 } } };`, " ++
                "or `.none` for one attempt.",
        );
        if (@TypeOf(K.retry) != Retry) @compileError(
            "nilo: the job " ++ name ++ "'s `retry` is " ++ @typeName(@TypeOf(K.retry)) ++ " rather than a `job.Retry`.\n" ++
                "  `pub const retry: job.Retry = …` — the type on the declaration is what makes it one.",
        );
        if (@hasDecl(K, "final")) {
            if (@TypeOf(K.final) != type or @typeInfo(K.final) != .error_set or @typeInfo(K.final).error_set == null) @compileError(
                "nilo: the job " ++ name ++ "'s `final` is not an error set.\n" ++
                    "  It names the failures that are final: `pub const final = error{ Rejected };` — " ++
                    "a `run` that fails with one of them is dead on that attempt, whatever `retry` says (ADR 179).",
            );
            if (@as(Retry, K.retry).times == 0) @compileError(
                "nilo: the job " ++ name ++ " declares `final`, and its `retry` is `.none`.\n" ++
                    "  With one attempt every failure is final already, so the set decides nothing. " ++
                    "Take it out, or give `retry` some `times` for the failures that are not in it.",
            );
        }
        if (@hasDecl(K, "priority")) {
            if (@TypeOf(K.priority) != Priority) @compileError(
                "nilo: the job " ++ name ++ "'s `priority` is " ++ @typeName(@TypeOf(K.priority)) ++ " rather than a `job.Priority`.\n" ++
                    "  `pub const priority: job.Priority = .high;` — the levels are `.high`, `.normal` and `.low`, and a number is not one of them.",
            );
        }
        if (@hasDecl(K, "timeout_ms")) {
            if (K.timeout_ms == 0) @compileError(
                "nilo: the job " ++ name ++ "'s `timeout_ms` is 0, which is no deadline and no lease.\n" ++
                    "  A worker that dies holding this row would hold it forever. Leave the declaration out for the queue's default.",
            );
        }

        if (Deps) |D| checkRun(K, name, D);

        if (scheduled(K)) {
            if (@TypeOf(K.schedule) != Schedule) @compileError(
                "nilo: the job " ++ name ++ "'s `schedule` is " ++ @typeName(@TypeOf(K.schedule)) ++ " rather than a `job.Schedule`.\n" ++
                    "  `pub const schedule = job.cron(\"0 3 * * *\");` or `job.every(600_000)`.",
            );
            if (!@hasDecl(K, "overlap")) @compileError(
                "nilo: the scheduled job " ++ name ++ " does not say what happens when a tick arrives while the last one is still running.\n" ++
                    "  `pub const overlap: job.Overlap = .skip;` drops it; `.queue` starts it on another worker. " ++
                    "Neither is right for everybody, so neither is the default (ADR 161).",
            );
            if (@TypeOf(K.overlap) != Overlap) @compileError(
                "nilo: the scheduled job " ++ name ++ "'s `overlap` is not a `job.Overlap`.\n" ++
                    "  `pub const overlap: job.Overlap = .skip;` or `.queue`.",
            );
            if (!@hasDecl(K, "missed")) @compileError(
                "nilo: the scheduled job " ++ name ++ " does not say what happens to a tick that was missed while the process was down.\n" ++
                    "  `pub const missed: job.Missed = .drop;` forgets it; `.catch_up` runs once for it. " ++
                    "Neither is right for everybody, so neither is the default (ADR 161).",
            );
            if (@TypeOf(K.missed) != Missed) @compileError(
                "nilo: the scheduled job " ++ name ++ "'s `missed` is not a `job.Missed`.\n" ++
                    "  `pub const missed: job.Missed = .drop;` or `.catch_up`.",
            );
            for (@typeInfo(K).@"struct".fields) |f| {
                if (f.default_value_ptr == null) @compileError(
                    "nilo: the scheduled job " ++ name ++ " has a field `" ++ f.name ++ "` with no default, and nobody pushes a scheduled job.\n" ++
                        "  The clock does, with nothing in hand. Give the field a default, or take it out.",
                );
            }
        }
    }
}

fn checkPayload(comptime T: type, comptime job_name: []const u8, comptime path: []const u8) void {
    if (T == core.Str) return;
    switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum", .void => {},
        .optional => |o| checkPayload(o.child, job_name, path ++ ".?"),
        .array => |a| checkPayload(a.child, job_name, path ++ "[0]"),
        .@"struct" => |s| for (s.fields) |f| checkPayload(f.type, job_name, path ++ "." ++ f.name),
        .@"union" => |u| {
            if (u.tag_type == null) @compileError(
                "nilo: the job " ++ job_name ++ " cannot carry `" ++ path ++ "`, which is an untagged union.\n" ++
                    "  A payload is written as JSON and read back, and an untagged union does not say which arm it is.",
            );
            for (u.fields) |f| checkPayload(f.type, job_name, path ++ "." ++ f.name);
        },
        .pointer => |p| {
            if (p.size == .slice) {
                if (p.child == u8) return;
                checkPayload(p.child, job_name, path ++ "[0]");
                return;
            }
            @compileError(
                "nilo: the job " ++ job_name ++ " cannot carry `" ++ path ++ "`, which is a pointer.\n" ++
                    "  A payload is written as JSON at `push` and read back on a worker, possibly in another process; " ++
                    "an address means nothing there. Carry the id and look it up in `run`.",
            );
        },
        else => @compileError(
            "nilo: the job " ++ job_name ++ " cannot carry `" ++ path ++ "`, which is " ++ @typeName(T) ++ ".\n" ++
                "  A payload is written as JSON, and JSON has no such value.",
        ),
    }
}

/// The half of `checkKinds` that waits for the queue type: the deps struct
/// and every `run`'s signature.
fn checkLate(comptime kinds: []const type, comptime Deps: type) void {
    checkDepsShape(Deps);
    for (kinds) |K| checkRun(K, shortName(K), Deps);
}

fn checkDepsShape(comptime Deps: type) void {
    if (@typeInfo(Deps) != .@"struct") @compileError(
        "nilo: `job.Jobs`'s `.deps` is " ++ @typeName(Deps) ++ ", and it has to be a struct of pointers.\n" ++
            "  `.deps = struct { db: *Db, mail: *Mailer }` — one field per service a `run` may ask for.",
    );
    for (@typeInfo(Deps).@"struct".fields) |f| {
        if (@typeInfo(f.type) != .pointer or @typeInfo(f.type).pointer.size != .one) @compileError(
            "nilo: `job.Jobs`'s `.deps." ++ f.name ++ "` is " ++ @typeName(f.type) ++ ", and a dep is a pointer.\n" ++
                "  A `run` asks for a service by `*T`, the way a route does; a value has no address to hand it.",
        );
    }
}

fn checkRun(comptime K: type, comptime name: []const u8, comptime Deps: type) void {
    if (!@hasDecl(K, "run")) @compileError(
        "nilo: the job " ++ name ++ " has no `run`, so there is nothing for a worker to do with it.\n" ++
            "  `pub fn run(self: " ++ name ++ ", scope: *nilo.Run) !void`",
    );
    const info = @typeInfo(@TypeOf(K.run));
    if (info != .@"fn") @compileError(
        "nilo: the job " ++ name ++ "'s `run` is not a function.\n" ++
            "  `pub fn run(self: " ++ name ++ ", scope: *nilo.Run) !void`",
    );
    const params = info.@"fn".params;
    const shape = "\n  `pub fn run(self: " ++ name ++ ", scope: *nilo.Run, …) !void` — the job by value, then the Run, then any service by pointer, and `tick: job.Tick` by value if it wants to know which tick it is.";
    if (params.len < 2) @compileError(
        "nilo: the job " ++ name ++ "'s `run` takes " ++ std.fmt.comptimePrint("{d}", .{params.len}) ++
            " argument(s), and it takes at least two." ++ shape,
    );
    if (params[0].type != K) @compileError(
        "nilo: the job " ++ name ++ "'s `run` takes " ++ @typeName(params[0].type orelse void) ++
            " first, and it takes the job itself, by value." ++ shape,
    );
    if (params[1].type != *core.Run) @compileError(
        "nilo: the job " ++ name ++ "'s `run` takes " ++ @typeName(params[1].type orelse void) ++
            " second, and it takes a `*nilo.Run`." ++ shape ++
            "\n  Not a `*Ctx`: a job runs with no request to answer, so there is nothing for a fail function to write into.",
    );
    for (params[2..], 2..) |p, i| {
        const P = p.type orelse @compileError(
            "nilo: the job " ++ name ++ "'s `run` has an `anytype` argument at position " ++
                std.fmt.comptimePrint("{d}", .{i}) ++ ", and a service is asked for by its type." ++ shape,
        );
        // The tick is the one thing after the Run that is not a service,
        // and it is asked for by value for the reason request data is in
        // a handler: a pointer is a service, a value is the tick (ADR 160).
        if (P == Tick) continue;
        if (P == *Tick or P == *const Tick) @compileError(
            "nilo: the job " ++ name ++ "'s `run` takes a `*job.Tick` at position " ++
                std.fmt.comptimePrint("{d}", .{i}) ++ ", and a tick is asked for by value.\n" ++
                "  `tick: job.Tick` — a pointer is a service looked up in `.deps`, and the tick is not one; " ++
                "it is the row's id, attempt and due time, handed to the run as the value it is.",
        );
        if (@typeInfo(P) != .pointer or @typeInfo(P).pointer.size != .one) @compileError(
            "nilo: the job " ++ name ++ "'s `run` takes " ++ @typeName(P) ++ " at position " ++
                std.fmt.comptimePrint("{d}", .{i}) ++ ", and after the job and the Run every argument is a service, by pointer." ++ shape,
        );
        _ = depField(name, Deps, P);
    }
    const R = info.@"fn".return_type.?;
    const payload = if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
    if (payload != void) @compileError(
        "nilo: the job " ++ name ++ "'s `run` returns " ++ @typeName(R) ++ ", and nobody is there to receive it.\n" ++
            "  `!void` — a job answers nobody. Write what it made into the database, or into a `status` Space.",
    );
}

fn checkStore(comptime Store: type) void {
    const name = shortName(Store);
    const wanted = [_][]const u8{ "push", "claim", "done", "retry", "dead", "release", "stats", "deadOnes", "retryDead" };
    for (wanted) |w| {
        if (!@hasDecl(Store, w)) @compileError(
            "nilo: `job.Jobs`'s `.store` is " ++ name ++ ", and it has no `" ++ w ++ "`.\n" ++
                "  A store answers the nine questions in `job/contract.zig`: `job.Memory` and `job.Table(Db)` do, " ++
                "and so does anything else written against that list.",
        );
    }
}

fn checkStatus(comptime S: type) void {
    if (S == void) return;
    if (!@hasDecl(S, "put") or !@hasDecl(S, "get")) @compileError(
        "nilo: `job.Jobs`'s `.status` is " ++ shortName(S) ++ ", and a status Space has `put` and `get`.\n" ++
            "  `cache.Space(\"job-status\", job.Status, .{ .ttl_s = 3_600 })` is the shape.",
    );
    if (@hasDecl(S, "Value")) {
        if (S.Value != Status) @compileError(
            "nilo: `job.Jobs`'s `.status` Space holds " ++ @typeName(S.Value) ++ " rather than `job.Status`.\n" ++
                "  `cache.Space(\"job-status\", job.Status, .{ .ttl_s = 3_600 })`.",
        );
    }
}

/// `SendWelcome` rather than `main.SendWelcome`, so a Refusal reads like the
/// code that caused it.
fn shortName(comptime T: type) []const u8 {
    const full = @typeName(T);
    var at = full.len;
    while (at > 0) : (at -= 1) {
        if (full[at - 1] == '.') return full[at..];
    }
    return full;
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

test {
    _ = @import("cron.zig");
    _ = @import("memory.zig");
    _ = @import("contract.zig");
}

test "exponential backoff doubles from the first wait and stops at the ceiling" {
    const r: Retry = .{ .times = 10, .backoff = .{ .exponential = .{ .from_ms = 100, .to_ms = 1_000 } } };
    try testing.expectEqual(@as(u64, 100), r.delayMs(1));
    try testing.expectEqual(@as(u64, 200), r.delayMs(2));
    try testing.expectEqual(@as(u64, 400), r.delayMs(3));
    try testing.expectEqual(@as(u64, 800), r.delayMs(4));
    try testing.expectEqual(@as(u64, 1_000), r.delayMs(5));
    try testing.expectEqual(@as(u64, 1_000), r.delayMs(40));
    const f: Retry = .{ .times = 2, .backoff = .{ .fixed_ms = 50 } };
    try testing.expectEqual(@as(u64, 50), f.delayMs(1));
    try testing.expectEqual(@as(u64, 50), f.delayMs(2));
}

// A little program, the way a user would write one.

const Ledger = struct {
    lines: std.ArrayList([]const u8) = .empty,
    gpa: std.mem.Allocator,
    fail_first: u32 = 0,
    seen: u32 = 0,

    fn record(self: *Ledger, text: []const u8) !void {
        try self.lines.append(self.gpa, try self.gpa.dupe(u8, text));
    }
    fn deinit(self: *Ledger) void {
        for (self.lines.items) |l| self.gpa.free(l);
        self.lines.deinit(self.gpa);
    }
};

const Greet = struct {
    pub const nilo_job = "greet";
    pub const retry: Retry = .none;

    who: core.Str,
    times: u8 = 1,

    pub fn run(self: Greet, scope: *core.Run, ledger: *Ledger) !void {
        var i: u8 = 0;
        while (i < self.times) : (i += 1) {
            const line = try std.fmt.allocPrint(scope.arena(), "hello {s}", .{self.who.view()});
            try ledger.record(line);
        }
    }
};

const Flaky = struct {
    pub const nilo_job = "flaky";
    pub const retry: Retry = .{ .times = 2, .backoff = .{ .fixed_ms = 0 } };

    pub fn run(self: Flaky, scope: *core.Run, ledger: *Ledger) !void {
        _ = self;
        _ = scope;
        ledger.seen += 1;
        if (ledger.seen <= ledger.fail_first) return error.NotYet;
        try ledger.record("flaky ran");
    }
};

/// Retries on one failure and is dead at once on the other (ADR 179).
const Picky = struct {
    pub const nilo_job = "picky";
    pub const retry: Retry = .{ .times = 5, .backoff = .{ .fixed_ms = 0 } };
    pub const final = error{Rejected};

    pub fn run(self: Picky, scope: *core.Run, ledger: *Ledger) !void {
        _ = self;
        _ = scope;
        ledger.seen += 1;
        if (ledger.seen <= ledger.fail_first) return error.NotYet;
        return error.Rejected;
    }
};

const Ticker = struct {
    pub const nilo_job = "tick";
    pub const retry: Retry = .none;
    pub const schedule = every(1);
    pub const overlap: Overlap = .skip;
    pub const missed: Missed = .catch_up;

    pub fn run(self: Ticker, scope: *core.Run, ledger: *Ledger) !void {
        _ = self;
        _ = scope;
        try ledger.record("tick");
    }
};

/// The same, dropping what it missed.
const Strict = struct {
    pub const nilo_job = "strict";
    pub const retry: Retry = .none;
    pub const schedule = every(1);
    pub const overlap: Overlap = .queue;
    pub const missed: Missed = .drop;

    pub fn run(self: Strict, scope: *core.Run, ledger: *Ledger) !void {
        _ = self;
        _ = scope;
        try ledger.record("strict");
    }
};

/// Keeps its payload `Str` past the tick, which is the mistake the trap is
/// for. `stashed` is where it goes, so the test can ask whether it is alive.
const Hoarder = struct {
    pub const nilo_job = "hoarder";
    pub const retry: Retry = .none;

    who: core.Str,

    var stashed: ?core.Str = null;

    pub fn run(self: Hoarder, scope: *core.Run, ledger: *Ledger) !void {
        _ = scope;
        _ = ledger;
        stashed = self.who;
    }
};

/// A scheduled kind that declares its urgency, and a plain one that does not:
/// the pair the priority-through-`Jobs` test needs. Their own `Jobs` rather
/// than `TestJobs`, because seeding one more scheduled kind would change what
/// every schedule test counts.
const UrgentTick = struct {
    pub const nilo_job = "urgent-tick";
    pub const retry: Retry = .none;
    pub const schedule = every(1);
    pub const overlap: Overlap = .skip;
    pub const missed: Missed = .catch_up;
    pub const priority: Priority = .high;
    pub fn run(self: UrgentTick, scope: *core.Run, ledger: *Ledger) !void {
        _ = self;
        _ = scope;
        try ledger.add("urgent-tick");
    }
};

const PlainWork = struct {
    pub const nilo_job = "plain";
    pub const retry: Retry = .none;
    pub fn run(self: PlainWork, scope: *core.Run, ledger: *Ledger) !void {
        _ = self;
        _ = scope;
        try ledger.add("plain");
    }
};

const PriorityJobs = Jobs(.{
    .kinds = .{ UrgentTick, PlainWork },
    .store = Memory,
    .deps = struct { ledger: *Ledger },
});

const TestJobs = Jobs(.{
    .kinds = .{ Greet, Flaky, Picky, Ticker, Strict, Hoarder },
    .store = Memory,
    .deps = struct { ledger: *Ledger },
});

test "a pushed job runs under drain with its payload parsed back, Str included" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var jobs: TestJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});

    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    // The Str is borrowed from this tick's arena, as it would be from a
    // request's. It is copied at push, so nothing of it is needed later.
    const who = run.str(try run.arena().dupe(u8, "wati"));
    const id = try jobs.push(&run, Greet{ .who = who, .times = 2 }, .{});
    try testing.expect(id != 0);
    try testing.expectEqual(@as(u64, 1), (try jobs.stats(&run)).queued);

    try testing.expectEqual(@as(usize, 1), try jobs.drain(&run));
    try testing.expectEqual(@as(usize, 2), ledger.lines.items.len);
    try testing.expectEqualStrings("hello wati", ledger.lines.items[0]);
    try testing.expectEqual(@as(u64, 0), (try jobs.stats(&run)).queued);
}

test "a payload Str held past its tick goes stale, the way a body's does" {
    if (!core.trap_enabled) return;
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var jobs: TestJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    _ = try jobs.push(&run, Hoarder{ .who = .static("wati") }, .{});
    try testing.expectEqual(@as(usize, 1), try jobs.drain(&run));

    // Alive while the tick's Scope is, and stale once it is reset — which is
    // what `Str.jsonParse` answering `static` could never do on its own.
    try testing.expect(Hoarder.stashed.?.alive());
    run.reset();
    try testing.expect(!Hoarder.stashed.?.alive());
    Hoarder.stashed = null;
}

test "a job that is not in the list is refused before it is stored" {
    // Held by `job/refusals/push_a_job_not_in_the_list.zig`; this is the
    // positive half — the same call with a listed kind compiles.
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var jobs: TestJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();
    _ = try jobs.push(&run, Flaky{}, .{ .after_ms = 60_000 });
    // Not due for a minute, so nothing runs.
    try testing.expectEqual(@as(usize, 0), try jobs.drain(&run));
}

test "a failing job is retried as many times as it said, then is dead" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator, .fail_first = 2 };
    defer ledger.deinit();
    var jobs: TestJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    _ = try jobs.push(&run, Flaky{}, .{});
    // Fails twice, succeeds on the third: `times = 2` allows exactly that.
    try testing.expectEqual(@as(usize, 3), try jobs.drain(&run));
    try testing.expectEqual(@as(usize, 1), ledger.lines.items.len);
    try testing.expectEqual(@as(u64, 0), (try jobs.stats(&run)).dead);

    // And one that fails three times is dead, with the error's name kept.
    ledger.seen = 0;
    ledger.fail_first = 3;
    const id = try jobs.push(&run, Flaky{}, .{});
    try testing.expectEqual(@as(usize, 3), try jobs.drain(&run));
    try testing.expectEqual(@as(u64, 1), (try jobs.stats(&run)).dead);
    const dead_rows = try jobs.deadOnes(&run);
    try testing.expectEqual(@as(usize, 1), dead_rows.len);
    try testing.expectEqual(id, dead_rows[0].id);
    try testing.expectEqualStrings("NotYet", dead_rows[0].err);
    try testing.expectEqual(@as(u32, 3), dead_rows[0].attempts);

    // Brought back, it runs again from the first attempt.
    ledger.fail_first = 0;
    try testing.expect(try jobs.retryDead(&run, id));
    try testing.expectEqual(@as(usize, 1), try jobs.drain(&run));
    try testing.expectEqual(@as(usize, 2), ledger.lines.items.len);
}

test "a failure the kind said is final is dead on that attempt, and the others still retry" {
    // Item 79: a 4xx is the same 4xx in an hour, and a reset socket is not.
    // The kind keeps its five retries for the second and stops on the first.
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator, .fail_first = 2 };
    defer ledger.deinit();
    var jobs: TestJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    // Two transient failures, then the final one: three attempts of the six
    // allowed, and the row keeps the error's own name.
    const id = try jobs.push(&run, Picky{}, .{});
    try testing.expectEqual(@as(usize, 3), try jobs.drain(&run));
    try testing.expectEqual(@as(u64, 1), (try jobs.stats(&run)).dead);
    const dead_rows = try jobs.deadOnes(&run);
    try testing.expectEqual(@as(usize, 1), dead_rows.len);
    try testing.expectEqual(id, dead_rows[0].id);
    try testing.expectEqualStrings("Rejected", dead_rows[0].err);
    try testing.expectEqual(@as(u32, 3), dead_rows[0].attempts);

    // And a kind with no `final` is untouched: `Flaky` still uses its count.
    ledger.seen = 0;
    ledger.fail_first = 3;
    _ = try jobs.push(&run, Flaky{}, .{});
    try testing.expectEqual(@as(usize, 3), try jobs.drain(&run));
    try testing.expectEqual(@as(u64, 2), (try jobs.stats(&run)).dead);
}

test "a unique key queues one and answers null for the second" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var jobs: TestJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    const first = try jobs.push(&run, Greet{ .who = .static("a") }, .{ .unique = "greet:a" });
    try testing.expect(first != null);
    const second = try jobs.push(&run, Greet{ .who = .static("a") }, .{ .unique = "greet:a" });
    try testing.expect(second == null);
    try testing.expectEqual(@as(usize, 1), try jobs.drain(&run));
}

test "a queued job can be cancelled, and one that ran cannot" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var jobs: TestJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    const id = try jobs.push(&run, Greet{ .who = .static("a") }, .{});
    try testing.expect(try jobs.cancel(&run, id));
    try testing.expectEqual(@as(usize, 0), try jobs.drain(&run));
    try testing.expectEqual(@as(usize, 0), ledger.lines.items.len);

    const ran = try jobs.push(&run, Greet{ .who = .static("b") }, .{});
    try testing.expectEqual(@as(usize, 1), try jobs.drain(&run));
    try testing.expect(!(try jobs.cancel(&run, ran)));
    try testing.expect(!(try jobs.cancel(&run, 4_000)));
}

test "a payload the program cannot read is dead at once rather than retried" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var jobs: TestJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    // Straight into the store, the way an older binary might have written it:
    // a Greet with no `who`.
    _ = try store.push(&run, "greet", "{\"times\":1}", .{ .run_at = 0 });
    try testing.expectEqual(@as(usize, 1), try jobs.drain(&run));
    const dead_rows = try jobs.deadOnes(&run);
    try testing.expectEqual(@as(usize, 1), dead_rows.len);
    try testing.expectEqualStrings("MissingField", dead_rows[0].err);
}

test "a scheduled kind's urgency survives the row it queues for next time" {
    // `seed` and the requeue after a run both go through `pushNext`, which
    // used to push the next turn with no priority at all: a kind could
    // declare `.high`, pass every check, and run `.normal` for ever. Nothing
    // caught it, because every priority test set `Enqueue.priority` on the
    // store by hand and never went through `Jobs`.
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var jobs: PriorityJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    try jobs.seedAt(&run, 0);
    // Due earlier than the seeded tick, and only `normal`.
    _ = try jobs.push(&run, PlainWork{}, .{ .at = 0 });

    // Both are due now. The urgent one goes first although it is due later,
    // which is only true if `pushNext` carried the kind's priority.
    const first = (try store.claim(&run, &.{ "urgent-tick", "plain" }, 10_000_000, 20_000_000)).?;
    try testing.expectEqualStrings("urgent-tick", first.kind);
    const second = (try store.claim(&run, &.{ "urgent-tick", "plain" }, 10_000_000, 20_000_000)).?;
    try testing.expectEqualStrings("plain", second.kind);
}

test "a schedule seeds its next tick, runs it when due, and queues the one after" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var jobs: TestJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    try jobs.seed(&run);
    // One row per scheduled kind.
    try testing.expectEqual(@as(u64, 2), (try jobs.stats(&run)).queued);
    // Seeding twice is the same two rows: the schedule key is unique.
    try jobs.seed(&run);
    try testing.expectEqual(@as(u64, 2), (try jobs.stats(&run)).queued);

    // `every(1)` is due a millisecond later. Both run: `tick` catches up,
    // and `strict` is not late by more than its own interval only if the
    // clock is kind, so only `tick` is asserted on.
    try threaded.io().sleep(.fromMilliseconds(2), .awake);
    try testing.expectEqual(@as(usize, 2), try jobs.drain(&run));
    var ticks: usize = 0;
    for (ledger.lines.items) |l| {
        if (std.mem.eql(u8, l, "tick")) ticks += 1;
    }
    try testing.expectEqual(@as(usize, 1), ticks);
    // And the next ones are already waiting.
    try testing.expectEqual(@as(u64, 2), (try jobs.stats(&run)).queued);
}

test "a missed tick under .drop is skipped and the schedule moves on" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var jobs: TestJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    // A tick from long ago, as the table would hold after a night down.
    _ = try store.push(&run, "strict", "{}", .{ .run_at = core.nowMicros() - 10 * std.time.us_per_s, .unique = schedule_key });
    try testing.expect(try jobs.runOne(&run));
    try testing.expectEqual(@as(usize, 0), ledger.lines.items.len);
    try testing.expectEqual(@as(u64, 1), (try jobs.stats(&run)).queued);

    // The same row for a kind that catches up runs once, and once only.
    _ = try store.push(&run, "tick", "{}", .{ .run_at = core.nowMicros() - 10 * std.time.us_per_s, .unique = schedule_key });
    try testing.expect(try jobs.runOne(&run));
    try testing.expectEqual(@as(usize, 1), ledger.lines.items.len);
    try testing.expectEqualStrings("tick", ledger.lines.items[0]);
}

/// No schedules in this one: a schedule of `every(1)` keeps a worker busy,
/// which is the wrong fixture for watching one row go by.
const LoopJobs = Jobs(.{
    .kinds = .{Greet},
    .store = Memory,
    .deps = struct { ledger: *Ledger },
});

test "the worker loop runs under std.Io.Threaded and stops when cancelled" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var jobs: LoopJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{ .workers = 2, .poll_ms = 5 });
    try jobs.nilo_start(io, .none);

    var run: core.Run = .init(testing.allocator);
    defer run.deinit();
    _ = try jobs.push(&run, Greet{ .who = .static("loop") }, .{});

    var serving = try io.concurrent(LoopJobs.serveOn, .{ &jobs, io });
    // Whatever this test concludes, the workers are stopped before the store
    // and the ledger go — `cancel` is idempotent, so the explicit one below
    // and this one do not fight.
    defer serving.cancel(io) catch {};

    // The row is picked up by a worker, not by this thread.
    var waited: u32 = 0;
    while (ledger.lines.items.len == 0 and waited < 2_000) : (waited += 1) try io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectEqual(@as(usize, 1), ledger.lines.items.len);
    // Both workers are up — the second may still be starting when the first
    // has already run the row, so this is waited for rather than asserted.
    waited = 0;
    while (jobs.alive.load(.acquire) < 2 and waited < 2_000) : (waited += 1) try io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectEqual(@as(u32, 2), jobs.alive.load(.acquire));

    // Cancel is the shutdown, and it comes back.
    const outcome = serving.cancel(io);
    try testing.expectError(error.Canceled, outcome);
    try testing.expectEqual(@as(u32, 0), jobs.alive.load(.acquire));
}

/// How long the test thread waits for a worker to run a row before it
/// gives up. The worker's own poll is a minute, so anything that arrives
/// inside this bound arrived because it was woken (ADR 160).
const wake_bound_ms = 2_000;

fn waitForLine(io: std.Io, ledger: *Ledger, count: usize) !void {
    var waited: u32 = 0;
    while (ledger.lines.items.len < count and waited < wake_bound_ms) : (waited += 1) try io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectEqual(count, ledger.lines.items.len);
}

test "a push wakes a sleeping worker rather than waiting out the poll" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    // A poll of a minute, so the poll cannot be what runs the row.
    var jobs: LoopJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{ .workers = 2, .poll_ms = 60_000 });
    try jobs.nilo_start(io, .none);

    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    var serving = try io.concurrent(LoopJobs.serveOn, .{ &jobs, io });
    defer serving.cancel(io) catch {};

    // Both workers asleep on an empty queue before anything is pushed —
    // this is the case a poll would make the caller wait a minute for.
    var waited: u32 = 0;
    while (jobs.alive.load(.acquire) < 2 and waited < wake_bound_ms) : (waited += 1) try io.sleep(.fromMilliseconds(1), .awake);
    try io.sleep(.fromMilliseconds(20), .awake);

    _ = try jobs.push(&run, Greet{ .who = .static("first") }, .{});
    try waitForLine(io, &ledger, 1);

    // And again, once the worker has gone back to sleep: the wake is per
    // push rather than a one-shot.
    try io.sleep(.fromMilliseconds(20), .awake);
    _ = try jobs.push(&run, Greet{ .who = .static("second") }, .{});
    try waitForLine(io, &ledger, 2);
}

test "wake reaches a worker for a row nilo did not push" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var jobs: LoopJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{ .workers = 1, .poll_ms = 60_000 });

    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    // `serveOn` with no `nilo_start` first: the worker-process shape, where
    // the `Io` the workers run on is the one a wake goes through.
    var serving = try io.concurrent(LoopJobs.serveOn, .{ &jobs, io });
    defer serving.cancel(io) catch {};
    var waited: u32 = 0;
    while (jobs.alive.load(.acquire) < 1 and waited < wake_bound_ms) : (waited += 1) try io.sleep(.fromMilliseconds(1), .awake);
    try io.sleep(.fromMilliseconds(20), .awake);

    // Straight into the store, the way another process would put it there.
    _ = try store.push(&run, "greet", "{\"who\":\"elsewhere\"}", .{ .run_at = core.nowMicros() });
    jobs.wake();
    try waitForLine(io, &ledger, 1);
}

// -- a job that pushes the next one (ADR 160) -----------------------------

/// The first half of a pipeline: it asks for `*PipelineJobs` — the queue it
/// is itself a kind of — and pushes the second half. Its `run` names the
/// queue type, which is why `pipelineDeps` is a function rather than a
/// struct.
const Download = struct {
    pub const nilo_job = "download";
    pub const retry: Retry = .none;

    file: u32,

    pub fn run(self: Download, scope: *core.Run, ledger: *Ledger, jobs: *PipelineJobs) !void {
        try ledger.record("downloaded");
        _ = try jobs.push(scope, Process{ .file = self.file }, .{});
    }
};

const Process = struct {
    pub const nilo_job = "process";
    pub const retry: Retry = .none;

    file: u32,

    pub fn run(self: Process, scope: *core.Run, ledger: *Ledger) !void {
        try ledger.record(try std.fmt.allocPrint(scope.arena(), "processed {d}", .{self.file}));
    }
};

fn pipelineDeps(comptime J: type) type {
    return struct { ledger: *Ledger, jobs: *J };
}

const PipelineJobs = Jobs(.{
    .kinds = .{ Download, Process },
    .store = Memory,
    .deps = pipelineDeps,
});

test "a job can push the next kind through a *Jobs dep, and two drains run both" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    // The queue is a dep of its own kinds, so it is opened once it has an
    // address to give.
    var jobs: PipelineJobs = undefined;
    jobs = .open(testing.allocator, &store, .{ .ledger = &ledger, .jobs = &jobs }, .{});

    // Pushed as due a moment ago, so the drain "at" that moment runs it and
    // not the row it pushes, which is due now — one kind per drain, with
    // nothing left to the clock's resolution.
    const t = core.nowMicros() - 1;
    _ = try jobs.push(&run, Download{ .file = 9 }, .{ .at = t });
    try testing.expectEqual(@as(usize, 1), try jobs.drainAt(&run, t));
    try testing.expectEqual(@as(usize, 1), ledger.lines.items.len);
    try testing.expectEqualStrings("downloaded", ledger.lines.items[0]);
    try testing.expectEqual(@as(u64, 1), (try jobs.stats(&run)).queued);

    try testing.expectEqual(@as(usize, 1), try jobs.drain(&run));
    try testing.expectEqual(@as(usize, 2), ledger.lines.items.len);
    try testing.expectEqualStrings("processed 9", ledger.lines.items[1]);
    try testing.expectEqual(@as(u64, 0), (try jobs.stats(&run)).queued);
}

// -- a test that moves the clock (ADR 160) --------------------------------

/// Fails three times with a backoff long enough that only a moved clock
/// reaches the fourth attempt.
const Stubborn = struct {
    pub const nilo_job = "stubborn";
    pub const retry: Retry = .{ .times = 3, .backoff = .{ .exponential = .{ .from_ms = 100, .to_ms = 10_000 } } };

    pub fn run(self: Stubborn, scope: *core.Run, ledger: *Ledger) !void {
        _ = self;
        _ = scope;
        ledger.seen += 1;
        if (ledger.seen <= ledger.fail_first) return error.NotYet;
        try ledger.record("stubborn ran");
    }
};

const Nightly = struct {
    pub const nilo_job = "nightly";
    pub const retry: Retry = .none;
    pub const schedule = cron("0 3 * * *");
    pub const overlap: Overlap = .skip;
    pub const missed: Missed = .drop;

    pub fn run(self: Nightly, scope: *core.Run, ledger: *Ledger) !void {
        _ = self;
        _ = scope;
        try ledger.record("nightly");
    }
};

const ClockJobs = Jobs(.{
    .kinds = .{ Greet, Stubborn, Nightly },
    .store = Memory,
    .deps = struct { ledger: *Ledger },
});

test "a row due in a minute does not run at t and runs at t plus a minute" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var jobs: ClockJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    const t = core.nowMicros();
    _ = try jobs.push(&run, Greet{ .who = .static("later") }, .{ .after_ms = 60_000 });
    try testing.expectEqual(@as(usize, 0), try jobs.drainAt(&run, t));
    try testing.expectEqual(@as(usize, 0), try jobs.drainAt(&run, t + 59 * std.time.us_per_s));
    // `after_ms` counted from the push, which was a moment after `t`; a
    // minute and a second is past it however slow the machine.
    try testing.expectEqual(@as(usize, 1), try jobs.drainAt(&run, t + 61 * std.time.us_per_s));
    try testing.expectEqual(@as(usize, 1), ledger.lines.items.len);
    try testing.expectEqualStrings("hello later", ledger.lines.items[0]);
}

test "an exponential backoff's third attempt waits the doubled time, on a moved clock" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator, .fail_first = 3 };
    defer ledger.deinit();
    var jobs: ClockJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    const ms = std.time.us_per_ms;
    const t: i64 = 1_800_000_000 * std.time.us_per_s;
    _ = try jobs.push(&run, Stubborn{}, .{ .at = t });

    // Attempt one fails at `t`, and the wait is 100 ms.
    try testing.expectEqual(@as(usize, 1), try jobs.drainAt(&run, t));
    try testing.expectEqual(@as(usize, 0), try jobs.drainAt(&run, t + 99 * ms));
    // Attempt two, and the wait doubles to 200 ms.
    try testing.expectEqual(@as(usize, 1), try jobs.drainAt(&run, t + 100 * ms));
    try testing.expectEqual(@as(usize, 0), try jobs.drainAt(&run, t + 299 * ms));
    // Attempt three, and 400 ms.
    try testing.expectEqual(@as(usize, 1), try jobs.drainAt(&run, t + 300 * ms));
    try testing.expectEqual(@as(usize, 0), try jobs.drainAt(&run, t + 699 * ms));
    // The fourth is the last `times = 3` allows, and it succeeds.
    try testing.expectEqual(@as(usize, 1), try jobs.drainAt(&run, t + 700 * ms));
    try testing.expectEqual(@as(usize, 1), ledger.lines.items.len);
    try testing.expectEqualStrings("stubborn ran", ledger.lines.items[0]);
    try testing.expectEqual(@as(u32, 4), ledger.seen);
    try testing.expectEqual(@as(u64, 0), (try jobs.stats(&run)).dead);
}

test "a cron schedule fires when the clock is moved to three in the morning" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator };
    defer ledger.deinit();
    var jobs: ClockJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    // Seeded at ten in the morning on a fixed day — day 20,833 since the
    // epoch — so the first tick is the next day's 03:00 and nothing here
    // reads the real clock.
    const seeded_at: i64 = (20_833 * 86_400 + 10 * 3600) * std.time.us_per_s;
    try jobs.seedAt(&run, seeded_at);
    try testing.expectEqual(@as(u64, 1), (try jobs.stats(&run)).queued);
    const three = Nightly.schedule.next(seeded_at);
    try testing.expectEqual(@as(i64, 3 * 3600), @rem(@divTrunc(three, std.time.us_per_s), 86_400));

    try testing.expectEqual(@as(usize, 0), try jobs.drainAt(&run, three - 1));
    try testing.expectEqual(@as(usize, 1), try jobs.drainAt(&run, three));
    try testing.expectEqual(@as(usize, 1), ledger.lines.items.len);
    try testing.expectEqualStrings("nightly", ledger.lines.items[0]);

    // The one after is already queued, for the next 03:00 and not before.
    try testing.expectEqual(@as(u64, 1), (try jobs.stats(&run)).queued);
    try testing.expectEqual(@as(usize, 0), try jobs.drainAt(&run, three + 23 * 3600 * std.time.us_per_s));
    try testing.expectEqual(@as(usize, 1), try jobs.drainAt(&run, three + 24 * 3600 * std.time.us_per_s));
    try testing.expectEqual(@as(usize, 2), ledger.lines.items.len);
}

// -- a run that knows which tick it is (ADR 160) --------------------------

/// Asks for the tick and records it. Fails until the attempt the ledger
/// says, so the test can watch `attempts` climb and `last` turn.
const Counting = struct {
    pub const nilo_job = "counting";
    pub const retry: Retry = .{ .times = 2, .backoff = .{ .fixed_ms = 0 } };

    pub fn run(self: Counting, scope: *core.Run, tick: Tick, ledger: *Ledger) !void {
        _ = self;
        try ledger.record(try std.fmt.allocPrint(scope.arena(), "row {d} attempt {d} last={}", .{ tick.id, tick.attempts, tick.last }));
        ledger.seen += 1;
        if (ledger.seen <= ledger.fail_first) return error.NotYet;
    }
};

const TickJobs = Jobs(.{
    .kinds = .{Counting},
    .store = Memory,
    .deps = struct { ledger: *Ledger },
});

test "a run that asks for a job.Tick sees attempts == 3 on the third attempt, and that it is the last" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var ledger: Ledger = .{ .gpa = testing.allocator, .fail_first = 2 };
    defer ledger.deinit();
    var jobs: TickJobs = .open(testing.allocator, &store, .{ .ledger = &ledger }, .{});
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    const id = try jobs.push(&run, Counting{}, .{});
    try testing.expectEqual(@as(usize, 3), try jobs.drain(&run));
    try testing.expectEqual(@as(usize, 3), ledger.lines.items.len);

    const first = try std.fmt.allocPrint(testing.allocator, "row {d} attempt 1 last=false", .{id});
    defer testing.allocator.free(first);
    const third = try std.fmt.allocPrint(testing.allocator, "row {d} attempt 3 last=true", .{id});
    defer testing.allocator.free(third);
    try testing.expectEqualStrings(first, ledger.lines.items[0]);
    try testing.expectEqualStrings(third, ledger.lines.items[2]);
    try testing.expectEqual(@as(u64, 0), (try jobs.stats(&run)).dead);
}

/// A `status` Space for a test with no `nilo_cache` in the graph: the two
/// calls `checkStatus` asks for, over a handful of fixed slots, keyed by
/// the id the queue writes as text.
const FakeSpace = struct {
    pub const Value = Status;

    const Entry = struct { id: Id, status: Status };

    slots: [8]?Entry = [_]?Entry{null} ** 8,

    pub fn get(self: *FakeSpace, key: []const u8) ?Status {
        const id = std.fmt.parseInt(Id, key, 10) catch return null;
        for (self.slots) |s| {
            if (s) |e| {
                if (e.id == id) return e.status;
            }
        }
        return null;
    }

    pub fn put(self: *FakeSpace, key: []const u8, value: Status) void {
        const id = std.fmt.parseInt(Id, key, 10) catch return;
        for (&self.slots) |*s| {
            if (s.*) |e| {
                if (e.id == id) {
                    s.* = .{ .id = id, .status = value };
                    return;
                }
            }
        }
        for (&self.slots) |*s| {
            if (s.* == null) {
                s.* = .{ .id = id, .status = value };
                return;
            }
        }
    }
};

/// Reports how far it is through its tick, which takes the tick's id and
/// the queue itself — ADR 160 in one signature.
const Exporting = struct {
    pub const nilo_job = "exporting";
    pub const retry: Retry = .none;

    pub fn run(self: Exporting, scope: *core.Run, tick: Tick, jobs: *ProgressJobs) !void {
        _ = self;
        _ = scope;
        jobs.progress(tick.id, 3);
        jobs.progress(tick.id, 7);
    }
};

fn progressDeps(comptime J: type) type {
    return struct { jobs: *J };
}

const ProgressJobs = Jobs(.{
    .kinds = .{Exporting},
    .store = Memory,
    .deps = progressDeps,
    .status = FakeSpace,
});

test "progress from inside a run reaches the status Space, and a finished row keeps it" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();
    var jobs: ProgressJobs = undefined;
    jobs = .openWith(testing.allocator, &store, .{ .jobs = &jobs }, .{}, .{});

    const id = try jobs.push(&run, Exporting{}, .{});
    try testing.expectEqual(State.queued, jobs.status(id).?.state);
    try testing.expectEqual(@as(u32, 0), jobs.status(id).?.progress);

    try testing.expectEqual(@as(usize, 1), try jobs.drain(&run));
    const after = jobs.status(id).?;
    try testing.expectEqual(State.done, after.state);
    try testing.expectEqual(@as(u32, 1), after.attempts);
    try testing.expectEqual(@as(u32, 7), after.progress);
}
