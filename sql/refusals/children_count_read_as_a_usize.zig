//! A count of children read into a `usize`. Every count nilo reads is an
//! `i64`, the type both databases answer `count(*)` in, and a count is never
//! null: a row with no children has a count of zero.

const sql = @import("nilo_sql");

const Rab = struct {
    pub const nilo_table = .{ .name = "rabs", .key = .id };

    id: i64,
    title: []const u8,
};

const Line = struct {
    pub const nilo_table = .{
        .name = "rab_lines",
        .key = .id,
        .references = .{ .rab_id = .{ Rab, .id } },
    };

    id: i64,
    rab_id: i64,
    position: i32,
};

const LineBrief = struct {
    pub const nilo_table = Line;

    position: i32,
};

const RabCard = struct {
    pub const nilo_table = Rab;
    pub const nilo_children = .{ .line_count = .{ .count = Line } };

    id: i64,
    line_count: usize,
};

export fn refusal() void {
    _ = sql.selectFor(RabCard, @TypeOf(.{}));
}
