//! `sql.Named("")`. The name is the whole mechanism — it is what makes the
//! type distinct, and an empty one gives back a type that is `sql.Db` in
//! everything but the spelling. Registering both would then be registering
//! the same service twice, which is a different error a long way from here.

const sql = @import("nilo_sql");

const Replica = sql.Named("");

export fn refusal() void {
    var db: Replica = undefined;
    _ = &db;
}
