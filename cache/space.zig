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
//! Bucket (ADR 0068). They share one `Store`, so the memory the cache holds is
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
//! life of it** ([ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md)).
//! A handler that declares a 4 KiB `Held` has added 4 KiB to every connection
//! that reaches it, and that is the caller's number rather than this module's
//! — which is exactly why it is written as an array the caller declares
//! instead of a buffer the cache hides.
//!
//! There is no third shape and no `BufferTooSmall`: `max_bytes` bounds both
//! ends, so a `put` that would not fit is `error.TooLarge` at the moment it
//! happens, and a `get` can never be handed too little.

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
            "  The length is stored in 16 bits so four ways of a bucket are one cache" ++
            " line (ADR 0138). Something larger wants a store of its own.",
        .{ name, opts.max_bytes, flat.max_value },
    ));

    return struct {
        const Self = @This();

        store: *Store,

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

        pub fn open(store: *Store) Self {
            store.registerSpace(id, name);
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

        /// Store a value **only if the key is free**, and say whether it was:
        /// true and it is yours, false and somebody was first. One shard lock
        /// around the scan and the write, so two callers racing for a key get
        /// one true between them — which is what makes this a claim rather
        /// than a `get` followed by a `put`. An expired entry is free.
        ///
        /// A value too large is `error.TooLarge` the way `put` says it, and a
        /// flat value cannot be. `nilo.Idempotent` is what this was built for
        /// ([ADR 0193](../docs/adr/0193-a-request-answered-once-is-answered-the-same-way-again.md)).
        pub const putIfAbsent = if (kind == .flat) claimFlat else claimBytes;

        /// The same read as `get`, into a buffer of the caller's choosing
        /// rather than into a `Held` — for a caller whose buffer is an arena
        /// and whose stack is per connection (ADR 0063). `out` shorter than
        /// the entry is a miss, the way `Held` can never be.
        pub fn getInto(self: Self, key: []const u8, out: []u8) ?[]const u8 {
            const n = self.store.get(id, key, out) orelse return null;
            return out[0..n];
        }

        fn claimFlat(self: Self, key: []const u8, value: V) bool {
            return self.store.putIfAbsent(id, key, flat.asBytes(V, &value), opts.ttl_s) == .stored;
        }

        fn claimBytes(self: Self, key: []const u8, value: []const u8) PutError!bool {
            if (value.len > opts.max_bytes) return error.TooLarge;
            return switch (self.store.putIfAbsent(id, key, value, opts.ttl_s)) {
                .stored => true,
                .taken => false,
                .refused => error.TooLarge,
            };
        }

        fn putFlat(self: Self, key: []const u8, value: V) void {
            self.putFlatFor(key, value, opts.ttl_s);
        }

        fn putFlatFor(self: Self, key: []const u8, value: V, ttl_s: u32) void {
            // A flat value cannot be too large — `kindOf` refused that while
            // compiling — so there is nothing here for a caller to handle.
            _ = self.store.put(id, key, flat.asBytes(V, &value), ttl_s);
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
    return Store.open(testing.allocator, .{ .bytes = 1 << 20, .shards = 4 });
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

    try testing.expectError(error.TooLarge, jobs.putIfAbsent("big", "x" ** 65));

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
