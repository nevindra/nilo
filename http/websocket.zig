//! WebSocket — the connection that stops being HTTP (ADR 021, ADR 062).
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
//! holds every byte of its stack (ADR 062). So the handler hands the loop
//! back and the connection loop runs it, which is `Handover` below and
//! ADR 062: 9,290 bytes an idle socket down to 5,183.
//!
//! Memory is one buffer per message **in flight**, not one per open socket. It
//! comes from the executor's free list when a message starts arriving and goes
//! back when the conversation goes quiet (`http/scratch.zig`). A message split
//! across frames is reassembled into it, and one bigger than
//! `Options.max_message` closes the connection with 1009 rather than growing
//! anything.
//!
//! **No byte of a message is copied twice** (ADR 046). A frame that is
//! already in the connection's read buffer — which is nearly every frame, and
//! every frame at all under the size of one read — is unmasked *as* it is
//! copied into the message buffer, in one pass. A frame too big to have
//! arrived whole is read straight into the message buffer, past the read
//! buffer entirely, and unmasked where it lands. There is no third case.

const std = @import("std");
const core = @import("nilo_core");

const bulkhead = @import("bulkhead.zig");
const watchdog = @import("watchdog.zig");
const http1 = @import("http1.zig");
const json_mod = @import("json.zig");
const naming = @import("names.zig");
const room_mod = @import("room.zig");
const scratch_mod = @import("scratch.zig");

/// The frame as bytes: header, masking, close payload and the rules a frame
/// is held to. It is `nilo_core`'s because `nilo_fetch`'s client reads and
/// writes the same frames and may not import this file (ADR 281, ADR 057).
const ws_frame = core.ws_frame;

pub const Options = struct {
    /// A sub-protocol this route speaks, the one-name spelling of `protocols`.
    /// Empty speaks none.
    ///
    /// **Answered only when the client offered it** (RFC 6455 §4.1). A browser
    /// fails a connection whose answer names a protocol it did not ask for, so
    /// writing the name back unasked, which this used to do, made
    /// `new WebSocket(url)` against such a route fail. A client that offered
    /// nothing, or nothing this route speaks, gets a handshake with no
    /// `Sec-WebSocket-Protocol` at all (ADR 046).
    protocol: []const u8 = "",

    /// The sub-protocols this route speaks. The client's
    /// `Sec-WebSocket-Protocol` is a list in its order of preference, and the
    /// answer is the first one of them found here, so a client offering two can
    /// be met by a route that speaks either. Added to `protocol` when both are
    /// set. Matching is exact: a protocol name is case-sensitive.
    protocols: []const []const u8 = &.{},

    /// Pages on other origins that may open this socket. Empty — the default —
    /// means only the origin this server is itself serving; `&.{"*"}` means
    /// anybody, which is what a public socket carrying no session wants.
    ///
    /// **A browser applies no CORS to a WebSocket.** It sends no preflight and
    /// honours no `Access-Control-Allow-Origin`, so a CORS middleware in front
    /// of an upgrade route sets headers nobody enforces and the socket opens
    /// anyway — **carrying the session cookie**, because the handshake is an
    /// ordinary GET. An application with `Session(T)` and `c.upgrade` on the
    /// same server was therefore open to a page on another origin reading and
    /// writing that user's socket for as long as the tab was open, and there is
    /// no browser step that refuses it: the whole check has to be the server's.
    ///
    /// So the default is same-origin, and what "same" means is the request's
    /// `Origin` naming the authority its `Host` did — **the scheme is not
    /// compared**, because TLS is terminated in front (ADR 027) and nilo never
    /// learns which one the browser used. A request with no `Origin` at all is
    /// allowed: that is not a browser, and the ambient-cookie problem this
    /// exists for is a browser's.
    ///
    /// Name an origin when the page and the socket are served from different
    /// hosts, which is an ordinary deployment:
    ///
    /// ```zig
    /// return c.upgradeWith(chatLoop, room, .{
    ///     .origins = &.{"https://app.example.com"},
    /// });
    /// ```
    ///
    /// Compared case-insensitively and read at run time rather than while
    /// compiling — unlike `cors.with`, whose list has to be a constant because
    /// the value that matched goes back out in a header. Here nothing goes
    /// back out, and a handshake happens once per connection, so an unrolled
    /// compare would buy nothing measurable and cost the option its ability to
    /// come from `nilo_config`.
    origins: []const []const u8 = &.{},

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
    /// That is ADR 021's recorded answer to the hole ADR 019 first named —
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
/// **ADR 021 refused to have this option at all**, on the grounds that the
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
/// connection, which for a chat tab is hours (ADR 062). So the handler does
/// the handshake and returns; the connection loop takes this back and runs the
/// loop from its own frame, a page higher up, with the request's machinery
/// already unwound. See ADR 062.
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
/// nilo asks of it is its first parameter (ADR 026).
pub fn checkLoop(comptime loop: anytype, comptime State: type) void {
    const Loop = @TypeOf(loop);
    const info = switch (@typeInfo(Loop)) {
        .@"fn" => |f| f,
        else => @compileError("nilo: a WebSocket route runs a function on the socket, and " ++
            naming.of(Loop) ++ " is not one"),
    };
    const wants: usize = if (State == void) 1 else 2;
    if (info.param_types.len != wants) {
        // The function's own type is not named here the way every other
        // refusal names what the caller wrote: `@typeName` of a function with
        // an inferred error set is four lines of `@typeInfo(@typeInfo(…))`,
        // which buries the sentence it is supposed to help.
        @compileError("nilo: a WebSocket loop takes " ++ (if (State == void)
            "*Socket and nothing else, because upgrade was given no state"
        else
            "*Socket and the state passed to upgrade (" ++ naming.of(State) ++ ")") ++
            "; this one takes " ++ num(info.param_types.len) ++ " argument" ++
            (if (info.param_types.len == 1) "" else "s"));
    }
    if (info.param_types[0] != *Socket) {
        @compileError("nilo: a WebSocket loop's first argument is *nilo.Socket, not " ++
            naming.of(info.param_types[0] orelse anyopaque));
    }
    if (State != void and info.param_types[1] != State) {
        @compileError("nilo: upgrade was given state of type " ++ naming.of(State) ++
            ", and the loop's second argument is " ++
            naming.of(info.param_types[1] orelse anyopaque));
    }
    // The loop runs after the handler has returned, so a `*Ctx` carried into
    // it points into a frame that is gone and at a request that is over: the
    // loop reads the next request's memory. Only through values, not behind
    // a pointer of the caller's, which is where the walk would have to guess
    // at whose memory it is reading.
    if (comptime ctxIn(State, "the state")) |where| {
        @compileError("nilo: " ++ where ++ " is a *nilo.Ctx, and the request it points at is over " ++
            "by the time the loop runs; take what the loop needs out of the Ctx before upgrade");
    }
    if (@sizeOf(State) > state_max) {
        @compileError("nilo: a WebSocket loop may carry " ++ num(state_max) ++
            " bytes of state and " ++ naming.of(State) ++ " is " ++ num(@sizeOf(State)) ++
            "; put it in the request arena and carry a pointer to it");
    }
    if (@alignOf(State) > state_align) {
        @compileError("nilo: a WebSocket loop's state is aligned to " ++ num(state_align) ++
            " bytes and " ++ naming.of(State) ++ " needs " ++ num(@alignOf(State)));
    }
}

/// Where in `T` a pointer to the request's `Ctx` sits, walking fields,
/// optionals and arrays, or null if nowhere. Named by `nilo_type_name` rather
/// than by type, because `ctx.zig` imports this file.
fn ctxIn(comptime T: type, comptime where: []const u8) ?[]const u8 {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            const C = p.child;
            if (@typeInfo(C) == .@"struct" and @hasDecl(C, naming.marker) and
                std.mem.eql(u8, @field(C, naming.marker), "nilo.Ctx")) return where;
            return null;
        },
        .optional => |o| return ctxIn(o.child, where),
        .array => |a| return ctxIn(a.child, where ++ "'s items"),
        .@"struct" => |s| {
            for (s.field_names, s.field_types) |f_name, f_type| {
                if (ctxIn(f_type, if (s.is_tuple) where ++ "'s item " ++ f_name else "field `" ++ f_name ++ "` of " ++ where)) |found| return found;
            }
            return null;
        },
        .@"union" => |u| {
            for (u.field_names, u.field_types) |f_name, f_type| {
                if (ctxIn(f_type, "field `" ++ f_name ++ "` of " ++ where)) |found| return found;
            }
            return null;
        },
        else => return null,
    }
}

fn num(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

pub const Kind = enum { text, binary };

/// One message, whole.
///
/// **`data` is borrowed, and the loan ends at the next `receive`.** A message
/// that arrived whole points into the connection's read buffer, which that
/// `receive` refills. One that did not points into this socket's message
/// buffer, which the socket does not own either: `takeScratch` borrows it
/// from the executor's free list and `giveScratch` hands it straight back
/// when the connection falls quiet (`park`) or ends. So a slice kept past one
/// turn of the loop is not merely stale, it is memory another message, or
/// another connection, may already be filling.
///
/// Nothing traps that. A `Str` that outlives its request is caught in Debug
/// (ADR 003) and this is not, which makes it the one
/// borrowed thing here a reader has to take on trust. A handler that wants a
/// message after the next `receive` copies it somewhere of its own first.
/// `room.say` and `socket.send` both finish with the bytes before they
/// return, which is why the ordinary echo loop never has to.
pub const Message = struct {
    kind: Kind,
    data: []u8,
};

/// Why a connection is being closed. The numbers are RFC 6455 §7.4.1's, and
/// the ones a server actually sends. Defined in `nilo_core` beside the rest of
/// the frame, because the client sends the same ones (ADR 281).
pub const Close = ws_frame.Close;

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

const Opcode = ws_frame.Opcode;

fn opcodeOf(kind: Kind) Opcode {
    return if (kind == .text) .text else .binary;
}

/// The longest a header nilo writes can be: two bytes and a 64-bit length.
/// A server never masks, so there are no four bytes of key on the end of it.
pub const max_header = ws_frame.max_header;

/// The bytes that go in front of one outgoing message, written into `into`
/// and returned as the part of it that counts.
///
/// Public because a `Room` builds this **once** for a message and every
/// connection in the room writes the same bytes. A server frame carries no
/// mask and no per-connection anything, so there is nothing in a header worth
/// building a thousand times (ADR 035, ADR 046).
pub fn headerFor(into: *[max_header]u8, kind: Kind, len: u64) []u8 {
    return writeHeader(into, opcodeOf(kind), len);
}

const writeHeader = ws_frame.writeHeader;

/// An open WebSocket connection.
pub const Socket = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Socket";

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
    /// The first room this connection sits in, and through its seat the
    /// rest (`room.Seating`). Empty is the ordinary case: a socket that
    /// echoes needs none of this.
    _seated: room_mod.Seating = .{},

    /// Where this connection's message buffer is parked between messages.
    ///
    /// Points at `Handover.scratch` on a real server, so that a handler which
    /// leaves its loop without a word still gives the buffer back — the
    /// connection loop owns that struct and holds the `defer`. Null for a
    /// Socket a test built by hand, which falls back to `_own_scratch` and
    /// hands it back when `receive` runs out.
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

    /// The request's blocking detector, or null for a Socket a test built by
    /// hand. A stretch of handler time ends at every park, so what is between
    /// two of them is what the handler did with one message (ADR 013).
    _watch: ?*watchdog.Watch = null,

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
            // the whole of ADR 028's finding, in three lines. A handler never
            // sees a post and never writes a branch for one.
            try self.deliver();

            // A server on its way out ends the conversation itself, rather
            // than leaving every handler to spell out the same `live()` check
            // and every client to find the socket gone without being told
            // (ADR 019). What is already queued has gone out above; what is
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
                //
                // That holds for the slot and not for `buf`, which an empty
                // first fragment has already filled from it: once `park` may
                // have given the buffer back, the local is forgotten too, and
                // the next fragment takes whatever the slot holds then.
                const may_give = filled == 0;
                if (may_give) buf = &.{};
                switch (self.park(may_give)) {
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
                        // A stop cancels the wait, and that wakes the socket
                        // as `.closed` too. The client is still there to be
                        // told, so it gets the 1001 the check above gives a
                        // socket that was not parked.
                        if (self.stopping()) {
                            self.closeWith(.going_away) catch {};
                            self.giveScratch();
                            return null;
                        }
                        self._closed = true;
                        return null;
                    },
                }
            }
            // Something arrived, so the question is answered whatever it was.
            self._awaiting_pong = false;

            // What is left of the ceiling, not the whole of it: a fragment
            // that cannot fit beside the ones already collected is refused on
            // what its header claims, before a byte of it is read.
            const frame = self.nextHeader(self._max_message - filled) catch |err| switch (err) {
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

            // A whole message already sitting in the connection's read buffer
            // is unmasked where it lies and handed over from there, which is
            // the loan `Message` describes: the buffer is only refilled by the
            // next `receive`. No message buffer is taken for it, and that is
            // the point rather than the copy it saves. A socket that lives
            // for ten messages took one from the executor's free list and gave
            // it back, and with more sockets open on an executor than its list
            // keeps spares for, every connection mapped sixteen kilobytes and
            // unmapped them again. Each unmapping stops every core the process
            // runs on to flush its TLB: measured, 420K of those in eight
            // seconds of `echo-ws-limited` against 600 for the same shape over
            // HTTP, and on the arena's sixty-four cores the server sat at
            // thirty-nine of them (ADR 216).
            if (filled == 0 and frame.fin and self._in.bufferedLen() >= frame.len) {
                const data = self._in.buffered()[0..@intCast(frame.len)];
                unmask(data, frame.mask, 0);
                self._in.toss(data.len);
                return self.handOver(kind.?, data);
            }

            // From here there are bytes to keep, so there has to be somewhere
            // to keep them. Taken only now: a socket that parks and never
            // hears anything again never holds one, and neither does one
            // whose messages all arrived whole.
            if (buf.len == 0) buf = self.takeScratch() catch {
                self.closeWith(.internal) catch {};
                return error.ReadFailed;
            };

            const into = buf[filled..][0..@intCast(frame.len)];
            self.readPayload(into, frame.mask) catch |err| return self.fail(err);
            filled += into.len;

            if (frame.fin) break;
        }

        return self.handOver(kind.?, buf[0..filled]);
    }

    /// A message with every frame in, whichever buffer it was collected in.
    fn handOver(self: *Socket, kind: Kind, data: []u8) Error!?Message {
        // Text is defined to be UTF-8, and a client is entitled to be told
        // when it is not rather than handed bytes that will break something
        // further along.
        if (kind == .text and !ws_frame.validText(data)) {
            self.closeWith(.invalid_payload) catch {};
            return error.ProtocolError;
        }
        return .{ .kind = kind, .data = data };
    }

    /// Send one message. Never fragmented: nilo has it all already, so
    /// there is nothing to be gained by cutting it up.
    ///
    /// A socket that has already closed writes nothing and says so with a
    /// plain return. The alternative — an error — would be one every handler
    /// has to branch on for the one case it cannot prevent: the other end
    /// closing between two of its own sends. That is the same reading
    /// `receive` gives a client that vanished (ADR 021).
    ///
    /// **A room's posts waiting for this connection leave first**, so what a
    /// handler said into a room and then sent here arrive in that order. The
    /// posts used to wait for the next `receive`, which put a `send` ahead of a
    /// `say` made before it. The check is one load of a null on a connection
    /// seated nowhere, and there is no allocation and no per-connection byte in
    /// it (ADR 046).
    pub fn send(self: *Socket, kind: Kind, data: []const u8) Error!void {
        if (self._closed) return;
        if (self._seated.room != null) try self.deliver();
        return self.sendFrame(opcodeOf(kind), data);
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
    /// memory another fiber is writing. **If they disagree the connection is
    /// closed rather than desynchronised** — `Framed` below is that check, and
    /// ADR 076 is why it is a close and not an assert.
    pub fn print(self: *Socket, comptime fmt: []const u8, args: anytype) Error!void {
        if (self._closed) return;
        if (self._seated.room != null) try self.deliver();
        const promise = try self.beginCounted(counted(struct {
            fn run(w: *std.Io.Writer, a: anytype) std.Io.Writer.Error!void {
                return w.print(fmt, a);
            }
        }.run, args));
        self._out.print(fmt, args) catch return error.WriteFailed;
        try self.keptTo(promise);
        try self.settle();
    }

    /// Serialise `value` as JSON into one text message — which is what a
    /// WebSocket carrying structured data almost always is.
    ///
    /// Two passes, for the reason `print` gives, and the same check between
    /// them.
    pub fn json(self: *Socket, value: anytype) Error!void {
        if (self._closed) return;
        if (self._seated.room != null) try self.deliver();
        const promise = try self.beginCounted(counted(json_mod.write, value));
        json_mod.write(self._out, value) catch return error.WriteFailed;
        try self.keptTo(promise);
        try self.settle();
    }

    /// Ask the other end to answer, which is how a connection through a
    /// proxy that drops quiet ones stays up. Nothing goes out on a socket
    /// that has closed, for the reason `send` gives.
    ///
    /// **Data past 125 bytes is cut to 125**, the most a control frame can
    /// carry (RFC 6455 §5.5). The alternative, an error, would be one more
    /// thing every caller handles for bytes nothing reads: nilo swallows the
    /// pong, so the payload is only ever a tag.
    pub noinline fn ping(self: *Socket, data: []const u8) Error!void {
        if (self._closed) return;
        return self.sendFrame(.ping, data[0..@min(data.len, 125)]);
    }

    /// Close, saying why. Safe to call twice, and safe to call after the
    /// other end has already closed.
    pub fn close(self: *Socket, code: Close, reason: []const u8) Error!void {
        if (self._closed) return;
        // What was said into a room before the goodbye is heard before it. A
        // connection already failing has nothing more to lose by trying.
        if (self._seated.room != null) self.deliver() catch {};
        self._closed = true;

        var payload: [ws_frame.max_control]u8 = undefined;
        try self.writeFrame(.close, ws_frame.closePayload(&payload, code, reason));
        // Flushed whatever the read buffer holds: this connection is not
        // going to read again, so there is no later moment (ADR 201).
        self._out.flush() catch return error.WriteFailed;
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
    /// (ADR 046). What it is still for is a handler doing work of its own
    /// between messages — a long computation, a timer, a queue it drains —
    /// which nilo cannot see and cannot end on its behalf (ADR 019).
    pub fn live(self: *const Socket) bool {
        return !self._closed and !self.stopping();
    }

    // ---- what a Room needs, and nothing more ----

    pub fn waker(self: *const Socket) bulkhead.Waker {
        return self._waker;
    }

    /// The head of the chain of rooms this socket sits in. A Room reads and
    /// writes it from this socket's own fiber and from nowhere else.
    pub fn seating(self: *Socket) *room_mod.Seating {
        return &self._seated;
    }

    /// Give up every seat this socket still holds. What the connection loop
    /// does when the loop returns, because each seat's bell lives in a frame
    /// that is about to go (ADR 082).
    pub fn leaveRooms(self: *Socket) void {
        while (self._seated.room) |in_room| in_room.leave(self);
    }

    /// Write out everything waiting for this connection. Called at the top of
    /// every `receive`, and by `receive` alone: a post is written by the fiber
    /// that owns the socket or it is not written at all.
    ///
    /// The posts are already framed — the room built the header once, for
    /// everybody — so each one is a single write, and the whole burst is one
    /// flush, across every room this socket sits in. A connection that was
    /// away for ten messages costs one syscall to catch up, not ten.
    noinline fn deliver(self: *Socket) Error!void {
        var any = false;
        var at = self._seated;
        while (at.room) |in_room| {
            while (in_room.take(at.ticket)) |post| {
                defer in_room.release(post);
                self._out.writeAll(in_room.framedBytes(post)) catch return error.WriteFailed;
                any = true;
            }
            at = in_room.after(at.ticket);
        }
        if (any) try self.settle();
    }

    fn stopping(self: *const Socket) bool {
        const flag = self._stopping orelse return false;
        return flag.load(.acquire);
    }

    // ---- the wire ----

    const Frame = ws_frame.Frame;
    const headerSize = ws_frame.headerSize;
    const headerFrom = ws_frame.headerFrom;

    /// The next frame's header, consumed. `room` is what is left of the
    /// handler's buffer, which is the only ceiling there is.
    fn nextHeader(self: *Socket, room: u64) Error!Frame {
        // Almost always the whole header is already in the connection's read
        // buffer, and then this is a slice and a few shifts: no fill, no copy,
        // no call into the reader at all.
        const frame = headerFrom(self._in.buffered()) orelse try self.fillHeader();

        // No reserved bit (nilo negotiates no extension), every frame from a
        // client masked, the length in its shortest form, a control frame
        // small and whole: `Frame.wellFormed` holds them, so the client in
        // `nilo_fetch` holds a server's frames to the same rules (RFC 6455
        // §5.2, ADR 281). A header read loosely here is one a proxy in front
        // may read strictly, which is how a frame is smuggled past it.
        if (!frame.wellFormed(.client)) return self.fail(error.ProtocolError);
        // Refused on what the header claims, before a byte of it is read: a
        // frame announcing four gigabytes should cost four bytes to refuse.
        if (!frame.opcode.isControl() and frame.len > room) return self.tooBig();

        self._in.toss(frame.size);
        return frame;
    }

    /// Wait for the rest of a header. Only reached when a frame arrived split
    /// across reads, which a real network does and a fixed buffer never will.
    fn fillHeader(self: *Socket) Error!Frame {
        // The only place a stream that stops means the connection simply
        // ended: between frames, with nothing half-read. A FIN and a reset
        // are the same event here, a client that has gone, and a client
        // that closes with `SO_LINGER` at zero, which is how a load
        // generator avoids `TIME_WAIT`, ends every connection with the
        // reset. So a read that fails on an empty buffer is the end of the
        // conversation, not an error for the handler's loop or a line in
        // the log; measured, the line was one per connection at 70,000
        // connections a second, and the one lock under it was what every
        // connection queued on to leave (ADR 202,
        // [`http.md`](../bench/result/http.md#a-reset-between-frames-is-a-client-that-has-gone)).
        // Everywhere below here a stream that stops is a truncated frame,
        // which is a broken one.
        const between = self._in.bufferedLen() == 0;
        const lead = (self._in.peekArray(2) catch |err| return switch (err) {
            error.EndOfStream => error.EndOfStream,
            else => if (between) error.EndOfStream else error.ReadFailed,
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
                // A goodbye that is not a goodbye — one byte where there
                // should be two, a code nobody assigned, a reason that is not
                // UTF-8 — is a framing error like any other, and echoing it
                // would put the same broken bytes back on the wire.
                if (!ws_frame.closeIsWellFormed(data)) return self.fail(error.ProtocolError);
                // Only now: a close frame that was not one is a framing error
                // and not a goodbye, so `closedCleanly` stays false for it.
                self._said_goodbye = true;
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

    /// Where this socket's buffer is parked. The Ctx's slot on a real server,
    /// its own field for a Socket a test built by hand — resolved on every
    /// call rather than once, because a `Socket` is handed to the handler by
    /// value and a pointer into the copy `upgrade` returned would dangle.
    fn slot(self: *Socket) *?[]align(std.heap.page_size_min) u8 {
        return self._scratch orelse &self._own_scratch;
    }

    /// This socket's message buffer, taken from the executor's free list the
    /// first time a message needs one.
    ///
    /// The slot holds the whole allocation, which the free list rounds up to a
    /// page; what comes back is exactly `_max_message` of it, so the ceiling a
    /// caller was promised is the ceiling a caller gets. A buffer that was
    /// quietly bigger than the option said is precisely the "the option is a
    /// lie" that ADR 021 refused to ship.
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

    /// Park until there is something to do, handing the connection's buffer
    /// pages back if it goes quiet first.
    ///
    /// `App.waitForRequest` does exactly this between two requests, and stops
    /// the moment a handler upgrades: a socket never goes back round that loop
    /// (ADR 021). So the twelve kilobytes an idle keep-alive connection hands
    /// back were held for the whole life of every WebSocket, which is a thing
    /// nobody had measured — `bench/ws_server.zig` and `bench/ws_idle.py` now
    /// do, and the entry is in `bench/result/http.md`.
    ///
    /// The short wait first is the whole design, and it is the HTTP side's
    /// lesson rather than a new one: releasing on every park took the
    /// keep-alive path from 1.31M req/s to 626k, because `MADV_DONTNEED` in a
    /// process with eight threads shoots TLB entries down on all of them. A
    /// socket with a conversation on it answers inside 200ms and never pays.
    fn park(self: *Socket, may_give_buffer: bool) bulkhead.Woken {
        // Nothing waits with a message still in memory. A send skips its
        // flush when the next frame is already buffered (`settle`), and this
        // is where the skipped flushes are made good: the wait below is on
        // the socket's readiness rather than on a read, so the Engine's own
        // guarantee, which sits on reads, does not reach it (ADR 201). A
        // peer that cannot be written to is a peer that is gone.
        if (self._out.end != 0) self._out.flush() catch return .closed;

        // Silence on a socket is not the handler holding its thread. This is
        // the wait that used to excuse a WebSocket from the detector
        // entirely; bracketed, what is left between two of them is exactly
        // what the handler did with one message (ADR 013).
        const token = watchdog.waiting(self._watch);
        defer watchdog.waited(self._watch, token);

        // A ping limit shorter than the peek is left alone rather than
        // reordered: the peek is supposed to be a prefix of the wait, not
        // longer than it.
        // Both peeks receive into the read buffer, which they hold anyway, so
        // a frame that arrives is parsed from memory with no read after it
        // (ADR 284); the wait after the buffers have gone back only listens.
        if (self._idle_ms != 0 and self._idle_ms <= idle_peek_ms) {
            return self._waker.waitFilling(self._idle_ms);
        }
        switch (self._waker.waitFilling(idle_peek_ms)) {
            .timed_out => {},
            else => |woken| return woken,
        }
        // Quiet. The allocation stays and nothing here allocates, so ADR
        // 017's per-request invariant is untouched; the next frame faults the
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

    /// One frame, gone, or as good as: on the wire unless the peer's next
    /// frame is already here, in which case it leaves with that one's
    /// answer (`settle`).
    fn sendFrame(self: *Socket, opcode: Opcode, data: []const u8) Error!void {
        try self.writeFrame(opcode, data);
        try self.settle();
    }

    /// Put what is written on the wire, unless the next frame is already
    /// waiting in the read buffer.
    ///
    /// A peer that sent its next message before reading this answer is not
    /// waiting on this flush, so the answer goes out with the next one, or
    /// with the last of the batch: a burst of sixteen echoes is one write
    /// rather than sixteen. A peer that sends one message and waits, which
    /// is a browser on a click, leaves the buffer empty and is answered here
    /// as it always was.
    ///
    /// What makes skipping safe is that nothing on this connection can wait
    /// for the peer with a message still in memory: `park` flushes before
    /// it waits, and the Engine flushes before any read of the socket
    /// ([ADR 201](../docs/adr/201-a-response-is-flushed-before-the-connection-waits.md)).
    /// What that leaves is a handler that stops calling `receive` while the
    /// peer has sent something it has not read, whose sends then leave when
    /// the write buffer fills; a handler that does not read what it is sent
    /// has a message queued for it either way.
    fn settle(self: *Socket) Error!void {
        if (self._in.bufferedLen() != 0) return;
        self._out.flush() catch return error.WriteFailed;
    }

    /// The header of a text message whose bytes are about to be printed
    /// straight into the connection.
    fn beginText(self: *Socket, len: u64) Error!void {
        var head: [max_header]u8 = undefined;
        self._out.writeAll(writeHeader(&head, .text, len)) catch return error.WriteFailed;
    }

    /// The same header, plus what `keptTo` needs to hold the writing pass to it.
    fn beginCounted(self: *Socket, len: u64) Error!Framed {
        const from = self._out.end;
        try self.beginText(len);
        const at = self._out.end;
        return .{
            .from = from,
            .at = at,
            .len = len,
            .bounded = len <= self._out.buffer.len - at,
        };
    }

    /// Whether the writing pass wrote the bytes the counting pass promised, and
    /// what to do when it did not (ADR 076).
    fn keptTo(self: *Socket, promise: Framed) Error!void {
        if (!promise.broken(self._out)) return;

        // Two passes that disagree put a length on the wire that is a lie, and
        // a WebSocket has no way to resynchronise from one: every frame after
        // this one is read at the wrong offset for the life of the connection.
        // So the connection ends here, in a way the other end can read.
        //
        // Usually the bad frame is still in the write buffer, whole and
        // unflushed, and then it never leaves the building at all.
        if (promise.recallable(self._out)) self._out.end = promise.from;
        self.closeWith(.internal) catch {};
        return error.WriteFailed;
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

/// A frame whose length went out before its bytes did, and what it takes to
/// check that the two agree ([ADR 076](../docs/adr/076-a-frame-that-lies-about-its-length-is-not-sent.md)).
///
/// `print` and `json` state a length from a counting pass and then write the
/// payload in a second pass. If the two disagree, the length on the wire is a
/// lie and the connection desynchronises for good — the one mistake in this
/// file that cannot be recovered from, and until ADR 076 the one place that
/// checked nothing. `Room.print` has the same two passes and has asserted
/// between them since the day it was written, because it writes into a buffer
/// it can measure.
///
/// The check is a subtraction and a compare, in every optimize mode, and it
/// needs neither a wrapper writer nor a third pass over the arguments. That is
/// what `at` buys: while the payload still fits in what is left of the
/// connection's write buffer nothing can drain, and while nothing drains
/// `Writer.end` is an exact count of what the second pass wrote.
///
/// **A message bigger than the write buffer is not checked**, because a drain
/// moves `end` and leaves nothing to compare against. `print` and `json` are
/// for the small structured messages a WebSocket carries — `send` takes bytes
/// somebody already has and needs none of this — so that is the uncommon shape
/// rather than the common one. It is a gap in the guard rather than a gap in
/// the framing, and it is written down instead of being papered over.
const Framed = struct {
    /// Where the write buffer stood before the header, so a frame that turns
    /// out to be a lie can be taken back off it instead of flushed.
    from: usize,
    /// Where the payload starts.
    at: usize,
    /// What the counting pass said the payload would be.
    len: u64,
    /// Whether `len` still fitted in the write buffer once the header was in.
    /// When it did, a drain is itself evidence: the second pass wrote more than
    /// it promised.
    bounded: bool,

    fn broken(self: Framed, out: *const std.Io.Writer) bool {
        if (!self.bounded) return false;
        if (out.end < self.at) return true;
        return out.end - self.at != self.len;
    }

    /// Whether the frame is still whole in the buffer, and so can be un-written.
    fn recallable(self: Framed, out: *const std.Io.Writer) bool {
        return out.end >= self.at;
    }
};

/// How many bytes something would be, without writing any of them. The
/// counting half of `print` and `json`, kept in one place so both pay the
/// same well-understood price and neither invents a buffer.
///
/// `Room.print` and `Room.json` count the same way for the same reason — a
/// frame states its length before its bytes — so they call this rather than
/// keeping a second copy of it. `u64` is the length a frame header carries;
/// a Room casts it down to the `usize` its allocation wants.
pub fn counted(
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

const unmask = ws_frame.unmask;
const unmaskInto = ws_frame.unmaskInto;

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
        // `Connection` is a comma-separated list of tokens (RFC 9110 §7.6.1),
        // so `keep-alive, Upgrade` is one, and `Upgrade-Insecure` or
        // `not-an-upgrade` are not: a substring match took both.
        if (!found_connection and std.ascii.eqlIgnoreCase(h.name, "connection")) {
            var tokens = std.mem.tokenizeScalar(u8, h.value, ',');
            while (tokens.next()) |token| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), "upgrade")) {
                    found_connection = true;
                    break;
                }
            }
        }
        // Both found, and a head with fifty more headers on it has nothing
        // left to say about this question.
        if (found_upgrade and found_connection) return true;
    }
    return false;
}

/// The sub-protocol to answer with: the first of the client's offers, across
/// every `Sec-WebSocket-Protocol` line, that the route speaks, or empty for
/// none (RFC 6455 §4.2.2). Returns the route's own spelling, which outlives
/// the request, rather than a view into the head (ADR 046).
pub fn negotiated(head: []const u8, options: Options) []const u8 {
    if (options.protocol.len == 0 and options.protocols.len == 0) return "";
    var headers = http1.HeaderIterator.from(head);
    while (headers.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "sec-websocket-protocol")) continue;
        var offers = std.mem.tokenizeScalar(u8, h.value, ',');
        while (offers.next()) |raw| {
            const offer = std.mem.trim(u8, raw, " \t");
            if (offer.len == 0) continue;
            if (options.protocol.len > 0 and std.mem.eql(u8, offer, options.protocol)) return options.protocol;
            for (options.protocols) |ours| {
                if (std.mem.eql(u8, offer, ours)) return ours;
            }
        }
    }
    return "";
}

/// Whether a `Sec-WebSocket-Key` is what RFC 6455 §4.1 says it is: the base64
/// of a sixteen-byte nonce, which is twenty-four characters ending in `==`.
/// A key that is not one is a client that is not speaking WebSocket, and the
/// handshake is a 400 rather than a 101 (ADR 046).
pub fn keyIsValid(key: []const u8) bool {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(key) catch return false;
    if (size != 16) return false;
    var nonce: [16]u8 = undefined;
    decoder.decode(&nonce, key) catch return false;
    return true;
}

/// Whether a page at `origin` may open this socket, given the `Host` the
/// request named and the origins the route allows. See `Options.origins` for
/// why this check exists at all and why the scheme is not part of it.
///
/// `host` is the whole `Host` field — authority and port, as the browser sent
/// it. An empty one matches nothing, which is what a hand-built `Ctx` and an
/// HTTP/1.0 request both come to; a real HTTP/1.1 request always has one,
/// because `parseHead` refuses the ones that do not (RFC 9112 §3.2).
pub fn originAllowed(origin: []const u8, host: []const u8, allowed: []const []const u8) bool {
    for (allowed) |one| {
        if (std.mem.eql(u8, one, "*")) return true;
        if (std.ascii.eqlIgnoreCase(one, origin)) return true;
    }
    return sameAuthority(origin, host);
}

/// Whether an origin names the authority a `Host` named, scheme aside.
/// `https://example.com` and `example.com` are the same place; so are
/// `http://localhost:5173` and `localhost:5173`. `csrf.zig` asks the same
/// question of a request that carries no `Sec-Fetch-Site` (ADR 224).
pub fn sameAuthority(origin: []const u8, host: []const u8) bool {
    if (host.len == 0) return false;
    const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return false;
    return std.ascii.eqlIgnoreCase(origin[scheme_end + "://".len ..], host);
}

/// The answer to `Sec-WebSocket-Key`. Written in `nilo_core`, because the
/// client in `nilo_fetch` checks the one this writes (ADR 281).
pub const accept = ws_frame.accept;

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
/// supply its own and the waiting costs nothing. ADR 032: a guard that has
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
        .half_close = struct {
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

/// A `Waker` whose wait is ended by a stop: it raises the server's stop flag
/// and answers `.closed`, which is what the Engine's cancel wakes a parked
/// socket with.
const Stopped = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn waker(self: *Stopped) bulkhead.Waker {
        return .{ .vtable = &vtable, .target = self };
    }

    const vtable: bulkhead.Waker.VTable = .{
        .wait = struct {
            fn f(target: ?*anyopaque, _: u32) bulkhead.Woken {
                const s: *Stopped = @ptrCast(@alignCast(target.?));
                s.flag.store(true, .release);
                return .closed;
            }
        }.f,
        .post = struct {
            fn f(_: ?*anyopaque) void {}
        }.f,
        .release_stack = struct {
            fn f(_: ?*anyopaque) void {}
        }.f,
        .half_close = struct {
            fn f(_: ?*anyopaque) void {}
        }.f,
    };
};

test "a socket parked when the server stops is told so with 1001" {
    var stopped: Stopped = .{};
    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: Socket = .{
        ._in = &in,
        ._out = &out,
        ._stopping = &stopped.flag,
        ._waker = stopped.waker(),
    };

    try testing.expect(try socket.receive() == null);
    // The close a server on its way out sends, rather than a connection that
    // simply ends (ADR 046).
    try testing.expectEqualStrings("\x88\x02\x03\xe9", out.buffered());
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
    /// way — the size is all a test gets to pick now (ADR 021's `max_message`,
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
/// kilobyte. Those paths are the slow half of ADR 046 and were untested
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
        const n = @min(self.rest.len, self.per, @backingInt(limit));
        const wrote = try w.write(self.rest[0..n]);
        self.rest = self.rest[wrote..];
        return wrote;
    }
};

/// A reader whose connection breaks: it hands over `bytes`, and then every
/// read fails the way a socket that was reset fails, with `ReadFailed`
/// rather than `EndOfStream`.
///
/// A load generator that closes with `SO_LINGER` at zero ends every
/// connection this way, and so does a client whose network went. `Trickle`
/// ends with a FIN and cannot stand in for it.
const Reset = struct {
    rest: []const u8,
    buf: [16]u8 = undefined,
    reader: std.Io.Reader = undefined,

    fn init(self: *Reset, bytes: []const u8) void {
        self.rest = bytes;
        self.reader = .{ .vtable = &vtable, .buffer = &self.buf, .seek = 0, .end = 0 };
    }

    const vtable: std.Io.Reader.VTable = .{ .stream = stream };

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *Reset = @alignCast(@fieldParentPtr("reader", r));
        if (self.rest.len == 0) return error.ReadFailed;
        const n = @min(self.rest.len, @backingInt(limit));
        const wrote = try w.write(self.rest[0..n]);
        self.rest = self.rest[wrote..];
        return wrote;
    }
};

test "a reset between frames ends the conversation the way a close does, quietly" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "last words");

    var reset: Reset = undefined;
    reset.init(peer.to_server.items);
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: Socket = .{ ._in = &reset.reader, ._out = &out, ._stopping = null };

    const message = (try socket.receive()).?;
    try testing.expectEqualStrings("last words", message.data);
    // The client is gone. Not an error: the handler's loop ends the way it
    // ends for a FIN, and nothing is logged for a client that hung up.
    try testing.expect(try socket.receive() == null);
    try testing.expect(!socket.closedCleanly());
    // Nothing was sent to a peer that cannot hear it.
    try testing.expectEqualStrings("", out.buffered());
}

test "a reset in the middle of a frame is still a broken frame" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "a message that never finishes arriving");

    var reset: Reset = undefined;
    // The header and the first few bytes of the payload, then the reset.
    reset.init(peer.to_server.items[0..12]);
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: Socket = .{ ._in = &reset.reader, ._out = &out, ._stopping = null };

    try testing.expectError(error.ReadFailed, socket.receive());
}

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

test "an upgrade is recognised, and an ordinary request is not" {
    try testing.expect(isUpgrade(
        "GET /ws HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
    ));
    // A browser sends `keep-alive, Upgrade`, so the value is a list.
    try testing.expect(isUpgrade(
        "GET /ws HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n\r\n",
    ));
    try testing.expect(!isUpgrade("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    // Half an upgrade is not one.
    try testing.expect(!isUpgrade("GET /ws HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\n\r\n"));
    try testing.expect(!isUpgrade("GET /ws HTTP/1.1\r\nHost: t\r\nConnection: Upgrade\r\n\r\n"));
    // The answer is settled before the rest of the head is walked.
    try testing.expect(isUpgrade(
        "GET /ws HTTP/1.1\r\nHost: t\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n" ++
            "X-Whatever: and a hundred more of these\r\n\r\n",
    ));
}

test "the page that opens a socket has to be one this server serves" {
    const none: []const []const u8 = &.{};

    // Same authority, whichever scheme the browser thinks it used. nilo sits
    // behind the TLS terminator (ADR 027) and never learns which it was.
    try testing.expect(originAllowed("https://example.dev", "example.dev", none));
    try testing.expect(originAllowed("http://example.dev", "example.dev", none));
    try testing.expect(originAllowed("http://localhost:5173", "localhost:5173", none));
    try testing.expect(originAllowed("https://EXAMPLE.dev", "example.dev", none));

    // A different host, a different port, and a host that merely ends the
    // same way — the three shapes of somebody else's page.
    try testing.expect(!originAllowed("https://evil.dev", "example.dev", none));
    try testing.expect(!originAllowed("http://localhost:5174", "localhost:5173", none));
    try testing.expect(!originAllowed("https://notexample.dev", "example.dev", none));
    // `null` is what a browser sends from a sandboxed iframe or a `file://`
    // page, and it is not an authority.
    try testing.expect(!originAllowed("null", "example.dev", none));

    // A named origin, which is what a page and a socket on two hosts needs.
    const named: []const []const u8 = &.{"https://app.example.com"};
    try testing.expect(originAllowed("https://app.example.com", "api.example.com", named));
    try testing.expect(originAllowed("HTTPS://App.Example.com", "api.example.com", named));
    try testing.expect(!originAllowed("https://other.example.com", "api.example.com", named));
    // Naming one does not stop the server answering its own pages.
    try testing.expect(originAllowed("https://api.example.com", "api.example.com", named));

    // And the public socket, which carries nothing worth stealing.
    try testing.expect(originAllowed("https://anywhere.dev", "example.dev", &.{"*"}));

    // With no `Host` to compare against — a hand-built `Ctx`, or HTTP/1.0 —
    // only a named origin gets in.
    try testing.expect(!originAllowed("https://example.dev", "", none));
    try testing.expect(originAllowed("https://example.dev", "", &.{"https://example.dev"}));
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

test "a message that arrived whole is handed over without taking a message buffer" {
    // The short-lived socket's case: ten small messages and gone. Taking a
    // buffer for each connection is what cost every core a TLB flush per
    // connection on a many-core machine (ADR 216).
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 2, "\x00\x01\x02\x03\x04\x05\x06\x07\x08");
    try peer.frame(true, 1, "second");
    var socket = peer.socket();

    const first = (try socket.receive()).?;
    try testing.expectEqual(Kind.binary, first.kind);
    try testing.expectEqualStrings("\x00\x01\x02\x03\x04\x05\x06\x07\x08", first.data);
    try testing.expect(socket._own_scratch == null);

    // Handed over from the read buffer and still good for what the loan
    // promises: echoing it back before the next `receive`.
    try socket.send(first.kind, first.data);
    try testing.expectEqualStrings("\x82\x09\x00\x01\x02\x03\x04\x05\x06\x07\x08", peer.sent());

    const second = (try socket.receive()).?;
    try testing.expectEqualStrings("second", second.data);
    try testing.expect(socket._own_scratch == null);
}

test "a message in pieces still collects into a message buffer" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(false, 1, "hel");
    try peer.frame(true, 0, "lo");
    var socket = peer.socket();
    defer socket.giveScratch();

    const message = (try socket.receive()).?;
    try testing.expectEqualStrings("hello", message.data);
    try testing.expect(socket._own_scratch != null);
}

test "a frame that arrives a few bytes at a time is the same message" {
    // The slow path, end to end: a header split across two reads and a
    // payload that never sits in the read buffer whole. What comes out has
    // to be byte for byte what the fast path produces.
    var peer: Peer = .{};
    defer peer.deinit();
    const long = repeat("the quick brown fox jumps over the lazy dog. ", 12); // 528 bytes
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

test "an empty first fragment and a quiet spell do not leave the message in a buffer given back" {
    // The empty fragment takes a message buffer and leaves nothing in it, so
    // the quiet spell after it is allowed to hand the buffer back. The
    // continuation then arrives in pieces, which is the path that writes into
    // the buffer, and it has to be one the socket still holds.
    var peer: Peer = .{};
    defer peer.deinit();
    const long = repeat("a continuation too long for the read buffer. ", 8);
    try peer.frame(false, 1, "");
    try peer.frame(true, 0, long);

    // Six bytes of empty fragment at three a read, so the reader is empty
    // once it is taken and the socket parks with the fragment open.
    var trickle: Trickle = undefined;
    trickle.init(peer.to_server.items, 3);
    // The first park, before anything arrives, spends one peek; the second,
    // after the empty fragment, spends the other and gives the buffer back.
    var quiet = Quiet{ .quiet_ms = 2 * Socket.idle_peek_ms };
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var socket: Socket = .{
        ._in = &trickle.reader,
        ._out = &out,
        ._stopping = null,
        ._waker = quiet.waker(),
    };
    defer socket.giveScratch();

    const message = (try socket.receive()).?;
    try testing.expectEqualStrings(long, message.data);
    try testing.expectEqual(@as(u64, 2 * Socket.idle_peek_ms), quiet.spent_ms);
    const held = socket._own_scratch orelse return error.MessageInABufferGivenBack;
    try testing.expectEqual(held.ptr, message.data.ptr);
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
    const reason = &@as([122]u8, @splat('x')) ++ "€" ++ "tail";
    try socket.close(.policy, reason);

    const sent = peer.sent();
    try testing.expectEqual(@as(u8, 0x88), sent[0]);
    const payload = sent[2..][0..sent[1]];
    try testing.expectEqual(@as(usize, 124), payload.len); // 2 + 122
    try testing.expect(std.unicode.utf8ValidateSlice(payload[2..]));
    try testing.expectEqualStrings(&@as([122]u8, @splat('x')), payload[2..]);
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
    try peer.frame(true, 1, &@as([200]u8, @splat('x')));
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
    try peer.frame(true, 1, &@as([300]u8, @splat('x')));
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
    try peer.frame(false, 1, &@as([40]u8, @splat('x')));
    try peer.frame(true, 0, &@as([40]u8, @splat('y')));
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
    const long = repeat("abcdefghij", 40); // 400 bytes
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
    try socket.print("{s}", .{&@as([300]u8, @splat('z'))});
    const rest = peer.sent()[17..];
    try testing.expectEqual(@as(u8, 0x81), rest[0]);
    try testing.expectEqual(@as(u8, 126), rest[1]);
    try testing.expectEqual(@as(u16, 300), std.mem.readInt(u16, rest[2..4], .big));
    try testing.expectEqualStrings(&@as([300]u8, @splat('z')), rest[4..]);
}

/// A value that formats differently the second time it is asked — which is
/// exactly the mistake `Socket.print`'s doc warns about, and until ADR 076 the
/// one nothing here could tell had happened.
const Shifting = struct {
    asked: *usize,

    pub fn format(self: Shifting, w: *std.Io.Writer) std.Io.Writer.Error!void {
        self.asked.* += 1;
        // Four bytes when it is counted, six when it is written.
        try w.writeAll(if (self.asked.* == 1) "abcd" else "abcdef");
    }
};

test "a format that disagrees with itself closes the connection instead of lying about a length" {
    var peer: Peer = .{};
    defer peer.deinit();
    var socket = peer.socket();

    var asked: usize = 0;
    try testing.expectError(
        error.WriteFailed,
        socket.print("{f}", .{Shifting{ .asked = &asked }}),
    );
    try testing.expectEqual(@as(usize, 2), asked);

    // Not one byte of the message left the building: the frame was still in
    // the write buffer, so what is on the wire is a close frame and nothing
    // in front of it.
    const sent = peer.sent();
    try testing.expectEqual(@as(usize, 4), sent.len);
    try testing.expectEqual(@as(u8, 0x88), sent[0]); // FIN + close
    try testing.expectEqual(@as(u8, 2), sent[1]);
    try testing.expectEqual(@as(u16, 1011), std.mem.readInt(u16, sent[2..4], .big));
    try testing.expect(!socket.live());

    // `json` is not tested separately because there is nothing separate to
    // test: both callers count with `counted`, take the header from
    // `beginCounted` and are held to it by `keptTo`, and those three are the
    // whole of the check.
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
    // socket that stopped answering (ADR 019).
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

/// A writer that counts how many times it put bytes on the wire, and keeps
/// them. What ADR 201 changes is how many writes a burst of echoes costs,
/// which `Peer`'s fixed writer cannot say: its flush is a no-op.
const Wire = struct {
    buffer: [1024]u8 = undefined,
    kept: std.ArrayList(u8) = .empty,
    writes: usize = 0,
    writer: std.Io.Writer = undefined,

    fn init(self: *Wire) void {
        self.writer = .{ .vtable = &vtable, .buffer = &self.buffer };
    }

    fn deinit(self: *Wire) void {
        self.kept.deinit(testing.allocator);
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Wire = @fieldParentPtr("writer", w);
        self.writes += 1;
        self.kept.appendSlice(testing.allocator, w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.kept.appendSlice(testing.allocator, bytes) catch return error.WriteFailed;
            n += bytes.len;
        }
        for (0..splat) |_| {
            self.kept.appendSlice(testing.allocator, data[data.len - 1]) catch return error.WriteFailed;
            n += data[data.len - 1].len;
        }
        return n;
    }
};

test "echoes of frames that arrived together leave in one write" {
    var peer: Peer = .{};
    defer peer.deinit();
    for (0..16) |_| try peer.frame(true, 1, "hello");
    var wire: Wire = .{};
    wire.init();
    defer wire.deinit();
    var socket = peer.socket();
    socket._out = &wire.writer;

    // The echo loop, as the HttpArena entry writes it. Each send finds
    // the next frame already in the read buffer and holds its echo; the
    // sixteenth finds nothing behind it and lets them all go.
    var echoed: usize = 0;
    while (try socket.receive()) |message| {
        try socket.send(message.kind, message.data);
        echoed += 1;
        if (echoed < 16) try testing.expectEqual(@as(usize, 0), wire.writes);
    }
    try testing.expectEqual(@as(usize, 16), echoed);
    try testing.expectEqual(@as(usize, 1), wire.writes);
    try testing.expectEqual(@as(usize, 16 * "\x81\x05hello".len), wire.kept.items.len);
    try testing.expectEqual(@as(usize, 16), std.mem.count(u8, wire.kept.items, "\x81\x05hello"));
}

test "an echo to a frame that arrived alone leaves at once" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "hello");
    var wire: Wire = .{};
    wire.init();
    defer wire.deinit();
    var socket = peer.socket();
    socket._out = &wire.writer;

    const message = (try socket.receive()).?;
    try socket.send(message.kind, message.data);
    // Nothing is buffered behind it, so nothing holds the answer: on the
    // wire before the handler has done anything else, the same as before.
    try testing.expectEqual(@as(usize, 1), wire.writes);
    try testing.expectEqualStrings("\x81\x05hello", wire.kept.items);

    // `print` and `json` settle the same way.
    try socket.print("{d} more", .{2});
    try testing.expectEqual(@as(usize, 2), wire.writes);
    try socket.json(.{ .n = 3 });
    try testing.expectEqual(@as(usize, 3), wire.writes);
}

test "a close frame leaves whatever the read buffer holds" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "hello");
    try peer.frame(true, 1, "unread");
    var wire: Wire = .{};
    wire.init();
    defer wire.deinit();
    var socket = peer.socket();
    socket._out = &wire.writer;

    _ = (try socket.receive()).?;
    // A handler that answers the first message by closing, with the second
    // still unread: the goodbye cannot wait for a read that is never coming.
    try socket.close(.normal, "bye");
    try testing.expectEqual(@as(usize, 1), wire.writes);
    try testing.expectEqualStrings("\x88\x05\x03\xe8bye", wire.kept.items);
}

test "a length written in a wider form than it needs is a protocol error" {
    // RFC 6455 §5.2: the minimal number of bytes MUST be used. A text frame
    // of five bytes in the sixteen-bit form, then in the sixty-four-bit form,
    // then a sixty-four-bit length with its top bit set.
    const key = "\x37\xfa\x21\x3d";
    const cases = [_][]const u8{
        "\x81\xfe\x00\x05" ++ key ++ "hello",
        "\x81\xff\x00\x00\x00\x00\x00\x00\x00\x05" ++ key ++ "hello",
        "\x81\xff\x00\x00\x00\x00\x00\x00\xff\xff" ++ key,
        "\x81\xff\x80\x00\x00\x00\x00\x00\x00\x05" ++ key,
    };
    for (cases) |bytes| {
        var peer: Peer = .{};
        defer peer.deinit();
        try peer.to_server.appendSlice(testing.allocator, bytes);
        var socket = peer.socket();
        try testing.expectError(error.ProtocolError, socket.receive());
        try testing.expectEqualStrings("\x88\x02\x03\xea", peer.sent()); // 1002
    }
}

test "a ping longer than a control frame can carry is cut, not sent broken" {
    var peer: Peer = .{};
    defer peer.deinit();
    var socket = peer.socket();

    try socket.ping(&@as([300]u8, @splat('p')));
    const sent = peer.sent();
    // 125 is the most a control frame holds; a 126 here would be the
    // sixteen-bit length form, which a control frame may not use.
    try testing.expectEqual(@as(usize, 2 + 125), sent.len);
    try testing.expectEqual(@as(u8, 0x89), sent[0]);
    try testing.expectEqual(@as(u8, 125), sent[1]);
}

test "Connection is a list of tokens, and only a token that is upgrade counts" {
    try testing.expect(isUpgrade(
        "GET /ws HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\nConnection: keep-alive , UPGRADE\r\n\r\n",
    ));
    try testing.expect(!isUpgrade(
        "GET /ws HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\nConnection: Upgrade-Insecure\r\n\r\n",
    ));
    try testing.expect(!isUpgrade(
        "GET /ws HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\nConnection: not-an-upgrade\r\n\r\n",
    ));
}

test "a close frame that is malformed does not count as a goodbye" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 8, "\x03");
    var socket = peer.socket();

    try testing.expectError(error.ProtocolError, socket.receive());
    try testing.expect(!socket.closedCleanly());
}

test "a sub-protocol is chosen from what the client offered, and only from that" {
    const head = "GET /ws HTTP/1.1\r\nHost: t\r\nSec-WebSocket-Protocol: graphql-ws, chat.v2\r\n" ++
        "Sec-WebSocket-Protocol: chat.v1\r\n\r\n";
    const none = "GET /ws HTTP/1.1\r\nHost: t\r\n\r\n";

    // The client's order wins among what the route speaks, across both lines.
    try testing.expectEqualStrings("chat.v2", negotiated(head, .{ .protocols = &.{ "chat.v1", "chat.v2" } }));
    // Spoken but not offered, and offered but not spoken: no answer at all.
    try testing.expectEqualStrings("", negotiated(head, .{ .protocols = &.{"mqtt"} }));
    try testing.expectEqualStrings("", negotiated(none, .{ .protocols = &.{"chat.v1"} }));
    // The single-protocol spelling still works, under the same rule.
    try testing.expectEqualStrings("chat.v1", negotiated(head, .{ .protocol = "chat.v1" }));
    try testing.expectEqualStrings("", negotiated(none, .{ .protocol = "chat.v1" }));
    try testing.expectEqualStrings("", negotiated(head, .{}));
}

test "a handshake key is sixteen bytes of base64 and nothing else" {
    try testing.expect(keyIsValid("dGhlIHNhbXBsZSBub25jZQ=="));
    try testing.expect(!keyIsValid(""));
    try testing.expect(!keyIsValid("x"));
    try testing.expect(!keyIsValid("dGhlIHNhbXBsZSBub25jZQ"));
    try testing.expect(!keyIsValid("dGhlIHNhbXBsZSBub25jZQ=!"));
    // Eighteen bytes, which is a valid base64 string and the wrong key.
    try testing.expect(!keyIsValid("dGhlIHNhbXBsZSBub25jZQECAwQF"));
}

/// `s` written `n` times over, at compile time: what `s ** n` said before
/// Zig 0.17 took the operator away.
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    // A comptime-known constant, so that `&built` is a pointer into the
    // binary and the call is as good at runtime as `**` was.
    const built = comptime blk: {
        @setEvalBranchQuota(10 * n + 1000);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        break :blk final;
    };
    return &built;
}
