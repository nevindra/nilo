//! An Engine built on zio (https://github.com/lalinsky/zio).
//!
//! The only file in nilo allowed to name zio. See ADR 0002.

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
    /// This connection came in over a unix socket, so it has no address at
    /// all and nothing remote could have opened it.
    ///
    /// Both halves matter to `Ctx.clientIp`. There is no address to return,
    /// and the machine on the other end is this one — which is what the
    /// named-network rules are trying to establish about a proxy over
    /// loopback, and can establish here without a rule at all (ADR 0130).
    local: bool = false,

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
/// Every connection costs a measured 4,669 bytes before it has asked for
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
    /// 0 means no limit, which is what nilo did before this existed.
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
/// would print a stack trace through nilo on top of it (ADR 0002 — the
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
/// The names are plain on purpose: the Bulkhead is what turns nilo's
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
    /// the only place nilo asks, and then the connection is closed.
    pub fn timedOut(self: *const Clocks) bool {
        if (self.reader.err) |err| if (err == error.Timeout) return true;
        if (self.writer.err) |err| if (err == error.Timeout) return true;
        return false;
    }
};

/// Bounding an operation that is **not** a read or a write on a connection
/// nilo holds — an outbound call by a Service, where the socket belongs to a
/// driver and there is nothing here to set a timeout on
/// (ADR 0071).
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
/// per-connection numbers in ADR 0018 as small as they are, and it is exactly
/// what a broadcast cannot live with — a connection sitting in a read cannot
/// be told anything until whoever is on the other end happens to speak.
///
/// ADR 0029 measured the alternative and rejected it: a second fiber per
/// connection to do the writing, 8,673 bytes each, against a whole-connection
/// budget that was 8,767 at the time and is 4,669 since ADR 0071 — so the
/// alternative reads worse now than it did then, not better. It named this
/// shape as the right one and recorded it as
/// unreachable, because zio exported no way to park on a completion. It does
/// — `zio.CompletionQueue` is public in the pinned v0.17.0 — and
/// `spike/completion_queue/` holds the cancel path and the re-arm to 630 runs
/// across three optimize modes.
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
    cq: zio.CompletionQueue,
    wake: zio.ev.Async,
    poll: zio.ev.NetPoll,
    /// The post half. Submitted once and re-submitted the moment it fires,
    /// because a notify carries no data that anybody has to read first.
    armed: bool = false,
    /// The readable half, which is **not** re-submitted on the way out — see
    /// `wait`. Separate from `armed` because handing a completion that is
    /// already submitted back to `submit` crashes zio (zio#673), so the two
    /// halves cannot share one flag once they stop being re-armed together.
    poll_armed: bool = false,

    pub fn init(handle: zio.ev.Backend.NetHandle) Wake {
        return .{
            .cq = zio.CompletionQueue.init(),
            .wake = zio.ev.Async.init(),
            // `NetPoll` rather than `NetRecv`, which is the exception zio's
            // author named when he said to prefer the latter: the connection's
            // buffered `std.Io.Reader` does its own reading, so what is wanted
            // here is readiness, not bytes. Level-triggered, so data left
            // unread simply fires again — which is correct, because the caller
            // reads on every `.readable`.
            .poll = zio.ev.NetPoll.init(handle, .recv),
        };
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
        if (!self.armed) {
            self.cq.submit(&self.wake.c);
            self.armed = true;
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
        if (!self.poll_armed) {
            self.cq.submit(&self.poll.c);
            self.poll_armed = true;
        }

        while (true) {
            // The limit belongs to the wait, not to the connection: it is
            // measured from *this* call, so a client that spoke a moment ago
            // gets a full stretch of silence before anybody asks after it.
            // `CompletionQueue` carries this already, which is why there is no
            // timer completion here to arm, cancel and re-arm.
            const done = (self.cq.timedWait(if (limit_ms == 0)
                .none
            else
                .{ .duration = .fromMilliseconds(limit_ms) }) catch |err| {
                return if (err == error.Timeout) .timed_out else .closed;
            }) orelse return .closed;

            // Rebuilding only the completion, never the handle around it.
            // Handing a fired completion straight back to `submit` crashes
            // zio 90 runs in 90 (zio#673, fix in flight as zio#674), and
            // rebuilding the *whole* `Async` clears the `pending` flag that
            // holds a notify landing in this window — 30 runs in 30 in the
            // spike's `--window` mode. `pending` belongs to `Async`, the
            // phase belongs to `Completion`, and only one of them needs
            // resetting.
            if (done == &self.wake.c) {
                self.wake.c = .init(.async);
                self.cq.submit(&self.wake.c);
                return .posted;
            }
            if (done == &self.poll.c) {
                self.poll.c = .init(.net_poll);
                self.poll_armed = false;
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
    /// That is where the SIGTERM nobody came back from was: an executor
    /// thread at 100% with no syscall outstanding, and no plain HTTP
    /// connection ever affected because nothing but a WebSocket arms either
    /// half. `bench/shutdown.py` at 24 connections a run puts it at **23 of
    /// 25 without this call and 0 of 25 with it**. zio's own
    /// `CompletionQueue` test cancels after a timeout for exactly this
    /// reason — the queue owns pointers the loop is using, and the owner has
    /// to say when it is done with them.
    ///
    /// Nothing to do for a connection that never waited, which is every
    /// ordinary request: a branch, no lock and no syscall.
    pub fn deinit(self: *Wake) void {
        if (!self.armed and !self.poll_armed) return;
        // `cancel` drains with cancellation disabled, so this finishes even
        // when the fiber is being cancelled — which is the case that matters,
        // since that is what shutdown does to a WebSocket that is still up.
        self.cq.cancel();
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

/// Hand back the pages of the *running* fiber's stack that are below its
/// current frame.
///
/// A suspended fiber holds its stack at the high-water mark it ever reached,
/// for the life of the connection, one byte for one byte
/// ([ADR 0063](../../docs/adr/0063-a-handlers-stack-is-per-connection.md)).
/// The frames that took it there have long since returned; the pages have not.
///
/// **ADR 0063 recorded this as blocked on zio and it never was.** It looked for
/// the running fiber through `runtime.getCurrentTaskOrNull`, which is not
/// re-exported, and concluded there was no supported way. There is, by another
/// door: `zio.coro.Coroutine.getCurrent()` is public in the pinned v0.17.0 and
/// carries `context.stack_info`, which is `base` and `limit`. The upstream ask
/// ([zio#677](https://github.com/lalinsky/zio/issues/677)) was answered by
/// pointing at it.
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

    return addr.listen(.{ .reuse_address = options.reuse_address }) catch |err| {
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

/// The same for a path. `port` is not read at all — there is nowhere for a
/// port to go on a unix socket, and pretending otherwise would put a number
/// in the log line that means nothing.
fn listenOnUnix(
    gpa: std.mem.Allocator,
    path: []const u8,
    reuse_address: bool,
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

    return addr.listen(.{}) catch |err| {
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

/// Run `handler(state, in, out, clocks, wake, peer)` for every accepted
/// connection, each in its own fiber, until that connection is done. The
/// Reader/Writer are already buffered; the handler does not need to know
/// there is a socket behind them. `handler` must be
/// `fn (@TypeOf(state), *std.Io.Reader, *std.Io.Writer, *Clocks, *Wake, Peer) void`.
///
/// `ready(state, io)` runs once, after the loop exists and the port is
/// taken, before the first connection is accepted. It is how something
/// that needs the event loop to exist gets built at all — a connection pool
/// is the case it was added for, and the loop is not there to hand out
/// until this function has started it (ADR 0040). `ready` must be
/// `fn (@TypeOf(state), std.Io) anyerror!void`.
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
) !void {
    const State = @TypeOf(state);
    const Options = @TypeOf(options);
    const threads: u8 = if (options.threads > 0)
        options.threads
    else
        @intCast(@min(std.Thread.getCpuCount() catch 1, 255));

    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(threads) });
    defer rt.deinit();

    // **Registered second, so it runs second to last** — after the group
    // below has cut off every connection, and before the Runtime is torn
    // down (ADR 0151). Both halves of that are load-bearing: a service put
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
    // zio's completion queue (ADR 0002 — the Engine is not the user's
    // business, in a crash log least of all).
    var why: StartupFailure = .other;

    // A path rather than a port: `.address = "unix:/run/nilo.sock"`. One
    // more spelling of the field that already says what to listen on, rather
    // than a field beside it — two fields would leave a third state, both
    // set, that means nothing (ADR 0130).
    const unix_path = unixPathIn(options.address);

    const maybe_server: ?zio.net.Server = if (unix_path) |path|
        listenOnUnix(gpa, path, options.reuse_address, &why)
    else
        listenOnIp(options, &why);
    const server = maybe_server orelse return why.toError();

    // Registered before the close, so it runs after it: the socket file is
    // this process's to take away, and one left behind is what makes the
    // next start fail.
    defer if (unix_path) |path| removeSocket(gpa, path);
    defer server.close();

    var group: zio.Group = .init;
    // Whatever is still running when the grace period is over is cut off
    // here. By then it has had its chance.
    defer group.cancel();

    // Registered after the cancel above, so it runs before it: nothing can
    // be spawned into a group that is already winding up (ADR 0029).
    //
    // **Above `ready` rather than below it** (ADR 0086). `ready` is where
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

    // After the port is taken, before anything is accepted, and before the
    // line below says the server is up — because until this returns it is
    // not. A pool that cannot reach its database explains itself and comes
    // back as an error here rather than as a surprise inside the first
    // request that needed it (ADR 0040). This runs on the thread that
    // called `serve`, which is already inside the loop: `accept` below is
    // waited on the same way, so anything `ready` does can wait too.
    try ready(state, rt.io());

    std.log.info("nilo listening on {f} across {d} thread(s)", .{ server.socket.address, threads });

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

            // A unix socket has no address, and nothing remote could have
            // opened it. Both of those matter below.
            const over_ip = stream.socket.address.getType() == .ip;

            // One response = one flush = one segment; Nagle would only add
            // latency without saving anything, so it is turned off.
            //
            // TCP only. On a unix socket the option is `EOPNOTSUPP`, and zio
            // answers an errno it does not recognise with a stack trace and an
            // invitation to file a bug — which `catch {}` does not swallow,
            // because it is printed before the error is returned. Once per
            // connection (ADR 0130).
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

            var reader = stream.reader(read_buf);
            var writer = stream.writer(write_buf);
            var clocks = Clocks{ .reader = &reader, .writer = &writer };

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
            };
            peer._len = writePeer(&peer._text, stream.socket.address);

            handler(st, &reader.interface, &writer.interface, &clocks, &wake, peer);
        }
    };

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
                    "nilo is holding its limit of {d} connections, so new ones are being closed " ++
                        "unanswered ({d} so far). Raise `.max_connections` in listen() if the " ++
                        "machine has the memory — an idle connection costs 4,669 bytes, plus " ++
                        "whatever stack the handler touches — or put fewer of them on this " ++
                        "process.",
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

/// A counting lock: N fibers through at once and the rest park.
///
/// A Mutex is this with N of 1, and the reason both are here is that the one
/// caller nilo has wants a number bigger than 1 and much smaller than the
/// blocking pool — see `http/password.zig` and ADR 0048.
///
/// Uncontended it takes the Mutex and nothing else, so a test driving an App
/// with no server running never reaches the fiber-parking half of it.
pub const Semaphore = zio.Semaphore;

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

// ---- files (see ADR 0037) ----
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

    /// Write `bytes` to `name` inside this directory, replacing what was
    /// there, and leave nothing half-written behind if the write fails.
    ///
    /// A randomly named file next to the destination takes the bytes and one
    /// rename puts it in place, so a reader of `name` — `sendFile`, a minute
    /// later, in this same server — sees the file it had or the file it now
    /// has, and never the truncated one that an open-and-write leaves visible
    /// for the length of the write
    /// ([ADR 0123](../../docs/adr/0123-a-file-is-written-by-the-engine.md)).
    ///
    /// Driven by the runtime exactly as `openFile` is: zio routes a
    /// descriptor the loop cannot poll to its own thread pool rather than
    /// issuing the call on the loop thread, so the fiber parks and the
    /// executor goes on serving the other connections it holds.
    pub fn writeFileAtomic(self: Dir, name: []const u8, bytes: []const u8) !void {
        var atomic = try self._dir.createFileAtomic(name, .{});
        // Removes the temporary file, including on the path where the fiber
        // is cancelled — after `replace` there is nothing left to remove.
        defer atomic.deinit();

        // Nothing to buffer: every byte is already here, and this runs on a
        // stack the connection holds for as long as it lives (ADR 0063).
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
    /// and two calls could describe two different files (ADR 0125).
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
// wrong shutdown. Nothing in nilo does that today and `listen` is the
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
    // The guard for ADR 0098. A `Wake` lives in the connection fiber's frame
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
