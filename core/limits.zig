//! When an operation gives up, as vocabulary two layers agree about
//! ([ADR 0065](../docs/adr/0065-the-way-out-was-open-the-clock-was-not.md)).
//!
//! A Service can dial out — `std.Io.net` does it and `ready(state, io)` hands
//! over the `std.Io` to do it with. What it could not do is **stop**.
//! `std.Io.net.Stream.Reader` has no per-read timeout and `std.http.Client` has
//! no deadline field, so an endpoint that accepts a connection and then says
//! nothing holds a handler until the process dies. Cancellation does reach —
//! every `std.Io.net` operation carries `Io.Cancelable` — so a deadline built
//! on it is enforced rather than decorative.
//!
//! This is the same shape as `Deadlines` in `http/bulkhead.zig` and for the
//! same reason: the Engine owns the machinery, nilo owns the concept, and
//! neither has to know the other's half. It lives here rather than beside
//! `Deadlines` because the caller is a **Service**, and a Service may not
//! import `nilo_http` — the same wall that sent `percent` down a layer
//! ([ADR 0066](../docs/adr/0066-percent-is-needed-by-two-layers.md)). It earns
//! the layer the way every file here does: the App fills it, a Service reads
//! it. No IO, no allocation, no engine named, and `zig test core/core.zig`
//! is unchanged.
//!
//! ## A Bound must not be copied once it is armed
//!
//! ADR 0065 sketched this as `var bound = limits.arm(2_000);` — a `Bound`
//! returned by value. **That sketch cannot be implemented safely and this API
//! deliberately differs from it.** The Engine's arming state is address
//! sensitive: zio's `AutoCancel` stores `&self` as its timer's userdata and
//! hands `&self.timer` to the event loop, so a struct armed at one address and
//! then copied to another leaves the loop holding a pointer to a slot nobody
//! owns. Returning it by value registers the timer against the temporary.
//!
//! So arming takes `*Bound` and the caller declares the storage first:
//!
//! ```zig
//! var bound: core.Limits.Bound = .idle;
//! defer bound.release();
//! bound.arm(self.limits, 2_000);
//!
//! const res = self.client.request(...) catch |err| {
//!     if (bound.fired()) return error.TimedOut;
//!     return err;
//! };
//! ```
//!
//! Note what that does *not* do: it does not look at the error first. ADR 0065
//! and the first draft of this file both wrote `error.Canceled => if
//! (bound.fired())`, and `fetch/deadline.zig` — the first test here to watch a
//! real timer fire — got `error.ReadFailed` instead. `std.Io.Reader`'s error
//! set is fixed, so a cancellation that crosses it is collapsed into a read
//! failure and the cause is kept in a field the caller never sees. **The bound
//! is the authority; the error is not.**
//!
//! Forgetting the `arm` line is the one mistake this shape allows, and it is
//! the harmless one: an idle `Bound` releases nothing and reports nothing, so
//! the operation is unbounded exactly as it would have been with none of these
//! lines written. The mistake the other shape allowed was a live timer holding
//! a dangling pointer, which is not harmless and not visible.

const std = @import("std");

pub const Limits = struct {
    target: ?*anyopaque = null,
    vtable: *const VTable = &noop,

    /// Room for the Engine's own arming state, held inside a `Bound` so that
    /// arming costs no allocation.
    ///
    /// Core cannot name an Engine, so it cannot ask how big that state is. It
    /// declares the slot and `http/bulkhead.zig` — which does name one — holds
    /// the `comptime` check that refuses an Engine whose state does not fit,
    /// in nilo's own words rather than as a failed `@memcpy` somewhere.
    ///
    /// **zio's `AutoCancel` measures 176 bytes**, most of it the `ev.Timer`
    /// inside it. The first draft of this file guessed 56 and the check caught
    /// it on the first build, which is the whole reason the check is a build
    /// step rather than a sentence — a slot too small would otherwise have
    /// been an `@alignCast` onto a buffer the Engine then wrote past.
    ///
    /// 192 rather than 176 so that a second Engine has somewhere to stand
    /// without a number in Core changing. Every byte is stack a handler
    /// touches, and by [ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md)
    /// that is per *connection* rather than per request — so this is 192 bytes
    /// on a connection whose handler arms one, and nothing at all on a
    /// connection whose handler does not.
    pub const slot_size = 192;
    pub const slot_align = 16;

    pub const VTable = struct {
        arm: *const fn (target: ?*anyopaque, slot: *anyopaque, ms: u32) void,
        release: *const fn (target: ?*anyopaque, slot: *anyopaque) void,
        fired: *const fn (target: ?*anyopaque, slot: *anyopaque) bool,
    };

    /// No Engine underneath: arming does nothing and nothing ever fires. What
    /// a Service built in a test with no server around it holds, and what the
    /// `off` in `Deadlines` is for.
    pub const off: Limits = .{};

    const noop: VTable = .{
        .arm = struct {
            fn f(_: ?*anyopaque, _: *anyopaque, _: u32) void {}
        }.f,
        .release = struct {
            fn f(_: ?*anyopaque, _: *anyopaque) void {}
        }.f,
        .fired = struct {
            fn f(_: ?*anyopaque, _: *anyopaque) bool {
                return false;
            }
        }.f,
    };

    /// One armed deadline, and the storage the Engine arms into.
    ///
    /// **Address sensitive once armed** — see the header. Declare it, arm it
    /// where it stands, and do not move it.
    pub const Bound = struct {
        limits: Limits = .off,
        slot: [slot_size]u8 align(slot_align) = undefined,
        armed: bool = false,

        /// Storage with nothing armed in it. Releasing one is a no-op and
        /// `fired` says no, so the two lines that follow are safe to leave
        /// out.
        pub const idle: Bound = .{};

        /// Give the operation on this fiber `ms` to finish. Zero means no
        /// limit — the same spelling `Deadlines` uses, so an option read from
        /// a Config behaves the same way at either end.
        ///
        /// Arming twice without releasing is a bug rather than a nesting
        /// mechanism: nest by declaring a second `Bound`, which is what the
        /// Engine's own machinery supports.
        pub fn arm(self: *Bound, limits: Limits, ms: u32) void {
            std.debug.assert(!self.armed);
            if (ms == 0) return;
            self.limits = limits;
            self.armed = true;
            limits.vtable.arm(limits.target, &self.slot, ms);
        }

        /// Take the deadline off. Safe to call on a `Bound` that was never
        /// armed, which is what lets it sit under an unconditional `defer`.
        ///
        /// **It also swallows a fire nobody asked about**, and that is not
        /// tidiness. A cancellation is a *pending count on the fiber* rather
        /// than a fact about the error that came back, and taking the timer
        /// off does not spend it. A call whose deadline expired one
        /// instruction before it succeeded would return a value and leave the
        /// fiber carrying a cancellation the next operation collects —
        /// writing the response. So the last thing an armed `Bound` does is
        /// consume its own.
        pub fn release(self: *Bound) void {
            if (!self.armed) return;
            self.armed = false;
            self.limits.vtable.release(self.limits.target, &self.slot);
            _ = self.limits.vtable.fired(self.limits.target, &self.slot);
        }

        /// Whether *this* deadline is what cancelled the operation.
        ///
        /// Ask it at **any** failure, not only at `error.Canceled`: a
        /// cancellation reaching a caller through `std.Io.Reader` arrives as
        /// `error.ReadFailed`, because that error set is fixed and the cause
        /// is kept in a field. The bound is the only thing that knows, so it
        /// is the thing to ask.
        ///
        /// What it answers is the question the error cannot: a shutdown
        /// cancels a fiber too, and a caller that reported every cancellation
        /// as a timeout would blame the wrong thing at every deploy.
        ///
        /// The answer is consumed, so ask once — asking is also what spends
        /// the cancellation, which is why `release` asks for anyone who did
        /// not.
        pub fn fired(self: *Bound) bool {
            if (!self.armed) return false;
            return self.limits.vtable.fired(self.limits.target, &self.slot);
        }
    };
};

const testing = std.testing;

test "a Bound with no Engine under it arms nothing and blames nothing" {
    var bound: Limits.Bound = .idle;
    defer bound.release();
    bound.arm(.off, 2_000);
    try testing.expect(!bound.fired());
}

test "a Bound that was never armed is safe to release and reports nothing" {
    var bound: Limits.Bound = .idle;
    try testing.expect(!bound.armed);
    try testing.expect(!bound.fired());
    bound.release();
    bound.release(); // twice, because a defer plus an early return can do that
}

test "zero milliseconds is no limit rather than a limit of zero" {
    var bound: Limits.Bound = .idle;
    defer bound.release();
    bound.arm(.off, 0);
    // Nothing was armed, so nothing has to be taken off — the same spelling
    // `Deadlines` gives `header_ms = 0`.
    try testing.expect(!bound.armed);
}

test "the slot holds what the Engine measured" {
    // The check that matters is in `http/bulkhead.zig`, where an Engine can be
    // named. This one holds the measured floor so that shrinking the slot from
    // down here — where the Engine is invisible — fails in Core rather than
    // three modules away.
    try testing.expect(Limits.slot_size >= 176); // zio's AutoCancel, measured
    try testing.expect(Limits.slot_align >= 8);
    try testing.expectEqual(Limits.slot_size, @sizeOf(@FieldType(Limits.Bound, "slot")));
}
