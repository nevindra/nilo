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
        /// is what a 12 µs saving is being bought with. `db.raw` does not
        /// come through here at all: its text arrives at run time, so there
        /// is no comptime name to derive and no bound on how many there
        /// would be (ADR 0057).
        fn planOf(self: *Self, comptime stmt: statement.Statement) ?[]const u8 {
            if (!self.opts.prepared) return null;
            return comptime statement.planName(stmt.sql);
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

        /// Finish building, now that there is an event loop to dial
        /// through. Called by `listen()` before the first connection is
        /// accepted (ADR 0040).
        pub fn nilo_start(self: *Self, io: std.Io) !void {
            self.wire = W.open(io, self.gpa, self.url, .{
                .size = self.opts.size,
                .connect_on_init = self.opts.connect_on_init,
                .timeout_ms = self.opts.timeout_ms,
            }) catch |err| {
                // Two failures reach here and they want different sentences.
                // Before ADR 0062 the pool dialled itself whatever
                // `connect_on_init` said, so *both* of them got the one
                // about the URL — which sent people to check a URL that was
                // correct while their database was down.
                if (isUrlProblem(err)) std.log.err(
                    "nilo could not read the database URL \"{s}\" ({s}). This is the URL " ++
                        "itself rather than the database: the scheme has to be `postgres://` " ++
                        "or `postgresql://`, and the only parameters understood are `sslmode` " ++
                        "and `tcp_user_timeout`.",
                    .{ redacted(self.url), @errorName(err) },
                ) else std.log.err(
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

            const check = self.check orelse return;
            // A schema check needs a connection, and the whole point of
            // `connect_on_init = 0` is that there may not be one. A
            // database that is merely not running is not a mistake anybody
            // can fix by reading a stack trace, so it is said plainly and
            // startup carries on.
            const problems = check(self) catch |err| {
                std.log.warn(
                    "nilo could not check the schema ({s}). The tables will be checked by " ++
                        "whichever request reaches them first, which is later than anybody wanted.",
                    .{@errorName(err)},
                );
                return;
            };
            if (problems != 0 and self.opts.schema_mismatch_is_fatal) {
                std.log.err(
                    "nilo found {d} disagreement(s) between a Row and its table, listed above. " ++
                        "Each one is a request that would have failed later; fix them, or set " ++
                        "`.schema_mismatch_is_fatal = false` to start anyway.",
                    .{problems},
                );
                return error.SchemaMismatch;
            }
        }

        // -- reading ---------------------------------------------------------

        /// Every row matching `options`, in the request's arena.
        ///
        /// The statement itself was settled while compiling: `options` only
        /// carries the values (ADR 0039).
        pub fn select(self: *Self, comptime Row: type, c: anytype, options: anytype) ![]Row {
            comptime core.checkScope(@TypeOf(c), "db.select");
            comptime assertUnlocked(Row, @TypeOf(options), "db.select",
                "Begin one and ask there: `var tx = try db.begin(c, .{}); defer tx.deinit();` " ++
                    "and then `tx.select(…)`.");
            const stmt = comptime statement.select(D, Row, @TypeOf(options));
            return fill(Row, stmt.reserve, try self.wireOf(), null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
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
            comptime assertUnlocked(Row, @TypeOf(options), "db.one",
                "Begin one and ask there: `var tx = try db.begin(c, .{}); defer tx.deinit();` " ++
                    "and then `tx.one(…)`.");
            const stmt = comptime statement.one(D, Row, @TypeOf(options));
            const found = try fill(Row, stmt.reserve, try self.wireOf(), null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
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
        pub fn find(self: *Self, comptime Row: type, c: anytype, key: anytype) !?Row {
            comptime core.checkScope(@TypeOf(c), "db.find");
            const stmt = comptime statement.find(D, Row, @TypeOf(key));
            const found = try fill(Row, stmt.reserve, try self.wireOf(), null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, key, c));
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
            const n = try only(i64, try self.wireOf(), null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
            // `count(*)` is a `bigint` and never negative. A negative one
            // would mean the column read as something else entirely.
            if (n < 0) return error.QueryFailed;
            return @intCast(n);
        }

        /// Whether any row matches `options`.
        ///
        /// `EXISTS` rather than `count(…) > 0`: the database stops at the
        /// first match instead of counting every one of them to answer a
        /// question the first settles.
        pub fn exists(self: *Self, comptime Row: type, c: anytype, options: anytype) !bool {
            comptime core.checkScope(@TypeOf(c), "db.exists");
            const stmt = comptime statement.exists(D, Row, @TypeOf(options));
            return only(bool, try self.wireOf(), null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
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
            comptime assertUnlocked(Row, @TypeOf(options), "db.stream",
                "There is no `tx.stream` to move this to, either: a result set held open " ++
                    "keeps its connection busy, so nothing else in the transaction could " ++
                    "run until it closed. Lock the rows with `tx.select` and work through " ++
                    "what comes back.");
            const stmt = comptime statement.select(D, Row, @TypeOf(options));
            const w = try self.wireOf();
            const rows = try w.run(c.arena(), stmt.sql, try valuesOf(stmt, Row, options, c), self.planOf(stmt));
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
        /// keeps the `Str` rule, keeps the row filling — and gives up the
        /// compile-time column check, which is the whole of what it costs.
        /// The `SELECT` list has to line up with `Row`'s fields by position.
        pub fn raw(
            self: *Self,
            comptime Row: type,
            c: anytype,
            sql: []const u8,
            values: anytype,
        ) ![]Row {
            comptime core.checkScope(@TypeOf(c), "db.raw");
            // No ceiling: this module did not write the statement and so has
            // nothing to say about how many rows it can answer with.
            return fill(Row, null, try self.wireOf(), null, c, sql, null, values);
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
            const w = try self.wireOf();
            return w.exec(c.arena(), sql, values, null);
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
            const back = try fill(Row, 1, try self.wireOf(), null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, values, c));
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
                try self.wireOf(),
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
                try self.wireOf(),
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
        pub fn insertOrIgnore(
            self: *Self,
            comptime Row: type,
            c: anytype,
            values: anytype,
            comptime on: anytype,
        ) !?Row {
            comptime core.checkScope(@TypeOf(c), "db.insertOrIgnore");
            const stmt = comptime statement.insertOrIgnore(D, Row, @TypeOf(values), on);
            const back = try fill(Row, stmt.reserve, try self.wireOf(), null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, values, c));
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
            const back = try fill(Row, stmt.reserve, try self.wireOf(), null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, values, c));
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
            const w = try self.wireOf();
            return w.exec(c.arena(), stmt.sql, try valuesOf(stmt, Row, options, c), self.planOf(stmt));
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
            return fill(Row, stmt.reserve, try self.wireOf(), null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
        }

        /// Delete every row matching `options`, and say how many there were.
        pub fn delete(self: *Self, comptime Row: type, c: anytype, options: anytype) !usize {
            comptime core.checkScope(@TypeOf(c), "db.delete");
            const stmt = comptime statement.delete(D, Row, @TypeOf(options));
            const w = try self.wireOf();
            return w.exec(c.arena(), stmt.sql, try valuesOf(stmt, Row, options, c), self.planOf(stmt));
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
            return fill(Row, stmt.reserve, try self.wireOf(), null, c, stmt.sql, self.planOf(stmt), try valuesOf(stmt, Row, options, c));
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
                return fill(Row, stmt.reserve, self.w, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
            }

            pub fn one(self: *Tx, comptime Row: type, c: anytype, options: anytype) !?Row {
                comptime core.checkScope(@TypeOf(c), "tx.one");
                const stmt = comptime statement.one(D, Row, @TypeOf(options));
                const found = try fill(Row, stmt.reserve, self.w, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
                return if (found.len == 0) null else found[0];
            }

            pub fn find(self: *Tx, comptime Row: type, c: anytype, key: anytype) !?Row {
                comptime core.checkScope(@TypeOf(c), "tx.find");
                const stmt = comptime statement.find(D, Row, @TypeOf(key));
                const found = try fill(Row, stmt.reserve, self.w, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, key, c));
                return if (found.len == 0) null else found[0];
            }

            pub fn count(self: *Tx, comptime Row: type, c: anytype, options: anytype) !usize {
                comptime core.checkScope(@TypeOf(c), "tx.count");
                const stmt = comptime statement.count(D, Row, @TypeOf(options));
                const n = try only(i64, self.w, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
                if (n < 0) return error.QueryFailed;
                return @intCast(n);
            }

            pub fn exists(self: *Tx, comptime Row: type, c: anytype, options: anytype) !bool {
                comptime core.checkScope(@TypeOf(c), "tx.exists");
                const stmt = comptime statement.exists(D, Row, @TypeOf(options));
                return only(bool, self.w, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
            }

            pub fn insert(self: *Tx, comptime Row: type, c: anytype, values: anytype) !Row {
                comptime core.checkScope(@TypeOf(c), "tx.insert");
                const stmt = comptime statement.insert(D, Row, @TypeOf(values));
                // `RETURNING` on a successful insert answers with exactly one
                // row, so the list is sized for one and never grows.
                const back = try fill(Row, 1, self.w, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, values, c));
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
                    self.w,
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
                    self.w,
                    &self.inner,
                    c,
                    stmt.sql,
                    self.db.planOf(stmt),
                    try batchValuesOf(stmt, Row, V, items, c),
                );
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
                const back = try fill(Row, stmt.reserve, self.w, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, values, c));
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
                const back = try fill(Row, stmt.reserve, self.w, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, values, c));
                if (back.len == 0) return error.QueryFailed;
                return back[0];
            }

            pub fn update(self: *Tx, comptime Row: type, c: anytype, options: anytype) !usize {
                comptime core.checkScope(@TypeOf(c), "tx.update");
                const stmt = comptime statement.update(D, Row, @TypeOf(options));
                return self.inner.exec(c.arena(), stmt.sql, try valuesOf(stmt, Row, options, c), self.db.planOf(stmt));
            }

            pub fn updateReturning(self: *Tx, comptime Row: type, c: anytype, options: anytype) ![]Row {
                comptime core.checkScope(@TypeOf(c), "tx.updateReturning");
                const stmt = comptime statement.updateReturning(D, Row, @TypeOf(options));
                return fill(Row, stmt.reserve, self.w, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
            }

            pub fn delete(self: *Tx, comptime Row: type, c: anytype, options: anytype) !usize {
                comptime core.checkScope(@TypeOf(c), "tx.delete");
                const stmt = comptime statement.delete(D, Row, @TypeOf(options));
                return self.inner.exec(c.arena(), stmt.sql, try valuesOf(stmt, Row, options, c), self.db.planOf(stmt));
            }

            pub fn deleteReturning(self: *Tx, comptime Row: type, c: anytype, options: anytype) ![]Row {
                comptime core.checkScope(@TypeOf(c), "tx.deleteReturning");
                const stmt = comptime statement.deleteReturning(D, Row, @TypeOf(options));
                return fill(Row, stmt.reserve, self.w, &self.inner, c, stmt.sql, self.db.planOf(stmt), try valuesOf(stmt, Row, options, c));
            }

            pub fn raw(
                self: *Tx,
                comptime Row: type,
                c: anytype,
                sql: []const u8,
                values: anytype,
            ) ![]Row {
                comptime core.checkScope(@TypeOf(c), "tx.raw");
                return fill(Row, null, self.w, &self.inner, c, sql, null, values);
            }

            /// `db.exec` inside the transaction: a statement that answers with
            /// nothing, and the rows it changed (ADR 0078).
            pub fn exec(self: *Tx, c: anytype, sql: []const u8, values: anytype) !usize {
                comptime core.checkScope(@TypeOf(c), "tx.exec");
                return self.inner.exec(c.arena(), sql, values, null);
            }
        };

        /// Rows pulled one at a time, each borrowed from the read buffer.
        pub fn Streamed(comptime Row: type) type {
            comptime row_mod.assertRow(Row);
            comptime assertStreamable(Row);
            return struct {
                db: *Self,
                w: *W,
                rows: W.Rows,
                /// Debug only: whether `close` has run. A `Streamed` is a
                /// value the handler holds, so `close` being called twice
                /// through two copies would take the count below zero.
                closed: if (traps_enabled) bool else void = if (traps_enabled) false else {},

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
                    if (traps_enabled) {
                        if (self.closed) return;
                        self.closed = true;
                        self.db.hold(&self.db.open_streams, .Sub);
                    }
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
                    "it, and `db.nilo_start(io)` does it for a `Db` no App holds. " ++
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
            w: *W,
            tx: ?*W.Tx,
            c: anytype,
            sql: []const u8,
            plan: ?[]const u8,
            values: anytype,
        ) ![]Row {
            comptime row_mod.assertRow(Row);
            const arena = c.arena();

            var rows = if (tx) |t|
                try t.run(arena, sql, values, plan)
            else
                try w.run(arena, sql, values, plan);
            // Whatever happens below, the connection goes back usable —
            // including a handler's own error on the way past (`wire.zig`).
            defer w.drain(&rows);

            var out: std.ArrayList(Row) = .empty;
            if (reserve) |ceiling| try out.ensureTotalCapacityPrecise(arena, ceiling);
            while (try w.next(&rows)) {
                var filled: Row = undefined;
                inline for (comptime row_mod.columnsOf(Row), 0..) |column, i| {
                    const F = comptime row_mod.ColumnType(Row, column);
                    @field(filled, column) = try readColumn(w, &rows, F, i, c);
                }
                try out.append(arena, filled);
            }
            return out.toOwnedSlice(arena);
        }

        /// Run a statement that answers with one row of one column, and read
        /// it. What `count` and `exists` are built on.
        ///
        /// There is no Row here and no filling: the answer is a number or a
        /// bool, and giving it a struct to live in is what `Tally` in
        /// `live.zig` had to do back when `db.raw` was the only way to ask.
        fn only(
            comptime T: type,
            w: *W,
            tx: ?*W.Tx,
            c: anytype,
            sql: []const u8,
            plan: ?[]const u8,
            values: anytype,
        ) !T {
            const arena = c.arena();
            var rows = if (tx) |t|
                try t.run(arena, sql, values, plan)
            else
                try w.run(arena, sql, values, plan);
            defer w.drain(&rows);

            // An aggregate answers with exactly one row. None would mean the
            // driver and Postgres disagree about what was sent, which is not
            // something to paper over with a zero.
            if (!try w.next(&rows)) return error.QueryFailed;
            return w.read(&rows, T, 0);
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
            for (out, bytes) |*item, b| item.* = if (comptime @typeInfo(Item) == .optional)
                (if (b) |text| c.str(text) else null)
            else
                c.str(b);
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
                out[i] = try forWire(@TypeOf(out[i]), where_mod.valueAt(options, path), c);
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
                const Column = comptime BatchWrite(D, row_mod.ColumnType(Row, param.column));
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
/// is `BatchWrite` — two column types travel differently in an array than they
/// do alone. Sharing the type would have meant a `WireWrite` that answered
/// differently depending on who was asking, which is worse than two functions.
fn BatchValues(comptime D: type, comptime Row: type, comptime stmt: statement.Statement) type {
    return comptime blk: {
        var fields: [stmt.params.len]type = undefined;
        for (stmt.params, 0..) |param, i| {
            fields[i] = []const BatchWrite(D, row_mod.ColumnType(Row, param.column));
        }
        const frozen = fields;
        break :blk std.meta.Tuple(&frozen);
    };
}

/// What a column binds as **inside a batch** — `WireWrite`, with two
/// differences, both of them forced by what the driver can encode an array of.
///
/// - A `Uuid` binds as a slice of its bytes rather than as the array of them.
///   A single insert cannot do that: the tuple is all the driver has to read
///   from, and a slice would point at the copy `where.valueAt` just returned.
///   A batch has somewhere better to point — the caller's own slice of rows,
///   which is alive for the whole call by definition. pg.zig has no encoder
///   for an array of `[16]u8` and does have one for `uuid[]` given text.
/// - A `Json(T)` binds as the document, written out here, because pg.zig
///   encodes a `jsonb[]` element from bytes and will not take a struct. **That
///   is one allocation per row for that column** — the same cost reading one
///   already has, and the only place a batch pays per row rather than per
///   column.
fn BatchWrite(comptime D: type, comptime F: type) type {
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
            const F = WireWrite(D, row_mod.ColumnType(Row, param.column));
            // `.in` is one placeholder holding many values — `= ANY($1)` —
            // so what binds is a list of the column's type rather than one
            // of them. `distinct_from` is the mirror: one value, which may be
            // null even on a column that may not, because the comparison is
            // null-safe and the statement says so either way (`where.zig`).
            fields[i] = if (param.list) []const F else if (param.nullable) Maybe(F) else F;
        }
        const frozen = fields;
        break :blk std.meta.Tuple(&frozen);
    };
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
/// applied to the element type, and only `Str` moves. Everything else a
/// Dialect will accept in an array is already a type the driver decodes into,
/// so for those this is `F` itself and `keptList` hands the slice straight
/// back.
fn WireList(comptime F: type) type {
    comptime {
        const optional = @typeInfo(F) == .optional;
        const Slice = if (optional) @typeInfo(F).optional.child else F;
        const Item = @typeInfo(Slice).pointer.child;
        const OnWire = switch (Item) {
            core.Str => []const u8,
            ?core.Str => ?[]const u8,
            else => Item,
        };
        if (OnWire == Item) return F;
        return if (optional) ?[]const OnWire else []const OnWire;
    }
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
    return value;
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
        "InvalidUriScheme",     "UnsupportedSSLModeValue", "UnsupportedConnectionParam",
        // `std.Uri.parse`, and the integer parse behind `tcp_user_timeout`.
        "UnexpectedCharacter",  "InvalidFormat",           "InvalidPort",
        "InvalidCharacter",     "Overflow",
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
    _ = try db.raw(Person, c, "SELECT 1", .{});

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
    _ = try tx.raw(Person, c, "SELECT 1", .{});

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
fn streamAndClose(db: *FakeDb, c: *nilo.Ctx) !void {
    var rows = try db.stream(Person, c, .{});
    if (traps_enabled) try testing.expectEqual(@as(usize, 1), db.open_streams);
    rows.close();
    rows.close();
}

test "a result set that is closed is not still counted as held" {
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
    try testing.expectEqual([]const u8, BatchWrite(dialect.Postgres, types.Uuid));
    try testing.expectEqual(?[]const u8, BatchWrite(dialect.Postgres, ?types.Uuid));

    // A `Json(T)` is handed to the driver whole when it is alone and written
    // out here when it is in a batch, which is the one place a batch pays per
    // row rather than per column.
    const Settings = types.Json(struct { theme: []const u8 });
    try testing.expectEqual(Settings, WireWrite(dialect.Postgres, Settings));
    try testing.expectEqual([]const u8, BatchWrite(dialect.Postgres, Settings));
    try testing.expectEqual(?[]const u8, BatchWrite(dialect.Postgres, ?Settings));

    // Everything else is the same both ways.
    try testing.expectEqual(i64, BatchWrite(dialect.Postgres, i64));
    try testing.expectEqual(i64, BatchWrite(dialect.Postgres, types.Timestamp));
    try testing.expectEqual([]const u8, BatchWrite(dialect.Postgres, core.Str));
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

test "a statement whose text arrives at run time is never prepared" {
    var db = FakeDb.init(testing.allocator, "postgres://test/test", .{});
    defer db.deinit();
    db.wire = .{ .answers = 1 };

    var run = nilo.Run.init(testing.allocator);
    defer run.deinit();

    // `db.raw` is the one call this module did not write the text for, so
    // there is no comptime name to derive and no bound on how many there
    // would be. A cache that grew with traffic is the thing ADR 0057 says
    // this design avoids, and this is where that claim is held.
    _ = try db.raw(Person, &run, "SELECT * FROM people WHERE id = $1", .{@as(i64, 7)});
    try testing.expectEqual(@as(?[]const u8, null), db.wire.?.last_plan);
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

test "a uuid column is written and read back on the SQLite Wire" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:uuid-round-trip?mode=memory&cache=shared",
        .{ .size = 2 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io());

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
    try db.nilo_start(threaded.io());

    var run: nilo.Run = .init(testing.allocator);
    defer run.deinit();
    _ = try db.exec(&run, accounts_ddl, .{});

    try testing.expectEqual(@as(usize, 0), try db.checkSchema(&.{SqliteAccount}));
}

test "db.exec answers with the rows it changed and needs no Row to do it" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db: SqliteDb = .init(
        testing.allocator,
        "file:exec-counts?mode=memory&cache=shared",
        .{ .size = 1 },
    );
    defer db.deinit();
    try db.nilo_start(threaded.io());

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
