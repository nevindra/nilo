//! A children entry's `.where` through a reference. An aggregate's `.where`
//! may follow one, because the table it reaches is joined into the grouped
//! statement once; a children list's condition is on the children's own
//! columns, and one reaching further belongs in a Row of its own or in
//! `db.raw`.

const sql = @import("nilo_sql");

const State = struct {
    pub const nilo_table = .{ .name = "work_item_states", .key = .id };

    id: i64,
    category: []const u8,
};

const Epic = struct {
    pub const nilo_table = .{ .name = "work_epics", .key = .id };

    id: i64,
    title: []const u8,
};

const Item = struct {
    pub const nilo_table = .{
        .name = "work_items",
        .key = .id,
        .references = .{ .epic_id = .{ Epic, .id }, .state_id = .{ State, .id } },
    };

    id: i64,
    epic_id: i64,
    state_id: i64,
};

const ItemBrief = struct {
    pub const nilo_table = Item;

    id: i64,
};

const EpicCard = struct {
    pub const nilo_table = Epic;
    pub const nilo_children = .{ .items = .{ .where = .{ .state_id = .{ .category = "done" } } } };

    id: i64,
    items: []const ItemBrief,
};

export fn refusal() void {
    _ = sql.childrenFor(EpicCard, "items");
}
