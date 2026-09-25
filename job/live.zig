//! The tests that need a database, and the one place `job/` names `nilo_sql`
//! (ADR 160). A root of its own rather than a line in `job/job.zig`'s test
//! block, for the reason `fetch/deadline.zig` is one: putting it there would
//! make `zig test job/job.zig` need a driver and cost the Fitting layer its
//! entry condition (ADR 061).
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
        f.db = .init(testing.allocator, url, .{ .size = 2, .unchecked = true });
        f.run = .init(testing.allocator);
        try f.db.nilo_start(f.threaded.io(), .off);
        try sql.migrate.createMissing(&f.db, &f.run, .{ .tables = &.{ SqliteTable.Row, Note } });
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
    try testing.expect((try table.claim(&f.run, live_kinds, 50, 1_000)) == null);

    const claimed = (try table.claim(&f.run, live_kinds, 150, 1_000)).?;
    try testing.expectEqual(id, claimed.id);
    try testing.expectEqualStrings("write-note", claimed.kind);
    try testing.expectEqualStrings("{\"text\":\"a\"}", claimed.payload);
    try testing.expectEqual(@as(u32, 1), claimed.attempts);
    // Running, and leased: not claimable again until the lease is over.
    try testing.expect((try table.claim(&f.run, live_kinds, 150, 1_000)) == null);
    try testing.expectEqual(@as(u64, 1), (try table.stats(&f.run)).running);
    const again = (try table.claim(&f.run, live_kinds, 1_001, 2_000)).?;
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

    const claimed = (try table.claim(&f.run, live_kinds, 1, 100)).?;
    try testing.expect((try table.push(&f.run, "write-note", "{}", .{ .run_at = 0, .unique = "u1" })) == null);
    try table.dead(&f.run, claimed.id, "Gone");
    try testing.expect((try table.push(&f.run, "write-note", "{}", .{ .run_at = 0, .unique = "u1" })) != null);

    const listed = try table.deadOnes(&f.run);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqualStrings("Gone", listed[0].err);
    try testing.expect(try table.retryDead(&f.run, claimed.id, 5));
    try testing.expect(!(try table.retryDead(&f.run, claimed.id, 5)));
}

test "on SQLite cancel deletes a queued row and leaves one a worker holds" {
    const f = try Fixture.open("job-cancel");
    defer f.close();
    var table = SqliteTable.open(&f.db);

    const id = (try table.push(&f.run, "write-note", "{}", .{ .run_at = 0, .unique = "u1" })).?;
    try testing.expect(try table.cancel(&f.run, id));
    try testing.expect(!(try table.cancel(&f.run, id)));
    try testing.expectEqual(@as(u64, 0), (try table.stats(&f.run)).queued);
    // The unique key went with the row, so the same key queues again.
    const again = (try table.push(&f.run, "write-note", "{}", .{ .run_at = 0, .unique = "u1" })).?;
    _ = (try table.claim(&f.run, live_kinds, 1, 100)).?;
    try testing.expect(!(try table.cancel(&f.run, again)));
    try testing.expectEqual(@as(u64, 1), (try table.stats(&f.run)).running);
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
        p.db = .init(testing.allocator, url, .{ .size = 3, .connect_on_init = 3, .unchecked = true });
        p.run = .init(testing.allocator);
        try p.db.nilo_start(p.threaded.io(), .off);
        _ = try p.db.exec(&p.run, "DROP TABLE IF EXISTS \"nilo_jobs\"", .{});
        try sql.migrate.createMissing(&p.db, &p.run, .{ .tables = &.{PgTable.Row} });
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
    try testing.expect((try table.claim(&p.run, live_kinds, 50, 1_000)) == null);

    const claimed = (try table.claim(&p.run, live_kinds, 150, 1_000)).?;
    try testing.expectEqual(id, claimed.id);
    try testing.expectEqualStrings("{\"text\":\"a\"}", claimed.payload);
    try testing.expect((try table.claim(&p.run, live_kinds, 150, 1_000)) == null);

    try table.retry(&p.run, id, 500, "Later");
    try testing.expect((try table.claim(&p.run, live_kinds, 200, 1_000)) == null);
    const again = (try table.claim(&p.run, live_kinds, 600, 1_000)).?;
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

test "the priority column carries a default, so it can be added to a table with rows" {
    // A column that may not be null and has no default is the one ALTER that
    // fails on a table that already has rows, and the one an older binary's
    // INSERT — or a sibling binary's, which is ADR 215's own case — walks
    // into during a rolling deploy. No database needed: this is the DDL nilo
    // would write.
    const created = comptime sql.ddl.createTable(sql.dialect.Postgres, PgTable.Row);
    try testing.expect(std.mem.indexOf(u8, created, "\"priority\"") != null);
    try testing.expect(std.mem.indexOf(u8, created, "DEFAULT 1") != null);
    const lite = comptime sql.ddl.createTable(sql.dialect.SQLite, SqliteTable.Row);
    try testing.expect(std.mem.indexOf(u8, lite, "DEFAULT 1") != null);
}

test "on Postgres a kind this program does not know is left in the queue" {
    const p = (try Pg.open()) orelse return error.SkipZigTest;
    defer p.close();
    var table = PgTable.open(&p.db);
    _ = try p.db.exec(&p.run, "DELETE FROM \"nilo_jobs\"", .{});

    // Due first, and it would win any ordering.
    _ = try table.push(&p.run, "from-another-binary", "{}", .{ .run_at = 0 });
    const mine = (try table.push(&p.run, "write-note", "{}", .{ .run_at = 10 })).?;

    const got = (try table.claim(&p.run, live_kinds, 1_000, 5_000)).?;
    try testing.expectEqual(mine, got.id);
    // Nothing else for this program: the stranger is not claimed, handed
    // back and claimed again, which is the loop that used to spin and walk
    // its `attempts` up to dead.
    try testing.expect((try table.claim(&p.run, live_kinds, 1_000, 5_000)) == null);

    const Row = PgTable.Row;
    const left = (try p.db.rawOne(Row, &p.run,
        "SELECT * FROM \"nilo_jobs\" WHERE \"kind\" = 'from-another-binary'", .{})).?;
    try testing.expectEqual(job.State.queued, left.state);
    try testing.expectEqual(@as(i32, 0), left.attempts);
}

test "on SQLite the claim takes the most urgent due row, not the oldest" {
    // SQLite has its own branch of `claimSql` — numbered placeholders, `IN`
    // rather than `ANY`, the i16 priority mapped back through RETURNING — so
    // the order and the narrowing are worth asserting on both, not just on
    // whichever one the harness reaches.
    const f = try Fixture.open("job-priority");
    defer f.close();
    var table = SqliteTable.open(&f.db);

    _ = (try table.push(&f.run, "backfill", "{}", .{ .run_at = 10, .priority = .low })).?;
    _ = (try table.push(&f.run, "sweep", "{}", .{ .run_at = 20 })).?;
    _ = (try table.push(&f.run, "revalidate-b", "{}", .{ .run_at = 40, .priority = .high })).?;
    _ = (try table.push(&f.run, "revalidate-a", "{}", .{ .run_at = 30, .priority = .high })).?;

    const order = [_][]const u8{ "revalidate-a", "revalidate-b", "sweep", "backfill" };
    for (order) |want| {
        const c = (try table.claim(&f.run, live_kinds, 100, 1_000)).?;
        try testing.expectEqualStrings(want, c.kind);
        try table.done(&f.run, c.id);
    }
    try testing.expect((try table.claim(&f.run, live_kinds, 100, 1_000)) == null);
}

test "on SQLite a kind this program does not know is left in the queue" {
    const f = try Fixture.open("job-foreign");
    defer f.close();
    var table = SqliteTable.open(&f.db);

    _ = (try table.push(&f.run, "from-another-binary", "{}", .{ .run_at = 0 })).?;
    const mine = (try table.push(&f.run, "write-note", "{}", .{ .run_at = 10 })).?;

    const got = (try table.claim(&f.run, live_kinds, 1_000, 5_000)).?;
    try testing.expectEqual(mine, got.id);
    try testing.expect((try table.claim(&f.run, live_kinds, 1_000, 5_000)) == null);

    // Untouched: still queued, still at nought attempts, for the binary
    // that knows the kind.
    const theirs = (try table.claim(&f.run, &.{"from-another-binary"}, 1_000, 5_000)).?;
    try testing.expectEqual(@as(u32, 1), theirs.attempts);
}

test "on Postgres the claim takes the most urgent due row, not the oldest" {
    const p = (try Pg.open()) orelse return error.SkipZigTest;
    defer p.close();
    var table = PgTable.open(&p.db);

    // The order a backfill and the small jobs behind it arrive in. By
    // `run_at` alone the backfill is claimed first and holds the worker for
    // as long as it runs, which is the whole complaint.
    _ = (try table.push(&p.run, "backfill", "{}", .{ .run_at = 10, .priority = .low })).?;
    _ = (try table.push(&p.run, "sweep", "{}", .{ .run_at = 20 })).?;
    _ = (try table.push(&p.run, "revalidate-b", "{}", .{ .run_at = 40, .priority = .high })).?;
    _ = (try table.push(&p.run, "revalidate-a", "{}", .{ .run_at = 30, .priority = .high })).?;

    const order = [_][]const u8{ "revalidate-a", "revalidate-b", "sweep", "backfill" };
    for (order) |want| {
        const c = (try table.claim(&p.run, live_kinds, 100, 1_000)).?;
        try testing.expectEqualStrings(want, c.kind);
        try table.done(&p.run, c.id);
    }
    try testing.expect((try table.claim(&p.run, live_kinds, 100, 1_000)) == null);
}

/// A run that waits in the database for as long as the test lets it: what a
/// refresh or a backfill looks like to the worker when the server is told to
/// stop.
const SleepInDb = struct {
    pub const nilo_job = "sleep-in-db";
    pub const retry: job.Retry = .{ .times = 3, .backoff = .{ .fixed_ms = 60_000 } };

    pub fn run(_: SleepInDb, scope: *core.Run, db: *sql.Db) !void {
        const Slept = struct {
            pub const nilo_table = .projection;
            slept: bool,
        };
        // Marked, so the test waits for this statement and not a sleep
        // another test left running on the same server.
        _ = try db.raw(Slept, scope, "SELECT pg_sleep(10) IS NULL AS slept WHERE 'nilo_job cut-off' IS NOT NULL", .{});
    }
};

const PgSleepJobs = job.Jobs(.{
    .kinds = .{SleepInDb},
    .store = PgTable,
    .deps = struct { db: *sql.Db },
});

test "on Postgres a run cut off by a shutdown in the middle of a statement goes back to the queue" {
    // The shutdown cancels the worker while its run is waiting on a
    // statement. nilo_sql reports that as `QueryFailed` and leaves the
    // cancellation pending (ADR 223), so the run's error is not
    // `error.Canceled` — and the row still has to go back untouched, not be
    // written off as a failed attempt by a store call the same cancellation
    // stops, which leaves it `running` until its lease is over.
    const p = (try Pg.open()) orelse return error.SkipZigTest;
    defer p.close();
    var table = PgTable.open(&p.db);
    _ = try p.db.exec(&p.run, "DELETE FROM \"nilo_jobs\"", .{});

    var jobs: PgSleepJobs = .open(testing.allocator, &table, .{ .db = &p.db }, .{ .workers = 1, .poll_ms = 50 });
    const io = p.threaded.io();
    try jobs.nilo_start(io, .off);
    const id = try jobs.push(&p.run, SleepInDb{}, .{});
    const pushed = (try p.db.rawOne(i64, &p.run, "SELECT (extract(epoch FROM clock_timestamp()) * 1e6)::bigint", .{})).?;

    var serving = try io.concurrent(PgSleepJobs.serveOn, .{ &jobs, io });
    // Until the row is claimed and its run's statement is on the wire, then
    // the shutdown. A statement that started before the push is a sleep an
    // earlier run of this test left behind, not this one.
    var waiting = false;
    for (0..100) |_| {
        const n = try p.db.rawOne(i64, &p.run,
            \\SELECT count(*) FROM pg_stat_activity a, "nilo_jobs" j
            \\WHERE a.query LIKE '%nilo_job cut-off%' AND a.state = 'active' AND a.pid <> pg_backend_pid()
            \\  AND (extract(epoch FROM a.query_start) * 1e6)::bigint >= $1
            \\  AND j."id" = $2 AND j."state" = 'running'
        , .{ pushed, @as(i64, @intCast(id)) });
        if ((n orelse 0) > 0) {
            waiting = true;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    }
    try testing.expect(waiting);
    serving.cancel(io) catch {};

    const Row = PgTable.Row;
    const row = (try p.db.rawOne(Row, &p.run, "SELECT * FROM \"nilo_jobs\" WHERE \"id\" = $1", .{@as(i64, @intCast(id))})).?;
    try testing.expectEqual(job.State.queued, row.state);
    // The attempt the shutdown cut off is not counted against the row.
    try testing.expectEqual(@as(i32, 0), row.attempts);
    try testing.expectEqual(@as(?[]const u8, null), row.last_error);
}

/// The kinds these tests push. A worker passes its own `kind_names`; the
/// claim is narrowed to them, so a row of any other kind is left alone.
const live_kinds: []const []const u8 = &.{ "write-note", "backfill", "revalidate-a", "revalidate-b", "sweep" };

/// The Table's own statement, spelled again here so the test can hold two
/// of it open at once — `Table.claim` runs outside a transaction on purpose.
fn claimSql() []const u8 {
    return "UPDATE \"nilo_jobs\" SET \"state\" = 'running', \"lease_until\" = $2, \"attempts\" = \"attempts\" + 1 " ++
        "WHERE \"id\" = (SELECT \"id\" FROM \"nilo_jobs\" WHERE \"kind\" IN ('write-note') AND " ++
        "((\"state\" = 'queued' AND \"run_at\" <= $1) OR " ++
        "(\"state\" = 'running' AND \"lease_until\" <= $1)) ORDER BY \"priority\", \"run_at\" LIMIT 1 FOR UPDATE SKIP LOCKED) " ++
        "RETURNING \"id\", \"kind\", \"payload\", \"state\", \"run_at\", \"lease_until\", \"attempts\", " ++
        "\"priority\", \"unique_key\", \"last_error\", \"created_at\", \"finished_at\"";
}
