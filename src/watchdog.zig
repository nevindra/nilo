//! Catching a handler that holds its thread (ADR 0034).
//!
//! Many requests share one OS thread. A handler that waits on the operating
//! system directly — a database driver, `std.fs`, `std.http.Client` — stops
//! every other request on that thread for as long as it waits. `zfast.blocking`
//! is the way not to, and ADR 0014 recorded that **nothing forces it**: the
//! wrong version compiles, passes its tests, and only misbehaves under
//! concurrency, which is the one condition development does not have.
//!
//! This is what now notices. It is the same shape as the `Str` staleness trap
//! (ADR 0004): a rule the type system cannot hold, held instead by something
//! that watches at run time and says so in words.
//!
//! What it measures is **elapsed time minus time the fiber spent parked**.
//! Parked time is not guessed at — it is reported by the six things a request
//! waits on that are not the handler's own code:
//!
//! - `zfast.blocking`, `zfast.sleep`, `zfast.Mutex.lock`, `randomSecure`
//!   (`bulkhead.zig`)
//! - reading the request body, and writing the response (`ctx.zig`, `app.zig`)
//!
//! Whatever is left is the handler running, and a handler that ran for a
//! quarter of a second without yielding once is either blocking or doing CPU
//! work it should have handed to `zfast.blocking` — which is the same advice
//! either way, so both are worth saying.
//!
//! ## What it does not see
//!
//! A request that takes the connection over — a stream, a body reader, a
//! WebSocket — is excused entirely. Those hold their fiber for as long as they
//! like, legitimately, and most of that time is socket I/O nothing here
//! accounts for. A blocking call inside a WebSocket loop is real and is not
//! reported. That is a stated gap, not an oversight.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");

/// The stopwatch one request carries. It lives on the `fail.InFlight`, so it
/// is reachable from anywhere the request is — including from inside a
/// blocking call, which is where half the reports come from.
pub const Watch = struct {
    /// When the middleware chain started, as a `monotonicNanos` reading.
    /// Zero means nobody is watching this request, which is what turns the
    /// whole thing off: every function below leaves immediately.
    from_ns: u64 = 0,
    /// How much of that span the fiber spent parked rather than running.
    waited_ns: u64 = 0,
    /// What counts as too long.
    warn_ns: u64 = 0,
};

/// How many requests have been caught holding their thread since the process
/// started, counted before the rate limit below throws any away.
///
/// This exists because a detector nobody can watch fail is a detector nobody
/// can trust (ADR 0033). The log line is for people; this is what a test
/// asserts on, since the suite runs with warnings turned off.
pub var caught: std.atomic.Value(u64) = .init(0);

/// Start the clock. `warn_ms` of 0 turns the detector off for this request.
pub fn begin(w: *Watch, warn_ms: u32) void {
    // A connection serves many requests and the Watch outlives each of them,
    // so both branches clear it rather than only the one that goes on to use
    // it — `waited_ns` left over from the previous request would otherwise
    // be forgiveness this one did not earn.
    if (warn_ms == 0) {
        w.* = .{};
        return;
    }
    w.* = .{
        // `| 1` because zero is how `from_ns` says "not watching". A clock
        // reading of exactly zero is not going to happen, and a detector
        // that silently switches itself off if it ever did is worse than a
        // nanosecond of error.
        .from_ns = bulkhead.coarseNanos() | 1,
        .warn_ns = @as(u64, warn_ms) * std.time.ns_per_ms,
    };
}

/// Stop the clock and report if what is left after the waiting is too long.
///
/// `excused` is for a request that took the connection over. `method` and
/// `path` are only read if there is something to say.
pub fn finish(w: *Watch, method: []const u8, path: []const u8, excused: bool) void {
    const from = w.from_ns;
    if (from == 0) return;
    w.from_ns = 0;
    if (excused) return;

    const held = (bulkhead.coarseNanos() -| from) -| w.waited_ns;
    if (held < w.warn_ns) return;

    _ = caught.fetchAdd(1, .monotonic);
    report(method, path, held / std.time.ns_per_ms);
}

/// The start of a wait that is not the handler holding the thread. Pairs with
/// `waited`, and the token is 0 when nobody is watching — which is the whole
/// cost of this on a server that has the detector turned off.
///
/// ```zig
/// const w = watchdog.waiting(c._watch);
/// defer watchdog.waited(c._watch, w);
/// ```
pub fn waiting(w: ?*Watch) u64 {
    const watch = w orelse return 0;
    if (watch.from_ns == 0) return 0;
    return bulkhead.coarseNanos() | 1;
}

/// Close a wait opened by `waiting`, adding it to what this request is
/// forgiven.
pub fn waited(w: ?*Watch, token: u64) void {
    if (token == 0) return;
    const watch = w orelse return;
    watch.waited_ns += bulkhead.coarseNanos() -| token;
}

/// The same pair for code with no Ctx to hand — `zfast.blocking` and
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
                "zfast.blocking (ADR 0014).",
            .{ method, path, ms },
        );
    } else {
        std.log.warn(
            "handler {s} {s} held its thread for {d}ms, and {d} more did in the second " ++
                "before it. Every other request being served on those threads waited. " ++
                "Hand the call that waits to zfast.blocking (ADR 0014).",
            .{ method, path, ms, others },
        );
    }
}

// ---- tests ----

const testing = std.testing;

/// Drive a Watch by hand, so the arithmetic can be checked without spending
/// the wall-clock time it is measuring. The integration tests in `app.zig`
/// pay for real milliseconds; these do not.
fn spent(elapsed_ms: u64, waited_ms: u64, warn_ms: u32) u64 {
    // The warning is the behaviour under test, not news, and on the test
    // runner's stderr it makes a passing suite print `failed command`.
    const previous = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = previous;

    const before = caught.load(.monotonic);
    var w = Watch{
        .from_ns = 1,
        .waited_ns = waited_ms * std.time.ns_per_ms,
        .warn_ns = @as(u64, warn_ms) * std.time.ns_per_ms,
    };
    // Held constant by pretending the span started `elapsed_ms` before now.
    w.from_ns = (bulkhead.coarseNanos() -| (elapsed_ms * std.time.ns_per_ms)) | 1;
    finish(&w, "GET", "/x", false);
    return caught.load(.monotonic) - before;
}

test "a handler that ran the whole time is reported" {
    try testing.expectEqual(@as(u64, 1), spent(50, 0, 10));
}

test "a handler that spent the time parked is not" {
    // The same 50ms, all of it waiting on something that yielded. This is
    // the case the detector exists to keep quiet about: `zfast.blocking`
    // done right must never look like `zfast.blocking` skipped.
    try testing.expectEqual(@as(u64, 0), spent(50, 50, 10));
}

test "waiting longer than the span does not wrap around into a report" {
    // The two clock readings are taken at different moments by different
    // pieces of code, so `waited_ns` above `elapsed` is arithmetic that has
    // to be survivable rather than a state that cannot happen.
    try testing.expectEqual(@as(u64, 0), spent(10, 500, 10));
}

test "a request nobody is watching costs nothing and says nothing" {
    var w = Watch{};
    const before = caught.load(.monotonic);
    finish(&w, "GET", "/x", false);
    try testing.expectEqual(before, caught.load(.monotonic));

    // And the pair a call site uses is a pair of no-ops, not a pair of
    // clock reads whose result is thrown away.
    begin(&w, 0);
    try testing.expectEqual(@as(u64, 0), w.from_ns);
    try testing.expectEqual(@as(u64, 0), waiting(&w));
}

test "begin sets a clock that is not zero" {
    var w = Watch{};
    begin(&w, 250);
    try testing.expect(w.from_ns != 0);
    try testing.expectEqual(250 * std.time.ns_per_ms, w.warn_ns);
}

test "an excused request is measured and then let go" {
    const before = caught.load(.monotonic);
    var w = Watch{
        .from_ns = (bulkhead.coarseNanos() -| (500 * std.time.ns_per_ms)) | 1,
        .warn_ns = std.time.ns_per_ms,
    };
    finish(&w, "GET", "/events", true);
    try testing.expectEqual(before, caught.load(.monotonic));
    // Still stopped, so a second call cannot report the same span twice.
    try testing.expectEqual(@as(u64, 0), w.from_ns);
}

test "a second request on the same connection does not inherit the first one's forgiveness" {
    // The Watch lives on the InFlight, which lives for the whole connection.
    // `waited_ns` from a request that spent its life in `zfast.blocking`
    // would otherwise excuse the next one on that connection for free.
    var w = Watch{};
    begin(&w, 10);
    waited(&w, waiting(&w));
    w.waited_ns += 500 * std.time.ns_per_ms;

    begin(&w, 10);
    try testing.expectEqual(@as(u64, 0), w.waited_ns);

    // And the same when the detector is switched off, which is the branch
    // that used to leave it behind.
    w.waited_ns = 500 * std.time.ns_per_ms;
    begin(&w, 0);
    try testing.expectEqual(@as(u64, 0), w.waited_ns);
}
