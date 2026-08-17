//! The one test that cannot run without the Engine, and the first test in this
//! repository that opens a real port.
//!
//! `fetch/live.zig` proves the Fitting layer's entry condition and pays for it:
//! `std.Io.Threaded` cannot cancel a fiber, so everything there runs against
//! `Limits.off` and **no deadline it arms has ever fired**. By
//! [ADR 0033](../docs/adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
//! that made the timeout a guard only ever seen to pass, which is the same as
//! no guard at all.
//!
//! So this stands a real server up on a real socket, points a handler at an
//! endpoint that accepts and then says nothing, and watches
//! `error.TimedOut` come back through
//! [ADR 0065](../docs/adr/0065-the-way-out-was-open-the-clock-was-not.md)'s
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
const fetch = @import("fetch.zig");

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
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Quiet) void {
        var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var candidate: u16 = 39_500;
        var server: std.Io.net.Server = while (candidate < 39_700) : (candidate += 1) {
            const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(candidate) };
            break address.listen(io, .{}) catch continue;
        } else return;
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

test "an endpoint that never answers is given up on, and says which clock did it" {
    hushStartupWiring();
    const gpa = std.heap.smp_allocator;

    var quiet: Quiet = .{};
    const quiet_thread = try std.Thread.spawn(.{}, Quiet.run, .{&quiet});
    defer {
        quiet.done.store(true, .release);
        quiet_thread.join();
    }

    // The listener has to be up before a URL can name it.
    var waiting: std.Io.Threaded = .init(gpa, .{});
    defer waiting.deinit();
    while (!quiet.ready.load(.acquire)) {
        try std.Io.sleep(waiting.io(), .fromMilliseconds(1), .awake);
    }

    var url_buf: [64]u8 = undefined;
    quiet_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{quiet.port});

    var api: fetch.Client = .init(gpa, .{});
    defer api.deinit();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.provide(&api);
    try app.get("/call", callQuiet);

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

    const body = try askOnce(gpa, serving.port, "/call");
    defer gpa.free(body);

    // The whole chain, in one string: the timer fired, the fiber was
    // cancelled, `bound.fired()` said the cancellation was this call's own,
    // and the handler was handed a timeout rather than a shutdown.
    try testing.expectEqualStrings("TimedOut", body);
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
