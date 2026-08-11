//! WebSocket — the connection that stops being HTTP (ADR 0022).
//!
//! ```zig
//! fn echo(c: *zfast.Ctx) !void {
//!     var socket = try c.upgrade();
//!     var buf: [4096]u8 = undefined;
//!     while (try socket.receive(&buf)) |message| {
//!         try socket.send(message.kind, message.data);
//!     }
//! }
//! ```
//!
//! The handler owns the loop, the same way a streaming handler owns its
//! `Stream`: zfast does the handshake, the framing and the housekeeping
//! frames, and then gets out of the way.
//!
//! Memory is the buffer passed to `receive` and nothing else. A message
//! split across frames is reassembled into that buffer, and one too big for
//! it closes the connection with 1009 rather than growing anything.

const std = @import("std");

const http1 = @import("http1.zig");

/// The string every WebSocket handshake in the world hashes against. It has
/// no meaning; it is there so that a server which merely echoes the key
/// cannot be mistaken for one that speaks the protocol (RFC 6455 §1.3).
const handshake_salt = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Options = struct {
    /// A sub-protocol to agree to, echoed back in the handshake. Empty
    /// agrees to nothing, which is what a client that asked for nothing
    /// expects.
    protocol: []const u8 = "",
};

// There is deliberately no `max_message` here. The buffer handed to
// `receive` is the limit, and one limit is better than two: an option set to
// a megabyte and a 4 KB buffer means the option is a lie, and the way you
// find out is a connection closing with 1009 for no visible reason. Ask for
// the size you can hold.

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
    /// A message bigger than `Options.max_message`.
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
};

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

    /// The next message, or null once the connection is over.
    ///
    /// Null covers both ways it ends: a close frame, and a client that
    /// simply vanished — a tab closed, a network gone. They are the same
    /// thing to a handler's loop, so a client dropping without saying
    /// goodbye is not an error to write a branch for. `closedCleanly` tells
    /// them apart afterwards, for the handler that cares.
    ///
    /// Fragmented messages are reassembled into `buf`. Ping frames are
    /// answered and close frames are echoed without the handler seeing
    /// either: they are the protocol keeping itself alive.
    pub fn receive(self: *Socket, buf: []u8) Error!?Message {
        if (self._closed) return null;

        var filled: usize = 0;
        var kind: ?Kind = null;

        while (true) {
            const frame = self.readFrameHeader(buf.len) catch |err| switch (err) {
                error.EndOfStream => {
                    self._closed = true;
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

            // Fragments together may be more than one of them was.
            if (filled + frame.len > buf.len) return self.tooBig();
            const into = buf[filled..][0..@intCast(frame.len)];
            self._in.readSliceAll(into) catch return self.fail(error.ReadFailed);
            unmask(into, frame.mask, 0);
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

    /// Send one message. Never fragmented: zfast has it all already, so
    /// there is nothing to be gained by cutting it up.
    pub fn send(self: *Socket, kind: Kind, data: []const u8) Error!void {
        return self.writeFrame(if (kind == .text) .text else .binary, data);
    }

    pub fn sendText(self: *Socket, text: []const u8) Error!void {
        return self.send(.text, text);
    }

    pub fn sendBinary(self: *Socket, bytes: []const u8) Error!void {
        return self.send(.binary, bytes);
    }

    /// Ask the other end to answer, which is how a connection through a
    /// proxy that drops quiet ones stays up.
    pub fn ping(self: *Socket, data: []const u8) Error!void {
        return self.writeFrame(.ping, data);
    }

    /// Close, saying why. Safe to call twice, and safe to call after the
    /// other end has already closed.
    pub fn close(self: *Socket, code: Close, reason: []const u8) Error!void {
        if (self._closed) return;
        self._closed = true;

        var payload: [125]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], @intFromEnum(code), .big);
        const room = @min(reason.len, payload.len - 2);
        @memcpy(payload[2..][0..room], reason[0..room]);
        return self.writeFrame(.close, payload[0 .. 2 + room]);
    }

    /// Whether the connection ended with a close frame rather than by simply
    /// stopping. Only meaningful once `receive` has returned null.
    pub fn closedCleanly(self: *const Socket) bool {
        return self._said_goodbye;
    }

    /// Whether the server still wants this connection running. Goes false on
    /// a shutdown, exactly as `Stream.live` does — a socket held open past
    /// that point holds the deploy open with it (ADR 0020).
    pub fn live(self: *const Socket) bool {
        if (self._closed) return false;
        const stopping = self._stopping orelse return true;
        return !stopping.load(.acquire);
    }

    // ---- the wire ----

    const Frame = struct {
        fin: bool,
        opcode: Opcode,
        len: u64,
        mask: [4]u8,
    };

    fn readFrameHeader(self: *Socket, room: u64) Error!Frame {
        var first: [2]u8 = undefined;
        self._in.readSliceAll(&first) catch |err| return switch (err) {
            error.EndOfStream => error.EndOfStream,
            else => error.ReadFailed,
        };

        // The three reserved bits are for extensions that were negotiated in
        // the handshake. zfast negotiates none, so a frame setting one is
        // talking to a server that is not there.
        if (first[0] & 0x70 != 0) return self.fail(error.ProtocolError);

        const fin = first[0] & 0x80 != 0;
        const opcode: Opcode = @enumFromInt(@as(u4, @truncate(first[0])));

        // Every frame from a client is masked. An unmasked one is either a
        // broken client or something that is not a client at all, and the
        // RFC says to fail the connection either way.
        if (first[1] & 0x80 == 0) return self.fail(error.ProtocolError);

        const short_len: u7 = @truncate(first[1]);
        const len: u64 = switch (short_len) {
            126 => try self.readLen(u16),
            127 => try self.readLen(u64),
            else => short_len,
        };

        // A control frame has to fit in one small frame, because it may
        // arrive in the middle of somebody else's message.
        if (opcode.isControl() and (len > 125 or !fin)) return self.fail(error.ProtocolError);
        // Refused on what the header claims, before a byte of it is read: a
        // frame announcing four gigabytes should cost four bytes to refuse.
        if (!opcode.isControl() and len > room) return self.tooBig();

        var mask: [4]u8 = undefined;
        self._in.readSliceAll(&mask) catch return self.fail(error.ReadFailed);

        return .{ .fin = fin, .opcode = opcode, .len = len, .mask = mask };
    }

    fn readLen(self: *Socket, comptime T: type) Error!u64 {
        var raw: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        self._in.readSliceAll(&raw) catch return self.fail(error.ReadFailed);
        return std.mem.readInt(T, &raw, .big);
    }

    /// Deal with a ping, pong or close. Returns true if the conversation
    /// carries on, false if the other end has closed.
    fn handleControl(self: *Socket, frame: Frame) Error!bool {
        var payload: [125]u8 = undefined;
        const data = payload[0..@intCast(frame.len)];
        self._in.readSliceAll(data) catch return self.fail(error.ReadFailed);
        unmask(data, frame.mask, 0);

        switch (frame.opcode) {
            // A pong carries the ping's payload back, which is how the other
            // end tells its own pings apart.
            .ping => {
                try self.writeFrame(.pong, data);
                return true;
            },
            .pong => return true,
            .close => {
                // Echoed back, then this end is done. What the RFC calls the
                // closing handshake, and what stops a browser reporting an
                // ordinary goodbye as a connection error.
                self._said_goodbye = true;
                if (!self._closed) {
                    self._closed = true;
                    self.writeFrame(.close, data) catch {};
                }
                return false;
            },
            else => return self.fail(error.ProtocolError),
        }
    }

    fn writeFrame(self: *Socket, opcode: Opcode, data: []const u8) Error!void {
        var head: [10]u8 = undefined;
        head[0] = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN, no reserved bits

        // A server never masks. The mask exists to stop a hostile page
        // making a browser send bytes that a proxy would read as a request,
        // and only a browser is in that position.
        var head_len: usize = 2;
        if (data.len < 126) {
            head[1] = @intCast(data.len);
        } else if (data.len <= std.math.maxInt(u16)) {
            head[1] = 126;
            std.mem.writeInt(u16, head[2..4], @intCast(data.len), .big);
            head_len = 4;
        } else {
            head[1] = 127;
            std.mem.writeInt(u64, head[2..10], data.len, .big);
            head_len = 10;
        }

        self._out.writeAll(head[0..head_len]) catch return error.WriteFailed;
        self._out.writeAll(data) catch return error.WriteFailed;
        // Flushed every time: a message nobody sent yet is a message that
        // has not arrived, and there is no later moment to flush at.
        self._out.flush() catch return error.WriteFailed;
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

/// Undo the client's masking, in place. `offset` is how far into the message
/// these bytes are, so the key lines up across a payload read in pieces.
fn unmask(data: []u8, key: [4]u8, offset: usize) void {
    for (data, offset..) |*byte, i| byte.* ^= key[i % 4];
}

// ---- the handshake ----

pub const Handshake = struct {
    /// What goes back in `Sec-WebSocket-Accept`.
    accept: [28]u8,
};

/// Whether this request is asking to become a WebSocket. Checked before
/// anything is written, so a request that is not gets an ordinary answer.
pub fn isUpgrade(head: []const u8) bool {
    var found_upgrade = false;
    var found_connection = false;
    var headers = http1.HeaderIterator.from(head);
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "upgrade") and
            std.ascii.eqlIgnoreCase(std.mem.trim(u8, h.value, " \t"), "websocket"))
        {
            found_upgrade = true;
        }
        // `Connection` may be a list — `keep-alive, Upgrade` — so this looks
        // inside it rather than comparing the whole value.
        if (std.ascii.eqlIgnoreCase(h.name, "connection") and
            std.ascii.indexOfIgnoreCase(h.value, "upgrade") != null)
        {
            found_connection = true;
        }
    }
    return found_upgrade and found_connection;
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
        unmask(self.to_server.items[start..], key, 0);
    }

    /// A frame with the mask bit off, which no real client may send.
    fn unmaskedFrame(self: *Peer, opcode: u4, payload: []const u8) !void {
        const gpa = testing.allocator;
        try self.to_server.append(gpa, 0x80 | @as(u8, opcode));
        try self.to_server.append(gpa, @intCast(payload.len));
        try self.to_server.appendSlice(gpa, payload);
    }

    fn socket(self: *Peer) Socket {
        self.in = .fixed(self.to_server.items);
        self.out = .fixed(&self.from_server);
        return .{ ._in = &self.in, ._out = &self.out, ._stopping = null };
    }

    fn sent(self: *const Peer) []const u8 {
        return self.out.buffered();
    }
};

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
}

test "a text message arrives unmasked, and is echoed back without a mask" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "hello");
    var socket = peer.socket();

    var buf: [64]u8 = undefined;
    const message = (try socket.receive(&buf)).?;
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

    var buf: [64]u8 = undefined;
    const message = (try socket.receive(&buf)).?;
    try testing.expectEqualStrings("hello, world", message.data);
}

test "a ping is answered without the handler hearing about it" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 9, "are you there"); // ping
    try peer.frame(true, 1, "yes"); // and then a real message
    var socket = peer.socket();

    var buf: [64]u8 = undefined;
    const message = (try socket.receive(&buf)).?;
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

    var buf: [64]u8 = undefined;
    const message = (try socket.receive(&buf)).?;
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

    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(?Message, null), try socket.receive(&buf));
    // 0x88 = FIN + close, and the same payload back: the closing handshake.
    try testing.expectEqualStrings("\x88\x08" ++ "\x03\xe8bye up", peer.sent());

    // Closing again writes nothing, so a handler with a `close` after its
    // loop does not send a second one.
    try socket.close(.normal, "");
    try testing.expectEqual(@as(usize, 10), peer.sent().len);
}

test "an unmasked frame from a client is refused" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.unmaskedFrame(1, "hello");
    var socket = peer.socket();

    var buf: [64]u8 = undefined;
    try testing.expectError(error.ProtocolError, socket.receive(&buf));
    // 1002, and said properly rather than by hanging up.
    try testing.expectEqualStrings("\x88\x02\x03\xea", peer.sent());
}

test "text that is not UTF-8 is refused with the status that says so" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "\xff\xfe");
    var socket = peer.socket();

    var buf: [64]u8 = undefined;
    try testing.expectError(error.ProtocolError, socket.receive(&buf));
    // 1007, invalid payload — not 1002, which would say the framing was
    // wrong when the framing was fine.
    try testing.expectEqualStrings("\x88\x02\x03\xef", peer.sent());

    // Binary has no such rule: the same bytes are a perfectly good message.
    var other: Peer = .{};
    defer other.deinit();
    try other.frame(true, 2, "\xff\xfe");
    var binary_socket = other.socket();
    const message = (try binary_socket.receive(&buf)).?;
    try testing.expectEqual(Kind.binary, message.kind);
    try testing.expectEqualStrings("\xff\xfe", message.data);
}

test "a message bigger than the buffer closes the connection rather than growing" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "x" ** 200);
    var socket = peer.socket();

    var buf: [64]u8 = undefined;
    try testing.expectError(error.MessageTooBig, socket.receive(&buf));
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
    var socket = peer.socket();

    var small: [100]u8 = undefined;
    try testing.expectError(error.MessageTooBig, socket.receive(&small));
    try testing.expectEqualStrings("\x88\x02\x03\xf1", peer.sent()); // 1009
}

test "a continuation with nothing to continue is a protocol error" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 0, "orphan");
    var socket = peer.socket();

    var buf: [64]u8 = undefined;
    try testing.expectError(error.ProtocolError, socket.receive(&buf));
}

test "a reserved bit set means an extension nobody negotiated" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "hello");
    peer.to_server.items[0] |= 0x40; // RSV1
    var socket = peer.socket();

    var buf: [64]u8 = undefined;
    try testing.expectError(error.ProtocolError, socket.receive(&buf));
}

test "a long message uses the sixteen-bit length form, both ways" {
    var peer: Peer = .{};
    defer peer.deinit();
    const long = "abcdefghij" ** 40; // 400 bytes
    try peer.frame(true, 2, long);
    var socket = peer.socket();

    var buf: [1024]u8 = undefined;
    const message = (try socket.receive(&buf)).?;
    try testing.expectEqualStrings(long, message.data);

    try socket.sendBinary(long);
    const head = peer.sent()[0..4];
    try testing.expectEqual(@as(u8, 0x82), head[0]); // FIN + binary
    try testing.expectEqual(@as(u8, 126), head[1]); // "the length is next"
    try testing.expectEqual(@as(u16, 400), std.mem.readInt(u16, head[2..4], .big));
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

test "a client that vanishes is the end of the conversation, not an error" {
    var peer: Peer = .{};
    defer peer.deinit();
    try peer.frame(true, 1, "one last thing");
    var socket = peer.socket();

    var buf: [64]u8 = undefined;
    _ = (try socket.receive(&buf)).?;
    // The stream simply stops. A tab closed, a network gone — the most
    // ordinary way a WebSocket ends, and the same `null` a close frame gives.
    try testing.expectEqual(@as(?Message, null), try socket.receive(&buf));
    try testing.expect(!socket.closedCleanly());
}

test "a close frame is told apart from a client that vanished" {
    var peer: Peer = .{};
    defer peer.deinit();
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, 1000, .big);
    try peer.frame(true, 8, &payload);
    var socket = peer.socket();

    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(?Message, null), try socket.receive(&buf));
    try testing.expect(socket.closedCleanly());
}
