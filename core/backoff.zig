//! How long to wait before trying again, as a function of how many times it
//! has already been tried
//! ([ADR 271](../docs/adr/271-a-retry-is-the-callers-numbers-and-nilos-mechanism.md)).
//!
//! It lived in `nilo_job`, and `nilo_fetch` needs the same arithmetic for the
//! same reason: a service that is down fails everything at once, and a wait
//! that is the same for every caller sends every caller back at the same
//! instant. The two modules are siblings and may not import each other, so by
//! [ADR 057](../docs/adr/057-percent-is-needed-by-two-layers.md)'s test (a
//! file earns its place by being needed by two layers) it is here. It needs
//! no loop, names no Engine and allocates nothing, so `zig test core/core.zig`
//! runs it.
//!
//! **It is arithmetic and holds no randomness.** Jitter takes the random
//! number as an argument, the way `nilo_id` takes its entropy: a module below
//! the loop has no `Io` to ask, and the caller that has one (a worker, a
//! client) draws the bits from it with `std.Io.random`, which is a
//! per-executor generator and not a syscall.

const std = @import("std");

/// How much of a wait is replaced by chance. The three of AWS's "Exponential
/// Backoff And Jitter": the whole wait, a half of it, or none.
pub const Jitter = enum {
    /// The wait is exactly what the backoff says. A herd that failed
    /// together retries together; right for one caller and for a test.
    none,
    /// Anywhere from no wait to the whole of it, evenly. The best spread of
    /// a herd, and the only choice that can retry at once.
    full,
    /// Half the wait, and then anywhere in the other half. Spreads a herd
    /// while keeping every caller at least half as polite as the backoff
    /// asked.
    equal,
};

pub const Backoff = union(enum) {
    /// The same wait every time. A promise to somebody, so nothing random is
    /// added: to spread a fixed wait, say `.exponential` with the same
    /// `from_ms` and `to_ms`.
    fixed_ms: u32,
    /// Doubling from `from_ms`, and never past `to_ms`, with the jitter the
    /// caller chose. `.none` is the default so a backoff written before
    /// jitter existed waits what it always waited.
    exponential: struct { from_ms: u32, to_ms: u32, jitter: Jitter = .none },

    /// The wait after the attempt numbered `failed` (`1` for the first),
    /// before any jitter: the most it will be.
    pub fn ceilingMs(self: Backoff, failed: u32) u64 {
        return switch (self) {
            .fixed_ms => |ms| ms,
            .exponential => |e| blk: {
                var ms: u64 = e.from_ms;
                var i: u32 = 1;
                while (i < failed and ms < e.to_ms) : (i += 1) ms *= 2;
                break :blk @min(ms, e.to_ms);
            },
        };
    }

    /// The wait after the attempt numbered `failed`, with `random` (any 64
    /// bits) spent on the jitter. A backoff with none ignores it.
    pub fn delayMs(self: Backoff, failed: u32, random: u64) u64 {
        const top = self.ceilingMs(failed);
        const jitter: Jitter = switch (self) {
            .fixed_ms => .none,
            .exponential => |e| e.jitter,
        };
        return switch (jitter) {
            .none => top,
            .full => below(top + 1, random),
            .equal => top / 2 + below(top - top / 2 + 1, random),
        };
    }

    /// `random` scaled onto `0..n`, without a division and without the
    /// bias of `%` on a number that does not divide 2^64.
    fn below(n: u64, random: u64) u64 {
        return @intCast((@as(u128, random) * n) >> 64);
    }
};

const testing = std.testing;

test "exponential backoff doubles from the first wait and stops at the ceiling" {
    const b: Backoff = .{ .exponential = .{ .from_ms = 100, .to_ms = 1_000 } };
    try testing.expectEqual(@as(u64, 100), b.ceilingMs(1));
    try testing.expectEqual(@as(u64, 200), b.ceilingMs(2));
    try testing.expectEqual(@as(u64, 800), b.ceilingMs(4));
    try testing.expectEqual(@as(u64, 1_000), b.ceilingMs(5));
    try testing.expectEqual(@as(u64, 1_000), b.ceilingMs(400));
    // No jitter ignores the bits it is given.
    try testing.expectEqual(@as(u64, 400), b.delayMs(3, 0));
    try testing.expectEqual(@as(u64, 400), b.delayMs(3, std.math.maxInt(u64)));
}

test "a fixed wait is the same every time, whatever the bits" {
    const b: Backoff = .{ .fixed_ms = 50 };
    try testing.expectEqual(@as(u64, 50), b.delayMs(1, 12345));
    try testing.expectEqual(@as(u64, 50), b.delayMs(9, std.math.maxInt(u64)));
}

test "full jitter spans none to the whole wait and equal jitter spans the top half" {
    const full: Backoff = .{ .exponential = .{ .from_ms = 100, .to_ms = 100, .jitter = .full } };
    const equal: Backoff = .{ .exponential = .{ .from_ms = 100, .to_ms = 100, .jitter = .equal } };
    // The two ends of the bits are the two ends of the range.
    try testing.expectEqual(@as(u64, 0), full.delayMs(1, 0));
    try testing.expectEqual(@as(u64, 100), full.delayMs(1, std.math.maxInt(u64)));
    try testing.expectEqual(@as(u64, 50), equal.delayMs(1, 0));
    try testing.expectEqual(@as(u64, 100), equal.delayMs(1, std.math.maxInt(u64)));
    // And nothing in between leaves it, over a spread of bits.
    var prng: std.Random.DefaultPrng = .init(7);
    const rnd = prng.random();
    var seen_low = false;
    var seen_high = false;
    for (0..2_000) |_| {
        const f = full.delayMs(1, rnd.int(u64));
        const e = equal.delayMs(1, rnd.int(u64));
        try testing.expect(f <= 100);
        try testing.expect(e >= 50 and e <= 100);
        if (f < 20) seen_low = true;
        if (f > 80) seen_high = true;
    }
    try testing.expect(seen_low and seen_high);
}

test "jitter of a zero wait is zero, and the top of the ceiling never overflows" {
    const none: Backoff = .{ .exponential = .{ .from_ms = 0, .to_ms = 0, .jitter = .full } };
    try testing.expectEqual(@as(u64, 0), none.delayMs(3, std.math.maxInt(u64)));
    const huge: Backoff = .{ .exponential = .{ .from_ms = std.math.maxInt(u32), .to_ms = std.math.maxInt(u32), .jitter = .equal } };
    try testing.expect(huge.delayMs(100, std.math.maxInt(u64)) <= std.math.maxInt(u32));
}
