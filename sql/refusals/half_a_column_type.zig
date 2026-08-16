//! A type that can be written to a column and not read back. `nilo_read` and
//! `nilo_write` are a pair: one builds the value out of what Postgres printed
//! and the other gives back the text to send, and a type carrying only the
//! second is a column nothing can select.

const sql = @import("nilo_sql");

const Money = struct {
    cents: i64,

    pub const nilo_column = "money";

    pub fn nilo_write(self: Money, arena: @import("std").mem.Allocator) ![]const u8 {
        _ = self;
        _ = arena;
        return "0";
    }
};

const Sale = struct {
    pub const nilo_table = .{ .name = "sales", .key = .id };

    id: i64,
    amount: Money,
};

export fn refusal() void {
    _ = sql.selectFor(Sale, @TypeOf(.{}));
}
