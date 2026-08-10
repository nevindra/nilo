//! Bulkhead — the internal boundary between zfast and the Engine.
//!
//! Everything zfast needs from the Engine goes through this file. No part
//! of zfast outside `src/engine/` may name zio. Swapping the Engine means
//! swapping the one import below, without touching a line of user code.
//!
//! The contract an Engine has to meet:
//! - `Options` — the address and port to listen on.
//! - `serve(gpa, options, state, handler)` — listen, accept connections,
//!   and run `handler(state, in, out)` for each one concurrently until
//!   that connection is done. `state` is carried through as-is (normally
//!   `*App`).
//! - `debug_io` — wired into `std_options_debug_io` so that `std.log`
//!   does not block the event loop.
//! - `Binding`/`bindSlot`/`unbindSlot`/`slot` — one pointer bound to the
//!   unit of work currently running (a fiber, a thread, whatever the
//!   Engine uses), for hidden per-request state (ADR 0007).
//!
//! The Reader/Writer handed to the handler are plain std types
//! (`*std.Io.Reader`, `*std.Io.Writer`), so the HTTP layer has no idea
//! which Engine is behind them.

const engine = @import("engine/zio.zig");

pub const Options = engine.Options;
pub const serve = engine.serve;
pub const debug_io = engine.debug_io;

pub const Binding = engine.Binding;
pub const binding_unset = engine.binding_unset;
pub const bindSlot = engine.bindSlot;
pub const unbindSlot = engine.unbindSlot;

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
