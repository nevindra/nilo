//! Rooms by name: a pool of Rooms lent out under a key the application makes
//! up, `"user:42"` or `"order:9f3c"`, for as long as somebody is in one
//! (ADR 228).
//!
//! ```zig
//! var rooms = try nilo.Rooms.init(gpa, .{ .rooms = 4096, .seats = 8 });
//! defer rooms.deinit();
//! try app.provide(&rooms);
//!
//! fn notify(rooms: *nilo.Rooms, user: u64) !void {
//!     var key: [32]u8 = undefined;
//!     try rooms.json(try std.fmt.bufPrint(&key, "user:{d}", .{user}), .{ .unread = 1 });
//! }
//! ```
//!
//! **A key is a Room nobody had to make.** Sending to one user is the case
//! that asks for it: every tab that user has open joins `"user:42"`, and
//! whatever wants to reach them says into that key without knowing who is
//! connected or where. A Room the application built itself stays the answer
//! for the rooms it knows about when it starts, a lobby or a feed.
//!
//! **Sized up front, like a Room's seats.** `rooms` Rooms of `seats` seats
//! each are made by `init` and nothing is allocated for a key after that, so
//! what the pool costs is a number the application states and not a function
//! of how many users showed up. A key needs a Room only while somebody is in
//! it: the last one out gives it back to the pool, and when every Room is
//! lent out a new key is `error.NoRoomFree`, said as what it is.
//!
//! **A key nobody is in is nothing.** Saying into it finds no Room and
//! allocates nothing, which is what a notification to a user who is not
//! connected should cost.
//!
//! **A Room with history keeps its key after the last one leaves**, because
//! that is when a user who is coming back needs it (ADR 229). It is lent to
//! another key only when the pool has no Room left that was never lent, the
//! one that went quiet first going first.
//!
//! **A Room is never lent under a new key while anybody could still reach it
//! under the old one.** Everything that says into a key pins its Room under
//! the pool's lock and unpins it after, so a Room that has emptied mid-say is
//! not handed to somebody else until the say is done. Without that, a
//! message for one user would reach the next.

const std = @import("std");

const bulkhead = @import("bulkhead.zig");
const room_mod = @import("room.zig");
const stream_mod = @import("stream.zig");
const websocket = @import("websocket.zig");

const Room = room_mod.Room;

pub const Options = struct {
    /// How many keys can have a Room at once. Every one is made by `init`.
    rooms: u32 = 1024,
    /// Seats in each Room: how many connections can sit under one key. Eight
    /// is one user's tabs and devices with some to spare; a key for a crowd
    /// is a Room of its own.
    seats: u32 = 8,
    /// See `Room.Options`.
    backlog: usize = 4,
    /// See `Room.Options`. The same for every Room in the pool, and what makes
    /// an empty one keep its key.
    history: usize = 0,
    history_bytes: usize = 64 * 1024,
    full: room_mod.Full = .drop_oldest,
};

/// The longest key. A key is copied into the Room it names, so this is what
/// each Room in the pool holds for it.
pub const max_key = 64;

pub const Error = room_mod.Error || error{
    /// Every Room in the pool is lent to a key somebody is in. The pool's
    /// `rooms` is the number to raise.
    NoRoomFree,
    /// Longer than `max_key`.
    KeyTooLong,
};

const nothing: u32 = std.math.maxInt(u32);

/// One Room in the pool and what the pool knows about it.
const Lent = struct {
    room: Room,
    pool: *Pool,
    key_buf: [max_key]u8 = undefined,
    key_len: u8 = 0,
    /// Lent under a key, which `key_buf` holds.
    lent: bool = false,
    /// On the quiet list: lent, nobody in it, nothing pinning it.
    quiet: bool = false,
    /// How many callers are between a pin and an unpin.
    pins: u32 = 0,
    /// The quiet list's links, and the free list's in `next`.
    prev: u32 = nothing,
    next: u32 = nothing,

    fn key(self: *const Lent) []const u8 {
        return self.key_buf[0..self.key_len];
    }
};

/// What a Room of the pool points back at. On the heap, because `Rooms` is a
/// value its owner moves after `init`, and the Rooms inside it are not.
const Pool = struct {
    gpa: std.mem.Allocator,
    lent: []Lent,
    /// Key to index. Sized for every Room at `init` and never grown; the keys
    /// are the ones in `key_buf`, which do not move.
    names: std.StringHashMapUnmanaged(u32) = .empty,
    /// Keys removed since the table was last rebuilt. A removal leaves a
    /// tombstone that a lookup for a missing key has to probe past, and a pool
    /// that turns keys over all day would otherwise end up probing the whole
    /// table to learn a user is not here.
    removed: u32 = 0,
    lock: bulkhead.Mutex = .{},
    free: u32 = nothing,
    quiet_first: u32 = nothing,
    quiet_last: u32 = nothing,
};

pub const Rooms = struct {
    /// What a nilo compile error calls this type (ADR 074).
    pub const nilo_type_name = "nilo.Rooms";

    pool: *Pool,

    pub fn init(gpa: std.mem.Allocator) Error!Rooms {
        return initWith(gpa, .{});
    }

    pub fn initWith(gpa: std.mem.Allocator, options: Options) Error!Rooms {
        const pool = try gpa.create(Pool);
        errdefer gpa.destroy(pool);
        pool.* = .{ .gpa = gpa, .lent = try gpa.alloc(Lent, options.rooms) };
        errdefer gpa.free(pool.lent);
        try pool.names.ensureTotalCapacity(gpa, options.rooms);
        errdefer pool.names.deinit(gpa);

        var made: usize = 0;
        errdefer for (pool.lent[0..made]) |*lent| lent.room.deinit();
        for (pool.lent, 0..) |*lent, i| {
            lent.* = .{
                .room = try Room.initWith(gpa, .{
                    .seats = options.seats,
                    .backlog = options.backlog,
                    .history = options.history,
                    .history_bytes = options.history_bytes,
                }),
                .pool = pool,
                .next = if (i + 1 < pool.lent.len) @intCast(i + 1) else nothing,
            };
            lent.room.full = options.full;
            lent.room.vacated = &vacated;
            made += 1;
        }
        pool.free = if (pool.lent.len > 0) 0 else nothing;
        return .{ .pool = pool };
    }

    pub fn deinit(self: *Rooms) void {
        const pool = self.pool;
        for (pool.lent) |*lent| lent.room.deinit();
        pool.names.deinit(pool.gpa);
        pool.gpa.free(pool.lent);
        pool.gpa.destroy(pool);
        self.* = undefined;
    }

    /// Take a seat under `key`, lending it a Room if it has none. Pair it with
    /// `defer rooms.leave(key, socket)`; when the loop returns nilo gives up
    /// whatever is left, and the key's Room goes back with the last seat.
    pub fn join(self: *Rooms, key: []const u8, socket: *websocket.Socket) Error!void {
        const lent = try self.pin(key);
        defer self.unpin(lent);
        return lent.room.join(socket);
    }

    /// Give up the seat under `key`. Safe twice, and safe for a key the
    /// socket never joined. Takes no lock of the pool's: a Room somebody is
    /// sitting in is never lent under another key, so the socket's own seats
    /// say which Room this is.
    pub fn leave(self: *Rooms, key: []const u8, socket: *websocket.Socket) void {
        const room = self.seatedUnder(key, socket.seating().*) orelse return;
        room.leave(socket);
    }

    /// How many posts under `key` this socket was too slow to take.
    pub fn missed(self: *Rooms, key: []const u8, socket: *websocket.Socket) u64 {
        const room = self.seatedUnder(key, socket.seating().*) orelse return 0;
        return room.missed(socket);
    }

    /// How many connections are under `key`: zero for a key with no Room.
    pub fn count(self: *Rooms, key: []const u8) usize {
        const lent = self.find(key) orelse return 0;
        defer self.unpin(lent);
        return lent.room.count();
    }

    /// Say something to everybody under `key`. Nothing, and no allocation,
    /// for a key with no Room.
    pub fn say(self: *Rooms, key: []const u8, kind: websocket.Kind, data: []const u8) Error!void {
        const lent = self.find(key) orelse return;
        defer self.unpin(lent);
        return lent.room.say(kind, data);
    }

    pub fn sayText(self: *Rooms, key: []const u8, text: []const u8) Error!void {
        return self.say(key, .text, text);
    }

    pub fn sayBinary(self: *Rooms, key: []const u8, bytes: []const u8) Error!void {
        return self.say(key, .binary, bytes);
    }

    pub fn print(self: *Rooms, key: []const u8, comptime fmt: []const u8, args: anytype) Error!void {
        const lent = self.find(key) orelse return;
        defer self.unpin(lent);
        return lent.room.print(fmt, args);
    }

    pub fn json(self: *Rooms, key: []const u8, value: anytype) Error!void {
        const lent = self.find(key) orelse return;
        defer self.unpin(lent);
        return lent.room.json(value);
    }

    pub fn event(self: *Rooms, key: []const u8, e: stream_mod.Event) Error!void {
        const lent = self.find(key) orelse return;
        defer self.unpin(lent);
        return lent.room.event(e);
    }

    /// `key` as something `c.eventsFrom` can sit a stream in, alone or in a
    /// tuple with Rooms: `c.eventsFrom(.{ lobby, rooms.named(key) }, .{})`.
    /// The key is read before `eventsFrom` returns, so it can be request
    /// text.
    pub fn named(self: *Rooms, key: []const u8) Named {
        return .{ .rooms = self, .key = key };
    }

    pub const Named = struct {
        pub const nilo_type_name = "nilo.Rooms.Named";
        rooms: *Rooms,
        key: []const u8,
    };

    // ---- nilo's own ----

    /// The Room lent under `key`, lending one if there is none, pinned so it
    /// cannot be lent to anybody else until `unpin`. `eventsFrom`'s, and
    /// `join`'s.
    pub fn pin(self: *Rooms, key: []const u8) Error!*Lent {
        if (key.len > max_key) return error.KeyTooLong;
        const pool = self.pool;
        try pool.lock.lock();
        defer pool.lock.unlock();

        if (pool.names.get(key)) |index| return pinned(pool, index);

        const index = takeFree(pool) orelse takeQuiet(pool) orelse return error.NoRoomFree;
        const lent = &pool.lent[index];
        @memcpy(lent.key_buf[0..key.len], key);
        lent.key_len = @intCast(key.len);
        lent.lent = true;
        pool.names.putAssumeCapacityNoClobber(lent.key(), index);
        return pinned(pool, index);
    }

    /// Let a Room go that `pin` or `find` held. If nobody is in it, it goes
    /// back to the pool or onto the quiet list.
    pub fn unpin(self: *Rooms, lent: *Lent) void {
        const pool = self.pool;
        pool.lock.lockUncancelable();
        defer pool.lock.unlock();
        lent.pins -= 1;
        settle(pool, lent);
    }

    /// The Room lent under `key`, pinned, or null if there is none.
    fn find(self: *Rooms, key: []const u8) ?*Lent {
        if (key.len > max_key) return null;
        const pool = self.pool;
        // Cancellation is the one error, and a fiber being cancelled is on
        // its way out: saying nothing is what it would have done next.
        pool.lock.lock() catch return null;
        defer pool.lock.unlock();
        const index = pool.names.get(key) orelse return null;
        return pinned(pool, index);
    }

    /// Which of the rooms in a connection's chain is this pool's under `key`.
    fn seatedUnder(self: *Rooms, key: []const u8, first: room_mod.Seating) ?*Room {
        var at = first;
        while (at.room) |room| {
            if (room.vacated == &vacated) {
                const lent: *Lent = @fieldParentPtr("room", room);
                if (lent.pool == self.pool and std.mem.eql(u8, lent.key(), key)) return room;
            }
            at = room.after(at.ticket);
        }
        return null;
    }
};

fn pinned(pool: *Pool, index: u32) *Lent {
    const lent = &pool.lent[index];
    if (lent.quiet) unlinkQuiet(pool, lent);
    lent.pins += 1;
    return lent;
}

/// What a Room of the pool is told when a seat in it is given up: from the
/// connection's own `leave`, or from nilo giving up what a loop left.
fn vacated(room: *Room) void {
    const lent: *Lent = @fieldParentPtr("room", room);
    const pool = lent.pool;
    pool.lock.lockUncancelable();
    defer pool.lock.unlock();
    settle(pool, lent);
}

/// Put a Room where its state says it belongs: nowhere new while anybody is
/// in it or holding it, the quiet list if it keeps history, and back in the
/// pool if it does not. The pool's lock is the caller's.
///
/// `count` is read here and written under the Room's own lock, and that is
/// enough: a seat is only ever taken by somebody holding a pin, so a Room
/// read as empty with no pins stays empty until this lock is let go.
fn settle(pool: *Pool, lent: *Lent) void {
    if (!lent.lent or lent.quiet or lent.pins != 0 or lent.room.count() != 0) return;
    const index: u32 = @intCast(lent - pool.lent.ptr);
    if (lent.room.keeps() != 0) {
        lent.quiet = true;
        lent.prev = pool.quiet_last;
        lent.next = nothing;
        if (pool.quiet_last != nothing) pool.lent[pool.quiet_last].next = index else pool.quiet_first = index;
        pool.quiet_last = index;
        return;
    }
    unlend(pool, lent);
    lent.next = pool.free;
    pool.free = index;
}

fn takeFree(pool: *Pool) ?u32 {
    const index = pool.free;
    if (index == nothing) return null;
    pool.free = pool.lent[index].next;
    pool.lent[index].next = nothing;
    return index;
}

/// The Room that went quiet first, taken from its key. What it kept is
/// forgotten before anybody else can read it.
fn takeQuiet(pool: *Pool) ?u32 {
    const index = pool.quiet_first;
    if (index == nothing) return null;
    const lent = &pool.lent[index];
    unlinkQuiet(pool, lent);
    unlend(pool, lent);
    return index;
}

fn unlinkQuiet(pool: *Pool, lent: *Lent) void {
    if (lent.prev != nothing) pool.lent[lent.prev].next = lent.next else pool.quiet_first = lent.next;
    if (lent.next != nothing) pool.lent[lent.next].prev = lent.prev else pool.quiet_last = lent.prev;
    lent.prev = nothing;
    lent.next = nothing;
    lent.quiet = false;
}

/// Take a Room back from its key.
fn unlend(pool: *Pool, lent: *Lent) void {
    _ = pool.names.remove(lent.key());
    pool.removed += 1;
    if (pool.removed > pool.lent.len / 2) {
        pool.names.rehash(std.hash_map.StringContext{});
        pool.removed = 0;
    }
    lent.room.forget();
    lent.lent = false;
    lent.key_len = 0;
}

// ---- tests ----

const testing = std.testing;

fn socketFor(in: *std.Io.Reader, out: *std.Io.Writer) websocket.Socket {
    return .{ ._in = in, ._out = out, ._stopping = null };
}

test "a key reaches every socket under it, and nobody else" {
    var rooms = try Rooms.initWith(testing.allocator, .{ .rooms = 4, .seats = 2 });
    defer rooms.deinit();

    var in = std.Io.Reader.fixed("");
    var tab_bytes: [64]u8 = undefined;
    var tab_out = std.Io.Writer.fixed(&tab_bytes);
    var phone_bytes: [64]u8 = undefined;
    var phone_out = std.Io.Writer.fixed(&phone_bytes);
    var other_bytes: [64]u8 = undefined;
    var other_out = std.Io.Writer.fixed(&other_bytes);
    var tab = socketFor(&in, &tab_out);
    var phone = socketFor(&in, &phone_out);
    var other = socketFor(&in, &other_out);

    try rooms.join("user:42", &tab);
    defer rooms.leave("user:42", &tab);
    try rooms.join("user:42", &phone);
    defer rooms.leave("user:42", &phone);
    try rooms.join("user:7", &other);
    defer rooms.leave("user:7", &other);
    try testing.expectEqual(@as(usize, 2), rooms.count("user:42"));

    try rooms.sayText("user:42", "hi");
    try testing.expect(try tab.receive() == null);
    try testing.expect(try phone.receive() == null);
    try testing.expect(try other.receive() == null);
    try testing.expectEqualStrings("\x81\x02hi", tab_out.buffered());
    try testing.expectEqualStrings("\x81\x02hi", phone_out.buffered());
    try testing.expectEqualStrings("", other_out.buffered());
}

test "saying into a key nobody is under allocates nothing" {
    var rooms = try Rooms.initWith(testing.allocator, .{ .rooms = 2, .seats = 1 });
    defer rooms.deinit();

    // Every Room was made by `init`; a key with no Room is a lookup and
    // nothing else, so an allocator that refuses everything is the assertion.
    const gpa = rooms.pool.lent[0].room.gpa;
    for (rooms.pool.lent) |*lent| lent.room.gpa = testing.failing_allocator;
    defer for (rooms.pool.lent) |*lent| {
        lent.room.gpa = gpa;
    };
    try rooms.sayText("user:1", "anybody?");
    try rooms.json("user:1", .{ .unread = 3 });
    try rooms.event("user:1", .{ .name = "ping", .data = "" });
    try testing.expectEqual(@as(usize, 0), rooms.count("user:1"));
}

test "the last one out gives the Room back, and the key with it" {
    var rooms = try Rooms.initWith(testing.allocator, .{ .rooms = 1, .seats = 2 });
    defer rooms.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket = socketFor(&in, &out);
    var second = socketFor(&in, &out);

    try rooms.join("a", &socket);
    // The one Room is lent: a second key has nowhere to go.
    try testing.expectError(error.NoRoomFree, rooms.join("b", &second));

    rooms.leave("a", &socket);
    try testing.expect(rooms.pool.names.get("a") == null);
    try rooms.join("b", &second);
    defer rooms.leave("b", &second);
    try testing.expectEqual(@as(usize, 1), rooms.count("b"));
}

test "a loop that forgot to leave gives the key back when nilo gives up its seats" {
    var rooms = try Rooms.initWith(testing.allocator, .{ .rooms = 1, .seats = 1 });
    defer rooms.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket = socketFor(&in, &out);

    try rooms.join("user:1", &socket);
    // What the connection loop does when a handler returns (serve.zig).
    socket.leaveRooms();
    try testing.expect(rooms.pool.names.get("user:1") == null);
    try testing.expectEqual(@as(u32, 0), rooms.pool.free);
}

test "leaving one key keeps the socket's other Rooms, its own and the pool's" {
    var rooms = try Rooms.initWith(testing.allocator, .{ .rooms = 2, .seats = 1 });
    defer rooms.deinit();
    var lobby = try Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 2 });
    defer lobby.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket = socketFor(&in, &out);

    try lobby.join(&socket);
    try rooms.join("a", &socket);
    try rooms.join("b", &socket);
    rooms.leave("a", &socket);
    rooms.leave("a", &socket);
    rooms.leave("never", &socket);

    try testing.expectEqual(@as(usize, 0), rooms.count("a"));
    try testing.expectEqual(@as(usize, 1), rooms.count("b"));
    try testing.expectEqual(@as(usize, 1), lobby.count());
    socket.leaveRooms();
}

test "a key past max_key is refused rather than cut short" {
    var rooms = try Rooms.initWith(testing.allocator, .{ .rooms = 1, .seats = 1 });
    defer rooms.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [8]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket = socketFor(&in, &out);
    try testing.expectError(error.KeyTooLong, rooms.join(&@as([(max_key + 1)]u8, @splat('k')), &socket));
    try rooms.sayText(&@as([(max_key + 1)]u8, @splat('k')), "nowhere");
}

test "a Room with history keeps its key when it empties, until the pool needs it" {
    var rooms = try Rooms.initWith(testing.allocator, .{ .rooms = 2, .seats = 1, .history = 4 });
    defer rooms.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket = socketFor(&in, &out);

    try rooms.join("user:1", &socket);
    rooms.leave("user:1", &socket);
    // Nobody is in it, and it still has its key: a user who is away is the
    // one a notification kept for later is for.
    try rooms.event("user:1", .{ .id = "1", .data = "while you were out" });
    const one = rooms.pool.names.get("user:1").?;
    try testing.expectEqual(@as(usize, 1), rooms.pool.lent[one].room.kept_count);

    // Two more keys in a pool of two: the first takes the Room never lent,
    // the second the one that went quiet, and what it kept goes with it.
    try rooms.join("user:2", &socket);
    rooms.leave("user:2", &socket);
    try rooms.join("user:3", &socket);
    defer rooms.leave("user:3", &socket);
    try testing.expect(rooms.pool.names.get("user:1") == null);
    try testing.expectEqual(one, rooms.pool.names.get("user:3").?);
    try testing.expectEqual(@as(usize, 0), rooms.pool.lent[one].room.kept_count);
}

test "a pool that turns keys over for ever still finds a missing one" {
    // Every removal leaves a tombstone; without the rebuild a lookup for a key
    // nobody has walks all of them.
    var rooms = try Rooms.initWith(testing.allocator, .{ .rooms = 4, .seats = 1 });
    defer rooms.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [8]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket = socketFor(&in, &out);

    var key: [16]u8 = undefined;
    for (0..1000) |i| {
        const k = try std.fmt.bufPrint(&key, "user:{d}", .{i});
        try rooms.join(k, &socket);
        rooms.leave(k, &socket);
    }
    try testing.expect(rooms.pool.removed <= rooms.pool.lent.len / 2);
    try testing.expectEqual(@as(u32, 0), rooms.pool.names.count());
}
