//! `sql.Replays` handed a type that is not a `nilo_sql` Db. It calls `exec`,
//! `insertOrUpdate`, `select` and `delete` on it, and a type with no
//! `Dialect` has none of them
//! ([ADR 268](../docs/adr/268-an-answer-kept-for-a-retry-is-a-row-when-instances-share-a-database.md)).

const sql = @import("nilo_sql");

const Replays = sql.Replays(u32, .{ .name = "orders" });

export fn refusal() void {
    var r: Replays = undefined;
    _ = &r;
}
