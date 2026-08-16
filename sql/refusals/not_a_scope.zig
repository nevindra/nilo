//! A query handed something that is not a Scope (ADR 0041).
//!
//! Every query in this module takes the thing that owns the memory the rows
//! will live in — a `*Ctx` inside a handler, a `*nilo.Run` in a program with
//! no request in it. It is a shape rather than a named type, so the mistake
//! this file makes is the one that shape has to catch: handing over
//! something that owns no memory at all.
//!
//! Without the check the failure is a compile error from inside `db.zig`
//! saying an allocator has no field `arena`, naming a line the caller never
//! wrote.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    age: i32,
};

export fn refusal() void {
    var db = sql.db.Db.init(undefined, "postgres://test/test", .{});
    defer db.deinit();

    // An allocator is not a Scope: it hands out memory and says nothing
    // about how long what is in it lives.
    var gpa: @import("std").mem.Allocator = undefined;
    _ = db.select(User, &gpa, .{ .where = .{ .age = .{ .gt = 18 } } }) catch {};
}
