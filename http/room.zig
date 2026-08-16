//! A Room — saying something to sockets this handler does not hold.
//!
//! ```zig
//! fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
//!     var socket = try c.upgrade();
//!     try room.join(&socket);
//!     defer room.leave(&socket);
//!
//!     var buf: [16 * 1024]u8 = undefined;
//!     while (try socket.receive(&buf)) |message| {
//!         try room.say(message.kind, message.data);
//!     }
//! }
//! ```
//!
//! The loop is ADR 0022's, unchanged. `receive` grew a second thing to wait
//! for and did not grow a second shape: a post that arrives while this
//! connection is quiet is written out by *this* fiber, inside `receive`,
//! before it goes back to waiting. A handler never sees it and never writes a
//! branch for it.
//!
//! **The speaker never writes to anybody else's socket.** ADR 0029 measured
//! what happens when it does: the broadcast is performed by the speaker's own
//! fiber, so it reaches the first client that has stopped reading and blocks
//! there, and everybody else's messages stop because one client stopped. A
//! lock per socket does not touch that — it was never contention. So `say`
//! copies a pointer into each seat and rings a bell (`Waker.post`), and the
//! writing is done by the fiber that already serves that connection, whose
//! stalling costs that connection alone.
//!
//! **What a post is made of.** One allocation per `say`, refcounted, freed by
//! whichever seat drains it last — not one copy per recipient. The alternative
//! was an inline copy into every seat, which needs no refcount and no
//! allocator and was rejected for what it does to the number ADR 0018 calls a
//! hard invariant: with the bytes inline, memory per idle connection becomes a
//! function of how big a message you allow, and a budget you can state turns
//! into a budget you have to multiply. Here a seat costs the same whether the
//! room is silent or shouting.
//!
//! **A Room is a Service.** `app.provide(&room)` and it arrives by type like
//! anything else, which is the whole of ADR 0022's argument for why a
//! WebSocket is a handler: nothing here is a registration API, a callback, or
//! a shape of its own.

const std = @import("std");

const bulkhead = @import("bulkhead.zig");
const fail = @import("fail.zig");
const websocket = @import("websocket.zig");

pub const Options = struct {
    /// How many connections may be in this room at once.
    ///
    /// Taken up front, because a room that grows while a broadcast walks it is
    /// a room whose memory nobody can state. `join` past this fails with a
    /// sentence naming the number, which is a server that says what is wrong
    /// rather than one that quietly stops delivering.
    seats: usize = 1024,

    /// How many posts one connection may fall behind before the policy below
    /// applies to it.
    ///
    /// Four is not a guess about throughput. It is the smallest number that
    /// lets a connection be mid-write on one post and still take the next
    /// few, which is the whole job — a backlog deep enough to ride out a slow
    /// reader is a backlog deep enough to hide one.
    backlog: usize = 4,
};

/// What happens to a post for a connection whose backlog is full.
///
/// [ADR 0020](../docs/adr/0020-a-request-that-lasts-is-still-one-request.md)
/// refused to have this at all — "a queue with a policy — drop oldest, drop
/// newest, disconnect — is what a pub/sub layer wants, and nilo is not one".
/// A room is one, so the refusal is amended rather than ignored, and the
/// amendment is that the policy is *named at the room* rather than assumed.
pub const Full = enum {
    /// Throw away the oldest post this connection has not read yet. What a
    /// chat wants: the newest message is the one worth having, and a client
    /// that fell behind wants to catch up at the front, not the back.
    drop_oldest,
    /// Throw away the post being sent. What a feed of independent events
    /// wants, where the ones already queued are no less current.
    drop_newest,
};

/// One message, held once however many connections are going to read it.
///
/// The bytes live immediately after the header in the same allocation, so a
/// post is one `alloc` and one `free` rather than two of each.
const Post = struct {
    refs: std.atomic.Value(u32),
    kind: websocket.Kind,
    len: usize,

    fn bytes(self: *const Post) []const u8 {
        const raw: [*]const u8 = @ptrCast(self);
        return raw[@sizeOf(Post)..][0..self.len];
    }

    fn block(self: *Post) []align(@alignOf(Post)) u8 {
        const raw: [*]align(@alignOf(Post)) u8 = @ptrCast(self);
        return raw[0 .. @sizeOf(Post) + self.len];
    }
};

/// One connection's place in the room: a small ring of posts waiting for it,
/// and the bell that tells its fiber to come and get them.
const Seat = struct {
    taken: bool = false,
    /// Bumped every time a seat is taken, so a stale `Ticket` from a
    /// connection that has already left cannot be mistaken for the one now
    /// sitting there. Without it, a handler that forgot its `defer` would
    /// have its posts delivered to whoever arrived next.
    era: u32 = 0,
    waker: bulkhead.Waker = .off,
    lock: bulkhead.Mutex = .{},

    /// A slice of the room's one ring allocation. Empty slots are null.
    ring: []?*Post = &.{},
    head: usize = 0,
    count: usize = 0,

    /// How many posts this connection was too slow to take. Reported rather
    /// than logged: a number a handler can read beats a line in a log nobody
    /// is watching.
    dropped: u64 = 0,
};

/// Where a connection sits, and proof it is still the one sitting there.
pub const Ticket = struct {
    index: usize,
    era: u32,
};

pub const Error = error{
    /// Every seat is taken. The room's `seats` is the number to raise.
    RoomFull,
    OutOfMemory,
    /// The connection was cancelled while waiting for a lock — a shutdown
    /// landing mid-broadcast. The handler is on its way out anyway.
    Canceled,
};

pub const Room = struct {
    gpa: std.mem.Allocator,
    seats: []Seat,
    ring_store: []?*Post,
    backlog: usize,
    full: Full = .drop_oldest,

    /// Guards taking and giving up a seat. Not held while posting: `say`
    /// reads `taken` under it, then works seat by seat under each seat's own
    /// lock, so one slow reader's lock is never on the path of another's.
    roster: bulkhead.Mutex = .{},
    /// Atomic so that `count()` is a plain read rather than a lock. It is a
    /// number to show people, and taking the roster's lock to read it would
    /// put every handler that says "3 here" behind every broadcast.
    here: std.atomic.Value(usize) = .init(0),

    /// A room of the default size. `deinit` when the app is done with it.
    pub fn init(gpa: std.mem.Allocator) Error!Room {
        return initWith(gpa, .{});
    }

    pub fn initWith(gpa: std.mem.Allocator, options: Options) Error!Room {
        const seats = try gpa.alloc(Seat, options.seats);
        errdefer gpa.free(seats);
        const store = try gpa.alloc(?*Post, options.seats * options.backlog);
        @memset(store, null);

        for (seats, 0..) |*seat, i| {
            seat.* = .{ .ring = store[i * options.backlog ..][0..options.backlog] };
        }
        return .{
            .gpa = gpa,
            .seats = seats,
            .ring_store = store,
            .backlog = options.backlog,
        };
    }

    pub fn deinit(self: *Room) void {
        // Posts nobody drained. A room outliving its connections is the
        // ordinary shutdown, so this is a normal path rather than a leak
        // check.
        for (self.seats) |*seat| {
            while (seat.count > 0) {
                const post = seat.ring[seat.head].?;
                seat.ring[seat.head] = null;
                seat.head = (seat.head + 1) % self.backlog;
                seat.count -= 1;
                self.release(post);
            }
        }
        self.gpa.free(self.ring_store);
        self.gpa.free(self.seats);
        self.* = undefined;
    }

    /// How many connections are in the room right now.
    pub fn count(self: *Room) usize {
        return self.here.load(.monotonic);
    }

    /// Take a seat, and tell the socket where it is sitting so `receive` can
    /// drain it.
    ///
    /// Pair it with `defer room.leave(&socket)`. Zig has no destructor to do
    /// it for you, and a seat nobody gives up is one the next connection
    /// cannot have.
    /// A socket with no Engine behind it — one built over a fixed buffer in a
    /// test — is seated like any other. Its bell rings into nothing, but
    /// `receive` drains its seat before it reads either way, so the posts
    /// still arrive and the whole thing is testable without a server. That is
    /// deliberate: a feature only reachable through a real socket is a
    /// feature tested by hand.
    pub fn join(self: *Room, socket: *websocket.Socket) Error!void {
        try self.roster.lock();
        defer self.roster.unlock();

        for (self.seats, 0..) |*seat, i| {
            if (seat.taken) continue;
            seat.taken = true;
            seat.era +%= 1;
            seat.waker = socket.waker();
            seat.dropped = 0;
            _ = self.here.fetchAdd(1, .monotonic);
            socket.seatedIn(self, .{ .index = i, .era = seat.era });
            return;
        }
        return error.RoomFull;
    }

    /// Give the seat up. Safe to call twice, and safe to call on a socket
    /// that never joined — which is what makes `defer room.leave(&socket)`
    /// correct on every path out of a handler, including the failed ones.
    pub fn leave(self: *Room, socket: *websocket.Socket) void {
        const ticket = socket.ticket() orelse return;
        socket.unseat();

        self.roster.lock() catch return;
        defer self.roster.unlock();

        const seat = &self.seats[ticket.index];
        if (!seat.taken or seat.era != ticket.era) return;

        // Under the seat's own lock, because a `say` already past the roster
        // may be pushing into this ring right now.
        seat.lock.lock() catch return;
        defer seat.lock.unlock();

        while (seat.count > 0) {
            const post = seat.ring[seat.head].?;
            seat.ring[seat.head] = null;
            seat.head = (seat.head + 1) % self.backlog;
            seat.count -= 1;
            self.release(post);
        }
        seat.taken = false;
        seat.waker = .off;
        _ = self.here.fetchSub(1, .monotonic);
    }

    /// Say something to everybody in the room, including whoever said it.
    ///
    /// Returns once every connection has been *told*, which is not the same
    /// as every connection having read it — and is deliberately not the same,
    /// because waiting for the second one is what ties this fiber's liveness
    /// to the slowest client in the room.
    pub fn say(self: *Room, kind: websocket.Kind, data: []const u8) Error!void {
        const post = try self.compose(kind, data);
        // The sender's own reference, released at the end. Without it a post
        // handed to nobody would never be freed, and one drained by a fast
        // reader before a slow seat has taken it would be freed too early.
        defer self.release(post);

        try self.roster.lock();
        defer self.roster.unlock();

        for (self.seats) |*seat| {
            if (!seat.taken) continue;
            self.put(seat, post);
        }
    }

    pub fn sayText(self: *Room, text: []const u8) Error!void {
        return self.say(.text, text);
    }

    pub fn sayBinary(self: *Room, bytes: []const u8) Error!void {
        return self.say(.binary, bytes);
    }

    /// How many posts this connection was too slow to take, since it joined.
    pub fn missed(self: *Room, socket: *websocket.Socket) u64 {
        const ticket = socket.ticket() orelse return 0;
        const seat = &self.seats[ticket.index];
        if (!seat.taken or seat.era != ticket.era) return 0;
        return seat.dropped;
    }

    // ---- what the Socket calls ----

    /// Take the next post waiting for this seat, or null. The caller writes it
    /// out and then calls `release`.
    pub fn take(self: *Room, ticket: Ticket) ?*Post {
        const seat = &self.seats[ticket.index];
        seat.lock.lock() catch return null;
        defer seat.lock.unlock();

        if (!seat.taken or seat.era != ticket.era) return null;
        if (seat.count == 0) return null;

        const post = seat.ring[seat.head].?;
        seat.ring[seat.head] = null;
        seat.head = (seat.head + 1) % self.backlog;
        seat.count -= 1;
        return post;
    }

    pub fn contentsOf(_: *Room, post: *const Post) struct { kind: websocket.Kind, data: []const u8 } {
        return .{ .kind = post.kind, .data = post.bytes() };
    }

    pub fn release(self: *Room, post: *Post) void {
        if (post.refs.fetchSub(1, .acq_rel) == 1) self.gpa.free(post.block());
    }

    // ---- inside ----

    fn compose(self: *Room, kind: websocket.Kind, data: []const u8) Error!*Post {
        const block = try self.gpa.alignedAlloc(
            u8,
            .fromByteUnits(@alignOf(Post)),
            @sizeOf(Post) + data.len,
        );
        const post: *Post = @ptrCast(block.ptr);
        post.* = .{ .refs = .init(1), .kind = kind, .len = data.len };
        @memcpy(block[@sizeOf(Post)..], data);
        return post;
    }

    /// Push one post into one seat, applying the policy if it is full. The
    /// seat's own lock, never the roster's: the point of the whole design is
    /// that a slow reader delays nobody but itself.
    fn put(self: *Room, seat: *Seat, post: *Post) void {
        seat.lock.lock() catch return;
        defer seat.lock.unlock();

        if (seat.count == self.backlog) {
            seat.dropped += 1;
            switch (self.full) {
                .drop_newest => return,
                .drop_oldest => {
                    const old = seat.ring[seat.head].?;
                    seat.ring[seat.head] = null;
                    seat.head = (seat.head + 1) % self.backlog;
                    seat.count -= 1;
                    self.release(old);
                },
            }
        }

        _ = post.refs.fetchAdd(1, .acq_rel);
        seat.ring[(seat.head + seat.count) % self.backlog] = post;
        seat.count += 1;

        // Outside the ring update but inside the seat's lock: the fiber being
        // woken takes the same lock to drain, so it cannot start draining
        // until this returns, and cannot miss what was just pushed.
        seat.waker.post();
    }
};

// ---- tests ----

const testing = std.testing;

test "a room hands out a seat and takes it back" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 2 });
    defer room.deinit();

    try testing.expectEqual(@as(usize, 0), room.count());
}

test "a post with no one to hear it is freed rather than leaked" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 2 });
    defer room.deinit();

    // No seats taken. The sender's own reference is the only one, so `say`
    // has to free it on the way out — the allocator's leak check is the
    // assertion.
    try room.sayText("into the void");
}

test "a full backlog drops the oldest and counts it" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 2 });
    defer room.deinit();

    // Sit in seat 0 by hand: this test is about the ring, and a real Socket
    // needs an Engine behind it.
    const seat = &room.seats[0];
    seat.taken = true;
    seat.era = 1;
    room.here.store(1, .monotonic);
    const ticket: Ticket = .{ .index = 0, .era = 1 };

    try room.sayText("one");
    try room.sayText("two");
    try room.sayText("three");

    try testing.expectEqual(@as(u64, 1), seat.dropped);

    const first = room.take(ticket).?;
    try testing.expectEqualStrings("two", room.contentsOf(first).data);
    room.release(first);

    const second = room.take(ticket).?;
    try testing.expectEqualStrings("three", room.contentsOf(second).data);
    room.release(second);

    try testing.expect(room.take(ticket) == null);
}

test "dropping the newest keeps what was already queued" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 2 });
    defer room.deinit();
    room.full = .drop_newest;

    const seat = &room.seats[0];
    seat.taken = true;
    seat.era = 1;
    room.here.store(1, .monotonic);
    const ticket: Ticket = .{ .index = 0, .era = 1 };

    try room.sayText("one");
    try room.sayText("two");
    try room.sayText("three");

    try testing.expectEqual(@as(u64, 1), seat.dropped);
    const first = room.take(ticket).?;
    try testing.expectEqualStrings("one", room.contentsOf(first).data);
    room.release(first);
}

test "a ticket from a connection that has left delivers nothing" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 2 });
    defer room.deinit();

    const seat = &room.seats[0];
    seat.taken = true;
    seat.era = 1;
    room.here.store(1, .monotonic);

    const stale: Ticket = .{ .index = 0, .era = 1 };
    try room.sayText("for the one who was here");

    // The seat turns over. Whoever sits here next has era 2, and the post
    // queued for era 1 is not theirs.
    seat.lock.lock() catch unreachable;
    while (seat.count > 0) {
        const post = seat.ring[seat.head].?;
        seat.ring[seat.head] = null;
        seat.head = (seat.head + 1) % room.backlog;
        seat.count -= 1;
        room.release(post);
    }
    seat.lock.unlock();
    seat.era = 2;

    try testing.expect(room.take(stale) == null);
}

test "what one connection says reaches a socket another handler is holding" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 4, .backlog = 4 });
    defer room.deinit();

    // Two connections, each the way a handler holds one: a Socket over this
    // side's reader and writer. No Engine, so nothing can ring their bells —
    // and it does not have to, because `receive` drains its seat before it
    // reads.
    var listener_in = std.Io.Reader.fixed("");
    var listener_bytes: [256]u8 = undefined;
    var listener_out = std.Io.Writer.fixed(&listener_bytes);
    var listener: websocket.Socket = .{
        ._in = &listener_in,
        ._out = &listener_out,
        ._stopping = null,
    };

    var speaker_in = std.Io.Reader.fixed("");
    var speaker_bytes: [256]u8 = undefined;
    var speaker_out = std.Io.Writer.fixed(&speaker_bytes);
    var speaker: websocket.Socket = .{
        ._in = &speaker_in,
        ._out = &speaker_out,
        ._stopping = null,
    };

    try room.join(&listener);
    defer room.leave(&listener);
    try room.join(&speaker);
    defer room.leave(&speaker);

    try room.sayText("hello everybody");

    // The listener's own fiber is what writes it out, inside `receive`. Its
    // reader is empty, so the call ends by saying the connection is over —
    // after the post has gone.
    var buf: [64]u8 = undefined;
    try testing.expect(try listener.receive(&buf) == null);

    // One unmasked text frame: a server never masks. 0x81, then the length,
    // then the bytes.
    try testing.expectEqualStrings("\x81\x0fhello everybody", listener_out.buffered());

    // And the speaker hears itself, which is what a chat wants — one code
    // path for "say something", not one for me and one for everyone else.
    try testing.expect(try speaker.receive(&buf) == null);
    try testing.expectEqualStrings("\x81\x0fhello everybody", speaker_out.buffered());
}

test "a seat given up stops receiving, and frees what it never read" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 4 });
    defer room.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: websocket.Socket = .{ ._in = &in, ._out = &out, ._stopping = null };

    try room.join(&socket);
    try testing.expectEqual(@as(usize, 1), room.count());

    try room.sayText("before");
    // Left with a post still queued. The allocator's leak check is what says
    // whether giving the seat up released it.
    room.leave(&socket);
    try testing.expectEqual(@as(usize, 0), room.count());

    try room.sayText("after");

    // Nothing written: the socket is not in the room any more, and `receive`
    // has no seat to drain.
    var buf: [64]u8 = undefined;
    try testing.expect(try socket.receive(&buf) == null);
    try testing.expectEqualStrings("", out.buffered());
}

test "leaving twice, and leaving without joining, are both fine" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 2 });
    defer room.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: websocket.Socket = .{ ._in = &in, ._out = &out, ._stopping = null };

    // `defer room.leave(&socket)` has to be correct on every path out of a
    // handler, including the ones that never got as far as joining.
    room.leave(&socket);

    try room.join(&socket);
    room.leave(&socket);
    room.leave(&socket);
    try testing.expectEqual(@as(usize, 0), room.count());
}

test "a room that is full says so, naming nothing it cannot" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 2 });
    defer room.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var first: websocket.Socket = .{ ._in = &in, ._out = &out, ._stopping = null };
    var second: websocket.Socket = .{ ._in = &in, ._out = &out, ._stopping = null };

    try room.join(&first);
    defer room.leave(&first);
    try testing.expectError(error.RoomFull, room.join(&second));
}

test "one post read by many seats is freed once, by the last of them" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 3, .backlog = 2 });
    defer room.deinit();

    for (room.seats) |*seat| {
        seat.taken = true;
        seat.era = 1;
    }
    room.here.store(3, .monotonic);

    try room.sayText("everybody");

    // Every seat sees the same bytes, and the allocator's leak check says
    // whether the last release was the one that freed them.
    for (0..3) |i| {
        const ticket: Ticket = .{ .index = i, .era = 1 };
        const post = room.take(ticket).?;
        try testing.expectEqualStrings("everybody", room.contentsOf(post).data);
        room.release(post);
    }
}
