//! An Engine built on zio (https://github.com/lalinsky/zio).
//!
//! The only file in nilo allowed to name zio. See ADR 001.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
// The TLS 1.3 server behind `-Dtls` (ADR 212), and the second library
// this file is allowed to name. `nilo_build.tls` is the flag as `build.zig`
// saw it; the import is taken only when it is on, so a build without the
// flag has no module named `tls` to resolve and links none of the library.
// Every use below sits under the same comptime `if`.
const nilo_build = @import("nilo_build");
const tls = if (nilo_build.tls) @import("tls") else struct {};

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
    /// This connection came in over a unix socket, so it has no address at
    /// all and nothing remote could have opened it.
    ///
    /// Both halves matter to `Ctx.clientIp`. There is no address to return,
    /// and the machine on the other end is this one — which is what the
    /// named-network rules are trying to establish about a proxy over
    /// loopback, and can establish here without a rule at all (ADR 103).
    local: bool = false,
    /// This connection's TLS is terminated here, by the listener's own
    /// certificate, so the client used `https` whatever any header says.
    tls: bool = false,
    /// Which listener this connection arrived on: 0 for the one `address`
    /// and `port` name, `n` for `also[n - 1]` (ADR 252). One byte on the
    /// fiber's stack and set once at accept from the acceptor's own
    /// listener, so it costs no allocation and no field on `Ctx`.
    listener: u8 = 0,

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

    /// The Peer a connection over a unix socket gets: no address, and known
    /// to be this machine.
    pub fn overUnixSocket() Peer {
        return .{ .local = true };
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
// writes inside `listen()` and ADR 001 says the Engine is not the user's
// business. They arrive here as `anytype` so that this file names only the
// fields it actually reads:
//
//   address  port  reuse_address  backlog  threads  read_buffer  write_buffer
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
/// Every connection costs a measured 4,669 bytes before it has asked for
/// anything, so a cap is the one option that turns that figure into a
/// number an operator can multiply.
///
/// `take` is called from every acceptor at once — there is one per
/// executor ([ADR 200](../../docs/adr/200-every-executor-accepts.md)) —
/// so the load and the increment are one compare-and-swap rather than two
/// operations that could interleave and let two acceptors past the cap on
/// the same free slot. `give` is called from every connection fiber.
/// Nothing is published through either — it is a count, not a handoff —
/// so `.monotonic` is the whole ordering requirement.
pub const Capacity = struct {
    live: std.atomic.Value(u32) = .init(0),
    /// 0 means no limit, which is what nilo did before this existed.
    max: u32 = 0,
    /// Connections closed because the server was full, since it started.
    /// Read only for the log line.
    refused: std.atomic.Value(u64) = .init(0),
    /// When the "server is full" warning last went out, so that N acceptors
    /// refusing at once write it once between them. 0 is never.
    warned_at_ns: std.atomic.Value(u64) = .init(0),

    /// Count one more connection, or say there is no room for it.
    pub fn take(self: *Capacity) bool {
        var live = self.live.load(.monotonic);
        while (true) {
            if (self.max != 0 and live >= self.max) {
                _ = self.refused.fetchAdd(1, .monotonic);
                return false;
            }
            live = self.live.cmpxchgWeak(live, live + 1, .monotonic, .monotonic) orelse return true;
        }
    }

    /// A connection has closed. Called from the fiber that held it.
    pub fn give(self: *Capacity) void {
        _ = self.live.fetchSub(1, .monotonic);
    }

    pub fn held(self: *const Capacity) u32 {
        return self.live.load(.monotonic);
    }

    /// Whether the acceptor that asks is the one to write the "full" warning:
    /// true once per `capacity_warn_gap_ns`, whoever asks. The claim is a
    /// compare-and-swap on the timestamp, so two acceptors refusing in the
    /// same microsecond cannot both win it.
    pub fn claimWarning(self: *Capacity, now_ns: u64) bool {
        const last = self.warned_at_ns.load(.monotonic);
        if (last != 0 and now_ns - last < capacity_warn_gap_ns) return false;
        return self.warned_at_ns.cmpxchgStrong(last, now_ns, .monotonic, .monotonic) == null;
    }
};

/// The shortest gap between two "the server is full" warnings.
///
/// A server that is full is full for a while, and one line per refused
/// connection would be a log that fills a disk at exactly the moment
/// somebody needs to read it. Once a minute, with a running total, says
/// the same thing.
const capacity_warn_gap_ns: u64 = 60 * std.time.ns_per_s;

/// What every connection of a TLS listener shares (ADR 212): the
/// certificate chain and key each handshake presents, read from disk once
/// at startup, and the loop's clock for the handshake's `now`.
///
/// Reached through `Accepting` rather than passed to the connection fiber
/// as arguments of its own, and that is a measured choice rather than
/// tidiness: two more arguments kept live across the handler grew a
/// *plain* connection's park frame past a page boundary, and that was a
/// whole page on every idle connection of a listener with no TLS on it
/// (see `Conn.runTls`). `void` without `-Dtls`, when nothing can build one.
const Secured = struct {
    auth: if (nilo_build.tls) tls.config.CertKeyPair else void,
    io: std.Io,
};

/// What every acceptor of every listener shares, on `serve`'s frame: the
/// count of connections held, whether the descriptor shortage has been
/// said, and the first listener failure, kept for `serve` to return once
/// the others are cancelled (ADR 200).
///
/// Separate from `Accepting` below because these three are the *server's*
/// and the TLS material beside them is one *listener's* (ADR 213).
/// `max_connections` counts the sockets this process holds rather than the
/// sockets a port holds, because what it protects is one descriptor table;
/// a shortage is one machine's and is said once, not once a port; and a
/// listener that fails takes the server down whichever one it was.
const Serving = struct {
    capacity: Capacity,
    /// Whether "out of descriptors" has been said and not yet taken back, so
    /// that N acceptors hitting the same shortage write one line and one
    /// "works again" between them.
    short: std.atomic.Value(bool) = .init(false),
    /// The first listener failure as `@intFromError`, or 0 for none.
    failure: std.atomic.Value(ErrorInt) = .init(0),

    const ErrorInt = std.meta.Int(.unsigned, @bitSizeOf(anyerror));

    /// Keep the first failure; a second acceptor failing after it changes
    /// nothing about what `serve` should say.
    fn fail(self: *Serving, err: anyerror) void {
        _ = self.failure.cmpxchgStrong(0, @intFromError(err), .acq_rel, .monotonic);
    }

    fn failed(self: *const Serving) bool {
        return self.failure.load(.acquire) != 0;
    }

    fn takeFailure(self: *const Serving) ?anyerror {
        const code = self.failure.load(.acquire);
        return if (code == 0) null else @errorFromInt(code);
    }
};

/// What one listener's acceptors share: the server they all belong to, and
/// the TLS material if this listener is a TLS one.
///
/// **Two fields and not four, which is the frame again.** A connection
/// fiber is handed one of these and keeps it live across the handler
/// (`Conn.run`), so what it costs is measured rather than assumed: the
/// server's three parts are reached through one pointer instead of being
/// copied in beside the certificate. An idle connection is what it was
/// before this type existed, to the byte (ADR 213, ADR 212).
const Accepting = struct {
    /// The server every listener of this process belongs to.
    all: *Serving,
    /// Set on a TLS listener and null on a plain one, which is the whole
    /// of how the acceptor tells them apart.
    secured: ?*Secured = null,
    /// This listener's place in the list `listen()` was given: 0 for the
    /// first, then each `also` entry in order (ADR 252). Copied into each
    /// connection's `Peer`, which is how a request learns it.
    index: u8 = 0,
    /// The `Options` `serve` was given, a heap copy it keeps for as long as
    /// any connection does. Type-erased because this struct is not generic over
    /// the Bulkhead's `Options`, and read back by the two entries, which are:
    /// a connection reads its sizes through here rather than being handed a copy,
    /// because the copy was 264 bytes of the task zio allocates for it, which put
    /// the task in the next size class of the allocator and made every idle
    /// connection 512 bytes dearer (ADR 062).
    sizes: *const anyopaque,

    fn fail(self: *Accepting, err: anyerror) void {
        self.all.fail(err);
    }
};

/// How often `serve` looks up to see whether a stop was asked for.
///
/// Polling rather than waking the loop directly: a signal handler may not
/// touch a wait queue. One timer per server, five times a second, is not a
/// cost worth avoiding — and a fifth of a second is below what anybody
/// notices after pressing Ctrl-C.
///
/// Until ADR 200 this was the timeout on every `accept`, so that the one
/// accept loop could look at the flag between connections. Now that there
/// is an acceptor per executor they wait with no timeout and are cancelled
/// when the flag is seen, and the poll is the main fiber's alone: it costs
/// one timer per server rather than a timer per connection accepted.
const accept_poll_ms = 200;

/// How long an acceptor waits after failing for want of a file descriptor
/// or memory, doubling up to the cap. Short enough that a brief shortage
/// costs a little latency, capped so a sustained one settles into one
/// attempt a second rather than a spin (ADR 194).
const accept_backoff_min_ms: u32 = 5;
const accept_backoff_max_ms: u32 = 1000;
/// How many accepts in a row may fail with an error `accept(2)` says is the
/// connection's before it is taken for the listener's. Enough that a burst
/// of clients failing at once is waited out, few enough that a listener
/// which is broken for good stops the server inside a tenth of a second.
const accept_strikes_max: u32 = 16;

/// How often a stop looks to see whether the last request has finished.
/// Shorter than the accept poll: by the time this runs somebody is waiting
/// for the process to go, and an ordinary request finishes in less time
/// than one of these.
const drain_poll_ms = 20;

/// Whether `serve` already said, in words, why the server did not start.
///
/// `App.listen()` stops the process on these instead of returning them: the
/// message is the whole answer, and letting the error travel up to `main`
/// would print a stack trace through nilo on top of it (ADR 001 — the
/// Engine is not the user's business, in a crash log least of all).
pub fn explained(err: anyerror) bool {
    return switch (err) {
        error.BadAddress,
        error.AddressInUse,
        error.PermissionDenied,
        error.AddressNotAvailable,
        error.CannotListen,
        error.TlsNotBuilt,
        error.TlsOnUnixSocket,
        error.TlsCertificate,
        => true,
        else => false,
    };
}

// ---- stopping on a signal ----
//
// A signal handler may do almost nothing safely, so it does almost nothing:
// one atomic swap and one store into the `Stop` below. The accept loop is what notices.

var signal_target: std.atomic.Value(?*Stop) = .init(null);

/// The signal number as this platform's `Sigaction` hands it over — an enum
/// on Linux, a plain integer elsewhere. Read off `Sigaction` rather than
/// spelled out, so it stays right wherever this is built.
const SigNum = @typeInfo(@typeInfo(@typeInfo(
    @FieldType(@FieldType(std.posix.Sigaction, "handler"), "handler"),
).optional.child).pointer.child).@"fn".params[0].type.?;

/// Whether this signal is the first, which asks for a graceful stop, or a
/// later one, which gives up on it.
const StopSignal = enum { graceful, exit_now };

///
/// "Seen" is a flag of the handler's own and not `stop.isRequested()`, which
/// `App.shutdown()` sets too: a SIGTERM arriving after a programmatic shutdown
/// is the first the operator sent, and reading the shared flag made it look
/// like the second and exit at once, with the grace period unspent and the
/// connections in flight cut off. One atomic swap, so two signals racing
/// cannot both be the first.
fn stopSignalSeen(stop: *Stop, seen: *std.atomic.Value(bool)) StopSignal {
    if (seen.swap(true, .acq_rel)) return .exit_now;
    stop.request();
    return .graceful;
}

/// Set by the first stop signal, cleared when the handlers are installed and
/// again when they are put back.
var signal_seen: std.atomic.Value(bool) = .init(false);

/// Leave the process now. The handler runs in a signal, where `exit` is not
/// safe: it runs `atexit` handlers and flushes stdio, and either can be in
/// the middle of running on the interrupted thread. `_exit` only ends the
/// process (`exit_group` where there is no libc).
fn exitNow(status: u8) noreturn {
    if (builtin.link_libc) std.c._exit(status);
    if (builtin.os.tag == .linux) std.os.linux.exit_group(status);
    std.process.exit(status);
}

fn onStopSignal(_: SigNum) callconv(.c) void {
    const stop = signal_target.load(.acquire) orelse return;
    // A second Ctrl-C means the person has stopped waiting for the graceful
    // part. 130 is the shell's convention for "killed by SIGINT".
    if (stopSignalSeen(stop, &signal_seen) == .exit_now) exitNow(130);
}

/// What was handling these before, so the previous arrangement is put back
/// when `serve` returns. A library that leaves its own handlers installed
/// after it is done has changed the program behind its back.
var previous_int: std.posix.Sigaction = undefined;
var previous_term: std.posix.Sigaction = undefined;

fn installStopSignals(stop: *Stop) void {
    if (builtin.os.tag == .windows) return;
    signal_seen.store(false, .release);
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
    signal_seen.store(false, .release);
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
/// The names are plain on purpose: the Bulkhead is what turns nilo's
/// policy into calls on these, and this file is not allowed to know what
/// that policy is (ADR 001).
pub const Clocks = struct {
    reader: *zio.net.Stream.Reader,
    writer: *zio.net.Stream.Writer,

    // Every arming forgets the side's last error. zio never clears it, so
    // without this a connection whose idle peek once ran out read as timed
    // out for the rest of its life, and a stop that cancelled its next wait
    // was taken for one more quiet spell and waited out (`timedOut` below).

    pub fn readNoLimit(self: *Clocks) void {
        self.reader.err = null;
        self.reader.setTimeout(.none);
    }

    pub fn readWithinMs(self: *Clocks, ms: u32) void {
        self.reader.err = null;
        self.reader.setTimeout(.fromMilliseconds(ms));
    }

    /// A limit shared by every read until it is changed, given as a reading
    /// of the same monotonic clock `monotonicNanos` returns.
    pub fn readByNanos(self: *Clocks, ns: u64) void {
        self.reader.err = null;
        self.reader.setTimeout(.{ .deadline = .fromNanoseconds(ns) });
    }

    pub fn writeNoLimit(self: *Clocks) void {
        self.writer.err = null;
        self.writer.setTimeout(.none);
    }

    pub fn writeWithinMs(self: *Clocks, ms: u32) void {
        self.writer.err = null;
        self.writer.setTimeout(.fromMilliseconds(ms));
    }

    pub fn writeByNanos(self: *Clocks, ns: u64) void {
        self.writer.err = null;
        self.writer.setTimeout(.{ .deadline = .fromNanoseconds(ns) });
    }

    /// Whether a read or write ran out of time, as opposed to the
    /// connection having broken.
    ///
    /// Both reach the HTTP layer as `error.ReadFailed`/`error.WriteFailed`,
    /// because that is all a `std.Io` interface can say; the reason is kept
    /// on the side, here. zio does not clear it, and the arming above does,
    /// so this answers for the operations since the last limit was set.
    pub fn timedOut(self: *const Clocks) bool {
        if (self.reader.err) |err| if (err == error.Timeout) return true;
        if (self.writer.err) |err| if (err == error.Timeout) return true;
        return false;
    }
};

/// Bounding an operation that is **not** a read or a write on a connection
/// nilo holds — an outbound call by a Service, where the socket belongs to a
/// driver and there is nothing here to set a timeout on
/// (ADR 062).
///
/// `Clocks` above is the inbound half and works by setting a timeout on the
/// stream. This half cannot: it cancels the *fiber* instead, which is what
/// reaches through `std.Io.net` and `std.http.Client` alike, because every
/// operation in both carries `Io.Cancelable`.
///
/// The three functions take the state as bytes because the type that holds it
/// lives in `nilo_core`, which may not name an Engine. `bulkhead.zig` checks
/// at `comptime` that `core.Limits`'s slot is big enough for what is written
/// here, so the `@ptrCast` below is checked rather than hoped.
pub const limit_state_size = @sizeOf(zio.AutoCancel);
pub const limit_state_align = @alignOf(zio.AutoCancel);

/// Give the operation running on this fiber `ms` to finish.
///
/// The state is initialised here rather than by the caller because only this
/// file knows what it is. It is address sensitive from this call until
/// `releaseOperation` — zio's `AutoCancel` hands `&self.timer` to the event
/// loop and stores `&self` as its userdata — which is why the whole `Bound`
/// API takes a pointer.
pub fn armOperation(state: *anyopaque, ms: u32) void {
    const cancel: *zio.AutoCancel = @ptrCast(@alignCast(state));
    cancel.* = .init;
    cancel.set(.{ .duration = .fromMilliseconds(ms) });
}

/// Take the deadline off. If the timer already fired, this parks until the
/// callback has finished with the state rather than returning while something
/// still points at it.
pub fn releaseOperation(state: *anyopaque) void {
    const cancel: *zio.AutoCancel = @ptrCast(@alignCast(state));
    cancel.clear();
}

/// Whether this deadline is what cancelled the fiber, as opposed to a
/// shutdown or somebody else's cancel. Consumes the answer, so it is asked
/// once, and only after an operation came back `error.Canceled`.
pub fn firedOperation(state: *anyopaque) bool {
    const cancel: *zio.AutoCancel = @ptrCast(@alignCast(state));
    return cancel.check(error.Canceled);
}

/// What ended a `Wake.wait`.
pub const Woken = enum {
    /// The socket has something to read.
    readable,
    /// Somebody else has something to say to this connection.
    posted,
    /// Nothing happened for as long as the caller was willing to wait. What a
    /// heartbeat is built on: silence is not an error, it is a question worth
    /// asking the other end.
    timed_out,
    /// The connection is going away — cancelled at shutdown, or the queue
    /// emptied under us. Either way the caller stops.
    closed,
};

/// A connection's second way to be woken: not by the client at the other end
/// of its socket, but by another fiber with something to say to it.
///
/// Everything else in nilo is woken by the client. That is what makes the
/// per-connection numbers in ADR 017 as small as they are, and it is exactly
/// what a broadcast cannot live with — a connection sitting in a read cannot
/// be told anything until whoever is on the other end happens to speak.
///
/// ADR 028 measured the alternative and rejected it: a second fiber per
/// connection to do the writing, 8,673 bytes each, against a whole-connection
/// budget that was 8,767 at the time and is 4,669 since ADR 062 — so the
/// alternative reads worse now than it did then, not better. It named this
/// shape as the right one and recorded it as
/// unreachable, because zio exported no way to park on a completion. It does
/// — `zio.CompletionQueue` has been public since v0.17.0 — and
/// `spike/completion_queue/` holds the cancel path and the re-arm to 630 runs
/// across three optimize modes, and the plain re-arm to 180 more under
/// v0.18.0.
///
/// **The struct lives in the connection's own fiber frame**, not in an
/// allocation of its own. `spike/mailbox/` measured why: given its own
/// allocation the cost is not the struct but the next power of two above it
/// — 320 bytes measured as 512, every row exact. Here it is 320 bytes of a
/// stack that is already mapped.
///
/// `post` is the only call another fiber makes, and `zio.ev.Async.notify` is
/// documented thread-safe. Everything else is the owning fiber's.
pub const Wake = struct {
    /// The ciphertext layer under a TLS connection, and null on a plain one.
    /// Here because `Wake` is the one thing of a connection's the Bulkhead
    /// holds a pointer to while the connection idles, and idling is when
    /// these pages are given back (ADR 212).
    raw: ?*const RawLayer = null,

    cq: zio.CompletionQueue,
    wake: zio.ev.Async,
    poll: zio.ev.NetPoll,
    /// The socket, for `halfClose`. The same handle `poll` was built on.
    handle: zio.ev.Backend.NetHandle,
    /// The post half. Submitted once and re-submitted the moment it fires,
    /// because a notify carries no data that anybody has to read first.
    armed: bool = false,
    /// The readable half, which is **not** re-submitted on the way out — see
    /// `wait`. Separate from `armed` because the two halves are re-armed at
    /// different moments, and a completion that is still pending must not be
    /// handed to `submit` a second time: the queue would link it twice.
    poll_armed: bool = false,
    /// A `wait` or `lookNow` was answered from bytes the record layer already
    /// held, so the readable poll may since have fired for bytes that were
    /// read in the meantime. Looked at once, by `believe`.
    skipped: bool = false,

    /// What sits between a TLS connection's socket and the buffers the
    /// handler reads: the records arrive in `in` and leave from `out`, and
    /// `leftover` is cleartext the last record decrypted that nobody has
    /// asked for yet. That last one can point *into* `in` (the library
    /// decrypts in place when the caller's buffer is smaller than the
    /// record), which is why it is carried here: while it is non-empty the
    /// input pages are live data, whatever the reader's own cursor says.
    pub const RawLayer = struct {
        in: *std.Io.Reader,
        out: *std.Io.Writer,
        leftover: *const []const u8,
    };

    /// The raw layer, if there is one and it is safe to hand its pages back:
    /// null on a plain connection, and null while decrypted bytes are still
    /// waiting in it. Whether the reader and writer themselves are empty is
    /// the Bulkhead's check, the same one it makes on the cleartext pair.
    pub fn rawIdle(self: *const Wake) ?*const RawLayer {
        const raw = self.raw orelse return null;
        if (raw.leftover.len != 0) return null;
        return raw;
    }

    /// Bytes this connection already holds that no poll of the socket will
    /// ever announce: a whole record of ciphertext the record layer read off the socket along
    /// with the record it decrypted (tls.zig pulls whatever is there, and
    /// decrypts one record a call), or cleartext a record decrypted that the
    /// reader has not taken yet. The caller checks its own cleartext buffer
    /// before it waits, which does not see either; a plain connection has
    /// neither. Without this a second frame sent a moment behind the first
    /// waits on a socket the kernel has already emptied, until the client
    /// sends again or a limit runs out: one HTTP/2 connection in a thousand
    /// over TLS, found by `bench/mem.py --tls --h2` in stage 7 of framing
    /// (ADR 259), and the question a WebSocket over TLS had open.
    fn held(self: *const Wake) bool {
        // Only a TLS connection has a layer under its buffers, and only a
        // build with TLS in it has the code to make one.
        if (comptime !nilo_build.tls) return false;
        const raw = self.raw orelse return false;
        if (raw.leftover.len != 0) return true;
        // A whole record, and only a whole one: tls.zig peeks the five-byte
        // header and takes the payload, so a header or half a payload would
        // send the caller into a read that blocks on the socket until the
        // rest arrives, deaf to every post meanwhile. A partial record falls
        // through to the poll, which fires when the rest does (the socket is
        // drained). A whole record that is not application data (a ticket, a
        // KeyUpdate) cannot be told from one: every record after the
        // handshake is type 23 on the wire, and only decrypting says more.
        const buffered = raw.in.buffered();
        if (buffered.len < 5) return false;
        return buffered.len >= 5 + std.mem.readInt(u16, buffered[3..5], .big);
    }

    /// Whether a fired poll still means something. After an answer from
    /// `held`, the poll that was armed stays armed, and may fire for bytes
    /// the reads that followed have already taken, which would send the caller
    /// into a read that nothing can end. Asked once, and only then, of the
    /// kernel: a socket with nothing in it is a poll to arm again.
    fn believe(self: *Wake) bool {
        if (comptime !nilo_build.tls) return true;
        if (!self.skipped) return true;
        self.skipped = false;
        var fds = [1]std.posix.pollfd{.{ .fd = self.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 0) catch return true;
        return ready != 0;
    }

    pub fn init(handle: zio.ev.Backend.NetHandle) Wake {
        return .{
            .cq = zio.CompletionQueue.init(),
            .wake = zio.ev.Async.init(),
            .handle = handle,
            // `NetPoll` rather than `NetRecv`, which is the exception zio's
            // author named when he said to prefer the latter: the connection's
            // buffered `std.Io.Reader` does its own reading, so what is wanted
            // here is readiness, not bytes. Level-triggered, so data left
            // unread simply fires again — which is correct, because the caller
            // reads on every `.readable`.
            .poll = zio.ev.NetPoll.init(handle, .recv),
        };
    }

    /// Tell the peer there is nothing more coming, without closing: a FIN on
    /// the send side. What it is for is a refused request whose bytes are
    /// still queued unread on this socket — closing with those unread makes
    /// the kernel send a reset instead, and a peer that gets a reset throws
    /// away the answer it had buffered and reports "connection reset" where
    /// the 431 should have been (ADR 195). The socket is still closed by
    /// `Conn.run` afterwards; this only orders the FIN before it.
    ///
    /// Every failure is swallowed: a peer that is already gone has nothing
    /// left to be told, and the close that follows is the same either way.
    pub fn halfClose(self: *Wake) void {
        const socket: zio.net.Socket = .{ .handle = self.handle, .address = undefined };
        socket.shutdown(.send) catch {};
    }

    /// Submit the two halves that are not in the loop's hands: the post half,
    /// and the readable half, which is armed here, on the way in, and not on
    /// the way out of a `.readable` (see `wait`).
    fn arm(self: *Wake) void {
        if (!self.armed) {
            self.cq.submit(&self.wake.c) catch unreachable;
            self.armed = true;
        }
        if (!self.poll_armed) {
            self.cq.submit(&self.poll.c) catch unreachable;
            self.poll_armed = true;
        }
    }

    /// `wait` that does not: what has already completed, `.timed_out` if
    /// nothing has. The loop has to have run since the socket changed for a
    /// completion to be there, which is what the caller's yield is for.
    /// Armed and answered exactly as `wait` is, and a readable poll that has
    /// not fired stays armed for the next look or wait, so nothing is
    /// submitted twice (`poll_armed` clears only when it fires).
    pub fn lookNow(self: *Wake) Woken {
        self.arm();
        if (self.held()) {
            self.skipped = true;
            return .readable;
        }
        const done = self.cq.next() orelse return .timed_out;
        if (done == &self.wake.c) {
            self.cq.submit(&self.wake.c) catch unreachable;
            return .posted;
        }
        if (done == &self.poll.c) {
            self.poll_armed = false;
            if (!self.believe()) {
                self.arm();
                return .timed_out;
            }
            return .readable;
        }
        return .timed_out;
    }

    /// Park until the socket has something to read or somebody posts.
    ///
    /// Only correct with the connection's read buffer already drained — a
    /// reader holding buffered bytes is readable whatever the socket says, and
    /// asking the kernel instead would park on a connection that has a whole
    /// frame sitting in memory. The WebSocket layer checks that before calling
    /// this; the Engine cannot, because it does not know what a frame is.
    /// `limit_ms` of 0 waits with no limit at all.
    pub fn wait(self: *Wake, limit_ms: u32) Woken {
        self.arm();
        // Bytes already held are readable whatever the socket says (`held`).
        if (self.held()) {
            self.skipped = true;
            return .readable;
        }
        // Armed on the way *in*, after the caller has read whatever the last
        // `.readable` was about, rather than on the way out of it.
        //
        // `NetPoll` is level-triggered, so a poll re-submitted while the bytes
        // are still sitting in the kernel's receive buffer completes
        // immediately — and the next `wait` finds that completion already
        // done, answers `.readable` for data the caller has since read, and
        // drops the caller into a blocking read that neither a post nor the
        // limit can reach. Every WebSocket stopped hearing broadcasts and
        // stopped being pinged the moment it sent its first message.
        //
        // `Waker` in `bulkhead.zig` states it as the contract it is: one
        // `.readable` per arrival of bytes, not one per call. Measured in
        // `bench/result/http.md`.
        //
        // `submit` can refuse (zio 0.18): a closed queue, or a completion that
        // belongs to a group or another queue. Nothing closes this queue and
        // both completions are this queue's own, so neither can happen here
        // — which is what `unreachable` states, at every `submit` in this file.
        while (true) {
            // The limit belongs to the wait, not to the connection: it is
            // measured from *this* call, so a client that spoke a moment ago
            // gets a full stretch of silence before anybody asks after it.
            // `CompletionQueue` carries this already, which is why there is no
            // timer completion here to arm, cancel and re-arm. A queue that is
            // closed and drained answers `error.Closed`; nothing closes this
            // one, so that arm is the same "stop" as a cancel.
            const done = self.cq.waitTimeout(if (limit_ms == 0)
                .none
            else
                .{ .duration = .fromMilliseconds(limit_ms) }) catch |err| {
                return if (err == error.Timeout) .timed_out else .closed;
            };

            // The fired completion goes straight back to `submit`, and the
            // loop re-arms it. Under v0.17.0 that crashed 90 runs in 90
            // (zio#673): `Loop.add` reset the completion and wiped the
            // queue's claim on it, and the workaround was to rebuild `wake.c`
            // first — the completion only, because rebuilding the whole
            // `Async` drops the `pending` flag that holds a notify landing in
            // this window. zio#674 fixed it and v0.18.0 carries the fix, so
            // the rebuild is gone; `spike/completion_queue/` holds the plain
            // re-arm to 180 runs in 180, `--window` included.
            if (done == &self.wake.c) {
                self.cq.submit(&self.wake.c) catch unreachable;
                return .posted;
            }
            if (done == &self.poll.c) {
                self.poll_armed = false;
                if (!self.believe()) {
                    self.arm();
                    continue;
                }
                return .readable;
            }
            // Neither of ours. Nothing else is ever submitted to this queue,
            // so this cannot happen; going round again is the harmless
            // reading of a thing that cannot happen.
        }
    }

    /// Give the loop back every completion this queue still holds, and do
    /// not return until it has let go of them.
    ///
    /// **Not optional, and not a tidy-up.** A `Wake` lives in the connection
    /// fiber's frame, so when the fiber returns, `cq`, `wake.c` and `poll.c`
    /// go with it — while `getCurrentExecutor().loop` is still holding
    /// pointers to all three, put there by `submit`. `wake.c` is submitted
    /// for as long as `armed`, and `poll.c` for as long as `poll_armed`, so
    /// on the ordinary way out of a WebSocket both are still in the loop's
    /// hands. What the loop does with them next is write a completion
    /// through `c.group.owner` into a frame that has been handed back.
    ///
    /// That is where the SIGTERM nobody came back from was.
    /// `bench/shutdown.py` at 24 connections a run puts it at **23 of 25
    /// without this call and 0 of 25 with it**. Only a WebSocket arms either
    /// half, which is why no plain HTTP connection was ever affected.
    ///
    /// Nothing to do for a connection that never waited, which is every
    /// ordinary request: a branch, no lock and no syscall.
    pub fn deinit(self: *Wake) void {
        if (!self.armed and !self.poll_armed) return;
        // `cancelAll` drains with cancellation disabled, so this finishes
        // even when the fiber is being cancelled — which is the case that
        // matters, since that is what shutdown does to a WebSocket that is
        // still up. `.discard` because both completions live in this frame:
        // nothing needs their results, and nothing else holds them.
        self.cq.cancelAll(.discard);
        self.armed = false;
        self.poll_armed = false;
    }

    /// Wake the fiber holding this connection. Thread-safe, and the only call
    /// another fiber makes on a `Wake` it does not own.
    pub fn post(self: *Wake) void {
        self.wake.notify();
    }
};

/// Bytes below this call's own frame that are never released.
///
/// **A page of margin is not the same thing as a page of safety, and getting
/// that backwards made this function do nothing for a year of its short life.**
/// The first version left four *pages*, reasoning that more slack is safer. It
/// is not: the whole point is to release the pages a returned call chain
/// touched, and on this framework that chain is four to six kilobytes deep — so
/// a sixteen-kilobyte margin reached past every page there was to give back and
/// the call was a syscall that freed nothing. Measured: an idle keep-alive
/// connection was 8,634 bytes with the release wired in and 8,634 without it.
///
/// What actually has to be true is narrower. `madvise` may not zero anything
/// the return path still reads, which is this frame, and the red zone the ABI
/// lets a leaf function write below the stack pointer — 128 bytes on x86-64.
/// Subtracting `stack_margin` *before* rounding down to a page boundary makes the
/// page holding both of them fall outside the range at every alignment: the
/// floor is at most `frame - stack_margin`, which is below `frame - 128`. Everything
/// under it is stack that has not been used yet and faults back in as zeroes,
/// which is what a fresh frame wants anyway.
const stack_margin = 512;

/// The most a connection's argument list may weigh, so that its task stays in
/// the 512-byte class of the allocator.
///
/// zio puts a task (`AnyTask`, then the result, then the context: 8 bytes for
/// the group and the arguments) in a pool item when it fits
/// `TaskPool.pool_item_size`, 384 bytes, and in `rt.allocator` when it does not.
/// The allocator rounds to a power of two, so a task of 385 to 512 bytes costs
/// 512 bytes resident per connection and one of 513 to 1,024 costs 1,024.
/// Handing each connection the whole `Options` by value, 264 bytes, put the
/// task in the 1,024 class: that is the 512 bytes an idle connection grew
/// between v0.2.0 and v0.3.0 (ADR 017, ADR 062), and why a connection reads its
/// sizes through `Accepting.sizes` instead.
///
/// **These are constants, not `@sizeOf`s, because zio does not export the types.**
/// `zio.zig` re-exports neither `AnyTask` nor `TaskPool`, so nothing here can
/// ask for their sizes. Read from the pinned zio 0.18.0: `src/task.zig:181`
/// (`AnyTask`, 192 bytes on x86-64), `src/task.zig:785-786`
/// (`pool_item_size = alignForward(@sizeOf(AnyTask) + 128, 128)`) and
/// `src/task.zig:801-808` (`alloc` sends anything over that to the allocator).
/// A zio bump re-reads those lines; `bench/mem.py` is what notices if nobody
/// does, since an argument list that fits here and a task that no longer does
/// reads as bytes on every idle connection.
const zio_any_task_bytes = 192;
const zio_context_header_bytes = 8;
const allocator_class_bytes = 512;
const connection_args_max = allocator_class_bytes - zio_any_task_bytes - zio_context_header_bytes;

fn assertTaskClass(comptime F: type) void {
    const size = @sizeOf(std.meta.ArgsTuple(F));
    if (size > connection_args_max) @compileError(std.fmt.comptimePrint(
        "nilo: a connection's argument list is {d} bytes and may be {d}: past that zio's task " ++
            "for it falls into the next size class of the allocator and every idle connection " ++
            "pays 512 bytes more. Hand the large part over by pointer to something `serve` " ++
            "keeps for as long as its connections (ADR 062)",
        .{ size, connection_args_max },
    ));
}

/// Hand back the pages of the *running* fiber's stack that are below its
/// current frame.
///
/// A suspended fiber holds its stack at the high-water mark it ever reached,
/// for the life of the connection, one byte for one byte
/// ([ADR 062](../../docs/adr/062-where-a-connection-waits-is-what-it-costs.md)).
/// The frames that took it there have long since returned; the pages have not.
///
/// `zio.coro.Coroutine.getCurrent()` has been public since v0.17.0 and
/// carries `context.stack_info` — `base` and `limit`.
///
/// Three things make the arithmetic safe, and they are the whole reason this is
/// allowed to exist at all — zio carves 64 stacks out of one slab, so a range
/// that ran one page past its own would zero a neighbouring connection's live
/// stack, silently and rarely:
///
///  1. **`limit` is the committed floor, not the reservation's.** Everything
///     from `limit` to `base` is mapped read-write; below it is `PROT_NONE`.
///     So the range can never reach the guard page.
///  2. **The bounds are checked against where this call actually is.** If the
///     stack pointer is not inside `[limit, base]` then `getCurrent` is not
///     describing the stack under our feet, and nothing happens.
///  3. **The page this call is standing on is never in the range**, so the
///     `madvise` call's own frames are never inside what it is releasing.
///     `stack_margin` is what makes that true at every alignment; see its doc.
///
/// `MADV_DONTNEED` rather than the `MADV_FREE` that `coro.stackRecycle` uses:
/// `FREE` is lazy and leaves the pages in `VmRSS` until the machine is under
/// pressure, which is exactly the number this exists to move. `DONTNEED` does
/// not decommit — the mapping stays read-write and the pages fault back in as
/// zeroes, which is all a dead frame needs to be.
pub fn releaseIdleStack() void {
    if (builtin.os.tag == .windows) return;
    const running = zio.coro.Coroutine.getCurrent() orelse return;
    const info = running.context.stack_info;

    var marker: u8 = 0;
    const frame = @intFromPtr(&marker);
    if (frame <= info.limit + stack_margin or frame > info.base) return;

    const page = std.heap.pageSize();
    const start = std.mem.alignForward(usize, info.limit, page);
    const floor = std.mem.alignBackward(usize, frame - stack_margin, page);
    if (floor <= start) return;

    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start);
    // A failure leaves the pages resident, which is where they were anyway.
    std.posix.madvise(ptr, floor - start, std.posix.MADV.DONTNEED) catch {};
}

/// `"unix:"` in front of `Options.address` means the rest of it is a
/// filesystem path to listen on rather than an IP address.
///
/// A prefix rather than a second field, and a prefix nothing else can be
/// mistaken for: no IPv4 or IPv6 address starts with a letter followed by a
/// colon, so nothing that used to work is read differently now.
const unix_prefix = "unix:";

fn unixPathIn(address: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, address, unix_prefix)) return null;
    return address[unix_prefix.len..];
}

/// Whether a listener asking for `address`:`port` wants one a listener
/// already bound at `bound_address`:`bound_port` has taken (ADR 213).
///
/// **The other side's *bound* port rather than the one it asked for**,
/// because 0 means "whichever is free" and two of those are two different
/// ports rather than a collision. A unix path has no port at all, so there
/// the path alone decides — and it is the *asking* listener's transport
/// that says so, because two listeners whose address strings are equal are
/// both unix or neither is.
///
/// A pure function and not the log line beside it, for the reason
/// `tlsRefusal` is one: an error log inside a test is a failed test
/// whatever it says, so the decision is what gets tested.
fn sameListener(address: []const u8, port: u16, over_unix: bool, bound_address: []const u8, bound_port: u16) bool {
    if (!std.mem.eql(u8, address, bound_address)) return false;
    return over_unix or port == bound_port;
}

/// The listener for an `address`/`port` pair, or null with `why` set and the
/// reason already said out loud.
fn listenOnIp(options: anytype, why: *StartupFailure) ?zio.net.Server {
    const addr = zio.net.IpAddress.parseIp(options.address, options.port) catch |err| {
        std.log.err(
            "\"{s}\" is not an address nilo can listen on ({s}). It wants an IP address, " ++
                "not a host name: \"127.0.0.1\" or \"::1\" for this machine only, " ++
                "\"0.0.0.0\" or \"::\" for every interface. A path goes in as " ++
                "\"unix:/run/nilo.sock\".",
            .{ options.address, @errorName(err) },
        );
        why.* = .bad_address;
        return null;
    };

    return addr.listen(.{ .reuse_address = options.reuse_address, .kernel_backlog = options.backlog }) catch |err| {
        why.* = classifyListenFailure(@errorName(err));
        switch (why.*) {
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
        return null;
    };
}

/// Why `.tls` cannot be honoured, decided before anything is opened, with
/// the saying of it kept apart so the deciding can be tested (ADR 212).
/// Not built comes second: a caller who set both a socket path and `.tls`
/// has a mistake to fix whichever build they have, and is told that one.
const TlsRefusal = enum {
    on_unix_socket,
    not_built,

    fn toError(self: TlsRefusal) anyerror {
        return switch (self) {
            .on_unix_socket => error.TlsOnUnixSocket,
            .not_built => error.TlsNotBuilt,
        };
    }

    fn say(self: TlsRefusal, address: []const u8) void {
        switch (self) {
            .on_unix_socket => std.log.err(
                "`.tls` is set and the address is a unix socket, \"{s}\". TLS is for a " ++
                    "port somebody else can reach; a socket file is reached by processes on " ++
                    "this machine, which the file's permissions already decide. Drop one of " ++
                    "the two.",
                .{address},
            ),
            .not_built => std.log.err(
                "`.tls` is set, and this build has no TLS in it. The library behind it is " ++
                    "fetched and linked only when asked for: pass `.tls = true` to " ++
                    "`b.dependency(\"nilo\", …)` in build.zig (`-Dtls` in this repository), " ++
                    "or drop `.tls` and terminate TLS in front (ADR 027).",
                .{},
            ),
        }
    }
};

fn tlsRefusal(built: bool, wanted: bool, over_unix_socket: bool) ?TlsRefusal {
    if (!wanted) return null;
    if (over_unix_socket) return .on_unix_socket;
    if (!built) return .not_built;
    return null;
}

/// The certificate chain and private key a TLS listener presents, read
/// once (ADR 212). Two files, PEM, relative to the working directory
/// unless absolute: the shape every certificate tool writes and every
/// other server reads, so there is nothing to convert. What is checked
/// here is that both parse; a key that is not the leaf's is found by the
/// first client rather than by this call, which is a roadmap entry. Said
/// out loud by the caller, not here, so this can be tested against a file
/// that is not there.
fn readCertKeyPair(gpa: std.mem.Allocator, io: std.Io, cert_path: []const u8, key_path: []const u8) !@FieldType(Secured, "auth") {
    return tls.config.CertKeyPair.fromFilePath(gpa, io, std.Io.Dir.cwd(), cert_path, key_path);
}

/// Where a handshake's signature is computed: the blocking pool, with the
/// connection's fiber parked until it is done (ADR 217).
///
/// The signature is the one step of a handshake measured in milliseconds,
/// 2.6 ms for the arena's RSA-2048 key on the machine in `bench/result/`,
/// and on the executor it held every connection that executor serves. A
/// burst of new connections is a burst of signatures, so the requests of
/// the connections already open waited behind all of them, and a paced
/// client times those requests from when they were due. Only the signature
/// moves: the rest of a handshake is tens of microseconds, and the hop costs
/// two wakeups.
const sign_elsewhere: tls.config.Offload = .{ .run = signOnPool };

fn signOnPool(_: ?*anyopaque, job: *const fn (arg: *anyopaque) void, arg: *anyopaque) void {
    zio.blockInPlace(callJob, .{ job, arg });
}

fn callJob(job: *const fn (arg: *anyopaque) void, arg: *anyopaque) void {
    job(arg);
}

/// Whether the key is the leaf certificate's own.
///
/// Two files that each parse are not a pair, and nothing above compares
/// them: a certificate handed somebody else's key takes the port, comes
/// up, and fails every handshake at the signature the client checks —
/// `curl` exit 35, with nothing in nilo's log above debug (ADR 212).
/// Both halves are already in hand by the time this is called, so the
/// comparison costs one parse of the leaf at startup and nothing per
/// connection.
///
/// **A pair this cannot compare is answered `true`.** A scheme with no
/// prong here is a key `tls.zig` parsed and nilo has no opinion about,
/// and refusing one would be a server that will not start over a
/// certificate that is fine. The three prongs are the three the library
/// signs with.
fn keyIsTheCertificates(pair: @FieldType(Secured, "auth")) bool {
    const certs = pair.bundle.bytes.items;
    if (certs.len == 0) return false;
    // Leaf first: the order a PEM chain is written in, and the order
    // `makeCertificate` sends them in.
    const leaf: std.crypto.Certificate = .{ .buffer = certs, .index = 0 };
    const parsed = leaf.parse() catch return false;
    const in_certificate = parsed.pubKey();

    switch (pair.key.signature_scheme) {
        // The public point, uncompressed SEC1, which is byte for byte what
        // the certificate carries for an EC key. Derived from the private
        // key at load and kept, because a server signs with it every
        // handshake.
        .ecdsa_secp256r1_sha256, .ecdsa_secp384r1_sha384 => {
            if (parsed.pub_key_algo != .X9_62_id_ecPublicKey) return false;
            const derived = pair.ecdsa_key_pair orelse return false;
            switch (derived) {
                inline else => |key_pair| {
                    const point = key_pair.public_key.toUncompressedSec1();
                    return std.mem.eql(u8, in_certificate, &point);
                },
            }
        },
        // The modulus, and not the exponent: the exponent is 65537 on
        // nearly every key ever issued, so comparing it alone would pass
        // two keys that share nothing.
        .rsa_pss_rsae_sha256, .rsa_pss_rsae_sha384, .rsa_pss_rsae_sha512 => {
            switch (parsed.pub_key_algo) {
                .rsaEncryption, .rsassa_pss => {},
                else => return false,
            }
            const derived = pair.key.key.rsa.public;
            const in_leaf = @TypeOf(derived).fromDer(in_certificate) catch return false;
            // 4,096 bits is the largest modulus the library holds, and
            // `toBytes` pads to whatever it is given, so both sides are
            // written the same width whatever the key size.
            var from_leaf: [512]u8 = undefined;
            var from_key: [512]u8 = undefined;
            in_leaf.modulus.toBytes(&from_leaf, .big) catch return false;
            derived.modulus.toBytes(&from_key, .big) catch return false;
            return std.mem.eql(u8, &from_leaf, &from_key);
        },
        .ed25519 => {
            if (parsed.pub_key_algo != .curveEd25519) return false;
            return std.mem.eql(u8, in_certificate, &pair.key.key.ed25519.public_key.bytes);
        },
        else => return true,
    }
}

/// The same for a path. `port` is not read at all — there is nowhere for a
/// port to go on a unix socket, and pretending otherwise would put a number
/// in the log line that means nothing.
fn listenOnUnix(
    gpa: std.mem.Allocator,
    path: []const u8,
    reuse_address: bool,
    backlog: u31,
    why: *StartupFailure,
) ?zio.net.Server {
    if (!zio.net.has_unix_sockets) {
        std.log.err(
            "this platform has no unix sockets, so \"{s}{s}\" cannot be listened on — " ++
                "an address and a port can.",
            .{ unix_prefix, path },
        );
        why.* = .bad_address;
        return null;
    }
    if (path.len == 0) {
        std.log.err(
            "\"{s}\" has nothing after the colon. It wants a path to put the socket at: " ++
                "\"unix:/run/nilo.sock\".",
            .{unix_prefix},
        );
        why.* = .bad_address;
        return null;
    }

    const addr = zio.net.UnixAddress.init(path) catch {
        std.log.err(
            "the socket path \"{s}\" is {d} bytes and the operating system takes at most {d}. " ++
                "This is a limit on the path itself, not on the file name — a shorter " ++
                "directory is the usual answer.",
            .{ path, path.len, zio.net.UnixAddress.max_len },
        );
        why.* = .bad_address;
        return null;
    };

    // A socket file outlives the process that made it, so a server that was
    // killed leaves one behind and the next bind is `AddressInUse` — which
    // during development is every restart, the same case `reuse_address` is
    // on by default for. What is taken away is narrow on purpose: only a
    // path that is a socket, and only when connecting to it is refused.
    // A regular file, a directory, or a socket something is still listening
    // on is left exactly as it is, and the bind below then fails with a
    // sentence about it.
    if (reuse_address) clearStaleSocket(gpa, path);

    return addr.listen(.{ .kernel_backlog = backlog }) catch |err| {
        why.* = classifyListenFailure(@errorName(err));
        switch (why.*) {
            .in_use => std.log.err(
                "something is already listening on \"{s}\". Stop it, or pass a different " ++
                    "path to listen().",
                .{path},
            ),
            .not_permitted => std.log.err(
                "not allowed to create a socket at \"{s}\" — the directory it goes in has " ++
                    "to be writable by the user this server runs as.",
                .{path},
            ),
            else => std.log.err(
                "could not listen on \"{s}\": {s}. The directory has to exist already; " ++
                    "nilo does not create one.",
                .{ path, @errorName(err) },
            ),
        }
        return null;
    };
}

/// Take away a socket file left behind by a process that is gone.
///
/// Two questions, and both have to answer yes. Is it a socket — because
/// unlinking whatever happens to be at a path the caller wrote is how a
/// typo deletes somebody's file. And is it dead — asked the only way it can
/// be asked, by connecting: a live server accepts, a stale path refuses.
fn clearStaleSocket(gpa: std.mem.Allocator, path: []const u8) void {
    if (!isStaleSocket(gpa, path)) return;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().deleteFile(threaded.io(), path) catch |err| std.log.warn(
        "the socket at \"{s}\" is left over from a server that is gone, and it could not be " ++
            "removed ({s}) — listening is about to fail. Remove it by hand.",
        .{ path, @errorName(err) },
    );
}

/// Both halves of that question.
///
/// **The probe goes through zio rather than through std**, which needs a
/// Runtime to be up — it is, `serve` makes one before it binds — and is not a
/// nicety: `std.Io.net.UnixAddress.ConnectError` does not list
/// `ConnectionRefused`, so std answers the refusal this is *looking for* with
/// `error.Unexpected` and a stack trace on stderr. That would print at every
/// ordinary restart, which is precisely the case this exists to make quiet.
fn isStaleSocket(gpa: std.mem.Allocator, path: []const u8) bool {
    if (!looksLikeSocket(gpa, path)) return false;

    const addr = zio.net.UnixAddress.init(path) catch return false;
    if (addr.connect(.{})) |live| {
        // Somebody is behind it. Not ours to remove, and the bind that
        // follows says so.
        live.close();
        return false;
    } else |_| {}
    return true;
}

/// Is there a socket at this path? No zio, so the safety half — the half that
/// decides whether a file somebody typed the wrong path for survives — is
/// answerable from a test with no runtime at all.
fn looksLikeSocket(gpa: std.mem.Allocator, path: []const u8) bool {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const info = std.Io.Dir.cwd().statFile(threaded.io(), path, .{}) catch return false;
    return info.kind == .unix_domain_socket;
}

/// Give the path back when the server stops. Nothing else will: a unix
/// socket is a file, and closing the descriptor leaves it there.
fn removeSocket(gpa: std.mem.Allocator, path: []const u8) void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().deleteFile(threaded.io(), path) catch {};
}

/// How many OS threads `options` means: `threads` when it was set, and when
/// it was left at 0, one per core the process may use, or one more than its
/// CPU quota where a container sets one. Public, and re-exported by the
/// Bulkhead, so that anything the App sizes to the thread count is sized to
/// the number this Engine actually starts rather than to a second reading
/// of the same field (ADR 211). Never past `max_threads`, whichever way
/// the count was arrived at.
pub fn threadCount(options: anytype) u8 {
    if (options.threads > 0) return @min(options.threads, max_threads);
    const cores = std.Thread.getCpuCount() catch 1;
    return @intCast(@min(autoThreads(cores, cpuQuota()), max_threads));
}

/// The most executors zio can run: an executor's id is a `u6` on a 64-bit
/// target and a `u5` on a 32-bit one, which is a bit per executor in its
/// masks. `ExecutorCount.exact` asserts it and says nothing, so a count
/// past it is held to it: the startup line says how many ran, and a
/// refusal in words cost 2.9 KB of every binary (ADR 230).
const max_threads = @bitSizeOf(usize);

/// The blocking pool `blocking` hands calls to. zio starts a worker for a
/// queued call only once twice as many calls wait as run, which suits many
/// short calls and strands a short one behind a long one: with one worker
/// busy for seconds, a 2 ms call waited for it to finish although the pool
/// could start dozens more. At 0 a call that finds no idle worker starts
/// one, up to the pool's ceiling, and idle workers are reaped as before.
const blocking_pool: zio.ev.ThreadPool.Options = .{ .scale_threshold = 0 };

// ---- how many threads a container means ----
//
// A container's CPU limit (`docker --cpus`, a Kubernetes CPU limit, systemd
// `CPUQuota=`) is a quota the kernel enforces per period, and the affinity
// mask `getCpuCount` reads cannot see it. A server given two CPUs of a
// 16-core host ran 16 executors, spent its quota in the first part of each
// 100 ms period and waited out the rest: a p99.9 of 70 ms (ADR 230).
//
// Not zio's reading, which is the same files: it floors a quota at two
// before handing it back, so one CPU and two CPUs arrive as the same
// number, and they want different counts.

/// The threads for `cores` visible cores under a quota of `quota`
/// thousandths of a CPU:
/// the quota rounded up and one more, because an executor is not busy for
/// the whole of its time, and a thread past the quota fills the gaps rather
/// than being throttled. Measured at quotas of 1, 2 and 4 CPUs, where it
/// was the best count on throughput every time, and at 4 on the tail too
/// (bench/result/http.md). No quota, or one past the cores, is one per core.
fn autoThreads(cores: usize, quota: ?u64) usize {
    const q = quota orelse return cores;
    const within = std.math.divCeil(u64, q, 1000) catch unreachable;
    return @intCast(@max(1, @min(cores, within + 1)));
}

/// The CPU quota of this process's cgroup, in thousandths of a CPU (an
/// integer, because a float would bring its formatting into every binary
/// for one log line), or null when there is
/// none (or this is not Linux, or the files cannot be read). The tightest
/// of the process's own cgroup and every one above it, because a limit is
/// often set on a parent: a Kubernetes pod's, or a systemd slice's.
fn cpuQuota() ?u64 {
    if (builtin.os.tag != .linux) return null;

    var own: [1024]u8 = undefined;
    if (readSmall("/proc/self/cgroup", &own)) |listing| {
        if (unifiedPath(listing)) |leaf| {
            var tightest: ?u64 = null;
            var at: ?[]const u8 = leaf;
            while (at) |dir| : (at = parentCgroup(dir)) {
                // Spelled out rather than formatted: `bufPrint` would be a
                // format function of its own in every binary, for one path.
                const root = "/sys/fs/cgroup";
                const file = "/cpu.max";
                var path: [root.len + 512 + file.len:0]u8 = undefined;
                if (dir.len > 512) break;
                @memcpy(path[0..root.len], root);
                @memcpy(path[root.len..][0..dir.len], dir);
                @memcpy(path[root.len + dir.len ..][0..file.len], file);
                path[root.len + dir.len + file.len] = 0;
                var content: [64]u8 = undefined;
                const at_path: [*:0]const u8 = @ptrCast(&path);
                const limit = parseCpuMax(readSmall(at_path, &content) orelse continue) orelse continue;
                tightest = if (tightest) |t| @min(t, limit) else limit;
            }
            return tightest;
        }
    }

    // cgroup v1: the controller's own files, at the path a container mounts.
    var quota: [32]u8 = undefined;
    var period: [32]u8 = undefined;
    return parseCfs(
        readSmall("/sys/fs/cgroup/cpu/cpu.cfs_quota_us", &quota) orelse return null,
        readSmall("/sys/fs/cgroup/cpu/cpu.cfs_period_us", &period) orelse return null,
    );
}

/// The unified (v2) cgroup this process is in, from `/proc/self/cgroup`'s
/// `0::<path>` line, or null on a v1-only host.
fn unifiedPath(listing: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) return std.mem.trimEnd(u8, line["0::".len..], "/");
    }
    return null;
}

/// `/a/b` → `/a` → `` (the root, whose `cpu.max` is `/sys/fs/cgroup/cpu.max`)
/// → null.
fn parentCgroup(dir: []const u8) ?[]const u8 {
    if (dir.len == 0) return null;
    return dir[0 .. std.mem.lastIndexOfScalar(u8, dir, '/') orelse 0];
}

/// `cpu.max` is `<quota> <period>` in microseconds, and the quota is the
/// word `max` when there is none.
fn parseCpuMax(content: []const u8) ?u64 {
    var words = std.mem.tokenizeAny(u8, content, " \n");
    const quota = words.next() orelse return null;
    if (std.mem.eql(u8, quota, "max")) return null;
    return ratio(quota, words.next() orelse return null);
}

/// v1 keeps the two in files of their own, and a quota of -1 is none.
fn parseCfs(quota: []const u8, period: []const u8) ?u64 {
    return ratio(std.mem.trim(u8, quota, " \n"), std.mem.trim(u8, period, " \n"));
}

/// Rounded up, so a quota a hair over a whole CPU still counts as more.
fn ratio(quota: []const u8, period: []const u8) ?u64 {
    const q = std.fmt.parseInt(i64, quota, 10) catch return null;
    const p = std.fmt.parseInt(i64, period, 10) catch return null;
    if (q <= 0 or p <= 0) return null;
    const scaled = std.math.mul(u64, @intCast(q), 1000) catch return null;
    return std.math.divCeil(u64, scaled, @intCast(p)) catch unreachable;
}

/// A pseudo-file into `buf`, or null for anything that goes wrong: a
/// missing controller, a path somebody else's namespace hides, a read that
/// fails. The question is asked before there is a loop to wait on, and any
/// answer but a quota means "no quota", which is what the count was before.
fn readSmall(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const linux = std.os.linux;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0) return null;
    return buf[0..n];
}

/// Run `handler(state, in, out, clocks, wake, peer)` for every accepted
/// connection, each in its own fiber, until that connection is done. The
/// Reader/Writer are already buffered; the handler does not need to know
/// there is a socket behind them. `handler` must be
/// `fn (@TypeOf(state), *std.Io.Reader, *std.Io.Writer, *Clocks, *Wake, Peer) void`.
///
/// `ready(state, io, port)` runs once, after the loop exists and the port is
/// taken, before the first connection is accepted. It is how something
/// that needs the event loop to exist gets built at all — a connection pool
/// is the case it was added for, and the loop is not there to hand out
/// until this function has started it (ADR 037). `port` is the one the
/// kernel answered with, which is the only way to learn it when `options.port`
/// was 0, and null for a unix socket. `ready` must be
/// `fn (@TypeOf(state), std.Io, ?u16) anyerror!void`.
///
/// Returns when `stop` is set — by a signal, or by somebody calling
/// `App.shutdown()` — once the connections still being served have
/// finished or the grace period has run out.
pub fn serve(
    gpa: std.mem.Allocator,
    options: anytype,
    stop: *Stop,
    state: anytype,
    comptime ready: anytype,
    comptime stopping: anytype,
    comptime handler: anytype,
    comptime plain_handler: anytype,
    comptime hand_on: anytype,
) !void {
    const State = @TypeOf(state);
    const Options = @TypeOf(options);
    const threads: u8 = threadCount(options);

    // No work stealing between executors, and nothing here says so: the
    // scheduling mode is a compile-time default `zioFor` in `build.zig`
    // gives zio (`.pinned`), which an application's root `zio_options` can
    // still override. A connection is served by the thread that was dealt
    // it, start to finish: its socket's completions land on that thread's
    // ring whatever the scheduler does, so a stolen fiber only moves the
    // *running* of a request away from where its I/O is. What stealing
    // costs is paid on every wake: an executor that has just run a task
    // dozes for 100 µs before it parks, so that its own loop can hand work
    // back before a thief takes it, and on a server that is not busy that
    // doze is a second context switch per request (100 µs of CPU a
    // request at 500 req/s against 70 without it, 44 against 34 at 8,000,
    // and +3% at saturation, four pairs of four;
    // [ADR 199](../../docs/adr/199-a-connection-is-served-by-the-thread-it-was-dealt-to.md)).
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(threads), .thread_pool = blocking_pool });
    defer rt.deinit();

    // **Registered second, so it runs second to last** — after the group
    // below has cut off every connection, and before the Runtime is torn
    // down (ADR 121). Both halves of that are load-bearing: a service put
    // down while a handler still holds it is a use-after-free, and a
    // service that still has work on this loop is a Runtime that cannot be
    // deinitialised — zio asserts `task_count == 0` and the process panics
    // one line after saying "nilo stopped".
    //
    // It runs on the failure paths too, which is the case that named this:
    // `ready` below can start a pool and then refuse the boot, and "the
    // server did not start" has to mean the pool let go of the loop.
    defer stopping(state);

    // Failing to take the port is the most common way a server does not
    // start, and it used to arrive as a stack trace three files deep in the
    // Engine. What the person running it needs is the port number and what
    // to do next — so the reason travels back as a value, and the error is
    // made fresh below. Going through a value is what resets the error
    // return trace: the one that gets printed then starts in nilo, not in
    // zio's completion queue (ADR 001 — the Engine is not the user's
    // business, in a crash log least of all).
    var why: StartupFailure = .other;

    // One address, or several: what `Options` names is the first, and
    // `also` is the rest ([ADR 213](../../docs/adr/213-a-server-answers-on-more-than-one-address.md)).
    // A plain port beside a TLS one in a single process is what the list
    // exists for, and almost every server has exactly one entry here.
    const Want = struct {
        address: []const u8,
        port: u16,
        tls: @TypeOf(options.tls),
    };

    // One address this server answers on, and everything that belongs to
    // that address alone.
    const Bound = struct {
        server: zio.net.Server,
        /// The path, when this listener is a unix socket, so the file is
        /// taken away on the way out (ADR 103).
        unix_path: ?[]const u8,
        /// This listener's certificate, owned here. `accepting.secured`
        /// points into this field, so nothing may move after the pointers
        /// below are taken.
        secured: ?Secured,
        /// Filled once `Serving` exists, which is after every socket is
        /// open. Nothing reads it before the acceptors are spawned.
        accepting: Accepting,
        /// What `listen()` was told, for the log line.
        address: []const u8,
        /// Set once the socket is closed and its path removed, which a stop
        /// does as soon as the acceptors are gone rather than at the end.
        closed: bool = false,

        /// Stop listening: the socket, then the file, which is the order
        /// that keeps a socket file from being left behind to fail the next
        /// start. Once, whichever of the stop and the `defer` comes first.
        fn close(b: *@This(), alloc: std.mem.Allocator) void {
            if (b.closed) return;
            b.closed = true;
            b.server.close();
            if (b.unix_path) |path| removeSocket(alloc, path);
        }
    };

    // A listener's number travels in one byte of every connection (ADR 252).
    if (options.also.len > std.math.maxInt(u8)) {
        std.log.err("`also` names {d} listeners; a server answers on at most 256 addresses.", .{options.also.len + 1});
        return error.TooManyListeners;
    }
    const listeners = try gpa.alloc(Bound, 1 + options.also.len);
    defer gpa.free(listeners);

    // How many are open. The one `defer` below reads it at its final value,
    // so a failure part way along the list closes exactly what was taken
    // and a clean run closes all of it, without two paths to keep in step.
    var opened: usize = 0;
    defer for (listeners[0..opened]) |*b| {
        b.close(gpa);
        // The certificate last: a connection still in its handshake reads
        // it until the group below is cancelled.
        if (nilo_build.tls) if (b.secured) |*sec| sec.auth.deinit(gpa);
    };

    for (listeners, 0..) |*b, i| {
        const want: Want = if (i == 0)
            .{ .address = options.address, .port = options.port, .tls = options.tls }
        else
            .{
                .address = options.also[i - 1].address,
                .port = options.also[i - 1].port,
                .tls = options.also[i - 1].tls,
            };

        // A path rather than a port: `.address = "unix:/run/nilo.sock"`. One
        // more spelling of the field that already says what to listen on, rather
        // than a field beside it — two fields would leave a third state, both
        // set, that means nothing (ADR 103).
        const unix_path = unixPathIn(want.address);

        if (tlsRefusal(nilo_build.tls, want.tls != null, unix_path != null)) |refusal| {
            refusal.say(want.address);
            return refusal.toError();
        }

        // Two listeners on one address is a configuration mistake the
        // kernel would report as "already in use", which reads as another
        // process holding the port and sends the reader hunting for one
        // (ADR 213). Said here instead, naming both.
        for (listeners[0..i], 0..) |*earlier, j| {
            const taken = if (unix_path != null) 0 else earlier.server.socket.address.ip.getPort();
            if (!sameListener(want.address, want.port, unix_path != null, earlier.address, taken)) continue;
            std.log.err(
                "listener {d} and listener {d} are both {s}:{d}. A server answers on each " ++
                    "address once; give one of them a different port, or drop it from `also`.",
                .{ j, i, want.address, want.port },
            );
            return error.AddressInUse;
        }

        // The certificate and key, read before the port is taken (ADR 212). A
        // file that is not there is a deployment mistake of the same kind as a
        // port that is not free, and it is said the same way: one line, what to
        // change, and no port held meanwhile. Only a build with `-Dtls` can
        // read one; every other build refuses the option in words rather than
        // serving plain HTTP on a port the caller believed was encrypted.
        //
        // Into a local first: assigned straight into `b.secured`, a failure
        // below would leave the array holding a key pair the `defer` above
        // does not yet count as open, and the `errdefer` is what frees it
        // while it is still this iteration's.
        var secured: ?Secured = null;
        errdefer if (nilo_build.tls) {
            if (secured) |*sec| sec.auth.deinit(gpa);
        };
        if (nilo_build.tls) if (want.tls) |t| {
            const auth = readCertKeyPair(gpa, rt.io(), t.cert, t.key) catch |err| {
                std.log.err(
                    "could not load the TLS certificate \"{s}\" and key \"{s}\" ({s}). Both are PEM " ++
                        "files, the key unencrypted, and the paths are relative to the directory " ++
                        "the server is started in. `openssl x509 -in {s} -noout -text` says " ++
                        "whether the first is a certificate at all.",
                    .{ t.cert, t.key, @errorName(err), t.cert },
                );
                return error.TlsCertificate;
            };
            secured = .{ .auth = auth, .io = rt.io() };
            // Assigned first, so the `errdefer` above owns the pair while
            // this refuses it.
            if (!keyIsTheCertificates(auth)) {
                std.log.err(
                    "the TLS key \"{s}\" is not the certificate \"{s}\"'s own. Both files " ++
                        "parse, so without this the server would take the port and then fail " ++
                        "every handshake, with the reason only visible to the client. " ++
                        "`openssl x509 -in {s} -noout -pubkey` and `openssl pkey -in {s} " ++
                        "-pubout` print the two public keys, and they have to be the same.",
                    .{ t.key, t.cert, t.cert, t.key },
                );
                return error.TlsCertificate;
            }
        };

        const maybe_server: ?zio.net.Server = if (unix_path) |path|
            listenOnUnix(gpa, path, options.reuse_address, options.backlog, &why)
        else
            listenOnIp(.{
                .address = want.address,
                .port = want.port,
                .reuse_address = options.reuse_address,
                .backlog = options.backlog,
            }, &why);
        const sock = maybe_server orelse return why.toError();

        b.* = .{
            .server = sock,
            .unix_path = unix_path,
            .secured = secured,
            .accepting = undefined,
            .address = want.address,
        };
        opened = i + 1;
    }

    // The one every other line below still means when it says "the server":
    // the address `Options` itself named, which is the port `boundPort()`
    // answers with and the one a test that asked the kernel to choose asked
    // about.
    const server = listeners[0].server;
    const unix_path = listeners[0].unix_path;

    // What every connection reads its sizes from (`Accepting.sizes`). A copy
    // of the `Options` in an allocation of its own, made before the group so
    // that it is freed after the group has cut the last connection off, and
    // **not a pointer to `options`**: taking the address of that parameter
    // keeps it in memory, and the same program grew by 20,304 bytes
    // (ADR 017, ADR 062).
    const held = try gpa.create(Options);
    defer gpa.destroy(held);
    held.* = options;

    var group: zio.Group = .init;
    // Whatever is still running when the grace period is over is cut off
    // here. By then it has had its chance.
    defer group.cancel();

    // Registered after the cancel above, so it runs before it: nothing can
    // be spawned into a group that is already winding up (ADR 028).
    //
    // **Above `ready` rather than below it** (ADR 028). `ready` is where
    // the App starts the work that is not a request, and a group that does
    // not exist yet is `error.NoServer` — which is the answer `spawn` gives
    // a unit test, arriving at startup where it means something else
    // entirely. Nothing between here and there accepts a connection, so
    // moving it up costs nothing and changes no ordering: `background` is
    // still cleared before the cancel, and the cancel is still inside the
    // Runtime's lifetime. What it does change is a `ready` that fails —
    // that now cancels whatever it had already started, which is what
    // "the server did not start" has to mean.
    background.store(&group, .release);
    defer background.store(null, .release);
    // The loop a handler's `c.io()` answers with (ADR 238). Set beside
    // `background` because it has the same lifetime and the same
    // one-server-per-process limit, and cleared before the Runtime goes.
    serving.store(rt, .release);
    defer serving.store(null, .release);

    // After the port is taken, before anything is accepted, and before the
    // line below says the server is up — because until this returns it is
    // not. A pool that cannot reach its database explains itself and comes
    // back as an error here rather than as a surprise inside the first
    // request that needed it (ADR 037). This runs on the thread that
    // called `serve`, which is already inside the loop: `accept` below is
    // waited on the same way, so anything `ready` does can wait too.
    // The port is read back from the socket rather than from `options`,
    // because 0 asks the kernel to choose and a test is the caller that does.
    try ready(state, rt.io(), if (unix_path != null) null else server.socket.address.ip.getPort());

    // The first listener keeps the line it always had, word for word: it is
    // what the guides quote and what a reader looks for. The rest say the
    // same thing one line each, without repeating the thread count, which
    // is the server's and not any one address's (ADR 213).
    if (listeners[0].secured != null)
        std.log.info("nilo listening on https://{f} across {d} thread(s)", .{ server.socket.address, threads })
    else
        std.log.info("nilo listening on {f} across {d} thread(s)", .{ server.socket.address, threads });
    for (listeners[1..]) |*b| {
        if (b.secured != null)
            std.log.info("nilo also listening on https://{f}", .{b.server.socket.address})
        else
            std.log.info("nilo also listening on {f}", .{b.server.socket.address});
    }
    // Only when the count is not the one a reader would guess from the
    // machine: a container's quota lowering it is invisible from inside,
    // and one number with no reason next to it is how sixteen threads on two
    // CPUs went unnoticed (ADR 230).
    if (options.threads == 0) {
        const cores = std.Thread.getCpuCount() catch threads;
        if (threads < cores) if (cpuQuota()) |quota| std.log.info(
            "nilo runs {d} thread(s) of the {d} core(s) it can see: its CPU quota is {d}.{d:0>2}, " ++
                "and a thread past the quota fills the time the others wait",
            .{ threads, cores, quota / 1000, quota % 1000 / 10 },
        );
    }

    // A buffer that starts on a page boundary and ends on one, so every page
    // of it belongs to this connection alone and can be given back.
    const alignedPages = struct {
        fn f(buf_gpa: std.mem.Allocator, want: usize) ![]align(std.heap.page_size_min) u8 {
            const page = std.heap.pageSize();
            const rounded = std.mem.alignForward(usize, @max(want, 1), page);
            return buf_gpa.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), rounded);
        }
    }.f;

    // How many records the ciphertext buffer of a TLS connection holds, so
    // a drain seals up to this many before one write. Page-aligned and
    // given back at every idle transition with the rest, so only the pages a
    // large answer touches are resident, and only until the connection waits.
    const cork_records = 2;
    // A file shorter than this is read through the writer's buffer as ever.
    const bulk_min = 16 * 1024;
    // What a file is read through, and sealed from, at a time on TLS.
    const bulk_file = 64 * 1024;
    // The slices of a drain that can keep a byte back (a write is a few).
    const held_slices = 8;

    // A connection's two halves, joined so that a read on one flushes the
    // other first ([ADR 201](../../docs/adr/201-a-response-is-flushed-before-the-connection-waits.md)).
    //
    // The HTTP and WebSocket layers skip the flush on a response whose
    // successor is already sitting in the read buffer, so a pipelined batch
    // goes out as one write instead of one a response. What makes that
    // safe to do without thinking is here: the reader's vtable is swapped
    // for one that flushes the writer before every socket read, so no read
    // can park this fiber with a response still in memory. The layers decide
    // when a flush is worth skipping; the Engine guarantees it is never
    // skipped for good. A read that finds nothing to flush pays one load.
    //
    // A flush that fails here is left alone: the bytes stay buffered with
    // the writer's error beside them, and the next write to the connection
    // fails where the HTTP layer already knows how to say why. The read
    // goes ahead, which is the read that finds the peer gone.
    const Link = struct {
        reader: zio.net.Stream.Reader,
        writer: zio.net.Stream.Writer,
        // zio's own vtable, which does the reading once the writer is empty.
        inner: *const std.Io.Reader.VTable,

        const Self = @This();

        const vtable: std.Io.Reader.VTable = .{
            .stream = stream,
            .readVec = readVec,
        };

        fn init(link: *Self, s: zio.net.Stream, read_buf: []u8, write_buf: []u8) void {
            link.reader = s.reader(read_buf);
            link.writer = s.writer(write_buf);
            link.inner = link.reader.interface.vtable;
            link.reader.interface.vtable = &vtable;
        }

        fn of(io_r: *std.Io.Reader) *Self {
            const r: *zio.net.Stream.Reader = @alignCast(@fieldParentPtr("interface", io_r));
            return @alignCast(@fieldParentPtr("reader", r));
        }

        /// A flush that failed is left for the next write to report, except
        /// one a stop cancelled. zio delivers a cancel once, so swallowed
        /// here it would be gone, and the read after it would park for a
        /// whole idle limit on a server that is trying to stop. It fails the
        /// read instead, with the reader saying why.
        fn settle(link: *Self) error{ReadFailed}!void {
            const w = &link.writer.interface;
            if (w.end == 0) return;
            w.flush() catch if (link.writer.err) |err| if (err == error.Canceled) {
                link.reader.err = error.Canceled;
                return error.ReadFailed;
            };
        }

        fn stream(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const link = of(io_r);
            try link.settle();
            return link.inner.stream(io_r, io_w, limit);
        }

        fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
            const link = of(io_r);
            try link.settle();
            return link.inner.readVec(io_r, data);
        }
    };

    const Conn = struct {
        /// The plain entry: one body for every connection a plain listener
        /// takes. In a `-Dhttp2` build it is handed `plain_handler`, which
        /// reads the first bytes, serves HTTP/1.1 itself and answers `.http2`
        /// for an HTTP/2 connection, which `hand_on` then runs from this
        /// entry's frame once the choosing has returned (ADR 259, ADR 062);
        /// in any other build it is `handler` and this is the function it
        /// was to the byte. A comptime parameter rather than a branch, so a
        /// build without the flag analyses none of the choosing.
        const run = if (nilo_build.http2) Entry(plain_handler, hand_on).run else Entry(handler, null).run;

        fn Entry(comptime connection: anytype, comptime hand_on_to: anytype) type {
            return struct {
        fn run(
            st: State,
            stream: zio.net.Stream,
            conn_gpa: std.mem.Allocator,
            // The listener's own state rather than `&sh.all.capacity`, which is all this
            // entry reads of it: `runTls` below wants the rest, and the two
            // entries keep one argument list so the plain one's frame is
            // what it was. Two more arguments kept live across the handler
            // measured one page more per *plain* idle connection: the plain
            // park sits under 300 bytes short of a page boundary, and
            // anything added above it is a whole page (ADR 212).
            sh: *Accepting,
        ) void {
            const capacity = &sh.all.capacity;
            const sizes: *const Options = @ptrCast(@alignCast(sh.sizes));
            // After the close, not before: the count is meant to answer
            // "how many sockets does this process hold", and the socket is
            // held until it is shut. Deferred first so it runs last.
            defer capacity.give();
            defer stream.close();

            // A unix socket has no address, and nothing remote could have
            // opened it. Both of those matter below.
            const over_ip = stream.socket.address.getType() == .ip;

            // A response goes out the moment nothing is queued behind it, and
            // the next one may be microseconds later; Nagle would hold the
            // second for the first's ack and save nothing, so it is turned
            // off.
            //
            // TCP only. On a unix socket the option is `EOPNOTSUPP`, and zio
            // answers an errno it does not recognise with a stack trace and an
            // invitation to file a bug — which `catch {}` does not swallow,
            // because it is printed before the error is returned. Once per
            // connection (ADR 103).
            if (over_ip) stream.socket.setNoDelay(true) catch {};

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

            var link: Link = undefined;
            link.init(stream, read_buf, write_buf);
            var clocks = Clocks{ .reader = &link.reader, .writer = &link.writer };

            // In the fiber's own frame, so it costs pages that are already
            // mapped rather than an allocation of its own — see `Wake`. An
            // ordinary request never touches it; it is armed on the first
            // `wait`, which only a WebSocket reaches.
            var wake = Wake.init(stream.socket.handle);
            // Registered after the two buffers and after `stream.close`, so
            // it unwinds before all three: the loop has to be done with the
            // completions before the frame holding them goes, and the poll
            // is on this socket's handle, so it has to be given back before
            // the handle is closed.
            defer wake.deinit();

            // `accept` already returned who this is, so this costs no
            // syscall — only the formatting, once per connection.
            var peer: Peer = .{
                .port = portOf(stream.socket.address),
                .local = !over_ip,
                .listener = sh.index,
            };
            peer._len = writePeer(&peer._text, stream.socket.address);

            const handed = connection(st, &link.reader.interface, &link.writer.interface, &clocks, &wake, peer);
            // A plain listener of a `-Dhttp2` build answers which framing it
            // read, and HTTP/2 is run from here, with the choosing returned
            // from, rather than from inside it (ADR 259). Nothing here in a
            // build without the flag: `connection` returns `void`.
            if (comptime @TypeOf(handed) != void) {
                if (handed == .http2) hand_on_to(&st, &link.reader.interface, &link.writer.interface, &clocks, &wake, &peer);
            }
        }
            };
        }

        /// The TLS connection's entry (ADR 212): the same as `run` with a
        /// handshake in front of the first request and a record layer under
        /// every read and write, and a fiber function of its own rather than
        /// a branch in `run`.
        ///
        /// A branch was measured. The call it adds (a `Peer` copied for the
        /// argument, the unwrap, the spills) grew the frame above a *plain*
        /// connection's park by 272 bytes, 2,618 to 2,890, and that crossed
        /// a page of the fiber's stack on a listener with no TLS on it. Two
        /// entries keep the plain path in a build without `-Dtls` byte for
        /// byte what it was, 5,191 idle; a build with the flag still pays
        /// the page on a plain listener, 9,293, and that one is the
        /// inliner's rather than this frame's (ADR 212). A listener that
        /// is not TLS never spawns this.
        ///
        /// What one of these holds while idle, measured at 10,000
        /// connections: 9,307 bytes, fourteen more than a plain connection
        /// on the same build. The 49 KB of record buffers are page-aligned
        /// and handed back with the cleartext pair at every idle transition,
        /// so they are not in that figure.
        ///
        /// In a `-Dhttp2` build the handshake offers `h2` and `http/1.1` by
        /// ALPN, `h2` first (the server's preference, RFC 7301), and the
        /// connection is served as what was chosen: HTTP/2 through
        /// `hand_on`, from this frame, and HTTP/1.1 through `handler` as
        /// ever. A client that sends no ALPN extension at all is served
        /// HTTP/1.1, the library selecting nothing; one that offers ALPN with
        /// nothing in common is sent RFC 7301's `no_application_protocol`
        /// alert (§3.2) and the handshake fails. In any other build it offers `http/1.1` alone and the
        /// choice is not compiled (ADR 259, ADR 027).
        const runTls = TlsEntry(handler, if (nilo_build.http2) hand_on else null).run;

        fn TlsEntry(comptime connection: anytype, comptime hand_on_to: anytype) type {
            const alpn: []const []const u8 = if (nilo_build.http2) &.{ "h2", "http/1.1" } else &.{"http/1.1"};
            return struct {
        fn run(
            st: State,
            stream: zio.net.Stream,
            conn_gpa: std.mem.Allocator,
            sh: *Accepting,
        ) void {
            if (!nilo_build.tls) unreachable;
            const capacity = &sh.all.capacity;
            const sizes: *const Options = @ptrCast(@alignCast(sh.sizes));
            defer capacity.give();
            defer stream.close();
            // Always IP: a TLS listener on a unix socket is refused in
            // `serve` before the port is taken.
            stream.socket.setNoDelay(true) catch {};

            // The record layer. A TLS record is at most 16,645 bytes on the
            // wire and has to be whole before it can be decrypted, so the
            // input side cannot be smaller than one; the output side holds
            // `cork_records` of the largest record this library writes, so a
            // drain is sealed and sent in as few writes as that allows
            // (ADR 212). Page-aligned for the same
            // reason the cleartext pair is: so every page of them belongs
            // to this connection alone and can be given back.
            const raw_in = alignedPages(conn_gpa, tls.input_buffer_len) catch return;
            defer conn_gpa.free(raw_in);
            const raw_out = alignedPages(conn_gpa, tls.output_buffer_len * cork_records) catch return;
            defer conn_gpa.free(raw_out);
            var link: Link = undefined;
            link.init(stream, raw_in, raw_out);
            var clocks = Clocks{ .reader = &link.reader, .writer = &link.writer };
            var wake = Wake.init(stream.socket.handle);
            defer wake.deinit();
            var peer: Peer = .{
                .port = portOf(stream.socket.address),
                .local = false,
                .tls = true,
                .listener = sh.index,
            };
            peer._len = writePeer(&peer._text, stream.socket.address);

            // The handshake is bounded by the same limits the first request
            // head would be, because until it is done that is what this is:
            // a client that has connected and not yet said anything nilo
            // can act on. Without this a client that connects and goes quiet,
            // or speaks plain HTTP to a TLS port, holds the fiber and its
            // 33 KB for ever. The Bulkhead arms its own limits once the
            // handler starts, the way it does on a plain connection.
            if (sizes.header_timeout_ms != 0)
                clocks.readByNanos(monotonicNanos() + @as(u64, sizes.header_timeout_ms) * std.time.ns_per_ms);
            if (sizes.write_timeout_ms != 0) clocks.writeWithinMs(sizes.write_timeout_ms);

            // Never inlined: the handshake's frames, a 16 KB cleartext
            // buffer among them, must be *below* this frame, in the region
            // the idle release hands back, and not folded into the frame
            // that lives as long as the connection (ADR 062). Measured as
            // one page per idle connection: 13,360 bytes inlined against
            // 9,302 not.
            const sec = sh.secured.?;
            var rng_source: std.Random.IoSource = .{ .io = sec.io };
            var conn = @call(.never_inline, tls.server, .{ &link.reader.interface, &link.writer.interface, tls.config.Server{
                .auth = &sec.auth,
                .now = std.Io.Clock.real.now(sec.io),
                .rng = rng_source.interface(),
                .alpn_protocols = alpn,
                .offload = sign_elsewhere,
            } }) catch |err| {
                // Debug rather than warn: a port on the internet is
                // handshaken at by scanners all day, and every one of those
                // is this line.
                std.log.debug("tls handshake with {s} failed: {s}", .{ peer.address(), @errorName(err) });
                return;
            };

            // Cleartext: the buffers the handler sees, the size a plain
            // connection's are, and released the same way. The record layer
            // goes back with them through `wake.raw`.
            const clear_in = alignedPages(conn_gpa, sizes.read_buffer) catch return;
            defer conn_gpa.free(clear_in);
            const clear_out = alignedPages(conn_gpa, sizes.write_buffer) catch return;
            defer conn_gpa.free(clear_out);
            const TlsWriter = @TypeOf(conn.writer(clear_out));
            // The cleartext writer the handler sees. The library seals a
            // record and writes it to the socket at once, so a frame's
            // nine-byte head and its payload were two records and two
            // writes, and a body of a megabyte was sixty-four. Sealer
            // keeps the library's flush after each record for the length of
            // one drain and sends what it sealed in as few writes as the
            // record buffer holds (`cork_records` of them).
            const Sealer = struct {
                inner: TlsWriter,
                link: *Link,
                plain: *const std.Io.Writer.VTable,
                corked: std.Io.Writer.VTable,
                gpa: std.mem.Allocator,
                interface: std.Io.Writer,

                const vtable: std.Io.Writer.VTable = .{ .drain = sealDrain, .sendFile = sealFile };

                fn of(w: *std.Io.Writer) *@This() {
                    return @alignCast(@fieldParentPtr("interface", w));
                }

                fn cork(self: *@This()) void {
                    self.link.writer.interface.vtable = &self.corked;
                }

                /// The library's flushes are over: the one write for what
                /// it sealed in between.
                fn uncork(self: *@This()) std.Io.Writer.Error!void {
                    const out = &self.link.writer.interface;
                    out.vtable = self.plain;
                    try out.flush();
                }

                fn sealDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                    const self = of(w);
                    // A drain that carries data keeps the last byte of it in
                    // the buffer: the records sealed so far wait in the
                    // record buffer for the write that the flush (or the
                    // next full buffer) makes, and a caller that flushes
                    // only a writer with something in it still finds
                    // something, as it would on a plain connection whose
                    // buffer was not emptied. Without it a frame's head and
                    // its payload were two writes.
                    var total: usize = 0;
                    if (splat == 1) for (data) |d| {
                        total += d.len;
                    };
                    var view: [held_slices][]const u8 = undefined;
                    var last: u8 = 0;
                    const hold = total != 0 and data.len <= held_slices;
                    if (hold) {
                        @memcpy(view[0..data.len], data);
                        var at = data.len;
                        while (at > 0) {
                            at -= 1;
                            if (view[at].len == 0) continue;
                            last = view[at][view[at].len - 1];
                            view[at] = view[at][0 .. view[at].len - 1];
                            break;
                        }
                    }
                    self.inner.interface.end = w.end;
                    self.cork();
                    const n = self.inner.interface.vtable.drain(&self.inner.interface, if (hold) view[0..data.len] else data, splat) catch |err| {
                        w.end = self.inner.interface.end;
                        self.link.writer.interface.vtable = self.plain;
                        return err;
                    };
                    w.end = self.inner.interface.end;
                    if (hold) {
                        self.link.writer.interface.vtable = self.plain;
                        w.buffer[0] = last;
                        w.end = 1;
                        return n + 1;
                    }
                    try self.uncork();
                    return n;
                }

                /// A file is read a buffer at a time and sealed as it goes.
                /// The writer's own buffer is a connection's write buffer,
                /// 4 KiB, which made every record 4 KiB and every record a
                /// read and a write; the buffer here lives for the file
                /// alone, so no connection holds it idle.
                fn sealFile(w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
                    const self = of(w);
                    const left0: usize = @intFromEnum(limit);
                    // `sendFileAll` asks again until its limit is met, and a
                    // limit past the end of the file means a second call
                    // that would take a buffer to learn there is nothing.
                    if (file_reader.atEnd()) return error.EndOfStream;
                    const left_in_file: u64 = if (file_reader.size) |size| size -| file_reader.logicalPos() else left0;
                    const wanted: usize = @intCast(@min(left0, left_in_file));
                    if (wanted < bulk_min) return error.Unimplemented;
                    const buf = self.gpa.alloc(u8, @min(wanted, bulk_file)) catch return error.Unimplemented;
                    defer self.gpa.free(buf);
                    var total: usize = 0;
                    while (total < wanted) {
                        const want = @min(wanted - total, buf.len);
                        const n = file_reader.interface.readSliceShort(buf[0..want]) catch return error.ReadFailed;
                        if (n == 0) {
                            if (total == 0) return error.EndOfStream;
                            break;
                        }
                        try w.writeAll(buf[0..n]);
                        total += n;
                    }
                    return total;
                }
            };
            var tw: Sealer = .{
                .inner = conn.writer(clear_out),
                .link = &link,
                .plain = link.writer.interface.vtable,
                .corked = link.writer.interface.vtable.*,
                .gpa = conn_gpa,
                .interface = .{ .vtable = &Sealer.vtable, .buffer = clear_out },
            };
            tw.corked.flush = std.Io.Writer.noopFlush;

            // `Link` one layer up: before the cleartext reader asks the
            // library for a record, what the handler wrote into the cleartext
            // writer is sealed and sent. `Link` flushes only the record writer
            // under it, so an answer written while the read buffer still held
            // bytes (an unread body, the rest of a WebSocket frame) sat in the
            // cleartext buffer while the connection waited for the client,
            // which a keep-alive POST measured as the whole idle limit
            // (ADR 201). tls.zig's reader has only `stream`, so that is the
            // one wrapped; the defaults it leaves call it.
            const TlsReader = @TypeOf(conn.reader(clear_in));
            const ClearLink = struct {
                reader: TlsReader,
                writer: *std.Io.Writer,
                inner: *const std.Io.Reader.VTable,
                /// The record layer, whose writer says why a flush failed.
                link: *Link,

                const vtable: std.Io.Reader.VTable = .{ .stream = streamSettled };

                fn streamSettled(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
                    const r: *TlsReader = @alignCast(@fieldParentPtr("interface", io_r));
                    const self: *@This() = @alignCast(@fieldParentPtr("reader", r));
                    // A failed flush is left for the next write to report,
                    // and a cancelled one fails the read, as `Link.settle`
                    // does and for its reason.
                    if (self.writer.end != 0) self.writer.flush() catch
                        if (self.link.writer.err) |err| if (err == error.Canceled) {
                            self.link.reader.err = error.Canceled;
                            return error.ReadFailed;
                        };
                    return self.inner.stream(io_r, io_w, limit);
                }
            };
            var clear: ClearLink = .{ .reader = conn.reader(clear_in), .writer = &tw.interface, .inner = undefined, .link = &link };
            clear.inner = clear.reader.interface.vtable;
            clear.reader.interface.vtable = &ClearLink.vtable;
            const tr = &clear.reader;
            const raw: Wake.RawLayer = .{
                .in = &link.reader.interface,
                .out = &link.writer.interface,
                .leftover = &conn.cleartext_buf,
            };
            wake.raw = &raw;
            // What the handshake settled on is read here and the HTTP/2
            // connection is run through one call that is never inlined, so
            // none of its frame is the one an HTTP/1.1 connection parks
            // under (ADR 062, ADR 259). A build without the flag has neither
            // the test nor the call.
            if (comptime nilo_build.http2) {
                const h2 = if (conn.alpn_protocol) |chosen| std.mem.eql(u8, chosen, "h2") else false;
                if (h2)
                    hand_on_to(&st, &tr.interface, &tw.interface, &clocks, &wake, &peer)
                else
                    connection(st, &tr.interface, &tw.interface, &clocks, &wake, peer);
            } else connection(st, &tr.interface, &tw.interface, &clocks, &wake, peer);
            // The handler is done with the connection: what it wrote goes
            // out as records, then close_notify, so the peer sees an end
            // rather than a reset. A failure here is a peer already gone.
            tw.interface.flush() catch {};
            conn.close() catch {};
        }
            };
        }
    };

    if (options.stop_on_signal) installStopSignals(stop);
    defer if (options.stop_on_signal) restoreStopSignals();

    warnIfDescriptorsShort(options.max_connections);

    // What every acceptor of every listener shares. On the main fiber's
    // frame, which outlives them: they are cancelled below before this
    // function returns.
    var shared: Serving = .{ .capacity = .{ .max = options.max_connections } };

    // The per-listener half, filled now that the array is final and the
    // server it belongs to exists. `secured` points into `Bound`, so this
    // is the line that fixes the array in place (ADR 213).
    for (listeners, 0..) |*b, i| b.accepting = .{
        .all = &shared,
        .secured = if (b.secured) |*sec| sec else null,
        .index = @intCast(i),
        .sizes = held,
    };

    // One acceptor. There is one per executor ([ADR 200](../../docs/adr/200-every-executor-accepts.md)),
    // each parked in its own `accept` on the one listening socket, so a
    // burst of connections is taken by as many threads as there are rather
    // than queued behind one fiber's round trips through the loop. The
    // kernel hands each completed handshake to one waiting acceptor; which
    // one does not matter, because the connection is then dealt to an
    // executor round-robin by `spawn`, the same as before.
    const Acceptor = struct {
        fn run(sh: *Accepting, server_: zio.net.Server, st: State, conn_gpa: std.mem.Allocator, connections: *zio.Group) void {
            // Grows while accepting keeps failing for want of a descriptor,
            // and is reset by the first connection that gets through. Per
            // acceptor, because each one waits on its own; the log line is
            // shared, so a shortage is said once and not once a thread.
            var backoff_ms: u32 = 0;
            // Failures in a row that `accept(2)` says belong to the
            // connection rather than the listener, below.
            var strikes: u32 = 0;

            while (true) {
                const stream = server_.accept(.{}) catch |err| switch (err) {
                    // `serve` saw the stop flag and cancelled every acceptor.
                    // Not an error, and the one way this loop ends.
                    error.Canceled => return,
                    // The machine is out of something, for now: this process's
                    // descriptor table is full, the system's is, or the kernel had
                    // no memory for a socket. None of that is the listener's fault
                    // and all of it clears on its own — the moment a connection
                    // closes, the next accept works. Returning would turn a
                    // condition that clears into an outage that needs a restart,
                    // and until ADR 194 that is what happened: a server holding
                    // ~1,000 connections on a default `ulimit -n` ended `listen()`
                    // with a clean "nilo stopping" in the log, well short of its
                    // own `max_connections`. So the loop sleeps and tries again,
                    // for longer each time, and says so once per shortage.
                    error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => {
                        const first = backoff_ms == 0;
                        backoff_ms = if (first) accept_backoff_min_ms else @min(backoff_ms * 2, accept_backoff_max_ms);
                        if (first and sh.all.short.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) std.log.warn(
                            "accept failed with {s}: the process or the machine is out of file " ++
                                "descriptors or memory, so nilo is pausing before it tries again. Held " ++
                                "connections: {d} of {d}. Raise `ulimit -n` (or `LimitNOFILE=` under " ++
                                "systemd) past `.max_connections`, or lower `.max_connections`.",
                            .{ @errorName(err), sh.all.capacity.held(), sh.all.capacity.max },
                        );
                        zio.sleep(.fromMilliseconds(backoff_ms)) catch return;
                        continue;
                    },
                    // A connection that failed between its handshake and
                    // this `accept`: Linux passes a network error pending on
                    // the new socket through `accept`, and `accept(2)` says
                    // to treat it like `EAGAIN` and try again. `EPROTO`,
                    // `EPERM` from a firewall, `ENETDOWN` and `EOPNOTSUPP`
                    // arrive named; `ENETUNREACH` and `EHOSTUNREACH` arrive
                    // as `Unexpected`. Each is one client's, so one of them
                    // ending the server cut every request in flight (ADR
                    // 194). A run of them with nothing getting through is
                    // the listener's after all, and stops it as below.
                    error.ProtocolFailure,
                    error.BlockedByFirewall,
                    error.NetworkDown,
                    error.OperationNotSupported,
                    error.Unexpected,
                    => {
                        strikes += 1;
                        if (strikes > accept_strikes_max) {
                            sh.fail(err);
                            return;
                        }
                        std.log.debug("accept failed with {s}; trying again", .{@errorName(err)});
                        zio.sleep(.fromMilliseconds(accept_backoff_min_ms)) catch return;
                        continue;
                    },
                    // Anything else is the listener's own failure, and it stops
                    // the server: the first acceptor to see one keeps it for
                    // `serve` to return, and raises the stop flag so that the
                    // others are cancelled and the drain begins. A client that
                    // gave up while still in the backlog is not that: under zio
                    // v0.17.0 it surfaced here as `error.ConnectionAborted` and
                    // took the whole server down with it; since v0.18.0 `accept`
                    // retries it inside, and it never reaches this line.
                    else => {
                        sh.fail(err);
                        return;
                    },
                };
                strikes = 0;
                if (backoff_ms != 0) {
                    backoff_ms = 0;
                    if (sh.all.short.cmpxchgStrong(true, false, .acq_rel, .monotonic) == null) {
                        std.log.info("accept works again after the descriptor shortage", .{});
                    }
                }

                // Full: closed at once, without being read from and without being
                // answered. Closing rather than not accepting, so that the client
                // finds out now — a connection left in the kernel's backlog hangs
                // until something times out, and the load balancer that ADR 027
                // says is in front cannot fail over to another instance until it
                // does. Closing rather than answering 503, because writing to a
                // client the server has just decided it cannot afford to serve is
                // work an attacker gets to choose, and it would put a write with a
                // deadline on it inside the one loop that must not stall.
                if (!sh.all.capacity.take()) {
                    stream.close();
                    if (sh.all.capacity.claimWarning(monotonicNanos())) {
                        std.log.warn(
                            "nilo is holding its limit of {d} connections, so new ones are being closed " ++
                                "unanswered ({d} so far). Raise `.max_connections` in listen() if the " ++
                                "machine has the memory — an idle connection costs 4,669 bytes, plus " ++
                                "whatever stack the handler touches — or put fewer of them on this " ++
                                "process.",
                            .{ sh.all.capacity.max, sh.all.capacity.refused.load(.monotonic) },
                        );
                    }
                    continue;
                }

                // Two entries and one argument list, for the reason on
                // `Conn.runTls`. `nilo_build.tls` first so that a build
                // without TLS has no reference to `runTls` to analyse.
                comptime assertTaskClass(@TypeOf(Conn.run));
                if (nilo_build.tls) comptime assertTaskClass(@TypeOf(Conn.runTls));
                const spawned = if (nilo_build.tls and sh.secured != null)
                    connections.spawn(Conn.runTls, .{ st, stream, conn_gpa, sh })
                else
                    connections.spawn(Conn.run, .{ st, stream, conn_gpa, sh });
                spawned catch |err| {
                    sh.all.capacity.give();
                    stream.close();
                    // `error.Closed` is the connections group winding up,
                    // which means `serve` is already on its way out.
                    if (err != error.Closed) sh.fail(err);
                    return;
                };
            }
        }
    };

    // One acceptor per executor. Spawned back to back, so that `spawn`'s
    // round-robin puts each on a different thread; what a thread gets is
    // one fiber parked in `accept`, four kilobytes of stack, for the life of
    // the server. Cancelled before anything else on the way out — before
    // the connections, before the listener is closed — so no `accept` is
    // ever pending on a socket that is being taken away.
    //
    // One set per listener (ADR 213), and the listener is the outer loop
    // so that each one's acceptors still land on consecutive executors: the
    // round-robin wraps, so a second listener gets the same spread of
    // threads the first did rather than the leftovers.
    var acceptors: zio.Group = .init;
    defer acceptors.cancel();
    for (listeners) |*b| {
        for (0..threads) |_| {
            try acceptors.spawn(Acceptor.run, .{ &b.accepting, b.server, state, gpa, &group });
        }
    }

    // The main fiber's only job from here is to notice a stop. It cannot be
    // woken for one — a signal handler may not touch a wait queue — so it
    // looks five times a second, and then cancels the acceptors, which is
    // the one thing that ends their `accept`.
    while (!stop.isRequested() and !shared.failed()) {
        zio.sleep(.fromMilliseconds(accept_poll_ms)) catch break;
    }
    acceptors.cancel();
    // Nothing is accepting, so nothing should be listening: left open for
    // the grace period, the kernel goes on completing handshakes into a
    // backlog nobody will read, and a load balancer keeps sending to an
    // instance that has stopped (ADR 194).
    for (listeners) |*b| b.close(gpa);

    // A listener that failed still lets the requests it already took
    // finish; returning first cut them off at the `group.cancel()` above.
    const failure = shared.takeFailure();
    drain(stop, options.shutdown_grace_ms);
    if (failure) |err| return err;
}

/// Descriptors a process holds that are not connections: the listener, the
/// log, stdin/out/err, the Runtime's own eventfds and timer fds, a database
/// pool. Two dozen is more than any of that comes to, and being generous
/// here only ever makes the warning fire a little early.
const descriptor_headroom: u64 = 32;

/// Say so at startup if `max_connections` is a number this process could
/// never reach, because the operating system would refuse the descriptor
/// first (ADR 194).
///
/// A warning rather than a refusal, and rather than raising the limit
/// ourselves. The default of 10,000 is above the 1,024 most shells hand out,
/// so refusing would stop every server that never changed either number —
/// and `setrlimit` past the soft limit is a policy call the person running
/// the process made when they left it there. What they need is the two
/// numbers next to each other, once, before the traffic arrives; the accept
/// loop's backoff is what holds the server up if they turn out to be wrong.
///
/// A soft limit is the one that applies; the hard limit is how far
/// `ulimit -n` may be raised without root, which is why it is in the message.
fn warnIfDescriptorsShort(max_connections: u32) void {
    if (max_connections == 0) return;
    if (comptime std.posix.rlimit == void) return;
    const limit = std.posix.getrlimit(.NOFILE) catch return;
    const wanted: u64 = @as(u64, max_connections) + descriptor_headroom;
    if (limit.cur >= wanted) return;
    std.log.warn(
        "`.max_connections` is {d} but this process may hold {d} file descriptors, so the " ++
            "operating system would refuse a connection long before nilo does — at about " ++
            "{d} of them. Raise it with `ulimit -n {d}` (the hard limit here is {d}) or " ++
            "`LimitNOFILE={d}` under systemd, or lower `.max_connections` to what the " ++
            "machine allows.",
        .{ max_connections, limit.cur, limit.cur -| descriptor_headroom, wanted, limit.max, wanted },
    );
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
            std.log.info("nilo stopped", .{});
            return;
        }
        if (waited >= grace_ms) {
            std.log.warn(
                "nilo stopped with {d} request(s) still unanswered after {d}ms — they were cut " ++
                    "off. Pass `.shutdown_grace_ms = …` to listen() if handlers need longer.",
                .{ busy, grace_ms },
            );
            return;
        }
        if (waited == 0) std.log.info(
            "nilo stopping: {d} request(s) still being answered, waiting up to {d}ms",
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
/// is (ADR 001): getting randomness is a syscall, and a syscall made
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
/// handler holding one still testable as an ordinary function (ADR 002).
pub const Mutex = zio.Mutex;

/// Parked fibers waiting on a `Mutex`, woken oldest first: `signal` pops the
/// head of a FIFO queue, and a waiter `signal` has claimed never reports a
/// timeout — it takes the signal instead. Both are what `Gate` builds its
/// arrival order on (ADR 222).
pub const Condition = zio.Condition;

/// `cond.wait(mutex)` for at most `ms`, with the mutex held again on every
/// return. `error.TimedOut` only when no `signal` claimed this waiter first.
pub fn waitWithin(cond: *Condition, mutex: *Mutex, ms: u64) error{ Canceled, TimedOut }!void {
    cond.waitTimeout(mutex, .{ .duration = .fromMilliseconds(ms) }) catch |err| switch (err) {
        error.Timeout => return error.TimedOut,
        error.Canceled => return error.Canceled,
    };
}

/// Run a blocking call on the Engine's thread pool, parking this fiber
/// until it comes back, so the other fibers sharing this thread keep
/// running (ADR 013).
///
/// Allocates nothing — the arguments and the result live on the calling
/// fiber's stack. Outside a fiber the call simply runs inline, which is
/// what keeps a handler that uses it testable as an ordinary function.
pub const blocking = zio.blockInPlace;

/// `blocking` with a worker guaranteed: an idle one, or a new one even past
/// the pool's `max_threads`, so the call never waits in the queue behind a
/// job already running (zio#745).
pub const blockingReserved = zio.blockInPlaceReserved;

/// Let the other fibers on this thread run before this one goes on, and
/// return at once where there is nothing to switch to. **A yield is a
/// cancellation point:** zio checks for a cancel when it switches and consumes
/// it, so a caller that swallowed the error would lose the one cancel a stop
/// sends it. Every caller passes `error.Canceled` on.
pub fn yield() error{Canceled}!void {
    try zio.yield();
}

/// Writes and waits made between `beginShield` and `endShield` are not
/// cancelled: how a connection that was cancelled at shutdown still says what
/// it owes its peer, once, before it goes (ADR 260). Outside a fiber, nothing.
pub fn beginShield() void {
    zio.beginShield();
}

pub fn endShield() void {
    zio.endShield();
}

/// Wait, without stopping the thread. `error.Canceled` if the request was
/// cancelled while waiting — the same failure `Mutex.lock` has, and it maps
/// to a 503 already.
///
/// Outside a fiber this really does sleep, rather than returning at once,
/// so a test measuring a timeout still measures one.
pub fn sleep(ms: u64) error{Canceled}!void {
    return zio.sleep(.fromMilliseconds(ms));
}

// ---- files (see ADR 009) ----
//
// The four calls the Bulkhead asks for, and nothing else. zio drives all of
// them through the event loop, so a request opening a file parks its fiber
// instead of stopping the thread — and outside a running server they fall
// through to the blocking path, which is what keeps a handler that answers
// with a file testable as an ordinary function.
//
// Wrappers rather than `pub const Dir = zio.Dir`, because zio's Dir also
// creates, deletes, renames and iterates. Re-exporting it would quietly
// make all of that the contract a second Engine has to meet.

/// A directory, held open. Everything is opened relative to it.
pub const Dir = struct {
    _dir: zio.Dir,

    pub fn open(path: []const u8) !Dir {
        return .{ ._dir = try zio.Dir.cwd().openDir(path, .{}) };
    }

    pub fn close(self: Dir) void {
        self._dir.close();
    }

    /// `openat` against this directory's descriptor.
    ///
    /// `allow_directory = false` costs an `fstat` on POSIX and is worth it:
    /// a directory opened as a file has a size that means nothing, and the
    /// alternative to refusing it here is a response whose `Content-Length`
    /// promises bytes that no read will produce.
    pub fn openFile(self: Dir, name: []const u8) !File {
        return .{ ._file = try self._dir.openFile(name, .{ .allow_directory = false }) };
    }

    /// `openFile` that refuses a symlink in the last component: `O_NOFOLLOW`
    /// on POSIX, which fails with `error.SymLinkLoop` and leaves no window
    /// between a check and the open, because the kernel does both.
    pub fn openFileNoFollow(self: Dir, name: []const u8) !File {
        return .{ ._file = try self._dir.openFile(name, .{
            .allow_directory = false,
            .follow_symlinks = false,
        }) };
    }

    /// Write `bytes` to `name` inside this directory, replacing what was
    /// there, and leave nothing half-written behind if the write fails.
    ///
    /// A randomly named file next to the destination takes the bytes and one
    /// rename puts it in place, so a reader of `name` — `sendFile`, a minute
    /// later, in this same server — sees the file it had or the file it now
    /// has, and never the truncated one that an open-and-write leaves visible
    /// for the length of the write
    /// ([ADR 097](../../docs/adr/097-a-file-is-written-by-the-engine.md)).
    ///
    /// Driven by the runtime exactly as `openFile` is: zio routes a
    /// descriptor the loop cannot poll to its own thread pool rather than
    /// issuing the call on the loop thread, so the fiber parks and the
    /// executor goes on serving the other connections it holds.
    pub fn writeFileAtomic(self: Dir, name: []const u8, bytes: []const u8) !void {
        var atomic = try self._dir.createAtomicFile(name, .{});
        // Removes the temporary file, including on the path where the fiber
        // is cancelled — after `replace` there is nothing left to remove.
        defer atomic.deinit();

        // Nothing to buffer: every byte is already here, and this runs on a
        // stack the connection holds for as long as it lives (ADR 062).
        var no_buffer: [0]u8 = .{};
        var out = atomic.file.stdWriter(&no_buffer);
        try out.interface.writeAll(bytes);
        try out.interface.flush();

        try atomic.replace();
    }
};

/// What a file is, as of one look at its descriptor.
///
/// Declared here beside `Peer` rather than in the Bulkhead, for the reason
/// `Peer` is: it never reaches a user, so nothing about it is part of what
/// swapping the Engine would change under one.
pub const Stat = struct {
    size: u64,
    /// Nanoseconds since the epoch, and signed because a clock is allowed to
    /// say anything — including a time before 1970.
    mtime_ns: i64,
};

/// One open file.
pub const File = struct {
    _file: zio.File,

    /// What this descriptor says the file is right now — its length and when
    /// it last changed. One call rather than a `size` and a second question
    /// later, because the two numbers are only worth anything together: the
    /// caller writing a `Content-Length` is also writing the ETag beside it,
    /// and two calls could describe two different files (ADR 098).
    ///
    /// Everything the caller wants is already in the one `statx` the kernel
    /// answers with, so asking for both costs exactly what asking for the
    /// size alone used to.
    pub fn stat(self: File) !Stat {
        const info = try self._file.stat();
        return .{ .size = info.size, .mtime_ns = info.mtime };
    }

    pub fn close(self: File) void {
        self._file.close();
    }

    /// std's reader over this file, bound to zio's `std.Io`. Reads through
    /// it still go through the runtime; what is standard is the type, which
    /// is what `std.Io.Writer.sendFileAll` insists on.
    pub fn reader(self: File, buffer: []u8) std.Io.File.Reader {
        return self._file.stdReader(buffer);
    }
};

// ---- work that is not a request (see ADR 028) ----
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
// wrong shutdown. Nothing in nilo does that today and `listen` is the
// only caller; if that changes, this is the line that has to move into
// the state `serve` already carries.
var background: std.atomic.Value(?*zio.Group) = .init(null);

/// The Runtime of the server that is running, for `serverIo`. A pointer to
/// the Runtime rather than a stored `std.Io`, so the read is one atomic load
/// and the `Io` is built from it on the way out; nothing is held per
/// connection (ADR 017).
var serving: std.atomic.Value(?*zio.Runtime) = .init(null);

/// The `std.Io` the running server's fibers run on, or null when no server
/// is running (a unit test, a `Client` driving an App). Readable from a
/// fiber and from a pool thread alike, which a lookup of the current
/// executor would not be: a handler handed to `nilo.blocking` runs on a
/// thread that has none.
pub fn serverIo() ?std.Io {
    const rt = serving.load(.acquire) orelse return null;
    return rt.io();
}

/// Start `func` in a fiber of its own, owned by the running server.
///
/// `error.NoServer` if there is no server running, which is what a unit
/// test calling a handler directly gets — the caller decides whether that
/// is a failure or a no-op.
pub fn spawn(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
    const group = background.load(.acquire) orelse return error.NoServer;
    return group.spawn(func, args);
}

/// `spawn`, on the executor of the fiber that calls it rather than the next
/// one round-robin. For work whose answer goes back to the fiber that
/// started it, where round-robin sends it to another thread and the answer
/// back again: a gRPC call spawned from its connection is 2.7x the calls a
/// second this way (ADR 220). Round-robin where tasks work steal, which an
/// application's own `zio_options` can ask for, because there a task has no
/// executor to stay on and zio refuses `.local`.
pub fn spawnLocal(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
    const group = background.load(.acquire) orelse return error.NoServer;
    return group.spawnInto(.local, func, args) catch |err| switch (err) {
        error.InvalidPlacement => group.spawn(func, args),
        else => err,
    };
}

/// `spawnLocal` that says so when the work could not be kept on the calling
/// executor (`error.InvalidPlacement`, work stealing), instead of dealing it
/// round-robin: for a caller whose reuse of a fiber depends on the next
/// stream running on the same thread (ADR 260).
pub fn spawnLocalExact(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
    const group = background.load(.acquire) orelse return error.NoServer;
    return group.spawnInto(.local, func, args);
}

// ---- the per-request slot (see ADR 006) ----
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

/// Whether `io` is this Engine's loop. Code handed an `Io` that must bind a
/// slot asks this first: `bindSlot` panics off a task, and `App.start(io)`
/// is handed `std.Io.Threaded` by every test that boots an App directly.
pub fn bindsOn(io: std.Io) bool {
    return zio.Runtime.fromIo(io) != null;
}

/// The slot of the fiber currently running, or null if there is no fiber
/// (a unit test calling App directly, for instance).
pub fn slot() ?*anyopaque {
    return fiber_slot.get();
}

/// When the run loop of the executor this fiber runs on last began a turn, as
/// nanoseconds of `CLOCK_MONOTONIC`, or null off a fiber (a pool thread, a
/// test with no server) or before the first turn.
///
/// **This is the signal that tells a park from a hold** (ADR 013). zio writes
/// the stamp once per turn of its run loop, after the poll and before the
/// batch of ready fibers, and a turn cannot end while a fiber is running, so a
/// stamp newer than the moment a stretch began means the fiber parked in
/// between, whatever it waited on: `std.Io.Event`, a `Queue`, a socket of a
/// service the Bulkhead never heard of. It costs the run loop nothing, because
/// zio writes the field for its own scheduling, and the fiber nothing, because
/// the watchdog reads it only for a stretch already past its limit.
///
/// zio does not export `Executor`, so the field is reached through the type of
/// `Runtime.executors`. `noinline` for the reason zio's own accessor is: a
/// threadlocal read must not be cached across a context switch. A fiber is
/// pinned here, so the answer could not differ, but the property is cheap to
/// keep and costly to find out about later.
pub noinline fn loopTurnNanos() ?u64 {
    const Executor = @typeInfo(@typeInfo(@TypeOf(@as(zio.Runtime, undefined).executors.items)).pointer.child).pointer.child;
    const exec = Executor.current_DO_NOT_ACCESS_DIRECTLY orelse return null;
    const at: u64 = @intCast(exec.tick_started_at.toNanoseconds());
    return if (at == 0) null else at;
}

const testing = std.testing;

fn ip6Text(buf: *[Peer.max_text]u8, groups: [8]u16) []const u8 {
    var bytes: [16]u8 = undefined;
    for (groups, 0..) |g, i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], g, .big);
    var w: std.Io.Writer = .fixed(buf);
    writeIp6(&w, bytes);
    return buf[0..w.end];
}

test "a stop signal after a programmatic shutdown is still the first one" {
    // The shutdown call sets the same flag a signal does, so reading it back
    // made the first SIGTERM after a shutdown look like the second and
    // exit(130) with the grace period unspent.
    var stop: Stop = .{};
    var seen: std.atomic.Value(bool) = .init(false);

    stop.request();
    try testing.expectEqual(StopSignal.graceful, stopSignalSeen(&stop, &seen));
    try testing.expectEqual(StopSignal.exit_now, stopSignalSeen(&stop, &seen));

    // And with no shutdown first, the same two steps.
    var fresh: Stop = .{};
    var fresh_seen: std.atomic.Value(bool) = .init(false);
    try testing.expectEqual(StopSignal.graceful, stopSignalSeen(&fresh, &fresh_seen));
    try testing.expect(fresh.isRequested());
    try testing.expectEqual(StopSignal.exit_now, stopSignalSeen(&fresh, &fresh_seen));
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

test "a path is read as a path only when it says unix:" {
    try testing.expectEqualStrings("/run/nilo.sock", unixPathIn("unix:/run/nilo.sock").?);
    // Nothing that used to work is read differently: no IPv4 or IPv6 address
    // starts with a letter and a colon.
    try testing.expect(unixPathIn("127.0.0.1") == null);
    try testing.expect(unixPathIn("::1") == null);
    try testing.expect(unixPathIn("0.0.0.0") == null);
    // Said, rather than guessed at: an empty path is refused by `listenOnUnix`
    // with a sentence, not treated as an address.
    try testing.expectEqualStrings("", unixPathIn("unix:").?);
}

test "`.tls` is refused, in words, by a build without it and by a listener on a socket file" {
    // The decision, apart from the line it prints: the line is an error log,
    // and an error log inside a test is a failed test whatever it says.
    try testing.expectEqual(@as(?TlsRefusal, null), tlsRefusal(false, false, false));
    try testing.expectEqual(@as(?TlsRefusal, null), tlsRefusal(true, true, false));
    try testing.expectEqual(@as(?TlsRefusal, .not_built), tlsRefusal(false, true, false));
    try testing.expectEqual(@as(?TlsRefusal, .on_unix_socket), tlsRefusal(true, true, true));
    // Both wrong: the one that is wrong on every build is the one said.
    try testing.expectEqual(@as(?TlsRefusal, .on_unix_socket), tlsRefusal(false, true, true));
    // And both are errors `listen()` stops the process on, having explained.
    try testing.expect(explained(TlsRefusal.not_built.toError()));
    try testing.expect(explained(TlsRefusal.on_unix_socket.toError()));
    try testing.expect(explained(error.TlsCertificate));
}

test "a certificate that is not there is an error, and the suite's own loads with its key" {
    if (!nilo_build.tls) return error.SkipZigTest;
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expectError(error.FileNotFound, readCertKeyPair(gpa, io, "http/testdata/tls/no-such.pem", "http/testdata/tls/localhost-key.pem"));
    // The suite's own pair parses, and the key is the ECDSA one the fixture
    // was made with, so the signing key pair is derived once here rather
    // than on every handshake.
    var pair = try readCertKeyPair(gpa, io, "http/testdata/tls/localhost.pem", "http/testdata/tls/localhost-key.pem");
    defer pair.deinit(gpa);
    try testing.expect(pair.ecdsa_key_pair != null);
}

test "a key that is not the certificate's is caught at listen rather than by the first client" {
    if (!nilo_build.tls) return error.SkipZigTest;
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The pair every deployment means to have.
    var own = try readCertKeyPair(gpa, io, "http/testdata/tls/localhost.pem", "http/testdata/tls/localhost-key.pem");
    defer own.deinit(gpa);
    try testing.expect(keyIsTheCertificates(own));

    // `other-key.pem` is a second P-256 key, so what is caught here is the
    // key and not the curve or the file format: both files parse,
    // `fromFilePath` returns happily, and the handshakes are what fail
    // (ADR 212).
    var stranger = try readCertKeyPair(gpa, io, "http/testdata/tls/localhost.pem", "http/testdata/tls/other-key.pem");
    defer stranger.deinit(gpa);
    try testing.expect(!keyIsTheCertificates(stranger));
}

test "only a socket is ever taken away" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);

    // A regular file. This is the case that decides the shape: unlinking
    // whatever happens to be at a path somebody typed is how a server deletes
    // their database.
    const file_path = try std.fmt.allocPrint(gpa, "{s}/not-a-socket", .{dir});
    defer gpa.free(file_path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "not-a-socket", .data = "keep me" });
    try testing.expect(!isStaleSocket(gpa, file_path));

    // A directory.
    try testing.expect(!isStaleSocket(gpa, dir));

    // Nothing at all — the ordinary first start.
    const absent = try std.fmt.allocPrint(gpa, "{s}/never-existed", .{dir});
    defer gpa.free(absent);
    try testing.expect(!isStaleSocket(gpa, absent));

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const sock_path = try std.fmt.allocPrint(gpa, "{s}/live.sock", .{dir});
    defer gpa.free(sock_path);
    const addr = try std.Io.net.UnixAddress.init(sock_path);

    // And a socket, which is the only thing that gets as far as the second
    // question.
    var live = try addr.listen(io, .{});
    try testing.expect(looksLikeSocket(gpa, sock_path));
    live.socket.close(io);
    // Closing the descriptor does not remove the path. That is the whole of
    // the problem this solves.
    try testing.expect(looksLikeSocket(gpa, sock_path));

    std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};
}

test "a socket somebody is listening on is left where it is" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sock_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/busy.sock", .{tmp.sub_path});
    defer gpa.free(sock_path);

    // The second question needs the loop, because the only way to ask whether
    // a socket is alive is to connect to it. `serve` has a Runtime up by the
    // time it asks; this stands one up for the same reason.
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();

    const addr = try zio.net.UnixAddress.init(sock_path);
    const live = try addr.listen(.{});
    // Two servers pointed at one path is a mistake worth being told about,
    // not one to resolve by taking the socket off whoever got there first.
    try testing.expect(!isStaleSocket(gpa, sock_path));

    // With nobody behind it, the same path is a leftover — every restart
    // during development.
    live.close();
    try testing.expect(isStaleSocket(gpa, sock_path));

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().deleteFile(threaded.io(), sock_path) catch {};
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
    // What nilo did before `max_connections` existed, and what setting it
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

test "threads left at 0 are the cores this process may use, and never more than the engine runs" {
    const auto = threadCount(.{ .threads = @as(u8, 0) });
    try testing.expect(auto >= 1);
    try testing.expect(auto <= max_threads);
    try testing.expect(auto <= (std.Thread.getCpuCount() catch auto));
    try testing.expectEqual(@as(u8, 3), threadCount(.{ .threads = @as(u8, 3) }));
    // Past the engine's limit is held to it, rather than asserted on.
    try testing.expectEqual(@as(u8, max_threads), threadCount(.{ .threads = @as(u8, 200) }));
}

test "a CPU quota is one thread more than the quota, and never more than the cores" {
    try testing.expectEqual(@as(usize, 16), autoThreads(16, null));
    try testing.expectEqual(@as(usize, 2), autoThreads(16, 1000));
    try testing.expectEqual(@as(usize, 2), autoThreads(16, 500));
    try testing.expectEqual(@as(usize, 3), autoThreads(16, 1500));
    try testing.expectEqual(@as(usize, 3), autoThreads(16, 2000));
    try testing.expectEqual(@as(usize, 4), autoThreads(16, 2001));
    try testing.expectEqual(@as(usize, 5), autoThreads(16, 4000));
    // A quota as large as the machine is no quota.
    try testing.expectEqual(@as(usize, 4), autoThreads(4, 4000));
    try testing.expectEqual(@as(usize, 1), autoThreads(1, 2000));
}

test "cpu.max and the v1 pair read as CPUs, and no limit reads as none" {
    try testing.expectEqual(@as(?u64, 2000), parseCpuMax("200000 100000\n"));
    try testing.expectEqual(@as(?u64, 1500), parseCpuMax("150000 100000"));
    // A third of a CPU rounds up, never down to a quota it is over.
    try testing.expectEqual(@as(?u64, 334), parseCpuMax("100000 300000"));
    try testing.expectEqual(@as(?u64, null), parseCpuMax("max 100000\n"));
    try testing.expectEqual(@as(?u64, null), parseCpuMax(""));
    try testing.expectEqual(@as(?u64, null), parseCpuMax("200000"));
    try testing.expectEqual(@as(?u64, null), parseCpuMax("200000 0"));
    try testing.expectEqual(@as(?u64, 500), parseCfs("50000\n", "100000\n"));
    try testing.expectEqual(@as(?u64, null), parseCfs("-1\n", "100000\n"));
}

test "the cgroup is read from its own line and walked up to the root" {
    try testing.expectEqualStrings("/user.slice/app.scope", unifiedPath("0::/user.slice/app.scope\n").?);
    // A hybrid host lists v1 controllers before the unified line.
    try testing.expectEqualStrings("/foo", unifiedPath("3:cpu,cpuacct:/foo\n0::/foo\n").?);
    // In a container with its own namespace, the cgroup is the root.
    try testing.expectEqualStrings("", unifiedPath("0::/\n").?);
    try testing.expectEqual(@as(?[]const u8, null), unifiedPath("3:cpu,cpuacct:/foo\n"));

    try testing.expectEqualStrings("/a", parentCgroup("/a/b").?);
    try testing.expectEqualStrings("", parentCgroup("/a").?);
    try testing.expectEqual(@as(?[]const u8, null), parentCgroup(""));
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

test "a Wake that parked hands its completions back before its frame goes" {
    // The guard for ADR 077. A `Wake` lives in the connection fiber's frame
    // and the loop keeps a pointer to every completion submitted to it, so a
    // frame that returns with either half still submitted leaves the loop
    // writing into memory that has been handed on. What that cost was a
    // SIGTERM the server did not come back from, three runs in four.
    //
    // `Runtime.init` makes this thread an executor, which is what lets a test
    // submit at all — the same shape zio's own `completion_queue.zig` tests
    // use. Port 0, so the kernel picks one and this joins no range of its own
    // (see roadmap, "Three test files pick loopback ports").
    var rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 0);
    const listener = try addr.listen(.{});
    defer listener.close();

    var wake = Wake.init(listener.socket.handle);
    try testing.expect(wake.cq.isEmpty());

    // Nobody connects, so the socket never becomes readable: this parks and
    // times out with both halves submitted, which is exactly the state an
    // ordinary WebSocket is in when its client goes away.
    try testing.expectEqual(Woken.timed_out, wake.wait(5));
    try testing.expect(wake.armed);
    try testing.expect(wake.poll_armed);
    try testing.expect(!wake.cq.isEmpty());

    // The line the whole ADR is about. Without it the two assertions below
    // fail and the loop is left holding this frame.
    wake.deinit();
    try testing.expect(wake.cq.isEmpty());
    try testing.expect(!wake.cq.hasPending());

    // Safe twice, because a fiber cancelled mid-wait has already had zio
    // cancel and drain the queue underneath it.
    wake.deinit();
    try testing.expect(wake.cq.isEmpty());
}

test "two listeners asking for one address is a refusal, and two asking for port 0 is not" {
    // The decision, apart from the line it prints: the line is an error log,
    // and an error log inside a test is a failed test whatever it says.

    // The same address and the same port, which is the mistake `also` makes
    // possible and the kernel would blame on another process.
    try testing.expect(sameListener("127.0.0.1", 8080, false, "127.0.0.1", 8080));

    // Different ports on one interface is the whole point of the option.
    try testing.expect(!sameListener("127.0.0.1", 8081, false, "127.0.0.1", 8080));

    // Different interfaces on one port is a server with two homes, which is
    // legitimate and is not this function's business to refuse: the kernel
    // takes both.
    try testing.expect(!sameListener("127.0.0.1", 8080, false, "0.0.0.0", 8080));

    // **Two listeners that both asked the kernel to choose are two ports.**
    // The one already bound reports the number it was given, and the one
    // asking still says 0, so they differ and neither is refused. A test is
    // the caller that does this.
    try testing.expect(!sameListener("127.0.0.1", 0, false, "127.0.0.1", 54321));

    // A path has no port, so the path alone decides. The same one twice is
    // a refusal whatever number rides along.
    try testing.expect(sameListener("unix:/run/nilo.sock", 0, true, "unix:/run/nilo.sock", 0));
    try testing.expect(!sameListener("unix:/run/one.sock", 0, true, "unix:/run/two.sock", 0));
}

// Also the check on `zioFor` in `build.zig`: a zio built without `.pinned`
// works steal, `spawnLocal` falls back to round-robin there, and the
// children below land on other threads.
test "a fiber spawned local runs on the thread that spawned it" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(4) });
    defer rt.deinit();

    const H = struct {
        fn child(want: std.Thread.Id, wrong: *std.atomic.Value(u32)) void {
            if (std.Thread.getCurrentId() != want) _ = wrong.fetchAdd(1, .monotonic);
        }

        fn parent(wrong: *std.atomic.Value(u32)) !void {
            var group: zio.Group = .init;
            defer group.cancel();
            background.store(&group, .release);
            defer background.store(null, .release);
            for (0..16) |_| try spawnLocal(child, .{ std.Thread.getCurrentId(), wrong });
            try group.wait();
        }
    };

    var wrong: std.atomic.Value(u32) = .init(0);
    var handle = try rt.spawn(H.parent, .{&wrong});
    try handle.join();
    try testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
}

// zio's pool left at its defaults, which this test keeps, starts no second
// worker until twice as many jobs wait as run, so behind one held worker a
// plain `blocking` call queues; `blocking_pool` is what `serve` runs instead. The holder
// gives up after two seconds: a call that queued fails this test by
// setting `gave_up` rather than hanging it.
test "a reserved blocking call gets a thread while the pool's only worker is held" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();

    const Flags = struct {
        started: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),
        gave_up: std.atomic.Value(bool) = .init(false),
    };

    const H = struct {
        fn hold(f: *Flags) void {
            f.started.store(true, .release);
            const until = monotonicNanos() + 2 * std.time.ns_per_s;
            while (!f.released.load(.acquire)) {
                if (monotonicNanos() > until) return f.gave_up.store(true, .release);
                std.Thread.yield() catch {};
            }
        }

        fn release(f: *Flags) void {
            f.released.store(true, .release);
        }

        fn holder(f: *Flags) void {
            blocking(hold, .{f});
        }

        fn caller(f: *Flags) !void {
            var waited: u32 = 0;
            while (!f.started.load(.acquire)) : (waited += 1) {
                if (waited == 2000) return error.HolderNeverStarted;
                try sleep(1);
            }
            blockingReserved(release, .{f});
        }
    };

    var flags: Flags = .{};
    var held = try rt.spawn(H.holder, .{&flags});
    var called = try rt.spawn(H.caller, .{&flags});
    try called.join();
    held.join();
    try testing.expect(flags.released.load(.acquire));
    try testing.expect(!flags.gave_up.load(.acquire));
}

// The same shape with a plain `blocking` call: a short call made while one
// long one holds the pool's only worker. A pool that starts no worker for
// it leaves it queued until the long one ends, which is what a WAL write
// behind a compaction pass met in a port of a log server (2 ms of work
// queued for up to 1.9 s). The holder gives up after two seconds, so a
// queued call fails this test rather than hanging it.
test "a short blocking call gets a thread while a long one holds the pool's only worker" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1), .thread_pool = blocking_pool });
    defer rt.deinit();

    const Flags = struct {
        started: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),
        gave_up: std.atomic.Value(bool) = .init(false),
    };

    const H = struct {
        fn hold(f: *Flags) void {
            f.started.store(true, .release);
            const until = monotonicNanos() + 2 * std.time.ns_per_s;
            while (!f.released.load(.acquire)) {
                if (monotonicNanos() > until) return f.gave_up.store(true, .release);
                std.Thread.yield() catch {};
            }
        }

        fn release(f: *Flags) void {
            f.released.store(true, .release);
        }

        fn holder(f: *Flags) void {
            blocking(hold, .{f});
        }

        fn caller(f: *Flags) !void {
            var waited: u32 = 0;
            while (!f.started.load(.acquire)) : (waited += 1) {
                if (waited == 2000) return error.HolderNeverStarted;
                try sleep(1);
            }
            blocking(release, .{f});
        }
    };

    var flags: Flags = .{};
    var held = try rt.spawn(H.holder, .{&flags});
    var called = try rt.spawn(H.caller, .{&flags});
    try called.join();
    held.join();
    try testing.expect(flags.released.load(.acquire));
    try testing.expect(!flags.gave_up.load(.acquire));
}
