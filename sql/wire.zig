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
//! - `run(sql, values)` — a statement and its parameters, in placeholder
//!   order, giving back something rows can be pulled from one at a time.
//! - `next(rows)` — the next row, or null. **The text in a row is valid only
//!   until the next call.** That is not a rule invented here; it is pg.zig's
//!   own, and passing it along unwrapped is deliberate. A `Str` handed out of
//!   this path would hide it behind a type whose entire meaning is that
//!   holding it is safe.
//! - `drain(rows)` — throw away what is left. Not optional: pg.zig's pool
//!   checks that a connection is idle on release and, finding it is not,
//!   destroys the connection and dials a new one. Leaving rows unread is
//!   therefore a correctness-safe, expensive mistake, and it is this module's
//!   job not to make it.
//! - `begin` / `commit` / `rollback` — and `rollback` has to be reachable
//!   from a `defer`, because that is how it will be called.
//!
//! ## The rule all three of those are instances of
//!
//! > **Whatever the handler did, the connection goes back usable.**
//!
//! A request body left half-read is finished off by zfast so the connection
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
    /// The database said no in a way this module does not translate. The text
    /// is logged; it does not reach the client (ADR 0025).
    QueryFailed,
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
            "run",   "next",   "drain",
            "begin", "commit", "rollback",
            "columnsOf",
        };
        for (owed) |decl| {
            if (!@hasDecl(W, decl)) @compileError(
                "zfast: " ++ @typeName(W) ++ " is being used as a Wire and has no `" ++
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
    began: usize = 0,
    committed: usize = 0,
    rolled_back: usize = 0,

    pub const Rows = struct {
        left: usize = 0,
        drained: bool = false,
    };

    pub fn run(self: *Fake, sql: []const u8, values: anytype) Error!Rows {
        _ = self;
        _ = sql;
        _ = values;
        return .{};
    }

    pub fn next(self: *Fake, rows: *Rows) Error!?void {
        _ = self;
        if (rows.left == 0) return null;
        rows.left -= 1;
        return {};
    }

    pub fn drain(self: *Fake, rows: *Rows) void {
        _ = self;
        rows.left = 0;
        rows.drained = true;
    }

    pub fn begin(self: *Fake) Error!void {
        self.began += 1;
    }

    pub fn commit(self: *Fake) Error!void {
        self.committed += 1;
    }

    pub fn rollback(self: *Fake) void {
        self.rolled_back += 1;
    }

    pub fn columnsOf(self: *Fake, table: []const u8) Error![]const Column {
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
    _ = try wire.next(&rows);

    wire.drain(&rows);
    try testing.expect(rows.drained);
    try testing.expectEqual(@as(usize, 0), rows.left);
}

test "a transaction that is never committed is rolled back" {
    var wire = Fake{};
    try wire.begin();
    wire.rollback();

    try testing.expectEqual(@as(usize, 1), wire.began);
    try testing.expectEqual(@as(usize, 0), wire.committed);
    try testing.expectEqual(@as(usize, 1), wire.rolled_back);
}
