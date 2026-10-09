//! The tests that need a server that is actually running.
//!
//! Almost every HTTP behaviour here is tested against in-memory buffers with
//! no server at all, which is what `App.handleRequest` taking only a Reader
//! and a Writer buys. Work that is not a request cannot be tested that way:
//! it exists precisely because there is a server, it is owned by the group
//! the Engine's accept loop runs its connections in, and outside one
//! `nilo.spawn` answers `error.NoServer` by design
//! ([ADR 028](../docs/adr/028-a-spawned-fiber-belongs-to-the-server.md)).
//!
//! [ADR 032](../docs/adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
//! is why this file exists rather than a unit test asserting that a list has
//! one entry in it: a registration nothing has ever been seen to *run* is not
//! evidence that anything runs.
//!
//! **The background-work tests ask for port 0 and never connect.** The whole
//! point of that feature is that it starts without being asked, so nothing has
//! to know the port, and two optimize modes running this suite at the same time
//! cannot collide.
//!
//! **`sendfile` is the half that does connect**, and it has to. Every other
//! test in this repository runs through `testing.Client`, whose writer is
//! `std.Io.Writer.fixed` and carries no `sendFile` in its vtable — so the suite
//! takes std's read-and-drain fallback and produces the right bytes by the
//! route a platform *without* `sendfile` uses. The splice chain the feature
//! exists for has never been executed by a test
//! ([ADR 009](../docs/adr/009-static-files-are-held-in-memory-or-opened.md)),
//! which by [ADR 032](../docs/adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
//! is the same standing as a guard only ever seen to pass. A real socket is the
//! only thing that reaches it.
//!
//! **Every port here is 0 and read back.** `App.listen` hands the port the
//! kernel chose to `ready`, and `app.boundPort()` is where a test reads it —
//! so nothing in the suite walks a range of loopback ports any more. Three
//! files did, held apart by comments naming each other, on the belief that a
//! bound port could not be read back; it could all along, in std and in zio
//! both, and the comments once failed (`error.NoFreePort` from the sixth of
//! ten consecutive `test-all` runs).

const std = @import("std");
const nilo = @import("http.zig");
const bulkhead = @import("bulkhead.zig");
const watchdog = @import("watchdog.zig");

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

    // `start(io)` and then `listen()`, the order ADR 180 first built and now
    // refuses once a service has kept the `Io`. This App has none, so the
    // boot goes ahead: `startServices` is skipped the second time round, and
    // **this is the case that used to take the background work down with
    // it** — the whole reason the two guards in `App` are separate flags
    // (ADR 028).
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

/// A service in the shape `nilo_sql`'s `Db` has: `nilo_start` is where the
/// pool would be built, on the loop it is handed.
const Booted = struct {
    started: std.atomic.Value(bool) = .init(false),

    pub fn nilo_start(self: *Booted, _: std.Io) !void {
        self.started.store(true, .release);
    }
};

/// What `before` work saw when it ran inside `listen()`, and what a fiber
/// started by `spawn` saw when it began.
const Boot = struct {
    /// The service was up when the `before` work ran.
    service_was_up: std.atomic.Value(bool) = .init(false),
    /// The Run the work was handed could reach the loop.
    had_io: std.atomic.Value(bool) = .init(false),
    /// How many times the `before` work ran; the assertion is exactly one.
    ran: std.atomic.Value(u32) = .init(0),
    /// The `before` work had finished when the spawned fiber began.
    before_first: std.atomic.Value(bool) = .init(false),
    ticker: Ticker = .{},

    fn migrate(run: *nilo.Run, booted: *Booted, self: *Boot) !void {
        self.service_was_up.store(booted.started.load(.acquire), .release);
        _ = try run.entropy(4);
        self.had_io.store(true, .release);
        _ = self.ran.fetchAdd(1, .monotonic);
    }

    fn tick(self: *Boot) void {
        self.before_first.store(self.ran.load(.acquire) == 1, .release);
        self.ticker.run();
    }
};

test "work registered with before runs inside listen, after the services and before the rest" {
    hush();
    const gpa = std.heap.smp_allocator;

    var booted: Booted = .{};
    var boot: Boot = .{};

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.provide(&booted);
    try app.before(Boot.migrate, .{ &booted, &boot });
    try app.spawn(Boot.tick, .{&boot});

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }

    try waitForATick(&boot.ticker);
    try testing.expect(serving.bound.load(.acquire));

    // The order ADR 180 fixes: the service, then the work that needs it,
    // then the fibers — and the Run that work was handed is on the loop the
    // service was started on, which is what a migration needs from it.
    try testing.expectEqual(@as(u32, 1), boot.ran.load(.acquire));
    try testing.expect(boot.service_was_up.load(.acquire));
    try testing.expect(boot.had_io.load(.acquire));
    try testing.expect(boot.before_first.load(.acquire));
}

/// Boot work that calls a fail function and carries on, so the boot
/// finishes and the test can read what the call found.
const Refused = struct {
    words: [64]u8 = undefined,
    n: std.atomic.Value(usize) = .init(0),
    status: std.atomic.Value(u16) = .init(0),
    ticker: Ticker = .{},

    fn seed(_: *nilo.Run, self: *Refused) void {
        const refused = nilo.fail.unprocessable("no suspicious return in {s}", .{"Sekernan"});
        if (refused != error.Failed) return;
        const f = nilo.fail.current() orelse return;
        const said = f.message();
        @memcpy(self.words[0..said.len], said);
        self.n.store(said.len, .release);
        self.status.store(f.status, .release);
    }
};

test "a fail function in before work inside listen finds the boot's box" {
    hush();
    const gpa = std.heap.smp_allocator;

    var refused: Refused = .{};

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.before(Refused.seed, .{&refused});
    try app.spawn(Ticker.run, .{&refused.ticker});

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }

    try waitForATick(&refused.ticker);

    // Inside `listen()` the box is bound to the loop's own task, the way a
    // connection binds its own, rather than put in the threadlocal every
    // spawned fiber on that thread would read (ADR 006). Bound there, the
    // sentence is where the boot's line reads it.
    try testing.expectEqual(@as(u16, 422), refused.status.load(.acquire));
    try testing.expectEqualStrings("no suspicious return in Sekernan", refused.words[0..refused.n.load(.acquire)]);
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

// ---- a stop and the connections that are only waiting ----

/// A server with a long idle limit, so that a stop which waits on an idle
/// connection is told apart from one that does not by seconds rather than
/// by milliseconds.
const ServingIdle = struct {
    app: *nilo.App,
    bound: std.atomic.Value(bool) = .init(true),

    fn run(self: *ServingIdle) void {
        self.app.tryListen(.{
            .port = 0,
            .threads = 1,
            .stop_on_signal = false,
            .idle_timeout_ms = 5_000,
        }) catch {
            self.bound.store(false, .release);
        };
    }
};

fn sayOk() []const u8 {
    return "ok";
}

/// Read until one whole `ok` answer has arrived, and no further, so the
/// connection stays open behind it.
fn readOneOk(reader: *std.Io.Reader) !void {
    while (true) {
        if (std.mem.indexOf(u8, reader.buffered(), "\r\n\r\nok")) |at| {
            reader.toss(at + 6);
            return;
        }
        try reader.fillMore();
    }
}

test "a stop does not wait on a keep-alive connection that is only waiting for its next request" {
    hush();
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/x", sayOk);

    var serving: ServingIdle = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, ServingIdle.run, .{&serving});

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Joined exactly once whichever way the test leaves, because returning
    // early would run `app.deinit()` under a server still using it.
    var joined = false;
    defer if (!joined) {
        app.shutdown();
        thread.join();
    };

    const port: u16 = for (0..300) |_| {
        if (app.boundPort()) |p| break p;
        if (!serving.bound.load(.acquire)) return error.ServerNeverCameUp;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    } else return error.ServerNeverCameUp;

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    var in_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);

    // Two requests with a quiet spell between them, past the peek, so the
    // connection has been idle once and is about to be again.
    for (0..2) |i| {
        try writer.interface.writeAll("GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
        try writer.interface.flush();
        try readOneOk(&reader.interface);
        if (i == 0) std.Io.sleep(io, .fromMilliseconds(400), .awake) catch {};
    }

    // Stopped while the connection waits for a third request that never
    // comes: nothing is in flight, so nothing should be waited for.
    const started = std.Io.Clock.awake.now(io);
    app.shutdown();
    thread.join();
    joined = true;
    const took_ms = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

    // The connection was closed rather than left to run out its idle limit.
    var rest: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), reader.interface.readSliceShort(&rest) catch 0);
    if (took_ms >= 2_000) {
        std.debug.print("the stop took {d} ms with one idle connection open\n", .{took_ms});
        return error.StopWaitedOnAnIdleConnection;
    }
}

fn sayOkSlowly() ![]const u8 {
    try nilo.sleep(800);
    return "ok";
}

test "a stop closes the listener before it waits for the requests in flight" {
    hush();
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/slow", sayOkSlowly);

    var serving: ServingIdle = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, ServingIdle.run, .{&serving});
    var joined = false;
    defer if (!joined) {
        app.shutdown();
        thread.join();
    };

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const port: u16 = for (0..300) |_| {
        if (app.boundPort()) |p| break p;
        if (!serving.bound.load(.acquire)) return error.ServerNeverCameUp;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    } else return error.ServerNeverCameUp;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };

    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    try writer.interface.writeAll("GET /slow HTTP/1.1\r\nHost: t\r\n\r\n");
    try writer.interface.flush();
    std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};

    // Past the main fiber's look at the stop flag, so the server is in its
    // grace period with the slow request still running.
    app.shutdown();
    std.Io.sleep(io, .fromMilliseconds(400), .awake) catch {};

    const late = address.connect(io, .{ .mode = .stream });
    if (late) |s| s.close(io) else |_| {}
    try testing.expectError(error.ConnectionRefused, late);

    // And the request that was already in flight is still answered.
    var in_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    try readOneOk(&reader.interface);

    thread.join();
    joined = true;
}

// ---- a file leaving by the route the rest of the suite never takes ----

/// The server for the `sendfile` tests: a real port, because that is the whole
/// point (see the header). Port 0, and the kernel's answer read back through
/// `app.boundPort()` — the way `fetch/live.zig` and `s3/canned.zig` already
/// get theirs, and the last of the three files that used to walk a range.
const ServingAt = struct {
    app: *nilo.App,
    bound: std.atomic.Value(bool) = .init(true),
    /// `block_warning_ms` for the server; the default is the shipped one.
    warn_ms: u32 = 250,

    fn run(self: *ServingAt) void {
        self.app.tryListen(.{
            .port = 0,
            .threads = 1,
            .stop_on_signal = false,
            .block_warning_ms = self.warn_ms,
        }) catch {
            self.bound.store(false, .release);
        };
    }
};

/// The port the server took, once it has. Bounded, for the reason
/// `waitForServer` is: a server that never binds fails here rather than
/// leaving the suite waiting (`CLAUDE.md`).
fn waitForPort(gpa: std.mem.Allocator, serving: *const ServingAt) !u16 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for (0..300) |_| {
        if (serving.app.boundPort()) |port| return port;
        if (!serving.bound.load(.acquire)) return error.ServerNeverCameUp;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.ServerNeverCameUp;
}

/// One request over a real socket, head and body kept apart.
///
/// The writer here is a socket's, so its vtable has a `sendFile` and the
/// response comes back by the route a deployed server actually uses.
const Answer = struct {
    head: []u8,
    body: []u8,

    fn deinit(self: Answer, gpa: std.mem.Allocator) void {
        gpa.free(self.head);
        gpa.free(self.body);
    }
};

fn ask(gpa: std.mem.Allocator, port: u16, request: []const u8) !Answer {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    // The server comes up on another thread, so the first attempts may arrive
    // before the port is taken. Bounded, because a server that never binds has
    // to fail here rather than leave the suite waiting (`CLAUDE.md`).
    var stream: std.Io.net.Stream = for (0..300) |_| {
        break address.connect(io, .{ .mode = .stream }) catch {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        };
    } else return error.ServerNeverCameUp;
    defer stream.close(io);

    return converse(gpa, io, stream, request);
}

/// The same request over a unix socket. `std.Io.net.UnixAddress` is std's own
/// — no zio anywhere on this side, which is what makes the answer evidence
/// that an ordinary client reaches the server rather than that two halves of
/// the same library agree.
/// The caller waits for the server first — `waitForServer` — because
/// `std.Io.net.UnixAddress.ConnectError` does not list `ConnectionRefused`,
/// so a connect that arrives before the server has bound comes back as
/// `error.Unexpected` with a stack trace on stderr, which is the shape of a
/// failing suite (`CLAUDE.md`).
fn askOverPath(gpa: std.mem.Allocator, path: []const u8, request: []const u8) !Answer {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = try std.Io.net.UnixAddress.init(path);
    var stream: std.Io.net.Stream = for (0..300) |_| {
        break address.connect(io) catch {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        };
    } else return error.ServerNeverCameUp;
    defer stream.close(io);

    return converse(gpa, io, stream, request);
}

fn converse(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    request: []const u8,
) !Answer {
    var out_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var in_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var whole: std.Io.Writer.Allocating = .init(gpa);
    defer whole.deinit();
    _ = reader.interface.streamRemaining(&whole.writer) catch {};

    const text = whole.written();
    const split = std.mem.indexOf(u8, text, "\r\n\r\n") orelse return error.NoHeadBoundary;
    return .{
        .head = try gpa.dupe(u8, text[0..split]),
        .body = try gpa.dupe(u8, text[split + 4 ..]),
    };
}

/// A directory with one file too big to be held, so every request for it goes
/// down `sendfile.send`. The path is relative to the working directory, which
/// is what `staticWith` takes.
const Spilled = struct {
    tmp: nilo.testing.TmpDir,
    path: [:0]u8,

    /// Longer than one page and not a round number of them, so a partial last
    /// chunk is exercised rather than an exact multiple.
    const contents = repeat("nilo sends this from a descriptor, not from memory. ", 200);

    fn init(gpa: std.mem.Allocator) !Spilled {
        var tmp = nilo.testing.tmpDir();
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.txt", .data = contents });
        return .{
            .tmp = tmp,
            .path = try tmp.pathAlloc(gpa, ""),
        };
    }

    fn deinit(self: *Spilled, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        self.tmp.cleanup();
    }
};

test "a spilled file's bytes reach a real socket, by the route only a real socket takes" {
    hush();
    const gpa = std.heap.smp_allocator;

    var tree = try Spilled.init(gpa);
    defer tree.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    // One byte under the file, so it is certain to spill and the test is not
    // resting on what the default threshold happens to be today.
    //
    // **`max_total_bytes` is what makes this test about `sendfile` at all.**
    // The bytes a held file answers with and the bytes a spilled one answers
    // with are the same bytes, so an assertion on the body cannot tell the two
    // apart and a threshold that quietly stopped working would look like a
    // pass. A total budget far under the file cannot be met by holding it: a
    // spilled file is charged nothing, a held one would be refused here, and
    // `staticWith` would take the process down before a request was ever made.
    try app.staticWith("/files", tree.path, .{
        .max_file_bytes = Spilled.contents.len - 1,
        .max_total_bytes = 1024,
        .compress = false,
    });

    var serving: ServingAt = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, ServingAt.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try waitForPort(gpa, &serving);

    const whole = try ask(gpa, port, "GET /files/big.txt HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer whole.deinit(gpa);

    try testing.expect(std.mem.startsWith(u8, whole.head, "HTTP/1.1 200 "));
    try testing.expectEqualStrings(Spilled.contents, whole.body);

    // The other arm of `sendfile.send`, and the one a resumed download takes:
    // a seek, a shorter length, and a 206 saying which bytes these are.
    const part = try ask(gpa, port, "GET /files/big.txt HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=10-19\r\n" ++
        "Connection: close\r\n\r\n");
    defer part.deinit(gpa);

    try testing.expect(std.mem.startsWith(u8, part.head, "HTTP/1.1 206 "));
    try testing.expectEqualStrings(Spilled.contents[10..20], part.body);
}

fn pong(c: *nilo.Ctx) anyerror!void {
    try c.sendText(200, "pong");
}

/// Read from `stream` until `text` has turned up `times` times, or the read
/// fails. Bounded by a receive timeout on the socket, set with std's own
/// `setsockopt`, so a server that never sends the second answer fails the
/// test instead of holding the suite (`CLAUDE.md`).
fn readUntilSeen(
    io: std.Io,
    stream: std.Io.net.Stream,
    whole: *std.Io.Writer.Allocating,
    text: []const u8,
    times: usize,
) !void {
    const limit: std.posix.timeval = .{ .sec = 5, .usec = 0 };
    try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&limit));

    var in_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    while (std.mem.count(u8, whole.written(), text) < times) {
        _ = reader.interface.stream(&whole.writer, .limited(in_buf.len)) catch return error.AnswerNeverCame;
    }
}

test "two requests sent together are answered together, and the second is not held for a third" {
    // ADR 201: a response whose successor is already in the read buffer is
    // held, and put on the wire before the connection next waits. Only a
    // real socket reaches the second half, which is the Engine's: a fixed
    // reader never parks. If the hold were not made good, the client here
    // would get one answer and then silence.
    hush();
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/ping", pong);

    var serving: ServingAt = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, ServingAt.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try waitForPort(gpa, &serving);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var stream: std.Io.net.Stream = for (0..300) |_| {
        break address.connect(io, .{ .mode = .stream }) catch {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        };
    } else return error.ServerNeverCameUp;
    defer stream.close(io);

    var out_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    const one = "GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    // Both in one write, so the server reads them in one go and the second
    // is in its buffer when it answers the first.
    try writer.interface.writeAll(one ++ one);
    try writer.interface.flush();

    var whole: std.Io.Writer.Allocating = .init(gpa);
    defer whole.deinit();
    try readUntilSeen(io, stream, &whole, "\r\n\r\npong", 2);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, whole.written(), "HTTP/1.1 200 "));
    // Nothing said the connection was closing, and it was not: a third
    // request, sent alone, is answered alone.
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, whole.written(), "Connection: close"));
    try writer.interface.writeAll(one);
    try writer.interface.flush();
    try readUntilSeen(io, stream, &whole, "\r\n\r\npong", 3);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, whole.written(), "HTTP/1.1 200 "));
}

/// The server under test on a path rather than a port.
const ServingOnPath = struct {
    app: *nilo.App,
    path: []const u8,
    trusted: []const []const u8 = &.{},
    bound: std.atomic.Value(bool) = .init(true),
    /// Set by a fiber the server owns, so it cannot be set before there is a
    /// server. See `waitForServer`.
    up: std.atomic.Value(bool) = .init(false),

    fn sayUp(flag: *std.atomic.Value(bool)) void {
        flag.store(true, .release);
    }

    fn run(self: *ServingOnPath) void {
        var buf: [std.Io.net.UnixAddress.max_len + 8]u8 = undefined;
        const address = std.fmt.bufPrint(&buf, "unix:{s}", .{self.path}) catch {
            self.bound.store(false, .release);
            return;
        };
        self.app.spawn(sayUp, .{&self.up}) catch {
            self.bound.store(false, .release);
            return;
        };
        self.app.tryListen(.{
            .address = address,
            .threads = 1,
            .stop_on_signal = false,
            .trusted_proxies = self.trusted,
        }) catch {
            self.bound.store(false, .release);
        };
    }
};

fn whoIsAsking(c: *nilo.Ctx) anyerror!void {
    try c.sendText(200, try std.fmt.allocPrint(c._arena, "{f}", .{c.clientIp()}));
}

/// A temporary directory with room for a socket in it, named short enough
/// that the whole path fits in the 108 bytes the operating system allows.
const SocketDir = struct {
    tmp: nilo.testing.TmpDir,
    path: [:0]u8,

    fn init(gpa: std.mem.Allocator, name: []const u8) !SocketDir {
        var tmp = nilo.testing.tmpDir();
        errdefer tmp.cleanup();
        return .{
            .tmp = tmp,
            .path = try tmp.pathAlloc(gpa, name),
        };
    }

    fn deinit(self: *SocketDir, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        self.tmp.cleanup();
    }
};

/// Wait until the server is listening, or give up.
///
/// Asked of the server rather than of the filesystem, because the filesystem
/// cannot answer it: on a path that already held a **stale** socket the file
/// is there before the server is, and the inode of the replacement is
/// routinely the one just freed. `ServingOnPath` registers a fiber that only
/// runs once the loop is up and the socket is bound
/// ([ADR 028](../docs/adr/028-a-spawned-fiber-belongs-to-the-server.md)),
/// which is the same fact stated somewhere that can be read.
///
/// Bounded, because a server that never binds has to fail here rather than
/// leave the suite waiting (`CLAUDE.md`).
fn waitForServer(gpa: std.mem.Allocator, serving: *const ServingOnPath) !void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for (0..300) |_| {
        if (serving.up.load(.acquire)) return;
        if (!serving.bound.load(.acquire)) return error.ServerNeverCameUp;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.ServerNeverCameUp;
}

fn stillThere(gpa: std.mem.Allocator, path: []const u8) bool {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    _ = std.Io.Dir.cwd().statFile(threaded.io(), path, .{}) catch return false;
    return true;
}

test "a server on a path answers over it, reads the proxy's header, and gives the path back" {
    hush();
    const gpa = std.heap.smp_allocator;

    var where = try SocketDir.init(gpa, "nilo.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/who", whoIsAsking);

    var serving: ServingOnPath = .{
        .app = &app,
        .path = where.path,
        // The deployment this feature is for: nginx in front, reaching the
        // server over the socket. There is no connection address for a rule
        // to name, and the connection is trusted by having arrived at all
        // (ADR 103).
        .trusted = &.{"private"},
    };
    const thread = try std.Thread.spawn(.{}, ServingOnPath.run, .{&serving});
    // Stopped by hand at the end of the test rather than only here, because
    // what is being asserted is what the stop leaves behind. The flag keeps
    // the two from joining the same thread twice.
    var stopped = false;
    defer if (!stopped) {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    };
    try waitForServer(gpa, &serving);

    const forwarded = try askOverPath(gpa, where.path, "GET /who HTTP/1.1\r\nHost: nilo\r\nX-Forwarded-For: 203.0.113.9\r\n" ++
        "Connection: close\r\n\r\n");
    defer forwarded.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, forwarded.head, "HTTP/1.1 200 "));
    try testing.expectEqualStrings("203.0.113.9", forwarded.body);

    // Nothing forwarded, so there is nobody to name: a unix connection has no
    // address of its own to fall back to.
    const bare = try askOverPath(gpa, where.path, "GET /who HTTP/1.1\r\nHost: nilo\r\nConnection: close\r\n\r\n");
    defer bare.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, bare.head, "HTTP/1.1 200 "));
    try testing.expectEqualStrings("", bare.body);

    // A socket file is a file, and closing the descriptor leaves it there. A
    // server that did not take its own path away would refuse to start next
    // time on the socket it made itself.
    app.shutdown();
    thread.join();
    stopped = true;
    try testing.expect(!stillThere(gpa, where.path));
}

test "a socket left behind by a server that is gone does not stop the next one" {
    hush();
    const gpa = std.heap.smp_allocator;

    var where = try SocketDir.init(gpa, "stale.sock");
    defer where.deinit(gpa);

    // A socket file with nobody behind it, which is what a killed process
    // leaves. Closing the descriptor does not remove the path — that is the
    // whole of the problem, and during development it is every restart.
    {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const addr = try std.Io.net.UnixAddress.init(where.path);
        var dead = try addr.listen(io, .{});
        dead.socket.close(io);
    }
    try testing.expect(stillThere(gpa, where.path));

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/who", whoIsAsking);

    var serving: ServingOnPath = .{ .app = &app, .path = where.path };
    const thread = try std.Thread.spawn(.{}, ServingOnPath.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }

    try waitForServer(gpa, &serving);
    const answer = try askOverPath(gpa, where.path, "GET /who HTTP/1.1\r\nHost: nilo\r\nConnection: close\r\n\r\n");
    defer answer.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, answer.head, "HTTP/1.1 200 "));
}

test "a stop asked for by shutdown ends listen at once, not at the server's next look for one" {
    // `serve` used to see a stop only when its 200 ms poll came round, so
    // `listen()` returned up to a fifth of a second after `shutdown()`. The
    // doorbell rings it now. The fastest of three is what is held, so a
    // machine busy for one of them does not fail it, and a poll does: each
    // stop here lands 50 ms into a 200 ms wait.
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fastest_ms: i64 = std.math.maxInt(i64);
    for (0..3) |_| {
        var where = try SocketDir.init(gpa, "bell.sock");
        defer where.deinit(gpa);
        var app = nilo.App.init(gpa);
        defer app.deinit();

        var serving: ServingOnPath = .{ .app = &app, .path = where.path };
        const thread = try std.Thread.spawn(.{}, ServingOnPath.run, .{&serving});
        waitForServer(gpa, &serving) catch |err| {
            if (serving.bound.load(.acquire)) app.shutdown();
            thread.join();
            return err;
        };
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};

        const asked = std.Io.Clock.awake.now(io);
        app.shutdown();
        thread.join();
        fastest_ms = @min(fastest_ms, asked.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds());
    }
    try testing.expect(fastest_ms < 100);
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

/// The server under test answering on two addresses at once: the one
/// `Options` names, on a port the kernel chose, and a unix socket beside it
/// ([ADR 213](../docs/adr/213-a-server-answers-on-more-than-one-address.md)).
///
/// Two *transports* rather than two ports, and that is what makes it a test
/// rather than a repetition: a second entry that differed only in its number
/// would prove the loop runs twice, while this one proves each listener
/// keeps its own way of carrying bytes and that the routes underneath are
/// the server's rather than the address's. The TLS pairing is the same fact
/// with encryption in place of the socket file, and lives in `tls_live.zig`
/// because only a build with TLS in it can run it.
const ServingOnBoth = struct {
    app: *nilo.App,
    path: []const u8,
    bound: std.atomic.Value(bool) = .init(true),

    fn run(self: *ServingOnBoth) void {
        var buf: [std.Io.net.UnixAddress.max_len + 8]u8 = undefined;
        const beside = std.fmt.bufPrint(&buf, "unix:{s}", .{self.path}) catch {
            self.bound.store(false, .release);
            return;
        };
        self.app.tryListen(.{
            .port = 0,
            .threads = 1,
            .stop_on_signal = false,
            .also = &.{.{ .address = beside }},
        }) catch {
            self.bound.store(false, .release);
        };
    }
};

/// The port the first listener took. The same bounded wait `waitForPort`
/// does, against this harness's own flag.
fn waitForFirstPort(gpa: std.mem.Allocator, serving: *const ServingOnBoth) !u16 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for (0..300) |_| {
        if (serving.app.boundPort()) |port| return port;
        if (!serving.bound.load(.acquire)) return error.ServerNeverCameUp;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.ServerNeverCameUp;
}

test "a server answers on a second address, and both addresses reach the same routes" {
    hush();
    const gpa = std.heap.smp_allocator;

    var where = try SocketDir.init(gpa, "beside.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/who", whoIsAsking);

    var serving: ServingOnBoth = .{ .app = &app, .path = where.path };
    const thread = try std.Thread.spawn(.{}, ServingOnBoth.run, .{&serving});
    var stopped = false;
    defer if (!stopped) {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    };
    const port = try waitForFirstPort(gpa, &serving);

    // The address `Options` itself named. `boundPort()` answers for this one
    // and only this one, which is what the option's doc says.
    const over_port = try ask(gpa, port, "GET /who HTTP/1.1\r\nHost: nilo\r\nConnection: close\r\n\r\n");
    defer over_port.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, over_port.head, "HTTP/1.1 200 "));

    // The one `also` added. Same App, same route table, same handler — the
    // listener decides how the bytes are carried and nothing above it does.
    const over_path = try askOverPath(gpa, where.path, "GET /who HTTP/1.1\r\nHost: nilo\r\nConnection: close\r\n\r\n");
    defer over_path.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, over_path.head, "HTTP/1.1 200 "));

    // A route that is not there is not there on either, which is the same
    // table answering twice rather than two tables that happen to agree.
    const missing = try askOverPath(gpa, where.path, "GET /nowhere HTTP/1.1\r\nHost: nilo\r\nConnection: close\r\n\r\n");
    defer missing.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, missing.head, "HTTP/1.1 404 "));

    // Both sockets are this process's to take away, not just the first.
    app.shutdown();
    thread.join();
    stopped = true;
    try testing.expect(!stillThere(gpa, where.path));
}

test "a route bound to a listener answers on that listener only, over a real port and a real socket file" {
    hush();
    const gpa = std.heap.smp_allocator;

    var where = try SocketDir.init(gpa, "bound.sock");
    defer where.deinit(gpa);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/who", whoIsAsking);
    try app.onListener(&.{0}).get("/public", whoIsAsking);
    try app.onListener(&.{1}).get("/ingest", whoIsAsking);

    var serving: ServingOnBoth = .{ .app = &app, .path = where.path };
    const thread = try std.Thread.spawn(.{}, ServingOnBoth.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try waitForFirstPort(gpa, &serving);

    const get = "GET {s} HTTP/1.1\r\nHost: nilo\r\nConnection: close\r\n\r\n";
    var buf: [96]u8 = undefined;
    const Case = struct { path: []const u8, first: []const u8, second: []const u8 };
    for ([_]Case{
        .{ .path = "/who", .first = "HTTP/1.1 200 ", .second = "HTTP/1.1 200 " },
        .{ .path = "/public", .first = "HTTP/1.1 200 ", .second = "HTTP/1.1 404 " },
        .{ .path = "/ingest", .first = "HTTP/1.1 404 ", .second = "HTTP/1.1 200 " },
    }) |case| {
        const request = try std.fmt.bufPrint(&buf, get, .{case.path});
        const over_port = try ask(gpa, port, request);
        defer over_port.deinit(gpa);
        try testing.expect(std.mem.startsWith(u8, over_port.head, case.first));
        const over_path = try askOverPath(gpa, where.path, request);
        defer over_path.deinit(gpa);
        try testing.expect(std.mem.startsWith(u8, over_path.head, case.second));
    }
}

/// Set by `bigAnswer` once its write has come back, however it came back.
var big_answer_returned: std.atomic.Value(bool) = .init(false);

/// Far more than the kernel will queue on a loopback socket, so the write
/// parks on a client that is not reading. Filled by the test before the
/// request is sent, never by the handler: the handler runs inside the
/// route's deadline, and a write that begins after the deadline has passed
/// goes out under the ordinary write limit (`Deadlines.armWrite`, ADR 105).
/// Filling 96 MB in the handler spent the budget it was measuring on a
/// loaded macOS runner, and the write then waited out thirty seconds.
var big_answer_body: []const u8 = "";

fn bigAnswer(c: *nilo.Ctx) !void {
    defer big_answer_returned.store(true, .release);
    try c.send(200, "application/octet-stream", big_answer_body);
}

test "a route deadline shortens the write to a client that reads nothing" {
    // ADR 105: `listen()`'s write limit is thirty seconds a write, and it was
    // armed once for the connection, so a route that had said two hundred
    // milliseconds still waited out the thirty. Only a real socket parks the
    // writer.
    hush();
    const gpa = std.heap.smp_allocator;
    big_answer_returned.store(false, .release);

    const body = try gpa.alloc(u8, 96 * 1024 * 1024);
    defer gpa.free(body);
    @memset(body, 'x');
    big_answer_body = body;
    defer big_answer_body = "";

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.with(nilo.deadline(200)).get("/big", bigAnswer);

    var serving: ServingAt = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, ServingAt.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try waitForPort(gpa, &serving);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var stream: std.Io.net.Stream = for (0..300) |_| {
        break address.connect(io, .{ .mode = .stream }) catch {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        };
    } else return error.ServerNeverCameUp;
    // Closed before the server is told to stop, so a server still writing
    // meets a reset rather than the thirty seconds.
    defer stream.close(io);

    var out_buf: [128]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    try writer.interface.writeAll("GET /big HTTP/1.1\r\nHost: t\r\n\r\n");
    try writer.interface.flush();

    // The client reads nothing. Bounded at ten seconds: fifty times the
    // route's deadline, and a third of the write limit it exists to beat, so
    // a write left on that limit still fails here. The time is printed on a
    // failure, because it says which of the two happened.
    const started = std.Io.Clock.awake.now(io);
    while (!big_answer_returned.load(.acquire)) {
        if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= 10_000) break;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    if (!big_answer_returned.load(.acquire)) {
        const took_ms = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
        std.debug.print("the write was still parked after {d} ms\n", .{took_ms});
        return error.DeadlineDidNotCutTheWrite;
    }
}

// ---- the detector against waits it was not told about (ADR 013) ----
//
// A handler may wait through the server's `Io`, which parks the fiber without
// saying so to the watchdog. These run each shape against a real loop and read
// `watchdog.caught`, because the loop's turn stamp is the signal and only a
// real loop has one.

const watched_ms = 100;

fn parkedOnAnEvent(c: *nilo.Ctx) anyerror!void {
    // Nobody ever sets it: the wait ends by its timeout, 4x the limit.
    var never: std.Io.Event = .unset;
    never.waitTimeout(c.io(), .{ .duration = .{ .raw = .fromMilliseconds(400), .clock = .awake } }) catch {};
    try c.sendEmpty(200);
}

fn parkedOnNiloSleep(c: *nilo.Ctx) anyerror!void {
    try nilo.sleep(400);
    try c.sendEmpty(200);
}

fn spinFor(ms: u64) void {
    const until = bulkhead.monotonicNanos() + ms * std.time.ns_per_ms;
    while (bulkhead.monotonicNanos() < until) {}
}

fn spins(c: *nilo.Ctx) anyerror!void {
    spinFor(300);
    try c.sendEmpty(200);
}

fn blocksInTheKernel(c: *nilo.Ctx) anyerror!void {
    const ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 300 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&ts, null);
    try c.sendEmpty(200);
}

fn parksThenSpinsBriefly(c: *nilo.Ctx) anyerror!void {
    // 150ms of unannounced park and 60ms of the handler's own: 210ms between
    // the two ends of the stretch, past the limit, and only the 60 is a hold.
    var never: std.Io.Event = .unset;
    never.waitTimeout(c.io(), .{ .duration = .{ .raw = .fromMilliseconds(150), .clock = .awake } }) catch {};
    spinFor(60);
    try c.sendEmpty(200);
}

fn parksThenSpins(c: *nilo.Ctx) anyerror!void {
    // 150ms of unannounced park, then 300ms of the handler's own: the report
    // is for the 300, and exactly one of them.
    var never: std.Io.Event = .unset;
    never.waitTimeout(c.io(), .{ .duration = .{ .raw = .fromMilliseconds(150), .clock = .awake } }) catch {};
    spinFor(300);
    try c.sendEmpty(200);
}

/// One GET to `route` on a one-thread server whose limit is `watched_ms`, and
/// how many reports it drew.
fn reportsFor(comptime route: []const u8, handler: anytype) !u64 {
    hush();
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get(route, handler);

    var serving: ServingAt = .{ .app = &app, .warn_ms = watched_ms };
    const thread = try std.Thread.spawn(.{}, ServingAt.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try waitForPort(gpa, &serving);

    const before = watchdog.caught.load(.monotonic);
    const answer = try ask(gpa, port, "GET " ++ route ++ " HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer answer.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, answer.head, "HTTP/1.1 200"));
    return watchdog.caught.load(.monotonic) - before;
}

test "a wait on an Event past the limit is a parked fiber, not a held thread" {
    try testing.expectEqual(@as(u64, 0), try reportsFor("/event", parkedOnAnEvent));
}

test "nilo.sleep past the limit is still not reported" {
    try testing.expectEqual(@as(u64, 0), try reportsFor("/sleep", parkedOnNiloSleep));
}

test "a handler that spins past the limit is reported, loop or no loop" {
    try testing.expectEqual(@as(u64, 1), try reportsFor("/spin", spins));
}

test "a blocking syscall past the limit is reported" {
    try testing.expectEqual(@as(u64, 1), try reportsFor("/syscall", blocksInTheKernel));
}

test "a park the detector was not told about, then a spin, is reported once for the spin" {
    try testing.expectEqual(@as(u64, 1), try reportsFor("/both", parksThenSpins));
}

test "a park the detector was not told about, then a spin under the limit, is not" {
    // The half that says the rule measures the run since the park rather than
    // the whole stretch: 210ms on the clock, 60ms of it the handler's own.
    try testing.expectEqual(@as(u64, 0), try reportsFor("/brief", parksThenSpinsBriefly));
}

var released: std.Io.Event = .unset;

fn waitsForTheRelease(c: *nilo.Ctx) anyerror!void {
    released.waitTimeout(c.io(), .{ .duration = .{ .raw = .fromMilliseconds(5000), .clock = .awake } }) catch {};
    spinFor(300);
    try c.sendEmpty(200);
}

fn release(c: *nilo.Ctx) anyerror!void {
    released.set(c.io());
    try c.sendEmpty(200);
}

fn askAndKeep(gpa: std.mem.Allocator, port: u16, request: []const u8) void {
    const a = ask(gpa, port, request) catch return;
    a.deinit(gpa);
}

test "a fiber woken by another request in the same turn is charged for its own spin, once" {
    // The shape of the write-ahead log: one request waits on an Event, another
    // sets it, and the woken fiber runs in the turn that ran the setter. The
    // turn's stamp is the setter's start, so the woken fiber's spin is
    // measured from there, and the setter, which ended its own stretch first,
    // is not reported.
    hush();
    const gpa = std.heap.smp_allocator;
    released = .unset;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/h", waitsForTheRelease);
    try app.get("/r", release);

    var serving: ServingAt = .{ .app = &app, .warn_ms = watched_ms };
    const thread = try std.Thread.spawn(.{}, ServingAt.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try waitForPort(gpa, &serving);

    const before = watchdog.caught.load(.monotonic);
    const waiter = try std.Thread.spawn(.{}, askAndKeep, .{ gpa, port, "GET /h HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n" });
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    std.Io.sleep(threaded.io(), .fromMilliseconds(300), .awake) catch {};
    const answer = try ask(gpa, port, "GET /r HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    answer.deinit(gpa);
    waiter.join();
    try testing.expectEqual(@as(u64, 1), watchdog.caught.load(.monotonic) - before);
}

/// The write-ahead log's shape (ADR 244), with an idle deadline: a route puts
/// an item on a queue and waits on the item's event, and one fiber
/// `app.spawn` started drains the queue, answers each item and, when nothing
/// is queued, waits on an event with a timeout so it wakes with no request in
/// flight. The fields are atomics because the fiber and the test run on
/// different threads.
const IdleWriter = struct {
    const Item = struct {
        done: std.Io.Event = .unset,
        written: bool = false,
    };

    slots: [16]*Item = undefined,
    queue: std.Io.Queue(*Item) = undefined,
    /// Set by every putter after `put`, reset by the writer before it drains.
    wake: std.Io.Event = .unset,
    idle_ms: u32 = 30,

    /// Items answered, and how often the idle deadline passed with nothing
    /// queued and no request arriving.
    answered: std.atomic.Value(u32) = .init(0),
    idle_wakes: std.atomic.Value(u32) = .init(0),
    /// `userdata` of the `std.Io` each side was given, as an address.
    writer_loop: std.atomic.Value(usize) = .init(0),
    route_loop: std.atomic.Value(usize) = .init(0),
    /// Counts the cancellation of the shutdown reaching the writer.
    canceled: std.atomic.Value(u32) = .init(0),

    fn init(self: *IdleWriter) void {
        self.queue = .init(&self.slots);
    }

    fn run(self: *IdleWriter) void {
        const io = nilo.io();
        self.writer_loop.store(@intFromPtr(io.userdata), .release);
        var batch: [8]*Item = undefined;
        while (true) {
            // Reset first, then drain: a put that lands after the drain sets
            // the event again, so the wait below returns at once.
            self.wake.reset();
            const n = self.queue.get(io, &batch, 0) catch break;
            if (n == 0) {
                self.wake.waitTimeout(io, .{ .duration = .{
                    .raw = .fromMilliseconds(self.idle_ms),
                    .clock = .awake,
                } }) catch |err| switch (err) {
                    error.Timeout => _ = self.idle_wakes.fetchAdd(1, .monotonic),
                    error.Canceled => {
                        _ = self.canceled.fetchAdd(1, .release);
                        break;
                    },
                };
                continue;
            }
            for (batch[0..n]) |item| {
                item.written = true;
                // Counted before the answer, so a test that has the answer
                // has the count.
                _ = self.answered.fetchAdd(1, .release);
                item.done.set(io);
            }
        }
        self.queue.close(io);
        while (true) {
            const n = self.queue.getUncancelable(io, &batch, 1) catch return;
            for (batch[0..n]) |item| item.done.set(io);
        }
    }

    fn append(io: std.Io, self: *IdleWriter) ![]const u8 {
        self.route_loop.store(@intFromPtr(io.userdata), .release);
        var item: Item = .{};
        try self.queue.putOne(io, &item);
        self.wake.set(io);
        item.done.waitUncancelable(io);
        return if (item.written) "written" else "refused";
    }
};

/// Wait for `counter` to reach `want`, or give up. Bounded for the reason
/// `waitForATick` is (`CLAUDE.md`).
fn waitForCount(counter: *const std.atomic.Value(u32), want: u32) !void {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    for (0..500) |_| {
        if (counter.load(.acquire) >= want) return;
        try std.Io.sleep(threaded.io(), .fromMilliseconds(10), .awake);
    }
    return error.NeverReached;
}

test "a fiber app.spawn started takes the server's loop, answers a route, and wakes on its idle deadline with no request" {
    hush();
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    var writer: IdleWriter = .{};
    writer.init();
    try app.provide(&writer);
    try app.post("/append", IdleWriter.append);
    try app.spawn(IdleWriter.run, .{&writer});

    const live = try nilo.testing.Live.start(gpa, &app, .{ .threads = 1 });
    var stopped = false;
    defer if (!stopped) live.stop() catch {};

    const answer = try ask(gpa, live.port, "POST /append HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    defer answer.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, answer.head, "HTTP/1.1 200"));
    try testing.expectEqualStrings("written", answer.body);
    try testing.expectEqual(@as(u32, 1), writer.answered.load(.acquire));

    // The writer and the route hold the one loop the connections run on, and
    // it is not the Io the test's own client runs on.
    const loop = writer.writer_loop.load(.acquire);
    try testing.expect(loop != 0);
    try testing.expectEqual(loop, writer.route_loop.load(.acquire));
    try testing.expect(loop != @intFromPtr(live.clientIo().userdata));

    // No further request: the writer is idle, and its deadline passes twice.
    const before = writer.idle_wakes.load(.monotonic);
    try waitForCount(&writer.idle_wakes, before + 2);
    try testing.expectEqual(@as(u32, 1), writer.answered.load(.acquire));

    stopped = true;
    try live.stop();
    try waitForCount(&writer.canceled, 1);
}

/// Background work that swallows its cancel: a job whose call the stop
/// cancelled reads it as an ordinary failure, logs, and carries on, the
/// way any `catch |err| log` does. Parked almost all the time in the long
/// wait, so that is where the stop's one cancel lands.
const Swallower = struct {
    started: std.atomic.Value(u32) = .init(0),
    swallowed: std.atomic.Value(u32) = .init(0),
    gone: std.atomic.Value(u32) = .init(0),

    fn run(self: *Swallower) void {
        defer _ = self.gone.fetchAdd(1, .release);
        _ = self.started.fetchAdd(1, .release);
        while (true) {
            nilo.sleep(60_000) catch {
                _ = self.swallowed.fetchAdd(1, .release);
            };
            nilo.sleep(10) catch return; // the server is going
        }
    }
};

test "spawned work that swallowed the stop's cancel still stops at its next sleep, and the server with it" {
    hush();
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    var work: Swallower = .{};
    try app.spawn(Swallower.run, .{&work});

    const live = try nilo.testing.Live.start(gpa, &app, .{ .threads = 1 });
    try waitForCount(&work.started, 1);
    // Before the fix the cancel was spent on the first wait, the second
    // slept on as though nothing had happened, and the loop went round
    // for good: `listen()` never returned and this was ServerDidNotStop.
    try live.stop();
    try testing.expectEqual(@as(u32, 1), work.swallowed.load(.acquire));
    try testing.expectEqual(@as(u32, 1), work.gone.load(.acquire));
}

/// `s` written `n` times over, at compile time: what `s ** n` said before
/// Zig 0.17 took the operator away.
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    // A comptime-known constant, so that `&built` is a pointer into the
    // binary and the call is as good at runtime as `**` was.
    const built = comptime blk: {
        @setEvalBranchQuota(10 * n + 1000);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        break :blk final;
    };
    return &built;
}
