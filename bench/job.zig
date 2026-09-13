//! What a claim costs, which is the number `nilo_job`'s `poll_ms` default
//! rests on (ADR 0198).
//!
//! A worker with nothing to do asks the store once per `poll_ms`, so an idle
//! queue costs one claim per worker per interval, forever. This times that
//! claim three ways on each database it can reach:
//!
//! 1. **empty** — the table has no due row, which is what an idle queue asks.
//! 2. **taking** — one thousand due rows, each claim takes one. What a busy
//!    queue pays per job before the job itself runs.
//! 3. **push** — what a handler pays to queue one, for the request path.
//!
//! ```
//! zig build bench-job                                                   # SQLite only
//! DATABASE_URL=postgres://nilo:nilo@localhost:5433/nilo zig build bench-job
//! ```
//!
//! `job.Memory` is in the printout as the floor: what the same three cost
//! with no database at all, so the database's share is visible rather than
//! guessed. Single-threaded, one connection, the way `bench-sql` measures —
//! **a Postgres row crosses a socket and a SQLite row does not**, so the
//! ratio between the two halves is not a race. The numbers and the decision
//! they moved are in `bench/result/job.md`.

const std = @import("std");
const core = @import("nilo_core");
const sql = @import("nilo_sql");
const job = @import("nilo_job");
const live_config = @import("live_config");

const rows = 1_000;
const rounds = 1_000;

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(threaded.io(), &out_buf);
    const w = &out.interface;

    try w.print("nilo_job: what a claim costs, {d} rounds, one connection\n\n", .{rounds});
    try w.print("{s:<12} {s:>12} {s:>12} {s:>12}\n", .{ "store", "empty", "taking", "push" });

    {
        // Room for the thousand taken and the thousand pushed after them.
        var store = try job.Memory.open(gpa, .{ .bytes = 16 << 20 });
        defer store.deinit();
        try measure(w, gpa, "memory", &store);
    }

    {
        const Db = sql.Sqlite(.{ .threading = .in_fiber });
        var db: Db = .init(gpa, "file:nilo-bench-job?mode=memory&cache=shared", .{ .size = 1 });
        defer db.deinit();
        try db.nilo_start(threaded.io(), .off);
        var run: core.Run = .init(gpa);
        defer run.deinit();
        try sql.migrate.createMissing(&db, &run, &.{job.Table(Db).Row});
        var store = job.Table(Db).open(&db);
        try measure(w, gpa, "sqlite", &store);
    }

    if (live_config.database_url) |url| {
        var db: sql.Db = .init(gpa, url, .{ .size = 1, .connect_on_init = 1 });
        defer db.deinit();
        try db.nilo_start(threaded.io(), .off);
        defer db.nilo_stop();
        var run: core.Run = .init(gpa);
        defer run.deinit();
        _ = try db.exec(&run, "DROP TABLE IF EXISTS \"nilo_jobs\"", .{});
        try sql.migrate.createMissing(&db, &run, &.{job.Table(sql.Db).Row});
        var store = job.Table(sql.Db).open(&db);
        try measure(w, gpa, "postgres", &store);
        _ = try db.exec(&run, "DROP TABLE IF EXISTS \"nilo_jobs\"", .{});
    } else {
        try w.print("{s:<12} {s}\n", .{ "postgres", "not reached: set DATABASE_URL" });
    }

    try w.flush();
}

fn measure(w: *std.Io.Writer, gpa: std.mem.Allocator, name: []const u8, store: anytype) !void {
    var run: core.Run = .init(gpa);
    defer run.deinit();

    // Empty: nothing is due. The table may still hold finished rows, which is
    // what an idle production table looks like.
    const empty = try timed(store, &run, .{ .claims = rounds, .now = 1 });

    // Taking: a thousand due rows, and a thousand claims.
    var i: usize = 0;
    while (i < rows) : (i += 1) {
        _ = try store.push(&run, "bench", "{\"n\":1}", .{ .run_at = 10 });
        run.reset();
    }
    const taking = try timed(store, &run, .{ .claims = rounds, .now = 100 });

    // Push: what a handler pays.
    const started = core.monotonicMicros();
    i = 0;
    while (i < rounds) : (i += 1) {
        _ = try store.push(&run, "bench", "{\"n\":1}", .{ .run_at = 1_000_000_000 });
        run.reset();
    }
    const push = @divTrunc(core.monotonicMicros() - started, rounds);

    try w.print("{s:<12} {d:>10}us {d:>10}us {d:>10}us\n", .{
        name, @as(u64, @intCast(empty)), @as(u64, @intCast(taking)), @as(u64, @intCast(push)),
    });
}

fn timed(store: anytype, run: *core.Run, what: struct { claims: usize, now: i64 }) !i64 {
    const started = core.monotonicMicros();
    var i: usize = 0;
    while (i < what.claims) : (i += 1) {
        _ = try store.claim(run, what.now, what.now + 60_000_000);
        run.reset();
    }
    return @divTrunc(core.monotonicMicros() - started, @as(i64, @intCast(what.claims)));
}
