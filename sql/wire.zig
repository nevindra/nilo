//! The half that speaks to the database — the entire contract this module
//! asks of a driver, listed here the way `bulkhead.zig` lists the Engine's
//! (ADR 0039).
//!
//! **This is not a Bulkhead, and the difference is worth stating.** The
//! Bulkhead is a wall: user code never names zio, and exactly one file does.
//! Here user code *does* name the driver — to build the pool, and for
//! everything outside this module's scope, `LISTEN`/`NOTIFY` and `COPY` among
//! it. Calling this a Bulkhead would promise a guarantee it does not make. It
//! is a seam inside this module, for this module's own use.
//!
//! What it buys is the thing ADR 0002 bought by fitting its seam before it was
//! needed: pg.zig is a fork maintained by the same person as zio, which is
//! already the project's first standing risk. If it stops, one file is
//! rewritten rather than every call site.
//!
//! ## What a Wire owes
//!
//! - `open(io, gpa, url, opts)` / `close()` — build a pool that dials
//!   through the given event loop, and take it down. The `std.Io` is the
//!   whole reason a `Db` is built in two halves: it does not exist until
//!   `listen()` has started the loop (ADR 0040).
//! - `run(arena, sql, values)` — a statement and its parameters, in
//!   placeholder order, giving back something rows can be pulled from one
//!   at a time. The arena is the request's, and is where the driver reads
//!   into when a row does not fit its own buffer — so a big row costs the
//!   request arena rather than the general allocator, and is freed by the
//!   reset that ends the request (ADR 0004).
//! - `next(rows)` — advance to the next row, or false at the end. **The
//!   text in a row is valid only until the next call.** That is not a rule
//!   invented here; it is pg.zig's own, and passing it along unwrapped is
//!   deliberate. A `Str` handed out of this path would hide it behind a
//!   type whose entire meaning is that holding it is safe.
//! - `read(rows, T, col)` — one column of the row `next` stopped on, by
//!   position. By position and not by name because the caller wrote the
//!   `SELECT` list itself and therefore already knows the order at compile
//!   time; a name lookup would be paying at run time for something that
//!   stopped being a question while compiling (ADR 0039).
//! - `readList(rows, T, col, arena)` — one column that holds an array, as a
//!   `[]T` in the arena. **The one read that takes an allocator**, and it has
//!   to: an array arrives as a length and a run of length-prefixed elements,
//!   so there is no slice of `T` in the buffer to point at the way there is a
//!   run of bytes for text. One allocation per array column per row, which is
//!   why a Row that reads one cannot be streamed.
//! - `drain(rows)` — throw away what is left. Not optional: pg.zig's pool
//!   checks that a connection is idle on release and, finding it is not,
//!   destroys the connection and dials a new one. Leaving rows unread is
//!   therefore a correctness-safe, expensive mistake, and it is this module's
//!   job not to make it.
//! - `exec(arena, sql, values)` — a statement that answers with a count
//!   rather than with rows, giving the count back. "Did that update
//!   anything" has no other answer, and Postgres sends the number in
//!   `CommandComplete` rather than as a result set.
//! - `begin(arena)` — a transaction, **holding one connection for its whole
//!   life**. That is not a detail: every statement in a transaction has to
//!   go down the same connection, and a Wire whose `run` takes a fresh one
//!   each time would silently run half a transaction somewhere else. So a
//!   transaction is its own type with its own `run`, rather than a mode the
//!   Wire is in.
//! - `Tx.commit` / `Tx.rollback` — and `rollback` has to be reachable from a
//!   `defer`, because that is how it will be called.
//! - `Tx.deadline(ms)` — bound how long the statements after it may run,
//!   for as long as this transaction lasts. **On the Tx rather than on the
//!   Wire, and that is the design rather than a limitation** (ADR 0047): a
//!   deadline has to be set on the same connection the statement will travel
//!   down, and holding one connection across two statements is the whole of
//!   what a transaction is. A Wire whose `run` takes a fresh connection each
//!   time has nowhere to put one.
//!
//! ## The rule all three of those are instances of
//!
//! > **Whatever the handler did, the connection goes back usable.**
//!
//! A request body left half-read is finished off by nilo so the connection
//! stays usable. A result set left half-read is drained. A transaction left
//! open is rolled back. The same sentence, three times, and it was already
//! true twice before this module existed.
//!
//! The third is the dangerous one and the reason is a fact rather than a
//! guess. `pg.Pool.release` reads:
//!
//! ```zig
//! if (conn._state != .idle) {
//!     lib.metrics.poolDirty();
//!     conn.deinit();
//!     ...
//! }
//! ```
//!
//! It issues no `ROLLBACK` and no `DISCARD ALL`. `_state` tracks the protocol
//! — whether a query is in flight — and an open transaction is server-side
//! state that leaves the protocol idle. So a connection released mid
//! transaction most likely passes that check and goes back into the pool
//! **inside a transaction**, where the next request to take it runs inside a
//! stranger's. Unread rows are caught; an open transaction is not.
//!
//! That is an inference about `_state`'s meaning rather than something the
//! documentation says, and it is the assumption this module is built on
//! because it is the only safe one: `Tx` rolls back on every path out,
//! including the ones nobody wrote.

const std = @import("std");

/// What a Wire may fail with. Deliberately short: this module turns these
/// into errors a handler can read, and a long list here would be a long list
/// there (ADR 0039).
pub const Error = error{
    /// A unique constraint was violated. The one error given a default answer
    /// — 409 — because it is the one whose meaning does not change with the
    /// request around it.
    AlreadyExists,
    /// A foreign key, check or not-null constraint was violated. No default:
    /// all three usually mean the code is wrong rather than the client.
    ConstraintViolated,
    /// The connection went away, or was never there.
    Disconnected,
    /// A statement ran past the deadline the caller set with `tx.deadline`
    /// and the database cancelled it. Separate from `QueryFailed` because a
    /// deadline nobody can tell fired is half a feature: the handler that set
    /// the number is the one that knows what to do about it — shed the
    /// request, answer from a cache, try a narrower query.
    ///
    /// No default status, deliberately. A deadline means something different
    /// every time it is set: a 504 for a report, a 503 for a health check, a
    /// 200 with less in it for a page that has a fallback.
    TimedOut,
    /// The database said no in a way this module does not translate. The text
    /// is logged; it does not reach the client (ADR 0025).
    QueryFailed,
};

/// What opening a pool takes, declared here rather than by any one driver
/// — the same reason `bulkhead.Options` is declared by the Bulkhead and not
/// by zio. Swapping the driver must not change what a caller writes.
pub const OpenOpts = struct {
    size: u16 = 10,
    /// How many connections to dial while opening. Zero means the pool is
    /// created without reaching the database at all, which is what lets a
    /// server boot with Postgres switched off (ADR 0039).
    connect_on_init: u16 = 0,
    timeout_ms: u32 = 10 * std.time.ms_per_s,
};

/// One column as the database describes it, for the schema comparison. Read
/// through the Dialect's `introspect` query, which is why the field names are
/// that query's column names rather than anything invented here.
pub const Column = struct {
    name: []const u8,
    /// `int4`, `text`, `timestamptz` — the names somebody writing a migration
    /// typed, rather than `data_type`'s `character varying`.
    udt: []const u8,
    nullable: bool,
};

/// Whether a type carries what this module asks of a Wire. Checked where the
/// Wire is handed over rather than at the first call that needs a missing
/// piece — the same reason `service.zig` checks the registry at `listen()`.
pub fn assertWire(comptime W: type) void {
    comptime {
        const owed = [_][]const u8{
            "open", "close",     "run",   "exec",
            "next", "read",      "drain", "begin",
            "Tx",   "columnsOf", "readList",
        };
        for (owed) |decl| {
            if (!@hasDecl(W, decl)) @compileError(
                "nilo: " ++ @typeName(W) ++ " is being used as a Wire and has no `" ++
                    decl ++ "`.\n" ++
                    "  What a Wire owes is listed at the top of `sql/wire.zig`.",
            );
        }
    }
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

/// A Wire that answers from a list written into the test. It exists to prove
/// the contract is a contract — that something other than pg.zig can satisfy
/// it — and it is what the schema tests compare against.
pub const Fake = struct {
    columns: []const Column = &.{},
    /// The statement the last `run` was given, so a test can assert on the
    /// SQL that actually reached the database rather than on the constant
    /// the comptime half produced.
    last_sql: []const u8 = "",
    /// How many rows the next `run` hands back. Every one of them reads the
    /// same way — this exists to drive the filling code, not to stand in
    /// for a database.
    answers: usize = 0,
    /// What every text column answers with. A field rather than a literal
    /// because a column whose bytes have to *mean* something — an enum's tag
    /// name — cannot be tested against a fixed `"fake"`, which is exactly the
    /// value such a column must refuse.
    text: []const u8 = "fake",
    began: usize = 0,
    committed: usize = 0,
    rolled_back: usize = 0,
    /// The last deadline a transaction asked for, or null if none did.
    deadline_ms: ?u32 = null,

    pub const Rows = struct {
        left: usize = 0,
        drained: bool = false,
    };

    pub fn open(io: std.Io, gpa: std.mem.Allocator, url: []const u8, opts: OpenOpts) !Fake {
        _ = io;
        _ = gpa;
        _ = url;
        _ = opts;
        return .{};
    }

    pub fn close(self: *Fake) void {
        _ = self;
    }

    pub fn run(self: *Fake, arena: std.mem.Allocator, sql: []const u8, values: anytype) Error!Rows {
        _ = arena;
        _ = values;
        self.last_sql = sql;
        return .{ .left = self.answers };
    }

    pub fn next(self: *Fake, rows: *Rows) Error!bool {
        _ = self;
        if (rows.left == 0) return false;
        rows.left -= 1;
        return true;
    }

    /// A value of the right type, and nothing more. Text points at a
    /// literal in the binary rather than at a read buffer, which is the one
    /// way this is not like a real Wire — the borrow it is standing in for
    /// is exactly what `db.zig` copies away, so the copy is exercised even
    /// though there is nothing here that would dangle without it.
    pub fn read(self: *Fake, rows: *const Rows, comptime T: type, col: usize) Error!T {
        _ = rows;
        _ = col;
        if (T == []const u8 or T == ?[]const u8) return self.text;
        return switch (@typeInfo(T)) {
            .int, .float => 0,
            .bool => false,
            .optional => null,
            else => error.QueryFailed,
        };
    }

    /// Two of whatever the column holds, in the arena. Two rather than one
    /// because a list is the first column that can be empty, single or many,
    /// and a length of one hides an off-by-one in the code that fills it.
    ///
    /// The elements come from `read`, so a Fake has exactly one answer per
    /// type whether it is asked for a column or for a column's contents.
    pub fn readList(
        self: *Fake,
        rows: *const Rows,
        comptime L: type,
        col: usize,
        arena: std.mem.Allocator,
    ) Error!L {
        const Slice = switch (@typeInfo(L)) {
            .optional => |o| o.child,
            else => L,
        };
        const Item = @typeInfo(Slice).pointer.child;
        const out = arena.alloc(Item, 2) catch return error.QueryFailed;
        for (out) |*item| item.* = try self.read(rows, Item, col);
        return out;
    }

    pub fn drain(self: *Fake, rows: *Rows) void {
        _ = self;
        rows.left = 0;
        rows.drained = true;
    }

    pub fn exec(self: *Fake, arena: std.mem.Allocator, sql: []const u8, values: anytype) Error!usize {
        _ = arena;
        _ = values;
        self.last_sql = sql;
        return self.answers;
    }

    pub const Tx = struct {
        wire: *Fake,

        pub fn run(
            self: *Tx,
            arena: std.mem.Allocator,
            sql: []const u8,
            values: anytype,
        ) Error!Rows {
            return self.wire.run(arena, sql, values);
        }

        pub fn exec(
            self: *Tx,
            arena: std.mem.Allocator,
            sql: []const u8,
            values: anytype,
        ) Error!usize {
            return self.wire.exec(arena, sql, values);
        }

        /// The number rather than the statement it becomes. What the SQL
        /// looks like is `postgres.zig`'s business and is pinned against a
        /// real Postgres in `live.zig`; what a Fake can say is whether the
        /// call arrived and with what.
        pub fn deadline(self: *Tx, ms: u32) Error!void {
            self.wire.deadline_ms = ms;
        }

        pub fn commit(self: *Tx) Error!void {
            self.wire.committed += 1;
        }

        pub fn rollback(self: *Tx) void {
            self.wire.rolled_back += 1;
        }
    };

    pub fn begin(self: *Fake, arena: std.mem.Allocator) Error!Tx {
        _ = arena;
        self.began += 1;
        return .{ .wire = self };
    }

    pub fn columnsOf(
        self: *Fake,
        arena: std.mem.Allocator,
        query: []const u8,
        schema: ?[]const u8,
        table: []const u8,
    ) Error![]const Column {
        _ = arena;
        _ = query;
        _ = schema;
        _ = table;
        return self.columns;
    }
};

test "the fake satisfies the contract, which is what makes it a contract" {
    comptime assertWire(Fake);
}

test "a result set left unread is drained rather than abandoned" {
    var wire = Fake{};
    var rows = Fake.Rows{ .left = 5 };
    try testing.expect(try wire.next(&rows));

    wire.drain(&rows);
    try testing.expect(rows.drained);
    try testing.expectEqual(@as(usize, 0), rows.left);
}

test "a transaction that is never committed is rolled back" {
    var wire = Fake{};
    var tx = try wire.begin(testing.allocator);
    tx.rollback();

    try testing.expectEqual(@as(usize, 1), wire.began);
    try testing.expectEqual(@as(usize, 0), wire.committed);
    try testing.expectEqual(@as(usize, 1), wire.rolled_back);
}
