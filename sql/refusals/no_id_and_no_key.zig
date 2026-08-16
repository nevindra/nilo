//! No column called `id` and no `.key` either. `id` is the one default the
//! marker allows, because it involves no guessing; a table keyed on anything
//! else has to say so.

const sql = @import("nilo_sql");

const Membership = struct {
    pub const nilo_table = .{ .name = "memberships" };

    user_id: i64,
    plan: []const u8,
};

export fn refusal() void {
    _ = sql.row.keyOf(Membership);
}
