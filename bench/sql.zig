//! What a prepared statement is worth, measured before it is built.
//!
//! `docs/roadmap.md` carried "prepared statements" as the SQL module's Next 1
//! with one condition on it: **measure first.** Every statement `nilo_sql`
//! sends is already a comptime constant, which is the property that makes a
//! per-connection statement cache cheap here and impossible in a library that
//! assembles its SQL per request — the key can be the statement's own
//! identity, and the number of distinct keys is fixed when the binary is
//! built. What nobody knew is the number, and
//! [ADR 0001](../docs/adr/0001-dx-wins-below-the-10-percent-threshold.md)'s
//! 10% cuts both ways: a feature that buys less than that is not worth the
//! surface either.
//!
//! It measures twice. Once at the driver, where the whole difference between
//! the two paths is one `cache_name` in `QueryOpts` — and once through
//! `db.find`, which is what a caller actually pays. The second was the honest
//! check on the first: everything `nilo_sql` does above the driver is the same
//! work either way, so if the module were eating the saving the ratio would
//! have collapsed up there. It did not. **The two agree to within 0.4 points,
//! and `db.find` costs about 100 ns more than the raw driver call it wraps** —
//! a quarter of one percent of a key lookup, which is the whole of what the
//! typed layer costs at run time.
//!
//! ```
//! DATABASE_URL=postgres://nilo:nilo@localhost:5433/nilo zig build bench-sql
//! ```
//!
//! The Postgres half needs a database and says so rather than skipping,
//! because unlike a test this was run on purpose.
//!
//! ## The SQLite half
//!
//! The same question again, against the second Wire (ADR 0073), and it needs
//! nothing: a file in `/tmp`, made and dropped by this program. Same three
//! statement shapes, same `db.find`, same prepared-against-not comparison, so
//! the two halves of the printout answer one question in two dialects.
//!
//! **Three things about it are worth reading before the numbers are quoted.**
//!
//! 1. **A Postgres row crosses a socket and a SQLite row does not**, so the
//!    absolute columns of the two halves are not a race. What travels between
//!    them is the *ratio*: what preparing a statement once is worth, which is
//!    a property of the work rather than of the transport.
//! 2. **The write arm is a disk measurement and belongs to whatever machine
//!    ran it.** It is here because ADR 0074 will not let a SQLite number be
//!    published without its durability beside it: `synchronous = NORMAL` is
//!    this module's default and `FULL` is one word away, and the gap between
//!    them is an `fsync`, not a database. Both are printed rather than one,
//!    so nobody has to take the default on trust.
//! 3. **`insertMany` has no SQLite arm at all, and that is the Dialect
//!    refusing rather than this file skipping.** There is no `unnest` and no
//!    array parameter, so the batch form SQLite has grows its own statement
//!    text and `arrayOf` answers null (ADR 0061). The shape that replaces it
//!    — a row at a time inside one transaction — is cheaper here than it
//!    sounds, because there is no round trip to pay per statement, and it is
//!    a different measurement rather than the same one in another dialect.
//!
//! What is **not** here is `.in_fiber` against `.{ .hop = nilo }`, which is
//! the choice ADR 0073 left to the caller and the one number that would make
//! one of them advice. That wants the Engine and a load generator — a run of
//! `bench-sql-server` with each — and it is `docs/roadmap.md`'s Next 1 for
//! this module rather than something this single-threaded program can answer.

const std = @import("std");
const pg = @import("pg");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");
const live_config = @import("live_config");

const table = "nilo_bench_people";

const setup =
    "DROP TABLE IF EXISTS " ++ table ++ ";" ++
    "CREATE TABLE " ++ table ++ " (" ++
    "  id bigint PRIMARY KEY," ++
    "  email text NOT NULL," ++
    "  age integer NOT NULL," ++
    "  created_at timestamptz NOT NULL DEFAULT now()" ++
    ");" ++
    "INSERT INTO " ++ table ++ " (id, email, age)" ++
    "  SELECT g, 'p' || g || '@example.dev', 20 + (g % 50) FROM generate_series(1, 1000) g;";

/// The statement `db.find(Person, c, id)` compiles to, written out rather
/// than imported: this file measures the driver, and taking the text from the
/// module would make it look like the module is what is being timed.
const find_sql =
    "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"" ++ table ++
    "\" WHERE \"id\" = $1 LIMIT 1";

/// Something with a plan worth keeping. A primary-key lookup is the cheapest
/// thing to plan, so it is the *floor* on what a cache buys; a condition with
/// a sort and a range is nearer what a page of a list costs.
const page_sql =
    "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"" ++ table ++
    "\" WHERE \"age\" > $1 AND \"email\" LIKE $2 ORDER BY \"created_at\" DESC, \"id\" ASC LIMIT 20";

/// `SELECT 1` prepared: as close to a bare round trip as the extended
/// protocol gets, and the number the pipelining question turns on
/// (ADR 0059). Whatever a statement costs, this is the floor under it.
const empty_sql = "SELECT 1";

const rounds = 20_000;
const warmup = 2_000;

/// How many times each comparison is run, alternating the two sides.
///
/// **One pass each is what this program used to do, and it was wrong enough to
/// matter.** Three consecutive runs of the SQLite key lookup on a two-core
/// shared machine gave 4,537, 6,158 and 8,281 ns for the *same* side of the
/// *same* comparison — a spread of 1.8x, which is wider than most of what a
/// benchmark like this is asked to detect. Taking one pass and publishing it
/// is how a run of the noise gets written down as a finding, which
/// `CLAUDE.md` records having happened here before.
///
/// So each side is run `passes` times, alternating, and two things are
/// printed rather than one: the **best** pass on each side, which is the run
/// least interfered with, and the **range** of the saving across pairs. A
/// margin narrower than its own range is not a margin.
const passes = 5;

/// The same for the write arm, and fewer because one of its two sides is an
/// `fsync` per row.
const write_passes = 3;

/// One comparison, kept as its spread rather than flattened to a number.
const Pair = struct {
    label: []const u8,
    first: []const u8,
    second: []const u8,
    /// Best of the passes on each side. Best rather than mean: every source of
    /// error on a shared machine adds time, so the minimum is the closest
    /// thing to the work itself.
    a: u64 = std.math.maxInt(u64),
    b: u64 = std.math.maxInt(u64),
    low: f64 = std.math.inf(f64),
    high: f64 = -std.math.inf(f64),

    fn add(self: *Pair, a: u64, b: u64) void {
        self.a = @min(self.a, a);
        self.b = @min(self.b, b);
        const share = pct(a, b);
        self.low = @min(self.low, share);
        self.high = @max(self.high, share);
    }

    fn pct(a: u64, b: u64) f64 {
        const from: f64 = @floatFromInt(a);
        return (from - @as(f64, @floatFromInt(b))) * 100.0 / from;
    }

    fn report(self: Pair, unit: []const u8) void {
        const saved = @as(f64, @floatFromInt(self.a)) - @as(f64, @floatFromInt(self.b));
        std.debug.print("{s}\n", .{self.label});
        std.debug.print("  {s:<19} {d:>9} ns/{s}   best of {d}\n", .{
            self.first, self.a, unit, passes,
        });
        std.debug.print("  {s:<19} {d:>9} ns/{s}\n", .{ self.second, self.b, unit });
        std.debug.print("  saved               {d:>9.1} ns  ({d:.1}%)\n", .{
            saved, pct(self.a, self.b),
        });
        std.debug.print("  across the passes   {d:>9.1}% … {d:.1}%\n\n", .{ self.low, self.high });
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    // First, because it needs nothing. A run with no Postgres in reach still
    // measures something, which is the difference between the two Wires
    // showing up in the benchmark harness before it shows up in a number.
    try sqliteArm(gpa, threaded.io());

    const url = live_config.database_url orelse {
        std.debug.print(
            "The Postgres half needs a database, and was skipped.\n" ++
                "  DATABASE_URL=postgres://… zig build bench-sql\n" ++
                "  docker compose -f sql/docker-compose.yml up -d\n",
            .{},
        );
        return;
    };

    const pool = try pg.Pool.initUri(threaded.io(), gpa, try std.Uri.parse(url), .{
        .size = 1,
        .connect_on_init_count = 1,
    });
    defer pool.deinit();

    var conn = try pool.acquire();
    defer conn.release();

    var it = std.mem.splitScalar(u8, setup, ';');
    while (it.next()) |raw| {
        const statement = std.mem.trim(u8, raw, " \n\r\t");
        if (statement.len == 0) continue;
        _ = try conn.exec(statement, .{});
    }

    std.debug.print(
        "\nnilo_sql on Postgres — what a per-connection statement cache is worth\n" ++
            "{d} rounds each, one connection, after {d} warm-up\n\n",
        .{ rounds, warmup },
    );

    try report(gpa, conn, "a bare round trip", empty_sql, .empty, "nilo_bench_empty");
    try report(gpa, conn, "a key lookup", find_sql, .key, "nilo_bench_key");
    try report(gpa, conn, "a page with a sort", page_sql, .page, "nilo_bench_page");

    // The same question one layer up, which is the one a caller actually
    // pays: `db.find` builds a parameter tuple, fills a Row and keeps its
    // text, and all of that is the same work either way. If the saving
    // measured at the driver did not survive up here, the module would be
    // eating it.
    conn.release();
    try throughTheModule(gpa, threaded.io(), url);

    // The table is left behind on purpose: `bench/sql_server.zig` reads the
    // same one, and the setup above drops and rebuilds it every run, so
    // leaving it costs a thousand rows in a throwaway database and saves
    // the second program a fixture of its own.
    std.debug.print("`" ++ table ++ "` is left in place for bench/sql_server.zig.\n", .{});
}

const Shape = enum { key, page, empty };

/// `name` is per shape, and finding that out the hard way is half of what
/// this measurement taught: reusing one name for two statements made pg.zig
/// answer `WrongNumberOfParameters`, because a cache hit re-binds against the
/// *cached* describe without looking at the SQL again. Two statements with
/// the same parameter count would not have said anything at all — which is
/// why the name `nilo_sql` derives has to be unique by construction rather
/// than by luck (ADR 0057).
fn report(
    gpa: std.mem.Allocator,
    conn: *pg.Conn,
    label: []const u8,
    text: []const u8,
    shape: Shape,
    name: []const u8,
) !void {
    _ = try walk(gpa, conn, text, shape, warmup, null);
    _ = try walk(gpa, conn, text, shape, warmup, name);

    var pair: Pair = .{ .label = label, .first = "parsed every time", .second = "prepared once" };
    for (0..passes) |_| pair.add(
        try walk(gpa, conn, text, shape, rounds, null),
        try walk(gpa, conn, text, shape, rounds, name),
    );
    pair.report("query");
}

/// One pass, giving back nanoseconds per query. The rows are read and drained
/// the way `db.zig` reads them, because a measurement that stops at the first
/// row is measuring a different statement.
fn walk(
    gpa: std.mem.Allocator,
    conn: *pg.Conn,
    text: []const u8,
    shape: Shape,
    count: usize,
    cache_name: ?[]const u8,
) !u64 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const started = monotonicNanos();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const opts: pg.Conn.QueryOpts = .{
            .allocator = arena.allocator(),
            .cache_name = cache_name,
        };
        var result = switch (shape) {
            // The id varies, which is the point of a parameter: a cache that
            // only worked for one value would not be a cache.
            .key => try conn.queryOpts(text, .{@as(i64, @intCast((i % 1000) + 1))}, opts),
            .page => try conn.queryOpts(text, .{ @as(i32, 20), "p%" }, opts),
            .empty => try conn.queryOpts(text, .{}, opts),
        };
        defer result.deinit();
        while (try result.next()) |_| {}
        try result.drain();
    }
    return @intCast(@divTrunc(monotonicNanos() - started, @as(i128, count)));
}

/// `CLOCK_MONOTONIC`, read the way `core/clock.zig` reads its own — Zig 0.16
/// has no `std.time.Timer`, and this file may not import Core anyway.
fn monotonicNanos() i128 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
        .SUCCESS => {},
        else => unreachable,
    }
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// The Row `db.find` is measured against — four columns, one of them text
/// that has to be copied into the arena.
const Person = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

    id: i64,
    email: nilo.Str,
    age: i32,
    created_at: sql.Timestamp,
};

fn throughTheModule(gpa: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    var pair: Pair = .{
        .label = "db.find through the whole module",
        .first = ".prepared = false",
        .second = ".prepared = true",
    };
    for (0..passes) |_| pair.add(
        try findRounds(gpa, io, url, false),
        try findRounds(gpa, io, url, true),
    );
    pair.report("query");
}

fn findRounds(gpa: std.mem.Allocator, io: std.Io, url: []const u8, prepared: bool) !u64 {
    var db = sql.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .prepared = prepared });
    defer db.deinit();
    try db.nilo_start(io);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    var i: usize = 0;
    while (i < warmup) : (i += 1) {
        _ = try db.find(Person, &run, @as(i64, @intCast((i % 1000) + 1)));
        run.reset();
    }

    const started = monotonicNanos();
    i = 0;
    while (i < rounds) : (i += 1) {
        _ = try db.find(Person, &run, @as(i64, @intCast((i % 1000) + 1)));
        run.reset();
    }
    return @intCast(@divTrunc(monotonicNanos() - started, @as(i128, rounds)));
}

// -- SQLite ---------------------------------------------------------------

/// `.in_fiber` because this program has no Engine: `.{ .hop = nilo }` hands
/// the statement to `nilo.blocking`, which is the Engine's thread pool and
/// does not exist under `std.Io.Threaded`. That is the constraint that makes
/// the hop comparison a `bench-sql-server` job rather than this one.
const SqliteWire = sql.sqlite.Wire(.{ .threading = .in_fiber });
const SqliteDb = sql.Sqlite(.{ .threading = .in_fiber });

/// The durability arm's other half. `synchronous` is a comptime option on the
/// Wire, so measuring both settings means compiling both — which is itself
/// worth knowing: it is not a runtime knob an operator can turn, and ADR 0074
/// chose that on purpose.
const SqliteFullWire = sql.sqlite.Wire(.{ .threading = .in_fiber, .synchronous = .full });

/// Fixed paths rather than a temporary directory, the same way
/// `spike/sqlite_facts` does it: this has to be a real file on a real
/// filesystem or the write arm is measuring nothing, and a run that crashes
/// leaves something a person can open with `sqlite3`.
const sqlite_db = "/tmp/nilo-bench-sqlite.db";
const sqlite_full_db = "/tmp/nilo-bench-sqlite-full.db";

/// `INTEGER PRIMARY KEY NOT NULL` and not just `PRIMARY KEY`: SQLite leaves
/// `notnull` at 0 for a rowid alias, so the schema check would read the column
/// as nullable and disagree with `id: i64` — which is the check working, and
/// a fixture that has to say so.
const sqlite_setup =
    "DROP TABLE IF EXISTS " ++ table ++ ";" ++
    "CREATE TABLE " ++ table ++ " (" ++
    "  id INTEGER PRIMARY KEY NOT NULL," ++
    "  email TEXT NOT NULL," ++
    "  age INTEGER NOT NULL," ++
    "  created_at INTEGER NOT NULL" ++
    ");" ++
    "WITH RECURSIVE g(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM g WHERE i < 1000) " ++
    "INSERT INTO " ++ table ++ " (id, email, age, created_at) " ++
    "SELECT i, 'p' || i || '@example.dev', 20 + (i % 50), 1755000000 FROM g;";

/// The same three statements as the Postgres half, in SQLite's placeholder
/// grammar. Written out for the same reason those are: this measures the
/// driver, and importing the text from the module would make it look like the
/// module is what is being timed.
const sqlite_find_sql =
    "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"" ++ table ++
    "\" WHERE \"id\" = ?1 LIMIT 1";

const sqlite_page_sql =
    "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"" ++ table ++
    "\" WHERE \"age\" > ?1 AND \"email\" LIKE ?2 ORDER BY \"created_at\" DESC, \"id\" ASC LIMIT 20";

const sqlite_insert_sql =
    "INSERT INTO " ++ table ++ " (id, email, age, created_at) VALUES (?1, ?2, ?3, ?4)";

/// Far fewer than the read rounds, because one of the two settings being
/// compared is an `fsync` per row. At the millisecond or so an `fsync` costs
/// on ordinary storage, twenty thousand of them is a benchmark nobody would
/// wait through — and the arm still takes about a second a pass.
const write_rounds = 500;
const write_warmup = 50;

/// The Row, and **`created_at` is an `i64` here where the Postgres one is a
/// `sql.Timestamp`**. That is not an oversight and it is not free: a
/// `timestamptz` is TEXT on SQLite (`dialect.SQLite.accepts`), so the two
/// columns are read differently and the last of the four is an integer here
/// against a conversion there. It is the one place the two `db.find` lines
/// below are not the same work, and it is stated rather than buried.
const SqlitePerson = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

    id: i64,
    email: nilo.Str,
    age: i32,
    created_at: i64,
};

fn sqliteArm(gpa: std.mem.Allocator, io: std.Io) !void {
    try freshFile(io, sqlite_db);
    try freshFile(io, sqlite_full_db);

    std.debug.print(
        "\nnilo_sql on SQLite — the same question, in a library rather than a server\n" ++
            "{d} rounds each, one connection, after {d} warm-up\n" ++
            "sqlite {s}, WAL, threading = .in_fiber\n\n",
        .{ rounds, warmup, sql.sqlite.version },
    );

    // The Wire lives in a block so it is shut before the module opens its own
    // pool on the same file. One writer is the whole design (ADR 0074), and
    // two pools on one file would be two of them — which is the case
    // `busy_timeout_ms` exists for and not what is being measured here.
    {
        var w = try SqliteWire.open(io, gpa, sqlite_db, .{ .size = 2 });
        defer w.close();

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        try fixture(SqliteWire, &w, arena.allocator());

        try sqliteReport(gpa, &w, "a bare round trip", "SELECT 1", .empty, "nilo_bench_sq_empty");
        try sqliteReport(gpa, &w, "a key lookup", sqlite_find_sql, .key, "nilo_bench_sq_key");
        try sqliteReport(gpa, &w, "a page with a sort", sqlite_page_sql, .page, "nilo_bench_sq_page");
    }

    try sqliteThroughTheModule(gpa, io);
    try sqliteDurability(gpa, io);

    std.debug.print(
        "`" ++ sqlite_db ++ "` and `" ++ sqlite_full_db ++ "` are left in place, " ++
            "and are rebuilt from scratch every run.\n\n",
        .{},
    );
}

/// Delete the database and both files WAL keeps beside it. `FileNotFound` is
/// the ordinary case on a first run, and the `-wal`/`-shm` pair is why this is
/// three deletes rather than one: leaving a WAL behind a deleted database is
/// how SQLite is asked to recover a file that is not there.
fn freshFile(io: std.Io, path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "", "-wal", "-shm" }) |suffix| {
        const full = std.fmt.bufPrint(&buf, "{s}{s}", .{ path, suffix }) catch return error.PathTooLong;
        std.Io.Dir.deleteFileAbsolute(io, full) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

/// The table and its thousand rows, dropped and rebuilt. `W` rather than a
/// value because the durability arm's two Wires are two types, and this is the
/// one piece of setup both of them want.
fn fixture(comptime W: type, w: *W, a: std.mem.Allocator) !void {
    var it = std.mem.splitScalar(u8, sqlite_setup, ';');
    while (it.next()) |raw| {
        const statement = std.mem.trim(u8, raw, " \n\r\t");
        if (statement.len == 0) continue;
        _ = try w.exec(a, statement, .{}, null);
    }
}

fn sqliteReport(
    gpa: std.mem.Allocator,
    w: *SqliteWire,
    label: []const u8,
    text: []const u8,
    shape: Shape,
    name: []const u8,
) !void {
    _ = try sqliteWalk(gpa, w, text, shape, warmup, null);
    _ = try sqliteWalk(gpa, w, text, shape, warmup, name);

    var pair: Pair = .{
        .label = label,
        .first = "prepared every time",
        .second = "prepared once",
    };
    for (0..passes) |_| pair.add(
        try sqliteWalk(gpa, w, text, shape, rounds, null),
        try sqliteWalk(gpa, w, text, shape, rounds, name),
    );
    pair.report("query");
}

/// One pass, giving back nanoseconds per query — the Postgres `walk` in
/// SQLite's grammar, reading no columns and draining, so the two measure the
/// same amount of the same thing.
fn sqliteWalk(
    gpa: std.mem.Allocator,
    w: *SqliteWire,
    text: []const u8,
    shape: Shape,
    count: usize,
    plan: ?[]const u8,
) !u64 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const started = monotonicNanos();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var rows = switch (shape) {
            .key => try w.run(a, text, .{@as(i64, @intCast((i % 1000) + 1))}, plan),
            .page => try w.run(a, text, .{ @as(i32, 20), "p%" }, plan),
            .empty => try w.run(a, text, .{}, plan),
        };
        errdefer rows.close();
        while (try w.next(&rows)) {}
        w.drain(&rows);
    }
    return @intCast(@divTrunc(monotonicNanos() - started, @as(i128, count)));
}

fn sqliteThroughTheModule(gpa: std.mem.Allocator, io: std.Io) !void {
    var pair: Pair = .{
        .label = "db.find through the whole module",
        .first = ".prepared = false",
        .second = ".prepared = true",
    };
    for (0..passes) |_| pair.add(
        try sqliteFindRounds(gpa, io, false),
        try sqliteFindRounds(gpa, io, true),
    );
    pair.report("query");
}

fn sqliteFindRounds(gpa: std.mem.Allocator, io: std.Io, prepared: bool) !u64 {
    var db = SqliteDb.init(gpa, sqlite_db, .{ .size = 2, .prepared = prepared });
    defer db.deinit();
    try db.nilo_start(io);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    var i: usize = 0;
    while (i < warmup) : (i += 1) {
        _ = try db.find(SqlitePerson, &run, @as(i64, @intCast((i % 1000) + 1)));
        run.reset();
    }

    const started = monotonicNanos();
    i = 0;
    while (i < rounds) : (i += 1) {
        _ = try db.find(SqlitePerson, &run, @as(i64, @intCast((i % 1000) + 1)));
        run.reset();
    }
    return @intCast(@divTrunc(monotonicNanos() - started, @as(i128, rounds)));
}

/// What `synchronous` costs, which is what ADR 0074 will not let a SQLite
/// number be published without.
///
/// Both arms write to their own file, because the setting is baked into the
/// Wire's type and a database primed at one cannot be re-primed at the other
/// without reopening it. What is being timed is one autocommitted INSERT —
/// the shape a handler writes without thinking about it, and the shape whose
/// cost is entirely the durability question.
fn sqliteDurability(gpa: std.mem.Allocator, io: std.Io) !void {
    var normal: u64 = std.math.maxInt(u64);
    var full: u64 = std.math.maxInt(u64);
    for (0..write_passes) |i| {
        const at: i64 = 1_000_000 + @as(i64, @intCast(i)) * 10_000;
        normal = @min(normal, try insertRounds(SqliteWire, gpa, io, sqlite_db, at));
        full = @min(full, try insertRounds(SqliteFullWire, gpa, io, sqlite_full_db, at));
    }

    const times = @as(f64, @floatFromInt(full)) / @as(f64, @floatFromInt(normal));

    std.debug.print("one autocommitted INSERT, {d} rounds after {d} warm-up\n", .{
        write_rounds, write_warmup,
    });
    std.debug.print("  synchronous = NORMAL  {d:>9} ns/insert   best of {d}, and the default\n", .{
        normal, write_passes,
    });
    std.debug.print("  synchronous = FULL    {d:>9} ns/insert\n", .{full});
    std.debug.print("  FULL costs            {d:>9.1}x\n", .{times});
    std.debug.print(
        "  This one is a disk measurement. The gap is an fsync, so it belongs to the\n" ++
            "  machine and the filesystem rather than to SQLite or to nilo.\n\n",
        .{},
    );
}

/// `W` rather than a value, because the two arms differ by a comptime option
/// and are therefore two types. The table is created here when it is missing,
/// which is what the `full` file needs and the `normal` one does not.
fn insertRounds(
    comptime W: type,
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    first_id: i64,
) !u64 {
    var w = try W.open(io, gpa, path, .{ .size = 2 });
    defer w.close();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try fixture(W, &w, arena.allocator());

    const plan = "nilo_bench_sq_insert";
    var i: usize = 0;
    while (i < write_warmup) : (i += 1) {
        try oneInsert(W, &w, arena.allocator(), first_id + @as(i64, @intCast(i)), plan);
    }

    const started = monotonicNanos();
    i = 0;
    while (i < write_rounds) : (i += 1) {
        try oneInsert(
            W,
            &w,
            arena.allocator(),
            first_id + write_warmup + @as(i64, @intCast(i)),
            plan,
        );
    }
    return @intCast(@divTrunc(monotonicNanos() - started, @as(i128, write_rounds)));
}

fn oneInsert(comptime W: type, w: *W, a: std.mem.Allocator, id: i64, plan: []const u8) !void {
    _ = try w.exec(a, sqlite_insert_sql, .{
        id,
        "written@example.dev",
        @as(i32, 33),
        @as(i64, 1755000000),
    }, plan);
}
