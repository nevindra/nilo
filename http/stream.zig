//! Responses written in pieces, because their length is not known when the
//! head goes out (ADR 0020).
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

const http1 = @import("http1.zig");
const json_mod = @import("json.zig");
const watchdog = @import("watchdog.zig");

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
    /// ([ADR 0128](../docs/adr/0128-a-stream-that-knows-its-length-says-so.md)).
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
    /// ([ADR 0097](../docs/adr/0097-a-frame-that-lies-about-its-length-is-not-sent.md)):
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
    /// What the head promised, when it promised anything (ADR 0128).
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
    /// reader's own import line gives it (ADR 0122).
    pub const nilo_type_name = "nilo.Stream";

    /// Write here. Everything that lands in this buffer leaves as one chunk.
    writer: std.Io.Writer,

    /// The connection. Chunk framing is written straight to it, around
    /// whatever the buffer above collected.
    _out: *std.Io.Writer,
    /// The server's "please stop" flag, or null when nothing can stop —
    /// App driven straight from a test.
    _stopping: ?*const std.atomic.Value(bool),
    /// The `Ctx`'s record of this stream, set to null by `finish`.
    _open: *?Open,
    /// The `Ctx`'s "this connection cannot carry another request" flag, or
    /// null when nothing owns one — a test driving a Stream against a buffer.
    /// Set when a promised length is not met, which is the one failure here
    /// that cannot be taken back (ADR 0128).
    _force_close: ?*bool = null,
    /// The request's blocking detector, or null when there is no request
    /// behind this — a Stream a test built against a buffer. A stretch of
    /// handler time ends at every write, which is what lets a stream be
    /// watched rather than excused (ADR 0132).
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
        try self._out.flush();
    }

    /// Whether it is still worth carrying on: false once the server has been
    /// asked to stop.
    ///
    /// A long-running loop should check this. `listen()` waits for requests
    /// in flight, and a stream that ignores this holds the shutdown open for
    /// as long as it runs (ADR 0020).
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
        // this case — nothing was going to be written (ADR 0128).
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

        if (open.chunked and !open.drop) try http1.writeLastChunk(self._out);
        try self._out.flush();

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
        // all rather than excused (ADR 0132). A client too slow to take what
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
        // (ADR 0097, ADR 0128), and loudly, because a silent one would leave
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

        if (open.chunked) http1.writeChunkHeader(self._out, total) catch return error.WriteFailed;
        if (buffered.len > 0) self._out.writeAll(buffered) catch return error.WriteFailed;
        for (data[0 .. data.len - 1]) |slice| self._out.writeAll(slice) catch return error.WriteFailed;
        for (0..splat) |_| self._out.writeAll(pattern) catch return error.WriteFailed;
        if (open.chunked) http1.endChunk(self._out) catch return error.WriteFailed;

        w.end = 0;
        return from_data;
    }

    /// nilo's own: `Ctx.stream` builds one of these once the head is out.
    pub fn init(
        buffer: []u8,
        out: *std.Io.Writer,
        stopping: ?*const std.atomic.Value(bool),
        open: *?Open,
    ) Stream {
        return .{
            .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain } },
            ._out = out,
            ._stopping = stopping,
            ._open = open,
        };
    }

    /// The same, for a caller that owns the connection's "close after this"
    /// flag — which is `Ctx` and nobody else.
    pub fn initClosing(
        buffer: []u8,
        out: *std.Io.Writer,
        stopping: ?*const std.atomic.Value(bool),
        open: *?Open,
        force_close: *bool,
    ) Stream {
        var self = init(buffer, out, stopping, open);
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
    /// reader's own import line gives it (ADR 0122).
    pub const nilo_type_name = "nilo.Event";

    /// The `event:` name a listener can subscribe to by itself. Empty is the
    /// default, which a browser delivers as `message`.
    name: []const u8 = "",
    /// The `id:`, which the browser sends back as `Last-Event-ID` when it
    /// reconnects. Empty leaves it off.
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
    /// reader's own import line gives it (ADR 0122).
    pub const nilo_type_name = "nilo.Events";

    stream: Stream,

    pub const content_type = "text/event-stream";

    /// Send one event.
    pub fn send(self: *Events, event: Event) !void {
        const w = &self.stream.writer;
        if (event.name.len > 0) try w.print("event: {s}\n", .{event.name});
        if (event.id.len > 0) try w.print("id: {s}\n", .{event.id});
        try writeData(w, event.data);
        try w.writeAll("\n");
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
    pub fn comment(self: *Events, text: []const u8) !void {
        try self.stream.print(": {s}\n\n", .{text});
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

/// `data:` for every line of `text`, because a newline inside a value is a
/// line break on the wire and would end the event early.
///
/// A CR is dropped rather than passed through: the client strips CRLF, and a
/// lone CR left in the middle of a value is a difference between what was
/// sent and what arrives.
fn writeData(w: *std.Io.Writer, text: []const u8) !void {
    if (text.len == 0) return w.writeAll("data:\n");
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        try w.print("data: {s}\n", .{trimmed});
    }
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
    stream_buf: [64]u8 = undefined,
    open: ?Open = null,

    fn init(self: *Wire) void {
        self.out = .fixed(&self.buf);
    }

    fn stream(self: *Wire, chunked: bool, drop: bool) Stream {
        self.open = .{ .chunked = chunked, .drop = drop };
        return .init(&self.stream_buf, &self.out, null, &self.open);
    }

    /// A stream whose head promised `length` bytes: no chunk framing, and a
    /// close flag for the one failure that cannot be taken back.
    fn promising(self: *Wire, length: u64, closing: *bool) Stream {
        self.open = .{ .chunked = false, .drop = false, .promised = length };
        return .initClosing(&self.stream_buf, &self.out, null, &self.open, closing);
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
    // what says where this stops (ADR 0128).
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
    // byte of the next response — which is the failure ADR 0097 refuses one
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
    var body: Stream = .initClosing(&wire.stream_buf, &wire.out, null, &wire.open, &closing);

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
    var body: Stream = .init(&wire.stream_buf, &wire.out, &stopping, &wire.open);
    try testing.expect(body.live());
    stopping.store(true, .release);
    try testing.expect(!body.live());

    // Still writable: a stop asks a stream to wind up, it does not cut it off.
    try body.writeAll("last");
    try body.finish();
    try testing.expectEqualStrings("4\r\nlast\r\n0\r\n\r\n", wire.written());
}
