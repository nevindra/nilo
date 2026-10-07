//! The inbound pipe of a request on HTTP/2: what the client sends after its
//! headers, from the connection's fiber to the request's
//! ([ADR 260](../docs/adr/260-a-request-on-http2-runs-from-its-headers.md)).
//!
//! A request on HTTP/2 runs when its header block is whole, so its body is
//! still on the wire when the handler starts. **The connection's fiber is the
//! only one that touches the socket** (ADR 220), so the call never waits on the
//! socket: it waits on this. The connection reads a stream's `DATA` into
//! `buf`, the call reads out of it through `reader`, a `std.Io.Reader` the
//! `Ctx` takes for the connection's own, and one of the two waits for the
//! other: the call when the buffer is empty and the stream has not ended, the
//! connection never (what it holds is bounded by the client's windows).
//!
//! **What the call has read is given back.** `freed` counts the bytes a read
//! took out of the buffer and `owed` the bytes the client may be told it can
//! send again; the connection reads both when the call says there is
//! something (`attention`), turns them into `WINDOW_UPDATE` frames and into
//! room in its budget (ADR 220), and so a stream holds at most its window of
//! unread bytes whatever its handler does. A call says so once a half window
//! has been read, not at every read: one wake of the connection's fiber for
//! 32 KiB of body.
//!
//! **A body that is asked for whole is not read out.** `whole` waits for the
//! stream to end and hands back the bytes where they lie, in this buffer, with
//! no copy and no allocation; it is how `c.body()` and a gRPC message are
//! read. From then on the stream is *collecting*: its window is given back as
//! the bytes arrive, held to the connection's budget, because nothing will
//! read them out (what a `bodyStream` handler does is the other half).
//!
//! **The buffer is the stream's, not the request arena's**, and one lock, the
//! connection's `Monitor`, guards everything here. The arena is the call's
//! alone, and the call can be on another thread than the connection's
//! (`bulkhead.spawnLocal`), so the connection never allocates from it. Space
//! consumed is reused: the bytes a reader has taken are moved out of the way
//! when the next frame needs room, so an upload through a buffer of 4 KiB
//! never holds more than its window however long it is.
//!
//! A call that waits is *parked* (`blocked` counts them), which is all a
//! scheduler that has to know when every call that can run has run needs to
//! see: the tests drive a connection that way when no Engine runs.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");
const h2 = @import("h2.zig");

/// Why a read ended without the body.
pub const Failure = enum {
    /// The stream was reset, or the connection went with it.
    gone,
    /// The client stopped sending: the read's bound passed.
    slow,
    /// The request's own deadline passed while it waited.
    deadline,
    /// The DATA did not add up to the `content-length` the client sent.
    length,
};

/// What the call needs to reach the connection, and nothing else of it.
pub const Link = struct {
    /// The lock every field below `link` is guarded by.
    monitor: *bulkhead.Monitor,
    /// Calls of this connection parked in a wait.
    blocked: *std.atomic.Value(u32),
    /// Tell the connection there is something to read here, and wake it. A
    /// call can outlive its connection, so what `poke` does once the
    /// connection has gone is nothing; that is the connection's to know, not
    /// this file's.
    ctx: *anyopaque,
    poke: *const fn (ctx: *anyopaque) void,
};

/// How many bytes a call reads before it tells the connection: a half window,
/// where the connection's own top-up of a window is.
const credit_every: usize = h2.default_window / 2;

/// What a stream keeps for the next one: the buffer of a small body.
pub const spare_keep = 4096;

pub const Inbox = struct {
    /// The body as the call reads it. Unbuffered: the bytes are in `buf`, and
    /// a read copies them where the caller said.
    reader: std.Io.Reader,
    link: Link,
    gpa: std.mem.Allocator,
    /// Where the call parks.
    wake: bulkhead.Signal = .init,
    /// Whether a wait may park. False where nothing could wake it: a
    /// connection driven with no Engine and no scheduler, which runs a call
    /// only once its stream has ended.
    can_park: bool = true,

    // Everything below is guarded by `link.monitor`.

    /// The bytes of the body not yet read are `buf[rd..len]`.
    buf: []u8 = &.{},
    rd: usize = 0,
    len: usize = 0,
    /// Every byte of DATA the stream has carried, dropped ones included.
    total: u64 = 0,
    ended: bool = false,
    failure: ?Failure = null,
    /// Nothing reads the bytes out: they are held for `whole`.
    collecting: bool = false,
    /// The most a collecting stream keeps unread.
    limit: usize,
    /// Bytes past `limit` were dropped.
    over: bool = false,

    // Call to connection.
    /// Bytes a read took out of the buffer: memory the connection's budget
    /// gets back.
    freed: usize = 0,
    /// Bytes the client may be given window for.
    owed: usize = 0,
    /// Bytes read since the connection was last told.
    since: usize = 0,
    /// The call wants `100 Continue` sent, once.
    cont: bool = false,
    cont_asked: bool = false,
    /// Room the call wants charged to the budget before it copies (a gzip
    /// message inflating), until `grant` says it is.
    want: usize = 0,
    granted: bool = false,
    parked: bool = false,

    // The bounds.
    /// How long a body asked for whole may take in all, and how long a read
    /// of a stream may find nothing: the rules a chunked HTTP/1.1 body is held
    /// to (`Deadlines.armBodyRun`, `armBody`), 0 for none.
    run_ms: u32 = 0,
    silence_ms: u32 = 0,
    /// The request's own deadline as a `monotonicNanos` reading, or 0.
    until_ns: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, link: Link, limit: usize) Inbox {
        return .{
            .reader = .{
                .vtable = &.{ .stream = streamFn, .discard = discardFn },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
            .link = link,
            .gpa = gpa,
            .limit = limit,
        };
    }

    /// Ready for the next stream: a small buffer is kept, a larger one given
    /// back. Nobody is waiting on it.
    pub fn recycle(self: *Inbox, limit: usize) void {
        var kept = self.buf;
        if (kept.len > spare_keep) {
            self.gpa.free(kept);
            kept = &.{};
        }
        self.* = init(self.gpa, self.link, limit);
        self.buf = kept;
    }

    pub fn deinit(self: *Inbox) void {
        if (self.buf.len > 0) self.gpa.free(self.buf);
        self.buf = &.{};
    }

    /// The pipe a reader is the reader of.
    pub fn of(r: *std.Io.Reader) *Inbox {
        return @alignCast(@fieldParentPtr("reader", r));
    }

    // ---- the connection's side ----

    /// Room for the next `n` bytes of DATA: where to read them to, and how
    /// many are to be dropped because the stream is collecting and its limit
    /// is reached. The bytes are not there until `commit`.
    pub const Slot = struct { dest: []u8, drop: usize, collecting: bool };

    pub fn begin(self: *Inbox, n: usize) error{OutOfMemory}!Slot {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        var keep = n;
        if (self.collecting) keep = @min(n, self.limit -| (self.len - self.rd));
        if (self.rd == self.len) {
            self.rd = 0;
            self.len = 0;
        }
        if (self.len + keep > self.buf.len) {
            // What a reader has taken goes first, so a long upload through a
            // small window stays in the buffer it started with.
            if (self.rd > 0) {
                std.mem.copyForwards(u8, self.buf[0 .. self.len - self.rd], self.buf[self.rd..self.len]);
                self.len -= self.rd;
                self.rd = 0;
            }
            if (self.len + keep > self.buf.len) {
                // Grown as bytes arrive and never to what the client announced:
                // a content-length is a claim, and what a connection allocates
                // is what the budget has been charged for (ADR 220), at most
                // twice it by the doubling. A stream nothing reads out is held
                // to its window, and one that is collected to its limit, so
                // the doubling stops there.
                const cap = if (self.collecting) self.limit else h2.default_window;
                const size = @max(self.len + keep, @min(self.buf.len * 2, cap), 512);
                self.buf = self.gpa.realloc(self.buf, size) catch return error.OutOfMemory;
            }
        }
        return .{ .dest = self.buf[self.len..][0..keep], .drop = n - keep, .collecting = self.collecting };
    }

    /// What `commit` found: how many of the bytes stayed, and whether the
    /// stream is collecting *now*, which the call may have made it between
    /// `begin` and here.
    pub const Committed = struct { kept: usize, collecting: bool };

    /// `kept` bytes are in the buffer, and `dropped` were thrown away. A call
    /// that asked for the whole body since `begin` made the stream collecting,
    /// and its limit then applies to this frame too: what does not fit is
    /// dropped here, under the lock, and the connection credits the frame by
    /// what is returned and not by what `begin` saw.
    pub fn commit(self: *Inbox, kept: usize, dropped: usize) Committed {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        var stays = kept;
        var thrown = dropped;
        if (self.collecting) {
            const room = self.limit -| (self.len - self.rd);
            if (stays > room) {
                thrown += stays - room;
                stays = room;
            }
        }
        self.len += stays;
        self.total += kept + dropped;
        if (thrown > 0) self.over = true;
        self.wakeLocked();
        return .{ .kept = stays, .collecting = self.collecting };
    }

    /// DATA that has nowhere to go, counted: what a length check reads.
    pub fn count(self: *Inbox, n: usize) u64 {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        self.total += n;
        return self.total;
    }

    /// The client has sent everything.
    pub fn end(self: *Inbox) void {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        self.ended = true;
        self.wakeLocked();
    }

    /// The body will not be completed, and a call waiting for it is woken
    /// to say so. The first reason stands.
    pub fn fail(self: *Inbox, why: Failure) void {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        if (self.failure == null) self.failure = why;
        self.wakeLocked();
    }

    /// What the call has told the connection since it last asked.
    pub const Taken = struct { freed: usize = 0, owed: usize = 0, cont: bool = false, want: usize = 0, collecting: bool = false };

    pub fn take(self: *Inbox) Taken {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        const t: Taken = .{
            .freed = self.freed,
            .owed = self.owed,
            .cont = self.cont,
            .want = if (self.granted or self.failure != null) 0 else self.want,
            .collecting = self.collecting,
        };
        self.freed = 0;
        self.owed = 0;
        self.cont = false;
        self.since = 0;
        return t;
    }

    /// The room the call is waiting to be given, or 0.
    pub fn wanted(self: *Inbox) usize {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        return if (self.granted or self.failure != null) 0 else self.want;
    }

    /// Say the room is the call's. False when it has stopped waiting (its
    /// deadline passed or the stream was reset) and nothing was charged.
    pub fn grant(self: *Inbox, n: usize) bool {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        if (self.granted or self.want != n or self.failure != null) return false;
        self.granted = true;
        self.wakeLocked();
        return true;
    }

    /// Whether the stream's bytes are held for `whole` rather than read out.
    pub fn isCollecting(self: *Inbox) bool {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        return self.collecting;
    }

    /// The unread bytes the buffer holds now.
    pub fn buffered(self: *Inbox) usize {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        return self.len - self.rd;
    }

    fn wakeLocked(self: *Inbox) void {
        if (self.parked) {
            self.parked = false;
            _ = self.link.blocked.fetchSub(1, .acq_rel);
        }
        self.wake.wake();
    }

    // ---- the call's side ----

    fn notify(self: *Inbox) void {
        self.link.poke(self.link.ctx);
    }

    /// Set the request's own deadline, which every wait is clamped to.
    pub fn setDeadline(self: *Inbox, until_ns: u64) void {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        self.until_ns = until_ns;
    }

    /// The client said `Expect: 100-continue` and the handler is about to read
    /// a body: ask for the interim answer, unless the body has started to
    /// arrive, which is what the client would have been told to do (ADR 073).
    pub fn askContinue(self: *Inbox) void {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        if (self.cont_asked or self.ended or self.total > 0) return;
        self.cont_asked = true;
        self.cont = true;
        self.notify();
    }

    /// Why the last read failed.
    pub fn cause(self: *Inbox) ?Failure {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        return self.failure;
    }

    /// Park until woken or `deadline_ns` (0 for no bound of its own), whichever
    /// is first, clamped to the request's deadline. The monitor is held on the
    /// way in and out. False when the bound passed: `failure` is set then.
    fn park(self: *Inbox, deadline_ns: u64) bool {
        if (!self.can_park) {
            if (self.failure == null) self.failure = .gone;
            return false;
        }
        var until = deadline_ns;
        if (self.until_ns != 0) until = if (until == 0) self.until_ns else @min(until, self.until_ns);
        var ms: ?u64 = null;
        if (until != 0) {
            const now = bulkhead.monotonicNanos();
            if (now >= until) return self.timedOut(deadline_ns);
            ms = (until - now + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
        }
        self.parked = true;
        _ = self.link.blocked.fetchAdd(1, .acq_rel);
        const result = self.wake.wait(self.link.monitor, ms);
        if (self.parked) {
            self.parked = false;
            _ = self.link.blocked.fetchSub(1, .acq_rel);
        }
        result catch |err| switch (err) {
            error.Canceled => {
                if (self.failure == null) self.failure = .gone;
                return false;
            },
            error.TimedOut => {
                // Woken by the clock: only past the bound is that the end.
                if (until != 0 and bulkhead.monotonicNanos() >= until) return self.timedOut(deadline_ns);
            },
        };
        return true;
    }

    fn timedOut(self: *Inbox, deadline_ns: u64) bool {
        if (self.failure == null) {
            const now = bulkhead.monotonicNanos();
            self.failure = if (self.until_ns != 0 and now >= self.until_ns and (deadline_ns == 0 or self.until_ns <= deadline_ns)) .deadline else .slow;
        }
        return false;
    }

    /// The bytes as they lie, once the stream has ended: waits for the end
    /// where it has not. From here on the connection gives the stream's
    /// window back as bytes arrive and holds them to its budget, since no
    /// read will free them.
    pub fn whole(self: *Inbox, max: usize) error{ BodyTooLarge, BodyTooSlow, EndOfStream }![]const u8 {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        if (!self.collecting) {
            self.collecting = true;
            // What arrived while nothing was reading, which the client has
            // not been told it may replace.
            self.owed += self.len - self.rd;
            self.notify();
        }
        var run_deadline: u64 = 0;
        while (true) {
            // A message that arrived whole is the call's even if the stream
            // was reset after: a route that has been given a call runs it to
            // the end, and a reset still counts against the cap until it does
            // (rapid reset, ADR 220).
            if (self.ended and (self.failure == null or self.failure == .gone)) {
                if (self.over or self.len - self.rd > max) return error.BodyTooLarge;
                return self.buf[self.rd..self.len];
            }
            if (self.failure) |why| return switch (why) {
                .slow, .deadline => error.BodyTooSlow,
                .gone, .length => error.EndOfStream,
            };
            if (self.over or self.len - self.rd > max) return error.BodyTooLarge;
            // Both bounds a chunked HTTP/1.1 body is held to: the whole of it
            // inside the run the rate allows, and no stretch of silence past
            // `body_ms`, which every byte that arrives starts again.
            const now = bulkhead.monotonicNanos();
            if (run_deadline == 0 and self.run_ms != 0) run_deadline = now + @as(u64, self.run_ms) * std.time.ns_per_ms;
            var bound = run_deadline;
            if (self.silence_ms != 0) {
                const quiet = now + @as(u64, self.silence_ms) * std.time.ns_per_ms;
                bound = if (bound == 0) quiet else @min(bound, quiet);
            }
            _ = self.park(bound);
        }
    }

    /// Wait for room the connection's budget has to be told about, and be
    /// charged it: `n` bytes, before the call makes the copy. An error when
    /// the call's deadline passed first or the stream is gone. Nothing waits
    /// where nothing could wake it (`can_park`), and nothing is charged.
    pub fn reserve(self: *Inbox, n: usize) error{ BodyTooSlow, EndOfStream }!void {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        if (!self.can_park) return;
        self.want = n;
        self.granted = false;
        self.notify();
        while (!self.granted) {
            if (self.failure) |why| {
                self.want = 0;
                return switch (why) {
                    .slow, .deadline => error.BodyTooSlow,
                    .gone, .length => error.EndOfStream,
                };
            }
            _ = self.park(0);
        }
        self.want = 0;
    }

    fn released(self: *Inbox, n: usize) void {
        self.freed += n;
        self.owed += n;
        self.since += n;
        if (self.since >= credit_every) {
            self.since = 0;
            self.notify();
        }
    }

    /// The most a read into a writer with no buffer of its own copies at a
    /// time, on the call's stack: small, because a suspended fiber keeps its
    /// stack at the high-water mark (ADR 062).
    const bare_chunk = 512;

    fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self = of(r);
        if (limit == .nothing) return 0;
        // Room in the writer first, and without the monitor: making room is
        // the writer's drain, which may write to a file or a socket or wait,
        // and nothing of the caller's runs while every stream of the
        // connection is locked out. The copy under the lock is then memory to
        // memory.
        var bare: [bare_chunk]u8 = undefined;
        const room: []u8 = if (w.buffer.len == 0) &bare else w.writableSliceGreedy(1) catch return error.WriteFailed;
        const most = limit.minInt(room.len);
        const got = try self.pull(room[0..most]);
        if (w.buffer.len == 0) {
            w.writeAll(room[0..got]) catch return error.WriteFailed;
        } else w.advance(got);
        return got;
    }

    /// Copy what is buffered, at most `into.len`, waiting for some where there
    /// is none. Under the monitor; touches no writer.
    fn pull(self: *Inbox, into: []u8) std.Io.Reader.StreamError!usize {
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        var deadline: u64 = 0;
        while (true) {
            if (self.failure) |why| if (!(self.ended and why == .gone)) return error.ReadFailed;
            const available = self.len - self.rd;
            if (available > 0) {
                const n = @min(available, into.len);
                @memcpy(into[0..n], self.buf[self.rd..][0..n]);
                self.rd += n;
                self.released(n);
                return n;
            }
            if (self.ended) return error.EndOfStream;
            if (deadline == 0 and self.silence_ms != 0) deadline = bulkhead.monotonicNanos() + @as(u64, self.silence_ms) * std.time.ns_per_ms;
            _ = self.park(deadline);
        }
    }

    fn discardFn(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self = of(r);
        if (limit == .nothing) return 0;
        self.link.monitor.enter();
        defer self.link.monitor.leave();
        var deadline: u64 = 0;
        while (true) {
            if (self.failure) |why| if (!(self.ended and why == .gone)) return error.ReadFailed;
            const available = self.len - self.rd;
            if (available > 0) {
                const n = limit.minInt(available);
                self.rd += n;
                self.released(n);
                return n;
            }
            if (self.ended) return error.EndOfStream;
            if (deadline == 0 and self.silence_ms != 0) deadline = bulkhead.monotonicNanos() + @as(u64, self.silence_ms) * std.time.ns_per_ms;
            _ = self.park(deadline);
        }
    }
};

// ---- tests ----

const testing = std.testing;

/// What a connection gives a pipe, counting the times the pipe asked for it.
const Fixture = struct {
    monitor: bulkhead.Monitor = .init,
    blocked: std.atomic.Value(u32) = .init(0),
    pokes: std.atomic.Value(u32) = .init(0),

    fn link(self: *Fixture) Link {
        return .{ .monitor = &self.monitor, .blocked = &self.blocked, .ctx = self, .poke = poke };
    }

    fn poke(ctx: *anyopaque) void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        _ = self.pokes.fetchAdd(1, .acq_rel);
    }
};

/// DATA of `n` bytes arriving as the connection would put it.
fn arrive(inbox: *Inbox, bytes: []const u8) !void {
    const slot = try inbox.begin(bytes.len);
    @memcpy(slot.dest, bytes[0..slot.dest.len]);
    _ = inbox.commit(slot.dest.len, slot.drop);
}

fn pause(ms: u64) void {
    bulkhead.sleep(ms) catch {};
}

test "a body that arrived whole is handed over where it lies, with no copy and no allocation" {
    var fx: Fixture = .{};
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var inbox = Inbox.init(failing.allocator(), fx.link(), 1 << 20);
    defer inbox.deinit();
    try arrive(&inbox, "hello, ");
    try arrive(&inbox, "world");
    inbox.end();

    const before = failing.alloc_index;
    const got = try inbox.whole(1 << 20);
    try testing.expectEqualStrings("hello, world", got);
    try testing.expectEqual(before, failing.alloc_index);
    try testing.expect(got.ptr == inbox.buf.ptr);
}

test "bytes a read took are given back once a half window has been read, and not at every read" {
    var fx: Fixture = .{};
    var inbox = Inbox.init(testing.allocator, fx.link(), 1 << 20);
    defer inbox.deinit();
    const chunk = [_]u8{'x'} ** 16_000;
    for (0..4) |_| try arrive(&inbox, &chunk);

    var sink: [10_000]u8 = undefined;
    for (0..3) |_| try inbox.reader.readSliceAll(&sink);
    try testing.expectEqual(@as(u32, 0), fx.pokes.load(.acquire));
    for (0..1) |_| try inbox.reader.readSliceAll(&sink);
    // 40,000 bytes read: past 32,767, so the connection is told once.
    try testing.expectEqual(@as(u32, 1), fx.pokes.load(.acquire));
    const said = inbox.take();
    try testing.expectEqual(@as(usize, 40_000), said.freed);
    try testing.expectEqual(@as(usize, 40_000), said.owed);
}

test "an upload through the buffer never holds more than one frame however long it is" {
    var fx: Fixture = .{};
    var inbox = Inbox.init(testing.allocator, fx.link(), 1 << 20);
    defer inbox.deinit();
    const frame = [_]u8{'u'} ** 16_000;
    var sink: [16_000]u8 = undefined;
    for (0..50) |_| {
        try arrive(&inbox, &frame);
        try inbox.reader.readSliceAll(&sink);
    }
    try testing.expectEqual(@as(usize, 16_000), inbox.buf.len);
}

test "a read that finds the buffer empty waits on another thread for bytes and ends when the stream does" {
    var fx: Fixture = .{};
    var inbox = Inbox.init(testing.allocator, fx.link(), 1 << 20);
    defer inbox.deinit();
    const feeder = try std.Thread.spawn(.{}, struct {
        fn run(i: *Inbox) void {
            pause(20);
            arrive(i, "late ") catch return;
            pause(20);
            arrive(i, "bytes") catch return;
            i.end();
        }
    }.run, .{&inbox});
    defer feeder.join();

    var got: [10]u8 = undefined;
    try inbox.reader.readSliceAll(&got);
    try testing.expectEqualStrings("late bytes", &got);
    var one: [1]u8 = undefined;
    try testing.expectError(error.EndOfStream, inbox.reader.readSliceAll(&one));
}

test "a reset wakes a call that is waiting, and says the stream is gone" {
    var fx: Fixture = .{};
    var inbox = Inbox.init(testing.allocator, fx.link(), 1 << 20);
    defer inbox.deinit();
    const resetter = try std.Thread.spawn(.{}, struct {
        fn run(i: *Inbox) void {
            pause(20);
            i.fail(.gone);
        }
    }.run, .{&inbox});
    defer resetter.join();

    var one: [1]u8 = undefined;
    try testing.expectError(error.ReadFailed, inbox.reader.readSliceAll(&one));
    try testing.expectEqual(Failure.gone, inbox.cause().?);
    try testing.expectEqual(@as(u32, 0), fx.blocked.load(.acquire));
}

test "a client that sends nothing for the silence limit fails the read as slow" {
    var fx: Fixture = .{};
    var inbox = Inbox.init(testing.allocator, fx.link(), 1 << 20);
    defer inbox.deinit();
    inbox.silence_ms = 30;
    var one: [1]u8 = undefined;
    try testing.expectError(error.ReadFailed, inbox.reader.readSliceAll(&one));
    try testing.expectEqual(Failure.slow, inbox.cause().?);
}

test "a request's own deadline ends a wait before the silence limit does, and is told apart" {
    var fx: Fixture = .{};
    var inbox = Inbox.init(testing.allocator, fx.link(), 1 << 20);
    defer inbox.deinit();
    inbox.silence_ms = 5_000;
    inbox.setDeadline(bulkhead.monotonicNanos() + 20 * std.time.ns_per_ms);
    try testing.expectError(error.BodyTooSlow, inbox.whole(100));
    try testing.expectEqual(Failure.deadline, inbox.cause().?);
}

test "asking for the whole body flips the stream to collecting and owes the window for what arrived" {
    var fx: Fixture = .{};
    var inbox = Inbox.init(testing.allocator, fx.link(), 1 << 20);
    defer inbox.deinit();
    try arrive(&inbox, "abc");
    inbox.end();
    _ = try inbox.whole(10);
    try testing.expect(inbox.isCollecting());
    try testing.expectEqual(@as(usize, 3), inbox.take().owed);
}

test "a body past the limit is dropped as it arrives and refused when asked for" {
    var fx: Fixture = .{};
    var inbox = Inbox.init(testing.allocator, fx.link(), 8);
    defer inbox.deinit();
    inbox.collecting = true;
    try arrive(&inbox, "0123456789");
    inbox.end();
    try testing.expectEqual(@as(usize, 8), inbox.buffered());
    try testing.expectError(error.BodyTooLarge, inbox.whole(8));
}

test "a stream that was reset after its body was whole still hands the body over" {
    var fx: Fixture = .{};
    var inbox = Inbox.init(testing.allocator, fx.link(), 100);
    defer inbox.deinit();
    try arrive(&inbox, "whole");
    inbox.end();
    inbox.fail(.gone);
    try testing.expectEqualStrings("whole", try inbox.whole(100));
}

test "100 Continue is asked for once, and not when the body has begun or is whole" {
    var fx: Fixture = .{};
    var inbox = Inbox.init(testing.allocator, fx.link(), 100);
    defer inbox.deinit();
    inbox.askContinue();
    inbox.askContinue();
    try testing.expectEqual(@as(u32, 1), fx.pokes.load(.acquire));
    try testing.expect(inbox.take().cont);

    var begun = Inbox.init(testing.allocator, fx.link(), 100);
    defer begun.deinit();
    try arrive(&begun, "x");
    begun.askContinue();
    try testing.expect(!begun.take().cont);
}

/// A writer that says whether the monitor was held while it drained, as a
/// sink that writes to a file or a socket would be waiting under it.
const WatchedSink = struct {
    writer: std.Io.Writer,
    monitor: *bulkhead.Monitor,
    held: bool = false,
    total: usize = 0,

    fn init(buffer: []u8, monitor: *bulkhead.Monitor) WatchedSink {
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer }, .monitor = monitor };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *WatchedSink = @alignCast(@fieldParentPtr("writer", w));
        if (self.monitor._lock.tryLock()) self.monitor._lock.unlock() else self.held = true;
        self.total += w.end;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| n += d.len;
        n += data[data.len - 1].len * splat;
        self.total += n;
        return n;
    }
};

test "a read into a writer never runs the writer's drain under the monitor, buffered or not" {
    var fx: Fixture = .{};
    var inbox = Inbox.init(testing.allocator, fx.link(), 1 << 20);
    defer inbox.deinit();
    const chunk = [_]u8{'s'} ** 3_000;
    for (0..10) |_| try arrive(&inbox, &chunk);

    var small: [64]u8 = undefined;
    var buffered = WatchedSink.init(&small, &fx.monitor);
    while (inbox.buffered() > 0) _ = try inbox.reader.stream(&buffered.writer, .unlimited);
    try buffered.writer.flush();
    try testing.expect(!buffered.held);
    try testing.expectEqual(@as(usize, 30_000), buffered.total);

    for (0..10) |_| try arrive(&inbox, &chunk);
    var bare = WatchedSink.init(&.{}, &fx.monitor);
    while (inbox.buffered() > 0) _ = try inbox.reader.stream(&bare.writer, .unlimited);
    try testing.expect(!bare.held);
    try testing.expectEqual(@as(usize, 30_000), bare.total);
}

test "a frame committed after the call asked for the whole body is held to the limit and credited as collected" {
    var fx: Fixture = .{};
    var inbox = Inbox.init(testing.allocator, fx.link(), 8);
    defer inbox.deinit();
    // `begin` saw a stream nothing collects, so it made room for all ten.
    const slot = try inbox.begin(10);
    try testing.expect(!slot.collecting);
    @memcpy(slot.dest, "0123456789");
    // The call asks for the whole body before the frame is committed.
    inbox.collecting = true;
    const done = inbox.commit(slot.dest.len, slot.drop);
    try testing.expect(done.collecting);
    try testing.expectEqual(@as(usize, 8), done.kept);
    try testing.expectEqual(@as(usize, 8), inbox.buffered());
    try testing.expect(inbox.over);
}
