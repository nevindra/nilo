//! An Engine built on zio (https://github.com/lalinsky/zio).
//!
//! The only file in zfast allowed to name zio. See ADR 0002.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");

pub const debug_io = zio.debug_io;

pub const Options = struct {
    /// An IPv4 or IPv6 address in the usual notation: `"127.0.0.1"` and
    /// `"::1"` for this machine only, `"0.0.0.0"` and `"::"` for every
    /// interface. A host name is not resolved — this is the address to bind
    /// to, and a name would make which interface it lands on a lookup's
    /// business rather than yours.
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

    /// Stop on Ctrl-C (SIGINT) and on SIGTERM, which is what a container
    /// runtime or a supervisor sends when it wants the process to go.
    ///
    /// On by default because the alternative is worse in both directions:
    /// during development, a server that ignores Ctrl-C has to be hunted
    /// down with `kill`; in production, a deploy that sends SIGTERM would
    /// otherwise kill requests mid-response. Turn it off if the surrounding
    /// program installs handlers of its own — then call `App.shutdown()`
    /// from them.
    stop_on_signal: bool = true,

    /// How long a stop waits for requests already in flight before giving
    /// up on them. 0 means don't wait.
    ///
    /// Long enough for an ordinary request to finish, short enough that a
    /// deploy is not held up by one slow handler. What is waited on is
    /// requests being answered, not connections held open: a browser tab
    /// parked on a keep-alive connection is holding no work, so Ctrl-C does
    /// not spend a single millisecond of this on it.
    shutdown_grace_ms: u32 = 10_000,
};

/// The flag that turns "please stop" into a server that has stopped.
///
/// It lives here rather than in `App` because stopping is the Engine's
/// business — it owns the accept loop that has to notice. `App` holds one
/// and hands it to `serve`; `App.shutdown()` sets it.
pub const Stop = struct {
    requested: std.atomic.Value(bool) = .init(false),
    /// Requests being answered right now — what a stop waits for.
    ///
    /// Requests, not connections. A connection between two keep-alive
    /// requests is parked in a read that will not return until the client
    /// sends something, and waiting on it would mean every idle browser tab
    /// adding the full grace period to a Ctrl-C. It is holding no work, so
    /// it is closed rather than waited for; `Connection: close` on the last
    /// response and a listener that has stopped accepting are both already
    /// telling that client where to go next.
    ///
    /// Kept by `App`, which is the only thing that knows when a request
    /// starts and stops.
    in_flight: std.atomic.Value(u32) = .init(0),

    /// Safe from any thread, and from a signal handler — one atomic store
    /// is all it does.
    pub fn request(self: *Stop) void {
        self.requested.store(true, .release);
    }

    pub fn isRequested(self: *const Stop) bool {
        return self.requested.load(.acquire);
    }
};

/// How often the accept loop looks up to see whether a stop was asked for.
///
/// Polling rather than waking the loop directly: a signal handler may not
/// touch a wait queue, and closing the listening socket out from under a
/// pending `accept` is a use-after-free waiting to happen. One timer per
/// server, five times a second, is not a cost worth avoiding — and a fifth
/// of a second is below what anybody notices after pressing Ctrl-C.
const accept_poll_ms = 200;

/// How often a stop looks to see whether the last request has finished.
/// Shorter than the accept poll: by the time this runs somebody is waiting
/// for the process to go, and an ordinary request finishes in less time
/// than one of these.
const drain_poll_ms = 20;

/// Whether `serve` already said, in words, why the server did not start.
///
/// `App.listen()` stops the process on these instead of returning them: the
/// message is the whole answer, and letting the error travel up to `main`
/// would print a stack trace through zfast on top of it (ADR 0002 — the
/// Engine is not the user's business, in a crash log least of all).
pub fn explained(err: anyerror) bool {
    return switch (err) {
        error.BadAddress,
        error.AddressInUse,
        error.PermissionDenied,
        error.AddressNotAvailable,
        error.CannotListen,
        => true,
        else => false,
    };
}

// ---- stopping on a signal ----
//
// A signal handler may do almost nothing safely, so it does almost nothing:
// one atomic store into the `Stop` below. The accept loop is what notices.

var signal_target: std.atomic.Value(?*Stop) = .init(null);

/// The signal number as this platform's `Sigaction` hands it over — an enum
/// on Linux, a plain integer elsewhere. Read off `Sigaction` rather than
/// spelled out, so it stays right wherever this is built.
const SigNum = @typeInfo(@typeInfo(@typeInfo(
    @FieldType(@FieldType(std.posix.Sigaction, "handler"), "handler"),
).optional.child).pointer.child).@"fn".params[0].type.?;

fn onStopSignal(_: SigNum) callconv(.c) void {
    const stop = signal_target.load(.acquire) orelse return;
    // A second Ctrl-C means the person has stopped waiting for the graceful
    // part. 130 is the shell's convention for "killed by SIGINT".
    if (stop.isRequested()) std.process.exit(130);
    stop.request();
}

/// What was handling these before, so the previous arrangement is put back
/// when `serve` returns. A library that leaves its own handlers installed
/// after it is done has changed the program behind its back.
var previous_int: std.posix.Sigaction = undefined;
var previous_term: std.posix.Sigaction = undefined;

fn installStopSignals(stop: *Stop) void {
    if (builtin.os.tag == .windows) return;
    signal_target.store(stop, .release);
    const action = std.posix.Sigaction{
        .handler = .{ .handler = onStopSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, &previous_int);
    std.posix.sigaction(std.posix.SIG.TERM, &action, &previous_term);
}

fn restoreStopSignals() void {
    if (builtin.os.tag == .windows) return;
    std.posix.sigaction(std.posix.SIG.INT, &previous_int, null);
    std.posix.sigaction(std.posix.SIG.TERM, &previous_term, null);
    signal_target.store(null, .release);
}

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
///
/// Returns when `stop` is set — by a signal, or by somebody calling
/// `App.shutdown()` — once the connections still being served have
/// finished or the grace period has run out.
pub fn serve(
    gpa: std.mem.Allocator,
    options: Options,
    stop: *Stop,
    state: anytype,
    comptime handler: anytype,
) !void {
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
        zio.net.IpAddress.parseIp(options.address, options.port) catch |err| bad: {
            std.log.err(
                "\"{s}\" is not an address zfast can listen on ({s}). It wants an IP address, " ++
                    "not a host name: \"127.0.0.1\" or \"::1\" for this machine only, " ++
                    "\"0.0.0.0\" or \"::\" for every interface.",
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
    // Whatever is still running when the grace period is over is cut off
    // here. By then it has had its chance.
    defer group.cancel();

    if (options.stop_on_signal) installStopSignals(stop);
    defer if (options.stop_on_signal) restoreStopSignals();

    while (!stop.isRequested()) {
        const stream = server.accept(.{ .timeout = .fromMilliseconds(accept_poll_ms) }) catch |err| {
            // The wait ran out, which is the loop's chance to look at the
            // stop flag rather than anything having gone wrong.
            if (err == error.Timeout) continue;
            return err;
        };
        errdefer stream.close();
        try group.spawn(Conn.run, .{ state, stream, gpa, options });
    }

    drain(stop, options.shutdown_grace_ms);
}

/// Having stopped accepting, let the requests still being answered finish.
///
/// Connections sitting idle between keep-alive requests are not waited for
/// — see `Stop.in_flight`. They are closed by the `group.cancel()` above,
/// which is what the client is already being told to expect.
fn drain(stop: *const Stop, grace_ms: u32) void {
    var waited: u32 = 0;
    while (true) {
        const busy = stop.in_flight.load(.acquire);
        if (busy == 0) {
            std.log.info("zfast stopped", .{});
            return;
        }
        if (waited >= grace_ms) {
            std.log.warn(
                "zfast stopped with {d} request(s) still unanswered after {d}ms — they were cut " ++
                    "off. Pass `.shutdown_grace_ms = …` to listen() if handlers need longer.",
                .{ busy, grace_ms },
            );
            return;
        }
        if (waited == 0) std.log.info(
            "zfast stopping: {d} request(s) still being answered, waiting up to {d}ms",
            .{ busy, grace_ms },
        );

        const step = @min(drain_poll_ms, grace_ms - waited);
        zio.sleep(.fromMilliseconds(step)) catch return;
        waited += step;
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
