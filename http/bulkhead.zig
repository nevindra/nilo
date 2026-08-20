//! Bulkhead — the internal boundary between nilo and the Engine.
//!
//! Everything nilo needs from the Engine goes through this file. No part
//! of nilo outside `src/engine/` may name zio. Swapping the Engine means
//! swapping the one import below, without touching a line of user code.
//!
//! The contract an Engine has to meet:
//! - reading the fields of `Options` that name a socket, a buffer or a
//!   deadline. The struct itself is declared here, not by the Engine, so
//!   that swapping the Engine cannot change what a user writes.
//! - `serve(gpa, options, stop, state, ready, handler)` — listen, accept
//!   connections, and run `handler(state, in, out, deadlines, waker, peer)`
//!   for each one concurrently until that connection is done. `state` is
//!   carried through as-is (normally `*App`). Returns when `stop` is set.
//! - `ready(state, io, limits)` inside that call — run once, after the port
//!   is taken and before the first connection is accepted, and hand over the
//!   `std.Io` the Engine runs on. This is the one thing here that exists
//!   for a caller rather than for nilo: a connection pool cannot be built
//!   before `listen()`, because the event loop it has to dial through does
//!   not exist yet, and a pool built without one blocks the thread every
//!   request shares (ADR 0040). The type is std's, not zio's, so this hands
//!   out nothing that names the Engine.
//! - `Limits.arm`/`release`/`fired` — put a time limit on an operation that
//!   is *not* a read or write of a connection nilo holds, and say afterwards
//!   whether that limit is what cancelled it. `Deadlines` below covers
//!   inbound, where nilo owns the socket and can set a timeout on it;
//!   outbound the socket belongs to a driver, so the only thing left to bound
//!   is the unit of work itself. An Engine that cannot cancel an operation in
//!   flight can no longer meet this contract (ADR 0065). The type is
//!   `nilo_core`'s, because the caller is a Service and a Service may not
//!   import `nilo_http`.
//! - `Peer` — who is at the other end of a connection. `accept` already
//!   knows, so this asks the Engine for nothing it did not have.
//! - `Deadlines.limit`/`Deadlines.timedOut` — put a time limit on the next
//!   read or write of one connection, and say afterwards whether that limit
//!   is what a failure was. An Engine that waits on sockets already has to
//!   be able to wait with a limit, so this asks for nothing new of it
//!   (ADR 0023).
//! - `Waker.wait`/`Waker.post` — park a connection until its socket is
//!   readable *or* another fiber has something to say to it, and wake one
//!   from anywhere. Everything else in nilo is woken by the client at the
//!   other end, which is what makes a broadcast impossible without this. An
//!   Engine that waits on sockets can already wait on two things — it has to,
//!   to wait with a deadline at all — so this asks for nothing new of it
//!   beyond a handle to say so with.
//! - `Stop`/`explained` — the flag that ends `serve`, and which startup
//!   failures it has already explained in words.
//! - `debug_io` — wired into `std_options_debug_io` so that `std.log`
//!   does not block the event loop.
//! - `Binding`/`bindSlot`/`unbindSlot`/`slot` — one pointer bound to the
//!   unit of work currently running (a fiber, a thread, whatever the
//!   Engine uses), for hidden per-request state (ADR 0007).
//! - `monotonicNanos` — a monotonic clock. Zig 0.16's `std.time` carries
//!   only constants, and the Engine already keeps a clock, so the logger
//!   asks for it here rather than reaching for a syscall of its own.
//! - `Mutex` — a lock that parks the unit of work rather than the OS
//!   thread under it. Handlers run concurrently on several threads, so a
//!   Service with mutable state needs one; and `std.Thread.Mutex` is the
//!   wrong tool, because blocking the thread also stops every other fiber
//!   sharing it — including, possibly, the one holding the lock.
//! - `blocking`/`sleep` — the general form of that same problem. A handler
//!   that calls anything blocking stops every other request sharing its
//!   thread, and the Engine is the only layer that knows how to wait
//!   without doing that (ADR 0014).
//! - `Dir`/`File` — open a directory, open a file inside it by name, ask
//!   how big it is, close either. Four calls, and deliberately no fifth: no
//!   seek, no write, and nothing that walks a directory while a request is
//!   waiting on it. The list is that short because everything past it is
//!   already standard — the reader is a `std.Io.File.Reader` and the bytes
//!   leave through `sendFile`, which is a slot in the `std.Io.Writer`
//!   vtable the Engine fills in anyway — so an Engine that has a `std.Io`
//!   has these already and owes nothing it was not going to write
//!   (ADR 0037).
//!
//! The Reader/Writer handed to the handler are plain std types
//! (`*std.Io.Reader`, `*std.Io.Writer`), so the HTTP layer has no idea
//! which Engine is behind them.

const std = @import("std");
const builtin = @import("builtin");

const engine = @import("engine/zio.zig");
const watchdog = @import("watchdog.zig");

/// Re-exported so nothing above has to know that the type came from a layer
/// below rather than from here. It lives in `nilo_core` because a Service
/// holds one and a Service may not import `nilo_http` (ADR 0065).
pub const Limits = @import("nilo_core").Limits;

// The check ADR 0065 says this file owes. Core declares a fixed slot for the
// Engine's arming state and cannot measure what goes in it, because it may
// not name an Engine; this is the one place that can do both.
comptime {
    if (engine.limit_state_size > Limits.slot_size) @compileError(std.fmt.comptimePrint(
        "nilo: this Engine needs {d} bytes to arm an operation deadline and " ++
            "core.Limits.slot_size is {d}.\n  Raise slot_size in core/limits.zig to at least {d}.",
        .{ engine.limit_state_size, Limits.slot_size, engine.limit_state_size },
    ));
    if (engine.limit_state_align > Limits.slot_align) @compileError(std.fmt.comptimePrint(
        "nilo: this Engine arms an operation deadline at {d}-byte alignment and " ++
            "core.Limits.slot_align is {d}.\n  Raise slot_align in core/limits.zig.",
        .{ engine.limit_state_align, Limits.slot_align },
    ));
}

const engine_limits: Limits.VTable = .{
    .arm = struct {
        fn f(_: ?*anyopaque, state: *anyopaque, ms: u32) void {
            engine.armOperation(state, ms);
        }
    }.f,
    .release = struct {
        fn f(_: ?*anyopaque, state: *anyopaque) void {
            engine.releaseOperation(state);
        }
    }.f,
    .fired = struct {
        fn f(_: ?*anyopaque, state: *anyopaque) bool {
            return engine.firedOperation(state);
        }
    }.f,
};

/// What a Service is handed at startup. There is no `target`: the Engine arms
/// the fiber that is running, and it already knows which one that is.
pub const engine_limits_value: Limits = .{ .vtable = &engine_limits };

pub const debug_io = engine.debug_io;
pub const Peer = engine.Peer;

/// Everything `listen()` takes.
///
/// Declared here rather than in the Engine, even though most of it is the
/// Engine's to read: this is the struct a user writes by hand, and ADR 0002
/// promises the Engine can be swapped without touching user code. An
/// options struct owned by zio would have broken that promise the first
/// time zio was replaced. The Engine reads the fields it knows and never
/// names the rest.
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
    /// `nilo.Mutex` (ADR 0011). Set this to 1 and that stops being true —
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

    // ---- deadlines (ADR 0023) ----
    //
    // Zero turns any one of these off. All four off is what nilo did
    // before 0.1.0, and it meant a client could hold a fiber by opening a
    // connection and saying nothing.

    /// How long a client has to finish sending a request head, counted from
    /// its first byte. Not per read — for the whole head, which is what
    /// makes it a limit at all: a client dribbling one byte a second is
    /// inside any per-read limit and never finishes.
    ///
    /// Ten seconds is far more than a real client needs on a real link, and
    /// the cost of being wrong is a 408 to somebody on a bad connection who
    /// will retry.
    header_timeout_ms: u32 = 10_000,
    /// How long a connection may sit between one request and the next
    /// before it is closed.
    ///
    /// This is the number that decides how much memory idle clients hold —
    /// 4,669 bytes each, whatever the buffers are set to, because a connection
    /// that has gone quiet gives them back (ADR 0071) — so a server with many
    /// visitors and few of them active wants it lower than a server with a
    /// handful of chatty ones. Above what browsers hold a connection for on
    /// their own (Chrome and Firefox let go at around a minute), so in
    /// practice the client is normally the one that closes.
    idle_timeout_ms: u32 = 75_000,
    /// How long any single read of a request body may take.
    ///
    /// Per read, not for the whole body: how long a legitimate body takes
    /// depends on its size and the client's line, and a server cannot put a
    /// number on either in advance. A client that stops sending halfway
    /// through can be caught without guessing at that.
    body_timeout_ms: u32 = 30_000,
    /// How long any single write to the client may take.
    ///
    /// The answer to a client that asks for something and then stops
    /// reading: the socket's buffers fill, the next write blocks, and
    /// without this it blocks for as long as TCP takes to give up. It is
    /// also what bounds a server-sent event stream whose reader has walked
    /// away — the write fails, the handler gets an error, the fiber
    /// unwinds.
    write_timeout_ms: u32 = 30_000,

    /// The most connections this process holds at once. 0 means no limit.
    ///
    /// A connection costs a measured 4,669 bytes before it has asked for
    /// anything, so this number times five kilobytes is what the server
    /// may hold: the default is about 47 MB. That is the whole point of
    /// having it. Without a cap a server does not fail at a number
    /// somebody chose, it fails when the machine runs out, and what
    /// notices is the OOM killer — which takes the process down along with
    /// every request that was being answered correctly.
    ///
    /// Past it, a connection is accepted and closed at once: no request is
    /// read and no status is sent. A client finds out immediately, which
    /// is what lets a load balancer try another instance, and the log says
    /// so once a minute for as long as it lasts. Ten thousand is above
    /// what an ordinary service sees and below what a small machine
    /// minds; a server holding WebSockets open wants it raised, and the
    /// arithmetic above is how to decide by how much.
    ///
    /// It bounds connections, not requests. One connection makes many
    /// requests in a row, and a WebSocket is one connection for as long as
    /// the tab is open.
    max_connections: u32 = 10_000,

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

    // ---- what a request may do ----

    /// The most `Ctx.body()` will read into the request arena. Past it, a
    /// 413 that names `bodyStream()` as the way to take more.
    ///
    /// A megabyte is a JSON body's worth. It is deliberately not a file
    /// upload's worth: this body is held whole, in memory, per request, so
    /// raising it raises what a handful of concurrent clients can make the
    /// server hold. `bodyStream()` has no such ceiling because it holds
    /// nothing — it is bounded by the buffer the handler passes in.
    max_body: usize = 1024 * 1024,

    /// How many proxies stand in front of this server, for reading a
    /// client's address out of `X-Forwarded-For`.
    ///
    /// Zero — the default — means trust nothing: `Ctx.clientIp()` is the
    /// address the connection actually came from, and a header claiming
    /// otherwise is ignored. That is the only safe default, because
    /// `X-Forwarded-For` is a header like any other and anyone can send
    /// one.
    ///
    /// A count rather than a list of addresses, and counted from the right,
    /// which is what makes it hard to get wrong. Each proxy appends the
    /// address it heard from, so the rightmost entry was written by the
    /// proxy nearest this server and the leftmost is whatever the original
    /// client claimed. With one proxy in front, a client sending
    /// `X-Forwarded-For: 1.2.3.4` arrives as `1.2.3.4, 203.0.113.9` — and
    /// counting one from the right reads `203.0.113.9`, the address the
    /// proxy saw, while the forgery sits to the left and is never looked
    /// at. Set this to the number of proxies you run, not to the number of
    /// entries you have seen in the header.
    ///
    /// Fewer entries than hops means the chain is not what this says it is,
    /// so the socket's own address is used rather than a guess.
    trusted_hops: u8 = 0,

    /// How many password hashes may be in flight at once (ADR 0048).
    ///
    /// Eight, and the number is measured rather than picked. Argon2id at the
    /// default Cost is bound by memory bandwidth, not by cores: on a 16-core
    /// machine the throughput ceiling is ~280 hash/s and it is reached at 8
    /// concurrent, not at 32. Going to 32 buys nothing — 263 hash/s, slightly
    /// *worse* — and costs 608 MiB of transient allocation instead of 152 MiB
    /// and 110 ms per hash instead of 31 ms.
    ///
    /// Left ungated, the ceiling would be the Engine's blocking pool, which
    /// is twice the core count and sized for calls that wait on a disk rather
    /// than calls that eat a core and 19 MiB. That matters beyond the hashing
    /// itself: `Ctx.entropy` goes to the same pool, so a flood of sign-ins
    /// with no Gate in front of them would queue every session cookie in the
    /// server behind it.
    ///
    /// This bounds concurrency, not queueing. Past it, requests wait their
    /// turn — a sign-in gets slower, and `header_timeout_ms` is what
    /// eventually answers a client that will not wait.
    password_hashes_at_once: u16 = 8,

    /// How long a handler may run without yielding before nilo says so in
    /// the log. 0 turns it off (ADR 0034).
    ///
    /// Many requests share one OS thread, so a handler that waits on the
    /// operating system directly stops all of them. `nilo.blocking` is the
    /// way not to, and nothing in the type system can make anybody use it —
    /// the wrong version compiles and passes its tests. This is what
    /// notices instead, and it notices on the first request rather than
    /// under load, which is the point: the bug is invisible in development
    /// precisely because there is nobody else to be slow for.
    ///
    /// What is measured is time the handler ran, not time the request took:
    /// waiting on `nilo.blocking`, `nilo.sleep`, a `nilo.Mutex`, the
    /// request body or the response write is all subtracted, because in
    /// every one of those the thread is off serving somebody else. A
    /// request that takes the connection over — a stream, a body reader, a
    /// WebSocket — is not watched at all.
    ///
    /// A quarter of a second is far longer than any handler that is not
    /// waiting, and long enough that ordinary CPU work does not trip it.
    /// Deliberately on outside `Debug` too: the cost is two clock readings
    /// per request, and a detector that only runs where the bug cannot
    /// happen would never have fired.
    block_warning_ms: u32 = 250,

    /// The secret `Session(T)` cookies are sealed with — exactly
    /// `nilo.session.key_len` (32) bytes. Null means this application has no
    /// sessions, and a handler that asks for one anyway fails with a sentence
    /// naming this option.
    ///
    /// **Where it comes from is yours**, the same line nilo draws around
    /// authentication: an environment variable, a mounted file, a secrets
    /// manager. What nilo will not do is have a default, because a default
    /// key is a key everybody who has read this repository already has.
    ///
    /// It has to be the *same on every instance* behind a load balancer, or a
    /// request will land on the machine that cannot read its own cookies —
    /// which looks like users being randomly signed out. It also has to
    /// survive a restart for the same reason.
    ///
    /// Checked at `listen()`: the wrong length stops the server with a
    /// message, rather than every request failing once the traffic arrives.
    session_secret: ?[]const u8 = null,
};

/// Listen, and run `handler(state, in, out, deadlines)` for every
/// connection. The one call here that is a wrapper rather than a re-export,
/// and only for this: the Engine hands over something it can put a time
/// limit on, and this is where that becomes a `Deadlines` carrying nilo's
/// policy. Neither side has to know about the other's half of it.
pub fn serve(
    gpa: std.mem.Allocator,
    options: Options,
    stop: *Stop,
    state: anytype,
    comptime ready: anytype,
    comptime handler: anytype,
) !void {
    const State = @TypeOf(state);

    // The limits travel to each connection through the Engine's `state`,
    // which is carried as-is, so `serve` needs no new parameter and the
    // Engine needs no idea what is in here.
    const Carried = struct { state: State, limits: Deadlines };

    const Bridge = struct {
        fn run(
            carried: Carried,
            in: *std.Io.Reader,
            out: *std.Io.Writer,
            clocks: *engine.Clocks,
            wake: *engine.Wake,
            peer: Peer,
        ) void {
            var deadlines = carried.limits;
            deadlines.target = clocks;
            const waker: Waker = .{ .vtable = &engine_waker, .target = wake };
            handler(carried.state, in, out, deadlines, waker, peer);
        }

        /// The startup hook, unwrapped from what the Engine carries. The
        /// deadlines travelling beside `state` are a connection's business
        /// and there is no connection yet, so only the state goes through —
        /// along with the one clock that is not a connection's, which is what
        /// a Service bounds an outbound call with (ADR 0065).
        fn start(carried: Carried, io: std.Io) anyerror!void {
            return ready(carried.state, io, engine_limits_value);
        }
    };

    return engine.serve(gpa, options, stop, Carried{
        .state = state,
        .limits = .{
            .vtable = &engine_deadlines,
            .header_ms = options.header_timeout_ms,
            .idle_ms = options.idle_timeout_ms,
            .body_ms = options.body_timeout_ms,
            .write_ms = options.write_timeout_ms,
        },
    }, Bridge.start, Bridge.run);
}

const engine_waker: Waker.VTable = .{
    .wait = struct {
        fn f(target: ?*anyopaque, limit_ms: u32) Woken {
            const wake: *engine.Wake = @ptrCast(@alignCast(target.?));
            return switch (wake.wait(limit_ms)) {
                .readable => .readable,
                .posted => .posted,
                .timed_out => .timed_out,
                .closed => .closed,
            };
        }
    }.f,
    .post = struct {
        fn f(target: ?*anyopaque) void {
            const wake: *engine.Wake = @ptrCast(@alignCast(target.?));
            wake.post();
        }
    }.f,
    .release_stack = struct {
        fn f(_: ?*anyopaque) void {
            // The target is not needed: it is *this* fiber's stack, and the
            // Engine asks the coroutine it is running on rather than being
            // told which connection is asking.
            engine.releaseIdleStack();
        }
    }.f,
};

const engine_deadlines: Deadlines.VTable = .{
    .limit = struct {
        fn f(target: ?*anyopaque, side: Side, l: Limit) void {
            const clocks: *engine.Clocks = @ptrCast(@alignCast(target.?));
            switch (side) {
                .read => switch (l) {
                    .none => clocks.readNoLimit(),
                    .within_ms => |ms| clocks.readWithinMs(ms),
                    .by_ns => |ns| clocks.readByNanos(ns),
                },
                .write => switch (l) {
                    .none => clocks.writeNoLimit(),
                    .within_ms => |ms| clocks.writeWithinMs(ms),
                    .by_ns => |ns| clocks.writeByNanos(ns),
                },
            }
        }
    }.f,
    .timedOut = struct {
        fn f(target: ?*anyopaque) bool {
            const clocks: *const engine.Clocks = @ptrCast(@alignCast(target.?));
            return clocks.timedOut();
        }
    }.f,
};

/// The "please stop" flag `serve` watches, and `explained` for saying which
/// startup failures have already been put into words.
pub const Stop = engine.Stop;
pub const explained = engine.explained;

pub const Binding = engine.Binding;
pub const binding_unset = engine.binding_unset;
pub const bindSlot = engine.bindSlot;
pub const unbindSlot = engine.unbindSlot;
pub const monotonicNanos = engine.monotonicNanos;

/// Bytes from the operating system's entropy source, off the event loop.
/// What a session nonce is made of.
///
/// Wrapped rather than re-exported for the reason `Mutex` and `sleep` below
/// are: this parks the fiber on the Engine's blocking pool, so the thread is
/// off serving somebody else and the detector has to be told (ADR 0034).
/// Without this, sealing a session cookie would be charged to the handler as
/// time it spent holding its thread.
pub fn randomSecure(buffer: []u8) !void {
    const w = watchdog.waitingAnywhere();
    defer watchdog.waitedAnywhere(w);
    return engine.randomSecure(buffer);
}

/// A monotonic clock reading that is cheap rather than exact.
///
/// `monotonicNanos` costs a measured 27ns, because `CLOCK_MONOTONIC` does
/// the full timekeeping arithmetic on every read. The blocking detector
/// (ADR 0034) reads a clock four times per request and compares the answer
/// against a quarter of a second, so it wants the opposite trade — and gets
/// it: 5ns, from a reading that only moves once a millisecond.
///
/// Where there is no such clock this is `monotonicNanos` and the detector
/// simply costs what it costs. Nothing's correctness depends on which one
/// is underneath, only the price of asking.
pub fn coarseNanos() u64 {
    if (builtin.os.tag == .linux) {
        // Through `std.posix.system`, which is `std.os.linux` in a build
        // that does not link libc and libc's own wrapper in one that does.
        //
        // That distinction used to be the point of this comment: it
        // recorded 5ns one way and 600ns the other, on the grounds that
        // only the libc path reached the vDSO. **Re-measured on Zig 0.16
        // and it is no longer true** — `std.os.linux` reaches the vDSO
        // too, and `CLOCK_MONOTONIC_COARSE` is 1–2ns either way (ADR 0045).
        // What survives is the reason the *coarse* clock is here at all:
        // it is 2ns against 15ns for `CLOCK_MONOTONIC` read the same way,
        // which is the sort of gap that turns a cheap check into the most
        // expensive thing a request does. (15ns is the raw clock; the 27ns
        // above is `monotonicNanos`, which is the Engine's call and carries
        // its own frame.)
        var ts: std.posix.system.timespec = undefined;
        const rc = std.posix.system.clock_gettime(.MONOTONIC_COARSE, &ts);
        if (std.posix.errno(rc) == .SUCCESS) {
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        }
    }
    return monotonicNanos();
}

/// A lock that parks the fiber rather than the OS thread.
///
/// A wrapper rather than a re-export for one reason: waiting on a lock is
/// not the handler holding its thread, and the detector has to be told so
/// or a busy lock would be reported as a blocking handler (ADR 0034). The
/// three methods are the Engine's, in the order it defines them.
pub const Mutex = struct {
    _inner: engine.Mutex = .init,

    pub const init: Mutex = .{};

    pub fn lock(self: *Mutex) !void {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        return self._inner.lock();
    }

    /// Take the lock if it is free, without waiting. Never parks, so there
    /// is nothing to forgive.
    pub fn tryLock(self: *Mutex) bool {
        return self._inner.tryLock();
    }

    pub fn unlock(self: *Mutex) void {
        self._inner.unlock();
    }
};

/// A lock that lets a fixed number through at once, and parks the rest.
///
/// A wrapper rather than a re-export for the reason `Mutex` is: waiting for a
/// turn is not the handler holding its thread, and the detector has to be
/// told or a busy Gate reads as a blocking handler (ADR 0034).
///
/// **What it is for is a call that is expensive rather than slow.**
/// `nilo.blocking` already keeps a slow call off the loop, and the Engine's
/// pool already caps how many run at once — at twice the core count, which is
/// the right ceiling for a call that is waiting on a disk and the wrong one
/// for a call that is eating 19 MiB and a core. Password hashing is the
/// caller this exists for and the numbers are in ADR 0048.
pub const Gate = struct {
    _inner: engine.Semaphore,

    /// A Gate that lets `at_once` through. Zero would be a Gate nothing gets
    /// through, so it is read as one.
    pub fn open(at_once: usize) Gate {
        return .{ ._inner = .{ .permits = @max(1, at_once) } };
    }

    /// Wait for a turn. `error.Canceled` if the request went away first,
    /// which is the same answer `Mutex.lock` gives.
    pub fn enter(self: *Gate) error{Canceled}!void {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        return self._inner.wait();
    }

    /// Give the turn back. Never waits, so there is nothing to forgive.
    pub fn leave(self: *Gate) void {
        self._inner.post();
    }
};

/// Wait, without stopping the thread. Wrapped for the same reason `Mutex`
/// is: a sleeping fiber is not a held thread.
pub fn sleep(ms: u64) error{Canceled}!void {
    const w = watchdog.waitingAnywhere();
    defer watchdog.waitedAnywhere(w);
    return engine.sleep(ms);
}

/// Somewhere to put work that is not a request, owned by the server that
/// is running rather than by the fiber that started it (ADR 0029).
pub const spawn = engine.spawn;

// ---- files (ADR 0037) ----
//
// A file too big to hold is opened rather than read, and this is the whole
// of what that costs the Bulkhead. Both types are wrappers rather than
// re-exports for the reason `Mutex` and `randomSecure` are: every call
// below parks the fiber on the Engine, so the thread is off serving
// somebody else and the blocking detector has to be told, or opening a file
// would be reported as a handler holding its thread (ADR 0034). Wrapped
// here rather than at each call site so that nobody has to remember.

/// A directory, opened once and held open.
///
/// The long way round to a file's bytes, on purpose. A name is opened
/// relative to a descriptor that was chosen before the socket was, so
/// nothing carried by a request is ever resolved as a path — which is the
/// property ADR 0010 bought by refusing disk IO outright, kept here by the
/// shape of the type rather than by a normalisation step somebody has to
/// get right.
pub const Dir = struct {
    _inner: engine.Dir,

    /// Open `path`, relative to the working directory the server runs in.
    ///
    /// Held for as long as whatever opened it — the static tree for the life
    /// of the App, a Service for the life of the process — so this is
    /// startup work, and the request path only ever calls `openFile`.
    pub fn open(path: []const u8) !Dir {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        return .{ ._inner = try engine.Dir.open(path) };
    }

    pub fn close(self: Dir) void {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        self._inner.close();
    }

    /// Open `name` inside this directory.
    ///
    /// `name` is a name, not a path to work out: it is resolved by the
    /// kernel against this directory's descriptor. A symlink inside the
    /// directory is followed, because refusing them breaks ordinary
    /// deployments and no static server on the internet refuses them by
    /// default (ADR 0037).
    ///
    /// `error.FileNotFound` is the one failure with an answer better than a
    /// 500 — from the client's side, a file the list promised and the disk
    /// no longer has is indistinguishable from one that never existed.
    pub fn openFile(self: Dir, name: []const u8) !File {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        return .{ ._inner = try self._inner.openFile(name) };
    }
};

/// One open file, on its way to a client.
pub const File = struct {
    _inner: engine.File,

    /// How many bytes there are, asked of the operating system rather than
    /// remembered. What the `Content-Length` of a file response is made of.
    pub fn size(self: File) !u64 {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        return self._inner.size();
    }

    pub fn close(self: File) void {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        self._inner.close();
    }

    /// A reader over this file, using `buffer` for whatever it has to hold.
    ///
    /// The type that comes back is the standard library's own, and that is
    /// the point rather than an implementation detail: `sendFileAll` takes
    /// exactly this, so the bytes reach the socket through a vtable slot the
    /// Engine already fills in, and the HTTP layer sends a file without ever
    /// naming the Engine (ADR 0037). Nothing here does any IO — it is a
    /// struct being built — so there is no wait to forgive.
    pub fn reader(self: File, buffer: []u8) std.Io.File.Reader {
        return self._inner.reader(buffer);
    }
};

// ---- idle connections give their pages back ----

/// Hand the physical pages behind a connection's buffers back to the kernel
/// while it waits for the next request.
///
/// A keep-alive connection is allocated its read and write buffers once and
/// holds them until it closes, so every page it has ever touched stays
/// resident for as long as the client keeps the connection open. Measured: a
/// connection that has never been used costs 8,766 bytes, one that has served
/// a 6-byte response costs 16,955, and one that has served a 982-byte response
/// costs 21,114. The difference is buffer pages doing nothing.
///
/// The allocation itself stays, which is the point. Nothing here allocates or
/// frees, so ADR 0018's per-request allocation invariant is untouched, and the
/// buffer is still exactly as big as it was — the next request faults the pages
/// back in as zeroes, which is all a buffer about to be overwritten needs to
/// be. What it costs is one syscall per idle transition and a fault per page
/// on the way back, which is why the caller only does this when the connection
/// is actually about to wait.
///
/// Does nothing unless both buffers are empty. A pipelined request already
/// sitting in the read buffer is live data, and so is a response that has not
/// been flushed; discarding either would be a corrupted connection rather than
/// a smaller one.
pub fn releaseIdlePages(in: *std.Io.Reader, out: *std.Io.Writer) void {
    if (in.seek != in.end) return;
    if (out.end != 0) return;
    dontNeed(in.buffer);
    dontNeed(out.buffer);
}

/// Hand back the pages behind a buffer that is not the connection's.
///
/// A WebSocket's message ceiling is a buffer the *handler* declared, usually on
/// its own stack, and a suspended fiber holds every page of its stack that it
/// ever touched ([ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md)).
/// So a socket that once received a 60 KiB message held 60 KiB for as long as
/// it stayed open, measured at 74,809 bytes per idle connection against 13,375
/// for the same socket that never saw one.
///
/// The bounds are exact rather than guessed, which is the whole reason this is
/// allowed to exist: `receive` is *handed* the slice, so there is no arithmetic
/// from a stack's limit that could run one page into a neighbouring fiber's
/// live stack. Aligned inward, so a 4 KiB buffer that straddles two pages
/// covers no whole page and nothing happens — which is the right answer, since
/// the case worth paying a syscall for is the big one.
///
/// The caller must be done with the bytes. `Socket.receive` does this only when
/// it has no message half-collected and is about to park, at which point the
/// previous message is already forfeit — the next one overwrites the buffer
/// whatever happens here.
pub fn releaseScratchPages(buf: []u8) void {
    dontNeed(buf);
}

/// `MADV_DONTNEED` over whatever whole pages the slice covers.
///
/// Aligned inward rather than outward: a partial page at either end may be
/// shared with somebody else's allocation, and zeroing that would be a bug of
/// the worst kind — silent, rare, and in another module. The engine allocates
/// these buffers page-aligned so that in practice nothing is trimmed.
///
/// Nothing happens off POSIX. Windows has `DiscardVirtualMemory` for the same
/// job and it is not wired up here, so a Windows build keeps the pages and the
/// old numbers — which is the behaviour that shipped, not a new fault.
fn dontNeed(buf: []u8) void {
    if (builtin.os.tag == .windows) return;
    if (buf.len == 0) return;
    const page = std.heap.pageSize();
    const start = std.mem.alignForward(usize, @intFromPtr(buf.ptr), page);
    const end = std.mem.alignBackward(usize, @intFromPtr(buf.ptr) + buf.len, page);
    if (end <= start) return;
    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start);
    // A failure here means the pages stay resident, which is where they were
    // anyway. There is nothing to report and nothing to do about it.
    std.posix.madvise(ptr, end - start, std.posix.MADV.DONTNEED) catch {};
}

// ---- deadlines (ADR 0023) ----

/// Which half of a connection a limit is being put on.
pub const Side = enum { read, write };

/// How long the Engine may wait for one read, or one write.
pub const Limit = union(enum) {
    /// As long as it takes. What every wait in nilo did before ADR 0023,
    /// and what a connection that has stopped being HTTP goes back to.
    none,
    /// This operation gets this many milliseconds to itself. The next one
    /// gets the same again.
    within_ms: u32,
    /// Every operation from now until the limit is changed shares one
    /// deadline, as a `monotonicNanos` reading. What a run of reads wants
    /// when it is the run that has to finish on time rather than any single
    /// read in it.
    by_ns: u64,
};

/// What ended a `Waker.wait` — the Engine's `Woken`, re-declared here so the
/// layers above never name the Engine.
pub const Woken = enum { readable, posted, timed_out, closed };

/// A connection that can be woken by somebody who is not the client on the
/// other end of it.
///
/// The same shape as `Deadlines` and for the same reason: the Engine owns the
/// machinery, nilo owns the concept, and neither has to know the other's
/// half. It travels the connection chain by value the way `Deadlines` does,
/// and it defaults to a vtable with no Engine behind it — which is what makes
/// the whole HTTP suite runnable against in-memory buffers with no server.
///
/// That default answers `.readable` to everything. A test driving `App`
/// straight has bytes in a fixed buffer or it does not; there is nobody to
/// post to it, and a `receive` that parked waiting for one would hang the
/// suite rather than fail it.
pub const Waker = struct {
    target: ?*anyopaque = null,
    vtable: *const VTable = &no_engine,

    pub const VTable = struct {
        wait: *const fn (target: ?*anyopaque, limit_ms: u32) Woken,
        post: *const fn (target: ?*anyopaque) void,
        /// Hand back the pages of this connection's fiber stack that are below
        /// its current frame, for a connection that has gone quiet.
        ///
        /// It sits on `Waker` because `Waker` is what a connection's fiber
        /// looks like from up here: the thing that parks it, wakes it, and now
        /// gives back what parking it costs. nilo has no other handle on a
        /// fiber and is not getting one — naming the Engine anywhere but the
        /// Engine is what ADR 0002 refuses.
        release_stack: *const fn (target: ?*anyopaque) void,
    };

    /// No Engine underneath: every wait says "go and read", every post is
    /// dropped. `App.handleRequest` called from a test gets this.
    pub const off: Waker = .{};

    const no_engine: VTable = .{
        .wait = struct {
            fn f(_: ?*anyopaque, _: u32) Woken {
                return .readable;
            }
        }.f,
        .post = struct {
            fn f(_: ?*anyopaque) void {}
        }.f,
        .release_stack = struct {
            fn f(_: ?*anyopaque) void {}
        }.f,
    };

    /// Park until the socket has something to read, somebody posts, or
    /// `limit_ms` goes by with neither. Zero waits with no limit.
    ///
    /// The caller must have drained its read buffer first — a reader with
    /// bytes still in it is readable whatever the socket thinks, and this
    /// would park a connection that is holding a whole frame already.
    ///
    /// **`.readable` is answered once per arrival of bytes, not once per
    /// call.** A wait that follows a read the caller has already done must
    /// park, not answer `.readable` again for bytes that are gone — an Engine
    /// that gets this wrong sends the caller into a blocking read where
    /// neither a `post` nor the next limit can reach it, and the connection
    /// silently stops taking part in either. It is stated here because it is
    /// the Engine's half of the bargain and it cannot be seen from a test
    /// against `off`, which answers `.readable` to everything by design.
    pub fn wait(self: Waker, limit_ms: u32) Woken {
        return self.vtable.wait(self.target, limit_ms);
    }

    /// Wake the connection. The one call another fiber makes, and the reason
    /// this exists at all.
    pub fn post(self: Waker) void {
        self.vtable.post(self.target);
    }

    /// Give this connection's dead stack pages back, for a connection that has
    /// gone quiet. Everything below the current frame; nothing above it.
    ///
    /// Only correct where the caller is about to wait and means to stay
    /// waiting: the pages fault back in as zeroes, so this pays for itself
    /// once and costs again on every return trip. `Socket.park` calls it
    /// behind the same 200ms peek that gates the buffers.
    pub fn releaseStack(self: Waker) void {
        self.vtable.release_stack(self.target);
    }
};

/// One connection's time limits, and the way to apply them.
///
/// Passed by value into everything that reads or writes: two pointers and
/// four numbers, copied rather than reached for through the App, because
/// the limits belong to a connection and the App is shared by all of them.
///
/// `.off` is a complete working instance that does nothing. That is what a
/// test driving `App` directly gets, and what a server with every limit set
/// to zero ends up with, so "no deadlines" needs no branch anywhere.
pub const Deadlines = struct {
    target: ?*anyopaque = null,
    vtable: *const VTable = &noop,

    /// Copied from `Options` so that nothing downstream has to be handed
    /// both a clock and a policy. Zero means no limit, field by field.
    header_ms: u32 = 0,
    idle_ms: u32 = 0,
    body_ms: u32 = 0,
    write_ms: u32 = 0,

    pub const VTable = struct {
        limit: *const fn (target: ?*anyopaque, side: Side, l: Limit) void,
        timedOut: *const fn (target: ?*anyopaque) bool,
    };

    pub const off: Deadlines = .{};

    const noop: VTable = .{
        .limit = struct {
            fn f(_: ?*anyopaque, _: Side, _: Limit) void {}
        }.f,
        .timedOut = struct {
            fn f(_: ?*anyopaque) bool {
                return false;
            }
        }.f,
    };

    /// Waiting on a client that has not said anything yet — a connection
    /// between one keep-alive request and the next.
    pub fn armIdle(self: Deadlines) void {
        self.set(.read, if (self.idle_ms == 0) .none else .{ .within_ms = self.idle_ms });
    }

    /// The first byte of a request head has arrived; the rest of the head
    /// has `header_ms` to follow it.
    ///
    /// All of it, not each read of it, and that distinction is the reason
    /// this exists at all: a client sending one byte a second satisfies any
    /// per-read limit you care to name and never finishes a head.
    pub fn armHeader(self: Deadlines) void {
        if (self.header_ms == 0) return self.set(.read, .none);
        self.set(.read, .{ .by_ns = monotonicNanos() + msToNanos(self.header_ms) });
    }

    /// Reading a request body, one read at a time. Per read rather than for
    /// the whole body, because how long a body legitimately takes is a
    /// function of its size and the client's line, and neither is something
    /// a server may put a number on in advance. What is not legitimate is a
    /// client that stops sending mid-body and holds the fiber, and that is
    /// what a per-read limit catches.
    pub fn armBody(self: Deadlines) void {
        self.set(.read, if (self.body_ms == 0) .none else .{ .within_ms = self.body_ms });
    }

    /// Writing to the client, one write at a time — same reasoning as
    /// `armBody`, in the other direction. Set once per connection: nothing
    /// in a response changes it.
    pub fn armWrite(self: Deadlines) void {
        self.set(.write, if (self.write_ms == 0) .none else .{ .within_ms = self.write_ms });
    }

    /// Take the limit off reads. For a connection that has stopped being a
    /// series of requests and is allowed to sit quiet — a WebSocket whose
    /// client has nothing to say for an hour is working correctly.
    pub fn readForever(self: Deadlines) void {
        self.set(.read, .none);
    }

    /// A deliberately short read limit, used to find out whether a connection
    /// is about to be idle rather than to enforce anything.
    ///
    /// Running out of time here is not an error and does not end the
    /// connection: it is the answer to "is the next request already on its
    /// way?", and the caller arms the real idle limit straight afterwards.
    pub fn armPeek(self: Deadlines, ms: u32) void {
        self.set(.read, .{ .within_ms = ms });
    }

    /// Whether the last read or write failed because it ran out of time,
    /// rather than because the connection broke. Both arrive as
    /// `error.ReadFailed`/`error.WriteFailed` through a `std.Io` interface,
    /// which is why this is a separate question.
    pub fn timedOut(self: Deadlines) bool {
        return self.vtable.timedOut(self.target);
    }

    fn set(self: Deadlines, side: Side, l: Limit) void {
        self.vtable.limit(self.target, side, l);
    }
};

fn msToNanos(ms: u32) u64 {
    return @as(u64, ms) * std.time.ns_per_ms;
}

/// Run a blocking call on the Engine's thread pool, parking this fiber
/// until it comes back (ADR 0014).
///
/// The slot travels with it. Without that, a fail function called inside
/// the blocking call would find no request — the worker is a plain thread,
/// not the fiber the slot is bound to — and `fail.notFound(…)` inside a
/// database query would quietly become a 500 instead of a 404. Carrying it
/// is safe because this is a hand-off, not sharing: the fiber is parked for
/// exactly as long as the worker is running, so only one of them is ever
/// looking at the InFlight.
///
/// The `setFallbackSlot` below must keep happening on a thread-pool worker
/// and never on an executor thread. `spawn` (ADR 0029) runs fibers with no
/// slot of their own, and those fall through to the threadlocal; if this
/// assignment ever landed on the thread they run on, spawned work would
/// write its failure message into an unrelated request — ADR 0007's leak,
/// by another route. It lands on a worker because `engine.blocking` is
/// `zio.blockInPlace`, which submits the call to the thread pool.
pub fn blocking(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) ReturnType(func) {
    const Args = @TypeOf(args);
    const Carrier = struct {
        fn run(carried: ?*anyopaque, inner: Args) ReturnType(func) {
            const previous = setFallbackSlot(carried);
            defer _ = setFallbackSlot(previous);
            return @call(.auto, func, inner);
        }
    };
    // Opened and closed on this side of the hand-off on purpose. Inside
    // `Carrier.run` the slot points at the same InFlight, so the arithmetic
    // would be the same — but that code runs on a thread-pool worker, and
    // two threads writing `waited_ns` is a race for no gain (ADR 0034).
    const w = watchdog.waitingAnywhere();
    defer watchdog.waitedAnywhere(w);
    return engine.blocking(Carrier.run, .{ slot(), args });
}

fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type orelse void;
}

/// A fallback for use outside the Engine: unit tests call App directly,
/// with no fiber, so `engine.slot()` is always null there. On a real
/// server a connection's fiber slot always exists and wins, so what is
/// stored here is never read by one.
///
/// A fiber from `spawn` (ADR 0029) has no slot, so it *does* read this. It
/// is safe only because the one place that writes it — `blocking` above —
/// does so on a thread-pool worker, and spawned fibers run on executor
/// threads. Anything that starts setting this on an executor thread
/// reintroduces the cross-request leak ADR 0007 exists to prevent.
threadlocal var fallback_slot: ?*anyopaque = null;

/// Install the fallback slot, returning the previous one so it can be
/// restored.
pub fn setFallbackSlot(p: ?*anyopaque) ?*anyopaque {
    const previous = fallback_slot;
    fallback_slot = p;
    return previous;
}

/// The slot of the request currently running, or null if there is none.
pub fn slot() ?*anyopaque {
    return engine.slot() orelse fallback_slot;
}

// ---- tests ----

const testing = std.testing;

/// Catches the last limit asked for, so what `arm*` works out can be
/// checked without a socket to apply it to.
const Caught = struct {
    side: Side = .read,
    limit: Limit = .none,
    n: usize = 0,

    fn deadlines(self: *Caught, limits: Deadlines) Deadlines {
        var d = limits;
        d.target = self;
        d.vtable = &.{ .limit = take, .timedOut = never };
        return d;
    }

    fn take(target: ?*anyopaque, side: Side, l: Limit) void {
        const self: *Caught = @ptrCast(@alignCast(target.?));
        self.side = side;
        self.limit = l;
        self.n += 1;
    }

    fn never(_: ?*anyopaque) bool {
        return false;
    }
};

test "an idle limit is a duration, because each wait stands on its own" {
    var caught = Caught{};
    const d = caught.deadlines(.{ .idle_ms = 900 });
    d.armIdle();
    try testing.expectEqual(Side.read, caught.side);
    try testing.expectEqual(Limit{ .within_ms = 900 }, caught.limit);
}

test "a header limit is a deadline, so a byte at a time does not extend it" {
    var caught = Caught{};
    const d = caught.deadlines(.{ .header_ms = 700 });

    const before = monotonicNanos();
    d.armHeader();
    const after = monotonicNanos();

    // In the future, and by about the right amount — bracketed by two
    // readings of the same clock rather than compared against a constant,
    // because the second one is the only thing that cannot drift.
    const at = caught.limit.by_ns;
    try testing.expect(at >= before + 700 * std.time.ns_per_ms);
    try testing.expect(at <= after + 700 * std.time.ns_per_ms);
}

test "a limit of zero takes the limit off rather than expiring at once" {
    // The difference matters: a duration of zero is a read that fails
    // immediately, which would be a server that answers nothing at all.
    var caught = Caught{};
    const d = caught.deadlines(.{});
    d.armIdle();
    try testing.expectEqual(Limit.none, caught.limit);
    d.armHeader();
    try testing.expectEqual(Limit.none, caught.limit);
    d.armBody();
    try testing.expectEqual(Limit.none, caught.limit);
    d.armWrite();
    try testing.expectEqual(Limit.none, caught.limit);
    try testing.expectEqual(Side.write, caught.side);
    try testing.expectEqual(@as(usize, 4), caught.n);
}

test "the deadlines a test gets by default do nothing, and say nothing timed out" {
    const d: Deadlines = .off;
    d.armIdle();
    d.armHeader();
    d.armBody();
    d.armWrite();
    d.readForever();
    try testing.expect(!d.timedOut());
}
