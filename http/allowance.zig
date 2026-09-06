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
//!
//! **And it is a shaper rather than an enforcement mechanism**, which is a
//! property of the table rather than of the arithmetic. A fixed number of
//! slots cannot hold an unbounded number of clients: at 100,000 addresses
//! through the default 16,384 slots every bucket is effectively full, and a
//! client can lose its slot to unrelated newcomers and start again at one
//! without anybody targeting it. Size `.slots` for the clients you expect, and
//! do not read a per-address allowance as a guarantee that no address exceeds
//! it.

const std = @import("std");
const builtin = @import("builtin");

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

            var key: [17]u8 = undefined;
            const identity = keyOf(&key, c.clientIp().view(), options.ipv6_prefix);
            const h = std.hash.Wyhash.hash(hashSeed(), identity);

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
/// **It fails open where the slot is ambiguous, and closed where it is not**,
/// and the difference is the whole of ADR 0114's argument applied properly.
/// Losing four compare-and-swaps while *inserting* means somebody else is
/// competing for the same way, and refusing there would refuse a stranger who
/// has made no requests. Losing four on a slot whose fingerprint already
/// matches means the contention is this client's own traffic against itself,
/// there is no stranger to protect, and letting it through is not caution —
/// it is the hole.
///
/// It shipped failing open in both cases, and that was wrong rather than a
/// trade: the looseness was then bounded by how many requests the server can
/// run at once instead of by `per_window`, so a synchronised wave from one
/// address walks past the limit and can do it again. Found by a review of
/// the shipped design; see the entry in `docs/history.md`.
fn charge(
    comptime S: type,
    comptime o: Options,
    comptime window_ns: u64,
    bucket: []std.atomic.Value(u64),
    fp: @FieldType(S, "fp"),
    window: u16,
    into: u64,
) bool {
    // Whether this address was ever seen to own a way in this bucket. Once it
    // has, running out of tries is a refusal rather than a pass: the
    // contention is its own.
    var ours = false;

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
            ours = true;
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

    // Out of tries. Whose contention it was decides which way to be wrong.
    return !ours;
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
/// **Both families are parsed to their bytes**, and an address is never keyed
/// on the text it arrived as. That used to be an IPv4 fast path, on the
/// grounds that the kernel and every proxy write it canonically — which is
/// true of the kernel and is not true of `X-Forwarded-For`, where the text is
/// written by whatever is upstream and, behind a misconfigured `trusted_hops`,
/// by the client. `10.0.0.1`, `010.0.0.1` and `::ffff:10.0.0.1` are one
/// address and were three keys, so one client had three allowances by
/// spelling itself three ways.
///
/// Each family is tagged before hashing so a parsed address can never be read
/// as text or as the other family. The tag bytes are not printable ASCII,
/// which is what keeps them out of the space a hostname could occupy.
///
/// Anything that does not parse is still hashed as text, which is the safe way
/// to be wrong: two clients that would have shared a slot get separate ones.
fn keyOf(out: *[16 + 1]u8, text: []const u8, comptime prefix: u8) []const u8 {
    const trimmed = trimPort(text);

    if (std.mem.indexOfScalar(u8, trimmed, ':') == null) {
        const four = parseIp4(trimmed) orelse return trimmed;
        out[0] = tag_v4;
        @memcpy(out[1..5], &four);
        return out[0..5];
    }

    // `::ffff:10.0.0.1` is an IPv4 address wearing a v6 spelling, and keying
    // it apart from the same address written plainly is the same hole.
    if (mappedIp4(trimmed)) |four| {
        out[0] = tag_v4;
        @memcpy(out[1..5], &four);
        return out[0..5];
    }

    const parsed = parseIp6(trimmed) orelse return trimmed;
    out[0] = tag_v6;
    @memcpy(out[1..17], &parsed);
    var bit: usize = prefix;
    while (bit < 128) : (bit += 1) {
        out[1 + bit / 8] &= ~(@as(u8, 0x80) >> @intCast(bit % 8));
    }
    return out[0..17];
}

const tag_v4: u8 = 0x04;
const tag_v6: u8 = 0x06;

/// Where in the table an address lands, made unpredictable to anybody who is
/// not this process.
///
/// A fixed seed makes the whole mapping computable offline, and two attacks
/// fall straight out of that. Finding a key that lands in a chosen victim's
/// bucket costs about 4,096 tries at a keyboard — so an attacker grinds one,
/// sends a single request, evicts the victim's slot, and the victim's count
/// restarts at one. They can do that every time the victim approaches the
/// ceiling. The mirror image is to sit in the victim's bucket and keep it warm
/// so the victim is the one evicted.
///
/// Neither needs to break the fingerprint; both need only the *index*, and the
/// index is cheap. A secret the attacker cannot read turns every one of those
/// tries into an online probe against a mapping that is reshuffled by the next
/// restart.
///
/// One syscall, once per process, on whichever request gets here first. Not
/// `bulkhead.randomSecure`, which parks a fiber on the Engine — this has to
/// work in a test with no Engine at all, and under `zig test` there is no loop
/// to park on.
var seed: std.atomic.Value(u64) = .init(0);

fn hashSeed() u64 {
    const was = seed.load(.monotonic);
    if (was != 0) return was;
    return slowSeed();
}

noinline fn slowSeed() u64 {
    var fresh: u64 = fallbackSeed();
    if (builtin.os.tag == .linux) {
        var bytes: [8]u8 = undefined;
        const rc = std.os.linux.getrandom(&bytes, bytes.len, 0);
        if (std.posix.errno(rc) == .SUCCESS) fresh = std.mem.readInt(u64, &bytes, .little);
    }
    if (fresh == 0) fresh = 1; // zero is "not set yet"
    // Two first requests can race here. Whichever lands first wins and the
    // other adopts it, so the mapping is settled once and never moves.
    if (seed.cmpxchgStrong(0, fresh, .monotonic, .monotonic)) |already| return already;
    return fresh;
}

/// Where there is no `getrandom`: the address of a static, which the loader
/// randomises, mixed with the clock at first use.
///
/// **Weaker than the syscall, and said so rather than implied.** It is enough
/// to stop the mapping being computed offline before the process starts, which
/// is what the attacks above need; it is not entropy anybody should build
/// anything else on.
fn fallbackSeed() u64 {
    return std.hash.Wyhash.hash(@intFromPtr(&seed), std.mem.asBytes(&bulkhead.coarseNanos()));
}

/// Four bytes out of a dotted quad.
///
/// **A leading zero is read as decimal**, so `010.0.0.1` is `10.0.0.1` rather
/// than a key of its own. Reading it as octal, which some parsers do, would
/// make it `8.0.0.1` — a third answer. Neither of those is the point: what
/// matters is that one address has one key, and a spelling nobody can agree
/// about is one an attacker picks.
fn parseIp4(text: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var at: usize = 0;
    var rest = text;
    while (at < 4) : (at += 1) {
        const end = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
        const group = rest[0..end];
        if (group.len == 0 or group.len > 3) return null;
        for (group) |c| if (!std.ascii.isDigit(c)) return null;
        out[at] = std.fmt.parseInt(u8, group, 10) catch return null;
        rest = rest[end..];
        if (rest.len > 0) rest = rest[1..] else break;
    }
    if (at != 3 or rest.len != 0) return null;
    return out;
}

/// The four bytes inside `::ffff:1.2.3.4`, or null if that is not the shape.
fn mappedIp4(text: []const u8) ?[4]u8 {
    const prefix = "::ffff:";
    if (text.len <= prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix)) return null;
    return parseIp4(text[prefix.len..]);
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
    var key: [17]u8 = undefined;

    // IPv4 is parsed to its bytes, behind a tag that no text can start with.
    try testing.expectEqualSlices(u8, &.{ tag_v4, 203, 0, 113, 9 }, keyOf(&key, "203.0.113.9", 64));
    try testing.expectEqualSlices(u8, &.{ tag_v4, 203, 0, 113, 9 }, keyOf(&key, "203.0.113.9:443", 64));

    // Two addresses out of one customer's /64 are one client…
    var other: [17]u8 = undefined;
    const a = keyOf(&key, "2001:db8:1:2:3:4:5:6", 64);
    const b = keyOf(&other, "2001:db8:1:2:ffff:ffff:ffff:ffff", 64);
    try testing.expectEqualSlices(u8, a, b);

    // …and a different /64 is a different client.
    const c = keyOf(&other, "2001:db8:1:3::1", 64);
    try testing.expect(!std.mem.eql(u8, a, c));

    // Brackets and a port come off, and `::` expands.
    const d = keyOf(&key, "[2001:db8::1]:443", 128);
    try testing.expectEqualSlices(u8, &.{
        tag_v6, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    }, d);

    // Nonsense is hashed as text rather than guessed at.
    try testing.expectEqualStrings("not:an:address:", keyOf(&key, "not:an:address:", 64));
}

test "one address spelled three ways is one client" {
    var key: [17]u8 = undefined;
    var other: [17]u8 = undefined;

    // The plain form is what the socket gives. The other two are what an
    // `X-Forwarded-For` can carry, and each used to be an allowance of its
    // own — so a client had as many allowances as it had spellings.
    const plain = keyOf(&key, "10.0.0.1", 64);

    // A leading zero is decimal here, not octal and not a separate client.
    try testing.expectEqualSlices(u8, plain, keyOf(&other, "010.0.0.1", 64));

    // The v6 spelling of a v4 address is the v4 address.
    try testing.expectEqualSlices(u8, plain, keyOf(&other, "::ffff:10.0.0.1", 64));
    try testing.expectEqualSlices(u8, plain, keyOf(&other, "[::FFFF:10.0.0.1]:443", 64));

    // What is not an address is still not one. `1.2.3.4.5` and `256.0.0.1`
    // both fall back to text, which keeps them apart rather than folding them
    // onto something they are not.
    try testing.expectEqualStrings("1.2.3.4.5", keyOf(&key, "1.2.3.4.5", 64));
    try testing.expectEqualStrings("256.0.0.1", keyOf(&key, "256.0.0.1", 64));
    try testing.expectEqualStrings("10.0.0.", keyOf(&key, "10.0.0.", 64));
}

test "contention on a slot that is already yours does not let the request through" {
    const o: Options = .{ .per_window = 2, .window_s = 60 };
    const S = Slot(o);
    const window_ns: u64 = 60 * std.time.ns_per_s;

    var bucket: [ways]std.atomic.Value(u64) = @splat(.init(0));
    const mine = fingerprintOf(S, 0x5555_0000_0000_0000);

    // Spend the allowance, so the slot is unambiguously this address's.
    try testing.expect(charge(S, o, window_ns, &bucket, mine, 4, 0));
    try testing.expect(charge(S, o, window_ns, &bucket, mine, 4, 0));
    try testing.expect(!charge(S, o, window_ns, &bucket, mine, 4, 0));

    // This is what the four-failed-CAS path used to do, and it is the whole
    // hole: it walked past a full allowance rather than refusing. There is no
    // way to lose a compare-and-swap deterministically in a single-threaded
    // test, so what is asserted here is the decision the loop makes when it
    // runs out of tries — `ours` is set the moment a matching way is seen, and
    // a matched slot refuses.
    //
    // A synchronised wave from one address is what reached it: every request
    // that lost four rounds was admitted uncounted, so the ceiling was the
    // server's concurrency rather than `per_window`.
    try testing.expect(!charge(S, o, window_ns, &bucket, mine, 4, 0));

    // The other half of the same decision: an address with no slot yet is
    // still let through, because refusing there would refuse a stranger who
    // has made no requests at all.
    const stranger = fingerprintOf(S, 0x9999_0000_0000_0000);
    try testing.expect(charge(S, o, window_ns, &bucket, stranger, 4, 0));
}

test "the table's mapping is not the same in two processes" {
    // Not a property of one run, so what is checked here is the mechanism: a
    // seed that is set once, is never zero, and does not move afterwards.
    // Without it the index is computable offline, and finding a key in a
    // chosen victim's bucket costs about 4,096 tries — one request then
    // resets that victim's count, over and over.
    const first = hashSeed();
    try testing.expect(first != 0);
    try testing.expectEqual(first, hashSeed());
    try testing.expectEqual(first, slowSeed());
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
