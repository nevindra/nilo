//! nilo_fetch's WebSocket client: one text message of 100 bytes sent on an
//! open socket and its echo received, which is what a service that talks to a
//! gateway does all day (ADR 281).
//!
//! The upstream is in this process, on a thread of its own, and **does not use
//! `nilo_core`'s framing**: it reads one masked frame with the 2-byte header a
//! message under 126 bytes has and writes the same bytes back unmasked, so the
//! only code in the difference over the difference that differs between refs
//! is the client's. A ref whose `nilo_fetch` has no `WebSocket` is "n/a" for
//! this row, which is the harness doing what it says. The socket is opened in
//! `init`, so the handshake is a cost paid once and not per operation, and the
//! client has no deadline for the reason `fetch.zig` gives: with no Engine and
//! a bound, every step is a task of the `Io`.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("nilo_fetch");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

const message = repeat("0123456789", 10);

const Program = struct {
    state: *State,

    const State = struct {
        threaded: std.Io.Threaded,
        client: fetch.Client,
        upstream: Upstream,
        url_buf: [64]u8,
        ws: fetch.WebSocket,
    };

    pub fn init(gpa: std.mem.Allocator) !Program {
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        state.threaded = .init(gpa, .{});
        errdefer state.threaded.deinit();
        const io = state.threaded.io();

        try state.upstream.open(io);
        const url = try std.fmt.bufPrint(&state.url_buf, "ws://127.0.0.1:{d}/", .{state.upstream.port});

        state.client = .init(gpa, .{ .timeout_ms = 0 });
        try state.client.nilo_start(io, .off);

        var scope: core.Run = .init(gpa);
        defer scope.deinit();
        state.ws = .idle;
        try state.ws.open(&state.client, &scope, url, .{});
        return .{ .state = state };
    }

    pub fn deinit(self: *Program) void {
        self.state.ws.deinit();
        self.state.client.deinit();
    }

    pub fn op(self: *Program, _: std.mem.Allocator, _: usize) !void {
        try self.state.ws.sendText(message);
        const echoed = (try self.state.ws.receive()) orelse return error.Closed;
        if (echoed.data.len != message.len) return error.WrongAnswer;
        harness.keep(echoed.data.ptr);
    }
};

/// A WebSocket upstream for messages under 126 bytes: the handshake, then each
/// masked frame written back whole and unmasked.
const Upstream = struct {
    server: std.Io.net.Server,
    port: u16,

    fn open(self: *Upstream, io: std.Io) !void {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.server = try address.listen(io, .{});
        self.port = self.server.socket.address.getPort();
        const thread = try std.Thread.spawn(.{}, accept, .{ self.server, io });
        thread.detach();
    }

    fn accept(server: std.Io.net.Server, io: std.Io) void {
        var listening = server;
        while (true) {
            const stream = listening.accept(io) catch return;
            const thread = std.Thread.spawn(.{}, serve, .{ stream, io }) catch {
                stream.close(io);
                continue;
            };
            thread.detach();
        }
    }

    fn serve(stream: std.Io.net.Stream, io: std.Io) void {
        defer stream.close(io);
        var in_buf: [4096]u8 = undefined;
        var out_buf: [512]u8 = undefined;
        var reader = stream.reader(io, &in_buf);
        var writer = stream.writer(io, &out_buf);
        const r = &reader.interface;
        const w = &writer.interface;

        var key: []const u8 = "";
        var key_buf: [64]u8 = undefined;
        while (true) {
            const line = r.takeDelimiterInclusive('\n') catch return;
            if (line.len <= 2) break;
            const name = "sec-websocket-key:";
            if (std.ascii.startsWithIgnoreCase(line, name)) {
                const value = std.mem.trim(u8, line[name.len..], " \t\r\n");
                @memcpy(key_buf[0..value.len], value);
                key = key_buf[0..value.len];
            }
        }
        var sha = std.crypto.hash.Sha1.init(.{});
        sha.update(key);
        sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [20]u8 = undefined;
        sha.final(&digest);
        var accept_key: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_key, &digest);
        w.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept_key}) catch return;
        w.flush() catch return;

        while (true) {
            const head = r.takeArray(2) catch return;
            const len = head[1] & 0x7f;
            const mask = r.takeArray(4) catch return;
            var payload: [125]u8 = undefined;
            r.readSliceAll(payload[0..len]) catch return;
            for (payload[0..len], 0..) |*b, i| b.* ^= mask[i % 4];
            // A close ends it; anything else is echoed.
            if (head[0] & 0x0f == 8) return;
            w.writeAll(&.{ head[0], len }) catch return;
            w.writeAll(payload[0..len]) catch return;
            w.flush() catch return;
        }
    }
};

/// `s` written `n` times over, at compile time: what `s ** n` said before
/// Zig 0.17 took the operator away.
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    comptime {
        @setEvalBranchQuota(10 * n + 1000);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        return &final;
    }
}
