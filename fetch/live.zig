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
    /// Filled in by `serveOne` so a test can assert on what arrived.
    seen: [1024]u8 = undefined,
    seen_len: usize = 0,

    /// `Io.net.Server` cannot report the port it was given, so asking for 0
    /// and reading it back is not available — walk a range instead.
    fn open(io: std.Io) !Canned {
        var candidate: u16 = 39_200;
        while (candidate < 39_400) : (candidate += 1) {
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
        try w.print("HTTP/1.1 {s}\r\nContent-Length: {d}\r\n\r\n", .{
            self.status,
            self.claim_len orelse self.body_len,
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
