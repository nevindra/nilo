//! The Wire, filled in with pg.zig. **The only file in this module allowed
//! to name pg.zig** — the same rule `src/engine/zio.zig` lives under, for
//! the same reason (ADR 0002, ADR 0039).
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
//! arena was not already going to do (ADR 0004).
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
//! ## What is deliberately not here
//!
//! `LISTEN`/`NOTIFY`, `COPY`, and prepared-statement caching. The first two
//! are outside this module's scope and reached by naming pg.zig directly,
//! which `wire.zig` says is allowed and is why this seam is not called a
//! Bulkhead. The third is a measurement nobody has taken yet.

const std = @import("std");
const pg = @import("pg");

const wire = @import("wire.zig");

/// A pool of connections, behind the contract in `wire.zig`.
pub const Wire = struct {
    pool: *pg.Pool,

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

        /// Give the connection back, whatever happened. Named rather than
        /// deferred inside `run` because the caller's loop outlives that
        /// call — `db.zig` defers this.
        pub fn close(self: *Rows) void {
            self.result.deinit();
            if (self.owns_conn) self.conn.release();
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
        fn fresh(self: *Tx) void {
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
        /// `conn.err` is set only by an ErrorResponse, and `fresh` empties it
        /// at the start of every statement — so a set `err` here means *this*
        /// statement got a reply and the socket is alive. A transport failure
        /// leaves it null and this does nothing, which is the case where
        /// destroying the connection is right.
        ///
        /// Delete this when pg.zig tells an aborted transaction apart from a
        /// broken connection. It is the only place in nilo that reads
        /// `_state`, and `postgres.zig` is the one file allowed to (ADR 0039).
        fn revive(self: *Tx) void {
            if (self.conn.err == null) return;
            if (self.conn._state != .fail) return;
            self.conn._state = .transaction;
        }

        pub fn run(
            self: *Tx,
            arena: std.mem.Allocator,
            sql: []const u8,
            values: anytype,
        ) wire.Error!Rows {
            if (self.done) return error.QueryFailed;
            self.fresh();
            const result = self.conn.queryOpts(sql, values, .{ .allocator = arena }) catch |err| {
                return translate(self.conn, err);
            };
            return .{ .conn = self.conn, .result = result, .owns_conn = false };
        }

        pub fn exec(
            self: *Tx,
            arena: std.mem.Allocator,
            sql: []const u8,
            values: anytype,
        ) wire.Error!usize {
            if (self.done) return error.QueryFailed;
            self.fresh();
            const count = self.conn.execOpts(sql, values, .{ .allocator = arena }) catch |err| {
                return translate(self.conn, err);
            };
            return @intCast(count orelse 0);
        }

        /// `SET LOCAL statement_timeout`, which Postgres undoes at the end of
        /// this transaction whichever way it ends. One round trip, and it is
        /// the caller who asked for it.
        ///
        /// **The statement is built rather than a constant, and that does not
        /// move ADR 0039's line.** The rule is about the shape of a query
        /// being settled while compiling; this is a session command with a
        /// `u32` this module printed itself. Nothing a request supplies
        /// reaches it, and there is no `SET` that takes a placeholder — the
        /// parameter form does not exist in Postgres, so a constant was never
        /// on offer.
        pub fn deadline(self: *Tx, ms: u32) wire.Error!void {
            if (self.done) return error.QueryFailed;
            self.fresh();
            var buf: [48]u8 = undefined;
            // `SET LOCAL statement_timeout = N` counts milliseconds, which is
            // the unit the argument is named for.
            const sql = std.fmt.bufPrint(&buf, "SET LOCAL statement_timeout = {d}", .{ms}) catch
                unreachable;
            _ = self.conn.exec(sql, .{}) catch |err| return translate(self.conn, err);
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
        /// `revive` before the undo, and only before the undo. Rolling back
        /// to a savepoint is the one thing a caller does *because* the last
        /// statement failed, so it is the path that finds the connection in
        /// pg.zig's `.fail` — the same state `commit` and `rollback` have to
        /// let it out of, and for the same reason.
        pub fn savepoint(
            self: *Tx,
            arena: std.mem.Allocator,
            comptime op: wire.SavepointOp,
            id: u32,
        ) wire.Error!void {
            _ = arena;
            if (self.done) return error.QueryFailed;
            if (op == .undo) self.revive();
            self.fresh();

            const verb = switch (op) {
                .mark => "SAVEPOINT ",
                .undo => "ROLLBACK TO SAVEPOINT ",
                .keep => "RELEASE SAVEPOINT ",
            };
            // The longest verb, the prefix, and ten digits of a u32.
            var buf: [verb.len + name_prefix.len + 10]u8 = undefined;
            const sql = std.fmt.bufPrint(&buf, verb ++ name_prefix ++ "{d}", .{id}) catch
                unreachable;
            _ = self.conn.exec(sql, .{}) catch |err| return translate(self.conn, err);
        }

        /// What a savepoint is called on the server. Prefixed so that it
        /// cannot collide with one a `tx.raw` put down by hand.
        const name_prefix = "nilo_sp_";

        pub fn commit(self: *Tx) wire.Error!void {
            if (self.done) return;
            self.done = true;
            // Before `fresh`, which is what the discrimination depends on.
            // A COMMIT on an aborted transaction is a ROLLBACK as far as
            // Postgres is concerned, and reaching the server to be told so
            // beats destroying the connection to avoid asking.
            self.revive();
            self.fresh();
            defer self.conn.release();
            _ = self.conn.exec("COMMIT", .{}) catch |err| return translate(self.conn, err);
        }

        /// Cannot fail, because it is called from a `defer` on the way out
        /// of a function that is already failing. A rollback that did not
        /// reach the server leaves a connection this module cannot vouch
        /// for, so that connection is destroyed rather than returned —
        /// which is what `release` does with one that is not idle.
        pub fn rollback(self: *Tx) void {
            if (self.done) return;
            self.done = true;
            // The path this is here for: a statement failed, which is the
            // usual reason anybody rolls back at all.
            self.revive();
            defer self.conn.release();
            _ = self.conn.exec("ROLLBACK", .{}) catch |err| {
                std.log.err(
                    "nilo_sql: a transaction could not be rolled back ({s}). The connection " ++
                        "is being dropped rather than returned to the pool.",
                    .{@errorName(err)},
                );
            };
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
        var conn = self.pool.acquire() catch return error.Disconnected;
        errdefer conn.release();
        _ = conn.exec(comptime beginText(opts), .{}) catch |err| return translate(conn, err);
        return .{ .wire = self, .conn = conn };
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
    /// the first connection is made by the first query. That is what lets a
    /// server start with Postgres switched off, and it is pg.zig's own
    /// option rather than one invented here (`connect_on_init_count`).
    pub fn open(
        io: std.Io,
        gpa: std.mem.Allocator,
        url: []const u8,
        opts: wire.OpenOpts,
    ) !Wire {
        const uri = try std.Uri.parse(url);
        const pool = try pg.Pool.initUri(io, gpa, uri, .{
            .size = opts.size,
            .timeout = opts.timeout_ms,
            .connect_on_init_count = opts.connect_on_init,
        });
        return .{ .pool = pool };
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
    ) wire.Error!Rows {
        var conn = self.pool.acquire() catch return error.Disconnected;
        errdefer conn.release();

        const result = conn.queryOpts(sql, values, .{ .allocator = arena }) catch |err| {
            return translate(conn, err);
        };
        return .{ .conn = conn, .result = result };
    }

    /// The next row, or false when the set is finished. The row itself is
    /// kept on `rows` rather than returned, so that `read` can stay a plain
    /// column index and this file stays the only one naming `pg.Row`.
    pub fn next(self: *Wire, rows: *Rows) wire.Error!bool {
        _ = self;
        rows.current = rows.result.next() catch |err| {
            return translate(rows.conn, err);
        } orelse {
            rows.current = null;
            return false;
        };
        return true;
    }

    /// Column `col` of the row `next` just handed back, as `T`.
    ///
    /// A `[]const u8` here points into the read buffer and dies at the next
    /// `next` — `db.zig` copies it before anybody sees it.
    pub fn read(self: *Wire, rows: *const Rows, comptime T: type, col: usize) wire.Error!T {
        _ = self;
        const row = rows.current orelse return error.QueryFailed;
        return row.get(T, col) catch return error.QueryFailed;
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

        const it = row.iterator(Item, col) catch return error.QueryFailed;
        return it.alloc(arena) catch return error.QueryFailed;
    }

    /// The two array shapes pg.zig asserts on rather than refuses, checked
    /// here so they answer with a 500 for one request instead of taking the
    /// process down (ADR 0008, and the same argument as `db.zig`'s `enumOf`).
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
    fn arrayFits(comptime Item: type, data: []const u8) wire.Error!void {
        if (data.len < 12) return error.QueryFailed;
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
    /// Not optional, and not only good manners: pg.zig's pool checks that a
    /// connection is idle on release, and on finding it is not, destroys it
    /// and dials a new one. A handler that stops reading early is an
    /// ordinary thing to write, so the cost of it must not be a reconnect.
    pub fn drain(self: *Wire, rows: *Rows) void {
        _ = self;
        rows.result.drain() catch {};
        rows.close();
    }

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
    ) wire.Error!usize {
        var conn = self.pool.acquire() catch return error.Disconnected;
        defer conn.release();
        const count = conn.execOpts(sql, values, .{ .allocator = arena }) catch |err| {
            return translate(conn, err);
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
        var rows = try self.run(arena, query, .{ schema, table });
        defer rows.close();

        var found: std.ArrayList(wire.Column) = .empty;
        while (try self.next(&rows)) {
            const name = try self.read(&rows, []const u8, 0);
            const udt = try self.read(&rows, []const u8, 1);
            const is_nullable = try self.read(&rows, []const u8, 2);
            found.append(arena, .{
                .name = arena.dupe(u8, name) catch return error.QueryFailed,
                .udt = arena.dupe(u8, udt) catch return error.QueryFailed,
                .nullable = std.mem.eql(u8, is_nullable, "YES"),
            }) catch return error.QueryFailed;
        }
        return found.toOwnedSlice(arena) catch return error.QueryFailed;
    }
};

/// A pg.zig error, plus whatever the server said about it, as one of the
/// four this module admits to (ADR 0039).
///
/// The mapping is by SQLSTATE rather than by message, because the message
/// is localised and the code is not. Class 23 is "integrity constraint
/// violation" and `23505` is the one worth separating: a unique violation
/// is the client having asked for something that is already there, which is
/// a 409 and not a bug. The rest of class 23 usually means the code is
/// wrong, so it stays undifferentiated on purpose.
/// The connection's error field is read first, because pg.zig puts the
/// server's answer there and hands back a generic error. That is only sound
/// while the field is about the statement that just ran: the pool clears it
/// on `release`, and a transaction clears it itself in `Tx.fresh`, which is
/// where the reasoning is written down.
fn translate(conn: *pg.Conn, err: anyerror) wire.Error {
    if (conn.err) |server| {
        if (std.mem.eql(u8, server.code, "23505")) return error.AlreadyExists;
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
        // The text never reaches the client (ADR 0025); it goes here, where
        // whoever is reading the log is the person who can fix it.
        std.log.err("nilo_sql: {s} [{s}]", .{ server.message, server.code });
        return error.QueryFailed;
    }
    return switch (err) {
        error.ConnectionBusy, error.ConnectionResetByPeer, error.BrokenPipe => error.Disconnected,
        else => error.QueryFailed,
    };
}

/// How many connections the pool has thrown away rather than taken back,
/// out of pg.zig's own `pg_pool_dirty` counter.
///
/// **Test-facing, and it exists because nothing else reveals the number.**
/// `Pool.release` destroys a connection it cannot vouch for and dials a
/// replacement on the spot, so a caller sees the same rows either way and the
/// pool's own `stats()` reads the same too. A test written against behaviour
/// therefore passes whether or not `revive` above is doing anything, which is
/// the shape [ADR 0033](../docs/adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
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
