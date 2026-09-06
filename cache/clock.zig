//! Seconds since the Store opened, and **the coarse clock on purpose**.
//!
//! A tool module imports nothing, so this is `core/clock.zig`'s syscall
//! written a second time rather than shared — the duplication ADR 0043
//! accepted when it decided a module in this layer may not name `nilo_core`.
//! Reaching for one would cost `zig test cache/cache.zig`, which is the
//! property that decides the layer.
//!
//! **`MONOTONIC_COARSE` rather than `MONOTONIC`, and the difference is not
//! rounding.** The precise clock is a vDSO call at ~27ns; the coarse one
//! reads a page the kernel updates on its own tick, at ~5ns. On an operation
//! whose whole cost is around a hundred nanoseconds, that is a fifth of it —
//! and what is bought with the 22ns is accuracy a TTL measured in *seconds*
//! has no use for. The tick is a millisecond or four. A cache entry set to
//! live 300 seconds does not care which side of 300.0000 it expires on, and
//! a design that pays a fifth of its budget for that is paying for the wrong
//! thing.
//!
//! Monotonic rather than wall clock, for the reason `core/clock.zig` gives:
//! NTP steps the wall clock, and an operator running `timedatectl` should not
//! expire every entry in the cache or none of them.

const std = @import("std");
const builtin = @import("builtin");

/// Seconds off a clock that only goes forwards. The number means nothing on
/// its own; two of them subtracted mean exactly one thing.
pub fn monotonicSeconds() i64 {
    if (builtin.os.tag == .windows) @compileError(
        "nilo: nilo_cache cannot read a clock on Windows.\n" ++
            "  An entry's expiry is the one thing in this module that needs an" ++
            " operating system, and Windows is not a platform nilo's Engine" ++
            " supports either (ADR 0045).",
    );

    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC_COARSE, &ts))) {
        .SUCCESS => {},
        // A valid pointer at a clock the kernel maintains has no failure
        // POSIX admits to, so this is a broken kernel rather than a
        // condition. Returning an error would put a `try` on `get` forever to
        // handle something that cannot happen.
        else => |e| std.debug.panic("nilo: the monotonic clock could not be read ({s})", .{@tagName(e)}),
    }
    return @intCast(ts.sec);
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

test "the coarse clock goes forwards and does not jump" {
    const a = monotonicSeconds();
    const b = monotonicSeconds();
    try testing.expect(b >= a);
    // Two reads in a row are the same second on any machine this runs on. If
    // this ever fails the clock is not coarse, which is the thing the file
    // is named for.
    try testing.expect(b - a <= 1);
}
