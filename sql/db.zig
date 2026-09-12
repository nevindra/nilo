//! The thing a handler holds: a pool of connections, and the calls that
//! turn a Row plus a struct of options into rows of that Row.
//!
//! ```zig
//! fn listAdults(db: *sql.Db, c: *nilo.Ctx) ![]User {
//!     return db.select(User, c, .{ .where = .{ .age = .{ .gt = 18 } } });
//! }
//! ```
//!
//! ## Why it is built twice
//!
//! A `Db` cannot be finished before `listen()`. The pool has to dial, and
//! dialling needs the event loop, and the loop does not exist until the
//! server starts — and a pool that dialled without one would block the
//! thread every request on it shares (ADR 0014). So `init` records what to
//! connect to and opens nothing, and `nilo_start` does the rest once the
//! loop is up (ADR 0040).
//!
//! That is also what makes a server boot with its database switched off:
//! `connect_on_init` defaults to zero, so startup asks for a pool rather
//! than for a connection. **That sentence was false for as long as it had
//! been written** — see `Opts.connect_on_init` and ADR 0062 — and what
//! holds it now is `bench/sql_server.zig`, which boots against a port
//! nothing is listening on. Somebody working on an endpoint that never
//! touches Postgres does not need Postgres running. The first request that
//! *does* touch it gets `error.Disconnected`, which reaches the client as a
//! 500 like any other error a handler did not catch — `AlreadyExists` is
//! the only one of the four given an answer of its own (ADR 0039), because
//! it is the only one whose meaning does not change with the request around
//! it. A handler that wants a 503 here says so with a fail function.
//!
//! **A `Db` with a `checking` list dials one anyway** (ADR 0144). A pool of
//! nothing has nothing for the check to borrow, so on `.{}` the check
//! answered `Disconnected` and the server started with a warning — a second
//! way to have no schema check while believing there is one, and the one you
//! get by writing the defaults. The dial is still allowed to fail: the
//! server starts, and the line it prints says the check is not happening
//! rather than that it passed.
//!
//! ## Where `Str` stops
//!
//! Text handed back by the driver is valid only until the next row is
//! pulled (`wire.zig`). That rule stops here: every column read into a
//! `Str` or a `[]const u8` is copied into the request arena on the way
//! past, so what a handler holds lives exactly as long as the response it
//! is going into. Nothing above this file has to know the borrow existed.
//!
//! Which is why every call wants the `Ctx`: not to read the request, but
//! for the arena to put the answer in.
//!
//! **`stream` is the exception, and it says so in its type.** A result set
//! too big to hold cannot be copied anywhere, so its rows come back as
//! `Borrowed(Row)` — `Row` with every `Str` replaced by `[]const u8`,
//! pointing into the driver's buffer and good only until the next one. The
//! type carries the rule instead of a comment (ADR 0039).
//!
//! ## Reads and writes are the same shape
//!
//! `select`, `one`, `count`, `exists`, `insert`, `update` and `delete` all
//! take a Row, a Ctx and a struct written where it is used, and all of them
//! settle their statement while compiling. `find` is the one exception and
//! takes a key rather than a struct, because a Row's `.key` already says
//! which column that is. `raw` is the way past all of it, for the joins and
//! aggregates this module refuses; it fills a Row the same way and gives up
//! the column check and nothing else.
//!
//! `update` and `delete` answer with a count; `updateReturning` and
//! `deleteReturning` answer with the rows themselves, which is one statement
//! where reading them separately is two and a race.

const std = @import("std");
const core = @import("nilo_core");

/// **Reached only by the tests at the bottom of this file** — a Service does
/// not import an App (ADR 0041). It is here rather than unreachable because
/// the test worth having is the one that drives a whole request through a
/// real App, and Zig makes that free: an import named only from a `test`
/// block is never analysed in a build that is not a test build, so the
/// published `nilo_sql` declares `nilo_core` alone and links no server.
const nilo = @import("nilo_http");

const dialect = @import("dialect.zig");
const postgres = @import("postgres.zig");
const rawcheck = @import("rawcheck.zig");
const row_mod = @import("row.zig");
const schema = @import("schema.zig");
const statement = @import("statement.zig");
const types = @import("types.zig");
const where_mod = @import("where.zig");
const wire_mod = @import("wire.zig");

const builtin = @import("builtin");

/// What a handler writes: `*sql.Db`. The Wire is chosen here rather than
/// spelled by the caller, so that a signature says what it means and not
/// which driver is behind it.
pub const Db = DbOf(postgres.Wire, dialect.Postgres, "");

/// A **second** database, told apart from the first by its name.
///
/// The Service registry is keyed by type (ADR 0011), so one `*sql.Db` is
/// all a program could ask for and a read replica had nowhere to live. A
/// name makes a distinct type, and two distinct types are two services:
///
/// ```zig
/// const Replica = sql.Named("replica");
///
/// fn listing(db: *Replica, c: *nilo.Ctx) ![]Product { … }   // may be stale
/// fn buy(db: *sql.Db, c: *nilo.Ctx) !Order { … }            // must not be
/// ```
///
/// **Which pool a statement takes is written in the handler's argument
/// list**, which is where the rest of this framework puts that kind of
/// decision. Nothing routes anything, and that is the design rather than
/// the first half of one — see
/// [ADR 0060](../docs/adr/0060-a-second-database-is-a-second-type.md) for
/// what a router would have had to know and could not.
pub fn Named(comptime name: []const u8) type {
    if (name.len == 0) @compileError(
        "nilo: `sql.Named(\"\")` has no name, so it is `sql.Db` with extra steps.\n" ++
            "  Give it the one a reader would want in the argument list: " ++
            "`sql.Named(\"replica\")`, `sql.Named(\"warehouse\")`.",
    );
    return DbOf(postgres.Wire, dialect.Postgres, name);
}

/// Everything above, over any Wire and any Dialect. Generic so that the
/// tests can drive the whole path against `wire.Fake` with no database
/// anywhere — the same reason `App.handleRequest` takes a Reader and a
/// Writer rather than a socket.
///
/// `name` tells two otherwise identical `Db`s apart, and has to be *kept*
/// to do it: Zig memoises a generic on the type it returns, so a parameter
/// the body never mentions gives back the same type twice. `db_name` below
/// is where it is kept, and the trap messages read it — which is the reason
/// it is not merely a marker.
/// One statement that has run, as the thing watching it is told about it
/// ([ADR 0137](../docs/adr/0137-a-statement-can-be-watched.md)).
///
/// **The values are not in it, and that is the decision rather than the first
/// version.** They are the interesting half and they are a password, an email
/// address and a card's last four digits — which is what
/// [ADR 0025](../docs/adr/0025-every-failure-answers-with-the-same-json-body.md)
/// is careful about one layer up, where a failure's message never reaches the
/// client. A log line is read by more people than a response is.
///
/// What is here is enough to answer *which statement is slow*, which is the
/// question somebody opens this for: the text, the plan name it was kept
/// under, how long it took, and how many rows it moved.
pub const Sent = struct {
    /// The statement, exactly as it went to the database. A comptime constant
    /// for everything this module writes, and the caller's own text for
    /// `db.raw` and `db.exec`.
    sql: []const u8,
    /// The name it is kept prepared under, or null for a statement that is
    /// not kept — which is `db.raw`, `db.exec`, and every statement on a `Db`
    /// with `prepared = false` (ADR 0057).
    plan: ?[]const u8,
    /// How long the database took, from the call going out to the rows being
    /// in hand. Taken from the monotonic clock, so an operator moving the
    /// wall clock mid-query cannot produce a query that took an hour.
    ///
    /// For `db.stream` it is how long the statement took to *open*: the rows
    /// are pulled by the handler afterwards, and nothing here sees the end.
    micros: u64,
    /// Rows filled, or rows changed for a statement that answers with a
    /// count. Null when nobody can say yet — a stream, or a statement that
    /// failed.
    rows: ?usize,
    /// Whether the database refused it. The error itself is not here: the
    /// caller is about to be handed it, and a watcher that has to switch on
    /// an error set is a watcher that breaks when the set grows.
    failed: bool,
    /// What the database said about refusing it, when it said anything —
    /// null on a statement that worked and on one nobody could get a word out
    /// of ([ADR 0146](../docs/adr/0146-a-statement-that-failed-says-what-the-database-said.md)).
    ///
    /// **This is not the reasoning above read backwards.** That paragraph is
    /// about the *Zig error*, which is a set that grows and breaks a switch;
    /// this is the server's own text, which is data. Leaving it out meant the
    /// whole debugging surface for a failed statement was the word
    /// `QueryFailed` — the message went to `std.log.err` and nowhere a program
    /// could reach, so an operator with a log reader had it and the code did
    /// not.
    ///
    /// It lives in the Scope's arena, so a watcher that wants to keep one past
    /// the request has to copy it — the same rule a `Str` follows. And it
    /// still never reaches the client (ADR 0025).
    problem: ?wire_mod.Problem = null,
};

/// What `db.watching` takes. A plain function pointer rather than an
/// interface: everything a watcher needs is in the `Sent`, and a nilo Service
/// is shared across every request in flight — so anything it closed over
/// would need a lock this module cannot see.
pub const Watcher = *const fn (Sent) void;

/// The last statement's failure, for the fiber that ran it
/// ([ADR 0184](../docs/adr/0184-a-failure-belongs-to-the-call-that-caused-it.md)).
///
/// **A watcher sees every statement and a caller sees one.** That is the split
/// `db.watching` gets right for logging and wrong for a branch: an observer
/// cannot tell a caller's own failure from a concurrent one on another
/// connection, and the caller is the only thing that knows what sentence the
/// failure deserves — *"was given something to do a moment ago and can no
/// longer be deleted"* rather than a 500.
///
/// **It is not a field on the `Db`, and that is the whole design.** A `Db` is
/// one Service shared by every request in flight, so a slot on it would be the
/// last failure *anywhere*. This is `threadlocal`, and a fiber owns its thread
/// for as long as it is running — a fiber only moves when it suspends, and
/// there is no suspension point between a statement failing and the `catch`
/// that reads this.
///
/// **Cleared by every statement, not only by a failing one.** The strings live
/// in the request arena, which is reset between requests on the same
/// connection, so a slot only ever written on failure would hand back freed
/// bytes to whoever asked after a statement that worked.
threadlocal var recent: Recent = .{};

const Recent = struct {
    problem: ?wire_mod.Problem = null,
    /// The arena the strings in `problem` were copied into. Two fibers are two
    /// connections and two arenas, so comparing this against the caller's is
    /// what makes a problem left behind by a fiber that moved unreadable
    /// rather than wrong.
    arena: ?std.mem.Allocator = null,
};

/// What every statement leaves behind, success included.
fn remember(arena: std.mem.Allocator, problem: ?wire_mod.Problem) void {
    recent.problem = problem;
    recent.arena = if (problem == null) null else arena;
}

/// What the database said about the last statement **this fiber** ran, or null
/// when it worked (ADR 0184).
///
/// ```zig
/// db.delete(Staff, c, .{ .where = .{ .id = id } }) catch |err| switch (err) {
///     error.ForeignKeyViolated => return fail.conflict(
///         "{s} was given something to do a moment ago and can no longer be " ++
///             "deleted. Set them inactive instead.",
///         .{name},
///     ),
///     else => return err,
/// };
/// ```
///
/// The error set is what to switch on and this is what to read afterwards —
/// `problem.constraint` is the field that says *which* unique index fired,
/// which is the half an error name cannot carry.
///
/// **It lives as long as the request does and no longer**, like every other
/// string a statement produced. Read it in the `catch`; keep a copy if it has
/// to outlive the handler.
/// Named `lastProblem` here and exported as `sql.problem`, because `problem`
/// is what every statement in this file already calls the slot it passes to
/// the Wire — and a file-scope declaration of that name shadows fifteen of
/// them.
pub fn lastProblem(c: anytype) ?wire_mod.Problem {
    comptime core.checkScope(@TypeOf(c), "sql.problem");
    const held = recent.problem orelse return null;
    const mine = recent.arena orelse return null;
    const asked = c.arena();
    // A fiber that moved between the failure and this call left its problem on
    // the other thread, and whatever is here belongs to somebody else's
    // request. Two pointers rather than a lock, and the answer is null rather
    // than a plausible sentence about the wrong row.
    if (mine.ptr != asked.ptr or mine.vtable != asked.vtable) return null;
    return held;
}

/// A ready-made watcher: one `std.log.debug` line per statement, in the
/// module's own scope.
///
/// It exists because it is what everybody writes first, and because writing it
/// once here means the guide can show `db.watching(sql.logging)` rather than
/// eleven lines somebody has to get right. Debug level, so a release build
/// with the default log level pays the branch and prints nothing.
pub fn logging(sent: Sent) void {
    const how = if (sent.failed) " failed" else "";
    // The database's own words, when there are any (ADR 0146). A watcher that
    // prints the statement and not the reason is the shape this module already
    // shipped once, and it is the one that costs somebody an afternoon.
    if (sent.problem) |said| {
        if (said.code.len == 0) {
            std.log.scoped(.nilo_sql).debug("{d}us failed ({s}): {s}", .{ sent.micros, said.message, sent.sql });
        } else {
            std.log.scoped(.nilo_sql).debug("{d}us failed ({s} [{s}]): {s}", .{
                sent.micros,
                said.message,
                said.code,
                sent.sql,
            });
        }
        return;
    }
    if (sent.rows) |n| {
        std.log.scoped(.nilo_sql).debug("{d}us{s}, {d} row(s): {s}", .{ sent.micros, how, n, sent.sql });
    } else {
        std.log.scoped(.nilo_sql).debug("{d}us{s}: {s}", .{ sent.micros, how, sent.sql });
    }
}

pub fn DbOf(comptime W: type, comptime D: type, comptime name: []const u8) type {
    comptime wire_mod.assertWire(W);
    comptime dialect.assertDialect(D);

    return struct {
        const Self = @This();

        /// Empty for the ordinary `sql.Db`, the caller's word for a
        /// `sql.Named`. Read by the traps so a panic says *which* database
        /// leaked the connection, which is the whole difficulty of having
        /// two.
        pub const db_name = name;

        /// The half that writes the SQL. A handler never names it — that is
        /// the whole point of the seam — and a migration has to, because DDL
        /// is the one thing this module generates from a type rather than
        /// from a statement it already knows
        /// ([ADR 0153](../docs/adr/0153-a-migration-is-a-diff-against-a-snapshot.md)).
        pub const Dialect = D;

        /// `db_name` as it goes into a message: the ordinary `Db` is "the
        /// database", a named one is quoted. Comptime, so a trap that never
        /// fires costs nothing to have worded well.
        const whoami = if (name.len == 0) "the database" else "`sql.Named(\"" ++ name ++ "\")`";

        gpa: std.mem.Allocator,
        url: []const u8,
        opts: Opts,
        /// Null until `nilo_start`. A handler cannot observe the null: the
        /// server does not accept a connection until the hook has run.
        wire: ?W = null,
        /// The schema check, with the Row list baked in by `checking`. Null
        /// when nobody asked for one.
        check: ?*const fn (*Self) anyerror!usize = null,
        /// Who to tell about each statement, or null for nobody — which is
        /// the default and costs one null test per statement
        /// ([ADR 0137](../docs/adr/0137-a-statement-can-be-watched.md)).
        watch: ?Watcher = null,
        /// Debug only: transactions begun and not yet ended. A leak here is
        /// a connection that never goes back, so the count is asserted at
        /// `deinit` — see `begin`.
        ///
        /// **Moved atomically, because a `Db` is a Service and a Service is
        /// shared across threads** (ADR 0011). A plain `+= 1` here is the
        /// exact race that ADR warns about, and losing a count does not
        /// merely weaken the trap: drift upwards makes `deinit` accuse a
        /// program of a leak that never happened, and drift downwards
        /// underflows a `usize` and panics. A trap that fires on correct
        /// code is worse than no trap.
        open_transactions: if (traps_enabled) usize else void = if (traps_enabled) 0 else {},
        /// Debug only: result sets opened with `stream` and never closed.
        ///
        /// The same trap as the one above, for the mistake that costs more.
        /// An abandoned transaction holds a connection until the request
        /// ends; an abandoned result set holds one until the process does,
        /// because nothing else will ever call `close`. A handful of them
        /// empty the pool and the server stops answering — so the cheaper
        /// mistake was the one being watched and the expensive one was not.
        open_streams: if (traps_enabled) usize else void = if (traps_enabled) 0 else {},

        pub const Opts = struct {
            /// Connections held open. The ceiling on how many requests can
            /// be inside the database at once, so it wants to be about the
            /// concurrency the database can take, not the concurrency the
            /// server can.
            size: u16 = 10,
            /// How many to dial during `listen()`. Zero on purpose: see the
            /// header. Raise it to fail fast on a bad URL in production.
            ///
            /// **This did not work until it was measured, and the reason is
            /// worth knowing** ([ADR 0062](../docs/adr/0062-a-pool-that-dialled-itself-whatever-it-was-told.md)):
            /// `pg.Pool.initUri` dropped the field on the way past, so every
            /// pool dialled itself in full at startup and a server whose
            /// database was down refused to start — the opposite of what the
            /// header promised. The URI is parsed in `sql/postgres.zig` now.
            ///
            /// **Under `std.Io.Threaded`, set this to `size`.** Anything
            /// less leaves pg.zig's reconnector to fill the rest from a
            /// spawned OS thread, and that thread parks on an `xsync.Mutex`
            /// against the `Io` it was handed — which `Threaded` cannot do
            /// for a caller that is not one of its tasks, so it reaches
            /// `unreachable`. Under the engine it is fine, because zio parks
            /// across threads; this is a constraint on a test harness rather
            /// than on a server.
            ///
            /// **Zero and a `checking` list means one, not zero** (ADR
            /// 0144). The check has to borrow a connection, and a pool that
            /// dialled none had nothing to lend it, so the check that was
            /// meant to stop a bad deploy became a warning. The dial is
            /// still allowed to fail — the server starts either way.
            connect_on_init: u16 = 0,
            /// How long a caller waits for a free connection.
            timeout_ms: u32 = 10 * std.time.ms_per_s,
            /// Whether a Row that disagrees with its table stops the server
            /// starting, or only says so in the log. A disagreement is a
            /// 500 waiting to happen, so stopping is the default.
            schema_mismatch_is_fatal: bool = true,
            /// Whether a statement is kept prepared on the connection it went
            /// down, so the next one that sends it skips Parse and Describe.
            ///
            /// **On by default, because it is measured at 31% of a key lookup
            /// and 15% of a page with a sort** — ~12 µs a query either way,
            /// which is a fixed cost and therefore matters most to the cheap
            /// queries a service runs most of
            /// ([ADR 0057](../docs/adr/0057-a-statement-that-is-a-constant-can-be-prepared-once.md)).
            ///
            /// What is kept is bounded by the *program* rather than by
            /// traffic: every statement this module sends is settled while
            /// compiling, and `db.raw` — the one whose text arrives at run
            /// time — is never kept whatever this says.
            ///
            /// Turn it off for a **connection pooler in transaction mode**.
            /// pgbouncer hands out a different server connection per
            /// transaction, so a statement prepared on one is missing on the
            /// next and Postgres says so. The failure is loud rather than
            /// silent, which is why the default is the fast one.
            prepared: bool = true,
        };

        /// Record what to connect to. Opens nothing — see the header.
        pub fn init(gpa: std.mem.Allocator, url: []const u8, opts: Opts) Self {
            return .{ .gpa = gpa, .url = url, .opts = opts };
        }

        pub fn deinit(self: *Self) void {
            if (traps_enabled) {
                const open = self.heldCount(&self.open_transactions);
                if (open != 0) std.debug.panic(
                    "nilo_sql: {d} transaction(s) were begun on {s} and never ended. Every " ++
                        "`begin` wants `defer tx.deinit()` on the line after it, or the " ++
                        "connection never goes back to the pool.",
                    .{ open, whoami },
                );
                const streaming = self.heldCount(&self.open_streams);
                if (streaming != 0) std.debug.panic(
                    "nilo_sql: {d} result set(s) were opened with `stream` on {s} and never " ++
                        "closed. " ++
                        "Every `stream` wants `defer rows.close()` on the line after it, or the " ++
                        "connection never goes back to the pool at all — an abandoned " ++
                        "transaction costs one until the request ends, an abandoned result set " ++
                        "costs one for as long as the process runs.",
                    .{ streaming, whoami },
                );
            }
            if (self.wire) |*w| w.close();
            self.wire = null;
        }

        /// The name this statement is kept prepared under, or null when this
        /// `Db` was told not to keep any (`Opts.prepared`).
        ///
        /// The name is comptime and the branch is one load and a test, which
        /// is what a 12 µs saving is being bought with.
        fn planOf(self: *Self, comptime stmt: statement.Statement) ?[]const u8 {
            if (!self.opts.prepared) return null;
            return comptime statement.planName(stmt.sql);
        }

        /// The same, for a statement this module did not write.
        ///
        /// `db.raw` used to be the one call that was never prepared, on
        /// ADR 0057's reasoning that its text arrived at run time and there
        /// was no bound on how many names there would be. Its text is
        /// comptime now, so both halves of that stopped being true and the
        /// same 12 µs applies ([ADR 0148](../docs/adr/0148-a-raw-statement-is-counted-while-compiling.md)).
        fn rawPlanOf(self: *Self, comptime sql: []const u8) ?[]const u8 {
            if (!self.opts.prepared) return null;
            return comptime statement.planName(sql);
        }

        /// One of the Debug-only counters, read the way it is written. Both
        /// are `void` outside Debug, which is why every use of them sits
        /// inside an `if (traps_enabled)` the compiler folds away.
        fn heldCount(self: *Self, field: *const usize) usize {
            _ = self;
            return @atomicLoad(usize, field, .monotonic);
        }

        /// Move one of them. `delta` is `.Add` or `.Sub`; the amount is
        /// always one, because these count things that are held.
        fn hold(self: *Self, field: *usize, comptime delta: std.builtin.AtomicRmwOp) void {
            _ = self;
            _ = @atomicRmw(usize, field, delta, 1, .monotonic);
        }

        /// Check these Rows against the tables they name, once, while the
        /// server is starting.
        ///
        /// The list cannot be an option on `Opts`, because a `[]const type`
        /// would make the whole struct comptime-only and a `Db` is a
        /// runtime value a handler holds. So it is a call, and what it
        /// stores is a function with the list already inside it.
        ///
        /// ```zig
        /// var db = sql.Db.init(gpa, url, .{});
        /// db.checking(&.{ User, Order });
        /// ```
        pub fn checking(self: *Self, comptime Rows: []const type) void {
            self.check = &struct {
                fn run(me: *Self) anyerror!usize {
                    return me.checkSchema(Rows);
                }
            }.run;
        }

        /// Be told about every statement this `Db` sends
        /// ([ADR 0137](../docs/adr/0137-a-statement-can-be-watched.md)).
        ///
        /// ```zig
        /// db.watching(sql.logging);   // one debug line per statement
        /// ```
        ///
        /// The text, the plan name, how long it took and how many rows moved
        /// — and **not the values**, for the reason `Sent` gives. Set it
        /// before `listen()`: it is read on every statement from every fiber,
        /// and nothing here locks it.
        ///
        /// One watcher rather than a list. A second one is a function that
        /// calls two, which is a line the caller writes and not a registry
        /// this module has to grow.
        pub fn watching(self: *Self, f: Watcher) void {
            self.watch = f;
        }

        /// The clock, read only when somebody is listening. Null means
        /// nobody is, and `told` below does nothing for it.
        fn timing(self: *const Self) ?i64 {
            return if (self.watch == null) null else core.monotonicMicros();
        }

        /// Tell the watcher what happened, if there is one.
        ///
        /// `problem` is what the Wire left in the slot the caller handed it,
        /// which is null on every path that did not fail and on the failures
        /// nobody could get a word out of (ADR 0146).
        fn told(
            self: *const Self,
            arena: std.mem.Allocator,
            started: ?i64,
            sql: []const u8,
            plan: ?[]const u8,
            rows: ?usize,
            failed: bool,
            problem: ?wire_mod.Problem,
        ) void {
            // Before either early return below, because this is not the
            // watcher's half: a `Db` with no watcher and a `Db` with timing off
            // both still owe the caller an answer about the statement it just
            // ran (ADR 0184).
            remember(arena, problem);
            const f = self.watch orelse return;
            const at = started orelse return;
            const took = core.monotonicMicros() - at;
            f(.{
                .sql = sql,
                .plan = plan,
                // A monotonic clock does not go backwards, so this cannot be
                // negative — the clamp is what makes that a fact about this
                // line rather than a fact about the kernel.
                .micros = if (took < 0) 0 else @intCast(took),
                .rows = rows,
                .failed = failed,
                .problem = problem,
            });
        }

        /// A statement that answers with a count rather than rows, timed.
        /// The one funnel for `exec`, so that a watcher sees an `UPDATE` that
        /// returns nothing on the same terms as a `SELECT`.
        fn execTold(
            self: *Self,
            tx: ?*W.Tx,
            c: anytype,
            sql: []const u8,
            plan: ?[]const u8,
            values: anytype,
        ) !usize {
            const arena = c.arena();
            const started = self.timing();
            const w = try self.wireOf();
            var problem: ?wire_mod.Problem = null;
            const changed = if (tx) |t|
                t.exec(arena, sql, values, plan, &problem) catch |err| {
                    self.told(arena, started, sql, plan, null, true, problem);
                    return err;
                }
            else
                w.exec(arena, sql, values, plan, &problem) catch |err| {
                    self.told(arena, started, sql, plan, null, true, problem);
                    return err;
                };
            self.told(arena, started, sql, plan, changed, false, null);
            return changed;
        }

        /// Finish building, now that there is an event loop to dial
        /// through. Called by `listen()` before the first connection is
        /// accepted (ADR 0040).
        ///
        /// **`limits` is what can stop a fiber that is waiting**, and it is
        /// taken for the same reason `nilo_fetch` and `nilo_s3` take one: the
        /// Engine owns the timer and a Service owns the number
        /// (`core/limits.zig`). A `Db` no App holds — a CLI, a migration, a
        /// test — passes `.off` and is bounded by nothing, which is what it
        /// was before ADR 0135 either way.
        pub fn nilo_start(self: *Self, io: std.Io, limits: core.Limits) !void {
            // **A check with nothing to check against never ran**
            // ([ADR 0144](../docs/adr/0144-a-check-dials-the-connection-it-needs.md)).
            // `connect_on_init` is 0 by default, so a `Db` written `.{}`
            // reached the schema check with an empty pool, the check
            // answered `Disconnected`, and the server started with a
            // warning. The point of checking at boot is that a Row
            // disagreeing with its table stops a deploy; on defaults it
            // stopped nothing, and the deploy was green.
            //
            // So a `Db` that has a check to run dials one connection for
            // it. What does not change is ADR 0039's promise that a
            // database which is merely down does not stop the server: a
            // dial that fails here falls back to the pool the caller asked
            // for and says in one line that the check is not happening.
            const dialing_for_check = self.check != null and self.opts.connect_on_init == 0;
            var check_dial_failed = false;

            var opened = W.open(io, self.gpa, self.url, .{
                .size = self.opts.size,
                .connect_on_init = if (dialing_for_check) 1 else self.opts.connect_on_init,
                .timeout_ms = self.opts.timeout_ms,
                .limits = limits,
            });
            if (dialing_for_check) if (opened) |_| {} else |err| {
                // A URL nilo cannot read will not become readable on a
                // second attempt, so that one goes straight to the message
                // written for it.
                if (!isUrlProblem(err)) {
                    std.log.warn(
                        "nilo could not dial the database to check the schema against it " ++
                            "({s}), so it is starting without the check. `connect_on_init` " ++
                            "is 0, which is what asks for a server that starts while its " ++
                            "database is down.",
                        .{@errorName(err)},
                    );
                    check_dial_failed = true;
                    opened = W.open(io, self.gpa, self.url, .{
                        .size = self.opts.size,
                        .connect_on_init = 0,
                        .timeout_ms = self.opts.timeout_ms,
                        .limits = limits,
                    });
                }
            };

            self.wire = opened catch |err| {
                // Two failures reach here and they want different sentences.
                // Before ADR 0062 the pool dialled itself whatever
                // `connect_on_init` said, so *both* of them got the one
                // about the URL — which sent people to check a URL that was
                // correct while their database was down.
                //
                // **`warn` rather than `err`, for the reason `sqlite.read`'s
                // is one and `wireOf`'s before it**
                // ([ADR 0178](../docs/adr/0178-a-suite-whose-database-is-down-is-not-a-suite-that-failed.md)):
                // `std.log.err` fails the test runner for every test that
                // provokes it, and this line runs once per test in a suite
                // whose database is not running. The error is returned and is
                // what the caller acts on — `nilo_start` is the one call here
                // that both logs and returns, so the line is a diagnostic
                // beside the answer rather than the answer itself.
                if (isUrlProblem(err)) std.log.warn(
                    "nilo could not read the database URL \"{s}\" ({s}). This is the URL " ++
                        "itself rather than the database: the scheme has to be `postgres://` " ++
                        "or `postgresql://`, and the only parameters understood are `sslmode` " ++
                        "and `tcp_user_timeout`.",
                    .{ redacted(self.url), @errorName(err) },
                ) else std.log.warn(
                    "nilo could not open {d} of the {d} connections to \"{s}\" ({s}). " ++
                        "`connect_on_init` is {d}, so startup dials that many and stops when it " ++
                        "cannot — the database may be down, the credentials wrong, or `size` " ++
                        "past the server's `max_connections`. Set `connect_on_init = 0` to " ++
                        "start anyway and let the first request that needs the database say so.",
                    .{
                        self.opts.connect_on_init,
                        self.opts.size,
                        redacted(self.url),
                        @errorName(err),
                        self.opts.connect_on_init,
                    },
                );
                return err;
            };

            // Already said above, in the sentence that names the dial.
            if (check_dial_failed) return;

            const check = self.check orelse return;
            // A schema check needs a connection, and a caller who set
            // `connect_on_init` themselves may have set it to 0. A database
            // that is merely not running is not a mistake anybody can fix by
            // reading a stack trace, so it is said plainly and startup
            // carries on.
            const problems = check(self) catch |err| {
                std.log.warn(
                    "nilo could not check the schema ({s}). The tables will be checked by " ++
                        "whichever request reaches them first, which is later than anybody wanted.",
                    .{@errorName(err)},
                );
                return;
            };
            if (problems != 0 and self.opts.schema_mismatch_is_fatal) {
                // **This one stays at `err` while the two above dropped to
                // `warn`, and the line between them is worth stating**
                // ([ADR 0178](../docs/adr/0178-a-suite-whose-database-is-down-is-not-a-suite-that-failed.md)).
                // A database that is not running is a fact about the machine
                // the suite is on; a Row that disagrees with its table is a
                // broken program, and a test runner going red for it is the
                // correct answer rather than noise. `checkSchema` lists each
                // one at `err` for the same reason.
                std.log.err(
                    "nilo found {d} disagreement(s) between a Row and its table, listed above. " ++
                        "Each one is a request that would have failed later; fix them, or set " ++
                        "`.schema_mismatch_is_fatal = false` to start anyway.",
                    .{problems},
                );
                return error.SchemaMismatch;
            }
        }

        /// Put the pool down, on the loop it was built on
        /// ([ADR 0151](../docs/adr/0151-a-service-is-stopped-before-the-loop-is.md)).
        ///
        /// `listen()` calls this on the way out, after the last connection
        /// has been cut off and before the Engine's loop is torn down. It has
        /// to happen there rather than in `deinit`: pg.zig's pool refills
        /// itself from a task on that loop, and a task outstanding when the
        /// Runtime is deinitialised is an assert inside zio, one line after
        /// nilo has said it stopped cleanly.
        ///
        /// **Idempotent, and it has to be.** It runs when `nilo_start` never
        /// ran — a `Db` provided beside another one that refused the boot —
        /// and `deinit` runs after it on the caller's own `defer`. Clearing
        /// `wire` is what makes both of those a no-op.
        pub fn nilo_stop(self: *Self) void {
            if (self.wire) |*w| w.close();
            self.wire = null;
        }

        /// What the health route asks
        /// ([ADR 0192](../docs/adr/0192-a-health-route-asks-the-services.md)).
        /// A pool that is up is a pool that can answer `SELECT 1`, and
        /// nothing short of sending one says so: `connect_on_init = 0` is a
        /// server that starts with its database down, and this is where that
        /// becomes a 503 rather than a 200 over a pool with nothing in it.
        ///
        /// One statement per probe, on the balancer's schedule rather than a
        /// request's. It goes through `exec`, so it is prepared like any other
        /// and a watcher sees it.
        pub fn nilo_ready(self: *Self, scope: *core.AnyScope) ?[]const u8 {
            if (self.wire == null) return "not started: `listen()` has not run";
            _ = self.exec(scope, "SELECT 1", .{}) catch |err| return switch (err) {
                error.Disconnected => "the database is not answering",
                error.TimedOut => "the database took too long to answer",
                else => "the database refused SELECT 1",
            };
            return null;
        }

        // -- reading ---------------------------------------------------------

        /// Every row matching `options`, in the request's arena.
        ///
        /// The statement itself was settled while compiling: `options` only
        /// carries the values (ADR 0039).
        pub fn select(self: *Self, comptime Row: type, c: anytype, options: anytype) ![]Row {
            comptime core.checkScope(@TypeOf(c), "db.select");
            comptime assertUnlocked(Row, @TypeOf(options), "db.select", "Begin one and ask there: `var tx = try db.begin(c, .{}); defer tx.deinit();` " ++
                "and then `tx.select(…)`.");
            const stmt = comptime statement.select(D, Row, @TypeOf(options));
            return fill(Row, stmt.reserve, self, null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
        }

        /// The first row matching `options`, or null.
        ///
        /// `?Row` is already a 404 in the typed layer (ADR 0024), so a
        /// handler that returns this and nothing else is a whole endpoint.
        ///
        /// The statement carries its own `LIMIT 1`, so a condition on a
        /// column that is not unique costs one row rather than every match.
        /// A `.limit` written alongside it is a Refusal.
        pub fn one(self: *Self, comptime Row: type, c: anytype, options: anytype) !?Row {
            comptime core.checkScope(@TypeOf(c), "db.one");
            comptime assertUnlocked(Row, @TypeOf(options), "db.one", "Begin one and ask there: `var tx = try db.begin(c, .{}); defer tx.deinit();` " ++
                "and then `tx.one(…)`.");
            const stmt = comptime statement.one(D, Row, @TypeOf(options));
            const found = try fill(Row, stmt.reserve, self, null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
            return if (found.len == 0) null else found[0];
        }

        /// The row a key identifies, or null.
        ///
        /// ```zig
        /// fn show(db: *sql.Db, c: *nilo.Ctx, id: i64) !?User {
        ///     return db.find(User, c, id);
        /// }
        /// ```
        ///
        /// The column comes from the Row's `.key`, so the same lookup is not
        /// written out at every call site — and `?Row` is already a 404 in
        /// the typed layer (ADR 0024), which makes the two lines above a
        /// whole endpoint. It is `one` with the condition filled in, `LIMIT
        /// 1` included; a struct where the key goes is a Refusal pointing at
        /// `one`.
        ///
        /// **A key of several columns is handed over by name**
        /// ([ADR 0172](../docs/adr/0172-a-key-is-as-many-columns-as-it-takes.md)):
        ///
        /// ```zig
        /// const seat = try db.find(Seat, c, .{ .tenant_id = tenant, .id = id });
        /// ```
        ///
        /// Named rather than positional, because two key columns of the same
        /// type written the other way round would find the wrong row and
        /// report nothing. A column left out, a column that is not part of the
        /// key, and a tuple are all Refusals.
        pub fn find(self: *Self, comptime Row: type, c: anytype, key: anytype) !?Row {
            comptime core.checkScope(@TypeOf(c), "db.find");
            const stmt = comptime statement.find(D, Row, @TypeOf(key));
            const found = try fill(Row, stmt.reserve, self, null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, key, c));
            return if (found.len == 0) null else found[0];
        }

        /// How many rows match `options`.
        ///
        /// Pagination needs a total, and the way to get one before this was
        /// `db.raw` with a Row invented to hold a number. The condition is
        /// compiled by the same walker `select` uses, so the count cannot
        /// drift from the query it is counting. No `.where` counts the table.
        pub fn count(self: *Self, comptime Row: type, c: anytype, options: anytype) !usize {
            comptime core.checkScope(@TypeOf(c), "db.count");
            const stmt = comptime statement.count(D, Row, @TypeOf(options));
            const n = try only(i64, self, null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
            // `count(*)` is a `bigint` and never negative. A negative one
            // would mean the column read as something else entirely.
            if (n < 0) return error.QueryFailed;
            return @intCast(n);
        }

        /// A page of rows, and how many the condition matched before the
        /// `.limit` cut it — in one statement
        /// ([ADR 0185](../docs/adr/0185-a-page-knows-what-it-left-out.md)).
        ///
        /// ```zig
        /// const found = try db.page(Order, c, .{
        ///     .where = .{ .status = "open" },
        ///     .order = .{ .id = .asc },
        ///     .limit = 20,
        ///     .offset = page * 20,
        /// });
        /// // found.rows is []Order, found.total is every order that matched.
        /// ```
        ///
        /// **One statement rather than two, and the round trip is the smaller
        /// half of why.** `db.count` beside `db.select` is two statements
        /// against a table somebody else can write between, so the total and
        /// the rows can disagree and nothing says so — a list that reads
        /// *"20 of 47"* while holding 20 of 46. `count(*) OVER ()` rides on
        /// the page and cannot.
        ///
        /// It costs one integer read per statement rather than per row: the
        /// window function answers the same number on every row, so only the
        /// first is read. A condition matching nothing answers with no rows
        /// and a total of zero.
        ///
        /// **`.limit` and `.order` are both required.** With no ceiling this is
        /// the whole table and the total is `rows.len`; with no order,
        /// Postgres owes the `LIMIT` nothing, so two requests for the same
        /// page can hold one row twice and miss another. `.lock` is refused
        /// too — `FOR UPDATE` and a window function cannot be in one
        /// statement.
        pub fn page(self: *Self, comptime Row: type, c: anytype, options: anytype) !Page(Row) {
            comptime core.checkScope(@TypeOf(c), "db.page");
            const stmt = comptime statement.page(D, Row, @TypeOf(options));
            var total: i64 = 0;
            const rows = try filling(
                Row,
                stmt.reserve,
                self,
                null,
                c,
                stmt.sql,
                self.planOf(stmt),
                try valuesOf(stmt, Row, options, c),
                &total,
            );
            return .{ .rows = rows, .total = total };
        }

        /// Whether any row matches `options`.
        ///
        /// `EXISTS` rather than `count(…) > 0`: the database stops at the
        /// first match instead of counting every one of them to answer a
        /// question the first settles.
        pub fn exists(self: *Self, comptime Row: type, c: anytype, options: anytype) !bool {
            comptime core.checkScope(@TypeOf(c), "db.exists");
            const stmt = comptime statement.exists(D, Row, @TypeOf(options));
            return only(bool, self, null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
        }

        /// Rows read one at a time, for a result set too big to hold.
        ///
        /// What comes back is `Borrowed(Row)` and the text in it dies at the
        /// next `next()`. Postgres sends every row without being asked, but
        /// they are read off the socket as they arrive, so a million-row
        /// export runs flat and needs no cursor.
        ///
        /// ```zig
        /// var rows = try db.stream(User, c, .{});
        /// defer rows.close();
        /// while (try rows.next()) |u| try s.print("{d},{s}\n", .{ u.id, u.email });
        /// ```
        pub fn stream(
            self: *Self,
            comptime Row: type,
            c: anytype,
            options: anytype,
        ) !Streamed(Row) {
            comptime core.checkScope(@TypeOf(c), "db.stream");
            comptime assertUnlocked(Row, @TypeOf(options), "db.stream", "There is no `tx.stream` to move this to, either: a result set held open " ++
                "keeps its connection busy, so nothing else in the transaction could " ++
                "run until it closed. Lock the rows with `tx.select` and work through " ++
                "what comes back.");
            const stmt = comptime statement.select(D, Row, @TypeOf(options));
            const arena = c.arena();
            const w = try self.wireOf();
            const started = self.timing();
            var problem: ?wire_mod.Problem = null;
            const rows = w.run(
                arena,
                stmt.sql,
                try valuesOf(stmt, Row, options, c),
                self.planOf(stmt),
                &problem,
            ) catch |err| {
                self.told(arena, started, stmt.sql, self.planOf(stmt), null, true, problem);
                return err;
            };
            // **What a watcher is told here is the statement opening**, with
            // no row count: the rows are pulled by the handler afterwards and
            // nothing in this call sees the last one. A stream that is slow to
            // *open* is the half worth reporting, and it is the half this can
            // report honestly (ADR 0137).
            self.told(arena, started, stmt.sql, self.planOf(stmt), null, false, null);
            // Counted only once the statement is away, so a `stream` that
            // never opened is not a `stream` that was never closed.
            if (traps_enabled) self.hold(&self.open_streams, .Add);
            return .{ .db = self, .w = w, .rows = rows };
        }

        /// A statement this module will not write, filling `Row` from the
        /// columns it selects, in order.
        ///
        /// The way past *one table, conditions that filter rows*: joins,
        /// aggregates, `HAVING`, window functions, CTEs. It keeps the arena,
        /// keeps the `Str` rule and keeps the row filling.
        ///
        /// **The text is comptime and the `SELECT` list is checked against the
        /// Row** ([ADR 0148](../docs/adr/0148-a-raw-statement-is-counted-while-compiling.md)):
        /// the columns are counted against the Row's fields, each column that
        /// plainly has a name is checked against the field in its position,
        /// and a disagreement is a compile error naming both. The statement is
        /// kept prepared like every other one.
        ///
        /// **What is still given up is the *type* check**, which is the whole
        /// of what this call costs now. A comptime pass has no schema, so
        /// `SELECT id, email` into `struct { id: i64, email: Str }` is checked
        /// for shape and not for whether `email` is really `text`. That half
        /// belongs to `db.checking`, which asks the database.
        ///
        /// A `*` in the list, and a statement with no `SELECT` and no
        /// `RETURNING`, are counted as "not counted" rather than guessed at —
        /// so `SELECT *` into a narrow Row still compiles, and the run-time
        /// width check is what holds it (ADR 0134).
        pub fn raw(
            self: *Self,
            comptime Row: type,
            c: anytype,
            comptime sql: []const u8,
            values: anytype,
        ) ![]Row {
            comptime core.checkScope(@TypeOf(c), "db.raw");
            comptime rawcheck.assertList(D, Row, sql, "db.raw");
            // No ceiling: this module did not write the statement and so has
            // nothing to say about how many rows it can answer with.
            //
            // The values still go through the same conversion a Row's do
            // (ADR 0145). This module did not write the *statement*; it is
            // still the one holding a `Uuid`, a `Str` and a `Timestamp`, and a
            // parameter that meant something different here than in
            // `db.select` would be two rules for one type.
            return fill(Row, null, self, null, c, sql, self.rawPlanOf(sql), try rawValuesOf(values, c));
        }

        /// `db.raw` for a statement whose `WHERE` holds a key: the first row,
        /// or null
        /// ([ADR 0179](../docs/adr/0179-a-statement-with-a-key-in-it-has-a-single-row-answer.md)).
        ///
        /// ```zig
        /// fn card(db: *sql.Db, c: *nilo.Ctx, id: sql.Uuid) !?WorkItemCard {
        ///     return db.rawOne(WorkItemCard, c, work_item_card, .{id});
        /// }
        /// ```
        ///
        /// **`db.one` is this for the typed select and there was no `rawOne`**,
        /// so the same three lines were written at every call site: take the
        /// slice, test its length, hand back `found[0]`. `?Row` is already a
        /// 404 in the typed layer (ADR 0024), so what the handler wants is
        /// `!?T` and what it had was a slice to unwrap.
        ///
        /// **No `LIMIT 1` is added**, which is the whole of how this differs
        /// from `db.one`. This module did not write the statement and has
        /// nowhere honest to put one — a `LIMIT` after a `UNION ALL` or inside
        /// a CTE means something else, and appending text to somebody else's
        /// SQL is the thing `db.raw` exists not to do. So a statement matching
        /// many rows still costs every one of them; it is a shorter way to
        /// write the unwrap, not a cheaper statement.
        pub fn rawOne(
            self: *Self,
            comptime Row: type,
            c: anytype,
            comptime sql: []const u8,
            values: anytype,
        ) !?Row {
            comptime core.checkScope(@TypeOf(c), "db.rawOne");
            comptime rawcheck.assertList(D, Row, sql, "db.rawOne");
            const found = try fill(Row, null, self, null, c, sql, self.rawPlanOf(sql), try rawValuesOf(values, c));
            return if (found.len == 0) null else found[0];
        }

        /// A statement that answers with **nothing**, and the number of rows
        /// it changed.
        ///
        /// `CREATE TABLE`, `CREATE INDEX`, `PRAGMA`, `VACUUM`, `ANALYZE`, a
        /// `DELETE` written by hand. `raw` cannot express any of them honestly:
        /// its first argument is the Row a `SELECT` list fills, and there is no
        /// shape to describe when nothing is selected — so the only way to say
        /// "no rows" used to be passing a Row that is not being read, which
        /// reads like a mistake and was the recommended path by elimination
        /// (ADR 0078).
        ///
        /// **A SQLite application needs this and a Postgres one mostly does
        /// not**, which is why it arrived with the second Wire: there is no
        /// server to have run the DDL somewhere else, so creating the table is
        /// the application's job at startup and nobody else's.
        ///
        /// ```zig
        /// _ = try db.exec(&run,
        ///     \\CREATE TABLE IF NOT EXISTS accounts (
        ///     \\  id    INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        ///     \\  email TEXT NOT NULL UNIQUE COLLATE NOCASE
        ///     \\)
        /// , .{});
        /// ```
        ///
        /// This module still did not write the statement, so the column check
        /// it gives up is the same one `raw` gives up. What it keeps is the
        /// pool, the Scope and the seven errors.
        pub fn exec(self: *Self, c: anytype, sql: []const u8, values: anytype) !usize {
            comptime core.checkScope(@TypeOf(c), "db.exec");
            return self.execTold(null, c, sql, null, try rawValuesOf(values, c));
        }

        // -- writing ---------------------------------------------------------

        /// Insert one row and give back what the database stored, generated
        /// key and defaults included.
        ///
        /// `values` names a subset of the columns, because the ones the
        /// database fills in are exactly the ones a caller has nothing to
        /// say about. A name that is not a column is a Refusal.
        pub fn insert(self: *Self, comptime Row: type, c: anytype, values: anytype) !Row {
            comptime core.checkScope(@TypeOf(c), "db.insert");
            const stmt = comptime statement.insert(D, Row, @TypeOf(values));
            // `RETURNING` on a successful insert answers with exactly one
            // row, so the list is sized for one and never grows.
            const back = try fill(Row, 1, self, null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, values, c));
            // `RETURNING` on a successful insert answers with exactly one
            // row. Reaching here with none would mean the driver and
            // Postgres disagree about what happened, which is not something
            // to paper over with an optional.
            if (back.len == 0) return error.QueryFailed;
            return back[0];
        }

        /// Insert many rows in one statement, and give back what the database
        /// stored — in the order they were sent.
        ///
        /// ```zig
        /// const Line = struct { sku: Str, qty: i32 };
        /// const stored = try db.insertMany(Item, c, lines);   // lines: []const Line
        /// ```
        ///
        /// **One round trip, whatever the batch size.** A thousand rows
        /// inserted in a loop is a thousand round trips, and inside a
        /// transaction it is a thousand round trips holding a connection.
        /// This sends one array per column and lets Postgres `unnest` them
        /// (`statement.zig`), so the statement text is a constant and the
        /// batch size is data.
        ///
        /// The cost is **one allocation per column** — the array a column's
        /// values are gathered into — and not one per row. An empty batch
        /// sends the statement with empty arrays and answers with no rows,
        /// which is the same thing the database would have said.
        pub fn insertMany(self: *Self, comptime Row: type, c: anytype, rows: anytype) ![]Row {
            comptime core.checkScope(@TypeOf(c), "db.insertMany");
            const V = comptime batchElement(Row, @TypeOf(rows));
            const stmt = comptime statement.insertMany(D, Row, V);
            const items: []const V = rows;
            return fill(
                Row,
                items.len,
                self,
                null,
                c,
                stmt.sql,
                self.planOf(stmt),
                try batchValuesOf(stmt, Row, V, items, c),
            );
        }

        /// Change many rows in one statement, and give back the ones that
        /// were there to change.
        ///
        /// ```zig
        /// const Change = struct { id: i64, qty: i32 };
        /// const changed = try db.updateMany(Item, c, changes);   // []const Change
        /// ```
        ///
        /// **Each row is found by the Row's key, which is why there is no
        /// `.where`**: the condition is the join against the batch
        /// (`statement.zig`). A key the table does not have simply matches
        /// nothing, so the answer can be shorter than the batch — that is how
        /// to tell which ones landed.
        ///
        /// The same one-allocation-per-column cost as `insertMany`, and two
        /// properties it does not share: **the order is the planner's**, and a
        /// batch naming one key twice changes that row once. Both come from
        /// this being a join; `db.update` in a loop is the answer where either
        /// matters.
        pub fn updateMany(self: *Self, comptime Row: type, c: anytype, rows: anytype) ![]Row {
            comptime core.checkScope(@TypeOf(c), "db.updateMany");
            const V = comptime batchElement(Row, @TypeOf(rows));
            const stmt = comptime statement.updateMany(D, Row, V);
            const items: []const V = rows;
            return fill(
                Row,
                items.len,
                self,
                null,
                c,
                stmt.sql,
                self.planOf(stmt),
                try batchValuesOf(stmt, Row, V, items, c),
            );
        }

        /// Store the row, or leave the one that is already there alone —
        /// `null` when that is what happened.
        ///
        /// ```zig
        /// const made = try db.insertOrIgnore(User, c, .{ .email = email }, .email);
        /// if (made == null) { … it was already there … }
        /// ```
        ///
        /// **The optional is the whole difference from `insert`.** `DO
        /// NOTHING` stores no row, and `RETURNING` on a row that was not
        /// stored answers with nothing — so an empty answer is the ordinary
        /// outcome here where in `insert` it would mean the driver and
        /// Postgres disagree. That is why this is a call of its own rather
        /// than an option on `insert`: the shape of the answer changed, which
        /// is the same reason `one` is not `select` and `updateReturning` is
        /// not `update`.
        ///
        /// The conflict target is a column the database has a unique
        /// constraint or index on. Postgres refuses the statement at run time
        /// if it has not — nothing on this side can know, because the
        /// constraint is not a column and a Row cannot name one.
        ///
        /// **`.key` is the Row's own key**, read off the `nilo_table` that
        /// already declares it, and is what a join table wants
        /// ([ADR 0186](../docs/adr/0186-a-key-is-named-once.md)):
        ///
        /// ```zig
        /// try db.insertOrIgnore(StaffRole, c, .{ .staff_id = id, .role = role }, .key);
        /// ```
        ///
        /// Spelling the columns out is still there for what it is for — a
        /// unique index that is not the key.
        pub fn insertOrIgnore(
            self: *Self,
            comptime Row: type,
            c: anytype,
            values: anytype,
            comptime on: anytype,
        ) !?Row {
            comptime core.checkScope(@TypeOf(c), "db.insertOrIgnore");
            const stmt = comptime statement.insertOrIgnore(D, Row, @TypeOf(values), on);
            const back = try fill(Row, stmt.reserve, self, null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, values, c));
            return if (back.len == 0) null else back[0];
        }

        /// Store the row, or write these values over the one that is already
        /// there. Either way a row comes back.
        ///
        /// ```zig
        /// const user = try db.insertOrUpdate(User, c, .{
        ///     .email = email,
        ///     .name = name,
        /// }, .email);
        /// ```
        ///
        /// What it sets is every column you passed except the ones being
        /// conflicted on, each taken from the row the insert proposed. A call
        /// where that leaves nothing to set is a Refusal pointing at
        /// `insertOrIgnore`, which is the statement it was actually asking
        /// for.
        ///
        /// **One round trip and no race.** The shape this replaces is a
        /// caught `AlreadyExists` and a follow-up update, which is two round
        /// trips and still loses when two requests arrive together.
        pub fn insertOrUpdate(
            self: *Self,
            comptime Row: type,
            c: anytype,
            values: anytype,
            comptime on: anytype,
        ) !Row {
            comptime core.checkScope(@TypeOf(c), "db.insertOrUpdate");
            const stmt = comptime statement.insertOrUpdate(D, Row, @TypeOf(values), on);
            const back = try fill(Row, stmt.reserve, self, null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, values, c));
            // `DO UPDATE` always touches a row, so an empty answer here means
            // the driver and Postgres disagree — the same reasoning as
            // `insert`, and the reason this one is not an optional.
            if (back.len == 0) return error.QueryFailed;
            return back[0];
        }

        /// Change every row matching `.where`, and say how many there were.
        ///
        /// Both halves are required: an update with no `.set` changes
        /// nothing, and one with no `.where` rewrites the table. Each is a
        /// Refusal rather than a statement nobody meant to send.
        pub fn update(self: *Self, comptime Row: type, c: anytype, options: anytype) !usize {
            comptime core.checkScope(@TypeOf(c), "db.update");
            const stmt = comptime statement.update(D, Row, @TypeOf(options));
            return self.execTold(null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
        }

        /// Change every row matching `.where` and give back what the database
        /// now holds, rather than how many rows that was.
        ///
        /// The shape a `PATCH` endpoint is. Written with `update` it costs a
        /// second `SELECT` — a round trip, and a read that may find what
        /// somebody else changed in between. `RETURNING` is one statement,
        /// and the column list is the one `select` already writes.
        ///
        /// A condition matching one row is the ordinary case and the answer
        /// is still a slice, because nothing in the statement says how many
        /// rows a condition matches. `changed[0]` after a length check is the
        /// single-row shape.
        pub fn updateReturning(self: *Self, comptime Row: type, c: anytype, options: anytype) ![]Row {
            comptime core.checkScope(@TypeOf(c), "db.updateReturning");
            const stmt = comptime statement.updateReturning(D, Row, @TypeOf(options));
            return fill(Row, stmt.reserve, self, null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
        }

        /// The same, for a `.where` that holds a key: the row as it now is, or
        /// null
        /// ([ADR 0179](../docs/adr/0179-a-statement-with-a-key-in-it-has-a-single-row-answer.md)).
        ///
        /// ```zig
        /// fn rename(db: *sql.Db, c: *nilo.Ctx, id: sql.Uuid, in: Rename) !?Partner {
        ///     return db.updateReturningOne(Partner, c, .{
        ///         .set = .{ .name = in.name },
        ///         .where = .{ .id = id },
        ///     });
        /// }
        /// ```
        ///
        /// **The condition is the caller's and this changes nothing about it.**
        /// The statement is the same `UPDATE … RETURNING`, sent unchanged, with
        /// the same rows coming back; what differs is that the answer is `?Row`
        /// rather than a slice the handler has to unwrap. Null is *no row
        /// matched*, which in a PATCH endpoint is the 404 the typed layer
        /// already writes for it (ADR 0024).
        ///
        /// A `.where` that matches several rows updates all of them and this
        /// hands back the first, exactly as `db.one` does for a condition on a
        /// column that is not unique. It is the shape of the call site rather
        /// than a promise about the statement.
        pub fn updateReturningOne(self: *Self, comptime Row: type, c: anytype, options: anytype) !?Row {
            comptime core.checkScope(@TypeOf(c), "db.updateReturningOne");
            const stmt = comptime statement.updateReturning(D, Row, @TypeOf(options));
            const changed = try fill(Row, stmt.reserve, self, null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
            return if (changed.len == 0) null else changed[0];
        }

        /// Delete every row matching `options`, and say how many there were.
        pub fn delete(self: *Self, comptime Row: type, c: anytype, options: anytype) !usize {
            comptime core.checkScope(@TypeOf(c), "db.delete");
            const stmt = comptime statement.delete(D, Row, @TypeOf(options));
            return self.execTold(null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
        }

        /// The same, answering with the rows that were removed.
        ///
        /// What a delete that has to report, log or undo what it took needs.
        /// Reading them first is two statements and a race: another writer can
        /// change a row between the `SELECT` and the `DELETE`, and what comes
        /// back then never existed.
        pub fn deleteReturning(self: *Self, comptime Row: type, c: anytype, options: anytype) ![]Row {
            comptime core.checkScope(@TypeOf(c), "db.deleteReturning");
            const stmt = comptime statement.deleteReturning(D, Row, @TypeOf(options));
            return fill(Row, stmt.reserve, self, null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
        }

        // -- transactions ----------------------------------------------------

        /// Begin a transaction, held and released the way every other
        /// resource in nilo is:
        ///
        /// ```zig
        /// var tx = try db.begin(c, .{});
        /// defer tx.deinit();       // rolls back unless committed
        /// _ = try tx.insert(Order, c, .{ … });
        /// try tx.commit();
        /// ```
        ///
        /// `opts` is `.{ .isolation = …, .read_only = … }` and both ride on
        /// the `BEGIN` itself, so asking for either costs no round trip. It
        /// is comptime and required — required because every other call in
        /// this module takes its options where they are used, and a second
        /// name for the same call with one argument more would be a worse
        /// answer than one `.{}`.
        ///
        /// The closure form — `db.transaction(c, run, args)`, impossible to
        /// get wrong — was rejected for being a second dialect: Zig has no
        /// closures, so it means a struct holding a function and every
        /// capture passed by hand, and `Stream`, `Socket` and `Body` are all
        /// *hold the thing, `defer` the cleanup* (ADR 0039).
        pub fn begin(self: *Self, c: anytype, comptime opts: wire_mod.Begin) !Tx {
            comptime core.checkScope(@TypeOf(c), "db.begin");
            const w = try self.wireOf();
            const inner = try w.begin(c.arena(), opts);
            if (traps_enabled) self.hold(&self.open_transactions, .Add);
            return .{ .db = self, .w = w, .inner = inner };
        }

        /// One transaction. Every call on it is the `Db` call of the same
        /// name, down the one connection this holds.
        pub const Tx = struct {
            db: *Self,
            w: *W,
            inner: W.Tx,
            finished: bool = false,
            /// The number the next savepoint gets. Counted up and never
            /// reused, so a savepoint taken inside a loop is a fresh mark
            /// each time around rather than one that shadows the last.
            sp_next: u32 = 0,
            /// The highest savepoint this transaction will still send SQL
            /// for. Undoing or dropping one destroys every savepoint taken
            /// after it — that is Postgres's rule, not a choice made here —
            /// so a handle above this line names a mark the server no longer
            /// has, and sending its `RELEASE` would abort the transaction
            /// with *no such savepoint*. It is a stale handle rather than a
            /// mistake, and `deinit` on one does nothing.
            sp_live: u32 = 0,

            /// Roll back unless something already committed. Written to be
            /// called from a `defer`, which is the only way it will be.
            pub fn deinit(self: *Tx) void {
                if (self.finished) return;
                self.inner.rollback();
                self.end();
            }

            pub fn commit(self: *Tx) !void {
                if (self.finished) return error.QueryFailed;
                try self.inner.commit();
                self.end();
            }

            /// Bound how long each statement after this one may run, until
            /// this transaction ends — `error.TimedOut` for one that goes
            /// past it ([ADR 0047](../docs/adr/0047-a-deadline-needs-a-connection-you-hold.md)).
            ///
            /// ```zig
            /// var tx = try db.begin(c, .{});
            /// defer tx.deinit();
            /// try tx.deadline(2_000);
            /// const rows = try tx.select(Report, c, .{ .where = … });
            /// ```
            ///
            /// **One round trip, and it is the only honest price.** There is
            /// no way to attach a deadline to a statement in the same message
            /// as the statement, so this is a `SET LOCAL` of its own — which
            /// is also why it lives here and not on `Db`. A `db.select`
            /// outside a transaction takes whichever connection is free and
            /// gives it straight back, so there is no *it* to set anything on.
            ///
            /// Postgres undoes a `SET LOCAL` at the end of the transaction
            /// however it ends, so the connection goes back to the pool
            /// carrying nothing — the rule the whole of `wire.zig` is built
            /// on.
            pub fn deadline(self: *Tx, ms: u32) !void {
                if (self.finished) return error.QueryFailed;
                return self.inner.deadline(ms);
            }

            /// Roll back now rather than on the way out, for a handler that
            /// has decided the answer is no.
            pub fn rollback(self: *Tx) void {
                if (self.finished) return;
                self.inner.rollback();
                self.end();
            }

            /// Put a mark inside this transaction that one part of it can be
            /// undone back to, without ending the whole thing.
            ///
            /// ```zig
            /// var sp = try tx.savepoint();
            /// defer sp.deinit();                 // undoes it, unless released
            /// if (tx.insert(Tag, c, .{ .name = name })) |_| {
            ///     try sp.release();
            /// } else |err| switch (err) {
            ///     error.AlreadyExists => sp.rollback(),   // it was there; carry on
            ///     else => return err,
            /// }
            /// ```
            ///
            /// **This is what a nested transaction is.** Postgres has no
            /// nested `BEGIN`, and every library that offers one is writing
            /// savepoints underneath; nilo writes them where they can be
            /// seen, because the two do not behave the same way — an inner
            /// commit here is not durable, it only means the outer
            /// transaction may still commit it.
            ///
            /// It earns its round trip on exactly one path, and it is the
            /// path that matters: **a statement that fails inside a
            /// transaction aborts all of it**, so a handler that wants to
            /// try something and carry on has no other way to do it.
            pub fn savepoint(self: *Tx) !Savepoint {
                if (self.finished) return error.QueryFailed;
                self.sp_next += 1;
                const id = self.sp_next;
                try self.inner.savepoint(self.arenaOf(), .mark, id);
                self.sp_live = id;
                return .{ .tx = self, .id = id };
            }

            /// The allocator a savepoint's statement is run with. It reads
            /// nothing and writes nothing, so there is nothing for it to
            /// allocate — but the Wire's shape takes one, and a Wire that
            /// wanted memory here would get the general allocator rather
            /// than a request arena this call does not have.
            fn arenaOf(self: *Tx) std.mem.Allocator {
                return self.db.gpa;
            }

            /// One mark inside a transaction, and the two ways out of it —
            /// the same trio `Tx` has, one level in: `deinit` undoes unless
            /// something kept it, `release` keeps, `rollback` undoes now.
            pub const Savepoint = struct {
                tx: *Tx,
                id: u32,
                finished: bool = false,

                /// Undo everything since the mark, unless it was released.
                /// Written to be called from a `defer`, which is the only
                /// way it will be.
                pub fn deinit(self: *Savepoint) void {
                    self.rollback();
                }

                /// Keep the work, and drop the mark. Fallible, the way
                /// `tx.commit` is and for the same reason: this is the path
                /// that is meant to succeed, so a caller wants to hear when
                /// it did not.
                pub fn release(self: *Savepoint) !void {
                    if (!self.live()) return error.QueryFailed;
                    self.end();
                    try self.tx.inner.savepoint(self.tx.arenaOf(), .keep, self.id);
                }

                /// Undo the work and carry on. Cannot fail, the way
                /// `tx.rollback` cannot: it is called on a path that is
                /// already handling something, and if the undo does not
                /// reach the server the next statement on this transaction
                /// will say so.
                pub fn rollback(self: *Savepoint) void {
                    if (!self.live()) return;
                    self.end();
                    self.tx.inner.savepoint(self.tx.arenaOf(), .undo, self.id) catch |err| {
                        std.log.err(
                            "nilo_sql: a savepoint could not be rolled back to ({s}). The " ++
                                "transaction around it is the one that will fail next.",
                            .{@errorName(err)},
                        );
                    };
                }

                /// Whether there is still a mark on the server this handle
                /// names. False once this handle has been used, and false
                /// when an outer savepoint or the transaction itself has
                /// already taken it — see `Tx.sp_live`.
                fn live(self: *Savepoint) bool {
                    if (self.finished) return false;
                    if (self.tx.finished) return false;
                    return self.id <= self.tx.sp_live;
                }

                /// Whichever way this handle was used, it is spent, and the
                /// server has dropped every mark taken after it. A
                /// `ROLLBACK TO` leaves the mark itself in place — but no
                /// handle names it any more, so nothing here will send SQL
                /// for it again.
                ///
                /// **There is no leak trap on a savepoint, unlike a
                /// transaction and a stream, and that is a decision.** Both
                /// of those count connections that never go back to the
                /// pool; an abandoned savepoint holds nothing at all — the
                /// `Tx` around it owns the connection and ends it either
                /// way. What abandoning one costs is that the work it marked
                /// is kept rather than undone, which is a bug in the
                /// handler's logic rather than a resource nobody can
                /// reclaim, and a Debug-only panic is the wrong shape for
                /// that.
                fn end(self: *Savepoint) void {
                    self.finished = true;
                    self.tx.sp_live = self.id - 1;
                }
            };

            fn end(self: *Tx) void {
                self.finished = true;
                if (traps_enabled) self.db.hold(&self.db.open_transactions, .Sub);
            }

            pub fn select(self: *Tx, comptime Row: type, c: anytype, options: anytype) ![]Row {
                comptime core.checkScope(@TypeOf(c), "tx.select");
                const stmt = comptime statement.select(D, Row, @TypeOf(options));
                return fill(Row, stmt.reserve, self.db, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
            }

            pub fn one(self: *Tx, comptime Row: type, c: anytype, options: anytype) !?Row {
                comptime core.checkScope(@TypeOf(c), "tx.one");
                const stmt = comptime statement.one(D, Row, @TypeOf(options));
                const found = try fill(Row, stmt.reserve, self.db, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
                return if (found.len == 0) null else found[0];
            }

            pub fn find(self: *Tx, comptime Row: type, c: anytype, key: anytype) !?Row {
                comptime core.checkScope(@TypeOf(c), "tx.find");
                const stmt = comptime statement.find(D, Row, @TypeOf(key));
                const found = try fill(Row, stmt.reserve, self.db, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, key, c));
                return if (found.len == 0) null else found[0];
            }

            pub fn count(self: *Tx, comptime Row: type, c: anytype, options: anytype) !usize {
                comptime core.checkScope(@TypeOf(c), "tx.count");
                const stmt = comptime statement.count(D, Row, @TypeOf(options));
                const n = try only(i64, self.db, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
                if (n < 0) return error.QueryFailed;
                return @intCast(n);
            }

            pub fn exists(self: *Tx, comptime Row: type, c: anytype, options: anytype) !bool {
                comptime core.checkScope(@TypeOf(c), "tx.exists");
                const stmt = comptime statement.exists(D, Row, @TypeOf(options));
                return only(bool, self.db, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
            }

            pub fn insert(self: *Tx, comptime Row: type, c: anytype, values: anytype) !Row {
                comptime core.checkScope(@TypeOf(c), "tx.insert");
                const stmt = comptime statement.insert(D, Row, @TypeOf(values));
                // `RETURNING` on a successful insert answers with exactly one
                // row, so the list is sized for one and never grows.
                const back = try fill(Row, 1, self.db, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, values, c));
                if (back.len == 0) return error.QueryFailed;
                return back[0];
            }

            pub fn insertMany(self: *Tx, comptime Row: type, c: anytype, rows: anytype) ![]Row {
                comptime core.checkScope(@TypeOf(c), "tx.insertMany");
                const V = comptime batchElement(Row, @TypeOf(rows));
                const stmt = comptime statement.insertMany(D, Row, V);
                const items: []const V = rows;
                return fill(
                    Row,
                    items.len,
                    self.db,
                    &self.inner,
                    c,
                    stmt.sql,
                    self.db.planOf(stmt),
                    try batchValuesOf(stmt, Row, V, items, c),
                );
            }

            pub fn updateMany(self: *Tx, comptime Row: type, c: anytype, rows: anytype) ![]Row {
                comptime core.checkScope(@TypeOf(c), "tx.updateMany");
                const V = comptime batchElement(Row, @TypeOf(rows));
                const stmt = comptime statement.updateMany(D, Row, V);
                const items: []const V = rows;
                return fill(
                    Row,
                    items.len,
                    self.db,
                    &self.inner,
                    c,
                    stmt.sql,
                    self.db.planOf(stmt),
                    try batchValuesOf(stmt, Row, V, items, c),
                );
            }

            /// A page of rows and the total behind it, inside the
            /// transaction (ADR 0185). The reason to want it here is the one
            /// the call exists for: a repeatable-read transaction is the other
            /// way to make a count and a page agree, and it costs a
            /// transaction where this costs a clause.
            pub fn page(self: *Tx, comptime Row: type, c: anytype, options: anytype) !Page(Row) {
                comptime core.checkScope(@TypeOf(c), "tx.page");
                const stmt = comptime statement.page(D, Row, @TypeOf(options));
                var total: i64 = 0;
                const rows = try filling(
                    Row,
                    stmt.reserve,
                    self.db,
                    &self.inner,
                    c,
                    stmt.sql,
                    self.db.planOf(stmt),
                    try valuesOf(stmt, Row, options, c),
                    &total,
                );
                return .{ .rows = rows, .total = total };
            }

            pub fn insertOrIgnore(
                self: *Tx,
                comptime Row: type,
                c: anytype,
                values: anytype,
                comptime on: anytype,
            ) !?Row {
                comptime core.checkScope(@TypeOf(c), "tx.insertOrIgnore");
                const stmt = comptime statement.insertOrIgnore(D, Row, @TypeOf(values), on);
                const back = try fill(Row, stmt.reserve, self.db, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, values, c));
                return if (back.len == 0) null else back[0];
            }

            pub fn insertOrUpdate(
                self: *Tx,
                comptime Row: type,
                c: anytype,
                values: anytype,
                comptime on: anytype,
            ) !Row {
                comptime core.checkScope(@TypeOf(c), "tx.insertOrUpdate");
                const stmt = comptime statement.insertOrUpdate(D, Row, @TypeOf(values), on);
                const back = try fill(Row, stmt.reserve, self.db, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, values, c));
                if (back.len == 0) return error.QueryFailed;
                return back[0];
            }

            pub fn update(self: *Tx, comptime Row: type, c: anytype, options: anytype) !usize {
                comptime core.checkScope(@TypeOf(c), "tx.update");
                const stmt = comptime statement.update(D, Row, @TypeOf(options));
                return self.db.execTold(&self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
            }

            pub fn updateReturning(self: *Tx, comptime Row: type, c: anytype, options: anytype) ![]Row {
                comptime core.checkScope(@TypeOf(c), "tx.updateReturning");
                const stmt = comptime statement.updateReturning(D, Row, @TypeOf(options));
                return fill(Row, stmt.reserve, self.db, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
            }

            /// `db.updateReturningOne` inside the transaction (ADR 0179).
            pub fn updateReturningOne(self: *Tx, comptime Row: type, c: anytype, options: anytype) !?Row {
                comptime core.checkScope(@TypeOf(c), "tx.updateReturningOne");
                const stmt = comptime statement.updateReturning(D, Row, @TypeOf(options));
                const changed = try fill(Row, stmt.reserve, self.db, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
                return if (changed.len == 0) null else changed[0];
            }

            pub fn delete(self: *Tx, comptime Row: type, c: anytype, options: anytype) !usize {
                comptime core.checkScope(@TypeOf(c), "tx.delete");
                const stmt = comptime statement.delete(D, Row, @TypeOf(options));
                return self.db.execTold(&self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
            }

            pub fn deleteReturning(self: *Tx, comptime Row: type, c: anytype, options: anytype) ![]Row {
                comptime core.checkScope(@TypeOf(c), "tx.deleteReturning");
                const stmt = comptime statement.deleteReturning(D, Row, @TypeOf(options));
                return fill(Row, stmt.reserve, self.db, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
            }

            /// `db.raw` inside the transaction, and the same call in every
            /// other way: comptime text, the `SELECT` list counted and named
            /// against the Row while compiling, and the statement kept
            /// prepared (ADR 0148). The type check is still the database's,
            /// through `db.checking`.
            pub fn raw(
                self: *Tx,
                comptime Row: type,
                c: anytype,
                comptime sql: []const u8,
                values: anytype,
            ) ![]Row {
                comptime core.checkScope(@TypeOf(c), "tx.raw");
                comptime rawcheck.assertList(D, Row, sql, "tx.raw");
                return fill(Row, null, self.db, &self.inner, c, sql, self.db.rawPlanOf(sql), try rawValuesOf(values, c));
            }

            /// `db.rawOne` inside the transaction: the first row of a statement
            /// this module did not write, or null (ADR 0179).
            pub fn rawOne(
                self: *Tx,
                comptime Row: type,
                c: anytype,
                comptime sql: []const u8,
                values: anytype,
            ) !?Row {
                comptime core.checkScope(@TypeOf(c), "tx.rawOne");
                comptime rawcheck.assertList(D, Row, sql, "tx.rawOne");
                const found = try fill(Row, null, self.db, &self.inner, c, sql, self.db.rawPlanOf(sql), try rawValuesOf(values, c));
                return if (found.len == 0) null else found[0];
            }

            /// `db.exec` inside the transaction: a statement that answers with
            /// nothing, and the rows it changed (ADR 0078).
            pub fn exec(self: *Tx, c: anytype, sql: []const u8, values: anytype) !usize {
                comptime core.checkScope(@TypeOf(c), "tx.exec");
                return self.db.execTold(&self.inner, c, sql, null, try rawValuesOf(values, c));
            }
        };

        /// What `db.page` answers with: the rows on this page, and how many
        /// the condition matched before the `.limit` cut it
        /// ([ADR 0185](../docs/adr/0185-a-page-knows-what-it-left-out.md)).
        ///
        /// A type of its own rather than an out-parameter, for the reason
        /// `db.one` is not `db.select`: the shape of the answer changed, and
        /// a caller that has to remember to read a second thing is a caller
        /// who will forget.
        ///
        /// The rows live in the request arena, like every other row. `total`
        /// is an `i64` because that is what `count(*)` is on both databases,
        /// and it is never negative.
        pub fn Page(comptime Row: type) type {
            return struct {
                /// What a nilo compile error calls this type (ADR 0122).
                pub const nilo_type_name = "nilo.sql.Page";

                rows: []Row,
                /// Every row the condition matched, `.limit` and `.offset`
                /// ignored. What a trimmed list needs to say *"20 of 47"*.
                total: i64,
            };
        }

        /// Rows pulled one at a time, each borrowed from the read buffer.
        pub fn Streamed(comptime Row: type) type {
            comptime row_mod.assertRow(Row);
            comptime assertStreamable(Row);
            return struct {
                db: *Self,
                w: *W,
                rows: W.Rows,
                /// Whether `close` has run.
                ///
                /// **A plain `bool` rather than a Debug-only one, and that is
                /// the fix rather than a tidying** (ADR 0117). This used to be
                /// `if (traps_enabled) bool else void`, so in ReleaseSafe the
                /// guard under it compiled away and the whole of `close` ran
                /// twice: on the Postgres Wire that is `result.deinit()` twice
                /// and `conn.release()` twice, which hands the pool a
                /// connection it is already holding.
                ///
                /// Reachable from the shape this API teaches. `rows.close()`
                /// early plus the `defer rows.close()` the doc comment on
                /// `stream` recommends is exactly two calls, and a `Streamed`
                /// is a value the handler holds, so two copies close twice as
                /// readily as one does. The SQLite Wire's own `Rows.closed` is
                /// an unconditional `bool` and never had it, which is what
                /// made this an oversight rather than a trade.
                ///
                /// The **counter** stays Debug-only, which is the part that
                /// was meant to be: `open_streams` watches a result set nobody
                /// closed, and paying for it in a release build would be a
                /// trap running where nothing reads it. What this costs
                /// instead is one byte on the stack of a handler that streams,
                /// and nothing at all to one that does not.
                closed: bool = false,

                const Rows = @This();

                /// The next row, or null at the end. **Everything read out
                /// of the row before this returns is invalid afterwards.**
                pub fn next(self: *Rows) !?row_mod.Borrowed(Row) {
                    if (!try self.w.next(&self.rows)) return null;
                    var out: row_mod.Borrowed(Row) = undefined;
                    inline for (comptime row_mod.columnsOf(Row), 0..) |column, i| {
                        const B = comptime row_mod.ColumnType(row_mod.Borrowed(Row), column);
                        @field(out, column) = try borrowColumn(self.w, &self.rows, B, i);
                    }
                    return out;
                }

                /// Give the connection back. Wanted on every path out,
                /// including the ones that stopped reading early.
                pub fn close(self: *Rows) void {
                    if (self.closed) return;
                    self.closed = true;
                    if (traps_enabled) self.db.hold(&self.db.open_streams, .Sub);
                    self.w.drain(&self.rows);
                }
            };
        }

        /// One column of a row that is **borrowed** rather than kept.
        ///
        /// The same shape as `readColumn` and deliberately not the same
        /// function: nothing is copied here, because the whole of what
        /// `stream` sells is that a million rows cost no allocation. Text
        /// stays pointing into the read buffer — which is why `Borrowed`
        /// calls it `[]const u8` and not `Str` — and a `Timestamp` or a
        /// `Uuid` is assembled from bytes that were going to be read anyway.
        fn borrowColumn(
            w: *W,
            rows: *const W.Rows,
            comptime B: type,
            comptime col: usize,
        ) !B {
            if (@typeInfo(B) == .optional) {
                const Inner = @typeInfo(B).optional.child;
                const on_wire = try w.read(rows, ?WireRead(Inner), col);
                return if (on_wire) |value| try borrowed(Inner, value) else null;
            }
            return borrowed(B, try w.read(rows, WireRead(B), col));
        }

        fn borrowed(comptime B: type, value: WireRead(B)) !B {
            if (B == types.Timestamp) return .{ .micros = value };
            if (B == types.Uuid) return uuidOf(value);
            // An enum costs no allocation to decode, so a streamed row is
            // held to the same standard as a kept one rather than being let
            // through to the driver's panic.
            if (@typeInfo(B) == .@"enum") return enumOf(B, value);
            // A `Decimal` column is `[]const u8` in a Borrowed row, so the
            // digits arrive as themselves and there is nothing to assemble —
            // `row.Borrowed` made the lifetime part of the type instead.
            return value;
        }

        // -- the shared middle -----------------------------------------------

        /// The pool, or the error a handler can act on. One place, so that
        /// "the server started but the database was never reachable" reads
        /// the same from every call.
        ///
        /// **A pool that was never opened is a different mistake from a
        /// database that went away**, and they used to be the same silent
        /// `error.Disconnected` (ADR 0079). The error is still the same value
        /// — a handler has nothing different to do — but the first one gets a
        /// line saying which of the two it is and how to fix it, once, because
        /// there is no way to reach here twice for that reason and have fixed
        /// it in between.
        fn wireOf(self: *Self) !*W {
            if (self.wire) |*w| return w;
            // A warning rather than an error, for the reason `listen()`'s
            // warning about `std_options_debug_io` is one: it is about the
            // shape of the program rather than about this request, and the
            // request already fails on its own. `std.log.err` would also
            // fail the test runner for every test that provokes it, which
            // is how a diagnostic ends up deleted rather than fixed.
            std.log.warn(
                "nilo_sql: {s} has no pool, so this query has nothing to run on. " ++
                    "The pool is opened by `nilo_start`, which `app.listen()` calls for every " ++
                    "provided service — outside a server, or before one, `app.start(io)` does " ++
                    "it, and `db.nilo_start(io, .off)` does it for a `Db` no App holds. " ++
                    "A `nilo.Run` is an arena and a lifetime; it is not a connection.",
                .{whoami},
            );
            return error.Disconnected;
        }

        /// Run a statement and fill a Row from each result. The one place
        /// the driver's borrowed text is copied into the arena, and the one
        /// place a transaction and a bare pool differ.
        /// Run a statement and fill a Row from each result.
        ///
        /// `reserve` is the ceiling on how many rows can arrive — a `LIMIT`
        /// that was written out, the one `db.one` compiles, or the length of
        /// the batch `insertMany` sent. When there is one the list is sized
        /// once and never grows; when there is not, it doubles, and each
        /// doubling abandons the buffer before it, because an arena cannot
        /// take one back.
        ///
        /// It is a runtime value rather than a comptime one **because of the
        /// batch**: every other caller knows its ceiling while compiling, and
        /// a batch knows it only when the slice arrives. What that costs is
        /// one branch per statement, against a doubling per 2ⁿ rows.
        ///
        /// A ceiling is not a count, and that distinction is the one ADR 0039
        /// originally got wrong: `.limit = 100` answering with 3 rows reserves
        /// room for 100 and fills 3. What is reserved and unused is
        /// `(ceiling - rows) * @sizeOf(Row)` bytes, and the `toOwnedSlice`
        /// below hands them back whenever the list is still the arena's last
        /// allocation — which it is for a Row of scalars, and is not for one
        /// with text in it, because each row's `dupe` lands after the list.
        /// The number the caller wrote is believed rather than second-guessed;
        /// a cap on it would be an unstated magic number.
        fn fill(
            comptime Row: type,
            reserve: ?usize,
            db: *Self,
            tx: ?*W.Tx,
            c: anytype,
            sql: []const u8,
            plan: ?[]const u8,
            values: anytype,
        ) ![]Row {
            return filling(Row, reserve, db, tx, c, sql, plan, values, null);
        }

        /// The same, with somewhere to put the column a page carries past its
        /// Row ([ADR 0185](../docs/adr/0185-a-page-knows-what-it-left-out.md)).
        ///
        /// **One extra `readColumn`, on the first row only**, because
        /// `count(*) OVER ()` is the same number on every row of the result —
        /// so a page costs one integer read rather than one per row, and a
        /// statement that matched nothing leaves the slot at the zero it was
        /// given.
        fn filling(
            comptime Row: type,
            reserve: ?usize,
            db: *Self,
            tx: ?*W.Tx,
            c: anytype,
            sql: []const u8,
            plan: ?[]const u8,
            values: anytype,
            total: ?*i64,
        ) ![]Row {
            comptime row_mod.assertRow(Row);
            const arena = c.arena();
            // The Db rather than the Wire, so that the one funnel every read
            // goes through is also the one place a watcher is told about it
            // (ADR 0137). Inside a transaction this is the same `*W` the `Tx`
            // is holding, because the `Tx` took it from here.
            const w = try db.wireOf();
            const started = db.timing();
            var problem: ?wire_mod.Problem = null;

            var rows = if (tx) |t|
                t.run(arena, sql, values, plan, &problem) catch |err| {
                    db.told(arena, started, sql, plan, null, true, problem);
                    return err;
                }
            else
                w.run(arena, sql, values, plan, &problem) catch |err| {
                    db.told(arena, started, sql, plan, null, true, problem);
                    return err;
                };
            // Whatever happens below, the connection goes back usable —
            // including a handler's own error on the way past (`wire.zig`).
            defer w.drain(&rows);

            var out: std.ArrayList(Row) = .empty;
            if (reserve) |ceiling| try out.ensureTotalCapacityPrecise(arena, ceiling);

            // The first row is pulled out of the loop so the width is asked
            // **once per statement** rather than once per row, and asked at
            // the first moment both drivers can answer it (ADR 0134).
            if (try w.next(&rows)) {
                wideEnough(Row, if (total == null) 0 else 1, w, &rows) catch |err| {
                    db.told(arena, started, sql, plan, null, true, null);
                    return err;
                };
                // Read once rather than per row: `count(*) OVER ()` is the
                // same number on every row of the result (ADR 0185).
                if (total) |slot| {
                    slot.* = readColumn(
                        w,
                        &rows,
                        i64,
                        comptime row_mod.columnsOf(Row).len,
                        c,
                    ) catch |err| {
                        db.told(arena, started, sql, plan, null, true, null);
                        return err;
                    };
                }
                while (true) {
                    var filled: Row = undefined;
                    inline for (comptime row_mod.columnsOf(Row), 0..) |column, i| {
                        const F = comptime row_mod.ColumnType(Row, column);
                        @field(filled, column) = readColumn(w, &rows, F, i, c) catch |err| {
                            db.told(arena, started, sql, plan, null, true, null);
                            return err;
                        };
                    }
                    try out.append(arena, filled);
                    if (!try w.next(&rows)) break;
                }
            }
            db.told(arena, started, sql, plan, out.items.len, false, null);
            return out.toOwnedSlice(arena);
        }

        /// Refuse a result set that has fewer columns than the Row reads by
        /// position.
        ///
        /// **`db.raw` gives up the compile-time column check and nothing
        /// else** — it does not give up being answerable (ADR 0134). A
        /// `SELECT` list shorter than the Row otherwise reaches
        /// `pg.Row.get`, which is `self.values[col]` with no bound on `col`:
        /// a panic in ReleaseSafe, taking the whole process down for one
        /// request's mistake, and undefined in ReleaseFast. That is the
        /// failure ADR 0008 says nilo cannot recover from, and this module
        /// already refuses two others of the same kind — `enumOf` and
        /// `arrayFits`.
        ///
        /// A list *longer* than the Row is not refused: reading the first N
        /// columns of a wider result is what `SELECT *` into a narrow Row
        /// means, and nothing about it is out of range.
        fn wideEnough(comptime Row: type, extra: usize, w: *W, rows: *const W.Rows) !void {
            const wanted = comptime row_mod.columnsOf(Row).len;
            const answered = w.width(rows);
            if (answered >= wanted + extra) return;
            std.log.warn(
                "nilo_sql: a statement answered with {d} column(s), and {s} reads {d} " ++
                    "by position. A `SELECT` list has to name at least the Row's columns, " ++
                    "in the Row's order.",
                .{ answered, @typeName(Row), wanted },
            );
            return error.QueryFailed;
        }

        /// Run a statement that answers with one row of one column, and read
        /// it. What `count` and `exists` are built on.
        ///
        /// There is no Row here and no filling: the answer is a number or a
        /// bool, and giving it a struct to live in is what `Tally` in
        /// `live.zig` had to do back when `db.raw` was the only way to ask.
        fn only(
            comptime T: type,
            db: *Self,
            tx: ?*W.Tx,
            c: anytype,
            sql: []const u8,
            plan: ?[]const u8,
            values: anytype,
        ) !T {
            const arena = c.arena();
            const w = try db.wireOf();
            const started = db.timing();
            var problem: ?wire_mod.Problem = null;

            var rows = if (tx) |t|
                t.run(arena, sql, values, plan, &problem) catch |err| {
                    db.told(arena, started, sql, plan, null, true, problem);
                    return err;
                }
            else
                w.run(arena, sql, values, plan, &problem) catch |err| {
                    db.told(arena, started, sql, plan, null, true, problem);
                    return err;
                };
            defer w.drain(&rows);

            // An aggregate answers with exactly one row. None would mean the
            // driver and Postgres disagree about what was sent, which is not
            // something to paper over with a zero.
            if (!try w.next(&rows)) {
                db.told(arena, started, sql, plan, null, true, null);
                return error.QueryFailed;
            }
            const answer = w.read(&rows, T, 0) catch |err| {
                db.told(arena, started, sql, plan, null, true, null);
                return err;
            };
            // One row, which is what an aggregate is — the count in it is the
            // answer rather than the number of rows, and a watcher reading
            // `rows` gets what a `SELECT` would have given it.
            db.told(arena, started, sql, plan, 1, false, null);
            return answer;
        }

        /// One column, with the borrow ended if there was one.
        ///
        /// The optional is stripped once, here, so that everything below
        /// answers one question about one type. Asking the Wire for the
        /// optional keeps the null check where the driver already does it.
        fn readColumn(
            w: *W,
            rows: *const W.Rows,
            comptime F: type,
            comptime col: usize,
            c: anytype,
        ) !F {
            // A list is asked for through a call of its own, because it is the
            // one column whose value cannot be pointed at — see `readList` in
            // `wire.zig`. It is also the one that arrives already copied, so
            // there is no borrow left for `kept` to end.
            if (comptime types.listElement(F) != null) return keptList(F, w, rows, col, c);
            if (@typeInfo(F) == .optional) {
                const Inner = @typeInfo(F).optional.child;
                const on_wire = try w.read(rows, ?WireRead(Inner), col);
                return if (on_wire) |value| try kept(Inner, value, c) else null;
            }
            return kept(F, try w.read(rows, WireRead(F), col), c);
        }

        /// The declared type, built out of what the Wire handed back — and
        /// **the one place a borrow ends**: every byte that came out of the
        /// driver's read buffer is copied into the request arena here, so
        /// what a handler holds lives exactly as long as the response it is
        /// going into.
        fn kept(comptime F: type, value: WireRead(F), c: anytype) !F {
            if (F == core.Str) return c.str(try c.arena().dupe(u8, value));
            if (F == []const u8) return try c.arena().dupe(u8, value);
            // Digits copied out of the read buffer, the same one call a text
            // column costs — so a `numeric` adds no class of allocation the
            // row was not already paying for.
            // A text column builds itself, and keeps whatever it keeps: the
            // bytes handed over are the read buffer's and die at the next row.
            if (comptime types.asText(F) != null) {
                return F.nilo_read(value, c.arena()) catch return error.QueryFailed;
            }
            // The same one copy a text column costs. What the Wire handed
            // back points into the driver's read buffer and dies at the next
            // row, so a `Bytes` that outlives the read is a `Bytes` that was
            // copied — there is no version of this that is free.
            if (F == types.Bytes) return .{ .bytes = try c.arena().dupe(u8, value.bytes) };
            if (F == types.Timestamp) return .{ .micros = value };
            if (F == types.Uuid) return uuidOf(value);
            if (comptime types.jsonPayload(F)) |Payload| {
                // The cost `types.zig` states: a Json column is parsed per
                // row, into the arena, and freed by the reset that ends the
                // request. This is `jsonPayload`'s one caller.
                return .{
                    .value = std.json.parseFromSliceLeaky(Payload, c.arena(), value, .{}) catch
                        return error.QueryFailed,
                };
            }
            // A tag rather than a view of the bytes it was named by, so
            // there is nothing here to copy either.
            if (@typeInfo(F) == .@"enum") return enumOf(F, value);
            // Everything else is a value rather than a view of a buffer, so
            // there is nothing to outlive.
            return value;
        }

        /// A list column, kept.
        ///
        /// The Wire is asked for the elements it can actually decode — which
        /// for text is `[]const u8`, the same substitution `WireRead` makes
        /// for a scalar `Str` — and hands back a slice that is already the
        /// arena's. When the Row asked for `Str` the slice is walked once more
        /// to attach the lifetime marker, and **that second walk is a second
        /// allocation per row**: one for the bytes and their slice, one for
        /// the `[]Str`. It is the price of `Str`'s trap on a list, it is paid
        /// only by a Row that asks for one, and a Row that reads the column as
        /// `[]const []const u8` pays a single allocation.
        ///
        /// A `Str` cannot be made below this layer at all: the marker comes
        /// from the Scope, and a Wire has none.
        ///
        /// A `Uuid` element takes the same second walk and for a different
        /// reason: the driver hands back the sixteen bytes and the sixteen
        /// bytes are not the type (ADR 0145). That walk allocates nothing
        /// extra beyond the `[]Uuid` itself, because a `Uuid` is a value
        /// rather than a view of a buffer.
        fn keptList(
            comptime F: type,
            w: *W,
            rows: *const W.Rows,
            comptime col: usize,
            c: anytype,
        ) !F {
            const optional = comptime @typeInfo(F) == .optional;
            const Slice = comptime if (optional) @typeInfo(F).optional.child else F;
            const Item = comptime @typeInfo(Slice).pointer.child;
            const OnWire = comptime WireList(F);

            const answered = try w.readList(rows, OnWire, col, c.arena());
            if (comptime OnWire == F) return answered;

            const bytes = if (comptime optional) (answered orelse return null) else answered;
            const out = try c.arena().alloc(Item, bytes.len);
            for (out, bytes) |*item, b| item.* = try keptElement(Item, b, c);
            return out;
        }

        /// Check every Row against the table it names, and log what does not
        /// line up. Returns how many problems there were.
        ///
        /// A scratch arena of its own rather than a request's: this runs at
        /// startup, where there is no request, and every byte of it is
        /// wanted only until the message is written.
        pub fn checkSchema(self: *Self, comptime Rows: []const type) !usize {
            var w = try self.wireOf();

            var scratch = std.heap.ArenaAllocator.init(self.gpa);
            defer scratch.deinit();
            const arena = scratch.allocator();

            var problems: std.ArrayList(schema.Problem) = .empty;
            inline for (Rows) |Row| {
                const q = comptime row_mod.qualifiedOf(Row);
                const actual = try w.columnsOf(arena, D.introspect, q.schema, q.table);
                _ = try schema.compare(D, Row, actual, &problems, arena);
            }

            for (problems.items) |problem| {
                var buf: [512]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&buf);
                problem.write(&writer) catch {};
                std.log.err("nilo_sql: {s}", .{writer.buffered()});
            }
            return problems.items.len;
        }

        /// The values a statement needs, in placeholder order, as the tuple
        /// the Wire wants. Every path was worked out while compiling; what
        /// happens here is reading the fields it names, and coercing each
        /// to the type its column actually is.
        ///
        /// The coercion is the point. `.{ .age = .{ .gt = 18 } }` writes a
        /// `comptime_int`, which has no size and nothing to put on a wire;
        /// what the database wants is whatever `age` was declared as. Doing
        /// it here also means a literal too big for its column stops at
        /// `zig build` rather than being truncated at run time.
        ///
        /// The column's type is used **whole**, optional included. An
        /// earlier version stripped the `?`, reasoning that a condition
        /// compares against a value — true for `.where`, and wrong for the
        /// half of this that writes: `.{ .handle = null }` is how a
        /// nullable column is set to NULL, and there is nothing to strip it
        /// to. `= null` in a condition never reaches here at all, because it
        /// compiled to `IS NULL`, which takes no parameter (`where.zig`).
        /// `c` is here for the one conversion that can need memory: a text
        /// column that builds its text rather than holding it (ADR 0055).
        /// Everything else is a copy, so the error set this infers is empty
        /// for a Row with no such column and the `try` costs nothing.
        fn valuesOf(
            comptime stmt: statement.Statement,
            comptime Row: type,
            options: anytype,
            c: anytype,
        ) !Values(D, Row, @TypeOf(options), stmt) {
            var out: Values(D, Row, @TypeOf(options), stmt) = undefined;
            inline for (stmt.paths, 0..) |path, i| {
                const param = comptime stmt.params[i];
                // The one parameter that is not one value: a list the Dialect
                // wants as JSON text rather than as an array (ADR 0119).
                if (comptime param.list and D.list_form == .json_each) {
                    const Item = comptime WireWrite(D, where_mod.ParamType(Row, param));
                    const value = where_mod.valueAt(options, path);
                    out[i] = try jsonList(Item, value, c);
                } else {
                    // `valueAtAs` and not `valueAt` for the values that have
                    // no type of their own — a literal, a `null`, an enum
                    // name. Read as themselves they make this a comptime
                    // call, which cannot then reach the runtime half of the
                    // same options struct (`where.valueAtAs`). Asked for as
                    // the column's type they are ordinary values, and the
                    // coercion is the one `forWire` was about to do anyway.
                    const Given = comptime where_mod.ValueAt(@TypeOf(options), path);
                    const Wanted = comptime if (where_mod.comptimeOnly(Given))
                        where_mod.ParamType(Row, param)
                    else
                        Given;
                    out[i] = try forWire(
                        @TypeOf(out[i]),
                        where_mod.valueAtAs(Wanted, options, path),
                        c,
                    );
                }
            }
            return out;
        }

        /// The values behind a statement **this module did not write**, in the
        /// same shapes a statement it did write would have sent
        /// ([ADR 0145](../docs/adr/0145-a-raw-parameter-is-converted-the-way-a-rows-is.md)).
        ///
        /// `db.raw` and `db.exec` have no Statement and no Row, so there was
        /// nothing to look a parameter's column up in and the tuple went to the
        /// driver untouched. That is fine for an `i64` and wrong for every type
        /// this module has a word for: a `Uuid` reached pg.zig as a Zig struct
        /// and came back `error.QueryFailed` at run time, and zqlite refused it
        /// while compiling. The workaround was to send thirty-six characters
        /// and write `$1::text::uuid`, which costs an arena allocation per id
        /// and twenty bytes on the wire.
        ///
        /// **No Row is needed, because `forWire` never wanted one.** It
        /// switches on the *value's* type and `WireWrite` takes a Dialect and a
        /// bare type — so the mapping a Row's parameter goes through is exactly
        /// the mapping available here, and the only thing missing was somebody
        /// calling it.
        ///
        /// **A call where nothing needs converting hands the caller's own
        /// tuple straight to the driver**, which is most calls and is what
        /// keeps this free. When something does, `RawWrite` says what each
        /// field becomes — including the ones that were only ever comptime,
        /// because a tuple the driver reads at run time cannot hold a
        /// `comptime_int`.
        fn rawValuesOf(values: anytype, c: anytype) !RawValues(D, @TypeOf(values)) {
            const V = @TypeOf(values);
            const Out = RawValues(D, V);
            if (comptime Out == V) return values;

            var out: Out = undefined;
            inline for (@typeInfo(V).@"struct".fields, 0..) |f, i| {
                out[i] = try forWire(@TypeOf(out[i]), @field(values, f.name), c);
            }
            return out;
        }

        /// The same tuple, filled the other way round: one field per column,
        /// each holding that column's value out of every row.
        ///
        /// A batch is the one statement whose parameters cannot be read
        /// straight out of the caller's struct, because the caller has a slice
        /// of structs and the wire wants a struct of slices. The transpose
        /// happens here, in the request arena, and is **one allocation per
        /// column** — the number of rows only decides how long each is.
        fn batchValuesOf(
            comptime stmt: statement.Statement,
            comptime Row: type,
            comptime V: type,
            items: []const V,
            c: anytype,
        ) !BatchValues(D, Row, stmt) {
            var out: BatchValues(D, Row, stmt) = undefined;
            inline for (stmt.params, 0..) |param, i| {
                const Column = comptime ArrayElement(D, row_mod.ColumnType(Row, param.column));
                const gathered = try c.arena().alloc(Column, items.len);
                // By pointer, because two of the conversions below hand back a
                // slice of the value rather than a copy of it — and what they
                // point at has to be the caller's row, which lives for the
                // whole call, rather than a loop variable that does not.
                for (items, gathered) |*item, *slot| {
                    slot.* = try forBatch(Column, &@field(item, param.column), c);
                }
                out[i] = gathered;
            }
            return out;
        }
    };
}

/// `?T`, unless it already is one. A column that may be null compared with a
/// value that may be null is one `?`, not two.
fn Maybe(comptime T: type) type {
    return comptime if (@typeInfo(T) == .optional) T else ?T;
}

/// The parameter tuple for a batch: one field per column, each a slice of
/// however many rows there are.
///
/// Not `Values` with `.list` set, though it is nearly that, and the difference
/// is `ArrayElement` — two column types travel differently in an array than they
/// do alone. Sharing the type would have meant a `WireWrite` that answered
/// differently depending on who was asking, which is worse than two functions.
fn BatchValues(comptime D: type, comptime Row: type, comptime stmt: statement.Statement) type {
    return comptime blk: {
        var fields: [stmt.params.len]type = undefined;
        for (stmt.params, 0..) |param, i| {
            fields[i] = []const ArrayElement(D, row_mod.ColumnType(Row, param.column));
        }
        const frozen = fields;
        break :blk std.meta.Tuple(&frozen);
    };
}

/// What a column binds as **inside an array parameter** — `WireWrite`, with
/// two differences, both of them forced by what the driver can encode an array
/// of.
///
/// - A `Uuid` binds as a slice of its bytes rather than as the array of them.
///   A single insert cannot do that: the tuple is all the driver has to read
///   from, and a slice would point at the copy `where.valueAt` just returned.
///   An array has somewhere better to point — the caller's own list, which is
///   alive for the whole call by definition. pg.zig has no encoder for an
///   array of `[16]u8` and does have one for `uuid[]` given a slice.
/// - A `Json(T)` binds as the document, written out here, because pg.zig
///   encodes a `jsonb[]` element from bytes and will not take a struct. **That
///   is one allocation per row for that column** — the same cost reading one
///   already has, and the only place a batch pays per row rather than per
///   column.
///
/// **Two callers, and the second is why it is not called `BatchWrite` any
/// more** (ADR 0145). A batch sends one array per column; an `.in` sends one
/// array of the values being matched. Both are `= ANY($1)`-shaped as far as
/// the driver is concerned, and both had a `Uuid` in them that did not
/// compile — the batch's was fixed when batches landed and the `.in`'s was
/// still `cannot bind value of type *const []const [16]u8`, from inside
/// pg.zig, on the operator that stops an N+1.
fn ArrayElement(comptime D: type, comptime F: type) type {
    comptime {
        if (F == types.Uuid) return []const u8;
        if (F == ?types.Uuid) return ?[]const u8;
        if (types.jsonPayload(F) != null) return []const u8;
        if (@typeInfo(F) == .optional and types.jsonPayload(@typeInfo(F).optional.child) != null) {
            return ?[]const u8;
        }
        return WireWrite(D, F);
    }
}

/// One value taken apart for a batch, given a pointer to where it lives in the
/// caller's row. `forWire` for everything the mapping above leaves alone.
///
/// The type it switches on is the *value's*, the way `forWire` does, and not
/// the column's: a `Str` column is written as a `[]const u8`, so a row struct's
/// field is whatever the caller wrote there.
fn forBatch(comptime To: type, value: anytype, c: anytype) !To {
    const V = @typeInfo(@TypeOf(value)).pointer.child;
    if (V == types.Uuid) return &value.bytes;
    if (V == ?types.Uuid) {
        if (value.* == null) return null;
        return &value.*.?.bytes;
    }
    if (comptime types.jsonPayload(V) != null) return jsonBytes(value.*, c);
    if (comptime @typeInfo(V) == .optional and
        types.jsonPayload(@typeInfo(V).optional.child) != null)
    {
        if (value.* == null) return null;
        return try jsonBytes(value.*.?, c);
    }
    return forWire(To, value.*, c);
}

/// A `Json(T)` written out, in the request arena. `std.json` finds the
/// `jsonStringify` on the wrapper and writes the `T` inside, which is the same
/// document a single insert hands the driver to write.
fn jsonBytes(value: anytype, c: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(c.arena(), value, .{}) catch error.QueryFailed;
}

/// The struct one row of a batch is written as, out of the slice it arrives
/// in. A `[]const V` and a `&[_]V{…}` are both what a caller has, so both are
/// taken; anything else is told what a batch looks like rather than left to
/// Zig's own message about a field that is not there.
fn batchElement(comptime Row: type, comptime R: type) type {
    comptime {
        switch (@typeInfo(R)) {
            .pointer => |p| switch (p.size) {
                .slice => if (p.child != u8) return p.child,
                .one => switch (@typeInfo(p.child)) {
                    .array => |a| return a.child,
                    else => {},
                },
                else => {},
            },
            else => {},
        }
        @compileError(
            "nilo: a batch insert into " ++ @typeName(Row) ++ " was given a " ++
                @typeName(R) ++ ".\n" ++
                "  It takes the rows as a slice: `[]const Line`, where `Line` is a " ++
                "struct naming the columns being written. One row is `db.insert`.",
        );
    }
}

/// Whether the Debug-only traps are compiled in. The same rule `Str`'s
/// staleness trap follows: a check that costs something is a check for the
/// mode people develop in (ADR 0004).
const traps_enabled = builtin.mode == .Debug;

/// The tuple type for a statement's parameters: one field per placeholder,
/// each the type of the column it is compared against.
///
/// `O` is the options struct the values are read out of, and it is here for
/// the parameters that belong to no column. A `LIMIT` used to bind as `i64`
/// on the reasoning that Postgres counts rows in a `bigint` — which is true
/// of the column and not of the caller. `.limit = per_page` with `per_page`
/// a `usize` is the shape everybody writes, and a `usize` does not coerce to
/// an `i64`, so it stopped with Zig's own message pointing inside this file
/// rather than with one of nilo's. Binding a count as whatever integer the
/// caller is holding costs nothing — the driver already narrows to the
/// column's width and says so when a value will not fit.
fn Values(
    comptime D: type,
    comptime Row: type,
    comptime O: type,
    comptime stmt: statement.Statement,
) type {
    return comptime blk: {
        var fields: [stmt.paths.len]type = undefined;
        for (stmt.params, 0..) |param, i| {
            if (param.isCount()) {
                fields[i] = where_mod.ValueAt(O, stmt.paths[i]);
                continue;
            }
            const F = WireWrite(D, where_mod.ParamType(Row, param));
            // `.in` is one placeholder holding many values — `= ANY($1)` —
            // so what binds is a list of the column's type rather than one
            // of them. `distinct_from` is the mirror: one value, which may be
            // null even on a column that may not, because the comparison is
            // null-safe and the statement says so either way (`where.zig`).
            //
            // **The element is `ArrayElement` rather than `WireWrite`, and a
            // `Uuid` is the whole reason** (ADR 0145). A scalar one binds as
            // `[16]u8`; `[]const [16]u8` is `cannot bind value of type` from
            // inside pg.zig, which is a dependency's compile error reaching a
            // reader who never chose the dependency. Inside an array it is the
            // sixteen bytes as a slice, pointing into the caller's own list.
            //
            // **Unless the Dialect reads its list out of JSON**, which is what
            // SQLite does: `json_each(?1)` takes one text parameter holding
            // the whole array, so the parameter is bytes rather than a list
            // (ADR 0119). `jsonList` is what fills it.
            fields[i] = if (param.list)
                (if (D.list_form == .json_each)
                    []const u8
                else
                    []const ArrayElement(D, where_mod.ParamType(Row, param)))
            else if (param.nullable) Maybe(F) else F;
        }
        const frozen = fields;
        break :blk std.meta.Tuple(&frozen);
    };
}

/// The tuple `db.raw` and `db.exec` actually send: the caller's own, with each
/// field mapped through `WireWrite` ([ADR 0145](../docs/adr/0145-a-raw-parameter-is-converted-the-way-a-rows-is.md)).
///
/// **It answers `V` itself when nothing needs converting**, which is most calls
/// and is what keeps this free: `rawValuesOf` then hands the caller's tuple
/// straight to the driver, the way it always did.
///
/// **It has to stay a tuple, and that is a fact about both drivers rather than
/// a preference.** pg.zig binds with `inline for (values)`, which takes a
/// tuple and nothing else; zqlite branches on `is_tuple` and binds a plain
/// struct's fields *by name*, so a rebuilt non-tuple would silently bind
/// nothing to `?1`. A named struct is therefore left exactly as it arrived,
/// which is what it was before this existed.
fn RawValues(comptime D: type, comptime V: type) type {
    comptime {
        const info = @typeInfo(V);
        // Not a struct at all: leave it to the driver, whose message is about
        // the shape of `values` rather than about any one field.
        if (info != .@"struct") return V;
        const given = info.@"struct".fields;

        if (!info.@"struct".is_tuple) {
            // A named struct is zqlite's `:name` binding and is left alone —
            // but a value nilo would have converted cannot be, because
            // rebuilding it as a tuple is what would go wrong quietly.
            for (given) |f| {
                if (WireWrite(D, f.type) != f.type) @compileError(
                    "nilo: `db.raw` was given `" ++ @typeName(f.type) ++ "` in a struct with " ++
                        "named fields, and nilo converts a parameter by position.\n" ++
                        "  Pass the values as a tuple — `.{ id, tag }` — which is what a " ++
                        "numbered placeholder binds against. A named struct binds by " ++
                        "`:name`, which only sqlite has and which this cannot convert into.",
                );
            }
            return V;
        }
        var fields: [given.len]type = undefined;
        var moved = false;
        for (given, 0..) |f, i| {
            fields[i] = RawWrite(D, f.type);
            if (fields[i] != f.type) moved = true;
        }
        if (!moved) return V;

        const frozen = fields;
        return std.meta.Tuple(&frozen);
    }
}

/// What one `db.raw` parameter travels as: `WireWrite`, plus the two things
/// only a hand-written call carries (ADR 0145).
///
/// - **A list written where it is used is `&.{ … }`**, a pointer to an array
///   rather than the slice a column is declared as, so `WireWrite` — which
///   answers about columns — does not see one at all. `= ANY($1)` is the whole
///   reason anybody writes a list here.
/// - **A value with no runtime representation cannot be a tuple field.**
///   `.{ 1, 1.5, null }` is three comptime fields, and the tuple this builds
///   is a value the driver reads from at run time. Each becomes the type both
///   drivers already bind the same way, which is why nothing about the bytes
///   changes: pg.zig's `.comptime_int` and `.int` arms are the same switch,
///   and its `.null` and `.optional`-holding-null arms write the same four
///   bytes whatever the column is.
///
/// An enum *literal* is the fourth of those and the one that gets better
/// rather than merely surviving: zqlite refuses one while compiling, and
/// `@tagName` is how both drivers send an enum anyway.
fn RawWrite(comptime D: type, comptime F: type) type {
    comptime {
        // Not through an optional: `?[]const T` is a shape `WireWrite` already
        // reads correctly, and unwrapping it here would drop the `?`.
        if (@typeInfo(F) != .optional) {
            if (givenElement(F)) |Item| return []const ArrayElement(D, Item);
        }
        const To = WireWrite(D, F);
        return switch (@typeInfo(To)) {
            .comptime_int => i64,
            .comptime_float => f64,
            // The type is never read: both drivers write a null without
            // consulting the column, so what matters is only that this is an
            // optional and that it fits in a tuple.
            .null => ?u8,
            .enum_literal => []const u8,
            else => To,
        };
    }
}

/// What the Wire is asked for when a column's declared type is not the shape
/// that travels on it. Everything here is a mapping to a type the driver
/// already knows, which is what keeps the driver's name inside
/// `sql/postgres.zig` where ADR 0039 put it — nothing above that file has to
/// know a wire format to make one of these.
///
/// - `Str` and `[]const u8` are bytes. The first is copied and renamed in
///   `kept`, the second only copied.
/// - `Timestamp` is an `i64`. Postgres counts a `timestamptz` from
///   2000-01-01 and the driver's own `i64` decoder already converts to the
///   epoch, so asking for the integer is asking for the field.
/// - `Uuid` is its sixteen bytes, in the order the column stores them.
/// - `Json(T)` is the bytes of the document. The driver hands back `jsonb`
///   with its version byte already off, so what arrives is text to parse.
/// - An **enum** is its tag name, and asking for the bytes rather than for
///   the enum is the whole of what stops the driver panicking on a value the
///   Zig type does not have — see `enumOf`. The bytes are identical either
///   way: pg.zig decodes an enum column by taking the text and calling
///   `std.meta.stringToEnum` on it, so this reads what it would have read and
///   makes the missing case an error instead of an unreachable.
fn WireRead(comptime F: type) type {
    comptime {
        // **Not `[]const u8`, and that is the point.** Text and bytes are the
        // same Zig type and two different columns, so a Wire handed
        // `[]const u8` cannot tell which read to make — and on SQLite the two
        // reads are `sqlite3_column_text` and `sqlite3_column_blob`, which are
        // not the same call. Keeping the type is what lets each Wire pick.
        if (F == types.Bytes) return types.Bytes;
        if (F == core.Str) return []const u8;
        if (F == types.Timestamp) return i64;
        if (F == types.Uuid) return []const u8;
        if (types.jsonPayload(F) != null) return []const u8;
        if (@typeInfo(F) == .@"enum") return []const u8;
        // A text column was asked for as `::text`, so what arrives is what
        // Postgres printed — the Dialect did the conversion in the SELECT
        // list rather than leaving a wire format for this layer to decode.
        // It is the whole of how a type this module has never heard of is
        // read at all (ADR 0055).
        if (types.asText(F) != null) return []const u8;
        return F;
    }
}

/// What the Wire is asked for when a column is a list: `WireRead`'s rule
/// applied to the element type. Two element types move and everything else a
/// Dialect will accept in an array is already a type the driver decodes into,
/// so for those this is `F` itself and `keptList` hands the slice straight
/// back.
///
/// **A `Uuid` element is `[]const u8` in both directions, and that is not the
/// scalar answer** ([ADR 0145](../docs/adr/0145-a-raw-parameter-is-converted-the-way-a-rows-is.md)).
/// A scalar `Uuid` binds on Postgres as `[16]u8` — the array rather than a
/// slice — because the parameter tuple is all the driver has to read from and
/// a slice would point at a copy `where.valueAt` just returned. An array
/// parameter has somewhere better to point: the caller's own list, which is
/// alive for the whole call. It also has no choice — pg.zig's `UUIDArray`
/// encoder reads `[]const u8` elements and takes either sixteen bytes or
/// thirty-six characters, and `[]const [16]u8` is `cannot bind value of type`
/// four frames inside the driver. `ArrayElement` reached the same answer for a
/// batch, for the same two reasons.
///
/// No Dialect is threaded in for it. A list column is Postgres-only — SQLite
/// has no array type, `dialect.acceptsSqlite` says so and `sqlite.readList` is
/// a Refusal — so there is no second answer for a parameter to choose between,
/// and the `.in` list on a Dialect that reads its lists out of JSON goes
/// through `jsonList` rather than through here.
fn WireList(comptime F: type) type {
    comptime {
        const optional = @typeInfo(F) == .optional;
        const Slice = if (optional) @typeInfo(F).optional.child else F;
        const Item = @typeInfo(Slice).pointer.child;
        const OnWire = switch (Item) {
            core.Str => []const u8,
            ?core.Str => ?[]const u8,
            types.Uuid => []const u8,
            ?types.Uuid => ?[]const u8,
            else => Item,
        };
        if (OnWire == Item) return F;
        return if (optional) ?[]const OnWire else []const OnWire;
    }
}

/// One element of a list column, built out of what the Wire handed back.
///
/// `kept`'s job for a scalar, and deliberately much smaller: the two element
/// types that move are the two `WireList` moves, and everything else arrives
/// as itself. A document or a text column inside an array is not here because
/// no Dialect will accept one — `dialect.listAccepts` declines both, so
/// `checking` refuses the column before a row is ever read.
fn keptElement(comptime Item: type, raw: anytype, c: anytype) !Item {
    if (comptime @typeInfo(Item) == .optional) {
        const Inner = comptime @typeInfo(Item).optional.child;
        return if (raw) |held| try keptElement(Inner, held, c) else null;
    }
    if (Item == core.Str) return c.str(raw);
    if (Item == types.Uuid) return uuidOf(raw);
    return raw;
}

/// A column's answer read as a `Uuid`, in either of the two shapes a database
/// stores one in (ADR 0078): **sixteen bytes**, which is what a Postgres
/// `uuid` is on the wire, or **thirty-six characters**, which is what a SQLite
/// TEXT column holds because SQLite has no uuid type.
///
/// No dialect is threaded in for this. The two lengths cannot be confused, and
/// the alternative — a Wire-specific reader — would make the same column read
/// two ways for no gain. Any other length is not a uuid, and saying so beats
/// reading past the end of the buffer or quietly keeping a prefix.
fn uuidOf(raw: []const u8) !types.Uuid {
    if (raw.len == types.Uuid.byte_len) return .{ .bytes = raw[0..types.Uuid.byte_len].* };
    if (raw.len == types.Uuid.text_len) return types.Uuid.parse(raw) catch error.QueryFailed;
    return error.QueryFailed;
}

/// A `Uuid` as the thirty-six characters SQLite stores, kept where the query
/// can read them. `arena` rather than a stack buffer: the tuple this feeds is
/// handed to the driver after this function has returned.
fn uuidText(value: types.Uuid, c: anytype) ![]const u8 {
    const text = value.toText();
    return c.arena().dupe(u8, &text) catch error.QueryFailed;
}

/// The tag whose name the column held, or a refusal naming the value.
///
/// **This is the one column type startup cannot check.** `dialect.accepts`
/// declines to judge an enum on purpose — a Postgres enum's type name lives
/// in the database and guessing it would fail honest schemas — so nothing
/// before the first read can tell that `Role` is missing a value the table
/// has. What stood behind it was the driver's own
/// `std.meta.stringToEnum(T, str).?`, which made a row added by an
/// `ALTER TYPE … ADD VALUE` take the whole process down: not this request,
/// every request, because Zig cannot recover from a panic (ADR 0008).
///
/// A 500 for the one request is the answer, and the value goes in the log
/// rather than to the client (ADR 0025) — it is the operator who has to go
/// and add the case, and `moderator` is the whole of what they need to know.
///
/// **`warn` rather than `err`, and the reason is not the level of the
/// problem.** The framework already logs the failed request; this is the
/// sentence that says why, so it sits at the level of the failure it
/// explains rather than announcing a second one. It also keeps the behaviour
/// testable: the test runner counts an `err` line as a failed run and
/// `std.testing.log_level` has nothing below `err` to turn down to, so a
/// module that logs `err` on a reachable path is a module whose path no test
/// can take (`http/test_root.zig`). `postgres.zig`'s `translate` logs `err`
/// for the case nothing else explains, which is the other half of the same
/// rule rather than an inconsistency with it.
fn enumOf(comptime E: type, raw: []const u8) !E {
    return std.meta.stringToEnum(E, raw) orelse {
        std.log.warn(
            "nilo_sql: a column held `{s}`, which is not a value of {s}. " ++
                "The database has a value the Zig enum does not.",
            .{ raw, @typeName(E) },
        );
        return error.QueryFailed;
    };
}

/// A Row is streamable unless it reads a column that costs an allocation.
///
/// A borrowed row costs none — that is the whole of what `stream` sells, and
/// it is what makes a million-row export run flat. Two column types cannot
/// keep to it, and they fail the same way rather than for two reasons:
///
/// - a `Json` column is parsed per row, into an arena that is not reset until
///   the request ends;
/// - a **list** column is built per row, because an array arrives as a run of
///   length-prefixed elements and there is no `[]T` in the read buffer to
///   point at (`wire.zig`).
///
/// Either would turn the one call with a bounded memory promise into the one
/// that grows without limit. Refusing is the honest answer; `select` reads
/// both, and the symmetry is what makes the rule one sentence — **a streamed
/// row holds only what the read buffer already holds.**
fn assertStreamable(comptime Row: type) void {
    comptime {
        for (@typeInfo(Row).@"struct".fields) |f| {
            const Inner = switch (@typeInfo(f.type)) {
                .optional => |o| o.child,
                else => f.type,
            };
            if (types.jsonPayload(Inner) != null) @compileError(
                "nilo: " ++ @typeName(Row) ++ " reads `" ++ f.name ++ "` as a Json column, " ++
                    "and a streamed row cannot hold one.\n" ++
                    "  A borrowed row allocates nothing, which is what makes a million of " ++
                    "them run flat, and parsing a document costs one allocation per row. " ++
                    "Read the column with `select`, or as `[]const u8` in a Row of its own " ++
                    "and parse it where it is needed.",
            );
            if (types.listElement(Inner) != null) @compileError(
                "nilo: " ++ @typeName(Row) ++ " reads `" ++ f.name ++ "` as a list column, " ++
                    "and a streamed row cannot hold one.\n" ++
                    "  A borrowed row allocates nothing, which is what makes a million of " ++
                    "them run flat, and an array has to be built per row — there is no " ++
                    "slice in the read buffer to point at. Read the column with `select`, " ++
                    "or leave it out of the Row being streamed.",
            );
        }
    }
}

/// A row lock is only a lock for as long as the transaction holding it lasts,
/// so a `.lock` outside one is refused rather than sent.
///
/// **What makes this worth a Refusal is that the wrong version works.**
/// `SELECT … FOR UPDATE` on a pooled connection with no transaction around it
/// runs, answers, and releases the lock before the handler has read the first
/// row — Postgres wraps a lone statement in a transaction of its own and ends
/// it immediately. Nothing fails, nothing is logged, and the read-modify-write
/// the lock was written to protect races anyway, under load, in production.
/// The statement is legal SQL; it is the promise that is missing, which is
/// exactly the kind of mistake a compiler can hold.
///
/// The same call inside a `Tx` is the intended one, and the message says so.
fn assertUnlocked(
    comptime Row: type,
    comptime O: type,
    comptime call: []const u8,
    comptime instead: []const u8,
) void {
    comptime {
        if (@typeInfo(O) != .@"struct") return;
        if (!@hasField(O, "lock")) return;
        @compileError(
            "nilo: `" ++ call ++ "` on " ++ @typeName(Row) ++ " was given a `.lock`, and " ++
                "there is no transaction to hold it.\n" ++
                "  A row lock lasts until the transaction around it ends, and this call " ++
                "has none — Postgres would take the lock, answer, and drop it before the " ++
                "handler read a row.\n" ++
                "  " ++ instead,
        );
    }
}

/// What a column's value binds as on the way *to* the database — the mirror
/// of `WireRead`, and the same mapping read the other way round.
///
/// A value going to the database has no lifetime question at all: it has to
/// survive the call and nothing more. So `Str` is not asked for here, and
/// requiring it would mean `.email = "a@b.c"` did not compile, which is the
/// shape everybody writes. `Str` is what text is when it comes *back*.
///
/// **A `Uuid` binds as whatever its Dialect stores one as** (ADR 0078), which
/// is the one place in this function the answer is not the same on both Wires.
///
/// On Postgres it is the sixteen bytes **as an array rather than a slice**, and
/// that is load-bearing: the tuple this builds is what the driver reads from,
/// so a slice would have to point at something, and the only thing available to
/// point at is the copy `where.valueAt` just returned. The array travels inside
/// the tuple and outlives the call, which a pointer into a temporary would not.
///
/// On SQLite it is the thirty-six characters, kept in the Scope's arena so they
/// outlive the call the same way. SQLite has no uuid type; the schema check has
/// always said TEXT for one (`dialect.acceptsSqlite`), and zqlite refuses to
/// bind a Zig array at all — so the array form was a `@compileError` from three
/// layers down naming a Zig issue, on the most ordinary column in a modern
/// schema.
///
/// A `Json(T)` is handed over whole. The driver writes any struct into a
/// `jsonb` column through `std.json`, which finds the `jsonStringify` on it
/// and writes the `T` inside rather than the wrapper.
fn WireWrite(comptime D: type, comptime F: type) type {
    comptime {
        // The write half of the same argument. Postgres binds the slice
        // inside and the Dialect casts it (`bindAs`); SQLite has to hand
        // zqlite its `Blob` wrapper, and only `sqlite.zig` may name that — so
        // what travels this far is nilo's own type and the Wire unwraps it.
        if (F == types.Bytes) return types.Bytes;
        if (F == ?types.Bytes) return ?types.Bytes;
        if (F == core.Str) return []const u8;
        if (F == ?core.Str) return ?[]const u8;
        if (F == types.Timestamp) return i64;
        if (F == ?types.Timestamp) return ?i64;
        if (F == types.Uuid) return switch (D.uuid_form) {
            .bytes => [types.Uuid.byte_len]u8,
            .text => []const u8,
        };
        if (F == ?types.Uuid) return switch (D.uuid_form) {
            .bytes => ?[types.Uuid.byte_len]u8,
            .text => ?[]const u8,
        };
        // The text, which the Dialect wrapped in a `::numeric`, `::interval`
        // or whatever the type named, where the placeholder goes.
        if (types.asText(F) != null) return if (@typeInfo(F) == .optional) ?[]const u8 else []const u8;
        // A list column binds as a list of what its elements bind as, which
        // for text is `[]const u8` for the same reason a scalar `Str` is not
        // asked for here. `.tags = &.{ "urgent", "billing" }` is the shape
        // everybody writes, and it coerces to this and not to `[]const Str`.
        if (types.listElement(F) != null) return WireList(F);
        // **A document and a tag, on a Dialect whose driver takes neither**
        // (ADR 0119). `WireRead` has always answered `[]const u8` for both, so
        // a Row carrying one read correctly and stopped compiling at the first
        // write — inside zqlite, four frames down, about a Zig type it has
        // never heard of. Which way each goes is the Dialect's to say, the
        // same arrangement `uuid_form` already makes.
        if (D.json_form == .text) {
            if (types.jsonPayload(F) != null) return []const u8;
            if (@typeInfo(F) == .optional and types.jsonPayload(@typeInfo(F).optional.child) != null) {
                return ?[]const u8;
            }
        }
        if (D.enum_form == .text) {
            if (@typeInfo(F) == .@"enum") return []const u8;
            if (@typeInfo(F) == .optional and @typeInfo(@typeInfo(F).optional.child) == .@"enum") {
                return ?[]const u8;
            }
        }
        return F;
    }
}

/// One value taken apart for the wire. Everything the driver already
/// understands is handed over unchanged and coerced by the assignment; the
/// two types carrying a column shape Zig has no word for are opened here,
/// which is the same conversion `kept` makes coming back.
fn forWire(comptime To: type, value: anytype, c: anytype) !To {
    const V = @TypeOf(value);
    // A `Str` is the text a request arrived with, and looking a row up by one
    // is the most ordinary thing anybody does with it: `.where = .{ .email =
    // form.email }`. It used to be a type error three layers down naming
    // `forWire`, so the guide's own sign-in snippet did not compile — which
    // is how the snippet check found it (ADR 0083). It lives exactly as long
    // as the statement does, so there is nothing to keep.
    if (V == core.Str) return value.view();
    if (V == ?core.Str) return if (value) |text| text.view() else null;
    if (V == types.Timestamp) return value.micros;
    if (V == ?types.Timestamp) return if (value) |t| t.micros else null;
    // Which of the two a `Uuid` becomes is `WireWrite`'s decision, made from
    // the Dialect; this reads it back off the type it was asked for, which is
    // how the conversion stays in one place (ADR 0078). The text is kept in the
    // arena because the tuple this fills is what the driver reads from, and a
    // pointer into this frame would not outlive the call.
    if (V == types.Uuid) return if (To == []const u8) try uuidText(value, c) else value.bytes;
    if (V == ?types.Uuid) {
        const held = value orelse return null;
        return if (To == ?[]const u8) try uuidText(held, c) else held.bytes;
    }
    // A **list** of them, which is the one list whose elements are not
    // themselves on the wire (ADR 0145). `WireList` says why the element is a
    // slice rather than the array a scalar binds as; this is where the slices
    // are made, and each one points into the caller's own list rather than at
    // a copy.
    if (comptime givenElement(V)) |Item| {
        if (comptime Item == types.Uuid or Item == ?types.Uuid) return uuidList(To, value, c);
        // And a list of `Str`, which is the same missing branch one type over
        // ([ADR 0156](../docs/adr/0156-a-list-of-str-is-a-parameter-too.md)).
        // A scalar `Str` has been handled at the top of this function since the
        // guide's own sign-in snippet failed to compile; a list of them fell
        // through to `return value;` and stopped as a type error naming a line
        // in this file, which reads like a bug in nilo rather than a spelling
        // at the call site. `docs/reference.md` had said `[]const Str` works
        // for two releases.
        if (comptime Item == core.Str or Item == ?core.Str) return strList(To, value, c);
    }
    // A text column writes itself. The arena is here for one that has to
    // build its text rather than hold it; the ones this module ships hold it
    // and never touch the allocator, which is why nothing extra is allocated
    // by a statement that does not carry such a column (ADR 0055).
    if (comptime types.asText(V) != null) {
        if (comptime @typeInfo(V) == .optional) {
            const Inner = comptime @typeInfo(V).optional.child;
            return if (value) |held| try Inner.nilo_write(held, c.arena()) else null;
        }
        return V.nilo_write(value, c.arena());
    }
    // A document and a tag, when the Dialect asked for them as text. Which of
    // the two `To` is was `WireWrite`'s decision, read back off the type here
    // — the same arrangement `Uuid` above makes, and the reason the Dialect is
    // not threaded into this function (ADR 0119).
    //
    // Keyed on `To` rather than on the Dialect, these also fire in one case
    // that has nothing to do with SQLite: a `Json(T)` or an enum *value*
    // written into a column whose own type is text, on either Wire. That used
    // to be a raw Zig type error from inside this function and is now the
    // document or the tag, which is the only thing it could reasonably mean.
    if (comptime types.jsonPayload(V) != null) {
        if (comptime To == []const u8) return jsonBytes(value, c);
    }
    if (comptime @typeInfo(V) == .optional and types.jsonPayload(@typeInfo(V).optional.child) != null) {
        if (comptime To == ?[]const u8) {
            const held = value orelse return null;
            return try jsonBytes(held, c);
        }
    }
    // `@tagName` rather than a copy: the name is a comptime constant in the
    // binary, so a tag costs no allocation on either Wire.
    if (comptime @typeInfo(V) == .@"enum") {
        if (comptime To == []const u8) return @tagName(value);
    }
    if (comptime @typeInfo(V) == .optional and @typeInfo(@typeInfo(V).optional.child) == .@"enum") {
        if (comptime To == ?[]const u8) return if (value) |tag| @tagName(tag) else null;
    }
    // A bare `.admin` written into a `db.exec`, which has no enum type behind
    // it and therefore no runtime representation at all (ADR 0145). The name
    // is what both drivers send for an enum anyway, and zqlite refused the
    // literal outright while compiling.
    if (comptime @typeInfo(V) == .enum_literal) {
        if (comptime To == []const u8) return @tagName(value);
    }
    return value;
}

/// The element type of a value that is a list, or null when it is not one.
///
/// `types.listElement` asks the same question about a *column*, and this asks
/// it about what somebody wrote at the call site — which is one shape wider,
/// because `&.{ a, b }` is a pointer to an array rather than a slice and is
/// what everybody writes. Text is not a list here for the reason it is not one
/// there: `[]const u8` was spoken for first.
fn givenElement(comptime V: type) ?type {
    return switch (@typeInfo(V)) {
        .optional => |o| givenElement(o.child),
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) null else p.child,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8) null else a.child,
                else => null,
            },
            else => null,
        },
        else => null,
    };
}

/// A list of `Uuid` as the list of slices the driver's array encoder reads
/// (ADR 0145).
///
/// **One allocation, for the slice headers, and none for the bytes.** Each
/// element points at the sixteen bytes sitting in the caller's own list, which
/// is alive for the whole call — the same thing `forBatch` does with a row of
/// a batch and for the same reason. Copying them would be a second allocation
/// for no gain.
fn uuidList(comptime To: type, value: anytype, c: anytype) !To {
    const given = if (comptime @typeInfo(@TypeOf(value)) == .optional)
        (value orelse return null)
    else
        value;

    const Slice = comptime if (@typeInfo(To) == .optional) @typeInfo(To).optional.child else To;
    const Element = comptime @typeInfo(Slice).pointer.child;

    // **Read off what the caller wrote rather than off the column**, and the
    // difference is not hypothetical: `.in` on a nullable column asks for
    // `[]const ?[]const u8` — the element carries the column's `?` — while the
    // list somebody writes at the call site is `&.{ a, b }` of plain ids. Both
    // shapes arrive here and only the first has a null to test for.
    const Given = comptime givenElement(@TypeOf(given)).?;

    const out = c.arena().alloc(Element, given.len) catch return error.QueryFailed;
    // By pointer, because what each slice points at has to be the caller's
    // list rather than a loop variable that stops existing.
    if (comptime @typeInfo(Given) == .optional) {
        for (given, out) |*item, *slot| {
            slot.* = if (item.* == null) null else &item.*.?.bytes;
        }
    } else {
        for (given, out) |*item, *slot| slot.* = &item.bytes;
    }
    return out;
}

/// A list of `Str` as the list of slices the driver's array encoder reads
/// ([ADR 0156](../docs/adr/0156-a-list-of-str-is-a-parameter-too.md)).
///
/// `uuidList` above with one line changed, and deliberately not merged with
/// it: what each does per element is the whole of it — sixteen bytes borrowed
/// there, a view taken here — and a shared version would be a comptime switch
/// wrapped in a function whose body is the switch.
///
/// **One allocation, for the slice headers, and none for the text.** A `Str`
/// is already text somebody else owns, and it outlives the statement by the
/// rule that made it a `Str` in the first place.
fn strList(comptime To: type, value: anytype, c: anytype) !To {
    const given = if (comptime @typeInfo(@TypeOf(value)) == .optional)
        (value orelse return null)
    else
        value;

    const Slice = comptime if (@typeInfo(To) == .optional) @typeInfo(To).optional.child else To;
    const Element = comptime @typeInfo(Slice).pointer.child;
    // Read off what the caller wrote, for the reason `uuidList` says: `.in` on
    // a nullable column asks for an element with the column's `?` on it, and
    // the list written at the call site has none.
    const Given = comptime givenElement(@TypeOf(given)).?;

    const out = c.arena().alloc(Element, given.len) catch return error.QueryFailed;
    if (comptime @typeInfo(Given) == .optional) {
        for (given, out) |item, *slot| slot.* = if (item) |text| text.view() else null;
    } else {
        for (given, out) |item, *slot| slot.* = item.view();
    }
    return out;
}

/// The list behind an `.in` or a `.not_in`, as the JSON array text
/// `json_each` reads (`dialect.ListForm.json_each`).
///
/// **This is the one allocation a statement makes on SQLite, and it is per
/// `.in` rather than per row.** `where.zig` has written
/// `"id" IN (SELECT value FROM json_each(?1))` since the second Dialect
/// landed and nothing anywhere turned the list into the text that statement
/// reads, so `.in` was a compile error from inside zqlite on the operator
/// every real schema uses (ADR 0119). Three documents said it worked.
///
/// The elements go through `forWire` first, so a list of `Str`, of `Uuid` or
/// of tags is written as what its column holds rather than as whatever Zig
/// struct the caller had. `F` is the element's *wire* type, which is what
/// makes that true — `Values` works it out from the Dialect.
fn jsonList(comptime F: type, values: anytype, c: anytype) ![]const u8 {
    const converted = c.arena().alloc(F, values.len) catch return error.QueryFailed;
    for (values, converted) |item, *slot| slot.* = try forWire(F, item, c);
    return std.json.Stringify.valueAlloc(c.arena(), converted, .{}) catch error.QueryFailed;
}

/// A connection URL with the password taken out, for the one log line that
/// prints one. `postgres://user:secret@host/db` has exactly one field worth
/// hiding and it is always in the same place.
fn redacted(url: []const u8) []const u8 {
    const at = std.mem.indexOfScalar(u8, url, '@') orelse return url;
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const colon = std.mem.indexOfScalarPos(u8, url, scheme_end + 3, ':') orelse return url;
    if (colon > at) return url;
    return url[0..colon];
}

/// Whether a failure to open a pool is about the URL or about the database.
///
/// **By name rather than by value, because the error set is the Wire's.** A
/// `switch` here would name errors a second Wire may not have, and this file
/// is generic over both. It costs a handful of string compares once, on a
/// path that is about to stop the server.
///
/// Getting this wrong is the whole reason it exists: the message that shipped
/// blamed the URL for every failure, so a database that was merely down sent
/// somebody to read a URL that was correct (ADR 0062).
fn isUrlProblem(err: anyerror) bool {
    const name = @errorName(err);
    for ([_][]const u8{
        // nilo's own, from `dialOpts`.
        "InvalidUriScheme",    "UnsupportedSSLModeValue", "UnsupportedConnectionParam",
        // `std.Uri.parse`, and the integer parse behind `tcp_user_timeout`.
        "UnexpectedCharacter", "InvalidFormat",           "InvalidPort",
        "InvalidCharacter",    "Overflow",
    }) |known| {
        if (std.mem.eql(u8, name, known)) return true;
    }
    return false;
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

test "a password never reaches the log" {
    try testing.expectEqualStrings(
        "postgres://app",
        redacted("postgres://app:hunter2@localhost:5432/shop"),
    );
    try testing.expectEqualStrings(
        "postgres://localhost:5432/shop",
        redacted("postgres://localhost:5432/shop"),
    );
}

/// A Db over the Fake: the whole of `db.zig` with no database behind it.
const FakeDb = DbOf(wire_mod.Fake, dialect.Postgres, "");

/// The same, named — a second service of the same shape, which is the whole
/// of what a read replica needs from this module (ADR 0060).
const FakeReplica = DbOf(wire_mod.Fake, dialect.Postgres, "replica");

const Person = struct {
    pub const nilo_table = .{ .name = "people", .key = .id };

    id: i64,
    email: nilo.Str,
    nickname: ?[]const u8,
    age: i32,
};

fn listPeople(db: *FakeDb, c: *nilo.Ctx) ![]Person {
    return db.select(Person, c, .{ .where = .{ .age = .{ .gt = 18 } } });
}

test "a handler's select runs the whole path, with no database anywhere" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    // As if `nilo_start` had run. What it would have built is a pool; what
    // is being tested here is everything after that.
    db.wire = .{ .answers = 2 };

    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/people", listPeople);

    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/people");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "[{\"id\":0,\"email\":\"fake\",\"nickname\":\"fake\",\"age\":0}," ++
            "{\"id\":0,\"email\":\"fake\",\"nickname\":\"fake\",\"age\":0}]",
        answer.body,
    );

    // The statement that reached the Wire is the constant the comptime half
    // produced — not something assembled on the way past.
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"nickname\", \"age\" FROM \"people\" WHERE \"age\" > $1",
        db.wire.?.last_sql,
    );
}

test "a select before the pool exists fails as an error, not as a crash" {
    // The framework logs a warning for any handler error, which is right and
    // is what this test provokes. Turned down around it so a passing run is
    // not painted red — `src/test_root.zig` explains why that happens.
    const was = std.testing.log_level;
    defer std.testing.log_level = was;
    std.testing.log_level = .err;

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();

    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/people", listPeople);

    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    // 500 rather than 503 on purpose: only `AlreadyExists` carries a
    // default answer (ADR 0039), so this arrives the way any uncaught
    // handler error does. What is being pinned here is that a Db whose
    // `nilo_start` never ran refuses in words instead of reading a null.
    const answer = try client.get(&app, "/people");
    try testing.expectEqual(@as(u16, 500), answer.status);
}

test "the parameter tuple is built from the paths the statement worked out" {
    const User = struct {
        pub const nilo_table = .{ .name = "users", .key = .id };

        id: i64,
        age: i32,
    };

    const options = .{ .where = .{ .age = .{ .gt = 18 } } };
    const stmt = comptime statement.select(dialect.Postgres, User, @TypeOf(options));

    // `18` is written as a `comptime_int` and has to reach the database as
    // whatever `age` is, or there is nothing to put on the wire.
    const Tuple = Values(dialect.Postgres, User, @TypeOf(options), stmt);
    try testing.expectEqual(@as(usize, 1), @typeInfo(Tuple).@"struct".fields.len);
    try testing.expectEqual(i32, @typeInfo(Tuple).@"struct".fields[0].type);
}

test "a nullable column keeps its optional, because a write may be null" {
    const User = struct {
        pub const nilo_table = .{ .name = "users", .key = .id };

        id: i64,
        nickname: ?[]const u8,
    };

    // Comparing: the `?` is harmless, a non-null optional binds the value.
    const found = .{ .where = .{ .nickname = "bo" } };
    const read = comptime statement.select(dialect.Postgres, User, @TypeOf(found));
    try testing.expectEqual(?[]const u8, @typeInfo(Values(dialect.Postgres, User, @TypeOf(found), read)).@"struct".fields[0].type);

    // Writing: the `?` is the whole point. `.nickname = null` is how a
    // column is set to NULL, and stripping it would leave nothing to write.
    const written = .{ .nickname = @as(?[]const u8, null) };
    const wrote = comptime statement.insert(dialect.Postgres, User, @TypeOf(written));
    try testing.expectEqual(?[]const u8, @typeInfo(Values(dialect.Postgres, User, @TypeOf(written), wrote)).@"struct".fields[0].type);
}

test "a limit held in a variable binds as a count, not as a column" {
    const User = struct {
        pub const nilo_table = .{ .name = "users", .key = .id };

        id: i64,
        age: i32,
    };

    var how_many: i64 = 10;
    _ = &how_many;
    const options = .{ .where = .{ .age = .{ .gt = 18 } }, .limit = how_many };
    const stmt = comptime statement.select(dialect.Postgres, User, @TypeOf(options));

    try testing.expectEqual(@as(usize, 2), stmt.paths.len);
    try testing.expectEqualStrings("age", stmt.params[0].column);
    try testing.expectEqualStrings(where_mod.Param.none, stmt.params[1].column);
}

test "a count binds as the integer the caller is holding, whatever it is" {
    const User = struct {
        pub const nilo_table = .{ .name = "users", .key = .id };

        id: i64,
        age: i32,
    };

    // A page size in a `usize` is the shape everybody writes, and binding
    // every count as `i64` meant this one stopped with Zig's own message
    // pointing inside this file rather than with one of nilo's.
    var per_page: usize = 20;
    _ = &per_page;
    const options = .{ .where = .{ .age = .{ .gt = 18 } }, .limit = per_page };
    const stmt = comptime statement.select(dialect.Postgres, User, @TypeOf(options));
    const fields = @typeInfo(Values(dialect.Postgres, User, @TypeOf(options), stmt)).@"struct".fields;

    try testing.expectEqual(@as(usize, 2), fields.len);
    // The condition still binds as its column's type, which is the half that
    // was always right.
    try testing.expectEqual(i32, fields[0].type);
    try testing.expectEqual(usize, fields[1].type);
}

test "the three types Zig has no word for are taken apart for the wire" {
    // Both directions of the same mapping, which is what makes a column
    // written by one call readable by the next.
    try testing.expectEqual(i64, WireRead(types.Timestamp));
    try testing.expectEqual(i64, WireWrite(dialect.Postgres, types.Timestamp));
    try testing.expectEqual([]const u8, WireRead(types.Uuid));
    try testing.expectEqual([types.Uuid.byte_len]u8, WireWrite(dialect.Postgres, types.Uuid));
    try testing.expectEqual([]const u8, WireRead(types.Json(struct { a: u8 })));

    // And a type the driver already understands is left alone.
    try testing.expectEqual(i32, WireRead(i32));
    try testing.expectEqual(i32, WireWrite(dialect.Postgres, i32));
}

test "a list of uuids travels as slices, because an array of them is not a shape the driver takes" {
    // Neither direction compiled before this (ADR 0145). Reading one stopped
    // in `forWire` with `expected type '…![]const [16]u8'`; writing one
    // stopped inside pg.zig with `cannot bind value of type
    // *const []const [16]u8` — a dependency's compile error reaching a reader
    // who never chose the dependency.
    try testing.expectEqual([]const []const u8, WireList([]const types.Uuid));
    try testing.expectEqual(?[]const []const u8, WireList(?[]const types.Uuid));
    // A list that may hold a NULL among its elements keeps the `?` on the
    // element, which is where Postgres keeps it too.
    try testing.expectEqual([]const ?[]const u8, WireList([]const ?types.Uuid));

    // The column, written: the same answer, because a Row's list column and
    // the Wire's list are the same array.
    try testing.expectEqual([]const []const u8, WireWrite(dialect.Postgres, []const types.Uuid));

    // And the other lists, which did not move.
    try testing.expectEqual([]const i32, WireList([]const i32));
    try testing.expectEqual([]const []const u8, WireList([]const core.Str));
}

test "a list of Str binds as slices, which is the branch the reference promised" {
    // `docs/reference.md` has said `[]const Str` is `text[]` since lists
    // landed. As a column both spellings worked; as a parameter only
    // `[]const []const u8` did, and the first fell through `forWire` to
    // `return value;` and stopped as a type error naming a line in this file
    // (ADR 0156). The type derivation was never the missing half — the test
    // above has asserted `WireList([]const core.Str)` all along.
    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();

    const wati = run.str("wati");
    const budi = run.str("budi");
    const given = [_]core.Str{ wati, budi };

    const bound = try forWire([]const []const u8, @as([]const core.Str, &given), &run);
    try testing.expectEqual(@as(usize, 2), bound.len);
    try testing.expectEqualStrings("wati", bound[0]);
    try testing.expectEqualStrings("budi", bound[1]);
    // Pointing at the caller's own text rather than at a copy of it, which is
    // what makes this one allocation for the headers and none for the bytes.
    try testing.expectEqual(wati.view().ptr, bound[0].ptr);

    // The optional list, absent.
    const none: ?[]const core.Str = null;
    try testing.expectEqual(
        @as(?[]const []const u8, null),
        try forWire(?[]const []const u8, none, &run),
    );

    // And a NULL among the elements, which is where the `?` sits on Postgres.
    const maybe = [_]?core.Str{ wati, null };
    const mixed = try forWire([]const ?[]const u8, @as([]const ?core.Str, &maybe), &run);
    try testing.expectEqualStrings("wati", mixed[0].?);
    try testing.expectEqual(@as(?[]const u8, null), mixed[1]);
}

test "an `in` over uuids is one parameter of slices rather than of arrays" {
    const Keyed = struct {
        pub const nilo_table = .{ .name = "keyed", .key = .id };

        id: types.Uuid,
        label: []const u8,
    };

    // `WHERE id = ANY($1::uuid[])` is what stops an N+1 on every list that
    // attaches children to its rows, and it is the call that did not compile.
    const options = .{ .where = .{ .id = .{ .in = &[_]types.Uuid{types.Uuid.nil} } } };
    const stmt = comptime statement.select(dialect.Postgres, Keyed, @TypeOf(options));
    const fields = @typeInfo(Values(dialect.Postgres, Keyed, @TypeOf(options), stmt)).@"struct".fields;

    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqual([]const []const u8, fields[0].type);

    // A scalar one is still the array, and that is not an inconsistency: the
    // tuple is all the driver has to read from, so a lone `Uuid` has nothing
    // to point at and a list points into the caller's own slice.
    const one = .{ .where = .{ .id = types.Uuid.nil } };
    const single = comptime statement.select(dialect.Postgres, Keyed, @TypeOf(one));
    try testing.expectEqual(
        [types.Uuid.byte_len]u8,
        @typeInfo(Values(dialect.Postgres, Keyed, @TypeOf(one), single)).@"struct".fields[0].type,
    );
}

test "a raw parameter is taken apart the way a Row's is" {
    // The defect: `db.raw` and `db.exec` have no Statement and no Row, so
    // their tuple went to the driver untouched — and pg.zig answered
    // `error.CannotBindStruct` at run time for the most ordinary key in a
    // modern schema, with nothing logged anywhere (ADR 0145). The type is what
    // is pinned here, because it is what the driver switches on.
    const bare = .{types.Uuid.nil};
    try testing.expectEqual(
        [types.Uuid.byte_len]u8,
        @typeInfo(RawValues(dialect.Postgres, @TypeOf(bare))).@"struct".fields[0].type,
    );
    // And the other Wire, which stores the thirty-six characters — the one
    // place the two disagree (ADR 0078), and it is the same disagreement
    // `WireWrite` already knew about.
    try testing.expectEqual(
        []const u8,
        @typeInfo(RawValues(dialect.SQLite, @TypeOf(bare))).@"struct".fields[0].type,
    );

    // A `Str` and a `Timestamp` are the same story, and both were the same
    // run-time refusal.
    const held = .{ types.Timestamp{ .micros = 1 }, types.Uuid.nil };
    const two = @typeInfo(RawValues(dialect.Postgres, @TypeOf(held))).@"struct".fields;
    try testing.expectEqual(i64, two[0].type);
    try testing.expectEqual([types.Uuid.byte_len]u8, two[1].type);
}

test "a raw tuple with nothing to convert is the caller's own, which is most of them" {
    // The whole of what this costs a call that did not need it: the tuple that
    // reaches the driver is the identical type it always was.
    const plain = .{ @as(i64, 7), "wati@example.dev" };
    try testing.expectEqual(@TypeOf(plain), RawValues(dialect.Postgres, @TypeOf(plain)));

    // A tuple with nothing in it, which is what every `CREATE TABLE` passes.
    try testing.expectEqual(@TypeOf(.{}), RawValues(dialect.Postgres, @TypeOf(.{})));

    // And a plain struct is left alone on purpose: zqlite binds one *by name*
    // rather than by position, so rebuilding it as a tuple would silently
    // bind nothing at all.
    const named = struct { a: i64 }{ .a = 1 };
    try testing.expectEqual(@TypeOf(named), RawValues(dialect.Postgres, @TypeOf(named)));
}

test "a literal beside a value that has to be converted still reaches the driver" {
    // The mixed tuple, which is the shape an ordinary `INSERT … VALUES ($1,$2)`
    // has: something nilo converts, and something written out. A `1` and a
    // `null` have no runtime representation at all, so the rebuilt tuple gives
    // each the type both drivers already bind the same way (ADR 0145).
    const mixed = .{ types.Uuid.nil, 42, 1.5, null, "cap" };
    const fields = @typeInfo(RawValues(dialect.Postgres, @TypeOf(mixed))).@"struct".fields;

    try testing.expectEqual([types.Uuid.byte_len]u8, fields[0].type);
    try testing.expectEqual(i64, fields[1].type);
    try testing.expectEqual(f64, fields[2].type);
    try testing.expectEqual(?u8, fields[3].type);
    try testing.expectEqual(*const [3:0]u8, fields[4].type);
}

test "a uuid column that is not sixteen bytes is refused rather than trimmed" {
    try testing.expectError(error.QueryFailed, uuidOf("short"));
    const ok = try uuidOf(&[_]u8{0xab} ** types.Uuid.byte_len);
    try testing.expectEqual(@as(u8, 0xab), ok.bytes[15]);
}

test "a borrowed row is the same row with its Strs told the truth" {
    const B = row_mod.Borrowed(Person);
    const fields = @typeInfo(B).@"struct".fields;

    try testing.expectEqual(@as(usize, 4), fields.len);
    // `email` was a Str and is now a plain slice; the numbers did not move.
    try testing.expectEqual(i64, fields[0].type);
    try testing.expectEqual([]const u8, fields[1].type);
    try testing.expectEqual(?[]const u8, fields[2].type);
    try testing.expectEqual(i32, fields[3].type);
}

/// A handler that opens a transaction and walks away from it. The `defer`
/// is the whole subject of the test below.
fn abandonTransaction(db: *FakeDb, c: *nilo.Ctx) !void {
    var tx = try db.begin(c, .{});
    defer tx.deinit();
    // and no commit
}

fn commitTransaction(db: *FakeDb, c: *nilo.Ctx) !void {
    var tx = try db.begin(c, .{});
    defer tx.deinit();
    try tx.commit();
}

/// One row of a batch, which is a named struct rather than a literal because
/// a slice of anonymous literals has no element type to name.
const Line = struct { email: []const u8, age: i32 };

/// One row of a batch update, which carries the key it is found by.
const Change = struct { id: i64, age: i32 };

/// Every call on `Db` and on `Tx`, in one handler.
///
/// A method on a generic struct is only analysed where it is called, so a
/// call that exists nowhere has never been compiled — which for this module
/// would mean whole statements nobody has type-checked. This route exists so
/// that all of them are, against the Fake, on every build.
fn touchEverything(db: *FakeDb, c: *nilo.Ctx) !void {
    _ = try db.select(Person, c, .{ .where = .{ .age = .{ .gte = 18 } } });
    _ = try db.one(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try db.find(Person, c, @as(i64, 1));
    _ = try db.insert(Person, c, .{ .email = "a@b.c", .age = @as(i32, 1) });
    _ = try db.insertMany(Person, c, &[_]Line{.{ .email = "a@b.c", .age = 1 }});
    _ = try db.updateMany(Person, c, &[_]Change{.{ .id = 1, .age = 2 }});
    _ = try db.update(Person, c, .{ .set = .{ .age = @as(i32, 2) }, .where = .{ .id = @as(i64, 1) } });
    _ = try db.updateReturning(Person, c, .{ .set = .{ .age = @as(i32, 2) }, .where = .{ .id = @as(i64, 1) } });
    _ = try db.delete(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try db.deleteReturning(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try db.raw(Person, c, "SELECT id, email, nickname, age FROM people", .{});

    // The condition shapes the guide shows and nothing else compiles.
    // `.nickname = null` is the literal, which is `IS NULL`; a `?[]const u8`
    // here is a Refusal, because whether that means `= $1` or `IS NULL`
    // would depend on a value that arrives after the statement is a constant
    // (`where.zig`, `assertNotOptional`).
    _ = try db.select(Person, c, .{ .where = .{
        .nickname = null,
        .id = .{ .ne = null },
        .email = .{ .like = "%@b.c", .not_like = "%+test@%" },
        .age = .{ .in = &[_]i32{ 1, 2, 3 }, .not_in = &[_]i32{ 9, 10 } },
        .any = .{ .{ .age = @as(i32, 1) }, .{ .age = @as(i32, 2) } },
    } });

    var offset: i64 = 5;
    _ = &offset;
    _ = try db.select(Person, c, .{ .order = .{ .id = .desc }, .limit = 10, .offset = offset });

    var rows = try db.stream(Person, c, .{});
    defer rows.close();
    while (try rows.next()) |_| {}

    var tx = try db.begin(c, .{});
    defer tx.deinit();
    _ = try tx.select(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try tx.one(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try tx.find(Person, c, @as(i64, 1));
    _ = try tx.count(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try tx.exists(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try tx.insert(Person, c, .{ .email = "a@b.c", .age = @as(i32, 1) });
    _ = try tx.insertMany(Person, c, &[_]Line{.{ .email = "a@b.c", .age = 1 }});
    _ = try tx.updateMany(Person, c, &[_]Change{.{ .id = 1, .age = 2 }});
    _ = try tx.update(Person, c, .{ .set = .{ .age = @as(i32, 3) }, .where = .{ .id = @as(i64, 1) } });
    _ = try tx.updateReturning(Person, c, .{ .set = .{ .age = @as(i32, 3) }, .where = .{ .id = @as(i64, 1) } });
    _ = try tx.delete(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try tx.deleteReturning(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try tx.raw(Person, c, "SELECT id, email, nickname, age FROM people", .{});

    // Every lock, and both ways out of a savepoint.
    _ = try tx.select(Person, c, .{ .where = .{ .id = @as(i64, 1) }, .lock = .update });
    _ = try tx.select(Person, c, .{ .where = .{ .id = @as(i64, 1) }, .lock = .update_nowait });
    _ = try tx.select(Person, c, .{ .where = .{ .id = @as(i64, 1) }, .lock = .update_skip_locked });
    _ = try tx.one(Person, c, .{ .where = .{ .id = @as(i64, 1) }, .lock = .share });

    var kept = try tx.savepoint();
    try kept.release();
    var undone = try tx.savepoint();
    undone.rollback();
    var deferred = try tx.savepoint();
    deferred.deinit();

    tx.rollback();
}

test "every call this module offers is compiled, and none of them is dead" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/everything", touchEverything);

    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/everything");
    try testing.expectEqual(@as(u16, 200), answer.status);
    if (traps_enabled) try testing.expectEqual(@as(usize, 0), db.open_transactions);
}

test "a transaction rolls back when nobody commits it" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{};

    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/abandon", abandonTransaction);

    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    _ = try client.get(&app, "/abandon");

    try testing.expectEqual(@as(usize, 1), db.wire.?.began);
    try testing.expectEqual(@as(usize, 0), db.wire.?.committed);
    try testing.expectEqual(@as(usize, 1), db.wire.?.rolled_back);
    // The trap's counter is back to zero, which is what `deinit` asserts.
    if (traps_enabled) try testing.expectEqual(@as(usize, 0), db.open_transactions);
}

/// A handler that nests three savepoints and then unwinds to the outermost,
/// which is the shape the bookkeeping in `Savepoint.live` exists for.
///
/// Undoing the outer one destroys the two inside it **on the server**, so a
/// `defer` on either that still sent SQL would be asking Postgres to release
/// a savepoint it no longer has — an error, inside a transaction, which
/// aborts the whole thing. The handles go stale rather than wrong.
fn nestSavepoints(db: *FakeDb, c: *nilo.Ctx) !void {
    var tx = try db.begin(c, .{});
    defer tx.deinit();

    var outer = try tx.savepoint();
    defer outer.deinit();
    var middle = try tx.savepoint();
    defer middle.deinit();
    var inner = try tx.savepoint();
    defer inner.deinit();

    outer.rollback();
}

test "undoing a savepoint leaves the ones inside it stale rather than wrong" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{};

    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/nest", nestSavepoints);

    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    const answer = try client.get(&app, "/nest");
    try testing.expectEqual(@as(u16, 200), answer.status);

    // Three marks went down, and exactly one undo came back — the two
    // `defer`s on the savepoints Postgres had already destroyed sent nothing.
    try testing.expectEqual(@as(usize, 3), db.wire.?.marked);
    try testing.expectEqual(@as(usize, 1), db.wire.?.undone);
    try testing.expectEqual(@as(usize, 0), db.wire.?.kept);
}

/// A handler that keeps the work a savepoint marked, and then takes another.
/// The second one has to be a fresh mark: reusing the number would name a
/// savepoint the server dropped with the release.
fn reuseSavepoint(db: *FakeDb, c: *nilo.Ctx) !void {
    var tx = try db.begin(c, .{});
    defer tx.deinit();

    var first = try tx.savepoint();
    try first.release();
    // Released once, and the second call does nothing rather than sending a
    // release for a mark that is gone.
    try testing.expectError(error.QueryFailed, first.release());

    var second = try tx.savepoint();
    defer second.deinit();
    try testing.expectEqual(@as(u32, 2), second.id);
}

test "a savepoint number is counted up and never reused" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{};

    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/reuse", reuseSavepoint);

    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    const answer = try client.get(&app, "/reuse");
    try testing.expectEqual(@as(u16, 200), answer.status);

    try testing.expectEqual(@as(usize, 2), db.wire.?.marked);
    try testing.expectEqual(@as(usize, 1), db.wire.?.kept);
    try testing.expectEqual(@as(usize, 1), db.wire.?.undone);
}

/// A handler that asks for a transaction nothing may be written in.
fn readOnlyTransaction(db: *FakeDb, c: *nilo.Ctx) !void {
    var tx = try db.begin(c, .{ .isolation = .serializable, .read_only = true });
    defer tx.deinit();
    _ = try tx.select(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
}

test "what a transaction is begun with travels down to the wire" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{};

    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/report", readOnlyTransaction);

    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    const answer = try client.get(&app, "/report");
    try testing.expectEqual(@as(u16, 200), answer.status);

    try testing.expectEqual(wire_mod.Isolation.serializable, db.wire.?.began_with.isolation.?);
    try testing.expect(db.wire.?.began_with.read_only);
}

/// A handler that opens a result set, closes it, and closes it again. The
/// second `close` is the subject: a `Streamed` is a value the handler holds,
/// so nothing stops one being closed twice, and a counter that went down
/// twice would underflow and take the process with it.
///
/// It is also the shape this API teaches — an early `close` on a path that
/// stops reading, plus the `defer rows.close()` on the line above it.
fn streamAndClose(db: *FakeDb, c: *nilo.Ctx) !void {
    var rows = try db.stream(Person, c, .{});
    if (traps_enabled) try testing.expectEqual(@as(usize, 1), db.open_streams);
    rows.close();
    rows.close();
}

test "a result set closed twice is drained once, in both optimize modes" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 2 };

    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/stream", streamAndClose);

    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    const answer = try client.get(&app, "/stream");
    try testing.expectEqual(@as(u16, 200), answer.status);

    // **The assertion that is not behind `traps_enabled`, and that is the
    // point** (ADR 0117). The guard used to be Debug-only, so this handler
    // drained twice in the mode people deploy in — on the Postgres Wire,
    // `result.deinit()` twice and `conn.release()` twice, handing the pool a
    // connection it was already holding.
    try testing.expectEqual(@as(usize, 1), db.wire.?.drains);

    // Zero rather than "not one": `deinit` panics on anything else, and the
    // trap exists because an abandoned result set holds a pool connection
    // for as long as the process runs — which is worse than the abandoned
    // transaction the counter beside it watches.
    if (traps_enabled) try testing.expectEqual(@as(usize, 0), db.open_streams);
}

test "a committed transaction is not rolled back on the way out" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{};

    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/commit", commitTransaction);

    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    _ = try client.get(&app, "/commit");

    try testing.expectEqual(@as(usize, 1), db.wire.?.committed);
    try testing.expectEqual(@as(usize, 0), db.wire.?.rolled_back);
    if (traps_enabled) try testing.expectEqual(@as(usize, 0), db.open_transactions);
}

test "Core is one module, so a Row's Str is the App's Str" {
    // Two modules built from the same root file are two different types to
    // Zig (ADR 0041). If `build.zig` ever hands this module a Core of its
    // own rather than the one the App was given, this is what notices —
    // before `kept` quietly stops recognising a `Str` column and leaves the
    // text pointing into a read buffer that is about to be reused.
    try testing.expect(core.Str == nilo.Str);
}

/// A Row of nothing but integers, so what a count measures is the list the
/// rows go into rather than the text inside them. Four `i64` is 32 bytes.
const Tick = struct {
    pub const nilo_table = .{ .name = "ticks", .key = .id };

    id: i64,
    at: i64,
    lo: i64,
    hi: i64,
};

/// How many times a `select` of `rows` rows reaches past the arena for more
/// memory. The arena is what the request holds; what is counted is the pages
/// underneath it, which is the sense ADR 0018 measures an allocation in.
fn allocationsFor(rows: usize, comptime options: anytype) !usize {
    return allocationsOf(Tick, rows, options);
}

fn allocationsOf(comptime Row: type, rows: usize, comptime options: anytype) !usize {
    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    var run = nilo.Run.init(counting.allocator());
    defer run.deinit();

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = rows };

    const found = try db.select(Row, &run, options);
    try testing.expectEqual(rows, found.len);
    return counting.allocations;
}

// The number ADR 0039 claims, held rather than asserted — the same job the
// budget test in `http/app.zig` does for the request path, which this module
// went without until the claim turned out to be false.
test "a select with a written-out limit reaches past the arena exactly once" {
    // One, at every size, because the ceiling is known before the first row
    // arrives and the list is built to it. It was 1, 5 and 9 at these three
    // sizes when the list doubled its way there, each doubling abandoning
    // the buffer before it — an arena cannot take one back.
    try testing.expectEqual(@as(usize, 1), try allocationsFor(10, .{ .limit = 10 }));
    try testing.expectEqual(@as(usize, 1), try allocationsFor(1_000, .{ .limit = 1_000 }));
    try testing.expectEqual(@as(usize, 1), try allocationsFor(100_000, .{ .limit = 100_000 }));

    // A ceiling is not a count. Fewer rows than the limit is still one
    // allocation — the reserved tail is what pays for that, and `fill` says
    // how much of it there is.
    try testing.expectEqual(@as(usize, 1), try allocationsFor(3, .{ .limit = 1_000 }));

    // And it holds for a Row carrying text, where every row allocates again
    // to copy its own bytes out of the read buffer.
    try testing.expectEqual(@as(usize, 1), try allocationsOf(Person, 1_000, .{ .limit = 1_000 }));
}

// The other half of the same claim, and the reason it is worth writing down:
// ADR 0039 only ever promised a number for the statement that says how many
// rows it can answer with. Without a limit there is nothing to build the list
// to, so it doubles — and this test exists so that the day somebody finds a
// way to do better, the number moves here rather than staying a surprise.
test "a select with no ceiling grows its list, and that is the cost of not saying" {
    try testing.expectEqual(@as(usize, 2), try allocationsFor(10, .{}));
    try testing.expectEqual(@as(usize, 3), try allocationsFor(100, .{}));
    try testing.expectEqual(@as(usize, 5), try allocationsFor(1_000, .{}));
    try testing.expectEqual(@as(usize, 9), try allocationsFor(100_000, .{}));
}

test "db.one asks the database for one row, not for every match" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    // The whole point: `age > $1` matches many rows and this statement asks
    // for one of them. Before, `one` called `select` and threw away the rest
    // after Postgres had sent them and the arena had copied them.
    _ = try db.one(Person, &run, .{ .where = .{ .age = .{ .gt = 18 } } });
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"nickname\", \"age\" FROM \"people\"" ++
            " WHERE \"age\" > $1 LIMIT 1",
        db.wire.?.last_sql,
    );

    // And the ceiling reaches `fill`, so the row it does read costs one
    // allocation rather than a list that grew into it.
    try testing.expectEqual(@as(usize, 1), try allocationsOf(Person, 1, .{ .limit = 1 }));
}

test "find compiles the condition the Row's key already described" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    var run = nilo.Run.init(counting.allocator());
    defer run.deinit();

    const found = try db.find(Person, &run, @as(i64, 7));
    try testing.expect(found != null);
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"nickname\", \"age\" FROM \"people\"" ++
            " WHERE \"id\" = $1 LIMIT 1",
        db.wire.?.last_sql,
    );

    // One row is a ceiling the statement states, so the list is built to it
    // rather than grown into it — one reach past the arena for the whole
    // call, `Person`'s two text columns copied out of the read buffer
    // included. The same number `db.one` holds, and for the same reason.
    try testing.expectEqual(@as(usize, 1), counting.allocations);
}

test "a condition takes the Str a request arrived with, not only its view" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    // `form.email` is a `Str`, and looking a row up by one is the first thing
    // anybody does with it. This was a type error from inside `forWire`, and
    // the guide's own sign-in snippet was written against the API it should
    // have had — found by compiling the snippet (ADR 0083).
    const email: nilo.Str = .static("wati@example.com");
    _ = try db.one(Person, &run, .{ .where = .{ .email = email } });
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"nickname\", \"age\" FROM \"people\"" ++
            " WHERE \"email\" = $1 LIMIT 1",
        db.wire.?.last_sql,
    );

    // And through the optional a nullable column takes. A condition refuses
    // one on purpose — `= NULL` is never true — so this is where it belongs.
    const maybe: ?nilo.Str = .static("wati");
    _ = try db.insert(Person, &run, .{ .email = email, .nickname = maybe, .age = @as(i32, 30) });
    try testing.expectEqualStrings(
        "INSERT INTO \"people\" (\"email\", \"nickname\", \"age\") VALUES ($1, $2, $3)" ++
            " RETURNING \"id\", \"email\", \"nickname\", \"age\"",
        db.wire.?.last_sql,
    );
}

test "an order survives the ceiling one puts on the end" {
    // `ORDER BY … LIMIT 1` is the newest row; `LIMIT 1` alone is whichever
    // row Postgres reached first. The clauses have to come out in that order
    // or the statement means something else.
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 0 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    const found = try db.one(Person, &run, .{ .order = .{ .age = .desc } });
    try testing.expectEqual(@as(?Person, null), found);
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"nickname\", \"age\" FROM \"people\"" ++
            " ORDER BY \"age\" DESC LIMIT 1",
        db.wire.?.last_sql,
    );
}

test "count and exists are one statement each, and neither invents a Row" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    // The Fake answers 0 for an integer, so what is asserted here is the
    // statement and the plumbing; `live.zig` is where the number is real.
    try testing.expectEqual(@as(usize, 0), try db.count(Person, &run, .{ .where = .{ .age = .{ .gt = 18 } } }));
    try testing.expectEqualStrings(
        "SELECT count(*) FROM \"people\" WHERE \"age\" > $1",
        db.wire.?.last_sql,
    );

    try testing.expectEqual(@as(usize, 0), try db.count(Person, &run, .{}));
    try testing.expectEqualStrings("SELECT count(*) FROM \"people\"", db.wire.?.last_sql);

    try testing.expectEqual(false, try db.exists(Person, &run, .{ .where = .{ .id = 7 } }));
    try testing.expectEqualStrings(
        "SELECT EXISTS(SELECT 1 FROM \"people\" WHERE \"id\" = $1)",
        db.wire.?.last_sql,
    );
}

test "a write that returns its rows sends one statement, not a write and a read" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    const changed = try db.updateReturning(Person, &run, .{
        .set = .{ .age = @as(i32, 31) },
        .where = .{ .id = @as(i64, 7) },
    });
    try testing.expectEqual(@as(usize, 1), changed.len);
    try testing.expectEqualStrings(
        "UPDATE \"people\" SET \"age\" = $1 WHERE \"id\" = $2" ++
            " RETURNING \"id\", \"email\", \"nickname\", \"age\"",
        db.wire.?.last_sql,
    );

    const gone = try db.deleteReturning(Person, &run, .{ .where = .{ .id = @as(i64, 7) } });
    try testing.expectEqual(@as(usize, 1), gone.len);
    try testing.expectEqualStrings(
        "DELETE FROM \"people\" WHERE \"id\" = $1" ++
            " RETURNING \"id\", \"email\", \"nickname\", \"age\"",
        db.wire.?.last_sql,
    );
}

test "a Run is a Scope, so a query needs no request around it" {
    // The half of ADR 0041 that is not tidying: everything this module ever
    // wanted from a `Ctx` was `arena()` and `str()`, so a program with no
    // server in it can hand over a `Run` instead and the same calls compile.
    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 2 };

    // No App, no request, no socket — and the rows come back filled, the
    // `Str` column included. That last part is the one worth asserting: it
    // is `kept` recognising the column and copying it into the Run's arena,
    // which is the same call it makes for a request.
    const found = try db.select(Person, &run, .{ .where = .{ .age = .{ .gt = 18 } } });
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("fake", found[0].email.view());

    // And it dies with the tick, exactly as it would with the request.
    if (core.trap_enabled) {
        const held = found[0].email;
        run.reset();
        try testing.expect(!held.alive());
    }
}

test "a literal beside a value the caller is holding still compiles" {
    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    // The most ordinary line anybody writes: a number written out in `.set`,
    // and an id that came from somewhere. Nothing about it is unusual, and
    // for a stage it did not compile — `31` has no type of its own, so
    // reading it made the whole read of `options` a comptime one, which then
    // could not reach `id`. The message named a parameter the caller never
    // wrote, three functions in.
    var id: i64 = 7;
    _ = &id;
    _ = try db.update(Person, &run, .{ .set = .{ .age = 31 }, .where = .{ .id = id } });
    try testing.expectEqualStrings(
        "UPDATE \"people\" SET \"age\" = $1 WHERE \"id\" = $2",
        db.wire.?.last_sql,
    );

    // The same shape on the way in, and the two other values that have no
    // type of their own: a `null` and an enum name are written the same way.
    _ = try db.insert(Person, &run, .{
        .email = "a@b.c",
        .age = 30,
        .nickname = null,
        .id = id,
    });
}

test "a deadline reaches the transaction, and only a transaction has one" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    var tx = try db.begin(&run, .{});
    defer tx.deinit();

    try testing.expectEqual(@as(?u32, null), db.wire.?.deadline_ms);
    try tx.deadline(2_000);
    try testing.expectEqual(@as(?u32, 2_000), db.wire.?.deadline_ms);

    // The other half of the design, asserted rather than described: `Db` has
    // no `deadline`, because a call that takes a connection and gives it
    // straight back has nothing to set one on (ADR 0047).
    try testing.expect(!@hasDecl(FakeDb, "deadline"));
}

test "a deadline on a finished transaction is refused rather than sent nowhere" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    var tx = try db.begin(&run, .{});
    defer tx.deinit();
    try tx.commit();

    // A `SET LOCAL` after `COMMIT` would either land on somebody else's
    // transaction or on nothing at all, and both are worse than an error.
    try testing.expectError(error.QueryFailed, tx.deadline(2_000));
    try testing.expectEqual(@as(?u32, null), db.wire.?.deadline_ms);
}

/// A Row with the one column type nothing checks at startup.
const Account = struct {
    pub const nilo_table = .{ .name = "accounts", .key = .id };

    id: i64,
    role: Role,

    const Role = enum { admin, member };
};

test "a column holding a value the Zig enum has is read as that value" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1, .text = "member" };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    const found = try db.select(Account, &run, .{});
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(Account.Role.member, found[0].role);
}

test "a column holding a value the Zig enum does not have is an error, not a panic" {
    // The log line names the value, which is the point of it — turned down
    // here so a passing run is not painted red.
    const was = std.testing.log_level;
    defer std.testing.log_level = was;
    std.testing.log_level = .err;

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    // What an `ALTER TYPE … ADD VALUE` looks like from this side: a value the
    // table has and `Role` does not. Before this was decoded here it was
    // `std.meta.stringToEnum(T, str).?` inside the driver, and it took the
    // process down rather than the request (ADR 0008).
    db.wire = .{ .answers = 1, .text = "moderator" };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    try testing.expectError(error.QueryFailed, db.select(Account, &run, .{}));
}

test "a streamed row holds an enum to the same standard as a kept one" {
    const was = std.testing.log_level;
    defer std.testing.log_level = was;
    std.testing.log_level = .err;

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1, .text = "moderator" };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    var rows = try db.stream(Account, &run, .{});
    defer rows.close();
    try testing.expectError(error.QueryFailed, rows.next());
}

test "a batch sends one statement, and it does not mention how many rows" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 2 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    const stored = try db.insertMany(Person, &run, &[_]Line{
        .{ .email = "a@b.c", .age = 1 },
        .{ .email = "d@e.f", .age = 2 },
    });
    try testing.expectEqual(@as(usize, 2), stored.len);
    try testing.expectEqualStrings(
        "INSERT INTO \"people\" (\"email\", \"age\")" ++
            " SELECT * FROM unnest($1::text[], $2::int4[])" ++
            " RETURNING \"id\", \"email\", \"nickname\", \"age\"",
        db.wire.?.last_sql,
    );
}

test "the batch tuple is a slice per column, not a value per row" {
    const stmt = comptime statement.insertMany(dialect.Postgres, Person, Line);
    const Tuple = BatchValues(dialect.Postgres, Person, stmt);
    const fields = @typeInfo(Tuple).@"struct".fields;

    // Two columns and any number of rows: the tuple's shape is the column
    // list, which is what makes the statement a constant.
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqual([]const []const u8, fields[0].type);
    try testing.expectEqual([]const i32, fields[1].type);
}

test "the two column types that travel differently in a batch say so" {
    // A `Uuid` alone is the array of its bytes, because a slice would point at
    // a temporary; in a batch it points at the caller's row, which lives for
    // the whole call — and pg.zig has no encoder for an array of `[16]u8`.
    try testing.expectEqual([types.Uuid.byte_len]u8, WireWrite(dialect.Postgres, types.Uuid));
    try testing.expectEqual([]const u8, ArrayElement(dialect.Postgres, types.Uuid));
    try testing.expectEqual(?[]const u8, ArrayElement(dialect.Postgres, ?types.Uuid));

    // A `Json(T)` is handed to the driver whole when it is alone and written
    // out here when it is in a batch, which is the one place a batch pays per
    // row rather than per column.
    const Settings = types.Json(struct { theme: []const u8 });
    try testing.expectEqual(Settings, WireWrite(dialect.Postgres, Settings));
    try testing.expectEqual([]const u8, ArrayElement(dialect.Postgres, Settings));
    try testing.expectEqual(?[]const u8, ArrayElement(dialect.Postgres, ?Settings));

    // Everything else is the same both ways.
    try testing.expectEqual(i64, ArrayElement(dialect.Postgres, i64));
    try testing.expectEqual(i64, ArrayElement(dialect.Postgres, types.Timestamp));
    try testing.expectEqual([]const u8, ArrayElement(dialect.Postgres, core.Str));
}

/// A Row with a list column of each kind: text, which has to be rebuilt as
/// `Str`, and a number, which the driver hands over as itself.
const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    tags: []const nilo.Str,
    scores: []const i32,
};

test "a list column comes back as a slice, and its text as Str" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1, .text = "urgent" };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    const found = try db.select(Ticket, &run, .{});
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(usize, 2), found[0].tags.len);
    try testing.expectEqualStrings("urgent", found[0].tags[0].view());
    try testing.expectEqualStrings("urgent", found[0].tags[1].view());
    try testing.expectEqual(@as(usize, 2), found[0].scores.len);
    try testing.expectEqual(@as(i32, 0), found[0].scores[0]);
}

test "a list column is selected as itself, with nothing wrapped round it" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    _ = try db.select(Ticket, &run, .{});
    try testing.expectEqualStrings(
        "SELECT \"id\", \"tags\", \"scores\" FROM \"tickets\"",
        db.wire.?.last_sql,
    );
}

test "a list column binds as a list of what the driver takes, not of Str" {
    // The mirror of the read: a value on the way out only has to survive the
    // call, so the shape everybody writes — a slice of literals — is the
    // shape the tuple wants.
    try testing.expectEqual([]const []const u8, WireWrite(dialect.Postgres, []const nilo.Str));
    try testing.expectEqual([]const ?[]const u8, WireWrite(dialect.Postgres, []const ?nilo.Str));
    try testing.expectEqual(?[]const []const u8, WireWrite(dialect.Postgres, ?[]const nilo.Str));
    // Everything the driver already decodes is left exactly alone, which is
    // what keeps `keptList` a single allocation for it.
    try testing.expectEqual([]const i32, WireWrite(dialect.Postgres, []const i32));
    try testing.expectEqual([]const i32, WireList([]const i32));
}

test "a list column that is null comes back as null rather than as no rows" {
    const Optional = struct {
        pub const nilo_table = .{ .name = "tickets", .key = .id };

        id: i64,
        tags: ?[]const nilo.Str,
    };

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1, .text = "urgent" };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    const found = try db.select(Optional, &run, .{});
    // The Fake answers every column, so what is pinned here is that the
    // optional survives the round trip as a type rather than being flattened.
    try testing.expectEqual(@as(usize, 2), found[0].tags.?.len);
}

test "the name a statement is prepared under is the one that reaches the wire" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    _ = try db.find(Person, &run, @as(i64, 7));
    // Not "some name": the one derived from the text that went down with it.
    // A `planOf` that hashed anything else — the Row, the call site — would
    // still be unique and would still be wrong, because the cache is keyed
    // by what Postgres parsed.
    try testing.expectEqualStrings(
        comptime statement.planName(
            "SELECT \"id\", \"email\", \"nickname\", \"age\" FROM \"people\"" ++
                " WHERE \"id\" = $1 LIMIT 1",
        ),
        db.wire.?.last_plan.?,
    );

    // And a different statement is a different name, down here rather than
    // only in the hash: two calls sharing one would make the second re-bind
    // against the first's describe.
    const first = db.wire.?.last_plan.?;
    _ = try db.count(Person, &run, .{});
    try testing.expect(!std.mem.eql(u8, first, db.wire.?.last_plan.?));
}

test "a statement this module did not write is prepared too, because its text is comptime" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    // `db.raw` used to be the one call that was never prepared, on the
    // reasoning that its text arrived at run time and a cache keyed on a
    // string built per request would grow with traffic (ADR 0057). Its text
    // is comptime now, so the name is derived the same way every other
    // statement's is and the set of them is still fixed when the binary is
    // built ([ADR 0148](../docs/adr/0148-a-raw-statement-is-counted-while-compiling.md)).
    _ = try db.raw(Person, &run, "SELECT * FROM people WHERE id = $1", .{@as(i64, 7)});
    const plan = db.wire.?.last_plan orelse return error.NoPlanName;
    try testing.expectEqualStrings(statement.planName("SELECT * FROM people WHERE id = $1"), plan);
}

test "a Db told to keep no plans keeps none for a raw statement either" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{ .prepared = false });
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    // The escape hatch for a pooler in transaction mode has to cover the
    // statement that only just started being prepared, or a caller behind
    // pgbouncer gets a "prepared statement does not exist" out of the one
    // call the option looked like it did not apply to.
    _ = try db.raw(Person, &run, "SELECT * FROM people", .{});
    try testing.expectEqual(@as(?[]const u8, null), db.wire.?.last_plan);
}

/// What the watcher below was told, and how often.
///
/// A file-scope variable because a `Watcher` is a plain function pointer with
/// nowhere to put a capture — which is the API's own argument
/// ([ADR 0137](../docs/adr/0137-a-statement-can-be-watched.md)), and testing it
/// means living with it.
var watched: struct {
    count: usize = 0,
    sql: []const u8 = "",
    plan: ?[]const u8 = null,
    rows: ?usize = null,
    failed: bool = false,
    micros: u64 = 0,
    problem: ?wire_mod.Problem = null,
} = .{};

fn recordSent(sent: Sent) void {
    watched.count += 1;
    watched.sql = sent.sql;
    watched.plan = sent.plan;
    watched.rows = sent.rows;
    watched.failed = sent.failed;
    watched.micros = sent.micros;
    watched.problem = sent.problem;
}

test "a watcher is told the statement, the plan and how many rows it moved" {
    watched = .{};

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 2 };
    db.watching(recordSent);

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    _ = try db.select(Person, &run, .{ .where = .{ .age = .{ .gt = 18 } } });

    try testing.expectEqual(@as(usize, 1), watched.count);
    // The constant the comptime half produced, which is the whole reason this
    // costs nothing to hand over: there is no text to assemble.
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"nickname\", \"age\" FROM \"people\" WHERE \"age\" > $1",
        watched.sql,
    );
    try testing.expect(watched.plan != null);
    try testing.expectEqual(@as(?usize, 2), watched.rows);
    try testing.expect(!watched.failed);
}

test "a statement that failed is reported as failed, with no row count to give" {
    const was = std.testing.log_level;
    defer std.testing.log_level = was;
    std.testing.log_level = .err;

    watched = .{};

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    // The short `SELECT` list of ADR 0134, which is a failure this module
    // raises itself rather than one the driver reports — so it also pins that
    // a refusal on the way past still reaches the watcher.
    //
    // **`SELECT *`, because a written-out short list no longer compiles**
    // (ADR 0148). That is not a weaker test: `*` is the shape the run-time
    // check still exists for, since how many columns it stands for is the
    // database's answer and no comptime pass can have it.
    db.wire = .{ .answers = 1, .columns_back = 2 };
    db.watching(recordSent);

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    try testing.expectError(error.QueryFailed, db.raw(Person, &run, "SELECT * FROM people", .{}));

    try testing.expectEqual(@as(usize, 1), watched.count);
    try testing.expect(watched.failed);
    try testing.expectEqual(@as(?usize, null), watched.rows);
    // And the name it was kept prepared under, which `db.raw` has had since
    // its text became comptime (ADR 0148).
    try testing.expect(watched.plan != null);
}

test "a statement that answers with a count reports the rows it changed" {
    watched = .{};

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 3 };
    db.watching(recordSent);

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    _ = try db.update(Person, &run, .{ .where = .{ .id = @as(i64, 7) }, .set = .{ .age = @as(i32, 31) } });

    try testing.expectEqual(@as(usize, 1), watched.count);
    try testing.expectEqual(@as(?usize, 3), watched.rows);
    try testing.expect(!watched.failed);
}

test "a statement that failed says what the database said, not only that it failed" {
    watched = .{};

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    // What Postgres actually answers a duplicate insert with, which used to
    // reach `std.log.err` and nowhere a program could read it (ADR 0146).
    db.wire = .{ .refuses = .{
        .message = "duplicate key value violates unique constraint \"people_email_key\"",
        .code = "23505",
        .severity = "ERROR",
        .detail = "Key (email)=(ada@example.dev) already exists.",
        .constraint = "people_email_key",
    } };
    db.watching(recordSent);

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    try testing.expectError(error.QueryFailed, db.select(Person, &run, .{}));

    try testing.expectEqual(@as(usize, 1), watched.count);
    try testing.expect(watched.failed);
    const said = watched.problem orelse return error.NoProblemReported;
    try testing.expectEqualStrings("23505", said.code);
    try testing.expectEqualStrings("ERROR", said.severity);
    try testing.expectEqualStrings("people_email_key", said.constraint);
    try testing.expect(std.mem.indexOf(u8, said.message, "unique constraint") != null);
}

test "a statement that answers with a count reports its failure the same way" {
    watched = .{};

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    // The other funnel: `execTold` rather than `fill`, which is the half a
    // test over `select` alone would not have covered.
    db.wire = .{ .refuses = .{ .message = "CannotBindStruct" } };
    db.watching(recordSent);

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    try testing.expectError(error.QueryFailed, db.exec(&run, "DELETE FROM people", .{}));

    try testing.expect(watched.failed);
    try testing.expectEqualStrings("CannotBindStruct", watched.problem.?.message);
    // Nothing invented where the driver had nothing to say: SQLite has no
    // SQLSTATE, and neither does a bind the driver refused.
    try testing.expectEqualStrings("", watched.problem.?.code);
}

test "a statement that worked carries no problem, which is what makes one mean something" {
    watched = .{};

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };
    db.watching(recordSent);

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    _ = try db.select(Person, &run, .{});
    try testing.expect(!watched.failed);
    try testing.expectEqual(@as(?wire_mod.Problem, null), watched.problem);
}

test "a Db nobody is watching tells nobody anything" {
    watched = .{};

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    _ = try db.select(Person, &run, .{});
    _ = try db.count(Person, &run, .{});

    // The default, and what every program written before this pays: one null
    // test per statement and no clock read at all.
    try testing.expectEqual(@as(usize, 0), watched.count);
}

test "a raw SELECT list shorter than the Row is refused, not read past the end" {
    // The refusal logs, which is the point of it. Turned down so a passing
    // run is not painted red — `src/test_root.zig` explains why.
    const was = std.testing.log_level;
    defer std.testing.log_level = was;
    std.testing.log_level = .err;

    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    // Two columns came back and `Person` reads four. Without the check the
    // third `read` is `values[2]` on an array of two, which pg.zig does not
    // bound: a panic in ReleaseSafe rather than an answer (ADR 0134).
    //
    // `SELECT *` is what a short list is written as now: counting the list
    // while compiling catches the written-out case before this ever runs
    // (ADR 0148), and `*` is the half no comptime pass can count.
    db.wire = .{ .answers = 1, .columns_back = 2 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    try testing.expectError(error.QueryFailed, db.raw(
        Person,
        &run,
        "SELECT * FROM people",
        .{},
    ));
}

test "a raw SELECT list wider than the Row is read, because the extra columns are nobody's" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1, .columns_back = 9 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    // `SELECT *` into a narrow Row is an ordinary thing to write and nothing
    // about it is out of range, so only the short list is refused.
    const found = try db.raw(Person, &run, "SELECT * FROM people", .{});
    try testing.expectEqual(@as(usize, 1), found.len);
}

test "a Db told to keep no plans sends none, whatever the statement is" {
    // The escape hatch for a pooler in transaction mode. It has to reach the
    // wire as an absent name rather than as a name the driver ignores,
    // because the driver is where the Parse would be skipped.
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{ .prepared = false });
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    _ = try db.find(Person, &run, @as(i64, 7));
    try testing.expectEqual(@as(?[]const u8, null), db.wire.?.last_plan);

    _ = try db.count(Person, &run, .{});
    try testing.expectEqual(@as(?[]const u8, null), db.wire.?.last_plan);
}

// -- a second database ----------------------------------------------------

/// A handler holding both. The signature is the routing: this one reads
/// from the replica and writes to the primary, and a reader can see that
/// without leaving the line.
fn readsOneWritesTheOther(db: *FakeDb, rdb: *FakeReplica, c: *nilo.Ctx) ![]Person {
    _ = try db.insert(Person, c, .{
        .id = @as(i64, 1),
        .email = "a@b.com",
        .nickname = @as(?[]const u8, null),
        .age = @as(i32, 30),
    });
    return rdb.select(Person, c, .{ .where = .{ .age = .{ .gt = 18 } } });
}

test "two databases are two types, so the registry holds both" {
    // The registry is keyed by type (ADR 0011), which is why one `*sql.Db`
    // was all a program could ask for. A name is what makes the second type
    // — and it has to be a name the struct *keeps*, because Zig memoises a
    // generic on the type it gives back and a parameter the body never
    // mentions gives back the same one twice.
    try testing.expect(FakeDb != FakeReplica);
    try testing.expect(sql_named_a != sql_named_b);
    try testing.expectEqualStrings("replica", FakeReplica.db_name);
    try testing.expectEqualStrings("", FakeDb.db_name);

    var primary = FakeDb.init(testing.allocator, "postgres://test/primary", .{});
    defer primary.deinit();
    primary.wire = .{ .answers = 1 };

    var replica = FakeReplica.init(testing.allocator, "postgres://test/replica", .{});
    defer replica.deinit();
    replica.wire = .{ .answers = 2 };

    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&primary);
    try app.provide(&replica);
    try app.get("/both", readsOneWritesTheOther);

    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    const answer = try client.get(&app, "/both");
    try testing.expectEqual(@as(u16, 200), answer.status);

    // Each statement went down its own Wire, which is the property the two
    // types buy: the write is on the primary and the read is not.
    try testing.expect(std.mem.startsWith(u8, primary.wire.?.last_sql, "INSERT INTO"));
    try testing.expect(std.mem.startsWith(u8, replica.wire.?.last_sql, "SELECT"));
}

const sql_named_a = DbOf(wire_mod.Fake, dialect.Postgres, "a");
const sql_named_b = DbOf(wire_mod.Fake, dialect.Postgres, "b");

test "a named database says which one it is when a connection is left behind" {
    // The name is not decoration: with two pools open, "a transaction was
    // begun and never ended" without saying *where* is a message that sends
    // somebody to read both. The trap panics, so what is asserted here is
    // the wording it would use.
    try testing.expectEqualStrings("the database", FakeDb.whoami);
    try testing.expectEqualStrings("`sql.Named(\"replica\")`", FakeReplica.whoami);
}

test "a bad URL and a database that is down get different sentences" {
    // Which of the two a startup failure is decides what somebody does next,
    // and the message that shipped said "the URL is the one thing checked
    // here" for both — so a database that was merely down sent people to
    // read a URL that was correct (ADR 0062).
    try testing.expect(isUrlProblem(error.InvalidUriScheme));
    try testing.expect(isUrlProblem(error.UnsupportedConnectionParam));
    try testing.expect(isUrlProblem(error.UnsupportedSSLModeValue));
    try testing.expect(isUrlProblem(error.InvalidPort));

    // The ones that mean the database, which are the ones the old message
    // was wrong about.
    try testing.expect(!isUrlProblem(error.ConnectionRefused));
    try testing.expect(!isUrlProblem(error.PG));
    try testing.expect(!isUrlProblem(error.OutOfMemory));
    try testing.expect(!isUrlProblem(error.Disconnected));
}

// -- the SQLite Wire, end to end -----------------------------------------
//
// Everything above this line runs against `wire.Fake`, which is the whole
// point of it: `db.zig` is the same code on both Wires and a fake proves that
// without a database. **The two things below could not be proved that way**,
// and both shipped broken because of it (ADR 0078) — a `Uuid` column did not
// compile against SQLite at all, and there was no call for a statement that
// answers with nothing. A real in-memory database is what a fake has no
// opinion about.

const sqlite_mod = @import("sqlite.zig");

/// `.in_fiber` because there is no Engine here to hop to — the same harness
/// `sqlite.zig`'s own tests use, under `std.Io.Threaded`.
const SqliteDb = DbOf(sqlite_mod.Wire(.{ .threading = .in_fiber }), dialect.SQLite, "");

const SqliteAccount = struct {
    pub const nilo_table = .{ .name = "accounts", .key = .id };

    id: i64,
    public: types.Uuid,
    email: nilo.Str,
};

const accounts_ddl =
    \\CREATE TABLE accounts (
    \\  id     INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    \\  public TEXT NOT NULL,
    \\  email  TEXT NOT NULL
    \\)
;

test "a Db answers the health page with SELECT 1, and says so before it has started" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:ready-probe?mode=memory&cache=shared",
        .{ .size = 1 },
    );
    defer db.deinit();

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();
    var scope = nilo.AnyScope.of(&run);

    // Before `listen()` there is no pool, and the page has to say so rather
    // than answer `ok` over nothing (ADR 0192).
    try testing.expectEqualStrings("not started: `listen()` has not run", db.nilo_ready(&scope).?);

    try db.nilo_start(threaded.io(), .off);
    try testing.expect(db.nilo_ready(&scope) == null);

    // And a Db that has been stopped is not ready again.
    db.nilo_stop();
    try testing.expect(db.nilo_ready(&scope) != null);
}

test "a uuid column is written and read back on the SQLite Wire" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:uuid-round-trip?mode=memory&cache=shared",
        .{ .size = 2 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();

    // `db.exec`, which is the call this used to need a Row for: nothing is
    // being selected, so there is no shape to describe.
    _ = try db.exec(&run, accounts_ddl, .{});

    const key = try types.Uuid.parse("01a01077-5ce8-7932-b42b-a05431a5c4c8");
    const made = try db.insert(SqliteAccount, &run, .{
        .public = key,
        .email = "wati@example.dev",
    });
    try testing.expectEqualSlices(u8, &key.bytes, &made.public.bytes);

    // Read back *by* the uuid, which is the half that proves the write and
    // the read agree about the column rather than merely being consistent
    // with each other.
    const found = (try db.one(SqliteAccount, &run, .{ .where = .{ .public = key } })).?;
    try testing.expectEqualSlices(u8, &key.bytes, &found.public.bytes);
    try testing.expectEqualStrings("wati@example.dev", found.email.view());

    // And it is stored as the thirty-six characters, which is what makes
    // `sqlite3` show the id and `WHERE public = '…'` typeable — the property
    // that decided the form.
    const Text = struct {
        pub const nilo_table = .{ .name = "accounts", .key = .id };
        id: i64,
        public: nilo.Str,
    };
    const as_text = try db.raw(Text, &run, "SELECT id, public FROM accounts", .{});
    try testing.expectEqual(@as(usize, 1), as_text.len);
    try testing.expectEqualStrings("01a01077-5ce8-7932-b42b-a05431a5c4c8", as_text[0].public.view());
}

test "a uuid bound bare to db.exec and db.raw reaches the database" {
    // The report this came from: `db.exec(c, "INSERT … VALUES ($1,$2)",
    // .{ partner_id, tag })` compiled and answered `error.QueryFailed` at run
    // time on Postgres, and did not compile at all here — zqlite refuses a Zig
    // struct while compiling. The workaround was thirty-six characters and
    // `$1::text::uuid`, which costs an arena allocation per id (ADR 0145).
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:raw-uuid?mode=memory&cache=shared",
        .{ .size = 2 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();
    _ = try db.exec(&run, accounts_ddl, .{});

    const key = try types.Uuid.parse("01a01077-5ce8-7932-b42b-a05431a5c4c8");

    // A `Uuid` and a literal in the same tuple, which is the ordinary shape:
    // the id needs converting and `42` has no runtime type at all.
    try testing.expectEqual(@as(usize, 1), try db.exec(
        &run,
        "INSERT INTO accounts (id, public, email) VALUES (?1, ?2, ?3)",
        .{ 42, key, "wati@example.dev" },
    ));

    // Read back *by* the id, so the write and the condition agree about what
    // the column holds rather than merely being consistent with each other.
    const Found = struct {
        pub const nilo_table = .{ .name = "accounts", .key = .id };
        id: i64,
        email: nilo.Str,
    };
    const found = try db.raw(
        Found,
        &run,
        "SELECT id, email FROM accounts WHERE public = ?1",
        .{key},
    );
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(i64, 42), found[0].id);
    try testing.expectEqualStrings("wati@example.dev", found[0].email.view());

    // And inside a transaction, which is the other pair of call sites.
    var tx = try db.begin(&run, .{});
    errdefer tx.rollback();
    _ = try tx.exec(&run, "DELETE FROM accounts WHERE public = ?1", .{key});
    _ = try tx.raw(Found, &run, "SELECT id, email FROM accounts WHERE public = ?1", .{key});
    try tx.commit();

    try testing.expectEqual(@as(usize, 0), try db.count(SqliteAccount, &run, .{}));
}

test "the schema check agrees with the wire about a uuid column" {
    // The two halves used to disagree: `accepts` routes a `Uuid` to TEXT
    // because it declares a column name, while the wire tried to send sixteen
    // raw bytes. This is the check that they now say the same thing.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:uuid-schema-check?mode=memory&cache=shared",
        .{ .size = 1 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();
    _ = try db.exec(&run, accounts_ddl, .{});

    try testing.expectEqual(@as(usize, 0), try db.checkSchema(&.{SqliteAccount}));
}

// -- every call, against the SQLite Wire ----------------------------------
//
// `touchEverything` above is the same idea against the Fake, and it is not
// enough: a method on a generic struct is analysed only where it is called,
// so `DbOf(sqlite.Wire, dialect.SQLite, …)`'s methods had **never been
// compiled at all**. `sql.Sqlite`'s only caller in the repository was
// `bench/sql.zig`, which reads a Row of `i64`, `Str` and `i32` and is not on
// `zig build test`; `sql/live.zig` is Postgres only; `sql/sqlite.zig` drives
// the Wire rather than `db.zig`.
//
// That is not one gap, it is the reason for three of them, and this is what
// found them (ADR 0119): a `Json` column, an enum column and `.in` were each
// a write path nothing had ever asked the compiler about, and each was a
// compile error four frames inside zqlite.

/// A tag, which SQLite has no type for and stores as its name.
const Grade = enum { bronze, silver, gold };

/// The payload of a document column.
const Prefs = struct { theme: []const u8, rows: u32 };

/// Every column type that binds as something other than itself, in one Row.
/// A list column is left out because SQLite has no array type at all, which
/// `dialect.acceptsSqlite` and `sqlite.readList` both say before this does.
const Everything = struct {
    pub const nilo_table = .{ .name = "everything", .key = .id };

    id: i64,
    email: nilo.Str,
    nickname: ?nilo.Str,
    age: i32,
    public: types.Uuid,
    made_at: types.Timestamp,
    prefs: types.Json(Prefs),
    grade: Grade,
};

/// The same table without the document, because a streamed row cannot hold
/// one — `assertStreamable` says so, and says why.
const Streamable = struct {
    pub const nilo_table = .{ .name = "everything", .key = .id };

    id: i64,
    email: nilo.Str,
    grade: Grade,
};

/// `made_at` is `INTEGER`, which is the column a `Timestamp` is actually bound
/// into: `WireWrite` answers `i64` whatever the Dialect is. It used to be
/// declared `TEXT` here to get past a startup check that judged it by its
/// Postgres name — the column that matched what was bound was the one being
/// refused, and the one that passed stored microseconds as digits
/// ([ADR 0136](../docs/adr/0136-a-timestamp-is-checked-against-the-column-it-is-bound-into.md)).
const everything_ddl =
    \\CREATE TABLE everything (
    \\  id       INTEGER PRIMARY KEY,
    \\  email    TEXT NOT NULL,
    \\  nickname TEXT,
    \\  age      INTEGER NOT NULL,
    \\  public   TEXT NOT NULL,
    \\  made_at  INTEGER NOT NULL,
    \\  prefs    TEXT NOT NULL,
    \\  grade    TEXT NOT NULL
    \\)
;

fn aRow(email: []const u8, age: i32, grade: Grade) struct {
    email: []const u8,
    nickname: ?[]const u8,
    age: i32,
    public: types.Uuid,
    made_at: types.Timestamp,
    prefs: types.Json(Prefs),
    grade: Grade,
} {
    return .{
        .email = email,
        .nickname = null,
        .age = age,
        .public = types.Uuid.nil,
        .made_at = .{ .micros = 1_700_000_000_000_000 },
        .prefs = .{ .value = .{ .theme = "dark", .rows = 25 } },
        .grade = grade,
    };
}

test "every call this module offers is compiled against the SQLite wire too" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:everything?mode=memory&cache=shared",
        .{ .size = 2 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();
    _ = try db.exec(&run, everything_ddl, .{});

    // The startup check agrees with all eight columns, which is the half that
    // was already true — every one of these reads correctly, and it is the
    // write half that had never been compiled.
    try testing.expectEqual(@as(usize, 0), try db.checkSchema(&.{Everything}));

    const key = try types.Uuid.parse("01a01077-5ce8-7932-b42b-a05431a5c4c8");
    var first = aRow("wati@example.dev", 30, .gold);
    first.public = key;
    const made = try db.insert(Everything, &run, first);
    try testing.expectEqualStrings("wati@example.dev", made.email.view());
    try testing.expectEqual(Grade.gold, made.grade);
    try testing.expectEqual(@as(u32, 25), made.prefs.value.rows);
    try testing.expectEqualSlices(u8, &key.bytes, &made.public.bytes);

    _ = try db.insert(Everything, &run, aRow("budi@example.dev", 20, .silver));

    // Every read, and each one names a column that binds as something else.
    _ = try db.select(Everything, &run, .{ .where = .{ .age = .{ .gte = @as(i32, 18) } } });
    _ = try db.one(Everything, &run, .{ .where = .{ .id = made.id } });
    _ = try db.find(Everything, &run, made.id);
    try testing.expectEqual(@as(usize, 2), try db.count(Everything, &run, .{}));
    try testing.expect(try db.exists(Everything, &run, .{ .where = .{ .grade = Grade.gold } }));
    _ = try db.raw(
        Everything,
        &run,
        "SELECT id, email, nickname, age, public, made_at, prefs, grade FROM everything",
        .{},
    );

    // Every write.
    _ = try db.update(Everything, &run, .{
        .set = .{ .age = @as(i32, 31), .grade = Grade.bronze, .prefs = types.Json(Prefs){
            .value = .{ .theme = "light", .rows = 50 },
        } },
        .where = .{ .id = made.id },
    });
    const back = (try db.find(Everything, &run, made.id)).?;
    try testing.expectEqual(Grade.bronze, back.grade);
    try testing.expectEqualStrings("light", back.prefs.value.theme);

    _ = try db.updateReturning(Everything, &run, .{
        .set = .{ .age = @as(i32, 32) },
        .where = .{ .id = made.id },
    });
    _ = try db.deleteReturning(Everything, &run, .{ .where = .{ .email = "nobody@example.dev" } });
    _ = try db.delete(Everything, &run, .{ .where = .{ .email = "nobody@example.dev" } });

    // A stream, on the Row that may be streamed.
    var rows = try db.stream(Streamable, &run, .{ .order = .{ .id = .asc } });
    defer rows.close();
    var seen: usize = 0;
    while (try rows.next()) |_| seen += 1;
    try testing.expectEqual(@as(usize, 2), seen);

    // And a transaction, with everything that is not a Refusal here. `.lock`,
    // `insertMany`, `updateMany` and `tx.deadline` are all compile errors on
    // this Dialect and stay that way — the seam refusing rather than lying
    // (ADR 0061).
    var tx = try db.begin(&run, .{});
    errdefer tx.rollback();
    _ = try tx.select(Everything, &run, .{ .where = .{ .id = made.id } });
    _ = try tx.one(Everything, &run, .{ .where = .{ .id = made.id } });
    _ = try tx.find(Everything, &run, made.id);
    _ = try tx.count(Everything, &run, .{});
    _ = try tx.exists(Everything, &run, .{});
    _ = try tx.insert(Everything, &run, aRow("tx@example.dev", 40, .bronze));
    _ = try tx.update(Everything, &run, .{
        .set = .{ .grade = Grade.silver },
        .where = .{ .id = made.id },
    });
    _ = try tx.updateReturning(Everything, &run, .{
        .set = .{ .grade = Grade.gold },
        .where = .{ .id = made.id },
    });
    _ = try tx.deleteReturning(Everything, &run, .{ .where = .{ .email = "tx@example.dev" } });
    _ = try tx.delete(Everything, &run, .{ .where = .{ .email = "gone@example.dev" } });
    _ = try tx.raw(Everything, &run, "SELECT id, email, nickname, age, public, made_at, prefs, grade FROM everything", .{});
    _ = try tx.exec(&run, "DELETE FROM everything WHERE email = 'never@example.dev'", .{});

    var kept = try tx.savepoint();
    try kept.release();
    var undone = try tx.savepoint();
    undone.rollback();
    try tx.commit();
}

test "an `in` on SQLite is the JSON array json_each reads, and it matches" {
    // **`.in` and `.not_in` did not compile here at all**, and three documents
    // said they did: `dialect.zig`'s header, ADR 0061, and the guide's table
    // of what SQLite will not do, which does not list them. `where.zig` writes
    // `"age" IN (SELECT value FROM json_each(?1))` for `list_form = .json_each`
    // and nothing anywhere turned the list into the text that statement reads,
    // so `WireWrite` handed zqlite a `[]const i64` and zqlite refused to
    // compile (ADR 0119).
    //
    // It survived because the only tests were over the SQL *text*, `live.zig`
    // has no SQLite arm, and no example or benchmark binds one.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:in-list?mode=memory&cache=shared",
        .{ .size = 2 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();
    _ = try db.exec(&run, everything_ddl, .{});

    const key = try types.Uuid.parse("01a01077-5ce8-7932-b42b-a05431a5c4c8");
    var one = aRow("wati@example.dev", 30, .gold);
    one.public = key;
    _ = try db.insert(Everything, &run, one);
    _ = try db.insert(Everything, &run, aRow("budi@example.dev", 20, .silver));
    _ = try db.insert(Everything, &run, aRow("sari@example.dev", 44, .bronze));

    // A number, which is the case the compile error was on.
    const twenties = try db.select(Everything, &run, .{
        .where = .{ .age = .{ .in = &[_]i32{ 20, 30 } } },
    });
    try testing.expectEqual(@as(usize, 2), twenties.len);

    // And the mirror, so the JSON is not merely accepted but read: three rows
    // less the two above.
    const rest = try db.select(Everything, &run, .{
        .where = .{ .age = .{ .not_in = &[_]i32{ 20, 30 } } },
    });
    try testing.expectEqual(@as(usize, 1), rest.len);
    try testing.expectEqualStrings("sari@example.dev", rest[0].email.view());

    // Text, where the elements are strings in the array rather than numbers.
    const named = try db.select(Everything, &run, .{
        .where = .{ .email = .{ .in = &[_][]const u8{ "wati@example.dev", "sari@example.dev" } } },
    });
    try testing.expectEqual(@as(usize, 2), named.len);

    // A tag, which is written through `forWire` — so the array holds the
    // names the column holds, not whatever a Zig enum would stringify as.
    const top = try db.select(Everything, &run, .{
        .where = .{ .grade = .{ .in = &[_]Grade{ .gold, .silver } } },
    });
    try testing.expectEqual(@as(usize, 2), top.len);

    // And a `Uuid`, which is the thirty-six characters here rather than
    // sixteen bytes — the element goes through the same conversion a scalar
    // does, which is the whole reason `jsonList` converts before it writes.
    const byKey = try db.select(Everything, &run, .{
        .where = .{ .public = .{ .in = &[_]types.Uuid{key} } },
    });
    try testing.expectEqual(@as(usize, 1), byKey.len);
    try testing.expectEqualStrings("wati@example.dev", byKey[0].email.view());

    // An empty list matches nothing rather than failing, which is what
    // `json_each('[]')` does and what `= ANY('{}')` does on Postgres.
    const none = try db.select(Everything, &run, .{
        .where = .{ .age = .{ .in = &[_]i32{} } },
    });
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "an INTEGER PRIMARY KEY is the rowid, so a correct table no longer stops the server" {
    // The spelling every SQLite tutorial, every migration tool and SQLite's
    // own documentation writes. SQLite reports `notnull = 0` for it because
    // the column is an *alias for the rowid* rather than a constraint, and
    // reading that as nullable made `nilo_start` refuse to start over a table
    // that is right (ADR 0115).
    //
    // This never showed up because `accounts_ddl` above says `INTEGER PRIMARY
    // KEY AUTOINCREMENT NOT NULL` — the redundant `NOT NULL` walks around the
    // bug, so the one SQLite schema-check test there was passed.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:rowid-alias?mode=memory&cache=shared",
        .{ .size = 1 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();

    _ = try db.exec(&run,
        \\CREATE TABLE events (
        \\  id    INTEGER PRIMARY KEY,
        \\  label TEXT NOT NULL
        \\)
    , .{});
    // The same column named by the tuple form rather than inline, which is
    // still the alias.
    _ = try db.exec(&run,
        \\CREATE TABLE notes (
        \\  id    INTEGER,
        \\  label TEXT NOT NULL,
        \\  PRIMARY KEY (id)
        \\)
    , .{});

    const Event = struct {
        pub const nilo_table = .{ .name = "events", .key = .id };
        id: i64,
        label: nilo.Str,
    };
    const Note = struct {
        pub const nilo_table = .{ .name = "notes", .key = .id };
        id: i64,
        label: nilo.Str,
    };
    try testing.expectEqual(@as(usize, 0), try db.checkSchema(&.{ Event, Note }));
}

// The other direction — the spellings SQLite does *not* turn into the rowid,
// which have to keep answering that they may be null — is checked one layer
// down, in `sqlite.zig`, against `columnsOf` itself. Not here, because
// `checkSchema` reports a problem with `std.log.err` and the test runner
// counts that as a failure: the same reason `wireOf` warns rather than errs.

test "db.exec answers with the rows it changed and needs no Row to do it" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:exec-counts?mode=memory&cache=shared",
        .{ .size = 1 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();
    _ = try db.exec(&run, accounts_ddl, .{});

    for (0..3) |_| _ = try db.insert(SqliteAccount, &run, .{
        .public = types.Uuid.nil,
        .email = "someone@example.dev",
    });
    try testing.expectEqual(@as(usize, 3), try db.exec(&run, "DELETE FROM accounts", .{}));

    // And inside a transaction, which is where a migration that has to be all
    // or nothing puts it.
    var tx = try db.begin(&run, .{});
    errdefer tx.rollback();
    _ = try tx.exec(&run, "CREATE INDEX accounts_email ON accounts(email)", .{});
    try tx.commit();
}

test "a Db can be stopped, and stopping it twice or deiniting after is a no-op" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    // `listen()` calls this on the way out, and the caller's own
    // `defer db.deinit()` runs after it. Both have to be safe, and so does a
    // stop on a `Db` whose `nilo_start` never ran (ADR 0151).
    db.nilo_stop();
    try testing.expect(db.wire == null);
    db.nilo_stop();
    db.deinit();
    try testing.expect(db.wire == null);
}

test "a Db that never started can still be stopped" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();

    // `Registry.start` stops at the first failure, so a `Db` provided beside
    // one that refused the boot reaches `stopAll` having opened nothing.
    db.nilo_stop();
    try testing.expect(db.wire == null);
}

test "rawOne answers with the row or with null, so a key lookup is not an unwrap" {
    // What this replaces, written out six times across four files before it
    // existed (ADR 0179):
    //
    //     const found = try db.raw(Row, c, "…", .{id});
    //     return if (found.len > 0) found[0] else null;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:raw-one?mode=memory&cache=shared",
        .{ .size = 2 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();
    _ = try db.exec(&run, accounts_ddl, .{});

    const key = try types.Uuid.parse("01a01077-5ce8-7932-b42b-a05431a5c4c8");
    _ = try db.insert(SqliteAccount, &run, .{ .public = key, .email = "wati@example.dev" });

    const Card = struct {
        pub const nilo_table = .projection;
        id: i64,
        email: nilo.Str,
    };
    const statement_text = "SELECT id, email FROM accounts WHERE public = ?1";

    const found = (try db.rawOne(Card, &run, statement_text, .{key})).?;
    try testing.expectEqualStrings("wati@example.dev", found.email.view());

    // Null rather than an empty slice, which is what makes `!?T` a 404 in the
    // typed layer with nothing written in the handler (ADR 0024).
    try testing.expectEqual(
        @as(?Card, null),
        try db.rawOne(Card, &run, statement_text, .{types.Uuid.nil}),
    );

    // And inside a transaction, which is the other pair of call sites.
    var tx = try db.begin(&run, .{});
    errdefer tx.rollback();
    const in_tx = (try tx.rawOne(Card, &run, statement_text, .{key})).?;
    try testing.expectEqualStrings("wati@example.dev", in_tx.email.view());
    try testing.expectEqual(
        @as(?Card, null),
        try tx.rawOne(Card, &run, statement_text, .{types.Uuid.nil}),
    );
    try tx.commit();
}

test "rawOne hands back the first row when a statement matches several" {
    // Stated rather than left to be discovered: no `LIMIT 1` is appended,
    // because this module did not write the statement and has nowhere honest
    // to put one (ADR 0179). It is the shape of the call site, not a promise
    // about the query.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:raw-one-many?mode=memory&cache=shared",
        .{ .size = 2 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();
    _ = try db.exec(&run, accounts_ddl, .{});

    for (0..3) |_| _ = try db.insert(SqliteAccount, &run, .{
        .public = types.Uuid.nil,
        .email = "someone@example.dev",
    });

    const Card = struct {
        pub const nilo_table = .projection;
        id: i64,
    };
    const first = (try db.rawOne(Card, &run, "SELECT id FROM accounts ORDER BY id", .{})).?;
    try testing.expectEqual(@as(i64, 1), first.id);
}

test "updateReturningOne is the PATCH shape: the row as it now is, or null" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:update-returning-one?mode=memory&cache=shared",
        .{ .size = 2 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();
    _ = try db.exec(&run, accounts_ddl, .{});

    const made = try db.insert(SqliteAccount, &run, .{
        .public = types.Uuid.nil,
        .email = "wati@example.dev",
    });

    const renamed = (try db.updateReturningOne(SqliteAccount, &run, .{
        .set = .{ .email = "sari@example.dev" },
        .where = .{ .id = made.id },
    })).?;
    try testing.expectEqualStrings("sari@example.dev", renamed.email.view());

    // A key that is not there changed nothing, and null is the 404 the handler
    // wanted rather than an empty slice it has to test the length of.
    try testing.expectEqual(@as(?SqliteAccount, null), try db.updateReturningOne(
        SqliteAccount,
        &run,
        .{ .set = .{ .email = "nobody@example.dev" }, .where = .{ .id = @as(i64, 404) } },
    ));

    var tx = try db.begin(&run, .{});
    errdefer tx.rollback();
    const in_tx = (try tx.updateReturningOne(SqliteAccount, &run, .{
        .set = .{ .email = "third@example.dev" },
        .where = .{ .id = made.id },
    })).?;
    try testing.expectEqualStrings("third@example.dev", in_tx.email.view());
    try testing.expectEqual(@as(?SqliteAccount, null), try tx.updateReturningOne(
        SqliteAccount,
        &run,
        .{ .set = .{ .email = "nobody@example.dev" }, .where = .{ .id = @as(i64, 404) } },
    ));
    try tx.commit();
}

test "the caller can read what the database said about its own statement" {
    // Item 55: a watcher got the whole `Problem` and the call site got
    // `error.QueryFailed`, which is the right split for a log and the wrong
    // one for a branch (ADR 0184).
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .refuses = .{
        .message = "duplicate key value violates unique constraint \"staff_email_key\"",
        .code = "23505",
        .constraint = "staff_email_key",
    } };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    // No watcher installed, which is the case the item is about: reading the
    // failure must not cost a `db.watching` nobody wanted.
    _ = db.select(Person, &run, .{}) catch {
        const said = lastProblem(&run) orelse return error.NoProblemReported;
        // The half an error name cannot carry: *which* unique index fired.
        try testing.expectEqualStrings("staff_email_key", said.constraint);
        try testing.expectEqualStrings("23505", said.code);
        return;
    };
    return error.StatementShouldHaveFailed;
}

test "a statement that worked leaves no problem behind it" {
    // The strings live in the request arena, which is reset between requests
    // on one connection — so a slot only ever written on failure would hand
    // back freed bytes after a statement that worked.
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    db.wire = .{ .refuses = .{ .message = "boom", .code = "23503" } };
    _ = db.select(Person, &run, .{}) catch {};
    try testing.expect(lastProblem(&run) != null);

    db.wire = .{ .refuses = null, .answers = 0 };
    _ = try db.select(Person, &run, .{});
    try testing.expectEqual(@as(?wire_mod.Problem, null), lastProblem(&run));
}

test "a problem left by somebody else's request is not this one's to read" {
    // Two Scopes are two arenas, which is what makes a fiber that moved
    // between the failure and the `catch` answer null rather than a plausible
    // sentence about the wrong row.
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .refuses = .{ .message = "boom", .code = "23505" } };

    var mine = nilo.Run.init(testing.allocator);
    defer mine.deinit();
    var theirs = nilo.Run.init(testing.allocator);
    defer theirs.deinit();

    _ = db.select(Person, &mine, .{}) catch {};
    try testing.expect(lastProblem(&mine) != null);
    try testing.expectEqual(@as(?wire_mod.Problem, null), lastProblem(&theirs));
}

test "a page carries the total the condition matched, in one statement" {
    // Item 56: a `db.count` beside a `db.select` is two statements against a
    // table somebody else can write between, so the total and the rows can
    // disagree with nothing saying so (ADR 0185).
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:paged-list?mode=memory&cache=shared",
        .{ .size = 2 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();
    _ = try db.exec(&run, accounts_ddl, .{});

    for (0..7) |i| {
        var mail: [16]u8 = undefined;
        var bytes: [16]u8 = @splat(0);
        bytes[15] = @intCast(i);
        _ = try db.insert(SqliteAccount, &run, .{
            .public = types.Uuid.v4(bytes),
            .email = try std.fmt.bufPrint(&mail, "n{d}@example.dev", .{i}),
        });
    }

    const first = try db.page(SqliteAccount, &run, .{
        .order = .{ .id = .asc },
        .limit = 3,
    });
    try testing.expectEqual(@as(usize, 3), first.rows.len);
    try testing.expectEqual(@as(i64, 7), first.total);
    try testing.expectEqualStrings("n0@example.dev", first.rows[0].email.view());

    // The last page is short and the total is the same number, which is the
    // whole of what a trimmed list needs to say "7 of 7".
    const last = try db.page(SqliteAccount, &run, .{
        .order = .{ .id = .asc },
        .limit = 3,
        .offset = @as(i64, 6),
    });
    try testing.expectEqual(@as(usize, 1), last.rows.len);
    try testing.expectEqual(@as(i64, 7), last.total);

    // A condition that narrows narrows the total with it — the count is the
    // page's own `WHERE`, which is the property two statements cannot hold.
    const narrowed = try db.page(SqliteAccount, &run, .{
        .where = .{ .email = "n2@example.dev" },
        .order = .{ .id = .asc },
        .limit = 3,
    });
    try testing.expectEqual(@as(usize, 1), narrowed.rows.len);
    try testing.expectEqual(@as(i64, 1), narrowed.total);

    // And nothing matching is an empty page with a total of zero rather than
    // a statement that could not answer.
    const none = try db.page(SqliteAccount, &run, .{
        .where = .{ .email = "nobody@example.dev" },
        .order = .{ .id = .asc },
        .limit = 3,
    });
    try testing.expectEqual(@as(usize, 0), none.rows.len);
    try testing.expectEqual(@as(i64, 0), none.total);
}

test "a page reads the same columns a select does, and one more" {
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"nickname\", \"age\", count(*) OVER ()" ++
            " FROM \"people\" WHERE \"age\" > $1 ORDER BY \"id\" ASC LIMIT 20 OFFSET 40",
        comptime statement.page(dialect.Postgres, Person, @TypeOf(.{
            .where = .{ .age = .{ .gt = 18 } },
            .order = .{ .id = .asc },
            .limit = 20,
            .offset = 40,
        })).sql,
    );
}

test "an optional filter narrows when it is set and drops when it is not" {
    // Items 54 and 56 together, which is the pair the report filed them as:
    // an optional filter and a total in one statement is the ordinary list
    // endpoint (ADR 0183, ADR 0185).
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:optional-filter?mode=memory&cache=shared",
        .{ .size = 2 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();
    _ = try db.exec(&run, accounts_ddl, .{});

    for ([_][]const u8{ "wati@example.dev", "budi@example.dev", "wati@other.dev" }, 0..) |mail, i| {
        var bytes: [16]u8 = @splat(0);
        bytes[15] = @intCast(i);
        _ = try db.insert(SqliteAccount, &run, .{
            .public = types.Uuid.v4(bytes),
            .email = mail,
        });
    }

    const Filter = struct { search: ?[]const u8 = null };

    // Set: the term is in the statement.
    const set: Filter = .{ .search = "wati" };
    const narrowed = try db.page(SqliteAccount, &run, .{
        .where = .{ .email = .{ .icontains = where_mod.given(set.search) } },
        .order = .{ .id = .asc },
        .limit = 10,
    });
    try testing.expectEqual(@as(usize, 2), narrowed.rows.len);
    try testing.expectEqual(@as(i64, 2), narrowed.total);

    // Absent: the same statement, the same parameter list, and the term is
    // not applied — every row, rather than the nothing `= NULL` would have
    // matched (ADR 0044 is what that refusal was protecting).
    const unset: Filter = .{};
    const all = try db.page(SqliteAccount, &run, .{
        .where = .{ .email = .{ .icontains = where_mod.given(unset.search) } },
        .order = .{ .id = .asc },
        .limit = 10,
    });
    try testing.expectEqual(@as(usize, 3), all.rows.len);
    try testing.expectEqual(@as(i64, 3), all.total);
}
