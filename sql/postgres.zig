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

        pub fn commit(self: *Tx) wire.Error!void {
            if (self.done) return;
            self.done = true;
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
    pub fn begin(self: *Wire, arena: std.mem.Allocator) wire.Error!Tx {
        _ = arena;
        var conn = self.pool.acquire() catch return error.Disconnected;
        errdefer conn.release();
        _ = conn.exec("BEGIN", .{}) catch |err| return translate(conn, err);
        return .{ .wire = self, .conn = conn };
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
        table: []const u8,
    ) wire.Error![]const wire.Column {
        var rows = try self.run(arena, query, .{table});
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

// -- tests ---------------------------------------------------------------

const testing = std.testing;

test "the postgres wire satisfies the contract" {
    comptime wire.assertWire(Wire);
}
