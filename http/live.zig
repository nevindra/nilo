//! The tests that need a server that is actually running.
//!
//! Almost every HTTP behaviour here is tested against in-memory buffers with
//! no server at all, which is what `App.handleRequest` taking only a Reader
//! and a Writer buys. Work that is not a request cannot be tested that way:
//! it exists precisely because there is a server, it is owned by the group
//! the Engine's accept loop runs its connections in, and outside one
//! `nilo.spawn` answers `error.NoServer` by design
//! ([ADR 0029](../docs/adr/0029-a-spawned-fiber-belongs-to-the-server.md)).
//!
//! [ADR 0033](../docs/adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
//! is why this file exists rather than a unit test asserting that a list has
//! one entry in it: a registration nothing has ever been seen to *run* is not
//! evidence that anything runs.
//!
//! **The port is 0 and there is no client here.** The whole point of the
//! feature is that it starts without being asked, so nothing in this file
//! ever connects — which means nothing has to know the port, and two
//! optimize modes running this suite at the same time cannot collide.
//! `fetch/deadline.zig` scans for a free port and derives a second one from
//! it because it has a request to make; this has none.

const std = @import("std");
const nilo = @import("http.zig");
const bulkhead = @import("bulkhead.zig");

const testing = std.testing;

/// Quieten the log for one test.
///
/// `App.listen` warns when the root source file is missing
/// `std_options_debug_io`, which is right for a program and **unsatisfiable
/// in a test**: the root of a test binary is Zig's own `test_runner.zig`, so
/// no declaration anywhere in this repository can be the one it looks for.
///
/// The warnings still cost something, because `zig build` prints a red
/// `failed command:` line for any step that writes to stderr — so a passing
/// suite looks like a failing one, which is how a real failure went unread
/// for a fortnight once already. The test runner resets `log_level` before
/// each test, so this is scoped to the test that calls it.
fn hush() void {
    std.testing.log_level = .err;
}

/// What a spawned fiber does, and what the test reads afterwards.
///
/// Atomics rather than plain fields because the fiber runs on one of the
/// Engine's executor threads and the assertions run on the test's own.
const Ticker = struct {
    /// How many times round the loop. The assertion is `>= 1`, never an exact
    /// count: how many 5ms ticks fit into the window before the test notices
    /// the first one is a property of the machine, not of nilo.
    ticks: std.atomic.Value(u32) = .init(0),
    /// Set when the wait came back cancelled, which is the shutdown reaching
    /// it — the one signal that says this fiber belongs to the server.
    canceled: std.atomic.Value(bool) = .init(false),

    fn run(self: *Ticker) void {
        while (true) {
            nilo.sleep(5) catch {
                self.canceled.store(true, .release);
                return;
            };
            _ = self.ticks.fetchAdd(1, .monotonic);
        }
    }
};

/// The server under test, on a thread of its own.
///
/// `tryListen` does not return while the server is up, so "did it bind?"
/// cannot be read from its return value in time. The flag is what the
/// shutdown keys off: calling `shutdown` on an App that never listened has
/// nothing to stop and would leave the join below waiting forever.
const Serving = struct {
    app: *nilo.App,
    bound: std.atomic.Value(bool) = .init(true),

    fn run(self: *Serving) void {
        // Port 0: the operating system picks a free one. Nothing here
        // connects, so nobody needs to know which. The default address is
        // already loopback, so the test is not reachable from the network
        // for the second it is up.
        //
        // One executor, not the default of one per core. Nothing here serves
        // a request, so the threads would buy nothing — and this suite runs
        // two optimize modes and `test-fetch-engine` at the same time, where
        // three runtimes each taking every core is load that lands on
        // somebody else's timing rather than on ours.
        self.app.tryListen(.{
            .port = 0,
            .threads = 1,
            .stop_on_signal = false,
        }) catch {
            self.bound.store(false, .release);
        };
    }
};

/// Wait for `ticker` to have run, or give up.
///
/// Bounded rather than a plain spin, because the failure this guards against
/// is work that never starts — and a test for that which hangs is a test
/// nobody can read the result of. Two seconds is four hundred 5ms ticks.
fn waitForATick(ticker: *const Ticker) !void {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    for (0..2000) |_| {
        if (ticker.ticks.load(.monotonic) >= 1) return;
        try std.Io.sleep(threaded.io(), .fromMilliseconds(1), .awake);
    }
    return error.BackgroundWorkNeverRan;
}

test "work registered before the server runs once the server is up" {
    hush();
    const gpa = std.heap.smp_allocator;

    var ticker: Ticker = .{};

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.spawn(Ticker.run, .{&ticker});

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }

    try waitForATick(&ticker);
    try testing.expect(serving.bound.load(.acquire));
}

test "work registered before the server still runs when the services were started first" {
    hush();
    const gpa = std.heap.smp_allocator;

    var ticker: Ticker = .{};

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.spawn(Ticker.run, .{&ticker});

    // The order `guide/sql.md` recommends and ADR 0079 built: the services
    // are finished with an `Io` of the caller's own so that a migration can
    // run, and only then does the server start. `startServices` is skipped
    // the second time round, and **this is the case that used to take the
    // background work down with it** — the whole reason the two guards in
    // `App` are separate flags (ADR 0086).
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try app.start(threaded.io());

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }

    try waitForATick(&ticker);
    try testing.expect(serving.bound.load(.acquire));
}

test "the shutdown reaches a fiber that is not serving anybody" {
    hush();
    const gpa = std.heap.smp_allocator;

    var ticker: Ticker = .{};

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.spawn(Ticker.run, .{&ticker});

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});

    // The wait's result is held rather than propagated, because the thread
    // has to be joined either way: returning early here would run
    // `app.deinit()` under a server still using it.
    const ticked = waitForATick(&ticker);
    app.shutdown();
    thread.join();
    try ticked;

    // `tryListen` has returned, which means the grace period is over and the
    // group has been cancelled. A fiber parked in `sleep` finds out as
    // `error.Canceled`, which is the same answer a handler gets and the
    // reason the shape of this work is a loop around a wait that can say no.
    try testing.expect(ticker.canceled.load(.acquire));
}

test "spawning with no server says so, and the App is what remembers instead" {
    // `nilo.spawn` is "now" and there is no now: nothing is listening, so
    // there is no group to be owned by and no shutdown to be cut off by.
    // `app.spawn` is the same work registered rather than started, so it
    // costs nothing here and is not an error.
    var app = nilo.App.init(testing.allocator);
    defer app.deinit();

    var ticker: Ticker = .{};
    try testing.expectError(error.NoServer, bulkhead.spawn(Ticker.run, .{&ticker}));
    try app.spawn(Ticker.run, .{&ticker});
    try testing.expectEqual(@as(u32, 0), ticker.ticks.load(.monotonic));
}
