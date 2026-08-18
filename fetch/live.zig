//! The half of `fetch.zig`'s tests that needs a socket at both ends.
//!
//! **This file is the Fitting layer's entry condition, written down as
//! something that runs.** A Tool module proves its layer by running under a
//! plain `zig test` with no module graph; a Fitting borrows the loop, so it
//! cannot do that — but it can run under `std.Io.Threaded`, which is std's
//! own. Everything below drives a real client against a real loopback server
//! with **no zio anywhere**, so `zig test fetch/fetch.zig` is the whole suite
//! and `zig build test-fetch` is only the second optimize mode
//! ([ADR 0070](../docs/adr/0070-a-fitting-borrows-the-loop.md)).
//!
//! If a change ever makes this file need the Engine, the module is in the
//! wrong layer rather than the test being wrong.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("fetch.zig");

const testing = std.testing;

/// A server that answers exactly what a test asked it to, once per
/// connection. Not an HTTP server — just enough of one to drive a client.
const Canned = struct {
    server: std.Io.net.Server,
    io: std.Io,
    port: u16,
    /// How many bytes of body to send, and what to claim in the header. They
    /// differ only when a test is about a server that lies.
    body_len: usize = 0,
    claim_len: ?usize = null,
    status: []const u8 = "200 OK",
    /// Response headers beyond the two above, each with its own `\r\n`.
    extra: []const u8 = "",
    /// Filled in by `serveOne` so a test can assert on what arrived.
    seen: [1024]u8 = undefined,
    seen_len: usize = 0,
    /// The request body, for the tests about what a streamed send puts on the
    /// wire.
    body_seen: [1024]u8 = undefined,
    body_seen_len: usize = 0,
    /// How many connections have been accepted — see `serveEach`.
    accepted: usize = 0,

    /// `Io.net.Server` cannot report the port it was given, so asking for 0
    /// and reading it back is not available — walk a range instead.
    ///
    /// **The walk starts at the process id and wraps**, and both halves of
    /// that matter. A server that closes a connection leaves its local port
    /// in `TIME-WAIT` for a minute, and a port in `TIME-WAIT` cannot be bound
    /// again, so a fixed start walks back over the ports the last run just
    /// finished with. Two hundred ports and a fixed start ran out after three
    /// consecutive `zig build test-all` runs, and the failure arrives as
    /// `error.NoFreePort` inside whichever test happened to be next — a
    /// message pointing at the wrong thing entirely. A thousand ports and a
    /// different start per process is enough that the two test binaries
    /// `test-all` runs at once do not tread on each other either.
    ///
    /// `reuse_address` would fix the `TIME-WAIT` half in one line and is
    /// refused: std sets `SO_REUSEPORT` alongside `SO_REUSEADDR`, so two test
    /// binaries would both bind the same port and the kernel would hand each
    /// of them some of the connections. Failing to bind is the signal that
    /// keeps them apart.
    fn open(io: std.Io) !Canned {
        const first: u16 = 39_200;
        const count: u16 = 1_000;
        // The thread id rather than the pid, because `getpid` is per-OS and
        // nothing else in this file is. Either would do: what is wanted is a
        // number that differs between two runs and between the two binaries.
        const start: u16 = @intCast(@as(u64, std.Thread.getCurrentId()) % count);
        var tried: u16 = 0;
        while (tried < count) : (tried += 1) {
            const candidate = first + (start + tried) % count;
            const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(candidate) };
            const server = address.listen(io, .{}) catch continue;
            return .{ .server = server, .io = io, .port = candidate };
        }
        return error.NoFreePort;
    }

    fn url(self: *Canned, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/", .{self.port});
    }

    fn serveOne(self: *Canned) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);

        var in_buf: [4 << 10]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);

        // The whole head, line by line to the blank one. Reading only as far
        // as the first `\r` would keep the request line and drop every header,
        // which is exactly what the header test is about — so it is read the
        // way a server reads it.
        while (true) {
            // Inclusive, because the exclusive form leaves the delimiter in
            // the buffer and the next call comes straight back empty — which
            // reads as "the head ended after one line".
            const line = try reader.interface.takeDelimiterInclusive('\n');
            const trimmed = std.mem.trimEnd(u8, line, "\r\n");
            if (trimmed.len == 0) break;
            const room = self.seen.len - self.seen_len;
            if (room < trimmed.len + 1) continue;
            @memcpy(self.seen[self.seen_len..][0..trimmed.len], trimmed);
            self.seen[self.seen_len + trimmed.len] = '\n';
            self.seen_len += trimmed.len + 1;
        }

        var out_buf: [64 << 10]u8 = undefined;
        var writer = stream.writer(self.io, &out_buf);
        const w = &writer.interface;
        // `extra` goes here as well as in `serveEach`, and leaving it out of
        // one of them is how the header test came to assert against headers
        // that were never sent: it sets `extra`, it is served by *this*
        // function, and `head.header("etag").?` panicked on a null.
        try w.print("HTTP/1.1 {s}\r\nContent-Length: {d}\r\n{s}\r\n", .{
            self.status,
            self.claim_len orelse self.body_len,
            self.extra,
        });
        try w.splatByteAll('x', self.body_len);
        try w.flush();
    }

    /// `count` requests on **one** connection, which `serveOne` cannot do:
    /// it closes after answering, so a client that comes back gets
    /// `error.HttpConnectionClosing` from its own pool. Keep-alive is the
    /// ordinary case for anything a service calls repeatedly, and it is the
    /// only way to ask what a call costs once the connection already exists.
    fn serveKeepAlive(self: *Canned, count: usize) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);

        var in_buf: [4 << 10]u8 = undefined;
        var out_buf: [64 << 10]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        var writer = stream.writer(self.io, &out_buf);

        for (0..count) |_| {
            while (true) {
                const line = try reader.interface.takeDelimiterInclusive('\n');
                if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break;
            }
            const w = &writer.interface;
            try w.print("HTTP/1.1 {s}\r\nContent-Length: {d}\r\n\r\n", .{
                self.status,
                self.claim_len orelse self.body_len,
            });
            try w.splatByteAll('x', self.body_len);
            try w.flush();
        }
    }

    /// A connection answered once and then closed, twice over: exactly what a
    /// peer reaping an idle keep-alive looks like from the client side.
    ///
    /// The client's first call pools a connection this server has already
    /// hung up on. Its second call takes that dead socket out of the pool,
    /// gets `HttpConnectionClosing` from `receiveHead` — no bytes, no answer
    /// — and either retries once on a fresh connection, which is the second
    /// `accept` here, or hands the caller a failure nobody caused.
    ///
    /// Measured against a real MinIO before it was written: 80 seconds idle
    /// and a `wrk` run answered exactly `max_in_flight` requests non-2xx.
    fn serveThenReap(self: *Canned) !void {
        for (0..2) |_| {
            var stream = try self.server.accept(self.io);
            defer stream.close(self.io);
            // Counted here rather than after the answer, so the tally cannot
            // race the client: a caller holding a response is a caller whose
            // connection was accepted, and both fibers share one thread.
            self.accepted += 1;

            var in_buf: [4 << 10]u8 = undefined;
            var out_buf: [64 << 10]u8 = undefined;
            var reader = stream.reader(self.io, &in_buf);
            var writer = stream.writer(self.io, &out_buf);

            while (true) {
                const line = try reader.interface.takeDelimiterInclusive('\n');
                if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break;
            }
            const w = &writer.interface;
            try w.print("HTTP/1.1 {s}\r\nContent-Length: {d}\r\n\r\n", .{
                self.status,
                self.claim_len orelse self.body_len,
            });
            try w.splatByteAll('x', self.body_len);
            try w.flush();
        }
    }

    /// `count` **requests**, however many connections they arrive on, and a
    /// tally of how many connections that took.
    ///
    /// The tally is the whole point: whether a client kept a pooled connection
    /// or dropped it is not visible from the client side at all, and it is
    /// exactly what the drain policy decides. A second `accept` means the
    /// first connection was dropped.
    ///
    /// **Counting requests rather than connections is what keeps this from
    /// hanging the suite**, and both of the other spellings did. A version that
    /// closed after answering one produced a second `accept` in *both* cases —
    /// a dropped connection because the client opened a new one, and a kept
    /// connection because the client came back to a socket this server had
    /// already closed — so the tally could not tell them apart and the control
    /// test asserted a 1 that nothing could produce. Fixing that by looping
    /// `for (0..count)` over *accepts* then parked the server on an `accept`
    /// that never comes the moment the client did the right thing and kept its
    /// connection: two requests on one socket leaves the second accept
    /// outstanding, and whether the test finishes comes down to whether
    /// `cancel` wins a race against it. Requests are what the client makes and
    /// what the test counts, so they are what the loop should be bounded by.
    fn serveEach(self: *Canned, count: usize) !void {
        var served: usize = 0;
        while (served < count) {
            var stream = try self.server.accept(self.io);
            defer stream.close(self.io);
            self.accepted += 1;

            var in_buf: [4 << 10]u8 = undefined;
            var out_buf: [64 << 10]u8 = undefined;
            var reader = stream.reader(self.io, &in_buf);
            var writer = stream.writer(self.io, &out_buf);

            while (served < count) {
                // End of head, or end of connection. EOF here is the client
                // saying it is finished with this socket, which is the signal
                // to go back to `accept` — not an error.
                var ended = false;
                while (true) {
                    const line = reader.interface.takeDelimiterInclusive('\n') catch {
                        ended = true;
                        break;
                    };
                    if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break;
                }
                if (ended) break;

                // Counted on arrival rather than on a completed answer. A
                // client that refuses this body may drop the connection before
                // the write finishes, and a request that was made is one the
                // loop has to account for — counting replies instead leaves it
                // short and sends it back to `accept` for a connection nobody
                // is going to open.
                served += 1;

                const w = &writer.interface;
                w.print("HTTP/1.1 {s}\r\nContent-Length: {d}\r\n{s}\r\n", .{
                    self.status,
                    self.claim_len orelse self.body_len,
                    self.extra,
                }) catch break;
                // A client under test is *allowed* to stop reading and drop the
                // connection mid-body — that is the whole of what the drain
                // policy decides, and the write then fails with a reset. Take
                // the next connection rather than failing the server.
                //
                // This is also the guard on the one way these tests can hang
                // the suite rather than fail it. The body has to fit in kernel
                // socket buffers, because nothing is reading the far end; if a
                // future `body_len` stops fitting, the write parks with nothing
                // to wake it and `zig build test` sits at 0% CPU forever.
                // Swallowing the error means the worst case is `accepted`
                // coming out wrong, which is a failed expectation with a line
                // number.
                w.splatByteAll('x', self.body_len) catch break;
                w.flush() catch break;
            }
        }
    }

    /// Read a request whole — head and `content-length` bytes of body — and
    /// answer it. For the tests about what goes *out*.
    fn serveWithBody(self: *Canned) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);

        var in_buf: [64 << 10]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);

        var body_len: usize = 0;
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            const trimmed = std.mem.trimEnd(u8, line, "\r\n");
            if (trimmed.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                const value = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
                body_len = try std.fmt.parseInt(usize, value, 10);
            }
            const room = self.seen.len - self.seen_len;
            if (room < trimmed.len + 1) continue;
            @memcpy(self.seen[self.seen_len..][0..trimmed.len], trimmed);
            self.seen[self.seen_len + trimmed.len] = '\n';
            self.seen_len += trimmed.len + 1;
        }

        self.body_seen_len = @min(body_len, self.body_seen.len);
        try reader.interface.readSliceAll(self.body_seen[0..self.body_seen_len]);

        var out_buf: [4 << 10]u8 = undefined;
        var writer = stream.writer(self.io, &out_buf);
        const w = &writer.interface;
        try w.print("HTTP/1.1 {s}\r\nContent-Length: 0\r\n{s}\r\n", .{ self.status, self.extra });
        try w.flush();
    }

    fn close(self: *Canned) void {
        self.server.socket.close(self.io);
    }
};

/// Everything here runs the loop the same way, and the way matters: this is
/// `std.Io.Threaded`, not the Engine.
fn withIo(comptime body: fn (std.Io) anyerror!void) !void {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try body(threaded.io());
}

/// A client wired the way `listen()` would wire it.
///
/// `.off` rather than the Engine's `Limits`, because there is no Engine here
/// and that is the whole point of the file. **So nothing below arms a real
/// deadline**, and the timeout is the one behaviour these tests cannot reach:
/// firing one needs something that can cancel a fiber, which is the Engine.
/// What *can* be checked without one is the decision the timeout leads to —
/// telling a deadline from a shutdown — and `fetch.zig` does that against a
/// hand-made `Limits` rather than pretending this file covers it.
fn started(io: std.Io, settings: fetch.Client.Settings) !fetch.Client {
    var client: fetch.Client = .init(testing.allocator, settings);
    try client.nilo_start(io, .off);
    return client;
}

test "a body comes back as request-lifetime text" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 11;

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = try client.get(&scope, try canned.url(&buf), .{});

            try testing.expectEqual(std.http.Status.ok, res.status);
            try testing.expect(res.ok());
            try testing.expectEqual(@as(usize, 11), res.body.len());
            // It is the Run's memory, so it goes when the Run's tick does and
            // nothing here frees it. The trap that can say so is Debug-only by
            // design, so this half of the claim is checked in one mode.
            if (core.trap_enabled) try testing.expect(res.body.alive());
        }
    }.run);
}

test "a body over the ceiling stops at the ceiling" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 4096;

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{ .max_body = 1024 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            try testing.expectError(
                error.BodyTooLarge,
                client.get(&scope, try canned.url(&buf), .{}),
            );
        }
    }.run);
}

test "a server that lies about content-length does not get past the ceiling" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            // Claims 10 bytes, sends 4096. The ceiling is enforced while
            // reading, so the claim buys nothing.
            canned.body_len = 4096;
            canned.claim_len = 10;

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{ .max_body = 1024 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = client.get(&scope, try canned.url(&buf), .{});
            // Either the ceiling caught it or the framing did; what must not
            // happen is 4096 bytes arriving under a ceiling of 1024.
            if (res) |ok| {
                try testing.expect(ok.body.len() <= 1024);
            } else |_| {}
        }
    }.run);
}

test "the status a caller checks is the status that arrived" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.status = "503 Service Unavailable";
            canned.body_len = 4;

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = try client.get(&scope, try canned.url(&buf), .{});

            try testing.expectEqual(std.http.Status.service_unavailable, res.status);
            // A 503 is a response, not an error: the call worked and the
            // service said no. Only the caller knows which of those matters.
            try testing.expect(!res.ok());
        }
    }.run);
}

test "a body sent is a body the other end reads" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 2;

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            _ = try client.post(&scope, try canned.url(&buf), "amount=500", .{});

            served.await(io) catch {};
            try testing.expect(std.mem.startsWith(u8, canned.seen[0..canned.seen_len], "POST /"));
        }
    }.run);
}

test "a header a caller adds is a header that arrives" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            _ = try client.get(&scope, try canned.url(&buf), .{
                .headers = &.{.{ .name = "Authorization", .value = "Bearer wati" }},
            });

            served.await(io) catch {};
            try testing.expect(std.mem.indexOf(
                u8,
                canned.seen[0..canned.seen_len],
                "Bearer wati",
            ) != null);
        }
    }.run);
}

test "JSON parses into a struct of the caller's own" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var run_scope: core.Run = .init(testing.allocator);
            defer run_scope.deinit();

            // No socket needed: the parse is the whole subject, and the body
            // is the same Str either way.
            const res: fetch.Response = .{
                .status = .ok,
                .body = run_scope.str(
                    \\{"id": 7, "email": "wati@example.com", "extra": "ignored"}
                ),
            };

            const User = struct { id: u32, email: []const u8 };
            const user = try res.json(User, &run_scope);

            try testing.expectEqual(@as(u32, 7), user.id);
            try testing.expectEqualStrings("wati@example.com", user.email);
            _ = io;
        }
    }.run);
}

test "the body is asked for uncompressed, so what comes back is the body" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 4;

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            _ = try client.get(&scope, try canned.url(&buf), .{});

            const head = canned.seen[0..canned.seen_len];

            // `std.http.Client` advertises `gzip, deflate` and then returns
            // the compressed bytes from `reader()`. `fetch/tls.zig` is where
            // that was caught, against a real endpoint; this is the half of
            // it that runs with no network, so deleting the line in `send`
            // fails in `zig build test` rather than only in `smoke-tls`.
            try testing.expect(std.mem.indexOf(u8, head, "accept-encoding: identity") != null);
            try testing.expect(std.mem.indexOf(u8, head, "gzip") == null);
        }
    }.run);
}

// ---- what an Exchange adds, and the drain that decides a connection ----

test "a refused body costs the connection rather than the download" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            // 32 KiB offered, a kilobyte allowed. What is left over is nearly
            // four times `max_drain`, so reading it to keep the connection is
            // the expensive answer and the connection goes instead.
            //
            // **The absolute size is load-bearing and it is not about HTTP.**
            // This server writes the whole body before the client stops
            // reading, so every byte of it has to sit in kernel socket buffers
            // — and a body past what they hold parks the server mid-write with
            // nothing to wake it. The first draft used a megabyte and hung the
            // suite; the second used 128 KiB, which is *exactly* this
            // machine's `net.ipv4.tcp_rmem` default of 131072 and hung it
            // again, intermittently, depending on where send-buffer
            // autotuning happened to be. 32 KiB is a quarter of the smallest
            // default worth worrying about, and the ratio to `max_drain` is
            // what the test is actually about — so scale both together, never
            // the body alone.
            canned.body_len = 32 << 10;

            var served = io.async(Canned.serveEach, .{ &canned, @as(usize, 2) });
            defer served.cancel(io) catch {};

            var client = try started(io, .{ .max_body = 1024, .max_drain = 8 << 10 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);

            try testing.expectError(error.BodyTooLarge, client.get(&scope, url, .{}));
            _ = client.get(&scope, url, .{}) catch {};

            // Two connections means the first was dropped. One would mean it
            // was kept — which is only possible by reading the megabyte, since
            // `Request.deinit` drains whatever it keeps.
            try testing.expectEqual(@as(usize, 2), canned.accepted);
        }
    }.run);
}

test "a leftover under the ceiling is read, and the connection stays" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 32 << 10;

            var served = io.async(Canned.serveEach, .{ &canned, @as(usize, 2) });
            defer served.cancel(io) catch {};

            // The same body and the same refusal, with the ceiling moved above
            // it. This is the control: it is the *decision* that changes, not
            // the request, so a version of `dropIfDrainIsDearer` that always
            // dropped would fail here and still look right above. The body has
            // to match the test above byte for byte or the pair stops being a
            // control.
            var client = try started(io, .{ .max_body = 1024, .max_drain = 1 << 20 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);

            try testing.expectError(error.BodyTooLarge, client.get(&scope, url, .{}));
            // The second call reuses a connection this server has already
            // closed, so whether it succeeds is the server's business. What is
            // being asked is whether the client went looking for a new one.
            _ = client.get(&scope, url, .{}) catch {};

            try testing.expectEqual(@as(usize, 1), canned.accepted);
        }
    }.run);
}

test "a response header is readable before the body is touched" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 5;
            canned.extra = "ETag: \"d41d8cd9\"\r\nx-amz-request-id: 8F2C\r\n";

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            var transfer: [1 << 10]u8 = undefined;

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            const head = try ex.begin(&client, .{
                .method = .GET,
                .url = try canned.url(&buf),
                .transfer_buffer = &transfer,
            });

            try testing.expect(head.ok());
            try testing.expectEqual(@as(u64, 5), head.content_length.?);
            // Case-insensitively, because a server picks its own spelling and
            // `ETag` is the one S3 uses.
            try testing.expectEqualStrings("\"d41d8cd9\"", head.header("etag").?);
            try testing.expectEqualStrings("8F2C", head.header("X-AMZ-REQUEST-ID").?);
            try testing.expect(head.header("content-md5") == null);

            const body = try ex.take(&scope, 1 << 20);
            try testing.expectEqualStrings("xxxxx", body.view());
        }
    }.run);
}

test "a body piped out is written rather than held" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 4096;

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var transfer: [1 << 10]u8 = undefined;

            // Where the body goes. No Scope anywhere in this test, which is
            // the property: a 4 KiB object moved through a 1 KiB transfer
            // buffer, and nothing allocated for either.
            var out: [8 << 10]u8 = undefined;
            var w = std.Io.Writer.fixed(&out);

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            _ = try ex.begin(&client, .{
                .method = .GET,
                .url = try canned.url(&buf),
                .transfer_buffer = &transfer,
            });
            const n = try ex.pipe(&w);

            try testing.expectEqual(@as(u64, 4096), n);
            try testing.expectEqual(@as(usize, 4096), w.buffered().len);
            try testing.expectEqual(@as(u8, 'x'), w.buffered()[4095]);
        }
    }.run);
}

test "a streamed body sends exactly the length it announced" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = io.async(Canned.serveWithBody, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var transfer: [1 << 10]u8 = undefined;

            // A reader over bytes already in hand is still a reader, which is
            // what makes this testable without a file: the source of a
            // streamed put is a `*std.Io.Reader` and nothing more.
            var source = std.Io.Reader.fixed("cinta laut dan langit");

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            const head = try ex.begin(&client, .{
                .method = .PUT,
                .url = try canned.url(&buf),
                .content_type = "text/plain",
                .body = .{ .stream = .{ .reader = &source, .len = 21 } },
                .transfer_buffer = &transfer,
            });
            try testing.expect(head.ok());

            served.await(io) catch {};
            const sent = canned.seen[0..canned.seen_len];
            try testing.expect(std.mem.startsWith(u8, sent, "PUT /"));
            try testing.expect(std.mem.indexOf(u8, sent, "content-length: 21") != null);
            try testing.expect(std.mem.indexOf(u8, sent, "content-type: text/plain") != null);
            // Framed by content-length, so the bytes arrive as themselves
            // rather than inside chunk headers a signature never covered.
            try testing.expect(std.mem.indexOf(u8, sent, "chunked") == null);
            try testing.expectEqualStrings(
                "cinta laut dan langit",
                canned.body_seen[0..canned.body_seen_len],
            );
        }
    }.run);
}

test "a signed call says its own host and authorization, verbatim" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var transfer: [1 << 10]u8 = undefined;

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            _ = try ex.begin(&client, .{
                .method = .GET,
                .url = try canned.url(&buf),
                // What SigV4 needs and what std would otherwise decide: the
                // host as it was signed, and an authorization header nobody
                // reformats.
                .host = "bucket.s3.example.com",
                .authorization = "AWS4-HMAC-SHA256 Credential=A/2/us-east-1/s3/aws4_request,Signature=ff",
                .headers = &.{.{ .name = "x-amz-date", .value = "20260817T000000Z" }},
                .transfer_buffer = &transfer,
            });

            served.await(io) catch {};
            const sent = canned.seen[0..canned.seen_len];
            try testing.expect(std.mem.indexOf(u8, sent, "host: bucket.s3.example.com") != null);
            try testing.expect(std.mem.indexOf(u8, sent, "Signature=ff") != null);
            try testing.expect(std.mem.indexOf(u8, sent, "x-amz-date: 20260817T000000Z") != null);
            // The one std would have written from the URL, and did not.
            try testing.expect(std.mem.indexOf(u8, sent, "host: 127.0.0.1") == null);
        }
    }.run);
}

/// Counts what passes through it and forwards the rest.
///
/// `http/budget.zig` has the same twenty lines, and this is not shared with
/// it: a Fitting may not import `nilo_http` (ADR 0042), and pushing a test
/// helper down into Core to avoid writing it twice would put something in the
/// vocabulary that no shipped code calls. Twenty duplicated lines is the
/// cheaper of the two.
const Counting = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,
    bytes: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        self.bytes += len;
        return self.child.vtable.alloc(self.child.ptr, len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.vtable.resize(self.child.ptr, m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.vtable.remap(self.child.ptr, m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.vtable.free(self.child.ptr, m, a, ra);
    }
};

test "a call on a warm connection allocates once, and it is the body" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 64;

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);

            // Two requests down one connection, and only the second counted.
            // Opening a connection is where `std.http.Client` allocates its
            // own buffers, and those are a cost of the *connection* rather
            // than of a call — counting them here would report a number no
            // steady-state request ever pays. The same reason `http/app.zig`'s
            // budget test warms the arena before it counts.
            var served = io.async(Canned.serveKeepAlive, .{ &canned, @as(usize, 2) });
            defer served.cancel(io) catch {};

            _ = try client.get(&scope, url, .{});

            var counting: Counting = .{ .child = testing.allocator };
            var counted: core.Run = .init(counting.allocator());
            defer counted.deinit();

            const res = try client.get(&counted, url, .{});
            try testing.expectEqual(@as(usize, 64), res.body.view().len);

            // One, and it is the body — `allocRemaining` into the Scope's
            // arena. The gate is a semaphore with no allocation behind it, the
            // deadline arms into a slot inside the `Bound` on the stack, and
            // the head is written into the connection's own buffer.
            //
            // Raising this needs a reason. It is the same rule ADR 0018's
            // second row puts on the inbound path, applied to the way out.
            try testing.expectEqual(@as(usize, 1), counting.allocs);
        }
    }.run);
}

test "a pooled connection the peer already closed costs one retry, not a failure" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 12;

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);

            var served = io.async(Canned.serveThenReap, .{&canned});
            defer served.cancel(io) catch {};

            // The call that leaves a connection in the pool. The server has
            // closed it by the time this returns.
            const first = try client.get(&scope, url, .{});
            try testing.expectEqual(@as(usize, 12), first.body.view().len);

            // And the one that finds it dead. Without the retry this is
            // `error.HttpConnectionClosing` reaching a handler as a 500 that
            // nothing about the request deserved.
            const second = try client.get(&scope, url, .{});
            try testing.expectEqual(@as(usize, 12), second.body.view().len);

            // Two connections for two calls, which is the shape of the fix:
            // the second call did not reuse the corpse, it dialled again.
            try testing.expectEqual(@as(usize, 2), canned.accepted);
        }
    }.run);
}

