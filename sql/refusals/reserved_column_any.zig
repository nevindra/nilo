//! A Row with a column called `any`. Inside a condition that word already
//! means OR, and one word cannot be both — a condition naming this column
//! would be read as a list of alternatives.

const sql = @import("zfast_sql");

const Answer = struct {
    pub const zfast_table = .{ .name = "answers", .key = .id };

    id: i64,
    any: bool,
};

export fn refusal() void {
    const found = sql.selectFor(Answer, @TypeOf(.{ .where = .{ .id = 7 } }));
    _ = found;
}
