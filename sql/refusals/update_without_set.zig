//! An update that changes nothing. It is a statement the database would
//! happily refuse to parse, caught one layer earlier and in nilo's words.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    age: i32,
};

export fn refusal() void {
    const found = sql.updateFor(User, @TypeOf(.{ .where = .{ .id = 1 } }));
    _ = found;
}
