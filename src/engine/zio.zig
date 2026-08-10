//! An Engine built on zio (https://github.com/lalinsky/zio).
//!
//! The only file in zfast allowed to name zio. See ADR 0002.

const std = @import("std");
const zio = @import("zio");

pub const debug_io = zio.debug_io;

pub const Options = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 8787,
    /// On by default so that stopping the server and starting it again
    /// works. Without it, connections left in TIME_WAIT hold the port and
    /// the restart fails with `AddressInUse` — which, during development,
    /// is every single restart. It does not let two servers share a port:
    /// a second listener on the same address is still refused.
    reuse_address: bool = true,

    /// How many OS threads run fibers. 0 means one per core.
    ///
    /// zio's own default is a single executor. That is the right default
    /// for a library that might be embedded in someone else's thread, and
    /// the wrong one for a server process, which would otherwise leave
    /// every core but one idle.
    ///
    /// The consequence is that handlers really do run at the same time on
    /// different threads, so a Service that gets written to needs
    /// `zfast.Mutex` (ADR 0011). Set this to 1 and that stops being true —
    /// but so does using the machine.
    threads: u8 = 0,

    /// Bytes of the connection's read buffer. It doubles as the ceiling on
    /// the size of a request head: a head that does not fit is answered
    /// with 431.
    read_buffer: usize = 8 * 1024,

    /// Bytes of the connection's write buffer. A response that fits in it
    /// leaves as one write; a bigger one is split across several.
    ///
    /// Together with `read_buffer` this is most of what an idle connection
    /// costs, so it is worth turning down for a server holding many
    /// connections open and up for one serving large responses.
    write_buffer: usize = 4 * 1024,
};

/// Run `handler(state, in, out)` for every accepted connection, each in
/// its own fiber, until that connection is done. The Reader/Writer are
/// already buffered; the handler does not need to know there is a socket
/// behind them. `handler` must be
/// `fn (@TypeOf(state), *std.Io.Reader, *std.Io.Writer) void`.
pub fn serve(gpa: std.mem.Allocator, options: Options, state: anytype, comptime handler: anytype) !void {
    const State = @TypeOf(state);
    const threads: u8 = if (options.threads > 0)
        options.threads
    else
        @intCast(@min(std.Thread.getCpuCount() catch 1, 255));

    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(threads) });
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp4(options.address, options.port);
    const server = try addr.listen(.{ .reuse_address = options.reuse_address });
    defer server.close();

    std.log.info("zfast listening on {f} across {d} thread(s)", .{ server.socket.address, threads });

    const Conn = struct {
        fn run(st: State, stream: zio.net.Stream, conn_gpa: std.mem.Allocator, sizes: Options) void {
            defer stream.close();

            // One response = one flush = one segment; Nagle would only add
            // latency without saving anything, so it is turned off.
            stream.socket.setNoDelay(true) catch {};

            // Allocated rather than put on the fiber stack, so the sizes can
            // be an option instead of a constant. Twice per connection, not
            // per request — next to a connection's lifetime it is nothing.
            const read_buf = conn_gpa.alloc(u8, sizes.read_buffer) catch return;
            defer conn_gpa.free(read_buf);
            const write_buf = conn_gpa.alloc(u8, sizes.write_buffer) catch return;
            defer conn_gpa.free(write_buf);

            var reader = stream.reader(read_buf);
            var writer = stream.writer(write_buf);

            handler(st, &reader.interface, &writer.interface);
        }
    };

    var group: zio.Group = .init;
    defer group.cancel();

    while (true) {
        const stream = try server.accept(.{});
        errdefer stream.close();
        try group.spawn(Conn.run, .{ state, stream, gpa, options });
    }
}

/// A monotonic clock reading in nanoseconds, for measuring how long
/// something took. Zig 0.16's `std.time` has no clock of its own, and the
/// Engine owns one anyway, so it comes through the Bulkhead like
/// everything else.
pub fn monotonicNanos() u64 {
    return @intCast(zio.Timestamp.now(.monotonic).toNanoseconds());
}

/// A lock that parks the fiber rather than the OS thread under it. Also
/// works from a plain thread with no fiber at all, which is what makes a
/// handler holding one still testable as an ordinary function (ADR 0003).
pub const Mutex = zio.Mutex;

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
