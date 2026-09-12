//! The bytes, the table that points at them, and the lock over both.
//!
//! One `Store` is one pool of memory, sized once when it opens and never grown
//! ([ADR 0138](../docs/adr/0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)).
//! Every `Space` in the program shares it, the way every bucket in `nilo_s3`
//! shares one `Store` — so "how much memory does my cache use" has one answer
//! and it is the number the caller wrote.
//!
//! ## A shard is a table and two rings
//!
//! The table is `http/allowance.zig`'s: buckets of eight ways, a fingerprint
//! per way, the coldest way forgotten when a bucket fills. Eight ways of 8
//! bytes is one cache line, so a lookup touches one.
//!
//! The ring is where a value that is not a `u64` has to live. A put takes its
//! space by moving a cursor that **only ever goes forwards** and copies the
//! header, the key and the value in. A region is a window on that cursor:
//! everything in `[head - capacity, head)` is live and everything older has
//! been written over. **Eviction is what writing does** — no free list to
//! fragment, no size class to waste, and no sweep.
//!
//! **There are two regions and that is the eviction policy** (ADR 0187). A new
//! entry goes into `small`, a tenth of the ring, so a key nobody asks for
//! twice is gone in a tenth of the time; one asked for again while it is still
//! there is copied into `main` and gets the other nine tenths. Without that,
//! every miss was admitted and a flood of keys nobody would ask for again
//! flushed the entries worth keeping — on Zipf 0.99 that was 67.0% of lookups
//! answered where 75.4% was available at the same size.
//!
//! ## Why the key is in the ring
//!
//! A fingerprint is 32 bits, so two keys in one bucket can share one. Trusting
//! it alone would hand back the other key's value, and a cache that is quietly
//! wrong is worse than one that misses. The key is stored and compared.
//!
//! ## Why a write takes a lock and a read takes nothing
//!
//! Writers hold a spin lock against each other, because two cursors moving at
//! once is two entries in one place. **A lookup holds nothing** (ADR 0188). It
//! reads the slot, copies the value out, and then reads the region's cursor a
//! second time: if the cursor has passed the entry since, some `put` was
//! writing over those bytes while they were being read, and the answer is
//! thrown away as an eviction. `reserve` publishes the cursor before it copies
//! a byte, which is what makes the second reading mean anything.
//!
//! **The lock-free version that was wrong is not this one.** The first attempt
//! had no cursor to ask: a writer descheduled inside its own `memcpy` is lapped
//! by the ring and writes over an entry *newer* than itself, whose position is
//! recent enough to pass every check a reader could make. Seven wrong values in
//! 1.9 million hits, measured in [`spike/cache_ring/`](../spike/cache_ring/),
//! and sharding did not fix it — sixteen rings gave eight. What is different
//! now is that a writer is alone, so the cursor it publishes is the whole
//! truth about where it is writing.
//!
//! The lock spins rather than parks because Zig 0.16's `std.Io.Mutex.lock`
//! takes an `io: Io`, and a module with no event loop has none to give it.
//! **That turns a preference into a rule this file has to keep forever:
//! nothing that waits, ever, inside a critical section.** It is also what makes
//! the lock safe to hold inside a fiber — a fiber only moves at a point that
//! waits, so a holder always finishes and releases.

const std = @import("std");
const builtin = @import("builtin");
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
/// **`freq` is two bits taken out of the fingerprint, not added to the slot.**
/// Both eviction paths in this file used to order entries by when they were
/// *written* — the ring laps whatever is oldest, and a full bucket forgets the
/// stalest way — so an entry read a million times died at the same moment as
/// one nobody ever asked for. Nothing recorded that a read had happened.
///
/// It cost nothing to fix because a fingerprint does not need sixteen bits.
/// The full key is compared behind it, so a collision is a wasted probe rather
/// than a wrong answer, and fourteen bits makes that wasted probe four times
/// likelier — about one lookup in 2,048 rather than one in 8,192. What it buys
/// is on `bench/result/cache.md`.
const Slot = packed struct(u64) {
    off: u32 = 0,
    gen: u16 = 0,
    fp: u14 = 0,
    /// How warm this entry is, saturating at three. Bumped by a hit, halved
    /// across the bucket when a displacement happens, which is the only clock
    /// this needs: a bucket that never fills never decays, and one under
    /// pressure decays exactly as fast as it is under pressure.
    freq: u2 = 0,

    /// **Every read and every write of a slot goes through here**, because
    /// `get` holds nothing (ADR 0188) and so a slot is always being read while
    /// somebody may be writing it. It costs nothing: eight bytes, aligned, is
    /// one `mov` either way. What it buys is that the compiler may not invent a
    /// second read of a word another thread is storing to, which is the thing
    /// that turns "the answer is stale" into "the answer is undefined".
    ///
    /// **Acquire rather than relaxed, and the ordering is load-bearing.** The
    /// caller reads the region's cursor straight after this to decide whether
    /// what the slot points at is still there. That load has to *follow* this
    /// one, or a slot a `put` has just written could be checked against a
    /// cursor from before the same `put` moved it, and a key that was just
    /// stored would read back as a miss. Free on x86, where a load is acquire
    /// anyway.
    inline fn load(slot: *const Slot) Slot {
        return @bitCast(@atomicLoad(u64, @as(*const u64, @ptrCast(slot)), .acquire));
    }

    /// Release, so the bytes this slot points at are in the ring before
    /// anything can follow the pointer to them.
    inline fn store(slot: *Slot, next: Slot) void {
        @atomicStore(u64, @as(*u64, @ptrCast(slot)), @bitCast(next), .release);
    }

    inline fn clear(slot: *Slot) void {
        @atomicStore(u64, @as(*u64, @ptrCast(slot)), 0, .release);
    }

    /// One warmer, and **nothing at all once it is saturated.** The guard is
    /// not a micro-optimisation: on Zipfian traffic most hits are to keys that
    /// are already warm, so without it every read of a hot key dirties the
    /// bucket's cache line and drags it between cores. quick_cache does the
    /// same thing for the same reason (`if referenced < MAX_F`).
    ///
    /// A lost race here costs one increment of a hint, so it gives up rather
    /// than looping.
    inline fn warmer(slot: *Slot, seen: Slot) void {
        if (seen.freq >= warm) return;
        var next = seen;
        next.freq += 1;
        _ = @cmpxchgWeak(u64, @as(*u64, @ptrCast(slot)), @bitCast(seen), @bitCast(next), .monotonic, .monotonic);
    }
};

comptime {
    if (@sizeOf(Slot) != 8) @compileError("nilo: a cache slot has to be 8 bytes for eight to be one cache line");
    if (@sizeOf(Slot) * ways != 64) @compileError("nilo: a bucket has to be exactly one 64-byte cache line");
}

/// How warm an entry has to be before a read will move it out of the ring's
/// way. Three is saturated, so this is "asked for at least three times since
/// the last time this bucket came under pressure".
const warm = 3;

/// The last eighth of the ring, where an entry is about to be written over.
/// A read that finds a warm entry in this window copies it back to the head
/// rather than letting the write cursor take it — second chance, which is
/// what turns a FIFO into a policy that knows which entries are worth keeping.
///
/// An eighth rather than a half because every rescue is itself a write, and a
/// write pushes the cursor into somebody else. Rescuing early rescues more
/// often than necessary and spends the ring on it.
const rescue_window = 8;

/// How much of a shard's ring is the doorkeeper. A tenth: small enough that a
/// key nobody asks twice for is gone quickly, large enough that a key asked
/// twice in an ordinary burst is still there to be promoted.
///
/// The number is the one S3-FIFO uses and it was checked here rather than
/// taken: a fifth and a twentieth were both measured and both worse
/// ([`bench/result/cache.md`](../bench/result/cache.md)).
const small_share = 10;

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
    /// How many entries the table can point at, when the five-sixths the ring
    /// takes by default is the wrong split. Zero derives it from what is left
    /// of `bytes`.
    ///
    /// **Clamped to the budget rather than added to it**, so raising it takes
    /// slots out of the ring rather than taking more memory from the machine.
    /// Raise it for many small values; lower it for few large ones.
    entries: usize = 0,
    /// How many independent tables and rings, and therefore how many threads
    /// can be inside the cache at once.
    ///
    /// **A fixed number rather than the number of cores on purpose.** A
    /// default read from the machine makes the same program hold different
    /// amounts of memory on two boxes and makes a benchmark unreproducible,
    /// which is a worse trade than a number somebody can raise.
    ///
    /// **Sixty-four rather than sixteen, and the number is measured.** A `put`
    /// takes its shard's lock, so few shards turn a write into a queue, and a
    /// shard is also the unit the ring laps in. On eight cores at nine reads to
    /// a write, sixteen shards
    /// served 87.4M ops/s and sixty-four served 125.0M — and on a working set
    /// small enough to stay in cache, 94.2M against 162.7M. It costs 5% of the
    /// single-threaded figure and **no hit rate at all**: on Zipf 0.99 the two
    /// are within 0.1 of a point at every budget measured.
    ///
    /// 256 is faster again (143.6M and 190.5M) and is not the default because
    /// it starts costing retention: 4.5 points at 512 KiB, where each shard's
    /// ring is too small to hold what hashes to it. Raise it by hand on a
    /// store of several MiB and a machine with cores to spare
    /// ([`bench/result/cache.md`](../bench/result/cache.md)).
    shards: usize = 64,
};

pub const OpenError = error{
    OutOfMemory,
    /// The numbers do not divide into a working cache: fewer than 64 KiB of
    /// value memory, or fewer entries than the shards have ways to hold them.
    TooSmall,
};

/// Hits and misses, so "why is my cache not hitting" has an answer that is not
/// a guess. Summed across shards on demand.
///
/// **This is a sum over a moving target rather than a snapshot**, because a
/// lookup takes no lock (ADR 0188) and so neither does this. The counters are
/// exact; what is not exact is that they were not all read at the same instant.
///
/// `evicted` therefore also counts the rare read whose bytes a `put` overwrote
/// while they were being copied. That read found the key and lost it to the
/// ring, which is what `evicted` means.
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
    /// Warm entries a read moved out of the write cursor's way. **This is the
    /// number that says the policy is doing something**: zero means every
    /// entry is dying in write order, which is what this cache did before.
    rescued: u64 = 0,

    /// Of the lookups that found nothing, how many were the ring being small.
    /// A cache with a high number here wants more `bytes`; one with a low
    /// number and few hits is being asked about keys nobody wrote.
    pub fn evictionRate(self: Stats) f64 {
        const looked = self.hits + self.misses + self.evicted + self.expired;
        if (looked == 0) return 0;
        return @as(f64, @floatFromInt(self.evicted)) / @as(f64, @floatFromInt(looked));
    }
};

/// What the store counts, as opposed to what a caller reads.
///
/// Three things separate this from `Stats`. It is **atomic**, because `get`
/// holds nothing and any number of reads can count a hit at once. It sits on a
/// **cache line of its own**, because it used to share one with `small` and
/// `main` — so every read dirtied the line every write has to read, which is
/// the shape of false sharing that does not show up until there are cores.
///
/// **Counting a read is not free and there is no cheaper exact version.**
/// Against a build that counted nothing at all it is 4.2% of the eight-thread
/// figure and 7.0% of the one-thread figure, because a read holds no lock now
/// and so the increment has to be an atomic read-modify-write. A version with
/// one set of counters per thread rather than per shard was built and measured:
/// 1.5% better on eight threads, 3% worse on one, which is a lane lookup buying
/// back contention it also pays for. Per shard is what stayed.
const Counters = struct {
    hits: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
    misses: std.atomic.Value(u64) = .init(0),
    evicted: std.atomic.Value(u64) = .init(0),
    expired: std.atomic.Value(u64) = .init(0),
    puts: std.atomic.Value(u64) = .init(0),
    refused: std.atomic.Value(u64) = .init(0),
    rescued: std.atomic.Value(u64) = .init(0),

    /// Relaxed throughout: nothing in the module branches on a counter, so
    /// they need to arrive eventually and in no particular order.
    inline fn bump(c: *std.atomic.Value(u64)) void {
        _ = c.fetchAdd(1, .monotonic);
    }

    fn read(self: *const Counters) Stats {
        return .{
            .hits = self.hits.load(.monotonic),
            .misses = self.misses.load(.monotonic),
            .evicted = self.evicted.load(.monotonic),
            .expired = self.expired.load(.monotonic),
            .puts = self.puts.load(.monotonic),
            .refused = self.refused.load(.monotonic),
            .rescued = self.rescued.load(.monotonic),
        };
    }
};

/// A spin lock, and not by preference — see the header. One to a cache line,
/// or two shards would share one and the sharding would buy nothing.
///
/// **Only writers take it** (ADR 0188). `put`, `del`, `clear` and the promotion
/// a read hands back are serialised against each other; a `get` takes nothing
/// at all and validates afterwards instead. A reader-writer version of this
/// lock was built first and measured: sharing it was worth 11% on eight threads
/// and cost 11% on one, because two atomic read-modify-writes per lookup is
/// most of what a lookup costs. Taking nothing was worth 12% on **both**.
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

/// One stretch of the ring with its own write cursor.
///
/// **There are two of them, and that is the whole eviction policy.** A ring is
/// a queue that forgets in write order, so every miss that writes pushes
/// something out — and on real traffic most misses are keys nobody will ask
/// for again. Admitting them all is what flushed the entries worth keeping:
/// measured on Zipf 0.99 at 128 KiB, the cache was answering 53.1% of lookups
/// where a cache of that size could answer 66.9%.
///
/// A new entry therefore lands in `small`, which is a tenth of the ring and
/// laps ten times as fast. A key asked for a second time while it is still
/// there is copied into `main` and gets the rest of the ring to live in; one
/// that is never asked for again never leaves the tenth it came in through.
/// **The doorkeeper is a second question rather than a data structure**, which
/// is why it costs no memory (ADR 0181).
/// Where a region's write cursor is, and how many times it has been round —
/// **in one word, so a reader takes both in one load and can never see half of
/// a move.** Two separate fields would let a lookup read the offset from before
/// a wrap and the pass number from after it, and conclude that an entry the
/// ring had just written over was still there.
const Mark = packed struct(u64) {
    head: u32,
    gen: u16,
    _unused: u16 = 0,
};

const Region = struct {
    from: u32,
    /// Exclusive.
    to: u32,
    /// A `Mark`. Moved only under the shard's lock, and read by anybody at any
    /// time with nothing held at all.
    cursor: std.atomic.Value(u64),

    fn init(from: u32, to: u32) Region {
        return .{
            .from = from,
            .to = to,
            .cursor = .init(@bitCast(Mark{ .head = from, .gen = 1 })),
        };
    }

    /// Where the cursor is now. Relaxed: the caller either holds the lock, in
    /// which case nothing else is moving it, or is a lookup that will ask again
    /// through `settled` before believing what it read.
    inline fn mark(r: *const Region) Mark {
        return @bitCast(r.cursor.load(.monotonic));
    }

    /// The same load, ordered against everything the caller did before it.
    /// **This is the whole of what makes a lookup safe without a lock**: a read
    /// copies the value out first and asks this afterwards, and a cursor that
    /// has since passed the entry means the bytes just copied were being
    /// written over while they were read. Sequentially consistent because the
    /// question is precisely "did that happen *before* this", and a relaxed or
    /// acquire load lets the compiler sink the copy below it.
    ///
    /// **The compiler is not the only thing that reorders, and `seq_cst` on
    /// this one load does not hold the processor** (ADR 0190). An acquire —
    /// which is all a `seq_cst` load is to the hardware — keeps what comes
    /// *after* it from moving up; it says nothing about the copy that came
    /// *before* it moving down, and on aarch64 that is an ordinary thing for
    /// two loads to do. x86 never noticed because it does not reorder loads
    /// against loads, which is the whole reason this shipped. The `dmb ishld`
    /// is the missing sentence: every load before it is complete before any
    /// load after it. Measured at no cost on an M1 Pro — three interleaved
    /// rounds, one and eight threads, inside the spread on every row — and it
    /// compiles to nothing on x86, so ADR 0188's figures stand as taken.
    inline fn settled(r: *const Region) Mark {
        if (comptime builtin.cpu.arch.isAARCH64()) asm volatile ("dmb ishld" ::: .{ .memory = true });
        return @bitCast(r.cursor.load(.seq_cst));
    }

    fn len(r: *const Region) u32 {
        return r.to - r.from;
    }

    fn holds(r: *const Region, off: u32) bool {
        return off >= r.from and off < r.to;
    }

    /// **An entry is never split across the seam.** One that will not fit
    /// before the end starts again at the region's first byte, leaving a gap
    /// of less than one entry — which costs a few bytes and takes the split
    /// `memcpy` out of every read and every write.
    ///
    /// **The cursor is published before a single byte is copied**, and that
    /// order is the contract the lock-free lookup rests on. A lookup that
    /// checks the cursor after its copy and finds it unmoved has proved that
    /// nothing had started writing here; if the store below could sink past the
    /// `memcpy` its caller does next, the lookup would be checking against a
    /// cursor that lied. Sequentially consistent is what says so to the
    /// compiler.
    ///
    /// **It does not say so to every processor** (ADR 0190). To the hardware a
    /// `seq_cst` store is a release: what came before it stays before it, and
    /// the `memcpy` that comes *after* is free to land first — which on
    /// aarch64 it does, and on x86, which keeps stores in order, it cannot.
    /// So off x86 the cursor moves by a swap instead. A read-modify-write is
    /// acquire and release at once, and nothing crosses it in either
    /// direction. It is under the shard's lock, so nobody is contending for the
    /// line, and a `put` measured the same with it as without.
    fn reserve(r: *Region, total: usize) u32 {
        var m = r.mark();
        if (m.head + total > r.to) {
            m.head = r.from;
            m.gen +%= 1;
            // Zero is how a slot says "never written", so a region's own
            // generation may never be it.
            if (m.gen == 0) m.gen = 1;
        }
        const off = m.head;
        m.head += @intCast(total);
        if (comptime builtin.cpu.arch == .x86_64) {
            r.cursor.store(@bitCast(m), .seq_cst);
        } else {
            _ = r.cursor.swap(@bitCast(m), .seq_cst);
        }
        return off;
    }

    /// Whether what the slot points at is still what it pointed at, judged
    /// against one reading of the cursor. Written on this pass and behind the
    /// cursor, or written on the pass before and still ahead of it.
    fn liveAt(m: Mark, slot: Slot) bool {
        if (slot.gen == 0) return false;
        if (slot.gen == m.gen) return slot.off < m.head;
        if (slot.gen +% 1 == m.gen) return slot.off >= m.head;
        return false;
    }

    fn live(r: *const Region, slot: Slot) bool {
        return liveAt(r.mark(), slot);
    }

    /// Whether the cursor wrote over this entry **inside the last lap**.
    ///
    /// This is a ghost queue that costs nothing (ADR 0188). A dead slot is
    /// already a record that some key hashing here was in the ring and the
    /// write cursor took it, which is exactly the fact quick_cache keeps a
    /// separate list of non-resident entries to remember — and pays half its
    /// capacity again in full-size slots to do it. `put` reads it to decide
    /// that a key coming back this soon has earned `main` without going
    /// through the doorkeeper a second time, which is S3-FIFO's admission rule.
    ///
    /// **One lap, and the narrowness is the whole of what it is worth.** The
    /// window can be widened by counting passes rather than one, and it was
    /// swept: a tenth of the ring is one lap of `small`, so ten laps of `small`
    /// is the same stretch of writing as one lap of `main` and looks like the
    /// fair comparison. It measured *worse* than one lap on five of six sizes
    /// (63.9% against 64.3% at 128 KiB) while holding 3% more entries, which is
    /// a cache remembering more and answering less. A ghost that reaches back
    /// far enough stops being evidence about this key and becomes evidence that
    /// keys exist.
    fn ghostAt(m: Mark, slot: Slot) bool {
        return slot.gen != 0 and slot.gen +% 1 == m.gen and slot.off < m.head;
    }

    /// How many bytes of writing this entry has left before the cursor reaches
    /// it. Small means it is about to go.
    ///
    /// **Takes the cursor rather than reading it**, because the caller has read
    /// it two lines earlier and an atomic load is one the compiler may not
    /// fold away. Reading it twice measured 16% of a one-thread lookup.
    fn untilAt(r: *const Region, m: Mark, slot: Slot) u32 {
        return if (slot.gen == m.gen)
            (r.to - m.head) + (slot.off - r.from)
        else
            slot.off -| m.head;
    }

    /// Whether the next `total` bytes reserved here would land on top of the
    /// entry at `src_off`. **A promotion reads its source out of the ring and
    /// writes it back into the same ring**, so the one thing it may not do is
    /// reserve the space it is about to copy from.
    fn wouldClobber(r: *const Region, total: usize, src_off: u32, src_total: usize) bool {
        var at: usize = r.mark().head;
        if (at + total > r.to) at = r.from;
        return at < @as(usize, src_off) + src_total and @as(usize, src_off) < at + total;
    }
};

const Shard = struct {
    lock: Lock = .{},
    /// Aligned so a bucket never straddles two cache lines. The alignment is
    /// in the type rather than only at the call site, or `free` would hand
    /// the allocator a different alignment than `alloc` was given.
    slots: []align(std.atomic.cache_line) Slot,
    ring: []u8,
    /// Where a new entry goes, and where one that proved itself goes. Which
    /// region a slot is in is read from its offset, so no bit of the slot is
    /// spent saying it.
    small: Region,
    main: Region,
    buckets: u32,
    stats: Counters = .{},

    /// Any number of buckets, not only a power of two, by multiplying into the
    /// top half of a 64-bit product instead of masking. One `mulx`, and the
    /// table can then be sized to the budget rather than to the next power of
    /// two below it.
    fn bucketOf(self: *Shard, hash: u64) []Slot {
        const wide = @as(u64, @as(u32, @truncate(hash))) * @as(u64, self.buckets);
        return self.slots[@as(usize, @intCast(wide >> 32)) * ways ..][0..ways];
    }

    fn regionOf(self: *Shard, off: u32) *Region {
        return if (self.small.holds(off)) &self.small else &self.main;
    }

    /// Whether what the slot points at is still what it pointed at. Written
    /// on this pass and behind the cursor, or written on the pass before and
    /// still ahead of it.
    fn live(self: *Shard, slot: Slot) bool {
        return self.regionOf(slot.off).live(slot);
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

    /// Copy an entry to `into`'s cursor and point its slot at the copy.
    ///
    /// Two things use this and they are the same move. **A promotion** takes an
    /// entry that has now been asked for twice out of `small` and gives it the
    /// rest of the ring. **A second chance** keeps a warm entry in `main` by
    /// putting it back at the head before the cursor reaches it. Both are one
    /// `memcpy` inside a lock that was already held, which is the only thing
    /// this module is allowed to do in there (ADR 0138).
    ///
    /// **It is given the slot's value as well as its address**, because the
    /// lock it holds keeps other writers out and no longer keeps lookups out: a
    /// lookup that found this entry expired clears the slot from under it, and
    /// re-reading the offset halfway through would copy from wherever the
    /// cleared slot pointed.
    fn carry(self: *Shard, into: *Region, slot: *Slot, seen: Slot, e: Entry) bool {
        const total = header + e.key.len + e.value.len;
        // An entry that does not fit the region it is going to stays where it
        // is rather than being truncated into it.
        if (total > into.len()) return false;
        if (into.wouldClobber(total, seen.off, total)) return false;

        const off = into.reserve(total);
        // `copyForwards` rather than `@memcpy`: source and destination are two
        // windows on one ring, and the check above rules out overlap in the
        // direction that matters but not aliasing as far as the compiler is
        // concerned.
        std.mem.copyForwards(u8, self.ring[off..][0..total], self.ring[seen.off..][0..total]);

        // **The slot moves as one word or not at all.** Two field writes would
        // let a lookup read the new offset with the old pass number and follow
        // it into the middle of somebody else's entry. And it is a swap rather
        // than a store because a lookup is allowed to have warmed this slot, or
        // to have cleared it as expired, while the copy was being made — the
        // first is a reason to try again, the second a reason to stop.
        const gen = into.mark().gen;
        while (true) {
            const now = slot.load();
            if (now.off != seen.off or now.gen != seen.gen) return false;
            var next = now;
            next.off = off;
            next.gen = gen;
            const word = @as(*u64, @ptrCast(slot));
            if (@cmpxchgWeak(u64, word, @bitCast(now), @bitCast(next), .release, .monotonic) == null) break;
        }
        // Counted by the caller: the counters belong to the thread now rather
        // than to the shard, and a `Shard` has no way to reach one.
        return true;
    }

    /// The write half of a read, and the reason `get` can hold nothing at all
    /// (ADR 0188).
    ///
    /// A hit that proved something — a second ask inside the doorkeeper, or a
    /// warm entry the cursor is about to reach — wants its entry copied to
    /// `main`'s head. That is a ring write and a ring write is exclusive, so it
    /// happens here, **after `get` has already put the value in the caller's
    /// buffer**. The caller waits for its answer, not for the policy.
    ///
    /// **It is handed the way rather than the key, and that is the difference
    /// between this being worth doing and not.** The first version re-hashed
    /// nothing but did walk the bucket again and compare the key again, and
    /// measured 2.5% *slower* than the exclusive lock it replaced: about an
    /// eighth of reads want a promotion, and an eighth of reads paying a second
    /// lock and a second scan costs more than seven eighths of reads gain from
    /// running together.
    ///
    /// So the read passes back where it looked, and all this does is check that
    /// the slot still points where it did. `off` and `gen` together identify
    /// the entry; `freq` is left out of the comparison because another reader
    /// is allowed to have bumped it in between, and that is not a reason to
    /// give up on the promotion.
    fn promote(self: *Shard, bucket: []Slot, way: usize, expect: Slot) bool {
        self.lock.take();
        defer self.lock.release();

        const slot = &bucket[way];
        const seen = slot.load();
        if (seen.off != expect.off or seen.gen != expect.gen) return false;
        if (!self.live(seen)) return false;
        const e = self.entry(seen) orelse return false;
        return self.carry(&self.main, slot, seen, e);
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
        // **A sixth to the table rather than a quarter**, which is where the
        // knee is and it was swept rather than reasoned. A slot is 8 bytes and
        // an entry is 12 of header plus the key plus the value, so a quarter
        // buys about twice as many slots as the ring can ever fill — surplus
        // paid for once in memory and again in every bucket probe that misses
        // a larger table. Measured on 100,000 entries in a 4 MiB budget:
        //
        //   table   held    bytes/entry  hit rate  1 thread  8 threads
        //   1/4     67,499  62.1         92.7%     22.7M     127.0M
        //   1/6     67,711  61.9         92.7%     24.4M     133.4M
        //   1/8     59,498  70.5         91.5%     28.4M     148.6M
        //
        // A sixth costs nothing on any of the first three columns and is worth
        // 7.5% on the fourth. An eighth is faster again and starts paying for
        // it in hit rate, which is the wrong currency: a miss is a database
        // round trip and an operation is 40 ns.
        const slot_bytes = @sizeOf(Slot);
        const total_slots = if (opts.entries == 0)
            opts.bytes / 6 / slot_bytes
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
        // **Floored to a power of two after the clamp, not before it.**
        // `shard_mask` is `shards_n - 1` used as a bitmask, which is a modulo
        // only when the count is a power of two — and the clamp above divides
        // by 4096, which is any number at all. A count of 12 gave a mask of
        // 0b1011, so four of the twelve shards were allocated and nothing
        // could ever hash to them: 33% of the budget at 64 KiB, the smallest
        // one this module accepts, on the default `shards`. At 192 KiB and 64
        // shards it was 78%.
        const shards_n = std.math.floorPowerOfTwo(usize, @max(1, @min(asked, total_cap / 4096)));
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
            // The doorkeeper never gets so small that an ordinary entry cannot
            // pass through it, which on the smallest shard this module builds
            // makes it a quarter rather than a tenth.
            const small_len: u32 = @intCast(@max(cap / small_share, 512));
            s.* = .{
                .slots = slots,
                .ring = ring,
                .small = .init(0, small_len),
                .main = .init(small_len, @intCast(cap)),
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
            Counters.bump(&shard.stats.refused);
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

        var chosen: usize = 0;
        var keep_freq: u2 = 0;
        var displaced = true;
        var returning = false;
        const small_to = shard.small.to;
        const small_mark = shard.small.mark();
        const main_mark = shard.main.mark();

        // **The same key first, and only the ways whose fingerprint says it
        // might be.** Refreshing a key that is already there is what a cache
        // in front of anything spends its writes on, and it used to walk all
        // eight ways doing the ranking arithmetic on the way past. The vector
        // compare answers "which ways could this be" in two instructions.
        //
        // **This runs before the region is chosen, which is the point of it
        // running here at all.** A way that carries this fingerprint and is
        // dead is a ghost — a record that this key was in the ring and the
        // cursor took it — and a key coming back that soon has already proved
        // what the doorkeeper exists to ask.
        var mask = matching(bucket, fp);
        while (mask != 0) : (mask &= mask - 1) {
            const i = @ctz(mask);
            const seen = bucket[i].load();
            const in_small = seen.off < small_to;
            const m = if (in_small) small_mark else main_mark;
            if (!Region.liveAt(m, seen)) {
                returning = returning or Region.ghostAt(m, seen);
                continue;
            }
            const e = shard.entry(seen) orelse continue;
            // The same key again is an update rather than a second entry, and
            // it keeps the warmth it earned — a value being refreshed is the
            // same value as far as anybody asking for it is concerned.
            if (e.space == space and std.mem.eql(u8, e.key, key)) {
                chosen = i;
                keep_freq = seen.freq;
                displaced = false;
                // A key already in `main` is not sent back through the
                // doorkeeper by being written again. It earned the nine tenths
                // once; a refresh is the same key, not a new one.
                returning = returning or !in_small;
                break;
            }
        }

        // **A new entry goes in through the doorkeeper, but only once there is
        // something to keep it out of.** `small` is a tenth of the ring, so a
        // key nobody asks for a second time is gone in a tenth of the time and
        // never displaces what `main` is holding.
        //
        // Three things skip it. One too large to leave room in the tenth goes
        // straight to `main`: a value that big costs enough to fetch that
        // making it prove itself twice is the wrong trade, and there are few
        // enough of them to be no threat.
        //
        // **A cache that is still filling admits everything**, because a
        // doorkeeper in front of empty space is not admission control, it is
        // throwing away room nobody is competing for. Sending unread entries
        // through the tenth regardless took a store holding 78,875 of them
        // down to 8,065 — a cache with space to spare using a tenth of it.
        // `main.gen == 1` says it has never been round.
        //
        // And **a key the ring has seen before goes straight back to `main`**,
        // which is the ghost above and is S3-FIFO's admission rule.
        const filling = main_mark.gen == 1 and main_mark.head + total <= shard.main.to;
        const into = if (filling or returning or total * 2 > shard.small.len())
            &shard.main
        else
            &shard.small;
        const off = into.reserve(total);
        @memcpy(shard.ring[off..][0..header], &head_bytes);
        @memcpy(shard.ring[off + header ..][0..key.len], key);
        @memcpy(shard.ring[off + header + key.len ..][0..value.len], value);

        // Only a genuinely new key pays for the ranking, and only then does
        // the bucket have to give something up. **After the reserve, not
        // before**: the entry just written killed whatever the cursor passed
        // over, and those ways are exactly the ones worth giving up.
        if (displaced) {
            var coldest: u64 = std.math.maxInt(u64);
            for (bucket, 0..) |*slot, i| {
                const seen = slot.load();
                if (seen.gen == 0) {
                    chosen = i;
                    displaced = false;
                    break;
                }
                const in_small = seen.off < small_to;
                const region = if (in_small) &shard.small else &shard.main;

                // **Lowest goes first, and age is the last question rather
                // than the only one.** Ordering by age alone is what made a key
                // read a million times die at the same moment as one nobody
                // asked for.
                //
                //   0  the ring already took this entry, so the slot is free
                //   1  still in the doorkeeper — it has been asked for once
                //   2  promoted, so somebody asked for it twice
                //
                // then warmth inside the tier, then write order inside that.
                const tier: u64 = if (!region.live(seen))
                    0
                else if (in_small)
                    1
                else
                    2;
                const rank = (tier << 62) | (@as(u64, seen.freq) << 60) |
                    (@as(u64, seen.gen) << 32) | seen.off;
                if (rank < coldest) {
                    coldest = rank;
                    chosen = i;
                }
            }
        }
        // **A bucket decays only when it cannot tell its ways apart**, which
        // is when the coldest thing in it is still warm. A bucket with a dead
        // or unproven way to give up has an answer already and must not spend
        // it: halving on every displacement instead took a warm entry to zero
        // in two of them, which is how a key being read constantly was still
        // thrown out by a flood of keys nobody read twice.
        if (displaced and bucket[chosen].load().freq > 0) for (bucket) |*slot| {
            var next = slot.load();
            next.freq >>= 1;
            slot.store(next);
        };
        bucket[chosen].store(.{ .off = off, .gen = into.mark().gen, .fp = fp, .freq = keep_freq });
        Counters.bump(&shard.stats.puts);
        return true;
    }

    /// Copy the value for `key` into `out`, and answer how many bytes that
    /// was. `null` is every kind of not-here; `Stats` is what tells them
    /// apart.
    pub fn get(self: *Store, space: u32, key: []const u8, out: []u8) ?usize {
        const hash = std.hash.Wyhash.hash(space, key);
        const shard = self.shardFor(hash);
        const fp = fingerprint(hash);
        const now = self.elapsed();

        // The bucket is one cache line and almost always a miss. Asking for the
        // line before anything else lets the miss and the arithmetic overlap.
        const bucket = shard.bucketOf(hash);
        @prefetch(bucket.ptr, .{ .rw = .read, .locality = 3, .cache = .data });

        // **A lookup takes nothing** (ADR 0188). It reads the slot, reads the
        // bytes, and then asks the region's cursor whether anything wrote over
        // those bytes while it was reading them — which is the same question
        // `live` already answers, asked a second time. Nothing here is
        // published to another thread except a warmer `freq` and, on a hit that
        // proved something, the promotion handed to `Shard.promote` below.
        var evicted = false;
        var answer: ?usize = null;
        var move: ?struct { way: usize, slot: Slot } = null;
        const small_to = shard.small.to;

        // **All eight fingerprints compared at once, and the loop runs only
        // over the ways that matched.** Walking eight ways with a branch each
        // costs a mispredict most of the time, and a mispredict is worth more
        // than the compare it was guarding: the bucket is one cache line that
        // has already arrived, so the scan was pure branch cost.
        var mask = matching(bucket, fp);
        // **Ask for the entry before deciding whether to read it.** The slot
        // points at the ring, so the second load cannot start until the first
        // returns — which is the whole of the gap to a hash map that keeps the
        // key beside the probe. Issuing it here rather than after the region
        // and liveness checks buys back the dozen cycles those take.
        if (mask != 0) @prefetch(shard.ring.ptr + bucket[@ctz(mask)].load().off, .{
            .rw = .read,
            .locality = 3,
            .cache = .data,
        });
        while (mask != 0) : (mask &= mask - 1) {
            const way = @ctz(mask);
            const slot = &bucket[way];
            const seen = slot.load();
            // Which region, worked out once: the liveness check below and the
            // promotion check further down both want it.
            const in_small = seen.off < small_to;
            const region = if (in_small) &shard.small else &shard.main;
            // The cursor is read *after* the slot, and `Slot.load` is an
            // acquire for that reason: a slot a `put` has just written must be
            // judged against the cursor that same `put` had already moved.
            const at = region.mark();
            if (!Region.liveAt(at, seen)) {
                evicted = true;
                continue;
            }
            const e = shard.entry(seen) orelse continue;

            // A Space whose name shares 32 bits with another's is refused at
            // `registerSpace`, so this can only be a fingerprint collision
            // between two keys — which is what it is here to catch. The key
            // comparison behind it is what makes a collision a miss rather
            // than somebody else's value.
            if (e.space != space) continue;
            if (!std.mem.eql(u8, e.key, key)) continue;
            if (e.value.len > out.len) continue;
            @memcpy(out[0..e.value.len], e.value);

            // **Everything above read the ring with nothing held, so nothing
            // above is true yet.** A `put` publishes its cursor before it
            // copies a byte, so a cursor that has since passed this entry means
            // those bytes were being written over while they were being read —
            // the key that matched may have been half of one key and half of
            // another, and what landed in `out` is somebody else's value or no
            // value at all. Asking again is the whole price of the lock this
            // does not take: one load, of a word every lookup already reads.
            //
            // It counts as an eviction rather than a miss, because that is what
            // it is: the ring reached this entry.
            if (!Region.liveAt(region.settled(), seen)) {
                evicted = true;
                continue;
            }

            if (e.expires != 0 and now >= e.expires) {
                // Forgotten now rather than at a sweep that does not exist.
                // Two readers may do this at once and it is the same store
                // either way.
                slot.clear();
                Counters.bump(&shard.stats.expired);
                return null;
            }

            // **The read is what the policy learns from**, and this is the
            // only place in the file that learns anything at all. What it
            // learns is one bit of arithmetic on the slot; what it *decides*
            // is whether a write has to follow, and that write is not done
            // from here.
            if (in_small) {
                // A second ask while it is still in the doorkeeper. That is
                // the whole admission test, and passing it buys the rest of
                // the ring.
                slot.warmer(seen);
                move = .{ .way = way, .slot = seen };
            } else if (seen.freq < warm) {
                slot.warmer(seen);
            } else if (@as(usize, shard.main.untilAt(at, seen)) < shard.main.len() / rescue_window) {
                // Warm, and the cursor is about to reach it. Cold entries are
                // left where they are on purpose: the ring is where this cache
                // forgets, and one that saves everything has stopped having a
                // policy.
                move = .{ .way = way, .slot = seen };
            }

            Counters.bump(&shard.stats.hits);
            answer = e.value.len;
            break;
        }

        if (answer == null) Counters.bump(if (evicted) &shard.stats.evicted else &shard.stats.misses);

        // **The value is already in the caller's buffer, so this is policy
        // rather than answer.** It checks the slot again because anything could
        // have happened in between; if the entry has gone, there is nothing
        // left to save and nothing to report.
        if (move) |m| {
            if (shard.promote(bucket, m.way, m.slot)) Counters.bump(&shard.stats.rescued);
        }
        return answer;
    }

    /// Forget a key. True when there was something to forget.
    pub fn del(self: *Store, space: u32, key: []const u8) bool {
        const hash = std.hash.Wyhash.hash(space, key);
        const shard = self.shardFor(hash);
        const fp = fingerprint(hash);

        shard.lock.take();
        defer shard.lock.release();

        for (shard.bucketOf(hash)) |*slot| {
            const seen = slot.load();
            if (seen.gen == 0 or seen.fp != fp or !shard.live(seen)) continue;
            const e = shard.entry(seen) orelse continue;
            if (e.space != space or !std.mem.eql(u8, e.key, key)) continue;
            slot.clear();
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
            // A slot at a time rather than one `memset`, because a lookup that
            // holds nothing may be reading any of them.
            for (shard.slots) |*slot| slot.clear();
        }
    }

    pub fn stats(self: *Store) Stats {
        var total: Stats = .{};
        for (self.shards) |*shard| {
            // No lock: the counters are atomic and nothing here branches on
            // them, so the answer is a sum over a moving target either way.
            const one = shard.stats.read();
            total.hits += one.hits;
            total.misses += one.misses;
            total.evicted += one.evicted;
            total.expired += one.expired;
            total.puts += one.puts;
            total.refused += one.refused;
            total.rescued += one.rescued;
        }
        return total;
    }

    /// Fourteen bits, the other two having gone to `Slot.freq`. The key
    /// comparison behind it is what decides, so a collision here costs one
    /// wasted compare against the ring and can never cost a wrong answer.
    fn fingerprint(hash: u64) u14 {
        return @as(u14, @truncate(hash >> 32)) | 1;
    }

    /// Which of a bucket's eight ways carry this fingerprint and have been
    /// written, as a bit per way.
    ///
    /// **A bucket is one cache line and it has already arrived**, so the old
    /// loop was not paying for memory — it was paying for eight branches the
    /// processor could not predict, on a line it already had. Comparing the
    /// eight as one vector and then visiting only the ways that matched turns
    /// that into two instructions and a `ctz` per real candidate.
    ///
    /// The shifts are `Slot`'s layout, which a packed struct fixes: `off` in
    /// bits 0–31, `gen` in 32–47, `fp` in 48–61, `freq` in 62–63. A `gen` of
    /// zero means the way was never written, which is why it is part of the
    /// test rather than a separate one.
    /// **The eight loads are atomic because somebody is always writing this
    /// line** (ADR 0188), and `unordered` because that is the weakest thing
    /// that is still not a race. A plain 64-byte read of the bucket is what
    /// this wants to be and it measured 16% faster on one thread; it is also a
    /// data race beside a `put`'s slot store, and this module's answer to "is
    /// that fine in practice" is written on its own header. `unordered` is the
    /// ordering LLVM has for exactly this — a load that may see any one write
    /// but never half of two — and it is free where the vector load is free.
    ///
    /// Whatever it returns is a list of candidates, not an answer: every way it
    /// names is loaded again and its whole key compared, so the worst a stale
    /// or reordered read can do is cost a probe or miss one.
    fn matching(bucket: []Slot, fp: u14) u8 {
        const Lanes = @Vector(ways, u64);
        var words: [ways]u64 = undefined;
        inline for (0..ways) |i| {
            words[i] = @atomicLoad(u64, @as(*const u64, @ptrCast(&bucket[i])), .unordered);
        }
        const v: Lanes = words;
        const fps = (v >> @as(Lanes, @splat(48))) & @as(Lanes, @splat(0x3fff));
        const gens = (v >> @as(Lanes, @splat(32))) & @as(Lanes, @splat(0xffff));
        const hit = (fps == @as(Lanes, @splat(fp))) & (gens != @as(Lanes, @splat(0)));
        return @bitCast(hit);
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
    // **Not `k0`.** A cache with room admits everything, so the first entries
    // in went into `main` and stayed; the doorkeeper only engaged once `main`
    // was full. What got forgotten is the oldest thing that arrived after
    // that, which is the middle of this run rather than the start of it.
    const mid = try std.fmt.bufPrint(&key, "k{d}", .{200});
    try testing.expectEqual(@as(?usize, null), store.get(1, mid, &out));
    try testing.expect(store.stats().evicted >= 1);

    // And the newest is still there, which is what makes the above eviction
    // rather than a cache that simply lost everything.
    const last = try std.fmt.bufPrint(&key, "k{d}", .{399});
    try testing.expect(store.get(1, last, &out) != null);
}

test "a working set that moves takes the old one's place" {
    // The property the pinning question is really about. `main` only advances
    // when something is promoted into it, so a cache written to and never read
    // holds its first entries indefinitely. That is harmless — nothing is
    // asking for them — but it must not survive traffic moving on, or the
    // cache would be a museum of whatever it saw first.
    var store = try Store.open(testing.allocator, .{ .bytes = 256 << 10, .shards = 1 });
    defer store.deinit();

    var out: [64]u8 = undefined;
    var key: [32]u8 = undefined;

    // An early working set, read enough to be promoted.
    for (0..2_000) |i| {
        const k = try std.fmt.bufPrint(&key, "old{d}", .{i});
        _ = store.put(1, k, "v", 0);
        _ = store.get(1, k, &out);
        _ = store.get(1, k, &out);
    }
    try testing.expect(store.get(1, "old1000", &out) != null);

    // Traffic moves to a different set of keys, read the same way.
    for (0..20_000) |i| {
        const k = try std.fmt.bufPrint(&key, "new{d}", .{i});
        _ = store.put(1, k, "v", 0);
        _ = store.get(1, k, &out);
        _ = store.get(1, k, &out);
    }

    try testing.expectEqual(@as(?usize, null), store.get(1, "old1000", &out));
    try testing.expect(store.get(1, "new19999", &out) != null);
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

    // A value that still fits, so what is being watched is the wrap and not a
    // refusal. It goes through whichever region `put` chooses, and the round
    // trip below is what says the wrap did not cut it in half.
    const value = "a" ** 300 ++ "b" ** 300;
    var key: [32]u8 = undefined;
    for (0..400) |i| {
        _ = store.put(1, try std.fmt.bufPrint(&key, "k{d}", .{i}), value, 0);
    }
    try testing.expect(store.put(1, "wrapped", value, 0));

    var out: [1024]u8 = undefined;
    const n = store.get(1, "wrapped", &out) orelse return error.TestExpectedHit;
    try testing.expectEqualStrings(value, out[0..n]);
}

test "a region that cannot fit an entry before its end starts again at its start" {
    // The wrap is a region's own rule, and which region a `put` lands in is a
    // different decision made above it — so this asks the region directly.
    var r: Region = .init(100, 1000);
    try testing.expectEqual(@as(u32, 100), r.reserve(500));
    try testing.expectEqual(@as(u32, 600), r.reserve(300));
    try testing.expectEqual(@as(u16, 1), r.mark().gen);

    // 900 + 200 is past `to`, so it starts again at `from` and the pass number
    // moves with it — never past zero, which is how a slot says "never
    // written".
    try testing.expectEqual(@as(u32, 100), r.reserve(200));
    try testing.expectEqual(@as(u16, 2), r.mark().gen);

    // And a slot from the pass before stops being live at the right instant,
    // not one entry early or late.
    try testing.expect(r.live(.{ .off = 600, .gen = 1 }));
    try testing.expect(!r.live(.{ .off = 100, .gen = 1 }));
    try testing.expect(r.live(.{ .off = 100, .gen = 2 }));
    try testing.expect(!r.live(.{ .off = 100, .gen = 0 }));
}

test "a slot the cursor has just passed is a ghost, and one from long ago is not" {
    // The ghost queue this cache does not pay for: a dead slot is already a
    // record that the key was here and the ring took it (ADR 0188).
    var r: Region = .init(0, 1000);
    _ = r.reserve(400); // off 0, pass 1
    _ = r.reserve(400); // off 400, pass 1
    _ = r.reserve(400); // wraps: off 0, pass 2, head 400

    const m = r.mark();
    // Written on pass 1 at 0, and pass 2's cursor has gone past it.
    try testing.expect(Region.ghostAt(m, .{ .off = 0, .gen = 1 }));
    // Written on pass 1 at 400, still ahead of pass 2's cursor — live, not a
    // ghost.
    try testing.expect(!Region.ghostAt(m, .{ .off = 400, .gen = 1 }));
    try testing.expect(Region.liveAt(m, .{ .off = 400, .gen = 1 }));
    // Nothing written on this pass is a ghost, and a way never written is not
    // a ghost either.
    try testing.expect(!Region.ghostAt(m, .{ .off = 0, .gen = 2 }));
    try testing.expect(!Region.ghostAt(m, .{ .off = 0, .gen = 0 }));

    // **The window is one lap and it is what makes this a policy.** A slot two
    // passes back is a key the cache stopped knowing anything about, not a key
    // that just came back.
    try testing.expect(!Region.ghostAt(.{ .head = 400, .gen = 9 }, .{ .off = 0, .gen = 7 }));
}

test "a key that is read again survives a flood of keys that are not" {
    // The property the two regions exist for. Before them a cache forgot in
    // write order alone, so a key asked for constantly died at the same moment
    // as one nobody ever asked for twice — and a flood of the second kind took
    // the whole cache with it.
    var store = try Store.open(testing.allocator, .{ .bytes = 1 << 20, .shards = 1 });
    defer store.deinit();

    var out: [64]u8 = undefined;
    var key: [32]u8 = undefined;

    // **Fill it first, and that is not setup.** While `main` is still filling
    // every put goes straight past the doorkeeper on purpose, so a flood into
    // an empty cache measures nothing this test is about. It also used to hide
    // the result: the wanted key landed on `main`'s very first byte, the flood
    // filled `main` exactly once, and the key survived by sitting precisely on
    // the cursor with no margin at all. One extra byte written to `main` and it
    // failed. Warming first gives it the nine tenths of the ring it should have.
    for (0..30_000) |i| {
        _ = store.put(1, try std.fmt.bufPrint(&key, "warm{d}", .{i}), "x" ** 32, 0);
    }

    // Read twice, which is what gets it out of the doorkeeper and into main.
    _ = store.put(1, "wanted", "the value", 0);
    try testing.expect(store.get(1, "wanted", &out) != null);
    try testing.expect(store.get(1, "wanted", &out) != null);

    // Now write far more one-shot keys than the ring can hold, reading each
    // one exactly never. Ten laps of `small` and one of the whole ring.
    for (0..200_000) |i| {
        _ = store.put(1, try std.fmt.bufPrint(&key, "flood{d}", .{i}), "x" ** 32, 0);
    }

    const n = store.get(1, "wanted", &out) orelse return error.TestExpectedHit;
    try testing.expectEqualStrings("the value", out[0..n]);

    // And the flood really did lap the ring, or the assertion above passed
    // because nothing was ever under pressure.
    try testing.expect(store.stats().evicted > 0 or store.stats().puts > 100_000);
}

test "a key already past the doorkeeper is not sent back through it by a refresh" {
    // A cache in front of anything spends most of its writes refreshing keys
    // it already holds. Writing one again used to send it back to `small`,
    // where the tenth of the ring laps ten times as fast — so a key hot enough
    // to be refreshed constantly was also the one being demoted constantly.
    var store = try Store.open(testing.allocator, .{ .bytes = 1 << 20, .shards = 1 });
    defer store.deinit();

    var out: [64]u8 = undefined;
    var key: [32]u8 = undefined;
    for (0..30_000) |i| {
        _ = store.put(1, try std.fmt.bufPrint(&key, "warm{d}", .{i}), "x" ** 32, 0);
    }

    _ = store.put(1, "hot", "first", 0);
    try testing.expect(store.get(1, "hot", &out) != null);
    try testing.expect(store.get(1, "hot", &out) != null);

    // Refreshed, then flooded. If the refresh had put it back in the
    // doorkeeper, ten laps of `small` would take it.
    _ = store.put(1, "hot", "second", 0);
    for (0..60_000) |i| {
        _ = store.put(1, try std.fmt.bufPrint(&key, "later{d}", .{i}), "x" ** 32, 0);
    }

    const n = store.get(1, "hot", &out) orelse return error.TestExpectedHit;
    try testing.expectEqualStrings("second", out[0..n]);
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

test "every shard the cache allocated is one a key can reach" {
    // `shard_mask` is a mask rather than a modulo, so a shard count that is
    // not a power of two names shards nothing can hash to. The budget is
    // clamped by `total_cap / 4096`, which is where a non-power-of-two came
    // from: 64 KiB on the default `shards` allocated twelve and could reach
    // eight, and the four it could not were a third of the whole budget.
    for ([_]usize{ 64 << 10, 96 << 10, 128 << 10, 192 << 10, 512 << 10, 4 << 20 }) |budget| {
        for ([_]usize{ 1, 4, 16, 64, 256 }) |asked| {
            var store = Store.open(testing.allocator, .{ .bytes = budget, .shards = asked }) catch continue;
            defer store.deinit();

            // The property itself, said directly. Everything below is the
            // demonstration that it is the property that matters.
            try testing.expect(std.math.isPowerOfTwo(store.shards.len));

            var key: [32]u8 = undefined;
            for (0..20_000) |i| {
                _ = store.put(1, std.fmt.bufPrint(&key, "k{d}", .{i}) catch unreachable, "v", 0);
            }
            // Every shard's ring cursor moved, which is the same statement as
            // "a key reached it" and is per shard, which the counters are not:
            // they are per thread now (ADR 0188).
            for (store.shards) |*s| {
                const moved = s.small.mark().head != s.small.from or
                    s.main.mark().head != s.main.from or s.main.mark().gen != 1;
                try testing.expect(moved);
            }
        }
    }
}

/// One thread of the soak below. Outside the test block because a test body
/// cannot be spawned onto a thread.
const Racer = struct {
    store: *Store,
    seed: u64,
    hits: u64 = 0,
    wrong: u64 = 0,

    const keys = 2_000;
    const longest = 400;

    /// The value's length and every byte of it come from the key's number, so
    /// half of one entry and half of another is caught, and so is a value read
    /// out of somebody else's bytes.
    fn valueLen(id: u32) usize {
        return 8 + (id * 37) % longest;
    }

    fn run(r: *Racer) void {
        var prng: std.Random.DefaultPrng = .init(r.seed);
        const rnd = prng.random();
        var key: [24]u8 = undefined;
        var val: [longest + 8]u8 = undefined;
        var out: [longest + 8]u8 = undefined;

        for (0..120_000) |_| {
            const id = rnd.uintLessThan(u32, keys);
            const k = std.fmt.bufPrint(&key, "k:{d}", .{id}) catch unreachable;
            const want: u8 = @as(u8, @truncate(id)) ^ 0x5a;

            // One write in four, so the cursor never stops moving.
            if (rnd.uintLessThan(u8, 4) == 0) {
                const n = valueLen(id);
                std.mem.writeInt(u64, val[0..8], id, .little);
                @memset(val[8..n], want);
                _ = r.store.put(7, k, val[0..n], 0);
                continue;
            }

            const n = r.store.get(7, k, &out) orelse continue;
            r.hits += 1;
            if (n != valueLen(id) or std.mem.readInt(u64, out[0..8], .little) != id) {
                r.wrong += 1;
                continue;
            }
            for (out[8..n]) |b| if (b != want) {
                r.wrong += 1;
                break;
            };
        }
    }
};

test "a lookup that holds no lock never hands back a value that is not the key's" {
    // **The test the lock-free read path exists to survive** (ADR 0188). A
    // `get` copies bytes out of the ring with nothing held and then asks the
    // region's cursor whether a `put` was writing over them while it read. This
    // is what says that second question is load-bearing rather than decoration.
    //
    // A small budget and values of every length, so the ring laps hard and
    // entries never line up. Deleting the second cursor read and running the
    // same shape for six seconds instead of this one's fraction of a second
    // produced 14,564 wrong answers on sixteen threads and 519 on eight; with
    // it, 310 million verified hits and none.
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var store = try Store.open(testing.allocator, .{ .bytes = 128 << 10, .shards = 2 });
    defer store.deinit();

    var racers: [4]Racer = undefined;
    var threads: [racers.len]std.Thread = undefined;
    for (&racers, 0..) |*r, i| r.* = .{ .store = &store, .seed = 1 + i * 7919 };
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Racer.run, .{&racers[i]});
    for (threads) |t| t.join();

    var hits: u64 = 0;
    var wrong: u64 = 0;
    for (racers) |r| {
        hits += r.hits;
        wrong += r.wrong;
    }
    try testing.expectEqual(@as(u64, 0), wrong);
    // And it really did answer things, or the assertion above passed because
    // the cache never held anything.
    try testing.expect(hits > 1_000);
}
