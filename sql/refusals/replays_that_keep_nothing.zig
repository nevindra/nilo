//! `sql.Replays` with a `max_bytes` of 0: no answer could be kept in it
//! ([ADR 268](../docs/adr/268-an-answer-kept-for-a-retry-is-a-row-when-instances-share-a-database.md)).

const sql = @import("nilo_sql");

const Db = sql.Sqlite(.{ .threading = .in_fiber });
const Replays = sql.Replays(Db, .{ .name = "orders", .max_bytes = 0 });

export fn refusal() void {
    var r: Replays = undefined;
    _ = &r;
}
