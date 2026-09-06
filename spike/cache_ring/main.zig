//! Can a cache hold values of any length without allocating per operation?
//!
//! `http/allowance.zig` already answers this for a value that is one `u64`: a
//! fixed table in `.bss`, four ways to a bucket, a fingerprint per way, and the
//! stalest way forgotten when a bucket fills. Nothing allocates, ever, and one
//! 64-byte cache line is touched per request.
//!
//! A cache is the same table with a harder value. `Cart` is not a `u64` and
//! two of them are not the same length, so the bytes have to live somewhere the
//! slot can point at — and the moment a slot points at bytes, three questions
//! arrive that the counter never had:
//!
//!  1. **Who frees them?** go-cache's answer is Go's garbage collector, which
//!     is why its design does not survive translation.
//!  2. **What stops a reader copying bytes another thread is overwriting?**
//!  3. **What does eviction cost when the entries are different sizes?** A
//!     free list fragments; slab classes waste.
//!
//! ## The shape under test
//!
//! One ring of bytes, owned by the cache, sized once at init. A put reserves
//! its bytes with a single `fetchAdd` on a position that **only ever goes
//! forwards**, then copies key and value in. The ring is a window on that
//! position: everything in `[head - capacity, head)` is live, everything older
//! has been overwritten by newer entries. That is the answer to all three at
//! once — nothing is freed because nothing is owned individually, eviction is
//! what writing does, and no size class exists to waste.
//!
//! A reader is where it gets interesting, and this is the part the spike is
//! actually for:
//!
//! ```
//! pos = slot.pos            // where the entry was written
//! copy key and value out of the ring
//! if (head_now - pos > capacity) -> miss    // it moved under us; throw the copy away
//! ```
//!
//! The check **after** the copy was supposed to be the whole trick: if the
//! window still holds `pos` once the copy is done, nothing overwrote those
//! bytes while it was being made.
//!
//! **It does not hold, and that is this spike's finding.** The reader is not
//! the only thread that can be interrupted. A *writer* descheduled inside its
//! own `memcpy` is lapped by the ring and writes its bytes over an entry newer
//! than itself, and the victim's position is recent enough to pass every check
//! a reader makes. Seven wrong values in 1.9 million hits, with more threads
//! than cores. `README.md` has the tables.
//!
//! So both shapes are here. `Cache.locked` picks between them, and the run
//! that matters is the one where they disagree.
//!
//! ## What a torn slot costs — and what it does not cover
//!
//! A slot is two `u64`s and a reader loads them separately, so it can pair the
//! position of one entry with the length of another. That is deliberate and it
//! is safe, because **the full key is stored in the ring and compared there**.
//! A mismatched pair reads bytes whose key is not the one asked for, so it
//! misses. A fingerprint alone would not be enough — it would hand back another
//! key's value — which is why the key is in the ring rather than only the hash.
//!
//! ## Modes
//!
//! ```
//! main torture <writers> <readers> <seconds> <shards> <locked>
//! main bench   <threads> <seconds> <shards> <locked>
//! main hit     <working-set> <ring-mb>
//! ```

const std = @import("std");
const builtin = @import("builtin");

// -- the cache -----------------------------------------------------------

/// Sixteen bytes, so four ways are one 64-byte cache line — the property
/// `allowance.zig` is built around and the reason the expiry is not in here.
/// It lives in the ring entry's header instead, where it is covered by the
/// same window check as the value.
const Slot = struct {
    /// Ring position of the entry, monotonically increasing. Zero means the
    /// way has never been written.
    pos: std.atomic.Value(u64) = .init(0),
    /// `fp` in the high 32 bits, key length in the next 16, value length in
    /// the low 16. One word, so a reader takes it in one load.
    meta: std.atomic.Value(u64) = .init(0),
};

const ways = 4;

/// What a reader is told, so a miss can say *why* it missed. The three
/// reasons are different findings: `absent` is an ordinary cold cache,
/// `evicted` is the ring being too small, and `raced` is the post-copy check
/// firing — the number this spike exists to produce.
const Miss = enum { absent, evicted, raced, expired };

const Result = union(enum) { hit: []const u8, miss: Miss };

const Shard = struct {
    slots: []Slot,
    ring: []u8,
    /// Bytes written since init. Never wraps in any run this can survive:
    /// at 10 GB/s it takes 58 years to overflow a u64.
    head: std.atomic.Value(u64),
    buckets: u64,
    cap: u64,
    started_s: i64,

    /// Values over 64 KB do not fit the 16 bits the slot gives their length.
    /// A real module refuses them by name; the spike asserts.
    const max_value = 65535;
    const max_key = 65535;
    /// Expiry, key length and value length, ahead of the key in the ring.
    const header = 4;

    fn init(gpa: std.mem.Allocator, buckets: u64, cap: u64) !Shard {
        std.debug.assert(std.math.isPowerOfTwo(buckets));
        std.debug.assert(std.math.isPowerOfTwo(cap));
        const slots = try gpa.alloc(Slot, buckets * ways);
        @memset(slots, .{});
        const ring = try gpa.alloc(u8, cap);
        // Touched once so the pages are resident and the first thousand
        // operations are not measuring the kernel handing them over.
        @memset(ring, 0);
        return .{
            .slots = slots,
            .ring = ring,
            // Starting at `cap` rather than 0 keeps `head - cap` from going
            // negative on the first reads, and keeps 0 free to mean "never
            // written".
            .head = .init(cap),
            .buckets = buckets,
            .cap = cap,
            .started_s = monotonicSeconds(),
        };
    }

    fn deinit(self: *Shard, gpa: std.mem.Allocator) void {
        gpa.free(self.slots);
        gpa.free(self.ring);
    }

    fn bucketOf(self: *const Shard, hash: u64) []Slot {
        const idx = (hash & (self.buckets - 1)) * ways;
        return self.slots[idx..][0..ways];
    }

    fn copyIn(self: *Shard, pos: u64, bytes: []const u8) void {
        const at: usize = @intCast(pos & (self.cap - 1));
        const first = @min(bytes.len, self.ring.len - at);
        @memcpy(self.ring[at..][0..first], bytes[0..first]);
        if (first < bytes.len) @memcpy(self.ring[0 .. bytes.len - first], bytes[first..]);
    }

    fn copyOut(self: *const Shard, pos: u64, out: []u8) void {
        const at: usize = @intCast(pos & (self.cap - 1));
        const first = @min(out.len, self.ring.len - at);
        @memcpy(out[0..first], self.ring[at..][0..first]);
        if (first < out.len) @memcpy(out[first..], self.ring[0 .. out.len - first]);
    }

    /// Reserve, write, publish. The reservation is one `fetchAdd`, so two
    /// writers never get the same bytes; the publish is last, so a reader
    /// that sees the slot sees bytes that are already there.
    fn put(self: *Shard, key: []const u8, value: []const u8, ttl_s: u32) void {
        std.debug.assert(key.len <= max_key and value.len <= max_value);
        const total = header + key.len + value.len;

        const pos = self.head.fetchAdd(total, .monotonic);
        var head_bytes: [header]u8 = undefined;
        const expires: u32 = if (ttl_s == 0) 0 else @intCast(self.elapsed() + ttl_s);
        std.mem.writeInt(u32, &head_bytes, expires, .little);
        self.copyIn(pos, &head_bytes);
        self.copyIn(pos + header, key);
        self.copyIn(pos + header + key.len, value);

        const hash = std.hash.Wyhash.hash(0, key);
        const meta = pack(fingerprint(hash), @intCast(key.len), @intCast(value.len));
        const bucket = self.bucketOf(hash);

        // Prefer the way already holding this key, then one never written,
        // then the stalest. Two writers can choose the same way and one
        // loses; the loser's bytes sit in the ring unreferenced until the
        // window passes them. That wastes space and corrupts nothing.
        var chosen: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (bucket, 0..) |*slot, i| {
            const p = slot.pos.load(.monotonic);
            if (p == 0) {
                chosen = i;
                break;
            }
            if (slot.meta.load(.monotonic) == meta) {
                chosen = i;
                break;
            }
            if (p < oldest) {
                oldest = p;
                chosen = i;
            }
        }
        bucket[chosen].meta.store(meta, .monotonic);
        bucket[chosen].pos.store(pos, .release);
    }

    /// `out` is the caller's. Nothing here allocates, and the signature is
    /// what says so — there is no allocator to pass.
    fn get(self: *Shard, key: []const u8, out: []u8) Result {
        const hash = std.hash.Wyhash.hash(0, key);
        const want = fingerprint(hash);
        const bucket = self.bucketOf(hash);

        var seen_evicted = false;
        for (bucket) |*slot| {
            const pos = slot.pos.load(.acquire);
            if (pos == 0) continue;
            const meta = slot.meta.load(.monotonic);
            if (fpOf(meta) != want) continue;

            const klen = klenOf(meta);
            const vlen = vlenOf(meta);
            if (klen != key.len or vlen > out.len) continue;

            // Cheap first check. The one that decides is after the copy.
            if (self.head.load(.monotonic) -% pos > self.cap) {
                seen_evicted = true;
                continue;
            }

            var head_bytes: [header]u8 = undefined;
            self.copyOut(pos, &head_bytes);
            var key_buf: [256]u8 = undefined;
            if (klen > key_buf.len) continue;
            self.copyOut(pos + header, key_buf[0..klen]);
            self.copyOut(pos + header + klen, out[0..vlen]);

            // The check the whole shape rests on. Everything copied above is
            // trustworthy only if the window still holds `pos` now.
            if (self.head.load(.acquire) -% pos > self.cap) return .{ .miss = .raced };

            if (!std.mem.eql(u8, key_buf[0..klen], key)) continue;

            const expires = std.mem.readInt(u32, &head_bytes, .little);
            if (expires != 0 and self.elapsed() >= expires) return .{ .miss = .expired };

            return .{ .hit = out[0..vlen] };
        }
        return .{ .miss = if (seen_evicted) .evicted else .absent };
    }

    fn elapsed(self: *const Shard) u32 {
        return @intCast(monotonicSeconds() - self.started_s);
    }

    fn fingerprint(hash: u64) u32 {
        // Never zero, because zero is how `meta` says "never written".
        return @as(u32, @truncate(hash >> 32)) | 1;
    }
    fn pack(fp: u32, klen: u16, vlen: u16) u64 {
        return (@as(u64, fp) << 32) | (@as(u64, klen) << 16) | @as(u64, vlen);
    }
    fn fpOf(meta: u64) u32 {
        return @truncate(meta >> 32);
    }
    fn klenOf(meta: u64) u16 {
        return @truncate(meta >> 16);
    }
    fn vlenOf(meta: u64) u16 {
        return @truncate(meta);
    }
};

/// What a caller holds. The ring and the table live in a Shard; this routes
/// to one and decides whether a lock is taken on the way in.
///
/// **`locked` is a field rather than a second type on purpose.** Both shapes
/// then run the same `put` and the same `get`, so the comparison below is
/// about the lock and nothing else. A shipped module would make it comptime
/// and pay no branch.
///
/// The lock, when taken, is held across a `memcpy` and nothing else. It never
/// waits on anything, which is what makes it safe to hold inside a fiber: a
/// fiber only moves at a point that waits, and there is no such point in here.
const Cache = struct {
    shards: []Shard,
    locks: []Lock,
    locked: bool,

    /// A spin lock, and **not by preference**. Zig 0.16's `std.Io.Mutex.lock`
    /// takes an `io: Io` — it parks the caller on a futex, and parking is
    /// something only a runtime can do. A module with no event loop has no
    /// `Io` to hand it, so a module in the tool layer cannot have a mutex at
    /// all without dragging `Io` into `get`'s signature and leaving the layer.
    ///
    /// That is the language deciding the shape rather than a taste: with only
    /// `tryLock` available, the critical section **must** stay short enough to
    /// spin on, which here means a `memcpy` and nothing else. It also means a
    /// holder that gets descheduled makes every other thread burn CPU, which
    /// is the cost this run is measuring.
    ///
    /// One to a cache line, or two shards would share one and the sharding
    /// would buy nothing.
    const Lock = struct {
        held: std.atomic.Value(bool) align(64) = .init(false),

        fn lock(l: *Lock) void {
            while (l.held.swap(true, .acquire)) std.atomic.spinLoopHint();
        }
        fn unlock(l: *Lock) void {
            l.held.store(false, .release);
        }
    };

    fn init(gpa: std.mem.Allocator, shards_n: u64, buckets: u64, cap: u64, locked: bool) !Cache {
        std.debug.assert(std.math.isPowerOfTwo(shards_n));
        const shards = try gpa.alloc(Shard, shards_n);
        for (shards) |*s| s.* = try Shard.init(gpa, buckets / shards_n, cap / shards_n);
        const locks = try gpa.alloc(Lock, shards_n);
        for (locks) |*l| l.* = .{};
        return .{ .shards = shards, .locks = locks, .locked = locked };
    }

    fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
        for (self.shards) |*s| s.deinit(gpa);
        gpa.free(self.shards);
        gpa.free(self.locks);
    }

    /// A different seed from the one the bucket index uses, so which shard a
    /// key lands in is independent of which way it takes inside it.
    fn shardOf(self: *const Cache, key: []const u8) usize {
        return @intCast(std.hash.Wyhash.hash(1, key) & (self.shards.len - 1));
    }

    fn put(self: *Cache, key: []const u8, value: []const u8, ttl_s: u32) void {
        const i = self.shardOf(key);
        if (self.locked) self.locks[i].lock();
        defer if (self.locked) self.locks[i].unlock();
        self.shards[i].put(key, value, ttl_s);
    }

    fn get(self: *Cache, key: []const u8, out: []u8) Result {
        const i = self.shardOf(key);
        if (self.locked) self.locks[i].lock();
        defer if (self.locked) self.locks[i].unlock();
        return self.shards[i].get(key, out);
    }
};

// -- the clock -----------------------------------------------------------

fn monotonicMicros() i64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
        .SUCCESS => {},
        else => |e| std.debug.panic("clock: {s}", .{@tagName(e)}),
    }
    return @as(i64, @intCast(ts.sec)) * std.time.us_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_us);
}

fn monotonicSeconds() i64 {
    return @divFloor(monotonicMicros(), std.time.us_per_s);
}

// -- a value that can be checked -----------------------------------------

/// A value whose own bytes say which key wrote them and how long they are, so
/// a reader that is handed the wrong entry — or half of two — can say so
/// rather than merely returning something plausible.
fn writeValue(buf: []u8, id: u64, len: usize) []const u8 {
    std.mem.writeInt(u64, buf[0..8], id, .little);
    std.mem.writeInt(u64, buf[8..16], len, .little);
    var i: usize = 16;
    while (i < len) : (i += 1) buf[i] = @truncate(id +% i);
    return buf[0..len];
}

fn checkValue(bytes: []const u8, id: u64) bool {
    if (bytes.len < 16) return false;
    if (std.mem.readInt(u64, bytes[0..8], .little) != id) return false;
    if (std.mem.readInt(u64, bytes[8..16], .little) != bytes.len) return false;
    var i: usize = 16;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] != @as(u8, @truncate(id +% i))) return false;
    }
    return true;
}

fn keyFor(buf: []u8, id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "cart:{d}", .{id}) catch unreachable;
}

/// Lengths that vary, because a cache of one length would never exercise the
/// thing this spike is about.
fn lengthFor(id: u64) usize {
    return 24 + (id % 977);
}

// -- torture -------------------------------------------------------------

const Torture = struct {
    cache: *Cache,
    keys: u64,
    stop: *std.atomic.Value(bool),
    puts: u64 = 0,
    gets: u64 = 0,
    hits: u64 = 0,
    raced: u64 = 0,
    evicted: u64 = 0,
    absent: u64 = 0,
    /// The number that decides whether the shape works. Anything but zero and
    /// the design is wrong, not the tuning.
    wrong: u64 = 0,
};

fn writer(t: *Torture, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var key_buf: [64]u8 = undefined;
    var val_buf: [1024]u8 = undefined;
    while (!t.stop.load(.monotonic)) {
        var n: usize = 0;
        while (n < 256) : (n += 1) {
            const id = rand.uintLessThan(u64, t.keys);
            const value = writeValue(&val_buf, id, lengthFor(id));
            t.cache.put(keyFor(&key_buf, id), value, 0);
            t.puts += 1;
        }
    }
}

fn reader(t: *Torture, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var key_buf: [64]u8 = undefined;
    var out: [1024]u8 = undefined;
    while (!t.stop.load(.monotonic)) {
        var n: usize = 0;
        while (n < 256) : (n += 1) {
            const id = rand.uintLessThan(u64, t.keys);
            t.gets += 1;
            switch (t.cache.get(keyFor(&key_buf, id), &out)) {
                .hit => |v| {
                    t.hits += 1;
                    if (!checkValue(v, id)) t.wrong += 1;
                },
                .miss => |why| switch (why) {
                    .raced => t.raced += 1,
                    .evicted => t.evicted += 1,
                    else => t.absent += 1,
                },
            }
        }
    }
}

fn torture(gpa: std.mem.Allocator, writers: usize, readers: usize, seconds: u64, shards_n: u64, locked: bool) !void {
    // Deliberately small: a ring that holds the whole working set never
    // overwrites anything, and never overwriting anything is exactly the case
    // this mode is not testing.
    const ring_mb = 1;
    var cache = try Cache.init(gpa, shards_n, 1 << 14, ring_mb << 20, locked);
    std.debug.print("shards={d} locked={}\n", .{ shards_n, locked });
    defer cache.deinit(gpa);

    var stop: std.atomic.Value(bool) = .init(false);
    const keys: u64 = 20_000;

    const states = try gpa.alloc(Torture, writers + readers);
    defer gpa.free(states);
    for (states) |*s| s.* = .{ .cache = &cache, .keys = keys, .stop = &stop };

    const threads = try gpa.alloc(std.Thread, writers + readers);
    defer gpa.free(threads);

    for (0..writers) |i| threads[i] = try std.Thread.spawn(.{}, writer, .{ &states[i], 1 + i });
    for (0..readers) |i| threads[writers + i] = try std.Thread.spawn(.{}, reader, .{ &states[writers + i], 1000 + i });

    const until = monotonicMicros() + @as(i64, @intCast(seconds)) * std.time.us_per_s;
    while (monotonicMicros() < until) {
        std.atomic.spinLoopHint();
    }
    stop.store(true, .monotonic);
    for (threads) |th| th.join();

    var total: Torture = .{ .cache = &cache, .keys = keys, .stop = &stop };
    for (states) |s| {
        total.puts += s.puts;
        total.gets += s.gets;
        total.hits += s.hits;
        total.raced += s.raced;
        total.evicted += s.evicted;
        total.absent += s.absent;
        total.wrong += s.wrong;
    }

    std.debug.print(
        \\writers={d} readers={d} seconds={d} ring={d}MB keys={d}
        \\  puts      {d}
        \\  gets      {d}
        \\  hits      {d} ({d:.1}%)
        \\  raced     {d} ({d:.4}% of gets)
        \\  evicted   {d}
        \\  absent    {d}
        \\  WRONG     {d}
        \\
    , .{
        writers,       readers,                                                    seconds, ring_mb, keys,
        total.puts,    total.gets,
        total.hits,    pct(total.hits, total.gets),
        total.raced,   pct(total.raced, total.gets),
        total.evicted, total.absent,
        total.wrong,
    });
    if (total.wrong != 0) std.process.exit(1);
}

fn pct(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(whole));
}

// -- bench ---------------------------------------------------------------

const Bench = struct {
    cache: *Cache,
    stop: *std.atomic.Value(bool),
    ops: u64 = 0,
};

fn benchWorker(b: *Bench, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var key_buf: [64]u8 = undefined;
    var val_buf: [1024]u8 = undefined;
    var out: [1024]u8 = undefined;
    const keys: u64 = 50_000;
    while (!b.stop.load(.monotonic)) {
        var n: usize = 0;
        while (n < 512) : (n += 1) {
            const id = rand.uintLessThan(u64, keys);
            // Nine reads to a write, which is what a cache is for.
            if (n % 10 == 0) {
                const value = writeValue(&val_buf, id, lengthFor(id));
                b.cache.put(keyFor(&key_buf, id), value, 0);
            } else {
                const r = b.cache.get(keyFor(&key_buf, id), &out);
                std.mem.doNotOptimizeAway(&r);
            }
            b.ops += 1;
        }
    }
}

fn bench(gpa: std.mem.Allocator, threads_n: usize, seconds: u64, shards_n: u64, locked: bool) !void {
    var cache = try Cache.init(gpa, shards_n, 1 << 16, 64 << 20, locked);
    std.debug.print("shards={d} locked={}\n", .{ shards_n, locked });
    defer cache.deinit(gpa);

    var stop: std.atomic.Value(bool) = .init(false);
    const states = try gpa.alloc(Bench, threads_n);
    defer gpa.free(states);
    for (states) |*s| s.* = .{ .cache = &cache, .stop = &stop };

    const threads = try gpa.alloc(std.Thread, threads_n);
    defer gpa.free(threads);

    const began = monotonicMicros();
    for (0..threads_n) |i| threads[i] = try std.Thread.spawn(.{}, benchWorker, .{ &states[i], 7 + i });
    const until = began + @as(i64, @intCast(seconds)) * std.time.us_per_s;
    while (monotonicMicros() < until) std.atomic.spinLoopHint();
    stop.store(true, .monotonic);
    for (threads) |th| th.join();
    const took = monotonicMicros() - began;

    var ops: u64 = 0;
    for (states) |s| ops += s.ops;
    const per_s = @as(f64, @floatFromInt(ops)) * 1_000_000.0 / @as(f64, @floatFromInt(took));
    std.debug.print("threads={d} ops={d} in {d}us -> {d:.0} ops/s ({d:.1} ns/op/thread)\n", .{
        threads_n,
        ops,
        took,
        per_s,
        @as(f64, @floatFromInt(took)) * 1000.0 * @as(f64, @floatFromInt(threads_n)) / @as(f64, @floatFromInt(ops)),
    });
}

// -- hit rate ------------------------------------------------------------

/// What the window costs. A ring big enough for the working set behaves like
/// a map; a ring smaller than it forgets, and the question is whether it
/// forgets gracefully or falls off a cliff.
fn hitRate(gpa: std.mem.Allocator, working_set: u64, ring_mb: u64) !void {
    var cache = try Cache.init(gpa, 1, 1 << 16, ring_mb << 20, false);
    defer cache.deinit(gpa);

    var key_buf: [64]u8 = undefined;
    var val_buf: [1024]u8 = undefined;
    var out: [1024]u8 = undefined;

    var bytes: u64 = 0;
    for (0..working_set) |i| {
        const id: u64 = @intCast(i);
        const len = lengthFor(id);
        bytes += Shard.header + keyFor(&key_buf, id).len + len;
        cache.put(keyFor(&key_buf, id), writeValue(&val_buf, id, len), 0);
    }

    var hits: u64 = 0;
    var evicted: u64 = 0;
    var wrong: u64 = 0;
    for (0..working_set) |i| {
        const id: u64 = @intCast(i);
        switch (cache.get(keyFor(&key_buf, id), &out)) {
            .hit => |v| {
                hits += 1;
                if (!checkValue(v, id)) wrong += 1;
            },
            .miss => |why| if (why == .evicted) {
                evicted += 1;
            },
        }
    }

    std.debug.print("working_set={d} ring={d}MB stored={d}B ({d:.1}% of ring) hits={d} ({d:.1}%) evicted={d} WRONG={d}\n", .{
        working_set,
        ring_mb,
        bytes,
        pct(bytes, ring_mb << 20),
        hits,
        pct(hits, working_set),
        evicted,
        wrong,
    });
    if (wrong != 0) std.process.exit(1);
}

// -- main ----------------------------------------------------------------

/// Zig 0.16 hands the command line to `main` rather than having it fetched,
/// and `Init.Minimal` is the smaller of the two shapes — the same one
/// `http/fuzz_main.zig` takes.
pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    std.debug.print("slot={d}B bucket={d}B optimize={s}\n", .{
        @sizeOf(Slot),
        @sizeOf(Slot) * ways,
        @tagName(builtin.mode),
    });

    var it: std.process.Args.Iterator = .init(init.args);
    _ = it.skip(); // the program's own name

    var rest: [5]u64 = .{ 0, 0, 0, 0, 0 };
    var given: usize = 0;
    const mode = it.next() orelse return usage();
    while (it.next()) |arg| {
        if (given == rest.len) return usage();
        rest[given] = std.fmt.parseInt(u64, arg, 10) catch return usage();
        given += 1;
    }

    if (std.mem.eql(u8, mode, "torture")) {
        try torture(gpa, or_(rest, given, 0, 2), or_(rest, given, 1, 2), or_(rest, given, 2, 5), or_(rest, given, 3, 1), or_(rest, given, 4, 0) != 0);
    } else if (std.mem.eql(u8, mode, "bench")) {
        try bench(gpa, or_(rest, given, 0, 1), or_(rest, given, 1, 3), or_(rest, given, 2, 1), or_(rest, given, 3, 0) != 0);
    } else if (std.mem.eql(u8, mode, "hit")) {
        try hitRate(gpa, or_(rest, given, 0, 10_000), or_(rest, given, 1, 1));
    } else {
        return usage();
    }
}

fn or_(rest: [5]u64, given: usize, i: usize, default: u64) u64 {
    return if (i < given) rest[i] else default;
}

fn usage() void {
    std.debug.print(
        \\usage:
        \\  torture <writers> <readers> <seconds> <shards> <locked>  correctness under concurrency
        \\  bench   <threads> <seconds> <shards> <locked>            operations a second
        \\  hit     <working-set> <ring-mb>                          what the window costs in hit rate
        \\
    , .{});
}
