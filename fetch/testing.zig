//! `fetch.testing` — a server that answers what a test told it to, for a
//! suite that wants one real exchange without writing the far end itself.
//!
//! ```zig
//! var canned = try fetch.testing.Canned.open(io);
//! defer canned.close();
//! canned.reply("429 Too Many Requests", "Retry-After: 30\r\n", "slow down");
//! var served = try io.concurrent(fetch.testing.Canned.serveOne, .{&canned});
//! defer served.cancel(io) catch {};
//!
//! var buf: [64]u8 = undefined;
//! const res = try client.get(&run, try canned.url(&buf), .{});
//! try std.testing.expectEqualStrings("30", res.header("retry-after").?);
//! ```
//!
//! This was private to `fetch/live.zig` for a year, and the guide told a
//! suite of somebody's own to copy its shape — a loopback
//! `std.Io.net.Server`, a `serveOne`, the port read back — so every such
//! suite wrote it again ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)).
//! It is not an HTTP server: just enough of one to drive a client, and
//! `serveOne` is the whole of what a caller's test needs. The other `serve*`
//! below are the shapes the module's own tests drive — a keep-alive, a
//! reaped connection, a chunked body, silence — and they are public because
//! `live.zig` is another file now, not because a caller should reach for
//! them first.
//!
//! Nothing here touches the Engine. A `Canned` runs on `std.Io.Threaded`,
//! which is the entry condition for the Fitting layer
//! ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)), and a
//! program that never names `fetch.testing` links none of it.

const std = @import("std");

/// A server that answers exactly what a test asked it to, once per
/// connection.
///
/// **Start it with `io.concurrent`, and `io.async` is the deadlock this
/// harness held for a day.** `std.Io.async` is allowed to run the function
/// on the calling thread — `Threaded` does exactly that whenever its pool
/// counts as many busy tasks as it has spare cores, which on a two-core
/// machine is one. Until ADR 056 nothing in the module's tests ever had a
/// task in flight while a server was being started, so the inline path was
/// never taken. Now every bounded call runs as a task of its own, and the
/// worker that ran it wakes the awaiter *before* it takes the pool's lock
/// to count itself free — so the very next `io.async(serveOne)` can see the
/// pool full, run `accept` on the test's own thread, and wait there for a
/// connection that thread was about to make. Found at test 19 of 34 with
/// two of these binaries running at once, at zero CPU, the way `CLAUDE.md`
/// says to look. `concurrent` is the call whose contract is the one the
/// harness actually needs: the server has to be on another thread, or
/// there is no test.
pub const Canned = struct {
    server: std.Io.net.Server,
    io: std.Io,
    port: u16,
    /// What `serveOne` answers with, in three parts. `reply` sets all three;
    /// the fields are here for a test that wants one of them.
    ///
    /// The status line after `HTTP/1.1 `.
    status: []const u8 = "200 OK",
    /// Response headers beyond `Content-Length`, each with its own `\r\n`.
    headers: []const u8 = "",
    /// The body, when a test gave one. Null is `body_len` bytes of `x`,
    /// which is what the module's own tests about ceilings and drains want:
    /// a body whose size is the subject and whose contents are not.
    body: ?[]const u8 = null,
    /// How many bytes of `x` to send when `body` is null, and what to claim
    /// in the header. They differ only when a test is about a server that
    /// lies.
    body_len: usize = 0,
    claim_len: ?usize = null,
    /// Filled in by `serveOne` so a test can assert on what arrived: the
    /// request head, one line per header, `\n` between them. `request`
    /// reads it out.
    seen: [1024]u8 = undefined,
    seen_len: usize = 0,
    /// The request body, for the tests about what a send puts on the wire.
    /// `requestBody` reads it out.
    body_seen: [1024]u8 = undefined,
    body_seen_len: usize = 0,
    /// How many connections have been accepted — see `serveEach`.
    accepted: usize = 0,

    /// Port 0, and the kernel's answer read back.
    ///
    /// **This used to walk a range of a thousand ports from a start derived
    /// from the thread id**, on the belief that `std.Io.net.Server` could not
    /// report the port it was given — and it could the whole time.
    /// `Threaded.netListenIpPosix` calls `getsockname` after `listen` and
    /// hands the result back as `Server.socket.address`, whose own doc says
    /// "the resolved ephemeral port number". The belief was written down in
    /// three files as re-checked rather than believed, and the walk it
    /// justified needed `s3/canned.zig` and `http/live.zig` to keep their
    /// ranges apart from this one by comment: ten consecutive `zig build
    /// test-all` runs failed from the sixth on when two of them overlapped.
    ///
    /// An ephemeral port is one nothing else is walking, and a port the
    /// kernel just handed out is not one in `TIME-WAIT`, so both halves of
    /// what the walk was for are the kernel's job again — and a suite of
    /// somebody's own needs no range of its own either. `reuse_address` is
    /// still not set, for the reason it never was: std sets `SO_REUSEPORT`
    /// with it, and two test binaries would share one port.
    pub fn open(io: std.Io) !Canned {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const server = try address.listen(io, .{});
        return .{ .server = server, .io = io, .port = server.socket.address.getPort() };
    }

    /// `http://127.0.0.1:<port>/`, written into `buf`.
    pub fn url(self: *Canned, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/", .{self.port});
    }

    /// What `serveOne` answers: a status line after `HTTP/1.1 `, headers
    /// each ending in `\r\n` (`""` for none — `Content-Length` is written
    /// for you), and the body as it is.
    pub fn reply(self: *Canned, status: []const u8, headers: []const u8, body: []const u8) void {
        self.status = status;
        self.headers = headers;
        self.body = body;
        self.body_len = body.len;
    }

    /// The request head that arrived, one line per header and `\n` between
    /// them, as it was on the wire. Empty until a `serve*` has read one.
    pub fn request(self: *const Canned) []const u8 {
        return self.seen[0..self.seen_len];
    }

    /// The request body that arrived, up to the first kilobyte.
    pub fn requestBody(self: *const Canned) []const u8 {
        return self.body_seen[0..self.body_seen_len];
    }

    /// Accept one connection, read the request whole — head and the body
    /// its `content-length` announced — answer it, and close.
    pub fn serveOne(self: *Canned) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        self.accepted += 1;

        var in_buf: [4 << 10]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);

        // The whole head, line by line to the blank one. Reading only as far
        // as the first `\r` would keep the request line and drop every header,
        // which is exactly what the header test is about — so it is read the
        // way a server reads it.
        const body_len = try self.readHead(&reader.interface);

        // And the body the head announced, kept up to what fits so a test
        // about what went out can read it back; the rest is read and dropped
        // so the answer is not written while the request is still arriving.
        self.body_seen_len = @min(body_len, self.body_seen.len);
        try reader.interface.readSliceAll(self.body_seen[0..self.body_seen_len]);
        if (body_len > self.body_seen_len) _ = try reader.interface.discard(.limited(body_len - self.body_seen_len));

        var out_buf: [64 << 10]u8 = undefined;
        var writer = stream.writer(self.io, &out_buf);
        const w = &writer.interface;
        // `headers` goes here as well as in `serveEach`, and leaving it out
        // of one of them is how the header test came to assert against
        // headers that were never sent: it sets them, it is served by *this*
        // function, and `head.header("etag").?` panicked on a null.
        try w.print("HTTP/1.1 {s}\r\nContent-Length: {d}\r\n{s}\r\n", .{
            self.status,
            self.claim_len orelse self.body_len,
            self.headers,
        });
        if (self.body) |bytes| try w.writeAll(bytes) else try w.splatByteAll('x', self.body_len);
        try w.flush();
    }

    /// The head off `r`, into `seen`, and the `content-length` it named or
    /// zero.
    fn readHead(self: *Canned, r: *std.Io.Reader) !usize {
        var body_len: usize = 0;
        while (true) {
            // Inclusive, because the exclusive form leaves the delimiter in
            // the buffer and the next call comes straight back empty — which
            // reads as "the head ended after one line".
            const line = try r.takeDelimiterInclusive('\n');
            const trimmed = std.mem.trimEnd(u8, line, "\r\n");
            if (trimmed.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                const value = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
                body_len = std.fmt.parseInt(usize, value, 10) catch 0;
            }
            const room = self.seen.len - self.seen_len;
            if (room < trimmed.len + 1) continue;
            @memcpy(self.seen[self.seen_len..][0..trimmed.len], trimmed);
            self.seen[self.seen_len + trimmed.len] = '\n';
            self.seen_len += trimmed.len + 1;
        }
        return body_len;
    }

    /// `count` requests on **one** connection, which `serveOne` cannot do:
    /// it closes after answering, so a client that comes back gets
    /// `error.HttpConnectionClosing` from its own pool. Keep-alive is the
    /// ordinary case for anything a service calls repeatedly, and it is the
    /// only way to ask what a call costs once the connection already exists.
    pub fn serveKeepAlive(self: *Canned, count: usize) !void {
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
    pub fn serveThenReap(self: *Canned) !void {
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

    /// The same reaping as `serveThenReap`, arrived at the other way round:
    /// the peer closes a connection that has an **unread** request sitting in
    /// it, so the kernel sends an RST rather than a FIN and the client sees
    /// `ReadFailed` where the other spelling gives `HttpConnectionClosing`.
    ///
    /// Which of the two a real client meets is a race it does not run, so both
    /// belong in the suite. This one used to arrive by accident: `serveThenReap`
    /// produced it whenever the machine was loaded enough for the client's
    /// second request to beat the server's `close`, which under `zig build
    /// test-all` was about one run in three, and it failed because
    /// `Exchange.nothingCameBack` did not exist yet.
    ///
    /// **The one unread byte is what makes it deterministic, and a timer would
    /// not have been.** Reading exactly one byte of the second request proves
    /// the request arrived, and leaves the rest of it in the receive queue,
    /// which is the condition the kernel turns into an RST. A `sleep` long
    /// enough to lose the race on this machine is a `sleep` that silently
    /// stops losing it on a slower one, and the test would go on passing
    /// through the FIN branch while claiming to cover this one.
    pub fn serveThenReset(self: *Canned) !void {
        {
            var stream = try self.server.accept(self.io);
            defer stream.close(self.io);
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

            // Blocks until the client comes back on this connection, which is
            // the point: everything after the byte stays unread, and `close`
            // on a socket with unread data is an RST.
            //
            // **A reader of one byte, and the size is the whole mechanism.**
            // Taking the byte through `in_buf` above reads as much as has
            // arrived, which is the entire second request, and a receive queue
            // that has been drained into user space closes with a FIN like any
            // other. Written that way this test passed with the branch it
            // exists for switched off. One byte of buffer is one byte off the
            // socket.
            var held_buf: [1]u8 = undefined;
            var held = stream.reader(self.io, &held_buf);
            _ = try held.interface.takeByte();
        }

        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);
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
    pub fn serveEach(self: *Canned, count: usize) !void {
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
                    self.headers,
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
    /// answer it with no body. For the tests about what goes *out*.
    /// `serveOne` reads the body too now; this stays for the tests written
    /// against an empty answer.
    pub fn serveWithBody(self: *Canned) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);

        var in_buf: [64 << 10]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);

        const body_len = try self.readHead(&reader.interface);
        self.body_seen_len = @min(body_len, self.body_seen.len);
        try reader.interface.readSliceAll(self.body_seen[0..self.body_seen_len]);

        var out_buf: [4 << 10]u8 = undefined;
        var writer = stream.writer(self.io, &out_buf);
        const w = &writer.interface;
        try w.print("HTTP/1.1 {s}\r\nContent-Length: 0\r\n{s}\r\n", .{ self.status, self.headers });
        try w.flush();
    }

    /// A `204 No Content` with no `content-length` — the way hyper answers a
    /// presigned POST, and S3 answers a DELETE — on a connection kept open
    /// for a second request, which is answered with a body. What a peer
    /// reaping an idle keep-alive looks like is `serveThenReap`; this is the
    /// peer *not* reaping it, which is what turned a complete answer into a
    /// wait for EOF (ADR 176).
    pub fn serveNoContentThenOne(self: *Canned) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        self.accepted += 1;

        var in_buf: [64 << 10]u8 = undefined;
        var out_buf: [4 << 10]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        var writer = stream.writer(self.io, &out_buf);
        const w = &writer.interface;

        for (0..2) |n| {
            var body_len: usize = 0;
            while (true) {
                const line = try reader.interface.takeDelimiterInclusive('\n');
                const trimmed = std.mem.trimEnd(u8, line, "\r\n");
                if (trimmed.len == 0) break;
                if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                    const value = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
                    body_len = try std.fmt.parseInt(usize, value, 10);
                }
            }
            if (body_len > 0) _ = try reader.interface.discard(.limited(body_len));

            if (n == 0) {
                try w.writeAll("HTTP/1.1 204 No Content\r\nlocation: /bucket/key\r\netag: \"1\"\r\n\r\n");
            } else {
                try w.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{self.body_len});
                try w.splatByteAll('x', self.body_len);
            }
            try w.flush();
        }
    }

    /// Accept, read the head, and never answer: the endpoint that takes the
    /// connection and then says nothing, which is the whole reason a
    /// deadline exists. Holds the socket until the client gives up on it,
    /// which is what closes it from the far side.
    pub fn serveSilence(self: *Canned) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        self.accepted += 1;

        var in_buf: [4 << 10]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break;
        }
        // Nothing more is coming from the client, so this is EOF when the
        // client closes and nothing before that.
        _ = reader.interface.takeByte() catch {};
    }

    /// A head that promises `body_len` bytes and sends three of them, then
    /// stalls the way `serveSilence` does. The deadline has to cover the
    /// body as well as the head, or a server that answers at once and then
    /// trickles is outside it.
    pub fn serveThenStall(self: *Canned) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        self.accepted += 1;

        var in_buf: [4 << 10]u8 = undefined;
        var out_buf: [4 << 10]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        var writer = stream.writer(self.io, &out_buf);
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break;
        }
        const w = &writer.interface;
        try w.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{self.body_len});
        try w.writeAll("xxx");
        try w.flush();
        _ = reader.interface.takeByte() catch {};
    }

    /// A head that promises `body_len` bytes and sends them one at a time,
    /// `trickle_ms` apart: the slow server ADR 056 refused to call a
    /// failure, and the control for the silence clock: a body that keeps
    /// moving, however slowly, must never be called a stall (ADR 056).
    pub fn serveTrickle(self: *Canned, trickle_ms: u32) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        self.accepted += 1;
        // Nagle's algorithm off, so each byte leaves when it is written. With
        // it on, macOS holds a one-byte write for the loopback's delayed
        // acknowledgement, the gaps stretch toward `stall_ms`, and the body
        // this exists to prove is moving gets called a stall.
        const on: c_int = 1;
        std.posix.setsockopt(stream.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&on)) catch {};

        var in_buf: [4 << 10]u8 = undefined;
        var out_buf: [4 << 10]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        var writer = stream.writer(self.io, &out_buf);
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break;
        }
        const w = &writer.interface;
        try w.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{self.body_len});
        try w.flush();
        const t0 = @import("nilo_core").monotonicMicros();
        for (0..self.body_len) |i| {
            try std.Io.sleep(self.io, .fromMilliseconds(trickle_ms), .awake);
            try w.writeByte('x');
            try w.flush();
            std.debug.print("DIAG server sent byte {d} at {d}us\n", .{ i, @import("nilo_core").monotonicMicros() - t0 });
        }
    }

    /// `body_len` bytes of `x` as **chunked** transfer coding, in chunks of
    /// at most 1,000: the framing that reads through a buffer if any does.
    pub fn serveChunked(self: *Canned) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        self.accepted += 1;

        var in_buf: [4 << 10]u8 = undefined;
        var out_buf: [8 << 10]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        var writer = stream.writer(self.io, &out_buf);
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break;
        }
        const w = &writer.interface;
        try w.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
        var left = self.body_len;
        while (left > 0) {
            const n = @min(left, 1_000);
            try w.print("{x}\r\n", .{n});
            try w.splatByteAll('x', n);
            try w.writeAll("\r\n");
            left -= n;
        }
        try w.writeAll("0\r\n\r\n");
        try w.flush();
    }

    /// A `302` to `/moved` and then a `200`, on **one** connection: a chain
    /// of one, for the test about where it ended. One connection because
    /// std pools the first and comes back on it for the second — a server
    /// that hung up after the 302 would hand the client a reaped socket,
    /// and the stale-connection retry would then send the *original* URL
    /// again on a fresh one, which is a different test.
    pub fn serveRedirectThenOne(self: *Canned) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        self.accepted += 1;

        var in_buf: [4 << 10]u8 = undefined;
        var out_buf: [4 << 10]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        var writer = stream.writer(self.io, &out_buf);
        for (0..2) |n| {
            while (true) {
                const line = try reader.interface.takeDelimiterInclusive('\n');
                const trimmed = std.mem.trimEnd(u8, line, "\r\n");
                if (trimmed.len == 0) break;
                const room = self.seen.len - self.seen_len;
                if (room < trimmed.len + 1) continue;
                @memcpy(self.seen[self.seen_len..][0..trimmed.len], trimmed);
                self.seen[self.seen_len + trimmed.len] = '\n';
                self.seen_len += trimmed.len + 1;
            }
            const w = &writer.interface;
            if (n == 0) {
                try w.print("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{d}/moved\r\nContent-Length: 0\r\n\r\n", .{self.port});
            } else {
                try w.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{self.body_len});
                try w.splatByteAll('x', self.body_len);
            }
            try w.flush();
        }
    }

    pub fn close(self: *Canned) void {
        self.server.socket.close(self.io);
    }
};
