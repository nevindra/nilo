//! Half of the A/B [ADR 0073](../../docs/adr/0073-a-file-has-no-socket-to-wait-on.md)
//! owes: **what does a program that imports `nilo_sql` and never names SQLite
//! pay for SQLite being in the module?**
//!
//! Both Wires live in one module, so both drivers are fetched and the module
//! links libc whichever one a program uses. What must *not* happen is the
//! megabyte of C being linked in as well — `sql/sqlite.zig` is only analysed
//! when something names it, so a program that does not should carry none of
//! it.
//!
//! That is a claim about the linker rather than about Zig's semantics, which
//! is why it is measured rather than asserted. This file names `sql.Db` and
//! nothing else; [`sqlite_only.zig`](./sqlite_only.zig) is identical except
//! for the one line that names `sql.Sqlite`.
//!
//!     zig build size-sql -Doptimize=ReleaseFast
//!
//! Neither program is meant to be run. They are compiled, stripped and
//! weighed.

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

fn show(db: *sql.Db, c: *nilo.Ctx, id: i64) !?User {
    return db.find(User, c, id);
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var db = sql.Db.init(gpa, "postgres://localhost/app", .{});
    defer db.deinit();

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.provide(&db);
    try app.get("/users/:id", show);
    try app.listen(.{ .port = 8080 });
}
