//! An Allowance: how many requests one address may make inside a window, and
//! the fixed table that remembers who has used what (ADR 0114).
//!
//! ```zig
//! try app.useOn("/api", allowance.with(.{ .per_window = 100, .window_s = 60 }));
//! ```
//!
//! **The shape is decided by the budget rather than by the algorithm.** Every
//! other framework keys a map by the client's address, which is a hash and an
//! allocation on the path of every request it guards — and one allocation per
//! request is the invariant this project treats as fixed
//! ([ADR 0018](../docs/adr/0018-the-trade-budget-has-three-axes.md)). So this
//! is a table sized while compiling, living in `.bss`, indexed by a hash of
//! the address: **no allocation at startup either**, nothing per connection,
//! and one 64-byte cache line touched per request.
//!
//! A slot is one `u64`, so taking a slot over and counting a request against
//! it are the same compare-and-swap. Four of them share a bucket, each
//! carrying a fingerprint of the address it belongs to, and a bucket with no
//! room forgets its stalest way rather than making two addresses share one
//! allowance — "your neighbour used your allowance" is a worse failure than
//! letting somebody through, and this design chose which direction to be
//! wrong in.
//!
//! **What it is not.** It is not a defence against a flood: a refused request
//! is still a read, a parse, a route match and a write, and a stranger with
//! ten thousand sockets still closes the door through `max_connections`, which
//! counts per process rather than per address. What it is for is the client
//! that asks too often — a scraper, a script in a loop, somebody's retry
//! storm, a password form being walked through a word list.

const std = @import("std");

const bulkhead = @import("bulkhead.zig");
const Ctx = @import("ctx.zig").Ctx;
const fail = @import("fail.zig");
const mw = @import("middleware.zig");

/// How many ways share a bucket. Four `u64`s is 32 bytes, so a bucket and its
/// neighbour fit in one 64-byte line and a lookup never touches two.
const ways = 4;

pub const Options = struct {
    /// How many requests one address may make inside `window_s`.
    per_window: u16 = 100,
    /// How long the window is, in seconds. Also what `Retry-After` says.
    window_s: u16 = 60,
    /// How many addresses this table remembers at once. A power of two.
    ///
    /// Eight bytes each, in `.bss`: 16,384 slots is 131,072 bytes, once, for
    /// the whole process. Nothing is allocated, at startup or ever, so this is
    /// a number an operator can multiply rather than a limit that surprises.
    slots: u32 = 16 * 1024,
    /// How much of an IPv6 address counts as one client.
    ///
    /// A /128 is not a customer — it is one of the 2^64 addresses a customer
    /// was handed, and a limit keyed on the whole thing is no limit at all. An
    /// IPv4 address is always taken whole.
    ipv6_prefix: u8 = 64,
    /// Tells this allowance apart from another with the same numbers.
    ///
    /// Two `with()` calls carrying identical options are **one table**,
    /// because Zig settles a generic once — which is usually what you want and
    /// is wrong when a sign-in route and a search route are meant to be
    /// counted apart. Give one of them a name.
    name: []const u8 = "",
};

/// The middleware. Everything about it is settled while compiling, so a route
/// it does not guard pays nothing at all and a program that never calls this
/// links none of it.
pub fn with(comptime options: Options) mw.Middleware {
    comptime check(options);

    const S = Slot(options);
    const buckets = options.slots / ways;
    const window_ns: u64 = @as(u64, options.window_s) * std.time.ns_per_s;
    const retry_after = std.fmt.comptimePrint("{d}", .{options.window_s});
    const refusal = std.fmt.comptimePrint(
        "too many requests: this address may make {d} every {d} seconds",
        .{ options.per_window, options.window_s },
    );

    return struct {
        /// `.bss`, sized while compiling. One table per distinct `Options` in
        /// the program, and none at all in a program that never calls `with`.
        var table: [options.slots]std.atomic.Value(u64) align(64) = @splat(.init(0));
        /// Whether the misconfiguration below has already been explained.
        var said: std.atomic.Value(bool) = .init(false);

        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            const now = bulkhead.coarseNanos();
            const window: u16 = @truncate(now / window_ns);
            const into = now % window_ns;

            var key: [16]u8 = undefined;
            const identity = keyOf(&key, c.clientIp().view(), options.ipv6_prefix);
            const h = std.hash.Wyhash.hash(0, identity);

            const at = (h % buckets) * ways;
            if (charge(S, options, window_ns, table[at..][0..ways], fingerprintOf(S, h), window, into)) {
                return next.run(c);
            }

            // Before the failure on purpose: `sendFailure` writes the headers
            // set on the Ctx, and this one is a compile-time constant, so
            // there is nothing here to dangle once this frame is gone.
            try c.setStaticHeader("Retry-After", retry_after);
            sayIfEverybodyLooksTheSame(c);
            return fail.tooManyRequests(refusal, .{});
        }

        /// The mistake this feature is most likely to be deployed with, said
        /// once, from the only place that can tell: a refusal.
        ///
        /// Behind a proxy with `trusted_hops` left at zero, every request
        /// appears to come from the proxy, the whole table collapses onto one
        /// slot, and the first busy second locks out the world. Nothing at
        /// `listen()` can know whether a proxy is there — but a request that
        /// carried an `X-Forwarded-For` and still counted as the socket's own
        /// address is the fact itself rather than a guess at the option.
        ///
        /// It costs the accepted path nothing: this is only ever reached on a
        /// 429.
        ///
        /// `noinline` for the reason `warnSocketFailed` is
        /// ([ADR 0071](../docs/adr/0071-where-a-connection-waits-is-what-it-costs.md)):
        /// inlined, `std.log.warn`'s format machinery would sit on the frame
        /// of every guarded request, and a suspended fiber holds its stack at
        /// its high-water mark for the life of the connection.
        noinline fn sayIfEverybodyLooksTheSame(c: *Ctx) void {
            if (said.load(.monotonic)) return;
            if (c.header("X-Forwarded-For") == null) return;
            // Bound to a local: `address()` returns a slice into the Peer, so
            // reading it off a temporary would hand out bytes that are gone
            // by the end of the expression.
            const peer = c.peer();
            if (!std.mem.eql(u8, c.clientIp().view(), peer.address())) return;
            if (said.swap(true, .monotonic)) return;
            std.log.warn(
                "an allowance refused {s}, which is the address the connection came from, " ++
                    "and the request carried an X-Forwarded-For. If a proxy stands in front " ++
                    "of this server then every request looks like it came from the proxy and " ++
                    "the whole table is one slot: set `.trusted_hops` on listen() to the " ++
                    "number of proxies you run.",
                .{peer.address()},
            );
        }
    }.run;
}

/// One address's state, in one word.
///
/// Two counters rather than one, which is a sliding window: a fixed one lets
/// twice the ceiling through across a boundary, and a burst is precisely what
/// this is against. It costs no memory at all — both counters, the window and
/// the fingerprint fit in the same 64 bits — and about fifteen lines of
/// arithmetic.
fn Slot(comptime o: Options) type {
    const count_bits = std.math.log2_int_ceil(u32, @as(u32, o.per_window) + 1);
    const fp_bits = 64 - 2 * @as(u16, count_bits) - 16;
    return packed struct(u64) {
        /// Requests counted in `window`.
        cur: std.meta.Int(.unsigned, count_bits),
        /// Requests counted in the window before it, weighted by how far into
        /// this one we are.
        prev: std.meta.Int(.unsigned, count_bits),
        /// Which window `cur` counts, modulo 2^16. Wraps every 65,536 windows
        /// — 45 days at sixty seconds — and the eviction pass reads age as a
        /// wrapping subtraction, so what a wrap costs is one client returning
        /// inside a two-window band after that long.
        window: u16,
        /// Whose slot this is. Zero means empty, which is what `.bss` starts
        /// as.
        fp: std.meta.Int(.unsigned, fp_bits),
    };
}

fn fingerprintOf(comptime S: type, h: u64) @FieldType(S, "fp") {
    const bits = @bitSizeOf(@FieldType(S, "fp"));
    const cut: @FieldType(S, "fp") = @truncate(h >> (64 - bits));
    // Zero is "empty", so an address whose fingerprint is zero borrows one.
    return if (cut == 0) 1 else cut;
}

/// Count one request against `bucket`, and say whether it is allowed.
///
/// Pass one looks for this address. Pass two takes the way whose window is
/// oldest, which is the eviction that keeps two addresses from sharing one
/// allowance.
///
/// **It fails open.** A bucket under enough contention to lose four
/// compare-and-swaps in a row lets the request through, because the
/// alternative — refusing on contention — turns a busy moment into an outage
/// for whoever happened to arrive during it.
fn charge(
    comptime S: type,
    comptime o: Options,
    comptime window_ns: u64,
    bucket: []std.atomic.Value(u64),
    fp: @FieldType(S, "fp"),
    window: u16,
    into: u64,
) bool {
    var tries: u8 = 0;
    while (tries < 4) : (tries += 1) {
        var oldest: usize = 0;
        var oldest_age: u16 = 0;
        var found: ?usize = null;

        for (bucket, 0..) |*cell, i| {
            const was: S = @bitCast(cell.load(.monotonic));
            if (was.fp == fp) {
                found = i;
                break;
            }
            const age = window -% was.window;
            if (was.fp == 0) {
                oldest = i;
                oldest_age = std.math.maxInt(u16);
            } else if (age > oldest_age) {
                oldest = i;
                oldest_age = age;
            }
        }

        if (found) |i| {
            const cell = &bucket[i];
            const was: S = @bitCast(cell.load(.monotonic));
            if (was.fp != fp) continue; // taken over between the two loads
            switch (take(S, o, window_ns, cell, was, window, into)) {
                .allowed => return true,
                .refused => return false,
                .again => continue,
            }
        }

        const cell = &bucket[oldest];
        const was: S = @bitCast(cell.load(.monotonic));
        if (was.fp == fp) continue; // somebody put us here; look again
        const fresh: S = .{ .fp = fp, .window = window, .cur = 1, .prev = 0 };
        if (cell.cmpxchgWeak(@bitCast(was), @bitCast(fresh), .monotonic, .monotonic) == null) {
            return true;
        }
    }
    return true;
}

const Outcome = enum { allowed, refused, again };

/// The arithmetic: roll the window forward, weigh what the previous one still
/// counts for, and take one if there is room.
fn take(
    comptime S: type,
    comptime o: Options,
    comptime window_ns: u64,
    cell: *std.atomic.Value(u64),
    was: S,
    window: u16,
    into: u64,
) Outcome {
    const age = window -% was.window;
    var cur: u32 = if (age == 0) was.cur else 0;
    const prev: u32 = if (age == 0) was.prev else if (age == 1) was.cur else 0;

    // How much of the previous window still counts: all of it at the boundary,
    // none of it a whole window later.
    const carried = (@as(u64, prev) * (window_ns - into)) / window_ns;
    if (carried + cur >= o.per_window) return .refused;

    cur += 1;
    const fresh: S = .{
        .fp = was.fp,
        .window = window,
        .cur = @intCast(cur),
        .prev = @intCast(prev),
    };
    if (cell.cmpxchgWeak(@bitCast(was), @bitCast(fresh), .monotonic, .monotonic) == null) {
        return .allowed;
    }
    return .again;
}

/// The bytes that identify a client, out of the text an address arrived as.
///
/// **An IPv4 address is its own text.** The kernel and every proxy write it
/// canonically, so there is nothing to parse and nothing to normalise — the
/// fast path hashes the bytes it was handed. Only an IPv6 text is parsed, and
/// only so that the prefix can be masked off.
///
/// Anything that does not parse is hashed as text, which is the safe way to be
/// wrong: two clients that would have shared a slot get separate ones.
fn keyOf(out: *[16]u8, text: []const u8, comptime prefix: u8) []const u8 {
    const trimmed = trimPort(text);
    if (std.mem.indexOfScalar(u8, trimmed, ':') == null) return trimmed;
    const parsed = parseIp6(trimmed) orelse return trimmed;

    out.* = parsed;
    var bit: usize = prefix;
    while (bit < 128) : (bit += 1) {
        out[bit / 8] &= ~(@as(u8, 0x80) >> @intCast(bit % 8));
    }
    return out[0..16];
}

/// `[2001:db8::1]:443` → `2001:db8::1`, and `10.0.0.1:80` → `10.0.0.1`. An
/// `X-Forwarded-For` entry may carry either shape.
fn trimPort(text: []const u8) []const u8 {
    if (text.len > 0 and text[0] == '[') {
        const close = std.mem.indexOfScalar(u8, text, ']') orelse return text;
        return text[1..close];
    }
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return text;
    // One colon is a port on an IPv4 address; several make it IPv6, where a
    // bare port cannot be told from the address without brackets.
    if (std.mem.indexOfScalarPos(u8, text, colon + 1, ':') == null) return text[0..colon];
    return text;
}

/// Sixteen bytes out of an IPv6 text, or null if it is not one.
///
/// Written here rather than taken from `std.net`, which wants an allocator's
/// worth of machinery and a socket family for a job that is eight groups and
/// one `::`. An IPv4-mapped tail (`::ffff:1.2.3.4`) is not read, and falls
/// back to hashing the text.
fn parseIp6(text: []const u8) ?[16]u8 {
    var out: [16]u8 = @splat(0);
    var at: usize = 0;
    var gap: ?usize = null;

    var rest = text;
    if (std.mem.startsWith(u8, rest, "::")) {
        gap = 0;
        rest = rest[2..];
    }

    while (rest.len > 0) {
        if (at >= 16) return null;
        if (rest[0] == ':') {
            if (gap != null) return null; // two `::` is not an address
            gap = at;
            rest = rest[1..];
            if (rest.len == 0) break;
            if (rest[0] == ':') return null;
            continue;
        }

        const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
        const group = rest[0..end];
        if (group.len == 0 or group.len > 4) return null;
        const value = std.fmt.parseInt(u16, group, 16) catch return null;
        out[at] = @intCast(value >> 8);
        out[at + 1] = @truncate(value);
        at += 2;
        rest = rest[end..];
        if (rest.len > 0) rest = rest[1..];
    }

    if (gap) |g| {
        if (at == 16) return null; // a `::` standing for nothing
        const tail = at - g;
        var i: usize = 0;
        while (i < tail) : (i += 1) out[16 - tail + i] = out[g + i];
        @memset(out[g .. 16 - tail], 0);
    } else if (at != 16) return null;

    return out;
}

/// Four things that cannot be right, said while compiling.
fn check(comptime o: Options) void {
    comptime {
        if (o.per_window == 0) @compileError(
            "nilo: an allowance of 0 requests is not a limit, it is a closed door.\n" ++
                "  A route nobody may reach is one that answers 403, or one that is not " ++
                "registered.",
        );
        if (o.per_window > 1023) @compileError(
            "nilo: an allowance above 1023 requests a window leaves too few bits for the " ++
                "fingerprint that tells two addresses apart.\n  Widen the window instead: " ++
                "`.per_window = 600, .window_s = 60` and `.per_window = 100, .window_s = 10` " ++
                "are the same rate.",
        );
        if (o.window_s == 0) @compileError(
            "nilo: an allowance needs a window to count inside — `.window_s = 60`.",
        );
        if (o.slots < 64 or (o.slots & (o.slots - 1)) != 0) @compileError(
            "nilo: an allowance's `.slots` is a power of two, and at least 64, because the " ++
                "table is indexed by a hash and shared four ways to a bucket.\n  " ++
                std.fmt.comptimePrint("Got {d}.", .{o.slots}),
        );
        if (o.ipv6_prefix > 128) @compileError(
            "nilo: an IPv6 address is 128 bits, so `.ipv6_prefix` cannot ask for more than " ++
                "128 of them.\n  The default of 64 is one customer's allocation; 128 counts " ++
                "each address on its own.",
        );
    }
}

// ---- tests ----

const testing = std.testing;
const App = @import("app.zig").App;
const test_client = @import("testing.zig");

test "the table's arithmetic: a window that slides rather than resetting" {
    const o: Options = .{ .per_window = 4, .window_s = 60 };
    const S = Slot(o);
    const window_ns: u64 = 60 * std.time.ns_per_s;

    var bucket: [ways]std.atomic.Value(u64) = @splat(.init(0));
    const fp = fingerprintOf(S, 0x1234_5678_9abc_def0);

    // Four through, the fifth refused.
    for (0..4) |_| try testing.expect(charge(S, o, window_ns, &bucket, fp, 7, 0));
    try testing.expect(!charge(S, o, window_ns, &bucket, fp, 7, 0));

    // The next window starts, and at its first instant the previous one still
    // counts for all of it — which is the whole point of a sliding window. A
    // fixed one would have let four more straight through here.
    try testing.expect(!charge(S, o, window_ns, &bucket, fp, 8, 0));

    // Halfway in, half of the previous window's four still counts, so two
    // more fit and the third does not.
    const half = window_ns / 2;
    try testing.expect(charge(S, o, window_ns, &bucket, fp, 8, half));
    try testing.expect(charge(S, o, window_ns, &bucket, fp, 8, half));
    try testing.expect(!charge(S, o, window_ns, &bucket, fp, 8, half));

    // A whole window later nothing is carried and the allowance is whole.
    for (0..4) |_| try testing.expect(charge(S, o, window_ns, &bucket, fp, 12, 0));
    try testing.expect(!charge(S, o, window_ns, &bucket, fp, 12, 0));
}

test "a full bucket forgets its stalest way rather than sharing an allowance" {
    const o: Options = .{ .per_window = 2, .window_s = 60 };
    const S = Slot(o);
    const window_ns: u64 = 60 * std.time.ns_per_s;

    var bucket: [ways]std.atomic.Value(u64) = @splat(.init(0));

    // Four addresses fill the bucket, each spending its whole allowance.
    var fps: [ways]@FieldType(S, "fp") = undefined;
    for (0..ways) |i| {
        fps[i] = fingerprintOf(S, @as(u64, @intCast(i + 1)) << 40);
        try testing.expect(charge(S, o, window_ns, &bucket, fps[i], 3, 0));
        try testing.expect(charge(S, o, window_ns, &bucket, fps[i], 3, 0));
        try testing.expect(!charge(S, o, window_ns, &bucket, fps[i], 3, 0));
    }

    // A fifth arrives in a later window. Somebody is evicted — and what the
    // fifth gets is its own allowance, not a share of somebody else's.
    const newcomer = fingerprintOf(S, 0xaaaa_0000_0000_0000);
    try testing.expect(charge(S, o, window_ns, &bucket, newcomer, 9, 0));
    try testing.expect(charge(S, o, window_ns, &bucket, newcomer, 9, 0));
    try testing.expect(!charge(S, o, window_ns, &bucket, newcomer, 9, 0));
}

test "an address is the key, and an IPv6 client is a prefix rather than one number" {
    var key: [16]u8 = undefined;

    // IPv4 is its own text: nothing is parsed, and nothing is normalised.
    try testing.expectEqualStrings("203.0.113.9", keyOf(&key, "203.0.113.9", 64));
    try testing.expectEqualStrings("203.0.113.9", keyOf(&key, "203.0.113.9:443", 64));

    // Two addresses out of one customer's /64 are one client…
    var other: [16]u8 = undefined;
    const a = keyOf(&key, "2001:db8:1:2:3:4:5:6", 64);
    const b = keyOf(&other, "2001:db8:1:2:ffff:ffff:ffff:ffff", 64);
    try testing.expectEqualSlices(u8, a, b);

    // …and a different /64 is a different client.
    const c = keyOf(&other, "2001:db8:1:3::1", 64);
    try testing.expect(!std.mem.eql(u8, a, c));

    // Brackets and a port come off, and `::` expands.
    const d = keyOf(&key, "[2001:db8::1]:443", 128);
    try testing.expectEqualSlices(u8, &.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, d);

    // Nonsense is hashed as text rather than guessed at.
    try testing.expectEqualStrings("not:an:address:", keyOf(&key, "not:an:address:", 64));
}

fn allowanceOk(_: *Ctx) anyerror!void {}

test "a client past its allowance is refused, and the next client is not" {
    const previous = testing.log_level;
    defer testing.log_level = previous;
    testing.log_level = .err;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(with(.{ .per_window = 3, .window_s = 60, .name = "test-basic" }));
    try app.get("/thing", allowanceOk);

    var client = try test_client.Client.init(testing.allocator, .{ .client_address = "203.0.113.7" });
    defer client.deinit();

    for (0..3) |_| {
        const answer = try client.get(&app, "/thing");
        try testing.expectEqual(@as(u16, 200), answer.status);
    }

    const refused = try client.get(&app, "/thing");
    try testing.expectEqual(@as(u16, 429), refused.status);
    try testing.expectEqualStrings("60", refused.header("Retry-After").?);
    try testing.expect(std.mem.indexOf(u8, refused.body, "too many requests") != null);

    // Somebody else's allowance is their own.
    var neighbour = try test_client.Client.init(testing.allocator, .{ .client_address = "198.51.100.4" });
    defer neighbour.deinit();
    try testing.expectEqual(@as(u16, 200), (try neighbour.get(&app, "/thing")).status);
}

test "a route the allowance does not cover is not counted" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.useOn("/api", with(.{ .per_window = 1, .window_s = 60, .name = "test-scoped" }));
    try app.get("/api/thing", allowanceOk);
    try app.get("/health", allowanceOk);

    var client = try test_client.Client.init(testing.allocator, .{ .client_address = "203.0.113.8" });
    defer client.deinit();

    try testing.expectEqual(@as(u16, 200), (try client.get(&app, "/api/thing")).status);
    try testing.expectEqual(@as(u16, 429), (try client.get(&app, "/api/thing")).status);

    // The prefix is what it guards, so this is untouched however many times
    // it is asked.
    for (0..5) |_| {
        try testing.expectEqual(@as(u16, 200), (try client.get(&app, "/health")).status);
    }
}
