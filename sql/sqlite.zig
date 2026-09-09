//! The second Wire, behind the same contract as the first (`wire.zig`).
//!
//! Everything here follows from one sentence: **SQLite is not a server.** It
//! is a library reading a file in this process, so there is no socket to wait
//! on, no server to hold the rules, and no second connection that may write.
//! [ADR 0073](../docs/adr/0073-a-file-has-no-socket-to-wait-on.md) decides how
//! a statement reaches a thread and whose C brings SQLite in;
//! [ADR 0074](../docs/adr/0074-one-writer-is-not-a-setting-it-is-the-database.md)
//! decides the pool, where `raw` goes, durability and the test story.
//!
//! Three things are worth knowing before reading the code.
//!
//! **The threading choice has no default.** `Wire` is a function of its
//! options and `threading` is the one field without one, so leaving it out is
//! a compile error naming both answers. It is not a tuning knob: it decides
//! whether a slow statement stalls an executor thread, and there is no
//! measurement yet saying which way a given deployment should go
//! (ADR 0073). What the field buys is that taking that measurement later
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
//! designs fail by being slow or by being wrong.

const std = @import("std");
const core = @import("nilo_core");
const zqlite = @import("zqlite");

const wire = @import("wire.zig");
/// Only the tests reach for this, and only for `SQLite.introspect` — the
/// query `columnsOf` is handed at run time. A Wire is not allowed to have an
/// opinion about a Dialect anywhere else, which is what keeps the seam a seam
/// (ADR 0061).
const dialect = @import("dialect.zig");

/// The SQLite that is compiled in, as its own version string — `3.53.0`.
///
/// Public because it is the one thing about this Wire that comes from
/// somewhere else: SQLite is a bundled amalgamation rather than a library the
/// machine happened to have (ADR 0073), so a benchmark or a `/health` route
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
    /// error message is a feature here (ADR 0027).
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
    /// [`spike/sqlite_facts`](../spike/sqlite_facts/) made to ADR 0074: a
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
    /// that reachable by accident (ADR 0074).
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
    /// The payload is the namespace holding `blocking` — `nilo` itself:
    ///
    /// ```zig
    /// const Wire = sqlite.Wire(.{ .threading = .{ .hop = nilo } });
    /// ```
    ///
    /// It arrives from the caller's program rather than being imported here
    /// because `blocking` lives in `http/bulkhead.zig` and `sql/` may not name
    /// `nilo_http` — `zig build layering` refuses it. `std.Io.concurrent` is
    /// not the way round it: zio implements that slot by starting a *fiber*,
    /// so a blocking call inside one holds an executor thread exactly as it
    /// would have held the caller's (ADR 0073).
    hop: type,
};

/// `Options` with `threading` settled, or a compile error saying why it
/// cannot be. The whole of ADR 0073 is that this choice is made rather than
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
        /// the choice in ADR 0073 is about where a statement *runs*, and this
        /// is about waiting for a turn to run it.
        io: std.Io,
        /// Index 0 is the writer. Everything after it is a read-only reader.
        conns: []Conn,
        lock: std.Io.Mutex = .init,
        /// **One queue per question, and that is the fix rather than a
        /// tidying** (ADR 0116). These used to be a single `Condition` that
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
        /// a `signal` consumed by a waiter that then answers `TimedOut` is a
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
        /// honoured on Postgres (ADR 0135).
        queue_timeout_ms: u32,
        /// What can reach a waiting fiber to stop it. `.off` in a program
        /// with no Engine, where nothing can cancel a fiber and the wait is
        /// unbounded — see `wire.OpenOpts.limits`.
        limits: core.Limits,

        /// One connection and the statements kept prepared on it.
        ///
        /// The cache is per connection because a `sqlite3_stmt` belongs to the
        /// `sqlite3` it was prepared against — which is the same reason
        /// [ADR 0057](../docs/adr/0057-a-statement-that-is-a-constant-can-be-prepared-once.md)
        /// gives for Postgres, arriving here from a different direction.
        const Conn = struct {
            handle: zqlite.Conn,
            /// Keyed by the plan name, which is a comptime constant derived
            /// from the statement. `db.raw` passes null and is not cached: its
            /// text arrives at run time, so a cache would grow with traffic
            /// rather than with the program.
            kept: std.StringHashMapUnmanaged(zqlite.Stmt) = .empty,
            busy: bool = false,

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

            pub fn run(
                self: *Tx,
                arena: std.mem.Allocator,
                sql: []const u8,
                values: anytype,
                plan: ?[]const u8,
                problem: ?*?wire.Problem,
            ) wire.Error!Rows {
                if (self.done) return error.QueryFailed;
                const stmt, const kept = self.wire.stmtOn(self.at, sql, plan, values) catch |err| {
                    self.wire.said(self.at, err, arena, problem);
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
                return self.wire.execOn(self.at, sql, plan, values) catch |err| {
                    self.wire.said(self.at, err, arena, problem);
                    return err;
                };
            }

            /// **Refused, and the dialect is named.**
            ///
            /// [ADR 0047](../docs/adr/0047-a-deadline-needs-a-connection-you-hold.md)
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
            /// happens — waiting on a lock nobody is releasing (ADR 0074).
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

                const verb = switch (op) {
                    .mark => "SAVEPOINT ",
                    .undo => "ROLLBACK TO SAVEPOINT ",
                    .keep => "RELEASE SAVEPOINT ",
                };
                var buf: [verb.len + name_prefix.len + 10 + 1]u8 = undefined;
                const sql = std.fmt.bufPrintZ(&buf, verb ++ name_prefix ++ "{d}", .{id}) catch
                    unreachable;
                try self.wire.command(self.at, sql);
            }

            const name_prefix = "nilo_sp_";

            pub fn commit(self: *Tx) wire.Error!void {
                if (self.done) return;
                self.done = true;
                defer self.wire.release(self.at);
                try self.wire.command(self.at, "COMMIT");
            }

            /// Cannot fail, because it is called from a `defer` on the way out
            /// of a function that is already failing.
            pub fn rollback(self: *Tx) void {
                if (self.done) return;
                self.done = true;
                defer self.wire.release(self.at);
                self.wire.command(self.at, "ROLLBACK") catch |err| {
                    std.log.err(
                        "nilo_sql: a transaction could not be rolled back ({s}).",
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
        /// without writing two option structs (ADR 0060).
        pub fn open(
            io: std.Io,
            gpa: std.mem.Allocator,
            url: []const u8,
            open_opts: wire.OpenOpts,
        ) !Self {
            if (isBarePrivateMemory(url)) return error.PrivateMemoryDatabase;

            const size = @max(open_opts.size, 2);
            const conns = try gpa.alloc(Conn, size);
            errdefer gpa.free(conns);

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (url.len >= path_buf.len) return error.PathTooLong;
            const path = std.fmt.bufPrintZ(&path_buf, "{s}", .{url}) catch return error.PathTooLong;

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
        fn prime(conn: zqlite.Conn, writer: bool) !void {
            var buf: [64]u8 = undefined;

            try conn.busyTimeout(@intCast(opts.busy_timeout_ms));

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
                    std.fmt.bufPrintZ(&buf, "PRAGMA cache_size = -{d}", .{kib}) catch unreachable,
                );
            }
        }

        /// `:memory:` on its own is private to the connection that opened it,
        /// so a pool of one writer and several readers opened on it would be
        /// *several separate empty databases* — writes going to one and reads
        /// finding nothing, which reads as a bug in the caller's code.
        ///
        /// Refused rather than worked around, because the shared form is a
        /// different string and the caller has to know which one they have:
        /// `file:name?mode=memory&cache=shared` is one database, and it lives
        /// only as long as a connection to it does.
        fn isBarePrivateMemory(url: []const u8) bool {
            return std.mem.eql(u8, url, ":memory:") or url.len == 0;
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
        /// **A cancelled wait answers `TimedOut`**, which is the one place
        /// this Wire has a deadline at all: `tx.deadline` is refused
        /// (ADR 0074), but a request whose fiber is cancelled while queueing
        /// gives its turn up rather than holding it. The name is right for
        /// what the handler has to decide — this statement is not going to
        /// run.
        ///
        /// **The queue is bounded by `timeout_ms`, and the timer is armed
        /// only by a fiber that is actually going to wait** (ADR 0135). A
        /// statement that finds the writer free pays nothing at all: arming
        /// is the Engine registering a timer, and doing that per statement
        /// would put the cost on the path that is never in trouble. The
        /// `Bound` costs `core.Limits.slot_size` bytes of this frame either
        /// way, which is stack a handler touches and therefore per
        /// connection (ADR 0063).
        fn takeWriter(self: *Self) wire.Error!usize {
            self.lock.lock(self.io) catch return error.TimedOut;
            defer self.lock.unlock(self.io);

            if (!self.conns[0].busy) {
                self.conns[0].busy = true;
                return 0;
            }

            var bound: core.Limits.Bound = .idle;
            defer bound.release();
            bound.arm(self.limits, self.queue_timeout_ms);

            while (self.conns[0].busy) self.free_writer.wait(self.io, &self.lock) catch
                return self.gaveUp(&bound, .writer);
            self.conns[0].busy = true;
            return 0;
        }

        /// Any free reader, or wait for one — bounded the same way, and armed
        /// only once every reader has turned out to be busy.
        fn takeReader(self: *Self) wire.Error!usize {
            self.lock.lock(self.io) catch return error.TimedOut;
            defer self.lock.unlock(self.io);

            var bound: core.Limits.Bound = .idle;
            defer bound.release();

            while (true) {
                for (self.conns[1..], 1..) |*conn, i| {
                    if (conn.busy) continue;
                    conn.busy = true;
                    return i;
                }
                if (!bound.armed) bound.arm(self.limits, self.queue_timeout_ms);
                self.free_reader.wait(self.io, &self.lock) catch
                    return self.gaveUp(&bound, .reader);
            }
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
        /// **The writer's message names the mistake that produces it most
        /// often.** There is exactly one writer, so a handler holding a `tx`
        /// and then sending a statement through `db` rather than `tx` queues
        /// for a connection it is itself holding. What this cannot do is
        /// *say* that is what happened: telling it apart from an honestly
        /// busy database means knowing which fiber holds the writer, and
        /// `std.Io` hands a Service no fiber identity to hold it by
        /// (ADR 0135).
        fn gaveUp(self: *Self, bound: *core.Limits.Bound, want: enum { writer, reader }) wire.Error {
            if (!bound.fired()) return error.TimedOut;
            switch (want) {
                .writer => std.log.warn(
                    "nilo_sql: a statement waited {d}ms for the writer connection and gave up. " ++
                        "There is one writer, so either the database is busy or this fiber is " ++
                        "queueing for a connection it already holds — a `db.…` call inside a " ++
                        "handler holding a `tx` waits for itself. `timeout_ms` is the bound.",
                    .{self.queue_timeout_ms},
                ),
                .reader => std.log.warn(
                    "nilo_sql: a statement waited {d}ms for a reader connection and gave up, " ++
                        "with all {d} of them busy. Raise `size`, or shorten what a request " ++
                        "holds one for. `timeout_ms` is the bound.",
                    .{ self.queue_timeout_ms, self.conns.len - 1 },
                ),
            }
            return error.TimedOut;
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
        /// than answering from the wrong snapshot (ADR 0074).
        ///
        /// `WITH` goes to the writer. A CTE may write, the keyword does not
        /// say, and being wrong in that direction costs a report the writer's
        /// time rather than costing correctness.
        fn wantsWriter(sql: []const u8) bool {
            const text = std.mem.trimStart(u8, sql, " \t\r\n");
            return !(std.ascii.startsWithIgnoreCase(text, "SELECT") or
                std.ascii.startsWithIgnoreCase(text, "PRAGMA"));
        }

        // -- statements --------------------------------------------------

        /// The prepared statement for `sql` on connection `at`, bound to
        /// `values`, plus whether it came from the cache.
        ///
        /// A cached statement is reset and its bindings cleared before it is
        /// bound again: SQLite keeps the previous bindings otherwise, so a
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
            // Once, at the top, rather than at the four `bind` calls below —
            // a conversion applied at three of four sites is a bug that only
            // shows up on the fourth path (`blobbed`).
            const args = blobbed(values);

            if (plan) |name| {
                if (conn.kept.get(name)) |stmt| {
                    stmt.reset() catch return error.QueryFailed;
                    stmt.clearBindings() catch return error.QueryFailed;
                    stmt.bind(args) catch |err| return translate(conn.handle, err);
                    return .{ stmt, true };
                }
                const stmt = conn.handle.prepare(sql) catch |err|
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

            const stmt = conn.handle.prepare(sql) catch |err| return translate(conn.handle, err);
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

            onThread(zqlite.Stmt.stepToCompletion, .{stmt}) catch |err|
                return translate(conn.handle, err);
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
                .hop => |Engine| Engine.blocking(f, args),
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
            const at = if (wantsWriter(sql)) try self.takeWriter() else try self.takeReader();
            errdefer self.release(at);
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
            const at = try self.takeWriter();
            defer self.release(at);
            return self.execOn(at, sql, plan, values) catch |err| {
                self.said(at, err, arena, problem);
                return err;
            };
        }

        /// What SQLite said about the statement that just failed, left where a
        /// program can read it rather than only in the log
        /// ([ADR 0146](../docs/adr/0146-a-statement-that-failed-says-what-the-database-said.md)).
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
            slot.* = .{ .message = arena.dupe(u8, text) catch @errorName(err) };
        }

        pub fn next(self: *Self, rows: *Rows) wire.Error!bool {
            const stmt = rows.stmt;
            return onThread(zqlite.Stmt.step, .{stmt}) catch |err|
                translate(self.conns[rows.at].handle, err);
        }

        /// How many columns the row `next` just stopped on has.
        ///
        /// **Only answerable once a row is under it**, which is what decides
        /// where `fill` asks (ADR 0134): zqlite's `columnCount` is
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
            // and that is the fix** (ADR 0118). The test used to live inside
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
            // and is skipped by design (ADR 0056), and it does not run at all
            // for a `Db` nobody called `checking` on.
            //
            // What it costs is one `sqlite3_column_type` — a couple of loads,
            // no allocation — per non-optional column per row. The optional
            // ones were already paying it.
            if (stmt.columnType(col) == .null) {
                if (optional) return null;
                // `warn` rather than `err` for the reason `db.wireOf`'s is
                // one: `std.log.err` fails the test runner for every test
                // that provokes it, which is how a diagnostic ends up deleted
                // rather than fixed. The error is what the caller acts on.
                std.log.warn(
                    "nilo_sql: column {d} came back NULL and the Row reads it as {s}, " ++
                        "which cannot hold one. Make the field optional, or make the " ++
                        "column NOT NULL. A view is the case the startup check cannot " ++
                        "see (ADR 0056).",
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

            return switch (@typeInfo(Inner)) {
                .bool => stmt.boolean(col),
                .int => std.math.cast(Inner, stmt.int(col)) orelse error.QueryFailed,
                .float => @floatCast(stmt.float(col)),
                .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8)
                    stmt.text(col)
                else
                    error.QueryFailed,
                else => error.QueryFailed,
            };
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

            const at = if (opts_.read_only) try self.takeReader() else try self.takeWriter();
            errdefer self.release(at);
            try self.command(at, if (opts_.read_only) "BEGIN" else "BEGIN IMMEDIATE");
            return .{ .wire = self, .at = at };
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

        /// The columns the database says a table has.
        ///
        /// **The schema goes into the text rather than into a parameter**, and
        /// that is the seam's one loose joint — written down in ADR 0061
        /// before this file existed. SQLite's `pragma_table_info` is a
        /// table-valued function and a schema qualifies the *function's* name,
        /// where Postgres puts it in a `WHERE` and binds it.
        ///
        /// **Every occurrence, not the first.** `dialect.SQLite.introspect`
        /// names `pragma_table_info` twice since ADR 0115 — once in the `FROM`
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
            var buf: [1024]u8 = undefined;
            const text = if (schema) |db_name| blk: {
                const fn_name = "pragma_table_info";
                var written: usize = 0;
                var rest = query;
                var qualified = false;
                while (std.mem.indexOf(u8, rest, fn_name)) |at| {
                    const piece = std.fmt.bufPrint(buf[written..], "{s}\"{s}\".{s}", .{
                        rest[0..at], db_name, fn_name,
                    }) catch return error.QueryFailed;
                    written += piece.len;
                    rest = rest[at + fn_name.len ..];
                    qualified = true;
                }
                if (!qualified) return error.QueryFailed;
                const tail = std.fmt.bufPrint(buf[written..], "{s}", .{rest}) catch
                    return error.QueryFailed;
                break :blk buf[0 .. written + tail.len];
            } else query;

            // No problem slot: this runs once per Row while the server is
            // starting, and the one caller already has a sentence for a check
            // it could not run.
            var rows = try self.run(arena, text, .{table}, null, null);
            defer rows.close();

            var found: std.ArrayList(wire.Column) = .empty;
            while (try self.next(&rows)) {
                const name = try self.read(&rows, []const u8, 0);
                const udt = try self.read(&rows, []const u8, 1);
                const nullable = try self.read(&rows, []const u8, 2);
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
    };
}

/// A zqlite error as one of the seven this module admits to (ADR 0039).
///
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
        const fields = @typeInfo(V).@"struct".fields;
        var out: [fields.len]type = undefined;
        var changed = false;
        for (fields, 0..) |f, i| {
            out[i] = switch (f.type) {
                wire.Bytes => zqlite.Blob,
                ?wire.Bytes => ?zqlite.Blob,
                else => f.type,
            };
            if (out[i] != f.type) changed = true;
        }
        if (!changed) return V;
        const frozen = out;
        return std.meta.Tuple(&frozen);
    }
}

fn blobbed(values: anytype) Blobbed(@TypeOf(values)) {
    const V = @TypeOf(values);
    if (comptime Blobbed(V) == V) return values;

    var out: Blobbed(V) = undefined;
    inline for (@typeInfo(V).@"struct".fields, 0..) |f, i| {
        const held = @field(values, f.name);
        out[i] = switch (f.type) {
            wire.Bytes => zqlite.blob(held.bytes),
            ?wire.Bytes => if (held) |b| zqlite.blob(b.bytes) else null,
            else => held,
        };
    }
    return out;
}

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
        // by SQLSTATE (ADR 0184). **Both Wires answer the same word for the
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
            std.log.err(
                "nilo_sql: a statement tried to write down a read-only connection. " ++
                    "`db.raw` is routed by its first keyword, so a write that does not " ++
                    "begin with a write verb lands on a reader: {s}",
                .{conn.lastError()},
            );
            return error.QueryFailed;
        },
        error.CantOpen, error.IoErr, error.NotADB, error.Corrupt => error.Disconnected,

        else => {
            // The text never reaches the client (ADR 0025); it goes here,
            // where whoever reads the log is the person who can fix it.
            std.log.err("nilo_sql: {s} [{s}]", .{ conn.lastError(), @errorName(err) });
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
/// into `nilo.blocking`, and what is worth testing is the statement rather
/// than which thread ran it.
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
/// Each test names its own, because a shared in-memory database is keyed by
/// that name and two tests on one name would be one database.
fn openTest(io: std.Io, name: [:0]const u8, size: u16) !TestWire {
    return TestWire.open(io, testing.allocator, name, .{ .size = size });
}

test "the sqlite wire satisfies the contract" {
    comptime wire.assertWire(TestWire);
}

test "a bare :memory: is refused, because a pool of them is several databases" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            try testing.expectError(
                error.PrivateMemoryDatabase,
                openTest(io, ":memory:", 4),
            );
            // The shared form is the one that works, and the message the
            // caller gets has to name it — otherwise the fix is a search
            // rather than a read.
            var w = try openTest(io, "file:refused-check?mode=memory&cache=shared", 2);
            w.close();
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
            // error rather than a zero (ADR 0118). It used to be `0` for the
            // integer and `""` for the text, because the null test only ran
            // for an optional field — the same class of wrong-answer-that-
            // looks-right as the truncation below, arriving from the other
            // side. Postgres refuses both; this is where SQLite caught up.
            try testing.expectError(error.QueryFailed, w.read(&rows, i64, 0));
            try testing.expectError(error.QueryFailed, w.read(&rows, []const u8, 2));
            try testing.expectEqual(@as(?[]const u8, null), try w.read(&rows, ?[]const u8, 2));
            // SQLite has one integer type, so a field too narrow for the value
            // is the one class of mismatch its schema check cannot catch
            // beforehand (ADR 0061). It has to be an error rather than a
            // truncation, because a truncated id is a wrong answer that looks
            // like a right one.
            try testing.expectError(error.QueryFailed, w.read(&rows, i16, 1));
            try testing.expectEqual(@as(i32, 70_000), try w.read(&rows, i32, 1));
        }
    }.run);
}

test "a returning reader wakes the fiber that wanted a reader, not the one that wanted the writer" {
    // **If this test ever hangs, the pool has lost a wakeup** — that is the
    // failure it exists to catch, and the diagnosis is `ps -o etime,cputime`
    // showing minutes of wall against no CPU. Before ADR 0116 both `take`
    // calls waited on one `Condition` while testing different predicates, so
    // `release` waking one fiber could wake the one that could not proceed.
    //
    // `withIoPair` rather than `withIo`, and that is not a detail: see its
    // doc. Two parked fibers need two threads to have been asked for.
    try withIoPair(struct {
        fn takeOne(w: *TestWire, want_writer: bool, out: *usize) void {
            out.* = (if (want_writer) w.takeWriter() else w.takeReader()) catch 99;
        }

        fn run(io: std.Io) !void {
            // One writer and two readers, so both queues can hold somebody.
            var w = try openTest(io, "file:pool-wakeups?mode=memory&cache=shared", 3);
            defer w.close();

            // Every connection taken, so anybody asking now has to park.
            try testing.expectEqual(@as(usize, 0), try w.takeWriter());
            try testing.expectEqual(@as(usize, 1), try w.takeReader());
            try testing.expectEqual(@as(usize, 2), try w.takeReader());

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

test "the introspection query reads the rowid alias as not-null, and its near misses as null" {
    // `dialect.SQLite.introspect` is asked directly rather than through
    // `db.checkSchema`, which reports a problem with `std.log.err` and so
    // fails the test runner for every test that provokes one. What is being
    // held here is the query's three answers, which is what the check is
    // built out of (ADR 0115).
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
                // A column with no declared type at all, which SQLite allows.
                // Here because ADR 0118 made a NULL in a non-optional field an
                // error, and this query reads `upper(i.type)` as a
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
            // SQLite's rule is the declared type spelled exactly `INTEGER`, and
            // this column really does accept a NULL.
            try testing.expectEqual(@as(?bool, true), try nullableOf(&w, arena, "not_integer", "id"));

            // A composite key over a rowid table — the shape of every
            // multi-tenant schema. Every column of it may hold a NULL, which is
            // SQLite's own long-standing quirk, so neither becomes the rowid.
            try testing.expectEqual(@as(?bool, true), try nullableOf(&w, arena, "composite", "tenant_id"));
            try testing.expectEqual(@as(?bool, true), try nullableOf(&w, arena, "composite", "id"));

            // The untyped column reads without the whole query failing, and
            // the rowid beside it is still the rowid.
            try testing.expectEqual(@as(?bool, true), try nullableOf(&w, arena, "untyped", "whatever"));
            try testing.expectEqual(@as(?bool, false), try nullableOf(&w, arena, "untyped", "id"));

            // And the third answer still arrives: a view says nothing about
            // nullability and the check skips it (ADR 0056). The rowid branch
            // sits behind the view branch so this cannot be turned into a
            // `false` by an `id` that came from an aliased column.
            try testing.expectEqual(@as(?bool, null), try nullableOf(&w, arena, "as_view", "id"));
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

            // One entry, on the one reader that ran it — the cache is per
            // connection because a prepared statement belongs to the
            // connection it was prepared against (ADR 0057).
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
            // ADR 0033 asks for: a guard seen to fail.
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
            // its own since ADR 0184, so a handler can say which one fired.
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
                try tx.commit();
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
            try tx.commit();

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
            try tx.commit();

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
    // `OpenFlags.ReadOnly` is what ADR 0074 leans on: routing `db.raw` by its
    // first keyword is a guess, and a guess that goes the wrong way has to
    // land somewhere it cannot do damage. But SQLite's URI `mode=` parameter
    // takes precedence over the flags handed to `sqlite3_open_v2`, so
    // `mode=memory` **silently gives a read-only connection write access**.
    // This test asserted the refusal against an in-memory database and failed,
    // which is how that was found; check 6c of `spike/sqlite_facts` is where
    // it is pinned.
    //
    // So the backstop exists on a file and does not exist in memory — one more
    // thing a suite running entirely in memory would never have tested.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp_sub_path = tmp.sub_path;

    try withIo(struct {
        fn run(io: std.Io) !void {
            var path: [96]u8 = undefined;
            const url = try std.fmt.bufPrintZ(
                &path,
                ".zig-cache/tmp/{s}/roles.db",
                .{tmp_sub_path},
            );

            var w = try openTest(io, url, 4);
            defer w.close();
            const gpa = testing.allocator;

            try testing.expectEqual(@as(usize, 4), w.conns.len);
            _ = try w.exec(gpa, "CREATE TABLE t(id INTEGER PRIMARY KEY)", .{}, null, null);

            // ADR 0074's backstop, seen to fail rather than assumed to work
            // (ADR 0033).
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

/// Where `std.testing.tmpDir` put the directory the test above uses. A file
/// rather than a shared in-memory database, and the path has to reach a
/// closure `withIo` calls as a plain function.
var tmp_sub_path: [@typeInfo(@FieldType(std.testing.TmpDir, "sub_path")).array.len]u8 = undefined;

test "each constraint a caller branches on arrives under its own name" {
    // Item 55: `23503` used to arrive as `ConstraintViolated` beside a check
    // somebody wrote and a null the code should never have sent, so the one
    // failure in class 23 that is routinely a race could not be told from the
    // two that mean the program is wrong (ADR 0184).
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
