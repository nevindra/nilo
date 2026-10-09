//! The Wire, filled in with pg.zig. **The only file in this module allowed
//! to name pg.zig** — the same rule `http/engine/zio.zig` lives under, for
//! the same reason (ADR 001, ADR 036).
//!
//! Everything above this file talks to `wire.zig`'s contract. If pg.zig
//! stops being maintained, or a second driver turns up, this file is what
//! gets rewritten and nothing else does.
//!
//! ## Three things pg.zig does that this file exists to hold on to
//!
//! **A query can be told which allocator to read into.** `queryOpts` takes
//! one, and pg.zig's own example says out loud that a per-request arena is
//! what it is for. So a row that needs to allocate allocates in the request
//! arena and is freed by the arena reset that ends the request — no `free`,
//! no leak, and nothing added to the request's allocation budget that the
//! arena was not already going to do (ADR 003).
//!
//! **Text in a row is valid only until the next `next()`.** That is pg.zig's
//! rule, and `wire.zig` passes it along unwrapped rather than hiding it
//! behind a `Str`, whose whole meaning is that holding it is safe. `db.zig`
//! is where it stops: a Row filled for a handler has its text copied into
//! the arena on the way past.
//!
//! **A connection has to go back.** `acquire` and `release` are a pair, and
//! `release` on a connection that is not idle destroys it and dials a new
//! one. Both are held by `Rows.close`, which every path out of a query
//! runs.
//!
//! **A prepared statement can outlive the table it was prepared against.**
//! Every statement with a plan name is prepared once per connection and kept
//! (ADR 051), so a migration that changes a column's type under a running
//! server leaves each connection holding a plan Postgres now refuses with
//! `0A000`, *cached plan must not change result type*. Outside a transaction
//! the statement is deallocated and sent once more; inside one the
//! transaction is already aborted, so it answers `error.RolledBack` and the
//! plan is deallocated when the transaction ends (`stalePlan`).
//!
//! ## What is deliberately not here
//!
//! `LISTEN`/`NOTIFY` and `COPY`. Both are outside this module's scope and
//! reached by naming pg.zig directly, which `wire.zig` says is allowed and is
//! why this seam is not called a Bulkhead.

const std = @import("std");
const builtin = @import("builtin");
const pg = @import("pg");

const types = @import("types.zig");
const wire = @import("wire.zig");
/// The plan reader `describe` hands `EXPLAIN`'s answer to (ADR 233).
const plan_reader = @import("plan.zig");
const core = @import("nilo_core");

/// A pool of connections, behind the contract in `wire.zig`.
pub const Wire = struct {
    pool: *pg.Pool,
    /// The `Io` the pool was opened on, kept here rather than read back out
    /// of pg.zig's own fields: a cancellation this file turns into an error
    /// of its own is re-armed through it, and a connection is given back
    /// with cancellation held off through it (ADR 223).
    io: std.Io,
    /// What the Engine handed `nilo_start`: every wait on a connection or
    /// its socket is reported through it, so the watchdog counts the fiber
    /// as parked rather than as a handler holding its thread (ADR 210).
    limits: core.Limits = .off,

    /// One result set, and the connection it is being read from. Both go
    /// back in `close`.
    pub const Rows = struct {
        conn: *pg.Conn,
        result: *pg.Result,
        /// The row `next` last handed back. `read` indexes into this, which
        /// is why the two are a pair and why the text is only good until
        /// the following `next`.
        current: ?pg.Row = null,
        /// Whether this result set is the connection's owner.
        ///
        /// False inside a transaction, where the `Tx` holds the connection
        /// for its whole life and every statement in it borrows the same
        /// one. Releasing it here would put a connection back in the pool
        /// with an open transaction on it — the exact failure the header of
        /// `wire.zig` is about.
        owns_conn: bool = true,
        /// The Wire's `Io`, for giving the connection back (ADR 223).
        io: std.Io,
        /// The wait `run` opened and this result is still inside: the
        /// exchange and every row read after it reach the socket, and are
        /// one park to the watchdog rather than one per row (ADR 210).
        /// Closed by `close`, where the handler has the whole result.
        limits: core.Limits = .off,
        wait: u64 = 0,

        /// Give the connection back, whatever happened. Named rather than
        /// deferred inside `run` because the caller's loop outlives that
        /// call — `db.zig` defers this.
        pub fn close(self: *Rows) void {
            self.result.deinit();
            if (self.owns_conn) giveBack(self.io, self.conn);
            self.limits.waited(self.wait);
        }
    };

    /// A transaction, and the connection it owns until it ends.
    ///
    /// Every statement inside one has to travel down the same connection,
    /// so this holds one rather than taking a fresh one per statement.
    /// Getting that wrong would not fail loudly: half a transaction would
    /// simply run somewhere else and commit on its own.
    pub const Tx = struct {
        wire: *Wire,
        conn: *pg.Conn,
        /// Set by whichever of `commit`/`rollback` got there first, so the
        /// second one does nothing and the connection is released once.
        done: bool = false,
        /// Whether a statement failed at the server since `BEGIN` or since
        /// the last `ROLLBACK TO SAVEPOINT`, which is exactly when Postgres
        /// holds the transaction aborted. Read off the connection by `fresh`
        /// before it forgets the error, because pg.zig's `.fail` is also what
        /// a dead socket leaves and only a server that answered can be told
        /// to roll back.
        ///
        /// **What `commit` asks before it sends anything.** A `COMMIT` on an
        /// aborted transaction is answered with the command tag `ROLLBACK`
        /// and no error, and pg.zig does not read the tag — so a handler that
        /// caught a statement's error without a savepoint and went on to
        /// commit was told the commit worked, answered 200, and kept none of
        /// it.
        aborted: bool = false,
        /// A plan this transaction found Postgres no longer honours
        /// (`stalePlan`), deallocated once the rollback has let the
        /// connection take a statement again. A comptime plan name, so
        /// holding the slice costs nothing.
        stale: ?[]const u8 = null,
        /// Begun with `.transaction = false`: a held connection and no
        /// `BEGIN`, so `commit` and `rollback` send nothing and only give it
        /// back (ADR 269).
        plain: bool = false,

        /// Forget the last statement's server error before running the next.
        ///
        /// `translate` reads the code off the connection, because that is
        /// where pg.zig leaves it — and pg.zig clears it in `release`, which
        /// happens after every statement that came out of the pool. A
        /// transaction is the one place that does not hold: it keeps its
        /// connection from `BEGIN` to `COMMIT`, so the field outlives the
        /// statement that set it. A unique violation followed by a broken
        /// pipe was then reported as `AlreadyExists` — the older statement's
        /// answer to a question nobody asked twice.
        ///
        /// Cleared here rather than reordered inside `translate`, because
        /// ordering only fixes the failures that have a spelling of their own
        /// (`BrokenPipe`, `ConnectionResetByPeer`); anything else would still
        /// read the stale code. This is the whole of what is wrong: the field
        /// is about a statement, so it is emptied when a statement starts.
        ///
        /// What the error said about the transaction is kept before the error
        /// goes: a server that answered and left pg.zig in `.fail` has
        /// aborted the transaction (`aborted`).
        fn fresh(self: *Tx) void {
            if (self.conn.err != null and self.conn._state == .fail) self.aborted = true;
            self.conn.err = null;
        }

        /// Let the connection out of pg.zig's `.fail` when what actually
        /// happened was an aborted transaction rather than a broken socket.
        ///
        /// Postgres answers a failed statement inside a transaction with a
        /// ReadyForQuery whose status byte is `E`: *this transaction is
        /// aborted*. That is a state the session recovers from with exactly
        /// one command — `ROLLBACK` — and Postgres will take it down the same
        /// connection. pg.zig reads the byte and maps it to `.fail`, which is
        /// also what it sets when the socket itself dies, and `canQuery`
        /// refuses both. So the rollback this module has to send came back
        /// `ConnectionBusy`, and **every failed statement inside a
        /// transaction cost a full reconnect** — a correct answer, at the
        /// price of TCP, TLS and auth, on a path nothing was measuring.
        ///
        /// The two cases are told apart by whether the server answered:
        /// `conn.err` is set only by an ErrorResponse, and `fresh` turns that
        /// into `aborted` before emptying it — so `aborted` here means a
        /// statement got a reply and the socket is alive. A transport failure
        /// leaves it false and this does nothing, which is the case where
        /// destroying the connection is right.
        ///
        /// **Every statement goes through here, not only the undo.** A
        /// statement sent into an aborted transaction used to be refused by
        /// pg.zig before it left the process, as `ConnectionBusy`, which this
        /// file reports as `Disconnected` and which destroyed the connection.
        /// Revived, it reaches the server and is answered `25P02` — *current
        /// transaction is aborted* — which is the truth, costs no reconnect,
        /// and is the answer the guide has always said a caller gets.
        ///
        /// Delete this when pg.zig tells an aborted transaction apart from a
        /// broken connection. It is the only place in nilo that writes
        /// `_state`, and `postgres.zig` is the one file allowed to (ADR 036).
        fn revive(self: *Tx) void {
            if (!self.aborted) return;
            if (self.conn._state != .fail) return;
            self.conn._state = .transaction;
        }

        /// `fresh` then `revive`, which every statement on a transaction
        /// starts with, in that order: the first reads what the last
        /// statement left, and the second acts on it.
        fn settle(self: *Tx) void {
            self.fresh();
            self.revive();
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
            self.settle();
            const w = self.wire.limits.waiting();
            errdefer self.wire.limits.waited(w);
            const result = self.conn.queryOpts(sql, opened(values), .{
                .allocator = arena,
                .cache_name = plan,
            }) catch |err| {
                self.noteStale(plan);
                return reported(self.wire.io, self.conn, err, arena, problem);
            };
            return .{ .conn = self.conn, .result = result, .owns_conn = false, .io = self.wire.io, .limits = self.wire.limits, .wait = w };
        }

        /// `Wire.columnsOf` down this transaction's connection, so a
        /// migration that holds one does not ask the pool for a second.
        pub fn columnsOf(
            self: *Tx,
            arena: std.mem.Allocator,
            query: []const u8,
            schema: ?[]const u8,
            table: []const u8,
        ) wire.Error![]const wire.Column {
            var rows = try self.run(arena, query, .{ schema, table }, null, null);
            defer rows.close();
            return self.wire.columnList(arena, &rows);
        }

        /// Remember a plan Postgres refused as stale, for `rollback` to
        /// deallocate. It cannot be done here: the refusal aborted the
        /// transaction, and an aborted transaction takes no `DEALLOCATE`.
        fn noteStale(self: *Tx, plan: ?[]const u8) void {
            const name = plan orelse return;
            if (stalePlan(self.conn) or planGone(self.conn)) self.stale = name;
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
            self.settle();
            const w = self.wire.limits.waiting();
            defer self.wire.limits.waited(w);
            const count = self.conn.execOpts(sql, opened(values), .{
                .allocator = arena,
                .cache_name = plan,
            }) catch |err| {
                self.noteStale(plan);
                return reported(self.wire.io, self.conn, err, arena, problem);
            };
            return @intCast(count orelse 0);
        }

        /// `SET LOCAL statement_timeout`, which Postgres undoes at the end of
        /// this transaction whichever way it ends. One round trip, and it is
        /// the caller who asked for it.
        ///
        /// **The statement is built rather than a constant, and that does not
        /// move ADR 036's line.** The rule is about the shape of a query
        /// being settled while compiling; this is a session command with a
        /// `u32` this module printed itself. Nothing a request supplies
        /// reaches it, and there is no `SET` that takes a placeholder — the
        /// parameter form does not exist in Postgres, so a constant was never
        /// on offer.
        pub fn deadline(self: *Tx, ms: u32) wire.Error!void {
            if (self.done) return error.QueryFailed;
            self.settle();
            var buf: [48]u8 = undefined;
            // `SET LOCAL statement_timeout = N` counts milliseconds, which is
            // the unit the argument is named for.
            const sql = std.fmt.bufPrint(&buf, "SET LOCAL statement_timeout = {d}", .{ms}) catch
                unreachable;
            const w = self.wire.limits.waiting();
            defer self.wire.limits.waited(w);
            _ = self.conn.exec(sql, .{}) catch |err| return translate(self.wire.io, self.conn, err);
        }

        /// `SAVEPOINT nilo_sp_3`, and the two ways back out of it.
        ///
        /// **The statement is built rather than a constant, for the reason
        /// `deadline` gives**: the number is one this module counted, no
        /// request supplies it, and there is no `SAVEPOINT $1` in Postgres —
        /// a savepoint name is an identifier, and identifiers do not take
        /// placeholders. So the alternative to printing it here is not a
        /// constant, it is not having savepoints.
        ///
        /// Rolling back to a savepoint is the one thing a caller does
        /// *because* the last statement failed, and it is the one statement
        /// an aborted transaction takes: once it succeeds the transaction is
        /// live again, so `aborted` is cleared.
        pub fn savepoint(
            self: *Tx,
            arena: std.mem.Allocator,
            comptime op: wire.SavepointOp,
            id: u32,
        ) wire.Error!void {
            _ = arena;
            if (self.done) return error.QueryFailed;
            self.settle();
            defer if (op == .undo and self.conn._state == .transaction) {
                self.aborted = false;
            };

            const verb = switch (op) {
                .mark => "SAVEPOINT ",
                .undo => "ROLLBACK TO SAVEPOINT ",
                .keep => "RELEASE SAVEPOINT ",
            };
            // The longest verb, the prefix, and ten digits of a u32.
            var buf: [verb.len + name_prefix.len + 10]u8 = undefined;
            const sql = std.fmt.bufPrint(&buf, verb ++ name_prefix ++ "{d}", .{id}) catch
                unreachable;
            const w = self.wire.limits.waiting();
            defer self.wire.limits.waited(w);
            _ = self.conn.exec(sql, .{}) catch |err| return translate(self.wire.io, self.conn, err);
        }

        /// What a savepoint is called on the server. Prefixed so that it
        /// cannot collide with one a `tx.raw` put down by hand.
        const name_prefix = "nilo_sp_";

        /// `problem` is where a COMMIT the server refused leaves its words: a
        /// deferred constraint is checked here and nowhere else, so this is
        /// the only place `sql.violated` can learn which key it was.
        pub fn commit(self: *Tx, arena: std.mem.Allocator, problem: ?*?wire.Problem) wire.Error!void {
            if (self.done) return;
            self.fresh();
            // **An aborted transaction is rolled back and the commit fails.**
            // Sent, the COMMIT would come back tagged `ROLLBACK` with no
            // error, and the caller would be told that work it lost was kept
            // (`aborted`).
            if (self.aborted and !self.plain) {
                // A ROLLBACK that could not be sent means the socket is gone
                // as well, and that is the nearer truth: the server rolls the
                // transaction back when the connection drops.
                if (self.undo()) |_| return error.Disconnected;
                std.log.warn("{s}", .{wire.aborted_commit});
                return error.QueryFailed;
            }
            self.done = true;
            defer giveBack(self.wire.io, self.conn);
            // Nothing was begun, so nothing is committed.
            if (self.plain) return;
            const w = self.wire.limits.waiting();
            defer self.wire.limits.waited(w);
            // **Held off from cancellation, the way a rollback is** (ADR 223).
            // A COMMIT cut off after it was written and before its answer was
            // read leaves nobody knowing whether the transaction landed: the
            // server may have committed it, and the caller hears
            // `QueryFailed`. Held off, it runs to its answer, and a
            // cancellation that arrived meanwhile is put back for the
            // caller's next cancellation point.
            if (std.Io.checkCancel(self.wire.io)) |_| {} else |_| self.wire.io.recancel();
            const was = self.wire.io.swapCancelProtection(.blocked);
            defer _ = self.wire.io.swapCancelProtection(was);
            _ = self.conn.exec("COMMIT", .{}) catch |err| return reported(self.wire.io, self.conn, err, arena, problem);
        }

        /// Cannot fail, because it is called from a `defer` on the way out
        /// of a function that is already failing. A rollback that did not
        /// reach the server leaves a connection this module cannot vouch
        /// for, so that connection is destroyed rather than returned —
        /// which is what `release` does with one that is not idle.
        pub fn rollback(self: *Tx) void {
            const err = self.undo() orelse return;
            std.log.warn(
                "nilo_sql: a transaction could not be rolled back ({s}). The connection " ++
                    "is being dropped rather than returned to the pool.",
                .{@errorName(err)},
            );
        }

        /// The ROLLBACK, and the connection given back: what the ROLLBACK
        /// failed with, or null when it landed — or when a cancellation is
        /// what cut it off, which is a shutdown rather than a failure.
        /// `commit` reads the answer; `rollback` can only log it.
        fn undo(self: *Tx) ?anyerror {
            if (self.done) return null;
            self.done = true;
            // The path this is here for: a statement failed, which is the
            // usual reason anybody rolls back at all.
            self.settle();
            defer giveBack(self.wire.io, self.conn);
            // Nothing was begun, so nothing is rolled back.
            if (self.plain) return null;
            const w = self.wire.limits.waiting();
            defer self.wire.limits.waited(w);
            // Whether a cancellation is what ended the transaction: asked
            // before holding it off, and put back for the caller (ADR 223).
            const cancelled = if (std.Io.checkCancel(self.wire.io)) |_| false else |_| blk: {
                self.wire.io.recancel();
                break :blk true;
            };
            // Held off from cancellation, as giving the connection back is:
            // a rollback is cleanup, and a re-armed cancellation would stop
            // the ROLLBACK before it was sent.
            const was = self.wire.io.swapCancelProtection(.blocked);
            defer _ = self.wire.io.swapCancelProtection(was);
            _ = self.conn.exec("ROLLBACK", .{}) catch |err| {
                // A statement a cancellation cut off leaves the connection
                // mid-answer, so the ROLLBACK cannot be sent at all. The
                // connection is dropped either way, and the server rolls
                // back when it goes: that is a shutdown, not a failure.
                if (cancelled) return null;
                return err;
            };
            // The plan a stale refusal left behind, now that the connection
            // takes statements again. One that cannot be deallocated would
            // collide with its own name when it is prepared again, so the
            // connection is marked for `release` to drop instead.
            if (self.stale) |name| self.conn.deallocate(name) catch {
                self.conn._state = .fail;
            };
            return null;
        }
    };

    /// Take a connection out of the pool and open a transaction on it.
    ///
    /// The isolation level and the read-only flag ride on the `BEGIN` rather
    /// than arriving as a `SET TRANSACTION` behind it, which is why asking
    /// for either costs nothing: `opts` is comptime, so what goes down the
    /// socket is a constant this file assembled while compiling.
    pub fn begin(self: *Wire, arena: std.mem.Allocator, comptime opts: wire.Begin) wire.Error!Tx {
        _ = arena;
        if (comptime opts.rebuilding) @compileError(
            "nilo: `.rebuilding` is not available on the postgres dialect.\n" ++
                "  It turns SQLite's foreign keys off so that dropping a table does not delete " ++
                "the rows pointing at it. Postgres refuses to drop a table something points at, " ++
                "and changes a column in place, so there is nothing to turn off.",
        );
        const w = self.limits.waiting();
        defer self.limits.waited(w);
        var conn = try self.take();
        errdefer giveBack(self.io, conn);
        if (comptime opts.transaction) {
            _ = conn.exec(comptime beginText(opts), .{}) catch |err| return translate(self.io, conn, err);
        }
        return .{ .wire = self, .conn = conn, .plain = comptime !opts.transaction };
    }

    /// A connection from the pool, **asked whether it is still there before
    /// anything is sent down it**. The pool hands back what it holds without
    /// asking, so after a restart, a failover or a NAT dropping an idle
    /// socket, every connection that had been idle cost one request a 5xx.
    ///
    /// **A check before rather than a resend after**, and the difference is
    /// whether a statement can run twice. A failure on the first read after
    /// the write cannot say whether the server got the statement: a FIN that
    /// arrived before it, and a crash after the server committed it, look the
    /// same from here, and an `INSERT` sent again is two rows. A socket that
    /// already said it was closing is known dead before anything went out.
    ///
    /// A dead one is given back in a state the pool does not take back, so
    /// pg.zig destroys it and dials its replacement, and the next is asked.
    /// Bounded by the pool's size: past that every connection has been looked
    /// at, and what is left is the pool's own answer.
    fn take(self: *Wire) wire.Error!*pg.Conn {
        var looked: usize = 0;
        while (true) {
            const conn = self.pool.acquire() catch |err| return acquireFailed(self.io, err);
            if (looked > self.pool._conns.len or !hungUp(conn)) return conn;
            looked += 1;
            std.log.info("nilo_sql: an idle connection had been closed by the server; replaced before use", .{});
            conn._state = .fail;
            giveBack(self.io, conn);
        }
    }

    /// `BEGIN`, with whatever the caller asked for spelled onto the end of
    /// it. Postgres takes the isolation level and the access mode as part of
    /// the statement, and they read in that order.
    fn beginText(comptime opts: wire.Begin) []const u8 {
        comptime {
            var text: []const u8 = "BEGIN";
            if (opts.isolation) |level| text = text ++ " ISOLATION LEVEL " ++ switch (level) {
                .read_committed => "READ COMMITTED",
                .repeatable_read => "REPEATABLE READ",
                .serializable => "SERIALIZABLE",
            };
            if (opts.read_only) text = text ++ " READ ONLY";
            return text;
        }
    }

    /// Build a pool that dials through `io`.
    ///
    /// With `connect_on_init` at zero — the default — this reaches the
    /// database not at all: the URL is parsed, the pool is allocated, and
    /// the first connection is made by pg.zig's reconnector in the
    /// background. That is what lets a server start with Postgres switched
    /// off.
    ///
    /// **`pg.Pool.initUri` cannot be used, and finding out why is
    /// [ADR 115](../docs/adr/115-a-boot-dials-the-connection-its-work-needs.md).**
    /// It copies exactly two fields of the `Opts` it is given onto the ones
    /// it parsed out of the URI — `size` and `timeout` — and drops
    /// `connect_on_init_count`, which then defaults to `orelse size` inside
    /// `Pool.init`. So every pool nilo ever opened dialled itself in full at
    /// startup and died on the first refusal, whatever this option said. The
    /// URI is parsed here instead, which is forty lines and the only way to
    /// hand `Pool.init` a whole `Opts`.
    pub fn open(
        io: std.Io,
        gpa: std.mem.Allocator,
        url: []const u8,
        opts: wire.OpenOpts,
    ) !Wire {
        const uri = try std.Uri.parse(url);

        // The strings below point into this arena or into `url`; `Pool.init`
        // dupes what it keeps into an arena of its own, so this one goes
        // back before `open` returns.
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();

        const pool = pg.Pool.init(io, gpa, try poolOpts(uri, scratch.allocator(), opts)) catch |err| {
            // **The refusal ADR 241 promises for a remote host with no
            // `sslmode`.** Said here because the error pg.zig returns names
            // the protocol, and the person reading it is looking at a URL
            // that never mentioned TLS. `warn`, not `err`: ADR 145.
            if (std.mem.eql(u8, @errorName(err), "SSLNotSupportedByServer")) std.log.warn(
                "nilo_sql: the server did not offer TLS, and the URL asks for it, " ++
                    "either with `sslmode=require` or by naming a host other than this " ++
                    "machine and no `sslmode` (ADR 241). Turn TLS on at the server, or " ++
                    "say `sslmode=disable` in the URL to connect without it knowingly.",
                .{},
            );
            return err;
        };
        return .{ .pool = pool, .io = io, .limits = opts.limits };
    }

    /// Everything `pg.Pool.init` needs, in one value — which is the point:
    /// `initUri` builds this internally and lets three of its fields be
    /// overwritten, so the fourth is silently whatever it parsed. Built here
    /// it is one struct literal a test can read (ADR 115).
    fn poolOpts(
        uri: std.Uri,
        arena: std.mem.Allocator,
        opts: wire.OpenOpts,
    ) !pg.Pool.Opts {
        var out = try dialOpts(uri, arena);
        out.size = opts.size;
        // **Zero is no bound, as `wire.OpenOpts` says**, and pg.zig reads it
        // as a deadline that has already passed: an empty pool would fail
        // the moment it was asked. The largest value it takes is about
        // forty-nine days, which is no bound to a request.
        out.timeout = if (opts.timeout_ms == 0) std.math.maxInt(u32) else opts.timeout_ms;
        out.connect_on_init_count = opts.connect_on_init;
        // `result_state_size` is left at pg.zig's 32, on purpose. It looked
        // free to size from the widest Row a `Db` reads, since every
        // statement is a comptime constant, and it is not: the same number
        // sizes the parameter-OID array a prepared statement is described
        // with, and a statement wider than it allocates per call rather
        // than failing, so a value chosen from the Rows would be paid for
        // again by the first `insertMany` whose tuple is wider than any Row.
        // A few hundred bytes a connection, held for the life of the pool,
        // against a stack that costs kilobytes (ADR 062).
        return out;
    }

    /// What a URL may carry, as the refusal lists it. One string, so the
    /// message and the branches in `dialOpts` cannot drift apart.
    const understood_params =
        "user, password, dbname, host, port, sslmode (disable, require or " ++
        "verify-full; with none, require for any host but this machine, ADR 241), " ++
        "sslrootcert (beside sslmode=verify-full), application_name, " ++
        "fallback_application_name, connect_timeout, keepalives, " ++
        "keepalives_idle, keepalives_interval, keepalives_count, options, " ++
        "pgbouncer (true turns prepared statements off), pool_mode and " ++
        "client_encoding=UTF8";

    /// A URI taken apart into what pg.zig needs to dial with.
    ///
    /// pg.zig's own `parseOpts` — not reachable through its module root —
    /// understands two query parameters and refuses a third, and the
    /// refusal is right for the reason it gives: a `sslmode` nobody read is
    /// a connection that is plaintext while the URL says otherwise. What it
    /// gets wrong is how much is refused. The URL a hosted database hands
    /// out carries `application_name`, `connect_timeout`, `pgbouncer=true`
    /// and `sslrootcert`, none of them a third meaning and every one of
    /// them a server that would not start. So every libpq parameter goes
    /// in one of three places:
    ///
    /// - **carried** — pg.zig has a field for it, and the field is set.
    /// - **dropped** — it asks for what the driver does anyway, or for what
    ///   the driver never does and nothing the caller can see changes:
    ///   `sslsni=1`, `channel_binding=prefer`. One `warn` line names them
    ///   all, once, at startup.
    /// - **refused** — the connection would not do what the URL says, and
    ///   the line before the error names the parameter, the reason and
    ///   `understood_params`. `sslmode=prefer` is the one to keep in mind:
    ///   it would fall back to plaintext, and pg.zig does not.
    ///   `tcp_user_timeout` is the other: libpq sets a socket option with
    ///   it, pg.zig has none to set, and its own parser reads the number as
    ///   the login timeout, which a URL that also says `connect_timeout`
    ///   would then overwrite or be overwritten by (ADR 241).
    ///
    /// `pgbouncer=true` and `pool_mode=transaction` are none of the three.
    /// They are **read by `urlIsPooled`**, which `Db.init` asks so that
    /// statements are not kept prepared behind a pooler that hands out a
    /// different server connection per transaction (ADR 051, ADR 241).
    ///
    /// **`sslmode` has a default, and it depends on where the host is**
    /// (ADR 241): none of `localhost`, `127.0.0.0/8`, `::1`, a unix socket
    /// path or no host at all (pg.zig dials `127.0.0.1`) is TLS by default,
    /// and every other host is `require`. libpq's `prefer` is not on offer,
    /// because anybody on the path can answer the `SSLRequest` with `N` and
    /// read the password that follows.
    ///
    /// The refusals log at `warn` rather than `err` for the reason `wireOf`
    /// in `db.zig` does: the error is returned and is what the caller acts
    /// on, and `std.log.err` fails the test runner for every test that
    /// provokes it (ADR 145).
    fn dialOpts(uri: std.Uri, arena: std.mem.Allocator) !pg.Pool.Opts {
        if (!std.mem.eql(u8, uri.scheme, "postgresql") and
            !std.mem.eql(u8, uri.scheme, "postgres")) return error.InvalidUriScheme;

        const path = std.mem.trimStart(u8, try uri.path.toRawMaybeAlloc(arena), "/");

        var out: pg.Pool.Opts = .{
            // Both overwritten by the caller; named here so that a field
            // added to `Pool.Opts` upstream is a compile error rather than a
            // default nobody chose.
            .size = 0,
            .timeout = 0,
            .connect_on_init_count = null,
            .auth = .{
                .username = if (uri.user) |u| try u.toRawMaybeAlloc(arena) else "postgres",
                .password = if (uri.password) |pw| try pw.toRawMaybeAlloc(arena) else null,
                .database = if (path.len == 0) null else path,
                .timeout = 10_000,
            },
            .connect = .{
                .tls = .off,
                .port = uri.port,
                .host = if (uri.host) |h| try h.toRawMaybeAlloc(arena) else null,
            },
        };
        // A URL with no query string says no `sslmode` either, so it takes the
        // default by where the server is (ADR 241) before it returns.
        const query = uri.query orelse {
            if (!isThisMachine(out.connect.host)) out.connect.tls = .require;
            return out;
        };

        // Split before decoding: a `password=` whose value holds `&` or `=`
        // arrives percent-encoded, and decoding the whole query first would
        // cut it in two.
        const encoded = query == .percent_encoded;
        const raw = switch (query) {
            .raw, .percent_encoded => |text| text,
        };

        // Null until the URL says one: the default depends on the host, and
        // the host may arrive as `?host=` after this parameter.
        var sslmode: ?[]const u8 = null;
        var sslrootcert: ?[]const u8 = null;
        var fallback_name: ?[]const u8 = null;
        var dropped: std.Io.Writer.Allocating = .init(arena);

        var it = std.mem.splitScalar(u8, raw, '&');
        while (it.next()) |param| {
            if (param.len == 0) continue;
            var pair = std.mem.splitScalar(u8, param, '=');
            const key = try decodeParam(arena, pair.first(), encoded);
            const value = try decodeParam(arena, pair.rest(), encoded);

            // Carried. The five that double the authority part are checked
            // against it: a URL that says two users is a URL nobody can
            // read, not one whose second half wins.
            if (eql(key, "user")) {
                if (uri.user != null and !eql(out.auth.username, value)) return twice(key);
                out.auth.username = value;
            } else if (eql(key, "password")) {
                try carry(key, &out.auth.password, value);
            } else if (eql(key, "dbname")) {
                try carry(key, &out.auth.database, value);
            } else if (eql(key, "host")) {
                try carry(key, &out.connect.host, value);
            } else if (eql(key, "port")) {
                const port = try std.fmt.parseInt(u16, value, 10);
                if (uri.port != null and uri.port.? != port) return twice(key);
                out.connect.port = port;
            } else if (eql(key, "sslmode")) {
                if (eql(value, "disable") or eql(value, "require") or eql(value, "verify-full")) {
                    sslmode = value;
                } else if (eql(value, "prefer") or eql(value, "allow")) {
                    return refuse(key, value, "would fall back to plaintext when TLS " ++
                        "fails, which pg.zig does not do. Say `require` for TLS or " ++
                        "`disable` for none", error.UnsupportedSSLModeValue);
                } else if (eql(value, "verify-ca")) {
                    return refuse(key, value, "asks for the certificate chain to be " ++
                        "checked and the host name not to be, which pg.zig cannot do by " ++
                        "halves: `verify-full` checks both and `require` checks " ++
                        "neither. Say which", error.UnsupportedSSLModeValue);
                } else return refuse(key, value, "is not a `sslmode`", error.UnsupportedSSLModeValue);
            } else if (eql(key, "sslrootcert")) {
                sslrootcert = value;
            } else if (eql(key, "application_name")) {
                out.auth.application_name = value;
            } else if (eql(key, "fallback_application_name")) {
                fallback_name = value;
            } else if (eql(key, "connect_timeout")) {
                // libpq counts seconds; pg.zig's auth timeout counts
                // milliseconds. `tcp_user_timeout` below is already in ms,
                // which is pg.zig's own reading of it.
                out.auth.timeout = try std.math.mul(u32, try std.fmt.parseInt(u32, value, 10), 1000);
            } else if (eql(key, "tcp_user_timeout")) {
                return refuse(key, value, "sets a timeout on the TCP socket in libpq, " ++
                    "which pg.zig has no way to set; it would only have bounded the " ++
                    "login, which is what `connect_timeout` (in seconds) says", error.UnsupportedConnectionParam);
            } else if (eql(key, "keepalives")) {
                out.connect.keepalive = !eql(value, "0");
            } else if (eql(key, "keepalives_idle")) {
                out.connect.keepalive_idle = try std.fmt.parseInt(u32, value, 10);
            } else if (eql(key, "keepalives_interval")) {
                out.connect.keepalive_interval = try std.fmt.parseInt(u32, value, 10);
            } else if (eql(key, "keepalives_count")) {
                out.connect.keepalive_count = try std.fmt.parseInt(u32, value, 10);
            } else if (eql(key, "options")) {
                // Handed to the server as written, in the startup message,
                // which parses it the way `postgres -c` does. It is how a
                // URL sets `statement_timeout` for every connection of a
                // pool, and how Neon is told which endpoint is meant.
                const params = try startupParams(arena, &out);
                if (params.get(key)) |was| {
                    if (!eql(was, value)) return refuse(key, value, "is the second `options` " ++
                        "in the URL, and the two disagree. Put every setting in one, " ++
                        "`-c a=1 -c b=2`", error.ConflictingConnectionParam);
                }
                try params.put(key, value);
            } else if (eql(key, "client_encoding")) {
                // Every `Str` nilo hands out is UTF-8, so UTF-8 is the one
                // encoding a connection may ask for. Postgres takes the
                // name in any case and with or without its hyphen.
                if (!std.ascii.eqlIgnoreCase(value, "UTF8") and !std.ascii.eqlIgnoreCase(value, "UTF-8"))
                    return refuse(key, value, "would send text in an encoding other " ++
                        "than UTF-8, and every `Str` nilo_sql hands out is read as " ++
                        "UTF-8. Drop it, or say `UTF8`", error.UnsupportedConnectionParamValue);
                try (try startupParams(arena, &out)).put(key, "UTF8");

                // Read, not dropped: `urlIsPooled` turns `Opts.prepared` off
                // from these two (ADR 241). What is checked here is that the
                // value is one it understands, since `pgbouncer=ture` read as
                // "no pooler" would be a Db that fails on its first
                // transaction.
            } else if (eql(key, "pgbouncer")) {
                if (!eql(value, "true") and !eql(value, "false")) return refuse(key, value, "is not `true` or `false`", error.UnsupportedConnectionParamValue);
            } else if (eql(key, "pool_mode")) {
                if (!eql(value, "session") and !eql(value, "transaction") and !eql(value, "statement"))
                    return refuse(key, value, "is not `session`, `transaction` or `statement`", error.UnsupportedConnectionParamValue);

                // Dropped.
            } else if ((eql(key, "sslsni") and eql(value, "1")) or
                (eql(key, "gssencmode") and (eql(value, "disable") or eql(value, "prefer"))) or
                (eql(key, "channel_binding") and (eql(value, "prefer") or eql(value, "disable"))) or
                (eql(key, "target_session_attrs") and eql(value, "any")))
            {
                dropped.writer.print("{s}{s}={s}", .{
                    if (dropped.written().len == 0) "" else ", ", key, value,
                }) catch return error.OutOfMemory;

                // Refused.
            } else if (eql(key, "sslcert") or eql(key, "sslkey")) {
                return refuse(key, value, "names a client certificate, and pg.zig " ++
                    "presents none", error.UnsupportedConnectionParam);
            } else if (eql(key, "channel_binding")) {
                return refuse(key, value, "asks for SCRAM channel binding, which pg.zig " ++
                    "does not do; the server would take the connection without it " ++
                    "and the URL would be lying", error.UnsupportedConnectionParamValue);
            } else if (eql(key, "gssencmode")) {
                return refuse(key, value, "asks for GSSAPI encryption, which pg.zig " ++
                    "does not do", error.UnsupportedConnectionParamValue);
            } else if (eql(key, "target_session_attrs")) {
                return refuse(key, value, "asks for a session pg.zig does not check " ++
                    "for: it dials the one host and takes whatever answers", error.UnsupportedConnectionParamValue);
            } else if (eql(key, "sslsni")) {
                return refuse(key, value, "would leave the host name out of the TLS " ++
                    "handshake, and pg.zig always sends it", error.UnsupportedConnectionParamValue);
            } else {
                return refuse(key, value, "is not a parameter nilo_sql understands", error.UnsupportedConnectionParam);
            }
        }

        // `sslrootcert` names a CA, and only `verify-full` reads one:
        // carried beside anything else it would be a file the connection
        // never opens while the URL says it was checked against.
        if (sslrootcert != null and !eql(sslmode orelse "", "verify-full")) {
            return refuse("sslrootcert", sslrootcert.?, "names a CA the connection " ++
                "would never check, because `sslmode` is not `verify-full`. Add " ++
                "`sslmode=verify-full`, or drop it", error.UnsupportedConnectionParam);
        }
        // **The default is decided by where the server is** (ADR 241).
        const mode = sslmode orelse if (isThisMachine(out.connect.host)) "disable" else "require";
        out.connect.tls = if (eql(mode, "require"))
            .require
        else if (eql(mode, "verify-full"))
            // libpq reads `sslrootcert=system` as the platform's store,
            // which is what pg.zig does with no path at all.
            .{ .verify_full = if (sslrootcert) |ca| (if (eql(ca, "system")) null else ca) else null }
        else
            .off;
        if (out.auth.application_name == null) out.auth.application_name = fallback_name;

        if (dropped.written().len > 0) std.log.warn(
            "nilo_sql: the database URL carries {s}, which the driver does " ++
                "already or could not act on; dropped.",
            .{dropped.written()},
        );
        return out;
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    /// Whether a connection to this host never leaves the machine: no host
    /// at all (pg.zig dials `127.0.0.1`), `localhost`, anything in
    /// `127.0.0.0/8`, `::1`, or a unix socket path. These are the hosts that
    /// default to no TLS; everything else defaults to `require` (ADR 241).
    ///
    /// **Only what the URL spells out.** A name that resolves to a loopback
    /// address (a `db` alias in `/etc/hosts`) is not looked up, since a
    /// lookup at parse time is a network call and an answer that can change
    /// between the check and the dial. It gets `require`, and a URL that
    /// means plaintext says `sslmode=disable`.
    fn isThisMachine(host: ?[]const u8) bool {
        var h = host orelse return true;
        if (h.len == 0 or h[0] == '/') return true;
        if (h[0] == '[' and h[h.len - 1] == ']') h = h[1 .. h.len - 1];
        if (std.ascii.eqlIgnoreCase(h, "localhost") or std.ascii.eqlIgnoreCase(h, "localhost.")) return true;
        if (eql(h, "::1")) return true;
        const address = std.Io.net.IpAddress.parse(h, 0) catch return false;
        return switch (address) {
            .ip4 => |v4| v4.bytes[0] == 127,
            .ip6 => false,
        };
    }

    /// Whether the URL says a connection pooler that hands out a different
    /// server connection per transaction sits in front of the database:
    /// `pgbouncer=true`, or `pool_mode=transaction` or `statement`. `Db.init`
    /// turns `Opts.prepared` off on it, because a statement prepared on one
    /// server connection is missing on the next and Postgres answers `26000`
    /// (ADR 051, ADR 241). Read with the same decoding `dialOpts` uses, so a
    /// key spelled with percent-escapes is seen by both or by neither.
    pub fn urlIsPooled(url: []const u8) bool {
        const uri = std.Uri.parse(url) catch return false;
        const query = uri.query orelse return false;
        const encoded = query == .percent_encoded;
        const raw = switch (query) {
            .raw, .percent_encoded => |text| text,
        };
        var buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var it = std.mem.splitScalar(u8, raw, '&');
        while (it.next()) |param| {
            fba.reset();
            var pair = std.mem.splitScalar(u8, param, '=');
            const key = decodeParam(fba.allocator(), pair.first(), encoded) catch continue;
            const value = decodeParam(fba.allocator(), pair.rest(), encoded) catch continue;
            if (eql(key, "pgbouncer") and eql(value, "true")) return true;
            if (eql(key, "pool_mode") and (eql(value, "transaction") or eql(value, "statement"))) return true;
        }
        return false;
    }

    /// One piece of a query string, percent-decoded into the arena when
    /// the URI came in encoded — which `std.Uri.parse` always leaves it.
    /// The startup message's own settings, made on first use in the arena
    /// `dialOpts` builds in; `Pool.init` copies the map and what is in it.
    fn startupParams(arena: std.mem.Allocator, out: *pg.Pool.Opts) !*std.StringHashMap([]const u8) {
        if (out.auth.startup_parameters == null) out.auth.startup_parameters = .init(arena);
        return &out.auth.startup_parameters.?;
    }

    fn decodeParam(arena: std.mem.Allocator, piece: []const u8, encoded: bool) ![]const u8 {
        if (!encoded) return piece;
        const buf = try arena.alloc(u8, piece.len);
        return std.Uri.percentDecodeBackwards(buf, piece);
    }

    /// A query-form parameter onto the slot the authority part may already
    /// have filled: the same value twice is fine, two values is `twice`.
    fn carry(key: []const u8, slot: *?[]const u8, value: []const u8) !void {
        if (slot.*) |had| if (!eql(had, value)) return twice(key);
        slot.* = value;
    }

    fn twice(key: []const u8) error{ConflictingConnectionParam} {
        std.log.warn(
            "nilo_sql: the database URL gives `{s}` twice — once before the `?` " ++
                "and once as `{s}=` — and the two disagree. Say it once.",
            .{ key, key },
        );
        return error.ConflictingConnectionParam;
    }

    /// The one sentence a refused parameter gets: which, why, and what
    /// would have been read.
    fn refuse(key: []const u8, value: []const u8, why: []const u8, comptime err: anytype) @TypeOf(err) {
        // A refused `sslpassword` is still a secret, and this line prints
        // the value of what it refuses.
        const shown = if (std.ascii.eqlIgnoreCase(key, "sslpassword")) "***" else value;
        std.log.warn(
            "nilo_sql: the database URL carries `{s}={s}`, which {s}. The " ++
                "parameters understood are {s}.",
            .{ key, shown, why, understood_params },
        );
        return err;
    }

    pub fn close(self: *Wire) void {
        self.pool.deinit();
    }

    /// Run a statement. `values` is a tuple in placeholder order, which is
    /// what `where.zig` builds at compile time.
    ///
    /// `arena` is the request's, and is where pg.zig reads into when a row
    /// is too big for its own buffer.
    pub fn run(
        self: *Wire,
        arena: std.mem.Allocator,
        sql: []const u8,
        values: anytype,
        plan: ?[]const u8,
        problem: ?*?wire.Problem,
    ) wire.Error!Rows {
        // The wait stays open until `Rows.close`: the rows are read off the
        // socket one `next` at a time, and a pair around each read would be
        // two calls and a clock per row (ADR 210).
        const w = self.limits.waiting();
        errdefer self.limits.waited(w);
        var conn = try self.take();
        errdefer giveBack(self.io, conn);

        const opts: pg.Conn.QueryOpts = .{ .allocator = arena, .cache_name = plan };
        const result = conn.queryOpts(sql, opened(values), opts) catch |err| retry: {
            if (!replanned(conn, plan)) return reported(self.io, conn, err, arena, problem);
            break :retry conn.queryOpts(sql, opened(values), opts) catch |again|
                return reported(self.io, conn, again, arena, problem);
        };
        return .{ .conn = conn, .result = result, .io = self.io, .limits = self.limits, .wait = w };
    }

    /// The next row, or false when the set is finished. The row itself is
    /// kept on `rows` rather than returned, so that `read` can stay a plain
    /// column index and this file stays the only one naming `pg.Row`.
    pub fn next(self: *Wire, rows: *Rows) wire.Error!bool {
        _ = self;
        rows.current = rows.result.next() catch |err| {
            return translate(rows.io, rows.conn, err);
        } orelse {
            rows.current = null;
            return false;
        };
        return true;
    }

    /// How many columns came back, out of the `RowDescription` pg.zig has
    /// already read.
    ///
    /// A property of the result set here, so the row `next` stopped on makes
    /// no difference to it — the answer would be the same before the first
    /// one. `fill` asks after the first `next` regardless, because SQLite
    /// cannot answer any earlier (ADR 106).
    pub fn width(self: *Wire, rows: *const Rows) usize {
        _ = self;
        return rows.result.number_of_columns;
    }

    /// Column `col` of the row `next` just handed back, as `T`.
    ///
    /// A `[]const u8` here points into the read buffer and dies at the next
    /// `next` — `db.zig` copies it before anybody sees it.
    pub fn read(self: *Wire, rows: *const Rows, comptime T: type, col: usize) wire.Error!T {
        _ = self;
        const row = rows.current orelse return error.QueryFailed;
        // pg.zig has no word for nilo's `Bytes`, and needs none: a `bytea`
        // column comes back as the bytes themselves, so this unwraps to the
        // slice pg.zig does understand and wraps the answer again. `opened`
        // is the same step the other way, on the parameter tuple, and the
        // `::bytea` the Dialect writes around the placeholder is what makes
        // the slice that type at the server (`dialect.bindAs`).
        if (comptime T == wire.Bytes) {
            const got = row.get([]const u8, col) catch return error.QueryFailed;
            return .{ .bytes = got };
        }
        if (comptime T == ?wire.Bytes) {
            const got = row.get(?[]const u8, col) catch return error.QueryFailed;
            return if (got) |b| .{ .bytes = b } else null;
        }
        // **A `date` read out of the column's own four bytes**, and it is done
        // here rather than through `row.get` because pg.zig has no decoder for
        // the type: `Int32.decode` verifies the OID is `int4` and refuses
        // `date` (1082). The bytes are a big-endian day count from 2000-01-01,
        // which is the same conversion its `Timestamp` makes for micros, so
        // this is one shift rather than a parse (ADR 181).
        //
        // `row.values[col]` is the raw slice, which `readList` already reads
        // the same way — so this is a seam the driver has rather than a hole
        // being poked in it.
        if (comptime types.isDate(T)) {
            const raw = row.values[col];
            if (raw.is_null) {
                if (comptime @typeInfo(T) == .optional) return null;
                return error.QueryFailed;
            }
            if (raw.data.len != 4) return error.QueryFailed;
            const since_y2k = std.mem.readInt(i32, raw.data[0..4], .big);
            if (since_y2k == std.math.maxInt(i32) or since_y2k == std.math.minInt(i32))
                return infinite("date", col, since_y2k > 0);
            return .{ .days = std.math.add(i32, since_y2k, types.date_days_from_epoch_to_y2k) catch
                return error.QueryFailed };
        }
        // **A `timestamp` read out of its own eight bytes**, for the reason the
        // `date` above is: pg.zig's decoder adds the offset from 2000 to the
        // epoch unchecked, so `'infinity'` (the largest `i64`) overflowed
        // inside the driver and took the process down, and `'-infinity'` read
        // as a moment 292,000 years ago. A `Timestamp` arrives here as `i64`
        // (`db.WireRead`), and the column's OID is what says it is a moment
        // rather than a `bigint`.
        if (comptime T == i64 or T == ?i64) {
            const oid = row.oids[col];
            if (oid == pg.types.Timestamp.oid.decimal or oid == pg.types.TimestampTz.oid.decimal) {
                const raw = row.values[col];
                if (raw.is_null) {
                    if (comptime T == ?i64) return null;
                    return error.QueryFailed;
                }
                if (raw.data.len != 8) return error.QueryFailed;
                const since_y2k = std.mem.readInt(i64, raw.data[0..8], .big);
                if (since_y2k == std.math.maxInt(i64) or since_y2k == std.math.minInt(i64))
                    return infinite("timestamp", col, since_y2k > 0);
                return std.math.add(i64, since_y2k, micros_from_epoch_to_y2k) catch error.QueryFailed;
            }
        }
        // **A number read out of whichever width the column is, and held to
        // the field's.** pg.zig decodes an `i32` out of `int4` and nothing
        // else, while the schema check lets an `i32` stand over an `int8` and
        // an `f64` over a `float4`, so every read of those answered
        // `QueryFailed` and a `u16` or an `i8` did not compile inside the
        // driver. Here a value that fits is read, and one that does not is
        // refused with its column named rather than truncated. Any other
        // column, a `numeric` read into an `f64` among them, is pg.zig's.
        if (comptime numberOf(T)) |N| {
            const oid = row.oids[col];
            // pg.zig decodes these five widths out of other columns too, a
            // `numeric` into an `f64` among them; any other width has no
            // decoder there at all.
            const theirs = comptime N == i16 or N == i32 or N == i64 or N == f32 or N == f64;
            if (isNumber(oid) or !theirs) {
                const raw = row.values[col];
                if (raw.is_null) {
                    if (comptime @typeInfo(T) == .optional) return null;
                    return error.QueryFailed;
                }
                if (!isNumber(oid)) return notANumber(N, oid, col);
                return try numberFrom(N, oid, raw.data, col);
            }
        }
        return row.get(T, col) catch return error.QueryFailed;
    }

    /// The number `T` holds, or null when it holds something else. An `i64`
    /// counts: a `Timestamp` over a moment was taken above by its OID, and
    /// one over an `int8` is the number it is.
    fn numberOf(comptime T: type) ?type {
        const Inner = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        return switch (@typeInfo(Inner)) {
            .int, .float => Inner,
            else => null,
        };
    }

    fn numberName(oid: i32) []const u8 {
        return switch (oid) {
            pg.types.Int16.oid.decimal => "int2",
            pg.types.Int32.oid.decimal => "int4",
            pg.types.Int64.oid.decimal => "int8",
            pg.types.Float32.oid.decimal => "float4",
            pg.types.Float64.oid.decimal => "float8",
            else => "another type",
        };
    }

    fn isNumber(oid: i32) bool {
        return switch (oid) {
            pg.types.Int16.oid.decimal,
            pg.types.Int32.oid.decimal,
            pg.types.Int64.oid.decimal,
            pg.types.Float32.oid.decimal,
            pg.types.Float64.oid.decimal,
            => true,
            else => false,
        };
    }

    /// A column of `int2`, `int4`, `int8`, `float4` or `float8`, in the
    /// binary form Postgres sends, as `N`. An integer is range-checked into
    /// any integer field; a float widens into an `f64` and reads into an
    /// `f32` only out of a `float4`, since narrowing a double loses digits
    /// without saying so.
    fn numberFrom(comptime N: type, oid: i32, data: []const u8, col: usize) wire.Error!N {
        switch (@typeInfo(N)) {
            .int => {
                const wide: i64 = switch (oid) {
                    pg.types.Int16.oid.decimal => if (data.len == 2) std.mem.readInt(i16, data[0..2], .big) else return error.QueryFailed,
                    pg.types.Int32.oid.decimal => if (data.len == 4) std.mem.readInt(i32, data[0..4], .big) else return error.QueryFailed,
                    pg.types.Int64.oid.decimal => if (data.len == 8) std.mem.readInt(i64, data[0..8], .big) else return error.QueryFailed,
                    // A float column into an integer field: not a number
                    // this reads without losing what is after the point.
                    else => return notANumber(N, oid, col),
                };
                return std.math.cast(N, wide) orelse {
                    std.log.warn(
                        "nilo_sql: column {d} holds {d}, which does not fit the Row's " ++ @typeName(N) ++
                            ". Widen the field, or narrow the column.",
                        .{ col, wide },
                    );
                    return error.QueryFailed;
                };
            },
            .float => switch (oid) {
                pg.types.Float32.oid.decimal => {
                    if (data.len != 4) return error.QueryFailed;
                    const narrow: f32 = @bitCast(std.mem.readInt(u32, data[0..4], .big));
                    return narrow;
                },
                pg.types.Float64.oid.decimal => {
                    if (N != f64 or data.len != 8) return notANumber(N, oid, col);
                    return @bitCast(std.mem.readInt(u64, data[0..8], .big));
                },
                else => return notANumber(N, oid, col),
            },
            else => comptime unreachable,
        }
    }

    fn notANumber(comptime N: type, oid: i32, col: usize) wire.Error {
        std.log.warn(
            "nilo_sql: column {d} arrived as {s}, which the Row's " ++ @typeName(N) ++ " does not read. " ++
                "Cast the column in the statement, or change the field's type.",
            .{ col, numberName(oid) },
        );
        return error.QueryFailed;
    }

    /// 2000-01-01 as microseconds since the epoch: where Postgres counts a
    /// `timestamp` from, and the number pg.zig's own decoder adds.
    const micros_from_epoch_to_y2k: i64 = 946_684_800_000_000;

    /// **Refused by name rather than given a constant.** `infinity` and
    /// `-infinity` are legal in a `date` or a `timestamp` column and any other
    /// client may write them, but no `Date` or `Timestamp` holds one, and a
    /// sentinel the Row could compare against would be a moment every caller
    /// has to remember is not a moment.
    fn infinite(comptime what: []const u8, col: usize, positive: bool) wire.Error {
        std.log.warn(
            "nilo_sql: column {d} holds '{s}infinity', which no " ++ what ++ " field can " ++
                "hold. Store a real moment or NULL for an open end, or read the column " ++
                "through a CASE in a raw statement.",
            .{ col, if (positive) "" else "-" },
        );
        return error.QueryFailed;
    }

    /// Column `col` as a slice of its elements, allocated in the arena.
    ///
    /// **The one read that allocates, and it has no choice.** An array
    /// arrives as a header and a run of length-prefixed elements, so unlike
    /// text there is no `[]T` sitting in the read buffer to point at. The
    /// slice and, for text elements, the bytes are copied into the request
    /// arena here — which means a Row that reads one has already ended the
    /// borrow by the time `db.zig` sees it, and is also why such a Row cannot
    /// be streamed.
    pub fn readList(
        self: *Wire,
        rows: *const Rows,
        comptime L: type,
        col: usize,
        arena: std.mem.Allocator,
    ) wire.Error!L {
        _ = self;
        const row = rows.current orelse return error.QueryFailed;

        const optional = @typeInfo(L) == .optional;
        const Slice = if (optional) @typeInfo(L).optional.child else L;
        const Item = @typeInfo(Slice).pointer.child;

        const raw = row.values[col];
        if (raw.is_null) {
            if (optional) return null;
            return error.QueryFailed;
        }
        try arrayFits(Item, raw.data);

        // **An enum list is read as its text and converted here.** pg.zig's
        // own decoder is `std.meta.stringToEnum(T, data).?`, so one label the
        // Zig enum lacks took the process down (ADR 007). Each label goes
        // through the same refusal a scalar enum does (`labelOf`), and the
        // cost is one more slice in the arena per row that reads one.
        if (comptime enumOfList(Item)) |E| {
            const Text = if (comptime @typeInfo(Item) == .optional) ?[]const u8 else []const u8;
            const texts_it = row.iterator(Text, col) catch return error.QueryFailed;
            const texts = texts_it.alloc(arena) catch return error.QueryFailed;
            const tags = arena.alloc(Item, texts.len) catch return error.QueryFailed;
            for (tags, texts) |*tag, text| {
                if (comptime @typeInfo(Item) == .optional) {
                    tag.* = if (text) |held| try labelOf(E, held) else null;
                } else {
                    tag.* = try labelOf(E, text);
                }
            }
            return tags;
        }

        const it = row.iterator(Item, col) catch return error.QueryFailed;
        const list = it.alloc(arena) catch return error.QueryFailed;
        // pg.zig copies an element out of its read buffer only when the
        // element is exactly `[]const u8`, so an optional one points into a
        // buffer the next statement overwrites. `db.zig` takes what this
        // answers as the arena's (`keptList`) and wraps it in a `Str`; a
        // `[]const ?Str` column read "ZZZZZZ" four statements later.
        if (comptime Item == ?[]const u8) {
            for (list) |*item| if (item.*) |text| {
                item.* = arena.dupe(u8, text) catch return error.QueryFailed;
            };
        }
        return list;
    }

    /// The enum a list's element is, when it is one (`Item` or `?Item`).
    fn enumOfList(comptime Item: type) ?type {
        const Bare = if (@typeInfo(Item) == .optional) @typeInfo(Item).optional.child else Item;
        return if (@typeInfo(Bare) == .@"enum") Bare else null;
    }

    /// The tag whose name a list element held, or a refusal naming the value.
    /// `db.zig`'s `enumOf` for a scalar, which this file cannot import.
    fn labelOf(comptime E: type, raw: []const u8) wire.Error!E {
        return std.meta.stringToEnum(E, raw) orelse {
            std.log.warn(
                "nilo_sql: a column held `{s}` in a list, which is not a value of {s}. " ++
                    "The database has a value the Zig enum does not.",
                .{ raw, @typeName(E) },
            );
            return error.QueryFailed;
        };
    }

    /// The element types (their OIDs) a list of `Item` may be read from, or
    /// `null` for an `Item` this does not know, which is then not judged.
    /// Exact, like `dialect.listAccepts`: an `int4[]` does not read into a
    /// `[]const i64`.
    fn elementOids(comptime Item: type) ?[]const i32 {
        const Bare = if (@typeInfo(Item) == .optional) @typeInfo(Item).optional.child else Item;
        const varchar = 1043;
        if (comptime @typeInfo(Bare) == .@"enum") return &.{ pg.types.String.oid.decimal, varchar };
        return switch (Bare) {
            // A `Uuid` list arrives as `[]const u8` too (`db.WireList`), so the
            // `uuid` element is in the set with the two text ones.
            []const u8 => &.{ pg.types.String.oid.decimal, varchar, pg.types.UUID.oid.decimal },
            bool => &.{pg.types.Bool.oid.decimal},
            i16 => &.{pg.types.Int16.oid.decimal},
            i32 => &.{pg.types.Int32.oid.decimal},
            i64 => &.{pg.types.Int64.oid.decimal},
            f32 => &.{pg.types.Float32.oid.decimal},
            f64 => &.{pg.types.Float64.oid.decimal},
            else => null,
        };
    }

    /// The array shapes pg.zig asserts or panics on rather than refuses,
    /// checked here so they answer with a 500 for one request instead of
    /// taking the process down (ADR 007, and the same argument as `db.zig`'s
    /// `enumOf`).
    ///
    /// This reads the array header out of the column's own bytes, which is
    /// reaching past pg.zig's API — the second place in this file that does,
    /// after `revive`. There is no way to ask first: `row.iterator` builds
    /// the iterator and asserts in the same call, so by the time nilo holds
    /// one the assert has already fired.
    ///
    /// The header is Postgres's binary array format and is fixed: dimension
    /// count, a null flag, the element OID, then per dimension a length and a
    /// lower bound. A zero-dimension array — Postgres's `'{}'` — stops after
    /// the first three.
    ///
    /// **The element OID is checked first, and before the empty array is let
    /// through.** pg.zig picks its element decoder from the column's type
    /// before it looks at the length, and for an `i64` or `f64` list of any
    /// other element type it is `std.debug.panic`: one `int4[]` read into a
    /// `[]const i64` took the process down, empty or not.
    fn arrayFits(comptime Item: type, data: []const u8) wire.Error!void {
        if (data.len < 12) return error.QueryFailed;

        if (comptime elementOids(Item)) |accepted| {
            const element = std.mem.readInt(i32, data[8..12], .big);
            const fits = for (accepted) |oid| {
                if (oid == element) break true;
            } else false;
            if (!fits) {
                std.log.warn(
                    "nilo_sql: a column held an array of elements with type OID {d}, " ++
                        "which a list of {s} cannot be read from. Declare the field to " ++
                        "match the column (`int4[]` is a list of i32, `int8[]` of i64, " ++
                        "`text[]` of text or of an enum).",
                    .{ element, @typeName(Item) },
                );
                return error.QueryFailed;
            }
        }

        // The empty array, which has no dimension to describe.
        if (data.len == 12) return;
        if (data.len < 20) return error.QueryFailed;

        if (std.mem.readInt(i32, data[0..4], .big) != 1) {
            std.log.warn(
                "nilo_sql: a column held an array of more than one dimension, " ++
                    "and a Zig slice is one deep.",
                .{},
            );
            return error.QueryFailed;
        }

        const has_nulls = std.mem.readInt(i32, data[4..8], .big) != 0;
        if (has_nulls and @typeInfo(Item) != .optional) {
            std.log.warn(
                "nilo_sql: a column held an array with a NULL in it, read as {s}. " ++
                    "Postgres lets any array hold one; declare the column as a " ++
                    "slice of optionals to read it.",
                .{@typeName(Item)},
            );
            return error.QueryFailed;
        }
    }

    /// Throw away what is left and give the connection back.
    ///
    /// pg.zig's pool checks that a connection is idle on release, and on
    /// finding it is not, destroys it and dials a new one. A handler that
    /// stops reading early is an ordinary thing to write, so a short rest is
    /// read off the socket and the connection kept.
    ///
    /// **A long rest is not** (ADR 238). Reading it held the connection for
    /// as long as the server took to send it: a stream let go after one of
    /// 200,000 rows of 200 bytes took 178 to 313 ms to give its connection
    /// back (bench/result/sql.md §20). Past `drain_budget` bytes the connection is
    /// given back as failed, so the pool closes it, which ends the query on
    /// the server at its next write, and dials a replacement: one connect in
    /// place of however long the rest was. Postgres's own way to stop a
    /// query, a CancelRequest, needs the key the server sends at startup,
    /// which pg.zig reads past without keeping.
    ///
    /// Inside a transaction the rest is read whatever its length: the
    /// connection is the transaction, and closing it would roll back what
    /// the caller has not committed.
    pub fn drain(self: *Wire, rows: *Rows) void {
        // A cancellation that lands while the rest is thrown away is the
        // caller's, like any other a statement is cut off by (ADR 223).
        if (!rows.owns_conn) {
            rows.result.drain() catch |err| if (err == error.Canceled) self.io.recancel();
            rows.close();
            return;
        }
        const conn = rows.conn;
        var thrown: usize = 0;
        while (conn._state == .query) {
            const msg = conn.read() catch |err| {
                if (err == error.Canceled) self.io.recancel();
                break;
            };
            switch (msg.type) {
                'Z' => break,
                'C', 'D' => {},
                else => {
                    conn._state = .fail;
                    break;
                },
            }
            thrown += msg.data.len;
            if (thrown > drain_budget and conn._state == .query) {
                std.log.info(
                    "nilo_sql: a stream was let go with more than {d} bytes still to come; its connection is replaced rather than read to the end",
                    .{drain_budget},
                );
                conn._state = .fail;
                break;
            }
        }
        rows.close();
    }

    /// How much of a stream let go early is read off the socket before its
    /// connection is replaced instead. A megabyte is read in 4 to 7 ms and a
    /// replacement dialled in 16 to 27 on loopback, so a rest past it costs
    /// at most one connect more than reading it would have, and a rest of
    /// forty megabytes costs 21 to 34 ms where it cost 178 to 313 (ADR 238,
    /// bench/result/sql.md §20).
    pub const drain_budget: usize = 1024 * 1024;

    /// Run a statement that answers with a count rather than with rows, and
    /// give the count back. An `UPDATE` that matched nothing and one that
    /// matched are otherwise indistinguishable, and "did that change
    /// anything" is a question handlers actually ask.
    ///
    /// A separate call rather than a field on `Rows` because Postgres sends
    /// the number in `CommandComplete`, which pg.zig surfaces through
    /// `exec` and not through a result set.
    pub fn exec(
        self: *Wire,
        arena: std.mem.Allocator,
        sql: []const u8,
        values: anytype,
        plan: ?[]const u8,
        problem: ?*?wire.Problem,
    ) wire.Error!usize {
        const w = self.limits.waiting();
        defer self.limits.waited(w);
        var conn = try self.take();
        defer giveBack(self.io, conn);
        const opts: pg.Conn.QueryOpts = .{ .allocator = arena, .cache_name = plan };
        const count = conn.execOpts(sql, opened(values), opts) catch |err| retry: {
            if (!replanned(conn, plan)) return reported(self.io, conn, err, arena, problem);
            break :retry conn.execOpts(sql, opened(values), opts) catch |again|
                return reported(self.io, conn, again, arena, problem);
        };
        return @intCast(count orelse 0);
    }

    /// The columns the database says a table has, for the schema
    /// comparison. The query is the Dialect's, not this file's — what a
    /// column is called is the SQL's business and this layer only carries
    /// the answer back.
    pub fn columnsOf(
        self: *Wire,
        arena: std.mem.Allocator,
        query: []const u8,
        schema: ?[]const u8,
        table: []const u8,
    ) wire.Error![]const wire.Column {
        // No plan: this runs once per Row while the server starts, so a kept
        // plan would be memory held for a statement nothing sends again. And
        // no problem slot: nobody is watching a startup query, and the one
        // caller already has a sentence for a check it could not run.
        var rows = try self.run(arena, query, .{ schema, table }, null, null);
        defer rows.close();
        return self.columnList(arena, &rows);
    }

    /// `columnsOf` for every table of one schema in one query, the answer cut
    /// into one list per table in the order asked (`dialect.Postgres.introspect_all`).
    /// What the startup check sends, so a schema of fifty Rows costs one round
    /// trip and not fifty. Same arrangement as `columnsOf`: no kept plan, no
    /// problem slot.
    pub fn columnsOfMany(
        self: *Wire,
        arena: std.mem.Allocator,
        query: []const u8,
        schema: ?[]const u8,
        tables: []const []const u8,
    ) wire.Error![]const []const wire.Column {
        var rows = try self.run(arena, query, .{ schema, tables }, null, null);
        defer rows.close();

        var found: std.ArrayList(wire.Keyed(wire.Column)) = .empty;
        while (try self.next(&rows)) {
            const table = try self.read(&rows, []const u8, 0);
            const name = try self.read(&rows, []const u8, 1);
            const udt = try self.read(&rows, []const u8, 2);
            const is_nullable = try self.read(&rows, []const u8, 3);
            found.append(arena, .{
                .key = arena.dupe(u8, table) catch return error.QueryFailed,
                .item = .{
                    .name = arena.dupe(u8, name) catch return error.QueryFailed,
                    .udt = arena.dupe(u8, udt) catch return error.QueryFailed,
                    .nullable = if (std.mem.eql(u8, is_nullable, "YES"))
                        true
                    else if (std.mem.eql(u8, is_nullable, "NO"))
                        false
                    else
                        null,
                },
            }) catch return error.QueryFailed;
        }
        return wire.cutByName(wire.Column, arena, tables, found.items, false);
    }

    /// The rows of the introspection query as columns. Shared by `columnsOf`
    /// and the one on `Tx`, so a migration reads the table through the
    /// connection it already holds (ADR 123).
    fn columnList(self: *Wire, arena: std.mem.Allocator, rows: *Rows) wire.Error![]const wire.Column {
        var found: std.ArrayList(wire.Column) = .empty;
        while (try self.next(rows)) {
            const name = try self.read(rows, []const u8, 0);
            const udt = try self.read(rows, []const u8, 1);
            const is_nullable = try self.read(rows, []const u8, 2);
            found.append(arena, .{
                .name = arena.dupe(u8, name) catch return error.QueryFailed,
                .udt = arena.dupe(u8, udt) catch return error.QueryFailed,
                .nullable = if (std.mem.eql(u8, is_nullable, "YES"))
                    true
                else if (std.mem.eql(u8, is_nullable, "NO"))
                    false
                else
                    null,
            }) catch return error.QueryFailed;
        }
        return found.toOwnedSlice(arena) catch return error.QueryFailed;
    }

    /// What `sql` would answer, column by column, without running it: the
    /// type of each column, and with `nulls` whether an outer join makes it
    /// NULL on some row (ADR 233). Asked once per raw statement per process.
    ///
    /// **The types come from the description a prepare answers with**, which
    /// is what pg.zig reads before every statement it binds, so they are the
    /// OIDs the rows would carry; one more round trip turns them into the
    /// names `Dialect.accepts` speaks. The OIDs go into that query's text
    /// rather than a parameter, because they are numbers the server just
    /// sent and binding an `oid[]` is a decoder pg.zig does not have.
    ///
    /// **The NULLs come from the plan**, and the plan needs values for the
    /// parameters it has none of. So the statement is prepared under a name
    /// and explained with every parameter NULL, with `plan_cache_mode` set so
    /// the plan is the generic one, which is the plan that holds for every
    /// value and so the one that cannot have used a NULL to drop a join.
    /// `SET LOCAL` needs a transaction, which is rolled back: nothing ran, so
    /// nothing is lost. A `PREPARE` outlives a rollback, so the name is
    /// dropped after it. Five round trips, planning only, once.
    pub fn describe(
        self: *Wire,
        arena: std.mem.Allocator,
        sql: []const u8,
        nulls: bool,
    ) wire.Error!?[]const wire.Described {
        const w = self.limits.waiting();
        defer self.limits.waited(w);
        var conn = try self.take();
        defer giveBack(self.io, conn);

        var oids: []const i32 = &.{};
        var params: u16 = 0;
        {
            var stmt = conn.prepareOpts(sql, .{ .allocator = arena }) catch |err|
                return translate(self.io, conn, err);
            defer stmt.deinit();
            oids = arena.dupe(i32, stmt.result_state.oids[0..stmt.column_count]) catch
                return error.QueryFailed;
            params = stmt.param_count;
        }

        const out = arena.alloc(wire.Described, oids.len) catch return error.QueryFailed;
        for (out) |*column| column.* = .{ .udt = null };
        if (oids.len == 0) return out;
        try typeNames(self.io, conn, arena, oids, out);
        if (nulls) try outerNulls(self.io, conn, arena, sql, params, out);
        return out;
    }

    /// The values an enum type has, for the same comparison. The query is
    /// `dialect.Postgres.enum_values`; an empty answer is a type that is not
    /// there, and `checkSchema` says so.
    pub fn labelsOf(
        self: *Wire,
        arena: std.mem.Allocator,
        query: []const u8,
        type_name: []const u8,
    ) wire.Error![]const []const u8 {
        const one = try self.labelsOfMany(arena, query, &.{type_name});
        return one[0];
    }

    /// `labelsOf` for every enum type at once: one query, the answer cut into
    /// one list per name in the order asked, a type that is not there an
    /// empty list. The query is the same one `labelsOf` sends, with a
    /// one-element array.
    pub fn labelsOfMany(
        self: *Wire,
        arena: std.mem.Allocator,
        query: []const u8,
        type_names: []const []const u8,
    ) wire.Error![]const []const []const u8 {
        var rows = try self.run(arena, query, .{type_names}, null, null);
        defer rows.close();

        var found: std.ArrayList(wire.Keyed([]const u8)) = .empty;
        while (try self.next(&rows)) {
            const type_name = try self.read(&rows, []const u8, 0);
            const label = try self.read(&rows, []const u8, 1);
            found.append(arena, .{
                .key = arena.dupe(u8, type_name) catch return error.QueryFailed,
                .item = arena.dupe(u8, label) catch return error.QueryFailed,
            }) catch return error.QueryFailed;
        }
        return wire.cutByName([]const u8, arena, type_names, found.items, false);
    }
};

/// The parameter tuple with every `wire.Bytes` in it opened to the slice
/// inside, which is the one shape pg.zig has an encoder for.
///
/// **The half of `sql.Bytes` this file did not have.** `WireWrite` in
/// `db.zig` hands a `Bytes` down as itself so that *the Wire unwraps it* —
/// SQLite has to, because only `sqlite.zig` may name `zqlite.Blob` — and
/// `sqlite.zig` did (`blobbed`), while this file handed the tuple to
/// `queryOpts` untouched. So a `bytea` column could be declared, checked at
/// startup and read, and every statement that wrote or matched one was
/// `CannotBindStruct` from inside the driver on the first sign-in. The cast
/// was already right (`$3::bytea`, from `dialect.bindAs`): what was missing
/// was the slice for it to apply to. Found by a port whose session table is
/// the first `bytea` anything here wrote through the typed path; the test in
/// `live.zig` that would have caught it is the one that now exists.
///
/// It answers the caller's own tuple type when nothing needs opening, which
/// is every statement with no binary column in it — so this costs nothing to
/// the programs that do not use one. The same shape `sqlite.zig`'s `blobbed`
/// and `db.rawValuesOf` have, for the same reason.
fn Opened(comptime V: type) type {
    comptime {
        if (@typeInfo(V) != .@"struct") return V;
        const info = @typeInfo(V).@"struct";
        var out: [info.field_names.len]type = undefined;
        var changed = false;
        for (info.field_types, 0..) |f_type, i| {
            out[i] = switch (f_type) {
                wire.Bytes => []const u8,
                ?wire.Bytes => ?[]const u8,
                else => f_type,
            };
            if (out[i] != f_type) changed = true;
        }
        if (!changed) return V;
        const frozen = out;
        return @Tuple(&frozen);
    }
}

fn opened(values: anytype) Opened(@TypeOf(values)) {
    const V = @TypeOf(values);
    if (comptime Opened(V) == V) return values;

    var out: Opened(V) = undefined;
    const v_info = @typeInfo(V).@"struct";
    inline for (v_info.field_names, v_info.field_types, 0..) |f_name, f_type, i| {
        const held = @field(values, f_name);
        out[i] = switch (f_type) {
            wire.Bytes => held.bytes,
            ?wire.Bytes => if (held) |b| b.bytes else null,
            else => held,
        };
    }
    return out;
}

/// Each OID's type name, into `out` by position. An OID the catalog does not
/// answer for leaves its column unjudged.
///
/// **A domain is named by the type under it**, because that is what the
/// driver decodes: a domain over `int4` sends an `int4`. And a type in the
/// string category, or an enum, is marked textual, because pg.zig asks for
/// every type it has no decoder for in binary and a string's binary form is
/// its text.
fn typeNames(
    io: std.Io,
    conn: *pg.Conn,
    arena: std.mem.Allocator,
    oids: []const i32,
    out: []wire.Described,
) wire.Error!void {
    var text: std.ArrayList(u8) = .empty;
    text.appendSlice(arena,
        \\SELECT t.oid::int8, b.typname::text, b.typcategory IN ('S', 'E')
        \\FROM pg_catalog.pg_type t
        \\JOIN pg_catalog.pg_type b
        \\  ON b.oid = CASE WHEN t.typtype = 'd' THEN t.typbasetype ELSE t.oid END
        \\WHERE t.oid IN (
    ) catch return error.QueryFailed;
    for (oids, 0..) |oid, i| {
        // An OID is unsigned and pg.zig reads it into an `i32`.
        text.print(arena, "{s}{d}", .{ if (i == 0) "" else ", ", @as(u32, @bitCast(oid)) }) catch
            return error.QueryFailed;
    }
    text.append(arena, ')') catch return error.QueryFailed;

    const result = conn.queryOpts(text.items, .{}, .{ .allocator = arena }) catch |err|
        return translate(io, conn, err);
    defer result.deinit();
    while (result.next() catch |err| return translate(io, conn, err)) |row| {
        const oid = row.get(i64, 0) catch return error.QueryFailed;
        const name = arena.dupe(u8, row.get([]const u8, 1) catch return error.QueryFailed) catch
            return error.QueryFailed;
        const textual = row.get(bool, 2) catch return error.QueryFailed;
        for (oids, out) |asked, *column| {
            if (@as(u32, @bitCast(asked)) == oid) column.* = .{ .udt = name, .textual = textual };
        }
    }
}

/// Mark in `out` the columns the generic plan of `sql` shows coming from the
/// side of an outer join that may find nothing (`plan.zig`).
fn outerNulls(
    io: std.Io,
    conn: *pg.Conn,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: u16,
    out: []wire.Described,
) wire.Error!void {
    conn.begin() catch |err| return translate(io, conn, err);
    var prepared = false;
    defer {
        // Cleanup, so it may not spend a cancellation meant for the caller
        // (ADR 223). Unguarded, a shutdown that landed in the PREPARE or the
        // EXPLAIN was re-armed by `translate` and then taken by this
        // ROLLBACK and dropped by its `catch`, so `db.raw` went on to run
        // the statement it had just been told to stop before: a job cut off
        // in its first raw statement ran to the end and was marked done.
        // A cut-off connection is mid-answer or still inside its BEGIN, so
        // nothing more is sent on it: it is not idle, `release` replaces
        // it, and the server rolls back when it goes.
        const cut_off = if (std.Io.checkCancel(io)) |_| false else |_| blk: {
            io.recancel();
            break :blk true;
        };
        if (!cut_off) {
            const was = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(was);
            conn.rollback() catch {};
            if (prepared) _ = conn.execOpts("DEALLOCATE nilo_describe", .{}, .{}) catch {};
        }
    }
    _ = conn.execOpts("SET LOCAL plan_cache_mode = force_generic_plan", .{}, .{}) catch |err|
        return translate(io, conn, err);

    const prepare = std.fmt.allocPrint(arena, "PREPARE nilo_describe AS {s}", .{sql}) catch
        return error.QueryFailed;
    _ = conn.execOpts(prepare, .{}, .{}) catch |err| return translate(io, conn, err);
    prepared = true;

    var explain: std.ArrayList(u8) = .empty;
    explain.appendSlice(arena, "EXPLAIN (VERBOSE, FORMAT JSON) EXECUTE nilo_describe") catch
        return error.QueryFailed;
    for (0..params) |i| {
        explain.appendSlice(arena, if (i == 0) "(NULL" else ", NULL") catch return error.QueryFailed;
    }
    if (params > 0) explain.append(arena, ')') catch return error.QueryFailed;

    var json: std.ArrayList(u8) = .empty;
    {
        const result = conn.queryOpts(explain.items, .{}, .{ .allocator = arena }) catch |err|
            return translate(io, conn, err);
        defer result.deinit();
        while (result.next() catch |err| return translate(io, conn, err)) |row| {
            const piece = row.get([]const u8, 0) catch return error.QueryFailed;
            json.appendSlice(arena, piece) catch return error.QueryFailed;
        }
    }

    const found = plan_reader.outerNullable(arena, json.items, out.len) catch return error.QueryFailed;
    for (out, found) |*column, is_null| column.outer_null = is_null;
}

/// Give a connection back to the pool with cancellation held off (ADR 223).
///
/// Returning a connection is cleanup, and pg.zig's `release` may dial a
/// replacement for one a cancelled statement left mid-conversation. That
/// dial is a cancellation point: unprotected, it takes the cancellation
/// `translate` has just re-armed, logs "connect error: Canceled", and the
/// caller is left with a failed statement and no cancellation — the loop
/// that should have stopped sleeps on.
fn giveBack(io: std.Io, conn: *pg.Conn) void {
    const was = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(was);
    conn.release();
}

/// Whether an idle connection's socket has something to say, which on a
/// connection nobody has sent anything down means it is gone: a FIN from a
/// server that restarted or failed over, the `57P01` it sends first, or a
/// reset from a NAT that forgot it. One `poll` with no wait, a few hundred
/// nanoseconds against a round trip of tens of microseconds.
///
/// A socket that died silently, dropped with nothing sent back, still reads
/// as quiet here; its first statement fails as it did before, and the pool
/// replaces it on the way back.
fn hungUp(conn: *pg.Conn) bool {
    if (comptime builtin.os.tag == .windows) return false;
    var fds = [1]std.posix.pollfd{.{
        .fd = conn._stream.state.stream.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, 0) catch return false;
    return ready > 0 and fds[0].revents != 0;
}

/// A connection that could not be had. A cancellation while waiting for
/// one is re-armed for the caller, as `translate` does (ADR 223).
///
/// **The pool's own bound is `TimedOut`**, which is what `wire.OpenOpts`
/// promises for `timeout_ms` and what the SQLite Wire answers for the same
/// wait (ADR 107). Every other failure is `Disconnected`, a cancellation
/// included.
fn acquireFailed(io: std.Io, err: anyerror) wire.Error {
    if (err == error.Canceled) io.recancel();
    if (err == error.Timeout) {
        std.log.warn(
            "nilo_sql: a statement waited for a connection from the pool and gave up. " ++
                "Raise `size`, or shorten what a request holds one for. `timeout_ms` is the bound.",
            .{},
        );
        return error.TimedOut;
    }
    return error.Disconnected;
}

/// Whether the statement that just failed was refused because the plan kept
/// for it on this connection no longer describes what it answers.
///
/// Postgres keeps a prepared statement's result type and refuses to run it
/// once a change to a table would alter that type — a migration's
/// `ALTER COLUMN … TYPE` under a server still running the old binary is the
/// ordinary way there. The code alone is not enough: `0A000` is
/// *feature_not_supported*, and most of what it covers has nothing to do with
/// a plan, so the message is read too.
fn stalePlan(conn: *const pg.Conn) bool {
    const server = conn.err orelse return false;
    return std.mem.eql(u8, server.code, "0A000") and
        std.mem.startsWith(u8, server.message, "cached plan must not change result type");
}

/// Drop a stale plan so the statement can be sent again, outside a
/// transaction, where nothing was done before it and it may simply run once
/// more. True when the statement is worth retrying.
///
/// **Once, and only on this refusal.** Every connection in the pool holds its
/// own copy of the plan, so each finds out on its next use of it; a retry
/// costs that one statement a `DEALLOCATE` and a fresh prepare, which is what
/// the first use of the plan cost anyway. Anything else is answered as it
/// was, and a second refusal of the retry is reported rather than retried.
///
/// **The same for a plan the server no longer has** (`planGone`, ADR 241):
/// a pooler that handed this connection a different server connection, or a
/// server that restarted behind a pooler that kept the client's socket.
/// pg.zig still believes the statement is prepared and would send `Bind`
/// for it forever, so the connection would go back to the pool and fail on
/// every call that reached it. `deallocate` forgets the client's copy first
/// and only then asks the server, which answers `26000` again for a name it
/// never had; that answer is the expected one and is dropped, and any other
/// failure of the `DEALLOCATE` (a dead socket) is not a retry.
///
/// **Once is enough** because the retry prepares the statement again and
/// sends it in the same call. A second `26000` on it means the server
/// connection changed *between the two halves of one call*, which is what a
/// transaction-mode pooler does and which no number of retries cures; the
/// answer is `pgbouncer=true` in the URL, and the message says so.
fn replanned(conn: *pg.Conn, plan: ?[]const u8) bool {
    const name = plan orelse return false;
    const gone = planGone(conn);
    if (!gone and !stalePlan(conn)) return false;
    conn.deallocate(name) catch |err| {
        if (!gone or err != error.PG) return false;
    };
    conn.err = null;
    return true;
}

/// Whether the statement that just failed was refused because the server has
/// no statement by that name: `26000`, *invalid_sql_statement_name*, with
/// Postgres's `prepared statement "…" does not exist`. The message is read
/// as well as the code, as `stalePlan` does, since `26000` also covers a
/// cursor or a portal.
fn planGone(conn: *const pg.Conn) bool {
    const server = conn.err orelse return false;
    return std.mem.eql(u8, server.code, "26000") and
        std.mem.startsWith(u8, server.message, "prepared statement ") and
        std.mem.endsWith(u8, server.message, " does not exist");
}

/// A pg.zig error, plus whatever the server said about it, as one of
/// `wire.Error` (ADR 036).
///
/// The mapping is by SQLSTATE rather than by message, because the message
/// is localised and the code is not. Class 23 is "integrity constraint
/// violation" and `23505` is the one worth separating: a unique violation
/// is the client having asked for something that is already there, which is
/// a 409 and not a bug. The rest of class 23 usually means the code is
/// wrong, so it stays undifferentiated on purpose.
///
/// The connection's error field is read first, because pg.zig puts the
/// server's answer there and hands back a generic error. That is only sound
/// while the field is about the statement that just ran: the pool clears it
/// on `release`, and a transaction clears it itself in `Tx.fresh`, which is
/// where the reasoning is written down.
fn translate(io: std.Io, conn: *pg.Conn, err: anyerror) wire.Error {
    // **A cancellation is handed back, not swallowed** (ADR 223). The fiber
    // was cancelled — a request that went away, a server shutting down — and
    // the statement was one cancellation point on its way out. `Canceled`
    // is not in `wire.Error`, so the caller gets `QueryFailed`; re-arming it
    // is what makes the caller's next cancellation point report it again.
    // Without this, a background loop whose `nilo.sleep(..) catch return`
    // is its only way out logs the failure and sleeps on, and the process
    // never exits.
    if (err == error.Canceled) {
        io.recancel();
        return error.QueryFailed;
    }
    if (conn.err) |server| {
        if (std.mem.eql(u8, server.code, "23505")) return error.AlreadyExists;
        // The three other codes in class 23 a caller routinely branches on
        // (ADR 117). `23503` is the one that matters most: it is the only
        // member of the class that is ordinarily a race rather than a bug, and
        // it used to arrive as `ConstraintViolated` beside a check somebody
        // wrote and a null the code should never have sent.
        if (std.mem.eql(u8, server.code, "23503")) return error.ForeignKeyViolated;
        if (std.mem.eql(u8, server.code, "23502")) return error.NotNullViolated;
        if (std.mem.eql(u8, server.code, "23514")) return error.CheckViolated;
        if (std.mem.startsWith(u8, server.code, "23")) return error.ConstraintViolated;
        // `57014` is `query_canceled`, which Postgres sends both for a
        // `statement_timeout` and for a `pg_cancel_backend` from somewhere
        // else. Nothing in this module issues a cancel, so inside nilo the
        // code means the deadline fired — and an operator who cancels a query
        // by hand has told the handler the same thing either way: this
        // statement is not going to finish.
        if (std.mem.eql(u8, server.code, "57014")) return error.TimedOut;
        // `55P03` is `lock_not_available`, which Postgres sends for a
        // `NOWAIT` that found the row held. It is the answer the statement
        // was written to get rather than a failure, so it gets a name.
        if (std.mem.eql(u8, server.code, "55P03")) return error.Locked;
        // `40001` is a serialization failure and `40P01` a deadlock: Postgres
        // rolled the whole transaction back so the ones beside it stay
        // consistent. Nothing it did was kept and running it again is the
        // answer, which a handler cannot do while this reads the same as a
        // statement that is simply wrong. The rest of class 40 is left out on
        // purpose: `40003` is *statement completion unknown*, which is the one
        // thing this name must not claim.
        if (std.mem.eql(u8, server.code, "40001") or std.mem.eql(u8, server.code, "40P01"))
            return error.RolledBack;
        // A plan kept on this connection that a migration has since changed
        // the answer of, reaching here only inside a transaction — outside one
        // `replanned` has already sent the statement again. The transaction
        // is aborted and the plan is dropped when it ends, so running it
        // again is the answer here too.
        if (stalePlan(conn)) {
            std.log.warn(
                "nilo_sql: a prepared statement's result changed under it (a migration ran " ++
                    "while this server was up); the transaction was rolled back and the " ++
                    "statement will be prepared again.",
                .{},
            );
            return error.RolledBack;
        }
        // The server has no statement by that name. Outside a transaction
        // `replanned` has already forgotten it and sent the statement again,
        // so reaching here twice means the server connection changed between
        // the halves of one call; inside one, the transaction is aborted and
        // the rollback forgets the plan (`noteStale`). Either way the cure
        // is not another retry (ADR 241).
        if (planGone(conn)) {
            std.log.warn(
                "nilo_sql: the server has no prepared statement by the name nilo kept it " ++
                    "under. That is a connection pooler in transaction mode handing out a " ++
                    "different server connection per transaction: put `pgbouncer=true` in " ++
                    "the URL, or `.prepared = false` in the options, to stop keeping " ++
                    "statements prepared.",
                .{},
            );
            return error.RolledBack;
        }
        // Every statement after a failed one in the same transaction, until a
        // rollback. What was wrong is the earlier failure the handler caught
        // and carried on past, so that is what the line says.
        if (std.mem.eql(u8, server.code, "25P02")) {
            std.log.warn("{s}", .{wire.aborted_statement});
            return error.QueryFailed;
        }
        // The text never reaches the client (ADR 024); it goes here, where
        // whoever is reading the log is the person who can fix it. `warn`
        // rather than `err`, because this is a request failing and `err` is
        // the level that says the server is refusing to start.
        std.log.warn("nilo_sql: {s} [{s}]", .{ server.message, server.code });
        return error.QueryFailed;
    }
    return switch (err) {
        // `SocketUnconnected` is a write to a socket the peer has already
        // closed: a statement sent into an aborted transaction is revived and
        // written, so it meets a dead socket here rather than a `.fail` that
        // pg.zig refuses as `ConnectionBusy`.
        error.ConnectionBusy,
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.SocketUnconnected,
        => error.Disconnected,
        // **Named rather than silent, and that is the fix**
        // ([ADR 117](../docs/adr/117-a-statement-that-failed-says-what-the-database-said.md)).
        // `conn.err` is null whenever the statement never left the process —
        // pg.zig refusing to bind a value is the ordinary way there — so this
        // branch used to log nothing at all and hand back `QueryFailed`. The
        // caller then had one word for a failure Postgres had never seen, and
        // Postgres had nothing to say either because nothing arrived. The
        // error's own name is the whole of what was missing: `CannotBindStruct`
        // is three iterations of somebody's afternoon.
        else => {
            std.log.warn(
                "nilo_sql: the driver refused a statement before it reached the database " ++
                    "({s}). The server said nothing because nothing arrived.",
                .{@errorName(err)},
            );
            return error.QueryFailed;
        },
    };
}

/// `translate`, plus the server's own words left where a program can read
/// them (ADR 117).
///
/// The copy is not optional: `server.message` points into memory pg.zig owns
/// per connection, and the connection goes back to the pool on the next line.
/// The arena is the request's, so what a watcher holds dies with the request
/// that produced it — the rule `db.zig` already applies to every column it
/// reads.
///
/// An allocation failure here is *not* an error: this runs on a path that is
/// already failing, and turning "the statement was refused" into "we ran out
/// of memory telling you so" would lose the answer the caller came for. What
/// cannot be copied is left empty.
fn reported(
    io: std.Io,
    conn: *pg.Conn,
    err: anyerror,
    arena: std.mem.Allocator,
    problem: ?*?wire.Problem,
) wire.Error {
    if (problem) |slot| {
        if (conn.err) |server| {
            slot.* = .{
                .message = keepText(arena, server.message),
                .code = keepText(arena, server.code),
                .severity = keepText(arena, server.severity),
                .detail = keepText(arena, server.detail orelse ""),
                .hint = keepText(arena, server.hint orelse ""),
                .constraint = keepText(arena, server.constraint orelse ""),
            };
        } else {
            // No server answer, so the driver's own error name is the message
            // — `@errorName` points into the binary and needs no copy.
            slot.* = .{ .message = @errorName(err) };
        }
    }
    return translate(io, conn, err);
}

/// One of the server's strings, in the arena, or empty when it will not fit.
fn keepText(arena: std.mem.Allocator, text: []const u8) []const u8 {
    if (text.len == 0) return "";
    return arena.dupe(u8, text) catch "";
}

/// How many connections the pool has thrown away rather than taken back,
/// out of pg.zig's own `pg_pool_dirty` counter.
///
/// **Test-facing, and it exists because nothing else reveals the number.**
/// `Pool.release` destroys a connection it cannot vouch for and dials a
/// replacement on the spot, so a caller sees the same rows either way and the
/// pool's own `stats()` reads the same too. A test written against behaviour
/// therefore passes whether or not `revive` above is doing anything, which is
/// the shape [ADR 032](../docs/adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
/// is about. Reading the counter is what makes the fix falsifiable.
///
/// Parsed out of the metrics text because that is the only way pg.zig hands
/// the number over; it is a process-wide counter, so a test compares two
/// readings rather than trusting one.
pub fn dirtyConnections() !usize {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try pg.writeMetrics(&w);

    const key = "pg_pool_dirty";
    const at = std.mem.indexOf(u8, w.buffered(), key) orelse return error.NoSuchMetric;
    // Prometheus text: `pg_pool_dirty <number>` on its own line, and the
    // `# TYPE` line above it also contains the name — so the count is read
    // off the line that has a number after the key rather than the first hit.
    var lines = std.mem.splitScalar(u8, w.buffered()[at..], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key ++ " ")) continue;
        const text = std.mem.trim(u8, line[key.len..], " \r");
        return std.fmt.parseInt(usize, text, 10) catch continue;
    }
    return error.NoSuchMetric;
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

test "the postgres wire satisfies the contract" {
    comptime wire.assertWire(Wire);
}

test "what a transaction was begun with is spelled onto the BEGIN itself" {
    try testing.expectEqualStrings("BEGIN", comptime Wire.beginText(.{}));
    try testing.expectEqualStrings(
        "BEGIN ISOLATION LEVEL SERIALIZABLE",
        comptime Wire.beginText(.{ .isolation = .serializable }),
    );
    try testing.expectEqualStrings(
        "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY",
        comptime Wire.beginText(.{ .isolation = .repeatable_read, .read_only = true }),
    );
    // Written out rather than left off, for a server whose role has a
    // different default set on it.
    try testing.expectEqualStrings(
        "BEGIN ISOLATION LEVEL READ COMMITTED",
        comptime Wire.beginText(.{ .isolation = .read_committed }),
    );
    try testing.expectEqualStrings("BEGIN READ ONLY", comptime Wire.beginText(.{ .read_only = true }));
}

test "how many connections to dial reaches the pool, which it did not" {
    // The bug this holds: `pg.Pool.initUri` copies `size` and `timeout` onto
    // the Opts it parsed and **drops `connect_on_init_count`**, which then
    // falls to `orelse size` inside `Pool.init`. So every pool nilo opened
    // dialled itself in full at startup and died on the first refusal —
    // which made `connect_on_init = 0`, the default, mean the opposite of
    // what three files said it meant (ADR 115).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const uri = try std.Uri.parse("postgres://app:hunter2@db.internal:5433/shop");
    const opts = try Wire.poolOpts(uri, arena.allocator(), .{
        .size = 10,
        .connect_on_init = 0,
        .timeout_ms = 3_000,
    });

    // Zero, not ten. The whole defect is that this was ten.
    try testing.expectEqual(@as(?u16, 0), opts.connect_on_init_count);
    try testing.expectEqual(@as(u16, 10), opts.size);
    try testing.expectEqual(@as(u32, 3_000), opts.timeout);
}

test "a pool wait of zero is no bound, and pg.zig's own timeout is TimedOut" {
    // pg.zig reads `timeout = 0` as a deadline already passed, so an empty
    // pool would fail at once for a caller who documented "no bound".
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const uri = try std.Uri.parse("postgres://app@db.internal/shop");
    const unbounded = try Wire.poolOpts(uri, arena.allocator(), .{ .size = 4, .timeout_ms = 0 });
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), unbounded.timeout);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try testing.expectEqual(wire.Error.TimedOut, acquireFailed(io, error.Timeout));
    try testing.expectEqual(wire.Error.Disconnected, acquireFailed(io, error.PoolExhausted));
}

test "a URL is taken apart the way pg.zig would have taken it apart" {
    // `parseOpts` is not reachable through pg.zig's module root, so this is
    // a copy — and a copy that drifts is worse than the call it replaced.
    // These are pg.zig's own defaults, asserted here so that a change to
    // them is a failing test rather than a connection to the wrong database.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const full = try Wire.dialOpts(
        try std.Uri.parse("postgres://app:hunter2@db.internal:5433/shop?sslmode=require"),
        aa,
    );
    try testing.expectEqualStrings("app", full.auth.username);
    try testing.expectEqualStrings("hunter2", full.auth.password.?);
    try testing.expectEqualStrings("shop", full.auth.database.?);
    try testing.expectEqualStrings("db.internal", full.connect.host.?);
    try testing.expectEqual(@as(?u16, 5433), full.connect.port);
    try testing.expect(full.connect.tls == .require);

    // Nothing given: `postgres` as the user, no database, no port, no TLS,
    // and a ten-second auth timeout.
    const bare = try Wire.dialOpts(try std.Uri.parse("postgres:///"), aa);
    try testing.expectEqualStrings("postgres", bare.auth.username);
    try testing.expectEqual(@as(?[]const u8, null), bare.auth.password);
    try testing.expectEqual(@as(?[]const u8, null), bare.auth.database);
    try testing.expectEqual(@as(?u16, null), bare.connect.port);
    try testing.expect(bare.connect.tls == .off);
    try testing.expectEqual(@as(u32, 10_000), bare.auth.timeout);

    // `tcp_user_timeout` is pg.zig's other parameter, and it lands on the
    // auth timeout rather than anywhere that sounds like it. libpq means a
    // socket option by it, which pg.zig cannot set, so it is refused
    // (ADR 241) instead of being read as something else.
    try testing.expectError(
        error.UnsupportedConnectionParam,
        Wire.dialOpts(try std.Uri.parse("postgres://h/db?tcp_user_timeout=5678"), aa),
    );
}

test "a sslmode nobody wrote is require for any host but this machine" {
    // ADR 241. libpq's `prefer` would encrypt when the server can, and
    // anybody on the path can make it unable; pg.zig does not do `prefer`,
    // so the two defaults it can honour are chosen by where the host is.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    for ([_][]const u8{
        "postgres://db.internal/shop",
        "postgres://app:pw@10.0.0.5:5432/shop",
        "postgres://db.example.com/shop",
        "postgres://[2001:db8::1]/shop",
        "postgres://128.0.0.1/shop",
        "postgres://localhost.example.com/shop",
        "postgres:///shop?host=db.internal",
    }) |url| {
        const got = try Wire.dialOpts(try std.Uri.parse(url), aa);
        try testing.expect(got.connect.tls == .require);
    }

    for ([_][]const u8{
        "postgres://localhost/shop",
        "postgres://LOCALHOST:5433/shop",
        "postgres://127.0.0.1/shop",
        "postgres://127.3.4.5/shop",
        "postgres://[::1]/shop",
        "postgres:///shop",
        "postgres://app:pw@%2Fvar%2Frun%2Fpostgresql/shop",
        "postgres:///shop?host=/var/run/postgresql",
        "postgres:///shop?host=localhost",
    }) |url| {
        const got = try Wire.dialOpts(try std.Uri.parse(url), aa);
        try testing.expect(got.connect.tls == .off);
    }
}

test "a sslmode the URL wrote wins over the default, whatever the host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Knowingly plaintext to a remote host: the one-line way out.
    const open = try Wire.dialOpts(try std.Uri.parse("postgres://db.internal/shop?sslmode=disable"), aa);
    try testing.expect(open.connect.tls == .off);

    // TLS to this machine, and verification, when asked for.
    const local = try Wire.dialOpts(try std.Uri.parse("postgres://localhost/shop?sslmode=require"), aa);
    try testing.expect(local.connect.tls == .require);
    const checked = try Wire.dialOpts(try std.Uri.parse("postgres://localhost/shop?sslmode=verify-full"), aa);
    try testing.expect(checked.connect.tls == .verify_full);
    try testing.expectEqual(@as(?[]const u8, null), checked.connect.tls.verify_full);
    const rooted = try Wire.dialOpts(try std.Uri.parse(
        "postgres://db.internal/shop?sslmode=verify-full&sslrootcert=/ca.crt",
    ), aa);
    try testing.expectEqualStrings("/ca.crt", rooted.connect.tls.verify_full.?);

    // A CA with the default mode is still refused: the default is not
    // `verify-full`, so the file would never be opened.
    try testing.expectError(
        error.UnsupportedConnectionParam,
        Wire.dialOpts(try std.Uri.parse("postgres://db.internal/shop?sslrootcert=/ca.crt"), aa),
    );
}

test "a URL that names a pooler in transaction mode turns prepared statements off" {
    // ADR 241: `pgbouncer=true` used to be dropped, and the `Db` behind it
    // kept statements prepared on a connection the pooler then swapped.
    try testing.expect(Wire.urlIsPooled("postgres://h/db?pgbouncer=true"));
    try testing.expect(Wire.urlIsPooled("postgres://h/db?sslmode=require&pgbouncer=true&connect_timeout=5"));
    try testing.expect(Wire.urlIsPooled("postgres://h/db?pool_mode=transaction"));
    try testing.expect(Wire.urlIsPooled("postgres://h/db?pool_mode=statement"));
    try testing.expect(Wire.urlIsPooled("postgres://h/db?pgbounce%72=true"));

    try testing.expect(!Wire.urlIsPooled("postgres://h/db?pgbouncer=false"));
    try testing.expect(!Wire.urlIsPooled("postgres://h/db?pool_mode=session"));
    try testing.expect(!Wire.urlIsPooled("postgres://h/db"));
    try testing.expect(!Wire.urlIsPooled("postgres://h/db?sslmode=require"));
    try testing.expect(!Wire.urlIsPooled("not a url"));

    // A value that is not a boolean is refused, not read as "no pooler".
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        error.UnsupportedConnectionParamValue,
        Wire.dialOpts(try std.Uri.parse("postgres://h/db?pgbouncer=ture"), arena.allocator()),
    );
}

test "a prepared statement the server never had is recognised by its code and its words" {
    // ADR 241. `26000` also names a missing cursor or portal, and those are
    // not this connection's plan.
    var conn: pg.Conn = undefined;
    conn.err = .{ .severity = "ERROR", .code = "26000", .message = "prepared statement \"nilo_x\" does not exist" };
    try testing.expect(planGone(&conn));
    conn.err = .{ .severity = "ERROR", .code = "26000", .message = "cursor \"c\" does not exist" };
    try testing.expect(!planGone(&conn));
    conn.err = .{ .severity = "ERROR", .code = "0A000", .message = "prepared statement \"x\" does not exist" };
    try testing.expect(!planGone(&conn));
    conn.err = null;
    try testing.expect(!planGone(&conn));
}

test "a parameter pg.zig has a field for is carried onto it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // The URL a hosted database hands out: a name for `pg_stat_activity`,
    // a connect timeout in seconds, keepalives, and a CA to verify against.
    const hosted = try Wire.dialOpts(try std.Uri.parse(
        "postgres://app:pw@h/shop?application_name=nilo&connect_timeout=5" ++
            "&keepalives=1&keepalives_idle=60&keepalives_interval=5&keepalives_count=2" ++
            "&sslmode=verify-full&sslrootcert=/etc/ssl/db.crt",
    ), aa);
    try testing.expectEqualStrings("nilo", hosted.auth.application_name.?);
    try testing.expectEqual(@as(u32, 5_000), hosted.auth.timeout);
    try testing.expect(hosted.connect.keepalive);
    try testing.expectEqual(@as(?u32, 60), hosted.connect.keepalive_idle);
    try testing.expectEqual(@as(?u32, 5), hosted.connect.keepalive_interval);
    try testing.expectEqual(@as(?u32, 2), hosted.connect.keepalive_count);
    try testing.expectEqualStrings("/etc/ssl/db.crt", hosted.connect.tls.verify_full.?);

    // `sslrootcert=system` is libpq for the platform's store, which is
    // pg.zig with no path; `fallback_application_name` yields to the
    // real one; `keepalives=0` switches them off.
    const system = try Wire.dialOpts(try std.Uri.parse(
        "postgres://h/db?sslrootcert=system&sslmode=verify-full" ++
            "&fallback_application_name=fallback&application_name=named&keepalives=0",
    ), aa);
    try testing.expectEqual(@as(?[]const u8, null), system.connect.tls.verify_full);
    try testing.expectEqualStrings("named", system.auth.application_name.?);
    try testing.expect(!system.connect.keepalive);
    const fallback = try Wire.dialOpts(
        try std.Uri.parse("postgres://h/db?fallback_application_name=fallback"),
        aa,
    );
    try testing.expectEqualStrings("fallback", fallback.auth.application_name.?);

    // The query forms of the authority part, for a password the URL could
    // not otherwise hold: split before decoding, so the `&` inside it
    // stays inside it.
    const query_form = try Wire.dialOpts(try std.Uri.parse(
        "postgres:///?user=app&password=p%26w%3D1&dbname=shop&host=db.internal&port=5433",
    ), aa);
    try testing.expectEqualStrings("app", query_form.auth.username);
    try testing.expectEqualStrings("p&w=1", query_form.auth.password.?);
    try testing.expectEqualStrings("shop", query_form.auth.database.?);
    try testing.expectEqualStrings("db.internal", query_form.connect.host.?);
    try testing.expectEqual(@as(?u16, 5433), query_form.connect.port);

    // Server settings ride in the startup message as written: `options`
    // is parsed by the server like `postgres -c`, and UTF-8 is the one
    // encoding asked for, spelled the way Postgres spells it.
    const set = try Wire.dialOpts(try std.Uri.parse(
        "postgres://h/db?options=-c%20statement_timeout%3D5s&client_encoding=utf-8",
    ), aa);
    try testing.expectEqualStrings("-c statement_timeout=5s", set.auth.startup_parameters.?.get("options").?);
    try testing.expectEqualStrings("UTF8", set.auth.startup_parameters.?.get("client_encoding").?);
    try testing.expect(hosted.auth.startup_parameters == null);
    try testing.expectError(
        error.ConflictingConnectionParam,
        Wire.dialOpts(try std.Uri.parse("postgres://h/db?options=-c%20a%3D1&options=-c%20a%3D2"), aa),
    );

    // Said twice and the same, fine; said twice and different, refused.
    _ = try Wire.dialOpts(try std.Uri.parse("postgres://app@h:5433/shop?user=app&port=5433"), aa);
    try testing.expectError(
        error.ConflictingConnectionParam,
        Wire.dialOpts(try std.Uri.parse("postgres://app@h/shop?user=other"), aa),
    );
    try testing.expectError(
        error.ConflictingConnectionParam,
        Wire.dialOpts(try std.Uri.parse("postgres://h:5432/shop?port=5433"), aa),
    );
}

test "a parameter the driver does already or could never act on is dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Every one of these is what Supabase, Neon or a pooler appends, and
    // none of them changes what the connection does. One warn line, and
    // the rest of the URL is read.
    const pooled = try Wire.dialOpts(try std.Uri.parse(
        "postgres://app@h/shop?pgbouncer=true&pool_mode=transaction&sslsni=1" ++
            "&gssencmode=disable&channel_binding=prefer&target_session_attrs=any&sslmode=require",
    ), aa);
    try testing.expectEqualStrings("shop", pooled.auth.database.?);
    try testing.expect(pooled.connect.tls == .require);
}

test "a URL nobody can read is refused rather than half understood" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // A scheme that is not Postgres, and a parameter nobody has heard of.
    // The second is the one worth refusing: a URL carrying a setting the
    // driver ignores is a deployment that believes something the
    // connection does not do.
    try testing.expectError(
        error.InvalidUriScheme,
        Wire.dialOpts(try std.Uri.parse("mysql://h/db"), aa),
    );
    try testing.expectError(
        error.UnsupportedConnectionParam,
        Wire.dialOpts(try std.Uri.parse("postgres://h/db?statement_timeout=5"), aa),
    );

    // The `sslmode`s that would fall back to plaintext, or check half of
    // what `verify-full` checks. Both are a connection that is not what the
    // URL says, and neither is quietly rounded to the nearest one pg.zig has.
    for ([_][]const u8{ "prefer", "allow", "verify-ca", "yes" }) |mode| {
        const url = try std.fmt.allocPrint(aa, "postgres://h/db?sslmode={s}", .{mode});
        try testing.expectError(
            error.UnsupportedSSLModeValue,
            Wire.dialOpts(try std.Uri.parse(url), aa),
        );
    }

    // A CA beside a mode that never opens it.
    try testing.expectError(
        error.UnsupportedConnectionParam,
        Wire.dialOpts(try std.Uri.parse("postgres://h/db?sslmode=require&sslrootcert=/ca.crt"), aa),
    );

    // Known parameters asking for what pg.zig does not do: a client
    // certificate, channel binding, GSSAPI, a read-write check, SNI off,
    // text in an encoding other than UTF-8.
    for ([_][]const u8{ "sslcert=/c.crt", "sslkey=/c.key" }) |param| {
        const url = try std.fmt.allocPrint(aa, "postgres://h/db?{s}", .{param});
        try testing.expectError(
            error.UnsupportedConnectionParam,
            Wire.dialOpts(try std.Uri.parse(url), aa),
        );
    }
    for ([_][]const u8{
        "channel_binding=require", "gssencmode=require",     "target_session_attrs=read-write",
        "sslsni=0",                "client_encoding=LATIN1",
    }) |param| {
        const url = try std.fmt.allocPrint(aa, "postgres://h/db?{s}", .{param});
        try testing.expectError(
            error.UnsupportedConnectionParamValue,
            Wire.dialOpts(try std.Uri.parse(url), aa),
        );
    }
}
