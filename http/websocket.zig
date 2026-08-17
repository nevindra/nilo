//! WebSocket — the connection that stops being HTTP (ADR 0022, ADR 0071).
//!
//! ```zig
//! fn echo(c: *nilo.Ctx) !void {
//!     return c.upgrade(echoLoop, {});
//! }
//!
//! fn echoLoop(socket: *nilo.Socket) !void {
//!     while (try socket.receive()) |message| {
//!         try socket.send(message.kind, message.data);
//!     }
//! }
//! ```
//!
//! The caller owns the loop, the same way a streaming handler owns its
//! `Stream`: nilo does the handshake, the framing and the housekeeping
//! frames, and then gets out of the way. What it does **not** do is let the
//! handler keep the loop — a handler that loops in place is suspended inside
//! the request machinery for the life of the socket, and a suspended fiber
//! holds every byte of its stack (ADR 0063). So the handler hands the loop
//! back and the connection loop runs it, which is `Handover` below and
//! ADR 0071: 9,290 bytes an idle socket down to 5,186.
//!
//! Memory is one buffer per message **in flight**, not one per open socket. It
//! comes from the executor's free list when a message starts arriving and goes
//! back when the conversation goes quiet (`http/scratch.zig`). A message split
//! across frames is reassembled into it, and one bigger than
//! `Options.max_message` closes the connection with 1009 rather than growing
//! anything.
//!
//! **No byte of a message is copied twice** (ADR 0052). A frame that is
//! already in the connection's read buffer — which is nearly every frame, and
//! every frame at all under the size of one read — is unmasked *as* it is
//! copied into the message buffer, in one pass. A frame too big to have
//! arrived whole is read straight into the message buffer, past the read
//! buffer entirely, and unmasked where it lands. There is no third case.

const std = @import("std");

const bulkhead = @import("bulkhead.zig");
const http1 = @import("http1.zig");
const json_mod = @import("json.zig");
const room_mod = @import("room.zig");
const scratch_mod = @import("scratch.zig");

/// The string every WebSocket handshake in the world hashes against. It has
/// no meaning; it is there so that a server which merely echoes the key
/// cannot be mistaken for one that speaks the protocol (RFC 6455 §1.3).
const handshake_salt = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Options = struct {
    /// A sub-protocol to agree to, echoed back in the handshake. Empty
    /// agrees to nothing, which is what a client that asked for nothing
    /// expects.
    protocol: []const u8 = "",

    /// How long this connection may say nothing before it is asked whether it
    /// is still there. Zero waits forever, which is what nilo did before this
    /// existed.
    ///
    /// **Not a deadline, and the difference is the whole design.** A WebSocket
    /// is *allowed* to sit quiet — a chat tab with nobody typing is working
    /// correctly, and closing it after thirty seconds would be a framework
    /// breaking a working connection. So silence does not end anything: it
    /// sends a ping. A client that answers has proved it is there and gets
    /// another stretch. A client that does not answer the next one has gone,
    /// and gets closed with 1001.
    ///
    /// That is ADR 0022's recorded answer to the hole ADR 0020 first named —
    /// "a client that opens a socket and never speaks holds a fiber until TCP
    /// gives up" — written down long before there was a wait that could carry
    /// a limit.
    ///
    /// Thirty seconds costs a dead connection about a minute to notice, and
    /// costs a live one two frames a minute. Proxies that drop quiet
    /// connections usually do so at sixty.
    idle_ms: u32 = 30_000,

    /// The biggest message this socket will assemble. One past it closes the
    /// connection with 1009 rather than growing anything.
    ///
    /// This is the buffer's size, and the buffer is **not** this connection's:
    /// it comes from the executor's free list when a message starts arriving
    /// and goes back when the connection goes quiet (`http/scratch.zig`). So
    /// raising it costs one buffer per message *in flight* rather than one per
    /// open socket, which is the change that made having the option worth it
    /// at all — see `default_max_message`.
    max_message: usize = default_max_message,
};

/// The default ceiling on one message, and the size of a buffer on the
/// executor's free list.
///
/// **ADR 0022 refused to have this option at all**, on the grounds that the
/// buffer handed to `receive` was already the limit and one limit is better
/// than two. That was right about the limits and wrong about where the buffer
/// should live: a buffer declared in the handler is a local in a frame that
/// stays live for the whole connection, so a socket that had received one
/// 60 KiB message held 74,809 bytes per idle connection against 13,375 for one
/// that had not. `http/scratch.zig` has the measurement and the shape that
/// replaced it — and the option comes back because a shared buffer has to have
/// a size before anybody asks for one.
///
/// 16 KiB because it is what `examples/chat` asked for when the number was the
/// handler's to pick, and a chat line is far inside it.
pub const default_max_message = 16 * 1024;

/// The most a handler may carry into its loop, in bytes.
///
/// The state travels in the connection loop's frame — the one frame this whole
/// arrangement exists to keep under a page — so it is a fixed slot rather than
/// an allocation, and a fixed slot needs a ceiling. Anything bigger goes in the
/// request arena, which is alive for as long as the loop is, with a pointer to
/// it carried here, and `refusals/ws_state_too_big.zig` says so at compile time
/// rather than truncating anything.
///
/// **128 and not 32, because a `Str` is not the same size in both optimize
/// modes.** It carries the use-after-request trap's marker in Debug and does
/// not in release, so it is 40 bytes and then 16 — and the first version of
/// this number was 32, which refused `c.upgrade(loop, c.query("name").?)`
/// under `zig build test` and accepted it under `-Doptimize=ReleaseFast`. **A
/// comptime refusal that depends on the optimize mode is worse than no
/// refusal**, because it turns a design rule into a build-configuration
/// surprise. 128 holds three Debug `Str`s, which is past anything worth
/// carrying by value; the mode still decides the arithmetic, but nothing a
/// caller would plausibly write lands on either side of it.
pub const state_max = 128;

/// The alignment the state slot can promise. Wider than a pointer so a
/// `u128` or a vector fits; a type that wants more is refused rather than
/// quietly misaligned.
pub const state_align = 16;

/// A socket the handler has handed back, and the function that is going to
/// run it.
///
/// **Where the loop's frame sits is what a WebSocket costs while it is quiet.**
/// A handler that keeps the loop itself parks 1,608 bytes inside
/// `App.serveRequest` — the `Ctx`, the parsed request, the route match — and a
/// suspended fiber holds every one of those bytes for the life of the
/// connection, which for a chat tab is hours (ADR 0063). So the handler does
/// the handshake and returns; the connection loop takes this back and runs the
/// loop from its own frame, a page higher up, with the request's machinery
/// already unwound. See ADR 0071.
pub const Handover = struct {
    socket: Socket,
    run: *const fn (*Socket, *const anyopaque) anyerror!void,
    /// The route this socket came in on, for the one log line that can be
    /// written about it. Points into the request arena, which is alive for as
    /// long as the loop is.
    path: []const u8 = "",
    /// Where this socket's message buffer is parked between messages. It lives
    /// here rather than on the `Socket` so that a loop which walks out without
    /// a word still gives the buffer back — the connection loop has the
    /// `defer`, and points `socket._scratch` here once this struct has stopped
    /// moving.
    scratch: ?[]align(std.heap.page_size_min) u8 = null,
    state: [state_max]u8 align(state_align) = undefined,
};

/// Type-erase `loop` so the connection loop can call it without knowing what
/// the handler carried. The state was copied into `Handover.state` by
/// `Ctx.upgrade`; this is the other half of that.
pub fn runner(
    comptime loop: anytype,
    comptime State: type,
) *const fn (*Socket, *const anyopaque) anyerror!void {
    return struct {
        fn call(socket: *Socket, state: *const anyopaque) anyerror!void {
            if (State == void) return loop(socket);
            const carried: *const State = @ptrCast(@alignCast(state));
            return loop(socket, carried.*);
        }
    }.call;
}

/// What a socket loop has to look like, checked where the mistake is made.
///
/// The messages name the argument list the caller wrote, because that is what
/// they have to change — a loop is an ordinary function and the only thing
/// nilo asks of it is its first parameter (ADR 0027).
pub fn checkLoop(comptime loop: anytype, comptime State: type) void {
    const Loop = @TypeOf(loop);
    const info = switch (@typeInfo(Loop)) {
        .@"fn" => |f| f,
        else => @compileError("nilo: a WebSocket route runs a function on the socket, and " ++
            @typeName(Loop) ++ " is not one"),
    };
    const wants: usize = if (State == void) 1 else 2;
    if (info.params.len != wants) {
        // The function's own type is not named here the way every other
        // refusal names what the caller wrote: `@typeName` of a function with
        // an inferred error set is four lines of `@typeInfo(@typeInfo(…))`,
        // which buries the sentence it is supposed to help.
        @compileError("nilo: a WebSocket loop takes " ++ (if (State == void)
            "*Socket and nothing else, because upgrade was given no state"
        else
            "*Socket and the state passed to upgrade (" ++ @typeName(State) ++ ")") ++
            "; this one takes " ++ num(info.params.len) ++ " argument" ++
            (if (info.params.len == 1) "" else "s"));
    }
    if (info.params[0].type != *Socket) {
        @compileError("nilo: a WebSocket loop's first argument is *nilo.Socket, not " ++
            @typeName(info.params[0].type orelse anyopaque));
    }
    if (State != void and info.params[1].type != State) {
        @compileError("nilo: upgrade was given state of type " ++ @typeName(State) ++
            ", and the loop's second argument is " ++
            @typeName(info.params[1].type orelse anyopaque));
    }
    if (@sizeOf(State) > state_max) {
        @compileError("nilo: a WebSocket loop may carry " ++ num(state_max) ++
            " bytes of state and " ++ @typeName(State) ++ " is " ++ num(@sizeOf(State)) ++
            "; put it in the request arena and carry a pointer to it");
    }
    if (@alignOf(State) > state_align) {
        @compileError("nilo: a WebSocket loop's state is aligned to " ++ num(state_align) ++
            " bytes and " ++ @typeName(State) ++ " needs " ++ num(@alignOf(State)));
    }
}

fn num(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

pub const Kind = enum { text, binary };

/// One message, whole. `data` points into the buffer handed to `receive`,
/// so it is the caller's memory and lives exactly as long as the caller
/// decides.
pub const Message = struct {
    kind: Kind,
    data: []u8,
};

/// Why a connection is being closed. The numbers are RFC 6455 §7.4.1's, and
/// the ones a server actually sends.
pub const Close = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported = 1003,
    /// Text that was not valid UTF-8.
    invalid_payload = 1007,
    policy = 1008,
    too_big = 1009,
    internal = 1011,
    _,
};

pub const Error = error{
    /// The other end broke the framing rules. The connection is closed.
    ProtocolError,
    /// A message longer than the buffer handed to `receive`, which is the
    /// only ceiling there is. The connection is closed with a 1009.
    MessageTooBig,
    ReadFailed,
    WriteFailed,
    EndOfStream,
};

const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,

    fn isControl(self: Opcode) bool {
        return @intFromEnum(self) & 0x8 != 0;
    }

    fn of(kind: Kind) Opcode {
        return if (kind == .text) .text else .binary;
    }
};

/// The longest a header nilo writes can be: two bytes and a 64-bit length.
/// A server never masks, so there are no four bytes of key on the end of it.
pub const max_header = 10;

/// The bytes that go in front of one outgoing message, written into `into`
/// and returned as the part of it that counts.
///
/// Public because a `Room` builds this **once** for a message and every
/// connection in the room writes the same bytes. A server frame carries no
/// mask and no per-connection anything, so there is nothing in a header worth
/// building a thousand times (ADR 0038, ADR 0052).
pub fn headerFor(into: *[max_header]u8, kind: Kind, len: u64) []u8 {
    return writeHeader(into, .of(kind), len);
}

fn writeHeader(into: *[max_header]u8, opcode: Opcode, len: u64) []u8 {
    into[0] = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN, no reserved bits

    // A server never masks. The mask exists to stop a hostile page making a
    // browser send bytes that a proxy would read as a request, and only a
    // browser is in that position.
    if (len < 126) {
        into[1] = @intCast(len);
        return into[0..2];
    }
    if (len <= std.math.maxInt(u16)) {
        into[1] = 126;
        std.mem.writeInt(u16, into[2..4], @intCast(len), .big);
        return into[0..4];
    }
    into[1] = 127;
    std.mem.writeInt(u64, into[2..10], len, .big);
    return into[0..10];
}

/// An open WebSocket connection.
pub const Socket = struct {
    _in: *std.Io.Reader,
    _out: *std.Io.Writer,
    _stopping: ?*const std.atomic.Value(bool),
    /// Set once a close frame has gone out, so the housekeeping does not
    /// send a second one and `receive` knows there is nothing left to read.
    _closed: bool = false,
    /// Whether a close frame was exchanged, as opposed to the connection
    /// simply ending. Read through `closedCleanly`.
    _said_goodbye: bool = false,

    /// How somebody who is not the client at the other end wakes this
    /// connection. `.off` — the default, and what a Socket over a fixed
    /// buffer in a test gets — answers "go and read" to everything, so
    /// `receive` behaves exactly as it did before any of this existed.
    _waker: bulkhead.Waker = .off,
    /// Where this connection is sitting, once it has joined a Room. Null is
    /// the ordinary case: a socket that echoes needs none of this.
    _room: ?*room_mod.Room = null,
    _ticket: ?room_mod.Ticket = null,

    /// Where this connection's message buffer is parked between messages.
    ///
    /// Points at the Ctx's slot on a real server, so that a handler which
    /// leaves its loop without a word still gives the buffer back — see
    /// `Ctx._ws_scratch`. Null for a Socket a test built by hand, which falls
    /// back to `_own_scratch` and hands it back when `receive` runs out.
    _scratch: ?*?[]align(std.heap.page_size_min) u8 = null,
    _own_scratch: ?[]align(std.heap.page_size_min) u8 = null,
    /// The message ceiling: the size of the buffer taken from the free list.
    _max_message: usize = default_max_message,

    /// How long silence is allowed to last before this end asks after the
    /// other. Zero waits forever — see `Options.idle_ms`.
    _idle_ms: u32 = 0,
    /// A ping has gone out and nothing has come back yet. The next stretch of
    /// silence is what turns that into a verdict.
    _awaiting_pong: bool = false,

    /// The next message, or null once the connection is over.
    ///
    /// Null covers every way it ends: a close frame, a client that simply
    /// vanished — a tab closed, a network gone — and a server that has been
    /// asked to stop. They are the same thing to a handler's loop, so none of
    /// them is an error to write a branch for. `closedCleanly` tells the first
    /// apart from the rest afterwards, for the handler that cares.
    ///
    /// Fragmented messages are reassembled into `buf`. Ping frames are
    /// answered and close frames are echoed without the handler seeing
    /// either: they are the protocol keeping itself alive.
    pub fn receive(self: *Socket) Error!?Message {
        if (self._closed) {
            self.giveScratch();
            return null;
        }

        var filled: usize = 0;
        var kind: ?Kind = null;
        // Empty until the first frame of a message turns up, and the same
        // slice for every frame of it after that.
        var buf: []align(std.heap.page_size_min) u8 = &.{};

        while (true) {
            // Anything the room posted while this connection was quiet goes
            // out here, written by the fiber that owns the socket — which is
            // the whole of ADR 0029's finding, in three lines. A handler never
            // sees a post and never writes a branch for one.
            try self.deliver();

            // A server on its way out ends the conversation itself, rather
            // than leaving every handler to spell out the same `live()` check
            // and every client to find the socket gone without being told
            // (ADR 0020). What is already queued has gone out above; what is
            // half-collected here is a message the other end never finished.
            if (self.stopping()) {
                self.closeWith(.going_away) catch {};
                self.giveScratch();
                return null;
            }

            // Only park when there is nothing already in hand: a reader
            // holding a buffered frame is readable whatever the socket
            // thinks, and asking the kernel instead would park a connection
            // that has a whole message sitting in memory.
            if (self._in.bufferedLen() == 0) {
                // `filled == 0` is what says the buffer holds nothing anybody
                // still wants: a fragmented message waiting for its next frame
                // keeps it, and a message already handed over does not, because
                // the next one overwrites it regardless. Whether it is actually
                // given back is `park`'s to decide, and it only does so once
                // the connection has gone quiet — giving it back before every
                // wait costs an allocator round trip per message and measured
                // 1.68M messages a second down to 990k.
                switch (self.park(filled == 0)) {
                    // Round again, and the `deliver` above writes it out.
                    .posted => continue,
                    .readable => {},
                    .timed_out => {
                        // Silence, for as long as this connection allows. The
                        // first stretch asks a question; the second reads the
                        // lack of an answer as a verdict. Anything at all from
                        // the other end clears it — a pong is what a live
                        // client sends, but a message proves the same thing.
                        if (self._awaiting_pong) {
                            self.closeWith(.going_away) catch {};
                            return null;
                        }
                        self._awaiting_pong = true;
                        self.ping("") catch {
                            self._closed = true;
                            return null;
                        };
                        continue;
                    },
                    .closed => {
                        self._closed = true;
                        return null;
                    },
                }
            }
            // Something arrived, so the question is answered whatever it was.
            self._awaiting_pong = false;

            // From here there may be bytes to keep, so there has to be
            // somewhere to keep them. Taken now rather than at the top of the
            // call: a socket that parks and never hears anything again never
            // holds one.
            buf = self.takeScratch() catch {
                self.closeWith(.internal) catch {};
                return error.ReadFailed;
            };

            // What is left of `buf`, not the whole of it: a fragment that
            // cannot fit beside the ones already collected is refused on what
            // its header claims, before a byte of it is read.
            const frame = self.nextHeader(buf.len - filled) catch |err| switch (err) {
                error.EndOfStream => {
                    self._closed = true;
                    self.giveScratch();
                    return null;
                },
                else => |e| return e,
            };

            if (frame.opcode.isControl()) {
                // A control frame may arrive in the middle of a fragmented
                // message, so this must not disturb what has been collected.
                if (try self.handleControl(frame)) continue;
                return null;
            }

            switch (frame.opcode) {
                .text, .binary => {
                    // A new data frame while a message is unfinished means
                    // the other end has lost track of its own fragments.
                    if (kind != null) return self.fail(error.ProtocolError);
                    kind = if (frame.opcode == .text) .text else .binary;
                },
                .continuation => if (kind == null) return self.fail(error.ProtocolError),
                else => return self.fail(error.ProtocolError),
            }

            const into = buf[filled..][0..@intCast(frame.len)];
            self.readPayload(into, frame.mask) catch |err| return self.fail(err);
            filled += into.len;

            if (frame.fin) break;
        }

        const data = buf[0..filled];
        // Text is defined to be UTF-8, and a client is entitled to be told
        // when it is not rather than handed bytes that will break something
        // further along.
        if (kind.? == .text and !std.unicode.utf8ValidateSlice(data)) {
            self.closeWith(.invalid_payload) catch {};
            return error.ProtocolError;
        }
        return .{ .kind = kind.?, .data = data };
    }

    /// Send one message. Never fragmented: nilo has it all already, so
    /// there is nothing to be gained by cutting it up.
    ///
    /// A socket that has already closed writes nothing and says so with a
    /// plain return. The alternative — an error — would be one every handler
    /// has to branch on for the one case it cannot prevent: the other end
    /// closing between two of its own sends. That is the same reading
    /// `receive` gives a client that vanished (ADR 0022).
    pub fn send(self: *Socket, kind: Kind, data: []const u8) Error!void {
        if (self._closed) return;
        return self.sendFrame(.of(kind), data);
    }

    pub fn sendText(self: *Socket, text: []const u8) Error!void {
        return self.send(.text, text);
    }

    pub fn sendBinary(self: *Socket, bytes: []const u8) Error!void {
        return self.send(.binary, bytes);
    }

    /// `socket.print("{d} here now", .{room.count()})` — one text message,
    /// formatted straight onto the wire with no buffer of your own in
    /// between.
    ///
    /// **The format runs twice**, once counting and once writing, and that is
    /// the cost written down. A frame states its length before its bytes, and
    /// the only places to put the bytes meanwhile are an allocation (which
    /// this module does not make) or a fixed buffer whose size you would have
    /// to guess — which is the `bufPrint` dance this exists to delete. Nothing
    /// is allocated either way.
    ///
    /// The arguments are therefore read twice: pass values, not a window onto
    /// memory another fiber is writing.
    pub fn print(self: *Socket, comptime fmt: []const u8, args: anytype) Error!void {
        if (self._closed) return;
        try self.beginText(counted(struct {
            fn run(w: *std.Io.Writer, a: anytype) std.Io.Writer.Error!void {
                return w.print(fmt, a);
            }
        }.run, args));
        self._out.print(fmt, args) catch return error.WriteFailed;
        self._out.flush() catch return error.WriteFailed;
    }

    /// Serialise `value` as JSON into one text message — which is what a
    /// WebSocket carrying structured data almost always is.
    ///
    /// Two passes, for the reason `print` gives, and no allocation in either.
    pub fn json(self: *Socket, value: anytype) Error!void {
        if (self._closed) return;
        try self.beginText(counted(json_mod.write, value));
        json_mod.write(self._out, value) catch return error.WriteFailed;
        self._out.flush() catch return error.WriteFailed;
    }

    /// Ask the other end to answer, which is how a connection through a
    /// proxy that drops quiet ones stays up. Nothing goes out on a socket
    /// that has closed, for the reason `send` gives.
    pub noinline fn ping(self: *Socket, data: []const u8) Error!void {
        if (self._closed) return;
        return self.sendFrame(.ping, data);
    }

    /// Close, saying why. Safe to call twice, and safe to call after the
    /// other end has already closed.
    pub fn close(self: *Socket, code: Close, reason: []const u8) Error!void {
        if (self._closed) return;
        self._closed = true;

        var payload: [125]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], @intFromEnum(code), .big);
        const room = fits(reason);
        @memcpy(payload[2..][0..room], reason[0..room]);
        return self.sendFrame(.close, payload[0 .. 2 + room]);
    }

    /// Whether the connection ended with a close frame rather than by simply
    /// stopping. Only meaningful once `receive` has returned null.
    pub fn closedCleanly(self: *const Socket) bool {
        return self._said_goodbye;
    }

    /// Whether the server still wants this connection running. False once the
    /// connection is over, and false once a shutdown has started.
    ///
    /// `receive` checks this itself, so a message loop needs no branch for it
    /// (ADR 0052). What it is still for is a handler doing work of its own
    /// between messages — a long computation, a timer, a queue it drains —
    /// which nilo cannot see and cannot end on its behalf (ADR 0020).
    pub fn live(self: *const Socket) bool {
        return !self._closed and !self.stopping();
    }

    // ---- what a Room needs, and nothing more ----

    pub fn waker(self: *const Socket) bulkhead.Waker {
        return self._waker;
    }

    pub fn ticket(self: *const Socket) ?room_mod.Ticket {
        return self._ticket;
    }

    pub fn seatedIn(self: *Socket, in_room: *room_mod.Room, t: room_mod.Ticket) void {
        self._room = in_room;
        self._ticket = t;
    }

    pub fn unseat(self: *Socket) void {
        self._room = null;
        self._ticket = null;
    }

    /// Write out everything waiting for this connection. Called at the top of
    /// every `receive`, and by `receive` alone: a post is written by the fiber
    /// that owns the socket or it is not written at all.
    ///
    /// The posts are already framed — the room built the header once, for
    /// everybody — so each one is a single write, and the whole burst is one
    /// flush. A connection that was away for ten messages costs one syscall
    /// to catch up, not ten.
    noinline fn deliver(self: *Socket) Error!void {
        const in_room = self._room orelse return;
        const t = self._ticket orelse return;

        var any = false;
        while (in_room.take(t)) |post| {
            defer in_room.release(post);
            self._out.writeAll(in_room.framedBytes(post)) catch return error.WriteFailed;
            any = true;
        }
        if (any) self._out.flush() catch return error.WriteFailed;
    }

    fn stopping(self: *const Socket) bool {
        const flag = self._stopping orelse return false;
        return flag.load(.acquire);
    }

    // ---- the wire ----

    /// One frame header, as it was found on the wire. `reserved` and `masked`
    /// are carried rather than judged, because `headerFrom` is pure and every
    /// refusal belongs to the connection that has a close frame to send.
    const Frame = struct {
        fin: bool,
        reserved: bool,
        masked: bool,
        opcode: Opcode,
        len: u64,
        mask: [4]u8,
        /// How many bytes of the stream this header took.
        size: usize,
    };

    /// How long a header is, from its first two bytes. The rest of it is a
    /// length in one of three widths and, from a client, four bytes of key.
    fn headerSize(lead: [2]u8) usize {
        const extra: usize = switch (@as(u7, @truncate(lead[1]))) {
            126 => 2,
            127 => 8,
            else => 0,
        };
        return 2 + extra + @as(usize, if (lead[1] & 0x80 != 0) 4 else 0);
    }

    /// Read a frame header out of bytes already in hand, or null when there
    /// are not yet enough of them to say.
    ///
    /// Pure: no reader, no socket, no refusals. That is what lets the whole of
    /// RFC 6455 §5.2 be checked against a table of byte strings instead of
    /// through a connection, and it is why the fast path below is three lines.
    fn headerFrom(bytes: []const u8) ?Frame {
        if (bytes.len < 2) return null;
        const lead: [2]u8 = bytes[0..2].*;
        const size = headerSize(lead);
        if (bytes.len < size) return null;

        const short: u7 = @truncate(lead[1]);
        const masked = lead[1] & 0x80 != 0;
        return .{
            .fin = lead[0] & 0x80 != 0,
            .reserved = lead[0] & 0x70 != 0,
            .masked = masked,
            .opcode = @enumFromInt(@as(u4, @truncate(lead[0]))),
            .len = switch (short) {
                126 => std.mem.readInt(u16, bytes[2..4], .big),
                127 => std.mem.readInt(u64, bytes[2..10], .big),
                else => short,
            },
            .mask = if (masked) bytes[size - 4 ..][0..4].* else .{ 0, 0, 0, 0 },
            .size = size,
        };
    }

    /// The next frame's header, consumed. `room` is what is left of the
    /// handler's buffer, which is the only ceiling there is.
    fn nextHeader(self: *Socket, room: u64) Error!Frame {
        // Almost always the whole header is already in the connection's read
        // buffer, and then this is a slice and a few shifts: no fill, no copy,
        // no call into the reader at all.
        const frame = headerFrom(self._in.buffered()) orelse try self.fillHeader();

        // The three reserved bits are for extensions that were negotiated in
        // the handshake. nilo negotiates none, so a frame setting one is
        // talking to a server that is not there.
        if (frame.reserved) return self.fail(error.ProtocolError);
        // Every frame from a client is masked. An unmasked one is either a
        // broken client or something that is not a client at all, and the
        // RFC says to fail the connection either way.
        if (!frame.masked) return self.fail(error.ProtocolError);
        // A control frame has to fit in one small frame, because it may
        // arrive in the middle of somebody else's message.
        if (frame.opcode.isControl() and (frame.len > 125 or !frame.fin)) {
            return self.fail(error.ProtocolError);
        }
        // Refused on what the header claims, before a byte of it is read: a
        // frame announcing four gigabytes should cost four bytes to refuse.
        if (!frame.opcode.isControl() and frame.len > room) return self.tooBig();

        self._in.toss(frame.size);
        return frame;
    }

    /// Wait for the rest of a header. Only reached when a frame arrived split
    /// across reads, which a real network does and a fixed buffer never will.
    fn fillHeader(self: *Socket) Error!Frame {
        // The only place `EndOfStream` means the connection simply ended:
        // between frames, with nothing half-read. Everywhere below here a
        // stream that stops is a truncated frame, which is a broken one.
        const lead = (self._in.peekArray(2) catch |err| return switch (err) {
            error.EndOfStream => error.EndOfStream,
            else => error.ReadFailed,
        }).*;

        // 14 bytes is the longest header there is, and the smallest read
        // buffer nilo hands a connection is far larger, so this never asks
        // for more room than the reader has.
        const whole = self._in.peek(headerSize(lead)) catch return self.fail(error.ReadFailed);
        return headerFrom(whole).?;
    }

    /// One frame's payload, unmasked into `dst`.
    ///
    /// Two paths, and between them no byte is ever copied twice. What is
    /// already in the read buffer is unmasked *while* it is copied out —
    /// one pass, where a `readSliceAll` and then an in-place unmask is two.
    /// What has not arrived yet is read straight into `dst`, past the read
    /// buffer entirely, and unmasked where it lands.
    fn readPayload(self: *Socket, dst: []u8, key: [4]u8) Error!void {
        var done: usize = 0;
        while (done < dst.len) {
            const held = self._in.buffered();
            if (held.len == 0) {
                // Nothing in hand, so there is nothing to fuse with. What is
                // left goes into the handler's buffer directly — `readSliceAll`
                // reads into the destination while the destination is the
                // bigger of the two — and is unmasked where it lands.
                self._in.readSliceAll(dst[done..]) catch return error.ReadFailed;
                return unmask(dst[done..], key, done);
            }
            const n = @min(held.len, dst.len - done);
            unmaskInto(dst[done..][0..n], held[0..n], key, done);
            self._in.toss(n);
            done += n;
        }
    }

    /// Deal with a ping, pong or close. Returns true if the conversation
    /// carries on, false if the other end has closed.
    noinline fn handleControl(self: *Socket, frame: Frame) Error!bool {
        var payload: [125]u8 = undefined;
        const data = payload[0..@intCast(frame.len)];
        self.readPayload(data, frame.mask) catch |err| return self.fail(err);

        switch (frame.opcode) {
            // A pong carries the ping's payload back, which is how the other
            // end tells its own pings apart.
            .ping => {
                try self.sendFrame(.pong, data);
                return true;
            },
            .pong => return true,
            .close => {
                self._said_goodbye = true;
                // A goodbye that is not a goodbye — one byte where there
                // should be two, a code nobody assigned, a reason that is not
                // UTF-8 — is a framing error like any other, and echoing it
                // would put the same broken bytes back on the wire.
                if (!closeIsWellFormed(data)) return self.fail(error.ProtocolError);
                // Echoed back, then this end is done. What the RFC calls the
                // closing handshake, and what stops a browser reporting an
                // ordinary goodbye as a connection error.
                if (!self._closed) {
                    self._closed = true;
                    self.sendFrame(.close, data) catch {};
                }
                return false;
            },
            else => return self.fail(error.ProtocolError),
        }
    }

    /// How long this connection has to say something before its buffers are
    /// worth more to the kernel than to us. `App.idle_peek_ms`'s number and
    /// its reasoning: long enough that a socket in the middle of a
    /// conversation never reaches it, short enough that a chat tab between two
    /// sentences always does.
    const idle_peek_ms = 200;

    /// Park until there is something to do, handing the connection's buffer
    /// pages back if it goes quiet first.
    ///
    /// `App.waitOrRelease` does exactly this between two requests, and stops
    /// the moment a handler upgrades: a socket never goes back round that loop
    /// (ADR 0022). So the twelve kilobytes an idle keep-alive connection hands
    /// back were held for the whole life of every WebSocket, which is a thing
    /// nobody had measured — `bench/ws_server.zig` and `bench/ws_idle.py` now
    /// do, and the entry is in `bench/result/http.md`.
    ///
    /// The short wait first is the whole design, and it is the HTTP side's
    /// lesson rather than a new one: releasing on every park took the
    /// keep-alive path from 1.31M req/s to 626k, because `MADV_DONTNEED` in a
    /// process with eight threads shoots TLB entries down on all of them. A
    /// socket with a conversation on it answers inside 200ms and never pays.
    /// Where this socket's buffer is parked. The Ctx's slot on a real server,
    /// its own field for a Socket a test built by hand — resolved on every
    /// call rather than once, because a `Socket` is handed to the handler by
    /// value and a pointer into the copy `upgrade` returned would dangle.
    fn slot(self: *Socket) *?[]align(std.heap.page_size_min) u8 {
        return self._scratch orelse &self._own_scratch;
    }

    /// This socket's message buffer, taken from the executor's free list the
    /// first time a message needs one.
    /// The slot holds the whole allocation, which the free list rounds up to a
    /// page; what comes back is exactly `_max_message` of it, so the ceiling a
    /// caller was promised is the ceiling a caller gets. A buffer that was
    /// quietly bigger than the option said is precisely the "the option is a
    /// lie" that ADR 0022 refused to ship.
    fn takeScratch(self: *Socket) error{OutOfMemory}![]align(std.heap.page_size_min) u8 {
        const parked = self.slot();
        const whole = parked.* orelse whole: {
            const fresh = try scratch_mod.take(self._max_message);
            parked.* = fresh;
            break :whole fresh;
        };
        return whole[0..@min(self._max_message, whole.len)];
    }

    /// Give it back. Safe to call when there is nothing to give.
    fn giveScratch(self: *Socket) void {
        const parked = self.slot();
        if (parked.*) |buf| {
            scratch_mod.give(buf);
            parked.* = null;
        }
    }

    fn park(self: *Socket, may_give_buffer: bool) bulkhead.Woken {
        // A ping limit shorter than the peek is left alone rather than
        // reordered: the peek is supposed to be a prefix of the wait, not
        // longer than it.
        if (self._idle_ms != 0 and self._idle_ms <= idle_peek_ms) {
            return self._waker.wait(self._idle_ms);
        }
        switch (self._waker.wait(idle_peek_ms)) {
            .timed_out => {},
            else => |woken| return woken,
        }
        // Quiet. The allocation stays and nothing here allocates, so ADR
        // 0018's per-request invariant is untouched; the next frame faults the
        // pages back in as zeroes, which is all a buffer about to be
        // overwritten needs to be.
        // The message buffer goes back to the executor's free list here and
        // nowhere else. A socket in the middle of a conversation answers inside
        // the peek and never reaches this, so the free list is not on the
        // message path at all — it is touched once when a socket first speaks
        // and once when it stops.
        if (may_give_buffer) self.giveScratch();
        bulkhead.releaseIdlePages(self._in, self._out);
        // And the stack under all of it — on a socket the frames above are
        // live, so this is normally nothing; it is here because the same call
        // is what an HTTP connection between two requests wants and the cost
        // of asking is one syscall on a connection that has already gone
        // quiet.
        self._waker.releaseStack();
        return self._waker.wait(
            if (self._idle_ms == 0) 0 else self._idle_ms - idle_peek_ms,
        );
    }

    /// One frame, written but not flushed. `deliver` is why the flush is
    /// somebody else's: a burst of posts is one syscall, not one each.
    fn writeFrame(self: *Socket, opcode: Opcode, data: []const u8) Error!void {
        var head: [max_header]u8 = undefined;
        // One call, so a payload too big for the write buffer leaves beside
        // its header rather than after a drain of it.
        var parts = [_][]const u8{ writeHeader(&head, opcode, data.len), data };
        self._out.writeVecAll(&parts) catch return error.WriteFailed;
    }

    /// One frame, gone. Flushed every time: a message nobody sent yet is a
    /// message that has not arrived, and there is no later moment to flush at.
    fn sendFrame(self: *Socket, opcode: Opcode, data: []const u8) Error!void {
        try self.writeFrame(opcode, data);
        self._out.flush() catch return error.WriteFailed;
    }

    /// The header of a text message whose bytes are about to be printed
    /// straight into the connection.
    fn beginText(self: *Socket, len: u64) Error!void {
        var head: [max_header]u8 = undefined;
        self._out.writeAll(writeHeader(&head, .text, len)) catch return error.WriteFailed;
    }

    fn closeWith(self: *Socket, code: Close) Error!void {
        return self.close(code, "");
    }

    /// Say goodbye properly, then report. A connection that is failed
    /// without a close frame looks to the other end like a crash.
    fn fail(self: *Socket, err: Error) Error {
        self.closeWith(.protocol_error) catch {};
        return err;
    }

    fn tooBig(self: *Socket) Error {
        self.closeWith(.too_big) catch {};
        return error.MessageTooBig;
    }
};

/// How many bytes something would be, without writing any of them. The
/// counting half of `print` and `json`, kept in one place so both pay the
/// same well-understood price and neither invents a buffer.
fn counted(
    comptime write: anytype,
    value: anytype,
) u64 {
    // Big enough that a short message is one call into the counter rather
    // than one per piece of the format, and small enough to be free.
    var scratch: [256]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&scratch);
    // A counter has nowhere to fail: its drain throws the bytes away.
    write(&counter.writer, value) catch unreachable;
    return counter.fullCount();
}

/// Whether a close frame's payload is one RFC 6455 §5.5.1 allows: nothing at
/// all, or two bytes of code and a reason in UTF-8.
///
/// One byte is neither. A code outside the ranges the registry hands out is
/// one nobody can act on, and 1005 and 1006 in particular only ever mean
/// something locally — an end that puts either on the wire is reporting
/// something it cannot have observed.
fn closeIsWellFormed(payload: []const u8) bool {
    if (payload.len == 0) return true;
    if (payload.len < 2) return false;

    const code = std.mem.readInt(u16, payload[0..2], .big);
    const known = switch (code) {
        1000...1003, 1007...1014 => true,
        // 3000-3999 belong to libraries and 4000-4999 to applications, and
        // neither is this server's business to second-guess.
        3000...4999 => true,
        else => false,
    };
    if (!known) return false;
    return std.unicode.utf8ValidateSlice(payload[2..]);
}

/// The most of `reason` that fits beside a close code, cut on a character
/// boundary.
///
/// 123 is what is left of a control frame's 125 once the code has had its
/// two, and a reason cut through the middle of a multi-byte character is a
/// close frame the other end is entitled to refuse — which would turn saying
/// goodbye politely into the crash it was meant to avoid.
fn fits(reason: []const u8) usize {
    if (reason.len <= 123) return reason.len;
    var n: usize = 123;
    // A continuation byte is 10xxxxxx. Back up to the one that starts the
    // character it belongs to.
    while (n > 0 and reason[n] & 0xc0 == 0x80) n -= 1;
    return n;
}

/// The widths the unmasking steps down through. The key is four bytes, so
/// every one of them tiles it exactly, and LLVM splits each into whatever
/// registers the target actually has.
///
/// 128 is where the throughput stopped improving when ADR 0052 measured it:
/// 2.4× a single 32-byte tile on a 16 KiB message, with 256 worth another 6%
/// and twice the unrolled code. The smaller steps are not an afterthought —
/// a chat line is forty bytes and would otherwise fall straight past the wide
/// tile into a byte-at-a-time tail almost as long as the message.
const unmask_tiers = [_]usize{ 128, 32, 8, 4 };

/// Undo the client's masking, in place. `offset` is how far into the message
/// these bytes are, so the key lines up across a payload read in pieces.
fn unmask(data: []u8, key: [4]u8, offset: usize) void {
    unmaskInto(data, data, key, offset);
}

/// Undo the client's masking out of `src` and into `dst`, which may be the
/// same slice. `offset` is how far into the message these bytes are, so the
/// key lines up across a payload that arrived in pieces.
///
/// The obvious loop — one XOR per byte, `key[i % 4]` — is what the RFC
/// describes, and it runs at about a fourteenth of the speed of copying the
/// same bytes. For a 16 KiB message that was the entire cost of receiving
/// one: 6.4µs, against 0.5µs to send the same message back. Since the key
/// repeats every four bytes, the whole thing is one XOR against a repeating
/// pattern, which is a vector operation rather than a loop.
///
/// **Copying and unmasking are the same pass**, which is the second half of
/// that finding (ADR 0052): the bytes arrive in the connection's read buffer
/// and have to reach the handler's, and doing the XOR on the way costs
/// nothing over the move itself. Reading them and then unmasking them where
/// they landed is two walks over the same cache lines for one result.
fn unmaskInto(dst: []u8, src: []const u8, key: [4]u8, offset: usize) void {
    std.debug.assert(dst.len == src.len);

    // Where these bytes sit in the message decides which byte of the key
    // lines up with the first of them.
    var rotated: [4]u8 = undefined;
    inline for (0..4) |k| rotated[k] = key[(k +% offset) & 3];

    // Widest first, and each step only entered if there is work its size for
    // it — so a 16 KiB message never touches the narrow loops and a forty-byte
    // one never builds the wide pattern.
    var i: usize = 0;
    inline for (unmask_tiers) |lanes| {
        if (dst.len - i >= lanes) {
            const pattern: @Vector(lanes, u8) = std.simd.repeat(lanes, @as(@Vector(4, u8), rotated));
            while (i + lanes <= dst.len) : (i += lanes) {
                const block: @Vector(lanes, u8) = src[i..][0..lanes].*;
                dst[i..][0..lanes].* = block ^ pattern;
            }
        }
    }
    // Three bytes at the most.
    while (i < dst.len) : (i += 1) dst[i] = src[i] ^ rotated[i & 3];
}

// ---- the handshake ----

/// Whether this request is asking to become a WebSocket. Checked before
/// anything is written, so a request that is not gets an ordinary answer.
pub fn isUpgrade(head: []const u8) bool {
    var found_upgrade = false;
    var found_connection = false;
    var headers = http1.HeaderIterator.from(head);
    while (headers.next()) |h| {
        if (!found_upgrade and std.ascii.eqlIgnoreCase(h.name, "upgrade") and
            std.ascii.eqlIgnoreCase(std.mem.trim(u8, h.value, " \t"), "websocket"))
        {
            found_upgrade = true;
        }
        // `Connection` may be a list — `keep-alive, Upgrade` — so this looks
        // inside it rather than comparing the whole value.
        if (!found_connection and std.ascii.eqlIgnoreCase(h.name, "connection") and
            std.ascii.indexOfIgnoreCase(h.value, "upgrade") != null)
        {
            found_connection = true;
        }
        // Both found, and a head with fifty more headers on it has nothing
        // left to say about this question.
        if (found_upgrade and found_connection) return true;
    }
    return false;
}

/// The answer to `Sec-WebSocket-Key`: SHA-1 of the key and a fixed string,
/// base64'd. It proves nothing about anybody; it proves the server on the
/// other end knows what protocol it is speaking.
pub fn accept(key: []const u8) [28]u8 {
    var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(handshake_salt);
    sha.final(&hash);

    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &hash);
    return out;
}

/// The 101 that ends the HTTP half of the conversation.
pub fn writeAcceptance(
    out: *std.Io.Writer,
    accept_key: []const u8,
    protocol: []const u8,
) !void {
    try out.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    try out.writeAll("Upgrade: websocket\r\nConnection: Upgrade\r\n");
    try out.print("Sec-WebSocket-Accept: {s}\r\n", .{accept_key});
    if (protocol.len > 0) try out.print("Sec-WebSocket-Protocol: {s}\r\n", .{protocol});
    try out.writeAll("\r\n");
    try out.flush();
}

// ---- tests ----

const testing = std.testing;

/// A `Waker` that reports silence a fixed number of times and then says the
/// socket is readable.
///
/// The heartbeat is the one behaviour here that a real clock would make a
/// slow, flaky test of — and `Waker` is a vtable and a pointer, so a test can
/// supply its own and the waiting costs nothing. ADR 0033: a guard that has
/// never been seen to fire is not a guard.
const Quiet = struct {
    /// How long the client stays quiet, counted across every wait the socket
    /// makes.
    ///
    /// A test says how long the silence lasts rather than how many waits it
    /// takes to sit through — `park` spends a stretch of silence as a short
    /// peek and then the rest of it, and a stub that counted calls would make
    /// every one of these a test of that shape instead of of the heartbeat.
    quiet_ms: u64,
    /// What the silence has cost so far: the limits of the waits that ran out,
    /// added up. A test checks it to prove the whole limit travelled.
    spent_ms: u64 = 0,
    /// What the last wait was told, recorded so a test can check that a socket
    /// with no idle limit ends up waiting with none.
    last_limit_ms: u32 = 0,

    fn waker(self: *Quiet) bulkhead.Waker {
        return .{ .vtable = &vtable, .target = self };
    }

    const vtable: bulkhead.Waker.VTable = .{
        .wait = struct {
            fn f(target: ?*anyopaque, limit_ms: u32) bulkhead.Woken {
                const q: *Quiet = @ptrCast(@alignCast(target.?));
                q.last_limit_ms = limit_ms;
                // A wait with no limit cannot run out, so the only thing that
                // ends it is the other end speaking.
                if (limit_ms == 0) return .readable;
                if (q.spent_ms + limit_ms <= q.quiet_ms) {
                    q.spent_ms += limit_ms;
                    return .timed_out;
                }
                return .readable;
            }
        }.f,
        .post = struct {
            fn f(_: ?*anyopaque) void {}
        }.f,
        .release_stack = struct {
            fn f(_: ?*anyopaque) void {}
        }.f,
    };
};

test "a connection that says nothing is asked whether it is still there" {
    var quiet = Quiet{ .quiet_ms = 30_000 };
    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: Socket = .{
        ._in = &in,
        ._out = &out,
        ._stopping = null,
        ._waker = quiet.waker(),
        ._idle_ms = 30_000,
    };

    // One stretch of silence, then a readable socket with nothing on it.
    try testing.expect(try socket.receive() == null);

    // The whole limit reached the Engine rather than being dropped on the way,
    // however many waits it was spent across.
    try testing.expectEqual(@as(u64, 30_000), quiet.spent_ms);
    // An empty ping: 0x89, length 0. Asking, not closing.
    try testing.expectEqualStrings("\x89\x00", out.buffered());
}

test "a connection that never answers the question is closed with 1001" {
    var quiet = Quiet{ .quiet_ms = 2_000 };
    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: Socket = .{
        ._in = &in,
        ._out = &out,
        ._stopping = null,
        ._waker = quiet.waker(),
        ._idle_ms = 1_000,
    };

    try testing.expect(try socket.receive() == null);

    // The ping, then a close frame carrying 1001 — `going_away`, which is
    // what a client that stopped answering has done.
    try testing.expectEqualStrings("\x89\x00\x88\x02\x03\xe9", out.buffered());
}

test "silence with no limit set waits, exactly as it did before heartbeats" {
    // Long enough to get past the peek `park` takes before handing the
    // connection's pages back, which is the only bounded wait a socket with no
    // idle limit ever makes.
    var quiet = Quiet{ .quiet_ms = 200 };
    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: Socket = .{
        ._in = &in,
        ._out = &out,
        ._stopping = null,
        ._waker = quiet.waker(),
        ._idle_ms = 0,
    };

    try testing.expect(try socket.receive() == null);
    try testing.expectEqual(@as(u32, 0), quiet.last_limit_ms);
    // Nothing sent: zero means wait, and waiting is not an event.
    try testing.expectEqualStrings("", out.buffered());
}

/// A client, for driving a Socket from the other side.
const Peer = struct {
    to_server: std.ArrayList(u8) = .empty,
    from_server: [8192]u8 = undefined,
    in: std.Io.Reader = undefined,
    out: std.Io.Writer = undefined,

    fn deinit(self: *Peer) void {
        self.to_server.deinit(testing.allocator);
    }

    /// One client frame: masked, as every client frame must be.
    fn frame(self: *Peer, fin: bool, opcode: u4, payload: []const u8) !void {
        const gpa = testing.allocator;
        try self.to_server.append(gpa, (if (fin) @as(u8, 0x80) else 0) | @as(u8, opcode));

        const key = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
        if (payload.len < 126) {
            try self.to_server.append(gpa, 0x80 | @as(u8, @intCast(payload.len)));
        } else if (payload.len <= std.math.maxInt(u16)) {
            try self.to_server.append(gpa, 0x80 | 126);
            var raw: [2]u8 = undefined;
            std.mem.writeInt(u16, &raw, @intCast(payload.len), .big);
            try self.to_server.appendSlice(gpa, &raw);
        } else {
            try self.to_server.append(gpa, 0x80 | 127);
            var raw: [8]u8 = undefined;
            std.mem.writeInt(u64, &raw, payload.len, .big);
            try self.to_server.appendSlice(gpa, &raw);
        }
        try self.to_server.appendSlice(gpa, &key);

        const start = self.to_server.items.len;
        try self.to_server.appendSlice(gpa, payload);
        maskLikeTheRfc(self.to_server.items[start..], key, 0);
    }

    /// A frame with the mask bit off, which no real client may send.
    fn unmaskedFrame(self: *Peer, opcode: u4, payload: []const u8) !void {
        const gpa = testing.allocator;
        try self.to_server.append(gpa, 0x80 | @as(u8, opcode));
        try self.to_server.append(gpa, @intCast(payload.len));
        try self.to_server.appendSlice(gpa, payload);
    }

    fn socket(self: *Peer) Socket {
        return self.socketHolding(default_max_message);
    }

    /// A socket with a ceiling of the caller's choosing, for the tests about
    /// what happens at it. The buffer itself comes from the free list either
    /// way — the size is all a test gets to pick now (ADR 0022's `max_message`,
    /// which that ADR refused and `http/scratch.zig` brought back).
    fn socketHolding(self: *Peer, max_message: usize) Socket {
        self.in = .fixed(self.to_server.items);
        self.out = .fixed(&self.from_server);
        return .{
            ._in = &self.in,
            ._out = &self.out,
            ._stopping = null,
            ._max_message = max_message,
        };
    }

    fn sent(self: *const Peer) []const u8 {
        return self.out.buffered();
    }
};

/// A reader that hands over a few bytes at a time.
///
/// A fixed reader has the whole conversation in memory before the first call,
/// so it never once reaches the paths that exist for a frame arriving split
/// across reads — which is what a network does with every frame over a
/// kilobyte. Those paths are the slow half of ADR 0052 and were untested
/// until this existed.
const Trickle = struct {
    rest: []const u8,
    per: usize,
    buf: [16]u8 = undefined,
    reader: std.Io.Reader = undefined,

    fn init(self: *Trickle, bytes: []const u8, per: usize) void {
        self.rest = bytes;
        self.per = per;
        self.reader = .{ .vtable = &vtable, .buffer = &self.buf, .seek = 0, .end = 0 };
    }

    const vtable: std.Io.Reader.VTable = .{ .stream = stream };

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *Trickle = @alignCast(@fieldParentPtr("reader", r));
        if (self.rest.len == 0) return error.EndOfStream;
        const n = @min(self.rest.len, self.per, @intFromEnum(limit));
        const wrote = try w.write(self.rest[0..n]);
        self.rest = self.rest[wrote..];
        return wrote;
    }
};

/// RFC 6455 §5.3 transformed-octet-i, written the way the RFC writes it:
/// one byte at a time, no cleverness. Every test masks with this and lets
/// `unmask` undo it, so what is being checked is agreement with the spec.
///
/// Masking with `unmask` itself — which is what these tests used to do — is
/// no check at all. XOR is its own inverse, so a completely broken `unmask`
/// still round-trips against itself, and every test here passed.
fn maskLikeTheRfc(data: []u8, key: [4]u8, offset: usize) void {
    for (data, offset..) |*byte, i| byte.* ^= key[i % 4];
}

test "unmask agrees with the RFC at every length around a vector boundary" {
    // The lanes are what a length has to be checked against: one short of a
    // block, exactly a block, one past it, and the same around two blocks —
    // and around the eight- and four-byte steps that clear up the tail.
    const lengths = [_]usize{ 0, 1, 2, 3, 4, 5, 7, 8, 9, 11, 12, 13, 15, 16, 31, 32, 33, 39, 40, 63, 64, 65, 127, 1000 };
    const key = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };

    var original: [1000]u8 = undefined;
    for (&original, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    for (lengths) |len| {
        // And at every alignment of the key, which is what `offset` decides
        // when a payload arrives in more than one piece.
        for (0..4) |offset| {
            var masked: [1000]u8 = undefined;
            @memcpy(masked[0..len], original[0..len]);
            maskLikeTheRfc(masked[0..len], key, offset);

            unmask(masked[0..len], key, offset);
            try testing.expectEqualSlices(u8, original[0..len], masked[0..len]);
        }
    }
}

test "unmasking into somewhere else agrees with unmasking in place" {
    // The pass that receive actually takes: out of the read buffer and into
    // the handler's, with the XOR done on the way. It has to agree with the
    // in-place one byte for byte, at every length and every key alignment.
    const lengths = [_]usize{ 0, 1, 3, 4, 7, 8, 15, 16, 31, 32, 33, 40, 65, 500 };
    const key = [4]u8{ 0x9a, 0x11, 0xc3, 0x04 };

    var original: [500]u8 = undefined;
    for (&original, 0..) |*b, i| b.* = @truncate(i *% 17 +% 3);

    for (lengths) |len| {
        for (0..4) |offset| {
            var masked: [500]u8 = undefined;
            @memcpy(masked[0..len], original[0..len]);
            maskLikeTheRfc(masked[0..len], key, offset);

            var landed: [500]u8 = undefined;
            unmaskInto(landed[0..len], masked[0..len], key, offset);
            try testing.expectEqualSlices(u8, original[0..len], landed[0..len]);
        }
    }
}

test "unmask picks up mid-message where the previous piece left off" {
    // The property `offset` exists for: two calls over halves of a payload
    // must produce what one call over the whole of it does.
    const key = [4]u8{ 0x01, 0x02, 0x03, 0x04 };
    var whole: [70]u8 = undefined;
    for (&whole, 0..) |*b, i| b.* = @truncate(i);
    var split = whole;

    maskLikeTheRfc(&whole, key, 0);
    maskLikeTheRfc(&split, key, 0);

    unmask(&whole, key, 0);
    // 33 is deliberately not a multiple of four or of the vector width.
    unmask(split[0..33], key, 0);
    unmask(split[33..], key, 33);

    try testing.expectEqualSlices(u8, &whole, &split);
}

test "a header is read out of the bytes in hand, or not read at all" {
    // Pure, so the whole of RFC 6455 §5.2 is a table rather than a
    // connection. Nothing here refuses anything: that is the socket's job,
    // and it needs a close frame to do it with.
    try testing.expect(Socket.headerFrom("") == null);
    try testing.expect(Socket.headerFrom("\x81") == null);
    // Announced as masked, and the four bytes of key have not arrived.
    try testing.expect(Socket.headerFrom("\x81\x85\x37\xfa") == null);

    const short = Socket.headerFrom("\x81\x85\x37\xfa\x21\x3d").?;
    try testing.expect(short.fin);
    try testing.expect(!short.reserved);
    try testing.expect(short.masked);
    try testing.expectEqual(Opcode.text, short.opcode);
    try testing.expectEqual(@as(u64, 5), short.len);
    try testing.expectEqual([4]u8{ 0x37, 0xfa, 0x21, 0x3d }, short.mask);
    try testing.expectEqual(@as(usize, 6), short.size);

    // 126 means the length is the next two bytes, and the header is 8 long.
    const medium = Socket.headerFrom("\x82\xfe\xea\x60\x01\x02\x03\x04").?;
    try testing.expectEqual(Opcode.binary, medium.opcode);
    try testing.expectEqual(@as(u64, 60_000), medium.len);
    try testing.expectEqual(@as(usize, 8), medium.size);

    // 127 means eight bytes of length, and a header of 14.
    const long = Socket.headerFrom(
        "\x02\xff\x00\x00\x00\x01\x00\x00\x00\x00\x0a\x0b\x0c\x0d",
    ).?;
    try testing.expect(!long.fin);
    try testing.expectEqual(@as(u64, 1 << 32), long.len);
    try testing.expectEqual(@as(usize, 14), long.size);

    // An unmasked frame is four bytes shorter and carries no key. It is a
    // header that parses and a frame that will be refused.
    const bare = Socket.headerFrom("\x89\x00").?;
    try testing.expect(!bare.masked);
    try testing.expectEqual(@as(usize, 2), bare.size);
    try testing.expect(bare.opcode.isControl());

    // Any of the three reserved bits.
    try testing.expect(Socket.headerFrom("\xc1\x80\x00\x00\x00\x00").?.reserved);
    try testing.expect(Socket.headerFrom("\xa1\x80\x00\x00\x00\x00").?.reserved);
    try testing.expect(Socket.headerFrom("\x91\x80\x00\x00\x00\x00").?.reserved);
}

test "the handshake answer is the one every client checks" {
    // The example from RFC 6455 §1.3, which every implementation is tested
    // against and which pins the salt, the hash and the encoding at once.
    const answer = accept("dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &answer);
}

test "an upgrade is recognised, and an ordinary request is not" {
    try testing.expect(isUpgrade(
        "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
    ));
    // A browser sends `keep-alive, Upgrade`, so the value is a list.
    try testing.expect(isUpgrade(
        "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n\r\n",
    ));
    try testing.expect(!isUpgrade("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    // Half an upgrade is not one.
    try testing.expect(!isUpgrade("GET /ws HTTP/1.1\r\nUpgrade: websocket\r\n\r\n"));
    try testing.expect(!isUpgrade("GET /ws HTTP/1.1\r\nConnection: Upgrade\r\n\r\n"));
    // The answer is settled before the rest of the head is walked.
    try testing.expect(isUpgrade(
        "GET /ws HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n" ++
            "X-Whatever: and a hundred more of these\r\n\r\n",
    ));
}

test "a text message arrives unmasked, and is echoed back without a mask" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "hello");
    var socket = peer.socket();

    const message = (try socket.receive()).?;
    try testing.expectEqual(Kind.text, message.kind);
    try testing.expectEqualStrings("hello", message.data);

    try socket.sendText("hi there");
    // 0x81 = FIN + text; 0x08 = eight bytes and no mask bit.
    try testing.expectEqualStrings("\x81\x08hi there", peer.sent());
}

test "a message split across frames is put back together" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(false, 1, "hel"); // text, not final
    try peer.frame(false, 0, "lo, "); // continuation
    try peer.frame(true, 0, "world"); // continuation, final
    var socket = peer.socket();

    const message = (try socket.receive()).?;
    try testing.expectEqualStrings("hello, world", message.data);
}

test "a frame that arrives a few bytes at a time is the same message" {
    // The slow path, end to end: a header split across two reads and a
    // payload that never sits in the read buffer whole. What comes out has
    // to be byte for byte what the fast path produces.
    var peer: Peer = .{};
    defer peer.deinit();
    const long = "the quick brown fox jumps over the lazy dog. " ** 12; // 528 bytes
    try peer.frame(true, 2, long);
    // A ceiling well under the header's 8 bytes for one read, and far under
    // the payload.
    try peer.frame(true, 1, "and then a short one");

    var trickle: Trickle = undefined;
    trickle.init(peer.to_server.items, 3);
    var bytes: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: Socket = .{ ._in = &trickle.reader, ._out = &out, ._stopping = null };

    const first = (try socket.receive()).?;
    try testing.expectEqual(Kind.binary, first.kind);
    try testing.expectEqualStrings(long, first.data);

    const second = (try socket.receive()).?;
    try testing.expectEqualStrings("and then a short one", second.data);
    try testing.expect(try socket.receive() == null);
}

test "a ping is answered without the handler hearing about it" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 9, "are you there"); // ping
    try peer.frame(true, 1, "yes"); // and then a real message
    var socket = peer.socket();

    const message = (try socket.receive()).?;
    try testing.expectEqualStrings("yes", message.data);

    // 0x8a = FIN + pong, carrying the ping's payload back.
    try testing.expectEqualStrings("\x8a\x0dare you there", peer.sent());
}

test "a ping in the middle of a fragmented message does not disturb it" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(false, 1, "half ");
    try peer.frame(true, 9, "hi"); // a control frame, mid-message
    try peer.frame(true, 0, "a message");
    var socket = peer.socket();

    const message = (try socket.receive()).?;
    try testing.expectEqualStrings("half a message", message.data);
    try testing.expectEqualStrings("\x8a\x02hi", peer.sent());
}

test "a close is echoed and ends the conversation" {
    var peer: Peer = .{};
    defer peer.deinit();
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 1000, .big);
    @memcpy(payload[2..], "bye up");
    try peer.frame(true, 8, &payload);
    var socket = peer.socket();

    try testing.expectEqual(@as(?Message, null), try socket.receive());
    // 0x88 = FIN + close, and the same payload back: the closing handshake.
    try testing.expectEqualStrings("\x88\x08" ++ "\x03\xe8bye up", peer.sent());

    // Closing again writes nothing, so a handler with a `close` after its
    // loop does not send a second one.
    try socket.close(.normal, "");
    try testing.expectEqual(@as(usize, 10), peer.sent().len);

    // Neither does sending: a message after goodbye is a frame the other end
    // is entitled to treat as a protocol error, and a handler racing the
    // client to the close is not a bug worth an error return.
    try socket.sendText("one more thing");
    try socket.print("or {d}", .{2});
    try socket.json(.{ .and_also = true });
    try testing.expectEqual(@as(usize, 10), peer.sent().len);
}

test "a close frame that is not one is refused rather than echoed" {
    // One byte where there should be two: neither an empty goodbye nor a
    // code and a reason. Echoing it would put the same broken frame back.
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 8, "\x03");
    var socket = peer.socket();

    try testing.expectError(error.ProtocolError, socket.receive());
    try testing.expectEqualStrings("\x88\x02\x03\xea", peer.sent()); // 1002

    // A code nobody assigned. 1005 in particular means "no code was sent",
    // which is not something an end can observe about itself and put on a
    // wire.
    for ([_]u16{ 999, 1004, 1005, 1006, 1016, 2999, 5000 }) |code| {
        var other: Peer = .{};
        defer other.deinit();
        var raw: [2]u8 = undefined;
        std.mem.writeInt(u16, &raw, code, .big);
        try other.frame(true, 8, &raw);
        var s = other.socket();
        try testing.expectError(error.ProtocolError, s.receive());
        try testing.expectEqualStrings("\x88\x02\x03\xea", other.sent());
    }

    // And the ones that are fine, including the ranges libraries and
    // applications get to themselves.
    for ([_]u16{ 1000, 1001, 1003, 1011, 1012, 3000, 4999 }) |code| {
        var other: Peer = .{};
        defer other.deinit();
        var raw: [2]u8 = undefined;
        std.mem.writeInt(u16, &raw, code, .big);
        try other.frame(true, 8, &raw);
        var s = other.socket();
        try testing.expectEqual(@as(?Message, null), try s.receive());
        try testing.expect(s.closedCleanly());
    }
}

test "a close reason that is not UTF-8 is refused with the framing intact" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 8, "\x03\xe8\xff\xfe");
    var socket = peer.socket();

    try testing.expectError(error.ProtocolError, socket.receive());
    try testing.expectEqualStrings("\x88\x02\x03\xea", peer.sent());
}

test "a close reason too long for a control frame is cut on a character" {
    var peer: Peer = .{};
    defer peer.deinit();
    var socket = peer.socket();

    // 122 bytes of ASCII and then a three-byte character, so the 123rd byte
    // is the start of a character that does not fit. Cutting at 123 would
    // send half of it, and half a character is not UTF-8.
    const reason = "x" ** 122 ++ "€" ++ "tail";
    try socket.close(.policy, reason);

    const sent = peer.sent();
    try testing.expectEqual(@as(u8, 0x88), sent[0]);
    const payload = sent[2..][0..sent[1]];
    try testing.expectEqual(@as(usize, 124), payload.len); // 2 + 122
    try testing.expect(std.unicode.utf8ValidateSlice(payload[2..]));
    try testing.expectEqualStrings("x" ** 122, payload[2..]);
}

test "an unmasked frame from a client is refused" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.unmaskedFrame(1, "hello");
    var socket = peer.socket();

    try testing.expectError(error.ProtocolError, socket.receive());
    // 1002, and said properly rather than by hanging up.
    try testing.expectEqualStrings("\x88\x02\x03\xea", peer.sent());
}

test "text that is not UTF-8 is refused with the status that says so" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "\xff\xfe");
    var socket = peer.socket();

    try testing.expectError(error.ProtocolError, socket.receive());
    // 1007, invalid payload — not 1002, which would say the framing was
    // wrong when the framing was fine.
    try testing.expectEqualStrings("\x88\x02\x03\xef", peer.sent());

    // Binary has no such rule: the same bytes are a perfectly good message.
    var other: Peer = .{};
    defer other.deinit();
    try other.frame(true, 2, "\xff\xfe");
    var binary_socket = other.socket();
    const message = (try binary_socket.receive()).?;
    try testing.expectEqual(Kind.binary, message.kind);
    try testing.expectEqualStrings("\xff\xfe", message.data);
}

test "a message bigger than the buffer closes the connection rather than growing" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "x" ** 200);
    var socket = peer.socketHolding(100);

    try testing.expectError(error.MessageTooBig, socket.receive());
    // 1009.
    try testing.expectEqualStrings("\x88\x02\x03\xf1", peer.sent());
}

test "a frame announcing more than the buffer holds is refused before its bytes are read" {
    var peer: Peer = .{};
    defer peer.deinit();
    // Announced as 60,000 bytes, and only two of them actually sent. A
    // reader that trusted the header would sit waiting for the rest.
    try peer.frame(true, 1, "x" ** 300);
    std.mem.writeInt(u16, peer.to_server.items[2..4], 60_000, .big);
    var socket = peer.socketHolding(100);

    try testing.expectError(error.MessageTooBig, socket.receive());
    try testing.expectEqualStrings("\x88\x02\x03\xf1", peer.sent()); // 1009
}

test "fragments are measured against what is left of the buffer, not all of it" {
    // Each frame fits on its own; together they do not. The second one is
    // refused on its header, before its bytes are read, because the room
    // that matters is what the first one left.
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(false, 1, "x" ** 40);
    try peer.frame(true, 0, "y" ** 40);
    var socket = peer.socketHolding(64);

    try testing.expectError(error.MessageTooBig, socket.receive());
    try testing.expectEqualStrings("\x88\x02\x03\xf1", peer.sent());
}

test "a continuation with nothing to continue is a protocol error" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 0, "orphan");
    var socket = peer.socket();

    try testing.expectError(error.ProtocolError, socket.receive());
}

test "a reserved bit set means an extension nobody negotiated" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "hello");
    peer.to_server.items[0] |= 0x40; // RSV1
    var socket = peer.socket();

    try testing.expectError(error.ProtocolError, socket.receive());
}

test "a long message uses the sixteen-bit length form, both ways" {
    var peer: Peer = .{};
    defer peer.deinit();
    const long = "abcdefghij" ** 40; // 400 bytes
    try peer.frame(true, 2, long);
    var socket = peer.socket();

    const message = (try socket.receive()).?;
    try testing.expectEqualStrings(long, message.data);

    try socket.sendBinary(long);
    const head = peer.sent()[0..4];
    try testing.expectEqual(@as(u8, 0x82), head[0]); // FIN + binary
    try testing.expectEqual(@as(u8, 126), head[1]); // "the length is next"
    try testing.expectEqual(@as(u16, 400), std.mem.readInt(u16, head[2..4], .big));
}

test "a formatted message needs no buffer of the handler's own" {
    var peer: Peer = .{};
    defer peer.deinit();
    var socket = peer.socket();

    try socket.print("welcome, {d} here", .{3});
    try testing.expectEqualStrings("\x81\x0fwelcome, 3 here", peer.sent());

    // And one long enough to need the sixteen-bit length form, so the header
    // the counting pass chose is the one the bytes deserve.
    try socket.print("{s}", .{"z" ** 300});
    const rest = peer.sent()[17..];
    try testing.expectEqual(@as(u8, 0x81), rest[0]);
    try testing.expectEqual(@as(u8, 126), rest[1]);
    try testing.expectEqual(@as(u16, 300), std.mem.readInt(u16, rest[2..4], .big));
    try testing.expectEqualStrings("z" ** 300, rest[4..]);
}

test "a value goes out as one JSON text message" {
    var peer: Peer = .{};
    defer peer.deinit();
    var socket = peer.socket();

    try socket.json(.{ .kind = "joined", .who = "wati", .here = 3 });
    const body = "{\"kind\":\"joined\",\"who\":\"wati\",\"here\":3}";
    const sent = peer.sent();
    try testing.expectEqual(@as(u8, 0x81), sent[0]); // FIN + text
    try testing.expectEqual(@as(u8, body.len), sent[1]);
    try testing.expectEqualStrings(body, sent[2..]);
}

test "live follows the server's stopping flag" {
    var peer: Peer = .{};
    defer peer.deinit();
    var socket = peer.socket();
    var stopping = std.atomic.Value(bool).init(false);
    socket._stopping = &stopping;

    try testing.expect(socket.live());
    stopping.store(true, .release);
    try testing.expect(!socket.live());
}

test "a shutdown ends the loop, and the client is told why" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "still typing");
    var socket = peer.socket();
    var stopping = std.atomic.Value(bool).init(false);
    socket._stopping = &stopping;

    try testing.expectEqualStrings("still typing", (try socket.receive()).?.data);

    // A deploy starts. The handler's loop ends on its own — no `live()`
    // branch of its own — and the other end gets a close rather than a
    // socket that stopped answering (ADR 0020).
    stopping.store(true, .release);
    try testing.expectEqual(@as(?Message, null), try socket.receive());
    try testing.expectEqualStrings("\x88\x02\x03\xe9", peer.sent()); // 1001
    try testing.expect(!socket.closedCleanly());
}

test "a client that vanishes is the end of the conversation, not an error" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "one last thing");
    var socket = peer.socket();

    _ = (try socket.receive()).?;
    // The stream simply stops. A tab closed, a network gone — the most
    // ordinary way a WebSocket ends, and the same `null` a close frame gives.
    try testing.expectEqual(@as(?Message, null), try socket.receive());
    try testing.expect(!socket.closedCleanly());
}

test "a close frame is told apart from a client that vanished" {
    var peer: Peer = .{};
    defer peer.deinit();
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, 1000, .big);
    try peer.frame(true, 8, &payload);
    var socket = peer.socket();

    try testing.expectEqual(@as(?Message, null), try socket.receive());
    try testing.expect(socket.closedCleanly());
}

test "the acceptance says exactly what a client is looking for" {
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try writeAcceptance(&out, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "chat");

    try testing.expectEqualStrings(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
            "Sec-WebSocket-Protocol: chat\r\n\r\n",
        out.buffered(),
    );
}

test "the header a room builds once is the one a socket would have written" {
    // The Room frames a message for everybody at once, so the bytes it puts
    // in front of it have to be exactly the bytes this module would.
    var mine: [max_header]u8 = undefined;
    var theirs: [max_header]u8 = undefined;

    for ([_]u64{ 0, 1, 125, 126, 127, 1000, 65_535, 65_536, 1 << 20 }) |len| {
        try testing.expectEqualSlices(
            u8,
            writeHeader(&mine, .text, len),
            headerFor(&theirs, .text, len),
        );
        try testing.expectEqualSlices(
            u8,
            writeHeader(&mine, .binary, len),
            headerFor(&theirs, .binary, len),
        );
    }

    // And the three length forms are the shortest that will hold each.
    try testing.expectEqual(@as(usize, 2), headerFor(&mine, .text, 125).len);
    try testing.expectEqual(@as(usize, 4), headerFor(&mine, .text, 126).len);
    try testing.expectEqual(@as(usize, 4), headerFor(&mine, .text, 65_535).len);
    try testing.expectEqual(@as(usize, 10), headerFor(&mine, .text, 65_536).len);
}
