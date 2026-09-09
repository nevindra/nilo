//! What fraction of lookups the cache answers, on traffic shaped like traffic.
//!
//! `bench/cache_bench.zig` picks its keys uniformly at random, and **uniform
//! random is the one distribution where an eviction policy provably cannot
//! matter**: every key is equally likely next, so knowing which entries were
//! read recently tells you nothing about which will be read again. A cache
//! measured that way reports `capacity / working set` whatever its policy is,
//! which is exactly the straight line ADR 0138 recorded and read as good news.
//!
//! Real traffic is Zipfian: a few keys take most of the requests. There the
//! policy is the whole game, and the gap between what a cache gets and what a
//! cache of that size *could* get is the number worth having.
//!
//! The ceiling here is analytic rather than simulated. For a stationary
//! Zipfian the best any cache of K entries can do is hold the K most popular
//! keys, so its hit rate is `zeta(K) / zeta(N)`. No policy beats it and Belady
//! does not need implementing to say so.

const std = @import("std");
const cache = @import("nilo_cache");

const Cart = struct { owner: u64, items: u32, total: u64 };
const Carts = cache.Space("cart", Cart, .{});

const keys_n = 100_000;
const trace_n = 5_000_000;

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
};

/// Probabilities proportional to `1 / rank^alpha`, as a cumulative table a
/// uniform draw is binary-searched into. Built once and shared by every row,
/// so two budgets are compared on the identical stream of keys.
const Zipf = struct {
    cdf: []f64,

    fn build(gpa: std.mem.Allocator, n: usize, alpha: f64) !Zipf {
        const cdf = try gpa.alloc(f64, n);
        var sum: f64 = 0;
        for (cdf, 0..) |*c, i| {
            sum += 1.0 / std.math.pow(f64, @floatFromInt(i + 1), alpha);
            c.* = sum;
        }
        for (cdf) |*c| c.* /= sum;
        return .{ .cdf = cdf };
    }

    fn pick(self: Zipf, u: f64) usize {
        var lo: usize = 0;
        var hi: usize = self.cdf.len - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.cdf[mid] < u) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// The best a cache of `k` entries can possibly do: hold the `k` most
    /// popular keys and answer everything they cover.
    fn ceiling(self: Zipf, k: usize) f64 {
        if (k == 0) return 0;
        if (k >= self.cdf.len) return 1;
        return self.cdf[k - 1];
    }
};

fn buildTrace(gpa: std.mem.Allocator, zipf: ?Zipf, n: usize, seed: u64) ![]u32 {
    const trace = try gpa.alloc(u32, n);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    for (trace) |*t| {
        t.* = if (zipf) |z|
            @intCast(z.pick(rand.float(f64)))
        else
            @intCast(rand.uintLessThan(usize, keys_n));
    }
    return trace;
}

/// One read-through pass: ask the cache, and on a miss write what the database
/// would have returned. That write is what moves the ring, so a hit rate
/// measured without it is measuring a cache nobody is filling.
fn run(store: *cache.Store, keys: Keys, trace: []const u32) struct { hits: u64, live: usize } {
    const carts = Carts.open(store);
    var hits: u64 = 0;
    for (trace) |i| {
        const key = keys.text[i];
        if (carts.get(key)) |_| {
            hits += 1;
        } else {
            carts.put(key, .{ .owner = i, .items = 2, .total = 3 });
        }
    }
    var live: usize = 0;
    for (keys.text) |k| {
        if (carts.get(k)) |_| live += 1;
    }
    return .{ .hits = hits, .live = live };
}

fn sweep(
    gpa: std.mem.Allocator,
    keys: Keys,
    trace: []const u32,
    zipf: ?Zipf,
    label: []const u8,
) !void {
    std.debug.print("\n{s}\n", .{label});
    std.debug.print("  {s: >9}  {s: >9}  {s: >8}  {s: >9}  {s: >9}  {s: >7}\n", .{
        "budget", "held", "hit rate", "ceiling", "uniform", "of best",
    });

    for ([_]usize{ 128 << 10, 256 << 10, 512 << 10, 1 << 20, 2 << 20, 4 << 20, 8 << 20, 16 << 20 }) |budget| {
        var store = try cache.open(gpa, .{ .bytes = budget, .shards = 1 });
        defer store.deinit();

        const got = run(&store, keys, trace);
        const rate = @as(f64, @floatFromInt(got.hits)) * 100 / @as(f64, @floatFromInt(trace.len));
        // What the cache actually managed to keep, measured rather than
        // derived: the ring, the table and the key length all have a say.
        const held = got.live;
        const ceiling = if (zipf) |z| z.ceiling(held) * 100 else @as(f64, @floatFromInt(held)) * 100 / keys_n;
        const uniform = @as(f64, @floatFromInt(held)) * 100 / keys_n;

        std.debug.print("  {d: >6} KiB  {d: >9}  {d: >7.1}%  {d: >8.1}%  {d: >8.1}%  {d: >6.0}%\n", .{
            budget >> 10,
            held,
            rate,
            ceiling,
            uniform,
            if (ceiling > 0) rate * 100 / ceiling else 0,
        });
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const gpa = std.heap.page_allocator;

    const keys = try Keys.build(gpa, keys_n);

    std.debug.print(
        "nilo_cache hit rate: {d} distinct keys, {d} lookups, read-through\n" ++
            "  ceiling = the best a cache holding that many entries could do\n" ++
            "  uniform = what the same cache gets on uniformly random keys\n",
        .{ keys_n, trace_n },
    );

    const uniform_trace = try buildTrace(gpa, null, trace_n, 1);
    try sweep(gpa, keys, uniform_trace, null, "uniform random (what bench/cache_bench.zig measures)");

    for ([_]f64{ 0.99, 0.9 }) |alpha| {
        const zipf = try Zipf.build(gpa, keys_n, alpha);
        const trace = try buildTrace(gpa, zipf, trace_n, 2);
        var buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&buf, "zipf alpha={d} (what traffic looks like)", .{alpha});
        try sweep(gpa, keys, trace, zipf, label);
    }
}
