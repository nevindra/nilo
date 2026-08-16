//! A condition given an optional. `.handle = null` written as a literal is
//! `IS NULL`, because the compiler can see the null; an optional that might
//! be null cannot be read the same way, because whether the statement says
//! `= $1` or `IS NULL` would then depend on a value that only exists at run
//! time — and the statement is a constant by then (ADR 0039).
//!
//! Sending `= $1` with NULL in it is legal SQL and never true, so the query
//! runs, matches nothing and reports no error. The same failure
//! `compared_with_null` refuses, reached by the other road.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    handle: ?[]const u8,
};

export fn refusal() void {
    var maybe: ?[]const u8 = null;
    _ = &maybe;
    const found = sql.selectFor(User, @TypeOf(.{ .where = .{ .handle = maybe } }));
    _ = found;
}
