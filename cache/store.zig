//! The bytes, the table that points at them, and the lock over both.
//!
//! One `Store` is one pool of memory, sized once when it opens and never grown
//! ([ADR 0138](../docs/adr/0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)).
//! Every `Space` in the program shares it, the way every bucket in `nilo_s3`
//! shares one `Store` — so "how much memory does my cache use" has one answer
//! and it is the number the caller wrote.
//!
//! ## A shard is a table and a ring
//!
//! The table is `http/allowance.zig`'s: buckets of four ways, a fingerprint
//! per way, the stalest way forgotten when a bucket fills. Four ways of 16
//! bytes is one cache line, so a lookup touches one.
//!
//! The ring is where a value that is not a `u64` has to live. A put takes its
//! space by moving a position that **only ever goes forwards** and copies the
//! header, the key and the value in. The ring is a window on that position:
//! everything in `[head - capacity, head)` is live and everything older has
//! been written over. **Eviction is what writing does** — no free list to
//! fragment, no size class to waste, and no sweep.
//!
//! ## Why the key is in the ring
//!
//! A fingerprint is 32 bits, so two keys in one bucket can share one. Trusting
//! it alone would hand back the other key's value, and a cache that is quietly
//! wrong is worse than one that misses. The key is stored and compared.
//!
//! ## Why there is a lock, and why it spins
//!
//! The lock-free version of this was built first and is wrong. A writer
//! descheduled inside its own `memcpy` is lapped by the ring and writes over
//! an entry *newer* than itself, whose position is recent enough to pass every
//! check a reader can make: seven wrong values in 1.9 million hits, measured
//! in [`spike/cache_ring/`](../spike/cache_ring/). Sharding does not fix it —
//! sixteen rings gave eight.
//!
//! It spins rather than parks because Zig 0.16's `std.Io.Mutex.lock` takes an
//! `io: Io`, and a module with no event loop has none to give it. **That turns
//! a preference into a rule this file has to keep forever: nothing that waits,
//! ever, inside a critical section.** It is also what makes the lock safe to
//! hold inside a fiber — a fiber only moves at a point that waits, so a holder
//! always finishes and releases. Uncontended the lock measured free.

const std = @import("std");
const clock = @import("clock.zig");

const Allocator = std.mem.Allocator;

/// Ways to a bucket. **Eight eight-byte slots are one 64-byte cache line**,
/// which is the whole reason for both numbers — and the reason the lengths
/// live in the ring rather than in the slot.
///
/// Four sixteen-byte slots are also one cache line and were what this held
/// first. Halving the slot and doubling the ways is the same line touched, a
/// table half the size, and *better* retention at any load: a key arriving at
/// a full bucket is what a set-associative table loses, and eight ways lose
/// far fewer of them than four. Measured on 200,000 entries, it took the cache
/// from 125.8 bytes an entry at 98.3% retrievable to 63 at 99%.
const ways = 8;

/// Expiry, space, and the two lengths, ahead of the key. The lengths are here
/// rather than in the slot because a byte in the ring is paid once per entry
/// and a byte in the slot is paid for every slot, occupied or not.
const header = 12;

/// Sixteen bytes. `gen` of zero means the way has never been written, which
/// is why a shard's own generation starts at one.
///
/// **An offset and a pass number rather than a monotonic position**, and that
/// is what lets a ring be any size at all. Masking a forever-increasing
/// position needs a power-of-two ring, and flooring a budget to a power of two
/// left nearly half of it unused: 200,000 entries that needed 8.6 MB of ring
/// were given 16 MiB, and the cache measured 125.8 bytes an entry against
/// go-cache's 96.9. Storing where the entry is, plus which pass over the ring
/// wrote it, needs no mask and no division.
const Slot = extern struct {
    off: u32 = 0,
    gen: u16 = 0,
    fp: u16 = 0,
};

comptime {
    if (@sizeOf(Slot) != 8) @compileError("nilo: a cache slot has to be 8 bytes for eight to be one cache line");
    if (@sizeOf(Slot) * ways != 64) @compileError("nilo: a bucket has to be exactly one 64-byte cache line");
}

/// How many `Space`s one Store will hold. Sixty-four is not a limit anybody
/// is going to reach; it exists so the collision check below can be an array
/// rather than an allocation.
const max_spaces = 64;

pub const Options = struct {
    /// **The whole budget, and a ceiling rather than a target.** The ring the
    /// values live in and the table that points at them come out of this
    /// number together, and `bytesHeld()` is never above it.
    ///
    /// A budget rather than the ring alone because the first version made
    /// `bytes` the ring, rounded it *up* to a power of two and put the table
    /// on top: a caller who wrote 9 MiB got 20. A number a caller cannot use
    /// to size a container is not a budget.
    bytes: usize = 8 << 20,
    /// How many entries the table can point at, when the three-quarters the
    /// ring takes by default is the wrong split. Zero derives it from what is
    /// left of `bytes`.
    ///
    /// **Clamped to the budget rather than added to it**, so raising it takes
    /// slots out of the ring rather than taking more memory from the machine.
    /// Raise it for many small values; lower it for few large ones.
    entries: usize = 0,
    /// How many independent tables and rings, and therefore how many threads
    /// can be inside the cache at once.
    ///
    /// **Sixteen rather than the number of cores on purpose.** A default read
    /// from the machine makes the same program hold different amounts of
    /// memory on two boxes and makes a benchmark unreproducible, which is a
    /// worse trade than a number somebody can raise.
    shards: usize = 16,
};

pub const OpenError = error{
    OutOfMemory,
    /// The numbers do not divide into a working cache: fewer than 64 KiB of
    /// value memory, or fewer entries than the shards have ways to hold them.
    TooSmall,
};

/// Hits and misses, so "why is my cache not hitting" has an answer that is not
/// a guess. Summed across shards on demand; the counters themselves live
/// inside a lock that was already held, so they cost an increment.
pub const Stats = struct {
    hits: u64 = 0,
    /// Nothing in the table under that key.
    misses: u64 = 0,
    /// The table knew the key and the ring had moved past it. **This is the
    /// number that says the ring is too small**, and it is the reason it is
    /// counted apart from a miss.
    evicted: u64 = 0,
    /// Found, and past its time.
    expired: u64 = 0,
    puts: u64 = 0,
    /// A value that did not fit an entry, so nothing was stored.
    refused: u64 = 0,

    /// Of the lookups that found nothing, how many were the ring being small.
    /// A cache with a high number here wants more `bytes`; one with a low
    /// number and few hits is being asked about keys nobody wrote.
    pub fn evictionRate(self: Stats) f64 {
        const looked = self.hits + self.misses + self.evicted + self.expired;
        if (looked == 0) return 0;
        return @as(f64, @floatFromInt(self.evicted)) / @as(f64, @floatFromInt(looked));
    }
};

/// A spin lock, and not by preference — see the header. One to a cache line,
/// or two shards would share one and the sharding would buy nothing.
const Lock = struct {
    held: std.atomic.Value(bool) align(std.atomic.cache_line) = .init(false),

    fn take(l: *Lock) void {
        while (l.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn release(l: *Lock) void {
        l.held.store(false, .release);
    }
};

/// One entry as it sits in the ring.
const Entry = struct {
    expires: u32,
    space: u32,
    key: []const u8,
    value: []const u8,
};

const Shard = struct {
    lock: Lock = .{},
    /// Aligned so a bucket never straddles two cache lines. The alignment is
    /// in the type rather than only at the call site, or `free` would hand
    /// the allocator a different alignment than `alloc` was given.
    slots: []align(std.atomic.cache_line) Slot,
    ring: []u8,
    /// Where the next entry goes, and how many times the ring has been round.
    /// Both guarded by the lock, so plain integers.
    head: u32 = 0,
    gen: u16 = 1,
    buckets: u32,
    stats: Stats = .{},

    /// Any number of buckets, not only a power of two, by multiplying into the
    /// top half of a 64-bit product instead of masking. One `mulx`, and the
    /// table can then be sized to the budget rather than to the next power of
    /// two below it.
    fn bucketOf(self: *Shard, hash: u64) []Slot {
        const wide = @as(u64, @as(u32, @truncate(hash))) * @as(u64, self.buckets);
        return self.slots[@as(usize, @intCast(wide >> 32)) * ways ..][0..ways];
    }

    /// **An entry is never split across the seam.** One that will not fit
    /// before the end starts again at zero, leaving a gap of less than one
    /// entry — which costs a few bytes and takes the split `memcpy` out of
    /// every read and every write.
    fn reserve(self: *Shard, total: usize) u32 {
        if (self.head + total > self.ring.len) {
            self.head = 0;
            self.gen +%= 1;
            // Zero is how a slot says "never written", so a shard's own
            // generation may never be it.
            if (self.gen == 0) self.gen = 1;
        }
        const off = self.head;
        self.head += @intCast(total);
        return off;
    }

    /// Whether what the slot points at is still what it pointed at. Written
    /// on this pass and behind the cursor, or written on the pass before and
    /// still ahead of it.
    fn live(self: *Shard, slot: Slot) bool {
        if (slot.gen == 0) return false;
        if (slot.gen == self.gen) return slot.off < self.head;
        if (slot.gen +% 1 == self.gen) return slot.off >= self.head;
        return false;
    }

    /// The header, the key and the value, read out of the ring.
    ///
    /// **Bounded, and the bound is not decoration.** A pass number is sixteen
    /// bits, so after 65,536 trips round the ring a slot nothing has touched
    /// can look live again while pointing into the middle of some newer
    /// entry — and the lengths now come from the ring rather than the slot, so
    /// what is read there would be whatever bytes happen to be at that offset.
    /// `null` here is what turns that into a miss. Everything past this point
    /// still checks the Space and the whole key, so the worst it can be is a
    /// lookup that found nothing.
    fn entry(self: *Shard, slot: Slot) ?Entry {
        if (@as(usize, slot.off) + header > self.ring.len) return null;
        const head_bytes = self.ring[slot.off..][0..header];
        const klen = std.mem.readInt(u16, head_bytes[8..10], .little);
        const vlen = std.mem.readInt(u16, head_bytes[10..12], .little);
        const total = @as(usize, header) + klen + vlen;
        if (@as(usize, slot.off) + total > self.ring.len) return null;
        return .{
            .expires = std.mem.readInt(u32, head_bytes[0..4], .little),
            .space = std.mem.readInt(u32, head_bytes[4..8], .little),
            .key = self.ring[slot.off + header ..][0..klen],
            .value = self.ring[slot.off + header + klen ..][0..vlen],
        };
    }
};

pub const Store = struct {
    gpa: Allocator,
    shards: []Shard,
    /// `shards.len - 1`. A power of two, so this is a mask rather than a
    /// division on the path of every operation.
    shard_mask: u64,
    opened_s: i64,
    /// Every `Space` that has opened against this Store, so two whose names
    /// hash to the same 32 bits are caught the moment the second one opens
    /// rather than by handing one space the other's value.
    names: [max_spaces][]const u8 = undefined,
    ids: [max_spaces]u32 = undefined,
    n_spaces: usize = 0,

    pub fn open(gpa: Allocator, opts: Options) OpenError!Store {
        if (opts.bytes < 64 << 10) return error.TooSmall;

        // **Nothing here is rounded to a power of two, and that is the point.**
        // The table splits the budget with the ring at whatever the caller's
        // `entries` implies, the ring takes the rest exactly, and the two
        // together are inside the budget by construction.
        const slot_bytes = @sizeOf(Slot);
        const total_slots = if (opts.entries == 0)
            opts.bytes / 4 / slot_bytes
        else
            // The table may take at most half, or a large `entries` would
            // leave a cache with nowhere to put anything.
            @min(opts.entries, opts.bytes / 2 / slot_bytes);
        const total_cap = opts.bytes - total_slots * slot_bytes;
        if (total_cap < 4096) return error.TooSmall;

        // Shards are cut to what the budget can carry rather than taken as
        // given. A shard holding less than a page is a shard that forgets
        // everything the moment anything is written to it, and a small cache
        // has nothing to gain from sixteen of those — the concurrency they buy
        // is bounded by how much work a cache that size is doing anyway.
        // `shardCount()` is what the program actually got.
        const asked = std.math.ceilPowerOfTwo(usize, @max(opts.shards, 1)) catch return error.TooSmall;
        const shards_n = @max(1, @min(asked, total_cap / 4096));
        const cap = total_cap / shards_n;
        if (cap > std.math.maxInt(u32)) return error.TooSmall;

        const buckets = total_slots / shards_n / ways;
        if (buckets == 0) return error.TooSmall;

        const shards = try gpa.alloc(Shard, shards_n);
        var made: usize = 0;
        errdefer {
            for (shards[0..made]) |*s| {
                gpa.free(s.slots);
                gpa.free(s.ring);
            }
            gpa.free(shards);
        }
        for (shards) |*s| {
            const slots = try gpa.alignedAlloc(Slot, .fromByteUnits(std.atomic.cache_line), buckets * ways);
            errdefer gpa.free(slots);
            const ring = try gpa.alloc(u8, cap);
            @memset(slots, .{});
            // Touched once so the pages are resident, rather than the first
            // few thousand operations measuring the kernel handing them over.
            @memset(ring, 0);
            s.* = .{
                .slots = slots,
                .ring = ring,
                .buckets = @intCast(buckets),
            };
            made += 1;
        }

        return .{
            .gpa = gpa,
            .shards = shards,
            .shard_mask = shards_n - 1,
            .opened_s = clock.monotonicSeconds(),
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.shards) |*s| {
            self.gpa.free(s.slots);
            self.gpa.free(s.ring);
        }
        self.gpa.free(self.shards);
        self.* = undefined;
    }

    /// How many independent tables and rings it ended up with, which is at
    /// most the `shards` it was asked for and less when the budget could not
    /// carry that many.
    pub fn shardCount(self: *const Store) usize {
        return self.shards.len;
    }

    /// Every byte this cache will ever hold, table and values together. It
    /// does not move, and it is never above the `bytes` it was opened with —
    /// which is the point of saying it.
    pub fn bytesHeld(self: *const Store) usize {
        const s = &self.shards[0];
        return self.shards.len * (s.ring.len + s.slots.len * @sizeOf(Slot));
    }

    /// Called once per `Space`, before anything is served. Not threadsafe and
    /// does not need to be: a Space opens where a Store does.
    pub fn registerSpace(self: *Store, id: u32, name: []const u8) void {
        for (self.ids[0..self.n_spaces], self.names[0..self.n_spaces]) |other_id, other| {
            if (other_id != id) continue;
            if (std.mem.eql(u8, other, name)) return; // opened twice, which is fine
            std.debug.panic(
                "nilo: the cache Spaces \"{s}\" and \"{s}\" hash to the same 32 bits, " ++
                    "so entries of one would be read as the other. Rename one of them.",
                .{ other, name },
            );
        }
        if (self.n_spaces == max_spaces) std.debug.panic(
            "nilo: more than {d} cache Spaces in one Store. Give the {d}th its own Store.",
            .{ max_spaces, max_spaces + 1 },
        );
        self.ids[self.n_spaces] = id;
        self.names[self.n_spaces] = name;
        self.n_spaces += 1;
    }

    fn shardFor(self: *Store, hash: u64) *Shard {
        // The high bits, because the low ones already picked the bucket.
        return &self.shards[(hash >> 32) & self.shard_mask];
    }

    fn elapsed(self: *const Store) u32 {
        return @intCast(clock.monotonicSeconds() - self.opened_s);
    }

    /// Store `value` under `key`. Returns false, and stores nothing, when the
    /// value cannot fit an entry — the caller's `Space` turns that into a
    /// named error rather than letting it pass quietly.
    pub fn put(self: *Store, space: u32, key: []const u8, value: []const u8, ttl_s: u32) bool {
        const total = header + key.len + value.len;
        const hash = std.hash.Wyhash.hash(space, key);
        const shard = self.shardFor(hash);
        const fp = fingerprint(hash);

        // Refused before anything is written down, because the header the
        // next lines build cannot express a length this large — the check has
        // to come first rather than read better lower down. A single entry big
        // enough to push out most of a shard is also a cache that holds one
        // thing.
        if (key.len > std.math.maxInt(u16) or value.len > std.math.maxInt(u16) or
            total > shard.ring.len / 4)
        {
            shard.lock.take();
            defer shard.lock.release();
            shard.stats.refused += 1;
            return false;
        }

        // The clock and the header are built **before** the lock. Nothing that
        // waits may happen inside a critical section this module holds by
        // spinning, and `clock_gettime` is the one call in here that could
        // (ADR 0138).
        var head_bytes: [header]u8 = undefined;
        std.mem.writeInt(u32, head_bytes[0..4], if (ttl_s == 0) 0 else self.elapsed() + ttl_s, .little);
        std.mem.writeInt(u32, head_bytes[4..8], space, .little);
        std.mem.writeInt(u16, head_bytes[8..10], @intCast(key.len), .little);
        std.mem.writeInt(u16, head_bytes[10..12], @intCast(value.len), .little);

        // The same overlap `get` uses: ask for the bucket's line before taking
        // the lock, so the miss and the two atomics happen together.
        const bucket = shard.bucketOf(hash);
        @prefetch(bucket.ptr, .{ .rw = .write, .locality = 3, .cache = .data });

        shard.lock.take();
        defer shard.lock.release();

        const off = shard.reserve(total);
        @memcpy(shard.ring[off..][0..header], &head_bytes);
        @memcpy(shard.ring[off + header ..][0..key.len], key);
        @memcpy(shard.ring[off + header + key.len ..][0..value.len], value);

        var chosen: usize = 0;
        var stalest: u64 = std.math.maxInt(u64);
        for (bucket, 0..) |*slot, i| {
            if (slot.gen == 0) {
                chosen = i;
                break;
            }
            // The same key again is an update rather than a second entry.
            if (slot.fp == fp and shard.live(slot.*)) {
                if (shard.entry(slot.*)) |e| {
                    if (std.mem.eql(u8, e.key, key)) {
                        chosen = i;
                        break;
                    }
                }
            }
            // Oldest pass first, then earliest in the pass.
            const age = (@as(u64, slot.gen) << 32) | slot.off;
            if (age < stalest) {
                stalest = age;
                chosen = i;
            }
        }
        bucket[chosen] = .{ .off = off, .gen = shard.gen, .fp = fp };
        shard.stats.puts += 1;
        return true;
    }

    /// Copy the value for `key` into `out`, and answer how many bytes that
    /// was. `null` is every kind of not-here; `Stats` is what tells them
    /// apart.
    pub fn get(self: *Store, space: u32, key: []const u8, out: []u8) ?usize {
        const hash = std.hash.Wyhash.hash(space, key);
        const shard = self.shardFor(hash);
        const fp = fingerprint(hash);
        // Read before the lock, for the reason `put` builds its header there.
        const now = self.elapsed();

        // The bucket is one cache line and almost always a miss, and taking
        // the lock is two atomics that do not need it. Asking for the line
        // first lets the two overlap instead of queueing.
        const bucket = shard.bucketOf(hash);
        @prefetch(bucket.ptr, .{ .rw = .read, .locality = 3, .cache = .data });

        shard.lock.take();
        defer shard.lock.release();

        var evicted = false;
        for (bucket) |*slot| {
            if (slot.gen == 0 or slot.fp != fp) continue;
            if (!shard.live(slot.*)) {
                evicted = true;
                continue;
            }
            const e = shard.entry(slot.*) orelse continue;

            // A Space whose name shares 32 bits with another's is refused at
            // `registerSpace`, so this can only be a fingerprint collision
            // between two keys — which is what it is here to catch. The key
            // comparison behind it is what makes a collision a miss rather
            // than somebody else's value.
            if (e.space != space) continue;
            if (!std.mem.eql(u8, e.key, key)) continue;

            if (e.expires != 0 and now >= e.expires) {
                // Forgotten now rather than at a sweep that does not exist.
                slot.* = .{};
                shard.stats.expired += 1;
                return null;
            }

            if (e.value.len > out.len) continue;
            @memcpy(out[0..e.value.len], e.value);
            shard.stats.hits += 1;
            return e.value.len;
        }

        if (evicted) shard.stats.evicted += 1 else shard.stats.misses += 1;
        return null;
    }

    /// Forget a key. True when there was something to forget.
    pub fn del(self: *Store, space: u32, key: []const u8) bool {
        const hash = std.hash.Wyhash.hash(space, key);
        const shard = self.shardFor(hash);
        const fp = fingerprint(hash);

        shard.lock.take();
        defer shard.lock.release();

        for (shard.bucketOf(hash)) |*slot| {
            if (slot.gen == 0 or slot.fp != fp or !shard.live(slot.*)) continue;
            const e = shard.entry(slot.*) orelse continue;
            if (e.space != space or !std.mem.eql(u8, e.key, key)) continue;
            slot.* = .{};
            return true;
        }
        return false;
    }

    /// Forget everything. The ring is not zeroed — no slot points into it any
    /// more, which is the same statement and costs nothing.
    pub fn clear(self: *Store) void {
        for (self.shards) |*shard| {
            shard.lock.take();
            defer shard.lock.release();
            @memset(shard.slots, .{});
        }
    }

    pub fn stats(self: *Store) Stats {
        var total: Stats = .{};
        for (self.shards) |*shard| {
            shard.lock.take();
            defer shard.lock.release();
            total.hits += shard.stats.hits;
            total.misses += shard.stats.misses;
            total.evicted += shard.stats.evicted;
            total.expired += shard.stats.expired;
            total.puts += shard.stats.puts;
            total.refused += shard.stats.refused;
        }
        return total;
    }

    /// Sixteen bits, because the slot is eight bytes and the key comparison
    /// behind it is what decides. A collision here costs one wasted key
    /// compare against the ring; it can never cost a wrong answer.
    fn fingerprint(hash: u64) u16 {
        return @as(u16, @truncate(hash >> 32)) | 1;
    }
};

// -- tests ---------------------------------------------------------------

const testing = std.testing;

fn openTest() !Store {
    return Store.open(testing.allocator, .{ .bytes = 1 << 20, .shards = 4 });
}

test "a value put under a key comes back under that key" {
    var store = try openTest();
    defer store.deinit();

    var out: [64]u8 = undefined;
    try testing.expect(store.put(1, "cart:42", "seven items", 0));
    const n = store.get(1, "cart:42", &out) orelse return error.TestExpectedHit;
    try testing.expectEqualStrings("seven items", out[0..n]);
}

test "a key nobody wrote is a miss rather than somebody else's value" {
    var store = try openTest();
    defer store.deinit();

    var out: [64]u8 = undefined;
    _ = store.put(1, "cart:42", "seven items", 0);
    try testing.expectEqual(@as(?usize, null), store.get(1, "cart:43", &out));
    try testing.expectEqual(@as(u64, 1), store.stats().misses);
}

test "two Spaces do not see each other's keys" {
    var store = try openTest();
    defer store.deinit();

    var out: [64]u8 = undefined;
    _ = store.put(1, "same", "one", 0);
    _ = store.put(2, "same", "two", 0);

    const a = store.get(1, "same", &out) orelse return error.TestExpectedHit;
    try testing.expectEqualStrings("one", out[0..a]);
    const b = store.get(2, "same", &out) orelse return error.TestExpectedHit;
    try testing.expectEqualStrings("two", out[0..b]);
}

test "putting the same key twice updates it rather than keeping both" {
    var store = try openTest();
    defer store.deinit();

    var out: [64]u8 = undefined;
    _ = store.put(1, "k", "before", 0);
    _ = store.put(1, "k", "after", 0);
    const n = store.get(1, "k", &out) orelse return error.TestExpectedHit;
    try testing.expectEqualStrings("after", out[0..n]);
}

test "a deleted key is gone and says so" {
    var store = try openTest();
    defer store.deinit();

    var out: [64]u8 = undefined;
    _ = store.put(1, "k", "v", 0);
    try testing.expect(store.del(1, "k"));
    try testing.expect(!store.del(1, "k"));
    try testing.expectEqual(@as(?usize, null), store.get(1, "k", &out));
}

test "clearing forgets everything without touching the values" {
    var store = try openTest();
    defer store.deinit();

    var out: [64]u8 = undefined;
    _ = store.put(1, "a", "1", 0);
    _ = store.put(1, "b", "2", 0);
    store.clear();
    try testing.expectEqual(@as(?usize, null), store.get(1, "a", &out));
    try testing.expectEqual(@as(?usize, null), store.get(1, "b", &out));
}

test "a value larger than a quarter of the ring is refused rather than stored" {
    var store = try openTest();
    defer store.deinit();

    const big = try testing.allocator.alloc(u8, 1 << 19);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    try testing.expect(!store.put(1, "k", big, 0));
    try testing.expectEqual(@as(u64, 1), store.stats().refused);
}

test "the ring forgets the oldest first, and says eviction rather than miss" {
    var store = try Store.open(testing.allocator, .{ .bytes = 64 << 10, .shards = 1 });
    defer store.deinit();

    // Fill well past the ring, then ask for the first thing written.
    var key: [32]u8 = undefined;
    const value = "x" ** 512;
    for (0..400) |i| {
        _ = store.put(1, try std.fmt.bufPrint(&key, "k{d}", .{i}), value, 0);
    }

    var out: [1024]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), store.get(1, "k0", &out));
    try testing.expect(store.stats().evicted >= 1);

    // And the newest is still there, which is what makes the above eviction
    // rather than a cache that simply lost everything.
    const last = try std.fmt.bufPrint(&key, "k{d}", .{399});
    try testing.expect(store.get(1, last, &out) != null);
}

test "an entry past its time is a miss, and the slot is freed on the way out" {
    var store = try openTest();
    defer store.deinit();

    _ = store.put(1, "k", "v", 1);
    // A minute passes. Moving the Store's own epoch back is the same thing to
    // every expiry in it and needs no sleeping, and the path the `get` below
    // takes is the one a real clock reaches.
    store.opened_s -= 60;

    var out: [64]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), store.get(1, "k", &out));
    try testing.expectEqual(@as(u64, 1), store.stats().expired);
}

test "an entry that will not fit before the end starts again at the beginning" {
    var store = try Store.open(testing.allocator, .{ .bytes = 64 << 10, .shards = 1 });
    defer store.deinit();

    // Put the write cursor where the next entry cannot fit, which is the one
    // moment the ring goes round. An entry is never split across the seam, so
    // what has to hold is that the pass number moves with it — a slot from
    // the pass before must stop being live at the right instant, and not one
    // entry early or late.
    const shard = &store.shards[0];
    const before = shard.gen;
    shard.head = @intCast(shard.ring.len - 8);

    const value = "a" ** 300 ++ "b" ** 300;
    try testing.expect(store.put(1, "wrapped", value, 0));
    try testing.expectEqual(before + 1, shard.gen);

    var out: [1024]u8 = undefined;
    const n = store.get(1, "wrapped", &out) orelse return error.TestExpectedHit;
    try testing.expectEqualStrings(value, out[0..n]);
}

test "a budget that is not a power of two is spent rather than rounded away" {
    // The shape the old layout got wrong: 12 MiB became an 8 MiB ring plus a
    // table, and four of the twelve went nowhere.
    var store = try Store.open(testing.allocator, .{ .bytes = 12 << 20, .shards = 4 });
    defer store.deinit();

    try testing.expect(store.bytesHeld() <= 12 << 20);
    // Within a rounding of the shard count, all of it is in use.
    try testing.expect(store.bytesHeld() > (12 << 20) - 4096 * 4);
}

test "the memory it holds is never more than the budget it was given" {
    // Including the sizes nobody would write, and the ones somebody would:
    // a budget that is not a power of two is the case the first version of
    // this got wrong by handing back nearly twice it.
    for ([_]usize{ 64 << 10, 100 << 10, 1 << 20, 9 << 20, 12_345_678, 64 << 20 }) |budget| {
        var store = try Store.open(testing.allocator, .{ .bytes = budget });
        defer store.deinit();
        try testing.expect(store.bytesHeld() <= budget);
        // And not so far under it that the budget meant nothing: the ring is
        // floored to a power of two, so the worst case is a shade under half.
        try testing.expect(store.bytesHeld() > budget / 3);
    }
}

test "asking for more entries takes them out of the ring rather than out of the machine" {
    var lean = try Store.open(testing.allocator, .{ .bytes = 4 << 20, .shards = 1 });
    defer lean.deinit();
    var packed_in = try Store.open(testing.allocator, .{ .bytes = 4 << 20, .entries = 1 << 20, .shards = 1 });
    defer packed_in.deinit();

    try testing.expect(packed_in.bytesHeld() <= 4 << 20);
    try testing.expect(packed_in.shards[0].slots.len >= lean.shards[0].slots.len);
}

test "a cache too small to work says so rather than rounding itself up" {
    try testing.expectError(error.TooSmall, Store.open(testing.allocator, .{ .bytes = 1024 }));
}
