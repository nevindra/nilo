//! A condition where `db.find` wants a key. `find` takes the value of the
//! column the Row's `.key` names, and every other call in this module takes a
//! struct of options — so writing one here is the mistake habit produces.
//!
//! It cannot be read as a condition quietly, because `find` compiles
//! `WHERE <key> = $1` and there is nowhere for a second condition to go.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.findFor(User, @TypeOf(.{ .where = .{ .id = 1 } }));
    _ = found;
}
