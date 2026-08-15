//! An Engine built on zio (https://github.com/lalinsky/zio).
//!
//! The only file in zfast allowed to name zio. See ADR 0002.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");

pub const debug_io = zio.debug_io;

/// The address at the other end of a connection, as text.
///
/// Text rather than bytes because every use of it is textual: it goes in a
/// log line, or it is compared against an `X-Forwarded-For` entry, which
/// arrives as text and would otherwise have to be parsed back. Formatted
/// once when the connection is accepted, into a fiber stack that is
/// already there, so it costs no allocation and no syscall — `accept`
/// hands the address over along with the socket.
///
/// The port is kept apart from the address, because the address is the
/// part anything identifies a client by. A port changes per connection.
pub const Peer = struct {
    _text: [max_text]u8 = @splat(0),
    _len: u8 = 0,
    port: u16 = 0,

    /// `ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255` — the longest an IP
    /// address gets in text.
    pub const max_text = 45;

    /// Empty when there is no socket behind the request, which is what a
    /// test driving App directly gets.
    pub fn address(self: *const Peer) []const u8 {
        return self._text[0..self._len];
    }

    /// A Peer standing for an address given as text. For the test client,
    /// which has no socket to ask. Anything longer than an address can be
    /// is refused rather than cut short, so a typo does not become a
    /// silently different address.
    pub fn from(text: []const u8) error{AddressTooLong}!Peer {
        if (text.len > max_text) return error.AddressTooLong;
        var self: Peer = .{ ._len = @intCast(text.len) };
        @memcpy(self._text[0..text.len], text);
        return self;
    }

    pub fn format(self: Peer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.address());
    }
};

/// An IPv4 client reaching a server bound to `::` arrives as
/// `::ffff:203.0.113.9`, and a user comparing that against an
/// `X-Forwarded-For` entry saying `203.0.113.9` would find they differ.
/// So a v4-mapped address is written the way everything else writes it.
fn writePeer(out: *[Peer.max_text]u8, sock_addr: zio.net.Address) u8 {
    var w: std.Io.Writer = .fixed(out);
    // A Unix socket has a path where an address would be, and nothing that
    // identifies a client. It reaches a handler as no address at all.
    if (sock_addr.getType() != .ip) return 0;
    const addr = sock_addr.ip;
    switch (addr.getFamily()) {
        .ipv4 => {
            const b: *const [4]u8 = @ptrCast(&addr.in.addr);
            w.print("{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch {};
        },
        .ipv6 => {
            const b = addr.in6.addr;
            if (std.mem.eql(u8, b[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
                w.print("{d}.{d}.{d}.{d}", .{ b[12], b[13], b[14], b[15] }) catch {};
            } else {
                writeIp6(&w, b);
            }
        },
    }
    return @intCast(w.end);
}

fn portOf(sock_addr: zio.net.Address) u16 {
    if (sock_addr.getType() != .ip) return 0;
    return sock_addr.ip.getPort();
}

/// RFC 5952: lower case, and the longest run of zero groups — two or more
/// of them — replaced by `::`.
fn writeIp6(w: *std.Io.Writer, bytes: [16]u8) void {
    var groups: [8]u16 = undefined;
    for (&groups, 0..) |*g, i| {
        g.* = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .big);
    }

    var best_at: usize = 8;
    var best_len: usize = 0;
    var run_at: usize = 0;
    var run_len: usize = 0;
    for (groups, 0..) |g, i| {
        if (g != 0) {
            run_len = 0;
            continue;
        }
        if (run_len == 0) run_at = i;
        run_len += 1;
        if (run_len > best_len) {
            best_at = run_at;
            best_len = run_len;
        }
    }
    // A single zero group is written out, not shortened: `::` has to save
    // something to be worth the ambiguity.
    if (best_len < 2) best_at = 8;

    var i: usize = 0;
    while (i < 8) {
        if (i == best_at) {
            w.writeAll("::") catch {};
            i += best_len;
            continue;
        }
        if (i != 0 and i != best_at + best_len) w.writeByte(':') catch {};
        w.print("{x}", .{groups[i]}) catch {};
        i += 1;
    }
}

// The options a caller passes in are the Bulkhead's — `bulkhead.Options`,
// where they are declared and documented, because they are what a user
// writes inside `listen()` and ADR 0002 says the Engine is not the user's
// business. They arrive here as `anytype` so that this file names only the
// fields it actually reads:
//
//   address  port  reuse_address  threads  read_buffer  write_buffer
//   header_timeout_ms  idle_timeout_ms  body_timeout_ms  write_timeout_ms
//   stop_on_signal  shutdown_grace_ms  max_connections
//
// Anything else in there — a body ceiling, how many proxies to trust — is
// HTTP, and an Engine that knew about it would not be one. A second Engine
// declares its own list; a field it never reads is a field it never sees.

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

/// How many connections are being held right now, against the most that
/// may be.
///
/// A server with no cap does not fail at a number somebody chose — it
/// fails when the machine runs out, and what notices is the OOM killer.
/// Every connection costs a measured 8,767 bytes before it has asked for
/// anything, so a cap is the one option that turns that figure into a
/// number an operator can multiply.
///
/// `take` is only ever called from the accept loop, and there is one of
/// those, so the load and the increment cannot race each other and a
/// compare-and-swap would be a lock nobody contends. `give` is called from
/// every connection fiber, which is why the counter is atomic at all.
/// Nothing is published through it — it is a count, not a handoff — so
/// `.monotonic` is the whole ordering requirement.
pub const Capacity = struct {
    live: std.atomic.Value(u32) = .init(0),
    /// 0 means no limit, which is what zfast did before this existed.
    max: u32 = 0,
    /// Connections closed because the server was full, since it started.
    /// Read only for the log line.
    refused: std.atomic.Value(u64) = .init(0),

    /// Count one more connection, or say there is no room for it.
    pub fn take(self: *Capacity) bool {
        if (self.max != 0 and self.live.load(.monotonic) >= self.max) {
            _ = self.refused.fetchAdd(1, .monotonic);
            return false;
        }
        _ = self.live.fetchAdd(1, .monotonic);
        return true;
    }

    /// A connection has closed. Called from the fiber that held it.
    pub fn give(self: *Capacity) void {
        _ = self.live.fetchSub(1, .monotonic);
    }

    pub fn held(self: *const Capacity) u32 {
        return self.live.load(.monotonic);
    }
};

/// The shortest gap between two "the server is full" warnings.
///
/// A server that is full is full for a while, and one line per refused
/// connection would be a log that fills a disk at exactly the moment
/// somebody needs to read it. Once a minute, with a running total, says
/// the same thing.
const capacity_warn_gap_ns: u64 = 60 * std.time.ns_per_s;

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

/// The time limits of one connection, as the Engine can act on them.
///
/// zio keeps a timeout on the reader and on the writer and applies it to
/// every operation, so putting a limit on the next read is a field store
/// rather than a timer, a watchdog fiber, or anything else with a cost.
/// The names are plain on purpose: the Bulkhead is what turns zfast's
/// policy into calls on these, and this file is not allowed to know what
/// that policy is (ADR 0002).
pub const Clocks = struct {
    reader: *zio.net.Stream.Reader,
    writer: *zio.net.Stream.Writer,

    pub fn readNoLimit(self: *Clocks) void {
        self.reader.setTimeout(.none);
    }

    pub fn readWithinMs(self: *Clocks, ms: u32) void {
        self.reader.setTimeout(.fromMilliseconds(ms));
    }

    /// A limit shared by every read until it is changed, given as a reading
    /// of the same monotonic clock `monotonicNanos` returns.
    pub fn readByNanos(self: *Clocks, ns: u64) void {
        self.reader.setTimeout(.{ .deadline = .fromNanoseconds(ns) });
    }

    pub fn writeNoLimit(self: *Clocks) void {
        self.writer.setTimeout(.none);
    }

    pub fn writeWithinMs(self: *Clocks, ms: u32) void {
        self.writer.setTimeout(.fromMilliseconds(ms));
    }

    pub fn writeByNanos(self: *Clocks, ns: u64) void {
        self.writer.setTimeout(.{ .deadline = .fromNanoseconds(ns) });
    }

    /// Whether a read or write ran out of time, as opposed to the
    /// connection having broken.
    ///
    /// Both reach the HTTP layer as `error.ReadFailed`/`error.WriteFailed`,
    /// because that is all a `std.Io` interface can say; the reason is kept
    /// on the side, here. zio does not clear it, so this only means
    /// anything asked directly after the operation that failed — which is
    /// the only place zfast asks, and then the connection is closed.
    pub fn timedOut(self: *const Clocks) bool {
        if (self.reader.err) |err| if (err == error.Timeout) return true;
        if (self.writer.err) |err| if (err == error.Timeout) return true;
        return false;
    }
};

/// Run `handler(state, in, out, clocks, peer)` for every accepted
/// connection, each in its own fiber, until that connection is done. The
/// Reader/Writer are already buffered; the handler does not need to know
/// there is a socket behind them. `handler` must be
/// `fn (@TypeOf(state), *std.Io.Reader, *std.Io.Writer, *Clocks, Peer) void`.
///
/// Returns when `stop` is set — by a signal, or by somebody calling
/// `App.shutdown()` — once the connections still being served have
/// finished or the grace period has run out.
pub fn serve(
    gpa: std.mem.Allocator,
    options: anytype,
    stop: *Stop,
    state: anytype,
    comptime handler: anytype,
) !void {
    const State = @TypeOf(state);
    const Options = @TypeOf(options);
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

    // A buffer that starts on a page boundary and ends on one, so every page
    // of it belongs to this connection alone and can be given back.
    const alignedPages = struct {
        fn f(buf_gpa: std.mem.Allocator, want: usize) ![]align(std.heap.page_size_min) u8 {
            const page = std.heap.pageSize();
            const rounded = std.mem.alignForward(usize, @max(want, 1), page);
            return buf_gpa.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), rounded);
        }
    }.f;

    const Conn = struct {
        fn run(
            st: State,
            stream: zio.net.Stream,
            conn_gpa: std.mem.Allocator,
            sizes: Options,
            capacity: *Capacity,
        ) void {
            // After the close, not before: the count is meant to answer
            // "how many sockets does this process hold", and the socket is
            // held until it is shut. Deferred first so it runs last.
            defer capacity.give();
            defer stream.close();

            // One response = one flush = one segment; Nagle would only add
            // latency without saving anything, so it is turned off.
            stream.socket.setNoDelay(true) catch {};

            // Allocated rather than put on the fiber stack, so the sizes can
            // be an option instead of a constant. Twice per connection, not
            // per request — next to a connection's lifetime it is nothing.
            //
            // Page-aligned, and rounded up to whole pages, so that
            // `bulkhead.releaseIdlePages` can hand every page back while the
            // connection sits idle. Unaligned, the first and last page of each
            // buffer might be shared with another allocation and would have to
            // be left alone — on an 8 KB buffer that is most of the saving. The
            // rounding costs at most a page per buffer of address space, and
            // the page it rounds up to is never touched.
            const read_buf = alignedPages(conn_gpa, sizes.read_buffer) catch return;
            defer conn_gpa.free(read_buf);
            const write_buf = alignedPages(conn_gpa, sizes.write_buffer) catch return;
            defer conn_gpa.free(write_buf);

            var reader = stream.reader(read_buf);
            var writer = stream.writer(write_buf);
            var clocks = Clocks{ .reader = &reader, .writer = &writer };

            // `accept` already returned who this is, so this costs no
            // syscall — only the formatting, once per connection.
            var peer: Peer = .{ .port = portOf(stream.socket.address) };
            peer._len = writePeer(&peer._text, stream.socket.address);

            handler(st, &reader.interface, &writer.interface, &clocks, peer);
        }
    };

    var group: zio.Group = .init;
    // Whatever is still running when the grace period is over is cut off
    // here. By then it has had its chance.
    defer group.cancel();

    // Registered after the cancel above, so it runs before it: nothing can
    // be spawned into a group that is already winding up (ADR 0029).
    background.store(&group, .release);
    defer background.store(null, .release);

    if (options.stop_on_signal) installStopSignals(stop);
    defer if (options.stop_on_signal) restoreStopSignals();

    var capacity: Capacity = .{ .max = options.max_connections };
    var warned_at_ns: u64 = 0;

    while (!stop.isRequested()) {
        const stream = server.accept(.{ .timeout = .fromMilliseconds(accept_poll_ms) }) catch |err| {
            // The wait ran out, which is the loop's chance to look at the
            // stop flag rather than anything having gone wrong.
            if (err == error.Timeout) continue;
            return err;
        };

        // Full: closed at once, without being read from and without being
        // answered. Closing rather than not accepting, so that the client
        // finds out now — a connection left in the kernel's backlog hangs
        // until something times out, and the load balancer that ADR 0028
        // says is in front cannot fail over to another instance until it
        // does. Closing rather than answering 503, because writing to a
        // client the server has just decided it cannot afford to serve is
        // work an attacker gets to choose, and it would put a write with a
        // deadline on it inside the one loop that must not stall.
        if (!capacity.take()) {
            stream.close();
            const now = monotonicNanos();
            if (warned_at_ns == 0 or now - warned_at_ns >= capacity_warn_gap_ns) {
                warned_at_ns = now;
                std.log.warn(
                    "zfast is holding its limit of {d} connections, so new ones are being closed " ++
                        "unanswered ({d} so far). Raise `.max_connections` in listen() if the " ++
                        "machine has the memory — each connection costs about 9 KB — or put " ++
                        "fewer of them on this process.",
                    .{ capacity.max, capacity.refused.load(.monotonic) },
                );
            }
            continue;
        }

        group.spawn(Conn.run, .{ state, stream, gpa, options, &capacity }) catch |err| {
            capacity.give();
            stream.close();
            return err;
        };
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

/// Fill `buffer` with bytes from the operating system's entropy source.
///
/// Through the Engine rather than out of `std`, for the same reason the clock
/// is (ADR 0002): getting randomness is a syscall, and a syscall made
/// directly from a fiber stops every request sharing its thread. zio hands it
/// to the blocking pool, and outside a running server it simply calls
/// `getrandom` inline — so a handler that seals a session is still testable
/// as an ordinary function.
///
/// `error.Canceled` if the request went away mid-call, which is the same
/// answer `sleep` and `Mutex.lock` give.
pub fn randomSecure(buffer: []u8) !void {
    return zio.randomSecure(buffer);
}

/// A lock that parks the fiber rather than the OS thread under it. Also
/// works from a plain thread with no fiber at all, which is what makes a
/// handler holding one still testable as an ordinary function (ADR 0003).
pub const Mutex = zio.Mutex;

/// Run a blocking call on the Engine's thread pool, parking this fiber
/// until it comes back, so the other fibers sharing this thread keep
/// running (ADR 0014).
///
/// Allocates nothing — the arguments and the result live on the calling
/// fiber's stack. Outside a fiber the call simply runs inline, which is
/// what keeps a handler that uses it testable as an ordinary function.
pub const blocking = zio.blockInPlace;

/// Wait, without stopping the thread. `error.Canceled` if the request was
/// cancelled while waiting — the same failure `Mutex.lock` has, and it maps
/// to a 503 already.
///
/// Outside a fiber this really does sleep, rather than returning at once,
/// so a test measuring a timeout still measures one.
pub fn sleep(ms: u64) error{Canceled}!void {
    return zio.sleep(.fromMilliseconds(ms));
}

// ---- work that is not a request (see ADR 0029) ----
//
// The group `serve` already runs its connections in, reached from outside
// it. A spawned fiber is therefore counted while it runs and cut off when
// the grace period ends, exactly like a connection — the alternative,
// `zio.spawn`, is detached, and a fiber the shutdown path cannot see is a
// shutdown message that lies.
//
// A pointer rather than a parameter because `spawn` is called from user
// code that holds no server: the same reason the stop signals are
// installed process-wide. Cleared before `serve` cancels the group, so
// nothing can be spawned into a group already winding up.
//
// Atomic because it is written by the thread that called `serve` and read
// by fibers on every executor. It is only ever written twice, both times
// with no connection in flight, so the ordering is not load-bearing — but
// a plain global read across threads is not something to leave to luck.
//
// One server per process, therefore. A second `serve` would take the
// pointer from the first, and its `spawn`ed work would be counted by the
// wrong shutdown. Nothing in zfast does that today and `listen` is the
// only caller; if that changes, this is the line that has to move into
// the state `serve` already carries.
var background: std.atomic.Value(?*zio.Group) = .init(null);

/// Start `func` in a fiber of its own, owned by the running server.
///
/// `error.NoServer` if there is no server running, which is what a unit
/// test calling a handler directly gets — the caller decides whether that
/// is a failure or a no-op.
pub fn spawn(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
    const group = background.load(.acquire) orelse return error.NoServer;
    return group.spawn(func, args);
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

const testing = std.testing;

fn ip6Text(buf: *[Peer.max_text]u8, groups: [8]u16) []const u8 {
    var bytes: [16]u8 = undefined;
    for (groups, 0..) |g, i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], g, .big);
    var w: std.Io.Writer = .fixed(buf);
    writeIp6(&w, bytes);
    return buf[0..w.end];
}

test "an IPv6 address is written the way RFC 5952 says to write it" {
    var buf: [Peer.max_text]u8 = undefined;

    // The longest run of zero groups becomes `::`, once.
    try testing.expectEqualStrings(
        "2001:db8::1",
        ip6Text(&buf, .{ 0x2001, 0x0db8, 0, 0, 0, 0, 0, 1 }),
    );
    // A run at the front, and a run at the back.
    try testing.expectEqualStrings("::1", ip6Text(&buf, .{ 0, 0, 0, 0, 0, 0, 0, 1 }));
    try testing.expectEqualStrings("2001::", ip6Text(&buf, .{ 0x2001, 0, 0, 0, 0, 0, 0, 0 }));
    try testing.expectEqualStrings("::", ip6Text(&buf, .{ 0, 0, 0, 0, 0, 0, 0, 0 }));

    // Nothing to shorten.
    try testing.expectEqualStrings(
        "2001:db8:1:2:3:4:5:6",
        ip6Text(&buf, .{ 0x2001, 0x0db8, 1, 2, 3, 4, 5, 6 }),
    );

    // A single zero group is written out. `::` has to save more than one
    // group to be worth the ambiguity, and RFC 5952 says so.
    try testing.expectEqualStrings(
        "2001:0:1:2:3:4:5:6",
        ip6Text(&buf, .{ 0x2001, 0, 1, 2, 3, 4, 5, 6 }),
    );

    // Two runs, different lengths: the longer one is the one that goes,
    // and the shorter is written out in full (RFC 5952 §4.2.3).
    try testing.expectEqualStrings(
        "2001:0:0:1::2",
        ip6Text(&buf, .{ 0x2001, 0, 0, 1, 0, 0, 0, 2 }),
    );

    // Two runs of the same length: the first one wins, so that two
    // machines never write the same address two ways.
    try testing.expectEqualStrings(
        "2001::1:0:0:5:6",
        ip6Text(&buf, .{ 0x2001, 0, 0, 1, 0, 0, 5, 6 }),
    );
}

test "a full server refuses, and takes the next connection once one closes" {
    var capacity: Capacity = .{ .max = 3 };

    try testing.expect(capacity.take());
    try testing.expect(capacity.take());
    try testing.expect(capacity.take());
    try testing.expectEqual(@as(u32, 3), capacity.held());

    // Full. Nothing is held by the refusal, so the count does not move.
    try testing.expect(!capacity.take());
    try testing.expect(!capacity.take());
    try testing.expectEqual(@as(u32, 3), capacity.held());
    try testing.expectEqual(@as(u64, 2), capacity.refused.load(.monotonic));

    // One closes, and the next client gets in. A cap that stayed full
    // after a connection ended would be a server that answers once.
    capacity.give();
    try testing.expect(capacity.take());
    try testing.expect(!capacity.take());
    try testing.expectEqual(@as(u32, 3), capacity.held());
}

test "no cap is a server that takes whatever arrives" {
    // What zfast did before `max_connections` existed, and what setting it
    // to zero asks for back.
    var capacity: Capacity = .{ .max = 0 };
    for (0..1000) |_| try testing.expect(capacity.take());
    try testing.expectEqual(@as(u32, 1000), capacity.held());
    try testing.expectEqual(@as(u64, 0), capacity.refused.load(.monotonic));
}

test "the count follows connections closing on other threads" {
    // `give` is the one that really is called from everywhere: every
    // connection fiber calls it as it goes, and they are spread across
    // every thread the server runs.
    var capacity: Capacity = .{ .max = 256 };
    for (0..256) |_| try testing.expect(capacity.take());
    try testing.expect(!capacity.take());

    const Closer = struct {
        fn run(c: *Capacity, n: usize) void {
            for (0..n) |_| c.give();
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Closer.run, .{ &capacity, 64 });
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u32, 0), capacity.held());
}

test "a Peer given as text keeps it, and refuses what cannot be an address" {
    const peer = try Peer.from("203.0.113.9");
    try testing.expectEqualStrings("203.0.113.9", peer.address());

    // No socket at all, which is what a handler called from a test gets.
    const nowhere: Peer = .{};
    try testing.expectEqualStrings("", nowhere.address());

    const too_long = "a" ** (Peer.max_text + 1);
    try testing.expectError(error.AddressTooLong, Peer.from(too_long));
}
