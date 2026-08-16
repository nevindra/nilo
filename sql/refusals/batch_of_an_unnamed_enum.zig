//! A batch insert naming an enum column that has not said what its Postgres
//! type is called. Nothing on the Zig side can derive it — the type lives in
//! the database — and `unnest($1)` with no cast is *could not determine data
//! type of parameter $1* at run time.

const sql = @import("nilo_sql");

const Role = enum { admin, member };

const Staff = struct {
    pub const nilo_table = .{ .name = "staff", .key = .id };

    id: i64,
    role: Role,
};

const Line = struct { role: Role };

export fn refusal() void {
    _ = sql.insertManyFor(Staff, Line);
}
