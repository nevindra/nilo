//! The other half of the A/B. Identical to [`pg_only.zig`](./pg_only.zig)
//! except that the database is a file, so the difference between the two
//! stripped binaries is what SQLite costs a program that uses it — and what
//! `pg_only.zig` proves a program that does not is *not* paying.
//!
//!     zig build size-sql -Doptimize=ReleaseFast
//!
//! `.in_fiber` rather than a hop, because the threading choice must not be
//! what the two binaries differ by: `nilo.blocking` would pull the Engine's
//! thread-pool path into one side of a comparison about SQLite.

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Db = sql.Sqlite(.{ .threading = .in_fiber });

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

fn show(db: *Db, c: *nilo.Ctx, id: i64) !?User {
    return db.find(User, c, id);
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var db = Db.init(gpa, "file:app.db", .{});
    defer db.deinit();

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.provide(&db);
    try app.get("/users/:id", show);
    try app.listen(.{ .port = 8080 });
}
