//! The one thing zigache needs that Zig 0.16 took away.
//!
//! zigache is pinned to Zig 0.14 and its five algorithms all open with
//! `const Mutex = if (thread_safety) std.Thread.RwLock else void;`. Zig 0.16
//! has neither `std.Thread.RwLock` nor `std.Thread.Mutex` — both moved behind
//! `std.Io`, which a plain library has no way to get. This is the same wall
//! `nilo_cache` hit (ADR 0138), and the answer is the same one: spin.
//!
//! **This is the whole patch.** Nothing else in the vendored copy is changed,
//! so what the benchmark measures is zigache's own algorithms. A spin lock is
//! if anything kinder than a blocking one at these critical-section sizes,
//! which is why nilo uses one too — so this cannot be flattering nilo.

const std = @import("std");

pub const RwLock = struct {
    /// Negative is "a writer holds it"; positive is that many readers.
    state: std.atomic.Value(i32) = .init(0),

    pub fn lock(self: *RwLock) void {
        while (true) {
            if (self.state.cmpxchgWeak(0, -1, .acquire, .monotonic) == null) return;
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *RwLock) void {
        self.state.store(0, .release);
    }

    pub fn lockShared(self: *RwLock) void {
        while (true) {
            const seen = self.state.load(.monotonic);
            if (seen >= 0 and self.state.cmpxchgWeak(seen, seen + 1, .acquire, .monotonic) == null) return;
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlockShared(self: *RwLock) void {
        _ = self.state.fetchSub(1, .release);
    }
};
