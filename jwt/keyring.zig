//! A key set that rotates under its readers
//! ([ADR 111](../docs/adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).
//!
//! ```zig
//! var google: jwt.Keyring = try .init(gpa, .{
//!     .url = "https://www.googleapis.com/oauth2/v3/certs",
//!     .issuer = .{ .is = "https://accounts.google.com" },
//!     .audience = .{ .is = client_id },
//! });
//! defer google.deinit();
//! try app.provide(&google);
//! try app.before(fetchKeys, .{ &google, &api });   // google.refresh(run, api, now)
//!
//! fn authenticate(c: *nilo.Ctx, google: *jwt.Keyring, api: *fetch.Client) !CurrentUser {
//!     const auth = try c.authorization(.bearer);
//!     const claims = try google.verifyOrRefresh(Claims, c.arena(), auth.value.view(), now_s, c, api);
//!     …
//! }
//! ```
//!
//! Every issuer rotates — Google on the order of days — and the guide used
//! to say the answer was three lines: fetch again on `NoSuchKey`, hold a
//! `*const Keys`, swap under a mutex. Each line was wrong in a way no test
//! finds. A `NoSuchKey` with no refetch is every sign-in failing until a
//! restart; a refetch with no bound is one HTTPS GET to the issuer per
//! forged `kid`; and replacing the `Keys` a verify on another thread is
//! reading, then `deinit`ing the old one, is a use-after-free. The third is
//! concurrency rather than policy, and it is why this lives here.
//!
//! **The set is swapped whole, and the old one is freed after its readers
//! are done — the readers never wait.** A verify pins the set it is about
//! to read, verifies, and unpins; a swap publishes the new set, waits for
//! the old set's pins to reach zero, and frees it. `std.Io.Mutex` needs an
//! `Io` a tool module has none of (ADR 109), so the one wait here is the
//! writer's spin on a count, bounded by the length of one verify — CPU
//! work with nothing in it that waits — and it runs once per rotation.
//! `nilo_cache` answers the same lifetime question by copying the value and
//! checking a generation afterwards (ADR 152); a key set is not flat, so
//! the answer here is a pin rather than a copy.
//!
//! **An unknown `kid` is a fetch at most once per `refresh_interval_s`.**
//! Whichever verify sees the miss first takes the slot; the others in that
//! window are `NoSuchKey`, which under a real rotation is a handful of 401s
//! and under a forged token is the bound doing its job.
//!
//! The module still imports nothing: the client is a parameter, the way
//! `job.Table` takes a Db, and it is asked for one call — `get(scope, url,
//! .{})` answering something with `ok()` and `body.view()` — which is what
//! `fetch.Client` answers and what a test's fake answers too.

const std = @import("std");
const jwks = @import("jwks.zig");
const token_mod = @import("token.zig");
const memo_mod = @import("memo.zig");

pub const Keyring = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    /// The set a verify reads, swapped whole and never null.
    current: std.atomic.Value(*Set),
    /// Readers between loading `current` and pinning what they loaded. A
    /// swap waits for this to be zero before it trusts the old set's own
    /// count, so a reader cannot pin a set the swap has already freed.
    crossing: std.atomic.Value(usize) = .init(0),
    /// When the last fetch ran, in seconds, or the minimum for never. What
    /// bounds a refresh an unknown `kid` asks for.
    last_refresh_s: std.atomic.Value(i64) = .init(std.math.minInt(i64)),
    /// The signatures checked under the current set (`remember_tokens`).
    memo: ?memo_mod.Memo = null,

    pub const Options = struct {
        /// Where the issuer publishes its keys: Google's is
        /// `https://www.googleapis.com/oauth2/v3/certs`, and for anything
        /// OIDC it is the `jwks_uri` in `/.well-known/openid-configuration`.
        url: []const u8,
        /// What `verify` insists on, for every token this ring checks. The
        /// same three fields `jwt.Options` has, held once. `issuer` and
        /// `audience` have no default: a ring over Google's keys that
        /// forgot its audience would accept an ID token minted for any
        /// other application Google signs, so leaving one out is a compile
        /// error and skipping one is `.unchecked`, written where it is read
        /// (ADR 111). `.{ .is = client_id }` is the check.
        issuer: token_mod.Expect,
        audience: token_mod.Expect,
        leeway_s: u32 = 0,
        /// How often an unknown `kid` may trigger a fetch, at most. Sixty
        /// seconds is one refetch a minute under a flood of forged tokens,
        /// and one rotation noticed within a minute of the first token
        /// signed under the new key.
        refresh_interval_s: u32 = 60,
        /// How many verified tokens to remember by digest, so a bearer
        /// token that comes back skips the signature arithmetic — ES256 is
        /// 400 µs a verify — and not the claims checks. Zero remembers
        /// none. A service whose callers hold a handful of long-lived
        /// tokens wants a few hundred; a site with a token per user wants
        /// enough for the users on at once. A lookup costs the same at any
        /// size; the memory is 66 bytes a token (ADR 209).
        remember_tokens: u16 = 0,
    };

    pub const Error = jwks.Error || error{
        /// The issuer answered the fetch with something other than a 2xx.
        /// The set that was held is still held.
        KeysNotAvailable,
    };

    /// One published set and how many verifies are reading it.
    const Set = struct {
        keys: jwks.Keys,
        readers: std.atomic.Value(usize) = .init(0),
    };

    /// A ring holding no keys: every verify is `NoSuchKey` until `load` or
    /// `refresh` has run. `deinit` frees whatever it holds then.
    pub fn init(gpa: std.mem.Allocator, opts: Options) error{OutOfMemory}!Keyring {
        const set = try gpa.create(Set);
        errdefer gpa.destroy(set);
        set.* = .{ .keys = .{ .all = &.{}, .arena = .init(gpa) } };
        const memo: ?memo_mod.Memo = if (opts.remember_tokens > 0) try memo_mod.Memo.init(gpa, opts.remember_tokens) else null;
        return .{ .gpa = gpa, .opts = opts, .current = .init(set), .memo = memo };
    }

    pub fn deinit(self: *Keyring) void {
        if (self.memo) |*m| m.deinit(self.gpa);
        const set = self.current.load(.acquire);
        std.debug.assert(set.readers.load(.acquire) == 0); // a verify still in flight
        set.keys.deinit();
        self.gpa.destroy(set);
        self.* = undefined;
    }

    /// Read a JWKS document and make it the set every verify from now on
    /// reads. The old set is freed once the verifies already reading it
    /// have finished, and not before.
    ///
    /// A document that does not parse leaves the old set in place, so an
    /// issuer publishing a broken page for a minute costs nothing but the
    /// error.
    pub fn load(self: *Keyring, bytes: []const u8) jwks.Error!void {
        var keys = try jwks.parse(self.gpa, bytes);
        errdefer keys.deinit();
        const set = try self.gpa.create(Set);
        set.* = .{ .keys = keys };

        // Published. Every reader from here loads the new set.
        const old = self.current.swap(set, .seq_cst);

        // A reader that loaded `old` a moment ago may not have pinned it
        // yet, and it is inside `crossing` until it has. Once that count
        // has been seen at zero, every pin on `old` there will ever be is
        // already counted, and the old set's own count is the truth. Both
        // waits are bounded by one verify's worth of CPU, and a swap is
        // once per rotation, so the spin is the right wait here (ADR 109).
        while (self.crossing.load(.seq_cst) != 0) std.atomic.spinLoopHint();
        while (old.readers.load(.acquire) != 0) std.atomic.spinLoopHint();

        // Nothing remembered under the old set counts: a key that is gone
        // verified nothing. Cleared *after* the drain, not at the swap — a
        // reader still pinned on `old` was verifying under its keys, and
        // would have remembered that digest a moment after a clear at the
        // swap, leaving a token the new set never saw in the memo.
        if (self.memo) |*m| m.clear();
        old.keys.deinit();
        self.gpa.destroy(old);
    }

    /// Fetch the document at `url` through `client` and `load` it. For a
    /// startup path in `app.before`, and a ticker that refreshes on a
    /// schedule; `verifyOrRefresh` is the one for a `kid` that went missing.
    ///
    /// `client` is anything with `get(scope, url, .{})` answering `ok()` and
    /// `body.view()`, which `fetch.Client` is; `scope` goes straight through
    /// to it. `now_s` is recorded as the last refresh, so a `NoSuchKey`
    /// straight after a scheduled one does not fetch again.
    pub fn refresh(self: *Keyring, scope: anytype, client: anytype, now_s: i64) !void {
        self.last_refresh_s.store(now_s, .release);
        const res = try client.get(scope, self.opts.url, .{});
        if (!res.ok()) return error.KeysNotAvailable;
        try self.load(res.body.view());
    }

    /// `jwt.verify` against the set the ring holds now, with the ring's
    /// issuer, audience and leeway. Strings in the result point into `gpa`.
    pub fn verify(self: *Keyring, comptime Claims: type, gpa: std.mem.Allocator, token: []const u8, now_s: i64) token_mod.Error!Claims {
        const set = self.pin();
        defer unpin(set);
        return token_mod.verify(Claims, gpa, token, .{
            .keys = &set.keys,
            .issuer = self.opts.issuer,
            .audience = self.opts.audience,
            .now_s = now_s,
            .leeway_s = self.opts.leeway_s,
            .memo = if (self.memo) |*m| m else null,
        });
    }

    /// `verify`, and on `NoSuchKey` — what a rotation looks like from here
    /// — a `refresh` at most once per `refresh_interval_s`, then `verify`
    /// again. A miss inside the interval is `NoSuchKey` as it was.
    pub fn verifyOrRefresh(
        self: *Keyring,
        comptime Claims: type,
        gpa: std.mem.Allocator,
        token: []const u8,
        now_s: i64,
        scope: anytype,
        client: anytype,
    ) !Claims {
        return self.verify(Claims, gpa, token, now_s) catch |err| switch (err) {
            error.NoSuchKey => {
                if (!self.claimRefresh(now_s)) return error.NoSuchKey;
                try self.refresh(scope, client, now_s);
                return self.verify(Claims, gpa, token, now_s);
            },
            else => |e| return e,
        };
    }

    /// Whether a refresh may run at `now_s`, and the slot taken if so: one
    /// winner per interval however many verifies saw the miss at once.
    fn claimRefresh(self: *Keyring, now_s: i64) bool {
        const last = self.last_refresh_s.load(.acquire);
        if (now_s -| last < self.opts.refresh_interval_s) return false;
        return self.last_refresh_s.cmpxchgStrong(last, now_s, .acq_rel, .acquire) == null;
    }

    /// The set to read, counted on. `crossing` is up while the pointer is
    /// loaded and not yet pinned, which is the window a swap has to see
    /// closed before it can trust the old set's count.
    fn pin(self: *Keyring) *Set {
        _ = self.crossing.fetchAdd(1, .seq_cst);
        const set = self.current.load(.seq_cst);
        _ = set.readers.fetchAdd(1, .acquire);
        _ = self.crossing.fetchSub(1, .seq_cst);
        return set;
    }

    fn unpin(set: *Set) void {
        _ = set.readers.fetchSub(1, .release);
    }
};

// ---- tests ----

const testing = std.testing;
const vector = @import("vector.zig");

const Sub = struct { sub: []const u8 };

/// What a keyring asks of a client: one `get` answering a status and a body.
/// A fake here, `fetch.Client` in a program, and the shape is the same one.
const FakeClient = struct {
    status: u16 = 200,
    body: []const u8,
    gets: usize = 0,
    last_url: []const u8 = "",

    const Body = struct {
        bytes: []const u8,
        fn view(self: Body) []const u8 {
            return self.bytes;
        }
    };
    const Answer = struct {
        status: u16,
        body: Body,
        fn ok(self: Answer) bool {
            return self.status >= 200 and self.status < 300;
        }
    };

    fn get(self: *FakeClient, scope: *u8, url: []const u8, call: struct {}) !Answer {
        _ = scope;
        _ = call;
        self.gets += 1;
        self.last_url = url;
        return .{ .status = self.status, .body = .{ .bytes = self.body } };
    }
};

const google: Keyring.Options = .{
    .url = "https://issuer.example/certs",
    .issuer = .{ .is = "https://accounts.example" },
    .audience = .{ .is = "client-1" },
};

test "an empty ring answers NoSuchKey, and a loaded document makes the key findable" {
    var ring: Keyring = try .init(testing.allocator, google);
    defer ring.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.NoSuchKey, ring.verify(Sub, arena.allocator(), vector.token, 1_500_000_000));
    try ring.load(vector.jwks);
    const claims = try ring.verify(Sub, arena.allocator(), vector.token, 1_500_000_000);
    try testing.expectEqualStrings("u-7", claims.sub);

    // A document that does not parse leaves the set as it was.
    try testing.expectError(error.NotAKeySet, ring.load("not json"));
    _ = try ring.verify(Sub, arena.allocator(), vector.token, 1_500_000_000);
}

test "a swap waits for the verify that pinned the old set, and frees it after" {
    var ring: Keyring = try .init(testing.allocator, google);
    defer ring.deinit();
    try ring.load(vector.jwks);

    // A verify in flight on another thread, held at the point where it has
    // the old set and is reading it.
    const old = ring.pin();
    const key = old.keys.find("test-key").?;
    try testing.expectEqualStrings("test-key", key.kid);

    const Swapper = struct {
        fn run(r: *Keyring, done: *std.atomic.Value(bool)) void {
            r.load("{\"keys\":[]}") catch unreachable;
            done.store(true, .release);
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Swapper.run, .{ &ring, &done });

    // The new set is published at once: a reader pinning now gets the
    // empty one. The swap itself is still waiting on the pin above.
    var spins: usize = 0;
    while (ring.current.load(.acquire) == old) : (spins += 1) {
        std.atomic.spinLoopHint();
        if (spins > 100_000_000) return error.TestUnexpectedResult;
    }
    for (0..1000) |_| std.Thread.yield() catch {};
    try testing.expect(!done.load(.acquire));
    // The old set is still whole while it is pinned.
    try testing.expectEqualStrings("test-key", old.keys.all[0].kid);

    Keyring.unpin(old);
    thread.join();
    try testing.expect(done.load(.acquire));
    try testing.expectEqual(@as(usize, 0), ring.current.load(.acquire).keys.all.len);
}

test "an unknown kid fetches at most once per interval, and the set that arrives is the one read" {
    var ring: Keyring = try .init(testing.allocator, google);
    defer ring.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var scope: u8 = 0;
    const base: i64 = 1_500_000_000;

    // The issuer has not published the key yet: the miss fetches once,
    // still misses, and the next miss inside the minute does not fetch.
    var client: FakeClient = .{ .body = "{\"keys\":[]}" };
    try testing.expectError(error.NoSuchKey, ring.verifyOrRefresh(Sub, arena.allocator(), vector.token, base, &scope, &client));
    try testing.expectEqual(@as(usize, 1), client.gets);
    try testing.expectEqualStrings("https://issuer.example/certs", client.last_url);
    try testing.expectError(error.NoSuchKey, ring.verifyOrRefresh(Sub, arena.allocator(), vector.token, base + 30, &scope, &client));
    try testing.expectEqual(@as(usize, 1), client.gets);

    // A minute on, the issuer has rotated: one fetch, and the token passes
    // in the same call.
    client.body = vector.jwks;
    const claims = try ring.verifyOrRefresh(Sub, arena.allocator(), vector.token, base + 60, &scope, &client);
    try testing.expectEqualStrings("u-7", claims.sub);
    try testing.expectEqual(@as(usize, 2), client.gets);

    // Found: no fetch at all.
    _ = try ring.verifyOrRefresh(Sub, arena.allocator(), vector.token, base + 1_000, &scope, &client);
    try testing.expectEqual(@as(usize, 2), client.gets);
}

test "a fetch the issuer refuses leaves the old set in place, and a scheduled refresh resets the interval" {
    var ring: Keyring = try .init(testing.allocator, google);
    defer ring.deinit();
    try ring.load(vector.jwks);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var scope: u8 = 0;

    var client: FakeClient = .{ .status = 503, .body = "down" };
    try testing.expectError(error.KeysNotAvailable, ring.refresh(&scope, &client, 5_000));
    _ = try ring.verify(Sub, arena.allocator(), vector.token, 1_500_000_000);

    // The refresh that just ran, even refused, is the last one: a miss ten
    // seconds later does not fetch again.
    var empty: Keyring = try .init(testing.allocator, google);
    defer empty.deinit();
    try testing.expectError(error.KeysNotAvailable, empty.refresh(&scope, &client, 5_000));
    try testing.expectEqual(@as(usize, 2), client.gets);
    try testing.expectError(error.NoSuchKey, empty.verifyOrRefresh(Sub, arena.allocator(), vector.token, 5_010, &scope, &client));
    try testing.expectEqual(@as(usize, 2), client.gets);
}

test "the ring's issuer and audience are what verify insists on" {
    var ring: Keyring = try .init(testing.allocator, .{
        .url = "https://issuer.example/certs",
        .issuer = .{ .is = "https://somebody.else" },
        .audience = .unchecked,
    });
    defer ring.deinit();
    try ring.load(vector.jwks);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.WrongIssuer, ring.verify(Sub, arena.allocator(), vector.token, 1_500_000_000));
}

test "a ring that remembers tokens skips the signature the second time, checks the claims every time, and forgets on a new set" {
    var opts = google;
    opts.remember_tokens = 8;
    var ring: Keyring = try .init(testing.allocator, opts);
    defer ring.deinit();
    try ring.load(vector.jwks);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    _ = try ring.verify(Sub, arena.allocator(), vector.token, 1_500_000_000);
    _ = try ring.verify(Sub, arena.allocator(), vector.token, 1_500_000_000);
    try testing.expectEqual(@as(u64, 1), ring.memo.?.hits.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), ring.memo.?.misses.load(.monotonic));

    // Remembered or not, an expired token is expired.
    try testing.expectError(error.Expired, ring.verify(Sub, arena.allocator(), vector.token, 2_000_000_001));

    // One byte of the signature changed is a different token, and it fails
    // the arithmetic rather than riding the memo.
    var forged = try testing.allocator.dupe(u8, vector.token);
    defer testing.allocator.free(forged);
    forged[forged.len - 1] = if (forged[forged.len - 1] == 'A') 'B' else 'A';
    try testing.expectError(error.BadSignature, ring.verify(Sub, arena.allocator(), forged, 1_500_000_000));

    // A new set forgets: the token has to prove itself under it again
    // (the forged one was a miss too, and was not remembered).
    try ring.load(vector.jwks);
    _ = try ring.verify(Sub, arena.allocator(), vector.token, 1_500_000_000);
    try testing.expectEqual(@as(u64, 3), ring.memo.?.misses.load(.monotonic));
}

test "a ring over a shared key set refuses a token minted for another application, unless it says .unchecked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The same keys, the same issuer; only the audience the ring was built
    // for differs, which is the whole of what tells two applications apart.
    var other: Keyring = try .init(testing.allocator, .{
        .url = "https://issuer.example/certs",
        .issuer = .{ .is = "https://accounts.example" },
        .audience = .{ .is = "client-2" },
    });
    defer other.deinit();
    try other.load(vector.jwks);
    try testing.expectError(error.WrongAudience, other.verify(Sub, arena.allocator(), vector.token, 1_500_000_000));

    var anyone: Keyring = try .init(testing.allocator, .{
        .url = "https://issuer.example/certs",
        .issuer = .{ .is = "https://accounts.example" },
        .audience = .unchecked,
    });
    defer anyone.deinit();
    try anyone.load(vector.jwks);
    const claims = try anyone.verify(Sub, arena.allocator(), vector.token, 1_500_000_000);
    try testing.expectEqualStrings("u-7", claims.sub);
}
