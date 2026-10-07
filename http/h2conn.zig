//! The HTTP/2 connection: one listener's connections, spoken as HTTP/2 with
//! prior knowledge, each request handed to the App as its fields and its body
//! ([ADR 220](../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md),
//! [ADR 253](../docs/adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md),
//! [ADR 259](../docs/adr/259-http2-is-a-framing-of-every-request.md)).
//! What is gRPC's rather than HTTP/2's (the content type, `grpc-timeout`, the
//! message prefix and compression, the status trailers) is `grpc.zig`, which
//! this file calls and which never names it.
//!
//! **Any request is an ordinary route, and gRPC is an envelope over it.** Any
//! method but `CONNECT`, held to RFC 9113 §8 before it reaches the App
//! (pseudo-headers, connection-specific fields, `te`, `content-length` against
//! the `DATA`, `cookie` joined), reaches the same router, middleware, services
//! and logger an HTTP/1.1 request does. What this file does is carry one
//! across: the HTTP/2 frames of one stream become a `framing.Call`, the
//! request's fields as its headers and its body whole, which the App reads as
//! it reads an HTTP/1.1 head and never as text it has to parse back; and what
//! the route answers goes back as HEADERS, DATA frames under both windows and
//! trailers when the route set any. A request whose content type is
//! `application/grpc` or `application/grpc+…` is a call: its message has the
//! length prefix and any gzip taken off, its answer is framed and carries
//! `grpc-status`, a route that fails with a status is a call that fails with
//! the gRPC code that status means, and a path no route answers is
//! `UNIMPLEMENTED`, which is what the gRPC spec asks of a method a server
//! does not have. **Collected whole, still**: the body is read before the
//! request runs and the answer is kept before it is written, so a streamed
//! answer, a file, `bodyStream`, an event stream and a WebSocket are refused
//! by name by `Ctx` (stage 6 makes them pipes, ADR 260).
//!
//! **Unary only for gRPC.** A call carries one message each way. Streaming
//! calls hold a stream open for their whole life, which is the one shape that
//! costs a fiber for as long as it lasts, and they wait for a caller (ADR 220).
//!
//! **One fiber reads and writes the socket; each request runs on a fiber of
//! its own.** The connection's fiber parses frames, collects a request's body,
//! and hands the finished request to `bulkhead.spawnLocal`, which keeps it on
//! the connection's thread. The request's fiber runs the route into memory and
//! hands the answer back through a queue and a
//! `Waker.post`, and the connection's fiber writes it, as far as the flow-
//! control windows allow. So no two fibers ever write the socket, and a
//! slow route never holds up the frames of another call. A call in flight
//! costs a fiber, 4,547 bytes and the stack its route touches, which is what
//! a request in flight on HTTP/1.1 costs already
//! ([`bench/result/http.md`](../bench/result/http.md#what-a-grpc-client-puts-on-the-wire-and-what-a-stream-would-cost)).
//! With no server running `spawnLocal` has nowhere to put one, and the call runs
//! on the connection's own fiber instead, which is how the tests below drive
//! a whole conversation through buffers in memory.
//!
//! **What a hostile client gets is bounded, and each bound is a test.** The
//! calls a connection may have in flight are capped, and a reset call still
//! counts until its route finishes, so resetting as fast as it opens (rapid
//! reset, CVE-2023-44487) gains a client nothing; one that keeps opening past
//! the cap is sent away. A header block is bounded however many CONTINUATION
//! frames it arrives in, and so is the header list it decodes to. A message
//! is bounded by its route's limit (`max_body`, or the route's own
//! `maxBody`, ADR 156), compressed or not, and the messages a
//! connection holds, arriving or held by a call until its answer is
//! written, by one ceiling between them (`max_body`, or the largest limit a route
//! raised to), past which a call waits on a
//! window the client is held to (`Conn.budget`); a gzip message's inflated
//! copy is charged to it before it is allocated, and a call whose copy does
//! not fit in what the other calls leave waits, holding only its compressed
//! bytes, until one of them gives room back (ADR 220). Frames that move no call
//! forward are counted, and a flood is sent away. A client that
//! stops reading while an answer waits on its window is cut off at the write
//! deadline.

const std = @import("std");
const h2 = @import("h2.zig");
const hpack = @import("hpack.zig");
const bulkhead = @import("bulkhead.zig");
const fail = @import("fail.zig");
const encoded = @import("encoded.zig");
const core = @import("nilo_core");
const framing = @import("framing.zig");
const grpc = @import("grpc.zig");
const date = @import("date.zig");

/// What a gRPC connection asks of the App, handed over by `app.zig` rather
/// than named here. This file sits outside the App's core (`http_core` in
/// build.zig), and the App passing itself in as these few things is what
/// keeps it there: routing and dispatch stay the core's, and this file only
/// translates.
pub const Host = struct {
    ptr: *anyopaque,
    gpa: std.mem.Allocator,
    stop: *const bulkhead.Stop,
    max_body: usize,
    /// The most a route may raise its own limit to, and `max_body` where none
    /// does: what one connection's messages are bounded by together
    /// (`Conn.budget`, ADR 220).
    ceiling: usize,
    /// What a request to this method and path is collected under: the
    /// route's `maxBody` where it has one, `max_body` where it has not. Read
    /// once the headers are in, before a byte of the body (ADR 156, ADR 220).
    body_limit: *const fn (ptr: *anyopaque, method: []const u8, path: []const u8) usize,
    /// Whether a `POST` to this path reaches a route.
    routes: *const fn (ptr: *anyopaque, path: []const u8) bool,
    /// One call through the App, handed over as what was read rather than
    /// as HTTP/1.1 text, and its answer kept in `collected` rather than
    /// written (ADR 253), with no waker and no read limits: a call's fiber
    /// never reads from the socket, so there is nothing for either to arm.
    /// `until_ns` is the call's `grpc-timeout` as a `monotonicNanos` reading,
    /// or 0, and it is the request's deadline (ADR 105).
    handle: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        lifetime: *core.Lifetime,
        in_flight: *fail.InFlight,
        call: framing.Call,
        collected: *framing.Collected,
        peer: bulkhead.Peer,
        until_ns: u64,
    ) void,
};

/// How many calls one connection may have in flight at once, advertised as
/// `SETTINGS_MAX_CONCURRENT_STREAMS`. A call is a fiber and the stack its
/// route touches, so this times that is the most one connection can hold:
/// about 1.7 MB on a route that reads a database (ADR 220). Every client
/// measured queues past it rather than failing, so it caps what a connection
/// costs and never what it can do.
pub const max_streams = 100;

/// The most a header list may weigh by RFC 7541's count, advertised as
/// `SETTINGS_MAX_HEADER_LIST_SIZE`. The same sixteen kilobytes an HTTP/1.1
/// head may be (`Options.read_buffer`).
pub const max_header_list = 16 * 1024;

/// The most one header block may be on the wire, however many CONTINUATION
/// frames carry it. Four times the list: a block larger than the list it
/// decodes to is padding or a table being filled for nothing.
const max_header_block = 4 * max_header_list;

/// Calls refused for being past the cap before the connection is sent away.
/// A client honouring the setting is refused at most the calls it sent
/// before reading it, a handful; one that keeps opening is not waiting.
const max_refused = 1000;

/// PING and SETTINGS frames in a row, with no call between them, before the
/// connection is sent away. Each one is answered, so a flood is a client
/// making this side write.
const max_control_run = 1000;

/// How long a connection with nothing in flight waits before handing its
/// pages back, the way an HTTP/1.1 connection does between requests
/// (`serve.idle_peek_ms`).
const idle_peek_ms = 200;

/// How much of a finished call's arena a spare stream keeps for the next one.
/// A unary call with a small message stays inside it, so a busy connection's
/// calls stop reaching the general-purpose allocator at all.
const spare_arena_keep = 4096;

/// `:status 100`, which is all an interim answer carries: the static table's
/// `:status` name and the three digits. A test holds it to `encodeBlock`.
const continue_block = "\x08\x03100";

/// What one listener speaking gRPC runs for each connection, in place of
/// `serve.handleConnection`. Returns when the client has gone, the
/// connection was sent away, or it sat idle past `idle_timeout_ms`.
pub fn serveConnection(
    app: Host,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    deadlines: bulkhead.Deadlines,
    waker: bulkhead.Waker,
    peer: bulkhead.Peer,
) void {
    const shared = Shared.create(app.gpa, waker) catch return;
    var conn: Conn = .{
        .app = app,
        .gpa = app.gpa,
        .in = in,
        .out = out,
        .deadlines = deadlines,
        .waker = waker,
        .peer = peer,
        .shared = shared,
        .decoder = hpack.Decoder.init(app.gpa),
    };
    defer conn.deinit();
    deadlines.armWrite();
    conn.run();
}

/// What a call's fiber and the connection's fiber share: the queue of
/// answered calls, and whether the connection is still there to write them.
///
/// **On the heap and counted**, because a call's fiber can outlive the
/// connection: a client that hangs up while a route is running leaves that
/// route to finish, and when it does there has to be something to tell it
/// nobody is listening. The last one out frees it.
const Shared = struct {
    gpa: std.mem.Allocator,
    waker: bulkhead.Waker,
    lock: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u32) = .init(1),
    /// Answered calls, oldest first, not yet taken by the connection.
    head: ?*Stream = null,
    tail: ?*Stream = null,
    /// Set once by the connection on its way out. After it, a call's fiber
    /// frees its own stream rather than queueing it, and never posts.
    closed: bool = false,
    /// Calls whose fiber has not handed them back yet.
    running: std.atomic.Value(u32) = .init(0),

    fn create(gpa: std.mem.Allocator, waker: bulkhead.Waker) !*Shared {
        const s = try gpa.create(Shared);
        s.* = .{ .gpa = gpa, .waker = waker };
        return s;
    }

    /// A spin, not a lock that parks: what is inside is a pointer or two, and
    /// the waiting it would save costs more than it does. The same trade the
    /// cache makes, for the same reason (ADR 109).
    fn acquire(s: *Shared) void {
        while (s.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(s: *Shared) void {
        s.lock.store(false, .release);
    }

    fn retain(s: *Shared) void {
        _ = s.refs.fetchAdd(1, .monotonic);
    }

    fn drop(s: *Shared) void {
        if (s.refs.fetchSub(1, .acq_rel) == 1) s.gpa.destroy(s);
    }

    /// A call's fiber, done. Queued for the connection and the connection
    /// woken, or freed if there is no connection any more.
    fn finish(s: *Shared, stream: *Stream) void {
        s.acquire();
        if (s.closed) {
            s.release();
            stream.destroy();
        } else {
            stream.next = null;
            if (s.tail) |t| t.next = stream else s.head = stream;
            s.tail = stream;
            s.waker.post();
            s.release();
        }
        _ = s.running.fetchSub(1, .release);
        s.drop();
    }

    fn takeAll(s: *Shared) ?*Stream {
        s.acquire();
        defer s.release();
        const all = s.head;
        s.head = null;
        s.tail = null;
        return all;
    }
};

/// One call, from its HEADERS frame to the last frame of its answer.
const Stream = struct {
    id: u31,
    gpa: std.mem.Allocator,
    /// Everything the call reads and writes, freed in one go when its answer
    /// has gone out.
    arena: std.heap.ArenaAllocator,
    state: State = .headers,
    /// The header block as it arrives, then the fields it decodes to.
    block: std.ArrayList(u8) = .empty,
    fields: std.ArrayList(hpack.Field) = .empty,
    headers_over_limit: bool = false,
    /// The HEADERS frame said END_STREAM and its block continues: the call
    /// starts when the last CONTINUATION arrives.
    ends_with_headers: bool = false,
    /// The message as it arrives, length prefix and all.
    body: std.ArrayList(u8) = .empty,
    body_over_limit: bool = false,
    /// Whether the request is a gRPC call: its content type says so, and only
    /// then is its body unframed and its answer framed and trailed as gRPC
    /// (ADR 259). Every other request is HTTP.
    grpc: bool = false,
    /// Its HEADERS frame said it depends on itself, which is a stream error
    /// (§5.3.1), said once the header block is decoded and the table is safe.
    self_dependent: bool = false,
    /// What this call's message may be, from its route once the headers are
    /// in: `max_body`, or the route's own `maxBody` (ADR 156, ADR 220).
    limit: usize,
    /// When the call's first HEADERS frame arrived: what `grpc-timeout` is
    /// counted from, because the client's clock started when it sent the
    /// call and not when its message was whole (gRPC over HTTP/2, "Requests").
    headers_ns: u64 = 0,
    /// When the client stops waiting, from `grpc-timeout`, or 0.
    until_ns: u64 = 0,
    /// When the client has to have finished sending this call, or 0 for no
    /// bound. `body_grace_ms + (max_body + 5) / body_min_rate` from the
    /// HEADERS frame: the rule a chunked HTTP/1.1 body is held to, sized from
    /// the most it may be because nothing says how much is coming (ADR 022).
    collect_until_ns: u64 = 0,
    /// Bytes read since this stream's window was last topped up.
    unacked: u32 = 0,
    /// Bytes counted in the connection's `collected`: the message as it
    /// arrived, and once the call starts, its inflated copy and the copy the
    /// route reads it into. Given back when the call is let go of.
    held: usize = 0,
    /// Its window is owed a top-up the connection's budget held back.
    starved: bool = false,
    /// What the client may still send on it before this side says more.
    recv_window: i64 = h2.default_window,
    /// What may be sent on this stream before the client says more.
    send_window: i64,
    /// The client reset it. Its route still runs to the end, because nothing
    /// can stop it midway, and still counts against the cap until it does;
    /// its answer is thrown away.
    reset: bool = false,

    // The answer, filled by the call's fiber.
    head_block: []const u8 = "",
    data: []const u8 = "",
    trailers: []const u8 = "",
    /// Everything is in `head_block`, END_STREAM included: a call that failed
    /// before it had anything to say (§ "Trailers-Only" of the gRPC spec).
    trailers_only: bool = false,
    /// An HTTP answer with no trailers: the last DATA frame ends the stream,
    /// where a call's answer always ends in a HEADERS frame.
    no_trailers: bool = false,
    head_sent: bool = false,
    data_sent: usize = 0,

    // For the call's fiber.
    app: Host,
    peer: bulkhead.Peer,
    shared: *Shared,
    next: ?*Stream = null,

    /// `waiting` is a gzip call whose message is whole and whose inflated
    /// copy does not fit in what the connection's budget has left: it holds
    /// its compressed bytes and nothing else until `admitWaiting` starts it.
    const State = enum { headers, body, waiting, running, writing };

    fn create(gpa: std.mem.Allocator, id: u31, app: Host, peer: bulkhead.Peer, shared: *Shared, send_window: i64) !*Stream {
        const s = try gpa.create(Stream);
        s.* = .{
            .id = id,
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .limit = app.max_body,
            .send_window = send_window,
            .app = app,
            .peer = peer,
            .shared = shared,
        };
        return s;
    }

    fn destroy(s: *Stream) void {
        s.arena.deinit();
        s.gpa.destroy(s);
    }

    /// Ready for the connection's next call: the arena keeps up to
    /// `spare_arena_keep` bytes and everything else is as `create` leaves it.
    fn recycle(s: *Stream) void {
        _ = s.arena.reset(.{ .retain_with_limit = spare_arena_keep });
        const kept = .{ s.gpa, s.arena, s.app, s.peer, s.shared };
        s.* = .{ .id = 0, .gpa = kept[0], .arena = kept[1], .limit = kept[2].max_body, .send_window = 0, .app = kept[2], .peer = kept[3], .shared = kept[4] };
    }

    fn field(s: *const Stream, name: []const u8) ?[]const u8 {
        for (s.fields.items) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }
};

/// Why a connection is being sent away; `goawayFor` says which GOAWAY.
const ConnError = error{ Protocol, FrameSize, FlowControl, Compression, Calm, Internal };

const Conn = struct {
    app: Host,
    gpa: std.mem.Allocator,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    deadlines: bulkhead.Deadlines,
    waker: bulkhead.Waker,
    peer: bulkhead.Peer,
    shared: *Shared,
    decoder: hpack.Decoder,

    /// Every call this connection holds: collecting, running or being
    /// written. Its length is what the cap counts.
    streams: std.ArrayList(*Stream) = .empty,
    /// The stream whose header block is not finished: only CONTINUATION
    /// frames for it may come next (§6.10).
    continuing: ?*Stream = null,
    last_stream: u31 = 0,

    /// What the client said, and where its windows stand.
    peer_window: i64 = h2.default_window,
    peer_max_frame: u32 = h2.default_max_frame,
    send_window: i64 = h2.default_window,
    /// Bytes of DATA read since the connection's window was last topped up.
    unacked: u32 = 0,
    /// Bytes of messages read and not yet handed to a route, across every
    /// call still arriving, and how many of those calls are owed a window.
    collected: usize = 0,
    starved: u32 = 0,
    /// Calls in `waiting`, so a connection with none skips looking.
    waiting: u32 = 0,
    /// What the client may still send on the connection before this side
    /// says more. A window is only a bound if it is held to.
    recv_window: i64 = h2.default_window,

    goaway_sent: bool = false,
    peer_goaway: bool = false,
    peer_gone: bool = false,
    released: bool = false,
    refused: u32 = 0,
    control_run: u32 = 0,
    /// When the oldest answer started waiting on a window, or 0.
    blocked_since: u64 = 0,
    /// When the last frame arrived. A call still being sent with nothing
    /// arriving for `body_ms` is a client that stopped, as a body read that
    /// times out is on HTTP/1.1.
    last_read_ns: u64 = 0,
    /// Streams whose calls are over, kept for the next ones: at most
    /// `max_streams` of them, and none once the connection waits with no call
    /// in flight, so they cost a busy connection what its calls already held
    /// and a quiet one nothing.
    spare: ?*Stream = null,
    spares: u32 = 0,

    fn newStream(c: *Conn, id: u31) !*Stream {
        if (c.spare) |s| {
            c.spare = s.next;
            c.spares -= 1;
            s.next = null;
            s.id = id;
            s.send_window = c.peer_window;
            return s;
        }
        return Stream.create(c.gpa, id, c.app, c.peer, c.shared, c.peer_window);
    }

    fn dropSpares(c: *Conn) void {
        while (c.spare) |s| {
            c.spare = s.next;
            s.destroy();
        }
        c.spares = 0;
    }

    fn deinit(c: *Conn) void {
        // The calls still running keep `shared` alive and free themselves;
        // everything this side holds goes now.
        c.shared.acquire();
        c.shared.closed = true;
        var queued = c.shared.head;
        c.shared.head = null;
        c.shared.tail = null;
        c.shared.release();
        while (queued) |s| {
            queued = s.next;
            c.forget(s);
        }
        for (c.streams.items) |s| if (s.state != .running) s.destroy();
        c.streams.deinit(c.gpa);
        c.dropSpares();
        c.decoder.deinit();
        c.shared.drop();
    }

    fn run(c: *Conn) void {
        c.deadlines.armHeader();
        const got = c.in.takeArray(h2.preface.len) catch return;
        // Not HTTP/2: most likely HTTP/1.1 on the wrong port, which is said
        // the only way that client can read, and the connection closed.
        if (!std.mem.eql(u8, got, h2.preface)) {
            c.out.writeAll("HTTP/1.1 505 HTTP Version Not Supported\r\ncontent-length: 0\r\nconnection: close\r\n\r\n") catch {};
            c.out.flush() catch {};
            return;
        }
        h2.writeSettings(c.out, &.{
            .{ .header_table_size, 0 },
            .{ .enable_push, 0 },
            .{ .max_concurrent_streams, max_streams },
            .{ .max_header_list_size, max_header_list },
        }) catch return;
        c.out.flush() catch return;

        while (true) {
            c.writeReady() catch break;
            _ = c.admitWaiting() catch break;
            c.grantWaiting() catch break;
            // Nothing in flight and nothing more already read: what a client
            // sent behind its GOAWAY is still answered, and closing on it
            // unread would reset the connection under the client's last frames.
            if (c.goaway_sent or c.peer_goaway) {
                if (c.streams.items.len == 0 and c.in.bufferedLen() == 0) break;
            }
            if (!c.goaway_sent and c.app.stop.isRequested()) {
                c.goaway(.no_error) catch break;
                continue;
            }
            if (c.in.bufferedLen() == 0) {
                // Everything answered since the last wait goes out in one
                // write, rather than a write for every frame read (ADR 220).
                c.out.flush() catch break;
                // Spares are for a connection with calls in flight. One that
                // is about to wait with none gives them back now rather than
                // at the idle release: held for those 200ms, a burst of
                // connections measured 5 MB of heap the allocator then kept.
                if (c.streams.items.len == 0) c.dropSpares();
                switch (c.wait()) {
                    .posted => continue,
                    .again => continue,
                    .stop => break,
                    .readable => {},
                }
            }
            c.released = false;
            c.readFrame() catch |err| {
                // Gone is a client that stopped sending, which may still be
                // reading: what it is owed is written on the way out.
                if (err != error.Gone) c.goawayFor(err);
                break;
            };
        }
        c.windDown();
    }

    const Waited = enum { readable, posted, again, stop };

    fn wait(c: *Conn) Waited {
        if (c.streams.items.len != 0) {
            // Something is in flight. A route that is running is waited for
            // as long as it takes: its own deadline is what bounds it. What
            // the client owes is not: an answer stuck on a window gets the
            // write limit, counted from when it first stuck rather than from
            // the last frame, and a call still being sent gets its own bound
            // and `body_ms` between frames.
            const limit = c.inFlightLimitMs() orelse return .stop;
            return switch (c.waker.wait(limit)) {
                .readable => .readable,
                .posted => .posted,
                .timed_out => c.overdue(),
                .closed => blk: {
                    c.peer_gone = true;
                    break :blk .stop;
                },
            };
        }
        if (!c.released) {
            switch (c.waker.wait(idle_peek_ms)) {
                .readable => return .readable,
                .posted => return .posted,
                .closed => {
                    c.peer_gone = true;
                    return .stop;
                },
                .timed_out => {
                    // Quiet: hand the pages back, the way an idle HTTP/1.1
                    // connection does, and wait again from this frame.
                    bulkhead.releaseIdlePages(c.in, c.out);
                    c.dropSpares();
                    c.streams.clearAndFree(c.gpa);
                    c.waker.releaseStack();
                    c.released = true;
                    return .again;
                },
            }
        }
        return switch (c.waker.wait(c.deadlines.idle_ms)) {
            .readable => .readable,
            .posted => .posted,
            .closed => blk: {
                c.peer_gone = true;
                break :blk .stop;
            },
            .timed_out => blk: {
                // Idle past its limit: said with a GOAWAY, which a client
                // reads as "open a new connection next time".
                c.goaway(.no_error) catch {};
                break :blk .stop;
            },
        };
    }

    fn writeLimitMs(c: *const Conn) u32 {
        return if (c.deadlines.write_ms == 0) 30_000 else c.deadlines.write_ms;
    }

    /// How long a wait with calls in flight may last: 0 for as long as it
    /// takes, which is only when nothing is owed by the client. Null when a
    /// bound has already passed.
    fn inFlightLimitMs(c: *const Conn) ?u32 {
        const now = bulkhead.monotonicNanos();
        var soonest: u64 = std.math.maxInt(u64);
        if (c.blocked_since != 0) {
            const until = c.blocked_since +| @as(u64, c.writeLimitMs()) * std.time.ns_per_ms;
            if (until <= now) return null;
            soonest = until;
        }
        var collecting = false;
        for (c.streams.items) |s| {
            // A call waiting for room is bounded by its own deadline, the
            // way a running one is: what it waits on is this side.
            if (s.state == .waiting and s.until_ns != 0) soonest = @min(soonest, s.until_ns);
            if (s.state != .headers and s.state != .body) continue;
            collecting = true;
            if (s.collect_until_ns != 0) soonest = @min(soonest, s.collect_until_ns);
        }
        if (collecting and c.deadlines.body_ms != 0) {
            soonest = @min(soonest, c.last_read_ns +| @as(u64, c.deadlines.body_ms) * std.time.ns_per_ms);
        }
        if (soonest == std.math.maxInt(u64)) return 0;
        // Rounded up, and never 0, which would mean no limit at all: a bound
        // already past gets a wait of 1 ms and `overdue` then acts on it.
        const left = soonest -| now;
        return @intCast(@max(1, @min(std.math.maxInt(u32), (left + std.time.ns_per_ms - 1) / std.time.ns_per_ms)));
    }

    /// A bound on a wait with calls in flight has passed: say which, and do
    /// what it asks.
    fn overdue(c: *Conn) Waited {
        const now = bulkhead.monotonicNanos();
        if (c.blocked_since != 0 and now -| c.blocked_since >= @as(u64, c.writeLimitMs()) * std.time.ns_per_ms) return .stop;
        var collecting = false;
        var i: usize = 0;
        while (i < c.streams.items.len) {
            const s = c.streams.items[i];
            if (s.state == .waiting and s.until_ns != 0 and now >= s.until_ns) {
                // The client stopped waiting before room came back: it is
                // told so, and the call is never run.
                c.leaveWaiting(s);
                c.answerNow(s, 4, "the call's deadline passed while it waited for room on this connection") catch return .stop;
                continue;
            }
            if (s.state != .headers and s.state != .body) {
                i += 1;
                continue;
            }
            if (s.collect_until_ns != 0 and now >= s.collect_until_ns) {
                // Too slow sending one call: that call is cancelled and its
                // buffered message freed, and the connection goes on. Not
                // while its header block is unfinished: a reset would leave
                // the table out of step, so the connection is sent away. The
                // silence limit below is no bound on that, because every
                // CONTINUATION resets it, and one byte a frame held a slot
                // for as long as `max_header_block` lasted (ADR 220).
                if (c.continuing == s) {
                    c.goaway(.enhance_your_calm) catch {};
                    return .stop;
                }
                h2.writeRstStream(c.out, s.id, .cancel) catch return .stop;
                c.forget(s);
                continue;
            }
            collecting = true;
            i += 1;
        }
        if (collecting and c.deadlines.body_ms != 0 and now -| c.last_read_ns >= @as(u64, c.deadlines.body_ms) * std.time.ns_per_ms) {
            // Nothing at all from a client that still owes a call.
            c.goaway(.no_error) catch {};
            return .stop;
        }
        return .again;
    }

    /// The bound on sending one call, from `now`.
    fn collectUntil(c: *const Conn, now: u64, bound: usize) u64 {
        const rate = c.deadlines.body_min_rate;
        if (rate == 0) return 0;
        const most: u64 = @as(u64, bound) + 5;
        const ms = @as(u64, c.deadlines.body_grace_ms) + most * std.time.ms_per_s / rate;
        return now +| ms * std.time.ns_per_ms;
    }

    /// Wait for the calls still running, then write what they answered if
    /// there is anybody left to read it. A client that stopped sending may
    /// still be reading, so the calls waiting for room are started as the
    /// running ones give it back, until nothing more can move: room held by
    /// an answer stuck on a window comes back only with a WINDOW_UPDATE, and
    /// nothing is read from here on. With nobody reading, a waiting call is
    /// not run at all, since what it answers would go nowhere.
    fn windDown(c: *Conn) void {
        while (!c.peer_gone) {
            c.flushReady() catch {
                c.peer_gone = true;
                break;
            };
            const started = c.admitWaiting() catch {
                c.peer_gone = true;
                break;
            };
            if (started != 0) continue;
            if (c.shared.running.load(.acquire) == 0) break;
            bulkhead.sleep(1) catch break;
        }
        while (c.shared.running.load(.acquire) != 0) {
            bulkhead.sleep(1) catch break;
            if (!c.peer_gone) c.flushReady() catch {
                c.peer_gone = true;
            };
        }
        if (!c.peer_gone) c.flushReady() catch {};
    }

    fn flushReady(c: *Conn) !void {
        try c.writeReady();
        try c.out.flush();
    }

    fn goaway(c: *Conn, code: h2.ErrorCode) !void {
        if (c.goaway_sent) return;
        c.goaway_sent = true;
        try h2.writeGoaway(c.out, c.last_stream, code);
        try c.out.flush();
    }

    fn goawayFor(c: *Conn, err: ReadError) void {
        const code: h2.ErrorCode = switch (err) {
            error.Gone => return,
            error.Protocol => .protocol_error,
            error.FrameSize => .frame_size_error,
            error.FlowControl => .flow_control_error,
            error.Compression => .compression_error,
            error.Calm => .enhance_your_calm,
            error.Internal => .internal_error,
        };
        c.goaway(code) catch {};
    }

    // ---- reading ----

    const ReadError = ConnError || error{Gone};

    fn take(c: *Conn, n: usize) ReadError![]u8 {
        return c.in.take(n) catch return error.Gone;
    }

    fn discard(c: *Conn, n: usize) ReadError!void {
        c.in.discardAll(n) catch return error.Gone;
    }

    fn readFrame(c: *Conn) ReadError!void {
        c.deadlines.armBody();
        const head = h2.Header.parse(c.in.takeArray(h2.header_len) catch return error.Gone);
        c.last_read_ns = bulkhead.monotonicNanos();
        if (head.len > h2.default_max_frame) return error.FrameSize;

        if (c.continuing) |s| {
            if (head.type != .continuation or head.stream != s.id) return error.Protocol;
        }

        switch (head.type) {
            .data => try c.onData(head),
            .headers => try c.onHeaders(head),
            .continuation => {
                const s = c.continuing orelse return error.Protocol;
                if (head.len == 0 and !head.has(h2.Flags.end_headers)) try c.control();
                try c.appendBlockBytes(s, head.len);
                if (head.has(h2.Flags.end_headers)) try c.headersDone(s);
            },
            .settings => try c.onSettings(head),
            .ping => {
                if (head.stream != 0) return error.Protocol;
                if (head.len != 8) return error.FrameSize;
                const data = (try c.take(8))[0..8];
                if (!head.has(h2.Flags.ack)) {
                    try c.control();
                    h2.writePingAck(c.out, data) catch return error.Gone;
                }
            },
            .window_update => try c.onWindowUpdate(head),
            .rst_stream => {
                if (head.stream == 0) return error.Protocol;
                if (head.len != 4) return error.FrameSize;
                try c.discard(4);
                if (head.stream > c.last_stream) return error.Protocol;
                if (c.find(head.stream)) |s| {
                    // A call reset before it ever ran cost a header block
                    // decoded and a stream made, and bought nothing: HEADERS
                    // then RST_STREAM, over and over, is a flood like PING.
                    if (s.state == .headers or s.state == .body) try c.control();
                    c.onReset(s);
                }
            },
            .priority => {
                if (head.stream == 0) return error.Protocol;
                if (head.len != 5) return error.FrameSize;
                const depends = dependsOn((try c.take(5))[0..5]);
                try c.control();
                // A stream that depends on itself is a stream error, whatever
                // state it is in (§5.3.1); nothing else about priority is read.
                if (depends == head.stream) {
                    h2.writeRstStream(c.out, head.stream, .protocol_error) catch return error.Gone;
                    if (c.find(head.stream)) |s| c.onReset(s);
                }
            },
            .goaway => {
                if (head.stream != 0) return error.Protocol;
                if (head.len < 8) return error.FrameSize;
                try c.discard(head.len);
                c.peer_goaway = true;
            },
            // A client may not push (§8.4).
            .push_promise => return error.Protocol,
            // Unknown frame types are ignored (§5.5), and counted: each one
            // is a frame read for nothing.
            _ => {
                try c.discard(head.len);
                try c.control();
            },
        }
    }

    /// A frame that moved no call forward, with no call since the last one:
    /// PING, SETTINGS, PRIORITY, an unknown type, an empty DATA or
    /// CONTINUATION, a WINDOW_UPDATE nothing was waiting for, a call reset
    /// before it ran. Only a call reaching `dispatch` starts the count again,
    /// so opening a stream in between does not.
    fn control(c: *Conn) ReadError!void {
        c.control_run += 1;
        if (c.control_run > max_control_run) return error.Calm;
    }

    /// Strip the padding length off the front of a padded frame, and say how
    /// much padding follows the content.
    fn padding(c: *Conn, head: h2.Header, len: *usize) ReadError!usize {
        if (!head.has(h2.Flags.padded)) return 0;
        if (len.* < 1) return error.Protocol;
        const pad = (try c.take(1))[0];
        len.* -= 1;
        if (pad > len.*) return error.Protocol;
        len.* -= pad;
        return pad;
    }

    fn onHeaders(c: *Conn, head: h2.Header) ReadError!void {
        if (head.stream == 0 or head.stream % 2 == 0) return error.Protocol;
        var len: usize = head.len;
        const pad = try c.padding(head, &len);
        var self_dependent = false;
        if (head.has(h2.Flags.priority)) {
            if (len < 5) return error.Protocol;
            self_dependent = dependsOn((try c.take(5))[0..5]) == head.stream;
            len -= 5;
        }

        // Trailers from the client, on a call still sending its message.
        if (c.find(head.stream)) |s| {
            if (s.state != .body) return error.Protocol;
            if (!head.has(h2.Flags.end_stream)) return error.Protocol;
            s.block.clearRetainingCapacity();
            try c.appendBlockBytes(s, len);
            try c.discard(pad);
            s.state = .headers;
            s.ends_with_headers = true;
            if (head.has(h2.Flags.end_headers)) try c.headersDone(s) else c.continuing = s;
            return;
        }
        if (head.stream <= c.last_stream) return error.Protocol;
        c.last_stream = head.stream;

        const s = c.newStream(head.stream) catch return error.Internal;
        s.self_dependent = self_dependent;
        s.headers_ns = bulkhead.monotonicNanos();
        s.collect_until_ns = c.collectUntil(s.headers_ns, c.app.max_body);
        c.streams.append(c.gpa, s) catch {
            s.destroy();
            return error.Internal;
        };
        // Read before anything else is decided: the block has to be decoded
        // whatever happens to the call, or the table falls out of step.
        try c.appendBlockBytes(s, len);
        try c.discard(pad);
        s.ends_with_headers = head.has(h2.Flags.end_stream);
        if (head.has(h2.Flags.end_headers)) try c.headersDone(s) else c.continuing = s;
    }

    fn appendBlockBytes(c: *Conn, s: *Stream, len: usize) ReadError!void {
        if (s.block.items.len + len > max_header_block) return error.Calm;
        const dest = s.block.addManyAsSlice(s.arena.allocator(), len) catch return error.Internal;
        c.in.readSliceAll(dest) catch return error.Gone;
    }

    /// The header block is whole: decode it, and either wait for the message
    /// or, if the client has nothing more to send, start the call.
    fn headersDone(c: *Conn, s: *Stream) ReadError!void {
        c.continuing = null;
        const end_stream = s.ends_with_headers;
        const is_trailers = s.fields.items.len != 0;
        const arena = s.arena.allocator();
        var scratch: std.ArrayList(hpack.Field) = .empty;
        const into = if (is_trailers) &scratch else &s.fields;
        const decoded = c.decoder.decode(s.block.items, arena, into, max_header_list) catch |err| switch (err) {
            error.Compression => return error.Compression,
            error.OutOfMemory => return error.Internal,
        };
        if (decoded.over_limit) s.headers_over_limit = true;
        if (is_trailers) {
            s.state = .body;
            return c.dispatch(s);
        }

        // A stream that depends on itself: decoded above, and reset now (§5.3.1).
        if (s.self_dependent) return c.malformed(s);

        // After this side's GOAWAY: decoded above, because the table has to
        // stay in step, and refused, because the GOAWAY told the client this
        // stream was never processed and a client may send it again on a new
        // connection. Running it here too would run a call twice (§6.8).
        if (c.goaway_sent) {
            const id = s.id;
            c.forget(s);
            h2.writeRstStream(c.out, id, .refused_stream) catch return error.Gone;
            return;
        }
        // Past the cap: refused, which a client reads as "try again", and
        // counted, because a client that keeps doing it is not waiting.
        if (c.streams.items.len > max_streams) {
            c.refused += 1;
            if (c.refused > max_refused) return error.Calm;
            const id = s.id;
            c.forget(s);
            h2.writeRstStream(c.out, id, .refused_stream) catch return error.Gone;
            return;
        }
        // The route is known from the headers, and so is what it takes: the
        // message is collected under that, and the time the client has to
        // send it is sized from it (ADR 156, ADR 220). Nothing is looked up
        // for a call with no path, which `dispatch` refuses.
        if (s.field(":path")) |path| {
            s.limit = c.app.body_limit(c.app.ptr, s.field(":method") orelse "", path);
            if (s.limit != c.app.max_body) s.collect_until_ns = c.collectUntil(s.headers_ns, s.limit);
        }
        s.grpc = grpc.isGrpcContentType(s.field("content-type") orelse "");
        s.state = .body;
        if (end_stream) return c.dispatch(s);
        // A CONNECT never ends its own stream, since what follows is the
        // tunnel, so it is answered now: refused, with the rest of what the
        // client was going to send told to stop once the answer is out.
        if (std.mem.eql(u8, s.field(":method") orelse "", "CONNECT")) {
            for (s.fields.items) |f| if (!validField(f)) return c.malformed(s);
            const id = s.id;
            try c.dispatch(s);
            if (c.find(id) == null) h2.writeRstStream(c.out, id, .no_error) catch return error.Gone;
            return;
        }
        // A client that waits to be told before it sends its body is told at
        // once: the body is collected whatever the route says, so there is no
        // refusing it first for a `100` to hold back (ADR 259). Said for a
        // stream that goes on, and never for one that is over.
        if (s.field("expect")) |expect| {
            if (std.ascii.eqlIgnoreCase(expect, "100-continue")) {
                h2.writeHeaderBlock(c.out, s.id, continue_block, false, c.peer_max_frame) catch return error.Gone;
            }
        }
    }

    fn onData(c: *Conn, head: h2.Header) ReadError!void {
        if (head.stream == 0) return error.Protocol;
        var len: usize = head.len;
        // The whole frame counts against the window, padding included (§6.9),
        // and a client that sends past a window it was given is not sending
        // HTTP/2 (§6.9.1): the budget below is only a bound if this is held.
        c.recv_window -= head.len;
        if (c.recv_window < 0) return error.FlowControl;
        try c.consumed(head.len);
        const pad = try c.padding(head, &len);
        const s = c.find(head.stream) orelse {
            if (head.stream > c.last_stream) return error.Protocol;
            // A call already answered, refused or reset: the bytes are
            // thrown away and nothing is said. §5.1 has a stream this side
            // reset ignore what was already in flight, and an RST for every
            // frame would be a client making this side write, uncounted.
            // The zig build fuzz -- --frames property found it (ADR 220).
            try c.discard(len + pad);
            if (len == 0) try c.control();
            return;
        };
        if (s.state != .body) {
            try c.discard(len + pad);
            if (s.state == .headers) return error.Protocol;
            // The client ended this request, which is half-closed (remote)
            // while its answer is made and written: more DATA on it is a
            // stream error STREAM_CLOSED (§5.1). Reset, and the stream is
            // gone, so a frame after this one is a frame on a closed stream,
            // ignored above and counted when it is empty.
            h2.writeRstStream(c.out, s.id, .stream_closed) catch return error.Gone;
            c.onReset(s);
            return;
        }
        if (len == 0 and !head.has(h2.Flags.end_stream)) try c.control();
        s.recv_window -= head.len;
        if (s.recv_window < 0) return error.FlowControl;
        if (s.body_over_limit or s.body.items.len + len > s.limit + @as(usize, if (s.grpc) grpc.prefix_len else 0)) {
            // Past the call's limit: read and dropped, so the connection stays in
            // step, and answered when the client says it is done.
            s.body_over_limit = true;
            try c.discard(len);
        } else {
            const dest = s.body.addManyAsSlice(s.arena.allocator(), len) catch return error.Internal;
            c.in.readSliceAll(dest) catch return error.Gone;
            c.hold(s, len);
        }
        try c.discard(pad);
        if (head.has(h2.Flags.end_stream)) {
            try c.dispatch(s);
        } else {
            s.unacked += head.len;
            if (s.unacked >= h2.default_window / 2) {
                if (c.mayGrow(s)) {
                    h2.writeWindowUpdate(c.out, s.id, @intCast(s.unacked)) catch return error.Gone;
                    s.recv_window += s.unacked;
                    s.unacked = 0;
                } else if (!s.starved) {
                    s.starved = true;
                    c.starved += 1;
                }
            }
        }
    }

    /// What one connection may hold of messages, arriving or held by a route
    /// still running: one message at `max_body`, which is what an HTTP/1.1
    /// connection holds.
    /// Past it a call's window is not topped up, so the client waits on it
    /// rather than this side reading, and all a call can hold beyond the
    /// budget is the window it was opened with.
    fn budget(c: *const Conn) usize {
        return @max(c.app.ceiling + 5, h2.default_window);
    }

    /// What the connection's budget has left for `s`: the budget less what
    /// every call but `s` holds. A call alone has all of it, which is what lets
    /// a message of `max_body` through when nothing else is running.
    fn budgetLeft(c: *const Conn, s: *const Stream) usize {
        return c.budget() -| (c.collected - s.held);
    }

    /// Whether this call's window may be topped up now: while the connection
    /// is under its budget, and otherwise for the oldest call still arriving,
    /// so that one call can always finish and give its bytes back. Without
    /// that, calls that each took their first window between them could
    /// fill the budget with none of them able to end.
    ///
    /// **Not while a call that has started still holds bytes.** That one
    /// gives them back with nothing more from the client, so waiting on it
    /// cannot stall; topping up past it let each call to a slow route become
    /// the oldest in turn and hold a whole message, a hundred of them
    /// (ADR 220). A call waiting for room counts as started here: it needs
    /// nothing more from the client either, and `admitWaiting` always lets
    /// the oldest one start once no running call holds bytes.
    fn mayGrow(c: *const Conn, s: *const Stream) bool {
        if (c.collected < c.budget() or s.body_over_limit) return true;
        for (c.streams.items) |x| {
            if (x.state != .headers and x.state != .body and x.held > 0) return false;
        }
        for (c.streams.items) |x| if (x.state == .body) return x == s;
        return false;
    }

    /// Top up the windows the budget held back, oldest call first, once
    /// bytes have been given back.
    fn grantWaiting(c: *Conn) ReadError!void {
        if (c.starved == 0) return;
        for (c.streams.items) |s| {
            if (!s.starved) continue;
            if (!c.mayGrow(s)) break;
            h2.writeWindowUpdate(c.out, s.id, @intCast(s.unacked)) catch return error.Gone;
            s.recv_window += s.unacked;
            s.unacked = 0;
            s.starved = false;
            c.starved -= 1;
        }
    }

    /// A call has been let go of: answered, refused or reset. Its bytes
    /// leave the budget. **Not when it starts**: a running call still holds
    /// its message, and the copies made of it, until its answer is written,
    /// and giving them back at the start let a hundred calls to a slow route
    /// hold a hundred messages while the budget said one (ADR 220).
    fn letGo(c: *Conn, s: *Stream) void {
        c.collected -= s.held;
        s.held = 0;
        c.unstarve(s);
    }

    /// The call is no longer waiting for room: it is starting, answered
    /// without running, or reset. Nothing for a call in any other state.
    fn leaveWaiting(c: *Conn, s: *Stream) void {
        if (s.state != .waiting) return;
        s.state = .body;
        c.waiting -= 1;
    }

    /// Whether a call that has started still holds bytes it will give back
    /// with nothing more from the client: running, or its answer being
    /// written.
    fn startedHolds(c: *const Conn) bool {
        for (c.streams.items) |x| {
            if ((x.state == .running or x.state == .writing) and x.held > 0) return true;
        }
        return false;
    }

    /// Start the calls waiting for room, oldest first, for as long as each
    /// one's inflated copy fits in what the budget has left. **The oldest
    /// starts whatever the room once no started call holds bytes**: nothing
    /// else would give any back, since the other waiting calls hold only
    /// their compressed bytes and the calls still arriving are held to their
    /// windows, so without it a few waiting calls could fill the budget with
    /// none able to start. That is the same rule `mayGrow` keeps for the
    /// oldest call still arriving, and it bounds the connection at the
    /// budget and one more call's copies. Strictly in order: a call that
    /// fits does not pass one that does not, or a stream of small calls
    /// would keep a large one waiting for good. How many started.
    fn admitWaiting(c: *Conn) ReadError!usize {
        var started: usize = 0;
        while (c.waiting != 0) {
            const s = for (c.streams.items) |x| {
                if (x.state == .waiting) break x;
            } else unreachable;
            // Read once already, by `dispatch`, from the same bytes.
            const announced = encoded.announcedSize(s.body.items[5..]) catch unreachable;
            if (announced > c.budgetLeft(s) and c.startedHolds()) break;
            c.leaveWaiting(s);
            try c.start(s, announced);
            started += 1;
        }
        return started;
    }

    /// The call is no longer waiting on a window: it has started, or it has
    /// been let go of.
    fn unstarve(c: *Conn, s: *Stream) void {
        if (s.starved) {
            s.starved = false;
            c.starved -= 1;
        }
    }

    /// Count `n` more bytes the call holds against the connection's budget,
    /// until `letGo`.
    fn hold(c: *Conn, s: *Stream, n: usize) void {
        s.held += n;
        c.collected += n;
    }

    /// Top the connection's window back up once half of it has been read.
    fn consumed(c: *Conn, n: usize) ReadError!void {
        c.unacked += @intCast(n);
        if (c.unacked >= h2.default_window / 2) {
            h2.writeWindowUpdate(c.out, 0, @intCast(c.unacked)) catch return error.Gone;
            c.recv_window += c.unacked;
            c.unacked = 0;
        }
    }

    fn onSettings(c: *Conn, head: h2.Header) ReadError!void {
        if (head.stream != 0) return error.Protocol;
        if (head.has(h2.Flags.ack)) {
            if (head.len != 0) return error.FrameSize;
            // The client has read ours: the table it may use is now 0.
            c.decoder.allow(0);
            return;
        }
        if (head.len % 6 != 0) return error.FrameSize;
        try c.control();
        var left = head.len / 6;
        while (left > 0) : (left -= 1) {
            const pair = try c.take(6);
            const id: h2.Setting = @enumFromInt(std.mem.readInt(u16, pair[0..2], .big));
            const value = std.mem.readInt(u32, pair[2..6], .big);
            switch (id) {
                .initial_window_size => {
                    if (value > h2.max_window) return error.FlowControl;
                    const delta = @as(i64, value) - c.peer_window;
                    c.peer_window = value;
                    // A change that lifts any window past 2^31-1 is a
                    // connection error (§6.9.2).
                    for (c.streams.items) |s| {
                        s.send_window += delta;
                        if (s.send_window > h2.max_window) return error.FlowControl;
                    }
                },
                .max_frame_size => {
                    if (value < h2.default_max_frame or value > 16_777_215) return error.Protocol;
                    c.peer_max_frame = value;
                },
                .enable_push => if (value > 1) return error.Protocol,
                // What the client's table for *our* headers may be. This side
                // never indexes, so there is nothing to shrink.
                else => {},
            }
        }
        h2.writeSettingsAck(c.out) catch return error.Gone;
    }

    fn onWindowUpdate(c: *Conn, head: h2.Header) ReadError!void {
        if (head.len != 4) return error.FrameSize;
        const bytes = try c.take(4);
        const increment = std.mem.readInt(u32, bytes[0..4], .big) & 0x7fff_ffff;
        // A client reading an answer sends these as it goes, so one while an
        // answer is being written is progress. One with nothing on the way
        // is not.
        if (!c.writing()) try c.control();
        if (head.stream == 0) {
            if (increment == 0) return error.Protocol;
            c.send_window += increment;
            if (c.send_window > h2.max_window) return error.FlowControl;
            return;
        }
        // A stream not opened yet is idle, and a frame other than HEADERS or
        // PRIORITY on one is a connection error (§5.1).
        if (head.stream > c.last_stream) return error.Protocol;
        const s = c.find(head.stream) orelse return;
        // Already reset and still running: its answer is going nowhere, and
        // an RST for every update would be the client making this side write.
        if (s.reset) return;
        if (increment == 0) {
            h2.writeRstStream(c.out, s.id, .protocol_error) catch return error.Gone;
            c.onReset(s);
            return;
        }
        s.send_window += increment;
        if (s.send_window > h2.max_window) {
            h2.writeRstStream(c.out, s.id, .flow_control_error) catch return error.Gone;
            c.onReset(s);
        }
    }

    fn onReset(c: *Conn, s: *Stream) void {
        switch (s.state) {
            // Its fiber owns it until it hands it back; the answer is
            // dropped then.
            .running => s.reset = true,
            // Still arriving or already written: what it held of the
            // budget goes back now, or `collected` keeps a dead call's
            // bytes for the life of the connection and the calls beside it
            // wait on a window nothing is left to give back (ADR 220).
            else => {
                c.leaveWaiting(s);
                c.letGo(s);
                c.remove(s);
                s.destroy();
            },
        }
    }

    fn writing(c: *const Conn) bool {
        for (c.streams.items) |s| if (s.state == .writing) return true;
        return false;
    }

    fn find(c: *const Conn, id: u31) ?*Stream {
        for (c.streams.items) |s| if (s.id == id) return s;
        return null;
    }

    fn remove(c: *Conn, s: *Stream) void {
        for (c.streams.items, 0..) |x, i| if (x == s) {
            _ = c.streams.orderedRemove(i);
            return;
        };
    }

    /// Take a stream out of the connection's hands for good.
    fn forget(c: *Conn, s: *Stream) void {
        c.letGo(s);
        c.remove(s);
        if (c.spares >= max_streams or c.goaway_sent) return s.destroy();
        s.recycle();
        s.next = c.spare;
        c.spare = s;
        c.spares += 1;
    }

    // ---- starting a call ----

    /// The client has sent everything. Check the request, and run it: as HTTP,
    /// or, when its content type says it is a gRPC call, with its message
    /// taken out of its framing (ADR 259).
    fn dispatch(c: *Conn, s: *Stream) ReadError!void {
        c.unstarve(s);
        const a = s.arena.allocator();
        if (s.headers_over_limit) {
            if (!s.grpc) return c.answerStatus(s, 431, "the request's header fields are larger than this server reads");
            return c.answerNow(s, 8, "the call's metadata is larger than this server reads");
        }
        if (s.body_over_limit) {
            if (!s.grpc) return c.answerStatus(s, 413, "the request body is larger than its route's limit");
            return c.answerNow(s, 8, "the message is larger than its route's body limit");
        }

        // Held to RFC 9113 §8 before anything reads it: a request that is not
        // well formed is a stream error and never reaches the App.
        for (s.fields.items) |f| if (!validField(f)) return c.malformed(s);
        const method = s.field(":method") orelse return c.malformed(s);
        if (std.mem.eql(u8, method, "CONNECT")) {
            // A tunnel is not a thing this server is: no `:path`, no route,
            // and extended CONNECT is not offered (RFC 9110 §9.3.6, §15.6.2).
            c.control_run = 0;
            return c.answerStatus(s, 501, "this server does not serve CONNECT");
        }
        const path = s.field(":path") orelse return c.malformed(s);
        if (s.grpc and !std.mem.eql(u8, method, "POST")) return c.malformed(s);
        // `OPTIONS *` is the one target that is not a path, and the empty
        // `:path` is malformed (§8.3.1).
        if (path.len == 0 or (path[0] != '/' and !(std.mem.eql(u8, method, "OPTIONS") and std.mem.eql(u8, path, "*"))))
            return c.malformed(s);
        if (!validPseudo(s.fields.items)) return c.malformed(s);
        if (!validConnectionFields(s.fields.items)) return c.malformed(s);
        if (!lengthAgrees(s.fields.items, s.body.items.len)) return c.malformed(s);

        // A well-formed request, answered or run: what ends a run of frames
        // that moved nothing forward. Not before this point, where a request
        // refused as malformed would end it for the cost of one HEADERS
        // frame, and 999 PINGs between two of them would never be a flood.
        c.control_run = 0;

        if (!s.grpc) return c.start(s, null);
        if (!c.app.routes(c.app.ptr, path))
            return c.answerNow(s, 12, "no route answers this method");
        if (s.field("grpc-timeout")) |text| {
            s.until_ns = grpc.untilNs(text, s.headers_ns) catch return c.refuse(s, grpc.bad_timeout);
        }

        switch (grpc.envelope(s.body.items, s.field("grpc-encoding"))) {
            .refused => |r| return c.refuse(s, r),
            .identity => return c.start(s, null),
            .unsupported => {
                s.head_block = grpc.unsupportedEncoding(a) catch return error.Internal;
                s.trailers_only = true;
                return c.ready(s);
            },
            .gzip => {},
        }
        // The inflated copy is charged to the budget **before** it is
        // allocated, by the size the stream announces, and `inflate` is
        // held to that size: so what the connection holds is what the
        // budget counted, and a hundred calls that each inflate to
        // `max_body` are not a hundred `max_body`s (ADR 220). Room is
        // what the other calls hold subtracted from the budget, so a call
        // alone on its connection always has all of it.
        const announced = encoded.announcedSize(s.body.items[grpc.prefix_len..]) catch
            return c.answerNow(s, 13, "the message's gzip could not be read");
        if (announced > s.limit)
            return c.answerNow(s, 8, "the message is larger than its route's body limit");
        // No room: the call waits with only its compressed bytes, and
        // starts when the calls ahead of it give room back. It used to be
        // refused UNAVAILABLE, which a Collector retries only after its
        // backoff: with ten consumers on one connection its queue grew
        // while the server sat idle (ADR 220). Behind another waiting
        // call even if it fits, so the oldest is never passed.
        if (c.waiting != 0 or announced > c.budgetLeft(s)) {
            s.state = .waiting;
            c.waiting += 1;
            return;
        }
        return c.start(s, announced);
    }

    /// Run a call whose message is whole and checked: inflate it first if
    /// `announced` is the size its gzip says it inflates to. Whatever fails
    /// from here, `letGo` gives what the call was charged back with the rest.
    fn start(c: *Conn, s: *Stream, announced: ?usize) ReadError!void {
        const a = s.arena.allocator();
        var message: []const u8 = if (s.grpc) s.body.items[grpc.prefix_len..] else s.body.items;
        if (announced) |size| {
            c.hold(s, size);
            message = encoded.inflate(a, message, size) catch |err| switch (err) {
                error.BodyTooLarge => return c.answerNow(s, 8, "the message is larger than its route's body limit"),
                else => return c.answerNow(s, 13, "the message's gzip could not be read"),
            };
        }
        // The route's `c.body()` reads the message into the arena once
        // more, for as long as the call runs.
        c.hold(s, message.len);
        s.body.items = @constCast(message);
        s.state = .running;
        _ = s.shared.running.fetchAdd(1, .acquire);
        s.shared.retain();
        bulkhead.spawnLocal(runCall, .{ s, true }) catch |err| switch (err) {
            // No server: a test driving the connection through buffers. The
            // call runs here, and is queued exactly as a fiber would queue it.
            error.NoServer => runCall(s, false),
            // The server is stopping, and has nowhere to put a fiber.
            else => {
                _ = s.shared.running.fetchSub(1, .release);
                s.shared.drop();
                s.state = .body;
                return c.answerNow(s, 14, "the server is stopping");
            },
        };
    }

    /// A request that is not a well-formed HTTP/2 one: a stream error, and
    /// nothing else (§8.1.1).
    fn malformed(c: *Conn, s: *Stream) ReadError!void {
        h2.writeRstStream(c.out, s.id, .protocol_error) catch return error.Gone;
        c.forget(s);
    }

    inline fn refuse(c: *Conn, s: *Stream, r: grpc.Refusal) ReadError!void {
        return c.answerNow(s, r.code, r.message);
    }

    /// Answer without running anything: one HEADERS frame carrying the
    /// status, which is what gRPC calls Trailers-Only.
    fn answerNow(c: *Conn, s: *Stream, code: u8, message: []const u8) ReadError!void {
        s.head_block = grpc.trailersOnly(s.arena.allocator(), code, .{ .ours = message }) catch return error.Internal;
        s.trailers_only = true;
        return c.ready(s);
    }

    /// Answer as HTTP without running anything: a status and the failure
    /// body every refusal of the App's own carries (ADR 024), for what is
    /// refused before there is a route to ask.
    fn answerStatus(c: *Conn, s: *Stream, comptime status: u16, comptime message: []const u8) ReadError!void {
        const body = comptime std.fmt.comptimePrint("{{\"error\":\"{s}\",\"status\":{d}}}", .{ message, status });
        var w: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(s.arena.allocator(), 96) catch return error.Internal;
        writeHttpHead(&w.writer, status, "application/json", body.len, &.{}) catch return error.Internal;
        s.head_block = w.written();
        s.data = body;
        s.no_trailers = true;
        return c.ready(s);
    }

    fn ready(c: *Conn, s: *Stream) ReadError!void {
        s.state = .writing;
        _ = c.writeStream(s) catch return error.Gone;
    }

    fn headerBlock(c: *Conn, a: std.mem.Allocator, fields: []const hpack.Field) ReadError![]const u8 {
        _ = c;
        return hpack.encodeBlock(a, fields) catch return error.Internal;
    }

    // ---- writing ----

    /// Take the answered calls off the queue and write every answer as far
    /// as the windows let it go.
    fn writeReady(c: *Conn) !void {
        var answered = c.shared.takeAll();
        while (answered) |s| {
            answered = s.next;
            s.next = null;
            if (s.reset) {
                c.forget(s);
                continue;
            }
            s.state = .writing;
        }
        var i: usize = 0;
        var blocked = false;
        while (i < c.streams.items.len) {
            const s = c.streams.items[i];
            if (s.state != .writing) {
                i += 1;
                continue;
            }
            if (try c.writeStream(s)) continue;
            blocked = true;
            i += 1;
        }
        if (blocked) {
            if (c.blocked_since == 0) c.blocked_since = bulkhead.monotonicNanos();
        } else c.blocked_since = 0;
    }

    /// Write as much of one answer as the windows allow. True when it is all
    /// gone and the stream has been let go of.
    fn writeStream(c: *Conn, s: *Stream) !bool {
        if (!s.head_sent) {
            try h2.writeHeaderBlock(c.out, s.id, s.head_block, s.trailers_only, c.peer_max_frame);
            s.head_sent = true;
            if (s.trailers_only) {
                c.forget(s);
                return true;
            }
        }
        while (s.data_sent < s.data.len) {
            const room = @min(c.send_window, s.send_window);
            if (room <= 0) return false;
            const n: usize = @intCast(@min(@as(i64, @intCast(s.data.len - s.data_sent)), room, c.peer_max_frame));
            const last = s.no_trailers and s.data_sent + n == s.data.len;
            try h2.writeHeader(c.out, n, .data, if (last) h2.Flags.end_stream else 0, s.id);
            try c.out.writeAll(s.data[s.data_sent..][0..n]);
            s.data_sent += n;
            c.send_window -= @intCast(n);
            s.send_window -= @intCast(n);
        }
        if (!s.no_trailers) try h2.writeHeaderBlock(c.out, s.id, s.trailers, true, c.peer_max_frame);
        c.forget(s);
        return true;
    }
};

// ---- the call's fiber ----

/// One call, run through the App as a request of its own, and its answer
/// turned back into frames. On a fiber of its own; everything it touches is
/// the stream's, until `finish` hands the stream back.
fn runCall(s: *Stream, on_engine: bool) void {
    const shared = s.shared;
    defer shared.finish(s);

    // The box a fail function writes into, bound to this fiber the way a
    // connection binds its own (ADR 006). With no Engine there is no fiber
    // to bind to, and the fallback slot is the one a test uses.
    var in_flight = fail.InFlight{};
    var binding = bulkhead.binding_unset;
    var previous: ?*anyopaque = null;
    if (on_engine) bulkhead.bindSlot(&binding, &in_flight) else previous = bulkhead.setFallbackSlot(&in_flight);
    defer if (on_engine) bulkhead.unbindSlot(&binding) else {
        _ = bulkhead.setFallbackSlot(previous);
    };

    answer(s, &in_flight) catch {
        if (s.grpc) {
            s.head_block = grpc.trailersOnly(s.arena.allocator(), 13, .{ .ours = "the server could not build its answer" }) catch "";
        } else {
            // `:status 500` from the static table, and the stream ended.
            s.head_block = "\x8e";
        }
        s.trailers_only = true;
    };
}

fn answer(s: *Stream, in_flight: *fail.InFlight) !void {
    const a = s.arena.allocator();
    const call: framing.Call = .{
        .method = s.field(":method").?,
        .target = s.field(":path").?,
        .head = try fieldHead(a, s),
        .body = s.body.items,
    };

    var lifetime = core.Lifetime.init();
    defer lifetime.deinit();
    // A call has five bytes in front of its body, so the message is framed
    // where it lies and held once for as long as the client's window keeps
    // it. Any other request is answered as HTTP, and a route's headers kept
    // as whole lines are read into fields for it.
    var collected: framing.Collected = .{ .arena = a, .front = if (s.grpc) grpc.prefix_len else 0, .lines = !s.grpc };
    s.app.handle(s.app.ptr, a, &lifetime, in_flight, call, &collected, s.peer, s.until_ns);
    lifetime.end();
    if (!s.grpc) return httpReply(s, &collected);
    const reply = try grpc.fromCollected(a, &collected, s.until_ns);
    s.head_block = reply.head_block;
    s.data = reply.data;
    s.trailers = reply.trailers;
    s.trailers_only = reply.trailers_only;
}

/// What a route answered, as an HTTP/2 answer: the head the route's status,
/// type, length and headers make, the body, and the trailers the route set
/// (ADR 254, ADR 259). A HEAD has the head a GET would, `content-length`
/// included, and no body to send.
fn httpReply(s: *Stream, collected: *const framing.Collected) !void {
    const a = s.arena.allocator();
    var extra: usize = 0;
    for (collected.headers) |f| extra += f.name.len + f.value.len + 4;
    var w: std.Io.Writer.Allocating = try .initCapacity(a, 96 + collected.content_type.len + extra);
    try writeHttpHead(&w.writer, if (collected.status == 0) 500 else collected.status, collected.content_type, collected.length, collected.headers);
    s.head_block = w.written();
    s.data = collected.body;
    if (collected.trailers.len > 0) {
        var fields: std.ArrayList(hpack.Field) = .empty;
        for (collected.trailers) |t| try fields.append(a, .{ .name = t.name, .value = t.value });
        s.trailers = try hpack.encodeBlock(a, fields.items);
    } else if (s.data.len == 0) {
        // The head is the whole answer, and ends the stream.
        s.trailers_only = true;
    } else s.no_trailers = true;
}

/// The head of an HTTP answer: `:status`, the content type when there is
/// one, `content-length` when the answer has a body to measure, the route's
/// headers with the ones HTTP/2 forbids dropped (§8.2.2), and `date` unless
/// the route said its own (ADR 197).
fn writeHttpHead(w: *std.Io.Writer, status: u16, content_type: []const u8, length: ?u64, headers: []const framing.Header) !void {
    // The seven statuses the static table has (RFC 7541 Appendix A), and a
    // literal for the rest.
    switch (status) {
        200 => try hpack.writeIndexed(w, 8),
        204 => try hpack.writeIndexed(w, 9),
        206 => try hpack.writeIndexed(w, 10),
        304 => try hpack.writeIndexed(w, 11),
        400 => try hpack.writeIndexed(w, 12),
        404 => try hpack.writeIndexed(w, 13),
        500 => try hpack.writeIndexed(w, 14),
        else => {
            var text: [5]u8 = undefined;
            try hpack.writeLiteral(w, ":status", std.fmt.bufPrint(&text, "{d}", .{status}) catch unreachable);
        },
    }
    if (content_type.len > 0) try hpack.writeLiteral(w, "content-type", content_type);
    if (length) |n| {
        var text: [20]u8 = undefined;
        try hpack.writeLiteral(w, "content-length", std.fmt.bufPrint(&text, "{d}", .{n}) catch unreachable);
    }
    var dated = false;
    for (headers) |f| {
        if (h2.hopByHop(f.name) or std.mem.eql(u8, f.name, "content-length")) continue;
        if (std.mem.eql(u8, f.name, "date")) dated = true;
        try hpack.writeLiteral(w, f.name, f.value);
    }
    if (!dated) {
        const now = date.now();
        try hpack.writeLiteral(w, "date", &now);
    }
}

/// The call's fields as the head `framing.Call` asks for: an empty request
/// line, `:authority` as `host`, the metadata, and the length of the one
/// message. The method and path are handed over as they are, and the message
/// is not copied into this; what was a whole HTTP/1.1 request, body and all,
/// for the App to parse back, is now only what it reads headers from.
fn fieldHead(a: std.mem.Allocator, s: *const Stream) ![]const u8 {
    var size: usize = "\nhost: localhost\r\ncontent-length: 4294967295\r\n\r\n".len;
    for (s.fields.items) |f| size += f.name.len + f.value.len + 4;
    var w: std.Io.Writer.Allocating = try .initCapacity(a, size);
    const out = &w.writer;
    try out.writeByte('\n');
    // One `host`, which `http1.zig` insists on: `:authority` when the call
    // has it, over a `host` field beside it (§8.3.1).
    const authority = s.field(":authority");
    if (authority) |host| {
        try out.writeAll("host: ");
        try out.writeAll(host);
        try out.writeAll("\r\n");
    } else if (s.field("host") == null) {
        try out.writeAll("host: localhost\r\n");
    }
    // The cookies a client splits for compression are one again, `; ` between
    // them (§8.2.3).
    var cookies = false;
    for (s.fields.items) |f| if (std.mem.eql(u8, f.name, "cookie")) {
        try out.writeAll(if (cookies) "; " else "cookie: ");
        try out.writeAll(f.value);
        cookies = true;
    };
    if (cookies) try out.writeAll("\r\n");
    for (s.fields.items) |f| {
        if (f.name.len == 0 or f.name[0] == ':') continue;
        if (authority != null and std.mem.eql(u8, f.name, "host")) continue;
        if (h2.hopByHop(f.name)) continue;
        if (std.mem.eql(u8, f.name, "cookie")) continue;
        if (std.mem.eql(u8, f.name, "content-length")) continue;
        // The whole message is already here, so there is nothing to wait
        // for leave to send.
        if (std.mem.eql(u8, f.name, "expect")) continue;
        try out.writeAll(f.name);
        try out.writeAll(": ");
        try out.writeAll(f.value);
        try out.writeAll("\r\n");
    }
    try out.print("content-length: {d}\r\n\r\n", .{s.body.items.len});
    return w.written();
}


/// The pseudo-headers of a request as §8.3.1 and §8.1.1 have them: only
/// `:method`, `:scheme`, `:path` and `:authority`, each at most once, all of
/// them ahead of the regular fields, and the first three present. Anything
/// else is a malformed request, which is a stream error and not a call.
fn validPseudo(fields: []const hpack.Field) bool {
    const names = [_][]const u8{ ":method", ":scheme", ":path", ":authority" };
    var seen = [_]bool{false} ** names.len;
    var regular = false;
    for (fields) |f| {
        if (f.name.len == 0 or f.name[0] != ':') {
            regular = true;
            continue;
        }
        if (regular) return false;
        const i = for (names, 0..) |n, i| {
            if (std.mem.eql(u8, n, f.name)) break i;
        } else return false;
        if (seen[i]) return false;
        seen[i] = true;
    }
    return seen[0] and seen[1] and seen[2];
}


/// The stream a PRIORITY frame's five bytes say the stream depends on,
/// without the exclusive bit (§6.3).
fn dependsOn(five: *const [5]u8) u32 {
    return std.mem.readInt(u32, five[0..4], .big) & 0x7fff_ffff;
}

/// Whether no field is one HTTP/2 forbids for belonging to a connection:
/// `connection`, `keep-alive`, `proxy-connection`, `transfer-encoding` and
/// `upgrade`, and `te` with anything but `trailers` (§8.2.2). A request that
/// has one is malformed.
fn validConnectionFields(fields: []const hpack.Field) bool {
    for (fields) |f| {
        if (f.name.len == 0 or f.name[0] == ':') continue;
        inline for (.{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade" }) |forbidden| {
            if (std.mem.eql(u8, f.name, forbidden)) return false;
        }
        if (std.mem.eql(u8, f.name, "te") and !std.ascii.eqlIgnoreCase(f.value, "trailers")) return false;
    }
    return true;
}

/// Whether every `content-length` is a number and is the length of the DATA
/// that arrived (§8.1.1): a request whose says otherwise is malformed.
fn lengthAgrees(fields: []const hpack.Field, received: usize) bool {
    for (fields) |f| {
        if (!std.mem.eql(u8, f.name, "content-length")) continue;
        if (f.value.len == 0) return false;
        for (f.value) |ch| if (ch < '0' or ch > '9') return false;
        const n = std.fmt.parseInt(u64, f.value, 10) catch return false;
        if (n != received) return false;
    }
    return true;
}

/// A field that can be written into a head as it is: a lowercase token for a
/// name, and a value with no line break and no NUL in it. What makes writing
/// a call's fields as a head safe; a field that is not this is a malformed
/// request (§8.2.1), refused before anything reads it.
fn validField(f: hpack.Field) bool {
    if (f.name.len == 0) return false;
    const name = if (f.name[0] == ':') f.name[1..] else f.name;
    if (name.len == 0) return false;
    for (name) |ch| switch (ch) {
        'a'...'z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    for (f.value) |ch| if (ch == 0 or ch == '\r' or ch == '\n') return false;
    return true;
}

// ---- tests ----

const testing = std.testing;

test "a field is valid when its name is a lowercase token and its value has no line break" {
    try testing.expect(validField(.{ .name = "x-trace", .value = "abc" }));
    try testing.expect(validField(.{ .name = ":path", .value = "/a" }));
    try testing.expect(!validField(.{ .name = "X-Trace", .value = "abc" }));
    try testing.expect(!validField(.{ .name = "x-trace", .value = "a\r\nb" }));
    try testing.expect(!validField(.{ .name = ":", .value = "a" }));
}

test "pseudo-headers are the four, once each, ahead of the regular fields, the first three present" {
    const ok = [_]hpack.Field{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/a" },
        .{ .name = "te", .value = "trailers" },
    };
    try testing.expect(validPseudo(&ok));
    try testing.expect(!validPseudo(ok[0..2]));
    try testing.expect(!validPseudo(&.{ ok[0], ok[3], ok[1], ok[2] }));
    try testing.expect(!validPseudo(&.{ ok[0], ok[0], ok[1], ok[2] }));
}

const ctx_mod = @import("ctx.zig");
const App = @import("app.zig").App;
const Ctx = ctx_mod.Ctx;
const h2test = @import("h2test.zig");
const TestClient = h2test.TestClient;
const Answer = h2test.Answer;
const converse = h2test.converse;
const converseFrom = h2test.converseFrom;
const answerOf = h2test.answerOf;

fn echoRoute(c: *Ctx) anyerror!void {
    const body = try c.body();
    try c.send(200, "application/grpc", body.view());
}

fn missingRoute(_: *Ctx) anyerror!void {
    return fail.notFound("no such order", .{});
}

/// A route saying its own status, with a message it encoded itself.
fn refusingRoute(c: *Ctx) anyerror!void {
    try c.setTrailer("grpc-status", "9");
    try c.setTrailer("grpc-message", "caf%C3%A9 is 50%25 off");
    try c.send(200, "application/grpc", "");
}

/// A unique violation, the way `nilo_sql` reports one.
fn duplicateRoute(_: *Ctx) anyerror!void {
    return error.AlreadyExists;
}

/// A transaction given up to keep the ones beside it consistent.
fn rolledBackRoute(_: *Ctx) anyerror!void {
    return error.RolledBack;
}

/// A trailer of the route's own beside the message, and one on a failure.
fn trailerRoute(c: *Ctx) anyerror!void {
    try c.setTrailer("x-checked", "yes");
    if ((try c.body()).view().len == 0) return fail.notFound("nothing to check", .{});
    try c.send(200, "application/grpc", "ok");
}

fn metadataRoute(c: *Ctx) anyerror!void {
    const who = if (c.header("x-caller")) |v| v.view() else "nobody";
    try c.setHeader("x-seen", who);
    try c.send(200, "application/grpc", "");
}

/// Answers the way `nilo.deadline` does when the clock has run out.
fn clockRoute(c: *Ctx) anyerror!void {
    if (c.overdue()) return fail.status(503, "out of time", .{});
    try c.send(200, "application/grpc", "");
}

const SumRequest = struct {
    pub const wire = .{ .a = 1, .b = 2 };
    a: i32 = 0,
    b: i32 = 0,
};

const SumReply = struct {
    pub const wire = .{ .total = 1 };
    total: i32 = 0,
};

/// A service of typed functions: its message read, and its answer written,
/// by the type (ADR 256), and `sum` served as `/test.Math/Sum` (ADR 258).
const Math = struct {
    pub const nilo_service = "test.Math";

    pub fn sum(in: SumRequest) SumReply {
        return .{ .total = in.a + in.b };
    }
};

fn testApp() !App {
    var app = App.init(testing.allocator);
    errdefer app.deinit();
    try app.post("/test.Echo/Say", echoRoute);
    try app.rpc(Math);
    try app.post("/test.Orders/Get", missingRoute);
    try app.post("/test.Meta/Who", metadataRoute);
    try app.post("/test.Clock/Check", clockRoute);
    try app.post("/test.Status/Refuse", refusingRoute);
    try app.post("/test.Orders/Duplicate", duplicateRoute);
    try app.post("/test.Orders/RolledBack", rolledBackRoute);
    try app.post("/test.Orders/Check", trailerRoute);
    try app.resolveChains();
    return app;
}

test "a unary call reaches its route as a POST, and its answer comes back framed with grpc-status 0" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Echo/Say", "hello over h2c");

    var got = try converse(&app, &client);
    defer got.deinit();
    const head = try got.fields(Answer.of(.headers, &got, 1)[0].payload);
    try testing.expectEqualStrings("200", Answer.value(head, ":status").?);
    try testing.expectEqualStrings("application/grpc", Answer.value(head, "content-type").?);
    try testing.expectEqualStrings("hello over h2c", try got.message(1));
    const trailers = try got.trailers(1);
    try testing.expectEqualStrings("0", Answer.value(trailers, "grpc-status").?);
}

test "a method of a service of typed functions reads its message and answers one, with no proto call in it" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Math/Sum", "\x08\x01\x10\x02");
    // A key with nothing after it: not a SumRequest.
    try client.call(3, "/test.Math/Sum", "\x08");

    var got = try converse(&app, &client);
    defer got.deinit();
    const head = try got.fields(Answer.of(.headers, &got, 1)[0].payload);
    try testing.expectEqualStrings("application/grpc", Answer.value(head, "content-type").?);
    try testing.expectEqualStrings("\x08\x03", try got.message(1));
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);

    const refused = try got.trailers(3);
    try testing.expectEqualStrings("3", Answer.value(refused, "grpc-status").?);
    try testing.expect(std.mem.indexOf(u8, Answer.value(refused, "grpc-message").?, "not a protobuf") != null);
}

test "the server's own SETTINGS ask for an HPACK table of 0, and cap the calls at max_streams" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();

    var got = try converse(&app, &client);
    defer got.deinit();
    const settings = got.frames.items[0];
    try testing.expectEqual(h2.Type.settings, settings.head.type);
    var saw_table = false;
    var saw_cap = false;
    var i: usize = 0;
    while (i < settings.payload.len) : (i += 6) {
        const id: h2.Setting = @enumFromInt(std.mem.readInt(u16, settings.payload[i..][0..2], .big));
        const v = std.mem.readInt(u32, settings.payload[i + 2 ..][0..4], .big);
        if (id == .header_table_size) {
            try testing.expectEqual(@as(u32, 0), v);
            saw_table = true;
        }
        if (id == .max_concurrent_streams) {
            try testing.expectEqual(@as(u32, max_streams), v);
            saw_cap = true;
        }
    }
    try testing.expect(saw_table and saw_cap);
}

test "a path no route answers is UNIMPLEMENTED, said in one HEADERS frame" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Nowhere/Nothing", "x");

    var got = try converse(&app, &client);
    defer got.deinit();
    const hs = Answer.of(.headers, &got, 1);
    try testing.expectEqual(@as(usize, 1), hs.len);
    try testing.expect(hs[0].head.has(h2.Flags.end_stream));
    try testing.expectEqualStrings("12", Answer.value(try got.fields(hs[0].payload), "grpc-status").?);
    try testing.expectEqual(@as(usize, 0), Answer.of(.data, &got, 1).len);
}

test "a route that fails with 404 is NOT_FOUND, and what it said is grpc-message" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Orders/Get", "x");

    const previous = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = previous;
    var got = try converse(&app, &client);
    defer got.deinit();
    const trailers = try got.trailers(1);
    try testing.expectEqualStrings("5", Answer.value(trailers, "grpc-status").?);
    try testing.expectEqualStrings("no such order", Answer.value(trailers, "grpc-message").?);
}

test "a call's metadata reaches the route as headers, and the route's headers come back as metadata" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Meta/Who", &.{.{ .name = "x-caller", .value = "the collector" }}, false);
    try client.message(1, "", false);

    var got = try converse(&app, &client);
    defer got.deinit();
    const head = try got.fields(Answer.of(.headers, &got, 1)[0].payload);
    try testing.expectEqualStrings("the collector", Answer.value(head, "x-seen").?);
}

test "a gzipped message reaches the route inflated" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();

    var zipped: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer zipped.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress: std.compress.flate.Compress = try .init(&zipped.writer, &window, .gzip, .default);
    try compress.writer.writeAll("squeezed " ** 20);
    try compress.finish();

    try client.headersFor(1, "/test.Echo/Say", &.{.{ .name = "grpc-encoding", .value = "gzip" }}, false);
    try client.message(1, zipped.written(), true);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("squeezed " ** 20, try got.message(1));
}

test "a compressed message in an encoding this server does not read is UNIMPLEMENTED" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Echo/Say", &.{.{ .name = "grpc-encoding", .value = "snappy" }}, false);
    try client.message(1, "whatever", true);

    var got = try converse(&app, &client);
    defer got.deinit();
    const trailers = try got.trailers(1);
    try testing.expectEqualStrings("12", Answer.value(trailers, "grpc-status").?);
    // And says which it does read, so the client can send again in one.
    try testing.expectEqualStrings("identity,gzip", Answer.value(trailers, "grpc-accept-encoding").?);
}

/// `n` bytes of one message's DATA on `stream`, in frames of 16,000, the
/// first starting with the length prefix of a message `total` bytes long.
fn sendPart(client: *TestClient, stream: u31, n: usize, total: ?u32, end: bool) !void {
    var left = n;
    var first = total != null;
    while (left > 0) {
        const len = @min(left, 16_000);
        left -= len;
        try h2.writeHeader(client.w(), len, .data, if (end and left == 0) h2.Flags.end_stream else 0, stream);
        var written: usize = 0;
        if (first) {
            try client.w().writeByte(0);
            var prefix: [4]u8 = undefined;
            std.mem.writeInt(u32, &prefix, total.?, .big);
            try client.w().writeAll(&prefix);
            written = 5;
            first = false;
        }
        try client.w().splatByteAll('m', len - written);
    }
}

fn windowUpdateAt(got: *const Answer, stream: u31) ?usize {
    for (got.frames.items, 0..) |f, i| if (f.head.type == .window_update and f.head.stream == stream) return i;
    return null;
}

test "calls still arriving hold one max_body between them, and the rest wait on their windows" {
    var app = try testApp();
    defer app.deinit();
    app.limits.max_body = 200_000;
    var client = try TestClient.init();
    defer client.deinit();

    // Four calls of 64,000 bytes each, inside the window every call opens
    // with. The fourth takes the connection past its budget, so its window
    // is not topped up: the client would have to wait on it.
    for ([_]u31{ 1, 3, 5, 7 }) |id| {
        try client.headersFor(id, "/test.Echo/Say", &.{}, false);
        try sendPart(&client, id, 64_000, 79_995, false);
    }
    // The first call ends and runs. Its bytes go back once its answer has
    // been written, which takes a client reading it: the answer is larger
    // than the window it is sent under.
    try sendPart(&client, 1, 16_000, null, true);
    try h2.writeWindowUpdate(client.w(), 0, 100_000);
    try h2.writeWindowUpdate(client.w(), 1, 100_000);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expect(windowUpdateAt(&got, 1) != null);
    try testing.expect(windowUpdateAt(&got, 3) != null);
    try testing.expect(windowUpdateAt(&got, 5) != null);
    // Stream 7 is topped up, but only once stream 1 was answered.
    const answered = for (got.frames.items, 0..) |f, i| {
        if (f.head.type == .headers and f.head.stream == 1) break i;
    } else return error.NotAnswered;
    const seven = windowUpdateAt(&got, 7) orelse return error.NeverToppedUp;
    try testing.expect(seven > answered);
}

test "a client that sends past the window it was given is sent away" {
    var app = try testApp();
    defer app.deinit();
    app.limits.max_body = 200_000;
    var client = try TestClient.init();
    defer client.deinit();
    for ([_]u31{ 1, 3, 5, 7 }) |id| {
        try client.headersFor(id, "/test.Echo/Say", &.{}, false);
        try sendPart(&client, id, 64_000, 150_000, false);
    }
    // Stream 7's window was held back, and 16,000 more is past the 65,535
    // it opened with. A budget is only a bound if the window is held to.
    try sendPart(&client, 7, 16_000, null, false);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.flow_control_error, got.goaway().?);
}

test "a message marked compressed with no grpc-encoding is INTERNAL" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Echo/Say", &.{}, false);
    try client.message(1, "whatever", true);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("13", Answer.value(try got.trailers(1), "grpc-status").?);
}

test "a call carrying expect: 100-continue is told so at once, and answered by its route" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Echo/Say", &.{.{ .name = "expect", .value = "100-continue" }}, false);
    try client.message(1, "still here", false);

    var got = try converse(&app, &client);
    defer got.deinit();
    const heads = Answer.of(.headers, &got, 1);
    try testing.expectEqualStrings("100", Answer.value(try got.fields(heads[0].payload), ":status").?);
    try testing.expect(!heads[0].head.has(h2.Flags.end_stream));
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
    try testing.expectEqualStrings("still here", try got.message(1));
}

test "a grpc-message the route encoded itself goes out as it wrote it" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Status/Refuse", "");

    var got = try converse(&app, &client);
    defer got.deinit();
    const trailers = try got.trailers(1);
    try testing.expectEqualStrings("9", Answer.value(trailers, "grpc-status").?);
    try testing.expectEqualStrings("caf%C3%A9 is 50%25 off", Answer.value(trailers, "grpc-message").?);
}

test "a duplicate row is ALREADY_EXISTS and a rolled-back transaction ABORTED, which their statuses alone would not say" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Orders/Duplicate", "");
    try client.call(3, "/test.Orders/RolledBack", "");

    var got = try converse(&app, &client);
    defer got.deinit();
    // Both answer 409 and 503 over HTTP/1.1, which read as ABORTED and
    // UNAVAILABLE; the error says which it was.
    try testing.expectEqualStrings("6", Answer.value(try got.trailers(1), "grpc-status").?);
    try testing.expectEqualStrings("10", Answer.value(try got.trailers(3), "grpc-status").?);
}

test "a route's own trailers go out after the message, and on a failure beside its status" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Orders/Check", "x");
    try client.call(3, "/test.Orders/Check", "");

    var got = try converse(&app, &client);
    defer got.deinit();
    const ok = try got.trailers(1);
    try testing.expectEqualStrings("0", Answer.value(ok, "grpc-status").?);
    try testing.expectEqualStrings("yes", Answer.value(ok, "x-checked").?);
    const failed = try got.trailers(3);
    try testing.expectEqualStrings("5", Answer.value(failed, "grpc-status").?);
    try testing.expectEqualStrings("yes", Answer.value(failed, "x-checked").?);
}

test "a gRPC status set as a header is refused with a sentence naming setTrailer" {
    try testing.expectError(error.Failed, Ctx.checkHeader(.{ .name = "grpc-status", .value = "6" }));
}

test "nilo's own grpc-message is encoded whole, a percent sign included" {
    const a = testing.allocator;
    const out = try grpc.percentEncoded(a, "50% off, caf\xc3\xa9", false);
    defer a.free(out);
    try testing.expectEqualStrings("50%25 off, caf%C3%A9", out);
    // A route's own escapes are kept; a stray percent in it is still encoded.
    const kept = try grpc.percentEncoded(a, "%C3%A9 and 5%", true);
    defer a.free(kept);
    try testing.expectEqualStrings("%C3%A9 and 5%25", kept);
}

test "a message larger than max_body is RESOURCE_EXHAUSTED, and the route never sees it" {
    var app = try testApp();
    defer app.deinit();
    app.limits.max_body = 16;
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Echo/Say", "this is well past sixteen bytes");

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("8", Answer.value(try got.trailers(1), "grpc-status").?);
}

test "a request that is not a gRPC call is served as HTTP, with no grpc-status and the body in plain DATA" {
    var app = try testApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{
        .method = "POST",
        .path = "/test.Echo/Say",
        .fields = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = "{\"a\":1}",
    });
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 200), ex.status);
    try testing.expectEqualStrings("{\"a\":1}", ex.body);
    try testing.expectEqualStrings("7", ex.header("content-length").?);
    try testing.expect(ex.header("date") != null);
    try testing.expect(Answer.value(ex.trailers, "grpc-status") == null);
    try testing.expectEqual(@as(usize, 0), ex.trailers.len);
}

test "a header value with a line break in it is refused before it can become a request" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Meta/Who", &.{.{ .name = "x-caller", .value = "a\r\nx-admin: yes" }}, false);
    try client.message(1, "", false);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.protocol_error, got.rst(1).?);
    try testing.expectEqual(@as(usize, 0), Answer.of(.headers, &got, 1).len);
}

test "a message split across DATA frames and a header block across CONTINUATION frames arrive whole" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();

    var block: std.Io.Writer.Allocating = .init(testing.allocator);
    defer block.deinit();
    try hpack.writeInt(&block.writer, 0x80, 7, 3);
    try hpack.writeInt(&block.writer, 0x80, 7, 6);
    try hpack.writeLiteral(&block.writer, ":path", "/test.Echo/Say");
    try hpack.writeLiteral(&block.writer, "content-type", "application/grpc");
    try h2.writeHeaderBlock(client.w(), 1, block.written(), false, 5);

    const text = "in two halves";
    var prefix: [5]u8 = .{ 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, prefix[1..5], text.len, .big);
    try h2.writeHeader(client.w(), 5 + 3, .data, 0, 1);
    try client.w().writeAll(&prefix);
    try client.w().writeAll(text[0..3]);
    try h2.writeHeader(client.w(), text.len - 3, .data, h2.Flags.end_stream, 1);
    try client.w().writeAll(text[3..]);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings(text, try got.message(1));
}

test "an answer larger than the client's window waits for WINDOW_UPDATE, then finishes" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    // A client that allows ten bytes a stream, then asks for forty.
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 10 }});
    try client.call(1, "/test.Echo/Say", "0123456789" ** 4);
    try h2.writeWindowUpdate(client.w(), 1, 100);

    var got = try converse(&app, &client);
    defer got.deinit();
    const data = Answer.of(.data, &got, 1);
    try testing.expect(data.len >= 2);
    try testing.expectEqual(@as(u24, 10), data[0].head.len);
    try testing.expectEqualStrings("0123456789" ** 4, try got.message(1));
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
}

test "a call past the cap is refused with REFUSED_STREAM, and the calls under it are not" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    // Opened and never finished, so every one of them is held.
    var id: u31 = 1;
    for (0..max_streams + 1) |_| {
        try client.headersFor(id, "/test.Echo/Say", &.{}, false);
        id += 2;
    }

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.refused_stream, got.rst(id - 2).?);
    try testing.expectEqual(@as(?h2.ErrorCode, null), got.rst(1));
}

test "a client that keeps opening past the cap is sent away with ENHANCE_YOUR_CALM" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    var id: u31 = 1;
    for (0..max_streams + max_refused + 2) |_| {
        try client.headersFor(id, "/test.Echo/Say", &.{}, false);
        id += 2;
    }

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.enhance_your_calm, got.goaway().?);
}

test "a header block that never ends is sent away with ENHANCE_YOUR_CALM, however it is split" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    const junk = [_]u8{0} ** 4096;
    try h2.writeHeader(client.w(), junk.len, .headers, 0, 1);
    try client.w().writeAll(&junk);
    for (0..20) |_| {
        try h2.writeHeader(client.w(), junk.len, .continuation, 0, 1);
        try client.w().writeAll(&junk);
    }

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.enhance_your_calm, got.goaway().?);
}

test "a flood of PINGs with no call between them is sent away" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    for (0..max_control_run + 1) |_| {
        try h2.writeHeader(client.w(), 8, .ping, 0, 0);
        try client.w().writeAll("12345678");
    }

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.enhance_your_calm, got.goaway().?);
}

test "a stream opened and reset before it runs counts toward the flood, however many streams it takes" {
    // HEADERS then RST_STREAM costs a decoded block and a stream, and used
    // to reset the count PING and SETTINGS are held to, so the pair walked
    // round it for ever.
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    var id: u31 = 1;
    for (0..max_control_run + 1) |_| {
        try client.headersFor(id, "/test.Echo/Say", &.{}, false);
        try h2.writeRstStream(client.w(), id, .cancel);
        id += 2;
    }

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.enhance_your_calm, got.goaway().?);
}

test "a flood of frames of a type nobody knows is sent away" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    for (0..max_control_run + 1) |_| try h2.writeHeader(client.w(), 0, @enumFromInt(0x20), 0, 0);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.enhance_your_calm, got.goaway().?);
}

/// The App a route asks to stop, from inside a call, which is the moment a
/// SIGTERM lands on a busy connection.
var stopping_app: *App = undefined;
var calls_after_stop: u32 = 0;

fn stopRoute(c: *Ctx) anyerror!void {
    stopping_app.stop.request();
    try c.send(200, "application/grpc", "");
}

fn countedRoute(c: *Ctx) anyerror!void {
    calls_after_stop += 1;
    try c.send(200, "application/grpc", "");
}

test "a stream opened after the server's GOAWAY is refused, and the ones before it are answered" {
    // The GOAWAY tells the client a later stream was never processed, and a
    // client may send it again on a new connection. Running it here as well
    // would run the call twice.
    var app = try testApp();
    defer app.deinit();
    try app.post("/test.Stop/Now", stopRoute);
    try app.post("/test.Counted/Once", countedRoute);
    try app.resolveChains();
    stopping_app = &app;
    calls_after_stop = 0;

    var client = try TestClient.init();
    defer client.deinit();
    // Stream 1 is still being sent when the stop lands, so the connection
    // stays open for it and reads what comes after.
    try client.headersFor(1, "/test.Echo/Say", &.{}, false);
    try client.call(3, "/test.Stop/Now", "");
    try client.call(5, "/test.Counted/Once", "");
    try client.message(1, "still owed", false);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.refused_stream, got.rst(5).?);
    try testing.expectEqual(@as(u32, 0), calls_after_stop);
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
    try testing.expectEqualStrings("still owed", try got.message(1));
}

test "a client that is not speaking HTTP/2 is told so in HTTP/1.1, and the connection closed" {
    var app = try testApp();
    defer app.deinit();
    var client: TestClient = .{ .buf = .init(testing.allocator) };
    defer client.deinit();
    try client.w().writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    serveConnection(app.grpcHost(), &in, &out.writer, .off, .off, .{});
    try testing.expect(std.mem.startsWith(u8, out.written(), "HTTP/1.1 505"));
}

test "a frame larger than the server allows is a FRAME_SIZE_ERROR" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2.writeHeader(client.w(), h2.default_max_frame + 1, .data, 0, 1);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.frame_size_error, got.goaway().?);
}

// The HTTP/1.1 budget (`behaviour.zig`) counts allocations inside a request's
// arena, and a keep-alive connection's arena is warm. A call here has an
// arena of its own, made and dropped with it, so what is counted is what
// reaches the general-purpose allocator: the connection's first call is
// taken away by running one call and then two, and the difference is the
// second call's. Raising either number needs a reason; lowering it is welcome.
test "a unary call stays inside its budget of heap allocations" {
    var app = try testApp();
    defer app.deinit();
    var counting = @import("budget.zig").Counting{ .child = testing.allocator };

    var results: [2]struct { allocs: usize, bytes: usize } = undefined;
    for (&results, 1..) |*r, calls| {
        var client = try TestClient.init();
        defer client.deinit();
        var id: u31 = 1;
        for (0..calls) |_| {
            try client.call(id, "/test.Echo/Say", "a message of ordinary size, forty bytes");
            id += 2;
        }
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(client.buf.written());
        var host = app.grpcHost();
        host.gpa = counting.allocator();
        counting.reset();
        serveConnection(host, &in, &out.writer, .off, .off, .{});
        r.* = .{ .allocs = counting.allocs, .bytes = counting.bytes };
    }
    // None: the second call reuses the first one's stream and the arena it
    // kept (`spare_arena_keep`). It was four allocations and 3,342 bytes
    // before streams were kept (ADR 220).
    try testing.expectEqual(@as(usize, 0), results[1].allocs - results[0].allocs);
    try testing.expectEqual(@as(usize, 0), results[1].bytes - results[0].bytes);
}

test "grpc-timeout is the request's deadline, and a route that runs out of it is DEADLINE_EXCEEDED" {
    var app = try testApp();
    defer app.deinit();
    // A default from listen() longer than the client's timeout does not
    // replace it: the client's is the one that decides.
    app.limits.request_deadline_ms = 60_000;
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Clock/Check", &.{.{ .name = "grpc-timeout", .value = "5S" }}, false);
    try client.message(1, "", false);
    try client.headersFor(3, "/test.Clock/Check", &.{.{ .name = "grpc-timeout", .value = "1n" }}, false);
    try client.message(3, "", false);

    const previous = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = previous;
    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
    try testing.expectEqualStrings("4", Answer.value(try got.trailers(3), "grpc-status").?);
}

test "a grpc-timeout that is not one is INVALID_ARGUMENT, and the route never runs" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Clock/Check", &.{.{ .name = "grpc-timeout", .value = "soon" }}, false);
    try client.message(1, "", false);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("3", Answer.value(try got.trailers(1), "grpc-status").?);
}

test "a header block that decodes to more than max_header_list is RESOURCE_EXHAUSTED, however small it was" {
    // The HPACK bomb: one byte on the wire, `:method: GET` from the static
    // table, forty-five bytes against the list's limit every time it is said.
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    const bomb = [_]u8{0x82} ** 8000;
    // A call says what it is before the bomb, a request that is not one
    // says nothing: the first is RESOURCE_EXHAUSTED, the second a 431.
    var call_block: std.Io.Writer.Allocating = .init(testing.allocator);
    defer call_block.deinit();
    try hpack.writeLiteral(&call_block.writer, "content-type", "application/grpc");
    try call_block.writer.writeAll(&bomb);
    try h2.writeHeaderBlock(client.w(), 1, call_block.written(), false, h2.default_max_frame);
    try client.message(1, "", false);
    try h2.writeHeaderBlock(client.w(), 3, &bomb, true, h2.default_max_frame);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("8", Answer.value(try got.trailers(1), "grpc-status").?);
    try testing.expectEqualStrings("431", Answer.value(try got.fields(Answer.of(.headers, &got, 3)[0].payload), ":status").?);
    try testing.expectEqual(@as(?h2.ErrorCode, null), got.goaway());
}

test "a flood of SETTINGS with no call between them is sent away" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    for (0..max_control_run + 1) |_| try h2.writeSettings(client.w(), &.{});

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.enhance_your_calm, got.goaway().?);
}

// ---- what RFC 9113 and the gRPC spec refuse, and allow (the audit of `http/` at 39896d2) ----

const base_fields = [_]hpack.Field{
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":path", .value = "/test.Echo/Say" },
    .{ .name = ":authority", .value = "localhost" },
    .{ .name = "content-type", .value = "application/grpc" },
};

/// A call whose request headers are exactly `fields`, in that order, every
/// one written as a literal: what the tests below need to say a request wrong.
fn callWithFields(client: *TestClient, stream: u31, fields: []const hpack.Field) !void {
    var block: std.Io.Writer.Allocating = .init(testing.allocator);
    defer block.deinit();
    for (fields) |f| try hpack.writeLiteral(&block.writer, f.name, f.value);
    try h2.writeHeaderBlock(client.w(), stream, block.written(), false, h2.default_max_frame);
    try client.message(stream, "x", false);
}

fn expectMalformed(fields: []const hpack.Field) !void {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try callWithFields(&client, 1, fields);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.protocol_error, got.rst(1).?);
    try testing.expectEqual(@as(usize, 0), Answer.of(.headers, &got, 1).len);
    try testing.expectEqual(@as(?h2.ErrorCode, null), got.goaway());
}

fn hostRoute(c: *Ctx) anyerror!void {
    const host = if (c.header("host")) |v| v.view() else "none";
    try c.send(200, "application/grpc", host);
}

/// Whether a request with this content type is answered as a gRPC call
/// (a `grpc-status` in its trailers) or as HTTP (none, and a `content-length`).
fn expectContentType(value: []const u8, is_grpc: bool) !void {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    var fields = base_fields;
    fields[4].value = value;
    try callWithFields(&client, 1, &fields);

    var got = try converse(&app, &client);
    defer got.deinit();
    const head = try got.fields(Answer.of(.headers, &got, 1)[0].payload);
    try testing.expectEqualStrings("200", Answer.value(head, ":status").?);
    try testing.expectEqual(is_grpc, Answer.value(try got.trailers(1), "grpc-status") != null);
    try testing.expectEqual(!is_grpc, Answer.value(head, "content-length") != null);
}

test "a content-type of application/grpc, or application/grpc+ and a subtype, is a gRPC call" {
    try expectContentType("application/grpc", true);
    try expectContentType("application/grpc+proto", true);
    try expectContentType("application/grpc+json", true);
}

test "application/grpc-web and other near misses are not a native gRPC call: they are served as HTTP" {
    try expectContentType("application/grpc-web", false);
    try expectContentType("application/grpc-web+proto", false);
    try expectContentType("application/grpcx", false);
    try expectContentType("application/grpc+", false);
    try expectContentType("application/grpc;x", false);
}

test "a request with a pseudo-header twice is a stream error PROTOCOL_ERROR" {
    try expectMalformed(&(base_fields ++ [_]hpack.Field{.{ .name = ":path", .value = "/test.Echo/Say" }}));
}

test "a request with a pseudo-header that is not defined is a stream error PROTOCOL_ERROR" {
    // Ahead of the regular fields, where a pseudo-header belongs, so only
    // its name is wrong.
    try expectMalformed(&([_]hpack.Field{.{ .name = ":version", .value = "2" }} ++ base_fields));
}

test "a pseudo-header after a regular field is a stream error PROTOCOL_ERROR" {
    try expectMalformed(&[_]hpack.Field{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/test.Echo/Say" },
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = ":scheme", .value = "http" },
    });
}

test "a request with no :scheme is a stream error PROTOCOL_ERROR" {
    try expectMalformed(&[_]hpack.Field{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/test.Echo/Say" },
        .{ .name = "content-type", .value = "application/grpc" },
    });
}

/// The `grpc-status` a call with exactly `fields` is answered with.
fn statusFor(fields: []const hpack.Field) ![]const u8 {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try callWithFields(&client, 1, fields);

    var got = try converse(&app, &client);
    defer got.deinit();
    const code = Answer.value(try got.trailers(1), "grpc-status").?;
    return if (std.mem.eql(u8, code, "0")) "0" else if (std.mem.eql(u8, code, "3")) "3" else "other";
}

test "metadata an HTTP/1.1 head would be refused for is INVALID_ARGUMENT, by the same rules" {
    // A call reaches the App as its fields rather than as a head the App
    // parses, and they are held to `parseHead`'s rules by its own loop
    // (ADR 253): a control byte in a value, a body coding nilo does not
    // read, and two hosts with no `:authority` to settle it are each the
    // 400 or 415 an HTTP/1.1 request gets, which a call reads as code 3.
    try testing.expectEqualStrings("3", try statusFor(&(base_fields ++ [_]hpack.Field{.{ .name = "x-note", .value = "a\x01b" }})));
    try testing.expectEqualStrings("3", try statusFor(&(base_fields ++ [_]hpack.Field{.{ .name = "content-encoding", .value = "br" }})));
    try testing.expectEqualStrings("3", try statusFor(&[_]hpack.Field{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/test.Echo/Say" },
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = "host", .value = "a.example" },
        .{ .name = "host", .value = "b.example" },
    }));
    // And a tab in a value is the one control a field may hold.
    try testing.expectEqualStrings("0", try statusFor(&(base_fields ++ [_]hpack.Field{.{ .name = "x-note", .value = "a\tb" }})));
}

test "a content-length that is the length of the DATA is not what the route reads: the message is" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    // The message is five bytes of prefix and "x".
    try callWithFields(&client, 1, &(base_fields ++ [_]hpack.Field{.{ .name = "content-length", .value = "6" }}));

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
    try testing.expectEqualStrings("x", try got.message(1));
}

test "a content-length that is not the length of the DATA is a stream error PROTOCOL_ERROR, over or under" {
    try expectMalformed(&(base_fields ++ [_]hpack.Field{.{ .name = "content-length", .value = "999" }}));
    try expectMalformed(&(base_fields ++ [_]hpack.Field{.{ .name = "content-length", .value = "5" }}));
    try expectMalformed(&(base_fields ++ [_]hpack.Field{.{ .name = "content-length", .value = "six" }}));
}

test "a request with :authority and host is served, with :authority as its one host" {
    var app = try testApp();
    defer app.deinit();
    try app.post("/test.Host/Which", hostRoute);
    try app.resolveChains();
    var client = try TestClient.init();
    defer client.deinit();
    var fields = base_fields ++ [_]hpack.Field{.{ .name = "host", .value = "other.example" }};
    fields[2].value = "/test.Host/Which";
    try callWithFields(&client, 1, &fields);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
    try testing.expectEqualStrings("localhost", try got.message(1));
}

/// A client whose bytes arrive in two goes, the second after a wait: what a
/// call that takes its time sending its message looks like to the connection.
const Delayed = struct {
    first: []const u8,
    second: []const u8,
    wait_ms: u64,
    step: u8 = 0,
    reader: std.Io.Reader,

    fn init(first: []const u8, second: []const u8, wait_ms: u64, buffer: []u8) Delayed {
        return .{
            .first = first,
            .second = second,
            .wait_ms = wait_ms,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .end = 0, .seek = 0 },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Delayed = @alignCast(@fieldParentPtr("reader", r));
        const part = switch (self.step) {
            0 => self.first,
            1 => blk: {
                // Spun, not slept: no Engine is running to sleep on.
                const until = bulkhead.monotonicNanos() + self.wait_ms * std.time.ns_per_ms;
                while (bulkhead.monotonicNanos() < until) std.atomic.spinLoopHint();
                break :blk self.second;
            },
            else => return error.EndOfStream,
        };
        self.step += 1;
        const dest = limit.slice(try w.writableSliceGreedy(part.len));
        @memcpy(dest[0..part.len], part);
        w.advance(part.len);
        return part.len;
    }
};

test "grpc-timeout is counted from when the headers arrived, not from when the message was whole" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Clock/Check", &.{.{ .name = "grpc-timeout", .value = "10m" }}, false);
    const split = client.buf.written().len;
    try client.message(1, "", false);

    // The message is whole 40 ms after the headers, and the call had 10.
    var buffer: [4096]u8 = undefined;
    var delayed = Delayed.init(client.buf.written()[0..split], client.buf.written()[split..], 40, &buffer);
    const previous = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = previous;
    var got = try converseFrom(&app, &delayed.reader);
    defer got.deinit();
    try testing.expectEqualStrings("4", Answer.value(try got.trailers(1), "grpc-status").?);
}

test "a malformed call between runs of PINGs does not start the flood count again" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    var id: u31 = 1;
    for (0..3) |_| {
        for (0..max_control_run / 2) |_| {
            try h2.writeHeader(client.w(), 8, .ping, 0, 0);
            try client.w().writeAll("12345678");
        }
        // No :scheme: refused, so it moved nothing forward.
        try callWithFields(&client, id, &.{
            .{ .name = ":method", .value = "POST" },
            .{ .name = ":path", .value = "/test.Echo/Say" },
        });
        id += 2;
    }

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.enhance_your_calm, got.goaway().?);
}

test "a call that reaches its route does start the flood count again" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    var id: u31 = 1;
    for (0..3) |_| {
        for (0..max_control_run / 2) |_| {
            try h2.writeHeader(client.w(), 8, .ping, 0, 0);
            try client.w().writeAll("12345678");
        }
        try client.call(id, "/test.Echo/Say", "x");
        id += 2;
    }

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(@as(?h2.ErrorCode, null), got.goaway());
}

test "a flood of empty DATA frames to a stream that is not collecting is sent away" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Echo/Say", "x");
    // Stream 1 is answered and gone: the frames are ignored (§5.1), and
    // each one is still a frame read for nothing.
    for (0..max_control_run + 1) |_| try h2.writeHeader(client.w(), 0, .data, 0, 1);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.enhance_your_calm, got.goaway().?);
}

test "a SETTINGS_INITIAL_WINDOW_SIZE that lifts a send window past 2^31-1 is a FLOW_CONTROL_ERROR" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Echo/Say", &.{}, false);
    // The stream's window, brought to the most it may be.
    try h2.writeWindowUpdate(client.w(), 1, h2.max_window - h2.default_window);
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, h2.default_window + 1 }});

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.flow_control_error, got.goaway().?);
}

test "a call reset while its message is arriving gives its bytes back to the connection's budget" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Echo/Say", &.{}, false);
    try sendPart(&client, 1, 1000, 5000, false);
    try h2.writeRstStream(client.w(), 1, .cancel);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    const shared = try Shared.create(testing.allocator, .off);
    var conn: Conn = .{
        .app = app.grpcHost(),
        .gpa = testing.allocator,
        .in = &in,
        .out = &out.writer,
        .deadlines = .off,
        .waker = .off,
        .peer = .{},
        .shared = shared,
        .decoder = hpack.Decoder.init(testing.allocator),
    };
    defer conn.deinit();
    conn.run();
    try testing.expectEqual(@as(usize, 0), conn.streams.items.len);
    try testing.expectEqual(@as(usize, 0), conn.collected);
}

test "a call reset while its message is arriving does not hold back the windows of the calls beside it" {
    var app = try testApp();
    defer app.deinit();
    app.limits.max_body = 200_000;
    var client = try TestClient.init();
    defer client.deinit();
    // Five calls of 64,000 bytes each: from the fourth on the connection is
    // past its budget, and only the oldest call's window is topped up.
    for ([_]u31{ 1, 3, 5, 7, 9 }) |id| {
        try client.headersFor(id, "/test.Echo/Say", &.{}, false);
        try sendPart(&client, id, 64_000, 79_995, false);
    }
    // Two are cancelled: what they held is the budget's again.
    try h2.writeRstStream(client.w(), 3, .cancel);
    try h2.writeRstStream(client.w(), 5, .cancel);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expect(windowUpdateAt(&got, 7) != null);
    try testing.expect(windowUpdateAt(&got, 9) != null);
}

/// A connection over `client`'s bytes, driven a frame at a time rather than
/// by `run`, so a test can look at it between two frames.
fn steppedConn(app: *App, in: *std.Io.Reader, out: *std.Io.Writer) !Conn {
    _ = try in.takeArray(h2.preface.len);
    return .{
        .app = app.grpcHost(),
        .gpa = testing.allocator,
        .in = in,
        .out = out,
        .deadlines = .off,
        .waker = .off,
        .peer = .{},
        .shared = try Shared.create(testing.allocator, .off),
        .decoder = hpack.Decoder.init(testing.allocator),
    };
}

test "a call's message counts against the connection's budget while its route runs, and leaves it once the answer is written" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Echo/Say", &.{}, false);
    try sendPart(&client, 1, 5005, 5000, true);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    var conn = try steppedConn(&app, &in, &out.writer);
    defer conn.deinit();
    while (in.bufferedLen() > 0) try conn.readFrame();

    // The route has run (with no server it runs inline) and its answer is
    // waiting to be written: the message is still held, so it still counts.
    try testing.expect(conn.collected >= 5005);
    try conn.writeReady();
    try testing.expectEqual(@as(usize, 0), conn.collected);
}

test "a header block still unfinished when its call's time to arrive is up sends the connection away" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    const part = [_]u8{0} ** 16;
    try h2.writeHeader(client.w(), part.len, .headers, 0, 1);
    try client.w().writeAll(&part);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    var conn = try steppedConn(&app, &in, &out.writer);
    defer conn.deinit();
    while (in.bufferedLen() > 0) try conn.readFrame();

    const s = conn.continuing.?;
    // A CONTINUATION a byte at a time resets the silence limit each time, so
    // the call's own bound is the one that has to end it.
    s.collect_until_ns = 1;
    try testing.expectEqual(Conn.Waited.stop, conn.overdue());
    try testing.expect(conn.goaway_sent);
}

test "the oldest call still arriving waits while a call that started still holds its message" {
    var app = try testApp();
    defer app.deinit();
    app.limits.max_body = 100_000;
    var client = try TestClient.init();
    defer client.deinit();
    // A client that will not read: every answer waits on a window of 0, so a
    // call that has run keeps what it holds until the write gives up.
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 0 }});
    // Call 1 arrives whole and runs; its answer cannot go out.
    try client.headersFor(1, "/test.Echo/Say", &.{}, false);
    try sendPart(&client, 1, 64_000, 63_995, true);
    // Call 3 is now the oldest call still arriving. The connection is past
    // its budget because of call 1, which needs nothing more from the client
    // to give its bytes back, so call 3 is not topped up past it.
    try client.headersFor(3, "/test.Echo/Say", &.{}, false);
    try sendPart(&client, 3, 64_000, 99_995, false);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expect(windowUpdateAt(&got, 3) == null);
}

/// `n` bytes of `byte`, gzipped, in `out`.
fn gzipRun(out: *std.Io.Writer.Allocating, byte: u8, n: usize) !void {
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress: std.compress.flate.Compress = try .init(&out.writer, &window, .gzip, .default);
    try compress.writer.splatByteAll(byte, n);
    try compress.finish();
}

test "calls that inflate past the connection's budget wait for room, and what is held stays inside it" {
    var app = try testApp();
    defer app.deinit();
    app.limits.max_body = 200_000;
    var client = try TestClient.init();
    defer client.deinit();
    // A client that will not read, so a call that ran keeps what it holds.
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 0 }});

    // Six calls of a few hundred bytes of gzip, each inflating to 40,000. Each
    // that starts holds its inflated copy and the request text built from it.
    var zipped: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer zipped.deinit();
    try gzipRun(&zipped, 'q', 40_000);
    const ids = [_]u31{ 1, 3, 5, 7, 9, 11 };
    for (ids) |id| {
        try client.headersFor(id, "/test.Echo/Say", &.{.{ .name = "grpc-encoding", .value = "gzip" }}, false);
        try client.message(id, zipped.written(), true);
    }

    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(client.buf.written());
        var conn = try steppedConn(&app, &in, &out.writer);
        defer conn.deinit();
        while (in.bufferedLen() > 0) try conn.readFrame();
        // The budget is 200,005. Before the inflation was held to the room
        // left, all six started and held about 480,000. Two fit; the other
        // four hold their few hundred compressed bytes and wait.
        try testing.expect(conn.collected <= conn.budget() + 40_000 + zipped.written().len);
        try testing.expectEqual(@as(u32, 4), conn.waiting);
    }

    // Nothing comes back while the two that started are stuck on a window of
    // 0, and nothing is refused either: before, the four were UNAVAILABLE,
    // which a Collector retries only after its backoff (ADR 220).
    var got = try converse(&app, &client);
    defer got.deinit();
    for (ids) |id| {
        const trailers = got.trailers(id) catch continue;
        const status = Answer.value(trailers, "grpc-status") orelse continue;
        try testing.expect(!std.mem.eql(u8, status, "14"));
    }
}

test "calls that waited for room all finish, in order, once the calls ahead give it back" {
    var app = try testApp();
    defer app.deinit();
    app.limits.max_body = 200_000;
    var client = try TestClient.init();
    defer client.deinit();

    var zipped: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer zipped.deinit();
    try gzipRun(&zipped, 'q', 40_000);
    const ids = [_]u31{ 1, 3, 5, 7, 9, 11 };
    for (ids) |id| {
        try client.headersFor(id, "/test.Echo/Say", &.{.{ .name = "grpc-encoding", .value = "gzip" }}, false);
        try client.message(id, zipped.written(), true);
    }
    // Room on the connection for all six answers.
    try h2.writeWindowUpdate(client.w(), 0, 1_000_000);

    var got = try converse(&app, &client);
    defer got.deinit();
    for (ids) |id| {
        try testing.expectEqualStrings("0", Answer.value(try got.trailers(id), "grpc-status").?);
        const body = try got.message(id);
        try testing.expectEqual(@as(usize, 40_000), body.len);
        for (body) |b| try testing.expectEqual(@as(u8, 'q'), b);
    }
}

test "the oldest call waiting for room starts once no started call holds bytes, however little room is left" {
    var app = try testApp();
    defer app.deinit();
    app.limits.max_body = 100_000;
    var client = try TestClient.init();
    defer client.deinit();
    // Answers wait on a window of 0 until the client says otherwise below.
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 0 }});

    // Bytes gzip cannot shrink, so a waiting call holds about as much as it
    // inflates to: three of them hold more than the budget leaves any one.
    var noise: [40_000]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    prng.random().bytes(&noise);
    var zipped: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer zipped.deinit();
    {
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var compress: std.compress.flate.Compress = try .init(&zipped.writer, &window, .gzip, .default);
        try compress.writer.writeAll(&noise);
        try compress.finish();
    }
    const ids = [_]u31{ 1, 3, 5, 7 };
    for (ids) |id| {
        try client.headersFor(id, "/test.Echo/Say", &.{.{ .name = "grpc-encoding", .value = "gzip" }}, false);
        try client.messageInFrames(id, zipped.written(), true);
    }
    // Call 1 started alone and holds about 120,000 of a budget of 100,005;
    // 3, 5 and 7 wait with about 40,000 each. Once 1's answer is written, 3
    // has 100,005 less 80,000 left and needs 40,000: only the rule that the
    // oldest starts when nothing started holds bytes lets it, and without it
    // the three wait for good.
    try h2.writeWindowUpdate(client.w(), 0, 1_000_000);
    for (ids) |id| try h2.writeWindowUpdate(client.w(), id, 100_000);

    var got = try converse(&app, &client);
    defer got.deinit();
    for (ids) |id| {
        try testing.expectEqualStrings("0", Answer.value(try got.trailers(id), "grpc-status").?);
        try testing.expectEqualSlices(u8, &noise, try got.message(id));
    }
}

test "a call whose grpc-timeout passes while it waits for room is DEADLINE_EXCEEDED and never runs" {
    var app = try testApp();
    defer app.deinit();
    app.limits.max_body = 100_000;
    var client = try TestClient.init();
    defer client.deinit();
    // A client that will not read: call 1's answer holds its room for good.
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 0 }});
    var zipped: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer zipped.deinit();
    try gzipRun(&zipped, 'd', 60_000);
    const gzip: hpack.Field = .{ .name = "grpc-encoding", .value = "gzip" };
    try client.headersFor(1, "/test.Echo/Say", &.{gzip}, false);
    try client.message(1, zipped.written(), true);
    try client.headersFor(3, "/test.Echo/Say", &.{ gzip, .{ .name = "grpc-timeout", .value = "5S" } }, false);
    try client.message(3, zipped.written(), true);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    var conn = try steppedConn(&app, &in, &out.writer);
    defer conn.deinit();
    while (in.bufferedLen() > 0) try conn.readFrame();

    const waiting = conn.find(3).?;
    try testing.expectEqual(Stream.State.waiting, waiting.state);
    try testing.expect(conn.inFlightLimitMs().? > 0);
    waiting.until_ns = 1;
    try testing.expectEqual(Conn.Waited.again, conn.overdue());
    try testing.expectEqual(@as(u32, 0), conn.waiting);
    try testing.expect(conn.find(3) == null);

    var got = try answerOf(out.written());
    defer got.deinit();
    const trailers = try got.trailers(3);
    try testing.expectEqualStrings("4", Answer.value(trailers, "grpc-status").?);
    try testing.expect(Answer.of(.data, &got, 3).len == 0);
}

test "a gzip message that inflates to max_body is read when nothing else is held, byte for byte" {
    var app = try testApp();
    defer app.deinit();
    app.limits.max_body = 100_000;
    var client = try TestClient.init();
    defer client.deinit();

    var zipped: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer zipped.deinit();
    try gzipRun(&zipped, 'z', 100_000);
    try client.headersFor(1, "/test.Echo/Say", &.{.{ .name = "grpc-encoding", .value = "gzip" }}, false);
    try client.message(1, zipped.written(), true);
    // The answer is larger than the window it is sent under.
    try h2.writeWindowUpdate(client.w(), 0, 100_000);
    try h2.writeWindowUpdate(client.w(), 1, 100_000);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
    const body = try got.message(1);
    try testing.expectEqual(@as(usize, 100_000), body.len);
    for (body) |b| try testing.expectEqual(@as(u8, 'z'), b);
}

const maxbody = @import("maxbody.zig");

test "a route's maxBody above max_body takes a message between the two, and its neighbours stay under max_body" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.max_body = 16;
    try app.with(maxbody.with(64)).post("/test.Echo/Say", echoRoute);
    try app.post("/test.Echo/Other", echoRoute);
    try app.resolveChains();
    var client = try TestClient.init();
    defer client.deinit();
    const forty = "forty bytes, which is over sixteen....";
    try client.call(1, "/test.Echo/Say", forty);
    try client.call(3, "/test.Echo/Other", forty);
    try client.call(5, "/test.Echo/Say", "x" ** 80);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
    try testing.expectEqualStrings(forty, try got.message(1));
    // The neighbour has no maxBody: unchanged.
    try testing.expectEqualStrings("8", Answer.value(try got.trailers(3), "grpc-status").?);
    // And the raised limit is a limit: eighty is over sixty-four.
    try testing.expectEqualStrings("8", Answer.value(try got.trailers(5), "grpc-status").?);
    try testing.expectEqual(@as(usize, 0), Answer.of(.data, &got, 5).len);
}

test "a route's maxBody below max_body refuses a message past it before the route runs" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.max_body = 200;
    try app.with(maxbody.with(8)).post("/test.Echo/Say", echoRoute);
    try app.resolveChains();
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Echo/Say", "eight by");
    try client.call(3, "/test.Echo/Say", "twelve bytes");

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
    try testing.expectEqualStrings("8", Answer.value(try got.trailers(3), "grpc-status").?);
    try testing.expectEqual(@as(usize, 0), Answer.of(.data, &got, 3).len);
}

var held_limit: usize = 0;

test "a maxBody that reads its limit from a usize is read on the gRPC side too, and zero leaves max_body in force" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.max_body = 16;
    try app.with(maxbody.with(&held_limit)).post("/test.Echo/Say", echoRoute);
    try app.resolveChains();
    const forty = "forty bytes, which is over sixteen....";

    // Zero: the server's own number, as on HTTP/1.
    held_limit = 0;
    {
        var client = try TestClient.init();
        defer client.deinit();
        try client.call(1, "/test.Echo/Say", forty);
        var got = try converse(&app, &client);
        defer got.deinit();
        try testing.expectEqualStrings("8", Answer.value(try got.trailers(1), "grpc-status").?);
    }
    // Set before listen(): the route takes it.
    held_limit = 64;
    {
        var client = try TestClient.init();
        defer client.deinit();
        try client.call(1, "/test.Echo/Say", forty);
        var got = try converse(&app, &client);
        defer got.deinit();
        try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
        try testing.expectEqualStrings(forty, try got.message(1));
    }
}

test "a gzip message is held to its route's limit, announced size and all" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.max_body = 1_000;
    try app.use(maxbody.with(50_000));
    try app.with(maxbody.with(500)).post("/test.Echo/Small", echoRoute);
    try app.post("/test.Echo/Say", echoRoute);
    try app.resolveChains();
    var client = try TestClient.init();
    defer client.deinit();

    var zipped: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer zipped.deinit();
    try gzipRun(&zipped, 'z', 20_000);
    const gzip: hpack.Field = .{ .name = "grpc-encoding", .value = "gzip" };
    // Inflates to 20,000: past max_body of 1,000, under the use()'s 50,000,
    // and past the narrower route's 500.
    try client.headersFor(1, "/test.Echo/Say", &.{gzip}, false);
    try client.message(1, zipped.written(), true);
    try client.headersFor(3, "/test.Echo/Small", &.{gzip}, false);
    try client.message(3, zipped.written(), true);
    try h2.writeWindowUpdate(client.w(), 0, 100_000);
    try h2.writeWindowUpdate(client.w(), 1, 100_000);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
    try testing.expectEqual(@as(usize, 20_000), (try got.message(1)).len);
    try testing.expectEqualStrings("8", Answer.value(try got.trailers(3), "grpc-status").?);
}

test "one connection's budget grows to the largest limit a route raised to, and no further" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.max_body = 1_000;
    try app.post("/test.Echo/Say", echoRoute);
    try app.resolveChains();
    try testing.expectEqual(@as(usize, 1_000), app.grpcHost().ceiling);

    // A lower limit moves nothing, and a raise on a route of any method is
    // a request's, since any method is served on HTTP/2 now (ADR 259).
    try app.with(maxbody.with(10)).post("/test.Echo/Low", echoRoute);
    try app.resolveChains();
    try testing.expectEqual(@as(usize, 1_000), app.grpcHost().ceiling);
    try app.with(maxbody.with(900_000)).put("/export", echoRoute);
    try app.resolveChains();
    try testing.expectEqual(@as(usize, 900_000), app.grpcHost().ceiling);

    try app.with(maxbody.with(3_000_000)).post("/test.Echo/High", echoRoute);
    try app.resolveChains();
    try testing.expectEqual(@as(usize, 3_000_000), app.grpcHost().ceiling);
}

// ---- any request, not only a call (ADR 259) ----

fn pingRoute(c: *Ctx) anyerror!void {
    try c.setHeader("X-Seen", "ping");
    try c.sendText(200, "pong");
}

fn emptyRoute(c: *Ctx) anyerror!void {
    try c.sendEmpty(204);
}

fn cookieRoute(c: *Ctx) anyerror!void {
    try c.sendText(200, if (c.header("cookie")) |h| h.view() else "no cookie");
}

fn trailingRoute(c: *Ctx) anyerror!void {
    try c.setTrailer("x-sum", "ok");
    try c.sendText(200, "body");
}

fn bigRoute(c: *Ctx) anyerror!void {
    try c.send(200, "application/octet-stream", "0123456789" ** 4_000);
}

fn pathRoute(c: *Ctx) anyerror!void {
    const id = c.param("id").?.view();
    try c.sendText(200, id);
}

fn sizeRoute(c: *Ctx) anyerror!void {
    var buf: [20]u8 = undefined;
    try c.sendText(200, std.fmt.bufPrint(&buf, "{d}", .{(try c.body()).view().len}) catch unreachable);
}

fn streamRoute(c: *Ctx) anyerror!void {
    var out = try c.stream(200, "text/plain");
    try out.finish();
}

fn eventsRoute(c: *Ctx) anyerror!void {
    _ = try c.events();
}

fn bodyStreamRoute(c: *Ctx) anyerror!void {
    _ = try c.bodyStream();
}

fn upgradeRoute(c: *Ctx) anyerror!void {
    return c.upgrade(struct {
        fn loop(_: *@import("websocket.zig").Socket) anyerror!void {}
    }.loop, {});
}

fn eventsFromRoute(c: *Ctx) anyerror!void {
    var room = try @import("room.zig").Room.init(testing.allocator);
    defer room.deinit();
    return c.eventsFrom(&room, .{});
}

var one_file: ?*OneFile = null;

/// A directory with one file in it, for the route that sends it.
const OneFile = struct {
    tmp: nilo_testing.TmpDir,
    dir: bulkhead.Dir,

    fn init() !OneFile {
        var tmp = nilo_testing.tmpDir();
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.bin", .data = "0123456789" });
        var path_buf: [128]u8 = undefined;
        const path = try tmp.path(&path_buf, "");
        return .{ .tmp = tmp, .dir = try bulkhead.Dir.open(path) };
    }

    fn deinit(self: *OneFile) void {
        self.dir.close();
        self.tmp.cleanup();
    }
};

fn fileRoute(c: *Ctx) anyerror!void {
    const file = try one_file.?.dir.openFile("f.bin");
    return c.sendFile(.{ .file = file, .content_type = "application/octet-stream" });
}

const nilo_testing = @import("testing.zig");

fn httpApp() !App {
    var app = App.init(testing.allocator);
    errdefer app.deinit();
    try app.get("/ping", pingRoute);
    try app.get("/empty", emptyRoute);
    try app.get("/cookie", cookieRoute);
    try app.get("/trailing", trailingRoute);
    try app.get("/big", bigRoute);
    try app.get("/users/:id", pathRoute);
    try app.post("/size", sizeRoute);
    try app.get("/stream", streamRoute);
    try app.get("/events", eventsRoute);
    try app.get("/room", eventsFromRoute);
    try app.get("/ws", upgradeRoute);
    try app.get("/file", fileRoute);
    try app.post("/body-stream", bodyStreamRoute);
    try app.post("/test.Echo/Say", echoRoute);
    try app.resolveChains();
    return app;
}

fn quiet() std.log.Level {
    const previous = testing.log_level;
    testing.log_level = .err;
    return previous;
}

test "a GET is answered as HTTP: its status, type, length and date in one HEADERS frame, and its body in DATA that ends the stream" {
    var app = try httpApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .path = "/ping" });
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 200), ex.status);
    try testing.expectEqualStrings("pong", ex.body);
    try testing.expectEqualStrings("text/plain", ex.header("content-type").?);
    try testing.expectEqualStrings("4", ex.header("content-length").?);
    try testing.expectEqualStrings("ping", ex.header("x-seen").?);
    try testing.expectEqual(@as(usize, 29), ex.header("date").?.len);
    try testing.expectEqual(@as(usize, 0), ex.trailers.len);
    // The stream ends on the last DATA frame, with no HEADERS after it.
    const data = Answer.of(.data, &ex.answer, 1);
    try testing.expect(data[data.len - 1].head.has(h2.Flags.end_stream));
    try testing.expectEqual(@as(usize, 1), Answer.of(.headers, &ex.answer, 1).len);
    try testing.expect(!Answer.of(.headers, &ex.answer, 1)[0].head.has(h2.Flags.end_stream));
}

test "a HEAD has the head a GET would, content-length included, and no DATA" {
    var app = try httpApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .method = "HEAD", .path = "/ping" });
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 200), ex.status);
    try testing.expectEqualStrings("4", ex.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), Answer.of(.data, &ex.answer, 1).len);
    try testing.expect(Answer.of(.headers, &ex.answer, 1)[0].head.has(h2.Flags.end_stream));
}

test "a 204 has no content-length and no body, and its HEADERS end the stream" {
    var app = try httpApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .path = "/empty" });
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 204), ex.status);
    try testing.expect(ex.header("content-length") == null);
    try testing.expectEqual(@as(usize, 0), ex.body.len);
    try testing.expect(Answer.of(.headers, &ex.answer, 1)[0].head.has(h2.Flags.end_stream));
}

test "a route's trailers follow its body as one more HEADERS frame that ends the stream" {
    var app = try httpApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .path = "/trailing" });
    defer ex.deinit();
    try testing.expectEqualStrings("body", ex.body);
    try testing.expectEqualStrings("ok", Answer.value(ex.trailers, "x-sum").?);
    const heads = Answer.of(.headers, &ex.answer, 1);
    try testing.expectEqual(@as(usize, 2), heads.len);
    try testing.expect(heads[1].head.has(h2.Flags.end_stream));
    const data = Answer.of(.data, &ex.answer, 1);
    try testing.expect(!data[data.len - 1].head.has(h2.Flags.end_stream));
}

test "a failure is answered as the App answers it on HTTP/1.1: a 404 with the failure body, and a 405 with Allow" {
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try httpApp();
    defer app.deinit();
    var missing = try h2test.roundTrip(&app, .{ .path = "/nowhere" });
    defer missing.deinit();
    try testing.expectEqual(@as(u16, 404), missing.status);
    try testing.expectEqualStrings("application/json", missing.header("content-type").?);
    try testing.expect(std.mem.indexOf(u8, missing.body, "\"status\":404") != null);

    var wrong = try h2test.roundTrip(&app, .{ .method = "DELETE", .path = "/ping" });
    defer wrong.deinit();
    try testing.expectEqual(@as(u16, 405), wrong.status);
    try testing.expect(std.mem.indexOf(u8, wrong.header("allow").?, "GET") != null);
}

test "a path parameter and a body reach the route as they do on HTTP/1.1" {
    var app = try httpApp();
    defer app.deinit();
    var got = try h2test.roundTrip(&app, .{ .path = "/users/42" });
    defer got.deinit();
    try testing.expectEqualStrings("42", got.body);

    var sized = try h2test.roundTrip(&app, .{ .method = "POST", .path = "/size", .body = "x" ** 40_000, .frame = 9_000 });
    defer sized.deinit();
    try testing.expectEqualStrings("40000", sized.body);
}

test "cookies a client split across fields are one field when the route reads them, joined with a semicolon" {
    var app = try httpApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .path = "/cookie", .fields = &.{
        .{ .name = "cookie", .value = "a=1" },
        .{ .name = "cookie", .value = "b=2" },
        .{ .name = "cookie", .value = "c=3" },
    } });
    defer ex.deinit();
    try testing.expectEqualStrings("a=1; b=2; c=3", ex.body);
}

test "OPTIONS * is a request, and answered with what the server supports" {
    var app = try httpApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .method = "OPTIONS", .path = "*" });
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 204), ex.status);
    try testing.expect(std.mem.indexOf(u8, ex.header("allow").?, "GET") != null);
}

test "an answer past the client's window waits for it, and the body still arrives whole" {
    var app = try httpApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    // A window of 1,000 bytes, then the updates a client reading would send.
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 1_000 }});
    try h2test.requestOn(&client, 1, .{ .path = "/big" });
    try h2.writeWindowUpdate(client.w(), 0, 100_000);
    try h2.writeWindowUpdate(client.w(), 1, 100_000);

    var ex = try h2test.exchangeOf(try converse(&app, &client), 1);
    defer ex.deinit();
    try testing.expectEqual(@as(usize, 40_000), ex.body.len);
    try testing.expectEqualStrings("40000", ex.header("content-length").?);
    try testing.expect(Answer.of(.data, &ex.answer, 1).len > 2);
}

test "a request with expect: 100-continue whose body has not arrived is told to send it, at once" {
    var app = try httpApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{
        .method = "POST",
        .path = "/size",
        .fields = &.{.{ .name = "expect", .value = "100-continue" }},
        .body = "hello",
    });
    defer ex.deinit();
    try testing.expectEqualSlices(u16, &.{100}, ex.interim);
    try testing.expectEqualStrings("5", ex.body);
    // The 100 is a HEADERS frame that does not end the stream, ahead of the answer.
    const heads = Answer.of(.headers, &ex.answer, 1);
    try testing.expect(!heads[0].head.has(h2.Flags.end_stream));
    // And is the constant block, which `encodeBlock` would have written.
    try testing.expectEqualStrings(try hpack.encodeBlock(ex.answer.arena.allocator(), &.{.{ .name = ":status", .value = "100" }}), continue_block);
}

test "a request that is over, and expects 100-continue, is not sent one" {
    var app = try httpApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .path = "/ping", .fields = &.{.{ .name = "expect", .value = "100-continue" }} });
    defer ex.deinit();
    try testing.expectEqual(@as(usize, 0), ex.interim.len);
}

/// A request with exactly `fields`, no body and END_STREAM on its HEADERS.
fn expectHttpMalformed(fields: []const hpack.Field) !void {
    var app = try httpApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    var block: std.Io.Writer.Allocating = .init(testing.allocator);
    defer block.deinit();
    for (fields) |f| try hpack.writeLiteral(&block.writer, f.name, f.value);
    try h2.writeHeaderBlock(client.w(), 1, block.written(), true, h2.default_max_frame);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.protocol_error, got.rst(1).?);
    try testing.expectEqual(@as(usize, 0), Answer.of(.headers, &got, 1).len);
    try testing.expectEqual(@as(?h2.ErrorCode, null), got.goaway());
}

const get_fields = [_]hpack.Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":path", .value = "/ping" },
    .{ .name = ":authority", .value = "localhost" },
};

test "a request without :method, :scheme or :path is a stream error PROTOCOL_ERROR" {
    try expectHttpMalformed(get_fields[1..]);
    try expectHttpMalformed(&[_]hpack.Field{ get_fields[0], get_fields[2], get_fields[3] });
    try expectHttpMalformed(&[_]hpack.Field{ get_fields[0], get_fields[1], get_fields[3] });
}

test "an empty :path is a stream error PROTOCOL_ERROR, and a :path that is not a path is too" {
    try expectHttpMalformed(&[_]hpack.Field{ get_fields[0], get_fields[1], .{ .name = ":path", .value = "" } });
    try expectHttpMalformed(&[_]hpack.Field{ get_fields[0], get_fields[1], .{ .name = ":path", .value = "ping" } });
    try expectHttpMalformed(&[_]hpack.Field{ get_fields[0], get_fields[1], .{ .name = ":path", .value = "*" } });
}

test "a field that belongs to an HTTP/1.1 connection is a stream error PROTOCOL_ERROR" {
    for ([_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade" }) |name| {
        try expectHttpMalformed(&(get_fields ++ [_]hpack.Field{.{ .name = name, .value = "x" }}));
    }
}

test "te is malformed unless it is trailers (§8.2.2)" {
    try expectHttpMalformed(&(get_fields ++ [_]hpack.Field{.{ .name = "te", .value = "gzip" }}));
    var app = try httpApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .path = "/ping", .fields = &.{.{ .name = "te", .value = "trailers" }} });
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 200), ex.status);
}

test "a field name in capitals is a stream error PROTOCOL_ERROR" {
    try expectHttpMalformed(&(get_fields ++ [_]hpack.Field{.{ .name = "X-Trace", .value = "1" }}));
}

test "a pseudo-header after a regular field is a stream error PROTOCOL_ERROR, and so is one that is a response's" {
    try expectHttpMalformed(&[_]hpack.Field{ get_fields[0], get_fields[1], .{ .name = "x-a", .value = "1" }, get_fields[2] });
    try expectHttpMalformed(&(get_fields ++ [_]hpack.Field{.{ .name = ":status", .value = "200" }}));
    try expectHttpMalformed(&[_]hpack.Field{ .{ .name = ":status", .value = "200" }, get_fields[0], get_fields[1], get_fields[2] });
}

fn expectLengthMalformed(declared: []const u8, body: []const u8) !void {
    var app = try httpApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .method = "POST", .path = "/size", .fields = &.{.{ .name = "content-length", .value = declared }}, .body = body });
    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.protocol_error, got.rst(1).?);
    try testing.expectEqual(@as(usize, 0), Answer.of(.headers, &got, 1).len);
}

test "a content-length the DATA does not add up to is a stream error PROTOCOL_ERROR, over and under (§8.1.1)" {
    try expectLengthMalformed("10", "hello");
    try expectLengthMalformed("3", "hello");
    var app = try httpApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .method = "POST", .path = "/size", .fields = &.{.{ .name = "content-length", .value = "5" }}, .body = "hello" });
    defer ex.deinit();
    try testing.expectEqualStrings("5", ex.body);
}

test "a malformed request resets its own stream and leaves the ones beside it alone" {
    var app = try httpApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .path = "/ping", .fields = &.{.{ .name = "connection", .value = "close" }} });
    try h2test.requestOn(&client, 3, .{ .path = "/ping" });
    const got = try converse(&app, &client);
    try testing.expectEqual(h2.ErrorCode.protocol_error, got.rst(1).?);
    var ex = try h2test.exchangeOf(got, 3);
    defer ex.deinit();
    try testing.expectEqualStrings("pong", ex.body);
}

test "CONNECT is answered 501, and no tunnel is made" {
    var app = try httpApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    var block: std.Io.Writer.Allocating = .init(testing.allocator);
    defer block.deinit();
    try hpack.writeLiteral(&block.writer, ":method", "CONNECT");
    try hpack.writeLiteral(&block.writer, ":authority", "example.test:443");
    try h2.writeHeaderBlock(client.w(), 1, block.written(), false, h2.default_max_frame);
    var ex = try h2test.exchangeOf(try converse(&app, &client), 1);
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 501), ex.status);
    try testing.expect(std.mem.indexOf(u8, ex.body, "CONNECT") != null);
    // The tunnel's bytes are not wanted: the client is told to stop sending them.
    try testing.expectEqual(h2.ErrorCode.no_error, ex.answer.rst(1).?);
}

/// A route that asks for what HTTP/2 cannot give until stage 6, and the call
/// it names in its sentence.
fn expectRefusedByName(method: []const u8, path: []const u8, call: []const u8) !void {
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try httpApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .method = method, .path = path, .body = if (std.mem.eql(u8, method, "POST")) "x" else "" });
    defer ex.deinit();
    // A 500 that says what was asked for, and never a 501 that would read as
    // the route's own answer.
    try testing.expectEqual(@as(u16, 500), ex.status);
    try testing.expect(std.mem.indexOf(u8, ex.body, call) != null);
    try testing.expect(std.mem.indexOf(u8, ex.body, "not available on HTTP/2 yet") != null);
}

test "a streamed answer, an event stream and a body stream are refused by name on HTTP/2" {
    try expectRefusedByName("GET", "/stream", "c.stream()");
    try expectRefusedByName("GET", "/events", "c.events()");
    try expectRefusedByName("POST", "/body-stream", "c.bodyStream()");
    try expectRefusedByName("GET", "/room", "c.eventsFrom()");
}

test "a WebSocket is refused by name on HTTP/2, and the sentence says it is HTTP/1.1" {
    try expectRefusedByName("GET", "/ws", "c.upgrade()");
    try expectRefusedByName("GET", "/ws", "a WebSocket is HTTP/1.1");
}

test "a file is refused by name on HTTP/2, and a HEAD of it, which sends none of it, is not" {
    var files = try OneFile.init();
    defer files.deinit();
    one_file = &files;
    defer one_file = null;
    try expectRefusedByName("GET", "/file", "c.sendFile()");

    var app = try httpApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .method = "HEAD", .path = "/file" });
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 200), ex.status);
    try testing.expectEqualStrings("10", ex.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), Answer.of(.data, &ex.answer, 1).len);
}

test "a request on HTTP/2 stays inside the heap allocations of one on HTTP/1.1, from its second on a connection" {
    var app = try httpApp();
    defer app.deinit();
    var counting = @import("budget.zig").Counting{ .child = testing.allocator };

    var results: [2]usize = undefined;
    for (&results, [_]usize{ 2, 12 }) |*r, requests| {
        var client = try TestClient.init();
        defer client.deinit();
        var id: u31 = 1;
        for (0..requests) |_| {
            try h2test.requestOn(&client, id, .{ .path = "/ping", .fields = &.{
                .{ .name = "user-agent", .value = "wrk" },
                .{ .name = "accept", .value = "*/*" },
                .{ .name = "accept-encoding", .value = "gzip" },
            } });
            id += 2;
        }
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(client.buf.written());
        var host = app.grpcHost();
        host.gpa = counting.allocator();
        counting.reset();
        serveConnection(host, &in, &out.writer, .off, .off, .{});
        r.* = counting.allocs;
    }
    // HTTP/1.1 reaches the general-purpose allocator for none of them once its
    // arena is warm, and one on HTTP/2 does not either: it reuses the stream
    // and the arena the one before kept (`spare_arena_keep`).
    try testing.expectEqual(@as(usize, 0), results[1] - results[0]);
}

test "a WINDOW_UPDATE on a stream nobody has opened is a connection error PROTOCOL_ERROR (§5.1)" {
    var app = try httpApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2.writeWindowUpdate(client.w(), 5, 10);
    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.protocol_error, got.goaway().?);
}

test "a stream that depends on itself is a stream error PROTOCOL_ERROR, by HEADERS and by PRIORITY (§5.3.1)" {
    var app = try httpApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    // HEADERS on stream 1 carrying PRIORITY, the dependency being stream 1.
    var block: std.Io.Writer.Allocating = .init(testing.allocator);
    defer block.deinit();
    for (get_fields) |f| try hpack.writeLiteral(&block.writer, f.name, f.value);
    try h2.writeHeader(client.w(), 5 + block.written().len, .headers, h2.Flags.end_headers | h2.Flags.end_stream | h2.Flags.priority, 1);
    try client.w().writeAll("\x00\x00\x00\x01\x10");
    try client.w().writeAll(block.written());
    // PRIORITY on stream 3 depending on stream 3, then an ordinary request.
    try h2.writeHeader(client.w(), 5, .priority, 0, 3);
    try client.w().writeAll("\x80\x00\x00\x03\x10");
    try h2test.requestOn(&client, 5, .{ .path = "/ping" });

    const got = try converse(&app, &client);
    try testing.expectEqual(h2.ErrorCode.protocol_error, got.rst(1).?);
    try testing.expectEqual(h2.ErrorCode.protocol_error, got.rst(3).?);
    try testing.expectEqual(@as(?h2.ErrorCode, null), got.goaway());
    var ex = try h2test.exchangeOf(got, 5);
    defer ex.deinit();
    try testing.expectEqualStrings("pong", ex.body);
}

test "DATA on a request the client already ended, whose answer is still being written, is a stream error STREAM_CLOSED (§5.1)" {
    var app = try httpApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    // A window of 0, so the answer waits and the stream is still there.
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 0 }});
    try h2test.requestOn(&client, 1, .{ .path = "/ping" });
    try h2.writeHeader(client.w(), 3, .data, 0, 1);
    try client.w().writeAll("abc");
    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.stream_closed, got.rst(1).?);
    try testing.expectEqual(@as(?h2.ErrorCode, null), got.goaway());
}

test "a GOAWAY from the client does not stop the frames it sent behind it from being answered" {
    var app = try httpApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2.writeHeader(client.w(), 8, .goaway, 0, 0);
    try client.w().writeAll("\x00\x00\x00\x00\x00\x00\x00\x00");
    try h2.writeHeader(client.w(), 8, .ping, 0, 0);
    try client.w().writeAll("h2spec  ");
    var got = try converse(&app, &client);
    defer got.deinit();
    var acked = false;
    for (got.frames.items) |f| {
        if (f.head.type == .ping and f.head.has(h2.Flags.ack)) acked = std.mem.eql(u8, f.payload, "h2spec  ");
    }
    try testing.expect(acked);
}

test "a SETTINGS_INITIAL_WINDOW_SIZE of 2^31-1, the most RFC 9113 §6.5.2 allows, is accepted" {
    var app = try httpApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, h2.max_window }});
    try h2test.requestOn(&client, 1, .{ .path = "/ping" });
    var ex = try h2test.exchangeOf(try converse(&app, &client), 1);
    defer ex.deinit();
    try testing.expectEqualStrings("pong", ex.body);
    try testing.expectEqual(@as(?h2.ErrorCode, null), ex.answer.goaway());
}
