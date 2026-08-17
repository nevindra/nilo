//! What `nilo_sql` costs over the driver it sits on, measured against a clock
//! that will not hold still.
//!
//! This box drifts up to 8% over a few minutes. The number this program exists
//! to report — the typed layer's cost — is about **100 ns on a 26 µs
//! operation**, which is 0.4%. Measuring one arm's rounds and then the other's
//! would put twenty parts of drift on top of one part of signal and produce a
//! table that looks clean and says nothing.
//!
//! So the two arms interleave **inside one process**: a block of `nilo_sql`,
//! a block of raw pg.zig, a block of `nilo_sql`, and so on, with the order
//! flipped on odd blocks so neither arm always runs on the warm half. Drift
//! lands on both arms of a pair equally and cancels in the subtraction, which
//! is the quantity being reported anyway. `bench/sql.zig` makes the same move
//! for prepared-versus-not, and that is why its 0.4-point agreement held up.
//!
//! Per-block figures are printed raw rather than averaged here. The statistics
//! belong in `ops.py`, where every candidate's blocks are in one place and a
//! margin narrower than its own spread can be reported as what it is — not a
//! ranking that will not survive the next run.
//!
//! ```
//! DATABASE_URL=postgres://nilo:nilo@localhost:5433/nilo ./zig-out/bin/zigsql-ops
//! ```

const std = @import("std");
const pg = @import("pg");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const table = "nilo_compare_people";
const wide_table = "nilo_compare_wide";
const write_table = "nilo_compare_writes";
const update_table = "nilo_compare_updates";
const delete_table = "nilo_compare_deletes";

/// 2026-01-01T00:00:00Z. Every `created_at` the write shapes store is this plus
/// a whole number of seconds, so the checksum four languages have to agree
/// about never depends on when the benchmark ran.
const epoch_base_s: i64 = 1_767_225_600;
const four_cols = "\"id\", \"email\", \"age\", \"created_at\"";

/// The Row, and the same four columns every other candidate declares — one
/// integer key, one text that has to be copied, one narrow integer and one
/// timestamp. Four types rather than one, because a benchmark over `id` alone
/// measures a protocol and not a mapper.
const Person = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

    id: i64,
    email: nilo.Str,
    age: i32,
    created_at: sql.Timestamp,
};

/// The statements the raw arm sends, written out rather than taken from the
/// module: this arm is the control, and importing the text it is being
/// compared against would make the control a copy of the thing.
const key_sql = "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"" ++ table ++
    "\" WHERE \"id\" = $1 LIMIT 1";
const page_sql = "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"" ++ table ++
    "\" WHERE \"age\" > $1 AND \"email\" LIKE $2 ORDER BY \"created_at\" DESC, \"id\" ASC LIMIT 20";
const scan_sql = "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"" ++ table ++ "\"";
const empty_sql = "SELECT 1";

/// Twenty columns, named in the order the Row declares them so the raw arm
/// reads them by the same index `nilo_sql` does.
const wide_cols = "\"id\", \"t1\", \"t2\", \"t3\", \"t4\", \"t5\", \"t6\", \"t7\", " ++
    "\"n1\", \"n2\", \"n3\", \"n4\", \"n5\", \"n6\", " ++
    "\"d1\", \"d2\", \"d3\", \"d4\", \"b1\", \"b2\"";
const wide_key_sql = "SELECT " ++ wide_cols ++ " FROM \"" ++ wide_table ++
    "\" WHERE \"id\" = $1 LIMIT 1";
const wide_scan_sql = "SELECT " ++ wide_cols ++ " FROM \"" ++ wide_table ++ "\"";

const insert_sql = "INSERT INTO \"" ++ write_table ++ "\" (" ++ four_cols ++
    ") VALUES ($1, $2, $3, $4) RETURNING " ++ four_cols;
/// One array per column, `unnest` on the server — the shape `insertMany`
/// compiles to (ADR 0053), written out here so the control sends the same
/// statement rather than a hand-rolled multi-VALUES that would be a different
/// benchmark.
const batch_sql = "INSERT INTO \"" ++ write_table ++ "\" (" ++ four_cols ++
    ") SELECT * FROM unnest($1::bigint[], $2::text[], $3::int[], $4::timestamptz[])" ++
    " RETURNING " ++ four_cols;
const update_sql = "UPDATE \"" ++ update_table ++ "\" SET \"age\" = $1 WHERE \"id\" = $2" ++
    " RETURNING " ++ four_cols;
const delete_sql = "DELETE FROM \"" ++ delete_table ++ "\" WHERE \"id\" = $1" ++
    " RETURNING " ++ four_cols;
const tx_find_sql = "SELECT " ++ four_cols ++ " FROM \"" ++ table ++
    "\" WHERE \"id\" = $1 LIMIT 1";

const batch_rows = 100;

const Shape = enum {
    /// The floor: a round trip with nothing to decode. Raw arm only — there is
    /// no ORM in `SELECT 1`, and putting one there would measure `db.raw`,
    /// which is never prepared and would be a different question.
    empty,
    /// One row. What a request usually does, and where decode cost is at its
    /// smallest against the round trip.
    key,
    /// Twenty rows with a sort. A page of a list.
    scan_page,
    /// A thousand rows. Where a mapper that decodes by reflection stops hiding
    /// behind the socket.
    scan_all,
    /// One row of twenty columns. The narrow shapes vary the row count and
    /// hold the width at four; these two hold the row count and vary the
    /// width, which is the axis a wide entity table actually moves along.
    wide_key,
    /// A thousand rows of twenty columns — twenty thousand values in one
    /// answer. A mapper that resolves a column by name at run time pays here
    /// for every one of them.
    wide_all,
    /// One row stored, and the stored row read back. Everything above this
    /// line reads; `bench/result/sql.md` closes by saying every table in it
    /// does, and these five are that gap.
    insert_one,
    /// A hundred rows in one statement.
    batch,
    /// One row changed by key, and the changed row read back.
    update_one,
    /// One row removed by key, and the removed row read back.
    delete_one,
    /// `BEGIN`, a read, a write, `COMMIT`. Four statements where the other
    /// shapes send one, so this is where a library's per-statement overhead
    /// stops being amortised by the round trip.
    tx,

    fn rounds(self: Shape) usize {
        return switch (self) {
            .empty, .key => 200,
            .scan_page => 100,
            .scan_all => 20,
            .wide_key => 200,
            .wide_all => 10,
            .insert_one, .update_one, .delete_one => 50,
            .batch => 10,
            .tx => 50,
        };
    }

    fn writes(self: Shape) bool {
        return switch (self) {
            .insert_one, .batch, .update_one, .delete_one, .tx => true,
            else => false,
        };
    }

    /// Rows a single operation decodes. The divisor that turns a difference
    /// between two arms into a per-row cost — and the reason `scan_all` is the
    /// precise instrument here while `key` is the honest one. A mapper costing
    /// 1 ns a row is invisible under a 26 µs round trip at one row and is
    /// 1 µs of a 126 µs operation at a thousand.
    fn rows(self: Shape) usize {
        return switch (self) {
            .empty => 0,
            .key, .wide_key, .insert_one, .update_one, .delete_one => 1,
            .scan_page => 20,
            .scan_all, .wide_all => 1000,
            .batch => batch_rows,
            // A read and a write, both one row.
            .tx => 2,
        };
    }

    /// Columns a row carries. `rows × columns` is the number of values a
    /// mapper has to place, and it is the divisor that makes `wide_all`
    /// comparable with `scan_all` rather than merely bigger than it.
    fn columns(self: Shape) usize {
        return switch (self) {
            .empty => 0,
            .wide_key, .wide_all => 20,
            else => 4,
        };
    }

    fn label(self: Shape) []const u8 {
        return switch (self) {
            .empty => "empty",
            .key => "key",
            .scan_page => "page",
            .scan_all => "scan",
            .wide_key => "wide",
            .wide_all => "wide_scan",
            .insert_one => "insert",
            .batch => "batch",
            .update_one => "update",
            .delete_one => "delete",
            .tx => "tx",
        };
    }
};

/// The row a write shape stores, and the values it stores. Derived from the
/// row's own id so that two arms writing "the same" row write the same bytes,
/// and so the checksum does not move between runs.
fn writtenEmail(buf: []u8, id: i64) []const u8 {
    return std.fmt.bufPrint(buf, "w{d}@example.dev", .{id}) catch unreachable;
}

fn writtenAge(id: i64) i32 {
    return @intCast(20 + @mod(id, 50));
}

fn writtenMicros(id: i64) i64 {
    return (epoch_base_s + id - 1) * std.time.us_per_s;
}

const blocks = 300;

/// Warm-up runs over **every** shape before any shape is timed, and that
/// ordering is not cosmetic. The first version warmed each shape immediately
/// before measuring it, and the shape that happened to run first read 32 µs in
/// its opening blocks and 24.6 µs in its closing ones — a 23% slide that was
/// the CPU coming up to clock and Postgres filling its caches, charged
/// entirely to whichever measurement drew the short straw.
const warmup_blocks = 20;

/// What a decoded row is worth, summed over every row every arm reads.
///
/// This is the harness's version of `drive.py`'s byte-for-byte payload rule.
/// A candidate that decodes lazily, hands back a cursor, or reads the key
/// column and skips the rest is faster for a reason that is not a merit, and
/// the only way to catch it is to demand a number that cannot be produced
/// without touching all four fields.
fn tally(id: i64, email: []const u8, age: i32, micros: i64) i64 {
    return id + age + @as(i64, @intCast(email.len)) + @divFloor(micros, std.time.us_per_s);
}

/// Twenty columns: seven text, six integer, four timestamp, two boolean, and
/// the key. No floating point anywhere in the fixture, because a checksum four
/// runtimes have to agree about bit for bit is not the place to find out how
/// each of them rounds.
const Wide = struct {
    pub const nilo_table = .{ .name = wide_table, .key = .id };

    id: i64,
    t1: nilo.Str,
    t2: nilo.Str,
    t3: nilo.Str,
    t4: nilo.Str,
    t5: nilo.Str,
    t6: nilo.Str,
    t7: nilo.Str,
    n1: i32,
    n2: i32,
    n3: i32,
    n4: i32,
    n5: i32,
    n6: i64,
    d1: sql.Timestamp,
    d2: sql.Timestamp,
    d3: sql.Timestamp,
    d4: sql.Timestamp,
    b1: bool,
    b2: bool,
};

/// Three Rows over three tables with identical columns, because the shapes
/// must not disturb each other: `insert` truncates its table, `delete` empties
/// its own, and `update` overwrites in place and so never needs reseeding.
/// One shared table would have made each write shape a measurement of
/// whichever ran before it.
const Written = struct {
    pub const nilo_table = .{ .name = write_table, .key = .id };
    id: i64,
    email: nilo.Str,
    age: i32,
    created_at: sql.Timestamp,
};

const Updated = struct {
    pub const nilo_table = .{ .name = update_table, .key = .id };
    id: i64,
    email: nilo.Str,
    age: i32,
    created_at: sql.Timestamp,
};

const Deleted = struct {
    pub const nilo_table = .{ .name = delete_table, .key = .id };
    id: i64,
    email: nilo.Str,
    age: i32,
    created_at: sql.Timestamp,
};

/// The element type `insertMany` compiles its statement from (ADR 0053).
const Line = struct {
    id: i64,
    email: []const u8,
    age: i32,
    created_at: sql.Timestamp,
};

fn tallyWide(w: Wide) i64 {
    return w.id + w.n1 + w.n2 + w.n3 + w.n4 + w.n5 + w.n6 +
        @as(i64, @intCast(w.t1.len() + w.t2.len() + w.t3.len() + w.t4.len() +
            w.t5.len() + w.t6.len() + w.t7.len())) +
        w.d1.seconds() + w.d2.seconds() + w.d3.seconds() + w.d4.seconds() +
        @intFromBool(w.b1) + @intFromBool(w.b2);
}

/// Which arm a block belongs to. An enum rather than a name compared at run
/// time, so the two call sites cannot drift apart.
const Which = enum { raw, nilo };

const Arm = struct {
    name: []const u8,
    /// ns per operation, one entry per block.
    ns: [blocks]u64 = undefined,
    checksum: i64 = 0,
    used: usize = 0,

    fn record(self: *Arm, b: Block) void {
        self.ns[self.used] = b.ns;
        self.checksum = b.checksum;
        self.used += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const url = init.minimal.environ.getPosix("DATABASE_URL") orelse {
        std.debug.print(
            "zigsql-ops needs a database.\n" ++
                "  DATABASE_URL=postgres://… ./zig-out/bin/zigsql-ops\n" ++
                "  then apply bench/compare-sql/fixture.sql\n",
            .{},
        );
        return error.NoDatabaseUrl;
    };

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // One connection each, dialled up front. A pool would measure queueing,
    // which is `drive.py`'s question rather than this one.
    const pool = try pg.Pool.initUri(io, gpa, try std.Uri.parse(url), .{
        .size = 1,
        .connect_on_init_count = 1,
    });
    defer pool.deinit();
    var conn = try pool.acquire();
    defer conn.release();

    var db = sql.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .prepared = true });
    defer db.deinit();
    try db.nilo_start(io);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Knobs for the syscall census rather than for the benchmark. Counting
    // packets per query under `strace` needs a run small enough to trace and a
    // warm-up of zero, and it needs two runs differing by one block so the
    // connection handshake subtracts out. Left at their defaults these change
    // nothing.
    const n_blocks = envUsize(init, "OPS_BLOCKS", blocks);
    const n_warmup = envUsize(init, "OPS_WARMUP", warmup_blocks);
    const only = init.minimal.environ.getPosix("OPS_SHAPES");

    // `OPS_ARMS=raw` or `OPS_ARMS=nilo` runs one arm and not the other, which
    // is a census knob and never a benchmark one: a single arm is measured
    // against the clock rather than against its pair, so the drift the
    // interleaving exists to cancel comes straight back. It is here for one
    // question. `insert` and `delete` cost nilo_sql ~+3 µs over raw pg.zig
    // while its read path costs nothing measurable, and ~3 µs is the size of
    // one unix-socket round trip. Counting packets settles whether that is
    // what it is — and `strace` cannot tell two interleaved arms apart.
    const arms = init.minimal.environ.getPosix("OPS_ARMS");
    const want_raw = arms == null or std.mem.eql(u8, arms.?, "raw");
    const want_nilo = arms == null or std.mem.eql(u8, arms.?, "nilo");
    if (arms != null and !want_raw and !want_nilo) {
        std.debug.print("nilo: OPS_ARMS is 'raw' or 'nilo', not '{s}'\n", .{arms.?});
        return error.UnknownArm;
    }

    std.debug.print("zig — nilo_sql against raw pg.zig, {d} interleaved blocks\n", .{blocks});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"language\":\"zig\",\"shapes\":{");

    const shapes = [_]Shape{
        .empty,      .key,        .scan_page,  .scan_all,    .wide_key, .wide_all,
        .insert_one, .batch,      .update_one, .delete_one,  .tx,
    };

    // Every shape, both arms, nothing timed. Two things are being settled
    // here and they are worth naming separately. The prepared-statement cache
    // has to be filled, or the first blocks measure a Parse and a Describe.
    // And the *machine* has to be at clock: see `warmup_blocks` above for the
    // 23% slide this exists to keep out of whichever shape runs first.
    std.debug.print("  warming {d} blocks a shape…\n", .{n_warmup});
    for (shapes) |shape| {
        if (!wanted(only, shape)) continue;
        var w: usize = 0;
        while (w < n_warmup) : (w += 1) {
            if (want_raw) {
                try prepareWrites(conn, shape, shape.rounds());
                _ = try rawBlock(&arena, conn, shape, shape.rounds());
            }
            if (want_nilo and shape != .empty) {
                try prepareWrites(conn, shape, shape.rounds());
                _ = try niloBlock(&run, &db, shape, shape.rounds());
            }
        }
    }

    var first = true;
    for (shapes) |shape| {
        if (!wanted(only, shape)) continue;
        var nilo_arm: Arm = .{ .name = "nilo_sql" };
        var raw_arm: Arm = .{ .name = "pgzig" };

        var b: usize = 0;
        while (b < n_blocks) : (b += 1) {
            // Flip the order on odd blocks. Whichever arm runs first in a pair
            // pays for whatever the other one left in the caches, and always
            // giving that position to the same arm is a bias that averages to
            // a constant rather than to zero.
            const order: [2]Which = if (b % 2 == 0) .{ .raw, .nilo } else .{ .nilo, .raw };
            for (order) |which| switch (which) {
                .raw => {
                    if (!want_raw) continue;
                    try prepareWrites(conn, shape, shape.rounds());
                    const r = try rawBlock(&arena, conn, shape, shape.rounds());
                    raw_arm.record(r);
                },
                .nilo => {
                    if (!want_nilo or shape == .empty) continue;
                    try prepareWrites(conn, shape, shape.rounds());
                    const r = try niloBlock(&run, &db, shape, shape.rounds());
                    nilo_arm.record(r);
                },
            };
        }

        if (!first) try out.append(gpa, ',');
        first = false;
        try writeShape(gpa, &out, shape, &raw_arm, &nilo_arm);

        const raw_mid = median(raw_arm.ns[0..raw_arm.used]);
        if (shape == .empty or !want_nilo) {
            std.debug.print("  {s:<9} pgzig {d:>9} ns\n", .{ shape.label(), raw_mid });
        } else if (!want_raw) {
            std.debug.print("  {s:<9} nilo_sql {d:>9} ns\n", .{
                shape.label(),
                median(nilo_arm.ns[0..nilo_arm.used]),
            });
        } else {
            std.debug.print("  {s:<9} pgzig {d:>9} ns   nilo_sql {d:>9} ns\n", .{
                shape.label(),
                raw_mid,
                median(nilo_arm.ns[0..nilo_arm.used]),
            });
        }
    }

    try out.appendSlice(gpa, "},\"peak_rss_kb\":");
    try out.print(gpa, "{d}", .{peakRssKb()});
    try out.appendSlice(gpa, "}");

    std.debug.print("RESULT {s}\n", .{out.items});
}

const Block = struct { ns: u64, checksum: i64 };

/// Put the write tables back the way a timed block expects to find them.
/// Outside the timer, and run before **each arm's** block rather than before
/// each pair — two arms inserting the same primary keys into a table only one
/// of them emptied is a unique-violation, not a benchmark.
fn prepareWrites(conn: *pg.Conn, shape: Shape, count: usize) !void {
    switch (shape) {
        .insert_one, .batch => {
            _ = try conn.exec("TRUNCATE \"" ++ write_table ++ "\"", .{});
        },
        .delete_one => {
            _ = try conn.exec("TRUNCATE \"" ++ delete_table ++ "\"", .{});
            // Exactly the rows the block will remove, and no more: seeding a
            // thousand to delete fifty would put an index of a different size
            // under every measurement.
            _ = try conn.exec(
                "INSERT INTO \"" ++ delete_table ++ "\" (" ++ four_cols ++ ")" ++
                    " SELECT g, 'w' || g || '@example.dev', 20 + (g % 50)," ++
                    " to_timestamp($2::bigint + g - 1)" ++
                    " FROM generate_series(1, $1::int) g",
                .{ @as(i32, @intCast(count)), epoch_base_s },
            );
        },
        else => {},
    }
}

/// The control arm: pg.zig with nothing above it, doing the same decoding and
/// the same copy into an arena that `nilo_sql` does. Anything this arm skips
/// would show up as the typed layer's cost and belong to neither.
fn rawBlock(
    arena: *std.heap.ArenaAllocator,
    conn: *pg.Conn,
    shape: Shape,
    count: usize,
) !Block {
    if (shape.writes()) return rawWriteBlock(arena, conn, shape, count);

    var sum: i64 = 0;
    const started = monotonicNanos();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();
        const opts: pg.Conn.QueryOpts = .{ .allocator = alloc, .cache_name = cacheName(shape) };

        var result = switch (shape) {
            .empty => try conn.queryOpts(empty_sql, .{}, opts),
            .key => try conn.queryOpts(key_sql, .{@as(i64, @intCast((i % 1000) + 1))}, opts),
            .scan_page => try conn.queryOpts(page_sql, .{ @as(i32, 20), "p%" }, opts),
            .scan_all => try conn.queryOpts(scan_sql, .{}, opts),
            .wide_key => try conn.queryOpts(
                wide_key_sql,
                .{@as(i64, @intCast((i % 1000) + 1))},
                opts,
            ),
            .wide_all => try conn.queryOpts(wide_scan_sql, .{}, opts),
            // The write shapes never reach here: `rawBlock` hands them to
            // `rawWriteBlock` on its first line.
            else => unreachable,
        };
        defer result.deinit();

        while (try result.next()) |row| {
            switch (shape) {
                .empty => {},
                .key, .scan_page, .scan_all => {
                    // The same four reads `db.zig` makes, and the same copy: a
                    // `Str` keeps its bytes in the Scope's arena, so an arm
                    // that pointed at the driver's buffer instead would be
                    // doing less work.
                    const id = try row.get(i64, 0);
                    const email = try row.get([]const u8, 1);
                    const age = try row.get(i32, 2);
                    const micros = try row.get(i64, 3);
                    const kept = try alloc.dupe(u8, email);
                    sum += tally(id, kept, age, micros);
                },
                .wide_key, .wide_all => {
                    // Twenty reads and seven copies, written out. Spelling all
                    // of it is the point: this is what the typed layer is
                    // being compared against, and a control that looped over
                    // an array of column indices would be a mapper of its own.
                    var w: i64 = try row.get(i64, 0);
                    inline for (1..8) |c| {
                        w += @intCast((try alloc.dupe(u8, try row.get([]const u8, c))).len);
                    }
                    inline for (8..13) |c| w += try row.get(i32, c);
                    w += try row.get(i64, 13);
                    inline for (14..18) |c| {
                        w += @divFloor(try row.get(i64, c), std.time.us_per_s);
                    }
                    w += @intFromBool(try row.get(bool, 18));
                    w += @intFromBool(try row.get(bool, 19));
                    sum += w;
                },
                // The write shapes never reach here: `rawBlock` hands them to
                // `rawWriteBlock` on its first line.
                else => unreachable,
            }
        }
        try result.drain();
    }
    const elapsed = monotonicNanos() - started;
    return .{ .ns = @intCast(@divTrunc(elapsed, @as(i128, @intCast(count)))), .checksum = sum };
}

/// The control's write path. Four statements rather than four query shapes,
/// and the same rows read back through `RETURNING` that the typed arm reads —
/// a control that discarded the stored row would be doing less work.
fn rawWriteBlock(
    arena: *std.heap.ArenaAllocator,
    conn: *pg.Conn,
    shape: Shape,
    count: usize,
) !Block {
    var sum: i64 = 0;
    var email_buf: [64]u8 = undefined;

    var ids: [batch_rows]i64 = undefined;
    var emails: [batch_rows][]const u8 = undefined;
    var email_store: [batch_rows][32]u8 = undefined;
    var ages: [batch_rows]i32 = undefined;
    var stamps: [batch_rows]i64 = undefined;

    const started = monotonicNanos();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();
        const opts: pg.Conn.QueryOpts = .{ .allocator = alloc, .cache_name = cacheName(shape) };
        const id: i64 = @intCast(i + 1);

        switch (shape) {
            .insert_one => {
                var r = try conn.queryOpts(insert_sql, .{
                    id,
                    writtenEmail(&email_buf, id),
                    writtenAge(id),
                    writtenMicros(id),
                }, opts);
                defer r.deinit();
                sum += try drainFour(r, alloc);
                try r.drain();
            },
            .batch => {
                for (0..batch_rows) |j| {
                    const rid: i64 = @intCast(i * batch_rows + j + 1);
                    ids[j] = rid;
                    emails[j] = writtenEmail(&email_store[j], rid);
                    ages[j] = writtenAge(rid);
                    stamps[j] = writtenMicros(rid);
                }
                var r = try conn.queryOpts(batch_sql, .{
                    ids[0..batch_rows],
                    emails[0..batch_rows],
                    ages[0..batch_rows],
                    stamps[0..batch_rows],
                }, opts);
                defer r.deinit();
                sum += try drainFour(r, alloc);
                try r.drain();
            },
            .update_one => {
                const key: i64 = @intCast((i % 1000) + 1);
                var r = try conn.queryOpts(update_sql, .{ writtenAge(key), key }, opts);
                defer r.deinit();
                sum += try drainFour(r, alloc);
                try r.drain();
            },
            .delete_one => {
                var r = try conn.queryOpts(delete_sql, .{id}, opts);
                defer r.deinit();
                sum += try drainFour(r, alloc);
                try r.drain();
            },
            .tx => {
                const key: i64 = @intCast((i % 1000) + 1);
                _ = try conn.exec("BEGIN", .{});
                var r1 = try conn.queryOpts(tx_find_sql, .{key}, .{
                    .allocator = alloc,
                    .cache_name = "nilo_cmp_tx_find",
                });
                sum += try drainFour(r1, alloc);
                try r1.drain();
                r1.deinit();
                var r2 = try conn.queryOpts(update_sql, .{ writtenAge(key), key }, .{
                    .allocator = alloc,
                    .cache_name = "nilo_cmp_tx_upd",
                });
                sum += try drainFour(r2, alloc);
                try r2.drain();
                r2.deinit();
                _ = try conn.exec("COMMIT", .{});
            },
            else => unreachable,
        }
    }
    const elapsed = monotonicNanos() - started;
    return .{ .ns = @intCast(@divTrunc(elapsed, @as(i128, @intCast(count)))), .checksum = sum };
}

/// Read every row of a four-column result the way the typed arm reads it,
/// including the copy of the text into the arena.
fn drainFour(r: *pg.Result, alloc: std.mem.Allocator) !i64 {
    var sum: i64 = 0;
    while (try r.next()) |row| {
        const id = try row.get(i64, 0);
        const email = try row.get([]const u8, 1);
        const age = try row.get(i32, 2);
        const micros = try row.get(i64, 3);
        const kept = try alloc.dupe(u8, email);
        sum += tally(id, kept, age, micros);
    }
    return sum;
}

/// The subject: the same rows through `db.find` and `db.select`, which build a
/// parameter tuple, fill a Row and keep its text.
fn niloBlock(run: *nilo.Run, db: anytype, shape: Shape, count: usize) !Block {
    var sum: i64 = 0;
    const started = monotonicNanos();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        switch (shape) {
            .empty => unreachable,
            .key => {
                if (try db.find(Person, run, @as(i64, @intCast((i % 1000) + 1)))) |p| {
                    sum += tally(p.id, p.email.view(), p.age, p.created_at.micros);
                }
            },
            .scan_page => {
                const rows = try db.select(Person, run, .{
                    .where = .{ .age = .{ .gt = @as(i32, 20) }, .email = .{ .like = "p%" } },
                    .order = .{ .created_at = .desc, .id = .asc },
                    .limit = 20,
                });
                for (rows) |p| sum += tally(p.id, p.email.view(), p.age, p.created_at.micros);
            },
            .scan_all => {
                const rows = try db.select(Person, run, .{});
                for (rows) |p| sum += tally(p.id, p.email.view(), p.age, p.created_at.micros);
            },
            .wide_key => {
                if (try db.find(Wide, run, @as(i64, @intCast((i % 1000) + 1)))) |w| {
                    sum += tallyWide(w);
                }
            },
            .wide_all => {
                const rows = try db.select(Wide, run, .{});
                for (rows) |w| sum += tallyWide(w);
            },
            .insert_one => {
                const id: i64 = @intCast(i + 1);
                var buf: [64]u8 = undefined;
                const w = try db.insert(Written, run, .{
                    .id = id,
                    .email = writtenEmail(&buf, id),
                    .age = writtenAge(id),
                    .created_at = sql.Timestamp{ .micros = writtenMicros(id) },
                });
                sum += tally(w.id, w.email.view(), w.age, w.created_at.micros);
            },
            .batch => {
                var lines: [batch_rows]Line = undefined;
                var store: [batch_rows][32]u8 = undefined;
                for (0..batch_rows) |j| {
                    const rid: i64 = @intCast(i * batch_rows + j + 1);
                    lines[j] = .{
                        .id = rid,
                        .email = writtenEmail(&store[j], rid),
                        .age = writtenAge(rid),
                        .created_at = .{ .micros = writtenMicros(rid) },
                    };
                }
                const stored = try db.insertMany(Written, run, lines[0..batch_rows]);
                for (stored) |w| sum += tally(w.id, w.email.view(), w.age, w.created_at.micros);
            },
            .update_one => {
                const key: i64 = @intCast((i % 1000) + 1);
                const rows = try db.updateReturning(Updated, run, .{
                    .set = .{ .age = writtenAge(key) },
                    .where = .{ .id = key },
                });
                for (rows) |u| sum += tally(u.id, u.email.view(), u.age, u.created_at.micros);
            },
            .delete_one => {
                const id: i64 = @intCast(i + 1);
                const rows = try db.deleteReturning(Deleted, run, .{ .where = .{ .id = id } });
                for (rows) |d| sum += tally(d.id, d.email.view(), d.age, d.created_at.micros);
            },
            .tx => {
                const key: i64 = @intCast((i % 1000) + 1);
                var tx = try db.begin(run, .{});
                defer tx.deinit();
                if (try tx.find(Person, run, key)) |p| {
                    sum += tally(p.id, p.email.view(), p.age, p.created_at.micros);
                }
                const rows = try tx.updateReturning(Updated, run, .{
                    .set = .{ .age = writtenAge(key) },
                    .where = .{ .id = key },
                });
                for (rows) |u| sum += tally(u.id, u.email.view(), u.age, u.created_at.micros);
                try tx.commit();
            },
        }
        run.reset();
    }
    const elapsed = monotonicNanos() - started;
    return .{ .ns = @intCast(@divTrunc(elapsed, @as(i128, @intCast(count)))), .checksum = sum };
}

/// One name per statement, and never shared. Reusing a name for two statements
/// makes pg.zig re-bind against the *cached* describe without looking at the
/// SQL again — `bench/sql.zig` found that the hard way and it cost an
/// afternoon.
fn cacheName(shape: Shape) []const u8 {
    return switch (shape) {
        .empty => "nilo_cmp_empty",
        .key => "nilo_cmp_key",
        .scan_page => "nilo_cmp_page",
        .scan_all => "nilo_cmp_scan",
        .wide_key => "nilo_cmp_wide_key",
        .wide_all => "nilo_cmp_wide_scan",
        .insert_one => "nilo_cmp_insert",
        .batch => "nilo_cmp_batch",
        .update_one => "nilo_cmp_update",
        .delete_one => "nilo_cmp_delete",
        .tx => "nilo_cmp_tx",
    };
}

fn writeShape(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    shape: Shape,
    raw_arm: *const Arm,
    nilo_arm: *const Arm,
) !void {
    try out.print(gpa, "\"{s}\":{{\"rows\":{d},\"columns\":{d},\"rounds\":{d},\"arms\":{{", .{
        shape.label(),
        shape.rows(),
        shape.columns(),
        shape.rounds(),
    });
    try writeArm(gpa, out, raw_arm);
    if (shape != .empty) {
        try out.append(gpa, ',');
        try writeArm(gpa, out, nilo_arm);
    }
    try out.appendSlice(gpa, "}}");
}

fn writeArm(gpa: std.mem.Allocator, out: *std.ArrayList(u8), arm: *const Arm) !void {
    try out.print(gpa, "\"{s}\":{{\"checksum\":{d},\"blocks\":[", .{ arm.name, arm.checksum });
    for (arm.ns[0..arm.used], 0..) |n, i| {
        if (i != 0) try out.append(gpa, ',');
        try out.print(gpa, "{d}", .{n});
    }
    try out.appendSlice(gpa, "]}");
}

fn envUsize(init: std.process.Init, name: []const u8, default: usize) usize {
    const text = init.minimal.environ.getPosix(name) orelse return default;
    return std.fmt.parseInt(usize, text, 10) catch default;
}

/// `OPS_SHAPES=empty,key` restricts the run. Absent means every shape, which
/// is what the benchmark itself always wants.
fn wanted(only: ?[]const u8, shape: Shape) bool {
    const list = only orelse return true;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |name| {
        if (std.mem.eql(u8, std.mem.trim(u8, name, " "), shape.label())) return true;
    }
    return false;
}

fn median(xs: []const u64) u64 {
    if (xs.len == 0) return 0;
    var copy: [blocks]u64 = undefined;
    @memcpy(copy[0..xs.len], xs);
    std.mem.sort(u64, copy[0..xs.len], {}, std.sort.asc(u64));
    return copy[xs.len / 2];
}

/// The high-water mark rather than the current size: a benchmark that reset an
/// arena before it was asked would otherwise look thriftier than it was.
fn peakRssKb() u64 {
    var buf: [4096]u8 = undefined;
    // `open`/`read` rather than `std.Io.Dir`: this is one line of /proc and
    // going through the Io interface would mean threading it into a function
    // that has nothing else to do with the event loop.
    const fd = std.posix.openat(
        std.posix.AT.FDCWD,
        "/proc/self/status",
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch return 0;
    defer _ = std.posix.system.close(fd);
    const n = std.posix.read(fd, &buf) catch return 0;
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "VmHWM:")) continue;
        var fields = std.mem.tokenizeAny(u8, line["VmHWM:".len..], " \t");
        const digits = fields.next() orelse return 0;
        return std.fmt.parseInt(u64, digits, 10) catch 0;
    }
    return 0;
}

/// `CLOCK_MONOTONIC`, read the way `bench/sql.zig` reads its own — Zig 0.16 has
/// no `std.time.Timer`, and this program may not import Core.
fn monotonicNanos() i128 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
        .SUCCESS => {},
        else => unreachable,
    }
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
