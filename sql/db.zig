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
//! `select`, `one`, `insert`, `update` and `delete` all take a Row, a Ctx
//! and a struct written where it is used, and all of them settle their
//! statement while compiling. `raw` is the way past that, for the joins and
//! aggregates this module refuses; it fills a Row the same way and gives up
//! the column check and nothing else.

const std = @import("std");
const nilo = @import("nilo");

const dialect = @import("dialect.zig");
const postgres = @import("postgres.zig");
const row_mod = @import("row.zig");
const schema = @import("schema.zig");
const statement = @import("statement.zig");
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
        open_transactions: if (traps_enabled) usize else void = if (traps_enabled) 0 else {},

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
            if (traps_enabled and self.open_transactions != 0) {
                std.debug.panic(
                    "nilo_sql: {d} transaction(s) were begun and never ended. Every `begin` " ++
                        "wants `defer tx.deinit()` on the line after it, or the connection " ++
                        "never goes back to the pool.",
                    .{self.open_transactions},
                );
            }
            if (self.wire) |*w| w.close();
            self.wire = null;
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
        pub fn select(self: *Self, comptime Row: type, c: *nilo.Ctx, options: anytype) ![]Row {
            const stmt = comptime statement.select(D, Row, @TypeOf(options));
            return fill(Row, try self.wireOf(), null, c, stmt.sql, valuesOf(stmt, Row, options));
        }

        /// The first row matching `options`, or null.
        ///
        /// `?Row` is already a 404 in the typed layer (ADR 0024), so a
        /// handler that returns this and nothing else is a whole endpoint.
        pub fn one(self: *Self, comptime Row: type, c: *nilo.Ctx, options: anytype) !?Row {
            const found = try self.select(Row, c, options);
            return if (found.len == 0) null else found[0];
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
            c: *nilo.Ctx,
            options: anytype,
        ) !Streamed(Row) {
            const stmt = comptime statement.select(D, Row, @TypeOf(options));
            const w = try self.wireOf();
            return .{
                .w = w,
                .rows = try w.run(c.arena(), stmt.sql, valuesOf(stmt, Row, options)),
            };
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
            c: *nilo.Ctx,
            sql: []const u8,
            values: anytype,
        ) ![]Row {
            return fill(Row, try self.wireOf(), null, c, sql, values);
        }

        // -- writing ---------------------------------------------------------

        /// Insert one row and give back what the database stored, generated
        /// key and defaults included.
        ///
        /// `values` names a subset of the columns, because the ones the
        /// database fills in are exactly the ones a caller has nothing to
        /// say about. A name that is not a column is a Refusal.
        pub fn insert(self: *Self, comptime Row: type, c: *nilo.Ctx, values: anytype) !Row {
            const stmt = comptime statement.insert(D, Row, @TypeOf(values));
            const back = try fill(Row, try self.wireOf(), null, c, stmt.sql, valuesOf(stmt, Row, values));
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
        pub fn update(self: *Self, comptime Row: type, c: *nilo.Ctx, options: anytype) !usize {
            const stmt = comptime statement.update(D, Row, @TypeOf(options));
            const w = try self.wireOf();
            return w.exec(c.arena(), stmt.sql, valuesOf(stmt, Row, options));
        }

        /// Delete every row matching `options`, and say how many there were.
        pub fn delete(self: *Self, comptime Row: type, c: *nilo.Ctx, options: anytype) !usize {
            const stmt = comptime statement.delete(D, Row, @TypeOf(options));
            const w = try self.wireOf();
            return w.exec(c.arena(), stmt.sql, valuesOf(stmt, Row, options));
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
        pub fn begin(self: *Self, c: *nilo.Ctx) !Tx {
            const w = try self.wireOf();
            const inner = try w.begin(c.arena());
            if (traps_enabled) self.open_transactions += 1;
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
                if (traps_enabled) self.db.open_transactions -= 1;
            }

            pub fn select(self: *Tx, comptime Row: type, c: *nilo.Ctx, options: anytype) ![]Row {
                const stmt = comptime statement.select(D, Row, @TypeOf(options));
                return fill(Row, self.w, &self.inner, c, stmt.sql, valuesOf(stmt, Row, options));
            }

            pub fn one(self: *Tx, comptime Row: type, c: *nilo.Ctx, options: anytype) !?Row {
                const found = try self.select(Row, c, options);
                return if (found.len == 0) null else found[0];
            }

            pub fn insert(self: *Tx, comptime Row: type, c: *nilo.Ctx, values: anytype) !Row {
                const stmt = comptime statement.insert(D, Row, @TypeOf(values));
                const back = try fill(Row, self.w, &self.inner, c, stmt.sql, valuesOf(stmt, Row, values));
                if (back.len == 0) return error.QueryFailed;
                return back[0];
            }

            pub fn update(self: *Tx, comptime Row: type, c: *nilo.Ctx, options: anytype) !usize {
                const stmt = comptime statement.update(D, Row, @TypeOf(options));
                return self.inner.exec(c.arena(), stmt.sql, valuesOf(stmt, Row, options));
            }

            pub fn delete(self: *Tx, comptime Row: type, c: *nilo.Ctx, options: anytype) !usize {
                const stmt = comptime statement.delete(D, Row, @TypeOf(options));
                return self.inner.exec(c.arena(), stmt.sql, valuesOf(stmt, Row, options));
            }

            pub fn raw(
                self: *Tx,
                comptime Row: type,
                c: *nilo.Ctx,
                sql: []const u8,
                values: anytype,
            ) ![]Row {
                return fill(Row, self.w, &self.inner, c, sql, values);
            }
        };

        /// Rows pulled one at a time, each borrowed from the read buffer.
        pub fn Streamed(comptime Row: type) type {
            comptime row_mod.assertRow(Row);
            return struct {
                w: *W,
                rows: W.Rows,

                const Rows = @This();

                /// The next row, or null at the end. **Everything read out
                /// of the row before this returns is invalid afterwards.**
                pub fn next(self: *Rows) !?row_mod.Borrowed(Row) {
                    if (!try self.w.next(&self.rows)) return null;
                    var out: row_mod.Borrowed(Row) = undefined;
                    inline for (comptime row_mod.columnsOf(Row), 0..) |column, i| {
                        const F = comptime row_mod.ColumnType(Row, column);
                        @field(out, column) = try self.w.read(&self.rows, comptime plainOf(F), i);
                    }
                    return out;
                }

                /// Give the connection back. Wanted on every path out,
                /// including the ones that stopped reading early.
                pub fn close(self: *Rows) void {
                    self.w.drain(&self.rows);
                }
            };
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
        fn fill(
            comptime Row: type,
            w: *W,
            tx: ?*W.Tx,
            c: *nilo.Ctx,
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

        /// One column, with the borrow ended if there was one.
        fn readColumn(
            w: *W,
            rows: *const W.Rows,
            comptime F: type,
            comptime col: usize,
            c: *nilo.Ctx,
        ) !F {
            if (F == nilo.Str) {
                const borrowed = try w.read(rows, []const u8, col);
                return c.str(try c.arena().dupe(u8, borrowed));
            }
            if (F == ?nilo.Str) {
                const borrowed = try w.read(rows, ?[]const u8, col);
                return if (borrowed) |b| c.str(try c.arena().dupe(u8, b)) else null;
            }
            if (F == []const u8) {
                return try c.arena().dupe(u8, try w.read(rows, []const u8, col));
            }
            if (F == ?[]const u8) {
                const borrowed = try w.read(rows, ?[]const u8, col);
                return if (borrowed) |b| try c.arena().dupe(u8, b) else null;
            }
            // Everything else is a value rather than a view of a buffer, so
            // there is nothing to outlive.
            return w.read(rows, F, col);
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
        fn valuesOf(comptime stmt: statement.Statement, comptime Row: type, options: anytype) Values(Row, stmt) {
            var out: Values(Row, stmt) = undefined;
            inline for (stmt.paths, 0..) |path, i| {
                out[i] = where_mod.valueAt(options, path);
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
fn Values(comptime Row: type, comptime stmt: statement.Statement) type {
    return comptime blk: {
        var fields: [stmt.paths.len]type = undefined;
        for (stmt.params, 0..) |param, i| {
            if (param.isBound()) {
                // A LIMIT or an OFFSET, which is a count and not a column.
                fields[i] = i64;
                continue;
            }
            const F = plainOf(row_mod.ColumnType(Row, param.column));
            // `.in` is one placeholder holding many values — `= ANY($1)` —
            // so what binds is a list of the column's type rather than one
            // of them.
            fields[i] = if (param.list) []const F else F;
        }
        const frozen = fields;
        break :blk std.meta.Tuple(&frozen);
    };
}

/// A column's declared type with `Str`'s claim taken off it: plain bytes.
///
/// Two callers, and they are the same question asked at both ends.
///
/// **Reading**, in a `stream`: the row is borrowed from the driver's buffer
/// and dies at the next one, so it is not a `Str` and must not be called
/// one. This is `row.Borrowed`, one field at a time.
///
/// **Writing**, in the parameter tuple: a value going *to* the database has
/// no lifetime question at all — it has to survive the call and nothing
/// more. Requiring a `Str` there would mean `.email = "a@b.c"` did not
/// compile, which is the shape everybody writes; `Str` is what text is when
/// it comes *back*, and the same rule the other way round would be
/// ceremony with nothing behind it.
fn plainOf(comptime F: type) type {
    comptime {
        if (F == nilo.Str) return []const u8;
        if (F == ?nilo.Str) return ?[]const u8;
        return F;
    }
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
    const Tuple = Values(User, stmt);
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
    try testing.expectEqual(?[]const u8, @typeInfo(Values(User, read)).@"struct".fields[0].type);

    // Writing: the `?` is the whole point. `.nickname = null` is how a
    // column is set to NULL, and stripping it would leave nothing to write.
    const written = .{ .nickname = @as(?[]const u8, null) };
    const wrote = comptime statement.insert(dialect.Postgres, User, @TypeOf(written));
    try testing.expectEqual(?[]const u8, @typeInfo(Values(User, wrote)).@"struct".fields[0].type);
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
    _ = try db.insert(Person, c, .{ .email = "a@b.c", .age = @as(i32, 1) });
    _ = try db.update(Person, c, .{ .set = .{ .age = @as(i32, 2) }, .where = .{ .id = @as(i64, 1) } });
    _ = try db.delete(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
    _ = try db.raw(Person, c, "SELECT 1", .{});

    // The condition shapes the guide shows and nothing else compiles.
    _ = try db.select(Person, c, .{ .where = .{
        .nickname = @as(?[]const u8, null),
        .id = .{ .ne = null },
        .email = .{ .like = "%@b.c" },
        .age = .{ .in = &[_]i32{ 1, 2, 3 } },
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
    _ = try tx.insert(Person, c, .{ .email = "a@b.c", .age = @as(i32, 1) });
    _ = try tx.update(Person, c, .{ .set = .{ .age = @as(i32, 3) }, .where = .{ .id = @as(i64, 1) } });
    _ = try tx.delete(Person, c, .{ .where = .{ .id = @as(i64, 1) } });
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
