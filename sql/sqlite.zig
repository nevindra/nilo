//! The second Wire, behind the same contract as the first (`wire.zig`).
//!
//! Everything here follows from one sentence: **SQLite is not a server.** It
//! is a library reading a file in this process, so there is no socket to wait
//! on, no server to hold the rules, and no second connection that may write.
//! [ADR 064](../docs/adr/064-a-file-has-no-socket-to-wait-on.md) decides how
//! a statement reaches a thread and whose C brings SQLite in;
//! [ADR 065](../docs/adr/065-one-writer-is-not-a-setting-it-is-the-database.md)
//! decides the pool, where `raw` goes, durability and the test story.
//!
//! Three things are worth knowing before reading the code.
//!
//! **The threading choice has no default.** `Wire` is a function of its
//! options and `threading` is the one field without one, so leaving it out is
//! a compile error naming both answers. It is not a tuning knob: it decides
//! whether a slow statement stalls an executor thread, and there is no
//! measurement yet saying which way a given deployment should go
//! (ADR 064). What the field buys is that taking that measurement later
//! changes a line in a program rather than this file.
//!
//! **The pool is one writer and several read-only readers.** SQLite
//! serialises writers over the whole database, so a pool of equal connections
//! would be describing something that does not exist — two of them writing at
//! once means `SQLITE_BUSY`, which this module reports as `Locked`, which
//! `wire.zig` says is *the answer the caller asked the question to get*. An
//! error raised because two of our own connections collided is not an answer
//! to anything.
//!
//! **A reader is opened read-only, and that is a safety net rather than a
//! label.** Routing is by the statement's first keyword, which is exact for
//! everything this module generates because this module wrote the text. For
//! `db.raw`, where the text is the caller's, it is a guess — and a guess that
//! goes the wrong way lands on a connection SQLite itself will not let write.
//! The failure is loud, immediate, and names the connection; the alternative
//! designs fail by being slow or by being wrong. The net is two strands, the
//! read-only open flag and `PRAGMA query_only`, because SQLite's URI `mode=`
//! outranks the flag and an in-memory database, where a suite runs, would
//! otherwise have none.
//!
//! **`:memory:` is one database for the whole pool and private to it.** On
//! its own SQLite gives each connection a private one, which would make a
//! pool several empty databases; `open` turns it into a shared-cache name no
//! other pool in the process has (ADR 065).

const std = @import("std");
const core = @import("nilo_core");
const zqlite = @import("zqlite");

const wire = @import("wire.zig");
/// Only the tests reach for this, and only for `SQLite.introspect` — the
/// query `columnsOf` is handed at run time. A Wire is not allowed to have an
/// opinion about a Dialect anywhere else, which is what keeps the seam a seam
/// (ADR 055).
const dialect = @import("dialect.zig");
const types = @import("types.zig");

/// The SQLite that is compiled in, as its own version string — `3.53.0`.
///
/// Public because it is the one thing about this Wire that comes from
/// somewhere else: SQLite is a bundled amalgamation rather than a library the
/// machine happened to have (ADR 064), so a benchmark or a `/health` route
/// that prints a version is printing something the build pinned. Reading it
/// here saves every caller an import of `zqlite`, which is the seam's whole
/// point.
pub const version: []const u8 = zqlite.c.SQLITE_VERSION;

/// What building a Wire takes. Everything except `threading` has a default,
/// and `threading` has none on purpose.
pub const Options = struct {
    /// Where a statement runs. **No default**, and the null below is how that
    /// is spelled rather than one: `Wire` refuses a null with a message naming
    /// both answers and what each costs. Leaving the field out of the struct
    /// entirely would refuse it too, in Zig's words rather than nilo's, and an
    /// error message is a feature here (ADR 026).
    threading: ?Threading = null,

    /// How long SQLite waits for a lock somebody else holds before giving up.
    /// Its expiry is what becomes `wire.Error.Locked`.
    ///
    /// With one writer connection this is reachable only from outside the
    /// process — another program, or a second instance on the same file —
    /// which is exactly the case worth reporting rather than hiding.
    busy_timeout_ms: u32 = 5_000,

    /// `PRAGMA cache_size`, in KiB, or null for SQLite's own default of 2,000.
    ///
    /// **It is a ceiling rather than an allocation**, which is the correction
    /// [`spike/sqlite_facts`](../spike/sqlite_facts/) made to ADR 065: a
    /// connection holds 28 KiB opened and grows towards this as pages are
    /// touched. The same spike measured what the ceiling buys, in reads: five
    /// thousand primary-key lookups issue ten of them at 2,000 KiB and ten at
    /// 32, and three full scans of a table larger than any cache issue 2,261
    /// and 2,265. Lowering it is close to free for a service that scans, and
    /// the cliff for a service that does not sits wherever its working set
    /// sits — which is why the default is SQLite's rather than a number this
    /// module invented.
    cache_kib: ?u32 = null,

    /// `PRAGMA synchronous`. `NORMAL` under WAL is what SQLite recommends for
    /// application use: the database cannot corrupt, and what a power cut can
    /// lose is the most recent transactions.
    ///
    /// `.full` is one word away and is what to write if losing a committed
    /// transaction is not survivable. `OFF` is not offered — it is the
    /// setting where corruption is possible, and no default here should make
    /// that reachable by accident (ADR 065).
    synchronous: Synchronous = .normal,
};

/// How hard a commit tries before it reports success.
///
/// Named rather than written inline because `Options` and `Settled` both hold
/// one, and two anonymous enums with the same fields are two types.
pub const Synchronous = enum {
    /// WAL's recommended setting for application use. The database cannot
    /// corrupt; a power cut can lose the most recent transactions.
    normal,
    /// Wait for the disk to confirm. `bench/result/sql.md` §8 prices it: one
    /// autocommitted INSERT is 660 µs, and every library measures the same,
    /// because what is being timed is an fsync.
    full,
};

/// Where a statement runs. Both answers are legitimate and they fail
/// differently, which is why neither is a default.
pub const Threading = union(enum) {
    /// Run it on the fiber that asked, holding that executor thread for the
    /// duration.
    ///
    /// The faster answer when every statement is a primary-key lookup served
    /// from the page cache: a hop costs a few microseconds and so does the
    /// read. The wrong answer when a statement can be slow — a cold page, a
    /// scan, a `raw` doing something large — because that thread serves every
    /// other connection assigned to it while it waits.
    in_fiber,
    /// Hand it to the Engine's thread pool and park the fiber until it comes
    /// back.
    ///
    /// The payload is the namespace holding `blockingReserved`, `nilo`
    /// itself:
    ///
    /// ```zig
    /// const Wire = sqlite.Wire(.{ .threading = .{ .hop = nilo } });
    /// ```
    ///
    /// It arrives from the caller's program rather than being imported here
    /// because it lives in `http/bulkhead.zig` and `sql/` may not name
    /// `nilo_http` — `zig build layering` refuses it. `std.Io.concurrent` is
    /// not the way round it: zio implements that slot by starting a *fiber*,
    /// so a blocking call inside one holds an executor thread exactly as it
    /// would have held the caller's (ADR 064).
    hop: type,
};

/// `Options` with `threading` settled, or a compile error saying why it
/// cannot be. The whole of ADR 064 is that this choice is made rather than
/// defaulted, and a default here would be the one place it could be missed.
const Settled = struct {
    threading: Threading,
    busy_timeout_ms: u32,
    cache_kib: ?u32,
    synchronous: Synchronous,
};

fn resolve(comptime opts: Options) Settled {
    const threading = opts.threading orelse @compileError(
        "nilo: a sqlite Wire has to say where its statements run.\n" ++
            "  SQLite is a library reading a file, not a server, so there is no socket to " ++
            "wait on and the choice cannot be made for you.\n" ++
            "  .threading = .{ .hop = nilo }  — hand each statement to the Engine's thread " ++
            "pool. Slower per statement, and no statement can stall an executor thread.\n" ++
            "  .threading = .in_fiber        — run it on the fiber that asked. Faster when " ++
            "every statement is a cached lookup, and one slow statement holds a thread that " ++
            "serves other connections.",
    );
    return .{
        .threading = threading,
        .busy_timeout_ms = opts.busy_timeout_ms,
        .cache_kib = opts.cache_kib,
        .synchronous = opts.synchronous,
    };
}

/// How many `:memory:` pools this process has opened, which is what keeps
/// them apart.
///
/// **At file scope rather than inside `Wire`**, because `Wire` is a function
/// of its options: `sql.Sqlite` and `sql.SqliteNamed("cache", …)` are two
/// types, and a counter in each would hand both of them `0`, one database
/// under two names. Atomic because tests in one process open pools from
/// several threads at once, and monotonic because all a name needs is to be
/// unequal to every other.
var memory_pools: std.atomic.Value(usize) = .init(0);

/// The shared-cache name a `:memory:` pool opens, written into the buffer
/// `open` already has for the path, so the name costs no allocation and has
/// no owner to outlive the Db: SQLite keys the database by it while a
/// connection is open, and nothing reads it after.
///
/// The counter's address goes in beside its value, so two copies of this
/// module linked into one program, each counting from zero, still cannot
/// meet. A caller's own `file:NAME?mode=memory&cache=shared` is untouched and
/// still shared by name, which is what that spelling is for.
fn privateMemoryName(buf: []u8) [:0]const u8 {
    const n = memory_pools.fetchAdd(1, .monotonic);
    return std.mem.printSentinel(
        buf,
        "file:nilo-memory-{x}-{d}?mode=memory&cache=shared",
        .{ @intFromPtr(&memory_pools), n },
        0,
    ) catch unreachable;
}

pub fn Wire(comptime opts_in: Options) type {
    const opts = comptime resolve(opts_in);
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        /// The loop, kept rather than ignored — and **the one thing this Wire
        /// needs it for is the queue in front of the writer.**
        ///
        /// There is no socket to dial, so `open` looks like it has no use for
        /// an `Io` at all. Waiting is the use: `std.Io.Mutex` and
        /// `std.Io.Condition` reach the futex slots of the vtable, so a fiber
        /// queueing for the writer *parks* instead of holding its thread —
        /// through zio when there is an Engine, and through `std.Io.Threaded`
        /// in a test. That is true under `.in_fiber` as much as under `.hop`:
        /// the choice in ADR 064 is about where a statement *runs*, and this
        /// is about waiting for a turn to run it.
        io: std.Io,
        /// Index 0 is the writer. Everything after it is a read-only reader.
        conns: []Conn,
        lock: std.Io.Mutex = .init,
        /// **One queue per question, and that is the fix rather than a
        /// tidying** (ADR 065). These used to be a single `Condition` that
        /// `takeWriter` and `takeReader` both waited on while testing
        /// different predicates, woken with `signal`. So a reader coming back
        /// could wake the fiber that wanted the *writer*, which re-tested
        /// `conns[0].busy`, found it still true and waited again — and the
        /// fiber that asked for a reader was never woken at all, though the
        /// connection it wanted was sitting free. Under a load that both reads
        /// and writes that is a request which stalls with nothing in the log
        /// and nothing holding it.
        ///
        /// **`broadcast` rather than `signal` within a queue**, which is the
        /// second half. This Wire's wait is cancellable on purpose — a fiber
        /// whose request is gone gives its turn up rather than holding it — and
        /// a `signal` consumed by a waiter that then gives up is a
        /// wakeup nobody else receives. Waking everybody queued for the one
        /// thing that just became free costs a re-test of one `bool` each, on
        /// a path that is by definition already waiting.
        free_writer: std.Io.Condition = .init,
        free_reader: std.Io.Condition = .init,
        /// How long a fiber may queue for a connection before it gives up,
        /// out of `Db.Opts.timeout_ms`. Zero is no bound.
        ///
        /// **`open` used to read `size` and drop the rest**, so the option a
        /// caller set to bound a queue was silently ignored here while it was
        /// honoured on Postgres (ADR 107).
        queue_timeout_ms: u32,
        /// What can reach a waiting fiber to stop it. `.off` in a program
        /// with no Engine, where nothing can cancel a fiber and the wait is
        /// unbounded — see `wire.OpenOpts.limits`.
        limits: core.Limits,

        /// One connection and the statements kept prepared on it.
        ///
        /// The cache is per connection because a `sqlite3_stmt` belongs to the
        /// `sqlite3` it was prepared against — which is the same reason
        /// [ADR 051](../docs/adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)
        /// gives for Postgres, arriving here from a different direction.
        const Conn = struct {
            handle: zqlite.Conn,
            /// Keyed by the plan name, which is a comptime constant derived
            /// from the statement. `db.raw` is named like any other (its text is
            /// comptime, ADR 051). What passes null and is not cached is text
            /// that arrives at run time (`db.exec`, a `Composed` statement), so
            /// a cache would grow with traffic rather than with the program.
            kept: std.StringHashMapUnmanaged(zqlite.Stmt) = .empty,
            busy: bool = false,
            /// The statement that took this connection, for the line a
            /// statement that gave up waiting for it writes. The text is the
            /// holder's own and is alive for exactly as long as it holds the
            /// connection, and it is read under the Wire's lock while `busy`,
            /// so nothing is copied. No time beside it: a clock read per
            /// statement measured 4.5% of a prepared `find`, and the waiter's
            /// own `timeout_ms` already says how long it has been held at
            /// least.
            holder: []const u8 = "",
            /// Whether a statement failed inside the transaction this
            /// connection is holding, since its `BEGIN` or its last
            /// `ROLLBACK TO SAVEPOINT`.
            ///
            /// **SQLite keeps a transaction going after a failed statement,
            /// and Postgres does not, so the Wire holds SQLite to Postgres's
            /// rule.** Left alone, a handler that caught `AlreadyExists`
            /// without a savepoint and went on to commit would keep the rest
            /// of its work here and lose all of it on Postgres, where the
            /// failure aborted the transaction — and the test run against
            /// this file would be the one telling it the code was right. Held
            /// here, the statements after the failure are refused and the
            /// commit rolls back, on both Wires, until a savepoint is rolled
            /// back to.
            ///
            /// On the connection rather than the `Tx` because a failure can
            /// arrive in `next`, stepping a result set that knows its
            /// connection and not the transaction it belongs to.
            aborted: bool = false,

            fn deinit(self: *Conn, gpa: std.mem.Allocator) void {
                var it = self.kept.valueIterator();
                while (it.next()) |stmt| stmt.deinit();
                self.kept.deinit(gpa);
                self.handle.close();
            }
        };

        /// One statement in flight, and the connection it is running on.
        pub const Rows = struct {
            wire: *Self,
            at: usize,
            stmt: zqlite.Stmt,
            /// Whether the statement lives in the connection's cache. A kept
            /// statement is reset rather than finalised — finalising one would
            /// leave the cache holding a pointer SQLite has freed.
            kept: bool,
            /// False inside a transaction, where the `Tx` holds the connection
            /// for its whole life. Releasing it here would put a connection
            /// back in the pool with an open transaction on it.
            owns_conn: bool = true,
            closed: bool = false,

            /// Give the statement and the connection back, whatever happened.
            ///
            /// **Resetting is not tidiness.** A statement left mid-result
            /// holds a read transaction open on its connection, so a reader
            /// released without this would carry somebody else's snapshot into
            /// the next request — which is `wire.zig`'s *whatever the handler
            /// did, the connection goes back usable*, in SQLite's dialect.
            pub fn close(self: *Rows) void {
                if (self.closed) return;
                self.closed = true;
                if (self.kept) {
                    self.stmt.reset() catch {};
                    self.stmt.clearBindings() catch {};
                } else {
                    self.stmt.deinit();
                }
                if (self.owns_conn) self.wire.release(self.at);
            }
        };

        /// A transaction, and the connection it owns until it ends.
        pub const Tx = struct {
            wire: *Self,
            at: usize,
            done: bool = false,
            /// Begun with `.rebuilding`: foreign keys are off on the writer
            /// until this ends, and go back on before it is released
            /// (`wire.Begin.rebuilding`).
            rebuilding: bool = false,
            /// The tables this `.rebuilding` transaction dropped, read off
            /// its statements (`dialect.Drops`), and whether one could not be
            /// read. Where the check before COMMIT looks, so an old violation
            /// in a table the version never touched does not fail it.
            dropped: []const []const u8 = &.{},
            dropped_unread: bool = false,

            /// Note the tables `sql` drops, when this transaction is one that
            /// checks the keys it touched. Allocates only on a `DROP TABLE`,
            /// on the arena the transaction already runs in; an allocation
            /// that fails leaves the whole-database check, the safe side.
            fn noteDrops(self: *Tx, arena: std.mem.Allocator, sql: []const u8) void {
                if (!self.rebuilding) return;
                var drops: dialect.Drops = .{ .text = sql };
                while (true) {
                    const seen = drops.next() catch {
                        self.dropped_unread = true;
                        return;
                    };
                    const found = seen orelse return;
                    const grown = arena.alloc([]const u8, self.dropped.len + 1) catch {
                        self.dropped_unread = true;
                        return;
                    };
                    @memcpy(grown[0..self.dropped.len], self.dropped);
                    grown[self.dropped.len] = arena.dupe(u8, found) catch {
                        self.dropped_unread = true;
                        return;
                    };
                    self.dropped = grown;
                }
            }

            pub fn run(
                self: *Tx,
                arena: std.mem.Allocator,
                sql: []const u8,
                values: anytype,
                plan: ?[]const u8,
                problem: ?*?wire.Problem,
            ) wire.Error!Rows {
                if (self.done) return error.QueryFailed;
                try self.live();
                try Self.checked(values, problem);
                self.noteDrops(arena, sql);
                const stmt, const kept = self.wire.stmtOn(self.at, sql, plan, values) catch |err| {
                    self.wire.said(self.at, err, arena, problem);
                    self.wire.conns[self.at].aborted = true;
                    return err;
                };
                return .{
                    .wire = self.wire,
                    .at = self.at,
                    .stmt = stmt,
                    .kept = kept,
                    .owns_conn = false,
                };
            }

            pub fn exec(
                self: *Tx,
                arena: std.mem.Allocator,
                sql: []const u8,
                values: anytype,
                plan: ?[]const u8,
                problem: ?*?wire.Problem,
            ) wire.Error!usize {
                if (self.done) return error.QueryFailed;
                try self.live();
                try Self.checked(values, problem);
                self.noteDrops(arena, sql);
                return self.wire.execOn(self.at, sql, plan, values) catch |err| {
                    self.wire.said(self.at, err, arena, problem);
                    self.wire.conns[self.at].aborted = true;
                    return err;
                };
            }

            /// `Wire.columnsOf` down this transaction's connection, so a
            /// migration that holds one does not ask for a second.
            pub fn columnsOf(
                self: *Tx,
                arena: std.mem.Allocator,
                query: []const u8,
                schema: ?[]const u8,
                table: []const u8,
            ) wire.Error![]const wire.Column {
                var pragma_buf: [1024]u8 = undefined;
                var master_buf: [1024]u8 = undefined;
                const text = try Self.qualifiedQuery(&pragma_buf, &master_buf, query, schema);
                var rows = try self.run(arena, text, .{table}, null, null);
                defer rows.close();
                return self.wire.columnList(arena, &rows);
            }

            /// Refuse a statement on a transaction a failed one has aborted,
            /// the way Postgres answers `25P02` (`Conn.aborted`).
            fn live(self: *Tx) wire.Error!void {
                if (!self.wire.conns[self.at].aborted) return;
                std.log.warn("{s}", .{wire.aborted_statement});
                return error.QueryFailed;
            }

            /// **Refused, and the dialect is named.**
            ///
            /// [ADR 043](../docs/adr/043-a-deadline-needs-a-connection-you-hold.md)
            /// put this on the `Tx` because a deadline has to be set on the
            /// connection the statement travels down. On Postgres that is a
            /// message to a server. SQLite has no server: the only mechanism
            /// is `sqlite3_interrupt`, called from another thread while the
            /// statement runs, and it aborts whatever *the connection* is
            /// doing rather than the statement that asked.
            ///
            /// A deadline that sometimes aborts a neighbouring statement is
            /// worse than one that says plainly it is not available here.
            /// `busy_timeout_ms` already covers the case that actually
            /// happens — waiting on a lock nobody is releasing (ADR 065).
            pub fn deadline(self: *Tx, ms: u32) wire.Error!void {
                _ = self;
                _ = ms;
                @compileError(
                    "nilo: tx.deadline is not available on the sqlite dialect.\n" ++
                        "  A deadline has to be enforced by the database, and SQLite has no server " ++
                        "to enforce it — sqlite3_interrupt aborts the whole connection rather than " ++
                        "one statement.\n" ++
                        "  What it would have caught is already bounded: `busy_timeout_ms` on the " ++
                        "Wire's options is how long a statement waits for a lock somebody else holds.",
                );
            }

            /// `SAVEPOINT nilo_sp_3`, and the two ways back out. Spelled the
            /// same three ways Postgres spells them, which is the one place
            /// SQLite's grammar matches without qualification.
            pub fn savepoint(
                self: *Tx,
                arena: std.mem.Allocator,
                comptime op: wire.SavepointOp,
                id: u32,
            ) wire.Error!void {
                _ = arena;
                if (self.done) return error.QueryFailed;
                // Undoing is the one statement an aborted transaction takes,
                // and once it lands the transaction is live again.
                if (op != .undo) try self.live();

                const verb = switch (op) {
                    .mark => "SAVEPOINT ",
                    .undo => "ROLLBACK TO SAVEPOINT ",
                    .keep => "RELEASE SAVEPOINT ",
                };
                var buf: [verb.len + name_prefix.len + 10 + 1]u8 = undefined;
                const sql = std.mem.printSentinel(&buf, verb ++ name_prefix ++ "{d}", .{id}, 0) catch
                    unreachable;
                try self.wire.command(self.at, sql);
                if (op == .undo) self.wire.conns[self.at].aborted = false;
            }

            const name_prefix = "nilo_sp_";

            /// `problem` is where a refused COMMIT leaves SQLite's words:
            /// a deferred foreign key is checked here and nowhere else.
            pub fn commit(self: *Tx, arena: std.mem.Allocator, problem: ?*?wire.Problem) wire.Error!void {
                if (self.done) return;
                // Rolled back rather than committed: Postgres would have kept
                // none of it, and a handler tested here has to hear what it
                // will hear there (`Conn.aborted`).
                if (self.wire.conns[self.at].aborted) {
                    self.rollback();
                    std.log.warn("{s}", .{wire.aborted_commit});
                    return error.QueryFailed;
                }
                self.done = true;
                defer self.wire.release(self.at);
                defer self.restore();
                if (self.rebuilding) {
                    // The check the statements did not make as they ran.
                    // A row pointing at nothing is refused here rather than
                    // committed, which is SQLite's own recipe for a rebuild.
                    const broken = self.wire.brokenReference(self.at, arena, self.dropped, self.dropped_unread) catch |err| {
                        self.wire.command(self.at, "ROLLBACK") catch {};
                        return err;
                    };
                    if (broken) {
                        std.log.warn("{s}", .{wire.rebuild_broke_reference});
                        if (problem) |slot| slot.* = .{ .message = wire.rebuild_broke_reference };
                        self.wire.command(self.at, "ROLLBACK") catch {};
                        return error.ForeignKeyViolated;
                    }
                }
                self.wire.command(self.at, "COMMIT") catch |err| {
                    self.wire.said(self.at, err, arena, problem);
                    // **A COMMIT SQLite refused leaves the transaction open**
                    // — a deferred foreign key that is still broken, a
                    // `BUSY` on the WAL — and the writer was about to go back
                    // to the pool with it, for the next request to run inside
                    // somebody else's transaction. Rolled back first; one
                    // that is no longer open refuses the ROLLBACK harmlessly.
                    self.wire.command(self.at, "ROLLBACK") catch {};
                    return err;
                };
            }

            /// Cannot fail, because it is called from a `defer` on the way out
            /// of a function that is already failing.
            pub fn rollback(self: *Tx) void {
                if (self.done) return;
                self.done = true;
                self.wire.conns[self.at].aborted = false;
                defer self.wire.release(self.at);
                defer self.restore();
                self.wire.command(self.at, "ROLLBACK") catch |err| {
                    std.log.warn(
                        "nilo_sql: a transaction could not be rolled back ({s}).",
                        .{@errorName(err)},
                    );
                };
            }

            /// Foreign keys back on, after a `.rebuilding` transaction and
            /// before the writer is released. The pragma is a no-op inside a
            /// transaction, so it has to come after the COMMIT or ROLLBACK.
            fn restore(self: *Tx) void {
                if (!self.rebuilding) return;
                self.wire.command(self.at, "PRAGMA foreign_keys = ON") catch |err| {
                    std.log.warn(
                        "nilo_sql: foreign keys could not be turned back on after a rebuild ({s}); " ++
                            "the writer goes on without them until the process restarts.",
                        .{@errorName(err)},
                    );
                };
            }
        };

        /// Open the database and build the pool.
        ///
        /// `url` is a path, or SQLite's URI form. `size` is the whole pool:
        /// one writer and `size - 1` readers, because `wire.OpenOpts` is the
        /// contract both Wires answer and *swapping the driver must not change
        /// what a caller writes*. A second knob here would have made that
        /// false.
        ///
        /// `connect_on_init` has no meaning: a file is opened or it is not,
        /// and there is no server to be switched off. It is ignored rather
        /// than refused, so one program can hold both kinds of database
        /// without writing two option structs (ADR 054).
        ///
        /// **`dials_on_open` is how `Db.nilo_start` knows this**, so it does
        /// not open a file twice when the first open fails, nor answer in a
        /// server's words about a `connect_on_init` that did nothing. The
        /// Postgres Wire has no such declaration and is taken to dial.
        pub const dials_on_open = false;

        /// `:memory:` opens a database the pool shares and nobody else does:
        /// its writer and readers see one another, and a second pool on
        /// `:memory:`, in this test or the one running beside it, gets a
        /// database of its own (`privateMemoryName`). It goes when the pool
        /// closes, as SQLite's own `:memory:` goes with its connection.
        ///
        /// **An empty URL is refused.** SQLite would give each connection a
        /// private temporary database, which is a pool of several empty ones,
        /// and an empty URL is far more often a setting that was never set
        /// than a choice; `:memory:` is how the choice is spelled.
        pub fn open(
            io: std.Io,
            gpa: std.mem.Allocator,
            url: []const u8,
            open_opts: wire.OpenOpts,
        ) !Self {
            if (url.len == 0) return error.EmptyDatabaseUrl;

            const size = @max(open_opts.size, 2);
            const conns = try gpa.alloc(Conn, size);
            errdefer gpa.free(conns);

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (url.len >= path_buf.len) return error.PathTooLong;
            const path = if (std.mem.eql(u8, url, ":memory:"))
                privateMemoryName(&path_buf)
            else
                std.mem.printSentinel(&path_buf, "{s}", .{url}, 0) catch return error.PathTooLong;

            var made: usize = 0;
            errdefer for (conns[0..made]) |*conn| conn.deinit(gpa);

            for (conns, 0..) |*conn, i| {
                const flags = if (i == 0)
                    zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite |
                        zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.Uri
                else
                    zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.Uri;

                conn.* = .{ .handle = try zqlite.open(path, flags) };
                made += 1;
                try prime(conn.handle, i == 0);
            }

            return .{
                .gpa = gpa,
                .io = io,
                .conns = conns,
                .queue_timeout_ms = open_opts.timeout_ms,
                .limits = open_opts.limits,
            };
        }

        /// The pragmas every connection gets, in the order they have to be in:
        /// the journal mode is a property of the database and the rest are
        /// properties of this connection.
        ///
        /// **The writer sets the journal mode and a reader does not**, because
        /// `journal_mode = WAL` is a write to the database header and a
        /// read-only connection cannot make one.
        ///
        /// **A reader also gets `query_only`**, the half of the backstop that
        /// holds in memory: SQLite's URI `mode=memory` outranks the read-only
        /// open flag, so without it a reader on `:memory:` writes (check 6c
        /// of `spike/sqlite_facts`), and a `raw` routed there by mistake
        /// would succeed on the connection meant to refuse it (ADR 065).
        fn prime(conn: zqlite.Conn, writer: bool) !void {
            var buf: [64]u8 = undefined;

            try conn.busyTimeout(@intCast(opts.busy_timeout_ms));

            if (!writer) try conn.execNoArgs("PRAGMA query_only = ON");

            if (writer) {
                try conn.execNoArgs("PRAGMA journal_mode = WAL");
                try conn.execNoArgs(switch (opts.synchronous) {
                    .normal => "PRAGMA synchronous = NORMAL",
                    .full => "PRAGMA synchronous = FULL",
                });
                // Off by default in SQLite, for compatibility with databases
                // written before 2009. A Row that names another Row expects
                // them to be enforced.
                try conn.execNoArgs("PRAGMA foreign_keys = ON");
            }

            if (opts.cache_kib) |kib| {
                try conn.execNoArgs(
                    std.mem.printSentinel(&buf, "PRAGMA cache_size = -{d}", .{kib}, 0) catch unreachable,
                );
            }
        }

        pub fn close(self: *Self) void {
            for (self.conns) |*conn| conn.deinit(self.gpa);
            self.gpa.free(self.conns);
        }

        // -- the pool ----------------------------------------------------

        /// Wait for the writer. There is exactly one, so this is where writes
        /// queue — which is the database's own behaviour surfaced as a wait
        /// rather than as a `SQLITE_BUSY` somebody has to interpret.
        ///
        /// **A wait cut short answers by whose cancellation it was.** This
        /// Wire's own timer (`timeout_ms`) is `TimedOut`, the one place it
        /// has a deadline at all: `tx.deadline` is refused (ADR 065). Any
        /// other cancellation, a request that went away or a server shutting
        /// down, gives its turn up rather than holding it, answers
        /// `Disconnected` as the Postgres Wire's failed `acquire` does, and
        /// **is handed back with `recancel`** so the caller's next
        /// cancellation point sees it (ADR 223). Answering `TimedOut` and
        /// leaving the cancellation spent is how a background loop queued
        /// for the writer at shutdown slept on and kept the process alive.
        ///
        /// **The queue is bounded by `timeout_ms`, and the timer is armed
        /// only by a fiber that is actually going to wait** (ADR 107). A
        /// statement that finds the writer free pays nothing at all: arming
        /// is the Engine registering a timer, and doing that per statement
        /// would put the cost on the path that is never in trouble. The
        /// `Bound` costs `core.Limits.slot_size` bytes of this frame either
        /// way, which is stack a handler touches and therefore per
        /// connection (ADR 062).
        fn takeWriter(self: *Self, holder: []const u8) wire.Error!usize {
            self.lock.lock(self.io) catch return self.cancelled();
            defer self.lock.unlock(self.io);

            if (!self.conns[0].busy) return self.hold(0, holder);

            var bound: core.Limits.Bound = .idle;
            defer bound.release();
            bound.arm(self.limits, self.queue_timeout_ms);

            while (self.conns[0].busy) self.free_writer.wait(self.io, &self.lock) catch
                return self.gaveUp(&bound, .writer);
            return self.hold(0, holder);
        }

        /// Mark a connection taken, and by what. Under the lock.
        fn hold(self: *Self, at: usize, holder: []const u8) usize {
            self.conns[at].busy = true;
            self.conns[at].holder = holder;
            return at;
        }

        /// Any free reader, or wait for one — bounded the same way, and armed
        /// only once every reader has turned out to be busy.
        fn takeReader(self: *Self, holder: []const u8) wire.Error!usize {
            self.lock.lock(self.io) catch return self.cancelled();
            defer self.lock.unlock(self.io);

            var bound: core.Limits.Bound = .idle;
            defer bound.release();

            while (true) {
                for (self.conns[1..], 1..) |*conn, i| {
                    if (conn.busy) continue;
                    return self.hold(i, holder);
                }
                if (!bound.armed) bound.arm(self.limits, self.queue_timeout_ms);
                self.free_reader.wait(self.io, &self.lock) catch
                    return self.gaveUp(&bound, .reader);
            }
        }

        /// A wait ended by a cancellation that is not this Wire's own
        /// timer: hand it back and answer `Disconnected` (ADR 223).
        fn cancelled(self: *Self) wire.Error {
            self.io.recancel();
            return error.Disconnected;
        }

        /// What a wait that ended without a connection means, and the one
        /// line an operator gets for it.
        ///
        /// The `Bound` is the authority rather than the error, for the reason
        /// `core/limits.zig` gives: a cancellation reaching a caller through
        /// somebody else's fixed error set arrives wearing another name. Here
        /// there are only two ways in — this Wire's own timer, or the server
        /// shutting the fiber down — and only the first is worth a line.
        ///
        /// **It names the statement holding the connection.** The line used to guess: one writer, so either the database
        /// is busy or a handler holding a `tx` sent a statement through `db`
        /// and queued for itself. An application whose `/healthz` failed this
        /// way behind a thirty-second report went looking for a `tx` it did
        /// not have. What held the writer was the previous probe's own
        /// `SELECT 1`, parked in the Engine's thread pool behind the report.
        /// The holder's text tells those three apart without a fiber
        /// identity, which `std.Io` does not hand a Service (ADR 107): a
        /// `BEGIN` is a transaction, a long `SELECT` is the work itself, and
        /// a one-line statement held past `timeout_ms` is waiting for a
        /// thread rather than for the database.
        fn gaveUp(self: *Self, bound: *core.Limits.Bound, want: enum { writer, reader }) wire.Error {
            if (!bound.fired()) return self.cancelled();
            switch (want) {
                .writer => std.log.warn(
                    "nilo_sql: a statement waited {d}ms for the writer connection and gave up; " ++
                        "it is held by `{s}`. A `BEGIN` is a transaction, and a `db.…` call " ++
                        "inside a handler holding a `tx` waits for itself. A short statement " ++
                        "holding it this long is waiting for a thread, not for the database. " ++
                        "`timeout_ms` is the bound.",
                    .{ self.queue_timeout_ms, shown(self.conns[0].holder) },
                ),
                .reader => std.log.warn(
                    "nilo_sql: a statement waited {d}ms for a reader connection and gave up, " ++
                        "with all {d} of them busy, held by {f}. Raise `size`, or shorten what " ++
                        "a request holds one for. `timeout_ms` is the bound.",
                    .{ self.queue_timeout_ms, self.conns.len - 1, Holders{ .conns = self.conns[1..] } },
                ),
            }
            return error.TimedOut;
        }

        /// The readers' holders written straight into the log line, so naming
        /// four statements costs no buffer on the frame of a fiber that is
        /// about to be parked (ADR 062).
        const Holders = struct {
            conns: []const Conn,

            pub fn format(self: Holders, w: *std.Io.Writer) std.Io.Writer.Error!void {
                for (self.conns, 0..) |conn, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print("`{s}`", .{shown(conn.holder)});
                }
            }
        };

        /// A statement as the log line shows it: long enough to recognise,
        /// short enough that a generated `SELECT` of forty columns stays one
        /// line.
        fn shown(text: []const u8) []const u8 {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            return trimmed[0..@min(trimmed.len, 120)];
        }

        /// Uncancelable, and it has to be: this runs from `Rows.close` and
        /// from a `defer` on the way out of a failing transaction, where
        /// giving up would leak a connection for the life of the process.
        /// **Which queue is woken is decided by which connection came back**,
        /// and the two cannot serve each other: there is exactly one writer,
        /// so a returning reader can satisfy nobody in `takeWriter`, and a
        /// returning writer can satisfy nobody in `takeReader`.
        fn release(self: *Self, at: usize) void {
            self.lock.lockUncancelable(self.io);
            self.conns[at].busy = false;
            self.lock.unlock(self.io);
            if (at == 0) self.free_writer.broadcast(self.io) else self.free_reader.broadcast(self.io);
        }

        /// Which connection a statement belongs on.
        ///
        /// For everything this module generates the answer is exact: the text
        /// is a comptime constant this module wrote, and it starts with the
        /// verb. For `db.raw` it is a guess, and the guess is safe because a
        /// reader is open read-only — a `raw` that writes and looks like a
        /// read is refused by SQLite with `ReadOnly` on its first call rather
        /// than answering from the wrong snapshot (ADR 065).
        ///
        /// `WITH` goes to the writer. A CTE may write, the keyword does not
        /// say, and being wrong in that direction costs a report the writer's
        /// time rather than costing correctness.
        fn wantsWriter(sql: []const u8) bool {
            const text = std.mem.trimStart(u8, sql, " \t\r\n");
            return !(std.ascii.startsWithIgnoreCase(text, "SELECT") or
                std.ascii.startsWithIgnoreCase(text, "PRAGMA") or
                // A plan is prepared and never stepped through, so it writes
                // nothing whatever it explains (`db.rawExplain`).
                std.ascii.startsWithIgnoreCase(text, "EXPLAIN"));
        }

        // -- statements --------------------------------------------------

        /// The prepared statement for `sql` on connection `at`, bound to
        /// `values`, plus whether it came from the cache.
        ///
        /// A cached statement is reset and its bindings cleared **when it is
        /// let go** (`Rows.close`, `execOn`), and here only if SQLite still
        /// calls it busy: SQLite keeps the previous bindings otherwise, so a
        /// statement reused with fewer parameters would silently carry the
        /// last request's values.
        fn stmtOn(
            self: *Self,
            at: usize,
            sql: []const u8,
            plan: ?[]const u8,
            values: anytype,
        ) wire.Error!struct { zqlite.Stmt, bool } {
            const conn = &self.conns[at];
            // The values were held to `checked` by the caller, before any
            // `bind`: a refusal there is not a failed statement and must not
            // mark a transaction aborted.
            // Once, at the top, rather than at the four `bind` calls below —
            // a conversion applied at three of four sites is a bug that only
            // shows up on the fourth path (`blobbed`).
            const args = blobbed(values);

            if (plan) |name| {
                if (conn.kept.get(name)) |stmt| {
                    // **Released clean, so nothing to undo on the way in.**
                    // `Rows.close` and `execOn` reset a kept statement and
                    // clear its bindings before it is anyone's again, which
                    // this used to do a second time on every use. Left is
                    // the check that it was: a statement SQLite still calls
                    // busy is reset, with its bindings, as it always was.
                    if (zqlite.c.sqlite3_stmt_busy(stmt.stmt) != 0) {
                        stmt.reset() catch return error.QueryFailed;
                        stmt.clearBindings() catch return error.QueryFailed;
                    }
                    stmt.bind(args) catch |err| {
                        // A bind that stops partway leaves the values it got
                        // to in a statement that goes back in the cache.
                        stmt.reset() catch {};
                        stmt.clearBindings() catch {};
                        return translate(conn.handle, err);
                    };
                    return .{ stmt, true };
                }
                const stmt = prepareOne(conn.handle, sql) catch |err|
                    return translate(conn.handle, err);
                conn.kept.put(self.gpa, name, stmt) catch {
                    // A cache that cannot grow is a slower Wire, not a broken
                    // one: the statement still runs, it is just finalised
                    // afterwards like a `raw`.
                    stmt.bind(args) catch |err| return translate(conn.handle, err);
                    return .{ stmt, false };
                };
                stmt.bind(args) catch |err| return translate(conn.handle, err);
                return .{ stmt, true };
            }

            const stmt = prepareOne(conn.handle, sql) catch |err| return translate(conn.handle, err);
            stmt.bind(args) catch |err| {
                stmt.deinit();
                return translate(conn.handle, err);
            };
            return .{ stmt, false };
        }

        fn execOn(
            self: *Self,
            at: usize,
            sql: []const u8,
            plan: ?[]const u8,
            values: anytype,
        ) wire.Error!usize {
            const conn = &self.conns[at];
            const stmt, const kept = try self.stmtOn(at, sql, plan, values);
            defer if (kept) {
                stmt.reset() catch {};
                stmt.clearBindings() catch {};
            } else stmt.deinit();

            // **`changes()` alone answers the last DML this connection ran**,
            // so a `CREATE INDEX` or a `PRAGMA` after an `UPDATE` of 7 rows
            // answered 7, where Postgres's command tag says 0. The total
            // moves only when a statement changed a row, so a statement that
            // left it where it was changed none.
            const before = zqlite.c.sqlite3_total_changes64(conn.handle.conn);
            onThread(zqlite.Stmt.stepToCompletion, .{stmt}) catch |err|
                return translate(conn.handle, err);
            if (zqlite.c.sqlite3_total_changes64(conn.handle.conn) == before) return 0;
            return conn.handle.changes();
        }

        /// A statement with no parameters and no rows — `COMMIT`, `SAVEPOINT`.
        fn command(self: *Self, at: usize, sql: [*:0]const u8) wire.Error!void {
            const conn = self.conns[at].handle;
            onThread(zqlite.Conn.execNoArgs, .{ conn, sql }) catch |err|
                return translate(conn, err);
        }

        /// Run whatever SQLite is going to block on, where the caller said to
        /// run it. The `switch` is over a comptime value, so one arm survives
        /// compilation and the other is not analysed.
        inline fn onThread(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
            return switch (comptime opts.threading) {
                .in_fiber => @call(.auto, f, args),
                // Reserved rather than queued: the statement holds its
                // connection while it waits, and behind a slow call on the
                // pool's one busy worker it held the writer from everyone
                // (zio#745).
                .hop => |Engine| Engine.blockingReserved(f, args),
            };
        }

        // -- the contract ------------------------------------------------

        pub fn run(
            self: *Self,
            arena: std.mem.Allocator,
            sql: []const u8,
            values: anytype,
            plan: ?[]const u8,
            problem: ?*?wire.Problem,
        ) wire.Error!Rows {
            const at = if (wantsWriter(sql)) try self.takeWriter(sql) else try self.takeReader(sql);
            errdefer self.release(at);
            try checked(values, problem);
            const stmt, const kept = self.stmtOn(at, sql, plan, values) catch |err| {
                self.said(at, err, arena, problem);
                return err;
            };
            return .{ .wire = self, .at = at, .stmt = stmt, .kept = kept };
        }

        pub fn exec(
            self: *Self,
            arena: std.mem.Allocator,
            sql: []const u8,
            values: anytype,
            plan: ?[]const u8,
            problem: ?*?wire.Problem,
        ) wire.Error!usize {
            const at = try self.takeWriter(sql);
            defer self.release(at);
            try checked(values, problem);
            return self.execOn(at, sql, plan, values) catch |err| {
                self.said(at, err, arena, problem);
                return err;
            };
        }

        /// The values a statement is given, held to what SQLite can store
        /// (`intsFit`, `floatsKept`) before anything is prepared or bound.
        ///
        /// **A value refused here is not a statement that failed.** Postgres's
        /// client refuses the same values before a byte is sent and the
        /// transaction goes on; a `Tx` here that marked itself aborted (`Conn.aborted`)
        /// refused every statement after it and rolled back at commit, which
        /// a handler tested on SQLite would hear and one on Postgres would not.
        /// So this is called ahead of `stmtOn` by the four entry points and
        /// touches no flag.
        fn checked(
            values: anytype,
            problem: ?*?wire.Problem,
        ) wire.Error!void {
            // **Neither of these reached SQLite, so neither reads its `errmsg`**,
            // which holds whatever the connection's last statement said: an
            // INSERT refused on a unique, then a value past an `i64` on the
            // same writer, would answer with the unique's constraint and make
            // `sql.violated` true. The Zig error's name is all there is.
            intsFit(values) catch |err| {
                if (problem) |slot| slot.* = .{ .message = @errorName(err) };
                return err;
            };
            floatsKept(values) catch |err| {
                if (problem) |slot| slot.* = .{ .message = @errorName(err) };
                return err;
            };
        }

        /// What SQLite said about the statement that just failed, left where a
        /// program can read it rather than only in the log
        /// ([ADR 117](../docs/adr/117-a-statement-that-failed-says-what-the-database-said.md)).
        ///
        /// **Three of `Problem`'s fields stay empty here, and that is said
        /// rather than guessed at.** SQLite has no SQLSTATE, no severity word
        /// and no separate hint — `sqlite3_errmsg` is the whole of what it
        /// offers — so inventing a code would be this module making something
        /// up in a field whose only value is that it came from the database.
        ///
        /// The text is copied into the arena because it points at memory the
        /// connection owns and the connection goes back to the pool on the
        /// next line. `"not an error"` is what `errmsg` answers when the
        /// failure never reached SQLite at all — a bind zqlite refused, which
        /// is the case this whole seam exists for — so that answer is dropped
        /// for the Zig error's name, which does say something.
        fn said(
            self: *Self,
            at: usize,
            err: wire.Error,
            arena: std.mem.Allocator,
            problem: ?*?wire.Problem,
        ) void {
            const slot = problem orelse return;
            const text = std.mem.span(self.conns[at].handle.lastError());
            if (text.len == 0 or std.mem.eql(u8, text, "not an error")) {
                slot.* = .{ .message = @errorName(err) };
                return;
            }
            const message = arena.dupe(u8, text) catch @errorName(err);
            slot.* = .{ .message = message, .constraint = constraintOf(message) };
        }

        /// What SQLite's message names after `constraint failed: `. The
        /// columns for a key or a unique, `users.email`, since SQLite does
        /// not report an index's name; the name for a named check. Empty for
        /// a foreign key, which SQLite reports without saying which one.
        fn constraintOf(message: []const u8) []const u8 {
            const marker = "constraint failed: ";
            const at = std.mem.indexOf(u8, message, marker) orelse return "";
            return message[at + marker.len ..];
        }

        /// What SQLite said about the step `next` just failed, for the
        /// `Db` to hand the watcher and `sql.problem` (ADR 117). A step is
        /// where an `INSERT … RETURNING` meets its constraint.
        pub fn stepProblem(self: *Self, rows: *const Rows, err: wire.Error, arena: std.mem.Allocator) ?wire.Problem {
            var slot: ?wire.Problem = null;
            self.said(rows.at, err, arena, &slot);
            return slot;
        }

        pub fn next(self: *Self, rows: *Rows) wire.Error!bool {
            const stmt = rows.stmt;
            return onThread(zqlite.Stmt.step, .{stmt}) catch |err| {
                // Stepping is where most of SQLite's failures arrive — an
                // `INSERT … RETURNING` meets its constraint here, not when it
                // is prepared — so a result set borrowed from a transaction
                // marks it aborted from here (`Conn.aborted`).
                if (!rows.owns_conn) self.conns[rows.at].aborted = true;
                return translate(self.conns[rows.at].handle, err);
            };
        }

        /// How many columns the row `next` just stopped on has.
        ///
        /// **Only answerable once a row is under it**, which is what decides
        /// where `fill` asks (ADR 106): zqlite's `columnCount` is
        /// `sqlite3_data_count`, and that is `0` on a prepared statement
        /// nobody has stepped, on one that has run off the end, and on one
        /// that answers with no rows at all. `sqlite3_column_count` is the
        /// one settled by preparing, and zqlite does not expose it — asking
        /// SQLite for it directly would be reaching past the driver for a
        /// number the caller can get by pulling the row it was going to pull
        /// anyway.
        pub fn width(self: *Self, rows: *const Rows) usize {
            _ = self;
            const n = rows.stmt.columnCount();
            return if (n < 0) 0 else @intCast(n);
        }

        /// Column `col` of the row `next` just stopped on, as `T`.
        ///
        /// A `[]const u8` here points into SQLite's own buffer and dies at the
        /// next `next` — the same rule pg.zig has, which is why `wire.zig`
        /// passes it along unwrapped and `db.zig` copies before anybody sees
        /// it.
        pub fn read(self: *Self, rows: *const Rows, comptime T: type, col: usize) wire.Error!T {
            _ = self;
            const stmt = rows.stmt;

            const optional = @typeInfo(T) == .optional;
            const Inner = if (optional) @typeInfo(T).optional.child else T;

            // **Asked for every column rather than only the optional ones,
            // and that is the fix** (ADR 094). The test used to live inside
            // `if (optional)`, so a NULL arriving in a column the Row says is
            // not optional fell straight through to the reads below — where
            // `stmt.int` answers 0 and `stmt.text` answers the empty string,
            // because zqlite's `text` returns `""` whenever
            // `sqlite3_column_bytes` is zero. A wrong answer that looks like a
            // right one, which is what the cast below already refuses for an
            // integer too wide for its field.
            //
            // The startup check catches this when the table declares the
            // column nullable. It cannot catch a view, which answers `UNKNOWN`
            // and is skipped by design (ADR 050), and it does not run at all
            // for a `Db` nobody called `checking` on.
            //
            // What it costs is one `sqlite3_column_type` — a couple of loads,
            // no allocation — per non-optional column per row. The optional
            // ones were already paying it.
            const class = stmt.columnType(col);
            if (class == .null) {
                if (optional) return null;
                // `warn` rather than `err` for the reason `db.wireOf`'s is
                // one: `std.log.err` fails the test runner for every test
                // that provokes it, which is how a diagnostic ends up deleted
                // rather than fixed. The error is what the caller acts on.
                std.log.warn(
                    "nilo_sql: column {d} came back NULL and the Row reads it as {s}, " ++
                        "which cannot hold one. Make the field optional, or make the " ++
                        "column NOT NULL. A view is the case the startup check cannot " ++
                        "see (ADR 050).",
                    .{ col, @typeName(Inner) },
                );
                return error.QueryFailed;
            }

            // **`sqlite3_column_blob`, not `sqlite3_column_text`.** Asking
            // for a BLOB as text makes SQLite convert the column in place,
            // which changes what a pointer taken earlier points at and reads
            // the bytes as though they were characters. The two calls are not
            // interchangeable, which is why `WireRead` keeps the type this far
            // instead of flattening it to `[]const u8` like everything else.
            if (comptime Inner == wire.Bytes) return .{ .bytes = stmt.blob(col) };

            // **A `Date` is the ten characters here**, which is what SQLite
            // stores for it and what `sqlite3_strftime` and friends read. The
            // Postgres Wire reads the same column as four bytes, and neither
            // reads it as a number — which is why `WireRead` keeps the type
            // this far (ADR 181).
            if (comptime Inner == types.Date) return types.Date.nilo_parse(stmt.text(col)) orelse
                error.QueryFailed;

            // **The storage class is asked before a number is read**, because
            // `sqlite3_column_int64` and `sqlite3_column_double` convert
            // whatever the value is without a word: text in an INTEGER column
            // reads 0, a REAL 2.7 read as an integer is 2, and a `DATETIME
            // DEFAULT CURRENT_TIMESTAMP` read as a `Timestamp` is the year. A
            // moment stored as text is decided (ADR 067); a number read out of
            // text is not, so it is refused like the NULL above. An integer is
            // let into a float, which loses nothing a Row could have kept.
            switch (@typeInfo(Inner)) {
                .bool, .int => if (class != .int) return wrongClass(Inner, col, class),
                .float => if (class != .int and class != .float) return wrongClass(Inner, col, class),
                else => {},
            }

            return switch (@typeInfo(Inner)) {
                // **Anything but 0 is true**, which is what `WHERE flag` says
                // about the same value. zqlite's `boolean` is `== 1`, so a 2
                // read false out of a row the filter had called true.
                .bool => stmt.int(col) != 0,
                .int => std.math.cast(Inner, stmt.int(col)) orelse error.QueryFailed,
                .float => try narrowed(Inner, col, stmt.float(col)),
                .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8)
                    stmt.text(col)
                else
                    error.QueryFailed,
                else => error.QueryFailed,
            };
        }

        /// **A double read into a narrower float must survive the trip.**
        /// SQLite has one float width, so it cannot say `float4` the way the
        /// Postgres Wire's column does; what it can say is whether this value
        /// fits. Postgres refuses every `float8` read into an `f32`
        /// (`notANumber`) and answers `QueryFailed` with a warning; this
        /// answers the same for a value the `f32` would round or overflow,
        /// where the `@floatCast` it replaces returned the wrong number
        /// without a word. A value an `f32` holds exactly, such as one that
        /// was written from an `f32`, reads as it always did.
        fn narrowed(comptime F: type, col: usize, wide: f64) wire.Error!F {
            const narrow: F = @floatCast(wide);
            if (F == f64 or @as(f64, @floatCast(narrow)) == wide) return narrow;
            std.log.warn(
                "nilo_sql: column {d} holds {d}, which the Row's " ++ @typeName(F) ++ " cannot hold " ++
                    "exactly. Widen the field to f64, or store a value that fits.",
                .{ col, wide },
            );
            return error.QueryFailed;
        }

        fn wrongClass(comptime Inner: type, col: usize, class: zqlite.ColumnType) wire.Error {
            std.log.warn(
                "nilo_sql: column {d} holds {s} and the Row reads it as {s}. SQLite " ++
                    "stores what it is given whatever the column's type says; write the " ++
                    "value as the field's type, or read the column into a field that " ++
                    "holds {s} (ADR 067).",
                .{ col, @tagName(class), @typeName(Inner), @tagName(class) },
            );
            return error.QueryFailed;
        }

        /// **Refused.** SQLite has no array type, so there is no column for
        /// this to read. The Dialect says so first — `arrayOf` answers null,
        /// which makes a list column a Refusal while compiling and the schema
        /// check decline it at startup — so reaching here means both of those
        /// were bypassed.
        pub fn readList(
            self: *Self,
            rows: *const Rows,
            comptime L: type,
            col: usize,
            arena: std.mem.Allocator,
        ) wire.Error!L {
            _ = .{ self, rows, col, arena };
            @compileError(
                "nilo: a list column cannot be read on the sqlite dialect (" ++
                    @typeName(L) ++ ").\n" ++
                    "  SQLite has no array type. A list belongs in its own table, or in a " ++
                    "TEXT column your own code encodes.",
            );
        }

        pub fn drain(self: *Self, rows: *Rows) void {
            _ = self;
            // Stepping to the end is what the Postgres Wire has to do; here
            // `reset` releases the statement's read transaction outright, so
            // the rows nobody wanted cost nothing at all.
            rows.close();
        }

        /// Open a transaction, and take the connection its statements will
        /// travel down.
        ///
        /// **A read-only transaction takes a reader**, which is worth more
        /// here than the flag is on Postgres: a report inside `begin(.{
        /// .read_only = true })` runs beside writes instead of stopping them.
        ///
        /// A writing transaction takes the writer with `BEGIN IMMEDIATE`.
        /// Deferred would take the write lock at the first write instead,
        /// which is where SQLite's upgrade deadlock lives when a second
        /// process is on the same file.
        pub fn begin(self: *Self, arena: std.mem.Allocator, comptime opts_: wire.Begin) wire.Error!Tx {
            _ = arena;
            comptime checkIsolation(opts_);

            const begin_text = if (opts_.read_only) "BEGIN" else "BEGIN IMMEDIATE";
            const at = if (opts_.read_only) try self.takeReader(begin_text) else try self.takeWriter(begin_text);
            errdefer self.release(at);
            if (opts_.rebuilding) {
                if (comptime opts_.read_only) @compileError(
                    "nilo: a transaction cannot be both .read_only and .rebuilding.\n" ++
                        "  `.rebuilding` is for a version that drops and remakes tables, which is a write.",
                );
                // Before the BEGIN, because inside a transaction SQLite
                // accepts this pragma and does nothing with it.
                try self.command(at, "PRAGMA foreign_keys = OFF");
            }
            errdefer if (opts_.rebuilding) self.command(at, "PRAGMA foreign_keys = ON") catch {};
            try self.command(at, if (opts_.read_only) "BEGIN" else "BEGIN IMMEDIATE");
            self.conns[at].aborted = false;
            return .{ .wire = self, .at = at, .rebuilding = opts_.rebuilding };
        }

        /// Whether `PRAGMA foreign_key_check` finds any row pointing at a row
        /// that is not there. One row is enough to refuse, so only one is read.
        ///
        /// **Only the keys the version could have broken.** `dropped` are the
        /// tables the transaction dropped and made again; a violation counts
        /// when it is a row of one of them or a row pointing at one. An old
        /// violation in a table the version never touched used to fail every
        /// rebuild with `ForeignKeyViolated`. A version whose drops could not
        /// be read, or that dropped none the statements name, checks every
        /// key, as it always did.
        fn brokenReference(
            self: *Self,
            at: usize,
            arena: std.mem.Allocator,
            dropped: []const []const u8,
            unread: bool,
        ) wire.Error!bool {
            const conn = self.conns[at].handle;
            const text = foreignKeyCheck(arena, dropped, unread) catch return error.QueryFailed;
            return onThread(firstBroken, .{ conn, text }) catch |err| translate(conn, err);
        }

        fn firstBroken(conn: zqlite.Conn, text: []const u8) !bool {
            const found = try conn.row(text, .{}) orelse return false;
            found.deinit();
            return true;
        }

        /// `SELECT 1 FROM pragma_foreign_key_check`, narrowed to the tables
        /// named when there are any. A name is a SQL literal with its quotes
        /// doubled, and compared without regard to case, as SQLite does.
        /// `migrations.zig`'s twin of a version writes the same filter.
        fn foreignKeyCheck(arena: std.mem.Allocator, dropped: []const []const u8, unread: bool) ![]const u8 {
            const whole = "SELECT 1 FROM pragma_foreign_key_check LIMIT 1";
            if (unread or dropped.len == 0) return whole;
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(arena, "SELECT 1 FROM pragma_foreign_key_check WHERE \"table\" COLLATE NOCASE IN (");
            for (dropped, 0..) |name, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try out.append(arena, '\'');
                for (name) |ch| {
                    if (ch == '\'') try out.append(arena, '\'');
                    try out.append(arena, ch);
                }
                try out.append(arena, '\'');
            }
            try out.appendSlice(arena, ") OR \"parent\" COLLATE NOCASE IN (");
            for (dropped, 0..) |name, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try out.append(arena, '\'');
                for (name) |ch| {
                    if (ch == '\'') try out.append(arena, '\'');
                    try out.append(arena, ch);
                }
                try out.append(arena, '\'');
            }
            try out.appendSlice(arena, ") LIMIT 1");
            return out.items;
        }

        /// SQLite gives every transaction snapshot isolation and serialises
        /// the writers, so `.serializable` is what it always does and the
        /// weaker two cannot be asked for — there is nothing to relax.
        ///
        /// Refused while compiling rather than ignored, which is the whole
        /// reason `wire.Begin` is comptime: a transaction that asked for
        /// `read_committed` and silently got something else is a correctness
        /// difference nobody would see.
        fn checkIsolation(comptime opts_: wire.Begin) void {
            const level = opts_.isolation orelse return;
            if (level == .serializable) return;
            @compileError(
                "nilo: the sqlite dialect has no ." ++ @tagName(level) ++ " isolation level.\n" ++
                    "  SQLite gives every transaction a snapshot and serialises the writers, " ++
                    "which is .serializable — there is no weaker level to ask for.\n" ++
                    "  Leave `.isolation` out, or write `.isolation = .serializable` to say " ++
                    "you meant it.",
            );
        }

        /// `name` with `"db".` in front of every occurrence, or `QueryFailed`
        /// when there is none — a query that has stopped naming the relation
        /// this expects to qualify is a query this function no longer
        /// understands, and saying so beats asking the wrong database.
        fn qualifyEvery(
            buf: []u8,
            query: []const u8,
            comptime name: []const u8,
            db_name: []const u8,
        ) wire.Error![]const u8 {
            var written: usize = 0;
            var rest = query;
            var qualified = false;
            while (std.mem.indexOf(u8, rest, name)) |at| {
                const piece = std.fmt.bufPrint(buf[written..], "{s}\"{s}\".{s}", .{
                    rest[0..at], db_name, name,
                }) catch return error.QueryFailed;
                written += piece.len;
                rest = rest[at + name.len ..];
                qualified = true;
            }
            if (!qualified) return error.QueryFailed;
            const tail = std.fmt.bufPrint(buf[written..], "{s}", .{rest}) catch
                return error.QueryFailed;
            return buf[0 .. written + tail.len];
        }

        /// The columns the database says a table has.
        ///
        /// **The schema goes into the text rather than into a parameter**, and
        /// that is the seam's one loose joint — written down in ADR 055
        /// before this file existed. SQLite's `pragma_table_info` is a
        /// table-valued function and a schema qualifies the *function's* name,
        /// where Postgres puts it in a `WHERE` and binds it.
        ///
        /// **Every occurrence, not the first.** `dialect.SQLite.introspect`
        /// names `pragma_table_info` twice since ADR 050 — once in the `FROM`
        /// and once in the subquery that counts a table's primary-key columns
        /// — and the rewrite this used to do qualified whichever came first in
        /// the text. That would have asked the attached database for the
        /// columns and `main` for the key, which is one question answered by
        /// two databases: a table absent from `main` would report no primary
        /// key at all, and every `INTEGER PRIMARY KEY` in an attached schema
        /// would go back to being reported as nullable.
        pub fn columnsOf(
            self: *Self,
            arena: std.mem.Allocator,
            query: []const u8,
            schema: ?[]const u8,
            table: []const u8,
        ) wire.Error![]const wire.Column {
            // Twice the query, plus a qualifier at each occurrence. The query
            // is a comptime constant of this module's own and the schema comes
            // from a Row's `nilo_table`, so nothing here is the client's — but
            // `bufPrint` still answers `QueryFailed` rather than truncating.
            //
            // **Two names, not one.** `sqlite_master` is the second relation
            // in the query — the `LEFT JOIN` that says whether the name is a
            // view — and it went unqualified for a cycle after the first
            // rewrite, so a Row over a view in an attached database asked
            // `main.sqlite_master`, found nothing, and got exactly the
            // failure ADR 050 was written to remove.
            var pragma_buf: [1024]u8 = undefined;
            var master_buf: [1024]u8 = undefined;
            const text = try qualifiedQuery(&pragma_buf, &master_buf, query, schema);

            // No problem slot: this runs once per Row while the server is
            // starting, and the one caller already has a sentence for a check
            // it could not run.
            var rows = try self.run(arena, text, .{table}, null, null);
            defer rows.close();
            return self.columnList(arena, &rows);
        }

        /// `columnsOf` for a list of tables of one schema in one query
        /// (`dialect.SQLite.introspect_all`), the answer cut into one list per
        /// table in the order asked. The names travel as one JSON array, the
        /// way this Dialect binds every list, and the schema goes into the
        /// text exactly as `columnsOf` puts it (`qualifiedQuery`). The buffers
        /// are twice `columnsOf`'s because the text is longer and is
        /// qualified at every occurrence; a schema name that does not fit
        /// answers `QueryFailed` rather than a truncated query.
        pub fn columnsOfMany(
            self: *Self,
            arena: std.mem.Allocator,
            query: []const u8,
            schema: ?[]const u8,
            tables: []const []const u8,
        ) wire.Error![]const []const wire.Column {
            var pragma_buf: [2048]u8 = undefined;
            var master_buf: [2048]u8 = undefined;
            const text = try qualifiedQuery(&pragma_buf, &master_buf, query, schema);
            const names: []const u8 = std.json.Stringify.valueAlloc(arena, tables, .{}) catch
                return error.QueryFailed;

            var rows = try self.run(arena, text, .{names}, null, null);
            defer rows.close();

            var found: std.ArrayList(wire.Keyed(wire.Column)) = .empty;
            while (try self.next(&rows)) {
                const table = try self.read(&rows, []const u8, 0);
                const name = try self.read(&rows, []const u8, 1);
                const udt = try self.read(&rows, []const u8, 2);
                const nullable = try self.read(&rows, []const u8, 3);
                found.append(arena, .{
                    .key = arena.dupe(u8, table) catch return error.QueryFailed,
                    .item = .{
                        .name = arena.dupe(u8, name) catch return error.QueryFailed,
                        .udt = arena.dupe(u8, udt) catch return error.QueryFailed,
                        .nullable = if (std.mem.eql(u8, nullable, "YES"))
                            true
                        else if (std.mem.eql(u8, nullable, "NO"))
                            false
                        else
                            null,
                    },
                }) catch return error.QueryFailed;
            }
            // Folded: `pragma_table_info` finds `Users` for `users`, so the
            // name the catalog returns may not be the one asked for.
            return wire.cutByName(wire.Column, arena, tables, found.items, true);
        }

        /// `query` with the schema in front of the two relations it reads,
        /// or as it is when the table has no schema of its own.
        fn qualifiedQuery(
            pragma_buf: []u8,
            master_buf: []u8,
            query: []const u8,
            schema: ?[]const u8,
        ) wire.Error![]const u8 {
            const db_name = schema orelse return query;
            const with_pragma = try qualifyEvery(pragma_buf, query, "pragma_table_info", db_name);
            return qualifyEvery(master_buf, with_pragma, "sqlite_master", db_name);
        }

        /// The rows of the introspection query as columns. Shared by the
        /// Wire's `columnsOf` and the one on `Tx`, so a migration reads the
        /// table through the connection it already holds (ADR 123).
        fn columnList(self: *Self, arena: std.mem.Allocator, rows: *Rows) wire.Error![]const wire.Column {
            var found: std.ArrayList(wire.Column) = .empty;
            while (try self.next(rows)) {
                const name = try self.read(rows, []const u8, 0);
                const udt = try self.read(rows, []const u8, 1);
                const nullable = try self.read(rows, []const u8, 2);
                found.append(arena, .{
                    .name = arena.dupe(u8, name) catch return error.QueryFailed,
                    .udt = arena.dupe(u8, udt) catch return error.QueryFailed,
                    .nullable = if (std.mem.eql(u8, nullable, "YES"))
                        true
                    else if (std.mem.eql(u8, nullable, "NO"))
                        false
                    else
                        null,
                }) catch return error.QueryFailed;
            }
            return found.toOwnedSlice(arena) catch return error.QueryFailed;
        }

        /// What `sql` would answer, without stepping it: the affinity of
        /// each column's declared type, which is what SQLite converts a
        /// value by and so what `dialect.SQLite.reads` is written in
        /// (ADR 233).
        ///
        /// **Only a column read straight out of a table has one.** SQLite's
        /// types belong to values, not to expressions, so `count(*)`, a
        /// `CAST` and anything computed come back unjudged. And `nulls` asks
        /// for nothing here: SQLite has no plan that names a join's far side.
        /// What this catches is a `Str` field over an `INTEGER` column, which
        /// zqlite would otherwise read as the digits.
        pub fn describe(
            self: *Self,
            arena: std.mem.Allocator,
            sql: []const u8,
            nulls: bool,
        ) wire.Error!?[]const wire.Described {
            _ = nulls;
            const at = if (wantsWriter(sql)) try self.takeWriter(sql) else try self.takeReader(sql);
            defer self.release(at);
            const conn = self.conns[at].handle;
            const stmt = prepareOne(conn, sql) catch |err| return translate(conn, err);
            defer stmt.deinit();

            const count: usize = @intCast(zqlite.c.sqlite3_column_count(stmt.stmt));
            const out = arena.alloc(wire.Described, count) catch return error.QueryFailed;
            for (out, 0..) |*column, i| {
                column.* = .{ .udt = null };
                const declared = zqlite.c.sqlite3_column_decltype(stmt.stmt, @intCast(i)) orelse continue;
                const affinity = dialect.SQLite.affinityOf(std.mem.span(declared)) orelse continue;
                column.* = .{ .udt = affinity, .textual = std.mem.eql(u8, affinity, "TEXT") };
            }
            return out;
        }

        /// Never called: `dialect.SQLite.enum_values` is null, because SQLite
        /// has no enum type to hold a Zig enum against. Here so the Wire
        /// contract is one list rather than one with an exception in it.
        pub fn labelsOf(
            self: *Self,
            arena: std.mem.Allocator,
            query: []const u8,
            type_name: []const u8,
        ) wire.Error![]const []const u8 {
            _ = self;
            _ = arena;
            _ = query;
            _ = type_name;
            return &.{};
        }

        /// Never called, for the reason `labelsOf` is not: one empty answer
        /// per name.
        pub fn labelsOfMany(
            self: *Self,
            arena: std.mem.Allocator,
            query: []const u8,
            type_names: []const []const u8,
        ) wire.Error![]const []const []const u8 {
            _ = self;
            _ = query;
            const out = arena.alloc([]const []const u8, type_names.len) catch return error.QueryFailed;
            for (out) |*slot| slot.* = &.{};
            return out;
        }
    };
}

/// The parameter tuple with every `wire.Bytes` in it turned into the wrapper
/// zqlite binds a blob from.
///
/// **This file is the only one allowed to name `zqlite.Blob`**, which is the
/// whole reason the conversion happens here rather than in `db.zig`: `Blob` is
/// compared by identity inside the driver, so a structurally identical type of
/// nilo's would bind as text and store the bytes in a TEXT column that reads
/// back looking almost right.
///
/// It answers the caller's own tuple type when nothing needs converting, which
/// is every statement that carries no binary column — so this costs nothing to
/// the programs that do not use one. The same shape `db.rawValuesOf` has, and
/// for the same reason.
fn Blobbed(comptime V: type) type {
    comptime {
        if (@typeInfo(V) != .@"struct") return V;
        const info = @typeInfo(V).@"struct";
        var out: [info.field_names.len]type = undefined;
        var changed = false;
        for (info.field_types, 0..) |f_type, i| {
            out[i] = switch (f_type) {
                wire.Bytes => zqlite.Blob,
                ?wire.Bytes => ?zqlite.Blob,
                else => f_type,
            };
            if (out[i] != f_type) changed = true;
        }
        if (!changed) return V;
        const frozen = out;
        return @Tuple(&frozen);
    }
}

/// Every integer in `values` checked into `i64`, which is all SQLite stores.
///
/// zqlite binds an integer with `@intCast`, so a `u64` of 2^63 or more, an
/// `?offset=9223372036854775808` read into a `usize`, is a panic in Debug and
/// ReleaseSafe and undefined behaviour in ReleaseFast: a request could take
/// the server down. pg.zig answers `IntWontFit` for the same value, and this
/// answers the same way. Unrolled while compiling, so a statement holding no
/// integer wider than `i64` costs nothing here.
fn intsFit(values: anytype) wire.Error!void {
    const info = @typeInfo(@TypeOf(values)).@"struct";
    inline for (info.field_names, info.field_types) |f_name, f_type| {
        if (comptime wideInt(f_type)) |I| {
            const held: ?I = @field(values, f_name);
            if (held) |n| if (std.math.cast(i64, n) == null) {
                std.log.warn(
                    "nilo_sql: {d} was refused before it was bound: SQLite stores an " ++
                        "integer as a signed 64-bit number, and this one does not fit.",
                    .{n},
                );
                return error.QueryFailed;
            };
        }
    }
}

/// Every float in `values` checked for a NaN, which SQLite cannot store.
///
/// `sqlite3_bind_double` binds a NaN as NULL, so a NOT NULL column answered
/// `NotNullViolated` for a value that was never null and a nullable one read
/// back `null`, where Postgres keeps the NaN. Refused here, before it is
/// bound, with a message that names it. An infinity is not refused: SQLite
/// stores and reads it back as itself, the same as Postgres does.
fn floatsKept(values: anytype) wire.Error!void {
    const info = @typeInfo(@TypeOf(values)).@"struct";
    inline for (info.field_names, info.field_types) |f_name, f_type| {
        const F = switch (@typeInfo(f_type)) {
            .float => f_type,
            .optional => |o| if (@typeInfo(o.child) == .float) o.child else continue,
            else => continue,
        };
        const held: ?F = @field(values, f_name);
        if (held) |x| if (std.math.isNan(x)) {
            std.log.warn(
                "nilo_sql: a NaN was refused before it was bound: SQLite stores a NaN " ++
                    "as NULL, so the row would not hold the value it was given.",
                .{},
            );
            return error.QueryFailed;
        };
    }
}

/// The integer type behind `T`, optional or not, when it holds a value `i64`
/// cannot: a `u64`, a `usize`, an `i128`. Null for everything else.
fn wideInt(comptime T: type) ?type {
    const I = switch (@typeInfo(T)) {
        .int => T,
        .optional => |o| if (@typeInfo(o.child) == .int) o.child else return null,
        else => return null,
    };
    if (std.math.minInt(I) >= std.math.minInt(i64) and std.math.maxInt(I) <= std.math.maxInt(i64))
        return null;
    return I;
}

fn blobbed(values: anytype) Blobbed(@TypeOf(values)) {
    const V = @TypeOf(values);
    if (comptime Blobbed(V) == V) return values;

    var out: Blobbed(V) = undefined;
    const v_info = @typeInfo(V).@"struct";
    inline for (v_info.field_names, v_info.field_types, 0..) |f_name, f_type, i| {
        const held = @field(values, f_name);
        out[i] = switch (f_type) {
            wire.Bytes => zqlite.blob(held.bytes),
            ?wire.Bytes => if (held) |b| zqlite.blob(b.bytes) else null,
            else => held,
        };
    }
    return out;
}

/// `conn.prepare`, and a refusal of a second statement in **every** optimize
/// mode. zqlite makes that check only under `builtin.mode == .Debug`, so a
/// release build ran the first of two statements given to one call and dropped
/// the rest without a word: `exec("INSERT …; INSERT …")` inserted one row and
/// reported success, and a test in Debug could not have shown it.
///
/// SQLite reports the first statement's text through `sqlite3_sql` (exactly
/// what `sqlite3_prepare_v2` consumed, up to the tail), so what follows it is
/// found without a second `prepare` on the common path. A tail that compiles to
/// nothing, whitespace or comments or a lone `;`, is not a statement and is
/// let through, the way the Debug check treats it. In Debug zqlite's own check
/// runs first and answers the same `error.MultipleStatements`.
fn prepareOne(conn: zqlite.Conn, sql: []const u8) !zqlite.Stmt {
    const stmt = try conn.prepare(sql);
    errdefer stmt.deinit();

    const c = zqlite.c;
    const consumed_ptr = c.sqlite3_sql(stmt.stmt) orelse return stmt;
    const consumed = std.mem.len(consumed_ptr);
    if (consumed >= sql.len) return stmt;
    const rest = sql[consumed..];

    var tail_stmt: ?*c.sqlite3_stmt = null;
    defer if (tail_stmt != null) {
        _ = c.sqlite3_finalize(tail_stmt);
    };
    const rc = c.sqlite3_prepare_v2(conn.conn, rest.ptr, @intCast(rest.len), &tail_stmt, null);
    if (rc != c.SQLITE_OK or tail_stmt != null) return error.MultipleStatements;
    return stmt;
}

/// A zqlite error as one of `wire.Error` (ADR 036).
///
/// **Cleaner than the Postgres mapping, and for a reason worth recording**:
/// SQLite's extended result codes tell a unique violation apart from every
/// other constraint natively, so this is a switch over an error set rather
/// than a comparison of SQLSTATE strings. `EXResCode` on every `open` is what
/// turns them on; without it every constraint arrives as one code and the
/// 409 below would be unreachable.
fn translate(conn: zqlite.Conn, err: anyerror) wire.Error {
    return switch (err) {
        // The one error with a default answer — 409 — because its meaning
        // does not change with the request around it.
        error.ConstraintUnique, error.ConstraintPrimaryKey => error.AlreadyExists,
        // The three the extended codes can name, which the Postgres side names
        // by SQLSTATE (ADR 117). **Both Wires answer the same word for the
        // same failure**, which is the property that lets a handler tested
        // against SQLite branch on what Postgres will send it.
        error.ConstraintForeignKey => error.ForeignKeyViolated,
        error.ConstraintNotNull => error.NotNullViolated,
        error.ConstraintCheck => error.CheckViolated,
        error.Constraint,
        error.ConstraintTrigger,
        error.ConstraintRowId,
        error.ConstraintDatatype,
        => error.ConstraintViolated,

        // `busy_timeout` ran out, or a shared-cache table lock did. Either
        // way somebody else is holding what this statement wants.
        error.Busy,
        error.BusyTimeout,
        error.BusySnapshot,
        error.Locked,
        error.LockedSharedCache,
        => error.Locked,

        // `sqlite3_interrupt`, which nothing in this module calls. If it
        // arrives, somebody outside asked for the statement to stop, and that
        // is the same thing a deadline means to the handler.
        error.Interrupt => error.TimedOut,

        // The file went away, or was never there. A `ReadOnly` belongs here
        // rather than under `QueryFailed`: it is what a `raw` that writes gets
        // when it was routed to a reader, and the log line is the only place
        // that says so.
        error.ReadOnly => {
            std.log.warn(
                "nilo_sql: a statement tried to write down a read-only connection. " ++
                    "`db.raw` is routed by its first keyword, so a write that does not " ++
                    "begin with a write verb lands on a reader: {s}",
                .{conn.lastError()},
            );
            return error.QueryFailed;
        },
        error.CantOpen, error.IoErr, error.NotADB, error.Corrupt => error.Disconnected,

        // `prepareOne`'s refusal. `lastError` would name whatever the
        // connection said last, which is not this.
        error.MultipleStatements => {
            std.log.warn(
                "nilo_sql: a statement text held more than one statement, and SQLite " ++
                    "runs only the first. Send each as its own call.",
                .{},
            );
            return error.QueryFailed;
        },

        else => {
            // The text never reaches the client (ADR 024); it goes here,
            // where whoever reads the log is the person who can fix it.
            std.log.warn("nilo_sql: {s} [{s}]", .{ conn.lastError(), @errorName(err) });
            return error.QueryFailed;
        },
    };
}
// -- tests ---------------------------------------------------------------

const testing = std.testing;

/// The threading choice a test makes.
///
/// `.in_fiber` because there is no Engine here to hop to — these run under
/// `std.Io.Threaded`, which is std's own. That is not a gap: `.hop` is a call
/// into `nilo.blockingReserved`, tested where the Engine is, and what is worth
/// testing here is the statement rather than which thread ran it.
const TestWire = Wire(.{ .threading = .in_fiber });

/// Every test gets a real `std.Io`, because the pool's queue is built out of
/// `std.Io.Mutex` and `std.Io.Condition` and those reach the futex slots of
/// the vtable. The same harness `s3/canned.zig` and `fetch/live.zig` use, and
/// for the same reason: no Engine anywhere.
fn withIo(comptime body: fn (std.Io) anyerror!void) !void {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try body(threaded.io());
}

/// The same, with room for **two** tasks to be parked at once.
///
/// **`std.Io.Threaded`'s default `async_limit` is one less than the number of
/// logical cores, and past that limit `io.async` runs the task inline on the
/// caller's thread** rather than queueing it — that is documented behaviour
/// and not a fallback for an error. On a two-core box the limit is one, so a
/// test that wants two fibers waiting at the same time deadlocks in a way that
/// looks exactly like the bug it is testing for: the second `async` never
/// returns, and the thread that would have released a connection is the one
/// blocked inside it.
///
/// Every other `io.async` in this repository — `s3/canned.zig`,
/// `fetch/live.zig` — spawns exactly one task beside the main thread, which is
/// why nothing had met this before. Anything that wants a second one has to
/// ask for the room.
fn withIoPair(comptime body: fn (std.Io) anyerror!void) !void {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .async_limit = .limited(2) });
    defer threaded.deinit();
    try body(threaded.io());
}

/// A pool on a database that lives in memory and is shared between its
/// connections — the form check 2 of `spike/sqlite_facts` confirmed is one
/// database rather than several.
///
/// `:memory:` is a database nobody else has. A test that names its own,
/// `file:NAME?mode=memory&cache=shared`, shares it with any other test on the
/// same name while both are open, so each name here is used once.
fn openTest(io: std.Io, name: [:0]const u8, size: u16) !TestWire {
    return TestWire.open(io, testing.allocator, name, .{ .size = size });
}

test "the sqlite wire satisfies the contract" {
    comptime wire.assertWire(TestWire);
}

test "an empty database URL is refused, because it is a setting nobody set" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            try testing.expectError(error.EmptyDatabaseUrl, openTest(io, "", 4));
        }
    }.run);
}

test "a select takes a reader and everything else takes the writer" {
    // Routing is by the first keyword, which is exact for the statements this
    // module generates because this module wrote them.
    try testing.expect(!TestWire.wantsWriter("SELECT \"id\" FROM \"t\""));
    try testing.expect(!TestWire.wantsWriter("  \n select 1"));
    try testing.expect(TestWire.wantsWriter("INSERT INTO \"t\" (\"id\") VALUES (?1)"));
    try testing.expect(TestWire.wantsWriter("UPDATE \"t\" SET \"n\" = ?1"));
    try testing.expect(TestWire.wantsWriter("DELETE FROM \"t\""));
    // A CTE may write and the keyword does not say, so it goes where being
    // wrong costs time rather than correctness.
    try testing.expect(TestWire.wantsWriter("WITH x AS (SELECT 1) SELECT * FROM x"));
}

test "a row written through the writer is read back through a reader" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:round-trip?mode=memory&cache=shared", 4);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY, s TEXT)", .{}, null, null);
            const changed = try w.exec(
                gpa,
                "INSERT INTO t(id, s) VALUES (?1, ?2)",
                .{ @as(i64, 7), "wati" },
                null,
                null,
            );
            try testing.expectEqual(@as(usize, 1), changed);

            var rows = try w.run(gpa, "SELECT id, s FROM t WHERE id = ?1", .{@as(i64, 7)}, null, null);
            defer rows.close();

            // The select went to a reader, which is the half a
            // single-connection pool could not have shown.
            try testing.expect(rows.at != 0);
            try testing.expect(try w.next(&rows));
            try testing.expectEqual(@as(i64, 7), try w.read(&rows, i64, 0));
            try testing.expectEqualStrings("wati", try w.read(&rows, []const u8, 1));
            try testing.expect(!try w.next(&rows));
        }
    }.run);
}

test "a NULL reads as null, and an integer too wide for the field is refused not truncated" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:nulls?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(a INTEGER, b INTEGER, s TEXT)", .{}, null, null);
            _ = try w.exec(gpa, "INSERT INTO t(a, b, s) VALUES (NULL, 70000, NULL)", .{}, null, null);

            var rows = try w.run(gpa, "SELECT a, b, s FROM t", .{}, null, null);
            defer rows.close();
            try testing.expect(try w.next(&rows));

            try testing.expectEqual(@as(?i64, null), try w.read(&rows, ?i64, 0));

            // And the same NULL read into a field that cannot hold one is an
            // error rather than a zero (ADR 094). It used to be `0` for the
            // integer and `""` for the text, because the null test only ran
            // for an optional field — the same class of wrong-answer-that-
            // looks-right as the truncation below, arriving from the other
            // side. Postgres refuses both; this is where SQLite caught up.
            try testing.expectError(error.QueryFailed, w.read(&rows, i64, 0));
            try testing.expectError(error.QueryFailed, w.read(&rows, []const u8, 2));
            try testing.expectEqual(@as(?[]const u8, null), try w.read(&rows, ?[]const u8, 2));
            // SQLite has one integer type, so a field too narrow for the value
            // is the one class of mismatch its schema check cannot catch
            // beforehand (ADR 055). It has to be an error rather than a
            // truncation, because a truncated id is a wrong answer that looks
            // like a right one.
            try testing.expectError(error.QueryFailed, w.read(&rows, i16, 1));
            try testing.expectEqual(@as(i32, 70_000), try w.read(&rows, i32, 1));
        }
    }.run);
}

test "a number is read only out of a number, so text and a fraction are refused rather than guessed" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:classes?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(
                gpa,
                "CREATE TABLE t(n INTEGER, r REAL, flag BOOLEAN, at DATETIME DEFAULT CURRENT_TIMESTAMP)",
                .{},
                null,
                null,
            );
            _ = try w.exec(gpa, "INSERT INTO t(n, r, flag) VALUES ('seven', 2.7, 2)", .{}, null, null);
            _ = try w.exec(gpa, "INSERT INTO t(n, r, flag) VALUES (7, 3, 'yes')", .{}, null, null);

            var rows = try w.run(gpa, "SELECT n, r, flag, at FROM t ORDER BY rowid", .{}, null, null);
            defer rows.close();

            try testing.expect(try w.next(&rows));
            // Text in an INTEGER column read 0, and a REAL read 2: both were
            // answers that look like data.
            try testing.expectError(error.QueryFailed, w.read(&rows, i64, 0));
            try testing.expectError(error.QueryFailed, w.read(&rows, i64, 1));
            try testing.expectEqual(@as(f64, 2.7), try w.read(&rows, f64, 1));
            // A 2 is true to `WHERE flag`, so it is true here too.
            try testing.expectEqual(true, try w.read(&rows, bool, 2));
            // What `CURRENT_TIMESTAMP` stores is text, which a `Timestamp`'s
            // microseconds used to read as the year.
            try testing.expectError(error.QueryFailed, w.read(&rows, i64, 3));
            try testing.expectError(error.QueryFailed, w.read(&rows, ?i64, 3));

            try testing.expect(try w.next(&rows));
            try testing.expectEqual(@as(i64, 7), try w.read(&rows, i64, 0));
            // An integer is a float with nothing lost.
            try testing.expectEqual(@as(f64, 3), try w.read(&rows, f64, 1));
            try testing.expectError(error.QueryFailed, w.read(&rows, bool, 2));
            try testing.expectError(error.QueryFailed, w.read(&rows, f64, 2));
        }
    }.run);
}

test "a NaN is refused before SQLite stores it as NULL, and an infinity is kept" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:nan?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(x REAL NOT NULL, y REAL)", .{}, null, null);
            // It used to arrive as `NotNullViolated` on a value that was never
            // null, and as a `null` read back from the nullable column.
            try testing.expectError(error.QueryFailed, w.exec(
                gpa,
                "INSERT INTO t(x, y) VALUES (?1, ?2)",
                .{ @as(f64, 1), @as(?f64, std.math.nan(f64)) },
                null,
                null,
            ));
            try testing.expectError(error.QueryFailed, w.exec(
                gpa,
                "INSERT INTO t(x) VALUES (?1)",
                .{std.math.nan(f32)},
                null,
                null,
            ));

            _ = try w.exec(
                gpa,
                "INSERT INTO t(x, y) VALUES (?1, ?2)",
                .{ std.math.inf(f64), @as(?f64, null) },
                null,
                null,
            );
            var rows = try w.run(gpa, "SELECT x, y FROM t", .{}, null, null);
            defer rows.close();
            try testing.expect(try w.next(&rows));
            try testing.expectEqual(std.math.inf(f64), try w.read(&rows, f64, 0));
            try testing.expectEqual(@as(?f64, null), try w.read(&rows, ?f64, 1));
            try testing.expect(!try w.next(&rows));
        }
    }.run);
}

test "a returning reader wakes the fiber that wanted a reader, not the one that wanted the writer" {
    // **If this test ever hangs, the pool has lost a wakeup** — that is the
    // failure it exists to catch, and the diagnosis is `ps -o etime,cputime`
    // showing minutes of wall against no CPU. Before ADR 065 both `take`
    // calls waited on one `Condition` while testing different predicates, so
    // `release` waking one fiber could wake the one that could not proceed.
    //
    // `withIoPair` rather than `withIo`, and that is not a detail: see its
    // doc. Two parked fibers need two threads to have been asked for.
    try withIoPair(struct {
        fn takeOne(w: *TestWire, want_writer: bool, out: *usize) void {
            out.* = (if (want_writer) w.takeWriter("test") else w.takeReader("test")) catch 99;
        }

        fn run(io: std.Io) !void {
            // One writer and two readers, so both queues can hold somebody.
            var w = try openTest(io, "file:pool-wakeups?mode=memory&cache=shared", 3);
            defer w.close();

            // Every connection taken, so anybody asking now has to park.
            try testing.expectEqual(@as(usize, 0), try w.takeWriter("test"));
            try testing.expectEqual(@as(usize, 1), try w.takeReader("test"));
            try testing.expectEqual(@as(usize, 2), try w.takeReader("test"));

            var writer_at: usize = 99;
            var reader_at: usize = 99;
            var wants_writer = io.async(takeOne, .{ &w, true, &writer_at });
            var wants_reader = io.async(takeOne, .{ &w, false, &reader_at });

            // Give a *reader* back, and nothing else. The fiber queued for the
            // writer cannot use it and must not be the one woken.
            w.release(1);
            wants_reader.await(io);
            try testing.expectEqual(@as(usize, 1), reader_at);

            // The writer's own queue still works, which is the half that would
            // have kept passing if the split had been made the wrong way round.
            w.release(0);
            wants_writer.await(io);
            try testing.expectEqual(@as(usize, 0), writer_at);

            w.release(0);
            w.release(1);
            w.release(2);
        }
    }.run);
}

test "a fiber cancelled while it queues for a connection keeps its cancellation" {
    // A background loop queued for the writer at shutdown used to be told
    // `TimedOut` with the cancellation spent, so its next `sleep` ran and the
    // process never exited (ADR 223).
    try withIoPair(struct {
        const After = enum { still_cancelled, lost, took };

        fn waitThenAsk(w: *TestWire, io: std.Io, want_writer: bool) After {
            _ = (if (want_writer) w.takeWriter("test") else w.takeReader("test")) catch |err| {
                std.debug.assert(err == error.Disconnected);
                std.Io.checkCancel(io) catch return .still_cancelled;
                return .lost;
            };
            return .took;
        }

        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:cancel-in-queue?mode=memory&cache=shared", 2);
            defer w.close();

            // Everything taken, so both askers have to park.
            try testing.expectEqual(@as(usize, 0), try w.takeWriter("test"));
            try testing.expectEqual(@as(usize, 1), try w.takeReader("test"));

            for ([_]bool{ true, false }) |want_writer| {
                var task = io.concurrent(waitThenAsk, .{ &w, io, want_writer }) catch return error.SkipZigTest;
                try std.Io.sleep(io, .fromMilliseconds(100), .awake);
                try testing.expectEqual(After.still_cancelled, task.cancel(io));
            }

            w.release(0);
            w.release(1);
        }
    }.run);
}

test "the introspection query reads the rowid alias as not-null, and a key that may hold a NULL as unknown" {
    // `dialect.SQLite.introspect` is asked directly rather than through
    // `db.checkSchema`, which reports a problem with `std.log.err` and so
    // fails the test runner for every test that provokes one. What is being
    // held here is the query's three answers, which is what the check is
    // built out of (ADR 050).
    try withIo(struct {
        fn nullableOf(
            w: *TestWire,
            arena: std.mem.Allocator,
            table: []const u8,
            column: []const u8,
        ) !?bool {
            const columns = try w.columnsOf(arena, dialect.SQLite.introspect, null, table);
            for (columns) |c| if (std.mem.eql(u8, c.name, column)) return c.nullable;
            return error.TestUnexpectedResult;
        }

        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:rowid-introspect?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            const ddl = [_][]const u8{
                "CREATE TABLE alias (id INTEGER PRIMARY KEY, label TEXT NOT NULL)",
                "CREATE TABLE tuple_form (id INTEGER, label TEXT, PRIMARY KEY (id))",
                "CREATE TABLE not_integer (id INT PRIMARY KEY, label TEXT)",
                "CREATE TABLE composite (tenant_id INTEGER, id INTEGER, PRIMARY KEY (tenant_id, id))",
                "CREATE TABLE text_key (id TEXT PRIMARY KEY, label TEXT)",
                "CREATE TABLE text_key_checked (id TEXT NOT NULL PRIMARY KEY, label TEXT)",
                "CREATE TABLE no_rowid (id TEXT PRIMARY KEY, label TEXT) WITHOUT ROWID",
                // A column with no declared type at all, which SQLite allows.
                // Here because ADR 094 made a NULL in a non-optional field an
                // error, and this query reads `i.type` as a
                // `[]const u8`: if the pragma answered NULL rather than the
                // empty string for an untyped column, the schema check would
                // have started failing on a table it used to read.
                "CREATE TABLE untyped (id INTEGER PRIMARY KEY, whatever)",
                "CREATE VIEW as_view AS SELECT id, label FROM alias",
            };
            for (ddl) |text| _ = try w.exec(gpa, text, .{}, null, null);

            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            const arena = scratch.allocator();

            // The alias, inline and as a one-column tuple. Both are the rowid,
            // both report `notnull = 0`, and neither may hold a NULL.
            try testing.expectEqual(@as(?bool, false), try nullableOf(&w, arena, "alias", "id"));
            try testing.expectEqual(@as(?bool, false), try nullableOf(&w, arena, "tuple_form", "id"));

            // An ordinary column beside it, so the branch is not simply
            // answering `false` for everything.
            try testing.expectEqual(@as(?bool, false), try nullableOf(&w, arena, "alias", "label"));
            try testing.expectEqual(@as(?bool, true), try nullableOf(&w, arena, "tuple_form", "label"));

            // `INT` rather than `INTEGER`: the same affinity, and not an alias.
            // This column really does accept a NULL, and it is a key, so the
            // answer is "the database does not say" and not "may be null"
            // (ADR 050).
            try testing.expectEqual(@as(?bool, null), try nullableOf(&w, arena, "not_integer", "id"));
            try testing.expectEqual(@as(?bool, true), try nullableOf(&w, arena, "not_integer", "label"));

            // A composite key over a rowid table, the shape of every
            // multi-tenant schema: SQLite lets any column of it hold a NULL.
            try testing.expectEqual(@as(?bool, null), try nullableOf(&w, arena, "composite", "tenant_id"));
            try testing.expectEqual(@as(?bool, null), try nullableOf(&w, arena, "composite", "id"));

            // `id TEXT PRIMARY KEY`, the key photon and most hand-written
            // schemas have: unknown, so a plain `Str` field passes the check.
            try testing.expectEqual(@as(?bool, null), try nullableOf(&w, arena, "text_key", "id"));
            try testing.expectEqual(@as(?bool, true), try nullableOf(&w, arena, "text_key", "label"));
            // With `NOT NULL`, which is what nilo writes for a table it
            // creates, and on a `WITHOUT ROWID` table, which enforces it.
            try testing.expectEqual(@as(?bool, false), try nullableOf(&w, arena, "text_key_checked", "id"));
            try testing.expectEqual(@as(?bool, false), try nullableOf(&w, arena, "no_rowid", "id"));

            // The untyped column reads without the whole query failing, and
            // the rowid beside it is still the rowid.
            try testing.expectEqual(@as(?bool, true), try nullableOf(&w, arena, "untyped", "whatever"));
            try testing.expectEqual(@as(?bool, false), try nullableOf(&w, arena, "untyped", "id"));

            // And the third answer still arrives: a view says nothing about
            // nullability and the check skips it (ADR 050). The rowid branch
            // sits behind the view branch so this cannot be turned into a
            // `false` by an `id` that came from an aliased column.
            try testing.expectEqual(@as(?bool, null), try nullableOf(&w, arena, "as_view", "id"));
        }
    }.run);
}

test "the introspection query answers the affinity of a hand-written declared type" {
    // The startup check used to be handed `upper(i.type)` and wanted an exact
    // name, so a `VARCHAR(255)` under a `Str` refused to start a server whose
    // table was right (ADR 055). Asked directly, for the reason the test
    // above gives.
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:affinity-introspect?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa,
                \\CREATE TABLE hand (
                \\  a VARCHAR(255), b DATE, c uuid, d BIGINT, e DOUBLE PRECISION,
                \\  f BOOLEAN, g DATETIME, h CLOB, i blob, j, k NVARCHAR(10),
                \\  l DECIMAL(10,2), m FLOAT, n INTEGER, o POINT
                \\)
            , .{}, null, null);

            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            const columns = try w.columnsOf(scratch.allocator(), dialect.SQLite.introspect, null, "hand");

            const want = [_][]const u8{
                "TEXT",    "NUMERIC", "NUMERIC", "INTEGER", "REAL",
                "NUMERIC", "NUMERIC", "TEXT",    "BLOB",    "ANY",
                "TEXT",    "NUMERIC", "REAL",    "INTEGER", "INTEGER",
            };
            try testing.expectEqual(want.len, columns.len);
            for (want, columns) |udt, c| try testing.expectEqualStrings(udt, c.udt);
        }
    }.run);
}

test "a statement given a plan name is prepared once, and one without a name is not kept" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:kept?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);
            _ = try w.exec(gpa, "INSERT INTO t(id) VALUES (1), (2)", .{}, null, null);

            for (0..3) |_| {
                var rows = try w.run(
                    gpa,
                    "SELECT id FROM t WHERE id = ?1",
                    .{@as(i64, 1)},
                    "nilo_t_find",
                    null,
                );
                defer rows.close();
                try testing.expect(try w.next(&rows));
                try testing.expectEqual(@as(i64, 1), try w.read(&rows, i64, 0));
            }

            // Let go clean: reset, and holding none of the last call's values,
            // which is what lets the next call bind without undoing anything.
            for (w.conns) |conn| {
                const stmt = conn.kept.get("nilo_t_find") orelse continue;
                try testing.expectEqual(@as(c_int, 0), zqlite.c.sqlite3_stmt_busy(stmt.stmt));
                const expanded = try stmt.expandedSql(gpa);
                defer gpa.free(expanded);
                try testing.expect(std.mem.indexOf(u8, expanded, "id = NULL") != null);
            }
            // And a second value on the same statement is the second value.
            {
                var rows = try w.run(gpa, "SELECT id FROM t WHERE id = ?1", .{@as(i64, 2)}, "nilo_t_find", null);
                defer rows.close();
                try testing.expect(try w.next(&rows));
                try testing.expectEqual(@as(i64, 2), try w.read(&rows, i64, 0));
            }

            // One entry, on the one reader that ran it — the cache is per
            // connection because a prepared statement belongs to the
            // connection it was prepared against (ADR 051).
            var kept: usize = 0;
            for (w.conns) |conn| kept += conn.kept.count();
            try testing.expectEqual(@as(usize, 1), kept);

            // And a statement with no plan leaves nothing behind, which is
            // what stops `db.raw` growing a cache with traffic.
            var raw = try w.run(gpa, "SELECT id FROM t", .{}, null, null);
            raw.close();
            kept = 0;
            for (w.conns) |conn| kept += conn.kept.count();
            try testing.expectEqual(@as(usize, 1), kept);
        }
    }.run);
}

test "a result set nobody finished reading leaves its connection usable" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:abandoned?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);
            _ = try w.exec(gpa, "INSERT INTO t(id) VALUES (1), (2), (3)", .{}, null, null);

            // Read one of three and walk away, which is an ordinary thing to
            // write.
            {
                var rows = try w.run(gpa, "SELECT id FROM t", .{}, "nilo_t_all", null);
                defer w.drain(&rows);
                try testing.expect(try w.next(&rows));
            }

            // The connection is back, and the kept statement starts from the
            // top rather than from where the last caller stopped. Without the
            // reset in `Rows.close` this would answer 2 — which is the shape
            // ADR 032 asks for: a guard seen to fail.
            var again = try w.run(gpa, "SELECT id FROM t", .{}, "nilo_t_all", null);
            defer again.close();
            try testing.expect(try w.next(&again));
            try testing.expectEqual(@as(i64, 1), try w.read(&again, i64, 0));
        }
    }.run);
}

test "a unique violation is AlreadyExists and every other constraint is not" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:unique?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(
                gpa,
                "CREATE TABLE t(id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE)",
                .{},
                null,
                null,
            );
            _ = try w.exec(gpa, "INSERT INTO t(id, email) VALUES (1, 'a@b')", .{}, null, null);

            // The one error with a default answer — 409 — and SQLite's
            // extended result codes are what let it be told apart without
            // reading a message.
            try testing.expectError(error.AlreadyExists, w.exec(
                gpa,
                "INSERT INTO t(id, email) VALUES (2, 'a@b')",
                .{},
                null,
                null,
            ));

            // A NOT NULL is a constraint too, and it is not a 409: it usually
            // means the code is wrong rather than the client. It has a name of
            // its own since ADR 117, so a handler can say which one fired.
            try testing.expectError(error.NotNullViolated, w.exec(
                gpa,
                "INSERT INTO t(id, email) VALUES (3, NULL)",
                .{},
                null,
                null,
            ));
        }
    }.run);
}

test "a transaction commits, rolls back, and gives its connection back either way" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:tx?mode=memory&cache=shared", 3);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);

            {
                var tx = try w.begin(gpa, .{});
                errdefer tx.rollback();
                _ = try tx.exec(gpa, "INSERT INTO t(id) VALUES (1)", .{}, null, null);
                try tx.commit(gpa, null);
            }
            {
                var tx = try w.begin(gpa, .{});
                _ = try tx.exec(gpa, "INSERT INTO t(id) VALUES (2)", .{}, null, null);
                tx.rollback();
            }

            // The writer is free both times, so a third transaction does not
            // hang — which is what a leaked connection would look like, and
            // there is only one writer to leak.
            var tx = try w.begin(gpa, .{});
            try tx.commit(gpa, null);

            var rows = try w.run(gpa, "SELECT count(*) FROM t", .{}, null, null);
            defer rows.close();
            try testing.expect(try w.next(&rows));
            try testing.expectEqual(@as(i64, 1), try w.read(&rows, i64, 0));
        }
    }.run);
}

test "a savepoint undoes part of a transaction without ending it" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:savepoint?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);

            var tx = try w.begin(gpa, .{});
            errdefer tx.rollback();
            _ = try tx.exec(gpa, "INSERT INTO t(id) VALUES (1)", .{}, null, null);
            try tx.savepoint(gpa, .mark, 1);
            _ = try tx.exec(gpa, "INSERT INTO t(id) VALUES (2)", .{}, null, null);
            try tx.savepoint(gpa, .undo, 1);
            _ = try tx.exec(gpa, "INSERT INTO t(id) VALUES (3)", .{}, null, null);
            try tx.commit(gpa, null);

            var rows = try w.run(gpa, "SELECT id FROM t ORDER BY id", .{}, null, null);
            defer rows.close();
            try testing.expect(try w.next(&rows));
            try testing.expectEqual(@as(i64, 1), try w.read(&rows, i64, 0));
            try testing.expect(try w.next(&rows));
            try testing.expectEqual(@as(i64, 3), try w.read(&rows, i64, 0));
            try testing.expect(!try w.next(&rows));
        }
    }.run);
}

test "a read-only transaction takes a reader, so a report does not stop the writes" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:ro-tx?mode=memory&cache=shared", 3);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);

            var report = try w.begin(gpa, .{ .read_only = true });
            defer report.rollback();
            try testing.expect(report.at != 0);

            // The writer is untouched while the report is open, which is what
            // the flag buys on this dialect and does not buy on the other.
            _ = try w.exec(gpa, "INSERT INTO t(id) VALUES (1)", .{}, null, null);
        }
    }.run);
}

test "a reader refuses a write, which is what makes routing safe to get wrong" {
    // **On a file, and that is the test rather than an accident of it.**
    //
    // `OpenFlags.ReadOnly` is what ADR 065 leans on: routing `db.raw` by its
    // first keyword is a guess, and a guess that goes the wrong way has to
    // land somewhere it cannot do damage. But SQLite's URI `mode=` parameter
    // takes precedence over the flags handed to `sqlite3_open_v2`, so
    // `mode=memory` **silently gives a read-only connection write access**.
    // This test asserted the refusal against an in-memory database and failed,
    // which is how that was found; check 6c of `spike/sqlite_facts` is where
    // it is pinned.
    //
    // So the flag holds on a file and not in memory, which is why a reader
    // also gets `query_only`, tested on `:memory:` at the bottom of this file.
    // WAL, below, is still one more thing a suite running entirely in memory
    // would never have tested.
    tmp = core.tmpDir();
    defer tmp.cleanup();

    try withIo(struct {
        fn run(io: std.Io) !void {
            var path: [96]u8 = undefined;
            const url = try tmp.path(&path, "roles.db");

            var w = try openTest(io, url, 4);
            defer w.close();
            const gpa = testing.allocator;

            try testing.expectEqual(@as(usize, 4), w.conns.len);
            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);

            // ADR 065's backstop, seen to fail rather than assumed to work
            // (ADR 032).
            for (w.conns[1..]) |conn| {
                try testing.expectError(
                    error.ReadOnly,
                    conn.handle.execNoArgs("INSERT INTO t(id) VALUES (99)"),
                );
            }

            // And WAL, which is the other thing only a file can show: an
            // in-memory database answers `memory` to the same pragma without
            // failing, so a pool tested only in memory has never once run in
            // the journal mode it ships in (check 3 of the same spike).
            var rows = try w.run(gpa, "PRAGMA journal_mode", .{}, null, null);
            defer rows.close();
            try testing.expect(try w.next(&rows));
            try testing.expectEqualStrings("wal", try w.read(&rows, []const u8, 0));
        }
    }.run);
}

test "a write that waits past busy_timeout on a lock another program holds answers Locked" {
    // With one writer in the pool, a lock held elsewhere is another program
    // on the same file, and only a file can have one: `busy_timeout` counts
    // down and the write answers `Locked`, the word Postgres's `55P03` gets.
    tmp = core.tmpDir();
    defer tmp.cleanup();

    try withIo(struct {
        fn run(io: std.Io) !void {
            var path: [96]u8 = undefined;
            const url = try tmp.path(&path, "busy.db");
            const Quick = Wire(.{ .threading = .in_fiber, .busy_timeout_ms = 50 });
            var w = try Quick.open(io, testing.allocator, url, .{ .size = 2 });
            defer w.close();
            const gpa = testing.allocator;
            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);

            const other = try zqlite.open(url, zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode);
            defer other.close();
            try other.execNoArgs("BEGIN IMMEDIATE");
            try testing.expectError(error.Locked, w.exec(gpa, "INSERT INTO t(id) VALUES (1)", .{}, null, null));

            // Let go of, the same write goes through on the same pool.
            try other.execNoArgs("ROLLBACK");
            try testing.expectEqual(@as(usize, 1), try w.exec(gpa, "INSERT INTO t(id) VALUES (1)", .{}, null, null));
        }
    }.run);
}

test "each SQLite failure a caller branches on has the name the Postgres one has" {
    // The table, one row a case. Most of these cannot be produced on demand
    // (an interrupt nothing here calls, a snapshot that went stale, a disk
    // that went away), so the mapping is held here rather than by accident.
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.Create);
    defer conn.close();
    const cases = [_]struct { anyerror, wire.Error }{
        .{ error.ConstraintUnique, error.AlreadyExists },
        .{ error.ConstraintPrimaryKey, error.AlreadyExists },
        .{ error.ConstraintForeignKey, error.ForeignKeyViolated },
        .{ error.ConstraintNotNull, error.NotNullViolated },
        .{ error.ConstraintCheck, error.CheckViolated },
        .{ error.Constraint, error.ConstraintViolated },
        .{ error.ConstraintTrigger, error.ConstraintViolated },
        .{ error.Busy, error.Locked },
        .{ error.BusyTimeout, error.Locked },
        .{ error.BusySnapshot, error.Locked },
        .{ error.Locked, error.Locked },
        .{ error.LockedSharedCache, error.Locked },
        .{ error.Interrupt, error.TimedOut },
        .{ error.CantOpen, error.Disconnected },
        .{ error.IoErr, error.Disconnected },
        .{ error.Corrupt, error.Disconnected },
    };
    for (cases) |case| try testing.expectEqual(case[1], translate(conn, case[0]));
}

/// The directory the two tests above put their file in. A file rather than a
/// shared in-memory database, and the directory has to reach a closure
/// `withIo` calls as a plain function.
var tmp: core.TmpDir = undefined;

test "each constraint a caller branches on arrives under its own name" {
    // Item 55: `23503` used to arrive as `ConstraintViolated` beside a check
    // somebody wrote and a null the code should never have sent, so the one
    // failure in class 23 that is routinely a race could not be told from the
    // two that mean the program is wrong (ADR 117).
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:named-constraints?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "PRAGMA foreign_keys = ON", .{}, null, null);
            _ = try w.exec(
                gpa,
                "CREATE TABLE staff(id INTEGER PRIMARY KEY, age INTEGER CHECK (age > 0))",
                .{},
                null,
                null,
            );
            _ = try w.exec(
                gpa,
                "CREATE TABLE task(id INTEGER PRIMARY KEY, staff_id INTEGER NOT NULL " ++
                    "REFERENCES staff(id))",
                .{},
                null,
                null,
            );
            _ = try w.exec(gpa, "INSERT INTO staff(id, age) VALUES (1, 30)", .{}, null, null);

            // A child naming a parent that is not there.
            try testing.expectError(error.ForeignKeyViolated, w.exec(
                gpa,
                "INSERT INTO task(id, staff_id) VALUES (1, 99)",
                .{},
                null,
                null,
            ));

            // And the other direction, which is the one the report was about:
            // a delete that lost a race with somebody adding work.
            _ = try w.exec(gpa, "INSERT INTO task(id, staff_id) VALUES (2, 1)", .{}, null, null);
            try testing.expectError(error.ForeignKeyViolated, w.exec(
                gpa,
                "DELETE FROM staff WHERE id = 1",
                .{},
                null,
                null,
            ));

            try testing.expectError(error.CheckViolated, w.exec(
                gpa,
                "INSERT INTO staff(id, age) VALUES (2, -1)",
                .{},
                null,
                null,
            ));

            try testing.expectError(error.NotNullViolated, w.exec(
                gpa,
                "INSERT INTO task(id, staff_id) VALUES (3, NULL)",
                .{},
                null,
                null,
            ));
        }
    }.run);
}

test "a statement text holding a second statement is refused in every optimize mode, and a tail of nothing is not" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:two-statements?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);

            // zqlite refuses this only in Debug; a release build ran the
            // first INSERT and dropped the second without a word.
            try testing.expectError(error.QueryFailed, w.exec(
                gpa,
                "INSERT INTO t(id) VALUES (1); INSERT INTO t(id) VALUES (2)",
                .{},
                null,
                null,
            ));

            // A trailing semicolon, whitespace and a comment are not statements.
            try testing.expectEqual(@as(usize, 1), try w.exec(gpa, "INSERT INTO t(id) VALUES (3);", .{}, null, null));
            try testing.expectEqual(@as(usize, 1), try w.exec(gpa, "INSERT INTO t(id) VALUES (4); \n\t", .{}, null, null));
            try testing.expectEqual(@as(usize, 1), try w.exec(gpa, "INSERT INTO t(id) VALUES (5); -- done", .{}, null, null));
            try testing.expectEqual(@as(usize, 1), try w.exec(gpa, "INSERT INTO t(id) VALUES (6); /* done */", .{}, null, null));

            // Nothing from the refused text ran: 3, 4, 5 and 6 only.
            var rows = try w.run(gpa, "SELECT count(*) FROM t", .{}, null, null);
            defer rows.close();
            try testing.expect(try w.next(&rows));
            try testing.expectEqual(@as(i64, 4), try w.read(&rows, i64, 0));
        }
    }.run);
}

test "the numbered list of blob keys joins a blob column, because it is read back out of its hex" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:blob-children?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE child(id INTEGER PRIMARY KEY, parent BLOB NOT NULL)", .{}, null, null);
            _ = try w.exec(gpa, "INSERT INTO child(id, parent) VALUES (1, x'0a0b'), (2, x'ff'), (3, x'0a0b')", .{}, null, null);

            // The same statement `shape.children` builds: the list, then a
            // join on its `value`. The parameter is what `jsonList` writes
            // for a `Bytes` key: a JSON array of hex text.
            const listed = comptime dialect.SQLite.ordinalList("?1", wire.Bytes, "\"#k\"").?;
            var rows = try w.run(
                gpa,
                "SELECT child.id, \"#k\".\"key\" FROM " ++ listed ++
                    " JOIN child ON child.parent = \"#k\".\"value\" ORDER BY \"#k\".\"key\", child.id",
                .{"[\"ff\",\"0a0b\"]"},
                null,
                null,
            );
            defer rows.close();
            try testing.expect(try w.next(&rows));
            try testing.expectEqual(@as(i64, 2), try w.read(&rows, i64, 0));
            try testing.expectEqual(@as(i64, 0), try w.read(&rows, i64, 1));
            try testing.expect(try w.next(&rows));
            try testing.expectEqual(@as(i64, 1), try w.read(&rows, i64, 0));
            try testing.expectEqual(@as(i64, 1), try w.read(&rows, i64, 1));
            try testing.expect(try w.next(&rows));
            try testing.expectEqual(@as(i64, 3), try w.read(&rows, i64, 0));
            try testing.expect(!try w.next(&rows));
        }
    }.run);
}

test "a double is read into an f32 only when the f32 holds it exactly" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:narrow?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(x REAL)", .{}, null, null);
            _ = try w.exec(gpa, "INSERT INTO t(x) VALUES (?1), (?2), (?3)", .{ @as(f64, 0.5), @as(f64, 0.1), @as(f64, 1e300) }, null, null);

            var rows = try w.run(gpa, "SELECT x FROM t ORDER BY rowid", .{}, null, null);
            defer rows.close();
            try testing.expect(try w.next(&rows));
            try testing.expectEqual(@as(f32, 0.5), try w.read(&rows, f32, 0));
            // Postgres refuses every float8 read into an f32; here the
            // value that would have been rounded is the one refused.
            try testing.expect(try w.next(&rows));
            try testing.expectError(error.QueryFailed, w.read(&rows, f32, 0));
            try testing.expectEqual(@as(f64, 0.1), try w.read(&rows, f64, 0));
            // And one that overflows an f32 is not an infinity.
            try testing.expect(try w.next(&rows));
            try testing.expectError(error.QueryFailed, w.read(&rows, ?f32, 0));
        }
    }.run);
}

test "a value refused before it was bound does not abort the transaction" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:refused-not-aborted?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER)", .{}, null, null);

            var tx = try w.begin(gpa, .{});
            errdefer tx.rollback();
            // A u64 SQLite cannot store: refused, as Postgres's client
            // refuses it, and nothing has reached the database.
            try testing.expectError(error.QueryFailed, tx.exec(
                gpa,
                "INSERT INTO t(id, n) VALUES (1, ?1)",
                .{@as(u64, std.math.maxInt(u64))},
                null,
                null,
            ));
            // The transaction goes on, and commits what came after.
            _ = try tx.exec(gpa, "INSERT INTO t(id, n) VALUES (2, 20)", .{}, null, null);
            try tx.commit(gpa, null);

            var rows = try w.run(gpa, "SELECT count(*) FROM t", .{}, null, null);
            defer rows.close();
            try testing.expect(try w.next(&rows));
            try testing.expectEqual(@as(i64, 1), try w.read(&rows, i64, 0));
        }
    }.run);
}

test "exec answers the rows a statement changed, and 0 for one that changed none" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:exec-count?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);
            try testing.expectEqual(@as(usize, 3), try w.exec(gpa, "INSERT INTO t(id) VALUES (1), (2), (3)", .{}, null, null));
            // `changes()` alone answered 3 for each of these, the count of the
            // last statement that did change rows.
            try testing.expectEqual(@as(usize, 0), try w.exec(gpa, "CREATE INDEX t_id ON t(id)", .{}, null, null));
            try testing.expectEqual(@as(usize, 0), try w.exec(gpa, "PRAGMA user_version = 7", .{}, null, null));
            try testing.expectEqual(@as(usize, 0), try w.exec(gpa, "UPDATE t SET id = id WHERE id > 99", .{}, null, null));
            try testing.expectEqual(@as(usize, 2), try w.exec(gpa, "DELETE FROM t WHERE id > 1", .{}, null, null));
        }
    }.run);
}

test "a plan goes to a reader, so a transaction holding the writer does not wait for itself" {
    try testing.expect(!TestWire.wantsWriter("EXPLAIN QUERY PLAN INSERT INTO \"t\" VALUES (?1)"));
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:plan-reader?mode=memory&cache=shared", 2);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);
            var tx = try w.begin(gpa, .{});
            defer tx.rollback();
            // The one writer is the transaction's now.
            var plan = try w.run(gpa, "EXPLAIN QUERY PLAN SELECT * FROM t WHERE id = 1", .{}, null, null);
            defer plan.close();
            try testing.expect(try w.next(&plan));
        }
    }.run);
}

test "the check before a rebuild's commit looks at the tables it dropped and the rows pointing at them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "SELECT 1 FROM pragma_foreign_key_check WHERE \"table\" COLLATE NOCASE IN ('a''b', 'c') " ++
            "OR \"parent\" COLLATE NOCASE IN ('a''b', 'c') LIMIT 1",
        try TestWire.foreignKeyCheck(a, &.{ "a'b", "c" }, false),
    );
    // A drop it could not read, or none: every key, as it always was.
    try testing.expectEqualStrings(
        "SELECT 1 FROM pragma_foreign_key_check LIMIT 1",
        try TestWire.foreignKeyCheck(a, &.{"c"}, true),
    );
    try testing.expectEqualStrings(
        "SELECT 1 FROM pragma_foreign_key_check LIMIT 1",
        try TestWire.foreignKeyCheck(a, &.{}, false),
    );
}

test "an old broken key in a table a rebuild never touched does not fail the rebuild" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, "file:rebuild-scope?mode=memory&cache=shared", 3);
            defer w.close();
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            _ = try w.exec(a, "CREATE TABLE p(id INTEGER PRIMARY KEY)", .{}, null, null);
            _ = try w.exec(a, "CREATE TABLE c(id INTEGER PRIMARY KEY, p_id INTEGER REFERENCES p(id))", .{}, null, null);
            _ = try w.exec(a, "CREATE TABLE other(id INTEGER PRIMARY KEY)", .{}, null, null);
            _ = try w.exec(a, "CREATE TABLE old(id INTEGER PRIMARY KEY, o_id INTEGER REFERENCES other(id))", .{}, null, null);
            _ = try w.exec(a, "INSERT INTO p(id) VALUES (1)", .{}, null, null);
            _ = try w.exec(a, "INSERT INTO c(id, p_id) VALUES (1, 1)", .{}, null, null);
            // A violation from before, in a table the rebuild does not name.
            _ = try w.exec(a, "PRAGMA foreign_keys = OFF", .{}, null, null);
            _ = try w.exec(a, "INSERT INTO old(id, o_id) VALUES (1, 99)", .{}, null, null);
            _ = try w.exec(a, "PRAGMA foreign_keys = ON", .{}, null, null);

            {
                var tx = try w.begin(a, .{ .rebuilding = true });
                errdefer tx.rollback();
                _ = try tx.exec(a, "CREATE TABLE p_new(id INTEGER PRIMARY KEY)", .{}, null, null);
                _ = try tx.exec(a, "INSERT INTO p_new SELECT id FROM p", .{}, null, null);
                _ = try tx.exec(a, "DROP TABLE p", .{}, null, null);
                _ = try tx.exec(a, "ALTER TABLE p_new RENAME TO p", .{}, null, null);
                // Every key used to be checked here, and `old` failed it.
                try tx.commit(a, null);
            }

            // And a rebuild that loses a parent row still fails, through the
            // child that points at it.
            var tx = try w.begin(a, .{ .rebuilding = true });
            _ = try tx.exec(a, "CREATE TABLE p_new(id INTEGER PRIMARY KEY)", .{}, null, null);
            _ = try tx.exec(a, "DROP TABLE p", .{}, null, null);
            _ = try tx.exec(a, "ALTER TABLE p_new RENAME TO p", .{}, null, null);
            try testing.expectError(error.ForeignKeyViolated, tx.commit(a, null));
        }
    }.run);
}

test "two pools on :memory: are two databases, and each is one database across its own pool" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const gpa = testing.allocator;
            var a = try openTest(io, ":memory:", 3);
            defer a.close();
            // A second type of Wire as well as a second pool: the counter
            // lives outside `Wire`, or each type would count from zero and
            // the two would meet under one name.
            var b = try Wire(.{ .threading = .in_fiber, .busy_timeout_ms = 1 }).open(
                io,
                gpa,
                ":memory:",
                .{ .size = 2 },
            );
            defer b.close();

            _ = try a.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);
            _ = try a.exec(gpa, "INSERT INTO t(id) VALUES (7)", .{}, null, null);

            // The writer's row through a reader: one database, not three.
            var rows = try a.run(gpa, "SELECT id FROM t", .{}, null, null);
            defer rows.close();
            try testing.expect(rows.at != 0);
            try testing.expect(try a.next(&rows));
            try testing.expectEqual(@as(i64, 7), try a.read(&rows, i64, 0));

            // And nothing of it in the other pool, which is the property a
            // suite running its tests side by side needs.
            var tables = try b.run(gpa, "SELECT count(*) FROM sqlite_master", .{}, null, null);
            defer tables.close();
            try testing.expect(try b.next(&tables));
            try testing.expectEqual(@as(i64, 0), try b.read(&tables, i64, 0));
        }
    }.run);
}

test "a reader on :memory: refuses a write, though mode=memory outranks the read-only flag" {
    // The test on a file shows the flag holding; this is the database the
    // flag does not hold on, and `query_only` is what refuses here.
    try withIo(struct {
        fn run(io: std.Io) !void {
            var w = try openTest(io, ":memory:", 3);
            defer w.close();
            const gpa = testing.allocator;

            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);
            for (w.conns[1..]) |conn| {
                try testing.expectError(
                    error.ReadOnly,
                    conn.handle.execNoArgs("INSERT INTO t(id) VALUES (99)"),
                );
            }

            // And through the routing it backs: a write that reads as a read
            // lands on a reader and is refused rather than kept.
            var rows = try w.run(gpa, "PRAGMA user_version = 3", .{}, null, null);
            defer rows.close();
            try testing.expect(rows.at != 0);
            try testing.expectError(error.QueryFailed, w.next(&rows));
        }
    }.run);
}

test "a name given to a shared in-memory database is still shared by every pool that gives it" {
    // `:memory:` is the private spelling; a caller's own name keeps meaning
    // what SQLite says it means, so two pools can share on purpose.
    try withIo(struct {
        fn run(io: std.Io) !void {
            const gpa = testing.allocator;
            var a = try openTest(io, "file:shared-on-purpose?mode=memory&cache=shared", 2);
            defer a.close();
            var b = try openTest(io, "file:shared-on-purpose?mode=memory&cache=shared", 2);
            defer b.close();

            _ = try a.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);
            var tables = try b.run(gpa, "SELECT count(*) FROM sqlite_master", .{}, null, null);
            defer tables.close();
            try testing.expect(try b.next(&tables));
            try testing.expectEqual(@as(i64, 1), try b.read(&tables, i64, 0));
        }
    }.run);
}
