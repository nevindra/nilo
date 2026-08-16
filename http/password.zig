//! Hashing a password from inside a request: the Gate, the blocking pool and
//! the salt, so that a handler writes one call (ADR 0048).
//!
//! `nilo_pw` is the whole of the cryptography and none of this. It is a tool
//! module with no event loop, so it cannot take entropy, cannot park a fiber
//! and cannot know how many hashes are already running. This file is the half
//! that can, and it is not a convenience wrapper — **it is the half that is
//! load-bearing**, for a reason worth stating plainly:
//!
//! **A forgotten `nilo.blocking` around a password hash is silent.** The
//! blocking detector fires at `block_warning_ms`, 250 by default, and one
//! hash at the default Cost is 13 ms. So a handler that calls `pw.hash`
//! directly holds its thread for 13 ms per sign-in, every sign-in, and
//! nothing anywhere says so — not the log, not a test, not the benchmark. It
//! shows up as p99 on endpoints that have nothing to do with signing in
//! (ADR 0034 is the detector; this is the gap in it).
//!
//! That is why the two functions here exist rather than a paragraph in the
//! documentation telling people to wrap the call. The wrapping is not
//! optional, so it is not the caller's to remember.
//!
//! The Gate is a file-level `var` rather than something on the App because
//! there is one blocking pool and one memory controller per process, and two
//! Apps in one process hashing 8 each would be 16 — which is the number the
//! measurement says not to run. `limit` is set from `Options` by `listen`.

const std = @import("std");
const pw = @import("nilo_pw");
const bulkhead = @import("bulkhead.zig");
const Ctx = @import("ctx.zig").Ctx;

/// A stored password hash. Named here as well as in `nilo_pw` so that a
/// handler holding what `Ctx.hashPassword` returned does not have to import
/// the module to spell its type.
pub const Hash = pw.Hash;

/// How much work one hash is.
pub const Cost = pw.Cost;

/// How many hashes may run at once, process-wide. Opened at the default so
/// that a Ctx driven by a test with no `listen()` behind it still has a Gate
/// that works.
var gate: bulkhead.Gate = .open(default_at_once);

const default_at_once = 8;

/// Set the Gate from `Options`, called by `listen`.
///
/// The permits are replaced rather than adjusted, because this runs before
/// the socket opens and there is nobody waiting to lose a wakeup. A second
/// App in the same process listening with a different number is the last one
/// to call this, which is the honest outcome for a process-wide limit and is
/// said out loud in `Options`.
pub fn setLimit(at_once: u16) void {
    gate = .open(at_once);
}

/// Hash a password, off the loop and behind the Gate.
///
/// The salt comes from `Ctx.entropy` (ADR 0046) and the 19 MiB comes from
/// `gpa`, which is an argument because it is a number worth seeing at the
/// call site. The request arena is the wrong allocator for it: the arena is
/// reset per request keeping `arena_keep` bytes, and 19 MiB through it would
/// spend the one axis ADR 0018 treats as an invariant.
pub fn hash(c: *const Ctx, gpa: std.mem.Allocator, password: []const u8) !pw.Hash {
    return hashWith(.default, c, gpa, password);
}

/// The same, at a Cost of the caller's own.
pub fn hashWith(
    comptime cost: pw.Cost,
    c: *const Ctx,
    gpa: std.mem.Allocator,
    password: []const u8,
) !pw.Hash {
    // Before the Gate rather than after it: entropy is a trip to the blocking
    // pool of its own, and holding a permit across it would be holding one of
    // eight for a call that is not hashing anything.
    const salt = try c.entropy(pw.salt_len);

    try gate.enter();
    defer gate.leave();

    // The Cost is bound here rather than passed through `blocking`.
    // `std.meta.ArgsTuple` cannot describe a function with a comptime
    // parameter, so what crosses to the thread-pool worker has to be a
    // function whose Cost is already settled.
    const Bound = struct {
        fn run(
            gpa_: std.mem.Allocator,
            password_: []const u8,
            salt_: [pw.salt_len]u8,
        ) pw.Error!pw.Hash {
            return pw.hashWith(cost, gpa_, password_, salt_);
        }
    };
    return bulkhead.blocking(Bound.run, .{ gpa, password, salt });
}

/// Whether a password matches a stored hash, off the loop and behind the
/// Gate.
///
/// **`stored` is optional and null means there was no account.** It costs the
/// same as an account that exists, which is what stops a sign-in form
/// answering the question "is this address registered?" — see `nilo_pw` for
/// why that is the signature rather than a second function somebody has to
/// know about.
pub fn verify(
    c: *const Ctx,
    gpa: std.mem.Allocator,
    stored: ?[]const u8,
    password: []const u8,
) !bool {
    _ = c;
    try gate.enter();
    defer gate.leave();

    return bulkhead.blocking(pw.verify, .{ gpa, stored, password });
}

const testing = std.testing;
const App = @import("app.zig").App;
const nilo_testing = @import("testing.zig");

/// The Cost every test here uses: the floor rather than the default, because
/// the suite runs these on every `zig build test` in two optimize modes and
/// 19 MiB a time is not what that budget is for. What the default costs is a
/// measurement, and it lives in ADR 0048 rather than in a test.
const test_cost: pw.Cost = .{ .memory_kib = pw.Cost.floor_memory_kib, .passes = 1 };

fn signsInAndBackOut(c: *Ctx) anyerror!void {
    const gpa = testing.allocator;

    const stored = try hashWith(test_cost, c, gpa, "hunter2");

    if (!try verify(c, gpa, stored.text(), "hunter2")) return c.sendText(500, "right one failed");
    if (try verify(c, gpa, stored.text(), "hunter3")) return c.sendText(500, "wrong one passed");
    // No account at all, which is the signature that cannot be got wrong.
    if (try verify(c, gpa, null, "hunter2")) return c.sendText(500, "nobody passed");

    // Twice, because the salt comes from the Ctx and two hashes of one
    // password have to differ.
    const again = try hashWith(test_cost, c, gpa, "hunter2");
    if (std.mem.eql(u8, stored.text(), again.text())) return c.sendText(500, "same salt twice");

    try c.sendText(200, stored.text());
}

test "a handler can hash a password and check it again" {
    // Driven through a whole request rather than called directly, for the
    // reason the entropy test in `app.zig` is: what is being checked is that
    // the Gate, the blocking pool and `Ctx.entropy` all answer outside a
    // running server, so a handler that signs somebody in stays an ordinary
    // function (ADR 0003, ADR 0046).
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sign-in", signsInAndBackOut);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.post(&app, "/sign-in", "");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expect(std.mem.startsWith(u8, answer.body, "$argon2id$v=19$"));
}

test "the Gate lets its number through and puts the rest back in order" {
    // Uncontended, which is every test in this file and most requests: enter
    // and leave are a Mutex each way and never reach the parking half.
    var g: bulkhead.Gate = .open(2);
    try g.enter();
    try g.enter();
    g.leave();
    try g.enter();
    g.leave();
    g.leave();
}

test "a Gate of zero is a Gate of one rather than a deadlock" {
    var g: bulkhead.Gate = .open(0);
    try g.enter();
    g.leave();
}
