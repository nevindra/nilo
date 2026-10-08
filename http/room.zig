//! A Room — saying something to sockets this handler does not hold.
//!
//! ```zig
//! fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
//!     return c.upgrade(chatLoop, room);
//! }
//!
//! fn chatLoop(socket: *nilo.Socket, room: *nilo.Room) !void {
//!     try room.join(socket);
//!     defer room.leave(socket);
//!
//!     while (try socket.receive()) |message| {
//!         try room.say(message.kind, message.data);
//!     }
//! }
//! ```
//!
//! The loop is the echo server's, unchanged. `receive` grew a second thing to wait
//! for and did not grow a second shape: a post that arrives while this
//! connection is quiet is written out by *this* fiber, inside `receive`,
//! before it goes back to waiting. A handler never sees it and never writes a
//! branch for it.
//!
//! **The speaker never writes to anybody else's socket.** ADR 028 measured
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
//! allocator and was rejected for what it does to the number ADR 017 calls a
//! hard invariant: with the bytes inline, memory per idle connection becomes a
//! function of how big a message you allow, and a budget you can state turns
//! into a budget you have to multiply. Here a seat costs the same whether the
//! room is silent or shouting.
//!
//! **A post arrives already framed** (ADR 046). A server frame carries no
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
//! anything else, which is the whole of ADR 021's argument for why a
//! WebSocket is a handler: nothing here is a registration API, a callback, or
//! a shape of its own.
//!
//! **An event stream sits in a room as well** (ADR 227). `c.eventsFrom(room,
//! .{})` hands the stream to the connection, which drains its seats the way a
//! Socket's `receive` does, so one room reaches browser tabs on either. A post
//! is framed for a WebSocket once, here, and written as event-stream lines by
//! each stream as it goes out, because those lines are the same bytes for
//! every stream and cost nothing to build a second time next to the syscall.

const std = @import("std");

const bulkhead = @import("bulkhead.zig");
const json_mod = @import("json.zig");
const stream_mod = @import("stream.zig");
const websocket = @import("websocket.zig");

pub const Options = struct {
    /// How many connections may be in this room at once.
    ///
    /// Taken up front, because a room that grows while a broadcast walks it is
    /// a room whose memory nobody can state. `join` past this fails with a
    /// sentence naming the number, which is a server that says what is wrong
    /// rather than one that quietly stops delivering.
    ///
    /// Sizing it generously is cheap in a way it was not before ADR 046: an
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

    /// How many of the room's latest text posts it keeps for an event stream
    /// that comes back. A browser reconnecting sends `Last-Event-ID`, the id
    /// of the last event it read, and `eventsFrom` writes what this room said
    /// after that one before anything new (ADR 229). Zero, the default, keeps
    /// nothing, and a room that keeps nothing costs nothing for having the
    /// option.
    ///
    /// A post is found by the id `event` gave it, so a room that keeps
    /// posts wants every post to have one: a `say` in between carries no id,
    /// and a browser that read it still reports the id before it.
    history: usize = 0,

    /// The most bytes the kept posts may hold between them, each counted
    /// whole, header and all. The oldest goes first when a new one would pass
    /// it, and a post bigger than this on its own is not kept. So what a room
    /// holding history costs is this number, and not a count times the
    /// biggest message anybody might say.
    history_bytes: usize = 64 * 1024,
};

/// What happens to a post for a connection whose backlog is full.
///
/// [ADR 019](../docs/adr/019-a-request-that-lasts-is-still-one-request.md)
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
/// of each — and so a connection delivering it writes one slice. An event's
/// name and id, when it has them, follow the message in the same block: a
/// WebSocket never reads them and an event stream writes them as fields.
pub const Post = struct {
    refs: std.atomic.Value(u32),
    kind: websocket.Kind,
    /// How many of the bytes behind this struct are the frame header nilo
    /// wrote, rather than what somebody said. Two, four or ten.
    head: u8,
    /// The `event:` and `id:` an event stream sends with it. Zero for a post
    /// from `say`, which a stream sends as a plain `message`.
    name_len: u32 = 0,
    id_len: u32 = 0,
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

    /// The event's name and id, behind the message.
    fn fields(self: *Post) []u8 {
        const raw: [*]u8 = @ptrCast(self);
        return raw[@sizeOf(Post) + self.head + self.len ..][0 .. self.name_len + self.id_len];
    }

    fn name(self: *const Post) []const u8 {
        const raw: [*]const u8 = @ptrCast(self);
        return raw[@sizeOf(Post) + self.head + self.len ..][0..self.name_len];
    }

    fn id(self: *const Post) []const u8 {
        const raw: [*]const u8 = @ptrCast(self);
        return raw[@sizeOf(Post) + self.head + self.len + self.name_len ..][0..self.id_len];
    }

    fn block(self: *Post) []align(@alignOf(Post)) u8 {
        const raw: [*]align(@alignOf(Post)) u8 = @ptrCast(self);
        return raw[0 .. @sizeOf(Post) + self.head + self.len + self.name_len + self.id_len];
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
    /// An event stream sits here, and an event stream is text: a binary post
    /// is counted in `dropped` rather than queued, because there is no way to
    /// write it as event-stream lines that a browser reads back as the same
    /// bytes.
    text_only: bool = false,

    /// A slice of the room's one ring allocation. Empty slots are null.
    ring: []?*Post = &.{},
    head: usize = 0,
    count: usize = 0,

    /// How many posts this connection was too slow to take. Reported rather
    /// than logged: a number a handler can read beats a line in a log nobody
    /// is watching.
    ///
    /// Atomic because `missed` reads it and does not take this seat's lock to
    /// do so — it is a counter to show somebody, and putting a handler asking
    /// for it behind a broadcast would cost more than the number is worth.
    /// It used to be a plain `u64` read outside the lock that guards it, which
    /// nothing tears on but which is a race all the same.
    ///
    /// Every write is under the seat's lock, so the increment is a load and a
    /// store rather than an atomic add: the lock is what makes it exclusive,
    /// and the atomic is only there so the reader is not racing.
    dropped: std.atomic.Value(u64) = .init(0),

    /// The next room the connection in this seat sits in. See `Seating`.
    next: Seating = .{},
};

/// Where a connection sits, and proof it is still the one sitting there.
///
/// `u32` because `roll` already is: a room has at most that many seats, and
/// the narrower index is what keeps a `Seating` at sixteen bytes.
pub const Ticket = struct {
    index: u32,
    era: u32,
};

/// One room a connection sits in, and through that seat the next one.
///
/// A connection holds the first of these and every seat holds the one after
/// it, so a connection in any number of rooms carries sixteen bytes however
/// many it joins, and a room pays sixteen bytes a seat for being joinable
/// alongside others. The cost sits on the seat for ADR 046's reason: a seat
/// is paid for once, when the room is made, and a connection is the number
/// ADR 017 holds.
///
/// **Only the connection's own fiber touches the chain.** It joins, it
/// leaves, it drains, and the loop's end gives up what is left; a speaker
/// touches a seat's ring and its bell and never `next`. So the chain needs
/// no lock of its own, and a seat's lock is not held while walking it.
pub const Seating = struct {
    room: ?*Room = null,
    ticket: Ticket = .{ .index = 0, .era = 0 },
};

pub const Error = error{
    /// Every seat is taken. The room's `seats` is the number to raise.
    RoomFull,
    /// An event's name or id has a line break in it, which on an event
    /// stream would end the field early and start a field nobody sent.
    EventFieldBreaksLine,
    /// A `print` or `json` whose two passes disagreed, so its post was
    /// dropped rather than sent with a length that was wrong (ADR 076).
    WriteFailed,
    OutOfMemory,
    /// The connection was cancelled while waiting for a lock — a shutdown
    /// landing mid-broadcast. The handler is on its way out anyway.
    Canceled,
};

pub const Room = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Room";

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
    /// three, and four bytes a seat to have (ADR 046).
    roll: []u32,
    backlog: usize,
    full: Full = .drop_oldest,

    /// The latest text posts, oldest at `kept_head`, for an event stream
    /// coming back with `Last-Event-ID` (ADR 229). Empty unless `history`
    /// asked for some. Written under the roster's lock, where `handOut`
    /// already is.
    kept: []?*Post = &.{},
    kept_head: usize = 0,
    kept_count: usize = 0,
    kept_bytes: usize = 0,
    kept_limit: usize = 0,

    /// Told when a seat has been given up, so whoever lent this room out can
    /// take it back once nobody is in it. `Rooms` sets it on the rooms in its
    /// pool (ADR 228); a room somebody made for themselves has none. A
    /// pointer rather than a call, so that `stand`, which every program with a
    /// WebSocket links, does not link the pool.
    vacated: ?*const fn (*Room) void = null,

    /// Guards taking and giving up a seat, and **held for the whole of a
    /// broadcast**: `handOut` takes it, walks the roll's taken half under it,
    /// and takes each seat's own lock inside that. So `join` and `leave` queue
    /// behind whatever is being posted.
    ///
    /// What that hold does *not* cost is the thing worth having. A post is
    /// pushed into a seat's ring and a bell is rung; the bytes reach the wire
    /// on the connection's own fiber, outside every lock in this file. A
    /// client that has stopped reading holds nothing here, so one slow reader
    /// is never on another's path (ADR 028).
    ///
    /// Releasing the roster before the loop is not the small change it looks
    /// like. `leave` drains a seat under this lock and `takeSeat` does not
    /// drain before handing one out, so a post landing between the two would
    /// be delivered to whoever sits down next. Nothing catches it: `put` reads
    /// no era, and `take` reads the *new* occupant's, which matches. Making
    /// the shorter hold correct means draining in `takeSeat` as well, and
    /// showing the contention was real first. Nothing measures a Room under
    /// load yet.
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
        errdefer gpa.free(roll);
        const kept = try gpa.alloc(?*Post, options.history);
        @memset(kept, null);

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
            .kept = kept,
            .kept_limit = options.history_bytes,
        };
    }

    pub fn deinit(self: *Room) void {
        // Posts nobody drained. A room outliving its connections is the
        // ordinary shutdown, so this is a normal path rather than a leak
        // check.
        for (self.seats) |*seat| self.drain(seat);
        while (self.kept_count > 0) self.forgetOldest();
        self.gpa.free(self.kept);
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
    /// Pair it with `defer room.leave(&socket)`, which gives the seat up the
    /// moment the handler is done with the room. When the loop returns, nilo
    /// gives up whatever seat is still taken, because the seat's bell is in
    /// the connection's frame and a seat left behind would ring it after the
    /// frame has gone.
    ///
    /// Joining the room the socket is already in does nothing. Joining
    /// another as well is a seat in each, drained by the same `receive`: a
    /// lobby and a channel of its own, or everybody and one user's tabs.
    /// A socket with no Engine behind it — one built over a fixed buffer in a
    /// test — is seated like any other. Its bell rings into nothing, but
    /// `receive` drains its seats before it reads either way, so the posts
    /// still arrive and the whole thing is testable without a server. That is
    /// deliberate: a feature only reachable through a real socket is a
    /// feature tested by hand.
    pub fn join(self: *Room, socket: *websocket.Socket) Error!void {
        return self.sit(socket.seating(), socket.waker(), false);
    }

    /// Give the seat up. Safe to call twice, and safe to call on a socket
    /// that never joined — which is what makes `defer room.leave(&socket)`
    /// correct on every path out of a handler, including the failed ones.
    /// The socket's other rooms keep their seats.
    pub fn leave(self: *Room, socket: *websocket.Socket) void {
        self.stand(socket.seating());
    }

    /// `join`, for whatever holds a chain and a bell: a Socket, or an event
    /// stream handed to its connection. nilo's own; a handler joins a Socket.
    pub fn sit(self: *Room, first: *Seating, waker: bulkhead.Waker, text_only: bool) Error!void {
        _ = try self.sitAfter(first, waker, text_only, "", &.{});
    }

    /// `sit`, and under the same lock the kept posts that followed the one
    /// whose id is `last_id`, each with a reference the caller writes out and
    /// then `release`s. Returns how many went into `into`, which has room for
    /// `keeps()` of them.
    ///
    /// **One lock for both is the whole point.** Seated first, a post landing
    /// between the two would be in the seat and in the copy, and written
    /// twice; copied first, a post landing between would be in neither.
    pub fn sitAfter(
        self: *Room,
        first: *Seating,
        waker: bulkhead.Waker,
        text_only: bool,
        last_id: []const u8,
        into: []*Post,
    ) Error!usize {
        if (self.find(first.*) != null) return 0;

        try self.roster.lock();
        defer self.roster.unlock();

        const ticket = self.takeSeat() orelse return error.RoomFull;
        const seat = &self.seats[ticket.index];
        seat.waker = waker;
        seat.text_only = text_only;
        // In front of the rooms it already sits in. The order is nobody's to
        // rely on: every seat is drained before the connection waits,
        // whichever rang.
        seat.next = first.*;
        first.* = .{ .room = self, .ticket = ticket };
        return self.keptAfter(last_id, into);
    }

    /// How many posts this room keeps for a stream that comes back.
    pub fn keeps(self: *const Room) usize {
        return self.kept.len;
    }

    /// Throw away every kept post. What `Rooms` does before it lends this
    /// room out under another name, so one user's history is never read by
    /// the next.
    pub fn forget(self: *Room) void {
        self.roster.lockUncancelable();
        defer self.roster.unlock();
        while (self.kept_count > 0) self.forgetOldest();
    }

    /// `leave`, for whatever `sit` seated.
    pub fn stand(self: *Room, first: *Seating) void {
        // Found by room rather than read off the front: a ticket is an index
        // into one room's seats, and read against another room's it would
        // give up a seat that is not this connection's and leave the one that
        // is.
        const ticket = self.unlink(first) orelse return;
        self.giveUp(ticket);
        // After the roster's lock is let go, because whoever lent the room
        // out takes a lock of its own, and a pool's lock taken inside a
        // room's would order the two differently from every other path.
        if (self.vacated) |told| told(self);
    }

    fn giveUp(self: *Room, ticket: Ticket) void {
        // **Neither of these may be the cancellable `lock`.** Both used to be,
        // and both gave up the same way — `catch return` — on the one error
        // they can return, which is `Canceled`: what a fiber gets when the
        // server is shutting down. Returning here leaves `seat.taken` true and
        // `seat.waker` pointing into the `Socket` of a handler on its way out,
        // so the next `say` walks the roll, finds the seat still on the taken
        // half, pushes a post into its ring and rings a bell whose fiber has
        // ended. `zio.Mutex.lock` tries uncontended first and only then checks
        // cancellation, so it takes a broadcast in flight at the moment the
        // connection is cancelled — narrow, and a use-after-free.
        //
        // Giving a seat up is short, takes no other lock and waits for
        // nothing, which is what makes it safe to make uninterruptible.
        self.roster.lockUncancelable();
        defer self.roster.unlock();

        const seat = &self.seats[ticket.index];
        if (!seat.taken or seat.era != ticket.era) return;

        // Under the seat's own lock, because a `say` already past the roster
        // may be pushing into this ring right now.
        seat.lock.lockUncancelable();
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
    ///
    /// **If the two passes disagree** (a value another fiber was writing, a
    /// format that is not repeatable) nothing is posted and the call is
    /// `error.WriteFailed`. A Room has a buffer to check the second pass
    /// against, so it can refuse the post and keep the room; a Socket cannot,
    /// and closes (ADR 076).
    pub fn print(self: *Room, comptime fmt: []const u8, args: anytype) Error!void {
        if (self.empty()) return;

        const post = try self.reserve(.text, sizeOf(struct {
            fn run(w: *std.Io.Writer, a: anytype) std.Io.Writer.Error!void {
                return w.print(fmt, a);
            }
        }.run, args));
        defer self.release(post);

        var into: std.Io.Writer = .fixed(post.mutable());
        try agreed(into.print(fmt, args), &into, post);

        return self.handOut(post);
    }

    /// Serialise `value` as JSON into one text message to everybody — which
    /// is what a room carrying anything but chat lines is saying.
    pub fn json(self: *Room, value: anytype) Error!void {
        if (self.empty()) return;

        const post = try self.reserve(.text, sizeOf(json_mod.write, value));
        defer self.release(post);

        var into: std.Io.Writer = .fixed(post.mutable());
        try agreed(json_mod.write(&into, value), &into, post);

        return self.handOut(post);
    }

    /// One event with a name, an id or both, to everybody. An event stream
    /// sends `event:` and `id:` with it; a WebSocket gets `data` as a text
    /// message, because a frame has nowhere to carry the other two.
    ///
    /// A line break in `name` or `id` is `error.EventFieldBreaksLine` and
    /// nothing is said, the rule `Events.send` keeps: on the wire it would end
    /// the field and begin one nobody sent.
    pub fn event(self: *Room, e: stream_mod.Event) Error!void {
        if (std.mem.indexOfAny(u8, e.name, "\r\n") != null) return error.EventFieldBreaksLine;
        if (std.mem.indexOfAny(u8, e.id, "\r\n") != null) return error.EventFieldBreaksLine;
        if (self.empty()) return;

        const post = try self.reserveFields(.text, e.data.len, e.name.len, e.id.len);
        defer self.release(post);
        @memcpy(post.mutable(), e.data);
        const fields = post.fields();
        @memcpy(fields[0..e.name.len], e.name);
        @memcpy(fields[e.name.len..], e.id);

        return self.handOut(post);
    }

    /// How many posts this connection was too slow to take, since it joined.
    pub fn missed(self: *Room, socket: *websocket.Socket) u64 {
        const ticket = self.find(socket.seating().*) orelse return 0;
        const seat = &self.seats[ticket.index];
        if (!seat.taken or seat.era != ticket.era) return 0;
        return seat.dropped.load(.monotonic);
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

    /// A post as an event stream writes it: its name and id, when `event`
    /// gave it any, and the message as its data.
    pub fn eventOf(_: *Room, post: *const Post) stream_mod.Event {
        return .{ .name = post.name(), .id = post.id(), .data = post.bytes() };
    }

    pub fn release(self: *Room, post: *Post) void {
        if (post.refs.fetchSub(1, .acq_rel) == 1) self.gpa.free(post.block());
    }

    /// The room the connection in this seat sits in after this one, or an
    /// empty `Seating` at the end of the chain.
    pub fn after(self: *Room, ticket: Ticket) Seating {
        return self.seats[ticket.index].next;
    }

    // ---- inside ----

    /// This room's seat in a connection's chain, or null if it has none here.
    fn find(self: *Room, first: Seating) ?Ticket {
        var at = first;
        while (at.room) |in_room| {
            if (in_room == self) return at.ticket;
            at = in_room.after(at.ticket);
        }
        return null;
    }

    /// Take this room's seat out of a connection's chain and say which it
    /// was, or null if it had none here. The connection's own fiber is the
    /// only caller, which is why nothing here is locked (see `Seating`).
    fn unlink(self: *Room, first: *Seating) ?Ticket {
        var holder = first;
        while (holder.room) |in_room| {
            const seat = &in_room.seats[holder.ticket.index];
            if (in_room == self) {
                const ticket = holder.ticket;
                holder.* = seat.next;
                seat.next = .{};
                return ticket;
            }
            holder = &seat.next;
        }
        return null;
    }

    /// Nobody here. Worth its own check at the top of everything that says
    /// something: a room is empty most of the time, and a message into one
    /// should cost an atomic load rather than an allocation to throw away.
    fn empty(self: *Room) bool {
        return self.here.load(.monotonic) == 0 and self.kept.len == 0;
    }

    /// Room for one post, with its frame header already written in front of
    /// where the message goes. The header is built here — once — because a
    /// server frame carries no mask and nothing else that differs by
    /// recipient (ADR 046).
    fn reserve(self: *Room, kind: websocket.Kind, len: usize) Error!*Post {
        return self.reserveFields(kind, len, 0, 0);
    }

    /// `reserve`, with room behind the message for an event's name and id.
    fn reserveFields(self: *Room, kind: websocket.Kind, len: usize, name_len: usize, id_len: usize) Error!*Post {
        var head: [websocket.max_header]u8 = undefined;
        const framing = websocket.headerFor(&head, kind, len);
        // A name or id past four gigabytes is not an event anybody sends, and
        // the allocation it asks for would fail the same way.
        const names = std.math.cast(u32, name_len) orelse return error.OutOfMemory;
        const ids = std.math.cast(u32, id_len) orelse return error.OutOfMemory;

        const block = try self.gpa.alignedAlloc(
            u8,
            .fromByteUnits(@alignOf(Post)),
            @sizeOf(Post) + framing.len + len + name_len + id_len,
        );
        const post: *Post = @ptrCast(block.ptr);
        post.* = .{
            .refs = .init(1),
            .kind = kind,
            .head = @intCast(framing.len),
            .name_len = names,
            .id_len = ids,
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
        // Text only, for `put`'s reason: an event stream is the one thing
        // that reads these back, and it cannot carry a binary post.
        if (self.kept.len != 0 and post.kind == .text) self.keep(post);
    }

    /// Hold on to one more post, letting the oldest go past either bound.
    /// The roster's lock is the caller's.
    fn keep(self: *Room, post: *Post) void {
        const size = post.block().len;
        if (size > self.kept_limit) return;

        _ = post.refs.fetchAdd(1, .acq_rel);
        if (self.kept_count == self.kept.len) self.forgetOldest();
        self.kept[(self.kept_head + self.kept_count) % self.kept.len] = post;
        self.kept_count += 1;
        self.kept_bytes += size;
        while (self.kept_bytes > self.kept_limit) self.forgetOldest();
    }

    fn forgetOldest(self: *Room) void {
        const old = self.kept[self.kept_head].?;
        self.kept[self.kept_head] = null;
        self.kept_head = (self.kept_head + 1) % self.kept.len;
        self.kept_count -= 1;
        self.kept_bytes -= old.block().len;
        self.release(old);
    }

    /// The kept posts after the newest one whose id is `last_id`, into
    /// `into`, each with a reference of its own. None when nothing here has
    /// that id: a stream in several rooms reports the id of whichever spoke
    /// last, and the others have nothing to go on. The roster's lock is the
    /// caller's.
    fn keptAfter(self: *Room, last_id: []const u8, into: []*Post) usize {
        if (last_id.len == 0 or self.kept_count == 0) return 0;

        var at = self.kept_count;
        const found = while (at > 0) {
            at -= 1;
            const post = self.kept[(self.kept_head + at) % self.kept.len].?;
            if (std.mem.eql(u8, post.id(), last_id)) break at;
        } else return 0;

        var n: usize = 0;
        for (found + 1..self.kept_count) |i| {
            if (n == into.len) break;
            const post = self.kept[(self.kept_head + i) % self.kept.len].?;
            _ = post.refs.fetchAdd(1, .acq_rel);
            into[n] = post;
            n += 1;
        }
        return n;
    }

    /// Push one post into one seat, applying the policy if it is full. The
    /// seat's own lock, never the roster's: the point of the whole design is
    /// that a slow reader delays nobody but itself.
    fn put(self: *Room, seat: *Seat, post: *Post) void {
        seat.lock.lock() catch return;
        defer seat.lock.unlock();

        // Counted as missed rather than queued, and the bell is not rung: an
        // event stream has no way to carry it, and waking a connection to
        // write nothing is a wakeup for nothing.
        if (seat.text_only and post.kind == .binary) {
            seat.dropped.store(seat.dropped.load(.monotonic) + 1, .monotonic);
            return;
        }

        if (seat.count == self.backlog) {
            seat.dropped.store(seat.dropped.load(.monotonic) + 1, .monotonic);
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
        seat.dropped.store(0, .monotonic);
        seat.next = .{};
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
///
/// One line over `websocket.counted`, which is the same counting a Socket's
/// own `print` and `json` do. It used to be a second copy of those nine
/// lines, comments included, differing only in this cast: a post's length is
/// what gets allocated, so a Room wants a `usize` where a frame header wants
/// the `u64` it puts on the wire.
/// Whether the writing pass filled exactly the bytes the counting pass
/// promised. A post whose length is a lie must not reach a seat, so the caller
/// returns this error with the post still unshared and `defer`ed into the
/// free (ADR 076). Checked in every optimize mode: it is a failure a request
/// can reach, and a panic cannot be recovered from (ADR 007).
fn agreed(wrote: std.Io.Writer.Error!void, into: *const std.Io.Writer, post: *const Post) Error!void {
    wrote catch return error.WriteFailed;
    if (into.end != post.len) return error.WriteFailed;
}

fn sizeOf(comptime write: anytype, value: anytype) usize {
    return @intCast(websocket.counted(write, value));
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

    try testing.expectEqual(@as(u64, 1), seat.dropped.load(.monotonic));

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

    try testing.expectEqual(@as(u64, 1), seat.dropped.load(.monotonic));
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
    try room.sayText(&@as([300]u8, @splat('z')));
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
    try room.print("{s}", .{&@as([900]u8, @splat('y'))});
    const long = room.take(ticket).?;
    try testing.expectEqual(@as(usize, 900), room.contentsOf(long).data.len);
    try testing.expectEqualStrings(&@as([900]u8, @splat('y')), room.contentsOf(long).data);
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
    try testing.expect(try listener.receive() == null);

    // One unmasked text frame: a server never masks. 0x81, then the length,
    // then the bytes.
    try testing.expectEqualStrings("\x81\x0fhello everybody", listener_out.buffered());

    // And the speaker hears itself, which is what a chat wants — one code
    // path for "say something", not one for me and one for everyone else.
    try testing.expect(try speaker.receive() == null);
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
    try testing.expect(try socket.receive() == null);
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
    try testing.expect(try socket.receive() == null);
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

test "a socket in two rooms hears both, from one receive" {
    // A lobby and a channel of its own: the shape that used to be
    // `error.AlreadySeated`, because a socket held one ticket and `receive`
    // drained one seat.
    var lobby = try Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 2 });
    defer lobby.deinit();
    var mine = try Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 2 });
    defer mine.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: websocket.Socket = .{ ._in = &in, ._out = &out, ._stopping = null };

    try lobby.join(&socket);
    defer lobby.leave(&socket);
    try mine.join(&socket);
    defer mine.leave(&socket);
    try testing.expectEqual(@as(usize, 1), lobby.count());
    try testing.expectEqual(@as(usize, 1), mine.count());

    try lobby.sayText("all");
    try mine.sayText("you");

    // One `receive` drains every seat, and the burst is one flush. Which
    // room comes out first is not a promise, so this asserts on the bytes
    // rather than their order.
    try testing.expect(try socket.receive() == null);
    const got = out.buffered();
    try testing.expectEqual(@as(usize, 10), got.len);
    try testing.expect(std.mem.indexOf(u8, got, "\x81\x03all") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\x81\x03you") != null);
}

test "joining a room twice takes one seat, and leaving one room keeps the others" {
    var a = try Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 2 });
    defer a.deinit();
    var b = try Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 2 });
    defer b.deinit();
    var c = try Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 2 });
    defer c.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: websocket.Socket = .{ ._in = &in, ._out = &out, ._stopping = null };

    try a.join(&socket);
    try b.join(&socket);
    try c.join(&socket);
    try b.join(&socket);
    try testing.expectEqual(@as(usize, 1), b.count());

    // The middle of the chain, which is the case a list gets wrong: the seat
    // in front of it has to be pointed past it, not at it.
    b.leave(&socket);
    try testing.expectEqual(@as(usize, 0), b.count());
    try testing.expectEqual(@as(usize, 1), a.count());
    try testing.expectEqual(@as(usize, 1), c.count());

    try b.sayText("gone");
    try a.sayText("a");
    try c.sayText("c");
    try testing.expect(try socket.receive() == null);
    try testing.expectEqual(@as(usize, 6), out.buffered().len);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "gone") == null);

    // Leaving a room the socket is not in gives up nothing anywhere.
    b.leave(&socket);
    try testing.expectEqual(@as(usize, 1), a.count());
    try testing.expectEqual(@as(usize, 1), c.count());

    socket.leaveRooms();
    try testing.expectEqual(@as(usize, 0), a.count());
    try testing.expectEqual(@as(usize, 0), c.count());
    try testing.expect(socket.seating().room == null);
}

test "a count of dropped posts is the room's own, however many rooms the socket is in" {
    var loud = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 1 });
    defer loud.deinit();
    var quiet = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 1 });
    defer quiet.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: websocket.Socket = .{ ._in = &in, ._out = &out, ._stopping = null };

    try loud.join(&socket);
    defer loud.leave(&socket);
    try quiet.join(&socket);
    defer quiet.leave(&socket);

    try loud.sayText("1");
    try loud.sayText("2");
    try loud.sayText("3");
    try testing.expectEqual(@as(u64, 2), loud.missed(&socket));
    try testing.expectEqual(@as(u64, 0), quiet.missed(&socket));
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
    var seen = @as([64]bool, @splat(false));
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

test "a room with history keeps its latest text posts, inside both bounds" {
    // Three posts or 200 bytes, whichever comes first. A post here is its header
    // struct, a two-byte frame header and the text.
    var room = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 2, .history = 3, .history_bytes = 200 });
    defer room.deinit();

    // Nobody is here, and it is still kept: a client that is away is the
    // one it is for.
    try room.event(.{ .id = "a", .data = "one" });
    try room.sayBinary("\x00");
    try room.event(.{ .id = "b", .data = "two" });
    try room.event(.{ .id = "c", .data = "three" });
    try room.event(.{ .id = "d", .data = "four" });
    // Three by count, the binary never kept.
    try testing.expectEqual(@as(usize, 3), room.kept_count);
    try testing.expectEqualStrings("b", room.kept[room.kept_head].?.id());

    // A post bigger than the whole byte bound is not kept, and costs nothing
    // already kept.
    try room.sayText(&@as([300]u8, @splat('x')));
    try testing.expectEqual(@as(usize, 3), room.kept_count);
    try testing.expect(room.kept_bytes <= 200);

    room.forget();
    try testing.expectEqual(@as(usize, 0), room.kept_count);
    try testing.expectEqual(@as(usize, 0), room.kept_bytes);
}

test "sitting down after an id takes what followed it and nothing already queued" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 4, .history = 4 });
    defer room.deinit();
    try room.event(.{ .id = "1", .data = "one" });
    try room.event(.{ .id = "2", .data = "two" });
    try room.event(.{ .id = "3", .data = "three" });

    var first: Seating = .{};
    var into: [4]*Post = undefined;
    const n = try room.sitAfter(&first, .off, true, "1", &into);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("two", room.eventOf(into[0]).data);
    try testing.expectEqualStrings("three", room.eventOf(into[1]).data);
    for (into[0..n]) |post| room.release(post);

    // Seated: the seat holds only what is said from now on.
    try testing.expect(room.take(first.ticket) == null);
    try room.event(.{ .id = "4", .data = "four" });
    const next = room.take(first.ticket).?;
    try testing.expectEqualStrings("4", room.eventOf(next).id);
    room.release(next);
    room.stand(&first);
}

/// A value whose second formatting is `second` bytes where its first was
/// `first`: the mistake `Room.print`'s two passes cannot tell from honesty.
const Fickle = struct {
    asked: *usize,
    first: usize,
    second: usize,

    pub fn format(self: Fickle, w: *std.Io.Writer) std.Io.Writer.Error!void {
        self.asked.* += 1;
        try w.splatByteAll('x', if (self.asked.* == 1) self.first else self.second);
    }
};

test "a format that disagrees with itself drops the post and says so" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 4 });
    defer room.deinit();
    const ticket = sitDown(&room);

    // Longer the second time, and shorter: neither may panic, and neither may
    // reach a seat (ADR 076).
    for ([_][2]usize{ .{ 4, 6 }, .{ 6, 4 } }) |sizes| {
        var asked: usize = 0;
        try testing.expectError(
            error.WriteFailed,
            room.print("{f}", .{Fickle{ .asked = &asked, .first = sizes[0], .second = sizes[1] }}),
        );
        try testing.expect(room.take(ticket) == null);
    }

    // The room is as it was: the next post goes through.
    try room.print("ok {d}", .{1});
    const post = room.take(ticket).?;
    try testing.expectEqualStrings("ok 1", room.contentsOf(post).data);
    room.release(post);
}

test "a post and a direct send leave a connection in the order they were made" {
    var room = try Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 4 });
    defer room.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: websocket.Socket = .{ ._in = &in, ._out = &out, ._stopping = null };
    try room.join(&socket);
    defer room.leave(&socket);

    try room.sayText("one");
    try socket.sendText("two");
    try room.sayText("three");
    try socket.print("{s}", .{"four"});
    try room.sayText("five");
    try socket.close(.normal, "");

    try testing.expectEqualStrings(
        "\x81\x03one\x81\x03two\x81\x05three\x81\x04four\x81\x04five\x88\x02\x03\xe8",
        out.buffered(),
    );
}
