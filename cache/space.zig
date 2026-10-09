//! A Space is a type, and what it holds decides how it is read.
//!
//! ```zig
//! const Carts = cache.Space("cart", Cart, .{ .ttl_s = 300 });
//!
//! var carts = Carts.open(&store);
//! carts.put("u42", cart);
//! if (carts.get("u42")) |c| { … }
//! ```
//!
//! Two Spaces are two types, therefore two services, and which one a handler
//! reaches is written in its argument list — the rule `nilo_s3` states for a
//! Bucket (ADR 059). They share one `Store`, so the memory the cache holds is
//! one number rather than one per Space.
//!
//! ## Two shapes, and the value type picks
//!
//! A **flat** value — a number, an enum, a struct with no pointer anywhere in
//! it — has a size known while compiling, so it comes back by value and
//! nobody needs a buffer:
//!
//! ```zig
//! const Hits = cache.Space("hits", u64, .{ .ttl_s = 60 });
//! if (hits.get("/pricing")) |n| { … }
//! ```
//!
//! A **`[]const u8`** value does not, so the Space says how big one can get
//! and hands out the array to read it into:
//!
//! ```zig
//! const Pages = cache.Space("page", []const u8, .{ .max_bytes = 4096 });
//!
//! var held: Pages.Held = undefined;
//! if (pages.get("/about", &held)) |html| { … }
//! ```
//!
//! **`Held` is the caller's stack, and stack is held per connection for the
//! life of it** ([ADR 062](../docs/adr/062-where-a-connection-waits-is-what-it-costs.md)).
//! A handler that declares a 4 KiB `Held` has added 4 KiB to every connection
//! that reaches it, and that is the caller's number rather than this module's
//! — which is exactly why it is written as an array the caller declares
//! instead of a buffer the cache hides.
//!
//! There is no third shape and no `BufferTooSmall`: `max_bytes` bounds both
//! ends, so a `put` that would not fit is `error.TooLarge` at the moment it
//! happens, and a `get` can never be handed too little.
//!
//! ## A Space of integers counts
//!
//! ```zig
//! const Attempts = cache.Space("signin", u32, .{ .ttl_s = 3600 });
//! if ((try attempts.incr(email, 1)) > 5) return fail.tooMany("try again in an hour", .{});
//! ```
//!
//! `incr` is one add under the shard's lock, so two requests arriving at
//! once count two — the `get` then `put` it replaces lost one of them
//! ([ADR 109](../docs/adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)).
//! A key nobody wrote counts from zero and lives `ttl_s`; one already there
//! keeps the expiry it had, so the hour above is the hour of the first
//! attempt rather than a window that slides with every one. Saturating: a
//! counter at its type's ceiling stays there rather than opening the quota
//! again. Only on a Space whose value is an integer — anything else is a
//! Refusal naming the type.

const std = @import("std");
const flat = @import("flat.zig");
const store_mod = @import("store.zig");

const Store = store_mod.Store;

pub const Options = struct {
    /// Seconds an entry lives. Zero means until the ring writes over it,
    /// which for a cache is a perfectly good answer — nothing here sweeps.
    ttl_s: u32 = 0,
    /// The largest value a `[]const u8` Space will hold, and the size of its
    /// `Held`. **Read only for that shape**: a flat value's size is its
    /// type's, and this is ignored.
    max_bytes: usize = 4096,
};

pub const PutError = error{
    /// The value is longer than the Space's `max_bytes`, or longer than a
    /// quarter of one shard's ring — a single entry big enough to evict most
    /// of a shard is a cache that holds one thing.
    TooLarge,
};

/// `name` separates one Space's keys from another's and costs nothing at run
/// time: it is hashed while compiling into the seed every key of this Space
/// goes through, and stored in each entry so a fingerprint collision between
/// two keys cannot cross a Space boundary.
pub fn Space(comptime name: []const u8, comptime V: type, comptime opts: Options) type {
    if (name.len == 0) @compileError(
        "nilo: a cache Space needs a name.\n" ++
            "  It is what keeps one Space's keys out of another's, and it is what a" ++
            " collision between two of them is reported by. `cache.Space(\"cart\", …)`.",
    );

    const kind = flat.kindOf(V, shortName(V));
    if (kind == .bytes and opts.max_bytes == 0) @compileError(
        "nilo: the cache Space \"" ++ name ++ "\" holds bytes and its `max_bytes` is 0.\n" ++
            "  That is the size of the buffer a `get` reads into, so nothing could ever" ++
            " be read out of it.",
    );
    if (kind == .bytes and opts.max_bytes > flat.max_value) @compileError(std.fmt.comptimePrint(
        "nilo: the cache Space \"{s}\" asks to hold {d} bytes, and an entry holds at most {d}.\n" ++
            "  The length is stored in 16 bits so eight ways of a bucket are one cache" ++
            " line (ADR 109). Something larger wants a store of its own.",
        .{ name, opts.max_bytes, flat.max_value },
    ));

    return struct {
        const Self = @This();

        store: *Store,

        /// Nothing a Space does waits (ADR 109: a lock is held across a copy
        /// and nothing else), which is what lets an HTTP/2 call to a route
        /// that takes one run on its connection's fiber (ADR 260).
        pub const nilo_never_waits = true;

        /// Hashed while compiling. Two Spaces whose names land on the same 32
        /// bits are caught by `Store.registerSpace` when the second opens,
        /// which turns a one-in-four-billion wrong answer into a panic naming
        /// both names.
        pub const id: u32 = @truncate(std.hash.Wyhash.hash(0, name));

        /// What a `get` reads into, for a Space that holds bytes. `void` for
        /// a flat one, which needs no buffer at all.
        pub const Held = if (kind == .bytes) [opts.max_bytes]u8 else void;

        /// The largest value this Space will take.
        pub const max_bytes: usize = if (kind == .bytes) opts.max_bytes else @sizeOf(V);

        /// Registers the name, and **refuses a flat `V` this Store could never
        /// hold**: a panic naming the type, the limit and the budget, as
        /// `registerSpace` does for a name collision, because it is a
        /// programmer's error found at startup rather than a request's.
        /// An entry is refused over a quarter of one shard's ring, so a
        /// 20,000-byte struct on a 64 KiB store would otherwise be dropped on
        /// every `put` with nothing to say so. Checked with the same rule
        /// `Store.write` refuses by (`Store.fits`).
        pub fn open(store: *Store) Self {
            store.registerSpace(id, name);
            if (kind == .flat and !store.fits(0, @sizeOf(V))) std.debug.panic(
                "nilo: the cache Space \"{s}\" holds {s}, which is {d} bytes ({d} with its entry header), " ++
                    "and this Store takes an entry of at most {d}: a quarter of a shard's ring, " ++
                    "and its {d} shards hold {d} bytes of ring between them.\n" ++
                    "  A value this size would be refused on every put. Open the Store with more " ++
                    "`bytes` or fewer `shards`, or make the value smaller.",
                .{
                    name,                                          shortName(V),       @sizeOf(V),
                    store_mod.header + @sizeOf(V),                 store.entryLimit(), store.shardCount(),
                    store.shardCount() * store.shards[0].ring.len,
                },
            );
            return .{ .store = store };
        }

        /// Store a value under a key, for this Space's `ttl_s`.
        pub const put = if (kind == .flat) putFlat else putBytes;

        /// The same, for one entry that should live a different length of
        /// time. Zero means until the ring writes over it.
        pub const putFor = if (kind == .flat) putFlatFor else putBytesFor;

        /// Read it back. `null` is every kind of not-here — never written,
        /// written and expired, written and evicted — and `Store.stats()` is
        /// what tells those apart.
        pub const get = if (kind == .flat) getFlat else getBytes;

        /// Forget a key. True when there was something to forget.
        pub fn del(self: Self, key: []const u8) bool {
            return self.store.del(id, key);
        }

        /// Add `delta` to the count under `key` and answer the new count
        /// — see the file header. A Space whose value is not an integer has
        /// nothing to add to, and says so while compiling.
        ///
        /// A key over 65,535 bytes, or an entry over a quarter of a shard's
        /// ring, is `error.TooLarge`: a refusal is never a count.
        pub fn incr(self: Self, key: []const u8, delta: V) PutError!V {
            comptime if (@typeInfo(V) != .int) @compileError(
                "nilo: the cache Space \"" ++ name ++ "\" holds " ++ shortName(V) ++
                    ", and `incr` adds to an integer.\n" ++
                    "  A count is a Space of its own: `cache.Space(\"" ++ name ++
                    "\", u64, .{ .ttl_s = … })`, and `incr(key, 1)` on that is the " ++
                    "new count under the lock a `put` already takes (ADR 109).",
            );
            return self.store.add(V, id, key, delta, opts.ttl_s);
        }

        /// Store a value **only if the key is free**, and say whether it was:
        /// true and it is yours, false and somebody was first. One shard lock
        /// around the scan and the write, so two callers racing for a key get
        /// one true between them — which is what makes this a claim rather
        /// than a `get` followed by a `put`. An expired entry is free.
        ///
        /// A value too large is `error.TooLarge` the way `put` says it, and a
        /// flat value cannot be. `nilo.Cached` claims its key with this
        /// ([ADR 188](../docs/adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)).
        pub const putIfAbsent = if (kind == .flat) claimFlat else claimBytes;

        /// The same claim, for an entry that lives `ttl_s` rather than the
        /// Space's own. Zero means until the ring writes over it. What
        /// `nilo.Idempotent` claims its in-flight marker with, so that a
        /// Space whose answers are kept for a day does not keep a marker a
        /// crashed handler left for a day (ADR 155).
        pub const putIfAbsentFor = if (kind == .flat) claimFlatFor else claimBytesFor;

        /// The same read as `get`, into a buffer of the caller's choosing
        /// rather than into a `Held` — for a caller whose buffer is an arena
        /// and whose stack is per connection (ADR 062). `out` shorter than
        /// the entry is a miss, the way `Held` can never be.
        pub fn getInto(self: Self, key: []const u8, out: []u8) ?[]const u8 {
            const n = self.store.get(id, key, out) orelse return null;
            return out[0..n];
        }

        fn claimFlat(self: Self, key: []const u8, value: V) bool {
            return self.claimFlatFor(key, value, opts.ttl_s);
        }

        fn claimFlatFor(self: Self, key: []const u8, value: V, ttl_s: u32) bool {
            const claim = self.store.putIfAbsent(id, key, flat.asBytes(V, &value), ttl_s);
            // `open` refused a V no shard could hold, so a refusal here is the
            // key's doing (over 65,535 bytes, or so long the entry passes a
            // quarter of the ring), and a refusal is not "somebody was first".
            std.debug.assert(claim != .refused or !self.store.fits(key.len, @sizeOf(V)));
            return claim == .stored;
        }

        fn claimBytes(self: Self, key: []const u8, value: []const u8) PutError!bool {
            return self.claimBytesFor(key, value, opts.ttl_s);
        }

        fn claimBytesFor(self: Self, key: []const u8, value: []const u8, ttl_s: u32) PutError!bool {
            if (value.len > opts.max_bytes) return error.TooLarge;
            return switch (self.store.putIfAbsent(id, key, value, ttl_s)) {
                .stored => true,
                .taken => false,
                .refused => error.TooLarge,
            };
        }

        fn putFlat(self: Self, key: []const u8, value: V) void {
            self.putFlatFor(key, value, opts.ttl_s);
        }

        fn putFlatFor(self: Self, key: []const u8, value: V, ttl_s: u32) void {
            // A flat value cannot be too large: `kindOf` refused 65,535 bytes
            // while compiling and `open` refused one over a quarter of a
            // shard's ring when the Store was known, so there is nothing for
            // a caller to handle. What can still be refused is a key so long
            // that the entry no longer fits, which the assertion lets through
            // and nothing else.
            const stored = self.store.put(id, key, flat.asBytes(V, &value), ttl_s);
            std.debug.assert(stored or !self.store.fits(key.len, @sizeOf(V)));
        }

        fn getFlat(self: Self, key: []const u8) ?V {
            // Straight into the value rather than into a buffer and then out
            // of it again. The two-step read cost a second copy of every hit
            // for nothing — the destination was always going to be this.
            var value: V = undefined;
            const n = self.store.get(id, key, flat.asWritableBytes(V, &value)) orelse return null;
            // A shorter answer means another type wrote this key, which
            // cannot happen inside one Space and is a miss if it ever does.
            if (n != @sizeOf(V)) return null;
            return value;
        }

        fn putBytes(self: Self, key: []const u8, value: []const u8) PutError!void {
            return self.putBytesFor(key, value, opts.ttl_s);
        }

        fn putBytesFor(self: Self, key: []const u8, value: []const u8, ttl_s: u32) PutError!void {
            if (value.len > opts.max_bytes) return error.TooLarge;
            if (!self.store.put(id, key, value, ttl_s)) return error.TooLarge;
        }

        fn getBytes(self: Self, key: []const u8, held: *Held) ?[]const u8 {
            const n = self.store.get(id, key, held) orelse return null;
            return held[0..n];
        }
    };
}

/// `Cart` rather than `space.test.a cached value.Cart`, so a Refusal reads
/// like the code that caused it.
fn shortName(comptime V: type) []const u8 {
    const full = @typeName(V);
    var at = full.len;
    while (at > 0) : (at -= 1) {
        if (full[at - 1] == '.') return full[at..];
    }
    return full;
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

const Currency = enum { idr, usd };
const Cart = struct { owner: u64, items: u16, currency: Currency };

fn openStore() !Store {
    return Store.open(testing.allocator, .{ .bytes = 1 << 20, .shards = 4, .seed = 1 });
}

test "a flat value comes back by value, with no buffer anywhere" {
    var store = try openStore();
    defer store.deinit();

    const Carts = Space("cart", Cart, .{});
    var carts = Carts.open(&store);

    carts.put("u42", .{ .owner = 42, .items = 3, .currency = .idr });
    const got = carts.get("u42") orelse return error.TestExpectedHit;
    try testing.expectEqual(@as(u64, 42), got.owner);
    try testing.expectEqual(@as(u16, 3), got.items);
    try testing.expectEqual(Currency.idr, got.currency);
}

test "a key nobody wrote is null rather than a zero value" {
    var store = try openStore();
    defer store.deinit();

    const Hits = Space("hits", u64, .{});
    var hits = Hits.open(&store);

    try testing.expectEqual(@as(?u64, null), hits.get("/pricing"));
    hits.put("/pricing", 0);
    try testing.expectEqual(@as(?u64, 0), hits.get("/pricing"));
}

test "a Space of integers counts, and a key nobody wrote counts from zero" {
    var store = try openStore();
    defer store.deinit();

    const Attempts = Space("signin", u32, .{ .ttl_s = 3600 });
    var attempts = Attempts.open(&store);

    try testing.expectEqual(@as(?u32, null), attempts.get("ada@example"));
    try testing.expectEqual(@as(u32, 1), try attempts.incr("ada@example", 1));
    try testing.expectEqual(@as(u32, 4), try attempts.incr("ada@example", 3));
    try testing.expectEqual(@as(?u32, 4), attempts.get("ada@example"));
    // Adding nothing reads the count under the same lock, and a delete
    // starts it over.
    try testing.expectEqual(@as(u32, 4), try attempts.incr("ada@example", 0));
    try testing.expect(attempts.del("ada@example"));
    try testing.expectEqual(@as(u32, 1), try attempts.incr("ada@example", 1));
}

test "a bytes Space reads into the array it hands out" {
    var store = try openStore();
    defer store.deinit();

    const Pages = Space("page", []const u8, .{ .max_bytes = 64 });
    var pages = Pages.open(&store);

    try pages.put("/about", "<h1>hello</h1>");
    var held: Pages.Held = undefined;
    const html = pages.get("/about", &held) orelse return error.TestExpectedHit;
    try testing.expectEqualStrings("<h1>hello</h1>", html);
}

test "a value over the Space's ceiling is refused by name rather than dropped" {
    var store = try openStore();
    defer store.deinit();

    const Pages = Space("page", []const u8, .{ .max_bytes = 8 });
    var pages = Pages.open(&store);

    try testing.expectError(error.TooLarge, pages.put("/about", "more than eight bytes"));
    var held: Pages.Held = undefined;
    try testing.expectEqual(@as(?[]const u8, null), pages.get("/about", &held));
}

test "two Spaces of different types share a Store and never each other's keys" {
    var store = try openStore();
    defer store.deinit();

    const Carts = Space("cart", Cart, .{});
    const Hits = Space("hits", u64, .{});
    var carts = Carts.open(&store);
    var hits = Hits.open(&store);

    carts.put("same", .{ .owner = 7, .items = 1, .currency = .usd });
    hits.put("same", 99);

    try testing.expectEqual(@as(u64, 7), (carts.get("same") orelse return error.TestExpectedHit).owner);
    try testing.expectEqual(@as(?u64, 99), hits.get("same"));
}

test "the same Space opened twice is not a collision" {
    var store = try openStore();
    defer store.deinit();

    const Hits = Space("hits", u64, .{});
    var a = Hits.open(&store);
    var b = Hits.open(&store);
    a.put("k", 1);
    try testing.expectEqual(@as(?u64, 1), b.get("k"));
}

test "an entry given its own life expires without touching the Space's default" {
    var store = try openStore();
    defer store.deinit();

    const Hits = Space("hits", u64, .{ .ttl_s = 0 });
    var hits = Hits.open(&store);

    hits.put("forever", 1);
    hits.putFor("briefly", 2, 1);
    store.opened_s -= 60;

    try testing.expectEqual(@as(?u64, 1), hits.get("forever"));
    try testing.expectEqual(@as(?u64, null), hits.get("briefly"));
}

test "a deleted key is gone from its Space and only from it" {
    var store = try openStore();
    defer store.deinit();

    const Hits = Space("hits", u64, .{});
    const Views = Space("views", u64, .{});
    var hits = Hits.open(&store);
    var views = Views.open(&store);

    hits.put("k", 1);
    views.put("k", 2);
    try testing.expect(hits.del("k"));

    try testing.expectEqual(@as(?u64, null), hits.get("k"));
    try testing.expectEqual(@as(?u64, 2), views.get("k"));
}

test "a claim on a Space goes to whoever was first, and getInto reads without a Held" {
    var store = try openStore();
    defer store.deinit();

    const Jobs = Space("job", []const u8, .{ .max_bytes = 64 });
    const jobs = Jobs.open(&store);

    try testing.expect(try jobs.putIfAbsent("nightly", "worker-1"));
    try testing.expect(!try jobs.putIfAbsent("nightly", "worker-2"));

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("worker-1", jobs.getInto("nightly", &buf).?);
    // A buffer too short is a miss rather than a partial read.
    var short: [4]u8 = undefined;
    try testing.expect(jobs.getInto("nightly", &short) == null);

    try testing.expectError(error.TooLarge, jobs.putIfAbsent("big", &@as([65]u8, @splat('x'))));

    // The same claim with a lifetime of its own is still a claim.
    try testing.expect(try jobs.putIfAbsentFor("weekly", "worker-1", 60));
    try testing.expect(!try jobs.putIfAbsentFor("weekly", "worker-2", 60));
    try testing.expectEqualStrings("worker-1", jobs.getInto("weekly", &buf).?);
    try testing.expectError(error.TooLarge, jobs.putIfAbsentFor("big", &@as([65]u8, @splat('x')), 60));

    const Locks = Space("lock", u32, .{});
    const locks = Locks.open(&store);
    try testing.expect(locks.putIfAbsent("a", 1));
    try testing.expect(!locks.putIfAbsent("a", 2));
    try testing.expectEqual(@as(?u32, 1), locks.get("a"));
}

test "Held is the value's own size for a flat Space, and nothing at all" {
    try testing.expectEqual(void, Space("cart", Cart, .{}).Held);
    try testing.expectEqual(@sizeOf(Cart), Space("cart", Cart, .{}).max_bytes);
    try testing.expectEqual([32]u8, Space("page", []const u8, .{ .max_bytes = 32 }).Held);
}

test "incr on a key too large for the cache is an error rather than a count" {
    var store = try Store.open(testing.allocator, .{ .bytes = 1 << 20, .shards = 1, .seed = 1 });
    defer store.deinit();
    const Attempts = Space("attempts", u32, .{ .ttl_s = 60 });
    var attempts = Attempts.open(&store);

    try testing.expectError(error.TooLarge, attempts.incr(&@as([70_000]u8, @splat('k')), 1));
    try testing.expectEqual(@as(u32, 1), try attempts.incr("ada@example", 1));
}

test "a flat value that fits no shard is refused by open rather than dropped on every put" {
    // 20,000 bytes on a 64 KiB store: a shard's ring is under 7 KiB and an
    // entry may take a quarter of it. `open` panics for this V (a panic cannot
    // be caught in a test), so the rule it asks is what is checked, and the
    // old outcome is shown for the Store that cannot hold it.
    const Big = struct { bytes: [20_000]u8 };
    var small = try Store.open(testing.allocator, .{ .bytes = 64 << 10, .seed = 1 });
    defer small.deinit();
    try testing.expect(!small.fits(0, @sizeOf(Big)));
    try testing.expect(!small.put(Space("big", Big, .{}).id, "k", &@as([@sizeOf(Big)]u8, @splat(1)), 0));

    // A Store with room takes it, and opens.
    var roomy = try Store.open(testing.allocator, .{ .bytes = 8 << 20, .shards = 4, .seed = 1 });
    defer roomy.deinit();
    try testing.expect(roomy.fits(0, @sizeOf(Big)));
    const Bigs = Space("big", Big, .{});
    var bigs = Bigs.open(&roomy);
    bigs.put("k", .{ .bytes = @splat(7) });
    try testing.expectEqual(@as(u8, 7), bigs.get("k").?.bytes[19_999]);
}

test "a flat value exactly at the limit opens and round-trips" {
    // One shard on the smallest budget: ring = 65,536 - 1,365 slots * 8 =
    // 54,616, a quarter is 13,654, and the header takes 12 of it.
    const Edge = struct { bytes: [13_642]u8 };
    var store = try Store.open(testing.allocator, .{ .bytes = 64 << 10, .shards = 1, .seed = 1 });
    defer store.deinit();
    try testing.expectEqual(@as(usize, 13_654), store.entryLimit());
    try testing.expectEqual(store.entryLimit(), store_mod.header + @sizeOf(Edge));
    try testing.expect(store.fits(0, @sizeOf(Edge)));
    try testing.expect(!store.fits(0, @sizeOf(Edge) + 1));

    const Edges = Space("edge", Edge, .{});
    var edges = Edges.open(&store);
    edges.put("", .{ .bytes = @splat(9) });
    try testing.expectEqual(@as(u8, 9), edges.get("").?.bytes[13_641]);
}
