//! A WebSocket client: the socket a service opens to a feed it consumes
//! (ADR 281).
//!
//! ```zig
//! var ws: fetch.WebSocket = .idle;
//! defer ws.deinit();
//! try ws.open(&api, c, "wss://stream.example.com/prices", .{ .idle_ms = 30_000 });
//! try ws.sendText("{\"subscribe\":[\"BTC-USD\"]}");
//! while (try ws.receive()) |message| {
//!     handle(message.kind, message.data); // borrowed: copy what outlives the next receive
//! }
//! ```
//!
//! **It is `Exchange` with the middle left in.** A WebSocket starts as an
//! ordinary call, a GET that asks for `Upgrade: websocket`, and every decision
//! `nilo_fetch` has already made about a call is made about it: the gate, the
//! route's deadline, the system's roots or the private authority's, TLS,
//! `Call.unix_socket`, the `X-Request-Id` and the trace. The answer is the
//! thing that differs: a `101` leaves the connection open and no longer HTTP,
//! and this file takes it from there. `Exchange.upgraded` is the hand-over, and
//! the Exchange stays begun inside the `WebSocket` so that closing the socket
//! is the one place the connection is destroyed.
//!
//! The frame is not here. Its header, its masking, the rules a header is held
//! to and what a close frame carries are `nilo_core`'s `ws_frame`, written once
//! and used by the server's `Socket` as well (ADR 057, ADR 281).
//!
//! ## What was settled, and by whom
//!
//! - **A limit on a message, counted in decoded bytes** (`Call.max_message`,
//!   default 1 MiB). A frame announcing more than is left of it is refused on
//!   its header, before a byte of it is read, and the connection is closed
//!   with 1009. Counted after decoding because that is the only count that
//!   stays true if an extension is ever negotiated: gorilla counts frame
//!   bytes and has no default, which leaves a compressed message unbounded.
//!   There is no extension here (no permessage-deflate: the server does not
//!   have it either, ADR 046), so the two counts agree today.
//! - **A ping is answered by this side**, in `receive`, with the same payload
//!   and no word to the caller. tungstenite queues the pong and awc leaves it
//!   to the caller, and a caller that forgets is a connection the server
//!   closes for not answering.
//! - **A close waits a bounded time for the other side's** (`Call.close_timeout_ms`,
//!   5 s, coder/websocket's number), and says which way it ended.
//!
//! ## One fiber
//!
//! Like the server's `Socket`, a `WebSocket` belongs to one fiber at a time:
//! `receive` writes the pongs, so a second fiber in `send` while the first is
//! in `receive` would interleave two frames in one buffer. A feed read in one
//! place and written to from another is two sockets or a queue between them.
//!
//! ## What it costs
//!
//! No allocation on a message that arrived whole in the connection's read
//! buffer, which is nearly every message under 8 KiB and every message of a
//! price feed: it is handed over where it lies, the frame from a server being
//! unmasked. A message that did not (larger, or fragmented) is collected in
//! one buffer the socket holds, grown to the largest message seen and never
//! past `max_message`, and freed at `deinit`. The permit the open held
//! returns when the handshake is done, so a socket that lives for hours does
//! not count against `max_in_flight`.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("fetch.zig");
const params = @import("params.zig");

const frame = core.ws_frame;
const Client = fetch.Client;
const Exchange = fetch.Exchange;

/// The default ceiling on one message, in decoded bytes.
///
/// 1 MiB, against the cases that have to fit. A price feed's message is
/// hundreds of bytes and a chat platform's event a few kilobytes, so for both
/// this is a ceiling that is never near. The case that sets it is the
/// gateway whose first message is large: a bot's `READY` on a big platform is
/// hundreds of kilobytes and can pass a megabyte on the biggest, which is
/// why the number is a field and not a constant. The other direction is the
/// server that goes wrong: a peer that is compromised or buggy and sends a
/// message that never ends, and what it costs is one buffer per socket.
/// Others settled at 32 KiB (coder/websocket), 64 MiB (tungstenite) and
/// 128 MiB (undici); this is closer to the first than the last because a
/// buffer is held per socket, and a program that holds sixty-four of them
/// should not be able to be made to hold eight gigabytes by its upstreams.
/// Memory is paid at the size of the largest message that arrived, not in
/// advance, so the ceiling is a bound and not a reservation.
pub const default_max_message = 1 << 20;

/// How long `close` waits for the other side's close frame, in milliseconds.
/// coder/websocket's number: long enough for a peer across an ocean to answer
/// with a loaded queue in front of it, short enough that a shutdown which has
/// many sockets to close is not the slowest thing it does.
pub const default_close_timeout_ms = 5_000;

pub const Kind = enum { text, binary };

/// One message, whole.
///
/// **`data` is borrowed, and the loan ends at the next `receive`, `send` or
/// `close`.** A message that arrived whole points into the connection's read
/// buffer, which the next read refills, and one that did not points into the
/// socket's message buffer, which the next message overwrites. A slice kept
/// past one turn of the loop is stale. Nothing traps it, which makes it the
/// one thing in this file a reader has to take on trust, and it is the
/// server's `Message` with the same loan for the same reason (ADR 021).
pub const Message = struct {
    kind: Kind,
    data: []const u8,
};

/// How `close` ended.
pub const Closed = enum {
    /// The other side's close frame came back inside the time.
    acknowledged,
    /// It did not. The connection was dropped without it.
    timed_out,
    /// The connection was already gone, or went while waiting.
    dropped,
};

/// What `open` takes beyond the URL. Everything has a default and `.{}` is the
/// ordinary socket.
pub const Call = struct {
    /// Sent with the handshake, in this order. A name the handshake owns
    /// (`upgrade`, `connection`, `sec-websocket-key`, `-version`,
    /// `-extensions`, `-protocol`) is `error.ReservedHeader`: a second copy of
    /// one would be a handshake the far end reads either way. A subprotocol
    /// goes in `protocols`.
    headers: []const std.http.Header = &.{},
    /// The subprotocols this client speaks, in order of preference
    /// (`Sec-WebSocket-Protocol`). The one the server chose is
    /// `WebSocket.subprotocol`; an answer naming one that was not offered is
    /// `error.BadHandshake` (RFC 6455 §4.1).
    protocols: []const []const u8 = &.{},
    /// How long the open may take, end to end: connect, TLS, the request and
    /// the `101`. Null takes `Settings.timeout_ms`. **It bounds the open and
    /// nothing after it**: a socket is allowed to live for hours, and what
    /// bounds a silent one is `idle_ms`. The route's deadline is carried into
    /// the open the way it is into any call (ADR 105).
    timeout_ms: ?u32 = null,
    /// The biggest message `receive` will assemble, in decoded bytes. One past
    /// it closes the socket with 1009 and is `error.MessageTooBig`.
    max_message: usize = default_max_message,
    /// How long `receive` may wait with **nothing at all** arriving, a ping or
    /// a pong or a frame of a message included, before it is `error.Stalled`.
    /// Zero, the default, waits for ever, because a quiet socket is working:
    /// a chat gateway with nobody typing says nothing. A feed that must not go
    /// quiet sets it above the server's heartbeat. Silence is stamped at frame
    /// boundaries, so one frame that takes longer than this to arrive in
    /// pieces counts as silence.
    idle_ms: u32 = 0,
    /// How long `close` waits for the other side's close frame.
    close_timeout_ms: u32 = default_close_timeout_ms,
    /// Open the socket over the unix domain socket at this absolute path
    /// rather than dialling the URL's host, exactly as `Client.Call` does
    /// (ADR 272). The URL must be `ws://`; `wss://` is `error.TlsOverSocket`.
    unix_socket: ?[]const u8 = null,
};

pub const Error = Client.Error || error{
    /// The server answered the upgrade with something other than `101`. Its
    /// status is `WebSocket.status`: a 401 is a credential to refresh, a 429
    /// is a wait, and a 404 is a URL.
    UpgradeRefused,
    /// A `101` that is not an answer to this handshake: no `Upgrade:
    /// websocket`, no `Connection: Upgrade`, an accept key that is not the
    /// hash of ours, an extension nobody offered, a subprotocol nobody offered.
    BadHandshake,
    /// `Call.headers` names a header the handshake writes.
    ReservedHeader,
    /// A name in `Call.protocols` that is not a token (RFC 6455 §4.1).
    InvalidProtocol,
    /// The other end broke the framing rules. The socket was closed with 1002.
    ProtocolError,
    /// A message past `Call.max_message`. The socket was closed with 1009.
    MessageTooBig,
    /// Text that is not UTF-8. The socket was closed with 1007.
    InvalidPayload,
    /// `send` on a socket that is closed, or being closed.
    Closed,
};

/// What `receive` can fail with: the transport's errors, which `blame` names,
/// and the three this side decided.
const ReadError = Client.Error || error{ ProtocolError, MessageTooBig, InvalidPayload };

pub const WebSocket = struct {
    ex: Exchange = .idle,
    conn: *std.http.Client.Connection = undefined,
    in: *std.Io.Reader = undefined,
    out: *std.Io.Writer = undefined,
    state: State = .new,
    max_message: usize = default_max_message,
    idle_ms: u32 = 0,
    close_ms: u32 = default_close_timeout_ms,
    /// The collected message, for one that did not arrive whole.
    buf: []u8 = &.{},
    /// The status the server answered the upgrade with, kept so that a
    /// refusal can be read after `open` has failed. Zero before an answer.
    status: u16 = 0,
    /// The subprotocol the server chose: one of the slices in
    /// `Call.protocols`, which the caller owns, or null for none.
    subprotocol: ?[]const u8 = null,
    sent_close: bool = false,
    said_goodbye: bool = false,
    peer_code: ?u16 = null,
    peer_reason: [frame.max_control - 2]u8 = undefined,
    peer_reason_len: u8 = 0,

    const State = enum { new, open, closed, released };

    /// Nothing held: no socket, no permit, no buffer.
    pub const idle: WebSocket = .{};

    /// Dial `url` and ask to become a WebSocket. `ws://` and `wss://`, and
    /// `http://` and `https://` for the same two; anything else is
    /// `error.UnsupportedUriScheme`.
    ///
    /// **A WebSocket must not be copied once it has opened**, for the reason
    /// an `Exchange` must not: it holds one, and the Engine's deadline slot is
    /// registered by address. Declare it, open it where it stands and leave it
    /// there. `deinit` is safe on one that never opened, which is what lets
    /// the `defer` go above the `open`.
    ///
    /// A refusal leaves the status in `status` and the socket unopened; there
    /// is nothing to close.
    pub fn open(self: *WebSocket, client: *Client, c: anytype, url: []const u8, call: Call) Error!void {
        comptime core.checkScope(@TypeOf(c), "fetch.WebSocket.open");
        std.debug.assert(self.state == .new);
        self.status = 0;
        // The span of the open, as for any call: the socket that follows is
        // the other service's to trace, and its `traceparent` names this one
        // (ADR 247).
        const begun = core.traceBeginOf(c);
        self.begin(client, c, url, call, begun) catch |err| {
            self.ex.end();
            // Nothing was opened, so there is nothing to release and the
            // socket can be opened again: a reconnect loop retries on one.
            self.state = .new;
            if (begun) |b| Client.endTrace(c, b, .GET, url, self.status, @errorName(err));
            return err;
        };
        if (begun) |b| Client.endTrace(c, b, .GET, url, 101, null);
    }

    fn begin(
        self: *WebSocket,
        client: *Client,
        c: anytype,
        url: []const u8,
        call: Call,
        begun: ?core.trace.Outbound,
    ) Error!void {
        if (!client.started) return error.NotStarted;
        const arena = c.arena();
        for (call.headers) |h| if (reserved(h.name)) return error.ReservedHeader;
        for (call.protocols) |p| if (!isToken(p)) return error.InvalidProtocol;
        const http_url = try httpUrl(arena, url);

        // Sixteen random bytes, base64'd. Not a secret (RFC 6455 §4.1 asks
        // only that it be selected at random), it is what makes the answer
        // prove the server read this request and did not replay one.
        var nonce: [16]u8 = undefined;
        client.inner.io.random(&nonce);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &nonce);

        const extra: usize = if (call.protocols.len > 0) 1 else 0;
        const lines = try arena.alloc(std.http.Header, 4 + extra + call.headers.len);
        lines[0] = .{ .name = "Upgrade", .value = "websocket" };
        lines[1] = .{ .name = "Connection", .value = "Upgrade" };
        lines[2] = .{ .name = "Sec-WebSocket-Key", .value = &key };
        lines[3] = .{ .name = "Sec-WebSocket-Version", .value = "13" };
        if (extra == 1) lines[4] = .{
            .name = "Sec-WebSocket-Protocol",
            .value = try std.mem.join(arena, ", ", call.protocols),
        };
        @memcpy(lines[4 + extra ..], call.headers);

        var carried: [3]std.http.Header = undefined;
        var traceparent: [core.trace.text_len]u8 = undefined;
        const headers = try Client.withCarried(c, lines, &carried, client.settings.forward_request_id, begun, &traceparent);

        const head = try self.ex.begin(client, .{
            .method = .GET,
            .url = http_url,
            .headers = headers,
            .timeout_ms = call.timeout_ms,
            .unix_socket = call.unix_socket,
            .route_left_ms = core.timeLeftOf(c),
            .redirects = .refuse,
        });
        self.status = @backingInt(head.status);
        if (head.status != .switching_protocols) return error.UpgradeRefused;
        self.subprotocol = try checkAnswer(head.bytes, frame.accept(&key), call.protocols);

        // From here the connection is this socket's. What `begin` armed for
        // the head is over, and the permit goes back: it counts calls in
        // flight, and a socket that lasts for hours is not one.
        self.conn = self.ex.upgraded();
        self.in = self.conn.reader();
        self.out = self.conn.writer();
        self.ex.stopClocks();
        self.ex.releasePermit();
        self.max_message = call.max_message;
        self.idle_ms = call.idle_ms;
        self.close_ms = call.close_timeout_ms;
        self.state = .open;
    }

    /// The next message, or null when the conversation is over.
    ///
    /// Null covers every way it ends: a close frame (`closedCleanly` says so),
    /// and a connection that simply stopped. They are the same thing to a loop
    /// that reconnects, so neither is an error to write a branch for. Pings are
    /// answered and pongs and close frames are handled without the caller
    /// seeing any of them; a close frame is echoed.
    ///
    /// What is an error is a socket gone wrong rather than gone: `Stalled`
    /// after `Call.idle_ms` of silence, `MessageTooBig`, `InvalidPayload` and
    /// `ProtocolError` (each closed with its code first), and the transport's
    /// own. After any of them `receive` returns null.
    pub fn receive(self: *WebSocket) Error!?Message {
        if (self.state != .open) return null;
        self.ex.watchSilence(self.idle_ms);
        defer self.ex.stopClocks();
        const result = self.ex.bounded(readMessage, .{self}) catch |err| {
            self.state = .closed;
            return switch (err) {
                error.ProtocolError, error.MessageTooBig, error.InvalidPayload => |e| e,
                else => |e| self.ex.blame(e),
            };
        };
        // A stream that "ended" because the silence bound cancelled the read
        // is a stall and not an ordinary end: std reports both the same way.
        if (result == null and self.ex.clockFired()) return self.ex.blame(error.ReadFailed);
        return result;
    }

    /// Send one message, whole and in one frame. The frame is masked with four
    /// fresh random bytes, as RFC 6455 §5.3 requires of every frame a client
    /// sends: without it a page, or anything else that can make this side
    /// write bytes, could write ones a proxy in front would read as a request.
    pub fn send(self: *WebSocket, kind: Kind, data: []const u8) Error!void {
        return self.sendFrame(if (kind == .text) .text else .binary, data);
    }

    pub fn sendText(self: *WebSocket, text: []const u8) Error!void {
        return self.send(.text, text);
    }

    pub fn sendBinary(self: *WebSocket, bytes: []const u8) Error!void {
        return self.send(.binary, bytes);
    }

    /// `value` written out as JSON and sent as one text message. Text is
    /// refused while compiling: a `[]const u8` here would go out as one JSON
    /// *string*, quotes and all, and a message already encoded goes through
    /// `sendText`. The text is built on the client's allocator and freed
    /// before this returns, so a socket that lives for hours spends nothing
    /// of a Scope's arena on it.
    pub fn sendJson(self: *WebSocket, value: anytype) Error!void {
        comptime if (params.isText(@TypeOf(value))) @compileError(
            "nilo: fetch.WebSocket.sendJson was handed text, and would send it as one JSON string. " ++
                "A message already encoded goes through sendText.",
        );
        const gpa = self.ex.client.inner.allocator;
        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        std.json.Stringify.value(value, .{}, &text.writer) catch return error.OutOfMemory;
        return self.sendText(text.written());
    }

    /// A ping, for a caller that keeps the socket alive itself. `data` is cut
    /// to the 125 bytes a control frame carries. The pong comes back through
    /// `receive` and is swallowed there, so what it proves is that `receive`
    /// is being called and the peer is answering.
    pub fn ping(self: *WebSocket, data: []const u8) Error!void {
        return self.sendFrame(.ping, data[0..@min(data.len, frame.max_control)]);
    }

    /// Say goodbye, wait for the other side's, and let the socket go.
    ///
    /// **The wait is bounded**, by `Call.close_timeout_ms`: a peer that never
    /// answers a close frame holds a TCP connection, a buffer and a fiber for
    /// as long as it likes otherwise, and RFC 6455 §7.1.1 says only that the
    /// closer waits "for a reasonable time". Data that arrives meanwhile is
    /// read and dropped, so a peer that keeps sending cannot hold it open.
    /// Safe to call twice and safe after the peer has closed, in which case
    /// the goodbye was already exchanged and nothing is waited for.
    ///
    /// The connection is destroyed when this returns, whatever it returned.
    pub fn close(self: *WebSocket, code: frame.Close, reason: []const u8) Closed {
        if (self.state == .new or self.state == .released) return .dropped;
        defer self.release();
        if (self.said_goodbye) return .acknowledged;
        if (self.state != .open) return .dropped;

        self.ex.startClock(self.close_ms);
        defer self.ex.stopClocks();
        const verdict = self.ex.bounded(closeAndWait, .{ self, code, reason }) catch |err| {
            self.state = .closed;
            return switch (err) {
                error.ProtocolError, error.MessageTooBig, error.InvalidPayload => .dropped,
                else => |e| if (self.ex.blame(e) == error.TimedOut) .timed_out else .dropped,
            };
        };
        self.state = .closed;
        // The same collapse as in `receive`: the clock's cancelling the wait
        // reads as the connection ending.
        if (verdict == .dropped and self.ex.clockFired()) return .timed_out;
        return verdict;
    }

    /// Whether the conversation ended with a close frame from the other side,
    /// as opposed to the connection simply stopping.
    pub fn closedCleanly(self: *const WebSocket) bool {
        return self.said_goodbye;
    }

    /// The code the other side closed with, once it has.
    pub fn closeCode(self: *const WebSocket) ?u16 {
        return self.peer_code;
    }

    /// The reason that came with it, empty when there was none. Valid for the
    /// life of the socket.
    pub fn closeReason(self: *const WebSocket) []const u8 {
        return self.peer_reason[0..self.peer_reason_len];
    }

    /// Whether `receive` and `send` can still be called.
    pub fn isOpen(self: *const WebSocket) bool {
        return self.state == .open and !self.sent_close;
    }

    /// Let the socket go. **Never waits**: an open socket gets a close frame
    /// with 1000 written without a wait for the answer, which is the courtesy
    /// a `defer` can afford on an error path; `close` is the call that waits.
    /// Safe to call twice, after `close`, and on a socket that never opened.
    pub fn deinit(self: *WebSocket) void {
        if (self.state == .new or self.state == .released) return;
        if (self.state == .open and !self.sent_close) self.sendClose(.normal, "") catch {};
        self.release();
    }

    // ---- the wire ----

    /// The connection destroyed, the permit and the clocks given back, and the
    /// message buffer freed.
    fn release(self: *WebSocket) void {
        if (self.state == .released) return;
        self.ex.end();
        if (self.buf.len != 0) self.ex.client.inner.allocator.free(self.buf);
        self.buf = &.{};
        self.state = .released;
    }

    fn sendFrame(self: *WebSocket, opcode: frame.Opcode, data: []const u8) Error!void {
        if (self.state != .open or self.sent_close) return error.Closed;
        self.ex.bounded(writeFrame, .{ self, opcode, data }) catch |err| {
            self.state = .closed;
            return self.ex.blame(err);
        };
    }

    fn sendClose(self: *WebSocket, code: frame.Close, reason: []const u8) std.Io.Writer.Error!void {
        self.sent_close = true;
        var payload: [frame.max_control]u8 = undefined;
        return self.writeFrame(.close, frame.closePayload(&payload, code, reason));
    }

    /// One frame, masked under a key of its own, written into the connection's
    /// buffer and flushed.
    ///
    /// The mask is applied *as the bytes are copied into the write buffer*,
    /// one pass over the message and no scratch of this side's own, which is
    /// the server's finding turned round (ADR 046): there the XOR rides along
    /// with the move out of the read buffer, here with the move into the write
    /// buffer. The caller's slice is never written to.
    fn writeFrame(self: *WebSocket, opcode: frame.Opcode, data: []const u8) std.Io.Writer.Error!void {
        var key: [4]u8 = undefined;
        self.ex.client.inner.io.random(&key);
        var head: [frame.max_masked_header]u8 = undefined;
        try self.out.writeAll(frame.writeMaskedHeader(&head, opcode, data.len, key));
        var done: usize = 0;
        while (done < data.len) {
            const room = try self.out.writableSliceGreedy(1);
            const n = @min(room.len, data.len - done);
            frame.maskInto(room[0..n], data[done..][0..n], key, done);
            self.out.advance(n);
            done += n;
        }
        try self.conn.flush();
    }

    fn readMessage(self: *WebSocket) ReadError!?Message {
        var filled: usize = 0;
        var kind: ?Kind = null;

        while (true) {
            const header = self.nextHeader(self.max_message - filled) catch |err| switch (err) {
                // Between frames with nothing half-read: the other end is
                // gone, which is the end of the conversation and not a fault.
                error.EndOfStream => {
                    self.state = .closed;
                    return null;
                },
                else => |e| return e,
            };
            if (self.idle_ms != 0) self.ex.mark();

            if (header.opcode.isControl()) {
                // May arrive in the middle of a fragmented message, so it
                // must not disturb what has been collected.
                if (try self.handleControl(header)) continue;
                return null;
            }

            switch (header.opcode) {
                .text, .binary => {
                    if (kind != null) return self.fail(.protocol_error, error.ProtocolError);
                    kind = if (header.opcode == .text) .text else .binary;
                },
                .continuation => if (kind == null) return self.fail(.protocol_error, error.ProtocolError),
                else => return self.fail(.protocol_error, error.ProtocolError),
            }

            // `nextHeader` refused anything past what is left of the ceiling,
            // so this fits a `usize` and fits the buffer.
            const len: usize = @intCast(header.len);

            // A whole message already in the read buffer is handed over where
            // it lies. A server never masks, so there is nothing to undo and
            // nothing to copy, and no buffer is taken for it.
            if (filled == 0 and header.fin and self.in.bufferedLen() >= len) {
                const data = self.in.buffered()[0..len];
                self.in.toss(len);
                return self.finish(kind.?, data);
            }

            try self.reserve(filled + len);
            try self.in.readSliceAll(self.buf[filled..][0..len]);
            filled += len;
            if (self.idle_ms != 0) self.ex.mark();
            if (header.fin) break;
        }
        return self.finish(kind.?, self.buf[0..filled]);
    }

    /// A message with every frame in. Text is UTF-8 by definition and a
    /// caller is entitled to be told when it is not (RFC 6455 §5.6).
    fn finish(self: *WebSocket, kind: Kind, data: []const u8) ReadError!?Message {
        if (kind == .text and !frame.validText(data)) return self.fail(.invalid_payload, error.InvalidPayload);
        return .{ .kind = kind, .data = data };
    }

    /// The buffer big enough for `need` bytes of message, grown to what has
    /// been needed and no further than `max_message`.
    fn reserve(self: *WebSocket, need: usize) error{OutOfMemory}!void {
        if (self.buf.len >= need) return;
        const gpa = self.ex.client.inner.allocator;
        const grown = @min(@max(need, self.buf.len * 2), @max(need, self.max_message));
        self.buf = try gpa.realloc(self.buf, grown);
    }

    /// The next header, consumed, with every refusal a header can earn made
    /// here. `room` is what is left of the ceiling.
    fn nextHeader(self: *WebSocket, room: usize) ReadError!frame.Frame {
        const header = frame.headerFrom(self.in.buffered()) orelse try self.fillHeader();
        if (!header.wellFormed(.server)) return self.fail(.protocol_error, error.ProtocolError);
        // On what the header claims, before a byte of it is read: a frame
        // announcing four gigabytes costs four bytes to refuse.
        if (!header.opcode.isControl() and header.len > room) return self.fail(.too_big, error.MessageTooBig);
        self.in.toss(header.size);
        return header;
    }

    /// Wait for the rest of a header, which arrived split across reads.
    fn fillHeader(self: *WebSocket) ReadError!frame.Frame {
        // A read that fails with nothing buffered is the end of the
        // conversation, between frames. Anywhere after it is a truncated
        // frame, which is a broken one.
        const between = self.in.bufferedLen() == 0;
        const lead = (self.in.peekArray(2) catch |err| return switch (err) {
            error.EndOfStream => error.EndOfStream,
            else => if (between) error.EndOfStream else error.ReadFailed,
        }).*;
        const whole = try self.in.peek(frame.headerSize(lead));
        return frame.headerFrom(whole).?;
    }

    /// A ping, a pong or a close. True when the conversation goes on.
    fn handleControl(self: *WebSocket, header: frame.Frame) ReadError!bool {
        var payload: [frame.max_control]u8 = undefined;
        const data = payload[0..@intCast(header.len)];
        try self.in.readSliceAll(data);

        switch (header.opcode) {
            // The same payload back, which is how the other end tells its own
            // pings apart. No word to the caller.
            .ping => {
                if (!self.sent_close) try self.writeFrame(.pong, data);
                return true;
            },
            .pong => return true,
            .close => {
                // A goodbye that is not one is a framing error like any
                // other, and echoing it would put the same bytes back.
                if (!frame.closeIsWellFormed(data)) return self.fail(.protocol_error, error.ProtocolError);
                self.said_goodbye = true;
                self.noteClose(data);
                // The closing handshake: echoed, then this end is done.
                if (!self.sent_close) {
                    self.sent_close = true;
                    self.writeFrame(.close, data) catch {};
                }
                self.state = .closed;
                return false;
            },
            else => return self.fail(.protocol_error, error.ProtocolError),
        }
    }

    fn noteClose(self: *WebSocket, data: []const u8) void {
        if (data.len < 2) return;
        self.peer_code = std.mem.readInt(u16, data[0..2], .big);
        const reason = data[2..];
        @memcpy(self.peer_reason[0..reason.len], reason);
        self.peer_reason_len = @intCast(reason.len);
    }

    /// Say why, best effort, and fail. A connection failed without a close
    /// frame looks to the other end like a crash.
    fn fail(self: *WebSocket, code: frame.Close, err: ReadError) ReadError {
        if (!self.sent_close) self.sendClose(code, "") catch {};
        self.state = .closed;
        return err;
    }

    /// The body of `close`: the frame out, then everything in until the other
    /// side's close frame. Run under the one clock `close` started.
    fn closeAndWait(self: *WebSocket, code: frame.Close, reason: []const u8) ReadError!Closed {
        if (!self.sent_close) try self.sendClose(code, reason);
        while (true) {
            const header = self.nextHeader(std.math.maxInt(usize)) catch |err| switch (err) {
                error.EndOfStream => return .dropped,
                else => |e| return e,
            };
            // What arrives while saying goodbye is not wanted: a message is
            // read past, a ping is not answered (RFC 6455 §5.5.2 allows
            // either once a close has gone), and the close is what ends it.
            if (header.opcode != .close) {
                try self.in.discardAll64(header.len);
                continue;
            }
            var payload: [frame.max_control]u8 = undefined;
            const data = payload[0..@intCast(header.len)];
            try self.in.readSliceAll(data);
            if (!frame.closeIsWellFormed(data)) return .dropped;
            self.said_goodbye = true;
            self.noteClose(data);
            return .acknowledged;
        }
    }
};

// ---- the handshake ----

/// `ws://` and `wss://` are `http://` and `https://` to std, which has no
/// other idea of a scheme, and are the same sockets. One arena allocation for
/// the rewritten text; an `http` URL is passed as it is.
fn httpUrl(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    const map = [_][2][]const u8{
        .{ "wss://", "https://" },
        .{ "ws://", "http://" },
    };
    for (map) |pair| {
        if (url.len >= pair[0].len and std.ascii.eqlIgnoreCase(url[0..pair[0].len], pair[0])) {
            return std.mem.concat(arena, u8, &.{ pair[1], url[pair[0].len..] });
        }
    }
    for ([_][]const u8{ "https://", "http://" }) |scheme| {
        if (url.len >= scheme.len and std.ascii.eqlIgnoreCase(url[0..scheme.len], scheme)) return url;
    }
    return error.UnsupportedUriScheme;
}

/// The header names the handshake writes itself.
fn reserved(name: []const u8) bool {
    const names = [_][]const u8{
        "upgrade",                  "connection",
        "sec-websocket-key",        "sec-websocket-version",
        "sec-websocket-extensions", "sec-websocket-protocol",
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return false;
}

/// A subprotocol name is an HTTP token (RFC 6455 §4.1, RFC 9110 §5.6.2).
fn isToken(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    return true;
}

/// Whether a head carries `token` in a header called `name`, over every line
/// of that name and every comma-separated item on it.
fn hasToken(head: []const u8, name: []const u8, token: []const u8) bool {
    var it = std.http.HeaderIterator.init(head);
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, name)) continue;
        var items = std.mem.tokenizeScalar(u8, h.value, ',');
        while (items.next()) |item| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, item, " \t"), token)) return true;
        }
    }
    return false;
}

fn valueOf(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.http.HeaderIterator.init(head);
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return std.mem.trim(u8, h.value, " \t");
    }
    return null;
}

/// What a `101` has to say for it to be the answer to this request (RFC 6455
/// §4.2.2), and the subprotocol it chose, as the caller's own slice.
fn checkAnswer(head: []const u8, expected: [28]u8, offered: []const []const u8) error{BadHandshake}!?[]const u8 {
    if (!hasToken(head, "upgrade", "websocket")) return error.BadHandshake;
    if (!hasToken(head, "connection", "upgrade")) return error.BadHandshake;
    const accepted = valueOf(head, "sec-websocket-accept") orelse return error.BadHandshake;
    if (!std.mem.eql(u8, accepted, &expected)) return error.BadHandshake;
    // None was offered, so one in the answer is the server speaking a
    // protocol this side never agreed to.
    if (valueOf(head, "sec-websocket-extensions") != null) return error.BadHandshake;
    const chosen = valueOf(head, "sec-websocket-protocol") orelse return null;
    for (offered) |p| if (std.mem.eql(u8, p, chosen)) return p;
    return error.BadHandshake;
}

test {
    _ = @import("websocket_live.zig");
}
