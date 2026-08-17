//! What a Fitting costs, with three controls standing next to it.
//!
//! `nilo_fetch` is one call away from `std.http.Client`, so the only honest
//! question is what the sixty-five lines wrapped round it cost — and by
//! [ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md) the
//! answer that matters is not throughput. **A handler's stack is held per
//! connection at its high-water mark**, and `send` puts a 2 KB redirect
//! buffer, a 4 KB transfer buffer and a 216-byte `Bound` on it. Every one of
//! those is a byte an idle keep-alive connection carries for as long as the
//! client keeps the socket open.
//!
//! So six routes on one binary, each one removing a layer from the one above:
//!
//! - `/health` — a constant `[]const u8`, no `Ctx`, no client. The floor this
//!   binary runs at, and the same route `bench/sql_server.zig` uses for the
//!   same reason.
//! - `/bound` — arms a `core.Limits.Bound` and releases it. No socket, no
//!   buffers. Isolates the deadline slot from everything else.
//! - `/bare` — a call through a plain `std.http.Client` held as a Service,
//!   with no gate, no deadline and no ceiling. **This is the control that
//!   decides the whole question**: whatever it costs is std's, and only the
//!   difference is nilo's.
//! - `/arena` — `/bare` with the two buffers moved off the stack into the
//!   request arena. The lever, priced.
//! - `/warm` — a kilobyte out of the request arena and no client at all. The
//!   control that decided the result.
//! - `/call` — the same call through `nilo_fetch`.
//!
//! The upstream is inside this process, on a thread of its own with its own
//! `std.Io.Threaded`, answering a fixed ~1 KB body. That is deliberate: an
//! upstream over the network would put its own latency and its own variance
//! into every reading, and the thing being measured here is a client's
//! overhead, not a round trip. It is also what makes this runnable with
//! nothing installed.
//!
//! ```
//! zig build -Doptimize=ReleaseFast bench-fetch-server
//! ./zig-out/bin/nilo-bench-fetch-server
//!
//! # throughput, one route at a time
//! ./bench/bench.sh http://127.0.0.1:8791/call
//!
//! # memory per idle connection, which is the number this exists for
//! python3 bench/mem.py --port 8791 --path /call
//! python3 bench/mem.py --port 8791 --path /bare
//! ```

const std = @import("std");
const nilo = @import("nilo_http");
const core = @import("nilo_core");
const fetch = @import("nilo_fetch");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

/// Where the upstream ended up. Written before `listen()`, read on the loop.
var upstream_url: []const u8 = "";

/// The floor: no `Ctx`, no service, no allocation.
fn health() []const u8 {
    return "alive\n";
}

/// Holds nothing but the deadline seam, so a route can arm one without a
/// client attached to it. Also the smallest possible reading of the two-arity
/// `nilo_start`: a Service that wants `Limits` asks for it by taking a third
/// parameter, and one that does not is left alone.
const Clock = struct {
    limits: core.Limits = .off,

    pub fn nilo_start(self: *Clock, io: std.Io, limits: core.Limits) !void {
        _ = io;
        self.limits = limits;
    }
};

/// A deadline armed and taken off again, and nothing else. Separates the
/// `Bound`'s slot — 192 bytes plus its bookkeeping — from the client buffers
/// that dwarf it, so the two are not guessed at from one total.
fn bound(clock: *Clock, c: *nilo.Ctx) !nilo.Str {
    var b: core.Limits.Bound = .idle;
    defer b.release();
    b.arm(clock.limits, 5_000);
    return c.str("armed\n");
}

/// The same call `/call` makes, with none of the policy round it: no permit,
/// no deadline, no body ceiling, and `deinit` left to decide for itself
/// whether the connection is worth draining.
const Bare = struct {
    inner: std.http.Client,

    pub fn nilo_start(self: *Bare, io: std.Io) !void {
        self.inner.io = io;
    }

    fn call(self: *Bare, c: *nilo.Ctx) !nilo.Str {
        const uri = try std.Uri.parse(upstream_url);
        var req = try self.inner.request(.GET, uri, .{});
        defer req.deinit();
        try req.sendBodiless();

        var redirect_buffer: [2 << 10]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        var transfer_buffer: [4 << 10]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        const bytes = try reader.allocRemaining(c.arena(), .limited(1 << 20));
        return c.str(bytes);
    }
};

fn bare(client: *Bare, c: *nilo.Ctx) !nilo.Str {
    return client.call(c);
}

/// `/bare` with the two client buffers taken off the stack and put in the
/// request arena instead — the obvious lever, and **it does not work.**
///
/// The reasoning was sound: by
/// [ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md) a byte
/// of handler stack is held per *connection* at the high-water mark, while a
/// byte of arena is held per *request*. Moving 6 KB across that line should
/// have been worth 6 KB on every idle connection.
///
/// Measured, it is worth **−66 bytes**: 25,326 against `/bare`'s 25,260. The
/// two buffers are not what sets the high-water mark; the depth of
/// `std.http.Client`'s own call chain is, and it reaches the same pages with
/// or without them. Kept in the file because a lever that was tried and lost
/// is worth more to the next person than one that was never priced.
fn arena(client: *Bare, c: *nilo.Ctx) !nilo.Str {
    const uri = try std.Uri.parse(upstream_url);
    var req = try client.inner.request(.GET, uri, .{});
    defer req.deinit();
    try req.sendBodiless();

    const redirect_buffer = try c.arena().alloc(u8, 2 << 10);
    var response = try req.receiveHead(redirect_buffer);

    const transfer_buffer = try c.arena().alloc(u8, 4 << 10);
    const reader = response.reader(transfer_buffer);
    const bytes = try reader.allocRemaining(c.arena(), .limited(1 << 20));
    return c.str(bytes);
}

/// No client, no socket, no outbound anything — just a handler that puts a
/// kilobyte in the request arena and answers with it.
///
/// **The control that ruled out the arena.** `/bare` costs 16,495 bytes an
/// idle connection more than `/health`, and 16,384 of that is exactly
/// `arena_keep` — which made the retained arena look like the whole answer.
/// This route serves the same 1,008 bytes out of the same arena and costs
/// **2,048**, so the arena is not where the 16 KB went. What is left is the
/// fiber stack, at the depth `std.http.Client` drives it to, held per
/// connection exactly as ADR 0063 says.
fn warm(c: *nilo.Ctx) !nilo.Str {
    const bytes = try c.arena().alloc(u8, 1_008);
    @memset(bytes, 'x');
    return c.str(bytes);
}

fn call(api: *fetch.Client, c: *nilo.Ctx) !nilo.Str {
    const res = try api.get(c, upstream_url, .{});
    return res.body;
}

/// A fixed ~1 KB answer, on a thread that is not the Engine's, so the number
/// being read is the client's and not an upstream's.
const Upstream = struct {
    const body = "A systems nerd who writes Zig before breakfast. " ** 21;

    port: u16 = 0,
    ready: std.atomic.Value(bool) = .init(false),
    /// Set instead of `ready` when there was nowhere to listen. Without it
    /// `main` waits for a flag that will never be set and the process sits
    /// there with one thread doing nothing, which is a failure mode that
    /// looks exactly like a fast server to a load generator pointed at a
    /// port something *else* is holding.
    doomed: std.atomic.Value(bool) = .init(false),

    fn run(self: *Upstream) void {
        var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var candidate: u16 = 8_900;
        var server: std.Io.net.Server = while (candidate < 9_000) : (candidate += 1) {
            const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(candidate) };
            break address.listen(io, .{}) catch continue;
        } else {
            self.doomed.store(true, .release);
            return;
        };
        defer server.socket.close(io);

        self.port = candidate;
        self.ready.store(true, .release);

        while (true) {
            var stream = server.accept(io) catch continue;
            const thread = std.Thread.spawn(.{}, serveOne, .{ stream, io }) catch {
                stream.close(io);
                continue;
            };
            thread.detach();
        }
    }

    /// Keep-alive, so the client's connection pool is exercised the way it
    /// would be against a real service rather than reconnecting every call.
    fn serveOne(stream: std.Io.net.Stream, io: std.Io) void {
        defer stream.close(io);

        var in_buf: [4096]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &in_buf);
        var writer = stream.writer(io, &out_buf);

        while (true) {
            // One request is its head and a blank line; nothing here sends a
            // body, so the blank line is the whole of the framing.
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                if (line.len <= 2) break;
            }
            writer.interface.print(
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: text/plain\r\n\r\n{s}",
                .{ body.len, body },
            ) catch return;
            writer.interface.flush() catch return;
        }
    }
};

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var upstream: Upstream = .{};
    const upstream_thread = try std.Thread.spawn(.{}, Upstream.run, .{&upstream});
    upstream_thread.detach();

    var waiting: std.Io.Threaded = .init(gpa, .{});
    defer waiting.deinit();
    while (!upstream.ready.load(.acquire)) {
        if (upstream.doomed.load(.acquire)) return error.NoPortForTheUpstream;
        try std.Io.sleep(waiting.io(), .fromMilliseconds(1), .awake);
    }

    var url_buf: [64]u8 = undefined;
    upstream_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{upstream.port});

    var api: fetch.Client = .init(gpa, .{ .max_in_flight = 4096 });
    defer api.deinit();

    var raw: Bare = .{ .inner = .{ .allocator = gpa, .io = undefined } };
    defer raw.inner.deinit();

    var clock: Clock = .{};

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.provide(&api);
    try app.provide(&raw);
    try app.provide(&clock);

    try app.get("/health", health);
    try app.get("/bound", bound);
    try app.get("/bare", bare);
    try app.get("/arena", arena);
    try app.get("/warm", warm);
    try app.get("/call", call);

    // 8791 rather than 8789, which `bench/sql_server.zig`'s neighbour and any
    // other bench server in a sibling worktree will already want. A load
    // generator pointed at a port somebody else is holding measures somebody
    // else's routes and reports them as non-2xx, which is how three runs of
    // this were thrown away before the port was the thing suspected.
    try app.listen(.{ .port = 8791 });
}
