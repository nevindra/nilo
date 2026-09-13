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
//! ([ADR 0198](../docs/adr/0198-a-queue-is-a-table-in-the-database-you-already-have.md)).
//! That is what makes `pushIn(&tx, …)` possible — the job row commits with
//! the order row or not at all — and what lets several instances share one
//! queue with `SKIP LOCKED` and no second service. `job.Memory` is the same
//! contract in this process for a test, or for a program that can lose its
//! queue at a restart and says so.
//!
//! **A schedule is a type that makes the caller choose**
//! ([ADR 0199](../docs/adr/0199-a-schedule-is-a-type-that-makes-the-caller-choose.md)):
//! whether two runs may overlap and whether a missed run is caught up are
//! declared on the job or it does not compile, which is the shape ADR 0086
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
//! ([ADR 0070](../docs/adr/0070-a-fitting-borrows-the-loop.md)). It imports
//! `nilo_core` and nothing else. The store it runs on is a type parameter,
//! so a `job.Table` over a `nilo_sql` Db never costs `job/` an import, and
//! the worker loop is written against `std.Io` — `zig build test-job` runs
//! it under `std.Io.Threaded` with no Engine, which is the layer's entry
//! condition.
//!
//! ## What it is not
//!
//! Not a priority queue, not a workflow engine, not a rate limiter for a
//! job kind — `nilo.Gate` inside `run` is that — and not exactly-once.
//! `docs/roadmap.md` carries each of those with what it is waiting for.

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
};

/// A value for a `.within` Space: it has nothing to say, and a `cache.Space`
/// wants a flat type rather than `void`.
pub const Mark = struct {};

/// The `Settings` a `Jobs` is opened with.
pub const Settings = struct {
    /// How many rows may run at once in this process. Each is a fiber, and a
    /// fiber holds its stack at its high-water mark for as long as it lives
    /// ([ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md)),
    /// so this is paid per worker rather than per row.
    workers: u16 = 4,
    /// How long a worker with nothing to do waits before asking the store
    /// again. One query per worker per interval, so this is the cost of an
    /// idle queue and the latency of a busy one.
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
/// | `.deps` | optional: a struct of pointers a `run` may ask for by type |
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
    const Deps = if (@hasField(Options, "deps")) options.deps else struct {};
    const StatusSpace = if (@hasField(Options, "status")) options.status else void;

    comptime checkKinds(&kinds, Deps);
    comptime checkStore(Store);
    comptime checkStatus(StatusSpace);

    return struct {
        const Self = @This();

        /// What a nilo compile error calls this type (ADR 0122).
        pub const nilo_type_name = "job.Jobs";

        /// The store's table Row, for `db.checking(&.{ Jobs.Row })` and a
        /// migration. `void` for a store that has no table.
        pub const Row = if (@hasDecl(Store, "Row")) Store.Row else void;

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
        limits: core.Limits = .off,
        /// Set once the server is going, so a worker that has just finished
        /// a row does not claim another.
        stopping: std.atomic.Value(bool) = .init(false),
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
            comptime if (StatusSpace == void) @compileError(
                "nilo: this `job.Jobs` names no `.status` Space, so there is nothing for `openWith` to take.\n" ++
                    "  Add `.status = Statuses` to the `job.Jobs(.{ … })`, or call `open`.",
            );
            return .{ .gpa = gpa, .store = store, .deps = deps, .settings = settings, .statuses = space };
        }

        // -- as a service ---------------------------------------------------

        /// Finished when the loop exists, like every service (ADR 0040). The
        /// `Io` is what `serve` runs the workers on and the limits are what
        /// bound one run in time (ADR 0065).
        pub fn nilo_start(self: *Self, io: std.Io, limits: core.Limits) !void {
            self.io = io;
            self.limits = limits;
        }

        /// What `app.health` asks (ADR 0192): the store, if it can be down,
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

            const bytes = try std.json.Stringify.valueAlloc(scope.arena(), value, .{});
            const id = try self.store.push(scope, K.nilo_job, bytes, .{ .run_at = run_at, .unique = unique });
            if (o.unique) {
                if (id) |i| self.note(i, .queued, 0);
                return id;
            }
            const i = id orelse unreachable;
            self.note(i, .queued, 0);
            return i;
        }

        /// `push` inside a transaction the caller holds, for a store that can
        /// join one — so the row commits with the caller's rows or not at
        /// all. `job.Memory` refuses this while compiling.
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

            const bytes = try std.json.Stringify.valueAlloc(scope.arena(), value, .{});
            const id = try self.store.pushIn(tx, scope, K.nilo_job, bytes, .{ .run_at = run_at, .unique = unique });
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

        // -- serving --------------------------------------------------------

        /// The worker loop, for `app.spawn(Jobs.serve, .{&jobs})`. It may not
        /// fail — there is nobody to answer — and `error.Canceled` from the
        /// loop is the shutdown, which is the one way out (ADR 0086).
        pub fn serve(self: *Self) void {
            const io = self.io orelse {
                std.log.scoped(.nilo_job).err("serve: not started — `listen()` or `app.start(io)` has not run, so there is no loop to run workers on", .{});
                return;
            };
            self.serveOn(io) catch {};
        }

        /// The same loop on an `Io` of the caller's, for a worker process with
        /// no server in it. Returns when cancelled.
        pub fn serveOn(self: *Self, io: std.Io) std.Io.Cancelable!void {
            self.serving.store(true, .release);
            {
                var run: core.Run = .initIo(self.gpa, io);
                defer run.deinit();
                self.seedSchedules(&run) catch |err| {
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
        pub fn drain(self: *Self, scope: anytype) !usize {
            comptime core.checkScope(@TypeOf(scope), "jobs.drain");
            var n: usize = 0;
            while (try self.runOne(scope)) n += 1;
            return n;
        }

        /// Claim one due row and run it, on this thread. `false` when nothing
        /// was due.
        pub fn runOne(self: *Self, scope: anytype) !bool {
            comptime core.checkScope(@TypeOf(scope), "jobs.runOne");
            const now = core.nowMicros();
            const claimed = try self.store.claim(scope, now, now + self.leaseMicros()) orelse return false;
            self.execute(scope, claimed);
            return true;
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

            const poll: std.Io.Duration = .fromMilliseconds(self.settings.poll_ms);
            while (!self.stopping.load(.acquire)) {
                defer run.reset();
                // A queue that is never empty is a loop that never sleeps, and
                // a cancellation is only seen at an `Io` call — so ask for it
                // here, or a busy worker would outlive the shutdown.
                try io.checkCancel();
                const now = core.nowMicros();
                const claimed = self.store.claim(&run, now, now + self.leaseMicros()) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    std.log.scoped(.nilo_job).err("claim: {t}", .{err});
                    try io.sleep(poll, .awake);
                    continue;
                };
                if (claimed) |c| {
                    self.execute(&run, c);
                } else {
                    try io.sleep(poll, .awake);
                }
            }
        }

        /// One row: parse, run, and tell the store what happened. Never
        /// fails, because there is nobody to fail to; everything it cannot
        /// handle goes to the log and the row.
        fn execute(self: *Self, scope: anytype, claimed: Claimed) void {
            inline for (kinds) |K| {
                if (std.mem.eql(u8, claimed.kind, K.nilo_job)) return self.executeKind(K, scope, claimed);
            }
            // A row from a binary that knows a kind this one does not. Not
            // ours to run and not ours to lose: back in the queue, where the
            // binary that pushed it will find it.
            std.log.scoped(.nilo_job).warn("row {d} is a \"{s}\", which this program has no job for; leaving it", .{ claimed.id, claimed.kind });
            self.store.release(scope, claimed.id) catch |err| {
                std.log.scoped(.nilo_job).err("releasing row {d}: {t}", .{ claimed.id, err });
            };
        }

        fn executeKind(self: *Self, comptime K: type, scope: anytype, claimed: Claimed) void {
            const log = std.log.scoped(.nilo_job);
            const retry: Retry = K.retry;
            const now = core.nowMicros();

            // Past the last retry already — a row that was reclaimed after its
            // lease ran out one time too many, which is what a crash loop
            // looks like from the table.
            if (claimed.attempts > @as(u32, retry.times) + 1) {
                self.finishDead(scope, claimed.id, K, "LeaseExpired", claimed.attempts);
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

            const value = std.json.parseFromSliceLeaky(K, scope.arena(), claimed.payload, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                // A payload this binary cannot read is not going to become
                // readable by trying again.
                self.finishDead(scope, claimed.id, K, @errorName(err), claimed.attempts);
                return;
            };

            var bound: core.Limits.Bound = .idle;
            defer bound.release();
            bound.arm(self.limits, if (@hasDecl(K, "timeout_ms")) K.timeout_ms else self.settings.timeout_ms);

            const outcome = self.call(K, value, scope);
            if (outcome) |_| {
                self.store.done(scope, claimed.id) catch |err| log.err("row {d}: {t}", .{ claimed.id, err });
                self.note(claimed.id, .done, claimed.attempts);
                if (comptime scheduled(K)) self.pushNext(K, scope, core.nowMicros());
                return;
            } else |err| {
                if (err == error.Canceled and !bound.fired()) {
                    // The server is going. The row never ran to the end, so
                    // it goes back untouched; whoever starts next takes it.
                    self.stopping.store(true, .release);
                    self.store.release(scope, claimed.id) catch |e| log.err("row {d}: {t}", .{ claimed.id, e });
                    self.note(claimed.id, .queued, claimed.attempts -| 1);
                    return;
                }
                const name = if (bound.fired()) "TimedOut" else @errorName(err);
                if (claimed.attempts > retry.times) {
                    self.finishDead(scope, claimed.id, K, name, claimed.attempts);
                    return;
                }
                const again = core.nowMicros() + @as(i64, @intCast(retry.delayMs(claimed.attempts))) * std.time.us_per_ms;
                log.warn("\"{s}\" row {d} failed with {s} on attempt {d}; again in {d}ms", .{
                    K.nilo_job, claimed.id, name, claimed.attempts, retry.delayMs(claimed.attempts),
                });
                self.store.retry(scope, claimed.id, again, name) catch |e| log.err("row {d}: {t}", .{ claimed.id, e });
                self.note(claimed.id, .queued, claimed.attempts);
            }
        }

        /// `warn` rather than `err`, and not because a dead row is minor: the
        /// test runner counts an `err` line as a failed run, so a module that
        /// logs `err` on a path a test takes is a module that path cannot be
        /// tested on (`sql/db.zig`'s `enumOf` has the same note). A store that
        /// cannot be written to is `err` — nothing here takes that path on
        /// purpose.
        fn finishDead(self: *Self, scope: anytype, id: Id, comptime K: type, name: []const u8, attempts: u32) void {
            std.log.scoped(.nilo_job).warn("\"{s}\" row {d} is dead after {d} attempt(s): {s}", .{ K.nilo_job, id, attempts, name });
            self.store.dead(scope, id, name) catch |e| std.log.scoped(.nilo_job).err("row {d}: {t}", .{ id, e });
            self.note(id, .dead, attempts);
            // A schedule whose tick died still has a next tick.
            if (comptime scheduled(K)) self.pushNext(K, scope, core.nowMicros());
        }

        /// `K.run` with its arguments found: the value, the Scope, and every
        /// pointer after them looked up in `deps` by type.
        fn call(self: *Self, comptime K: type, value: K, scope: anytype) anyerror!void {
            const params = @typeInfo(@TypeOf(K.run)).@"fn".params;
            var args: std.meta.ArgsTuple(@TypeOf(K.run)) = undefined;
            args[0] = value;
            args[1] = runOf(scope);
            inline for (params[2..], 2..) |p, i| {
                args[i] = @field(self.deps, depField(Deps, p.type.?));
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

        /// Make sure every scheduled kind has its next tick queued. On start,
        /// and by every tick for the one after it.
        fn seedSchedules(self: *Self, scope: anytype) !void {
            const now = core.nowMicros();
            inline for (kinds) |K| {
                if (comptime scheduled(K)) self.pushNext(K, scope, now);
            }
        }

        fn pushNext(self: *Self, comptime K: type, scope: anytype, after: i64) void {
            const at = K.schedule.next(after);
            _ = self.store.push(scope, K.nilo_job, "{}", .{ .run_at = at, .unique = schedule_key }) catch |err| {
                std.log.scoped(.nilo_job).err("queueing the next \"{s}\": {t}", .{ K.nilo_job, err });
            };
        }

        fn note(self: *Self, id: Id, state: State, attempts: u32) void {
            if (StatusSpace == void) return;
            var buf: [20]u8 = undefined;
            self.statuses.put(idKey(&buf, id), .{ .state = state, .attempts = attempts });
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

/// The field of `Deps` whose type is `P`, or a Refusal naming what `run`
/// asked for.
fn depField(comptime Deps: type, comptime P: type) []const u8 {
    for (@typeInfo(Deps).@"struct".fields) |f| {
        if (f.type == P) return f.name;
    }
    unreachable;
}

// -- the checks -----------------------------------------------------------

fn checkKinds(comptime kinds: []const type, comptime Deps: type) void {
    if (kinds.len == 0) @compileError(
        "nilo: `job.Jobs`'s `.kinds` is empty, so this queue could run nothing.\n" ++
            "  Give it at least one job type.",
    );
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
        if (@hasDecl(K, "timeout_ms")) {
            if (K.timeout_ms == 0) @compileError(
                "nilo: the job " ++ name ++ "'s `timeout_ms` is 0, which is no deadline and no lease.\n" ++
                    "  A worker that dies holding this row would hold it forever. Leave the declaration out for the queue's default.",
            );
        }

        checkRun(K, name, Deps);

        if (scheduled(K)) {
            if (@TypeOf(K.schedule) != Schedule) @compileError(
                "nilo: the job " ++ name ++ "'s `schedule` is " ++ @typeName(@TypeOf(K.schedule)) ++ " rather than a `job.Schedule`.\n" ++
                    "  `pub const schedule = job.cron(\"0 3 * * *\");` or `job.every(600_000)`.",
            );
            if (!@hasDecl(K, "overlap")) @compileError(
                "nilo: the scheduled job " ++ name ++ " does not say what happens when a tick arrives while the last one is still running.\n" ++
                    "  `pub const overlap: job.Overlap = .skip;` drops it; `.queue` starts it on another worker. " ++
                    "Neither is right for everybody, so neither is the default (ADR 0199).",
            );
            if (@TypeOf(K.overlap) != Overlap) @compileError(
                "nilo: the scheduled job " ++ name ++ "'s `overlap` is not a `job.Overlap`.\n" ++
                    "  `pub const overlap: job.Overlap = .skip;` or `.queue`.",
            );
            if (!@hasDecl(K, "missed")) @compileError(
                "nilo: the scheduled job " ++ name ++ " does not say what happens to a tick that was missed while the process was down.\n" ++
                    "  `pub const missed: job.Missed = .drop;` forgets it; `.catch_up` runs once for it. " ++
                    "Neither is right for everybody, so neither is the default (ADR 0199).",
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
    const shape = "\n  `pub fn run(self: " ++ name ++ ", scope: *nilo.Run, …) !void` — the job by value, then the Run, then any service by pointer.";
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
        if (@typeInfo(P) != .pointer or @typeInfo(P).pointer.size != .one) @compileError(
            "nilo: the job " ++ name ++ "'s `run` takes " ++ @typeName(P) ++ " at position " ++
                std.fmt.comptimePrint("{d}", .{i}) ++ ", and after the job and the Run every argument is a service, by pointer." ++ shape,
        );
        var found = false;
        for (@typeInfo(Deps).@"struct".fields) |f| {
            if (f.type == P) found = true;
        }
        if (!found) @compileError(
            "nilo: the job " ++ name ++ "'s `run` asks for a " ++ @typeName(P) ++ ", and `job.Jobs`'s `.deps` has no such thing.\n" ++
                "  A worker has no registry to look in; the deps struct is the whole of what a `run` may ask for. " ++
                "Add a field of that type to `.deps` and pass it at `open`.",
        );
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

const Tick = struct {
    pub const nilo_job = "tick";
    pub const retry: Retry = .none;
    pub const schedule = every(1);
    pub const overlap: Overlap = .skip;
    pub const missed: Missed = .catch_up;

    pub fn run(self: Tick, scope: *core.Run, ledger: *Ledger) !void {
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

const TestJobs = Jobs(.{
    .kinds = .{ Greet, Flaky, Tick, Strict },
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

    try jobs.seedSchedules(&run);
    // One row per scheduled kind.
    try testing.expectEqual(@as(u64, 2), (try jobs.stats(&run)).queued);
    // Seeding twice is the same two rows: the schedule key is unique.
    try jobs.seedSchedules(&run);
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
    try jobs.nilo_start(io, .off);

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
