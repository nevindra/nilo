//! Bulkhead — the internal boundary between zfast and the Engine.
//!
//! Everything zfast needs from the Engine goes through this file. No part
//! of zfast outside `src/engine/` may name zio. Swapping the Engine means
//! swapping the one import below, without touching a line of user code.
//!
//! The contract an Engine has to meet:
//! - reading the fields of `Options` that name a socket, a buffer or a
//!   deadline. The struct itself is declared here, not by the Engine, so
//!   that swapping the Engine cannot change what a user writes.
//! - `serve(gpa, options, stop, state, handler)` — listen, accept
//!   connections, and run `handler(state, in, out, deadlines, peer)` for
//!   each one concurrently until that connection is done. `state` is
//!   carried through as-is (normally `*App`). Returns when `stop` is set.
//! - `Peer` — who is at the other end of a connection. `accept` already
//!   knows, so this asks the Engine for nothing it did not have.
//! - `Deadlines.limit`/`Deadlines.timedOut` — put a time limit on the next
//!   read or write of one connection, and say afterwards whether that limit
//!   is what a failure was. An Engine that waits on sockets already has to
//!   be able to wait with a limit, so this asks for nothing new of it
//!   (ADR 0023).
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
//!
//! The Reader/Writer handed to the handler are plain std types
//! (`*std.Io.Reader`, `*std.Io.Writer`), so the HTTP layer has no idea
//! which Engine is behind them.

const std = @import("std");
const builtin = @import("builtin");

const engine = @import("engine/zio.zig");

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

    // ---- deadlines (ADR 0023) ----
    //
    // Zero turns any one of these off. All four off is what zfast did
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
    /// about 21 KB each with the default buffers — so a server with many
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
    /// A connection costs a measured 8,767 bytes before it has asked for
    /// anything, so this number times nine kilobytes is what the server
    /// may hold: the default is about 88 MB. That is the whole point of
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
};

/// Listen, and run `handler(state, in, out, deadlines)` for every
/// connection. The one call here that is a wrapper rather than a re-export,
/// and only for this: the Engine hands over something it can put a time
/// limit on, and this is where that becomes a `Deadlines` carrying zfast's
/// policy. Neither side has to know about the other's half of it.
pub fn serve(
    gpa: std.mem.Allocator,
    options: Options,
    stop: *Stop,
    state: anytype,
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
            peer: Peer,
        ) void {
            var deadlines = carried.limits;
            deadlines.target = clocks;
            handler(carried.state, in, out, deadlines, peer);
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
    }, Bridge.run);
}

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
pub const Mutex = engine.Mutex;
pub const sleep = engine.sleep;

// SPIKE (spike/broadcast). Not part of the Bulkhead contract until an ADR
// says so; deleted with the spike otherwise.
pub const Spawned = engine.Spawned;
pub const spawn = engine.spawn;
pub const Channel = engine.Channel;
pub const BroadcastChannel = engine.BroadcastChannel;

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
    /// As long as it takes. What every wait in zfast did before ADR 0023,
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
pub fn blocking(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) ReturnType(func) {
    const Args = @TypeOf(args);
    const Carrier = struct {
        fn run(carried: ?*anyopaque, inner: Args) ReturnType(func) {
            const previous = setFallbackSlot(carried);
            defer _ = setFallbackSlot(previous);
            return @call(.auto, func, inner);
        }
    };
    return engine.blocking(Carrier.run, .{ slot(), args });
}

fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type orelse void;
}

/// A fallback for use outside the Engine: unit tests call App directly,
/// with no fiber, so `engine.slot()` is always null there. On a real
/// server the fiber slot always exists and wins, so what is stored here
/// is never read.
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
