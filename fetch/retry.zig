//! A call that is worth another try is tried again by a mechanism, and the
//! numbers are the caller's
//! ([ADR 271](../docs/adr/271-a-retry-is-the-callers-numbers-and-nilos-mechanism.md)).
//!
//! ```zig
//! const Stripe = fetch.Target("stripe", .{
//!     .retry = .{ .times = 3, .mint_key = "Idempotency-Key" },
//! });
//! ```
//!
//! The loop every caller used to write had four traps in three lines: a POST
//! sent again charges twice, a sleep with no jitter sends every caller back
//! at the same instant, `Retry-After` is read by hand or not at all, and a
//! loop with no budget turns a service's bad minute into three times its
//! load. What is here is the part that is the same for everybody, in the
//! shape tower, the AWS SDKs and Stripe's clients converged on:
//!
//! - **Only a call that can be sent again is.** GET, HEAD, PUT, DELETE,
//!   OPTIONS and TRACE (`std.http.Method.idempotent`), and a POST or PATCH
//!   only when it carries an `Idempotency-Key` of the caller's or the type
//!   says how to mint one (`mint_key`), in which case the one key goes on
//!   every attempt.
//! - **A budget** in tower's shape: retries are allowed up to a percentage of
//!   the calls made in a recent window, plus a floor per second so a quiet
//!   service can still retry. When most calls fail the budget runs out and
//!   the service gets no more load than the calls it was given plus that
//!   fraction. There is no way to turn it off, because a retry with no
//!   budget is the multiplication this exists to stop.
//! - **Jitter** from `nilo_core`'s `Backoff`, full by default.
//! - **`Retry-After`** (seconds or an HTTP date) is a floor on the wait,
//!   capped at `retry_after_max_ms`.
//! - **The route's deadline bounds the whole sequence.** A wait that would
//!   not leave the request time to try again is not taken, and a retry never
//!   outlives the deadline (`core.timeLeftOf`).
//!
//! The state is a `Ledger`, the budget's counts, one per service. A Target
//! that declares no `.retry` has none of it.

const std = @import("std");
const core = @import("nilo_core");

/// What a retry is: every field is a fact about the other service, and the
/// defaults are the ones the clients named above agree on.
pub const Retry = struct {
    /// How many times to try again after the first, so `2` is three calls at
    /// most.
    times: u8 = 2,
    /// The wait between tries, with its jitter. Full jitter by default: the
    /// best spread of callers that failed together.
    backoff: core.Backoff = .{ .exponential = .{ .from_ms = 100, .to_ms = 2_000, .jitter = .full } },
    /// The statuses worth another try: the service said "later" (429), or a
    /// hop in front of it failed (502, 503, 504). A 500 is not here, because
    /// it is as often a bug that will answer the same again; add it for a
    /// service that means "try me again" by it.
    statuses: []const u16 = &.{ 429, 502, 503, 504 },
    /// The longest `Retry-After` is waited for. A service that says an hour
    /// is waited for this long and tried once more, and the route's
    /// deadline is what ends it sooner.
    retry_after_max_ms: u32 = 5_000,
    budget: Budget = .{},
    /// The header a POST or PATCH that carries no key of its own gets one
    /// under, minted once per call and sent on every attempt:
    /// `"Idempotency-Key"` for Stripe and most that followed. Naming it is a
    /// claim that the service honours it. Null, the default, retries a POST
    /// only when the caller put a key on it.
    mint_key: ?[]const u8 = null,

    /// The most retries a window allows (tower's `Budget`).
    pub const Budget = struct {
        /// Retries up to this percent of the calls made in the window.
        percent: u16 = 20,
        /// And this many a second regardless, so a service called twice a
        /// minute can still retry.
        min_per_sec: u16 = 10,
        /// How far back the calls are counted, 1 to 16 seconds.
        window_s: u8 = 10,
    };

    /// What is wrong with these numbers, or null. Run while compiling for a
    /// Target and at `open` for a Store.
    pub fn problem(self: Retry) ?[]const u8 {
        if (self.times == 0) return "`times` is 0, which is no retry at all; take `.retry` out";
        if (self.budget.window_s == 0 or self.budget.window_s > Ledger.slots_len) return "`budget.window_s` is outside 1 to 16 seconds";
        if (self.budget.percent == 0 and self.budget.min_per_sec == 0) return "the budget allows no retry at all (`percent` and `min_per_sec` are both 0)";
        switch (self.backoff) {
            .fixed_ms => {},
            .exponential => |e| {
                if (e.from_ms == 0) return "the exponential backoff starts at `from_ms = 0`, and doubling zero is zero";
                if (e.to_ms < e.from_ms) return "the exponential backoff's `to_ms` is below its `from_ms`";
            },
        }
        for (self.statuses) |s| if (s < 400 or s > 599) return "`statuses` names a status that is not an error (400 to 599)";
        if (self.statuses.len == 0) return "`statuses` is empty, and only a transport failure would ever be retried";
        if (self.mint_key) |name| {
            if (name.len == 0) return "`mint_key` is empty";
            for (name) |ch| if (ch <= ' ' or ch == ':' or ch >= 127) return "`mint_key` is not a header name";
        }
        return null;
    }

    /// Whether `status` is one the service means as "later".
    pub fn retriesStatus(self: Retry, status: u16) bool {
        for (self.statuses) |s| if (s == status) return true;
        return false;
    }

    /// Whether a call that failed with `err` before an answer is one to try
    /// again: the connection could not be made or was lost, or this call's
    /// own clock ran out. Named by text so that an error std has not got in
    /// a given version is not a compile error here; **`Canceled` is never
    /// here**, because a shutdown is not the service's bad minute.
    pub fn retriesError(err: anyerror) bool {
        const name = @errorName(err);
        inline for (transient) |t| if (std.mem.eql(u8, name, t)) return true;
        return false;
    }

    const transient = [_][]const u8{
        "ConnectionRefused",    "ConnectionResetByPeer", "ConnectionTimedOut",
        "NetworkUnreachable",   "HttpConnectionClosing", "UnknownHostName",
        "TemporaryNameServerFailure", "ReadFailed",      "WriteFailed",
        "TimedOut",             "Stalled",
    };

    /// Whether the headers name an idempotency key, in any case.
    pub fn hasKey(headers: []const std.http.Header) bool {
        for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "idempotency-key")) return true;
        return false;
    }

    /// Whether a call may be sent again at all: its method is idempotent, or
    /// it carries a key (the caller's, in `headers`, or one to be minted).
    pub fn may(self: Retry, method: std.http.Method, headers: []const std.http.Header) bool {
        if (method.idempotent()) return true;
        return self.mint_key != null or hasKey(headers);
    }
};

/// `Retry-After` as a wait in milliseconds, from seconds or an HTTP date
/// (`Sun, 06 Nov 1994 08:49:37 GMT`), or null when it is neither. A date in
/// the past is no wait.
pub fn retryAfterMs(value: []const u8, now_s: i64) ?u64 {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len == 0) return null;
    if (std.fmt.parseInt(u64, v, 10)) |secs| return std.math.mul(u64, secs, 1000) catch std.math.maxInt(u64) else |_| {}
    const at = httpDate(v) orelse return null;
    return if (at <= now_s) 0 else @as(u64, @intCast(at - now_s)) * 1000;
}

/// IMF-fixdate to unix seconds. The other two formats RFC 9110 allows are
/// obsolete and a server sending one is ignored.
fn httpDate(v: []const u8) ?i64 {
    // "Sun, 06 Nov 1994 08:49:37 GMT"
    if (v.len != 29 or v[3] != ',' or !std.mem.endsWith(u8, v, " GMT")) return null;
    const day = std.fmt.parseInt(i64, v[5..7], 10) catch return null;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var month: i64 = 0;
    for (months, 1..) |m, i| if (std.mem.eql(u8, v[8..11], m)) {
        month = @intCast(i);
    };
    if (month == 0) return null;
    const year = std.fmt.parseInt(i64, v[12..16], 10) catch return null;
    const hh = std.fmt.parseInt(i64, v[17..19], 10) catch return null;
    const mm = std.fmt.parseInt(i64, v[20..22], 10) catch return null;
    const ss = std.fmt.parseInt(i64, v[23..25], 10) catch return null;
    // Days from civil (Howard Hinnant's algorithm).
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hh * 3600 + mm * 60 + ss;
}

/// The budget's counts: calls made and retries spent, a second at a time for
/// the last sixteen. One per service, shared by every handler calling it,
/// so a short spin lock guards it and nothing waits inside (a handful of
/// integer operations).
pub const Ledger = struct {
    lock: std.atomic.Value(u32) = .init(0),
    slots: [slots_len]Slot = @splat(.{}),

    pub const slots_len = 16;
    const Slot = struct { second: i64 = -1, calls: u32 = 0, retries: u32 = 0 };

    pub const empty: Ledger = .{};

    fn acquire(self: *Ledger) void {
        while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(self: *Ledger) void {
        self.lock.store(0, .release);
    }

    fn slot(self: *Ledger, now_s: i64) *Slot {
        const sl = &self.slots[@intCast(@mod(now_s, slots_len))];
        if (sl.second != now_s) sl.* = .{ .second = now_s };
        return sl;
    }

    /// A call was made: the retries it allows grow by the budget's percent.
    pub fn deposit(self: *Ledger, now_s: i64) void {
        self.acquire();
        defer self.release();
        self.slot(now_s).calls +|= 1;
    }

    /// Whether one more retry is within the budget, spent if so.
    pub fn withdraw(self: *Ledger, b: Retry.Budget, now_s: i64) bool {
        self.acquire();
        defer self.release();
        var calls: u64 = 0;
        var spent: u64 = 0;
        for (self.slots) |sl| {
            if (sl.second > now_s - b.window_s and sl.second <= now_s) {
                calls += sl.calls;
                spent += sl.retries;
            }
        }
        const allowed = calls * b.percent / 100 + @as(u64, b.min_per_sec) * b.window_s;
        if (spent + 1 > allowed) return false;
        self.slot(now_s).retries +|= 1;
        return true;
    }
};

fn nowSecond() i64 {
    return @divFloor(core.monotonicMicros(), std.time.us_per_s);
}

/// One logical call's progress through its tries, on the caller's stack.
///
/// ```zig
/// var tries = Tries.start(&policy, &ledger, io);
/// while (true) {
///     const res = attempt() catch |err| {
///         if (Retry.retriesError(err) and try tries.again(c, null)) continue;
///         return err;
///     };
///     if (policy.retriesStatus(res.status) and try tries.again(c, after)) continue;
///     return res;
/// }
/// ```
pub const Tries = struct {
    policy: *const Retry,
    ledger: *Ledger,
    io: std.Io,
    /// Retries made so far.
    made: u8 = 0,

    /// The first call is made: it goes in the budget's count.
    pub fn start(policy: *const Retry, ledger: *Ledger, io: std.Io) Tries {
        ledger.deposit(nowSecond());
        return .{ .policy = policy, .ledger = ledger, .io = io };
    }

    /// Whether to try again, and if so the wait has been taken. False is
    /// "return what you have": out of tries, out of budget, or the route
    /// has no time left for the wait and another try. `after_ms` is the
    /// `Retry-After` the answer carried, if any.
    pub fn again(self: *Tries, c: anytype, after_ms: ?u64) std.Io.Cancelable!bool {
        if (self.made >= self.policy.times) return false;
        var bits: [8]u8 = undefined;
        self.io.random(&bits);
        var wait = self.policy.backoff.delayMs(@as(u32, self.made) + 1, std.mem.readInt(u64, &bits, .little));
        if (after_ms) |a| wait = @max(wait, @min(a, self.policy.retry_after_max_ms));
        // The deadline is the whole sequence's: a wait that leaves nothing
        // to try with is not worth taking, and neither costs the budget.
        if (core.timeLeftOf(c)) |left| if (wait >= left) return false;
        if (!self.ledger.withdraw(self.policy.budget, nowSecond())) return false;
        if (wait != 0) try self.io.sleep(.fromMilliseconds(@intCast(wait)), .awake);
        self.made += 1;
        return true;
    }
};

/// A key for a call that needs one: 16 random bytes as 32 hex digits, drawn
/// from the loop's generator. Written into `out`.
pub fn mintKey(io: std.Io, out: *[32]u8) void {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    out.* = std.fmt.bytesToHex(raw, .lower);
}

const testing = std.testing;

test "a retry with nothing wrong in it has no problem, and each thing wrong is named" {
    try testing.expect((Retry{}).problem() == null);
    try testing.expect((Retry{ .times = 0 }).problem() != null);
    try testing.expect((Retry{ .backoff = .{ .exponential = .{ .from_ms = 0, .to_ms = 10 } } }).problem() != null);
    try testing.expect((Retry{ .backoff = .{ .exponential = .{ .from_ms = 50, .to_ms = 10 } } }).problem() != null);
    try testing.expect((Retry{ .statuses = &.{200} }).problem() != null);
    try testing.expect((Retry{ .statuses = &.{} }).problem() != null);
    try testing.expect((Retry{ .budget = .{ .percent = 0, .min_per_sec = 0 } }).problem() != null);
    try testing.expect((Retry{ .budget = .{ .window_s = 30 } }).problem() != null);
    try testing.expect((Retry{ .mint_key = "Bad Name" }).problem() != null);
}

test "only an idempotent method is retried, unless the call carries a key or the type mints one" {
    const plain: Retry = .{};
    const minting: Retry = .{ .mint_key = "Idempotency-Key" };
    const keyed = [_]std.http.Header{.{ .name = "idempotency-key", .value = "k1" }};
    try testing.expect(plain.may(.GET, &.{}));
    try testing.expect(plain.may(.PUT, &.{}));
    try testing.expect(plain.may(.DELETE, &.{}));
    try testing.expect(!plain.may(.POST, &.{}));
    try testing.expect(!plain.may(.PATCH, &.{}));
    try testing.expect(plain.may(.POST, &keyed));
    try testing.expect(minting.may(.POST, &.{}));
}

test "Retry-After is seconds or an HTTP date, and anything else is ignored" {
    try testing.expectEqual(@as(?u64, 30_000), retryAfterMs("30", 0));
    try testing.expectEqual(@as(?u64, 0), retryAfterMs(" 0 ", 0));
    try testing.expectEqual(@as(?u64, null), retryAfterMs("soon", 0));
    try testing.expectEqual(@as(?u64, null), retryAfterMs("", 0));
    // 06 Nov 1994 08:49:37 GMT is 784111777.
    try testing.expectEqual(@as(?i64, 784111777), httpDate("Sun, 06 Nov 1994 08:49:37 GMT"));
    try testing.expectEqual(@as(?u64, 23_000), retryAfterMs("Sun, 06 Nov 1994 08:49:37 GMT", 784111777 - 23));
    try testing.expectEqual(@as(?u64, 0), retryAfterMs("Sun, 06 Nov 1994 08:49:37 GMT", 784111777 + 5));
    try testing.expectEqual(@as(?u64, null), retryAfterMs("Sunday, 06-Nov-94 08:49:37 GMT", 0));
}

test "the budget allows its percent of the calls plus the floor, and not one more" {
    var ledger: Ledger = .empty;
    const b: Retry.Budget = .{ .percent = 20, .min_per_sec = 0, .window_s = 10 };
    // No calls, no retries.
    try testing.expect(!ledger.withdraw(b, 100));
    for (0..10) |_| ledger.deposit(100);
    // Ten calls at 20 percent: two retries.
    try testing.expect(ledger.withdraw(b, 100));
    try testing.expect(ledger.withdraw(b, 100));
    try testing.expect(!ledger.withdraw(b, 100));
    // The floor is per second of the window, with no calls at all.
    var quiet: Ledger = .empty;
    const floor: Retry.Budget = .{ .percent = 0, .min_per_sec = 1, .window_s = 3 };
    for (0..3) |_| try testing.expect(quiet.withdraw(floor, 50));
    try testing.expect(!quiet.withdraw(floor, 50));
}

test "calls that left the window no longer count" {
    var ledger: Ledger = .empty;
    const b: Retry.Budget = .{ .percent = 100, .min_per_sec = 0, .window_s = 5 };
    for (0..4) |_| ledger.deposit(10);
    try testing.expect(ledger.withdraw(b, 14));
    // Five seconds on, second 10 is outside a window of five.
    try testing.expect(!ledger.withdraw(b, 15));
}

test "a key is 32 hex digits and differs from the next" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    mintKey(threaded.io(), &a);
    mintKey(threaded.io(), &b);
    for (a) |ch| try testing.expect(std.ascii.isHex(ch));
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "a transport failure is retried and a cancellation is not" {
    try testing.expect(Retry.retriesError(error.ConnectionRefused));
    try testing.expect(Retry.retriesError(error.TimedOut));
    try testing.expect(!Retry.retriesError(error.Canceled));
    try testing.expect(!Retry.retriesError(error.BodyTooLarge));
    try testing.expect(!Retry.retriesError(error.OutOfMemory));
}
