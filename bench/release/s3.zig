//! nilo_s3: one GetObject, signed with SigV4 and held whole in the Scope,
//! which is a handler serving a file out of a bucket.
//!
//! The upstream is a stub in this process, on a thread of its own, answering
//! every request with the same kilobyte on the same connection. It checks no
//! signature: the signing is the client's work and is counted either way, and
//! checking it would put a second SigV4 into the number. Static credentials
//! and a plaintext endpoint, so the payload hash is a real SHA-256 of nothing,
//! the way it is against MinIO in a test. The Store gets `timeout_ms = 0` for
//! the reason `fetch.zig` gives its client one.
//!
//! The signature reads the wall clock for its date, which the count follows:
//! `x-amz-date` pads every field under ten with a `0`, at ~190 instructions a
//! request each, so the same binary reads 0.35% higher in seconds :00 to :09.
//! `release.py` measures this program for every ref inside one minute from
//! second 10 for that reason (its `CLOCKED`). The signing key is derived again
//! only when the date changes: a run that crosses midnight UTC pays one more
//! derivation, a few thousand instructions in the total.

const std = @import("std");
const core = @import("nilo_core");
const s3 = @import("nilo_s3");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

/// Path style, because `127.0.0.1` cannot carry a bucket as a DNS label.
/// `key_max` as `bench/s3_server.zig` has it.
const Files = s3.Bucket("nilo-release", .{
    .style = .path,
    .max_bytes = 64 << 10,
    .key_max = 128,
});

const Program = struct {
    /// On the heap, because an `Io` points at its `Threaded`, a Bucket at its
    /// Store, and `init` returns the Program by value.
    state: *State,

    const State = struct {
        threaded: std.Io.Threaded,
        store: s3.Store,
        files: Files,
        upstream: Upstream,
        endpoint_buf: [64]u8,
    };

    pub fn init(gpa: std.mem.Allocator) !Program {
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        state.threaded = .init(gpa, .{});
        errdefer state.threaded.deinit();
        const io = state.threaded.io();

        try state.upstream.open(io);
        const endpoint = try std.fmt.bufPrint(&state.endpoint_buf, "http://127.0.0.1:{d}", .{state.upstream.port});

        state.store = try s3.open(gpa, .{
            .endpoint = endpoint,
            .region = "ap-southeast-1",
            .credentials = .{ .static = .{
                .access_key_id = "AKIDNILORELEASEBENCH",
                .secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYNILORELEASE",
            } },
            .timeout_ms = 0,
        });
        errdefer state.store.deinit();
        state.files = try Files.open(&state.store);
        try state.files.nilo_start(io, .off);
        return .{ .state = state };
    }

    /// As in `fetch.zig`: the Store's client closes its pooled connection,
    /// and the `Threaded` is left for the process to take, because the
    /// upstream's detached threads still hold the `Io`.
    pub fn deinit(self: *Program) void {
        self.state.files.deinit();
        self.state.store.deinit();
    }

    pub fn op(self: *Program, scratch: std.mem.Allocator, _: usize) !void {
        var scope: Scope = .{ .memory = scratch, .lifetime = .init() };
        defer scope.lifetime.deinit();
        const object = try self.state.files.get(&scope, "avatars/7/original.bin");
        if (object.len != Upstream.body.len) return error.WrongAnswer;
        harness.keep(object.bytes.view().ptr);
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

/// Keep-alive HTTP/1.1 on loopback, the same fixed answer to every request:
/// what S3 sends for a GetObject, less the headers nothing here reads. One
/// constant written with one flush, so nothing in it varies run to run.
const Upstream = struct {
    const body = repeat("0123456789abcdef", 64);
    const answer = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: application/octet-stream\r\n" ++
            "ETag: \"0f343b0931126a20f133d67c2b018a3b\"\r\n\r\n{s}",
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
        var out_buf: [2048]u8 = undefined;
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
