//! Where `nilo.Idempotent` keeps its answers when more than one instance has
//! to agree: a table in the database the program already has
//! ([ADR 268](../docs/adr/268-an-answer-kept-for-a-retry-is-a-row-when-instances-share-a-database.md)).
//!
//! ```zig
//! const Replays = sql.Replays(Db, .{ .name = "orders", .ttl_s = 86_400, .max_bytes = 16 << 10 });
//!
//! try sql.migrate.createMissing(&db, &run, .{ .tables = &.{Replays.Row} });
//! var replays = Replays.open(&db);
//! try app.provide(&replays);
//!
//! fn placeOrder(key: nilo.Idempotent(Replays, .{ .by = account }), body: NewOrder, …) !nilo.Status(201, Order)
//! ```
//!
//! `nilo_http` names no store ([ADR 155](../docs/adr/155-a-request-answered-once-is-answered-the-same-way-again.md)),
//! and neither does this file name `nilo_http`: `Idempotent` asks its store
//! for six declarations by name, and this type has them. It differs from a
//! `nilo_cache` Space in one way the contract knows about, `takes_scope`: a
//! statement needs the request's Scope to allocate its answer in, so every
//! method takes one first, and a method can fail the way a database does.
//!
//! **The claim is atomic in the database, and never a read followed by a
//! write.** `putIfAbsentFor` is `INSERT … ON CONFLICT DO NOTHING`, and if the
//! key was taken, `UPDATE … WHERE <the row has expired>`: each statement
//! changes a row for exactly one of the instances that race for it, because the
//! primary key is where they meet and the loser re-reads what the winner
//! committed. A key somebody holds costs the second statement only when the
//! first answered no row, and neither writes anything then. Both databases take
//! the same statements; on SQLite there is one writer anyway
//! ([ADR 065](../docs/adr/065-one-writer-is-not-a-setting-it-is-the-database.md)).
//!
//! **A row lives until `expires_at`, and nothing reaps it.** A read ignores an
//! expired row and a claim writes over one, so a key that is used again costs
//! nothing, but a key that never comes back leaves its row. `sweep` deletes
//! them; call it from a scheduled job, the way `job.Table.sweep` is called.
//! The table is `space`, `slot`, `value`, `expires_at`; `space` is the
//! `name`, so two stores can share one table, and `Row` is what to give
//! `createMissing` or `db.checking`.
//!
//! **The clock is this instance's.** `expires_at` is written and compared in
//! microseconds of the wall clock of whichever instance asks, so two instances
//! whose clocks differ by a second disagree about a row's last second. The
//! marker's two minutes and an answer's day are both far wider than any skew
//! that NTP leaves.
//!
//! **The marker and the handler's own writes are two transactions.** A claim
//! that commits, then a handler whose database write rolls back, leaves the
//! marker to be released by `Idempotent` (a failure deletes it), and a
//! process that dies between them leaves it for `marker_ttl_s`. What this
//! cannot do is make the handler's write and the answer commit together; that
//! is the price of the store being a separate statement from the handler's
//! (ADR 268).

const std = @import("std");
const core = @import("nilo_core");
const types = @import("types.zig");

pub const Options = struct {
    /// Which store this is, in the table it shares with others. What
    /// `cache.Space`'s name is: it keeps one store's keys out of another's.
    name: []const u8,
    /// Seconds an answer is kept. Zero is until `sweep` deletes it, which for
    /// an idempotency key is rarely what is wanted.
    ttl_s: u32 = 0,
    /// The largest answer kept, as for a Space. A larger one is
    /// `error.TooLarge` and `Idempotent` sends it without keeping it.
    max_bytes: usize = 4096,
    /// The table. Two optimize modes of one test suite, or two programs that
    /// should not share a table, name another.
    table: []const u8 = "nilo_replays",
};

/// The longest key a store takes, in bytes: `by`, a separator and the
/// client's key (at most 255). A btree index entry in Postgres is bounded at
/// a third of a page, and a key this long is a bug in `.by`, so it is
/// `error.TooLarge` the way a key too long for a Space is.
pub const max_key = 1024;

/// What `expires_at` holds for an entry that does not expire, so that "still
/// good" is one comparison on both databases.
const forever = std.math.maxInt(i64);

pub fn Replays(comptime Db: type, comptime opts: Options) type {
    if (@typeInfo(Db) != .@"struct" or !@hasDecl(Db, "Dialect")) @compileError(
        "nilo: `sql.Replays(" ++ @typeName(Db) ++ ", …)` was given something that is not a `nilo_sql` Db.\n" ++
            "  `sql.Replays(sql.Db, .{ … })`, or `sql.Replays(sql.Sqlite(.{ … }), .{ … })`, or a `sql.Named(…)`.",
    );
    if (opts.name.len == 0) @compileError(
        "nilo: `sql.Replays` needs a `name`.\n" ++
            "  It is what keeps one store's keys out of another's in a table they share: " ++
            "`sql.Replays(Db, .{ .name = \"orders\", … })`.",
    );
    if (opts.table.len == 0) @compileError("nilo: `sql.Replays` was given an empty `table`.");
    if (opts.max_bytes == 0) @compileError(
        "nilo: the `sql.Replays` \"" ++ opts.name ++ "\" has a `max_bytes` of 0, so no answer could be kept in it.",
    );

    return struct {
        const Self = @This();

        db: *Db,

        /// Said so that `Idempotent` hands every call the request's Scope
        /// first, which a statement needs and a Space does not. A store
        /// without it is called the way a `cache.Space` is.
        pub const takes_scope = true;

        /// The largest answer this store keeps; `Idempotent` reads an
        /// answer back into an arena allocation of this size.
        pub const max_bytes: usize = opts.max_bytes;

        /// The table, for `createMissing` and `db.checking`. Nothing here
        /// creates it.
        pub const Row = struct {
            pub const nilo_table = .{
                .name = opts.table,
                .key = .{ .space, .slot },
                // The one lookup that is not by key is `sweep`'s.
                .index = .{.expires_at},
            };

            space: []const u8,
            /// `by`, a NUL and the client's key, so bytes rather than text:
            /// a NUL is not text in Postgres, and a header value need not be
            /// UTF-8.
            slot: types.Bytes,
            /// The encoded answer (`idempotent.encode`), or the marker.
            value: types.Bytes,
            /// Microseconds since the epoch, or the largest `i64` for an
            /// entry that does not expire.
            expires_at: i64,
        };

        pub fn open(db: *Db) Self {
            return .{ .db = db };
        }

        /// The claim: store `value` under `slot` for `ttl_s` seconds **only
        /// if nobody holds it**, and say whether it is now yours. An
        /// expired row is nobody's. Zero seconds is until `sweep`.
        ///
        /// Two statements, each atomic, and the second only when the first
        /// found the key taken. `INSERT … ON CONFLICT DO NOTHING` takes a
        /// free key, and there is no instant between "is it free" and "take
        /// it" for a second instance to be in; a key somebody holds answers
        /// no row **without writing anything**, which on Postgres is the
        /// difference between a read (44 µs) and a commit (1.6 ms) for the
        /// common case of a retry that finds its marker
        /// (`bench/result/sql.md` §27). The second statement takes a row that
        /// has run out: `UPDATE … WHERE expires_at <= now` changes the row
        /// for exactly one of the instances that reach it, because the loser
        /// re-reads the row after the winner commits and finds it live.
        pub fn putIfAbsentFor(self: *Self, scope: anytype, slot: []const u8, value: []const u8, ttl_s: u32) !bool {
            if (value.len > opts.max_bytes or slot.len > max_key) return error.TooLarge;
            const now = core.nowMicros();
            const until = expiry(now, ttl_s);
            const made = try self.db.insertOrIgnore(Row, scope, .{
                .space = opts.name,
                .slot = types.Bytes.of(slot),
                .value = types.Bytes.of(value),
                .expires_at = until,
            }, .{ .space, .slot });
            if (made != null) return true;
            const taken = try self.db.update(Row, scope, .{
                .set = .{ .value = types.Bytes.of(value), .expires_at = until },
                .where = .{ .space = opts.name, .slot = types.Bytes.of(slot), .expires_at = .{ .lte = now } },
            });
            return taken == 1;
        }

        /// Store `value`, over whatever is there, for the store's `ttl_s`.
        /// What `Idempotent` replaces its marker with: the answer.
        pub fn put(self: *Self, scope: anytype, slot: []const u8, value: []const u8) !void {
            return self.putFor(scope, slot, value, opts.ttl_s);
        }

        pub fn putFor(self: *Self, scope: anytype, slot: []const u8, value: []const u8, ttl_s: u32) !void {
            if (value.len > opts.max_bytes or slot.len > max_key) return error.TooLarge;
            _ = try self.db.insertOrUpdate(Row, scope, .{
                .space = opts.name,
                .slot = types.Bytes.of(slot),
                .value = types.Bytes.of(value),
                .expires_at = expiry(core.nowMicros(), ttl_s),
            }, .{ .space, .slot });
        }

        /// Read what is kept under `slot` into `out`, or null for a key
        /// nobody wrote, one that ran out, and an entry longer than `out`.
        pub fn getInto(self: *Self, scope: anytype, slot: []const u8, out: []u8) !?[]const u8 {
            if (slot.len > max_key) return null;
            const rows = try self.db.select(Row, scope, .{
                .where = .{
                    .space = opts.name,
                    .slot = types.Bytes.of(slot),
                    .expires_at = .{ .gt = core.nowMicros() },
                },
                .limit = 1,
            });
            if (rows.len == 0) return null;
            const kept = rows[0].value.bytes;
            if (kept.len > out.len) return null;
            @memcpy(out[0..kept.len], kept);
            return out[0..kept.len];
        }

        /// Forget a key. True when there was a row to forget.
        pub fn del(self: *Self, scope: anytype, slot: []const u8) !bool {
            if (slot.len > max_key) return false;
            const gone = try self.db.delete(Row, scope, .{
                .where = .{ .space = opts.name, .slot = types.Bytes.of(slot) },
            });
            return gone > 0;
        }

        /// Delete this store's entries that have run out, and say how many.
        /// Nothing calls it for you; see the file header.
        pub fn sweep(self: *Self, scope: anytype) !usize {
            return self.db.delete(Row, scope, .{
                .where = .{ .space = opts.name, .expires_at = .{ .lt = core.nowMicros() } },
            });
        }

        fn expiry(now: i64, ttl_s: u32) i64 {
            if (ttl_s == 0) return forever;
            return now +| @as(i64, ttl_s) * std.time.us_per_s;
        }
    };
}

// ---- tests ----

const testing = std.testing;
const sql = @import("sql.zig");
const migrate = @import("migrate.zig");

const SqliteDb = sql.Sqlite(.{ .threading = .in_fiber });
const Orders = Replays(SqliteDb, .{ .name = "orders", .ttl_s = 60, .max_bytes = 1024 });
const Refunds = Replays(SqliteDb, .{ .name = "refunds", .ttl_s = 60, .max_bytes = 1024 });

const Fixture = struct {
    threaded: std.Io.Threaded,
    db: SqliteDb,
    run: core.Run,

    /// `:memory:` is a database this fixture's pool has to itself.
    fn open() !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.threaded = .init(testing.allocator, .{});
        f.db = .init(testing.allocator, ":memory:", .{ .size = 1, .unchecked = true });
        f.run = .init(testing.allocator);
        try f.db.nilo_start(f.threaded.io(), .off);
        try migrate.createMissing(&f.db, &f.run, .{ .tables = &.{Orders.Row} });
        return f;
    }

    fn close(f: *Fixture) void {
        f.run.deinit();
        f.db.deinit();
        f.threaded.deinit();
        testing.allocator.destroy(f);
    }
};

test "a key is claimed once, and the second claim is told somebody was first" {
    const f = try Fixture.open();
    defer f.close();
    var orders = Orders.open(&f.db);

    try testing.expect(try orders.putIfAbsentFor(&f.run, "acct\x00k1", "marker", 120));
    try testing.expect(!try orders.putIfAbsentFor(&f.run, "acct\x00k1", "other", 120));
    try testing.expect(try orders.putIfAbsentFor(&f.run, "acct\x00k2", "marker", 120));

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("marker", (try orders.getInto(&f.run, "acct\x00k1", &buf)).?);
}

test "an answer put over a marker is what a read returns, bytes and all" {
    const f = try Fixture.open();
    defer f.close();
    var orders = Orders.open(&f.db);

    try testing.expect(try orders.putIfAbsentFor(&f.run, "k", "m", 120));
    // Every byte value, a NUL among them: an encoded answer is not text.
    var answer: [256]u8 = undefined;
    for (&answer, 0..) |*b, i| b.* = @intCast(i);
    try orders.put(&f.run, "k", &answer);

    var buf: [512]u8 = undefined;
    try testing.expectEqualSlices(u8, &answer, (try orders.getInto(&f.run, "k", &buf)).?);
}

test "an entry that has run out is nobody's, to a read and to a claim" {
    const f = try Fixture.open();
    defer f.close();
    var orders = Orders.open(&f.db);

    try testing.expect(try orders.putIfAbsentFor(&f.run, "k", "old", 120));
    // Age the row by hand: a test that slept for two minutes would be a bug.
    _ = try f.db.exec(&f.run, "UPDATE \"nilo_replays\" SET \"expires_at\" = 1", .{});

    var buf: [64]u8 = undefined;
    try testing.expect((try orders.getInto(&f.run, "k", &buf)) == null);
    try testing.expect(try orders.putIfAbsentFor(&f.run, "k", "new", 120));
    try testing.expectEqualStrings("new", (try orders.getInto(&f.run, "k", &buf)).?);
}

test "sweep takes what has run out and leaves what has not" {
    const f = try Fixture.open();
    defer f.close();
    var orders = Orders.open(&f.db);

    try testing.expect(try orders.putIfAbsentFor(&f.run, "a", "m", 120));
    try testing.expect(try orders.putIfAbsentFor(&f.run, "b", "m", 120));
    try testing.expectEqual(@as(usize, 0), try orders.sweep(&f.run));
    _ = try f.db.exec(&f.run, "UPDATE \"nilo_replays\" SET \"expires_at\" = 1 WHERE \"slot\" = x'61'", .{});
    try testing.expectEqual(@as(usize, 1), try orders.sweep(&f.run));
    var buf: [8]u8 = undefined;
    try testing.expect((try orders.getInto(&f.run, "b", &buf)) != null);
}

test "del frees a key for the next claim, and says whether there was one" {
    const f = try Fixture.open();
    defer f.close();
    var orders = Orders.open(&f.db);

    try testing.expect(!try orders.del(&f.run, "k"));
    try testing.expect(try orders.putIfAbsentFor(&f.run, "k", "m", 120));
    try testing.expect(try orders.del(&f.run, "k"));
    try testing.expect(try orders.putIfAbsentFor(&f.run, "k", "m2", 120));
}

test "two stores in one table keep their keys apart" {
    const f = try Fixture.open();
    defer f.close();
    var orders = Orders.open(&f.db);
    var refunds = Refunds.open(&f.db);

    try testing.expect(try orders.putIfAbsentFor(&f.run, "k", "order", 120));
    try testing.expect(try refunds.putIfAbsentFor(&f.run, "k", "refund", 120));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("order", (try orders.getInto(&f.run, "k", &buf)).?);
    try testing.expectEqualStrings("refund", (try refunds.getInto(&f.run, "k", &buf)).?);
}

test "a value or a key past the limits is TooLarge, and a read into a short buffer is a miss" {
    const f = try Fixture.open();
    defer f.close();
    var orders = Orders.open(&f.db);

    const big: [1025]u8 = @splat('x');
    try testing.expectError(error.TooLarge, orders.putIfAbsentFor(&f.run, "k", &big, 120));
    try testing.expectError(error.TooLarge, orders.put(&f.run, "k", &big));
    const long_key: [max_key + 1]u8 = @splat('k');
    try testing.expectError(error.TooLarge, orders.putIfAbsentFor(&f.run, &long_key, "m", 120));

    try orders.put(&f.run, "k", "twelve bytes");
    var small: [4]u8 = undefined;
    try testing.expect((try orders.getInto(&f.run, "k", &small)) == null);
}

// ---- through nilo.Idempotent ----
//
// What the table is for: the same key reaching two instances. An instance is
// an App and the pool it holds, so two of them are two of each over one
// database. These are the only tests in the repository where `Idempotent`
// meets a store that can fail and can be shared, and `http/behaviour.zig`
// holds the half that does not need a database.

const nilo = @import("nilo_http");
const builtin = @import("builtin");
const live_config = @import("live_config");

const NewOrder = struct { sku: []const u8, qty: u32 };
const Placed = struct { id: u32 };

const Counter = struct {
    placed: std.atomic.Value(u32) = .init(0),
    io: std.Io,
    /// How long the handler works, so a second request can arrive while it does.
    work_ms: i64 = 0,
};

fn OrderRoute(comptime R: type) type {
    return struct {
        fn place(key: nilo.Idempotent(R, .{}), body: NewOrder, counter: *Counter) !nilo.Status(201, Placed) {
            _ = key;
            _ = body;
            if (counter.work_ms > 0) std.Io.sleep(counter.io, .fromMilliseconds(counter.work_ms), .awake) catch {};
            return .{ .value = .{ .id = counter.placed.fetchAdd(1, .monotonic) + 1 } };
        }
    };
}

fn sendOrder(client: *nilo.testing.Client, app: *nilo.App, key: []const u8) !nilo.testing.Answer {
    return client.sendRequest(app, .{
        .method = "POST",
        .path = "/orders",
        .headers = &.{.{ .name = "Idempotency-Key", .value = key }},
        .content_type = "application/json",
        .body = "{\"sku\":\"A1\",\"qty\":2}",
    });
}

test "a retry sent to the other instance is answered from the table and the handler runs once" {
    const f = try Fixture.open();
    defer f.close();
    var counter: Counter = .{ .io = f.threaded.io() };
    const Route = OrderRoute(Orders);

    // Two instances: an App each, and one database under both. (SQLite has
    // one connection here; the Postgres test below has a pool each.)
    var replays = Orders.open(&f.db);
    var a = nilo.App.init(testing.allocator);
    defer a.deinit();
    var b = nilo.App.init(testing.allocator);
    defer b.deinit();
    for ([_]*nilo.App{ &a, &b }) |app| {
        try app.provide(&replays);
        try app.provide(&counter);
        try app.post("/orders", Route.place);
    }
    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const first = try sendOrder(&client, &a, "k-1");
    try testing.expectEqual(@as(u16, 201), first.status);
    try testing.expect(first.header("Idempotent-Replayed") == null);
    // The client reuses its buffer for the next answer.
    const first_body = try testing.allocator.dupe(u8, first.body);
    defer testing.allocator.free(first_body);

    const retried = try sendOrder(&client, &b, "k-1");
    try testing.expectEqual(@as(u16, 201), retried.status);
    try testing.expectEqualStrings("true", retried.header("Idempotent-Replayed").?);
    try testing.expectEqualStrings(first_body, retried.body);
    try testing.expectEqual(@as(u32, 1), counter.placed.load(.monotonic));

    // A different key is a different order, and the row it leaves is the answer.
    const other = try sendOrder(&client, &b, "k-2");
    try testing.expectEqual(@as(u16, 201), other.status);
    try testing.expectEqual(@as(u32, 2), counter.placed.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), try f.db.count(Orders.Row, &f.run, .{}));
}

test "a table that stopped answering is a 503 and the handler does not run" {
    const f = try Fixture.open();
    defer f.close();
    var counter: Counter = .{ .io = f.threaded.io() };
    const Route = OrderRoute(Orders);
    var replays = Orders.open(&f.db);
    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&replays);
    try app.provide(&counter);
    try app.post("/orders", Route.place);
    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    // The table is gone, which is what a database that cannot be asked looks
    // like to a statement: it fails, and the request is refused unrun.
    _ = try f.db.exec(&f.run, "DROP TABLE \"nilo_replays\"", .{});
    const refused = try sendOrder(&client, &app, "k-1");
    try testing.expectEqual(@as(u16, 503), refused.status);
    try testing.expectEqual(@as(u32, 0), counter.placed.load(.monotonic));
}

// -- Postgres: two pools, one table ----------------------------------------

const mode_suffix = switch (builtin.mode) {
    .debug => "debug",
    .safe => "releasesafe",
    .fast => "releasefast",
    .small => "releasesmall",
};

/// Named for the optimize mode, because `zig build test-sql` runs the Debug
/// and ReleaseSafe suites at once against one database.
const PgOrders = Replays(sql.Db, .{ .name = "orders", .ttl_s = 60, .max_bytes = 1024, .table = "nilo_replays_" ++ mode_suffix });

/// Two instances' worth of Postgres: a pool each, and the table made once.
const Pair = struct {
    threaded: std.Io.Threaded,
    admin: sql.Db,
    one: sql.Db,
    two: sql.Db,
    run: core.Run,

    fn open(url: []const u8) !*Pair {
        const p = try testing.allocator.create(Pair);
        p.threaded = .init(testing.allocator, .{});
        p.run = .init(testing.allocator);
        const io = p.threaded.io();
        p.admin = .init(testing.allocator, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
        try p.admin.nilo_start(io, .off);
        _ = try p.admin.exec(&p.run, "DROP TABLE IF EXISTS \"nilo_replays_" ++ mode_suffix ++ "\"", .{});
        try migrate.createMissing(&p.admin, &p.run, .{ .tables = &.{PgOrders.Row} });
        p.one = .init(testing.allocator, url, .{ .size = 8, .connect_on_init = 1, .unchecked = true });
        try p.one.nilo_start(io, .off);
        p.two = .init(testing.allocator, url, .{ .size = 8, .connect_on_init = 1, .unchecked = true });
        try p.two.nilo_start(io, .off);
        return p;
    }

    fn close(p: *Pair) void {
        _ = p.admin.exec(&p.run, "DROP TABLE IF EXISTS \"nilo_replays_" ++ mode_suffix ++ "\"", .{}) catch {};
        p.two.nilo_stop();
        p.two.deinit();
        p.one.nilo_stop();
        p.one.deinit();
        p.admin.nilo_stop();
        p.admin.deinit();
        p.run.deinit();
        p.threaded.deinit();
        testing.allocator.destroy(p);
    }
};

fn claimTask(replays: *PgOrders, key: []const u8) bool {
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();
    return replays.putIfAbsentFor(&run, key, "marker", 120) catch false;
}

/// Sixteen claims on `key`, half through each pool, and how many were won.
fn raceFor(p: *Pair, from_one: *PgOrders, from_two: *PgOrders, key: []const u8) !usize {
    const io = p.threaded.io();
    var tasks: [16]std.Io.Future(bool) = undefined;
    var started: usize = 0;
    for (&tasks, 0..) |*t, i| {
        const replays = if (i % 2 == 0) from_one else from_two;
        t.* = io.concurrent(claimTask, .{ replays, key }) catch break;
        started += 1;
    }
    var won: usize = 0;
    for (tasks[0..started]) |*t| {
        if (t.await(io)) won += 1;
    }
    if (started < tasks.len) return error.SkipZigTest;
    return won;
}

test "sixteen claims on one key from two pools at once are won exactly once" {
    const url = live_config.database_url orelse return error.SkipZigTest;
    const p = try Pair.open(url);
    defer p.close();
    var from_one = PgOrders.open(&p.one);
    var from_two = PgOrders.open(&p.two);

    try testing.expectEqual(@as(usize, 1), try raceFor(p, &from_one, &from_two, "acct\x00same-key"));

    // And a row that has run out is won again, by exactly one of them.
    _ = try p.admin.exec(&p.run, "UPDATE \"nilo_replays_" ++ mode_suffix ++ "\" SET \"expires_at\" = 1", .{});
    try testing.expectEqual(@as(usize, 1), try raceFor(p, &from_one, &from_two, "acct\x00same-key"));
}

const Sent = struct {
    app: *nilo.App,
    key: []const u8,
};

fn sendTask(s: Sent) u16 {
    var client = nilo.testing.Client.init(testing.allocator, .{}) catch return 0;
    defer client.deinit();
    const answer = sendOrder(&client, s.app, s.key) catch return 0;
    return answer.status;
}

test "the same key reaching two instances at once runs the handler once and refuses the other" {
    const url = live_config.database_url orelse return error.SkipZigTest;
    const p = try Pair.open(url);
    defer p.close();
    const io = p.threaded.io();
    // The handler works for a while, so the second request arrives while the
    // first is still in it: the 409 is what the marker is for.
    var counter: Counter = .{ .io = io, .work_ms = 300 };
    const Route = OrderRoute(PgOrders);

    var from_one = PgOrders.open(&p.one);
    var from_two = PgOrders.open(&p.two);
    var a = nilo.App.init(testing.allocator);
    defer a.deinit();
    var b = nilo.App.init(testing.allocator);
    defer b.deinit();
    try a.provide(&from_one);
    try a.provide(&counter);
    try a.post("/orders", Route.place);
    try b.provide(&from_two);
    try b.provide(&counter);
    try b.post("/orders", Route.place);

    var first = io.concurrent(sendTask, .{Sent{ .app = &a, .key = "k-1" }}) catch return error.SkipZigTest;
    var second = io.concurrent(sendTask, .{Sent{ .app = &b, .key = "k-1" }}) catch return error.SkipZigTest;
    const x = first.await(io);
    const y = second.await(io);

    try testing.expectEqual(@as(u32, 1), counter.placed.load(.monotonic));
    try testing.expect((x == 201 and y == 409) or (x == 409 and y == 201));

    // The loser retries once the winner is done, and is answered from the table.
    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    const retried = try sendOrder(&client, &b, "k-1");
    try testing.expectEqual(@as(u16, 201), retried.status);
    try testing.expectEqualStrings("true", retried.header("Idempotent-Replayed").?);
    try testing.expectEqual(@as(u32, 1), counter.placed.load(.monotonic));
}

test "a handler that fails frees the key on the table, so the retry from another instance runs" {
    const url = live_config.database_url orelse return error.SkipZigTest;
    const p = try Pair.open(url);
    defer p.close();
    const io = p.threaded.io();
    var counter: Counter = .{ .io = io };
    const Failing = struct {
        fn place(key: nilo.Idempotent(PgOrders, .{}), c: *Counter) !nilo.Status(201, Placed) {
            _ = key;
            if (c.work_ms == 0) {
                c.work_ms = -1;
                return nilo.fail.unprocessable("not yet", .{});
            }
            return .{ .value = .{ .id = c.placed.fetchAdd(1, .monotonic) + 1 } };
        }
    };
    var from_one = PgOrders.open(&p.one);
    var from_two = PgOrders.open(&p.two);
    var a = nilo.App.init(testing.allocator);
    defer a.deinit();
    var b = nilo.App.init(testing.allocator);
    defer b.deinit();
    try a.provide(&from_one);
    try a.provide(&counter);
    try a.post("/orders", Failing.place);
    try b.provide(&from_two);
    try b.provide(&counter);
    try b.post("/orders", Failing.place);
    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const failed = try client.sendRequest(&a, .{
        .method = "POST",
        .path = "/orders",
        .headers = &.{.{ .name = "Idempotency-Key", .value = "k-1" }},
    });
    try testing.expectEqual(@as(u16, 422), failed.status);
    try testing.expectEqual(@as(usize, 0), try p.admin.count(PgOrders.Row, &p.run, .{}));

    const ran = try client.sendRequest(&b, .{
        .method = "POST",
        .path = "/orders",
        .headers = &.{.{ .name = "Idempotency-Key", .value = "k-1" }},
    });
    try testing.expectEqual(@as(u16, 201), ran.status);
    try testing.expectEqual(@as(usize, 1), try p.admin.count(PgOrders.Row, &p.run, .{}));
}
