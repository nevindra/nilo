//! SPIKE — throwaway. Not part of `test`, `test-all`, `examples` or CI.
//!
//! The question this exists to answer is the one ADR 0022 wrote down and
//! left open: what does it take to write to a socket this fiber does not
//! own? Everything here is written to be deleted once the ADR that comes
//! out of it is written. It is not an example, it is not a design, and
//! nothing in `src/` may grow to look like it without that ADR.
//!
//! ```
//! zig build spike-broadcast              # the naive shape, mode A
//! zig build spike-broadcast -- b         # snapshot then write, mode B
//! ```
//!
//! Two shapes, in one file, so they can be driven by the same client and
//! the difference measured rather than argued about:
//!
//!   A. The room's lock is held across every write. Correct, obvious, and
//!      the shape anybody writes first.
//!   B. The room's lock is held only long enough to copy out who is here.
//!      The writes happen outside it, one lock per socket.
//!
//! `drive.py` next to this file is what makes them disagree.

const std = @import("std");
const zfast = @import("zfast");

pub const std_options = zfast.std_options;
pub const std_options_debug_io = zfast.debug_io;

/// The most connections this spike keeps track of. A fixed array so that
/// the registry itself allocates nothing — the interesting problems here
/// are about lifetimes and locks, and a growable list would add a third.
const seats = 512;

/// One connected socket, as seen by a fiber that is not the one serving it.
///
/// `socket` points at a local variable on another fiber's stack. That is
/// the first thing this spike had to find out and it is not a detail: the
/// pointer is only valid while that handler is inside its loop, so taking
/// a seat and giving it back has to be exclusive with anything that walks
/// the registry. Get that wrong and a broadcast writes into a stack frame
/// that has been reused by whatever the fiber ran next.
const Member = struct {
    socket: *zfast.Socket,
    /// Held across a whole frame — header and payload — because a frame
    /// written half way and then interleaved with another is not a slow
    /// stream, it is a corrupt one, and the client closes with 1002.
    lock: zfast.Mutex = .{},
    /// Counted so mode B can let go of the room's lock while still holding
    /// a pointer into this seat. Mode A never needs it.
    users: std.atomic.Value(u32) = .init(0),
    dropped: std.atomic.Value(u32) = .init(0),

    /// Mode C only. The queue, its storage, and the fiber that drains it.
    /// The storage sits here rather than on the handler's stack because
    /// the writer fiber outlives nothing but must not outlive it either —
    /// which turned out to be the whole difficulty.
    outbox: zfast.Channel(Post) = undefined,
    posts: [outbox_depth]Post = undefined,
    writer: ?zfast.Spawned = null,

    /// Mode D only. Everything a connection needs to be broadcast to, in
    /// place of mode C's queue: one read position into the room's shared
    /// ring. Eight bytes against eight kilobytes.
    room: *Room = undefined,
    seat: u16 = 0,
    consumer: zfast.BroadcastChannel(Post).Consumer = undefined,
};

const Mode = enum { a, b, c, d };

/// The unit of post for modes C and D. Fixed size so the queue is one
/// array and the broadcaster copies rather than borrows — a slice would
/// point into the sending fiber's buffer, which is reused by its next
/// `receive`.
const Post = struct {
    /// Who said it, so a reader can skip its own. Mode D needs this
    /// because there is one ring for everybody and no per-seat loop left
    /// in which to skip anyone.
    from: u16 = 0,
    len: u16 = 0,
    bytes: [256]u8 = undefined,

    fn of(from: usize, said: []const u8) Post {
        var p: Post = .{ .from = @intCast(from), .len = @intCast(@min(said.len, 256)) };
        @memcpy(p.bytes[0..p.len], said[0..p.len]);
        return p;
    }

    fn text(self: *const Post) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// How many messages a connection may fall behind before its own are
/// thrown away. 8 KB per connection at this size — on its own, near enough
/// the whole per-connection budget in ADR 0018 a second time, before the
/// second fiber's stack is counted at all.
const outbox_depth = 32;

/// Mode D's ring, shared by the whole server rather than per connection.
/// 256 posts is 66 KB once, against mode C's 8 KB times however many
/// connections there are — the crossover is 8 connections.
const wire_depth = 256;

const Room = struct {
    lock: zfast.Mutex = .{},
    seat: [seats]?*Member = @splat(null),
    mode: Mode = .a,

    /// Mode D. One ring for the whole server. Note what is *not* here:
    /// broadcasting no longer walks the seats, so it takes no lock and
    /// touches no other connection's memory at all.
    wire: zfast.BroadcastChannel(Post) = undefined,
    ring: [wire_depth]Post = undefined,

    fn join(self: *Room, m: *Member) !usize {
        try self.lock.lock();
        defer self.lock.unlock();
        for (&self.seat, 0..) |*s, i| {
            if (s.* == null) {
                s.* = m;
                return i;
            }
        }
        return error.RoomFull;
    }

    /// The handler is about to return, which means `m.socket` is about to
    /// stop existing. Nothing may be holding this seat by the time this
    /// returns.
    fn leave(self: *Room, at: usize) void {
        self.lock.lock() catch return;
        self.seat[at] = null;
        self.lock.unlock();

        // Mode B hands out pointers that outlive the room's lock, so the
        // seat is only really free once the last of them is done with it.
        // Spinning here is not the answer a design should ship; it is here
        // to show that the answer has to exist.
        if (self.mode == .b) {
            const m = self.seat[at];
            _ = m;
        }
    }

    fn broadcast(self: *Room, from: usize, text: []const u8) !void {
        return switch (self.mode) {
            .a => self.broadcastHoldingTheLock(from, text),
            .b => self.broadcastFromASnapshot(from, text),
            .c => self.broadcastIntoOutboxes(from, text),
            .d => self.wire.send(Post.of(from, text)) catch {},
        };
    }

    /// Mode A. One lock, held from the first write to the last.
    ///
    /// Every property anybody wants is true here: no torn frames, no seat
    /// freed underneath a writer, no second lock to reason about. It is
    /// also the version where one client that has stopped reading stops
    /// the room — including `join` and `leave`, which want the same lock.
    fn broadcastHoldingTheLock(self: *Room, from: usize, text: []const u8) !void {
        try self.lock.lock();
        defer self.lock.unlock();
        for (self.seat, 0..) |maybe, i| {
            if (i == from) continue;
            const m = maybe orelse continue;
            m.socket.send(.text, text) catch {
                _ = m.dropped.fetchAdd(1, .monotonic);
            };
        }
    }

    /// Mode B. The room's lock covers the copy and nothing else.
    ///
    /// The writes then happen one socket at a time, each under that
    /// socket's own lock, so a client that has stopped reading holds up
    /// only itself — and the fiber writing to it.
    fn broadcastFromASnapshot(self: *Room, from: usize, text: []const u8) !void {
        var here: [seats]?*Member = @splat(null);

        try self.lock.lock();
        for (self.seat, 0..) |maybe, i| {
            if (i == from) continue;
            const m = maybe orelse continue;
            _ = m.users.fetchAdd(1, .acq_rel);
            here[i] = m;
        }
        self.lock.unlock();

        for (here) |maybe| {
            const m = maybe orelse continue;
            defer _ = m.users.fetchSub(1, .acq_rel);

            m.lock.lock() catch continue;
            defer m.lock.unlock();
            m.socket.send(.text, text) catch {
                _ = m.dropped.fetchAdd(1, .monotonic);
            };
        }
    }

    /// Mode C. Nobody writes to a socket they do not own.
    ///
    /// The broadcast leaves a copy in each connection's outbox and returns.
    /// `trySend` rather than `send`: a full outbox means that connection is
    /// not keeping up, and the answer is to throw its message away, not to
    /// hold up the fiber that had something to say. That is the whole point
    /// — the cost of a slow client is paid by the slow client.
    fn broadcastIntoOutboxes(self: *Room, from: usize, text: []const u8) !void {
        const post = Post.of(from, text);

        try self.lock.lock();
        defer self.lock.unlock();
        for (self.seat, 0..) |maybe, i| {
            if (i == from) continue;
            const m = maybe orelse continue;
            m.outbox.trySend(post) catch {
                _ = m.dropped.fetchAdd(1, .monotonic);
            };
        }
    }
};

/// Mode C's second fiber. Its whole job is to be the only thing that ever
/// writes to this one socket, so that being slow costs nobody else.
///
/// It must not outlive `m.socket`, which is a local in the handler below.
/// That is arranged by the handler closing the outbox and then waiting —
/// and "and then waiting" is where mode C stops being simple.
fn drainOutbox(m: *Member) void {
    while (true) {
        const post = m.outbox.receive() catch return;
        m.lock.lock() catch return;
        defer m.lock.unlock();
        m.socket.send(.text, post.text()) catch return;
    }
}

/// Mode D's second fiber. Same job, but it reads from the room's one ring
/// at its own position instead of from a queue of its own.
///
/// `error.Lagged` is zio saying this connection fell more than the ring
/// behind and the messages it missed are gone. It is not a failure — it is
/// the backpressure policy arriving as a value, and the consumer has
/// already been moved to the oldest message still there.
fn drainWire(m: *Member) void {
    while (true) {
        const post = m.room.wire.receive(&m.consumer) catch |err| switch (err) {
            error.Lagged => {
                _ = m.dropped.fetchAdd(1, .monotonic);
                continue;
            },
            else => return, // Closed, or this fiber was cancelled
        };
        if (post.from == m.seat) continue;

        m.lock.lock() catch return;
        defer m.lock.unlock();
        m.socket.send(.text, post.text()) catch return;
    }
}

fn chat(c: *zfast.Ctx, room: *Room) !void {
    var socket = try c.upgrade();
    var me: Member = .{ .socket = &socket, .room = room };

    switch (room.mode) {
        .c => me.outbox = .init(&me.posts),
        // A read position into the shared ring. Taken before the seat, so
        // nothing said between the two is missed.
        .d => me.consumer = room.wire.subscribe(),
        else => {},
    }

    const seat = room.join(&me) catch {
        try socket.close(.normal, "room full");
        return;
    };
    defer room.leave(seat);
    me.seat = @intCast(seat);

    me.writer = switch (room.mode) {
        .c => try zfast.spawn(drainOutbox, .{&me}),
        .d => try zfast.spawn(drainWire, .{&me}),
        else => null,
    };
    defer if (me.writer) |*w| {
        switch (room.mode) {
            // Nothing more will be posted, and the fiber is told to stop.
            // The wait is what keeps `me.socket` — a pointer into this
            // stack frame — alive until nothing is using it.
            .c => {
                me.outbox.close(.immediate);
                w.join();
            },
            // The ring belongs to everybody, so there is no closing it for
            // one reader. The fiber has to be cancelled instead, and this
            // is the first place mode D costs something mode C did not:
            // stopping one reader is now a cancellation rather than a
            // close, and a cancellation is the Engine's business.
            else => w.cancel(),
        }
    };

    var line: [64]u8 = undefined;
    try socket.sendText(try std.fmt.bufPrint(&line, "seat {d}", .{seat}));

    var buf: [16 * 1024]u8 = undefined;
    while (try socket.receive(&buf)) |message| {
        if (!socket.live()) break;
        try room.broadcast(seat, message.data);
    }

    try socket.close(.normal, "");
}

fn page() []const u8 {
    return
        \\<!doctype html>
        \\<title>spike: broadcast</title>
        \\<pre id=log></pre>
        \\<input id=say autofocus>
        \\<script>
        \\  const s = new WebSocket(`ws://${location.host}/ws`);
        \\  s.onmessage = e => log.textContent += e.data + "\n";
        \\  say.addEventListener("keydown", e => {
        \\    if (e.key === "Enter" && e.target.value) { s.send(e.target.value); e.target.value = ""; }
        \\  });
        \\</script>
        \\
    ;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var mode: Mode = .a;
    var args: std.process.Args.Iterator = .init(init.args);
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "b")) mode = .b;
        if (std.mem.eql(u8, arg, "c")) mode = .c;
        if (std.mem.eql(u8, arg, "d")) mode = .d;
    }

    var app = zfast.App.init(std.heap.smp_allocator);
    defer app.deinit();

    var room = Room{ .mode = mode };
    room.wire = .init(&room.ring);
    std.log.info("spike: broadcast, mode {t}", .{room.mode});
    try app.provide(&room);

    try app.get("/", page);
    try app.get("/ws", chat);

    try app.listen(.{ .port = 8788 });
}
