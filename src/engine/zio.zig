//! An Engine built on zio (https://github.com/lalinsky/zio).
//!
//! The only file in zfast allowed to name zio. See ADR 0002.

const std = @import("std");
const zio = @import("zio");

pub const debug_io = zio.debug_io;

pub const Options = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 8787,
};

/// Run `handler(state, in, out)` for every accepted connection, each in
/// its own fiber, until that connection is done. The Reader/Writer are
/// already buffered; the handler does not need to know there is a socket
/// behind them. `handler` must be
/// `fn (@TypeOf(state), *std.Io.Reader, *std.Io.Writer) void`.
pub fn serve(gpa: std.mem.Allocator, options: Options, state: anytype, comptime handler: anytype) !void {
    const State = @TypeOf(state);
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp4(options.address, options.port);
    const server = try addr.listen(.{});
    defer server.close();

    std.log.info("zfast listening on {f}", .{server.socket.address});

    const Conn = struct {
        fn run(st: State, stream: zio.net.Stream) void {
            defer stream.close();

            // One response = one flush = one segment; Nagle would only add
            // latency without saving anything, so it is turned off.
            stream.socket.setNoDelay(true) catch {};

            // The read buffer doubles as the ceiling on request head size
            // (431 if it is exceeded). The write buffer is big enough for a
            // response head plus a body the size of the primary metric
            // (~1KB of JSON).
            var read_buf: [8 * 1024]u8 = undefined;
            var write_buf: [4 * 1024]u8 = undefined;
            var reader = stream.reader(&read_buf);
            var writer = stream.writer(&write_buf);

            handler(st, &reader.interface, &writer.interface);
        }
    };

    var group: zio.Group = .init;
    defer group.cancel();

    while (true) {
        const stream = try server.accept(.{});
        errdefer stream.close();
        try group.spawn(Conn.run, .{ state, stream });
    }
}

// ---- the per-request slot (see ADR 0007) ----
//
// zio runs each connection in its own fiber, and many fibers share one OS
// thread. So a threadlocal is wrong: fiber A can fall asleep mid-handler,
// fiber B runs on the same thread, then A wakes up and writes into B's
// slot. `zio.TaskLocal` binds the value to its fiber and travels with it
// if the fiber moves threads — exactly what is needed.

var fiber_slot: zio.TaskLocal(*anyopaque) = .{};

/// Storage for one slot binding. Owned by the caller: put it on the fiber
/// stack, and do not move it while it is bound.
pub const Binding = zio.TaskLocal(*anyopaque).Node;

pub const binding_unset: Binding = .unset;

/// Bind `p` to the fiber currently running. Panics if called outside a
/// fiber — only the Engine may call it, and the Engine always knows.
pub fn bindSlot(n: *Binding, p: *anyopaque) void {
    fiber_slot.set(n, p);
}

pub fn unbindSlot(n: *Binding) void {
    fiber_slot.clear(n);
}

/// The slot of the fiber currently running, or null if there is no fiber
/// (a unit test calling App directly, for instance).
pub fn slot() ?*anyopaque {
    return fiber_slot.get();
}
