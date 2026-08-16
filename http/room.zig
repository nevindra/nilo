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
//! **A post arrives already framed** (ADR 0052). A server frame carries no
//! mask and nothing else that differs by recipient, so the WebSocket header
//! is built here, once, and every connection in the room writes the same
//! bytes. Delivery is one `writeAll` per post rather than a header built a
//! thousand times for a thousand copies of the same message.
//!
//! **A broadcast costs what the room holds, not what it was sized for.** The
//! seats are walked through `roll`, which keeps every taken one in front, so a
//! room sized for ten thousand and holding three visits three. It used to
//! visit ten thousand, per message.
//!
//! **A Room is a Service.** `app.provide(&room)` and it arrives by type like
//! anything else, which is the whole of ADR 0022's argument for why a
//! WebSocket is a handler: nothing here is a registration API, a callback, or
//! a shape of its own.

const std = @import("std");

const bulkhead = @import("bulkhead.zig");
const json_mod = @import("json.zig");
const websocket = @import("websocket.zig");

pub const Options = struct {
    /// How many connections may be in this room at once.
    ///
    /// Taken up front, because a room that grows while a broadcast walks it is
    /// a room whose memory nobody can state. `join` past this fails with a
    /// sentence naming the number, which is a server that says what is wrong
    /// rather than one that quietly stops delivering.
    ///
    /// Sizing it generously is cheap in a way it was not before ADR 0052: an
    /// empty seat costs its own bytes and nothing else, because neither `join`
    /// nor `say` walks past the connections that are actually here.
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

/// One message, framed once and held once however many connections are going
/// to read it.
///
/// The frame header and the bytes live immediately after the struct in the
/// same allocation, so a post is one `alloc` and one `free` rather than three
/// of each — and so a connection delivering it writes one slice.
const Post = struct {
    refs: std.atomic.Value(u32),
    kind: websocket.Kind,
    /// How many of the bytes behind this struct are the frame header nilo
    /// wrote, rather than what somebody said. Two, four or ten.
    head: u8,
    /// How many are the message.
    len: usize,

    /// The whole frame, ready for the wire.
    fn framed(self: *const Post) []const u8 {
        const raw: [*]const u8 = @ptrCast(self);
        return raw[@sizeOf(Post)..][0 .. self.head + self.len];
    }

    /// Just the message, for a handler asking what was said.
    fn bytes(self: *const Post) []const u8 {
        const raw: [*]const u8 = @ptrCast(self);
        return raw[@sizeOf(Post) + self.head ..][0..self.len];
    }

    /// Where the message goes while it is being composed.
    fn mutable(self: *Post) []u8 {
        const raw: [*]u8 = @ptrCast(self);
        return raw[@sizeOf(Post) + self.head ..][0..self.len];
    }

    fn block(self: *Post) []align(@alignOf(Post)) u8 {
        const raw: [*]align(@alignOf(Post)) u8 = @ptrCast(self);
        return raw[0 .. @sizeOf(Post) + self.head + self.len];
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
    /// Where this seat sits on the room's roll while it is taken. Meaningless
    /// when it is not, and what makes giving a seat up a swap rather than a
    /// search.
    slot: u32 = 0,
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
    /// Every seat index, exactly once: the first `here` of them are taken and
    /// the rest are free.
    ///
    /// `join` takes the one sitting at `here` and `leave` swaps the leaver
    /// with the last taken one, so both are a handful of stores rather than a
    /// walk, and `say` visits the connections that are actually in the room
    /// rather than every seat it was sized for. A room of ten thousand seats
    /// holding three used to cost ten thousand iterations a message; it costs
    /// three, and four bytes a seat to have (ADR 0052).
    roll: []u32,
    backlog: usize,
    full: Full = .drop_oldest,

    /// Guards taking and giving up a seat. Not held while posting: `say`
    /// reads the roll under it, then works seat by seat under each seat's own
    /// lock, so one slow reader's lock is never on the path of another's.
    roster: bulkhead.Mutex = .{},
    /// How many seats are taken, which is also how much of `roll` is the
    /// taken half. Atomic so that `count()` is a plain read rather than a
    /// lock: it is a number to show people, and taking the roster's lock to
    /// read it would put every handler that says "3 here" behind every
    /// broadcast. Written only under the roster's lock.
    here: std.atomic.Value(usize) = .init(0),

    /// A room of the default size. `deinit` when the app is done with it.
    pub fn init(gpa: std.mem.Allocator) Error!Room {
        return initWith(gpa, .{});
    }

    pub fn initWith(gpa: std.mem.Allocator, options: Options) Error!Room {
        const seats = try gpa.alloc(Seat, options.seats);
        errdefer gpa.free(seats);
        const store = try gpa.alloc(?*Post, options.seats * options.backlog);
        errdefer gpa.free(store);
        @memset(store, null);
        const roll = try gpa.alloc(u32, options.seats);

        for (seats, 0..) |*seat, i| {
            seat.* = .{ .ring = store[i * options.backlog ..][0..options.backlog] };
            roll[i] = @intCast(i);
        }
        return .{
            .gpa = gpa,
            .seats = seats,
            .ring_store = store,
            .roll = roll,
            .backlog = options.backlog,
        };
    }

    pub fn deinit(self: *Room) void {
        // Posts nobody drained. A room outliving its connections is the
        // ordinary shutdown, so this is a normal path rather than a leak
        // check.
        for (self.seats) |*seat| self.drain(seat);
        self.gpa.free(self.roll);
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

        const ticket = self.takeSeat() orelse return error.RoomFull;
        self.seats[ticket.index].waker = socket.waker();
        socket.seatedIn(self, ticket);
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
        self.drain(seat);
        seat.lock.unlock();

        seat.taken = false;
        seat.waker = .off;
        self.giveUpSlot(seat, ticket.index);
    }

    /// Say something to everybody in the room, including whoever said it.
    ///
    /// Returns once every connection has been *told*, which is not the same
    /// as every connection having read it — and is deliberately not the same,
    /// because waiting for the second one is what ties this fiber's liveness
    /// to the slowest client in the room.
    pub fn say(self: *Room, kind: websocket.Kind, data: []const u8) Error!void {
        if (self.empty()) return;

        const post = try self.reserve(kind, data.len);
        // The sender's own reference, released at the end. Without it a post
        // handed to nobody would never be freed, and one drained by a fast
        // reader before a slow seat has taken it would be freed too early.
        defer self.release(post);
        @memcpy(post.mutable(), data);

        return self.handOut(post);
    }

    pub fn sayText(self: *Room, text: []const u8) Error!void {
        return self.say(.text, text);
    }

    pub fn sayBinary(self: *Room, bytes: []const u8) Error!void {
        return self.say(.binary, bytes);
    }

    /// `room.print("{s} joined, {d} here", .{ name, room.count() })` — one
    /// text message to everybody, formatted with no buffer of your own in
    /// between.
    ///
    /// The format runs twice: once to size the post, once to fill it. That is
    /// what a message whose length is not known in advance costs when the
    /// alternative is a fixed buffer you have to guess the size of — and the
    /// allocation is the one `say` was going to make anyway, not a second.
    pub fn print(self: *Room, comptime fmt: []const u8, args: anytype) Error!void {
        if (self.empty()) return;

        const post = try self.reserve(.text, sizeOf(struct {
            fn run(w: *std.Io.Writer, a: anytype) std.Io.Writer.Error!void {
                return w.print(fmt, a);
            }
        }.run, args));
        defer self.release(post);

        var into: std.Io.Writer = .fixed(post.mutable());
        into.print(fmt, args) catch unreachable;
        std.debug.assert(into.end == post.len);

        return self.handOut(post);
    }

    /// Serialise `value` as JSON into one text message to everybody — which
    /// is what a room carrying anything but chat lines is saying.
    pub fn json(self: *Room, value: anytype) Error!void {
        if (self.empty()) return;

        const post = try self.reserve(.text, sizeOf(json_mod.write, value));
        defer self.release(post);

        var into: std.Io.Writer = .fixed(post.mutable());
        json_mod.write(&into, value) catch unreachable;
        std.debug.assert(into.end == post.len);

        return self.handOut(post);
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

    /// One post as one write: nilo's frame header and the bytes behind it,
    /// built once for everybody who is going to get them.
    pub fn framedBytes(_: *Room, post: *const Post) []const u8 {
        return post.framed();
    }

    pub fn contentsOf(_: *Room, post: *const Post) struct { kind: websocket.Kind, data: []const u8 } {
        return .{ .kind = post.kind, .data = post.bytes() };
    }

    pub fn release(self: *Room, post: *Post) void {
        if (post.refs.fetchSub(1, .acq_rel) == 1) self.gpa.free(post.block());
    }

    // ---- inside ----

    /// Nobody here. Worth its own check at the top of everything that says
    /// something: a room is empty most of the time, and a message into one
    /// should cost an atomic load rather than an allocation to throw away.
    fn empty(self: *Room) bool {
        return self.here.load(.monotonic) == 0;
    }

    /// Room for one post, with its frame header already written in front of
    /// where the message goes. The header is built here — once — because a
    /// server frame carries no mask and nothing else that differs by
    /// recipient (ADR 0052).
    fn reserve(self: *Room, kind: websocket.Kind, len: usize) Error!*Post {
        var head: [websocket.max_header]u8 = undefined;
        const framing = websocket.headerFor(&head, kind, len);

        const block = try self.gpa.alignedAlloc(
            u8,
            .fromByteUnits(@alignOf(Post)),
            @sizeOf(Post) + framing.len + len,
        );
        const post: *Post = @ptrCast(block.ptr);
        post.* = .{
            .refs = .init(1),
            .kind = kind,
            .head = @intCast(framing.len),
            .len = len,
        };
        @memcpy(block[@sizeOf(Post)..][0..framing.len], framing);
        return post;
    }

    /// Hand one post to everybody in the room. The roll's taken half, so this
    /// visits the connections that are here and no others.
    fn handOut(self: *Room, post: *Post) Error!void {
        try self.roster.lock();
        defer self.roster.unlock();

        for (self.roll[0..self.here.load(.monotonic)]) |index| {
            self.put(&self.seats[index], post);
        }
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

    /// Take the seat sitting at the front of the roll's free half. The
    /// roster's lock is the caller's.
    fn takeSeat(self: *Room) ?Ticket {
        const taken = self.here.load(.monotonic);
        if (taken == self.seats.len) return null;

        const index = self.roll[taken];
        const seat = &self.seats[index];
        seat.taken = true;
        seat.era +%= 1;
        seat.slot = @intCast(taken);
        seat.dropped = 0;
        self.here.store(taken + 1, .monotonic);
        return .{ .index = index, .era = seat.era };
    }

    /// Put this seat back in the roll's free half by swapping it with the
    /// last taken one, so the taken half stays dense. The roster's lock is
    /// the caller's.
    fn giveUpSlot(self: *Room, seat: *Seat, index: usize) void {
        const last = self.here.load(.monotonic) - 1;
        const moved = self.roll[last];
        self.roll[last] = @intCast(index);
        self.roll[seat.slot] = moved;
        self.seats[moved].slot = seat.slot;
        self.here.store(last, .monotonic);
    }

    /// Release everything queued for a seat. The seat's lock is the caller's,
    /// except in `deinit` where there is nobody left to hold it.
    fn drain(self: *Room, seat: *Seat) void {
        while (seat.count > 0) {
            const post = seat.ring[seat.head].?;
            seat.ring[seat.head] = null;
            seat.head = (seat.head + 1) % self.backlog;
            seat.count -= 1;
            self.release(post);
        }
    }
};

/// How many bytes something would take, without writing any of them. What
/// `print` and `json` size a post with, so neither invents a buffer nor
/// guesses at one.
fn sizeOf(comptime write: anytype, value: anytype) usize {
    // Big enough that a short message is one call into the counter rather
    // than one per piece of the format, and small enough to be free.
    var scratch: [256]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&scratch);
    // A counter has nowhere to fail: its drain throws the bytes away.
    write(&counter.writer, value) catch unreachable;
    return @intCast(counter.fullCount());
}

// ---- tests ----

const testing = std.testing;

/// Sit in a seat without a Socket, for the tests that are about the ring
/// rather than about a connection.
fn sitDown(room: *Room) Ticket {
    return room.takeSeat().?;
}

test "a room hands out a seat and takes it back" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 2 });
    defer room.deinit();

    try testing.expectEqual(@as(usize, 0), room.count());
}

test "saying something into an empty room costs nothing at all" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 2 });
    defer room.deinit();

    // An allocator that refuses everything, so these passing is the whole
    // assertion: a room with nobody in it does not compose a post in order to
    // throw it away.
    room.gpa = testing.failing_allocator;
    try room.sayText("into the void");
    try room.sayBinary(&.{ 1, 2, 3 });
    try room.print("{d} here", .{0});
    try room.json(.{ .nobody = true });
    room.gpa = testing.allocator;
}

test "a post nobody drains is freed rather than leaked" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 2 });
    defer room.deinit();

    // One seat taken and nothing ever read from it. The sender's own
    // reference has to go on the way out, and the seat's has to go in
    // `deinit` — the allocator's leak check is the assertion.
    _ = sitDown(&room);
    try room.sayText("for whoever is sitting there");
}

test "a full backlog drops the oldest and counts it" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 2 });
    defer room.deinit();

    const ticket = sitDown(&room);
    const seat = &room.seats[ticket.index];

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

    const ticket = sitDown(&room);
    const seat = &room.seats[ticket.index];

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

    const stale = sitDown(&room);
    const seat = &room.seats[stale.index];
    try room.sayText("for the one who was here");

    // The seat turns over. Whoever sits here next has era 2, and the post
    // queued for era 1 is not theirs.
    seat.lock.lock() catch unreachable;
    room.drain(seat);
    seat.lock.unlock();
    seat.era +%= 1;

    try testing.expect(room.take(stale) == null);
}

test "a post carries the frame nilo would have written by hand" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 4 });
    defer room.deinit();

    const ticket = sitDown(&room);
    try room.sayText("hello everybody");
    try room.sayBinary("\x00\xff");

    // The header is the room's, built once. What the connection writes is
    // this, whole, with nothing left to work out per recipient.
    const text = room.take(ticket).?;
    try testing.expectEqualStrings("\x81\x0fhello everybody", room.framedBytes(text));
    try testing.expectEqualStrings("hello everybody", room.contentsOf(text).data);
    room.release(text);

    const binary = room.take(ticket).?;
    try testing.expectEqualStrings("\x82\x02\x00\xff", room.framedBytes(binary));
    try testing.expectEqual(websocket.Kind.binary, room.contentsOf(binary).kind);
    room.release(binary);

    // And a message past 125 bytes takes the longer header, still once.
    try room.sayText("z" ** 300);
    const long = room.take(ticket).?;
    const framed = room.framedBytes(long);
    try testing.expectEqualStrings("\x81\x7e\x01\x2c", framed[0..4]);
    try testing.expectEqual(@as(usize, 304), framed.len);
    room.release(long);
}

test "a formatted message and a JSON one need no buffer of the caller's own" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 4 });
    defer room.deinit();

    const ticket = sitDown(&room);
    try room.print("welcome, {d} here", .{7});
    try room.json(.{ .kind = "joined", .here = 7 });

    const greeting = room.take(ticket).?;
    try testing.expectEqualStrings("welcome, 7 here", room.contentsOf(greeting).data);
    try testing.expectEqualStrings("\x81\x0fwelcome, 7 here", room.framedBytes(greeting));
    room.release(greeting);

    const structured = room.take(ticket).?;
    try testing.expectEqualStrings(
        "{\"kind\":\"joined\",\"here\":7}",
        room.contentsOf(structured).data,
    );
    room.release(structured);

    // Longer than the counter's own scratch buffer, so the counting pass has
    // to have drained rather than only measured what it held.
    try room.print("{s}", .{"y" ** 900});
    const long = room.take(ticket).?;
    try testing.expectEqual(@as(usize, 900), room.contentsOf(long).data.len);
    try testing.expectEqualStrings("y" ** 900, room.contentsOf(long).data);
    room.release(long);
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

test "a burst waiting for one connection arrives in the order it was said" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 4 });
    defer room.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: websocket.Socket = .{ ._in = &in, ._out = &out, ._stopping = null };

    try room.join(&socket);
    defer room.leave(&socket);

    try room.sayText("one");
    try room.sayText("two");
    try room.print("and {s}", .{"three"});

    // Three posts, one `receive`, and one flush at the end of them — a
    // connection that was away for a burst catches up in a single syscall.
    var buf: [64]u8 = undefined;
    try testing.expect(try socket.receive(&buf) == null);
    try testing.expectEqualStrings(
        "\x81\x03one\x81\x03two\x81\x09and three",
        out.buffered(),
    );
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

test "the roll keeps every seat once, however the room fills and empties" {
    // The property the whole thing rests on: `roll` is a permutation of the
    // seats with the taken ones in front. Get that wrong and a broadcast
    // either misses somebody or delivers to a seat twice — and a room that
    // has churned for a week is where it would show up, not a test that
    // fills one once.
    var room = try Room.initWith(testing.allocator, .{ .seats = 6, .backlog = 2 });
    defer room.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var sockets: [6]websocket.Socket = undefined;
    for (&sockets) |*s| s.* = .{ ._in = &in, ._out = &out, ._stopping = null };

    // In, out of the middle, out of the front, out of the back, and in again.
    for (&sockets) |*s| try room.join(s);
    try expectWholeRoll(&room);

    room.leave(&sockets[3]);
    try expectWholeRoll(&room);
    room.leave(&sockets[0]);
    try expectWholeRoll(&room);
    room.leave(&sockets[5]);
    try expectWholeRoll(&room);

    try room.join(&sockets[3]);
    try room.join(&sockets[0]);
    try expectWholeRoll(&room);
    try testing.expectEqual(@as(usize, 5), room.count());

    for (&sockets) |*s| room.leave(s);
    try testing.expectEqual(@as(usize, 0), room.count());
    try expectWholeRoll(&room);
}

/// Every seat index exactly once, the taken ones in front, and every taken
/// seat's `slot` pointing back at where it sits.
fn expectWholeRoll(room: *Room) !void {
    var seen = [_]bool{false} ** 64;
    for (room.roll) |index| {
        try testing.expect(!seen[index]);
        seen[index] = true;
    }
    for (seen[0..room.seats.len]) |was| try testing.expect(was);

    const taken = room.count();
    for (room.roll[0..taken], 0..) |index, slot| {
        try testing.expect(room.seats[index].taken);
        try testing.expectEqual(@as(u32, @intCast(slot)), room.seats[index].slot);
    }
    for (room.roll[taken..]) |index| try testing.expect(!room.seats[index].taken);
}

test "a broadcast visits the connections that are here, not the seats there are" {
    // A room sized for a crowd and holding three. What the roll buys is that
    // this costs three visits rather than a thousand, and the way to see it
    // without a clock is that the seats nobody is in are never touched.
    var room = try Room.initWith(testing.allocator, .{ .seats = 1000, .backlog = 2 });
    defer room.deinit();

    var tickets: [3]Ticket = undefined;
    for (&tickets) |*t| t.* = sitDown(&room);

    try room.sayText("everybody");

    var holding: usize = 0;
    for (room.seats) |*seat| holding += seat.count;
    try testing.expectEqual(@as(usize, 3), holding);

    for (tickets) |t| {
        const post = room.take(t).?;
        try testing.expectEqualStrings("everybody", room.contentsOf(post).data);
        room.release(post);
    }
}

test "one post read by many seats is freed once, by the last of them" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 3, .backlog = 2 });
    defer room.deinit();

    var tickets: [3]Ticket = undefined;
    for (&tickets) |*t| t.* = sitDown(&room);

    try room.sayText("everybody");

    // Every seat sees the same bytes, and the allocator's leak check says
    // whether the last release was the one that freed them.
    for (tickets) |ticket| {
        const post = room.take(ticket).?;
        try testing.expectEqualStrings("everybody", room.contentsOf(post).data);
        room.release(post);
    }
}
