//! A `.lock` on a read with no transaction around it. The statement is legal
//! SQL and that is the problem: Postgres wraps a lone statement in a
//! transaction of its own and ends it immediately, so the lock is taken and
//! dropped before the handler reads a row. Nothing fails, nothing is logged,
//! and the read-modify-write races anyway.

const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    var db: sql.Db = undefined;
    var run: nilo.Run = undefined;
    _ = db.select(User, &run, .{ .where = .{ .id = 1 }, .lock = .update }) catch {};
}
