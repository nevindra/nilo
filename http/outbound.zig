//! The outbound pipe of a request on HTTP/2: what the handler writes, from
//! the request's fiber to the connection's
//! ([ADR 260](../docs/adr/260-a-request-on-http2-runs-from-its-headers.md)).
//!
//! `inbound.zig` is the other direction. **The connection's fiber is the only
//! one that touches the socket** (ADR 220), so a handler that streams, sends
//! an event or a file never writes to it: it *lends* what it has to the
//! connection and waits until the connection has put it in its writer.
//!
//! **Nothing is copied and nothing is allocated per piece.** What is lent is
//! the stream's own buffer (the one `c.stream` took from the request arena
//! when it opened, ADR 019), and the slices a write handed past it, as the
//! `std.Io.Writer` drain gave them (`Lent`). The connection writes `DATA`
//! frames straight out of them, as many as both windows allow, and when the
//! last byte is in its writer it wakes the call. A handler is parked for the
//! length of that wait and holds nothing else of the connection, so what a
//! stream costs a connection is the buffer the handler already had, and a
//! client that stops reading stops the handler at its next write and no
//! further (a handler on a socket that has stopped reading is held the same
//! way).
//!
//! **The memory is the call's, so the call does not return while it is
//! lent.** The wait for the connection to be done with it cannot be cancelled
//! (`Signal.waitUncancelable`): a fiber unwinding on a cancel would free a
//! buffer the connection's fiber, on another thread, is writing from. What
//! makes that safe is that the connection ends every lend one way or the
//! other: it writes it, or it fails it (a reset stream, a stalled client past
//! the write deadline, a connection that is going), and a failed lend is
//! never read again.
//!
//! One lock, the connection's `Monitor`, guards every field here that both
//! fibers touch, and the connection never does I/O while holding it: it takes
//! a copy of what is lent (`take`), writes without the lock, and reports what
//! it wrote (`wrote`). The slices are safe to read unlocked meanwhile because
//! the call that lent them is parked, and is woken only by the connection.
//!
//! A call that cannot wait (a connection driven with no Engine and no
//! scheduler, `can_park`) copies what it writes into a buffer of the request
//! arena instead, and the connection writes it when the call has returned.
//! That costs an allocation per piece and is for tests and `zig build
//! profile`, which never stream.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");
const inbound = @import("inbound.zig");

/// Why a lend ended without being written.
pub const Failure = enum {
    /// The stream was reset by the client or by a rule of the protocol.
    reset,
    /// The client stopped reading, and the write deadline passed.
    slow,
    /// The connection is going, or the client has.
    gone,
};

/// What one piece of a stream is: the bytes the stream's buffer held, then
/// each slice of `data` but the last, then the last repeated `splat` times,
/// which is what a `std.Io.Writer` drain is handed. Borrowed from the caller
/// that is parked in the lend.
pub const Lent = struct {
    buffered: []const u8 = &.{},
    data: []const []const u8 = &.{},
    splat: usize = 0,
    /// The bytes of all of it.
    len: usize = 0,

    pub fn of(buffered: []const u8, data: []const []const u8, splat: usize) Lent {
        var total = buffered.len;
        if (data.len > 0) {
            for (data[0 .. data.len - 1]) |slice| total += slice.len;
            total += data[data.len - 1].len * splat;
        }
        return .{ .buffered = buffered, .data = data, .splat = splat, .len = total };
    }

    /// `n` bytes of it from `from`, into `w`: the connection's DATA frame.
    pub fn write(self: Lent, w: *std.Io.Writer, from: usize, n: usize) std.Io.Writer.Error!void {
        std.debug.assert(from + n <= self.len);
        var skip = from;
        var left = n;
        if (skip < self.buffered.len) {
            const m = @min(left, self.buffered.len - skip);
            try w.writeAll(self.buffered[skip..][0..m]);
            left -= m;
            skip = 0;
        } else skip -= self.buffered.len;
        if (left == 0 or self.data.len == 0) return;
        for (self.data[0 .. self.data.len - 1]) |slice| {
            if (left == 0) return;
            if (skip >= slice.len) {
                skip -= slice.len;
                continue;
            }
            const m = @min(left, slice.len - skip);
            try w.writeAll(slice[skip..][0..m]);
            left -= m;
            skip = 0;
        }
        const pattern = self.data[self.data.len - 1];
        if (left == 0 or pattern.len == 0) return;
        var at = skip;
        while (left > 0) {
            const i = at % pattern.len;
            const m = @min(left, pattern.len - i);
            try w.writeAll(pattern[i..][0..m]);
            at += m;
            left -= m;
        }
    }
};

pub const Outbox = struct {
    link: inbound.Link,
    /// The request arena, for a call that cannot wait.
    arena: std.mem.Allocator,
    /// Where the call parks.
    wake: bulkhead.Signal = .init,
    can_park: bool = true,

    // Everything below is guarded by `link.monitor`.

    parked: bool = false,

    // Call to connection.
    /// The header block of the answer, and whether it ends the stream (a
    /// HEAD), which the connection knows only when the body ends.
    head: []const u8 = "",
    head_only: bool = false,
    opened: bool = false,
    head_sent: bool = false,
    /// What is lent, and how much of it the connection has written.
    lent: Lent = .{},
    sent: usize = 0,
    pending: bool = false,
    /// The last lend was written, as against failed.
    consumed: bool = false,
    /// For a call that cannot wait: everything it wrote, in order.
    collect: std.ArrayList(u8) = .empty,
    /// The body is over, with the trailers' header block when there are any.
    ending: bool = false,
    trailers: []const u8 = "",

    /// The call returned leaving the body to the connection: an event stream
    /// whose events the rooms post (ADR 227). Not an abandoned answer.
    handed: bool = false,

    // Connection to call.
    /// The end of the stream is written.
    done: bool = false,
    failure: ?Failure = null,

    // ---- the call's side ----

    fn notify(self: *Outbox) void {
        self.link.poke(self.link.ctx);
    }

    /// The connection has stopped writing for good (`Link.dead`): fail this
    /// pipe now, since the wake that would fail it later is not coming.
    /// Called with the monitor held.
    fn goneLocked(self: *Outbox) bool {
        if (self.link.dead) |dead| if (dead.*) {
            if (self.failure == null) self.failure = .gone;
            self.pending = false;
            return true;
        };
        return self.failure != null;
    }

    /// Say what the answer's head is. The connection writes it when it next
    /// looks; `notify` follows once the connection knows where to look.
    pub fn open(self: *Outbox, head: []const u8, head_only: bool) void {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        self.head = head;
        self.head_only = head_only;
        self.opened = true;
        _ = self.goneLocked();
    }

    pub fn wakeConnection(self: *Outbox) void {
        self.notify();
    }

    /// Lend one piece and wait until it is written. An error when the stream
    /// was reset, the client stopped reading past the write deadline or the
    /// connection went: the piece is not written, and nothing more will be.
    pub fn lend(self: *Outbox, buffered: []const u8, data: []const []const u8, splat: usize) error{WriteFailed}!void {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        if (self.goneLocked()) return error.WriteFailed;
        if (!self.can_park) {
            const piece = Lent.of(buffered, data, splat);
            self.collect.ensureUnusedCapacity(self.arena, piece.len) catch return error.WriteFailed;
            self.collect.appendSliceAssumeCapacity(buffered);
            if (data.len > 0) {
                for (data[0 .. data.len - 1]) |slice| self.collect.appendSliceAssumeCapacity(slice);
                for (0..splat) |_| self.collect.appendSliceAssumeCapacity(data[data.len - 1]);
            }
            self.lent = .{ .buffered = self.collect.items, .len = self.collect.items.len };
            self.pending = true;
            return;
        }
        self.lent = Lent.of(buffered, data, splat);
        self.sent = 0;
        self.pending = true;
        self.consumed = false;
        self.notify();
        while (self.pending) self.park();
        if (!self.consumed) return error.WriteFailed;
    }

    /// End the body, with the trailers' header block when there are any, and
    /// wait until the end is written.
    pub fn finish(self: *Outbox, trailers: []const u8) error{WriteFailed}!void {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        if (self.goneLocked()) return error.WriteFailed;
        self.ending = true;
        self.trailers = trailers;
        self.notify();
        if (!self.can_park) return;
        while (!self.done and self.failure == null) self.park();
        if (!self.done) return error.WriteFailed;
    }

    /// Park until the connection says something. The monitor is held on the
    /// way in and out; not cancellable, for the reason in the header.
    fn park(self: *Outbox) void {
        self.parked = true;
        _ = self.link.blocked.fetchAdd(1, .acq_rel);
        self.wake.waitUncancelable(self.link.monitor);
        if (self.parked) {
            self.parked = false;
            _ = self.link.blocked.fetchSub(1, .acq_rel);
        }
    }

    // ---- the connection's side ----

    fn wakeLocked(self: *Outbox) void {
        if (self.parked) {
            self.parked = false;
            _ = self.link.blocked.fetchSub(1, .acq_rel);
        }
        self.wake.wake();
    }

    /// What the connection has to do for this call, taken under the lock and
    /// written without it.
    pub const Work = struct {
        /// The call's pipe is over: failed, or its end written.
        over: bool,
        /// The header block still to write, unless the body decides its flags.
        head: ?[]const u8,
        head_only: bool,
        head_sent: bool,
        lent: Lent,
        sent: usize,
        pending: bool,
        ending: bool,
        trailers: []const u8,
    };

    pub fn take(self: *Outbox) Work {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        return .{
            .over = self.failure != null or self.done,
            .head = if (self.opened and !self.head_sent and !self.head_only) self.head else null,
            .head_only = self.head_only,
            .head_sent = self.head_sent,
            .lent = self.lent,
            .sent = self.sent,
            .pending = self.pending,
            .ending = self.ending,
            .trailers = self.trailers,
        };
    }

    pub fn headWritten(self: *Outbox) void {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        self.head_sent = true;
    }

    /// `sent` bytes of the lent piece are in the connection's writer, and the
    /// call is woken when that is all of it.
    pub fn wrote(self: *Outbox, sent: usize, complete: bool) void {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        self.sent = sent;
        if (complete) {
            self.pending = false;
            self.consumed = true;
            self.wakeLocked();
        }
    }

    /// The end of the stream is written.
    pub fn ended(self: *Outbox) void {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        self.done = true;
        self.wakeLocked();
    }

    /// Nothing more will be written: the call waiting for it is woken to say
    /// so, and what was lent is never read again. The first reason stands.
    pub fn fail(self: *Outbox, why: Failure) void {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        if (self.failure == null) self.failure = why;
        self.pending = false;
        self.wakeLocked();
    }

    /// The body is the connection's from here, and the call may return
    /// without ending it.
    pub fn handedOver(self: *Outbox) void {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        self.handed = true;
    }

    /// Whether the call has begun an answer through this pipe.
    pub fn started(self: *Outbox) bool {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        return self.opened;
    }

    /// The call returned without ending its body or being failed: an answer
    /// that cannot be completed.
    pub fn abandoned(self: *Outbox) bool {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        return !self.pending and !self.ending and !self.done and !self.handed and self.failure == null;
    }

    pub fn isDone(self: *Outbox) bool {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        return self.done;
    }

    pub fn isFailed(self: *Outbox) bool {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        return self.failure != null;
    }
};

// ---- tests ----

const testing = std.testing;

test "a lent piece is written from any offset across the buffer, the slices and the repeated one" {
    const lent = Lent.of("ab", &.{ "cd", "ef", "-" }, 3);
    try testing.expectEqual(@as(usize, 2 + 2 + 2 + 3), lent.len);
    var out: [16]u8 = undefined;
    for (0..lent.len + 1) |from| {
        for (0..lent.len - from + 1) |n| {
            var w: std.Io.Writer = .fixed(&out);
            try lent.write(&w, from, n);
            try testing.expectEqualStrings("abcdef---"[from..][0..n], w.buffered());
        }
    }
}

test "a lent piece with a pattern longer than a byte is cut where a frame ends and resumed inside it" {
    const lent = Lent.of("", &.{"xyz"}, 4);
    var out: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try lent.write(&w, 0, 5);
    try lent.write(&w, 5, 7);
    try testing.expectEqualStrings("xyzxyzxyzxyz", w.buffered());
}

test "a lent piece with no slices past the buffer is the buffer" {
    const lent = Lent.of("hello", &.{}, 0);
    var out: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try lent.write(&w, 1, 3);
    try testing.expectEqualStrings("ell", w.buffered());
}

test "a pipe on a connection that has stopped writing fails at its first lend and its end, and never parks" {
    const Fx = struct {
        monitor: bulkhead.Monitor = .init,
        blocked: std.atomic.Value(u32) = .init(0),
        dead: bool = false,
        pokes: u32 = 0,
        fn poke(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.pokes += 1;
        }
    };
    var fx: Fx = .{};
    const link: inbound.Link = .{ .monitor = &fx.monitor, .blocked = &fx.blocked, .ctx = &fx, .poke = Fx.poke, .dead = &fx.dead };
    var box: Outbox = .{ .link = link, .arena = testing.allocator };
    // Alive: opened and not failed.
    box.open("head", false);
    try testing.expect(box.failure == null);
    fx.dead = true;
    try testing.expectError(error.WriteFailed, box.lend("abc", &.{}, 0));
    try testing.expectError(error.WriteFailed, box.finish(""));
    try testing.expectEqual(Failure.gone, box.failure.?);
    // Opened after: failed at once, so the first lend does not park.
    var late: Outbox = .{ .link = link, .arena = testing.allocator };
    late.open("head", false);
    try testing.expectEqual(Failure.gone, late.failure.?);
    try testing.expectError(error.WriteFailed, late.lend("abc", &.{}, 0));
}
