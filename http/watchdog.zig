//! Catching a handler that holds its thread (ADR 0034).
//!
//! Many requests share one OS thread. A handler that waits on the operating
//! system directly — a database driver, `std.fs`, `std.http.Client` — stops
//! every other request on that thread for as long as it waits. `nilo.blocking`
//! is the way not to, and ADR 0014 recorded that **nothing forces it**: the
//! wrong version compiles, passes its tests, and only misbehaves under
//! concurrency, which is the one condition development does not have.
//!
//! This is what now notices. It is the same shape as the `Str` staleness trap
//! (ADR 0004): a rule the type system cannot hold, held instead by something
//! that watches at run time and says so in words.
//!
//! What it measures is **the longest stretch the fiber ran without parking**
//! ([ADR 0132](../docs/adr/0132-what-is-watched-is-one-unparked-stretch.md)).
//! A stretch ends wherever the request waits on something that is not the
//! handler's own code, and every one of those says so:
//!
//! - `nilo.blocking`, `nilo.sleep`, `nilo.Mutex.lock`, `randomSecure`
//!   (`bulkhead.zig`)
//! - reading the request body, and writing the response (`ctx.zig`, `app.zig`)
//! - a stream's writes, a body reader's reads, and a WebSocket's park
//!   (`stream.zig`, `body.zig`, `websocket.zig`)
//!
//! Whatever is between two of those is the handler running, and a handler that
//! ran for a quarter of a second without yielding once is either blocking or
//! doing CPU work it should have handed to `nilo.blocking` — which is the same
//! advice either way, so both are worth saying.
//!
//! **This used to be elapsed time minus parked time, summed over the whole
//! request, and that is why a stream, a body reader and a WebSocket had to be
//! excused entirely.** A sum has no upper bound on a connection that is open
//! for an hour: a WebSocket answering a thousand messages a second accumulates
//! seconds of perfectly correct handler time and would have been reported for
//! it. One stretch has the same meaning on a request that lasts a millisecond
//! and on a connection that lasts a day, which is what let the exemption go.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");

/// The stopwatch one request carries. It lives on the `fail.InFlight`, so it
/// is reachable from anywhere the request is — including from inside a
/// blocking call, which is where half the reports come from.
pub const Watch = struct {
    /// When the stretch now running began, as a `coarseNanos` reading. Zero
    /// means the fiber is parked — or that this request is not watched at
    /// all, which `warn_ns` is what tells apart.
    from_ns: u64 = 0,
    /// What counts as too long. Zero means nobody is watching this request,
    /// which is what turns the whole thing off: every function below leaves
    /// immediately.
    warn_ns: u64 = 0,
    /// What to call the request in the report. Kept here rather than looked
    /// up, because the report can now fire from inside `waiting`, which has
    /// no Ctx to ask — `fail.InFlight` holds the same two, and a `Watch`
    /// living outside one is a thing a test is allowed to build.
    method: []const u8 = "",
    path: []const u8 = "",
};

/// How many requests have been caught holding their thread since the process
/// started, counted before the rate limit below throws any away.
///
/// This exists because a detector nobody can watch fail is a detector nobody
/// can trust (ADR 0033). The log line is for people; this is what a test
/// asserts on, since the suite runs with warnings turned off.
pub var caught: std.atomic.Value(u64) = .init(0);

/// Start the first stretch. `warn_ms` of 0 turns the detector off for this
/// request.
pub fn begin(w: *Watch, warn_ms: u32, method: []const u8, path: []const u8) void {
    // A connection serves many requests and the Watch outlives each of them,
    // so both branches clear it rather than only the one that goes on to use
    // it.
    if (warn_ms == 0) {
        w.* = .{};
        return;
    }
    w.* = .{
        // `| 1` because zero is how `from_ns` says "parked". A clock reading
        // of exactly zero is not going to happen, and a detector that
        // silently forgives a stretch if it ever did is worse than a
        // nanosecond of error.
        .from_ns = bulkhead.coarseNanos() | 1,
        .warn_ns = @as(u64, warn_ms) * std.time.ns_per_ms,
        .method = method,
        .path = path,
    };
}

/// Close the last stretch and report if it was too long.
///
/// There is no `excused` any more. A request that takes the connection over
/// is watched like any other, because what is measured is one stretch rather
/// than a total — see the header.
pub fn finish(w: *Watch) void {
    const from = w.from_ns;
    reportIfTooLong(w, from);
    w.* = .{};
}

/// The end of a stretch: report it if the handler ran too long, and leave the
/// watch parked.
fn reportIfTooLong(w: *Watch, from: u64) void {
    if (w.warn_ns == 0 or from == 0) return;
    const held = bulkhead.coarseNanos() -| from;
    if (held < w.warn_ns) return;

    _ = caught.fetchAdd(1, .monotonic);
    report(w.method, w.path, held / std.time.ns_per_ms);
}

/// The start of a wait that is not the handler holding the thread. **This is
/// where a stretch ends**, and where the report fires if it was too long.
/// Pairs with `waited`, and the token is 0 when nobody is watching — which is
/// the whole cost of this on a server that has the detector turned off.
///
/// ```zig
/// const w = watchdog.waiting(c._watch);
/// defer watchdog.waited(c._watch, w);
/// ```
///
/// **Nested pairs are safe and cost nothing.** The inner one finds the watch
/// already parked, returns 0, and its `waited` does nothing — so the stretch
/// is reopened by the outermost `waited` and by that one only. `nilo.sleep`
/// inside `Ctx.body` is exactly that shape.
pub fn waiting(w: ?*Watch) u64 {
    const watch = w orelse return 0;
    if (watch.warn_ns == 0) return 0;
    const from = watch.from_ns;
    if (from == 0) return 0;
    watch.from_ns = 0;
    reportIfTooLong(watch, from);
    return 1;
}

/// Close a wait opened by `waiting`: the fiber is running again, so a new
/// stretch starts here.
pub fn waited(w: ?*Watch, token: u64) void {
    if (token == 0) return;
    const watch = w orelse return;
    watch.from_ns = bulkhead.coarseNanos() | 1;
}

/// The same pair for code with no Ctx to hand — `nilo.blocking` and
/// friends, called from inside a handler that knows nothing about the
/// request it is part of.
///
/// These cost a slot lookup where the two above cost a null check, which is
/// why every path that can hold the pointer holds it. On this side that is
/// nothing: a request reaching one of these is about to park.
pub fn waitingAnywhere() u64 {
    return waiting(here());
}

pub fn waitedAnywhere(token: u64) void {
    waited(here(), token);
}

/// The watch belonging to the request running on this fiber, if any.
///
/// `fail.zig` is imported here rather than at the top because it holds a
/// `Watch` in its `InFlight` and so imports this file — the same knot
/// `resolve.zig` and `ctx.zig` are tied in, undone the same way.
fn here() ?*Watch {
    const fail = @import("fail.zig");
    return &(fail.inFlight() orelse return null).watch;
}

// ---- saying so ----

/// A handler that blocks blocks on every request, so the honest report is one
/// line a second with a count, not one line per request. Without this, finding
/// the bug means scrolling past ten thousand copies of the message describing
/// it.
var last_ns: std.atomic.Value(u64) = .init(0);
var also: std.atomic.Value(u32) = .init(0);

fn report(method: []const u8, path: []const u8, ms: u64) void {
    const now = bulkhead.coarseNanos();
    const last = last_ns.load(.monotonic);
    if (last != 0 and now -| last < std.time.ns_per_s) {
        _ = also.fetchAdd(1, .monotonic);
        return;
    }
    last_ns.store(now | 1, .monotonic);
    const others = also.swap(0, .monotonic);

    // Two spellings rather than one with a "(and 0 others)" tail: the first
    // report of a problem is the one somebody reads, and it should not have
    // to be parsed past a zero.
    if (others == 0) {
        std.log.warn(
            "handler {s} {s} held its thread for {d}ms. Every other request being served " ++
                "on that thread waited the whole time. Hand the call that waits to " ++
                "nilo.blocking (ADR 0014).",
            .{ method, path, ms },
        );
    } else {
        std.log.warn(
            "handler {s} {s} held its thread for {d}ms, and {d} more did in the second " ++
                "before it. Every other request being served on those threads waited. " ++
                "Hand the call that waits to nilo.blocking (ADR 0014).",
            .{ method, path, ms, others },
        );
    }
}

// ---- tests ----

const testing = std.testing;

/// Drive a Watch by hand, so the arithmetic can be checked without spending
/// the wall-clock time it is measuring. The integration tests in `app.zig`
/// pay for real milliseconds; these do not.
fn quiet() std.log.Level {
    // The warning is the behaviour under test, not news, and on the test
    // runner's stderr it makes a passing suite print `failed command`.
    const previous = testing.log_level;
    testing.log_level = .err;
    return previous;
}

/// A watch whose current stretch started `elapsed_ms` ago.
fn running(elapsed_ms: u64, warn_ms: u32) Watch {
    return .{
        .from_ns = (bulkhead.coarseNanos() -| (elapsed_ms * std.time.ns_per_ms)) | 1,
        .warn_ns = @as(u64, warn_ms) * std.time.ns_per_ms,
        .method = "GET",
        .path = "/x",
    };
}

test "a stretch that ran the whole time is reported" {
    const noisy = quiet();
    defer testing.log_level = noisy;

    const before = caught.load(.monotonic);
    var w = running(50, 10);
    finish(&w);
    try testing.expectEqual(before + 1, caught.load(.monotonic));
}

test "a stretch under the limit is not" {
    const before = caught.load(.monotonic);
    var w = running(1, 10);
    finish(&w);
    try testing.expectEqual(before, caught.load(.monotonic));
}

test "a wait ends the stretch, and the next one starts from there" {
    const noisy = quiet();
    defer testing.log_level = noisy;

    // 50ms of handler, then a wait. The wait is where the report fires —
    // that is what lets a handler which never returns be watched at all.
    const before = caught.load(.monotonic);
    var w = running(50, 10);
    const token = waiting(&w);
    try testing.expectEqual(before + 1, caught.load(.monotonic));
    try testing.expect(token != 0);
    // Parked: nothing is being timed.
    try testing.expectEqual(@as(u64, 0), w.from_ns);

    // Running again, from now rather than from where the first stretch
    // began. `finish` on the fresh one has nothing to say.
    waited(&w, token);
    try testing.expect(w.from_ns != 0);
    finish(&w);
    try testing.expectEqual(before + 1, caught.load(.monotonic));
}

test "a nested wait neither reports twice nor reopens early" {
    const noisy = quiet();
    defer testing.log_level = noisy;

    // `nilo.sleep` inside `Ctx.body` is this shape, and the inner pair must
    // not restart the clock while the outer one is still parked.
    const before = caught.load(.monotonic);
    var w = running(50, 10);
    const outer = waiting(&w);
    try testing.expectEqual(before + 1, caught.load(.monotonic));

    const inner = waiting(&w);
    try testing.expectEqual(@as(u64, 0), inner);
    waited(&w, inner);
    try testing.expectEqual(@as(u64, 0), w.from_ns);
    try testing.expectEqual(before + 1, caught.load(.monotonic));

    waited(&w, outer);
    try testing.expect(w.from_ns != 0);
}

test "a request nobody is watching costs nothing and says nothing" {
    var w = Watch{};
    const before = caught.load(.monotonic);
    finish(&w);
    try testing.expectEqual(before, caught.load(.monotonic));

    // And the pair a call site uses is a pair of no-ops, not a pair of
    // clock reads whose result is thrown away.
    begin(&w, 0, "GET", "/x");
    try testing.expectEqual(@as(u64, 0), w.from_ns);
    try testing.expectEqual(@as(u64, 0), waiting(&w));
}

test "begin sets a clock that is not zero" {
    var w = Watch{};
    begin(&w, 250, "GET", "/x");
    try testing.expect(w.from_ns != 0);
    try testing.expectEqual(250 * std.time.ns_per_ms, w.warn_ns);
    try testing.expectEqualStrings("/x", w.path);
}

test "a second request on the same connection starts from nothing" {
    // The Watch lives on the InFlight, which lives for the whole connection,
    // so a request that left a stretch open or a limit behind would decide
    // what the next one on that connection is measured against.
    var w = Watch{};
    begin(&w, 10, "GET", "/first");
    finish(&w);
    try testing.expectEqual(@as(u64, 0), w.from_ns);
    try testing.expectEqual(@as(u64, 0), w.warn_ns);

    // And the same when the detector is switched off, which is the branch
    // that used to leave state behind.
    w = running(500, 1);
    begin(&w, 0, "GET", "/second");
    try testing.expectEqual(@as(u64, 0), w.from_ns);
    try testing.expectEqual(@as(u64, 0), w.warn_ns);
}
