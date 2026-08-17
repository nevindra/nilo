//! A SQLite Wire built without saying where its statements run.
//!
//! There is no right default. SQLite is a library reading a file in this
//! process, so a statement either holds the executor thread it is on or pays a
//! hop to the Engine's thread pool — and which of those is right depends on
//! the deployment rather than on this repository
//! ([ADR 0073](../../docs/adr/0073-a-file-has-no-socket-to-wait-on.md)).
//!
//! Defaulting it would mean one of the two happening silently, and the two
//! differ in *when the server stops working* rather than in speed.

const sql = @import("nilo_sql");

export fn refusal() void {
    const Wire = sql.sqlite.Wire(.{});
    _ = Wire;
}
