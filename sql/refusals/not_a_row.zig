//! A plain struct handed to a query. It has the right fields, but nothing on
//! it says which table they came from, and a table name is written rather
//! than guessed from the type.

const sql = @import("zfast_sql");

const User = struct {
    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.selectFor(User, @TypeOf(.{}));
    _ = found;
}
