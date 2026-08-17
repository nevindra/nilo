//! What an outbound HTTP client would actually be, measured rather than
//! guessed.
//!
//! Two sessions arrived at the same wall from opposite sides: an object store
//! needs to speak HTTP to a service, a handler needs to speak HTTP to Stripe,
//! and a Service may not import `nilo_http` to share whatever the App layer
//! has. The proposal on the table is a fourth layer between Core and Service.
//! **A layer is an expensive answer, and nobody had asked how big its first
//! tenant is.**
//!
//! So this asks two questions with a compiler rather than an argument:
//!
//! 1. **How much of an outbound client is nilo's?** `std.http.Client` is
//!    already the client — connection pool, HTTP/1.1, TLS. What is left is
//!    policy. The policy is between the two markers below and nothing else is,
//!    so `run.sh` can count it without anybody trusting a claim about it.
//!
//! 2. **Can it be tested with no engine and no module graph?** The entry
//!    condition proposed for the fourth layer is `zig test <m>/<m>.zig` under
//!    `std.Io.Threaded` — the same shape as ADR 0042's, one tier up. Nobody
//!    had checked whether an HTTP client can pass it. Everything here runs
//!    against a loopback server on `std.Io.Threaded`, no zio anywhere, and the
//!    dependency list in `build.zig.zon` is empty.
//!
//! What is deliberately *not* here: TLS, which is `std.crypto.tls.Client` and
//! costs this layer nothing to enable, and the deadline, which is ADR 0065 and
//! does not exist yet. Where the deadline would be armed is marked. Neither
//! changes the answer to question 1 — see the README.

const std = @import("std");

// ---- BEGIN POLICY ----

/// What nilo would put in front of `std.http.Client`, and the reason the
/// layer question exists at all.
pub const Options = struct {
    /// The pool bounds *idle* connections (`free_size`, 32 by default) and
    /// does not bound the ones in use at all, so 500 concurrent handlers is
    /// 500 live connections. An HTTPS one holds 59,151 bytes of buffers, so
    /// that is 29.6 MB nobody asked for. This is the gate that stops it.
    max_in_flight: usize = 32,

    /// `Request.deinit` calls `discardRemaining()` with no bound when the head
    /// was read and the body was not, so refusing a 500 MB object still
    /// downloads it. Past this many bytes the connection is closed instead —
    /// losing it costs one handshake, and reading it costs the whole object.
    max_drain: usize = 64 * 1024,

    /// A response body larger than this is an error rather than an
    /// allocation. Nothing in std bounds it.
    max_body: usize = 8 * 1024 * 1024,
};

pub const Error = error{ BodyTooLarge, OutOfMemory } ||
    std.http.Client.RequestError ||
    std.Io.Writer.Error ||
    std.http.Client.Request.ReceiveHeadError ||
    std.Io.Reader.Error ||
    std.Io.Cancelable;

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
};

pub const Outbound = struct {
    client: std.http.Client,
    gate: std.Io.Semaphore,
    options: Options,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) Outbound {
        return .{
            .client = .{ .allocator = gpa, .io = io },
            .gate = .{ .permits = options.max_in_flight },
            .options = options,
        };
    }

    pub fn deinit(self: *Outbound) void {
        self.client.deinit();
    }

    /// One request, and the permit is held until the body is in hand rather
    /// than until the head arrives — a connection is live for the whole of it.
    pub fn fetch(
        self: *Outbound,
        gpa: std.mem.Allocator,
        method: std.http.Method,
        uri: std.Uri,
    ) Error!Response {
        const io = self.client.io;

        try self.gate.wait(io);
        defer self.gate.post(io);

        // Where ADR 0065 arms the deadline: one `Limits.bind` around
        // everything below, released with the permit.

        var req = try self.client.request(method, uri, .{});
        defer self.close(&req);

        try req.sendBodiless();

        var redirect_buffer: [2 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        var transfer_buffer: [4 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);

        // The ceiling is enforced while reading rather than checked after, so
        // a sender lying about content-length cannot get past it.
        const body = reader.allocRemaining(gpa, .limited(self.options.max_body)) catch |err| switch (err) {
            error.StreamTooLong => return error.BodyTooLarge,
            else => |e| return e,
        };

        return .{ .status = response.head.status, .body = body };
    }

    /// What `Request.deinit` would have done unbounded. A connection with more
    /// than `max_drain` still on it is dropped rather than read to the end.
    fn close(self: *Outbound, req: *std.http.Client.Request) void {
        if (req.connection) |conn| {
            const left = conn.reader().bufferedLen();
            if (left > self.options.max_drain) conn.closing = true;
        }
        req.deinit();
    }
};

// ---- END POLICY ----

// ---- a server on loopback, so none of this needs a network ----

const Canned = struct {
    server: std.Io.net.Server,
    body_len: usize,
    io: std.Io,
    port: u16,

    /// `Io.net.Server` has no way to read back the port it was given, so
    /// asking for 0 and looking is not available — walk a range until one
    /// binds instead.
    fn open(io: std.Io, body_len: usize) !Canned {
        var candidate: u16 = 39_000;
        while (candidate < 39_100) : (candidate += 1) {
            const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(candidate) };
            const server = address.listen(io, .{}) catch continue;
            return .{ .server = server, .body_len = body_len, .io = io, .port = candidate };
        }
        return error.NoFreePort;
    }

    /// One request, one response, then the connection goes. Enough to drive
    /// the policy above; not an HTTP server.
    fn serveOne(self: *Canned) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);

        var in_buf: [4 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        _ = try reader.interface.takeDelimiterExclusive('\r');

        var out_buf: [8 * 1024]u8 = undefined;
        var writer = stream.writer(self.io, &out_buf);
        const w = &writer.interface;
        try w.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{self.body_len});
        try w.splatByteAll('x', self.body_len);
        try w.flush();
    }

    fn close(self: *Canned) void {
        self.server.socket.close(self.io);
    }
};

const testing = std.testing;

/// Every test runs the loop the same way: `std.Io.Threaded`, which is std's
/// own, so nothing here names an engine. This is question 2.
fn withIo(comptime body: fn (std.Io) anyerror!void) !void {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try body(threaded.io());
}

test "a response comes back through the gate" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io, 11);
            defer canned.close();
            const uri = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/", .{canned.port});
            defer testing.allocator.free(uri);

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var out: Outbound = .init(testing.allocator, io, .{});
            defer out.deinit();

            const res = try out.fetch(testing.allocator, .GET, try std.Uri.parse(uri));
            defer testing.allocator.free(res.body);

            try testing.expectEqual(std.http.Status.ok, res.status);
            try testing.expectEqual(@as(usize, 11), res.body.len);
        }
    }.run);
}

test "a body over the ceiling is an error rather than an allocation" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io, 4096);
            defer canned.close();
            const uri = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/", .{canned.port});
            defer testing.allocator.free(uri);

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var out: Outbound = .init(testing.allocator, io, .{ .max_body = 1024 });
            defer out.deinit();

            try testing.expectError(
                error.BodyTooLarge,
                out.fetch(testing.allocator, .GET, try std.Uri.parse(uri)),
            );
        }
    }.run);
}

test "the gate hands out no more permits than it was given" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var out: Outbound = .init(testing.allocator, io, .{ .max_in_flight = 2 });
            defer out.deinit();

            try out.gate.wait(io);
            try out.gate.wait(io);
            try testing.expectEqual(@as(usize, 0), out.gate.permits);
            out.gate.post(io);
            try testing.expectEqual(@as(usize, 1), out.gate.permits);
        }
    }.run);
}

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&buf);
    const w = &out.interface;
    try w.writeAll(
        \\This spike is measured by `zig build test` and counted by `run.sh`.
        \\
        \\  question 1 — how many lines of policy: run.sh counts between the
        \\               BEGIN POLICY / END POLICY markers in main.zig
        \\  question 2 — engine-free tests: `zig build test` passing IS the
        \\               answer, since build.zig.zon has no dependencies
        \\
    );
    try w.flush();
}
