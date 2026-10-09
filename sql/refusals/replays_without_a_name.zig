//! `sql.Replays` with an empty `name`. The name is what keeps one store's keys
//! out of another's in a table they share, so an empty one is two stores
//! reading each other's answers
//! ([ADR 268](../docs/adr/268-an-answer-kept-for-a-retry-is-a-row-when-instances-share-a-database.md)).

const sql = @import("nilo_sql");

const Db = sql.Sqlite(.{ .threading = .in_fiber });
const Replays = sql.Replays(Db, .{ .name = "" });

export fn refusal() void {
    var r: Replays = undefined;
    _ = &r;
}
