//! The one test in this module that cannot run without the Engine: a SQLite
//! pool wait, watched giving up.
//!
//! Everything under `zig build test-sql` runs on `std.Io.Threaded`, which
//! **cannot cancel a fiber** — so every `Limits` those tests hand a Wire is
//! `.off`, and a bound armed there has never fired. By
//! [ADR 0033](../docs/adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
//! that is the same standing as no bound at all, which is exactly what
//! `takeWriter` had before [ADR 0135](../docs/adr/0135-a-wait-for-a-connection-has-a-bound.md):
//! a `std.Io.Condition` with no deadline on it, and a fiber that queued for
//! the one writer waited for as long as the process lived.
//!
//! So this stands a real server up, sends a statement down the path a
//! **handler holding a transaction** takes when it writes `db.` where it meant
//! `tx.`, and watches `error.TimedOut` come back through the whole chain:
//! `Limits.arm` → `zio.AutoCancel` → the timer → the cancelled fiber →
//! `bound.fired()` → the error a caller actually sees. It is the same shape
//! and the same argument as `fetch/deadline.zig`.
//!
//! **No port is coordinated here.** The server asks for port 0 and nothing
//! ever connects: the work under test is a spawned fiber, which the server
//! starts once it is up (ADR 0086), so the three loopback ranges the other
//! live files keep apart do not gain a fourth.
//!
//! This file names `nilo_http`, which is upward, and `sql`'s row in the
//! `layers` table already carries the `in_tests` exception for `sql/db.zig`
//! (ADR 0042). It is deliberately not imported by `sql/sql.zig`'s test block:
//! if it were, `zig build test-sql` would need the Engine and the module's
//! tests would stop being runnable without one.

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const testing = std.testing;

/// One writer and one reader, and 300ms to queue for either.
///
/// `.in_fiber` because nothing here is waiting on SQLite to do work — the
/// statement under test never reaches SQLite at all. The wait being measured
/// is the queue in front of the writer, which parks the fiber whichever
/// `threading` is set (ADR 0073).
const Db = sql.Sqlite(.{ .threading = .in_fiber });

/// Quieten the log for one test.
///
/// `App.listen` warns that the root source file is missing
/// `std_options_debug_io`, which is right for a program and unsatisfiable in
/// a test binary — the root there is Zig's own test runner. `zig build`
/// prints a red `failed command:` line for any step that writes to stderr, so
/// leaving it would make a passing suite look like a failing one, which is
/// how a real failure went unread here for a fortnight once already.
///
/// It also hides the warning `gaveUp` writes, which is the one this test
/// provokes on purpose.
fn hush() void {
    std.testing.log_level = .err;
}

/// A fiber that holds the writer and then asks for it again.
///
/// `db.exec` rather than `tx.exec` is the whole scenario: one character, no
/// compile error, and on Postgres it merely runs outside the transaction —
/// there is a second pool connection to run it on. On SQLite there is exactly
/// one writer, this fiber is holding it, and before ADR 0135 the queue it
/// joined had no bound and nothing in the log.
const Attempt = struct {
    db: *Db,
    /// The name of the error that came back, or `answered` if none did.
    /// Written by the fiber on an executor thread and read by the test on its
    /// own, so the length is the flag and the bytes are published before it.
    name: [32]u8 = @splat(0),
    len: std.atomic.Value(usize) = .init(0),

    fn run(self: *Attempt) void {
        var scope: nilo.Run = .init(std.heap.smp_allocator);
        defer scope.deinit();

        var tx = self.db.begin(&scope, .{}) catch |err| return self.say(@errorName(err));
        defer tx.rollback();

        _ = self.db.exec(&scope, "CREATE TABLE IF NOT EXISTS held (a INTEGER)", .{}) catch |err|
            return self.say(@errorName(err));
        self.say("answered");
    }

    fn say(self: *Attempt, what: []const u8) void {
        const n = @min(what.len, self.name.len);
        @memcpy(self.name[0..n], what[0..n]);
        self.len.store(n, .release);
    }

    /// What came back, or null while the fiber is still in the queue.
    fn answer(self: *const Attempt) ?[]const u8 {
        const n = self.len.load(.acquire);
        return if (n == 0) null else self.name[0..n];
    }
};

/// The server under test, on a thread of its own.
///
/// `tryListen` does not return while the server is up, so "did it bind?"
/// cannot be read from its return value in time — the flag is what the
/// shutdown keys off, because calling `shutdown` on an App that never
/// listened has nothing to stop and would leave the join waiting forever.
const Serving = struct {
    app: *nilo.App,
    bound: std.atomic.Value(bool) = .init(true),

    fn run(self: *Serving) void {
        // Port 0 and one executor, for the reasons `http/live.zig` gives: the
        // work under test starts without being asked, so nothing needs to
        // know the port, and this step runs two optimize modes at once.
        self.app.tryListen(.{
            .port = 0,
            .threads = 1,
            .stop_on_signal = false,
        }) catch {
            self.bound.store(false, .release);
        };
    }
};

/// Wait for the fiber to have finished one way or the other, or give up.
///
/// Bounded rather than a plain spin: the failure this test guards against is
/// a wait that never ends, and a test for that which itself never ends is a
/// test nobody can read the result of. Five seconds against a 300ms bound.
fn waitForAnAnswer(attempt: *const Attempt) ![]const u8 {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    for (0..5_000) |_| {
        if (attempt.answer()) |name| return name;
        try std.Io.sleep(threaded.io(), .fromMilliseconds(1), .awake);
    }
    return error.TheQueueNeverGaveUp;
}

test "a fiber queueing for the writer it already holds gives up, rather than waiting forever" {
    hush();
    const gpa = std.heap.smp_allocator;

    var db: Db = .init(gpa, "file:deadline-test?mode=memory&cache=shared", .{
        .size = 2,
        // Short enough that a failing run is a failing run rather than a
        // build that looks stuck, and long enough that a loaded machine does
        // not report a timeout the code did not cause.
        .timeout_ms = 300,
    });
    defer db.deinit();

    var attempt: Attempt = .{ .db = &db };

    var app = nilo.App.init(gpa);
    defer app.deinit();
    // `provide` before `spawn` for no reason but reading order: the App
    // starts services first either way (ADR 0079), which is what hands this
    // `Db` the Engine's `Limits` and is half of what is being tested.
    try app.provide(&db);
    try app.spawn(Attempt.run, .{&attempt});

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }

    // The whole chain in one string: the pool's own timer fired, the fiber
    // was cancelled, `bound.fired()` said the cancellation was this wait's
    // own, and the caller was handed a timeout rather than a shutdown.
    try testing.expectEqualStrings("TimedOut", try waitForAnAnswer(&attempt));
    try testing.expect(serving.bound.load(.acquire));
}
