//! A Row with a Json column, handed to `stream`. A borrowed row allocates
//! nothing — that is the whole of what `stream` sells, and it is what makes a
//! million-row export run flat — and parsing a document costs one allocation
//! per row, into an arena that is not reset until the request ends. So the
//! one call with a bounded memory promise would become the one that grows
//! without limit, and it is refused rather than quietly paid for.

const sql = @import("nilo_sql");

const Theme = struct { theme: []const u8 };

const Account = struct {
    pub const nilo_table = .{ .name = "accounts", .key = .id };

    id: i64,
    settings: sql.Json(Theme),
};

export fn refusal() void {
    const Rows = sql.Db.Streamed(Account);
    _ = Rows;
}
