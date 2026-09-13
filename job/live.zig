//! The tests that need a database, and the one place `job/` names `nilo_sql`
//! (ADR 0198). A root of its own rather than a line in `job/job.zig`'s test
//! block, for the reason `fetch/deadline.zig` is one: putting it there would
//! make `zig test job/job.zig` need a driver and cost the Fitting layer its
//! entry condition (ADR 0070).
//!
//! SQLite in memory is always here, so `zig build test-job-sql` needs nothing
//! installed. Postgres runs when `DATABASE_URL` or `-Ddatabase-url=…` says
//! where — the same switch `sql/live.zig` reads — and is where `FOR UPDATE
//! SKIP LOCKED` actually gets exercised. **In Debug only**: the table is named
//! `nilo_jobs` by design, so two optimize modes against one database would
//! create and drop each other's fixture mid-test, which `sql/live.zig` solves
//! with a suffix this Row cannot carry.
//!
//! Also the one place `job/` names `nilo_cache`: the `status` and `.within`
//! Spaces are duck-typed in `job.zig`, and a test with a real Space is what
//! holds that the duck is the right shape.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("nilo_core");
const sql = @import("nilo_sql");
const job = @import("nilo_job");
const cache = @import("nilo_cache");
const live_config = @import("live_config");

const testing = std.testing;

const SqliteDb = sql.Sqlite(.{ .threading = .in_fiber });
const SqliteTable = job.Table(SqliteDb);

/// A row a job writes, so the test can see the job ran through the same Db.
const Note = struct {
    pub const nilo_table = .{ .name = "notes", .key = .id };
    id: i64,
    text: []const u8,
};

const WriteNote = struct {
    pub const nilo_job = "write-note";
    pub const retry: job.Retry = .{ .times = 1, .backoff = .{ .fixed_ms = 0 } };

    text: core.Str,
    fail: bool = false,

    pub fn run(self: WriteNote, scope: *core.Run, db: *SqliteDb) !void {
        if (self.fail) return error.AsAsked;
        _ = try db.insert(Note, scope, .{ .text = self.text.view() });
    }
};

const Statuses = cache.Space("job-status", job.Status, .{ .ttl_s = 60 });
const Window = cache.Space("job-window", job.Mark, .{ .ttl_s = 60 });

const SqliteJobs = job.Jobs(.{
    .kinds = .{WriteNote},
    .store = SqliteTable,
    .deps = struct { db: *SqliteDb },
    .status = Statuses,
});

const Fixture = struct {
    threaded: std.Io.Threaded,
    db: SqliteDb,
    run: core.Run,

    fn open(name: []const u8) !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.threaded = .init(testing.allocator, .{});
        const url = try std.fmt.allocPrint(testing.allocator, "file:{s}?mode=memory&cache=shared", .{name});
        defer testing.allocator.free(url);
        f.db = .init(testing.allocator, url, .{ .size = 2 });
        f.run = .init(testing.allocator);
        try f.db.nilo_start(f.threaded.io(), .off);
        try sql.migrate.createMissing(&f.db, &f.run, &.{ SqliteTable.Row, Note });
        return f;
    }

    fn close(f: *Fixture) void {
        f.run.deinit();
        f.db.deinit();
        f.threaded.deinit();
        testing.allocator.destroy(f);
    }
};

test "on SQLite a row is pushed, claimed once, and finished" {
    const f = try Fixture.open("job-claim");
    defer f.close();
    var table = SqliteTable.open(&f.db);

    const id = (try table.push(&f.run, "write-note", "{\"text\":\"a\"}", .{ .run_at = 100 })).?;
    try testing.expect((try table.claim(&f.run, 50, 1_000)) == null);

    const claimed = (try table.claim(&f.run, 150, 1_000)).?;
    try testing.expectEqual(id, claimed.id);
    try testing.expectEqualStrings("write-note", claimed.kind);
    try testing.expectEqualStrings("{\"text\":\"a\"}", claimed.payload);
    try testing.expectEqual(@as(u32, 1), claimed.attempts);
    // Running, and leased: not claimable again until the lease is over.
    try testing.expect((try table.claim(&f.run, 150, 1_000)) == null);
    try testing.expectEqual(@as(u64, 1), (try table.stats(&f.run)).running);
    const again = (try table.claim(&f.run, 1_001, 2_000)).?;
    try testing.expectEqual(@as(u32, 2), again.attempts);

    try table.done(&f.run, id);
    const s = try table.stats(&f.run);
    try testing.expectEqual(@as(u64, 0), s.queued + s.running + s.dead);
}

test "on SQLite a unique key is the index, and is free again once the row is finished" {
    const f = try Fixture.open("job-unique");
    defer f.close();
    var table = SqliteTable.open(&f.db);

    const first = try table.push(&f.run, "write-note", "{}", .{ .run_at = 0, .unique = "u1" });
    try testing.expect(first != null);
    try testing.expect((try table.push(&f.run, "write-note", "{}", .{ .run_at = 0, .unique = "u1" })) == null);
    try testing.expect((try table.push(&f.run, "other", "{}", .{ .run_at = 0, .unique = "u1" })) != null);

    const claimed = (try table.claim(&f.run, 1, 100)).?;
    try testing.expect((try table.push(&f.run, "write-note", "{}", .{ .run_at = 0, .unique = "u1" })) == null);
    try table.dead(&f.run, claimed.id, "Gone");
    try testing.expect((try table.push(&f.run, "write-note", "{}", .{ .run_at = 0, .unique = "u1" })) != null);

    const listed = try table.deadOnes(&f.run);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqualStrings("Gone", listed[0].err);
    try testing.expect(try table.retryDead(&f.run, claimed.id, 5));
    try testing.expect(!(try table.retryDead(&f.run, claimed.id, 5)));
}

test "on SQLite pushIn commits with the transaction and rolls back with it" {
    const f = try Fixture.open("job-tx");
    defer f.close();
    var table = SqliteTable.open(&f.db);

    {
        var tx = try f.db.begin(&f.run, .{});
        defer tx.deinit();
        _ = try tx.insert(Note, &f.run, .{ .text = "with a job" });
        _ = try table.pushIn(&tx, &f.run, "write-note", "{}", .{ .run_at = 0 });
        // No commit: both go.
    }
    try testing.expectEqual(@as(u64, 0), (try table.stats(&f.run)).queued);
    try testing.expectEqual(@as(usize, 0), try f.db.count(Note, &f.run, .{}));

    {
        var tx = try f.db.begin(&f.run, .{});
        defer tx.deinit();
        _ = try tx.insert(Note, &f.run, .{ .text = "with a job" });
        _ = try table.pushIn(&tx, &f.run, "write-note", "{}", .{ .run_at = 0 });
        try tx.commit();
    }
    try testing.expectEqual(@as(u64, 1), (try table.stats(&f.run)).queued);
    try testing.expectEqual(@as(usize, 1), try f.db.count(Note, &f.run, .{}));
}

test "a Jobs over a SQLite table runs a job that writes through the same Db, and keeps a status" {
    const f = try Fixture.open("job-e2e");
    defer f.close();
    var table = SqliteTable.open(&f.db);

    var store = try cache.open(testing.allocator, .{ .bytes = 1 << 20 });
    defer store.deinit();
    var jobs: SqliteJobs = .openWith(testing.allocator, &table, .{ .db = &f.db }, .{}, Statuses.open(&store));

    const text = f.run.str(try f.run.arena().dupe(u8, "from a job"));
    const id = try jobs.push(&f.run, WriteNote{ .text = text }, .{});
    try testing.expectEqual(job.State.queued, jobs.status(id).?.state);

    try testing.expectEqual(@as(usize, 1), try jobs.drain(&f.run));
    const notes = try f.db.select(Note, &f.run, .{});
    try testing.expectEqual(@as(usize, 1), notes.len);
    try testing.expectEqualStrings("from a job", notes[0].text);
    try testing.expectEqual(job.State.done, jobs.status(id).?.state);
    try testing.expectEqual(@as(u32, 1), jobs.status(id).?.attempts);

    // One that fails twice is dead, and the status says so.
    const doomed = try jobs.push(&f.run, WriteNote{ .text = .static("x"), .fail = true }, .{});
    try testing.expectEqual(@as(usize, 2), try jobs.drain(&f.run));
    try testing.expectEqual(job.State.dead, jobs.status(doomed).?.state);
    try testing.expectEqual(@as(u32, 2), jobs.status(doomed).?.attempts);
    try testing.expectEqual(@as(u64, 1), (try jobs.stats(&f.run)).dead);

    // A window in front of a unique key: the second push inside it is
    // answered by the cache and never reaches the table.
    const window = Window.open(&store);
    const a = try jobs.push(&f.run, WriteNote{ .text = .static("w") }, .{ .unique = "note:w", .within = window });
    try testing.expect(a != null);
    const b = try jobs.push(&f.run, WriteNote{ .text = .static("w") }, .{ .unique = "note:w", .within = window });
    try testing.expect(b == null);
    try testing.expectEqual(@as(u64, 1), (try jobs.stats(&f.run)).queued);

    // And `pushIn` through the Jobs, with the kind checked.
    {
        var tx = try f.db.begin(&f.run, .{});
        defer tx.deinit();
        _ = try jobs.pushIn(&tx, &f.run, WriteNote{ .text = .static("tx") }, .{});
        try tx.commit();
    }
    try testing.expectEqual(@as(u64, 2), (try jobs.stats(&f.run)).queued);
}

// -- Postgres ---------------------------------------------------------------

const PgTable = job.Table(sql.Db);

const Pg = struct {
    threaded: std.Io.Threaded,
    db: sql.Db,
    run: core.Run,

    /// Null when there is no Postgres to reach, or this is not the Debug
    /// build — see the header.
    fn open() !?*Pg {
        const url = live_config.database_url orelse return null;
        if (builtin.mode != .Debug) return null;
        const p = try testing.allocator.create(Pg);
        errdefer testing.allocator.destroy(p);
        p.threaded = .init(testing.allocator, .{});
        // Every connection dialled here: under `std.Io.Threaded` the pool's
        // own reconnector cannot park, so the harness dials in full — the
        // constraint `sql/db.zig`'s `connect_on_init` documents.
        p.db = .init(testing.allocator, url, .{ .size = 3, .connect_on_init = 3 });
        p.run = .init(testing.allocator);
        try p.db.nilo_start(p.threaded.io(), .off);
        _ = try p.db.exec(&p.run, "DROP TABLE IF EXISTS \"nilo_jobs\"", .{});
        try sql.migrate.createMissing(&p.db, &p.run, &.{PgTable.Row});
        return p;
    }

    fn close(p: *Pg) void {
        _ = p.db.exec(&p.run, "DROP TABLE IF EXISTS \"nilo_jobs\"", .{}) catch {};
        p.run.deinit();
        p.db.nilo_stop();
        p.db.deinit();
        p.threaded.deinit();
        testing.allocator.destroy(p);
    }
};

test "on Postgres a row is claimed with SKIP LOCKED, once, and a unique key holds" {
    const p = (try Pg.open()) orelse return error.SkipZigTest;
    defer p.close();
    var table = PgTable.open(&p.db);

    const id = (try table.push(&p.run, "write-note", "{\"text\":\"a\"}", .{ .run_at = 100, .unique = "pg1" })).?;
    try testing.expect((try table.push(&p.run, "write-note", "{}", .{ .run_at = 100, .unique = "pg1" })) == null);
    try testing.expect((try table.claim(&p.run, 50, 1_000)) == null);

    const claimed = (try table.claim(&p.run, 150, 1_000)).?;
    try testing.expectEqual(id, claimed.id);
    try testing.expectEqualStrings("{\"text\":\"a\"}", claimed.payload);
    try testing.expect((try table.claim(&p.run, 150, 1_000)) == null);

    try table.retry(&p.run, id, 500, "Later");
    try testing.expect((try table.claim(&p.run, 200, 1_000)) == null);
    const again = (try table.claim(&p.run, 600, 1_000)).?;
    try testing.expectEqual(@as(u32, 2), again.attempts);
    try table.done(&p.run, id);
    try testing.expect((try table.push(&p.run, "write-note", "{}", .{ .run_at = 100, .unique = "pg1" })) != null);

    // Two rows due, claimed inside two open transactions at once: each
    // claim takes a different row, which is what SKIP LOCKED is for.
    _ = try table.push(&p.run, "write-note", "{}", .{ .run_at = 0 });
    var tx_a = try p.db.begin(&p.run, .{});
    defer tx_a.deinit();
    var tx_b = try p.db.begin(&p.run, .{});
    defer tx_b.deinit();
    const a = (try tx_a.rawOne(PgTable.Row, &p.run, claimSql(), .{ @as(i64, 1_000), @as(i64, 5_000) })).?;
    const b = (try tx_b.rawOne(PgTable.Row, &p.run, claimSql(), .{ @as(i64, 1_000), @as(i64, 5_000) })).?;
    try testing.expect(a.id != b.id);
    try tx_a.commit();
    try tx_b.commit();
}

/// The Table's own statement, spelled again here so the test can hold two
/// of it open at once — `Table.claim` runs outside a transaction on purpose.
fn claimSql() []const u8 {
    return "UPDATE \"nilo_jobs\" SET \"state\" = 'running', \"lease_until\" = $2, \"attempts\" = \"attempts\" + 1 " ++
        "WHERE \"id\" = (SELECT \"id\" FROM \"nilo_jobs\" WHERE (\"state\" = 'queued' AND \"run_at\" <= $1) OR " ++
        "(\"state\" = 'running' AND \"lease_until\" <= $1) ORDER BY \"run_at\" LIMIT 1 FOR UPDATE SKIP LOCKED) " ++
        "RETURNING \"id\", \"kind\", \"payload\", \"state\", \"run_at\", \"lease_until\", \"attempts\", " ++
        "\"unique_key\", \"last_error\", \"created_at\", \"finished_at\"";
}
