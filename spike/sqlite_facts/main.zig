//! Seven claims [ADR 0074](../../docs/adr/0074-one-writer-is-not-a-setting-it-is-the-database.md)
//! makes about SQLite and had not run. It says so itself:
//!
//! > Both SQLite behaviours above are stated from its documentation and are to
//! > be confirmed by a twelve-line program before this ADR is cited as
//! > evidence.
//!
//! This is that program. It runs against the library [ADR 0073](../../docs/adr/0073-a-file-has-no-socket-to-wait-on.md)
//! chose, so what it reports is the behaviour nilo would actually ship with
//! rather than SQLite in the abstract — the two can differ, because the flags
//! a wrapper passes to `sqlite3_open_v2` decide several of these.
//!
//!     zig build run
//!
//! Every check prints what it expected, what it got, and whether the ADR's
//! sentence survives. A failing check is the useful outcome: it means an ADR
//! gets edited before code is written against it.

const std = @import("std");
const zqlite = @import("zqlite");

var failures: usize = 0;

/// Fixed paths rather than a temporary directory: `run.sh` deletes them either
/// side of the run, and checks 4 and 6 need a real file on a real filesystem
/// because that is the whole difference they are measuring.
const wal_db = "/tmp/nilo-sqlite-facts.db";
const ro_db = "/tmp/nilo-sqlite-ro.db";
const pool_db = "/tmp/nilo-sqlite-pool.db";

fn check(name: []const u8, expected: []const u8, got: []const u8) void {
    const ok = std.mem.eql(u8, expected, got);
    if (!ok) failures += 1;
    std.debug.print("{s} {s}\n  expected: {s}\n  got:      {s}\n\n", .{
        if (ok) "PASS" else "FAIL",
        name,
        expected,
        got,
    });
}

/// `PRAGMA journal_mode` answers with the mode it ended up in rather than
/// failing, which is the whole point of checks 3 and 4.
fn journalMode(conn: zqlite.Conn, buf: []u8) ![]const u8 {
    const r = (try conn.row("PRAGMA journal_mode = WAL", .{})) orelse return "no row";
    defer r.deinit();
    const mode = r.text(0);
    @memcpy(buf[0..mode.len], mode);
    return buf[0..mode.len];
}

pub fn main(init: std.process.Init) !void {
    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;

    // `SCAN_CACHE_KIB=…` is check 9, run on its own so `strace -c` has one
    // process doing one thing. Reads are what a smaller page cache costs, and
    // a read is a syscall — which is a counter, and therefore a number this
    // machine can be trusted for where a timing would not be.
    //
    // The environment rather than arguments because that is what the rest of
    // the repository does (`bench/sql_server.zig`), and because
    // `std.process.args` and `std.os.argv` are both gone in 0.16.
    if (init.minimal.environ.getPosix("SCAN_CACHE_KIB")) |text| {
        const points = init.minimal.environ.getPosix("SCAN_POINTS") != null;
        return scan(try std.fmt.parseInt(i64, text, 10), points);
    }
    const uri_flags = flags | zqlite.OpenFlags.Uri;
    var buf: [64]u8 = undefined;

    std.debug.print("\nsqlite {s}, through zqlite\n\n", .{zqlite.c.SQLITE_VERSION});

    // 1. `:memory:` is private per connection.
    {
        const a = try zqlite.open(":memory:", flags);
        defer a.close();
        const b = try zqlite.open(":memory:", flags);
        defer b.close();

        try a.execNoArgs("create table t(id integer)");
        try a.execNoArgs("insert into t(id) values (1)");

        const seen = if (b.row("select id from t", .{})) |_| "visible" else |_| "not visible";
        check("1. `:memory:` twice is two databases", "not visible", seen);
    }

    // 2. The shared form is one database. This is what a pool must open.
    {
        const url = "file:nilo-facts?mode=memory&cache=shared";
        const a = try zqlite.open(url, uri_flags);
        defer a.close();
        const b = try zqlite.open(url, uri_flags);
        defer b.close();

        try a.execNoArgs("create table t(id integer)");
        try a.execNoArgs("insert into t(id) values (1)");

        const seen = if (b.row("select id from t", .{})) |maybe| blk: {
            if (maybe) |r| r.deinit();
            break :blk "visible";
        } else |_| "not visible";
        check("2. the shared URI form is one database", "visible", seen);
    }

    // 3. The claim the test story rests on: WAL is not available in memory,
    //    and asking for it is answered rather than refused.
    {
        const conn = try zqlite.open("file:nilo-wal?mode=memory&cache=shared", uri_flags);
        defer conn.close();
        check("3. WAL on an in-memory database", "memory", try journalMode(conn, &buf));
    }

    // 4. The control for 3. Same statement, a real file. The paths are fixed
    //    and the caller deletes them; `std.testing.tmpDir` is test-only and
    //    `Io.Dir` wants an `Io` this spike has no reason to stand up.
    {
        const conn = try zqlite.open(wal_db, flags);
        defer conn.close();
        check("4. WAL on a file (the control)", "wal", try journalMode(conn, &buf));
    }

    // 5. A shared in-memory database lives as long as a connection to it does.
    //    This is why the pool has to open the writer first and hold it.
    {
        const url = "file:nilo-life?mode=memory&cache=shared";
        {
            const a = try zqlite.open(url, uri_flags);
            defer a.close();
            try a.execNoArgs("create table t(id integer)");
        }
        const b = try zqlite.open(url, uri_flags);
        defer b.close();
        const seen = if (b.row("select id from t", .{})) |_| "survived" else |_| "gone";
        check("5. a shared in-memory database after its last connection closes", "gone", seen);
    }

    // 6. The mechanism ADR 0074 routes `db.raw` through: a reader is opened
    //    read-only, so a raw that writes is refused by SQLite rather than by
    //    us guessing from the text.
    {
        {
            const w = try zqlite.open(ro_db, flags);
            defer w.close();
            try w.execNoArgs("create table t(id integer)");
        }

        const r = try zqlite.open(ro_db, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
        defer r.close();

        // A read still works.
        const read_ok = if (r.row("select count(*) from t", .{})) |maybe| blk: {
            if (maybe) |row| row.deinit();
            break :blk "reads";
        } else |_| "cannot read";
        check("6a. a read-only connection", "reads", read_ok);

        // A write does not, and the error names why.
        const wrote = r.execNoArgs("insert into t(id) values (1)");
        const name = if (wrote) "no error" else |err| @errorName(err);
        // The name matters: this is what the Wire maps, and guessing it wrong
        // is how a refusal becomes a `QueryFailed` with the reason thrown away.
        check("6b. a write down a read-only connection", "ReadOnly", name);
    }

    // 6c. **The read-only flag does not survive `mode=memory`.** Found by a
    //     test failing rather than by reading: the same `OpenFlags.ReadOnly`
    //     that refuses a write on a file lets one through on a shared
    //     in-memory database, because SQLite's URI `mode=` parameter takes
    //     precedence over the flags passed to `sqlite3_open_v2`.
    //
    //     That matters because ADR 0074 leans on read-only readers as the
    //     backstop under routing `db.raw` by its first keyword. The backstop
    //     exists on a file and does not exist in memory — so it is one more
    //     thing a suite running entirely in memory would never test.
    {
        const url = "file:nilo-ro-mem?mode=memory&cache=shared";
        const w = try zqlite.open(url, uri_flags);
        defer w.close();
        try w.execNoArgs("create table t(id integer)");

        const r = try zqlite.open(url, zqlite.OpenFlags.ReadOnly |
            zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.Uri);
        defer r.close();

        const wrote = r.execNoArgs("insert into t(id) values (1)");
        const name = if (wrote) "no error" else |err| @errorName(err);
        check("6c. a write down a read-only connection to an in-memory database", "no error", name);
    }

    // 7. The per-connection memory ADR 0074 owes a number for. `cache_size`
    //    is negative for "this many KiB" and positive for "this many pages".
    {
        const conn = try zqlite.open(":memory:", flags);
        defer conn.close();

        const cache = (try conn.row("PRAGMA cache_size", .{})).?;
        defer cache.deinit();
        const page = (try conn.row("PRAGMA page_size", .{})).?;
        defer page.deinit();

        const cache_size = cache.int(0);
        const page_size = page.int(0);
        const bytes: i64 = if (cache_size < 0) -cache_size * 1024 else cache_size * page_size;
        std.debug.print(
            "7. page cache ceiling per connection\n  cache_size={d} page_size={d} -> {d} bytes ({d:.1} MiB)\n\n",
            .{ cache_size, page_size, bytes, @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0) },
        );
    }

    // 8. What a pool connection actually holds, which is the number ADR 0074
    //    says it owes and the one it got wrong on paper. `cache_size` is a
    //    **ceiling**: SQLite grows the page cache as pages are touched and
    //    never past that. So an idle reader and a reader that has scanned the
    //    table are two different numbers, and only measuring both says which
    //    one a deployment pays.
    {
        const readers = 8;

        try seed(pool_db, 50_000);
        const base = rssKib();

        var conns: [readers + 1]zqlite.Conn = undefined;
        conns[0] = try zqlite.open(pool_db, flags);
        for (conns[1..]) |*conn| {
            conn.* = try zqlite.open(pool_db, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
        }
        defer for (conns) |conn| conn.close();

        const idle = rssKib();

        // Touch every page through every reader, which is the worst case a
        // long-lived pool converges on rather than an unusual one.
        for (conns[1..]) |conn| {
            const r = (try conn.row("select sum(n) from t", .{})).?;
            r.deinit();
        }
        const warm = rssKib();

        std.debug.print(
            \\8. what a pool connection holds (1 writer + {d} readers, 50k rows)
            \\  baseline            {d} KiB
            \\  opened, idle        {d} KiB  ({d} KiB total, {d} KiB per connection)
            \\  after a full scan   {d} KiB  ({d} KiB total, {d} KiB per connection)
            \\  the 2 MiB from check 7 is a ceiling, not an allocation
            \\
            \\
        , .{
            readers,
            base,
            idle,       idle - base,          @divTrunc(idle - base, readers + 1),
            warm,       warm - base,          @divTrunc(warm - base, readers + 1),
        });
    }

    std.debug.print("{d} failing check(s)\n", .{failures});
    if (failures != 0) std.process.exit(1);
}

/// Resident set size, the same figure `bench/mem.py` reads for an HTTP
/// connection — so the two numbers can be put next to each other.
fn rssKib() i64 {
    var buf: [4096]u8 = undefined;
    const fd = std.os.linux.open("/proc/self/status", .{ .ACCMODE = .RDONLY }, 0);
    const n = std.os.linux.read(@intCast(fd), &buf, buf.len);
    defer _ = std.os.linux.close(@intCast(fd));
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "VmRSS:")) continue;
        var fields = std.mem.tokenizeAny(u8, line["VmRSS:".len..], " \t");
        return std.fmt.parseInt(i64, fields.next().?, 10) catch 0;
    }
    return 0;
}

/// One reader, one `cache_size`, three full scans. Run under `strace -c` and
/// compare `pread64` counts: that is what shrinking a reader's page cache
/// actually costs, in the only unit this box can be trusted to report.
fn scan(cache_kib: i64, points: bool) !void {
    var buf: [64]u8 = undefined;
    const conn = try zqlite.open(pool_db, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try conn.execNoArgs(try std.fmt.bufPrintZ(&buf, "pragma cache_size = -{d}", .{cache_kib}));

    if (points) {
        // The shape `bench/result/sql.md` actually measures: a primary-key
        // lookup, over and over, over a small hot range. This is where a page
        // cache is supposed to earn its memory, and a full scan is where it
        // cannot.
        var i: usize = 0;
        while (i < 5_000) : (i += 1) {
            const id: i64 = @intCast((i % 200) + 1);
            const r = (try conn.row("select n from t where id = ?1", .{id})).?;
            r.deinit();
        }
    } else {
        var pass: usize = 0;
        while (pass < 3) : (pass += 1) {
            const r = (try conn.row("select sum(n) from t", .{})).?;
            r.deinit();
        }
    }
    std.debug.print("cache_size = -{d} KiB, rss {d} KiB\n", .{ cache_kib, rssKib() });
}

fn seed(path: [*:0]const u8, rows: usize) !void {
    const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try conn.execNoArgs("pragma journal_mode = wal");
    try conn.execNoArgs("drop table if exists t");
    try conn.execNoArgs("create table t(id integer primary key, n integer, s text)");
    try conn.transaction();
    var i: usize = 0;
    while (i < rows) : (i += 1) {
        try conn.exec("insert into t(n, s) values (?1, ?2)", .{ @as(i64, @intCast(i)), "a row of text long enough to occupy a page or two" });
    }
    try conn.commit();
}
