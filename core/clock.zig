//! What time it is, in the layer that has no event loop (ADR 0045).
//!
//! Two layers wanted this and neither could have it. A handler had no way to
//! ask, so `id.v7` took a millisecond a caller could not produce; `nilo_sql`
//! had `Timestamp` and no `Timestamp.now()`, so a service filling `created_at`
//! wrote the column by hand or left it to a database default. Being wanted by
//! two layers is the rule for living here (ADR 0041), and this clears it.
//!
//! **A free function rather than a call on a Scope**, which is the whole
//! shape of the decision. `arena()` and `str()` are on a Scope because
//! something has to *own* what they hand out; nobody owns the time. There is
//! no permission to ask for, no lifetime to carry, and nothing to release —
//! so there is nothing for a Scope to be the holder of.
//!
//! **Reading it needs no event loop**, which is what makes it Core's rather
//! than the Bulkhead's. `clock_gettime` on a modern kernel is a read from a
//! page the kernel keeps mapped — no context switch, nothing to wait for, so
//! nothing for a fiber to be parked on. `http/bulkhead.zig` reads the
//! monotonic clock exactly this way and for exactly this reason. That does
//! amend ADR 0041's *no IO at all* to **needs no event loop**, which was the
//! question the layering has always actually been asking.
//!
//! What is *not* here is arithmetic, for the reason `sql/types.zig` gives at
//! length: a zone is a history rather than an offset, and the expensive half
//! of a date library has nothing to do with knowing what time it is.

const std = @import("std");
const builtin = @import("builtin");

/// Microseconds since 1970-01-01 UTC.
///
/// The unit is the one Postgres keeps a `timestamptz` in, so `sql.Timestamp`
/// is a copy rather than a conversion — and it is in the name because
/// `created_at: i64` not saying whether it counts seconds or microseconds is
/// the mistake `sql/types.zig` was written to stop.
///
/// Measured on this machine, `ReleaseFast`, best of five runs of five
/// million: **15ns**, and the same 15ns in a build that does not link libc.
/// `std.os.linux` reaches the vDSO on Zig 0.16, so there is no syscall on
/// either path — which is the fact the layer argument above rests on, and it
/// was checked rather than assumed (`bulkhead.coarseNanos` records a gap here
/// that no longer exists; its comment is corrected).
///
/// **`CLOCK_REALTIME_COARSE` was measured and not taken.** It is 2ns instead
/// of 15, and it moves once a millisecond — so it would make this function's
/// name a lie while `nowMillis` below would be entirely happy with it. The
/// 13ns buys a branch, a Linux-only path and two clocks to explain, for a
/// call nothing in the framework makes per request; it is the caller's own,
/// made once or twice. If one ever turns up who reads the clock in a loop,
/// this is the note that says where the 13ns went.
pub fn nowMicros() i64 {
    if (builtin.os.tag == .windows) @compileError(
        "nilo: nilo_core cannot read the wall clock on Windows.\n" ++
            "  The rest of this module works there; this call is the one thing that" ++
            " needs an operating system, and Windows is not a platform nilo's Engine" ++
            " supports either (ADR 0045).",
    );

    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
        .SUCCESS => {},
        // `CLOCK_REALTIME` with a valid pointer has no failure POSIX admits
        // to, so this is a broken kernel rather than a condition. Returning
        // an error would put a `try` on every call site forever to handle
        // something that cannot happen, and returning the epoch would be a
        // plausible wrong time — the one answer worse than stopping.
        else => |e| std.debug.panic("nilo: the system clock could not be read ({s})", .{@tagName(e)}),
    }

    return @as(i64, @intCast(ts.sec)) * std.time.us_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_us);
}

/// Milliseconds since 1970-01-01 UTC — the unit a UUID v7 puts in its first
/// six bytes, and the one a log line wants.
pub fn nowMillis() i64 {
    return @divFloor(nowMicros(), std.time.us_per_ms);
}

/// Microseconds since an arbitrary point, for measuring **how long something
/// took**. The number means nothing on its own; two of them subtracted mean
/// exactly one thing.
///
/// A second clock rather than a second use of `nowMicros`, because the wall
/// clock is allowed to move: NTP steps it, an operator sets it, and a
/// `timedatectl` in the middle of a query would otherwise be reported as a
/// query that took an hour or as one that finished before it started. The
/// duration a watcher is shown is a fact about the database
/// ([ADR 0137](../docs/adr/0137-a-statement-can-be-watched.md)), so it is
/// taken from the clock that only goes forwards.
///
/// Same cost as `nowMicros` and by the same route — `CLOCK_MONOTONIC` is in
/// the same vDSO page — which is what keeps this Core's rather than the
/// Bulkhead's. `http/bulkhead.zig` reads the same clock for the same reason
/// and cannot import this file; that duplication is the layering, not an
/// oversight.
pub fn monotonicMicros() i64 {
    if (builtin.os.tag == .windows) @compileError(
        "nilo: nilo_core cannot read the monotonic clock on Windows.\n" ++
            "  The rest of this module works there; this call is one of the two that" ++
            " need an operating system, and Windows is not a platform nilo's Engine" ++
            " supports either (ADR 0045).",
    );

    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
        .SUCCESS => {},
        // The same argument `nowMicros` makes: a valid pointer at a clock
        // POSIX requires leaves no failure to handle, so this is a broken
        // kernel rather than a condition.
        else => |e| std.debug.panic("nilo: the monotonic clock could not be read ({s})", .{@tagName(e)}),
    }

    return @as(i64, @intCast(ts.sec)) * std.time.us_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_us);
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

/// 2026-01-01, in microseconds. Any clock reading below this is either a
/// machine set wrong or, far likelier, this file counting the wrong unit.
const written_after = 1_767_225_600_000_000;

/// 2100-01-01, likewise, for the other direction: nanoseconds would land
/// a thousand times past it.
const before_long = 4_102_444_800_000_000;

test "the clock counts microseconds, and says so by being in range" {
    const now = nowMicros();
    try testing.expect(now > written_after);
    try testing.expect(now < before_long);
}

test "milliseconds are the same moment, a thousand at a time" {
    const micros = nowMicros();
    const millis = nowMillis();
    // Read one after the other, so they may straddle a millisecond. What
    // is being checked is the unit, not the instant.
    try testing.expect(@abs(millis - @divFloor(micros, std.time.us_per_ms)) <= 1);
}

test "the monotonic clock measures a duration, and only that" {
    const first = monotonicMicros();
    const second = monotonicMicros();
    // Forwards, always — that is the whole of what this clock promises, and
    // the reason a statement's duration is taken from it rather than from
    // `nowMicros` (ADR 0137).
    try testing.expect(second >= first);

    // And it is a different origin from the wall clock's, which is what says
    // it is a second clock rather than a second name for the first. Two
    // machines could disagree, so the assertion is that they are not the same
    // number rather than anything about the gap.
    try testing.expect(monotonicMicros() != nowMicros());
}

test "the clock does not go backwards between two reads" {
    // `>=` rather than `>`: two reads can land in the same microsecond,
    // and on a machine whose operator moves the wall clock they can land
    // anywhere — which is what a wall clock is, and why nothing measures a
    // duration with this one.
    const first = nowMicros();
    try testing.expect(nowMicros() >= first);
}
