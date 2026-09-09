//! nilo_cache — an expiring cache in this process, and nothing that needs a
//! loop (ADR 0138, ADR 0139).
//!
//! A **tool module**, the fourth: one job, no event loop, and it imports
//! nothing at all — which is why `zig test cache/cache.zig` runs the whole of
//! it, and why a program that is not a server can take this module and leave
//! the rest (ADR 0042).
//!
//! ```zig
//! const cache = @import("nilo_cache");
//!
//! const Carts = cache.Space("cart", Cart, .{ .ttl_s = 300 });
//!
//! var store = try cache.open(gpa, .{ .bytes = 64 << 20 });
//! defer store.deinit();
//! var carts = Carts.open(&store);
//!
//! carts.put("u42", cart);
//! if (carts.get("u42")) |c| { … }
//! ```
//!
//! ## What it holds, and what that costs
//!
//! **One number decides the memory and it never moves.** `bytes` is the ring
//! the values live in; the table that points at them is 8 bytes an entry on
//! top, and `store.bytesHeld()` is the sum. Nothing is allocated after `open`,
//! nothing grows, and there is no sweep — an entry goes when its time is up or
//! when the ring writes over it, whichever comes first.
//!
//! That number is the whole of it, which is worth saying because the two Go
//! caches of this shape mean something narrower by it: freecache and bigcache
//! bound the bytes their *values* take and put the index on top, unbounded, so
//! 200,000 entries on a 12 MiB budget cost them 25.2 and 28.5 MiB of RSS
//! against this module's 12.0.
//!
//! ## What it keeps when it cannot keep everything
//!
//! **A new entry has to be asked for twice before it gets the run of the
//! ring.** A shard's ring is in two parts: a new entry lands in `small`, a
//! tenth of it, and a key read again while it is still there is copied into
//! `main` and gets the other nine tenths. A key nobody asks for twice never
//! leaves the tenth it arrived in.
//!
//! This is what stops a flood of one-shot keys from flushing the entries worth
//! keeping, and it is most of what the cache is worth: on Zipf 0.99 at 512 KiB
//! it answers 75.4% of lookups where forgetting in write order alone answered
//! 67.0%, which is **two to three times less memory for the same hit rate**
//! (ADR 0187). `Stats.rescued` counts it happening.
//!
//! Two consequences to know about rather than discover:
//!
//! - **A cache with room still admits freely.** The doorkeeper is skipped
//!   while `main` has never been round, because a tenth in front of nine empty
//!   tenths is not admission control, it is throwing away room.
//! - **`main` moves only when something is promoted into it**, so a cache
//!   written to and never read holds its first entries indefinitely. Nothing
//!   is asking for them and a TTL still expires them on read, but "the ring
//!   forgets the oldest first" is no longer the whole story.
//!
//! **Nothing allocates per operation, and the signature is what says so.** A
//! flat value comes back by value; a `[]const u8` comes back in an array the
//! caller declared. There is no allocator to pass anywhere in this module.
//!
//! ## The value type decides how it is read
//!
//! | the value | `get` |
//! |---|---|
//! | flat — no pointer anywhere in it | `get(key) ?V` |
//! | `[]const u8` | `get(key, &held) ?[]const u8` |
//!
//! Anything else is refused while compiling, with the field that did it
//! named. A cache entry outlives the call that wrote it, so a pointer kept in
//! one would dangle — and Go's cache gets away with storing `interface{}`
//! only because a garbage collector is holding the other end.
//!
//! ## Why "why is my cache not hitting" has an answer
//!
//! `store.stats()` counts hits apart from the three ways of missing: never
//! written, written and expired, and **written and evicted**, which is the one
//! that means the ring is too small. `Stats.evictionRate()` is that question
//! asked directly. A cache whose misses are evictions wants more `bytes`; one
//! whose misses are misses is being asked about keys nobody wrote.
//!
//! Sizing, measured rather than guessed
//! ([`bench/result/cache.md`](../bench/result/cache.md)): on Zipf 0.99 a ring
//! at a fortieth of the working set answers 63.9% of lookups and one at a
//! fifth answers 94.1%. **Ask for the hit rate you want rather than for a
//! multiple of the data**, and read `stats()` to find out whether you got it.
//!
//! An earlier version of this paragraph said hit rate was ring bytes over
//! working-set bytes with no cliff, which was true of the benchmark that
//! produced it and not of traffic: it drew its keys uniformly at random, and
//! under uniform random every policy scores the same and that score is the
//! ratio. It is kept here as a warning rather than deleted, because that
//! sentence stood for a year (ADR 0187).
//!
//! ## What it will not do
//!
//! **It is this process's memory and no more than that.** Two instances of
//! your program have two caches that do not agree, they do not survive a
//! restart, and nothing here reaches a network. That is the trade the module
//! is for; ADR 0139 is where it is argued, and where `nilo_redis` is the other
//! answer nobody has needed yet.
//!
//! **And it is safe to hold under a fiber, because of a rule this module
//! keeps**: a lock is held across a `memcpy` and nothing else, ever. Zig
//! 0.16's `std.Io.Mutex` needs an `Io` a module in this layer does not have,
//! so the lock spins — and a critical section with nothing in it that waits
//! always finishes and releases (ADR 0138). **A `get` does not take it at
//! all** (ADR 0188): it copies the value out and then asks the ring's write
//! cursor whether anything wrote over those bytes while it read them.

const std = @import("std");

const clock = @import("clock.zig");
const flat = @import("flat.zig");
const space = @import("space.zig");
const store = @import("store.zig");

/// One pool of memory, shared by every Space in the program. The way
/// `nilo_s3`'s buckets share one Store, and for the same reason: how much a
/// cache costs should be one number.
pub const Store = store.Store;

/// How big, in how many pieces. `bytes` is the one most programs set.
pub const Options = store.Options;

pub const OpenError = store.OpenError;

/// Hits, and the three different ways of missing.
pub const Stats = store.Stats;

/// A keyspace with a name, a value type and a life. Two Spaces are two types,
/// therefore two services (ADR 0068).
pub const Space = space.Space;

/// The one thing a `put` of bytes can fail at.
pub const PutError = space.PutError;

/// The largest value an entry can hold, being what the slot's 16-bit length
/// can say.
pub const max_value = flat.max_value;

/// Open the memory. **It is all taken here** — the ring, the table, and the
/// pages behind both touched once so the first thousand operations are not
/// measuring the kernel handing them over.
pub fn open(gpa: std.mem.Allocator, options: Options) OpenError!Store {
    return Store.open(gpa, options);
}

test {
    _ = clock;
    _ = flat;
    _ = space;
    _ = store;
}

// -- the property ADR 0138 is about --------------------------------------

const testing = std.testing;

/// A value whose own bytes say which key wrote them, so a reader handed the
/// wrong entry — or half of two — can say so rather than merely returning
/// something plausible.
const Marked = struct {
    id: u64,
    /// `id` again, xored, so a value assembled from two different entries
    /// fails even when both halves are individually well-formed.
    check: u64,

    fn of(id: u64) Marked {
        return .{ .id = id, .check = id ^ 0x5eed_1234_dead_beef };
    }
    fn sound(self: Marked, id: u64) bool {
        return self.id == id and self.check == (id ^ 0x5eed_1234_dead_beef);
    }
};

const Marks = Space("marks", Marked, .{});

const Racer = struct {
    marks: Marks,
    /// Anything but zero in `wrong` and the design is wrong rather than the
    /// tuning — which is what ADR 0138 found the first time this was written.
    wrong: u64 = 0,
    hits: u64 = 0,

    const keys = 4_000;
    /// **A count rather than a stretch of time, and that is not a detail.**
    /// The first version of this test ran until a coarse clock had moved a
    /// second, and a coarse clock moves in ticks — starting a millisecond
    /// before one, it finished having done almost nothing, passed every
    /// assertion it could still reach, and failed the one about how much work
    /// it had done. Intermittently. A test whose amount of work depends on
    /// when it started is a test that reports the scheduler.
    const rounds = 200_000;

    fn write(self: *Racer, seed: u64) void {
        var prng = std.Random.DefaultPrng.init(seed);
        var key: [32]u8 = undefined;
        for (0..rounds) |_| {
            const id = prng.random().uintLessThan(u64, keys);
            self.marks.put(std.fmt.bufPrint(&key, "m{d}", .{id}) catch unreachable, .of(id));
        }
    }

    fn read(self: *Racer, seed: u64) void {
        var prng = std.Random.DefaultPrng.init(seed);
        var key: [32]u8 = undefined;
        for (0..rounds) |_| {
            const id = prng.random().uintLessThan(u64, keys);
            const got = self.marks.get(std.fmt.bufPrint(&key, "m{d}", .{id}) catch unreachable) orelse continue;
            self.hits += 1;
            if (!got.sound(id)) self.wrong += 1;
        }
    }
};

test "a reader is never handed another entry's bytes, with more threads than cores" {
    // Small on purpose. A ring that holds the whole working set never writes
    // over anything, and never writing over anything is the one case this
    // test is not about.
    var s = try open(testing.allocator, .{ .bytes = 256 << 10, .shards = 4 });
    defer s.deinit();
    const marks = Marks.open(&s);

    var racers: [6]Racer = undefined;
    for (&racers) |*r| r.* = .{ .marks = marks };

    // Six threads is more than the cores of any machine this is likely to run
    // on, which is the condition the failure needs: a writer descheduled
    // inside its own `memcpy` is lapped by the ring and writes over an entry
    // newer than itself. Threads equal to cores reported zero wrong answers
    // for 34.9 million reads while the shape was still broken, so a test that
    // does not oversubscribe is a test that passes for the wrong reason.
    var threads: [6]std.Thread = undefined;
    for (0..3) |i| threads[i] = try std.Thread.spawn(.{}, Racer.write, .{ &racers[i], 1 + i });
    for (3..6) |i| threads[i] = try std.Thread.spawn(.{}, Racer.read, .{ &racers[i], 100 + i });
    for (threads) |t| t.join();

    var wrong: u64 = 0;
    var hits: u64 = 0;
    for (racers) |r| {
        wrong += r.wrong;
        hits += r.hits;
    }

    try testing.expectEqual(@as(u64, 0), wrong);

    // A run that hit nothing would pass the line above while proving nothing,
    // which is the shape of a test that has quietly stopped testing.
    try testing.expect(hits > 10_000);

    // And the ring really was writing over things, or the run was the easy
    // case wearing the hard case's name.
    try testing.expect(s.stats().evicted > 0);
}
