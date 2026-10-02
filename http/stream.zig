//! Responses written in pieces, because their length is not known when the
//! head goes out (ADR 019).
//!
//! ```zig
//! fn report(c: *nilo.Ctx, db: *Db) !void {
//!     var body = try c.stream(200, "text/csv");
//!     for (db.rows()) |row| try body.print("{s},{d}\n", .{ row.name, row.total });
//!     try body.finish();
//! }
//! ```
//!
//! Two rules hold this together, and both come from the ADR:
//!
//! - **Nothing is allocated per piece.** One buffer is taken from the
//!   request arena when the stream opens, and after that a stream running
//!   for a week uses exactly the memory it used at the start.
//! - **A stream is told when the server wants to stop.** `live()` goes false
//!   on a shutdown, and a loop that checks it lets a deploy finish.
//!
//! `finish()` is not optional. It writes the zero-length chunk that says
//! where the body ends; forget it and App writes one for you, logs about it,
//! and anything still sitting in the buffer is lost.

const std = @import("std");

const bulkhead = @import("bulkhead.zig");
const framing_mod = @import("framing.zig");
const Framing = framing_mod.Framing;
const http1 = @import("http1.zig");
const json_mod = @import("json.zig");
const room_mod = @import("room.zig");
const watchdog = @import("watchdog.zig");
const websocket = @import("websocket.zig");

/// How much a stream buffers before a piece goes out on its own.
///
/// Four kilobytes matches the connection's write buffer, so a full stream
/// buffer becomes one write rather than a partial one. Turn it down for a
/// stream whose pieces are small and want to leave immediately — though for
/// that, `Events` already flushes after each one.
pub const Options = struct {
    buffer: usize = 4 * 1024,

    /// How many bytes the body will be, when the handler already knows.
    ///
    /// Null is the ordinary case and is what the whole module is named for: a
    /// length nobody knows yet, framed in chunks. Set it and the head carries
    /// a `Content-Length` instead, which is what a browser needs to draw a
    /// progress bar and what makes a `Range` against the response answerable
    /// ([ADR 101](../docs/adr/101-a-stream-that-knows-its-length-says-so.md)).
    ///
    /// The caller that has this is the one moving bytes out of something that
    /// counted them already — `nilo_s3`'s `bucket.stream` reports `len` before
    /// the first byte arrives, and a proxying handler has the length it was
    /// given upstream.
    ///
    /// **A promise is held to.** Writing past it is refused rather than sent,
    /// at the flush that would have sent the extra bytes rather than at the
    /// call that buffered them —
    /// for the reason a WebSocket frame that lies about its length is refused
    /// ([ADR 076](../docs/adr/076-a-frame-that-lies-about-its-length-is-not-sent.md)):
    /// the bytes past the promise would be read by the client as the start of
    /// the next response. Finishing short cannot be taken back — the head has
    /// gone — so the connection closes rather than leaving a client waiting
    /// for bytes that are not coming.
    length: ?u64 = null,
};

/// What an open stream is, from `Ctx`'s side. Lives on the `Ctx` rather than
/// on the `Stream`, because the `Stream` is on the handler's stack and App
/// has to know what was left open after the handler has returned.
pub const Open = struct {
    /// False for an HTTP/1.0 client, which has no chunked encoding and gets
    /// the pieces unframed with the connection closing at the end — and false
    /// for a stream that promised a `Content-Length`, which needs no framing
    /// because the promise already says where the body stops.
    chunked: bool,
    /// True when answering a HEAD: the handler writes as usual and none of
    /// it goes out, so a handler need not know which verb it is answering.
    drop: bool,
    /// What the head promised, when it promised anything (ADR 101).
    promised: ?u64 = null,
    /// How much of that promise has been written. Counted rather than
    /// inferred, because the buffer means the writer and the wire are never
    /// at the same place.
    written: u64 = 0,
};

/// A response being written in pieces.
///
/// `writer` is an ordinary `std.Io.Writer`, so anything in the standard
/// library that writes to one — `std.json.Stringify.value`, a formatter of
/// your own — writes into the response without an intermediate buffer.
pub const Stream = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Stream";

    /// Write here. Everything that lands in this buffer leaves as one chunk.
    writer: std.Io.Writer,

    /// Where the pieces go. How each is framed, and how the body ends, is
    /// the framing's (ADR 253).
    _framing: *Framing,
    /// The server's "please stop" flag, or null when nothing can stop —
    /// App driven straight from a test.
    _stopping: ?*const std.atomic.Value(bool),
    /// The `Ctx`'s record of this stream, set to null by `finish`.
    _open: *?Open,
    /// The `Ctx`'s "this connection cannot carry another request" flag, or
    /// null when nothing owns one — a test driving a Stream against a buffer.
    /// Set when a promised length is not met, which is the one failure here
    /// that cannot be taken back (ADR 101).
    _force_close: ?*bool = null,
    /// The request's blocking detector, or null when there is no request
    /// behind this — a Stream a test built against a buffer. A stretch of
    /// handler time ends at every write, which is what lets a stream be
    /// watched rather than excused (ADR 013).
    _watch: ?*watchdog.Watch = null,

    /// Write `bytes` into the stream. Nothing leaves until the buffer fills
    /// or something flushes.
    pub fn writeAll(self: *Stream, bytes: []const u8) !void {
        return self.writer.writeAll(bytes);
    }

    /// `body.print("{s},{d}\n", .{ name, total })` — formatted straight into
    /// the stream, with no buffer of your own in between.
    pub fn print(self: *Stream, comptime fmt: []const u8, args: anytype) !void {
        return self.writer.print(fmt, args);
    }

    /// Serialise `value` as JSON into the stream. Nothing is allocated: the
    /// serialiser writes into the same buffer everything else does.
    pub fn json(self: *Stream, value: anytype) !void {
        return json_mod.write(&self.writer, value);
    }

    /// Push whatever has been written so far out to the client.
    ///
    /// A stream that never flushes still arrives — the buffer flushes itself
    /// when it fills, and `finish` flushes what is left. This is for a
    /// stream whose pieces matter individually and should not wait for the
    /// one after them.
    pub fn flush(self: *Stream) !void {
        try self.writer.flush();
        try self._framing.flush();
    }

    /// Whether it is still worth carrying on: false once the server has been
    /// asked to stop.
    ///
    /// A long-running loop should check this. `listen()` waits for requests
    /// in flight, and a stream that ignores this holds the shutdown open for
    /// as long as it runs (ADR 019).
    ///
    /// The other way a stream ends needs no check at all: when the client
    /// goes away, the next write fails and the error unwinds the handler.
    pub fn live(self: *const Stream) bool {
        const stopping = self._stopping orelse return true;
        return !stopping.load(.acquire);
    }

    /// End the body. Required, and safe to call twice.
    pub fn finish(self: *Stream) !void {
        if (self._open.* == null) return;
        // Flushed before the record is cleared, not after: `drain` reads it
        // to know how to frame what it is writing, and a null one means the
        // body has already ended. Re-read afterwards, because the flush is
        // what moves `written`.
        try self.writer.flush();
        const open = self._open.*.?;
        self._open.* = null;

        // A promise that was not met. The head has gone out saying how many
        // bytes are coming, so there is no correcting it: what is left is to
        // stop the client waiting for the rest, and to stop the next response
        // on this connection being read as the tail of this one. A HEAD is not
        // this case — nothing was going to be written (ADR 101).
        if (open.promised) |promised| {
            if (!open.drop and open.written < promised) {
                // A warning rather than an error, because in this project
                // `std.log.err` means the server is refusing to start — every
                // other one is a `listen()` that returns rather than binds.
                // A handler that mis-counted its own body is one request going
                // wrong, which is what `warn` is for here and in `App`.
                std.log.warn(
                    "nilo: a stream promised {d} bytes and wrote {d} — the response is short, " ++
                        "so the connection is being closed rather than left half-answered",
                    .{ promised, open.written },
                );
                if (self._force_close) |flag| flag.* = true;
            }
        }

        try self._framing.end(open.chunked and !open.drop);

        // Take the buffer away, so that anything written from here on has
        // nowhere to sit and goes straight to `drain` — which is where the
        // "you wrote to a finished stream" warning lives. Without this a
        // short write after `finish` would be swallowed by the buffer and
        // never reach it, which is the quietest possible way to lose data.
        self.writer.buffer = &.{};
        self.writer.end = 0;
    }

    /// Everything buffered leaves as one chunk. Called by the writer when
    /// the buffer fills, and by `flush`/`finish`.
    ///
    /// The shape is the one `std.Io.Writer.Hashing` uses: consume
    /// `w.buffer[0..w.end]` first, then each slice of `data`, with the last
    /// one repeated `splat` times.
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Stream = @alignCast(@fieldParentPtr("writer", w));

        // Putting a piece on the wire is nilo waiting on the client, not the
        // handler running — and saying so is what lets a stream be watched at
        // all rather than excused (ADR 013). A client too slow to take what
        // is being sent parks this fiber for as long as it takes.
        const token = watchdog.waiting(self._watch);
        defer watchdog.waited(self._watch, token);

        const buffered = w.buffered();
        const pattern = data[data.len - 1];
        var from_data: usize = 0;
        for (data[0 .. data.len - 1]) |slice| from_data += slice.len;
        from_data += pattern.len * splat;

        const total = buffered.len + from_data;

        // A null record means `finish` has already run, so these bytes have
        // nowhere to go: the body ended and the terminator is written. They
        // are dropped either way — there is no correct way to reopen a
        // finished body — but silently dropping what a handler wrote is how
        // somebody spends an afternoon looking for the missing half of a
        // report, so it says so once.
        const open = self._open.* orelse {
            if (total > 0) std.log.warn(
                "nilo: {d} bytes were written to a stream after finish() — " ++
                    "the body had already ended, so they were dropped",
                .{total},
            );
            w.end = 0;
            return from_data;
        };

        // Nothing to say. A zero-length chunk is the one that ends a body, so
        // writing one here would end the response early. `drop` is a HEAD:
        // the handler writes as usual and none of it goes out.
        if (total == 0 or open.drop) {
            w.end = 0;
            return from_data;
        }

        // Past what the head promised. These bytes cannot go out: a client
        // reading a `Content-Length` stops there, so everything after it is
        // read as the beginning of the next response — which is a
        // response-splitting bug rather than a lost tail. Refused for the
        // reason a WebSocket frame that lies about its length is refused
        // (ADR 076, ADR 101), and loudly, because a silent one would leave
        // somebody looking for the missing end of a file. Loudly means
        // `warn`: `err` is reserved for a server that will not start.
        if (open.promised) |promised| {
            if (open.written + total > promised) {
                std.log.warn(
                    "nilo: a stream promised {d} bytes and tried to write {d} — refused, " ++
                        "because the bytes past the promise would be read as the next response",
                    .{ promised, open.written + total },
                );
                return error.WriteFailed;
            }
            self._open.*.?.written = open.written + total;
        }

        self._framing.piece(open.chunked, buffered, data, splat) catch return error.WriteFailed;

        w.end = 0;
        return from_data;
    }

    /// nilo's own: `Ctx.stream` builds one of these once the head is out.
    pub fn init(
        buffer: []u8,
        framing: *Framing,
        stopping: ?*const std.atomic.Value(bool),
        open: *?Open,
    ) Stream {
        return .{
            .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain } },
            ._framing = framing,
            ._stopping = stopping,
            ._open = open,
        };
    }

    /// The same, for a caller that owns the connection's "close after this"
    /// flag — which is `Ctx` and nobody else.
    pub fn initClosing(
        buffer: []u8,
        framing: *Framing,
        stopping: ?*const std.atomic.Value(bool),
        open: *?Open,
        force_close: *bool,
    ) Stream {
        var self = init(buffer, framing, stopping, open);
        self._force_close = force_close;
        return self;
    }
};

// ---- server-sent events ----
//
// One long response, `text/event-stream`, carrying messages a browser reads
// with `new EventSource(url)`. The framing is line-based and unforgiving in
// one specific way: a `data:` value containing a newline is two lines on the
// wire, so it has to be split rather than sent as it came.

/// One message on an event stream.
pub const Event = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Event";

    /// The `event:` name a listener can subscribe to by itself. Empty is the
    /// default, which a browser delivers as `message`. One line: a CR or LF
    /// in it is `error.EventFieldBreaksLine`, and nothing is written.
    name: []const u8 = "",
    /// The `id:`, which the browser sends back as `Last-Event-ID` when it
    /// reconnects. Empty leaves it off. One line, as `name`.
    id: []const u8 = "",
    data: []const u8,
};

/// A stream of server-sent events.
///
/// ```zig
/// fn tokens(c: *nilo.Ctx, llm: *Llm) !void {
///     var events = try c.events();
///     while (events.live()) {
///         const token = llm.next() orelse break;
///         try events.send(.{ .name = "token", .data = token });
///     }
///     try events.close();
/// }
/// ```
///
/// Every send flushes, because an event that sits in a buffer waiting for
/// the next one is an event that arrived late for no reason.
pub const Events = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Events";

    stream: Stream,

    pub const content_type = "text/event-stream";

    /// Send one event.
    pub fn send(self: *Events, event: Event) !void {
        try oneLine(event.name);
        try oneLine(event.id);
        try writeEvent(&self.stream.writer, event);
        try self.stream.flush();
    }

    /// `data: …` and nothing else — the shorthand for a stream of one kind
    /// of thing.
    pub fn data(self: *Events, text: []const u8) !void {
        return self.send(.{ .data = text });
    }

    /// An event whose data is `value` as JSON, serialised straight into the
    /// response. JSON escapes its own newlines, so this is always one line.
    pub fn json(self: *Events, name: []const u8, value: anytype) !void {
        try oneLine(name);
        const w = &self.stream.writer;
        if (name.len > 0) try w.print("event: {s}\n", .{name});
        try w.writeAll("data: ");
        try json_mod.write(w, value);
        try w.writeAll("\n\n");
        try self.stream.flush();
    }

    /// A line the client ignores. What it is for is proxies and load
    /// balancers, which close a connection that has said nothing for a
    /// while; a comment every thirty seconds is the usual answer.
    ///
    /// Text that runs over lines is one comment line per line, for
    /// `writeData`'s reason: a line that does not start with `:` is a field.
    pub fn comment(self: *Events, text: []const u8) !void {
        const w = &self.stream.writer;
        var lines: Lines = .{ .text = text };
        while (lines.next()) |line| try w.print(": {s}\n", .{line});
        try w.writeAll("\n");
        try self.stream.flush();
    }

    /// How long the browser should wait before reconnecting, in
    /// milliseconds. Sent once, usually first.
    pub fn retry(self: *Events, millis: u32) !void {
        try self.stream.print("retry: {d}\n\n", .{millis});
        try self.stream.flush();
    }

    /// Whether the server still wants this stream running. See `Stream.live`.
    pub fn live(self: *const Events) bool {
        return self.stream.live();
    }

    pub fn close(self: *Events) !void {
        return self.stream.finish();
    }
};

/// What `c.eventsFrom` takes besides the rooms.
pub const FromRooms = struct {
    /// A comment this often while nothing is said, so that a proxy or a load
    /// balancer that closes a quiet connection sees this one speak. `0` sends
    /// none. Thirty seconds is under nginx's default read timeout of sixty,
    /// and the same stretch a WebSocket waits before it pings (ADR 021).
    keepalive_ms: u32 = 30_000,
    /// `retry:`, sent once before anything else: how long the browser waits
    /// before reconnecting. Null sends none and leaves the browser's own,
    /// about three seconds.
    retry_ms: ?u32 = null,
};

/// An event stream whose every event comes from Rooms, handed to its
/// connection rather than held by its handler (ADR 227).
///
/// ```zig
/// fn feed(c: *nilo.Ctx, lobby: *nilo.Room) !void {
///     return c.eventsFrom(lobby, .{});
/// }
/// ```
///
/// **Where a stream waits is what it costs.** `c.events()` keeps the handler
/// suspended inside the request for as long as the stream is open, and a
/// suspended fiber holds its stack at its high-water mark: 21,058 bytes a
/// held stream against 4,669 for an idle connection (ADR 019, ADR 062). A
/// stream with nothing of its own to say has no reason to keep the handler,
/// so the handler writes the head, sits the stream in its rooms and returns,
/// and the connection loop waits on it from its own frame, the way it waits
/// on a Socket.
///
/// **A client that speaks has gone.** After its request an `EventSource`
/// sends nothing, so anything that makes the socket readable is either a
/// hang-up or bytes that can never be answered, because this response never
/// ends. Either way the stream ends. It is the one place nilo learns a client
/// left without writing to it, and the reason it can be learned here is the
/// same reason it cannot on an ordinary request: an ordinary response ends,
/// and a client that half-closed may be waiting for it (`docs/todo.md`).
pub const RoomEvents = struct {
    _in: *std.Io.Reader,
    _out: *std.Io.Writer,
    _stopping: ?*const std.atomic.Value(bool),
    _waker: bulkhead.Waker,
    /// The request's blocking detector, or null for one a test built. A
    /// stretch ends at every wait, so what lies between two is one burst of
    /// events written (ADR 013).
    _watch: ?*watchdog.Watch = null,
    _keepalive_ms: u32,
    /// False for an HTTP/1.0 client, which gets the events unframed and the
    /// connection closed at the end, as `Stream` does.
    _chunked: bool,
    /// The rooms this stream sits in: the first, and through its seat the
    /// rest (`room.Seating`).
    _seated: room_mod.Seating = .{},

    /// How long the connection waits before it gives its buffers and stack
    /// pages back: the peek a Socket and an idle HTTP connection take for the
    /// same reason (ADR 062).
    const idle_peek_ms = 200;

    pub fn seating(self: *RoomEvents) *room_mod.Seating {
        return &self._seated;
    }

    /// Give up every seat. What the end of `run` does, because each seat's
    /// bell lives in a frame about to go (ADR 082).
    pub fn leaveRooms(self: *RoomEvents) void {
        while (self._seated.room) |in_room| in_room.stand(&self._seated);
    }

    /// Wait on the rooms until the client goes, the server stops or a write
    /// fails, writing each post as it arrives. The connection loop's; a
    /// handler never calls it.
    pub fn run(self: *RoomEvents) void {
        defer self.leaveRooms();
        while (true) {
            self.deliver() catch return;
            // What is queued has gone out above. A server on its way out
            // ends the stream itself rather than leaving the client to find
            // the socket gone (ADR 019).
            if (self.stopping()) break;
            switch (self.park()) {
                .posted => {},
                .timed_out => self.keepAlive() catch return,
                .readable, .closed => break,
            }
        }
        self.finish();
    }

    /// Write out everything waiting in every seat, as events. Flushed by
    /// `park`, so a burst is one syscall.
    fn deliver(self: *RoomEvents) !void {
        var at = self._seated;
        while (at.room) |in_room| {
            while (in_room.take(at.ticket)) |post| {
                defer in_room.release(post);
                try self.writeFramed(in_room.eventOf(post));
            }
            at = in_room.after(at.ticket);
        }
    }

    /// One event as one chunk. Its length is counted first, with the same
    /// function that writes it, so the chunk header cannot disagree with the
    /// bytes behind it (ADR 076).
    fn writeFramed(self: *RoomEvents, event: Event) !void {
        if (self._chunked) try http1.writeChunkHeader(self._out, @intCast(websocket.counted(writeEvent, event)));
        try writeEvent(self._out, event);
        if (self._chunked) try http1.endChunk(self._out);
    }

    /// `retry:`, once, before any event. `eventsFrom`'s, from the handler's
    /// frame, while the head it follows is still in the write buffer.
    pub fn sendRetry(self: *RoomEvents, millis: u32) !void {
        var line: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "retry: {d}\n\n", .{millis}) catch unreachable;
        if (self._chunked) try http1.writeChunkHeader(self._out, text.len);
        try self._out.writeAll(text);
        if (self._chunked) try http1.endChunk(self._out);
    }

    /// What a room kept for a client coming back, written before anything
    /// new and released as it goes (ADR 229). `eventsFrom`'s, from the
    /// handler's frame. Every post is released whether or not the writing
    /// got that far.
    pub fn replay(self: *RoomEvents, in_room: *room_mod.Room, posts: []*room_mod.Post) !void {
        var at: usize = 0;
        defer for (posts[at..]) |post| in_room.release(post);
        while (at < posts.len) : (at += 1) {
            try self.writeFramed(in_room.eventOf(posts[at]));
            in_room.release(posts[at]);
        }
    }

    /// A comment with nothing in it: the smallest thing a proxy counts as
    /// the connection speaking.
    fn keepAlive(self: *RoomEvents) !void {
        if (self._chunked) try http1.writeChunkHeader(self._out, 3);
        try self._out.writeAll(":\n\n");
        if (self._chunked) try http1.endChunk(self._out);
    }

    /// The end of the body, for a client still there to read it. A client
    /// that has gone makes this fail, which is nothing to report.
    fn finish(self: *RoomEvents) void {
        if (self._chunked) http1.writeLastChunk(self._out) catch return;
        self._out.flush() catch {};
    }

    fn stopping(self: *const RoomEvents) bool {
        const flag = self._stopping orelse return false;
        return flag.load(.acquire);
    }

    /// Flush, then wait for a post, the client, or the keep-alive's stretch.
    /// Past a short peek the buffers and the stack pages below this frame go
    /// back, as they do for a quiet Socket: a feed with ten thousand readers
    /// is ten thousand connections that are almost always quiet.
    fn park(self: *RoomEvents) bulkhead.Woken {
        if (self._out.end != 0) self._out.flush() catch return .closed;

        const token = watchdog.waiting(self._watch);
        defer watchdog.waited(self._watch, token);

        const limit = self._keepalive_ms;
        if (limit != 0 and limit <= idle_peek_ms) return self._waker.wait(limit);
        switch (self._waker.wait(idle_peek_ms)) {
            .timed_out => {},
            else => |woken| return woken,
        }
        bulkhead.releaseIdlePages(self._in, self._out);
        self._waker.releaseStack();
        return self._waker.wait(if (limit == 0) 0 else limit - idle_peek_ms);
    }
};

/// One event's lines: `event:` and `id:` when it has them, `data:` for each
/// line of the data, and the blank line that ends it. The caller has checked
/// `name` and `id` for line breaks.
fn writeEvent(w: *std.Io.Writer, event: Event) !void {
    if (event.name.len > 0) try w.print("event: {s}\n", .{event.name});
    if (event.id.len > 0) try w.print("id: {s}\n", .{event.id});
    try writeData(w, event.data);
    try w.writeAll("\n");
}

/// `data:` for every line of `text`, because a newline inside a value is a
/// line break on the wire and would end the event early.
fn writeData(w: *std.Io.Writer, text: []const u8) !void {
    if (text.len == 0) return w.writeAll("data:\n");
    var lines: Lines = .{ .text = text };
    while (lines.next()) |line| try w.print("data: {s}\n", .{line});
}

/// The lines of `text` as an event stream's reader finds them. The grammar
/// ends a line at CRLF, at LF **and at a lone CR**, so splitting on LF alone
/// leaves `a\rdata: forged\revent: admin` as one line here and three at the
/// browser, the last of them naming an event nobody sent.
const Lines = struct {
    text: []const u8,
    at: usize = 0,
    done: bool = false,

    fn next(self: *Lines) ?[]const u8 {
        if (self.done) return null;
        const start = self.at;
        while (self.at < self.text.len) : (self.at += 1) {
            const ch = self.text[self.at];
            if (ch != '\n' and ch != '\r') continue;
            const line = self.text[start..self.at];
            self.at += 1;
            if (ch == '\r' and self.at < self.text.len and self.text[self.at] == '\n') self.at += 1;
            return line;
        }
        self.done = true;
        return self.text[start..];
    }
};

/// A field that is one line by definition, `event:` and `id:`, has nothing
/// to split into: a line break in it is refused before a byte is written.
fn oneLine(field: []const u8) error{EventFieldBreaksLine}!void {
    if (std.mem.indexOfAny(u8, field, "\r\n") != null) return error.EventFieldBreaksLine;
}

// ---- tests ----
//
// These drive a Stream against an in-memory writer, so what is asserted is
// the bytes on the wire. The behaviour as seen from a handler is tested in
// app.zig, where there is a request to hang it on.

const testing = std.testing;

const Wire = struct {
    buf: [4096]u8 = undefined,
    out: std.Io.Writer = undefined,
    in: std.Io.Reader = .fixed(""),
    framing: Framing = undefined,
    stream_buf: [64]u8 = undefined,
    open: ?Open = null,

    fn init(self: *Wire) void {
        self.out = .fixed(&self.buf);
        self.framing = .{ .http1 = .{ .in = &self.in, .out = &self.out, .minor_version = 1 } };
    }

    fn stream(self: *Wire, chunked: bool, drop: bool) Stream {
        self.open = .{ .chunked = chunked, .drop = drop };
        return .init(&self.stream_buf, &self.framing, null, &self.open);
    }

    /// A stream whose head promised `length` bytes: no chunk framing, and a
    /// close flag for the one failure that cannot be taken back.
    fn promising(self: *Wire, length: u64, closing: *bool) Stream {
        self.open = .{ .chunked = false, .drop = false, .promised = length };
        return .initClosing(&self.stream_buf, &self.framing, null, &self.open, closing);
    }

    fn written(self: *const Wire) []const u8 {
        return self.out.buffered();
    }
};

test "a chunked body frames each piece and ends with a zero" {
    var wire: Wire = .{};
    wire.init();
    var body = wire.stream(true, false);

    try body.writeAll("hello");
    try body.flush();
    try body.writeAll("world");
    try body.finish();

    try testing.expectEqualStrings("5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n", wire.written());
}

test "writing after finish adds nothing to a body that already ended" {
    var wire: Wire = .{};
    wire.init();
    var body = wire.stream(true, false);

    try body.writeAll("all of it");
    try body.finish();

    // The warning `drain` is about to emit is the behaviour under test, so it
    // is not news — but a `std.log.warn` from a test reaches stderr, and the
    // build runner answers stderr from a test process by printing a red
    // `failed command` block beside a suite that passed. This is the only
    // switch that turns it off: a test build's root module is the compiler's
    // own `test_runner.zig`, which sets `std_options` itself, so a tested
    // file's copy of it is never consulted (see `test_root.zig`).
    //
    // Scoped to this test rather than set once for the suite, because the
    // warning is worth having: a test that trips it by accident should still
    // say so out loud.
    const noisy = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = noisy;

    // Short enough to have fitted in the buffer, which is exactly the case
    // that used to disappear without reaching `drain`. The terminator has
    // already gone out and there is no reopening a finished body, so these
    // bytes are dropped — but loudly, and without corrupting what a client
    // has already been told is the whole response.
    try body.writeAll("and a bit more");
    try body.flush();
    try body.finish(); // still safe to call twice

    try testing.expectEqualStrings("9\r\nall of it\r\n0\r\n\r\n", wire.written());
}

test "an empty flush writes nothing, because a zero-length chunk ends the body" {
    var wire: Wire = .{};
    wire.init();
    var body = wire.stream(true, false);

    try body.flush();
    try body.flush();
    try body.writeAll("x");
    try body.finish();

    try testing.expectEqualStrings("1\r\nx\r\n0\r\n\r\n", wire.written());
}

test "finish is safe to call twice" {
    var wire: Wire = .{};
    wire.init();
    var body = wire.stream(true, false);
    try body.writeAll("x");
    try body.finish();
    try body.finish();
    try testing.expectEqualStrings("1\r\nx\r\n0\r\n\r\n", wire.written());
}

test "an HTTP/1.0 stream is unframed and has no terminator" {
    var wire: Wire = .{};
    wire.init();
    var body = wire.stream(false, false);

    try body.writeAll("hello ");
    try body.writeAll("world");
    try body.finish();

    try testing.expectEqualStrings("hello world", wire.written());
}

test "a HEAD stream writes no body at all" {
    var wire: Wire = .{};
    wire.init();
    var body = wire.stream(true, true);

    try body.print("{s} {d}\n", .{ "ignored", 42 });
    try body.finish();

    try testing.expectEqualStrings("", wire.written());
}

test "a piece too big for the buffer still goes out whole" {
    var wire: Wire = .{};
    wire.init();
    var body = wire.stream(true, false);

    // 100 bytes through a 64-byte buffer: the writer drains rather than
    // truncating, and the pieces reassemble into what was written.
    const long = "0123456789" ** 10;
    try body.writeAll(long);
    try body.finish();

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);
    var rest = wire.written();
    while (true) {
        const nl = std.mem.indexOf(u8, rest, "\r\n").?;
        const size = try std.fmt.parseInt(usize, rest[0..nl], 16);
        if (size == 0) break;
        try seen.appendSlice(testing.allocator, rest[nl + 2 ..][0..size]);
        rest = rest[nl + 2 + size + 2 ..];
    }
    try testing.expectEqualStrings(long, seen.items);
}

test "json goes into the stream with nothing in between" {
    var wire: Wire = .{};
    wire.init();
    var body = wire.stream(false, false);

    try body.json(.{ .id = 7, .name = "wati" });
    try body.finish();

    try testing.expectEqualStrings("{\"id\":7,\"name\":\"wati\"}", wire.written());
}

test "an event carries its name, id and data" {
    var wire: Wire = .{};
    wire.init();
    var events = Events{ .stream = wire.stream(false, false) };

    try events.send(.{ .name = "token", .id = "7", .data = "hi" });
    try events.close();

    try testing.expectEqualStrings("event: token\nid: 7\ndata: hi\n\n", wire.written());
}

test "a data value spanning lines becomes one data field per line" {
    var wire: Wire = .{};
    wire.init();
    var events = Events{ .stream = wire.stream(false, false) };

    // Sent as-is this would end the event after "one" and leave "two" as a
    // field name nobody recognises.
    try events.data("one\ntwo\r\nthree");
    try events.close();

    try testing.expectEqualStrings("data: one\ndata: two\ndata: three\n\n", wire.written());
}

test "a lone CR ends a data line as the browser reads it, so it cannot forge an event" {
    var wire: Wire = .{};
    wire.init();
    var events = Events{ .stream = wire.stream(false, false) };

    // Split on LF alone this went out as one `data:` line, and the browser
    // read a second event named `admin`.
    try events.data("a\r\rdata: forged\revent: admin");
    try events.comment("one\rtwo");
    try events.close();

    try testing.expectEqualStrings(
        "data: a\ndata: \ndata: data: forged\ndata: event: admin\n\n" ++
            ": one\n: two\n\n",
        wire.written(),
    );
}

test "a name or id with a line break in it is refused before anything is written" {
    var wire: Wire = .{};
    wire.init();
    var events = Events{ .stream = wire.stream(false, false) };

    try testing.expectError(error.EventFieldBreaksLine, events.send(.{ .name = "a\nevent: admin", .data = "x" }));
    try testing.expectError(error.EventFieldBreaksLine, events.send(.{ .id = "7\rdata: forged", .data = "x" }));
    try testing.expectError(error.EventFieldBreaksLine, events.json("a\r\nb", .{}));
    try events.close();

    try testing.expectEqualStrings("", wire.written());
}

test "an empty data value is still a well-formed event" {
    var wire: Wire = .{};
    wire.init();
    var events = Events{ .stream = wire.stream(false, false) };
    try events.data("");
    try events.close();
    try testing.expectEqualStrings("data:\n\n", wire.written());
}

test "an event's json data is one line, and comments and retry go out as themselves" {
    var wire: Wire = .{};
    wire.init();
    var events = Events{ .stream = wire.stream(false, false) };

    try events.retry(3000);
    try events.json("chunk", .{ .text = "a\nb" });
    try events.comment("keeping the proxy awake");
    try events.close();

    try testing.expectEqualStrings(
        "retry: 3000\n\n" ++
            "event: chunk\ndata: {\"text\":\"a\\nb\"}\n\n" ++
            ": keeping the proxy awake\n\n",
        wire.written(),
    );
}

test "a stream that promised a length writes its bytes unframed" {
    var wire: Wire = .{};
    wire.init();
    var closing = false;
    var body = wire.promising(11, &closing);

    try body.writeAll("hello ");
    try body.flush();
    try body.writeAll("world");
    try body.finish();

    // No chunk headers and no terminator: the `Content-Length` in the head is
    // what says where this stops (ADR 101).
    try testing.expectEqualStrings("hello world", wire.written());
    try testing.expect(!closing);
}

test "a stream refuses to write past the length it promised" {
    var wire: Wire = .{};
    wire.init();
    var closing = false;
    var body = wire.promising(5, &closing);

    try body.writeAll("hello");
    try body.flush();

    // Provoked on purpose, and a logged line is a failed test whatever the
    // level (see `test_root.zig`), so it is turned down around the call.
    const noisy = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = noisy;

    // One byte more than the head promised. A client reading a
    // `Content-Length` stops at five, so this byte would be read as the first
    // byte of the next response — which is the failure ADR 076 refuses one
    // layer down, and this refuses here.
    //
    // **The refusal arrives at the write that would have sent it**, not at the
    // call that buffered it: the counting is in `drain`, which is where every
    // byte actually passes. A `finish()` always flushes, so a handler cannot
    // reach the end of its response without being told.
    try body.writeAll("!");
    try testing.expectError(error.WriteFailed, body.flush());

    try testing.expectEqualStrings("hello", wire.written());
}

test "a stream that promised more than it wrote closes the connection" {
    var wire: Wire = .{};
    wire.init();
    var closing = false;
    var body = wire.promising(10, &closing);

    // Provoked on purpose, and a logged line is a failed test whatever the
    // level (see `test_root.zig`), so it is turned down around the call.
    const noisy = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = noisy;

    try body.writeAll("short");
    try body.finish();

    // The head has gone out promising ten. There is no correcting that, so
    // what is left is to stop the client waiting for five bytes that are not
    // coming — and to stop the next response being read as those five bytes.
    try testing.expect(closing);
    try testing.expectEqualStrings("short", wire.written());
}

test "a HEAD that promised a length writes nothing and closes nothing" {
    var wire: Wire = .{};
    wire.init();
    var closing = false;
    wire.open = .{ .chunked = false, .drop = true, .promised = 100 };
    var body: Stream = .initClosing(&wire.stream_buf, &wire.framing, null, &wire.open, &closing);

    // The head said a hundred bytes, because that is what a GET would have
    // said. Nothing follows it, and nothing about that is short.
    try body.print("{s}", .{"ignored"});
    try body.finish();

    try testing.expectEqualStrings("", wire.written());
    try testing.expect(!closing);
}

test "live follows the server's stopping flag" {
    var wire: Wire = .{};
    wire.init();
    var stopping = std.atomic.Value(bool).init(false);

    wire.open = .{ .chunked = true, .drop = false };
    var body: Stream = .init(&wire.stream_buf, &wire.framing, &stopping, &wire.open);
    try testing.expect(body.live());
    stopping.store(true, .release);
    try testing.expect(!body.live());

    // Still writable: a stop asks a stream to wind up, it does not cut it off.
    try body.writeAll("last");
    try body.finish();
    try testing.expectEqualStrings("4\r\nlast\r\n0\r\n\r\n", wire.written());
}

// ---- an event stream handed to its connection ----

/// A connection's bell for a test: it answers the waits it is given, in
/// order, and then says the client has gone. `park` spends a keep-alive
/// stretch as a short peek and then the rest, so the script is of what each
/// wait answers rather than of how long anything took.
const Script = struct {
    answers: []const bulkhead.Woken,
    at: usize = 0,
    /// The limits the waits were given, so a test can check the keep-alive
    /// travelled.
    limits: [8]u32 = @splat(0),

    fn waker(self: *Script) bulkhead.Waker {
        return .{ .vtable = &vtable, .target = self };
    }

    const vtable: bulkhead.Waker.VTable = .{
        .wait = struct {
            fn f(target: ?*anyopaque, limit_ms: u32) bulkhead.Woken {
                const s: *Script = @ptrCast(@alignCast(target.?));
                if (s.at < s.limits.len) s.limits[s.at] = limit_ms;
                defer s.at += 1;
                return if (s.at < s.answers.len) s.answers[s.at] else .readable;
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

fn roomEvents(in: *std.Io.Reader, out: *std.Io.Writer, waker: bulkhead.Waker, chunked: bool) RoomEvents {
    return .{
        ._in = in,
        ._out = out,
        ._stopping = null,
        ._waker = waker,
        ._keepalive_ms = 30_000,
        ._chunked = chunked,
    };
}

test "an event stream in a room writes each post as one chunk, and ends when the client goes" {
    var room = try room_mod.Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 4 });
    defer room.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var events = roomEvents(&in, &out, .off, true);
    try room.sit(events.seating(), .off, true);
    try testing.expectEqual(@as(usize, 1), room.count());

    try room.sayText("one line\nand a forged\revent: admin");
    try room.event(.{ .name = "tick", .id = "7", .data = "{}" });

    // `.off` answers every wait with "go and read", which is a client that
    // has spoken, so the stream writes what is queued and ends.
    events.run();

    try testing.expectEqualStrings(
        "36\r\ndata: one line\ndata: and a forged\ndata: event: admin\n\n\r\n" ++
            "1c\r\nevent: tick\nid: 7\ndata: {}\n\n\r\n" ++
            "0\r\n\r\n",
        out.buffered(),
    );
    // Every seat is given up on the way out, because each one's bell lives
    // in a frame that is about to go (ADR 082).
    try testing.expectEqual(@as(usize, 0), room.count());
}

test "a quiet event stream sends a comment every keep-alive, and a post wakes it" {
    var room = try room_mod.Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 4 });
    defer room.deinit();

    // Peek, then the rest of the stretch: a keep-alive. Then a post.
    var script: Script = .{ .answers = &.{ .timed_out, .timed_out, .posted } };
    var in = std.Io.Reader.fixed("");
    var bytes: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var events = roomEvents(&in, &out, script.waker(), true);
    try room.sit(events.seating(), .off, true);

    try room.sayText("first");
    events.run();

    try testing.expectEqualStrings(
        "d\r\ndata: first\n\n\r\n" ++ "3\r\n:\n\n\r\n" ++ "0\r\n\r\n",
        out.buffered(),
    );
    // The whole keep-alive travelled: a short peek, then what is left of it.
    try testing.expectEqual(@as(u32, RoomEvents.idle_peek_ms), script.limits[0]);
    try testing.expectEqual(@as(u32, 30_000 - RoomEvents.idle_peek_ms), script.limits[1]);
}

test "an event stream in two rooms hears both, and a binary post is counted rather than sent" {
    var lobby = try room_mod.Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 4 });
    defer lobby.deinit();
    var mine = try room_mod.Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 4 });
    defer mine.deinit();

    var in = std.Io.Reader.fixed("");
    var bytes: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    // HTTP/1.0: no chunks, and the end of the stream is the end of the
    // connection.
    var events = roomEvents(&in, &out, .off, false);
    try lobby.sit(events.seating(), .off, true);
    try mine.sit(events.seating(), .off, true);

    try lobby.sayBinary("\x00\x01");
    try lobby.sayText("all");
    try mine.sayText("you");
    try testing.expectEqual(@as(u64, 1), lobby.seats[lobby.roll[0]].dropped.load(.monotonic));

    events.run();
    const got = out.buffered();
    try testing.expectEqual(@as(usize, 22), got.len);
    try testing.expect(std.mem.indexOf(u8, got, "data: all\n\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "data: you\n\n") != null);
    try testing.expectEqual(@as(usize, 0), lobby.count());
    try testing.expectEqual(@as(usize, 0), mine.count());
}

test "an event stream ends itself when the server stops, after what was queued" {
    var room = try room_mod.Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 4 });
    defer room.deinit();

    var stopping = std.atomic.Value(bool).init(true);
    var script: Script = .{ .answers = &.{.posted} };
    var in = std.Io.Reader.fixed("");
    var bytes: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var events = roomEvents(&in, &out, script.waker(), true);
    events._stopping = &stopping;
    try room.sit(events.seating(), .off, true);

    try room.sayText("last");
    events.run();

    try testing.expectEqualStrings("c\r\ndata: last\n\n\r\n0\r\n\r\n", out.buffered());
    // It never waited: a stopped server is not something to park on.
    try testing.expectEqual(@as(usize, 0), script.at);
}
