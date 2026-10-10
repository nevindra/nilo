//! The tests of a TLS listener, which need a server that is actually running
//! and a client that is not nilo's.
//!
//! The client is `std.crypto.tls.Client`, the standard library's own, driven
//! on `std.Io.Threaded` with no zio anywhere on this side. That is what makes
//! an answer evidence: the handshake is between two implementations that
//! share no code, the certificate is checked by the client the way a browser
//! would check it (self-signed, and issued for the name asked for), and a
//! record that nilo's side wrote wrong would be refused by somebody who did
//! not write it. A test of the library talking to itself would show that its
//! two halves agree, which is not the question.
//!
//! Compiled only into a build that has TLS in it: `http.zig` imports this
//! file under `@import("nilo_build").tls`, and `build.zig` sets that for the
//! repository's own http test root whether or not `-Dtls` was passed, so the
//! feature is held by `zig build test` and not by whoever remembers a flag
//! ([ADR 212](../docs/adr/212-tls-is-an-option-a-build-asks-for.md)).
//!
//! Every port is 0 and read back, the way `live.zig` does it. The
//! certificate is `testdata/tls/localhost.pem`, a self-signed ECDSA P-256
//! certificate for `localhost` and `127.0.0.1` with a century on it, and
//! its key beside it. The key is not a secret: it signs nothing but this
//! suite's handshakes, on loopback, for a process that is gone a second
//! later.

const std = @import("std");
const nilo = @import("http.zig");

const testing = std.testing;

const cert_path = "http/testdata/tls/localhost.pem";
const key_path = "http/testdata/tls/localhost-key.pem";

/// Quieten the log for one test; see `live.zig` for why every test here
/// starts with it.
fn hush() void {
    std.testing.log_level = .err;
}

fn hello() []const u8 {
    return "hello over tls\n";
}

/// The server under test on a thread of its own, the way `live.zig`'s
/// `ServingAt` does it, with a certificate and whatever header limit the
/// test wants.
const ServingTls = struct {
    app: *nilo.App,
    header_timeout_ms: u32 = 10_000,
    idle_timeout_ms: u32 = 75_000,
    bound: std.atomic.Value(bool) = .init(true),
    /// Set once `tryListen` has returned, so a test can bound how long a
    /// stop takes rather than join a thread that may never come back.
    stopped: std.atomic.Value(bool) = .init(false),

    fn run(self: *ServingTls) void {
        self.app.tryListen(.{
            .port = 0,
            .threads = 1,
            .stop_on_signal = false,
            .header_timeout_ms = self.header_timeout_ms,
            .idle_timeout_ms = self.idle_timeout_ms,
            .tls = .{ .cert = cert_path, .key = key_path },
        }) catch {
            self.bound.store(false, .release);
        };
        self.stopped.store(true, .release);
    }
};

/// The port the server took, once it has. Bounded, because a server that
/// never binds has to fail here rather than leave the suite waiting.
fn waitForPort(gpa: std.mem.Allocator, serving: *const ServingTls) !u16 {
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

/// A TCP connection to the port, with the first attempts forgiven while the
/// server is still coming up.
fn connect(io: std.Io, port: u16) !std.Io.net.Stream {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    return for (0..300) |_| {
        break address.connect(io, .{ .mode = .stream }) catch {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        };
    } else error.ServerNeverCameUp;
}

/// Whatever the server sends next, or nothing, with a ceiling on the wait:
/// a server that never answers and never hangs up has to be a failed test
/// rather than a suite that does not finish (`CLAUDE.md`). `poll` and a raw
/// `read` rather than the stream's reader, because `std.Io.Threaded` treats
/// a receive timeout on a socket as a programmer error and panics on it.
fn readSome(stream: std.Io.net.Stream, buf: []u8) !usize {
    var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&fds, 5_000) == 0) return error.ServerNeverHungUp;
    return std.posix.read(stream.socket.handle, buf);
}

/// A client on top of a stream, handshaken and checking the certificate.
///
/// `.self_signed` and `.explicit = "localhost"` are the two checks a browser
/// makes against a certificate it has been told to trust: that it is signed
/// by the key it carries, and that it was issued for the name asked for.
/// `no_verification` on either would pass whatever the server sent.
const Client = struct {
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    in_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    out_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined,
    tls_in: [2 * std.crypto.tls.max_ciphertext_record_len]u8 = undefined,
    tls_out: [1024]u8 = undefined,
    client: std.crypto.tls.Client = undefined,

    fn handshake(self: *Client, io: std.Io, stream: std.Io.net.Stream) !void {
        self.reader = stream.reader(io, &self.in_buf);
        self.writer = stream.writer(io, &self.out_buf);
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        try std.Io.randomSecure(io, &entropy);
        self.client = try std.crypto.tls.Client.init(&self.reader.interface, &self.writer.interface, .{
            .host = .{ .explicit = "localhost" },
            .ca = .self_signed,
            .write_buffer = &self.tls_out,
            .read_buffer = &self.tls_in,
            .entropy = &entropy,
            .realtime_now = std.Io.Clock.real.now(io),
        });
    }

    /// One request, and the head of its answer plus exactly the body the
    /// head announced, without waiting for the server to hang up: the
    /// connection is meant to stay open. A server that hangs up early is
    /// `error.EndOfStream` from the reader, which is the failure.
    fn ask(self: *Client, gpa: std.mem.Allocator, request: []const u8) ![]u8 {
        try self.client.writer.writeAll(request);
        try self.client.writer.flush();
        try self.writer.interface.flush();

        var whole: std.ArrayList(u8) = .empty;
        defer whole.deinit(gpa);
        const r = &self.client.reader;
        var length: ?usize = null;
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            try whole.appendSlice(gpa, line);
            if (std.mem.eql(u8, line, "\r\n")) break;
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                const digits = std.mem.trim(u8, line["content-length:".len..], " \r\n");
                length = try std.fmt.parseInt(usize, digits, 10);
            }
        }
        const body = try r.readAlloc(gpa, length orelse return error.NoContentLength);
        defer gpa.free(body);
        try whole.appendSlice(gpa, body);
        return whole.toOwnedSlice(gpa);
    }

    /// Whether a byte can be read without asking the socket: the TLS layer
    /// above it or the buffer under it already holds one.
    fn holdsBytes(self: *Client) bool {
        return self.client.reader.bufferedLen() > 0 or self.reader.interface.bufferedLen() > 0;
    }

    /// Exactly `buf.len` bytes of cleartext, each wait for the socket bounded
    /// by `limit_ms`. Only a wait that has nothing buffered asks the kernel,
    /// so a record the library already holds is never mistaken for silence.
    /// A server that stops answering is `error.ServerWentQuiet` here, where
    /// the stream's own reader would wait for it (see `readSome`).
    fn readWithin(self: *Client, buf: []u8, limit_ms: i32) !void {
        var have: usize = 0;
        while (have < buf.len) {
            if (!self.holdsBytes()) {
                var fds = [_]std.posix.pollfd{.{ .fd = self.reader.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                if (try std.posix.poll(&fds, limit_ms) == 0) return error.ServerWentQuiet;
            }
            const got = try self.client.reader.peekGreedy(1);
            const n = @min(got.len, buf.len - have);
            @memcpy(buf[have..][0..n], got[0..n]);
            self.client.reader.toss(n);
            have += n;
        }
    }
};

test "a request over TLS is answered, and the certificate is the one the listener was given" {
    hush();
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/", hello);

    var serving: ServingTls = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, ServingTls.run, .{&serving});
    const port = try waitForPort(gpa, &serving);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stream = try connect(io, port);
    var client: Client = undefined;
    try client.handshake(io, stream);
    const answer = try client.ask(gpa, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer gpa.free(answer);
    // Closed before the stop, the way `live.zig`'s `ask` does: the server
    // is not being asked to take a connection away from a client here.
    stream.close(io);

    app.shutdown();
    thread.join();

    try testing.expect(std.mem.startsWith(u8, answer, "HTTP/1.1 200 "));
    try testing.expect(std.mem.endsWith(u8, answer, "hello over tls\n"));
}

test "a TLS connection kept alive answers again after idling past the peek, on the same handshake" {
    hush();
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/", hello);

    var serving: ServingTls = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, ServingTls.run, .{&serving});
    const port = try waitForPort(gpa, &serving);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stream = try connect(io, port);
    var client: Client = undefined;
    try client.handshake(io, stream);

    const first = try client.ask(gpa, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer gpa.free(first);
    // Longer than the 200ms peek a connection between requests waits before
    // it gives its pages back (ADR 062). What is being checked is that the
    // record layer under those pages is still a record layer afterwards:
    // the release must not have discarded a byte the next record needs.
    try std.Io.sleep(io, .fromMilliseconds(450), .awake);
    const second = try client.ask(gpa, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer gpa.free(second);
    stream.close(io);

    app.shutdown();
    thread.join();

    try testing.expect(std.mem.startsWith(u8, first, "HTTP/1.1 200 "));
    try testing.expect(std.mem.startsWith(u8, second, "HTTP/1.1 200 "));
    try testing.expect(std.mem.endsWith(u8, second, "hello over tls\n"));
}

test "an answer to a request whose body nobody read goes out at once over TLS" {
    // The head and a small body arrive in one record, and the handler
    // answers without reading the body. `settle` skips the flush while the
    // read buffer holds bytes, trusting the Engine to flush before its next
    // read (ADR 201); on TLS the answer sits in the cleartext writer above
    // the one the Engine flushes, so it waited for the idle limit.
    hush();
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.post("/", hello);

    var serving: ServingTls = .{ .app = &app, .idle_timeout_ms = 3_000 };
    const thread = try std.Thread.spawn(.{}, ServingTls.run, .{&serving});
    const port = try waitForPort(gpa, &serving);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stream = try connect(io, port);
    var client: Client = undefined;
    try client.handshake(io, stream);

    const started = std.Io.Clock.awake.now(io);
    const answer = try client.ask(gpa, "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello");
    defer gpa.free(answer);
    const took = started.durationTo(std.Io.Clock.awake.now(io));
    stream.close(io);

    app.shutdown();
    thread.join();

    try testing.expect(std.mem.startsWith(u8, answer, "HTTP/1.1 200 "));
    // Well under the idle limit, which is when it used to arrive.
    try testing.expect(took.toMilliseconds() < 1_000);
}

test "a client that connects to a TLS port and says nothing is dropped when the header limit runs out" {
    hush();
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/", hello);

    var serving: ServingTls = .{ .app = &app, .header_timeout_ms = 200 };
    const thread = try std.Thread.spawn(.{}, ServingTls.run, .{&serving});
    const port = try waitForPort(gpa, &serving);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stream = try connect(io, port);
    // Not a byte sent. Before the handshake had a deadline this held the
    // fiber and its 33 KB for ever; now the server hangs up at 200ms, which
    // the read below sees as end of stream.
    var buf: [64]u8 = undefined;
    const got = try readSome(stream, &buf);
    stream.close(io);

    app.shutdown();
    thread.join();

    try testing.expectEqual(@as(usize, 0), got);
}

test "plain HTTP sent to a TLS port is refused rather than answered" {
    hush();
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/", hello);

    // The header limit is what ends this one too. The library reads a
    // record's length from the first bytes before it looks at what they
    // are, so "GET /" is taken as a 12 KB record that never finishes rather
    // than refused on sight; the deadline is what turns that into a hang-up
    // rather than a fiber held for ever (ADR 212, the section on what the
    // library does not do yet).
    var serving: ServingTls = .{ .app = &app, .header_timeout_ms = 200 };
    const thread = try std.Thread.spawn(.{}, ServingTls.run, .{&serving});
    const port = try waitForPort(gpa, &serving);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stream = try connect(io, port);
    var out_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();
    // What comes back is a TLS alert or nothing, and then the end of the
    // stream. What must not come back is an HTTP response: a listener told
    // to encrypt that answered a plain request would be the failure a
    // deployment could not see.
    var buf: [256]u8 = undefined;
    const got = try readSome(stream, &buf);
    stream.close(io);

    app.shutdown();
    thread.join();

    try testing.expect(!std.mem.startsWith(u8, buf[0..got], "HTTP/"));
}

test "a stop comes back with an idle TLS connection still open, within the idle limit" {
    hush();
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/", hello);

    // The idle limit is what bounds this today, on a TLS connection and on
    // a plain one alike: a stop cancels the read the connection is parked
    // in, and the loop's next read parks again until the client speaks,
    // hangs up, or the idle limit runs out. What this test holds is that
    // the record layer adds nothing to that: no wait in `close_notify`, no
    // wait in the release of its buffers, nothing a plain connection would
    // not also do. Short, so the suite is not held for the default 75s.
    var serving: ServingTls = .{ .app = &app, .idle_timeout_ms = 1_000 };
    const thread = try std.Thread.spawn(.{}, ServingTls.run, .{&serving});
    const port = try waitForPort(gpa, &serving);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stream = try connect(io, port);
    var client: Client = undefined;
    try client.handshake(io, stream);
    const first = try client.ask(gpa, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer gpa.free(first);
    // Idle past the peek, so the connection is parked where an idle one
    // parks, with its pages given back, when the stop arrives.
    try std.Io.sleep(io, .fromMilliseconds(450), .awake);

    // The connection stays open across the stop. It has to come back on
    // its own; the client closing its end would be the test doing the
    // server's job for it, so that happens only after the verdict is in.
    const started = std.Io.Clock.awake.now(io);
    app.shutdown();
    const came_back = for (0..500) |_| {
        if (serving.stopped.load(.acquire)) break true;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    } else false;
    const took_ms = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    stream.close(io);
    thread.join();

    if (!came_back) return error.StopNeverCameBack;
    // The idle limit plus the stop's own polling, and well under the 10s
    // grace, which an idle connection is not charged against.
    if (took_ms >= 3000) return error.StopHeldPastTheIdleLimit;
}

/// The shape a server behind no proxy actually wants, and the one the
/// benchmark arena's profiles ask for: **HTTPS and cleartext at the same
/// time, from one process, over one set of routes**
/// ([ADR 213](../docs/adr/213-a-server-answers-on-more-than-one-address.md)).
///
/// TLS on the listener `Options` itself names, because that is the one
/// `boundPort()` answers for and the client below needs a number. The
/// cleartext half goes on a unix socket rather than a second port, for the
/// reason `live.zig` gives: a path cannot collide with the other optimize
/// mode running this same suite beside us, and what is being tested is that
/// each listener keeps its own way of carrying bytes rather than that the
/// loop ran twice.
const ServingTlsAndPlain = struct {
    app: *nilo.App,
    path: []const u8,
    bound: std.atomic.Value(bool) = .init(true),

    fn run(self: *ServingTlsAndPlain) void {
        var buf: [std.Io.net.UnixAddress.max_len + 8]u8 = undefined;
        const beside = std.fmt.bufPrint(&buf, "unix:{s}", .{self.path}) catch {
            self.bound.store(false, .release);
            return;
        };
        self.app.tryListen(.{
            .port = 0,
            .threads = 1,
            .stop_on_signal = false,
            .tls = .{ .cert = cert_path, .key = key_path },
            .also = &.{.{ .address = beside }},
        }) catch {
            self.bound.store(false, .release);
        };
    }
};

test "a TLS listener and a cleartext one answer in one process, over the same routes" {
    hush();
    const gpa = std.heap.smp_allocator;

    var tmp = nilo.testing.tmpDir();
    defer tmp.cleanup();
    const path = try tmp.pathAlloc(gpa, "plain.sock");
    defer gpa.free(path);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/", hello);

    var serving: ServingTlsAndPlain = .{ .app = &app, .path = path };
    const thread = try std.Thread.spawn(.{}, ServingTlsAndPlain.run, .{&serving});
    var stopped = false;
    defer if (!stopped) {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    };

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Waited for against this harness's own flag rather than `waitForPort`,
    // which takes the other one.
    const port = for (0..300) |_| {
        if (app.boundPort()) |p| break p;
        if (!serving.bound.load(.acquire)) return error.ServerNeverCameUp;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    } else return error.ServerNeverCameUp;

    // The encrypted half, handshaken by a client that shares no code with
    // the server and checks the certificate the way a browser would.
    const stream = try connect(io, port);
    var client: Client = undefined;
    try client.handshake(io, stream);
    const secure = try client.ask(gpa, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer gpa.free(secure);
    stream.close(io);
    try testing.expect(std.mem.startsWith(u8, secure, "HTTP/1.1 200 "));
    try testing.expect(std.mem.endsWith(u8, secure, "hello over tls\n"));

    // The cleartext half, at the same moment, from the same App. No
    // handshake, no records, and the same handler at the end of it: what
    // the listener decides is how the bytes are carried, and nothing above
    // it is told which one they came in on.
    const address = try std.Io.net.UnixAddress.init(path);
    var plain: std.Io.net.Stream = for (0..300) |_| {
        break address.connect(io) catch {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        };
    } else return error.ServerNeverCameUp;
    defer plain.close(io);

    var out: [256]u8 = undefined;
    var writer = plain.writer(io, &out);
    try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: nilo\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();

    var seen: [1024]u8 = undefined;
    const n = try readSome(plain, &seen);
    try testing.expect(std.mem.startsWith(u8, seen[0..n], "HTTP/1.1 200 "));
    try testing.expect(std.mem.indexOf(u8, seen[0..n], "hello over tls\n") != null);

    app.shutdown();
    thread.join();
    stopped = true;
}

// ---- large answers: the record buffer holds several records, and a drain keeps a byte back ----

/// Bytes that say where they are, so a record sealed in the wrong order or
/// dropped is a different byte rather than the same filler.
fn pattern(i: usize) u8 {
    return @truncate((i *% 2654435761) >> 7);
}

const big_len = 300 * 1000 + 17;

var big_body: [big_len]u8 = undefined;

fn bigBody(c: *nilo.Ctx) !void {
    try c.send(200, "application/octet-stream", &big_body);
}

const Spilled = struct {
    tmp: nilo.testing.TmpDir,
    dir: nilo.Dir,
};

fn bigFile(files: *Spilled) !nilo.FileBody {
    return .{ .dir = files.dir, .name = "big.bin", .content_type = "application/octet-stream" };
}

test "a body of 300 KB, a file and a small answer after them cross a TLS connection whole and in order" {
    hush();
    const gpa = std.heap.smp_allocator;
    for (&big_body, 0..) |*b, i| b.* = pattern(i);

    var files: Spilled = .{ .tmp = nilo.testing.tmpDir(), .dir = undefined };
    defer files.tmp.cleanup();
    try files.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.bin", .data = &big_body });
    var path_buf: [128]u8 = undefined;
    files.dir = try nilo.Dir.open(try files.tmp.path(&path_buf, ""));
    defer files.dir.close();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.provide(&files);
    try app.get("/", hello);
    try app.get("/big", bigBody);
    try app.get("/file", bigFile);

    var serving: ServingTls = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, ServingTls.run, .{&serving});
    const port = try waitForPort(gpa, &serving);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stream = try connect(io, port);
    var client: Client = undefined;
    try client.handshake(io, stream);

    // One connection, in a row: each answer is whole before the next is
    // asked for, so a byte held back in the cleartext buffer and not sent
    // by the flush would stall the next read for the whole of its wait.
    for ([_][]const u8{ "/big", "/file", "/", "/big", "/file" }) |path| {
        var request: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&request, "GET {s} HTTP/1.1\r\nHost: localhost\r\n\r\n", .{path});
        const answer = try client.ask(gpa, text);
        defer gpa.free(answer);
        try testing.expect(std.mem.startsWith(u8, answer, "HTTP/1.1 200 "));
        const at = std.mem.indexOf(u8, answer, "\r\n\r\n").? + 4;
        if (std.mem.eql(u8, path, "/")) {
            try testing.expectEqualStrings("hello over tls\n", answer[at..]);
        } else {
            try testing.expectEqual(@as(usize, big_len), answer.len - at);
            try testing.expect(std.mem.eql(u8, &big_body, answer[at..]));
        }
    }
    stream.close(io);

    app.shutdown();
    thread.join();
}

fn echoOnly(socket: *nilo.Socket) !void {
    while (try socket.receive()) |message| try socket.send(message.kind, message.data);
}

fn echoRoute(c: *nilo.Ctx) anyerror!void {
    return c.upgrade(echoOnly, {});
}

/// A masked text frame, the shape a client sends (RFC 6455 section 5.3).
fn maskedText(out: []u8, text: []const u8) []const u8 {
    out[0] = 0x81;
    out[1] = 0x80 | @as(u8, @intCast(text.len));
    const key = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    @memcpy(out[2..6], &key);
    for (text, 0..) |b, i| out[6 + i] = b ^ key[i % 4];
    return out[0 .. 6 + text.len];
}

test "a second WebSocket frame that arrived over TLS with the first is echoed, not waited for" {
    // Two frames, each its own TLS record, leave in one socket write, so the
    // server's record layer holds the second whole when its first read has
    // only decrypted the first. `Wake.wait` answers `.readable` for a whole
    // record it holds (`held`, ADR 259); a WebSocket's `park` waits in it
    // too, so this is the test that fails if that line is lost: the second
    // echo then waits for a socket the kernel has emptied, until the
    // client speaks again or the idle limit (75 s here) runs out. The wait
    // is bounded at five seconds, a margin a loaded machine does not need
    // for a loopback echo, and the claim is the order: the second echo
    // arrives with nothing sent after the two frames.
    hush();
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/ws", echoRoute);

    var serving: ServingTls = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, ServingTls.run, .{&serving});
    const port = try waitForPort(gpa, &serving);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stream = try connect(io, port);
    var client: Client = undefined;
    try client.handshake(io, stream);

    try client.client.writer.writeAll("GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" ++
        "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n");
    try client.client.writer.flush();
    try client.writer.interface.flush();
    // The 101's head, a byte at a time so nothing past it is taken.
    var head: [512]u8 = undefined;
    var head_len: usize = 0;
    while (!std.mem.endsWith(u8, head[0..head_len], "\r\n\r\n")) {
        try client.readWithin(head[head_len..][0..1], 5_000);
        head_len += 1;
    }
    try testing.expect(std.mem.startsWith(u8, head[0..head_len], "HTTP/1.1 101 "));

    // Each frame is its own record, staged apart from the socket and then
    // written in one go: flushing the library's writer would send each record
    // on its own, and the server would have read the first before the second
    // was written.
    // The library asks its output for a whole record's room before it writes.
    var staging: [3 * std.crypto.tls.max_ciphertext_record_len]u8 = undefined;
    var staged: std.Io.Writer = .fixed(&staging);
    const wire = client.client.output;
    client.client.output = &staged;
    var one: [16]u8 = undefined;
    var two: [16]u8 = undefined;
    try client.client.writer.writeAll(maskedText(&one, "one"));
    try client.client.writer.flush();
    try client.client.writer.writeAll(maskedText(&two, "two"));
    try client.client.writer.flush();
    client.client.output = wire;
    try testing.expect(staged.end > 2 * (5 + 6 + 3));
    try wire.writeAll(staged.buffered());
    try wire.flush();

    var echo: [5]u8 = undefined;
    try client.readWithin(&echo, 5_000);
    try testing.expectEqualSlices(u8, &.{ 0x81, 3, 'o', 'n', 'e' }, echo[0..5]);
    try client.readWithin(&echo, 5_000);
    try testing.expectEqualSlices(u8, &.{ 0x81, 3, 't', 'w', 'o' }, echo[0..5]);

    stream.close(io);
    app.shutdown();
    thread.join();
}
