//! The two Zig caches, under the same load `nilo_cache` is put under.
//!
//! ```
//! zig build run -Doptimize=ReleaseFast -- bench <threads> <seconds>
//! zig build run -Doptimize=ReleaseFast -- mem   <entries> <which>
//! zig build run -Doptimize=ReleaseFast -- hitrate
//! ```
//!
//! [cache.zig](https://github.com/karlseguin/cache.zig) is an LRU-ish cache
//! with reference-counted entries: `get` hands back a `*Entry` the caller
//! must `release()`, which is how it lets a value outlive the eviction that
//! removed it. [zigache](https://github.com/jaxron/zigache) is a policy
//! kit — FIFO, LRU, SIEVE, S3-FIFO and W-TinyLFU behind one type — and it is
//! the only other cache in this whole comparison whose replacement policy is
//! the same family as the one `nilo_cache` now uses.
//!
//! **Both bound a count of entries, not bytes**, which is the same difference
//! moka and quick_cache have on the Rust side and the reason the memory table
//! exists. And both keep the entry on the heap behind a pointer, so a `get` is
//! a map probe plus a pointer chase, where nilo's is a table probe plus a ring
//! read.
//!
//! One thing is not the same on both sides and it is worth saying before the
//! numbers: **zigache does not copy the key.** Its `put` stores the slice the
//! caller passed, and its docs say the key must stay valid for as long as it
//! is in the cache. cache.zig and nilo_cache both `dupe` it. So zigache's
//! bytes-an-entry excludes the key bytes entirely, which for a 12-byte key is
//! real money, and its number should be read as a floor rather than a total.
//!
//! The keys are built before the clock starts, the same as on every other
//! side: formatting a key inside a timed loop measures the formatter.

const std = @import("std");
const cachezig = @import("cachezig");
const zigache = @import("zigache");

/// The same 24 bytes every other side stores.
const Cart = [24]u8;

const keys_n = 50_000;

fn cart() Cart {
    var b: Cart = @splat(0);
    b[0] = 1;
    b[8] = 2;
    b[12] = 3;
    return b;
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

fn monotonicMicros() i64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
        .SUCCESS => {},
        else => |e| std.debug.panic("clock: {s}", .{@tagName(e)}),
    }
    return @as(i64, @intCast(ts.sec)) * std.time.us_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_us);
}

fn rssKiB() u64 {
    var buf: [4096]u8 = undefined;
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

// ---------------------------------------------------------------------------
// One wrapper a cache, so the driving loop below is literally the same code for
// all of them. They are types rather than a tagged union on purpose: a union
// would put a branch inside the timed loop and every row would carry it.
// ---------------------------------------------------------------------------

/// karlseguin/cache.zig. `segments` is its shard count; 8 is what it ships
/// with and 64 is what nilo_cache defaults to, so both are measured.
fn CacheZig(comptime segments: u16) type {
    return struct {
        const Self = @This();
        const Inner = cachezig.StringCache(Cart);
        pub const name = std.fmt.comptimePrint("cache.zig/{d}", .{segments});

        inner: Inner,

        pub fn open(gpa: std.mem.Allocator, io: std.Io, entries: usize) !Self {
            return .{ .inner = try Inner.init(io, gpa, .{
                .max_size = @intCast(entries),
                .segment_count = segments,
            }) };
        }
        pub fn close(self: *Self) void {
            self.inner.deinit();
        }
        pub fn set(self: *Self, key: []const u8, value: Cart) void {
            // An hour rather than the default five minutes, so nothing expires
            // inside a run and the row measures the cache rather than the TTL.
            self.inner.put(key, value, .{ .ttl = 3600 }) catch {};
        }
        pub fn get(self: *Self, key: []const u8) bool {
            const entry = self.inner.get(key) orelse return false;
            defer entry.release();
            std.mem.doNotOptimizeAway(entry.value);
            return true;
        }
    };
}

/// jaxron/zigache, one policy a type. 64 shards throughout, which is what
/// nilo_cache defaults to and what zigache's own benchmark uses for its
/// multi-threaded runs.
///
/// `scale` exists because reading `s3fifo.zig` suggested the table was unfair
/// and measuring said it was not, which is worth keeping rather than deleting.
/// **S3FIFO's ghost queue counts against `cache_size`** — `init` gives `small`
/// a tenth and splits the rest between `main` and `ghost`, and the eviction
/// test is `small.len + main.len + ghost.len >= max_size` — so a cache asked
/// for N looked like it would hold 0.55N. It holds 0.996N. zigache's ghost is
/// not the paper's key-only ghost: a demoted node keeps its value, stays in the
/// map, and `get` answers from it without looking at which queue it is in. So
/// asking every cache for the same N compares the same number of entries, and
/// the `held` column in the hit-rate table is what says so rather than this
/// paragraph. Left in place because a premise nobody re-checks is how a
/// comparison goes quietly wrong.
fn Zigache(
    comptime policy: zigache.CacheInitOptions.PolicyOptions,
    comptime label: []const u8,
    comptime scale: struct { num: usize = 1, den: usize = 1 },
) type {
    return struct {
        const Self = @This();
        const Inner = zigache.Cache([]const u8, Cart, .{});
        pub const name = label;

        inner: Inner,

        pub fn open(gpa: std.mem.Allocator, io: std.Io, entries: usize) !Self {
            _ = io;
            return .{ .inner = try Inner.init(gpa, .{
                .cache_size = @intCast(entries * scale.num / scale.den),
                .shard_count = 64,
                .policy = policy,
            }) };
        }
        pub fn close(self: *Self) void {
            self.inner.deinit();
        }
        pub fn set(self: *Self, key: []const u8, value: Cart) void {
            self.inner.put(key, value) catch {};
        }
        pub fn get(self: *Self, key: []const u8) bool {
            const value = self.inner.get(key) orelse return false;
            std.mem.doNotOptimizeAway(value);
            return true;
        }
    };
}

const s3fifo = Zigache(.{ .S3FIFO = .{} }, "zigache S3FIFO", .{});
/// Not in any table: it holds 1.8x what it is asked for, which is not a
/// comparison. It is the control that proved the paragraph above wrong.
const s3fifo_held = Zigache(.{ .S3FIFO = .{} }, "zigache S3FIFO+", .{ .num = 20, .den = 11 });
const tinylfu = Zigache(.{ .TinyLFU = .{} }, "zigache TinyLFU", .{});
const lru = Zigache(.{ .LRU = .{} }, "zigache LRU", .{});

// ---------------------------------------------------------------------------

fn Runner(comptime C: type) type {
    return struct {
        cache: *C,
        keys: []const []const u8,
        stop: *std.atomic.Value(bool),
        write_every: usize,
        ops: u64 = 0,

        fn run(self: *@This(), seed: u64) void {
            var prng: std.Random.DefaultPrng = .init(seed);
            const rnd = prng.random();
            const value = cart();
            while (!self.stop.load(.monotonic)) {
                for (0..512) |n| {
                    const key = self.keys[rnd.uintLessThan(usize, self.keys.len)];
                    if (self.write_every != 0 and n % self.write_every == 0) {
                        self.cache.set(key, value);
                    } else {
                        std.mem.doNotOptimizeAway(self.cache.get(key));
                    }
                    self.ops += 1;
                }
            }
        }
    };
}

fn measure(
    comptime C: type,
    gpa: std.mem.Allocator,
    io: std.Io,
    keys: *const Keys,
    label: []const u8,
    write_every: usize,
    threads_n: usize,
    seconds: u64,
) !void {
    // Sized to hold the whole working set, the way the other sides are given a
    // budget that holds theirs. A fresh cache a row, for the reason
    // `bench/cache_bench.zig` has three comments about.
    var c = try C.open(gpa, io, keys_n * 2);
    defer c.close();
    const value = cart();
    for (keys.text) |k| c.set(k, value);

    const R = Runner(C);
    const runners = try gpa.alloc(R, threads_n);
    defer gpa.free(runners);
    const threads = try gpa.alloc(std.Thread, threads_n);
    defer gpa.free(threads);

    var stop: std.atomic.Value(bool) = .init(false);
    for (runners) |*r| r.* = .{
        .cache = &c,
        .keys = keys.text,
        .stop = &stop,
        .write_every = write_every,
    };

    const began = monotonicMicros();
    for (threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, R.run, .{ &runners[i], 7 + i });
    const until = began + @as(i64, @intCast(seconds)) * std.time.us_per_s;
    while (monotonicMicros() < until) std.atomic.spinLoopHint();
    stop.store(true, .monotonic);
    for (threads) |t| t.join();
    const took = monotonicMicros() - began;

    var ops: u64 = 0;
    for (runners) |r| ops += r.ops;

    const per_s = @as(f64, @floatFromInt(ops)) * 1_000_000.0 / @as(f64, @floatFromInt(took));
    const ns = @as(f64, @floatFromInt(took)) * 1000.0 * @as(f64, @floatFromInt(threads_n)) /
        @as(f64, @floatFromInt(ops));
    std.debug.print("  {s: <16} {s: <12} {d: >2} threads  {d: >12.0} ops/s  {d: >7.1} ns/op\n", .{
        C.name, label, threads_n, per_s, ns,
    });
}

fn bench(gpa: std.mem.Allocator, io: std.Io, threads_n: usize, seconds: u64) !void {
    const keys = try Keys.build(gpa, keys_n);
    defer keys.free(gpa);

    inline for (.{ CacheZig(8), CacheZig(64), s3fifo, tinylfu, lru }) |C| {
        try measure(C, gpa, io, &keys, "get_flat", 0, threads_n, seconds);
        try measure(C, gpa, io, &keys, "mixed_flat", 10, threads_n, seconds);
    }
}

/// The same `held` question the Go and Rust sides answer with RSS, asked of the
/// entry count instead: how many of the entries a cache was asked for actually
/// have a value in them once it is full.
fn held(gpa: std.mem.Allocator, io: std.Io) !void {
    const universe = 100_000;
    const keys = try Keys.build(gpa, universe);
    defer keys.free(gpa);
    const value = cart();

    inline for (.{ CacheZig(8), s3fifo, s3fifo_held, tinylfu, lru }) |C| {
        for ([_]usize{ 8223, 64081 }) |asked| {
            var c = try C.open(gpa, io, asked);
            defer c.close();
            for (keys.text[0..@min(asked * 3, universe)]) |k| c.set(k, value);
            var live: usize = 0;
            for (keys.text) |k| {
                if (c.get(k)) live += 1;
            }
            std.debug.print("  {s: <16} asked {d: >6}  held {d: >6}  {d: >5.1}%\n", .{
                C.name, asked, live,
                @as(f64, @floatFromInt(live)) * 100.0 / @as(f64, @floatFromInt(asked)),
            });
        }
    }
}

/// What N entries cost to hold, as RSS, the same question asked of every other
/// side. Neither of these takes a byte budget, so each is given a capacity of
/// exactly N and then weighed.
///
/// **One cache a process.** Measuring several in one run reads every one after
/// the first far too low: the allocator does not hand the earlier one's memory
/// back, so the next `before` is already at the previous peak. `run.sh` invokes
/// this once per name.
fn mem(gpa: std.mem.Allocator, io: std.Io, entries: usize, only: usize) !void {
    const keys = try Keys.build(gpa, entries);
    defer keys.free(gpa);
    const value = cart();

    inline for (.{ CacheZig(8), s3fifo, tinylfu, lru }, 0..) |C, i| {
        if (i == only) {
            const before = rssKiB();
            var c = try C.open(gpa, io, entries);
            defer c.close();
            for (keys.text) |k| c.set(k, value);

            var live: usize = 0;
            for (keys.text) |k| {
                if (c.get(k)) live += 1;
            }
            const after = rssKiB();
            std.debug.print(
                "  {s: <16} {d} entries   RSS {d} KiB - {d} KiB = {d} KiB   {d:.1} bytes/entry   ({d} retrievable = {d:.1}%)\n",
                .{
                    C.name,
                    entries,
                    after,
                    before,
                    after -| before,
                    @as(f64, @floatFromInt((after -| before) * 1024)) / @as(f64, @floatFromInt(entries)),
                    live,
                    @as(f64, @floatFromInt(live)) * 100.0 / @as(f64, @floatFromInt(entries)),
                },
            );
        }
    }
}

/// The number that decides whether a cache is worth its memory. Same trace
/// shape as the Go and Rust sides: Zipf 0.99, read-through, and the capacity
/// swept in entries rather than bytes because that is what these two take.
const hit_sizes = [_]struct { kib: usize, entries: usize }{
    .{ .kib = 128, .entries = 2086 },
    .{ .kib = 256, .entries = 4159 },
    .{ .kib = 512, .entries = 8223 },
    .{ .kib = 1024, .entries = 16283 },
    .{ .kib = 2048, .entries = 32438 },
    .{ .kib = 4096, .entries = 64081 },
};

fn hitrate(gpa: std.mem.Allocator, io: std.Io) !void {
    const trace_n = 3_000_000;
    const universe = 100_000;

    const keys = try Keys.build(gpa, universe);
    defer keys.free(gpa);
    const value = cart();

    const cdf = try gpa.alloc(f64, universe);
    defer gpa.free(cdf);
    var sum: f64 = 0;
    for (cdf, 0..) |*c, i| {
        sum += 1.0 / std.math.pow(f64, @floatFromInt(i + 1), 0.99);
        c.* = sum;
    }
    for (cdf) |*c| c.* /= sum;

    const trace = try gpa.alloc(u32, trace_n);
    defer gpa.free(trace);
    var prng: std.Random.DefaultPrng = .init(2);
    const rnd = prng.random();
    for (trace) |*t| {
        const u = rnd.float(f64);
        var lo: usize = 0;
        var hi: usize = universe - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (cdf[mid] < u) lo = mid + 1 else hi = mid;
        }
        t.* = @intCast(lo);
    }

    std.debug.print("hit rate, zipf 0.99, read-through, {d} lookups\n", .{trace_n});
    inline for (.{ CacheZig(8), CacheZig(64), s3fifo, tinylfu, lru }) |C| {
        for (hit_sizes) |size| {
            var c = try C.open(gpa, io, size.entries);
            defer c.close();
            var hits: u64 = 0;
            for (trace) |i| {
                const k = keys.text[i];
                if (c.get(k)) hits += 1 else c.set(k, value);
            }
            // What it actually *held*, counted rather than assumed — the same
            // column nilo's own harness reports. Asked for N, cache.zig holds
            // about 0.9N (it shrinks by a fifth when a segment fills) and
            // zigache's S3FIFO about 0.55N (its ghost queue counts against
            // `cache_size`). Without this column the table compares a number
            // each library means something different by.
            var live: usize = 0;
            for (keys.text) |k| {
                if (c.get(k)) live += 1;
            }
            std.debug.print("  {s: <16} {d: >6} KiB equivalent (asked {d: >5}, held {d: >5})  {d: >7.1}%\n", .{
                C.name,
                size.kib,
                size.entries,
                live,
                @as(f64, @floatFromInt(hits)) * 100.0 / @as(f64, @floatFromInt(trace_n)),
            });
        }
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    // cache.zig reads the clock through an `Io`, so one has to exist. It is
    // stood up outside every measurement below and is not part of any of them.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var it: std.process.Args.Iterator = .init(init.args);
    _ = it.skip();
    const mode = it.next() orelse "bench";
    const first: ?[]const u8 = it.next();
    const second: ?[]const u8 = it.next();

    if (std.mem.eql(u8, mode, "mem")) {
        const entries: usize = if (first) |a| try std.fmt.parseInt(usize, a, 10) else 200_000;
        const only: usize = if (second) |a| try std.fmt.parseInt(usize, a, 10) else 0;
        return mem(gpa, io, entries, only);
    }
    if (std.mem.eql(u8, mode, "hitrate")) return hitrate(gpa, io);
    if (std.mem.eql(u8, mode, "held")) return held(gpa, io);

    const threads_n: usize = if (first) |a| try std.fmt.parseInt(usize, a, 10) else 1;
    const seconds: u64 = if (second) |a| try std.fmt.parseInt(u64, a, 10) else 3;
    return bench(gpa, io, threads_n, seconds);
}
