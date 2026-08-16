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
//! It needs a database and says so rather than skipping, because unlike a
//! test this was run on purpose.

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

const rounds = 20_000;
const warmup = 2_000;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const url = live_config.database_url orelse {
        std.debug.print(
            "bench-sql needs a database.\n" ++
                "  DATABASE_URL=postgres://… zig build bench-sql\n" ++
                "  docker compose -f sql/docker-compose.yml up -d\n",
            .{},
        );
        return;
    };

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

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
        "\nnilo_sql — what a per-connection statement cache is worth\n" ++
            "{d} rounds each, one connection, after {d} warm-up\n\n",
        .{ rounds, warmup },
    );

    try report(gpa, conn, "a key lookup", find_sql, .key, "nilo_bench_key");
    try report(gpa, conn, "a page with a sort", page_sql, .page, "nilo_bench_page");

    // The same question one layer up, which is the one a caller actually
    // pays: `db.find` builds a parameter tuple, fills a Row and keeps its
    // text, and all of that is the same work either way. If the saving
    // measured at the driver did not survive up here, the module would be
    // eating it.
    conn.release();
    try throughTheModule(gpa, threaded.io(), url);

    var last = try pool.acquire();
    defer last.release();
    _ = try last.exec("DROP TABLE IF EXISTS " ++ table, .{});
}

const Shape = enum { key, page };

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

    const plain = try walk(gpa, conn, text, shape, rounds, null);
    const cached = try walk(gpa, conn, text, shape, rounds, name);

    const saved = @as(f64, @floatFromInt(plain)) - @as(f64, @floatFromInt(cached));
    const share = saved * 100.0 / @as(f64, @floatFromInt(plain));

    std.debug.print("{s}\n", .{label});
    std.debug.print("  parsed every time   {d:>7} ns/query\n", .{plain});
    std.debug.print("  prepared once       {d:>7} ns/query\n", .{cached});
    std.debug.print("  saved               {d:>7.1} ns  ({d:.1}%)\n\n", .{ saved, share });
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
    const plain = try findRounds(gpa, io, url, false);
    const kept = try findRounds(gpa, io, url, true);

    const saved = @as(f64, @floatFromInt(plain)) - @as(f64, @floatFromInt(kept));
    const share = saved * 100.0 / @as(f64, @floatFromInt(plain));

    std.debug.print("db.find through the whole module\n", .{});
    std.debug.print("  .prepared = false   {d:>7} ns/query\n", .{plain});
    std.debug.print("  .prepared = true    {d:>7} ns/query\n", .{kept});
    std.debug.print("  saved               {d:>7.1} ns  ({d:.1}%)\n\n", .{ saved, share });
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
