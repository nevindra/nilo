//! An `https://` call through an egress proxy, against a real TLS server and a
//! real `CONNECT` proxy ([ADR 267](../docs/adr/267-a-call-can-go-through-a-proxy-and-trust-a-private-authority.md)),
//! and a call that does not verify the certificate, against the same server
//! when the client trusts nothing ([ADR 290](../docs/adr/290-a-call-can-skip-the-certificate-check-and-only-that-call.md)).
//!
//! `fetch/live.zig` has no TLS server, so until this file the claim that
//! std's tunnel never starts TLS was a reading of `std.http.Client.connect`
//! and not a run. The first test here is the run: std's own path, handed a
//! proxy that supports `CONNECT`, is watched sending `GET` as text where a
//! handshake belongs. It stays as a canary for the day std fixes it, when
//! `Exchange.dialTls` can go.
//!
//! The server is nilo's own TLS listener on `http/testdata/tls/localhost.pem`,
//! a self-signed certificate for `localhost` and `127.0.0.1`, which is also
//! the roots the client is given. The proxy is the one in this file: it reads
//! the `CONNECT`, answers it, and copies bytes both ways, recording the head
//! and the first byte that crossed so a test can tell a handshake from text.
//! It connects to the server whatever name the `CONNECT` asked for, which is
//! how a test can ask for a name the certificate does not carry.
//!
//! **This file names `nilo_http`, which is upward**, for the reason
//! `fetch/deadline.zig` does and under the same `in_tests` entry; it has a
//! build step of its own (`test-fetch-engine`) so that `zig test
//! fetch/fetch.zig` still needs no server (ADR 061).

const std = @import("std");
const nilo = @import("nilo_http");
const core = @import("nilo_core");
const fetch = @import("nilo_fetch");

const testing = std.testing;

const cert_path = "http/testdata/tls/localhost.pem";
const key_path = "http/testdata/tls/localhost-key.pem";

/// See `fetch/deadline.zig` for why a listener in a test warns and why this is
/// how it is quietened.
fn hush() void {
    std.testing.log_level = .err;
}

fn hello() []const u8 {
    return "hello over tls\n";
}

/// A body read back. Taking it as a parameter is the point: the handler
/// cannot run until every byte the head announced has arrived, so a body
/// the client left in its TLS buffer is a call that never answers.
const Note = struct { text: nilo.Str };

fn echo(note: Note) Note {
    return note;
}

/// A redirect that leaves the origin: `127.0.0.1` for the `localhost` the
/// test called, on the same port. Written once the server is up, before
/// any request, so the handler reads a settled value.
var away_location: [64]u8 = undefined;
var away_len: usize = 0;

fn away() nilo.Redirect(302) {
    return .to(away_location[0..away_len]);
}

/// A handler that redirects to `to`, one per hop of a chain.
fn hopTo(comptime to: []const u8) fn () nilo.Redirect(302) {
    return struct {
        fn h() nilo.Redirect(302) {
            return .to(to);
        }
    }.h;
}

/// The nilo TLS server on a thread of its own.
const Server = struct {
    app: nilo.App,
    bound: std.atomic.Value(bool) = .init(true),
    thread: ?std.Thread = null,

    fn start(self: *Server, io: std.Io) !u16 {
        self.app = nilo.App.init(testing.allocator);
        try self.app.get("/", hello);
        // A chain of five hops inside one origin, a loop, and a way out.
        try self.app.get("/c5", hopTo("/c4"));
        try self.app.get("/c4", hopTo("/c3"));
        try self.app.get("/c3", hopTo("/c2"));
        try self.app.get("/c2", hopTo("/c1"));
        try self.app.get("/c1", hopTo("/"));
        try self.app.get("/loop-a", hopTo("/loop-b"));
        try self.app.get("/loop-b", hopTo("/loop-a"));
        try self.app.get("/away", away);
        try self.app.post("/echo", echo);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        for (0..500) |_| {
            if (self.app.boundPort()) |port| return port;
            if (!self.bound.load(.acquire)) return error.ServerNeverCameUp;
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
        }
        return error.ServerNeverCameUp;
    }

    fn run(self: *Server) void {
        self.app.tryListen(.{
            .port = 0,
            .threads = 1,
            .stop_on_signal = false,
            .tls = .{ .cert = cert_path, .key = key_path },
        }) catch self.bound.store(false, .release);
    }

    fn stop(self: *Server) void {
        if (self.bound.load(.acquire)) self.app.shutdown();
        if (self.thread) |t| t.join();
        self.app.deinit();
    }
};

/// A `CONNECT` proxy. One accept thread; each connection is served by a
/// thread of its own, which pumps the two directions.
const Proxy = struct {
    server: std.Io.net.Server,
    io: std.Io,
    port: u16,
    /// Where every tunnel leads, whatever name the `CONNECT` asked for.
    target_port: u16,
    /// A status line to answer with instead of opening a tunnel.
    refuse: ?[]const u8 = null,
    /// The `Proxy-Authorization` value a `CONNECT` must carry, or a 407.
    require: ?[]const u8 = null,
    done: std.atomic.Value(bool) = .init(false),
    finished: bool = false,
    /// Tunnels opened, and the first byte the client sent into the latest
    /// (-1 until one did): 0x16 is a TLS handshake, `G` is a request in the
    /// clear.
    connects: std.atomic.Value(u32) = .init(0),
    after_connect: std.atomic.Value(i16) = .init(-1),
    head: [1024]u8 = undefined,
    head_len: usize = 0,
    accept_thread: ?std.Thread = null,
    handlers: [8]?std.Thread = @splat(null),
    handled: usize = 0,

    fn open(io: std.Io, target_port: u16) !Proxy {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const server = try address.listen(io, .{});
        return .{ .server = server, .io = io, .port = server.socket.address.getPort(), .target_port = target_port };
    }

    fn begin(self: *Proxy) !void {
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    fn acceptLoop(self: *Proxy) void {
        while (!self.done.load(.acquire)) {
            const stream = self.server.accept(self.io) catch return;
            if (self.done.load(.acquire) or self.handled == self.handlers.len) {
                stream.close(self.io);
                return;
            }
            self.handlers[self.handled] = std.Thread.spawn(.{}, serve, .{ self, stream }) catch {
                stream.close(self.io);
                return;
            };
            self.handled += 1;
        }
    }

    fn finish(self: *Proxy) void {
        if (self.finished) return;
        self.finished = true;
        self.done.store(true, .release);
        // One connection frees the `accept` the thread is parked in.
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (address.connect(self.io, .{ .mode = .stream })) |s| s.close(self.io) else |_| {}
        if (self.accept_thread) |t| t.join();
        for (self.handlers) |maybe| if (maybe) |t| t.join();
        self.server.deinit(self.io);
    }

    fn request(self: *const Proxy) []const u8 {
        return self.head[0..self.head_len];
    }

    fn serve(self: *Proxy, client: std.Io.net.Stream) void {
        var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        defer client.close(io);

        var buf: [2048]u8 = undefined;
        var have: usize = 0;
        const end = while (have < buf.len) {
            const n = std.posix.read(client.socket.handle, buf[have..]) catch return;
            if (n == 0) return;
            have += n;
            if (std.mem.indexOf(u8, buf[0..have], "\r\n\r\n")) |i| break i + 4;
        } else return;
        self.head_len = @min(end, self.head.len);
        @memcpy(self.head[0..self.head_len], buf[0..self.head_len]);

        var out: [256]u8 = undefined;
        var w = client.writer(io, &out);
        if (self.refuse) |status| {
            w.interface.print("HTTP/1.1 {s}\r\nContent-Length: 0\r\n\r\n", .{status}) catch return;
            w.interface.flush() catch {};
            return;
        }
        if (self.require) |value| {
            var line: [256]u8 = undefined;
            const want = std.fmt.bufPrint(&line, "Proxy-Authorization: {s}\r\n", .{value}) catch return;
            if (std.mem.indexOf(u8, buf[0..end], want) == null) {
                w.interface.writeAll("HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n") catch return;
                w.interface.flush() catch {};
                return;
            }
        }

        const upstream_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(self.target_port) };
        const upstream = upstream_address.connect(io, .{ .mode = .stream }) catch return;
        defer upstream.close(io);
        _ = self.connects.fetchAdd(1, .acq_rel);
        w.interface.writeAll("HTTP/1.1 200 Connection Established\r\n\r\n") catch return;
        w.interface.flush() catch return;

        const back = std.Thread.spawn(.{}, pump, .{ upstream, client, null }) catch return;
        // Whatever followed the head in the same read belongs to the tunnel.
        if (have > end) {
            var up: [256]u8 = undefined;
            var uw = upstream.writer(io, &up);
            uw.interface.writeAll(buf[end..have]) catch {};
            uw.interface.flush() catch {};
        }
        pump(client, upstream, &self.after_connect);
        back.join();
    }

    fn pump(from: std.Io.net.Stream, to: std.Io.net.Stream, first: ?*std.atomic.Value(i16)) void {
        var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var out: [4096]u8 = undefined;
        var w = to.writer(io, &out);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(from.socket.handle, &buf) catch break;
            if (n == 0) break;
            if (first) |f| if (f.load(.acquire) < 0) f.store(buf[0], .release);
            w.interface.writeAll(buf[0..n]) catch break;
            w.interface.flush() catch break;
        }
        to.shutdown(io, .send) catch {};
    }
};

/// Everything a test needs, in the order it has to be torn down.
const Rig = struct {
    threaded: std.Io.Threaded,
    server: Server,
    proxy: Proxy,
    roots: std.crypto.Certificate.Bundle,
    server_port: u16,

    fn up(rig: *Rig) !void {
        hush();
        rig.threaded = .init(testing.allocator, .{});
        rig.server = .{ .app = undefined };
        const io = rig.threaded.io();
        rig.server_port = try rig.server.start(io);
        rig.proxy = try Proxy.open(io, rig.server_port);
        away_len = (try std.fmt.bufPrint(&away_location, "https://127.0.0.1:{d}/", .{rig.server_port})).len;
        rig.roots = .empty;
        try rig.roots.addCertsFromFilePath(testing.allocator, io, std.Io.Clock.real.now(io), std.Io.Dir.cwd(), cert_path);
    }

    fn down(rig: *Rig) void {
        rig.roots.deinit(testing.allocator);
        rig.proxy.finish();
        rig.server.stop();
        rig.threaded.deinit();
    }

    fn loop(rig: *Rig) std.Io {
        return rig.threaded.io();
    }
};

test "std's own tunnel for an https target sends the request in the clear" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();
    try rig.proxy.begin();

    {
        var std_client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
        defer std_client.deinit();
        var proxy: std.http.Client.Proxy = .{
            .protocol = .plain,
            .host = .{ .bytes = "127.0.0.1" },
            .authorization = null,
            .port = rig.proxy.port,
            .supports_connect = true,
        };
        std_client.https_proxy = &proxy;
        // The caller's roots, copied in and taken out before std frees them.
        std_client.ca_bundle = rig.roots;
        std_client.now = std.Io.Clock.real.now(io);
        defer std_client.ca_bundle = .empty;

        var url_buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{rig.server_port});
        var req = try std_client.request(.GET, try std.Uri.parse(url), .{});
        defer req.deinit();
        req.sendBodiless() catch {};
        // A server that got text where it expected a handshake hangs up.
        try testing.expect(std.meta.isError(req.receiveHead(&.{})));
    }

    rig.proxy.finish();
    // 'G' of `GET`: no ClientHello (0x16) ever crossed the tunnel.
    try testing.expectEqual(@as(i16, 'G'), rig.proxy.after_connect.load(.acquire));
    try testing.expect(std.mem.startsWith(u8, rig.proxy.request(), "CONNECT localhost:"));
}

fn startedClient(io: std.Io, rig: *Rig, bypass: []const []const u8, credential: bool) !fetch.Client {
    var url: [96]u8 = undefined;
    var client: fetch.Client = .init(testing.allocator, .{
        .roots = &rig.roots,
        .proxy = .{
            .url = try std.fmt.bufPrint(&url, "http://{s}127.0.0.1:{d}", .{ if (credential) "user:secret@" else "", rig.proxy.port }),
            .bypass = bypass,
        },
    });
    errdefer client.deinit();
    try client.nilo_start(io, .none);
    return client;
}

test "an https call through a proxy is tunnelled, checked against the target's name, and answered" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();
    try rig.proxy.begin();
    rig.proxy.require = "Basic dXNlcjpzZWNyZXQ=";

    {
        var client = try startedClient(io, &rig, &.{}, true);
        defer client.deinit();
        var scope: core.Run = .init(testing.allocator);
        defer scope.deinit();

        var url: [64]u8 = undefined;
        const res = try client.get(&scope, try std.fmt.bufPrint(&url, "https://localhost:{d}/", .{rig.server_port}), .{});
        try testing.expectEqual(std.http.Status.ok, res.status);
        try testing.expectEqualStrings("hello over tls\n", res.body.view());
    }
    rig.proxy.finish();
    // A handshake crossed the tunnel, not text, and the credential rode the
    // CONNECT and nothing else.
    try testing.expectEqual(@as(i16, 0x16), rig.proxy.after_connect.load(.acquire));
    var want: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&want, "CONNECT localhost:{d} HTTP/1.1\r\n", .{rig.server_port});
    try testing.expect(std.mem.startsWith(u8, rig.proxy.request(), line));
    try testing.expect(std.mem.indexOf(u8, rig.proxy.request(), "Proxy-Authorization: Basic dXNlcjpzZWNyZXQ=\r\n") != null);
}

test "a certificate for another name is refused even when the proxy's own name would match it" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();
    try rig.proxy.begin();

    var client = try startedClient(io, &rig, &.{}, false);
    defer client.deinit();
    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();

    // The certificate carries `127.0.0.1`, which is the proxy's name, and
    // not `example.invalid`, which is the call's. A client that verified
    // against the host it dialled would accept this.
    var url: [64]u8 = undefined;
    const res = client.get(&scope, try std.fmt.bufPrint(&url, "https://example.invalid:{d}/", .{rig.server_port}), .{});
    try testing.expectError(error.TlsInitializationFailed, res);
}

test "a proxy that answers the CONNECT with anything but a 2xx fails the call before a byte of it is sent" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();
    try rig.proxy.begin();

    var client = try startedClient(io, &rig, &.{}, false);
    defer client.deinit();
    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();
    var url: [64]u8 = undefined;
    const target = try std.fmt.bufPrint(&url, "https://localhost:{d}/", .{rig.server_port});

    rig.proxy.refuse = "403 Forbidden";
    try testing.expectError(error.TunnelRefused, client.get(&scope, target, .{}));

    // No credential where one is required is a 407, and the same refusal.
    rig.proxy.refuse = null;
    rig.proxy.require = "Basic dXNlcjpzZWNyZXQ=";
    try testing.expectError(error.TunnelRefused, client.get(&scope, target, .{}));
    try testing.expectEqual(@as(u32, 0), rig.proxy.connects.load(.acquire));
}

test "a second call to the same https host rides the tunnel the first one opened" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();
    try rig.proxy.begin();

    var client = try startedClient(io, &rig, &.{}, false);
    defer client.deinit();
    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();
    var url: [64]u8 = undefined;
    const target = try std.fmt.bufPrint(&url, "https://localhost:{d}/", .{rig.server_port});

    for (0..3) |_| {
        const res = try client.get(&scope, target, .{});
        try testing.expectEqualStrings("hello over tls\n", res.body.view());
    }
    try testing.expectEqual(@as(u32, 1), rig.proxy.connects.load(.acquire));
}

test "an https host on the bypass list is dialled directly and the proxy never hears of it" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();
    try rig.proxy.begin();

    var client = try startedClient(io, &rig, &.{"127.0.0.1"}, false);
    defer client.deinit();
    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();
    var url: [64]u8 = undefined;
    const res = try client.get(&scope, try std.fmt.bufPrint(&url, "https://127.0.0.1:{d}/", .{rig.server_port}), .{});
    try testing.expectEqualStrings("hello over tls\n", res.body.view());
    try testing.expectEqual(@as(u32, 0), rig.proxy.connects.load(.acquire));
    try testing.expectEqual(@as(usize, 0), rig.proxy.head_len);
}

test "a body streamed over a tunnel uses the client that pools nothing and still reaches the target" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();
    try rig.proxy.begin();

    var client = try startedClient(io, &rig, &.{}, false);
    defer client.deinit();
    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();
    var url: [64]u8 = undefined;
    const target = try std.fmt.bufPrint(&url, "https://localhost:{d}/", .{rig.server_port});

    var source: std.Io.Reader = .fixed("x");
    var ex: fetch.Exchange = .idle;
    const head = try ex.begin(&client, .{ .method = .POST, .url = target, .body = .{ .stream = .{ .reader = &source, .len = 1 } } });
    // The route is a GET: the answer is a 405 or a 404, which is an answer
    // from the target and proves the request crossed a handshaken tunnel.
    try testing.expect(head.status != .ok);
    ex.end();
    try testing.expectEqual(@as(u32, 1), rig.proxy.connects.load(.acquire));
}

// ---- a body sent straight to an https origin ----

/// A POST whose body is smaller than the TLS writer's buffer, and one that is
/// not. `BodyWriter.end` flushes the TLS writer, which encrypts into the
/// socket writer's buffer and stops there; until `send` flushed the
/// connection after it, a body under about a kilobyte waited in that buffer
/// while the server waited for it, and the call timed out. Every alert
/// webhook a service posted was such a body. A big one filled the buffer and
/// went out on its own, which is why nothing large ever showed it.
fn postsEcho(rig: *Rig, comptime len: usize) !void {
    const io = rig.loop();
    var client: fetch.Client = .init(testing.allocator, .{ .roots = &rig.roots, .timeout_ms = 5_000 });
    defer client.deinit();
    try client.nilo_start(io, .none);
    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();
    var buf: [64]u8 = undefined;
    const target = try rigUrl(&buf, rig, "localhost", "/echo");

    const text: [len]u8 = @splat('x');
    const body = "{\"text\":\"" ++ text ++ "\"}";
    const headers: []const std.http.Header = &.{.{ .name = "content-type", .value = "application/json" }};
    const res = try client.post(&scope, target, body, .{ .headers = headers });
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings(body, res.body.view());

    // The same bytes from a reader, which ends its body the same way.
    var source: std.Io.Reader = .fixed(body);
    var ex: fetch.Exchange = .idle;
    const head = try ex.begin(&client, .{
        .method = .POST,
        .url = target,
        .headers = headers,
        .body = .{ .stream = .{ .reader = &source, .len = body.len } },
    });
    defer ex.end();
    try testing.expectEqual(std.http.Status.ok, head.status);
}

test "a small body posted to an https origin arrives without waiting for a full buffer" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try postsEcho(&rig, 16);
}

test "a body larger than the TLS buffer posted to an https origin arrives too" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try postsEcho(&rig, 20_000);
}

// ---- a call that does not verify the certificate (ADR 290) ----

/// A client that trusts no authority at all, so the server's self-signed
/// certificate is refused by a verified call whatever the host's own store
/// holds. `proxy` is the CONNECT proxy of the rig, or none.
fn trustingNothing(io: std.Io, rig: *Rig, through_proxy: bool) !fetch.Client {
    var url: [96]u8 = undefined;
    var client: fetch.Client = .init(testing.allocator, .{
        .roots = &no_roots,
        .proxy = if (through_proxy) .{ .url = try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}", .{rig.proxy.port}) } else null,
    });
    errdefer client.deinit();
    try client.nilo_start(io, .none);
    return client;
}

const no_roots: std.crypto.Certificate.Bundle = .empty;

fn rigUrl(buf: []u8, rig: *const Rig, host: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "https://{s}:{d}{s}", .{ host, rig.server_port, path });
}

test "a certificate the client does not trust is refused, and an unverified call to the same host is answered" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();

    var client = try trustingNothing(io, &rig, false);
    defer client.deinit();
    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();
    var buf: [64]u8 = undefined;
    const target = try rigUrl(&buf, &rig, "localhost", "/");

    // The control: verified, the certificate is nobody's.
    try testing.expectError(error.TlsInitializationFailed, client.get(&scope, target, .{}));

    const res = try client.get(&scope, target, .{ .tls = .unverified });
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings("hello over tls\n", res.body.view());

    // A name the certificate does not carry is no obstacle either, which
    // is the other half of what is skipped.
    var other: [64]u8 = undefined;
    const wrong_name = try rigUrl(&other, &rig, "127.0.0.1", "/");
    try testing.expectError(error.TlsInitializationFailed, client.get(&scope, wrong_name, .{}));
    _ = try client.get(&scope, wrong_name, .{ .tls = .unverified });
}

test "an unverified call to an IPv6 literal is refused by name, not quietly verified" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();

    var client = try trustingNothing(io, &rig, false);
    defer client.deinit();
    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();
    var buf: [64]u8 = undefined;
    const target = try std.fmt.bufPrint(&buf, "https://[::1]:{d}/", .{rig.server_port});
    try testing.expectError(error.UnverifiedNeedsHostName, client.get(&scope, target, .{ .tls = .unverified }));
}

test "a connection opened unverified is never handed to a verified call, and is kept for the next unverified one" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();

    var client = try trustingNothing(io, &rig, false);
    defer client.deinit();
    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();
    var buf: [64]u8 = undefined;
    const target = try rigUrl(&buf, &rig, "localhost", "/");
    const pool = &client.inner.connection_pool;

    _ = try client.get(&scope, target, .{ .tls = .unverified });
    // Kept, under the marked name and nowhere else.
    try testing.expectEqual(@as(usize, 1), pool.free_len);
    const kept: *std.http.Client.Connection = @alignCast(@fieldParentPtr("pool_node", pool.free.first.?));
    try testing.expectEqualStrings("!localhost", kept.host().bytes);

    // The verified call to the same host, port and protocol does not take
    // it: it dials, and the handshake is refused.
    try testing.expectError(error.TlsInitializationFailed, client.get(&scope, target, .{}));
    try testing.expectEqual(@as(usize, 1), pool.free_len);

    // The next unverified call rides the one it left, not a second.
    _ = try client.get(&scope, target, .{ .tls = .unverified });
    try testing.expectEqual(@as(usize, 1), pool.free_len);
}

test "a connection opened verified is not the unverified call's, and the verified one is still pooled" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();

    // Trusting the server's certificate, so a verified call succeeds.
    var client: fetch.Client = .init(testing.allocator, .{ .roots = &rig.roots });
    defer client.deinit();
    try client.nilo_start(io, .none);
    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();
    var buf: [64]u8 = undefined;
    const target = try rigUrl(&buf, &rig, "localhost", "/");
    const pool = &client.inner.connection_pool;

    _ = try client.get(&scope, target, .{});
    try testing.expectEqual(@as(usize, 1), pool.free_len);
    _ = try client.get(&scope, target, .{ .tls = .unverified });
    try testing.expectEqual(@as(usize, 2), pool.free_len);
    _ = try client.get(&scope, target, .{});
    _ = try client.get(&scope, target, .{ .tls = .unverified });
    try testing.expectEqual(@as(usize, 2), pool.free_len);
}

test "an unverified call through a proxy is tunnelled and answered, and pooled apart from a verified one" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();
    try rig.proxy.begin();

    {
        var client = try trustingNothing(io, &rig, true);
        defer client.deinit();
        var scope: core.Run = .init(testing.allocator);
        defer scope.deinit();
        var buf: [64]u8 = undefined;
        const target = try rigUrl(&buf, &rig, "localhost", "/");

        for (0..2) |_| {
            const res = try client.get(&scope, target, .{ .tls = .unverified });
            try testing.expectEqualStrings("hello over tls\n", res.body.view());
        }
        // One tunnel for both, and the verified call opens its own, which
        // the server's certificate then fails.
        try testing.expectEqual(@as(u32, 1), rig.proxy.connects.load(.acquire));
        try testing.expectError(error.TlsInitializationFailed, client.get(&scope, target, .{}));
    }
    rig.proxy.finish();
    try testing.expect(std.mem.startsWith(u8, rig.proxy.request(), "CONNECT localhost:"));
}

test "a followed redirect inside the origin stays unverified, five hops deep" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();

    var client = try trustingNothing(io, &rig, false);
    defer client.deinit();
    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();
    var buf: [64]u8 = undefined;

    // `/c5` to `/c4` to `/c3` to `/c2` to `/c1` to `/`: five hops, past
    // the three the limit used to be (ADR 183).
    var ex: fetch.Exchange = .idle;
    defer ex.end();
    var redirect: [1 << 10]u8 = undefined;
    const head = try ex.begin(&client, .{
        .method = .GET,
        .url = try rigUrl(&buf, &rig, "localhost", "/c5"),
        .tls = .unverified,
        .redirects = .{ .follow = &redirect },
    });
    try testing.expect(head.ok());
    var where: [96]u8 = undefined;
    var want: [64]u8 = undefined;
    try testing.expectEqualStrings(try rigUrl(&want, &rig, "localhost", "/"), (try head.location(&where)).?);
    const body = try ex.take(&scope, 1 << 10);
    try testing.expectEqualStrings("hello over tls\n", body.view());
}

test "a followed redirect to another origin is verified again, and the certificate there is refused" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();

    var client = try trustingNothing(io, &rig, false);
    defer client.deinit();
    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();
    var buf: [64]u8 = undefined;

    // `localhost` to `127.0.0.1`: another origin, so the permission
    // given to the first does not follow.
    var ex: fetch.Exchange = .idle;
    defer ex.end();
    var redirect: [1 << 10]u8 = undefined;
    try testing.expectError(error.TlsInitializationFailed, ex.begin(&client, .{
        .method = .GET,
        .url = try rigUrl(&buf, &rig, "localhost", "/away"),
        .tls = .unverified,
        .redirects = .{ .follow = &redirect },
    }));
}

test "a redirect loop ends at the limit with the documented error" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    const io = rig.loop();

    var client = try trustingNothing(io, &rig, false);
    defer client.deinit();
    var buf: [64]u8 = undefined;

    var ex: fetch.Exchange = .idle;
    defer ex.end();
    var redirect: [1 << 10]u8 = undefined;
    try testing.expectError(error.TooManyHttpRedirects, ex.begin(&client, .{
        .method = .GET,
        .url = try rigUrl(&buf, &rig, "localhost", "/loop-a"),
        .tls = .unverified,
        .redirects = .{ .follow = &redirect },
    }));
}

test "no setting and no target can turn verification off, only a call" {
    try testing.expect(@hasField(fetch.Client.Call, "tls"));
    try testing.expect(!@hasField(fetch.Client.Settings, "tls"));
    const T = fetch.Target("probe", .{});
    const Open = @FieldType(std.meta.ArgsTuple(@TypeOf(T.open)), "1");
    try testing.expect(!@hasField(Open, "tls"));
    try testing.expect(!@hasField(@TypeOf(T.options), "tls"));
}
