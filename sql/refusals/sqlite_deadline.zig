//! `tx.deadline` on the SQLite dialect.
//!
//! [ADR 0047](../../docs/adr/0047-a-deadline-needs-a-connection-you-hold.md)
//! put a deadline on the `Tx` because it has to be set on the connection the
//! statement will travel down, and on Postgres that is a message to a server.
//! SQLite has no server. The only mechanism is `sqlite3_interrupt`, which
//! aborts whatever *the connection* is running rather than the statement that
//! asked for the deadline
//! ([ADR 0074](../../docs/adr/0074-one-writer-is-not-a-setting-it-is-the-database.md)).
//!
//! A deadline that sometimes kills a neighbouring statement is worse than one
//! that says plainly it is not available here — and what it would have caught
//! is already bounded by `busy_timeout_ms`.

const sql = @import("nilo_sql");

const Wire = sql.sqlite.Wire(.{ .threading = .in_fiber });

export fn refusal() void {
    var tx: Wire.Tx = undefined;
    tx.deadline(2_000) catch {};
}
