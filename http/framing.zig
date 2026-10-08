//! The framing an answer leaves in: what `Ctx` hands a response to, so that
//! nothing above this file writes the bytes of one protocol (ADR 253).
//!
//! `Ctx` decides what the answer is, a status, a type, the headers a route
//! set and a body that is whole, streamed or a file, and whether the
//! connection can carry another request. How that is put on the wire is the
//! framing's: a status line, `Connection`, chunks and `settle` for HTTP/1.1;
//! frames and trailers for HTTP/2.
//!
//! **A tagged union with two arms, not a `Ctx` generic over its transport.**
//! A generic `Ctx` would compile every handler once per framing and spend the
//! size axis on it (ADR 017); the union costs one compare of a tag a write,
//! which the branch predictor never misses on a connection that only ever
//! has one arm. **The HTTP/2 arm exists only in a build that asked for HTTP/2**:
//! without `-Dhttp2` its type is `noreturn`, the tag is known while compiling,
//! and the union is the HTTP/1.1 arm and nothing else, so the default build
//! pays not even the compare.
//!
//! **The HTTP/2 arm collects a whole answer and pipes a streamed one.** A
//! request's answer is framed by the connection's fiber, never by the
//! request's (ADR 220), so this arm keeps what `Ctx` hands it in the request
//! arena for that fiber to frame. A stream, an event stream and a file are not
//! collected: `streamHead`, `piece` and `end` hand the connection the head, the
//! stream's own buffer and the end, through the outbound pipe, and the file is
//! read a buffer at a time into the same pipe (`outbound.zig`, ADR 260). The
//! pipe the other way, the body arriving, is `inbound.zig`. A gRPC call
//! answers one message, so it has no pipe, and `Ctx` refuses a stream there by
//! name (`Framing.canStream`).
//!
//! A WebSocket handed to the connection loop stays HTTP/1.1 only: it takes the
//! connection's reader and writer for their whole life, which `wire` gives it,
//! and a multiplexed connection has none to give. **An event stream whose
//! events come from Rooms is handed over on either framing**: on HTTP/1.1 the
//! connection loop runs it from its own frame, and on HTTP/2 the connection
//! keeps an `EventSource` for it, writes what the rooms post as `DATA` when it
//! wakes, and the handler's fiber has ended (ADR 227, ADR 260).
//!
//! **A trailer is the framing's to deliver, and every framing takes it.**
//! `Ctx` keeps the list a route set (`Ctx.setTrailer`); HTTP/2 sends it as a
//! HEADERS frame after the body, an HTTP/1.1 chunked body as a trailer
//! section, and a whole HTTP/1.1 answer chunked with one when the client said
//! it reads them (`TE: trailers`), and without it otherwise, which RFC 9110
//! §6.5.1 allows (ADR 254).

const std = @import("std");
const hpack = @import("hpack.zig");
const http1 = @import("http1.zig");
const inbound = @import("inbound.zig");
const outbound = @import("outbound.zig");
pub const http2_built = @import("nilo_build").http2;

pub const Header = http1.Header;

/// Where an answer is handed: the connection's writer, or an
/// answer kept whole for an HTTP/2 connection's fiber. Without `-Dhttp2` the
/// second has no values, as the framing's own second arm has none.
pub const Sink = union(enum) {
    wire: *std.Io.Writer,
    collect: if (http2_built) *Collected else noreturn,
};

/// How a request reaches `serve.serveRequest`: as an HTTP/1.1 head still to
/// be read from the connection, or as an HTTP/2 call its connection has read
/// already. Without `-Dhttp2` the second has no values, as `Sink`'s second arm
/// has none, so the default build knows the tag while compiling.
pub const Arrival = union(enum) {
    wire,
    call: if (http2_built) *const Call else noreturn,
};

/// A request that arrived as HTTP/2 rather than as HTTP/1.1 text, the way
/// `serve.serveRequest` takes it: what the framing read, and nothing written
/// back into a protocol it did not arrive in (ADR 253).
///
/// `head` is the request's fields as a head whose request line is empty
/// (`"\n"`, then a `name: value` line each, then the blank line), which
/// `http1.parseFields` holds to every rule an HTTP/1.1 head's fields are
/// held to and `Ctx` reads a header from as it reads any head. It is the
/// framing's to leave out what belongs to one connection rather than to the
/// request (RFC 9113 §8.2.2), and to say the body's length in it.
pub const Call = struct {
    method: []const u8,
    /// `:path`.
    target: []const u8,
    head: []const u8,
    /// The body, whole, with whatever envelope carried it taken off. Empty
    /// where `inbox` is set.
    body: []const u8,
    /// The body still arriving: the stream's `DATA` after its headers, read
    /// through the pipe the connection fills (ADR 260). Null for a request
    /// that sent none and for a gRPC call, whose message the connection has
    /// read already.
    inbox: ?*inbound.Inbox = null,
};

/// The framing a request's answers go to, from where `serveRequest` was told
/// to send them and the version the request was written in.
pub fn of(sink: Sink, in: *std.Io.Reader, minor_version: u1) Framing {
    return switch (sink) {
        .wire => |out| .{ .http1 = .{ .in = in, .out = out, .minor_version = minor_version } },
        .collect => |collected| if (comptime !http2_built) unreachable else .{ .http2 = collected },
    };
}

/// The trailers a route set (`Ctx.setTrailer`), and how HTTP/1.1 writes
/// them. The writers are reached through a pointer the first trailer sets,
/// so a program that never sets one links none of them: the move
/// `nilo.secure`'s block makes (ADR 246), worth 2,656 bytes of a stripped
/// `ReleaseFast` binary here (ADR 254).
pub const Trailing = struct {
    list: std.ArrayList(Header) = .empty,
    writers: ?*const Writers = null,

    /// What a whole answer is handed: the trailers, the writers, and whether
    /// the client said it reads them, which only an answer with some asks.
    pub fn out(self: *const Trailing, asked: bool) Trailers {
        return .{ .list = self.list.items, .asked = asked, .writers = self.writers };
    }
};

/// The trailers an answer carries, as a framing reads them.
pub const Trailers = struct {
    list: []const Header = &.{},
    /// Whether the client said it reads trailers (`TE: trailers`), worked out
    /// only when `list` is not empty.
    asked: bool = false,
    writers: ?*const Writers = null,
};

/// The two places HTTP/1.1 writes trailers.
pub const Writers = struct {
    whole: *const fn (h: *Http1, status: u16, content_type: []const u8, body: []const u8, keep: bool, extra: []const Header, list: []const Header) anyerror!void,
    last: *const fn (out: *std.Io.Writer, list: []const Header) anyerror!void,
};

/// What `Ctx.setTrailer` points `Trailing.writers` at.
pub const writers: Writers = .{ .whole = Http1.wholeChunked, .last = lastChunk };

fn lastChunk(out: *std.Io.Writer, list: []const Header) anyerror!void {
    return http1.writeLastChunkWith(out, list);
}

pub const Framing = union(enum) {
    http1: Http1,
    http2: if (http2_built) *Collected else noreturn,

    /// A whole answer, written and settled. `head_only` is a HEAD: the head a
    /// GET would get, its `Content-Length` the length of `body`, and no body.
    /// `keep` is whether the connection carries another request after this.
    pub fn whole(
        self: *Framing,
        status: u16,
        content_type: []const u8,
        body: []const u8,
        head_only: bool,
        keep: bool,
        extra: []const Header,
        trailers: Trailers,
    ) !void {
        switch (self.*) {
            .http1 => |*h| return h.whole(status, content_type, body, head_only, keep, extra, trailers),
            .http2 => |c| if (comptime !http2_built) unreachable else return c.whole(status, content_type, body, head_only, extra, trailers.list),
        }
    }

    /// Say that the answer about to be handed over is a failure, and which:
    /// the error and the sentence it carried. An envelope that has codes of
    /// its own picks one from the error before the status, where the status
    /// alone would lose it (a duplicate row is a 409 and a rolled-back
    /// transaction a 503, and gRPC has a code of its own for each).
    /// Nothing on HTTP/1.1, whose answer is the status and the body.
    pub fn failed(self: *Framing, err: anyerror, message: []const u8) !void {
        switch (self.*) {
            .http1 => {},
            .http2 => |c| if (comptime !http2_built) unreachable else {
                c.failure = err;
                c.message = try c.arena.dupe(u8, message);
            },
        }
    }

    /// The head of an answer of `len` bytes and none of them: a HEAD of a
    /// file, which has a length and no slice to take it from.
    pub fn head(
        self: *Framing,
        status: u16,
        content_type: []const u8,
        len: u64,
        keep: bool,
        extra: []const Header,
    ) !void {
        switch (self.*) {
            .http1 => |*h| return h.head(status, content_type, len, keep, extra),
            .http2 => |c| if (comptime !http2_built) unreachable else return c.head(status, content_type, len, extra),
        }
    }

    /// How a stream of `length` bytes, or of a length nobody knows, is told
    /// apart from the next answer. Asked before the head is written, because
    /// `Ctx` keeps the answer on its `Open` record.
    pub fn streamShape(self: *const Framing, length: ?u64) StreamShape {
        return switch (self.*) {
            .http1 => |h| h.streamShape(length),
            // Asked for, and never used: `streamHead`, which comes next,
            // refuses. A shape is still an answer, so nothing here has to be
            // optional.
            .http2 => if (comptime !http2_built) unreachable else .{ .chunked = false, .ends_connection = false },
        };
    }

    pub fn streamHead(
        self: *Framing,
        status: u16,
        content_type: []const u8,
        shape: StreamShape,
        length: ?u64,
        keep: bool,
        extra: []const Header,
    ) !void {
        switch (self.*) {
            .http1 => |*h| return h.streamHead(status, content_type, shape, length, keep, extra),
            .http2 => |c| if (comptime !http2_built) unreachable else return c.streamHead(status, content_type, shape, length, extra),
        }
    }

    /// Whether a streamed answer or a file can be carried: always on HTTP/1.1,
    /// and on HTTP/2 for every request but a gRPC call, which answers one
    /// message and has no pipe to the connection for more.
    pub fn canStream(self: *const Framing) bool {
        return switch (self.*) {
            .http1 => true,
            .http2 => |c| if (comptime !http2_built) unreachable else c.streamer != null,
        };
    }

    /// One piece of a streamed body: what the stream's buffer held, then
    /// `data` with its last slice written `splat` times, the shape of a
    /// `std.Io.Writer` drain.
    pub fn piece(self: *Framing, chunked: bool, buffered: []const u8, data: []const []const u8, splat: usize) !void {
        switch (self.*) {
            .http1 => |*h| return h.piece(chunked, buffered, data, splat),
            .http2 => |c| if (comptime !http2_built) unreachable else return c.piece(buffered, data, splat),
        }
    }

    /// Put what has been written on the wire.
    pub fn flush(self: *Framing) !void {
        switch (self.*) {
            .http1 => |*h| return h.out.flush(),
            .http2 => if (comptime !http2_built) unreachable else return,
        }
    }

    /// End a streamed body, with the marker that ends it when it has one, and
    /// the trailers after it where the framing can carry them: a chunked body
    /// can, a body framed by its length or by the connection closing cannot.
    pub fn end(self: *Framing, marked: bool, trailers: Trailers) !void {
        switch (self.*) {
            .http1 => |*h| return h.end(marked, trailers),
            .http2 => |c| if (comptime !http2_built) unreachable else return c.endBody(trailers),
        }
    }

    /// The head, then `len` bytes of the file `reader` is at. What it returns
    /// is what was sent, which is short only when the file was cut under the
    /// transfer.
    pub fn file(
        self: *Framing,
        status: u16,
        content_type: []const u8,
        reader: *std.Io.File.Reader,
        len: u64,
        keep: bool,
        extra: []const Header,
    ) !u64 {
        switch (self.*) {
            .http1 => |*h| return h.file(status, content_type, reader, len, keep, extra),
            .http2 => |c| if (comptime !http2_built) unreachable else return c.file(status, content_type, reader, len, extra),
        }
    }

    /// `100 Continue`, for a client that asked to be told before it sends its
    /// body (RFC 9110 §10.1.1). On HTTP/2 the connection is asked, and says it
    /// if the body has not started to arrive.
    pub fn interimContinue(self: *Framing) !void {
        switch (self.*) {
            .http1 => |*h| return h.interimContinue(),
            // Asked of the connection, whose fiber writes it: the one that
            // touches the socket (ADR 260).
            .http2 => |collected| if (comptime !http2_built) unreachable else {
                if (collected.inbound) |pipe| pipe.askContinue();
            },
        }
    }

    /// The pipe the request's body arrives through, on HTTP/2.
    pub fn inbox(self: *const Framing) ?*inbound.Inbox {
        return switch (self.*) {
            .http1 => null,
            .http2 => |collected| if (comptime !http2_built) unreachable else collected.inbound,
        };
    }

    /// Hand the connection an event stream whose events come from Rooms, on
    /// a framing that writes it from a connection shared with other requests:
    /// HTTP/2's. The handler returns right after, and holds nothing of the
    /// stream (ADR 227, ADR 260). Never asked of HTTP/1.1, whose connection
    /// loop runs the stream from its own frame (`wire`).
    pub fn handOverEvents(self: *Framing, source: EventSource) !void {
        switch (self.*) {
            .http1 => unreachable,
            .http2 => |c| if (comptime !http2_built) unreachable else return c.handOver(source),
        }
    }

    /// The pipe's link to the connection, for a bell a Room rings: what the
    /// connection is woken through. Null where the framing has no connection
    /// of its own to wake (HTTP/1.1, whose waker is the request's).
    pub fn eventLink(self: *const Framing) ?inbound.Link {
        return switch (self.*) {
            .http1 => null,
            .http2 => |c| if (comptime !http2_built) unreachable else if (c.streamer) |st| st.link else null,
        };
    }

    /// The connection itself, for a WebSocket or an event stream that takes
    /// it over for the rest of its life. Null on a framing that has no
    /// connection of one request's own to give.
    pub fn wire(self: *const Framing) ?Http1 {
        return switch (self.*) {
            .http1 => |h| h,
            .http2 => if (comptime !http2_built) unreachable else null,
        };
    }
};

/// An event stream handed to an HTTP/2 connection (ADR 227, ADR 260): what the
/// connection's fiber holds of it, with nothing of the handler's. The stream's
/// state lives in the request's arena, and the connection reaches it through
/// these pointers only, so a server that never calls `eventsFrom` links none
/// of the rooms behind it, as HTTP/1.1's `Handover.Events.run` does.
pub const EventSource = struct {
    state: *anyopaque,
    /// Write what is posted, as far as the windows and the turn allow.
    step: *const fn (state: *anyopaque, wire: *EventWire) EventError!Stepped,
    /// Give up every seat and release what the stream still holds. Safe from
    /// any thread, and the last thing done with `state`.
    leave: *const fn (state: *anyopaque) void,
    /// A comment this often while nothing is said; 0 sends none.
    keepalive_ms: u32,
    /// When the connection next owes the stream a comment, as a
    /// `monotonicNanos` reading. The connection's fiber only.
    due_ns: u64 = 0,
};

pub const Stepped = enum {
    /// Everything posted is written.
    drained,
    /// Something posted is held: the windows or the turn ran out.
    blocked,
};

pub const EventError = error{ WriteFailed, OutOfMemory };

/// The connection, as an event stream writes to it for the length of one
/// turn: `put` is the DATA frames of the stream under both windows, and
/// `quantum` what is left of the turn (`h2conn.pump_quantum`).
pub const EventWire = struct {
    conn: *anyopaque,
    stream: *anyopaque,
    /// An event is formatted here and written from here, so an event that
    /// does not fit the window is written from where it stopped. One buffer
    /// to a connection, however many streams it has.
    scratch: *std.Io.Writer.Allocating,
    /// What a stream keeps of an event the windows took only part of.
    gpa: std.mem.Allocator,
    quantum: usize,
    /// Write as much of `bytes` as the windows and the turn allow, as DATA
    /// frames, and say how much.
    put: *const fn (wire: *EventWire, bytes: []const u8) std.Io.Writer.Error!usize,
    /// How many bytes `put` would take now.
    room: *const fn (wire: *const EventWire) usize,
};

/// How a streamed body ends.
pub const StreamShape = struct {
    /// Each piece carries its own length and a last, empty one ends the body.
    chunked: bool,
    /// Nothing marks the end but the connection closing, so it cannot carry
    /// another request: HTTP/1.0 with no length given.
    ends_connection: bool,
    /// A HEAD: the head a GET would get and no body, which a framing that
    /// ends the stream with its head has to know before the body ends.
    bodyless: bool = false,
};

/// HTTP/1.1, and HTTP/1.0 where it differs: the bytes `http1.zig` writes.
pub const Http1 = struct {
    /// The connection's reader, read here only to know whether the next
    /// request is already in (`settle`).
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    minor_version: u1,

    fn connection(self: *const Http1, keep: bool) http1.Connection {
        return .of(keep, self.minor_version);
    }

    fn whole(
        self: *Http1,
        status: u16,
        content_type: []const u8,
        body: []const u8,
        head_only: bool,
        keep: bool,
        extra: []const Header,
        trailers: Trailers,
    ) !void {
        // Trailers need a chunked body to ride on, so an answer that has them,
        // for a client that said it reads them, is chunked rather than
        // given a length. Not for HTTP/1.0, which has no chunks, nor for an
        // answer with no body to chunk; those leave without them.
        if (trailers.writers) |w| if (trailers.list.len > 0 and trailers.asked and
            self.minor_version == 1 and !head_only and !http1.bodyless(status))
        {
            return w.whole(self, status, content_type, body, keep, extra, trailers.list);
        };
        if (head_only) {
            try http1.writeResponseHeadOnly(self.out, status, http1.statusPhrase(status), content_type, body.len, self.connection(keep), extra);
        } else {
            try http1.writeResponse(self.out, status, http1.statusPhrase(status), content_type, body, self.connection(keep), extra);
        }
        // On the wire now, unless the client has pipelined the next request
        // behind this one, in which case it goes out with that one's answer
        // (ADR 201).
        try http1.settle(self.out, self.in);
    }

    fn head(self: *Http1, status: u16, content_type: []const u8, len: u64, keep: bool, extra: []const Header) !void {
        try http1.writeResponseHeadOnly(self.out, status, http1.statusPhrase(status), content_type, len, self.connection(keep), extra);
        try http1.settle(self.out, self.in);
    }

    /// A length already says where the body stops, so there is nothing for
    /// chunked framing to add and a head must not carry both. Otherwise
    /// HTTP/1.1 gets chunks; HTTP/1.0 has neither, so the end of the body can
    /// only be the end of the connection.
    fn streamShape(self: Http1, length: ?u64) StreamShape {
        const chunked = length == null and self.minor_version == 1;
        return .{ .chunked = chunked, .ends_connection = !chunked and length == null };
    }

    fn streamHead(
        self: *Http1,
        status: u16,
        content_type: []const u8,
        shape: StreamShape,
        length: ?u64,
        keep: bool,
        extra: []const Header,
    ) !void {
        try http1.writeStreamHead(self.out, status, http1.statusPhrase(status), content_type, shape.chunked, length, self.connection(keep), extra);
    }

    fn piece(self: *Http1, chunked: bool, buffered: []const u8, data: []const []const u8, splat: usize) !void {
        var total = buffered.len;
        for (data[0 .. data.len - 1]) |slice| total += slice.len;
        const pattern = data[data.len - 1];
        total += pattern.len * splat;

        if (chunked) try http1.writeChunkHeader(self.out, total);
        if (buffered.len > 0) try self.out.writeAll(buffered);
        for (data[0 .. data.len - 1]) |slice| try self.out.writeAll(slice);
        for (0..splat) |_| try self.out.writeAll(pattern);
        if (chunked) try http1.endChunk(self.out);
    }

    /// A whole answer chunked to carry its trailers: one chunk of body, then
    /// the trailer section.
    fn wholeChunked(self: *Http1, status: u16, content_type: []const u8, body: []const u8, keep: bool, extra: []const Header, list: []const Header) anyerror!void {
        try http1.writeStreamHead(self.out, status, http1.statusPhrase(status), content_type, true, null, self.connection(keep), extra);
        if (body.len > 0) {
            try http1.writeChunkHeader(self.out, body.len);
            try self.out.writeAll(body);
            try http1.endChunk(self.out);
        }
        try http1.writeLastChunkWith(self.out, list);
        try http1.settle(self.out, self.in);
    }

    fn end(self: *Http1, marked: bool, trailers: Trailers) !void {
        if (marked) {
            if (trailers.writers) |w| if (trailers.list.len > 0) {
                try w.last(self.out, trailers.list);
                return self.out.flush();
            };
            try http1.writeLastChunk(self.out);
        }
        try self.out.flush();
    }

    fn file(
        self: *Http1,
        status: u16,
        content_type: []const u8,
        reader: *std.Io.File.Reader,
        len: u64,
        keep: bool,
        extra: []const Header,
    ) !u64 {
        // Left in the write buffer on purpose: `sendFileAll` sends what is
        // already buffered ahead of the file's first bytes, so the head and
        // the start of the body leave together (ADR 009).
        try http1.writeFileHead(self.out, status, http1.statusPhrase(status), content_type, len, self.connection(keep), extra);

        // A loop rather than one call, because a `std.Io.Limit` is a `usize`
        // and the length of a file is not: on a 32-bit build `limited64`
        // clamps, and without this a four-gigabyte download would look like
        // a truncated file. On a 64-bit build it goes round once.
        // `sendFileAll` is short only at the end of the file, so nothing sent
        // means there is no more file.
        var sent: u64 = 0;
        while (sent < len) {
            const n = try self.out.sendFileAll(reader, .limited64(len - sent));
            if (n == 0) break;
            sent += n;
        }
        try self.out.flush();
        return sent;
    }

    fn interimContinue(self: *Http1) !void {
        // An HTTP/1.0 client cannot be sent an interim response (RFC 9110
        // §15.2).
        if (self.minor_version == 0) return;
        try self.out.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
        try self.out.flush();
    }
};

/// What the connection gives a request that can stream: where its pipe is
/// published, how to tell the connection, how many pipes are open, and how
/// the head of its answer is encoded, which only the connection's file knows.
pub const Streamer = struct {
    link: inbound.Link,
    slot: *?*outbound.Outbox,
    /// Where an event stream handed to the connection is left (`handOver`).
    events: *?EventSource,
    live: *std.atomic.Value(u32),
    /// Bytes of file buffers the connection's calls hold (`Collected.file`).
    file_held: *std.atomic.Value(usize),
    can_park: bool,
    /// The HEADERS block of the answer, encoded into `a` from its status, its
    /// content type, its length and `extra`, the headers the route set, which
    /// are read where they lie and not copied (see `Collected.head_block`).
    head: *const fn (a: std.mem.Allocator, answer: *const Collected, extra: []const Header) anyerror![]const u8,
};

/// An answer kept for the connection's fiber to frame (ADR 220): what a
/// route handed `Ctx`, copied into the request arena because the slices it
/// came in, a handler's buffer and the headers inline in `Ctx`, are gone by
/// the time that fiber reads it. Field names are lowercased on the way in,
/// which HTTP/2 requires of every one (RFC 9113 §8.2.1).
pub const Collected = struct {
    arena: std.mem.Allocator,
    /// Bytes left free in front of `body`, for an envelope's prefix: gRPC's
    /// five, so a message is framed where it lies rather than copied again
    /// (ADR 220). Set by whoever collects, before the call runs.
    front: usize = 0,
    status: u16 = 0,
    content_type: []const u8 = "",
    headers: []const Header = &.{},
    body: []const u8 = "",
    /// How long the body a GET would have carried is, for a framing that says
    /// it in a head: `body.len` for a whole answer, and the length handed over
    /// for a HEAD, whose `body` is empty. Null for a status that has no body.
    length: ?u64 = null,
    /// Whether the route's headers kept as one nameless entry of whole lines
    /// (`nilo.secure`'s block) are read into fields. HTTP/2 answering as HTTP
    /// wants them, since a browser reads them; gRPC does not (ADR 259).
    lines: bool = false,
    /// The allocation `body` sits at the end of, `front` bytes longer, and
    /// empty when no body was handed over.
    room: []u8 = &.{},
    trailers: []const Header = &.{},
    /// The HEADERS block of a whole answer to a request that can stream, which
    /// is HTTP, encoded while the route's headers were still where the route
    /// left them, so that they are read once and not copied (`fields`) and read
    /// again to be encoded. Null where the block is made from `headers`: a
    /// gRPC call's, and the head of a HEAD.
    head_block: ?[]const u8 = null,
    /// The pipe the request's body arrives through, when it has one: how the
    /// framing reaches the connection to ask for a `100 Continue`.
    inbound: ?*inbound.Inbox = null,
    /// The error the answer is a failure for, when it is one (`Framing.failed`).
    failure: ?anyerror = null,
    /// The sentence that failure carried, nilo's own words.
    message: []const u8 = "",
    /// What a streamed answer is written through, when the request can have
    /// one: set by the connection before the call runs, null for a gRPC call.
    streamer: ?Streamer = null,
    /// The pipe a streamed answer is written through, once its head is out.
    outbox: ?*outbound.Outbox = null,

    // `whole` and `head` are `noinline` because the HTTP/1.1 answer pays
    // for them otherwise. Inlined into `Framing.whole`, which every answer
    // passes through, they made a routed GET in a `-Dhttp2` build 465ns
    // against 394ns before; kept apart it is 411ns, and the call 905ns
    // against 938ns (bench/result/http.md).
    noinline fn whole(self: *Collected, status: u16, content_type: []const u8, body: []const u8, head_only: bool, extra: []const Header, trailers: []const Header) !void {
        // The body, the room in front of it and the content type in one
        // allocation, so collecting an answer costs the call one where the
        // HTTP/1.1 text it replaced cost one too (ADR 017's hard axis).
        const kept = if (head_only or http1.bodyless(status)) "" else body;
        self.length = if (http1.bodyless(status)) null else body.len;
        const at = self.front + kept.len;
        const block = try self.arena.alloc(u8, at + content_type.len);
        @memcpy(block[self.front..at], kept);
        @memcpy(block[at..], content_type);
        self.status = status;
        self.content_type = block[at..];
        if (self.streamer) |st| {
            self.head_block = try st.head(self.arena, self, extra);
        } else self.headers = try self.fields(extra);
        self.room = block[0..at];
        self.body = block[self.front..at];
        self.trailers = try self.fields(trailers);
    }

    noinline fn head(self: *Collected, status: u16, content_type: []const u8, len: u64, extra: []const Header) !void {
        self.status = status;
        self.length = len;
        self.content_type = try self.arena.dupe(u8, content_type);
        self.headers = try self.fields(extra);
    }

    /// The head of a streamed answer: kept as a collected one is, encoded on
    /// this fiber into the request arena, and handed to the connection, which
    /// writes it as soon as it looks.
    noinline fn streamHead(self: *Collected, status: u16, content_type: []const u8, shape: StreamShape, length: ?u64, extra: []const Header) !void {
        const st = self.streamer orelse return error.NotCollected;
        self.status = status;
        self.length = length;
        self.content_type = try self.arena.dupe(u8, content_type);
        const block = try st.head(self.arena, self, extra);
        const box = try self.arena.create(outbound.Outbox);
        box.* = .{ .link = st.link, .arena = self.arena, .can_park = st.can_park };
        box.open(block, shape.bodyless);
        self.outbox = box;
        _ = st.live.fetchAdd(1, .acq_rel);
        // Published for the connection's fiber, which looks for it by this
        // pointer and is woken to.
        @atomicStore(?*outbound.Outbox, st.slot, box, .release);
        box.wakeConnection();
    }

    /// The stream's body is the connection's from here: its events are written
    /// from the rooms it sits in, and the call may return without ending it.
    noinline fn handOver(self: *Collected, source: EventSource) !void {
        const st = self.streamer orelse return error.NotCollected;
        const box = self.outbox orelse return error.NotCollected;
        st.events.* = source;
        box.handedOver();
        // Told once more, so a post that arrived while the call was still
        // running is found when the stream is.
        box.wakeConnection();
    }

    /// One piece, lent to the connection and waited for: no copy, and nothing
    /// allocated.
    noinline fn piece(self: *Collected, buffered: []const u8, data: []const []const u8, splat: usize) !void {
        const box = self.outbox orelse return error.NotCollected;
        return box.lend(buffered, data, splat);
    }

    /// The end of a streamed body, with the trailers a route set as a HEADERS
    /// frame after it (ADR 254).
    noinline fn endBody(self: *Collected, trailers: Trailers) !void {
        const box = self.outbox orelse return;
        var block: []const u8 = "";
        if (trailers.list.len > 0) {
            const list = try self.fields(trailers.list);
            const out = try self.arena.alloc(hpack.Field, list.len);
            for (list, out) |from, *to| to.* = .{ .name = from.name, .value = from.value };
            block = try hpack.encodeBlock(self.arena, out);
        }
        return box.finish(block);
    }

    /// How much of a file is read at a time, which is what one lend is: a
    /// connection's turn (`pump_quantum`), because a lend is a hand-over to
    /// the connection's fiber and a frame's worth of file per hand-over left
    /// HTTP/2 at 2.3 GB/s where 64 KiB reaches 3.2 (`bench/result/http.md`,
    /// ADR 260). Not more: 256 KiB, past the client's window, fell to 0.56.
    pub const file_buffer = 64 * 1024;

    /// What the file calls of one connection may hold of buffers between
    /// them, charged when a file starts and given back when it returns. A
    /// call past it is not failed or made to wait: it reads through a
    /// smaller buffer (never under `file_floor`), slower but correct, so a
    /// connection's worth of stalled downloads holds at most this and a
    /// floor a stream (100 streams: 1 MiB and 400 KB), not 6.4 MB.
    pub const file_budget = 1024 * 1024;
    pub const file_floor = 4 * 1024;

    /// The buffer a file of `len` bytes reads through when the connection's
    /// calls already hold `taken` bytes of them: the file's own size if it is
    /// smaller than a buffer, and otherwise what the budget has left, never
    /// under the floor.
    pub fn fileBufferSize(taken: usize, len: u64) usize {
        const wanted: usize = @intCast(@min(len, file_buffer));
        const room = file_budget -| taken;
        return @min(wanted, @max(room, @min(wanted, file_floor)));
    }

    /// The head, then the file read into frames a buffer at a time through
    /// the same pipe: there is no `sendfile` on HTTP/2, because a frame
    /// header goes between the pieces. What is returned is what was sent,
    /// short only when the file was cut under the transfer, and then the
    /// stream is left without its end, which the connection resets.
    noinline fn file(self: *Collected, status: u16, content_type: []const u8, reader: *std.Io.File.Reader, len: u64, extra: []const Header) !u64 {
        try self.streamHead(status, content_type, .{ .chunked = false, .ends_connection = false }, len, extra);
        const box = self.outbox.?;
        const st = self.streamer.?;
        // Charged to the connection before the buffer is made, and given
        // back when the file is done with it.
        const wanted: usize = @intCast(@min(len, file_buffer));
        const taken = st.file_held.fetchAdd(wanted, .acq_rel);
        const size = fileBufferSize(taken, len);
        if (size < wanted) _ = st.file_held.fetchSub(wanted - size, .acq_rel);
        defer _ = st.file_held.fetchSub(size, .acq_rel);
        const buffer = try self.arena.alloc(u8, @max(size, 1));
        var sent: u64 = 0;
        while (sent < len) {
            const want: usize = @intCast(@min(len - sent, buffer.len));
            const n = reader.interface.readSliceShort(buffer[0..want]) catch return error.ReadFailed;
            if (n == 0) break;
            try box.lend(buffer[0..n], &.{}, 0);
            sent += n;
        }
        if (sent == len) try box.finish("");
        return sent;
    }

    /// `list` copied, its names lowercased. The block `nilo.secure` keeps as
    /// one nameless entry of whole lines is HTTP/1.1 text: it is read into
    /// fields when `lines` is set, and left out when it is not, because a
    /// gRPC client reads none of a browser's headers.
    fn fields(self: *Collected, list: []const Header) ![]const Header {
        var kept: usize = 0;
        var bytes: usize = 0;
        for (list) |h| {
            if (h.name.len > 0) {
                kept += 1;
                bytes += h.name.len + h.value.len;
            } else if (self.lines) {
                kept += std.mem.count(u8, h.value, "\r\n");
                // A line's name and trimmed value are no longer than the line.
                bytes += h.value.len;
            }
        }
        if (kept == 0) return &.{};
        // The entries, and every byte of their names and values, in two
        // allocations, where a name and a value each were two a field.
        const out = try self.arena.alloc(Header, kept);
        const store = try self.arena.alloc(u8, bytes);
        var at: usize = 0;
        var i: usize = 0;
        for (list) |from| {
            if (from.name.len == 0) {
                if (!self.lines) continue;
                var rest = from.value;
                while (std.mem.indexOf(u8, rest, "\r\n")) |end| : (rest = rest[end + 2 ..]) {
                    const colon = std.mem.indexOfScalar(u8, rest[0..end], ':') orelse continue;
                    out[i] = .{
                        .name = lowered(store, &at, rest[0..colon]),
                        .value = copied(store, &at, std.mem.trim(u8, rest[colon + 1 .. end], " ")),
                    };
                    i += 1;
                }
                continue;
            }
            out[i] = .{
                .name = lowered(store, &at, from.name),
                .value = copied(store, &at, from.value),
            };
            i += 1;
        }
        return out[0..i];
    }

    /// `name` lowercased into `store` at `at.*`, which moves past it.
    fn lowered(store: []u8, at: *usize, name: []const u8) []const u8 {
        const to = store[at.*..][0..name.len];
        for (name, to) |ch, *out| out.* = std.ascii.toLower(ch);
        at.* += name.len;
        return to;
    }

    fn copied(store: []u8, at: *usize, value: []const u8) []const u8 {
        const to = store[at.*..][0..value.len];
        @memcpy(to, value);
        at.* += value.len;
        return to;
    }
};

// ---- tests ----

const testing = std.testing;

fn wired(out: *std.Io.Writer, in: *std.Io.Reader, minor_version: u1) Framing {
    return .{ .http1 = .{ .in = in, .out = out, .minor_version = minor_version } };
}

test "a whole answer on HTTP/1.1 is the bytes http1 writes, and a closing one says so" {
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var in: std.Io.Reader = .fixed("");
    var framing = wired(&out, &in, 1);
    try framing.whole(200, "text/plain", "hi", false, false, &.{}, .{});
    const written = out.buffered();
    try testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, written, "Connection: close\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, written, "\r\n\r\nhi"));
}

test "a HEAD on HTTP/1.1 carries the length of the body it does not send" {
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var in: std.Io.Reader = .fixed("");
    var framing = wired(&out, &in, 1);
    try framing.whole(200, "text/plain", "hello", true, true, &.{}, .{});
    const written = out.buffered();
    try testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
}

test "a stream on HTTP/1.0 with no length ends with the connection, and one with a length does not" {
    var buf: [8]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var in: std.Io.Reader = .fixed("");
    const old = wired(&out, &in, 0);
    try testing.expectEqual(StreamShape{ .chunked = false, .ends_connection = true }, old.streamShape(null));
    try testing.expectEqual(StreamShape{ .chunked = false, .ends_connection = false }, old.streamShape(10));
    const new = wired(&out, &in, 1);
    try testing.expectEqual(StreamShape{ .chunked = true, .ends_connection = false }, new.streamShape(null));
}

test "a chunked piece is framed by its whole length, the splat included" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var in: std.Io.Reader = .fixed("");
    var framing = wired(&out, &in, 1);
    try framing.piece(true, "ab", &.{ "c", "-" }, 3);
    try framing.end(true, .{});
    try testing.expectEqualStrings("6\r\nabc---\r\n0\r\n\r\n", out.buffered());
}

test "an HTTP/1.0 client is never sent a 100 Continue" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var in: std.Io.Reader = .fixed("");
    var old = wired(&out, &in, 0);
    try old.interimContinue();
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
    var new = wired(&out, &in, 1);
    try new.interimContinue();
    try testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", out.buffered());
}

test "an answer collected for HTTP/2 outlives the buffers it was handed in" {
    if (comptime !http2_built) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var collected: Collected = .{ .arena = arena_state.allocator() };
    var framing: Framing = .{ .http2 = &collected };

    var body = "message".*;
    var name = "X-Tenant".*;
    var value = "0".*;
    collected.front = 5;
    try framing.whole(200, "application/grpc", &body, false, true, &.{.{ .name = &name, .value = &value }}, .{});
    @memset(&body, 'x');
    @memset(&name, 'x');
    @memset(&value, 'x');

    try testing.expectEqual(@as(u16, 200), collected.status);
    try testing.expectEqualStrings("message", collected.body);
    try testing.expectEqualStrings("x-tenant", collected.headers[0].name);
    // The room in front is the collector's to write a prefix into, inside
    // the same allocation as the body.
    try testing.expectEqual(@as(usize, 5 + "message".len), collected.room.len);
    try testing.expectEqualStrings("message", collected.room[5..]);
    try testing.expectEqualStrings("0", collected.headers[0].value);
    try testing.expect(framing.wire() == null);
    try testing.expectError(error.NotCollected, framing.streamHead(200, "text/plain", .{ .chunked = false, .ends_connection = false }, null, true, &.{}));
}

test "a whole answer with trailers is chunked for a client that reads them, and plain for one that did not ask" {
    var buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var in: std.Io.Reader = .fixed("");
    var framing = wired(&out, &in, 1);
    const trailers: []const Header = &.{.{ .name = "Server-Timing", .value = "db;dur=12" }};

    try framing.whole(200, "text/plain", "hi", false, true, &.{}, .{ .list = trailers, .asked = true, .writers = &writers });
    const chunked = out.buffered();
    try testing.expect(std.mem.indexOf(u8, chunked, "Transfer-Encoding: chunked\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, chunked, "Content-Length") == null);
    try testing.expect(std.mem.endsWith(u8, chunked, "\r\n\r\n2\r\nhi\r\n0\r\nServer-Timing: db;dur=12\r\n\r\n"));

    out.end = 0;
    try framing.whole(200, "text/plain", "hi", false, true, &.{}, .{ .list = trailers, .asked = false, .writers = &writers });
    const plain = out.buffered();
    try testing.expect(std.mem.indexOf(u8, plain, "Content-Length: 2\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "Server-Timing") == null);
}

test "an HTTP/1.0 client and a body-less status get no trailer section even when one was asked for" {
    var buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var in: std.Io.Reader = .fixed("");
    const trailers: []const Header = &.{.{ .name = "Server-Timing", .value = "x" }};
    var old = wired(&out, &in, 0);
    try old.whole(200, "text/plain", "hi", false, false, &.{}, .{ .list = trailers, .asked = true, .writers = &writers });
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "Server-Timing") == null);
    out.end = 0;
    var new = wired(&out, &in, 1);
    try new.whole(204, "", "", false, true, &.{}, .{ .list = trailers, .asked = true, .writers = &writers });
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "Server-Timing") == null);
}

test "a chunked stream ends with its trailers, and one framed by a length ends without them" {
    var buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var in: std.Io.Reader = .fixed("");
    var framing = wired(&out, &in, 1);
    const trailers: []const Header = &.{.{ .name = "Digest", .value = "sha-256=abc" }};
    try framing.end(true, .{ .list = trailers, .writers = &writers });
    try testing.expectEqualStrings("0\r\nDigest: sha-256=abc\r\n\r\n", out.buffered());
    out.end = 0;
    try framing.end(false, .{ .list = trailers, .writers = &writers });
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
}

test "a collected failure keeps its error and its sentence past the buffers they came in" {
    if (comptime !http2_built) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var collected: Collected = .{ .arena = arena_state.allocator() };
    var framing: Framing = .{ .http2 = &collected };
    var sentence = "already there".*;
    try framing.failed(error.AlreadyExists, &sentence);
    @memset(&sentence, 'x');
    try testing.expectEqual(@as(?anyerror, error.AlreadyExists), collected.failure);
    try testing.expectEqualStrings("already there", collected.message);
}

test "a file's buffer is its size when it is small, a buffer when the connection has room, and a floor when it has none" {
    if (comptime !http2_built) return error.SkipZigTest;
    const C = Collected;
    try testing.expectEqual(@as(usize, 10), C.fileBufferSize(0, 10));
    try testing.expectEqual(@as(usize, 0), C.fileBufferSize(0, 0));
    try testing.expectEqual(C.file_buffer, C.fileBufferSize(0, 1 << 30));
    try testing.expectEqual(@as(usize, 10 * 1024), C.fileBufferSize(C.file_budget - 10 * 1024, 1 << 30));
    try testing.expectEqual(C.file_floor, C.fileBufferSize(C.file_budget, 1 << 30));
    try testing.expectEqual(C.file_floor, C.fileBufferSize(C.file_budget * 4, 1 << 30));
    // A hundred streams at once hold the budget and a floor each, not a
    // buffer each.
    var held: usize = 0;
    for (0..100) |_| held += C.fileBufferSize(held, 1 << 30);
    try testing.expect(held <= C.file_budget + 100 * C.file_floor);
    try testing.expect(held < 100 * C.file_buffer / 4);
}
