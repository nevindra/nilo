//! What one cache operation costs, and what one entry costs to hold.
//!
//! ```
//! zig build bench-cache -Doptimize=ReleaseFast -- [threads] [seconds]
//! ```
//!
//! **The keys are built before the clock starts**, which the spike this came
//! from did not do: `spike/cache_ring/` formatted a key with `std.fmt.bufPrint`
//! inside every timed operation, so a large part of its 471 ns belonged to
//! `{d}` rather than to the cache. Ratios survived that; absolutes did not.
//! Here the keys are an array built once, and what is timed is the lookup.
//!
//! The values are deliberately two sizes. A 24-byte flat struct is the cheap
//! case — one cache line of ring — and a 512-byte page is the case where the
//! `memcpy` rather than the lookup is the cost, which is what a cache in front
//! of a database actually looks like.

const std = @import("std");
const cache = @import("nilo_cache");

const Cart = struct { owner: u64, items: u32, total: u64 };

const Carts = cache.Space("cart", Cart, .{});
const Pages = cache.Space("page", []const u8, .{ .max_bytes = 1024 });

const keys_n = 50_000;
/// Enough that a 4 MiB ring is what runs out rather than the table, for the
/// second table below. A per-entry cost measured on a ring that never filled
/// is a measurement of the table instead.
const fill_keys_n = 300_000;

fn monotonicMicros() i64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
        .SUCCESS => {},
        else => |e| std.debug.panic("clock: {s}", .{@tagName(e)}),
    }
    return @as(i64, @intCast(ts.sec)) * std.time.us_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_us);
}

const Keys = struct {
    text: [][]const u8,
    backing: []u8,

    fn build(gpa: std.mem.Allocator, n: usize) !Keys {
        const backing = try gpa.alloc(u8, n * 24);
        const text = try gpa.alloc([]const u8, n);
        var at: usize = 0;
        for (text, 0..) |*k, i| {
            const written = try std.fmt.bufPrint(backing[at..], "cart:{d}", .{i});
            k.* = written;
            at += written.len;
        }
        return .{ .text = text, .backing = backing };
    }
    fn free(self: Keys, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.backing);
    }
};

const Work = enum { get_flat, put_flat, mixed_flat, get_page, mixed_page };

const Runner = struct {
    carts: Carts,
    pages: Pages,
    keys: *const Keys,
    work: Work,
    /// How many of the keys this row uses. A working set that fits in the
    /// processor's cache and one that does not are different measurements,
    /// and running both is what separates the lookup's cost from memory's.
    span: usize,
    stop: *std.atomic.Value(bool),
    ops: u64 = 0,
    hits: u64 = 0,

    fn run(self: *Runner, seed: u64) void {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        const page = "p" ** 512;
        var held: Pages.Held = undefined;

        while (!self.stop.load(.monotonic)) {
            // A batch between clock reads, so the loop is measuring the cache
            // rather than `clock_gettime`.
            for (0..512) |n| {
                const key = self.keys.text[rand.uintLessThan(usize, self.span)];
                switch (self.work) {
                    .get_flat => if (self.carts.get(key)) |_| {
                        self.hits += 1;
                    },
                    .put_flat => self.carts.put(key, .{ .owner = 1, .items = 2, .total = 3 }),
                    .mixed_flat => if (n % 10 == 0)
                        self.carts.put(key, .{ .owner = 1, .items = 2, .total = 3 })
                    else if (self.carts.get(key)) |_| {
                        self.hits += 1;
                    },
                    .get_page => if (self.pages.get(key, &held)) |_| {
                        self.hits += 1;
                    },
                    .mixed_page => if (n % 10 == 0)
                        self.pages.put(key, page) catch {}
                    else if (self.pages.get(key, &held)) |_| {
                        self.hits += 1;
                    },
                }
                self.ops += 1;
            }
        }
    }
};

fn measure(
    gpa: std.mem.Allocator,
    store: *cache.Store,
    keys: *const Keys,
    work: Work,
    threads_n: usize,
    seconds: u64,
    span: usize,
    label: []const u8,
) !void {
    const runners = try gpa.alloc(Runner, threads_n);
    defer gpa.free(runners);
    const threads = try gpa.alloc(std.Thread, threads_n);
    defer gpa.free(threads);

    // Warmed before every row rather than once at the top. The first version
    // of this file warmed once, and `put_flat` then wrote ten million entries
    // through a ring holding a few hundred thousand — so `get_page`, two rows
    // below it, measured a cache somebody else had emptied and reported 0%
    // hits at 7.4 million lookups a second. A miss is fast, which is exactly
    // what makes that shape of mistake read like a good number.
    warm(store, keys, span, work);

    var stop: std.atomic.Value(bool) = .init(false);
    for (runners) |*r| r.* = .{
        .carts = Carts.open(store),
        .pages = Pages.open(store),
        .keys = keys,
        .work = work,
        .span = span,
        .stop = &stop,
    };

    const began = monotonicMicros();
    for (threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Runner.run, .{ &runners[i], 7 + i });
    const until = began + @as(i64, @intCast(seconds)) * std.time.us_per_s;
    while (monotonicMicros() < until) std.atomic.spinLoopHint();
    stop.store(true, .monotonic);
    for (threads) |t| t.join();
    const took = monotonicMicros() - began;

    var ops: u64 = 0;
    var hits: u64 = 0;
    for (runners) |r| {
        ops += r.ops;
        hits += r.hits;
    }

    const per_s = @as(f64, @floatFromInt(ops)) * 1_000_000.0 / @as(f64, @floatFromInt(took));
    const ns = @as(f64, @floatFromInt(took)) * 1000.0 * @as(f64, @floatFromInt(threads_n)) /
        @as(f64, @floatFromInt(ops));
    std.debug.print("  {s: <20} {d: >2} threads  {d: >12.0} ops/s  {d: >7.1} ns/op  hits {d: >5.1}%\n", .{
        label, threads_n, per_s, ns, pct(hits, ops),
    });
}

/// **Only what the row about to run will read.** Warming both Spaces meant a
/// row reading 24-byte carts first had a thousand 512-byte pages written over
/// them, which on a small ring left the headline row at 23% hits — so most of
/// what it timed was the cost of missing. A miss is cheap, and a benchmark
/// that quietly measures one reads as a good number.
fn warm(store: *cache.Store, keys: *const Keys, span: usize, work: Work) void {
    const page = "p" ** 512;
    switch (work) {
        .get_flat, .put_flat, .mixed_flat => {
            const carts = Carts.open(store);
            for (keys.text[0..span]) |k| carts.put(k, .{ .owner = 1, .items = 2, .total = 3 });
        },
        .get_page, .mixed_page => {
            const pages = Pages.open(store);
            for (keys.text[0..span]) |k| pages.put(k, page) catch unreachable;
        },
    }
}

fn pct(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(whole));
}

/// What one entry costs to hold. **Two numbers, because the honest answer is
/// two numbers**: the ring an entry occupies, which is marginal and is what
/// decides how many fit, and the table slot beside it, which is provisioned up
/// front whether or not anything uses it.
///
/// Measured by filling until the ring starts writing over itself and counting
/// what is still readable, rather than by adding up struct sizes — what a
/// cache holds is what it can still answer with.
fn perEntry(gpa: std.mem.Allocator, value_len: usize) !void {
    const ring = 4 << 20;
    // Entries set generously so the *ring* is what runs out. With the table as
    // the limit this would measure the table, and the table is a number the
    // caller chose.
    var store = try cache.open(gpa, .{ .bytes = ring, .entries = 1 << 17, .shards = 1 });
    defer store.deinit();
    const pages = Pages.open(&store);

    const keys = try Keys.build(gpa, fill_keys_n);
    defer keys.free(gpa);

    const value = "v" ** 1024;
    var held: Pages.Held = undefined;

    for (keys.text) |k| try pages.put(k, value[0..value_len]);
    var live: usize = 0;
    for (keys.text) |k| {
        if (pages.get(k, &held)) |_| live += 1;
    }

    // Only meaningful once the ring is what ran out. Said rather than
    // printed anyway, because a number measured on a cache that never
    // forgot anything is a number about the table.
    if (store.stats().evicted == 0 and live == keys.text.len) {
        std.debug.print("  value {d: >4}B  the ring never filled — nothing to measure\n", .{value_len});
        return;
    }
    const per_ring = @as(f64, @floatFromInt(ring)) / @as(f64, @floatFromInt(@max(live, 1)));
    std.debug.print("  value {d: >4}B  {d: >6} live  {d: >6.1} ring bytes/entry  ({d} over the value itself)\n", .{
        value_len,
        live,
        per_ring,
        @as(i64, @intFromFloat(per_ring)) - @as(i64, @intCast(value_len)),
    });
}

fn rssKiB() u64 {
    var buf: [4096]u8 = undefined;
    // Straight at the kernel: Zig 0.16 moved file opening behind `std.Io.Dir`,
    // which wants an `Io`, and the thing being measured is a module that has
    // none. A bench that conjures a runtime to read one line of /proc would be
    // measuring the runtime too.
    const rc = std.os.linux.open("/proc/self/status", .{ .ACCMODE = .RDONLY }, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return 0;
    const fd: i32 = @intCast(rc);
    defer _ = std.os.linux.close(fd);
    const got = std.os.linux.read(fd, &buf, buf.len);
    if (std.os.linux.errno(got) != .SUCCESS) return 0;
    const n: usize = @intCast(got);
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "VmRSS:")) continue;
        var fields = std.mem.tokenizeAny(u8, line["VmRSS:".len..], " \t");
        const num = fields.next() orelse return 0;
        return std.fmt.parseInt(u64, num, 10) catch 0;
    }
    return 0;
}

/// How much memory it takes to hold `entries` of them — the same question the
/// Go side answers, asked the same way.
///
/// nilo takes its memory up front, so the honest form of the question is the
/// smallest budget that still holds all of them. Go grows into whatever it
/// needs, so its answer is an RSS reading. Both are RSS here, because RSS is
/// what the machine gives up whoever asked for it.
fn memFor(gpa: std.mem.Allocator, entries: usize) !void {
    const keys = try Keys.build(gpa, entries);
    defer keys.free(gpa);

    const budgets = [_]usize{ 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128 };
    for (budgets) |mib| {
        const budget = mib << 20;
        const before = rssKiB();
        var store = cache.open(gpa, .{ .bytes = budget, .entries = entries * 2 }) catch continue;
        defer store.deinit();

        const carts = Carts.open(&store);
        for (keys.text) |k| carts.put(k, .{ .owner = 1, .items = 2, .total = 3 });

        var live: usize = 0;
        for (keys.text) |k| {
            if (carts.get(k)) |_| live += 1;
        }
        // Ninety-nine rather than a hundred: a four-way bucket loses a few
        // keys to collision at any size, and waiting for the last of them
        // would report the table's shape rather than the memory.
        // Ninety-eight rather than a hundred, and the two points are a
        // property rather than slack. A bucket has four ways, so at any load
        // a few keys arrive at a bucket whose four are taken and the stalest
        // is forgotten — about 1.7% of them here. A cache is allowed to miss;
        // what it is not allowed to do is take memory it was not given.
        if (live * 100 < entries * 98) continue;

        const after = rssKiB();
        std.debug.print(
            "  nilo_cache    {d} entries   RSS {d} KiB - {d} KiB = {d} KiB   {d:.1} bytes/entry" ++
                "   (budget {d} MiB, held {d} B, {d} retrievable = {d:.1}%)\n",
            .{
                entries,
                after,
                before,
                after -| before,
                @as(f64, @floatFromInt((after -| before) * 1024)) / @as(f64, @floatFromInt(entries)),
                mib,
                store.bytesHeld(),
                live,
                @as(f64, @floatFromInt(live)) * 100 / @as(f64, @floatFromInt(entries)),
            },
        );
        return;
    }
    std.debug.print("  nilo_cache    {d} entries did not fit any budget tried\n", .{entries});
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    var it: std.process.Args.Iterator = .init(init.args);
    _ = it.skip();
    const first = it.next();
    if (first != null and std.mem.eql(u8, first.?, "mem")) {
        const entries: usize = if (it.next()) |a| try std.fmt.parseInt(usize, a, 10) else 200_000;
        return memFor(gpa, entries);
    }
    const threads_n: usize = if (first) |a| try std.fmt.parseInt(usize, a, 10) else 1;
    const seconds: u64 = if (it.next()) |a| try std.fmt.parseInt(u64, a, 10) else 3;

    const keys = try Keys.build(gpa, keys_n);
    defer keys.free(gpa);

    var store = try cache.open(gpa, .{ .bytes = 64 << 20 });
    defer store.deinit();

    // A second store small enough for its table and its ring to sit in the
    // processor's cache. The difference between the two is the answer to
    // "how much of an operation is the lookup and how much is memory".
    var small = try cache.open(gpa, .{ .bytes = 256 << 10, .entries = 4096, .shards = 4 });
    defer small.deinit();

    std.debug.print("nilo_cache: {d} keys, {d} MiB of ring, {d} bytes held in all\n\n", .{
        keys_n,
        64,
        store.bytesHeld(),
    });

    std.debug.print("what one operation costs (each row warmed first)\n", .{});
    try measure(gpa, &small, &keys, .get_flat, threads_n, seconds, 2_000, "get_flat in cache");
    for ([_]Work{ .get_flat, .put_flat, .mixed_flat, .get_page, .mixed_page }) |work| {
        try measure(gpa, &store, &keys, work, threads_n, seconds, keys_n, @tagName(work));
    }

    std.debug.print("\nwhat one entry costs to hold\n", .{});
    for ([_]usize{ 16, 64, 256, 1024 }) |len| try perEntry(gpa, len);

    const s = store.stats();
    std.debug.print("\nhits {d}  misses {d}  evicted {d}  eviction rate {d:.1}%\n", .{
        s.hits, s.misses, s.evicted, s.evictionRate() * 100,
    });
}
