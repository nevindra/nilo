//! A `.limit` on a children field. The children of every row are read by
//! one statement for the whole list, so a limit there would cut the list
//! across parents rather than per parent. What an entry takes is `.order`
//! and `.where`.

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
    pub const nilo_children = .{ .lines = .{ .order = .{ .position = .asc }, .limit = 5 } };

    id: i64,
    lines: []const LineBrief,
};

export fn refusal() void {
    _ = sql.selectFor(RabCard, @TypeOf(.{}));
}
