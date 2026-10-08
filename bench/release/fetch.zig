//! nilo_fetch: one GET on a pooled keep-alive connection, its whole body read
//! into the Scope, which is a call to somebody else's API from inside a
//! request.
//!
//! The upstream is in this process, on a thread of its own, answering every
//! request with the same 100 bytes on the same connection. It is the same
//! code at every ref, so its instructions cancel in the difference over the
//! difference and what is left is the client's. The client is started with
//! `Limits.off` and `timeout_ms = 0`: with no Engine and a deadline, every
//! step of a call becomes a task of the `Io` (ADR 056), a thread hop each way
//! that would measure the scheduler and not the client.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("nilo_fetch");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

const Program = struct {
    /// On the heap, because an `Io` points at its `Threaded` and the client's
    /// pool points at the client, and `init` returns the Program by value.
    state: *State,

    const State = struct {
        threaded: std.Io.Threaded,
        client: fetch.Client,
        upstream: Upstream,
        url_buf: [64]u8,
        url: []const u8,
    };

    pub fn init(gpa: std.mem.Allocator) !Program {
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        state.threaded = .init(gpa, .{});
        errdefer state.threaded.deinit();
        const io = state.threaded.io();

        try state.upstream.open(io);
        state.url = try std.fmt.bufPrint(&state.url_buf, "http://127.0.0.1:{d}/", .{state.upstream.port});

        state.client = .init(gpa, .{ .timeout_ms = 0 });
        try state.client.nilo_start(io, .off);
        return .{ .state = state };
    }

    /// The client closes its pooled connection, which ends the upstream's
    /// connection thread. The `Threaded` and the state are left for the
    /// process to take: the upstream's threads are detached and still hold
    /// the `Io`, and freeing it under them is a use after free for nothing.
    pub fn deinit(self: *Program) void {
        self.state.client.deinit();
    }

    pub fn op(self: *Program, scratch: std.mem.Allocator, _: usize) !void {
        var scope: Scope = .{ .memory = scratch, .lifetime = .init() };
        defer scope.lifetime.deinit();
        const res = try self.state.client.get(&scope, self.state.url, .{});
        if (res.status != .ok or res.body.view().len != Upstream.body.len) return error.WrongAnswer;
        harness.keep(res.body.view().ptr);
    }
};

/// A Scope over the harness's counting arena, so every allocation the call
/// makes is one the harness sees. A `Run` would put its own arena between
/// them and count only the arena's chunks.
const Scope = struct {
    memory: std.mem.Allocator,
    lifetime: core.Lifetime,

    pub fn arena(self: *Scope) std.mem.Allocator {
        return self.memory;
    }

    pub fn str(self: *Scope, bytes: []const u8) core.Str {
        return .fromRequest(bytes, &self.lifetime);
    }
};

/// Keep-alive HTTP/1.1 on loopback, the same fixed answer to every request.
/// The answer is one constant written with one flush, so each call is one
/// read and one write on either side and nothing in it varies run to run.
const Upstream = struct {
    const body = repeat("0123456789", 10);
    const answer = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: text/plain\r\n\r\n{s}",
        .{ body.len, body },
    );

    server: std.Io.net.Server,
    port: u16,

    /// Bound here, before the thread exists, so the port is known and the
    /// first call cannot race the listen.
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
        while (true) {
            // A GET has no body, so the blank line ends the request.
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                if (line.len <= 2) break;
            }
            writer.interface.writeAll(answer) catch return;
            writer.interface.flush() catch return;
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
