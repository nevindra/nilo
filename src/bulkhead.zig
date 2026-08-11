//! Bulkhead — the internal boundary between zfast and the Engine.
//!
//! Everything zfast needs from the Engine goes through this file. No part
//! of zfast outside `src/engine/` may name zio. Swapping the Engine means
//! swapping the one import below, without touching a line of user code.
//!
//! The contract an Engine has to meet:
//! - `Options` — the address and port to listen on.
//! - `serve(gpa, options, stop, state, handler)` — listen, accept
//!   connections, and run `handler(state, in, out, deadlines)` for each one
//!   concurrently until that connection is done. `state` is carried through
//!   as-is (normally `*App`). Returns when `stop` is set.
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

const engine = @import("engine/zio.zig");

pub const Options = engine.Options;
pub const debug_io = engine.debug_io;

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
        ) void {
            var deadlines = carried.limits;
            deadlines.target = clocks;
            handler(carried.state, in, out, deadlines);
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
