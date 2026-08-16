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
//! than for a connection. Somebody working on an endpoint that never
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
pub const Db = DbOf(postgres.Wire, dialect.Postgres);

/// Everything above, over any Wire and any Dialect. Generic so that the
/// tests can drive the whole path against `wire.Fake` with no database
/// anywhere — the same reason `App.handleRequest` takes a Reader and a
/// Writer rather than a socket.
pub fn DbOf(comptime W: type, comptime D: type) type {
    comptime wire_mod.assertWire(W);
    comptime dialect.assertDialect(D);

    return struct {
        const Self = @This();

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
            connect_on_init: u16 = 0,
            /// How long a caller waits for a free connection.
            timeout_ms: u32 = 10 * std.time.ms_per_s,
            /// Whether a Row that disagrees with its table stops the server
            /// starting, or only says so in the log. A disagreement is a
            /// 500 waiting to happen, so stopping is the default.
            schema_mismatch_is_fatal: bool = true,
        };

        /// Record what to connect to. Opens nothing — see the header.
        pub fn init(gpa: std.mem.Allocator, url: []const u8, opts: Opts) Self {
            return .{ .gpa = gpa, .url = url, .opts = opts };
        }

        pub fn deinit(self: *Self) void {
            if (traps_enabled) {
                const open = self.heldCount(&self.open_transactions);
                if (open != 0) std.debug.panic(
                    "nilo_sql: {d} transaction(s) were begun and never ended. Every `begin` " ++
                        "wants `defer tx.deinit()` on the line after it, or the connection " ++
                        "never goes back to the pool.",
                    .{open},
                );
                const streaming = self.heldCount(&self.open_streams);
                if (streaming != 0) std.debug.panic(
                    "nilo_sql: {d} result set(s) were opened with `stream` and never closed. " ++
                        "Every `stream` wants `defer rows.close()` on the line after it, or the " ++
                        "connection never goes back to the pool at all — an abandoned " ++
                        "transaction costs one until the request ends, an abandoned result set " ++
                        "costs one for as long as the process runs.",
                    .{streaming},
                );
            }
            if (self.wire) |*w| w.close();
            self.wire = null;
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
                std.log.err(
                    "nilo could not open a connection pool for \"{s}\" ({s}). The URL is the " ++
                        "one thing checked here — a database that is merely not running yet is " ++
                        "fine, and the first request that needs it will say so.",
                    .{ redacted(self.url), @errorName(err) },
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
            const stmt = comptime statement.select(D, Row, @TypeOf(options));
            return fill(Row, stmt.reserve, try self.wireOf(), null, c, stmt.sql, valuesOf(stmt, Row, options));
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
            const stmt = comptime statement.one(D, Row, @TypeOf(options));
            const found = try fill(Row, stmt.reserve, try self.wireOf(), null, c, stmt.sql, valuesOf(stmt, Row, options));
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
            const found = try fill(Row, stmt.reserve, try self.wireOf(), null, c, stmt.sql, valuesOf(stmt, Row, key));
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
            const n = try only(i64, try self.wireOf(), null, c, stmt.sql, valuesOf(stmt, Row, options));
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
            return only(bool, try self.wireOf(), null, c, stmt.sql, valuesOf(stmt, Row, options));
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
            const stmt = comptime statement.select(D, Row, @TypeOf(options));
            const w = try self.wireOf();
            const rows = try w.run(c.arena(), stmt.sql, valuesOf(stmt, Row, options));
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
            return fill(Row, null, try self.wireOf(), null, c, sql, values);
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
            const back = try fill(Row, 1, try self.wireOf(), null, c, stmt.sql, valuesOf(stmt, Row, values));
            // `RETURNING` on a successful insert answers with exactly one
            // row. Reaching here with none would mean the driver and
            // Postgres disagree about what happened, which is not something
            // to paper over with an optional.
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
            return w.exec(c.arena(), stmt.sql, valuesOf(stmt, Row, options));
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
            return fill(Row, stmt.reserve, try self.wireOf(), null, c, stmt.sql, valuesOf(stmt, Row, options));
        }

        /// Delete every row matching `options`, and say how many there were.
        pub fn delete(self: *Self, comptime Row: type, c: anytype, options: anytype) !usize {
            comptime core.checkScope(@TypeOf(c), "db.delete");
            const stmt = comptime statement.delete(D, Row, @TypeOf(options));
            const w = try self.wireOf();
            return w.exec(c.arena(), stmt.sql, valuesOf(stmt, Row, options));
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
            return fill(Row, stmt.reserve, try self.wireOf(), null, c, stmt.sql, valuesOf(stmt, Row, options));
        }

        // -- transactions ----------------------------------------------------

        /// Begin a transaction, held and released the way every other
        /// resource in nilo is:
        ///
        /// ```zig
        /// var tx = try db.begin(c);
        /// defer tx.deinit();       // rolls back unless committed
        /// _ = try tx.insert(Order, c, .{ … });
        /// try tx.commit();
        /// ```
        ///
        /// The closure form — `db.transaction(c, run, args)`, impossible to
        /// get wrong — was rejected for being a second dialect: Zig has no
        /// closures, so it means a struct holding a function and every
        /// capture passed by hand, and `Stream`, `Socket` and `Body` are all
        /// *hold the thing, `defer` the cleanup* (ADR 0039).
        pub fn begin(self: *Self, c: anytype) !Tx {
            comptime core.checkScope(@TypeOf(c), "db.begin");
            const w = try self.wireOf();
            const inner = try w.begin(c.arena());
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

            /// Roll back now rather than on the way out, for a handler that
            /// has decided the answer is no.
            pub fn rollback(self: *Tx) void {
                if (self.finished) return;
                self.inner.rollback();
                self.end();
            }

            fn end(self: *Tx) void {
                self.finished = true;
                if (traps_enabled) self.db.hold(&self.db.open_transactions, .Sub);
            }

            pub fn select(self: *Tx, comptime Row: type, c: anytype, options: anytype) ![]Row {
                comptime core.checkScope(@TypeOf(c), "tx.select");
                const stmt = comptime statement.select(D, Row, @TypeOf(options));
                return fill(Row, stmt.reserve, self.w, &self.inner, c, stmt.sql, valuesOf(stmt, Row, options));
            }

            pub fn one(self: *Tx, comptime Row: type, c: anytype, options: anytype) !?Row {
                comptime core.checkScope(@TypeOf(c), "tx.one");
                const stmt = comptime statement.one(D, Row, @TypeOf(options));
                const found = try fill(Row, stmt.reserve, self.w, &self.inner, c, stmt.sql, valuesOf(stmt, Row, options));
                return if (found.len == 0) null else found[0];
            }

            pub fn find(self: *Tx, comptime Row: type, c: anytype, key: anytype) !?Row {
                comptime core.checkScope(@TypeOf(c), "tx.find");
                const stmt = comptime statement.find(D, Row, @TypeOf(key));
                const found = try fill(Row, stmt.reserve, self.w, &self.inner, c, stmt.sql, valuesOf(stmt, Row, key));
                return if (found.len == 0) null else found[0];
            }

            pub fn count(self: *Tx, comptime Row: type, c: anytype, options: anytype) !usize {
                comptime core.checkScope(@TypeOf(c), "tx.count");
                const stmt = comptime statement.count(D, Row, @TypeOf(options));
                const n = try only(i64, self.w, &self.inner, c, stmt.sql, valuesOf(stmt, Row, options));
                if (n < 0) return error.QueryFailed;
                return @intCast(n);
            }

            pub fn exists(self: *Tx, comptime Row: type, c: anytype, options: anytype) !bool {
                comptime core.checkScope(@TypeOf(c), "tx.exists");
                const stmt = comptime statement.exists(D, Row, @TypeOf(options));
                return only(bool, self.w, &self.inner, c, stmt.sql, valuesOf(stmt, Row, options));
            }

            pub fn insert(self: *Tx, comptime Row: type, c: anytype, values: anytype) !Row {
                comptime core.checkScope(@TypeOf(c), "tx.insert");
                const stmt = comptime statement.insert(D, Row, @TypeOf(values));
                // `RETURNING` on a successful insert answers with exactly one
                // row, so the list is sized for one and never grows.
                const back = try fill(Row, 1, self.w, &self.inner, c, stmt.sql, valuesOf(stmt, Row, values));
                if (back.len == 0) return error.QueryFailed;
                return back[0];
            }

            pub fn update(self: *Tx, comptime Row: type, c: anytype, options: anytype) !usize {
                comptime core.checkScope(@TypeOf(c), "tx.update");
                const stmt = comptime statement.update(D, Row, @TypeOf(options));
                return self.inner.exec(c.arena(), stmt.sql, valuesOf(stmt, Row, options));
            }

            pub fn updateReturning(self: *Tx, comptime Row: type, c: anytype, options: anytype) ![]Row {
                comptime core.checkScope(@TypeOf(c), "tx.updateReturning");
                const stmt = comptime statement.updateReturning(D, Row, @TypeOf(options));
                return fill(Row, stmt.reserve, self.w, &self.inner, c, stmt.sql, valuesOf(stmt, Row, options));
            }

            pub fn delete(self: *Tx, comptime Row: type, c: anytype, options: anytype) !usize {
                comptime core.checkScope(@TypeOf(c), "tx.delete");
                const stmt = comptime statement.delete(D, Row, @TypeOf(options));
                return self.inner.exec(c.arena(), stmt.sql, valuesOf(stmt, Row, options));
            }

            pub fn deleteReturning(self: *Tx, comptime Row: type, c: anytype, options: anytype) ![]Row {
                comptime core.checkScope(@TypeOf(c), "tx.deleteReturning");
                const stmt = comptime statement.deleteReturning(D, Row, @TypeOf(options));
                return fill(Row, stmt.reserve, self.w, &self.inner, c, stmt.sql, valuesOf(stmt, Row, options));
            }

            pub fn raw(
                self: *Tx,
                comptime Row: type,
                c: anytype,
                sql: []const u8,
                values: anytype,
            ) ![]Row {
                comptime core.checkScope(@TypeOf(c), "tx.raw");
                return fill(Row, null, self.w, &self.inner, c, sql, values);
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
            return value;
        }

        // -- the shared middle -----------------------------------------------

        /// The pool, or the error a handler can act on. One place, so that
        /// "the server started but the database was never reachable" reads
        /// the same from every call.
        fn wireOf(self: *Self) !*W {
            if (self.wire) |*w| return w;
            return error.Disconnected;
        }

        /// Run a statement and fill a Row from each result. The one place
        /// the driver's borrowed text is copied into the arena, and the one
        /// place a transaction and a bare pool differ.
        /// Run a statement and fill a Row from each result.
        ///
        /// `reserve` is the statement's own ceiling on how many rows can
        /// arrive — a `LIMIT` that was written out, or the one `db.one`
        /// compiles. When there is one the list is sized once and never
        /// grows; when there is not, it doubles, and each doubling abandons
        /// the buffer before it, because an arena cannot take one back.
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
            comptime reserve: ?usize,
            w: *W,
            tx: ?*W.Tx,
            c: anytype,
            sql: []const u8,
            values: anytype,
        ) ![]Row {
            comptime row_mod.assertRow(Row);
            const arena = c.arena();

            var rows = if (tx) |t|
                try t.run(arena, sql, values)
            else
                try w.run(arena, sql, values);
            // Whatever happens below, the connection goes back usable —
            // including a handler's own error on the way past (`wire.zig`).
            defer w.drain(&rows);

            var out: std.ArrayList(Row) = .empty;
            if (comptime reserve) |ceiling| try out.ensureTotalCapacityPrecise(arena, ceiling);
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
            values: anytype,
        ) !T {
            const arena = c.arena();
            var rows = if (tx) |t|
                try t.run(arena, sql, values)
            else
                try w.run(arena, sql, values);
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
            // Everything else is a value rather than a view of a buffer, so
            // there is nothing to outlive.
            return value;
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
                const actual = try w.columnsOf(arena, D.introspect, comptime row_mod.tableOf(Row));
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
        fn valuesOf(
            comptime stmt: statement.Statement,
            comptime Row: type,
            options: anytype,
        ) Values(Row, @TypeOf(options), stmt) {
            var out: Values(Row, @TypeOf(options), stmt) = undefined;
            inline for (stmt.paths, 0..) |path, i| {
                out[i] = forWire(@TypeOf(out[i]), where_mod.valueAt(options, path));
            }
            return out;
        }
    };
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
fn Values(comptime Row: type, comptime O: type, comptime stmt: statement.Statement) type {
    return comptime blk: {
        var fields: [stmt.paths.len]type = undefined;
        for (stmt.params, 0..) |param, i| {
            if (param.isCount()) {
                fields[i] = where_mod.ValueAt(O, stmt.paths[i]);
                continue;
            }
            const F = WireWrite(row_mod.ColumnType(Row, param.column));
            // `.in` is one placeholder holding many values — `= ANY($1)` —
            // so what binds is a list of the column's type rather than one
            // of them.
            fields[i] = if (param.list) []const F else F;
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
fn WireRead(comptime F: type) type {
    comptime {
        if (F == core.Str) return []const u8;
        if (F == types.Timestamp) return i64;
        if (F == types.Uuid) return []const u8;
        if (types.jsonPayload(F) != null) return []const u8;
        return F;
    }
}

/// Sixteen bytes into a `Uuid`. A column that answered with a different
/// number of them is not a `uuid`, and saying so beats reading past the end
/// of the buffer or quietly keeping a prefix.
fn uuidOf(raw: []const u8) !types.Uuid {
    if (raw.len != types.Uuid.byte_len) return error.QueryFailed;
    return .{ .bytes = raw[0..types.Uuid.byte_len].* };
}

/// A Row is streamable unless it reads a `Json` column.
///
/// A borrowed row costs no allocation — that is the whole of what `stream`
/// sells, and it is what makes a million-row export run flat. Parsing a
/// document needs one per row, into an arena that is not reset until the
/// request ends, so a streamed `Json` column would turn the one call with a
/// bounded memory promise into the one that grows without limit. Refusing is
/// the honest answer; `select` parses them, and a Row that reads the column
/// as `[]const u8` streams it as bytes.
fn assertStreamable(comptime Row: type) void {
    comptime {
        for (@typeInfo(Row).@"struct".fields) |f| {
            const Inner = switch (@typeInfo(f.type)) {
                .optional => |o| o.child,
                else => f.type,
            };
            if (types.jsonPayload(Inner) == null) continue;
            @compileError(
                "nilo: " ++ @typeName(Row) ++ " reads `" ++ f.name ++ "` as a Json column, " ++
                    "and a streamed row cannot hold one.\n" ++
                    "  A borrowed row allocates nothing, which is what makes a million of " ++
                    "them run flat, and parsing a document costs one allocation per row. " ++
                    "Read the column with `select`, or as `[]const u8` in a Row of its own " ++
                    "and parse it where it is needed.",
            );
        }
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
/// A `Uuid` binds as its sixteen bytes **as an array rather than a slice**,
/// and that is load-bearing: the tuple this builds is what the driver reads
/// from, so a slice would have to point at something, and the only thing
/// available to point at is the copy `where.valueAt` just returned. The array
/// travels inside the tuple and outlives the call, which a pointer into a
/// temporary would not.
///
/// A `Json(T)` is handed over whole. The driver writes any struct into a
/// `jsonb` column through `std.json`, which finds the `jsonStringify` on it
/// and writes the `T` inside rather than the wrapper.
fn WireWrite(comptime F: type) type {
    comptime {
        if (F == core.Str) return []const u8;
        if (F == ?core.Str) return ?[]const u8;
        if (F == types.Timestamp) return i64;
        if (F == ?types.Timestamp) return ?i64;
        if (F == types.Uuid) return [types.Uuid.byte_len]u8;
        if (F == ?types.Uuid) return ?[types.Uuid.byte_len]u8;
        return F;
    }
}

/// One value taken apart for the wire. Everything the driver already
/// understands is handed over unchanged and coerced by the assignment; the
/// two types carrying a column shape Zig has no word for are opened here,
/// which is the same conversion `kept` makes coming back.
fn forWire(comptime To: type, value: anytype) To {
    const V = @TypeOf(value);
    if (V == types.Timestamp) return value.micros;
    if (V == ?types.Timestamp) return if (value) |t| t.micros else null;
    if (V == types.Uuid) return value.bytes;
    if (V == ?types.Uuid) return if (value) |u| u.bytes else null;
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
const FakeDb = DbOf(wire_mod.Fake, dialect.Postgres);

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
    const Tuple = Values(User, @TypeOf(options), stmt);
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
    try testing.expectEqual(?[]const u8, @typeInfo(Values(User, @TypeOf(found), read)).@"struct".fields[0].type);

    // Writing: the `?` is the whole point. `.nickname = null` is how a
    // column is set to NULL, and stripping it would leave nothing to write.
    const written = .{ .nickname = @as(?[]const u8, null) };
    const wrote = comptime statement.insert(dialect.Postgres, User, @TypeOf(written));
    try testing.expectEqual(?[]const u8, @typeInfo(Values(User, @TypeOf(written), wrote)).@"struct".fields[0].type);
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
    const fields = @typeInfo(Values(User, @TypeOf(options), stmt)).@"struct".fields;

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
    try testing.expectEqual(i64, WireWrite(types.Timestamp));
    try testing.expectEqual([]const u8, WireRead(types.Uuid));
    try testing.expectEqual([types.Uuid.byte_len]u8, WireWrite(types.Uuid));
    try testing.expectEqual([]const u8, WireRead(types.Json(struct { a: u8 })));

    // And a type the driver already understands is left alone.
    try testing.expectEqual(i32, WireRead(i32));
    try testing.expectEqual(i32, WireWrite(i32));
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
    var tx = try db.begin(c);
    defer tx.deinit();
    // and no commit
}

fn commitTransaction(db: *FakeDb, c: *nilo.Ctx) !void {
    var tx = try db.begin(c);
    defer tx.deinit();
    try tx.commit();
}

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

    var tx = try db.begin(c);
    defer tx.deinit();
    _ = try tx.select(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try tx.one(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try tx.find(Person, c, @as(i64, 1));
    _ = try tx.count(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try tx.exists(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try tx.insert(Person, c, .{ .email = "a@b.c", .age = @as(i32, 1) });
    _ = try tx.update(Person, c, .{ .set = .{ .age = @as(i32, 3) }, .where = .{ .id = @as(i64, 1) } });
    _ = try tx.updateReturning(Person, c, .{ .set = .{ .age = @as(i32, 3) }, .where = .{ .id = @as(i64, 1) } });
    _ = try tx.delete(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try tx.deleteReturning(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try tx.raw(Person, c, "SELECT 1", .{});
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
