//! The one test that cannot run without the Engine, and the first test in this
//! repository that opens a real port.
//!
//! `fetch/live.zig` proves the Fitting layer's entry condition and pays for it:
//! `std.Io.Threaded` cannot cancel a fiber, so everything there runs against
//! `Limits.off` and **no deadline it arms has ever fired**. By
//! [ADR 032](../docs/adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
//! that made the timeout a guard only ever seen to pass, which is the same as
//! no guard at all.
//!
//! So this stands a real server up on a real socket, points a handler at an
//! endpoint that accepts and then says nothing, and watches
//! `error.TimedOut` come back through
//! [ADR 056](../docs/adr/056-the-way-out-was-open-the-clock-was-not.md)'s
//! whole chain: `Limits.arm` → `zio.AutoCancel` → the timer → the cancelled
//! fiber → `bound.fired()` → the error a caller actually sees.
//!
//! **This file names `nilo_http`, which is upward**, and that is why `fetch`'s
//! row in the `layers` table carries an `in_tests` entry — the same exception
//! `sql/db.zig` already has, and with the same weakness: the layering step
//! cannot see that the import is only reached from a test.
//!
//! It is deliberately *not* imported by `fetch/fetch.zig`'s `test` block. If it
//! were, `zig test fetch/fetch.zig` would need the Engine and the layer's entry
//! condition would be gone. It has a build step of its own instead.

const std = @import("std");
const nilo = @import("nilo_http");
const fetch = @import("nilo_fetch");

/// Quieten the log for one test, and the reason it has to be done this way is
/// worth the four lines.
///
/// `App.listen` warns when its root source file is missing
/// `std_options_debug_io` or `std_options`, which is right for a program and
/// **unsatisfiable in a test**: the root of a test binary is Zig's own
/// `test_runner.zig`, so no declaration in this file or any other can be the
/// one it looks for. The warnings are therefore correct, unavoidable, and
/// about a root nobody deploys.
///
/// They still cost something, because `zig build` prints a red
/// `failed command:` line for any step that writes to stderr — so a passing
/// suite looked like a failing one, which is how a real failure went unread
/// here for a fortnight. The test runner's own log function checks
/// `std.testing.log_level` and resets it to `.warn` before each test, so this
/// is scoped to the test that calls it and nothing else.
fn hushStartupWiring() void {
    std.testing.log_level = .err;
}

const testing = std.testing;

// `listen()` warns twice here about the two root-file lines being missing, and
// **that cannot be fixed from this file**: in a test binary the root is the
// compiler's test runner, which declares `std_options` itself. Declaring them
// here changes nothing. The warnings are noise in this one place and correct
// everywhere a user will see them, which is the trade to keep.

/// An endpoint that accepts a connection, reads the request, and then says
/// nothing at all for as long as the test needs. What every deadline in every
/// HTTP client is actually for, and what no test here has ever staged.
const Quiet = struct {
    port: u16 = 0,
    ready: std.atomic.Value(bool) = .init(false),
    /// Set instead of `ready` when the scan below found no free port.
    ///
    /// **Without this the test hung rather than failed.** The scan gave up by
    /// returning, `ready` stayed false, and the loop waiting on it had no
    /// bound — so a run that could not get a port sat there for as long as
    /// anybody let it, burning no CPU, which is the shape `CLAUDE.md` warns
    /// is the perfect hiding place for a deadlock. Reproduced by running this
    /// binary six times at once: 200 ports is not many when the range is
    /// shared with every other copy and with everything in TIME_WAIT.
    no_port: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    /// What to say before going quiet. `nothing` is the endpoint above;
    /// the other two are for the silence clock (ADR 056): a head and three
    /// bytes of a ten-byte body and then nothing, or the whole body one
    /// byte every 60 ms, which is slow and is not silence.
    answer: enum { nothing, head_then_stall, trickle } = .nothing,

    /// Connect once, so `run`'s `accept` returns and the thread can be joined.
    ///
    /// **This is the third deadlock in this struct and it is six lines below
    /// the second.** `done` bounds the sleep loop at the *bottom* of `run`. It
    /// does not bound the `accept` above it, and nothing in this file ever
    /// connects here directly — the test's own request goes to the nilo server,
    /// which is what then dials this one. So any failure before that request
    /// leaves `run` parked in `accept` with `done` set and nobody left to read
    /// it, and the `join` in the teardown waits for a thread that is never
    /// coming back. The suite hangs instead of reporting the failure that
    /// caused it, which is strictly worse than the failure.
    ///
    /// Reached for real by running `bench/mem.py` first: 50,000 loopback
    /// connections leave the ephemeral range full of TIME_WAIT, the nilo server
    /// below could not bind, and `zig build test` sat at ten minutes of wall
    /// clock against **zero** of CPU — the one command `CLAUDE.md` says settles
    /// that, `ps -o etime,cputime -C zig`, is what found it.
    ///
    /// A self-connect rather than a deadline on the `accept`, because the
    /// teardown already knows the port and this needs no clock to be right.
    fn knock(self: *Quiet) void {
        if (!self.ready.load(.acquire)) return;
        var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        var stream = address.connect(io, .{ .mode = .stream }) catch return;
        stream.close(io);
    }

    fn run(self: *Quiet) void {
        var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var candidate: u16 = 39_500;
        var server: std.Io.net.Server = while (candidate < 39_700) : (candidate += 1) {
            const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(candidate) };
            break address.listen(io, .{}) catch continue;
        } else {
            self.no_port.store(true, .release);
            return;
        };
        defer server.socket.close(io);

        self.port = candidate;
        self.ready.store(true, .release);

        var stream = server.accept(io) catch return;
        defer stream.close(io);

        // Read whatever arrives and answer none of it. The connection stays
        // open, which is the case a per-read timeout would miss and a
        // whole-call deadline catches.
        var buf: [1024]u8 = undefined;
        var reader = stream.reader(io, &buf);
        _ = reader.interface.takeDelimiterInclusive('\n') catch {};

        var out: [256]u8 = undefined;
        var writer = stream.writer(io, &out);
        const w = &writer.interface;
        switch (self.answer) {
            .nothing => {},
            .head_then_stall => {
                w.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nxxx") catch return;
                w.flush() catch return;
            },
            .trickle => {
                w.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 24\r\n\r\n") catch return;
                w.flush() catch return;
                for (0..24) |_| {
                    std.Io.sleep(io, .fromMilliseconds(60), .awake) catch return;
                    w.writeByte('x') catch return;
                    w.flush() catch return;
                }
            },
        }

        while (!self.done.load(.acquire)) {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch break;
        }
    }
};

/// Where the handler below points. Filled in before `listen()`, read on the
/// event loop — a global because a handler takes its arguments by type and
/// there is nowhere else for a test fixture to live.
var quiet_url: []const u8 = "";

/// Calls the quiet endpoint with a deadline far shorter than it will ever
/// answer in, and reports what came back **as text**, so the assertion is on
/// the name of the error a real caller would get rather than on a bool.
fn callQuiet(api: *fetch.Client, c: *nilo.Ctx) !nilo.Str {
    const res = api.get(c, quiet_url, .{ .timeout_ms = 200 }) catch |err| {
        return c.str(@errorName(err));
    };
    _ = res;
    return c.str("answered");
}

/// The trickle's call: no ceiling on the call and a second on silence.
///
/// A second rather than the 200 ms `callPatient` gives a stall, because the
/// gaps here are the server's `sleep(60)`, and on a loaded CI machine a sleep
/// is a request, not a promise: on the macOS runner, with every test binary of
/// `zig build test` running at once, 60 ms sleeps were measured at 67 to
/// 135 ms and went past 200 often enough to fail this test on every run.
/// Twenty-four bytes keep the body longer than the bound, which is what the
/// test proves: a timer armed once at `begin` would still fire before the end.
fn callTrickle(api: *fetch.Client, c: *nilo.Ctx) !nilo.Str {
    const res = api.get(c, quiet_url, .{ .timeout_ms = 0, .stall_ms = 1000 }) catch |err| {
        return c.str(@errorName(err));
    };
    return res.body;
}

/// The same call with no ceiling on the call at all and 200 ms on silence
/// inside it, the download's shape (ADR 056). Reports the body when it
/// arrives, so the trickle test can see the whole of it came.
fn callPatient(api: *fetch.Client, c: *nilo.Ctx) !nilo.Str {
    const res = api.get(c, quiet_url, .{ .timeout_ms = 0, .stall_ms = 200 }) catch |err| {
        return c.str(@errorName(err));
    };
    return res.body;
}

/// What a call reports when it is timed against the clock: the error's name,
/// and `fast` or `slow` by whether it came back inside two seconds. The
/// calls below all have a bound of their own of twenty seconds or more (or
/// 200 ms where the test says), so `fast` can only be the route's deadline
/// or the call's own, whichever the test is staging (ADR 105).
fn timed(c: anytype, api: *fetch.Client, own_ms: u32) !nilo.Str {
    const began = nilo.nowMillis();
    const verdict: []const u8 = if (api.get(c, quiet_url, .{ .timeout_ms = own_ms })) |_| "answered" else |err| @errorName(err);
    const pace: []const u8 = if (nilo.nowMillis() - began < 2_000) "fast" else "slow";
    return c.str(try std.fmt.allocPrint(c.arena(), "{s} {s}", .{ verdict, pace }));
}

/// A route that gave itself 400 ms and a call that would have waited twenty
/// seconds. The deadline is taken off before the answer is written, because
/// a spent one would also bound the write of this very response.
fn callUnderRouteDeadline(api: *fetch.Client, c: *nilo.Ctx) !nilo.Str {
    c.giveDeadline(400);
    const out = try timed(c, api, 20_000);
    c.giveDeadline(0);
    return out;
}

/// A route whose deadline is longer than the call's own bound: the call's
/// 200 ms is the shorter, and the route's ten seconds changes nothing.
fn callUnderLongerDeadline(api: *fetch.Client, c: *nilo.Ctx) !nilo.Str {
    c.giveDeadline(10_000);
    const out = try timed(c, api, 200);
    c.giveDeadline(0);
    return out;
}

/// A route whose time is already gone when it calls out.
fn callAfterDeadline(api: *fetch.Client, c: *nilo.Ctx) !nilo.Str {
    c.giveDeadline(1);
    while (!c.overdue()) std.atomic.spinLoopHint();
    const out = try timed(c, api, 20_000);
    c.giveDeadline(0);
    return out;
}

/// A `Run` has no deadline to declare, so the call keeps its own 200 ms
/// even in a handler that has set one: the Run is not the request.
fn callFromARun(api: *fetch.Client, c: *nilo.Ctx) !nilo.Str {
    c.giveDeadline(60);
    var run = nilo.Run.init(std.heap.smp_allocator);
    defer run.deinit();
    const began = nilo.nowMillis();
    const verdict: []const u8 = if (api.get(&run, quiet_url, .{ .timeout_ms = 200 })) |_| "answered" else |err| @errorName(err);
    const waited = nilo.nowMillis() - began;
    c.giveDeadline(0);
    return c.str(try std.fmt.allocPrint(c.arena(), "{s} {s}", .{ verdict, if (waited >= 150) "own" else "early" }));
}

/// When the permit below went back, for the call that queued for it to
/// compare itself with.
var permit_back_ms: std.atomic.Value(i64) = .init(0);

/// Holds the client's only permit for a second: a call begun and left open.
/// Its own bound is what ends the body `end` has to read past on the
/// endpoint that trickles, so the permit is back by 1.4 s at the latest.
fn holdPermit(api: *fetch.Client, c: *nilo.Ctx) !nilo.Str {
    var ex: fetch.Exchange = .idle;
    _ = ex.begin(api, .{ .method = .GET, .url = quiet_url, .timeout_ms = 1_400 }) catch |err| return c.str(@errorName(err));
    nilo.sleep(1_000) catch {};
    ex.end();
    permit_back_ms.store(nilo.nowMillis(), .release);
    return c.str("held");
}

/// A route with 500 ms that queues for the permit above until it is back, long
/// after its time is gone. The time in the queue is spent: the call must be
/// refused the moment it is let in, where a time counted from then would
/// dial and wait another 500 ms, and the quiet endpoint never sees it.
fn callQueued(api: *fetch.Client, c: *nilo.Ctx) !nilo.Str {
    c.giveDeadline(500);
    const verdict: []const u8 = if (api.get(c, quiet_url, .{ .timeout_ms = 20_000 })) |_| "answered" else |err| @errorName(err);
    const after = nilo.nowMillis() - permit_back_ms.load(.acquire);
    c.giveDeadline(0);
    return c.str(try std.fmt.allocPrint(c.arena(), "{s} {s}", .{ verdict, if (after < 250) "at once" else "late" }));
}

/// The nilo server under test, on a thread of its own, plus whether it ever
/// got its port. `tryListen` blocks for the life of the server when it
/// succeeds, so "did it bind?" cannot be read from the return value in time —
/// the flag is what the shutdown below keys off, because calling `shutdown` on
/// an App that never listened has nothing to stop.
const Serving = struct {
    app: *nilo.App,
    port: u16,
    bound: std.atomic.Value(bool) = .init(false),

    fn run(self: *Serving) void {
        self.bound.store(true, .release);
        self.app.tryListen(.{ .port = self.port, .stop_on_signal = false }) catch {
            self.bound.store(false, .release);
        };
    }
};

/// The whole staging, once per test: a quiet endpoint of the given kind on
/// its own thread, a nilo server on another with `handler` at `route`, one
/// request through it, and what the handler reported as text.
fn drive(comptime answer: @FieldType(Quiet, "answer"), comptime route: []const u8, comptime handler: anytype) ![]u8 {
    hushStartupWiring();
    const gpa = std.heap.smp_allocator;

    var quiet: Quiet = .{ .answer = answer };
    const quiet_thread = try std.Thread.spawn(.{}, Quiet.run, .{&quiet});
    defer {
        // `done` first, so that once `knock` frees the `accept` the loop below
        // it reads a flag that is already set and the thread goes.
        quiet.done.store(true, .release);
        quiet.knock();
        quiet_thread.join();
    }

    // The listener has to be up before a URL can name it — and the wait is
    // bounded, because the two ways it can never come up are both real: no
    // free port in the range, and a thread that has not been scheduled yet.
    // Five seconds of 1ms sleeps, then a failure that says which.
    var waiting: std.Io.Threaded = .init(gpa, .{});
    defer waiting.deinit();
    for (0..5_000) |_| {
        if (quiet.ready.load(.acquire)) break;
        if (quiet.no_port.load(.acquire)) return error.NoFreePortForTheQuietEndpoint;
        try std.Io.sleep(waiting.io(), .fromMilliseconds(1), .awake);
    } else return error.QuietEndpointNeverCameUp;

    var url_buf: [64]u8 = undefined;
    quiet_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{quiet.port});

    var api: fetch.Client = .init(gpa, .{});
    defer api.deinit();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.provide(&api);
    try app.get(route, handler);

    // Derived from the port `Quiet` scanned its way to rather than fixed,
    // because `zig build test-fetch-engine` runs Debug and ReleaseSafe **at
    // the same time** and two processes on one hard-coded port is a test that
    // hangs on a machine and passes on the one it was written on. The offset
    // clears `Quiet`'s own range, so the two never collide either.
    var serving: Serving = .{ .app = &app, .port = quiet.port + 200 };
    const app_thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        app_thread.join();
    }

    return askOnce(gpa, serving.port, route);
}

test "an endpoint that never answers is given up on, and says which clock did it" {
    const body = try drive(.nothing, "/call", callQuiet);
    defer std.heap.smp_allocator.free(body);

    // The whole chain, in one string: the timer fired, the fiber was
    // cancelled, `bound.fired()` said the cancellation was this call's own,
    // and the handler was handed a timeout rather than a shutdown.
    try testing.expectEqualStrings("TimedOut", body);
}

test "silence inside a call with no ceiling is a stall, under the Engine's timer" {
    const body = try drive(.head_then_stall, "/stall", callPatient);
    defer std.heap.smp_allocator.free(body);

    // The same timer as above, armed for the other bound: a head and three
    // bytes came, then nothing for 200 ms, and the fiber was cancelled with
    // `stall_armed` saying which clock it was (ADR 056).
    try testing.expectEqualStrings("Stalled", body);
}

test "a body that trickles under the Engine is re-armed on every byte and never stalls" {
    const body = try drive(.trickle, "/trickle", callTrickle);
    defer std.heap.smp_allocator.free(body);

    // 1.44 s of body under a one-second silence bound: a timer armed once at
    // `begin` would have fired at one second, and one re-armed by each chunk
    // never does. The whole body coming back is the proof of the re-arm.
    try testing.expectEqualStrings(&@as([24]u8, @splat('x')), body);
}

test "a call made under a route's deadline gives up when the route's time does, not when its own bound would" {
    const body = try drive(.nothing, "/route", callUnderRouteDeadline);
    defer std.heap.smp_allocator.free(body);

    // Twenty seconds of its own, 400 ms of the route's: the answer came back
    // inside two seconds as a timeout, which only the route's bound can have
    // done (ADR 105).
    try testing.expectEqualStrings("TimedOut fast", body);
}

test "a route deadline longer than the call's own bound leaves the call's bound alone" {
    const body = try drive(.nothing, "/longer", callUnderLongerDeadline);
    defer std.heap.smp_allocator.free(body);

    try testing.expectEqualStrings("TimedOut fast", body);
}

test "a call from a route whose deadline has already passed fails at once" {
    const body = try drive(.nothing, "/spent", callAfterDeadline);
    defer std.heap.smp_allocator.free(body);

    try testing.expectEqualStrings("TimedOut fast", body);
}

test "a Run keeps the call's own bound, whatever deadline the request around it has" {
    const body = try drive(.nothing, "/run", callFromARun);
    defer std.heap.smp_allocator.free(body);

    // The request had 60 ms and the Run did not know: the call waited its
    // own 200 ms.
    try testing.expectEqualStrings("TimedOut own", body);
}

test "a call that queued for a permit past its route's deadline is refused and never dialled" {
    hushStartupWiring();
    const gpa = std.heap.smp_allocator;

    var quiet: Quiet = .{ .answer = .head_then_stall };
    const quiet_thread = try std.Thread.spawn(.{}, Quiet.run, .{&quiet});
    defer {
        quiet.done.store(true, .release);
        quiet.knock();
        quiet_thread.join();
    }
    var waiting: std.Io.Threaded = .init(gpa, .{});
    defer waiting.deinit();
    for (0..5_000) |_| {
        if (quiet.ready.load(.acquire)) break;
        if (quiet.no_port.load(.acquire)) return error.NoFreePortForTheQuietEndpoint;
        try std.Io.sleep(waiting.io(), .fromMilliseconds(1), .awake);
    } else return error.QuietEndpointNeverCameUp;

    var url_buf: [64]u8 = undefined;
    quiet_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{quiet.port});

    var api: fetch.Client = .init(gpa, .{ .max_in_flight = 1 });
    defer api.deinit();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.provide(&api);
    try app.get("/hold", holdPermit);
    try app.get("/queued", callQueued);

    var serving: Serving = .{ .app = &app, .port = quiet.port + 200 };
    const app_thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        app_thread.join();
    }

    const Holder = struct {
        fn run(port: u16) void {
            const body = askOnce(std.heap.smp_allocator, port, "/hold") catch return;
            std.heap.smp_allocator.free(body);
        }
    };
    const holder = try std.Thread.spawn(.{}, Holder.run, .{serving.port});
    defer holder.join();
    // Let the holder take the permit before the queued call asks.
    try std.Io.sleep(waiting.io(), .fromMilliseconds(300), .awake);

    const body = try askOnce(gpa, serving.port, "/queued");
    defer gpa.free(body);
    try testing.expectEqualStrings("TimedOut at once", body);
}

// ---- the WebSocket client against nilo's own server (ADR 281) ----
//
// The client's tests in `websocket_live.zig` run against a canned server on
// `std.Io.Threaded`. What they cannot show is the two things that need the
// other half of the repository: that the client and the server agree about
// the wire, which is `core.ws_frame` under both and is still worth watching
// meet, and that the two clocks the client arms (silence, and the wait for a
// close) fire under the Engine's timer as they do under a task of `Io`, which
// is the thing ADR 032 says has to be seen.

/// The port the server below listens on, for the handlers that dial it.
var ws_port: u16 = 0;

fn wsEchoLoop(socket: *nilo.Socket) !void {
    while (try socket.receive()) |message| try socket.send(message.kind, message.data);
}

fn wsEcho(c: *nilo.Ctx) !void {
    return c.upgradeWith(wsEchoLoop, {}, .{ .idle_ms = 0, .max_message = 1 << 20 });
}

/// Reads and answers nothing, so a client waiting for a message waits.
fn wsQuietLoop(socket: *nilo.Socket) !void {
    while (try socket.receive()) |_| {}
}

fn wsQuiet(c: *nilo.Ctx) !void {
    return c.upgradeWith(wsQuietLoop, {}, .{ .idle_ms = 0 });
}

/// Never reads, so a close frame sent to it is never answered.
fn wsDeafLoop(_: *nilo.Socket) !void {
    nilo.sleep(2_000) catch {};
}

fn wsDeaf(c: *nilo.Ctx) !void {
    return c.upgradeWith(wsDeafLoop, {}, .{ .idle_ms = 0 });
}

fn wsUrl(buf: []u8, route: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "ws://127.0.0.1:{d}{s}", .{ ws_port, route });
}

/// A text message, a binary one and one of 40,000 bytes out of this handler
/// and back through the server's loop, then a close the server echoes.
fn callWsEcho(api: *fetch.Client, c: *nilo.Ctx) !nilo.Str {
    var url_buf: [64]u8 = undefined;
    var ws: fetch.WebSocket = .idle;
    defer ws.deinit();
    ws.open(api, c, try wsUrl(&url_buf, "/echo"), .{}) catch |err| return c.str(@errorName(err));

    try ws.sendText("hello");
    const text = (try ws.receive()) orelse return c.str("ended");
    const text_ok = text.kind == .text and std.mem.eql(u8, text.data, "hello");

    try ws.sendBinary("\x00\x01\x02");
    const binary = (try ws.receive()) orelse return c.str("ended");
    const binary_ok = binary.kind == .binary and std.mem.eql(u8, binary.data, "\x00\x01\x02");

    const big = try c.arena().alloc(u8, 40_000);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try ws.sendBinary(big);
    const echoed = (try ws.receive()) orelse return c.str("ended");
    const big_ok = std.mem.eql(u8, echoed.data, big);

    const closed = ws.close(.normal, "done");
    return c.str(try std.fmt.allocPrint(c.arena(), "{s} {s} {s} {s} {s}", .{
        if (text_ok) "text" else "BAD",
        if (binary_ok) "binary" else "BAD",
        if (big_ok) "big" else "BAD",
        @tagName(closed),
        if (ws.closedCleanly()) "clean" else "unclean",
    }));
}

/// A socket that never hears anything, with 200 ms of patience: the Engine's
/// timer is what ends the wait, and the error is the silence bound's.
fn callWsQuiet(api: *fetch.Client, c: *nilo.Ctx) !nilo.Str {
    var url_buf: [64]u8 = undefined;
    var ws: fetch.WebSocket = .idle;
    defer ws.deinit();
    ws.open(api, c, try wsUrl(&url_buf, "/quiet"), .{ .idle_ms = 200 }) catch |err| return c.str(@errorName(err));
    const began = nilo.nowMillis();
    const verdict: []const u8 = if (ws.receive()) |_| "message" else |err| @errorName(err);
    const pace: []const u8 = if (nilo.nowMillis() - began < 2_000) "fast" else "slow";
    return c.str(try std.fmt.allocPrint(c.arena(), "{s} {s}", .{ verdict, pace }));
}

/// A close the far end never answers, with 200 ms to wait for it.
fn callWsDeaf(api: *fetch.Client, c: *nilo.Ctx) !nilo.Str {
    var url_buf: [64]u8 = undefined;
    var ws: fetch.WebSocket = .idle;
    defer ws.deinit();
    ws.open(api, c, try wsUrl(&url_buf, "/deaf"), .{ .close_timeout_ms = 200 }) catch |err| return c.str(@errorName(err));
    const began = nilo.nowMillis();
    const closed = ws.close(.normal, "");
    const pace: []const u8 = if (nilo.nowMillis() - began < 1_500) "fast" else "slow";
    return c.str(try std.fmt.allocPrint(c.arena(), "{s} {s}", .{ @tagName(closed), pace }));
}

/// A server with the three socket routes and the one client route asked for,
/// one request to the client route, and what its handler reported.
fn driveWs(comptime route: []const u8, comptime handler: anytype) ![]u8 {
    hushStartupWiring();
    const gpa = std.heap.smp_allocator;

    var api: fetch.Client = .init(gpa, .{});
    defer api.deinit();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.provide(&api);
    try app.get("/echo", wsEcho);
    try app.get("/quiet", wsQuiet);
    try app.get("/deaf", wsDeaf);
    try app.get(route, handler);

    // A free port, found by asking, and in a range of its own: Debug and
    // ReleaseSafe run at the same time, and `Quiet` takes 39,500 and up.
    var probe: std.Io.Threaded = .init(gpa, .{});
    defer probe.deinit();
    var port: u16 = 41_000 + @as(u16, @intCast(std.Thread.getCurrentId() % 400)) * 2;
    while (port < 42_000) : (port += 1) {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        var server = address.listen(probe.io(), .{}) catch continue;
        server.deinit(probe.io());
        break;
    } else return error.NoFreePortForTheWebSocketServer;
    ws_port = port;

    var serving: Serving = .{ .app = &app, .port = port };
    const app_thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        app_thread.join();
    }
    return askOnce(gpa, serving.port, route);
}

test "the client and the server speak the same wire, and the close is acknowledged" {
    const body = try driveWs("/call", callWsEcho);
    defer std.heap.smp_allocator.free(body);
    try testing.expectEqualStrings("text binary big acknowledged clean", body);
}

test "a socket that goes quiet is stalled by the Engine's timer, and says so" {
    const body = try driveWs("/call", callWsQuiet);
    defer std.heap.smp_allocator.free(body);
    try testing.expectEqualStrings("Stalled fast", body);
}

test "a close nobody answers is given up on by the Engine's timer, after the time it was given" {
    const body = try driveWs("/call", callWsDeaf);
    defer std.heap.smp_allocator.free(body);
    try testing.expectEqualStrings("timed_out fast", body);
}

/// One request over a real socket, from a thread that is not the Engine's.
///
/// `nilo.testing.Client` cannot be used here: it drives `App.handleRequest`
/// against in-memory buffers, and a handler running there has no event loop to
/// arm a deadline on — which is the whole thing being tested.
fn askOnce(gpa: std.mem.Allocator, port: u16, target: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };

    // The server is coming up on another thread, so the first connections may
    // arrive before the port is taken.
    var stream: std.Io.net.Stream = for (0..200) |_| {
        break address.connect(io, .{ .mode = .stream }) catch {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        };
    } else return error.ServerNeverCameUp;
    defer stream.close(io);

    var out_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    try writer.interface.print(
        "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        .{target},
    );
    try writer.interface.flush();

    var in_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var whole: std.Io.Writer.Allocating = .init(gpa);
    defer whole.deinit();
    _ = reader.interface.streamRemaining(&whole.writer) catch {};

    const text = whole.written();
    const split = std.mem.indexOf(u8, text, "\r\n\r\n") orelse return error.NoBody;
    return gpa.dupe(u8, text[split + 4 ..]);
}
