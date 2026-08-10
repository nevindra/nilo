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

/// Why the server never got as far as listening. Kept as a value so the
/// message and the error can be produced in two different places.
const StartupFailure = enum {
    bad_address,
    in_use,
    not_permitted,
    unavailable,
    other,

    fn toError(self: StartupFailure) anyerror {
        return switch (self) {
            .bad_address => error.BadAddress,
            .in_use => error.AddressInUse,
            .not_permitted => error.PermissionDenied,
            .unavailable => error.AddressNotAvailable,
            .other => error.CannotListen,
        };
    }
};

/// Matched on the error's name rather than on `error.AddressInUse`,
/// because the Engine infers this error set and which members it has
/// varies by platform — naming one that does not exist on macOS would
/// break the build there rather than improve a message.
fn classifyListenFailure(name: []const u8) StartupFailure {
    if (std.mem.eql(u8, name, "AddressInUse")) return .in_use;
    if (std.mem.eql(u8, name, "PermissionDenied")) return .not_permitted;
    if (std.mem.eql(u8, name, "AccessDenied")) return .not_permitted;
    if (std.mem.eql(u8, name, "AddressNotAvailable")) return .unavailable;
    return .other;
}

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

    // Failing to take the port is the most common way a server does not
    // start, and it used to arrive as a stack trace three files deep in the
    // Engine. What the person running it needs is the port number and what
    // to do next — so the reason travels back as a value, and the error is
    // made fresh below. Going through a value is what resets the error
    // return trace: the one that gets printed then starts in zfast, not in
    // zio's completion queue (ADR 0002 — the Engine is not the user's
    // business, in a crash log least of all).
    var why: StartupFailure = .other;

    const maybe_addr: ?zio.net.IpAddress =
        zio.net.IpAddress.parseIp4(options.address, options.port) catch |err| bad: {
            std.log.err(
                "\"{s}\" is not an address zfast can listen on ({s}). It wants a plain IPv4 " ++
                    "address: \"127.0.0.1\" for this machine only, \"0.0.0.0\" for every interface.",
                .{ options.address, @errorName(err) },
            );
            why = .bad_address;
            break :bad null;
        };
    const addr = maybe_addr orelse return why.toError();

    const maybe_server: ?zio.net.Server =
        addr.listen(.{ .reuse_address = options.reuse_address }) catch |err| failed: {
            why = classifyListenFailure(@errorName(err));
            switch (why) {
                .in_use => std.log.err(
                    "port {d} is already in use — something else is listening on {s}:{d}. " ++
                        "Stop it, or pass `.port = …` to listen() with a free one.",
                    .{ options.port, options.address, options.port },
                ),
                .not_permitted => std.log.err(
                    "not allowed to listen on port {d}. Ports below 1024 need root; " ++
                        "8080 or 8787 do not.",
                    .{options.port},
                ),
                .unavailable => std.log.err(
                    "no interface on this machine has the address {s}, so nothing can listen " ++
                        "on it. \"127.0.0.1\" reaches this machine only, \"0.0.0.0\" every " ++
                        "interface.",
                    .{options.address},
                ),
                else => std.log.err(
                    "could not listen on {s}:{d}: {s}",
                    .{ options.address, options.port, @errorName(err) },
                ),
            }
            break :failed null;
        };
    const server = maybe_server orelse return why.toError();
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
