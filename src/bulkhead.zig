//! Bulkhead — the internal boundary between zfast and the Engine.
//!
//! Everything zfast needs from the Engine goes through this file. No part
//! of zfast outside `src/engine/` may name zio. Swapping the Engine means
//! swapping the one import below, without touching a line of user code.
//!
//! The contract an Engine has to meet:
//! - `Options` — the address and port to listen on.
//! - `serve(gpa, options, stop, state, handler)` — listen, accept
//!   connections, and run `handler(state, in, out)` for each one
//!   concurrently until that connection is done. `state` is carried through
//!   as-is (normally `*App`). Returns when `stop` is set.
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
pub const serve = engine.serve;
pub const debug_io = engine.debug_io;

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
