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
//! ([ADR 0037](../docs/adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)),
//! which by [ADR 0033](../docs/adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
//! is the same standing as a guard only ever seen to pass. A real socket is the
//! only thing that reaches it.
//!
//! **41,200–42,199 is this file's port range.** `fetch/live.zig` has
//! 39,200–40,199 and `s3/canned.zig` has 40,200–41,199, and nothing but these
//! three comments keeps them apart — `std.Io.net.Server` cannot report the port
//! it was given, so binding zero and reading it back is not available. The walk
//! starts at the thread id and wraps, for the reason `fetch/live.zig` spells
//! out at length: a fixed start walks back over the ports the last run left in
//! `TIME-WAIT`.

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

// ---- a file leaving by the route the rest of the suite never takes ----

/// The server for the `sendfile` tests: a real port, because that is the whole
/// point (see the header).
const ServingAt = struct {
    app: *nilo.App,
    port: u16,
    bound: std.atomic.Value(bool) = .init(true),

    fn run(self: *ServingAt) void {
        self.app.tryListen(.{
            .port = self.port,
            .threads = 1,
            .stop_on_signal = false,
        }) catch {
            self.bound.store(false, .release);
        };
    }
};

/// A free port in this file's range. See the header for why it is a walk.
fn freePort() !u16 {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const first: u16 = 41_200;
    const count: u16 = 1_000;
    const start: u16 = @intCast(@as(u64, std.Thread.getCurrentId()) % count);
    var tried: u16 = 0;
    while (tried < count) : (tried += 1) {
        const candidate = first + (start + tried) % count;
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(candidate) };
        // Bound and closed again rather than held: the App does its own
        // binding, and holding this one would guarantee the collision it is
        // being asked about. A racing binder between the two is possible and
        // is what `bound` below reports.
        var server = address.listen(io, .{}) catch continue;
        server.socket.close(io);
        return candidate;
    }
    return error.NoFreePort;
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
    tmp: std.testing.TmpDir,
    path: []u8,

    /// Longer than one page and not a round number of them, so a partial last
    /// chunk is exercised rather than an exact multiple.
    const contents = "nilo sends this from a descriptor, not from memory. " ** 200;

    fn init(gpa: std.mem.Allocator) !Spilled {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.txt", .data = contents });
        return .{
            .tmp = tmp,
            .path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path}),
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

    var serving: ServingAt = .{ .app = &app, .port = try freePort() };
    const thread = try std.Thread.spawn(.{}, ServingAt.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }

    const whole = try ask(gpa, serving.port,
        "GET /files/big.txt HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer whole.deinit(gpa);

    try testing.expect(std.mem.startsWith(u8, whole.head, "HTTP/1.1 200 "));
    try testing.expectEqualStrings(Spilled.contents, whole.body);

    // The other arm of `sendfile.send`, and the one a resumed download takes:
    // a seek, a shorter length, and a 206 saying which bytes these are.
    const part = try ask(gpa, serving.port,
        "GET /files/big.txt HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=10-19\r\n" ++
            "Connection: close\r\n\r\n");
    defer part.deinit(gpa);

    try testing.expect(std.mem.startsWith(u8, part.head, "HTTP/1.1 206 "));
    try testing.expectEqualStrings(Spilled.contents[10..20], part.body);
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
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init(gpa: std.mem.Allocator, name: []const u8) !SocketDir {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{
            .tmp = tmp,
            .path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name }),
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
/// ([ADR 0029](../docs/adr/0029-a-spawned-fiber-belongs-to-the-server.md)),
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
        // (ADR 0130).
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

    const forwarded = try askOverPath(gpa, where.path,
        "GET /who HTTP/1.1\r\nHost: nilo\r\nX-Forwarded-For: 203.0.113.9\r\n" ++
            "Connection: close\r\n\r\n");
    defer forwarded.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, forwarded.head, "HTTP/1.1 200 "));
    try testing.expectEqualStrings("203.0.113.9", forwarded.body);

    // Nothing forwarded, so there is nobody to name: a unix connection has no
    // address of its own to fall back to.
    const bare = try askOverPath(gpa, where.path,
        "GET /who HTTP/1.1\r\nHost: nilo\r\nConnection: close\r\n\r\n");
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
    const answer = try askOverPath(gpa, where.path,
        "GET /who HTTP/1.1\r\nHost: nilo\r\nConnection: close\r\n\r\n");
    defer answer.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, answer.head, "HTTP/1.1 200 "));
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
