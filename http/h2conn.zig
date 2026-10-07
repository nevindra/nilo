//! The HTTP/2 connection: one listener's connections, spoken as HTTP/2 with
//! prior knowledge, each request handed to the App as its fields and its body
//! ([ADR 220](../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md),
//! [ADR 253](../docs/adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md),
//! [ADR 259](../docs/adr/259-http2-is-a-framing-of-every-request.md),
//! [ADR 260](../docs/adr/260-a-request-on-http2-runs-from-its-headers.md)).
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
//! request's fields as its headers and its body as the pipe its `DATA` is
//! read through, which the App reads as it reads an HTTP/1.1 head and never
//! as text it has to parse back; and what the route answers goes back as
//! HEADERS, DATA frames under both windows and trailers when the route set
//! any. A request whose content type is `application/grpc` or
//! `application/grpc+…` is a call: its message has the length prefix and any
//! gzip taken off, its answer is framed and carries `grpc-status`, a route
//! that fails with a status is a call that fails with the gRPC code that
//! status means, and a path no route answers is `UNIMPLEMENTED`, which is
//! what the gRPC spec asks of a method a server does not have.
//!
//! **A request runs when its header block is whole** (ADR 260), as an
//! HTTP/1.1 request runs when its head is read, and its body is what the
//! client sends after: `DATA` is appended to the stream's buffer by this
//! file's fiber and read out by the request's, through `inbound.zig`'s pipe,
//! which parks the request's fiber while the buffer is empty and the stream
//! has not ended. A body that had arrived whole before it is asked for is
//! handed over where it lies. What the request has read is given back to
//! the client as `WINDOW_UPDATE` and to the connection's budget, a half
//! window at a time, so a stream holds at most its window of what nothing
//! has read. A whole answer is collected and framed after the request's
//! fiber has returned. A streamed answer, an event stream and a file are
//! written while it runs, through `outbound.zig`'s pipe: the handler lends its
//! buffer to this file's fiber, which writes `DATA` out of it under both
//! windows, a round of at most `pump_quantum` bytes to each stream that has
//! some, and wakes the handler when it has; a client that stops reading holds
//! the handler there until the write deadline resets the stream. An event
//! stream from Rooms is handed to the connection (`pumpEvents`, ADR 260): the
//! handler ends, the Rooms ring the connection's bell, and the connection
//! writes their posts in the same rotation as every other stream. A WebSocket
//! is refused by name by `Ctx`.
//!
//! **Unary only for gRPC.** A call carries one message each way. The message
//! is waited for on the call's fiber (`inbound.Inbox.whole`) and a gzip one is
//! inflated there, after the call has asked for room in the connection's
//! budget and been given it. Streaming calls hold a stream open for their
//! whole life, which is the one shape that costs a fiber for as long as it
//! lasts, and they wait for a caller (ADR 220).
//!
//! **One fiber reads and writes the socket; each request runs on a fiber of
//! its own.** The connection's fiber parses frames and hands each request, as
//! soon as its headers are in, to `bulkhead.spawnLocal`, which keeps it on
//! the connection's thread where the Engine can and deals it to another
//! where it cannot. The request's fiber runs the route into memory and hands
//! the answer back through a queue and a `Waker.post`, and the connection's
//! fiber writes it, as far as the flow-control windows allow; what a fiber
//! tells the other (window to give back, `100 Continue` to send, room in the
//! budget to grant) goes through the stream's pipe and the same waker, so no
//! two fibers ever write the socket, and a slow route never holds up the
//! frames of another call. A call in flight costs a fiber, 4,547 bytes and the
//! stack its route touches, which is what a request in flight on HTTP/1.1
//! costs already
//! ([`bench/result/http.md`](../bench/result/http.md#what-a-grpc-client-puts-on-the-wire-and-what-a-stream-would-cost)).
//! With no server running `spawnLocal` has nowhere to put one (`fallback`).
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
//! bytes, until one of them gives room back (ADR 220). A client that stops
//! sending a body is held to the bound a chunked HTTP/1.1 body is held to, on
//! the read that waits for it. Frames that move no call forward are counted,
//! and a flood is sent away. A client that stops reading while an answer
//! waits on its window is cut off at the write deadline.

const std = @import("std");
const builtin = @import("builtin");
const h2 = @import("h2.zig");
const hpack = @import("hpack.zig");
const bulkhead = @import("bulkhead.zig");
const fail = @import("fail.zig");
const encoded = @import("encoded.zig");
const core = @import("nilo_core");
const framing = @import("framing.zig");
const grpc = @import("grpc.zig");
const date = @import("date.zig");
const inbound = @import("inbound.zig");
const outbound = @import("outbound.zig");

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

/// Bytes of DATA written that earn the WINDOW_UPDATEs the flood count lets
/// pass: two (the connection's and the stream's) a `credit_bytes`, however
/// many frames they were written in. A frame of one byte earns a
/// thousandth of that, so a client with a window of one, which sends two
/// updates for each byte it is sent, is counted (ADR 220).
const credit_bytes = 1024;

/// The most DATA one stream's pipe gets written in a round, before the next
/// stream with something to send has its turn: what keeps one stream with a
/// large answer from holding the connection's writer while the others wait.
const pump_quantum = 64 * 1024;

/// The most the buffer an event is formatted in keeps once a turn is over: an
/// event larger than this is written from a buffer that is given back.
const scratch_keep = 16 * 1024;

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

/// What runs a call when no Engine does, which only a connection driven
/// through buffers (a test, `zig build profile`, the fuzzer) is. The request
/// that has a body to wait for needs a fiber to wait on, and without an
/// Engine a fiber is a thread.
pub const Fallback = enum {
    /// On the connection's own fiber, once its stream has ended: a call that
    /// can never wait, which is all a fiber of the connection's can be. What
    /// `zig build profile` times, since a thread would be what it measured.
    inline_when_ended,
    /// On a thread of its own, and the connection goes on only once every
    /// call that can run has run or is parked (`Conn.settle`): so a test is
    /// as deterministic as a server whose calls all run on the connection's
    /// thread, and what a call does while its connection reads is real.
    threads,
};

pub var fallback: Fallback = if (builtin.is_test) .threads else .inline_when_ended;

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
        .scratch = .init(app.gpa),
    };
    defer conn.deinit();
    deadlines.armWrite();
    conn.run();
}

/// What a call's fiber and the connection's fiber share: the queue of
/// answered calls, whether the connection is still there to write them, and
/// the lock their pipes are guarded by.
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
    /// What the calls' pipes are guarded by (ADR 260).
    monitor: bulkhead.Monitor = .init,
    /// A call has told the connection something through its pipe: bytes it
    /// has read, a `100 Continue` it wants sent, room it asks for.
    attention: std.atomic.Value(bool) = .init(false),
    /// Calls parked in a wait on their pipe.
    blocked: std.atomic.Value(u32) = .init(0),
    /// Calls run on threads of their own, with no Engine (`Fallback`): the
    /// connection settles after what could wake one.
    baton: bool = false,
    /// Streams whose call has opened an outbound pipe and whose connection has
    /// not let go of them: one load tells the connection whether any is there
    /// to write to.
    streaming: std.atomic.Value(u32) = .init(0),
    /// The connection will write nothing more (`abortOutbound`), guarded by
    /// `monitor`: a pipe a late call opens fails at once.
    dead: bool = false,
    /// Bytes of file buffers the calls of this connection hold now.
    file_held: std.atomic.Value(usize) = .init(0),

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

    /// What a pipe holds of this connection.
    fn link(s: *Shared) inbound.Link {
        return .{ .monitor = &s.monitor, .blocked = &s.blocked, .ctx = s, .poke = poke, .dead = &s.dead };
    }

    /// A call has something to tell the connection: said, and the
    /// connection woken, unless it has gone, which the call that is late
    /// to know cannot be allowed to post to.
    fn poke(ctx: *anyopaque) void {
        const s: *Shared = @ptrCast(@alignCast(ctx));
        s.acquire();
        defer s.release();
        if (s.closed) return;
        s.attention.store(true, .release);
        s.waker.post();
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
    /// The HEADERS frame that is arriving is the client's trailers, which
    /// end the stream (§8.1).
    trailing: bool = false,
    /// The client has more to send: no END_STREAM yet, and no reset.
    open: bool = true,
    /// What the client sends after its headers, as the call reads it
    /// (ADR 260). Guarded by the connection's monitor.
    inbox: inbound.Inbox,
    /// Every byte of DATA so far, and what the client said it would be, which
    /// the connection holds it to (§8.1.1).
    received: u64 = 0,
    announced: ?u64 = null,
    /// Bytes past the limit were dropped while the stream was collecting.
    over: bool = false,
    /// The stream's bytes are held for `Inbox.whole` and its window is given
    /// back as they arrive, as against read out and given back as they are.
    collecting: bool = false,
    /// The call reads its body through the pipe: the stream was not over
    /// when the call started, and it is not a gRPC call, whose message is
    /// read whole by the call's fiber before the route sees it.
    piped: bool = false,
    /// A call that cannot run until its stream has ended, with no Engine.
    deferred: bool = false,
    /// The call is to be cancelled rather than answered: its client was too
    /// slow sending it.
    cancel: bool = false,
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
    /// When the client has to have finished sending this call's header
    /// block, or 0 for no bound. `body_grace_ms + (max_body + 5) / body_min_rate`
    /// from the HEADERS frame: the rule a chunked HTTP/1.1 body is held to,
    /// sized from the most it may be because nothing says how much is coming
    /// (ADR 022).
    collect_until_ns: u64 = 0,
    /// Bytes the call may be given window for, since this stream's window was
    /// last topped up.
    unacked: u32 = 0,
    /// Bytes counted in the connection's `collected`: the message as it
    /// arrived, and once the call asks for it, its inflated copy. Given back
    /// as the call reads them, or when the call is let go of.
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
    /// The pipe a streamed answer is written through, published by the call
    /// once its head is out (`@atomicStore`) and null for a whole answer. In
    /// the arena, so a stream that never streams pays a pointer for it.
    out: ?*outbound.Outbox = null,
    /// When the piece the call lent first went unfinished at the connection's
    /// last look, or 0: what the write deadline is counted from. Only the
    /// connection's fiber touches it.
    stuck_since: u64 = 0,
    /// An event stream whose events the rooms post, handed to this connection
    /// by the call before it returned (ADR 227). Published by the call and
    /// read here only once the stream is `.writing`. From then on no fiber
    /// holds the stream: the rooms ring its bell and this fiber writes.
    events: ?framing.EventSource = null,
    /// The connection has counted it in `Conn.events_open` and given it its
    /// first turn, which writes the head.
    ev_seen: bool = false,
    ev_head: bool = false,
    /// The last turn left an event unfinished for want of window (or turn).
    ev_blocked: bool = false,
    /// A turn could not format an event: the stream was reset and is the
    /// connection's to forget once the round is over.
    ev_failed: bool = false,

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

    /// `running` is a call whose fiber has been given it, until its answer is
    /// handed back and `writing` starts.
    const State = enum { headers, running, writing };

    fn create(gpa: std.mem.Allocator, id: u31, app: Host, peer: bulkhead.Peer, shared: *Shared, send_window: i64) !*Stream {
        const s = try gpa.create(Stream);
        s.* = .{
            .id = id,
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .inbox = .init(gpa, shared.link(), app.max_body),
            .limit = app.max_body,
            .send_window = send_window,
            .app = app,
            .peer = peer,
            .shared = shared,
        };
        return s;
    }

    /// Give up every seat an event stream sits in, before its memory goes:
    /// the rooms ring a bell that lives in the stream's arena, and a seat is
    /// given up under the lock a post is pushed under.
    fn leaveEvents(s: *Stream) void {
        const source = s.events orelse return;
        s.events = null;
        source.leave(source.state);
    }

    fn destroy(s: *Stream) void {
        s.leaveEvents();
        if (s.out != null) _ = s.shared.streaming.fetchSub(1, .release);
        s.inbox.deinit();
        s.arena.deinit();
        s.gpa.destroy(s);
    }

    /// Ready for the connection's next call: the arena keeps up to
    /// `spare_arena_keep` bytes, the pipe a small buffer, and everything else
    /// is as `create` leaves it.
    fn recycle(s: *Stream) void {
        s.leaveEvents();
        if (s.out != null) _ = s.shared.streaming.fetchSub(1, .release);
        _ = s.arena.reset(.{ .retain_with_limit = spare_arena_keep });
        s.inbox.recycle(s.app.max_body);
        const kept = .{ s.gpa, s.arena, s.app, s.peer, s.shared, s.inbox };
        s.* = .{
            .id = 0,
            .gpa = kept[0],
            .arena = kept[1],
            .inbox = kept[5],
            .limit = kept[2].max_body,
            .send_window = 0,
            .app = kept[2],
            .peer = kept[3],
            .shared = kept[4],
        };
    }

    /// A streamed answer whose last frame is already written: the stream is
    /// over from this side, and anything the client sends on it now is
    /// ignored rather than answered, as for a stream already forgotten.
    fn answerEnded(s: *const Stream) bool {
        const o = @atomicLoad(?*outbound.Outbox, &s.out, .acquire) orelse return false;
        return o.isDone();
    }

    fn field(s: *const Stream, name: []const u8) ?[]const u8 {
        for (s.fields.items) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }

    /// Still being sent, and held for `Inbox.whole`: a call whose bytes need
    /// something more from the client before they can be given back.
    fn arriving(s: *const Stream) bool {
        return s.state != .headers and s.open and s.collecting;
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
    /// The client's trailers as they arrive. Kept here and not in the
    /// stream's arena, which the stream's call may be allocating from on
    /// another thread.
    trailer_block: std.ArrayList(u8) = .empty,
    last_stream: u31 = 0,

    /// What the client said, and where its windows stand.
    peer_window: i64 = h2.default_window,
    peer_max_frame: u32 = h2.default_max_frame,
    send_window: i64 = h2.default_window,
    /// Bytes of DATA read since the connection's window was last topped up.
    unacked: u32 = 0,
    /// Bytes of messages read and not yet given back, across every call: the
    /// bytes a pipe holds that nothing has read, and the copies a call was
    /// charged for. How many calls are owed a window the budget held back.
    collected: usize = 0,
    starved: u32 = 0,
    /// Some call asked for room in the budget and may still be waiting for it,
    /// so a connection with none skips looking.
    reserving: bool = false,
    /// What the client may still send on the connection before this side
    /// says more. A window is only a bound if it is held to.
    recv_window: i64 = h2.default_window,
    /// A stream used its whole turn at the last round and has more to send,
    /// so there is a round to run before anything waits.
    out_more: bool = false,
    /// Where the next round of `pumpOutputs` starts, so that the streams
    /// share a window between them in turn and the first in the table does
    /// not take every WINDOW_UPDATE.
    pump_next: usize = 0,
    /// Bytes of DATA written since the last credit was earned, below
    /// `credit_bytes`.
    out_bytes: usize = 0,
    /// When `overdue` last looked, so a connection that never waits looks
    /// about once a millisecond.
    overdue_at: u64 = 0,
    /// DATA frames written for streamed answers that no WINDOW_UPDATE has
    /// answered yet, at most `max_control_run`: each earns two updates (the
    /// connection's and the stream's) the flood count does not hold against the client, so a long answer's
    /// updates are not a flood and a flood of them with nothing sent is.
    out_credit: u32 = 0,
    /// Event streams handed to this connection that it has taken up
    /// (`Stream.ev_seen`): when it is all the streams there are, the
    /// connection is only waiting for the rooms, and gives its pages back as
    /// an idle one does (ADR 062).
    events_open: u32 = 0,
    /// Where an event is formatted before it is written, so one that does not
    /// fit a window is written from where it stopped. One for the connection,
    /// as large as the largest event it has carried (`scratch_keep`).
    scratch: std.Io.Writer.Allocating,

    goaway_sent: bool = false,
    peer_goaway: bool = false,
    peer_gone: bool = false,
    /// The fiber was cancelled while the server was stopping: the peer is
    /// still there, and what it is owed is written under a shield.
    cancelled: bool = false,
    released: bool = false,
    refused: u32 = 0,
    control_run: u32 = 0,
    /// When the oldest answer started waiting on a window, or 0.
    blocked_since: u64 = 0,
    /// When the last frame arrived. A header block still being sent with
    /// nothing arriving for `body_ms` is a client that stopped, as a head
    /// read that times out is on HTTP/1.1.
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
        // A call parked on its pipe is told it will get nothing more, so it
        // returns and gives its stream back; with no Engine each one is a
        // thread, which is waited for here so nothing outlives the allocator.
        c.abortInbound(true);
        c.abortOutbound();
        if (c.shared.baton) while (c.shared.running.load(.acquire) != 0) std.Thread.yield() catch {};
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
        c.trailer_block.deinit(c.gpa);
        c.dropSpares();
        c.scratch.deinit();
        c.decoder.deinit();
        // A call that has handed its stream back still has to let go of
        // `shared`, which a thread it runs on does a moment after.
        while (c.shared.running.load(.acquire) == 0 and c.shared.refs.load(.acquire) > 1) std.Thread.yield() catch {};
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
            // What the calls said first, so a `100 Continue` is written ahead
            // of the answer that follows it (§8.1).
            c.service() catch break;
            c.writeReady() catch break;
            c.admit() catch break;
            // An event stream never ends by itself, so a connection that is
            // going away ends them: the stream is told, and its seats go,
            // rather than the client finding the socket gone (ADR 019).
            if (c.events_open != 0 and (c.goaway_sent or c.peer_goaway)) c.endEvents() catch break;
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
                // A stream with more to send than its turn: the calls get
                // theirs, and the next round is its.
                if (c.out_more) {
                    // A stream has more to send than its turn: the calls get
                    // theirs, and the socket is looked at without waiting, so
                    // a connection that is only writing still reads the
                    // WINDOW_UPDATEs that keep a client going, a RST_STREAM,
                    // a PING or a GOAWAY (ADR 260).
                    bulkhead.yield();
                    switch (c.waker.poll()) {
                        .readable => {},
                        .posted => continue,
                        .closed => {
                            c.closedWake();
                            break;
                        },
                        .timed_out => {
                            const now = bulkhead.monotonicNanos();
                            if (now -| c.overdue_at >= std.time.ns_per_ms) {
                                c.overdue_at = now;
                                if (c.overdue() == .stop) break;
                            }
                            continue;
                        },
                    }
                } else {
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
            }
            c.released = false;
            c.readFrame() catch |err| {
                // Gone is a client that stopped sending, which may still be
                // reading: what it is owed is written on the way out.
                if (err != error.Gone) c.goawayFor(err);
                break;
            };
        }
        if (c.cancelled and c.events_open != 0) c.endCancelled();
        // Nothing more is read: a call still waiting for its body is told so.
        c.abortInbound(false);
        c.windDown();
    }

    const Waited = enum { readable, posted, again, stop };

    /// A wait ended `.closed`: the fiber was cancelled. A server that is
    /// stopping cancels its connections to end them, which is not the peer
    /// going, and a connection holding event streams owes them their end.
    fn closedWake(c: *Conn) void {
        if (c.app.stop.isRequested()) c.cancelled = true;
        c.peer_gone = true;
    }

    /// The last frames of a connection that was cancelled by a stop: GOAWAY,
    /// and each event stream's end, written once under a shield, because a
    /// cancelled fiber's writes would otherwise fail at once (ADR 019, 260).
    fn endCancelled(c: *Conn) void {
        bulkhead.beginShield();
        defer bulkhead.endShield();
        c.goaway(.no_error) catch return;
        c.endEvents() catch return;
        c.out.flush() catch {};
    }

    fn wait(c: *Conn) Waited {
        if (c.streams.items.len != 0) {
            // Something is in flight. A route that is running is waited for
            // as long as it takes: its own deadline is what bounds it. What
            // the client owes is not: an answer stuck on a window gets the
            // write limit, counted from when it first stuck rather than from
            // the last frame, and a header block still being sent gets its
            // own bound and `body_ms` between frames. A body being sent is
            // bounded by the read of the call that waits for it (ADR 260).
            const limit = c.inFlightLimitMs() orelse return .stop;
            if (c.events_open == c.streams.items.len) return c.waitQuiet(limit);
            return switch (c.waker.wait(limit)) {
                .readable => .readable,
                .posted => .posted,
                .timed_out => c.overdue(),
                .closed => blk: {
                    c.closedWake();
                    break :blk .stop;
                },
            };
        }
        if (!c.released) {
            switch (c.waker.wait(idle_peek_ms)) {
                .readable => return .readable,
                .posted => return .posted,
                .closed => {
                    c.closedWake();
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
                c.closedWake();
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

    /// A wait with nothing in flight but event streams: what an HTTP/1.1
    /// event stream does between events, once for the whole connection. A
    /// short peek, then the pages go back, and the wait is for a post, a frame,
    /// the next comment or a deadline. No idle timeout: a stream that is open
    /// is not idle, and ends when its client goes or the server stops.
    fn waitQuiet(c: *Conn, limit: u32) Waited {
        if (!c.released) {
            const peek = if (limit == 0) idle_peek_ms else @min(limit, idle_peek_ms);
            switch (c.waker.wait(peek)) {
                .readable => return .readable,
                .posted => {
                    // The pages come back after the next quiet stretch.
                    return .posted;
                },
                .closed => {
                    c.closedWake();
                    return .stop;
                },
                .timed_out => {
                    if (limit != 0 and limit <= idle_peek_ms) return c.overdue();
                    bulkhead.releaseIdlePages(c.in, c.out);
                    c.dropSpares();
                    c.scratch.deinit();
                    c.scratch = .init(c.gpa);
                    c.waker.releaseStack();
                    c.released = true;
                    return .again;
                },
            }
        }
        return switch (c.waker.wait(limit)) {
            .readable => .readable,
            .posted => blk: {
                c.released = false;
                break :blk .posted;
            },
            .timed_out => c.overdue(),
            .closed => blk: {
                c.closedWake();
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
            // A piece a client has not taken, which its call waits on.
            if (s.stuck_since != 0) {
                soonest = @min(soonest, s.stuck_since +| @as(u64, c.writeLimitMs()) * std.time.ns_per_ms);
            } else if (s.state == .writing) {
                // An event stream owes a comment when its quiet stretch is up.
                if (s.events) |ev| if (ev.keepalive_ms != 0) {
                    soonest = @min(soonest, ev.due_ns);
                };
            }
            if (s.state != .headers) continue;
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
            if (s.stuck_since != 0 and now -| s.stuck_since >= @as(u64, c.writeLimitMs()) * std.time.ns_per_ms) {
                // A client that stopped reading: its stream is cancelled, its
                // call's next write fails as it would on a dead socket, and
                // the connection and every other stream go on.
                h2.writeRstStream(c.out, s.id, .cancel) catch return .stop;
                if (@atomicLoad(?*outbound.Outbox, &s.out, .acquire)) |o| o.fail(.slow);
                // A stream whose call has returned is gone from the table.
                const gone = s.state == .writing;
                c.onReset(s);
                if (!gone) i += 1;
                continue;
            }
            if (s.state != .headers) {
                i += 1;
                continue;
            }
            if (s.collect_until_ns != 0 and now >= s.collect_until_ns) {
                // Too slow sending its header block. Not while that block is
                // unfinished: a reset would leave the table out of step, so
                // the connection is sent away. The silence limit below is no
                // bound on that, because every CONTINUATION resets it, and
                // one byte a frame held a slot for as long as
                // `max_header_block` lasted (ADR 220).
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
            // Nothing at all from a client that still owes a header block.
            c.goaway(.no_error) catch {};
            return .stop;
        }
        return .again;
    }

    /// The bound on sending one call's header block, from `now`.
    fn collectUntil(c: *const Conn, now: u64, bound: usize) u64 {
        const rate = c.deadlines.body_min_rate;
        if (rate == 0) return 0;
        const most: u64 = @as(u64, bound) + 5;
        const ms = @as(u64, c.deadlines.body_grace_ms) + most * std.time.ms_per_s / rate;
        return now +| ms * std.time.ns_per_ms;
    }

    /// How long a body asked for whole may take to arrive, in milliseconds
    /// from the read that waits for it: what `Deadlines.armBodyRun` allows
    /// `bytes` of a chunked HTTP/1.1 body, and none where that has none.
    fn runMs(c: *const Conn, bytes: usize) u32 {
        const rate = c.deadlines.body_min_rate;
        if (rate == 0 or c.deadlines.body_ms == 0) return 0;
        const ms = @as(u64, c.deadlines.body_grace_ms) +| @as(u64, bytes) * std.time.ms_per_s / rate;
        return @intCast(@min(ms, std.math.maxInt(u32)));
    }

    /// Wait for the calls still running, then write what they answered if
    /// there is anybody left to read it. A client that stopped sending may
    /// still be reading, so the calls waiting for room are started as the
    /// running ones give it back, until nothing more can move: room held by
    /// an answer stuck on a window comes back only with a WINDOW_UPDATE, and
    /// nothing is read from here on. With nobody reading, a call waiting for
    /// room is not run at all, since what it answers would go nowhere.
    fn windDown(c: *Conn) void {
        while (!c.peer_gone) {
            c.flushReady() catch {
                c.peer_gone = true;
                break;
            };
            const started = c.admitAll() catch {
                c.peer_gone = true;
                break;
            };
            if (started != 0 or c.out_more) continue;
            // A piece waiting on a window that nothing is left to open is not
            // going to move, and the call that lent it is told so.
            c.failStuck();
            // What can still move is a call that is running its route, which
            // gives back what it holds when it returns; a call that waits for
            // room moves only when one does, and nobody is reading answers.
            if (c.shared.running.load(.acquire) == c.reservationWaiters()) break;
            bulkhead.sleep(1) catch break;
        }
        c.abortInbound(true);
        while (c.shared.running.load(.acquire) != 0) {
            if (c.out_more) bulkhead.yield() else bulkhead.sleep(1) catch break;
            if (!c.peer_gone) c.flushReady() catch {
                c.peer_gone = true;
            };
            if (c.peer_gone) c.abortOutbound() else c.failStuck();
        }
        if (!c.peer_gone) c.flushReady() catch {};
    }

    /// How many calls are waiting to be given room in the budget.
    fn reservationWaiters(c: *const Conn) u32 {
        var n: u32 = 0;
        for (c.streams.items) |s| {
            if (s.state == .running and s.inbox.wanted() != 0) n += 1;
        }
        return n;
    }

    /// Tell the calls waiting on a stream that the rest of it is not coming:
    /// the ones whose body is still arriving, and, with `everything`, the ones
    /// that wait for room too, which nobody is left to read the answer of.
    fn abortInbound(c: *Conn, everything: bool) void {
        for (c.streams.items) |s| {
            if (s.state != .running) continue;
            if (s.open or everything) s.inbox.fail(.gone);
        }
        c.settle();
    }

    /// Wait for the calls that can run to have run: finished, or parked on
    /// their pipe. A no-op where an Engine runs them, and where one thread
    /// each does it is what makes the connection's order of events the
    /// calls' too (`Fallback.threads`).
    fn settle(c: *Conn) void {
        if (!c.shared.baton) return;
        const started = bulkhead.monotonicNanos();
        while (c.shared.running.load(.acquire) != c.shared.blocked.load(.acquire)) {
            std.Thread.yield() catch {};
            if (bulkhead.monotonicNanos() -| started > 30 * std.time.ns_per_s) {
                std.log.warn("a call on a thread of its own neither finished nor parked in 30 s", .{});
                return;
            }
        }
    }

    fn flushReady(c: *Conn) !void {
        try c.service();
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

    /// One frame, and then what the calls have said while it was read: what
    /// they gave back, a `100 Continue` they asked for, room they want.
    fn readFrame(c: *Conn) ReadError!void {
        try c.readOne();
        try c.service();
        try c.admit();
    }

    fn readOne(c: *Conn) ReadError!void {
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
                    // A call reset before it was whole cost a header block
                    // decoded and a stream made, and bought nothing: HEADERS
                    // then RST_STREAM, over and over, is a flood like PING.
                    if (s.state == .headers or (s.state == .running and s.open)) try c.control();
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
    /// before it was whole. Only a request whose client has sent all of it
    /// starts the count again, so opening a stream in between does not.
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

        // Trailers from the client, on a call still receiving its body.
        if (c.find(head.stream)) |s| {
            // A stream reset and still running has trailers in flight to it
            // from a client that has not yet seen the reset: decoded, because
            // the table must stay in step, and ignored (`trailersDone`).
            if (s.state == .headers or (!s.open and !s.reset)) return error.Protocol;
            if (!head.has(h2.Flags.end_stream)) return error.Protocol;
            c.trailer_block.clearRetainingCapacity();
            s.trailing = true;
            try c.appendBlockBytes(s, len);
            try c.discard(pad);
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
        const block = if (s.trailing) &c.trailer_block else &s.block;
        if (block.items.len + len > max_header_block) return error.Calm;
        // The stream's arena is the call's once it runs, so the client's
        // trailers are not put in it.
        const from = if (s.trailing) c.gpa else s.arena.allocator();
        const dest = block.addManyAsSlice(from, len) catch return error.Internal;
        c.in.readSliceAll(dest) catch return error.Gone;
    }

    /// The header block is whole: decode it, and run the call. Or, when it
    /// was the client's trailers, the stream ends.
    fn headersDone(c: *Conn, s: *Stream) ReadError!void {
        c.continuing = null;
        if (s.trailing) return c.trailersDone(s);
        const arena = s.arena.allocator();
        const decoded = c.decoder.decode(s.block.items, arena, &s.fields, max_header_list) catch |err| switch (err) {
            error.Compression => return error.Compression,
            error.OutOfMemory => return error.Internal,
        };
        if (decoded.over_limit) s.headers_over_limit = true;

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
        // body is held to that (ADR 156, ADR 220). Nothing is looked up for a
        // call with no path, which `dispatch` refuses.
        if (s.field(":path")) |path| {
            s.limit = c.app.body_limit(c.app.ptr, s.field(":method") orelse "", path);
        }
        s.grpc = grpc.isGrpcContentType(s.field("content-type") orelse "");
        s.open = !s.ends_with_headers;
        return c.dispatch(s);
    }

    /// The client's trailers are decoded, because the table has to stay in
    /// step, and what they said is nothing the route reads: they end the
    /// stream.
    fn trailersDone(c: *Conn, s: *Stream) ReadError!void {
        s.trailing = false;
        var scratch_arena = std.heap.ArenaAllocator.init(c.gpa);
        defer scratch_arena.deinit();
        var scratch: std.ArrayList(hpack.Field) = .empty;
        _ = c.decoder.decode(c.trailer_block.items, scratch_arena.allocator(), &scratch, max_header_list) catch |err| switch (err) {
            error.Compression => return error.Compression,
            error.OutOfMemory => return error.Internal,
        };
        c.trailer_block.clearRetainingCapacity();
        // An answer already being written, or a stream reset, has nobody to
        // read them.
        if (s.reset) return;
        if (s.state == .writing) {
            s.open = false;
            return;
        }
        return c.endInbound(s);
    }

    fn onData(c: *Conn, head: h2.Header) ReadError!void {
        if (head.stream == 0) return error.Protocol;
        var len: usize = head.len;
        // The whole frame counts against the window, padding included (§6.9),
        // and a client that sends past a window it was given is not sending
        // HTTP/2 (§6.9.1): the budget below is only a bound if this is held.
        c.recv_window -= head.len;
        if (c.recv_window < 0) return error.FlowControl;
        // The connection's window is given back as the bytes arrive, and a
        // stream's as they are read: a stream whose handler does not read
        // cannot stop the others from sending (ADR 260).
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
        if (s.state == .headers) {
            try c.discard(len + pad);
            return error.Protocol;
        }
        if (s.reset) {
            // Reset, by either side, and still running: what is in flight is
            // thrown away and nothing is said, as for a forgotten stream. An
            // RST for every frame would be a client making this side write.
            try c.discard(len + pad);
            if (len == 0) try c.control();
            return;
        }
        if (!s.open) {
            try c.discard(len + pad);
            // A streamed answer whose end is already written has nothing
            // left to say to a client that sends after its own end: the
            // stream is over from this side, and a reset would be a frame
            // after the END_STREAM, as for a forgotten stream (above).
            if (s.answerEnded()) {
                if (len == 0) try c.control();
                return;
            }
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
        s.received += len;
        const end_stream = head.has(h2.Flags.end_stream);

        if (s.state == .writing) {
            // Answered, or being, before the client has finished: nothing
            // reads it. Said once the answer is out, with a reset (§8.1).
            try c.discard(len + pad);
            if (end_stream) s.open = false;
            return;
        }

        const slot = s.inbox.begin(len) catch return error.Internal;
        c.in.readSliceAll(slot.dest) catch return error.Gone;
        if (slot.drop > 0) {
            // Past the call's limit: read and dropped, so the connection stays
            // in step, and the call told so when it looks (`Inbox.whole`).
            try c.discard(slot.drop);
            s.over = true;
        }
        c.hold(s, slot.dest.len);
        try c.discard(pad);
        // Whether the stream is collecting is decided here, under the pipe's
        // lock: the call may have asked for the whole body since `begin`, and
        // then its limit applies to this frame and its window is given back
        // by what arrived.
        const done = s.inbox.commit(slot.dest.len, slot.drop);
        if (done.kept < slot.dest.len) {
            const back = slot.dest.len - done.kept;
            s.held -= back;
            c.collected -= back;
            s.over = true;
        }
        c.settle();
        s.collecting = done.collecting;
        // More than the client said it would send (§8.1.1).
        if (s.announced) |said| if (s.received > said) return c.lengthMismatch(s);
        if (end_stream) return c.endInbound(s);
        // What nothing reads out is given back as it arrives, and the
        // padding of what is read out, which no read will count.
        if (done.collecting) {
            try c.credit(s, head.len);
        } else if (head.len > len) try c.credit(s, head.len - len);
    }

    /// The client has sent all of the request: its body is whole, and the
    /// call waiting for it is woken. Held to what it said its length was.
    fn endInbound(c: *Conn, s: *Stream) ReadError!void {
        if (s.announced) |said| if (s.received != said) return c.lengthMismatch(s);
        s.open = false;
        c.unstarve(s);
        // A request whose client has sent it all is a request moved forward,
        // which is what ends a run of frames that moved nothing.
        c.control_run = 0;
        s.inbox.end();
        c.settle();
        if (s.deferred) {
            s.deferred = false;
            return c.start(s);
        }
    }

    /// The DATA did not add up to the `content-length` the client sent: a
    /// stream error (§8.1.1), after the call that was waiting for the body
    /// has been woken to say so.
    fn lengthMismatch(c: *Conn, s: *Stream) ReadError!void {
        h2.writeRstStream(c.out, s.id, .protocol_error) catch return error.Gone;
        s.inbox.fail(.length);
        c.settle();
        c.onReset(s);
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
    /// nothing more from the client either, and `admitReservations` always
    /// lets the oldest one start once no running call holds bytes.
    fn mayGrow(c: *const Conn, s: *const Stream) bool {
        if (c.collected < c.budget() or s.over) return true;
        for (c.streams.items) |x| {
            if (!x.arriving() and x.state != .headers and x.held > 0) return false;
        }
        for (c.streams.items) |x| if (x.arriving()) return x == s;
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

    /// `n` more bytes of the stream's window may be given back: now, once a
    /// half window of it is owed and the budget has room, and when it has
    /// room otherwise.
    fn credit(c: *Conn, s: *Stream, n: usize) ReadError!void {
        s.unacked += @intCast(n);
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

    /// A call has been let go of: answered, refused or reset. Its bytes
    /// leave the budget. **Not when it starts**: a running call still holds
    /// what it has been charged for until its answer is written, and giving
    /// them back at the start let a hundred calls to a slow route hold a
    /// hundred messages while the budget said one (ADR 220).
    fn letGo(c: *Conn, s: *Stream) void {
        c.collected -= s.held;
        s.held = 0;
        c.unstarve(s);
    }

    /// Whether a call that has started still holds bytes it will give back
    /// with nothing more from the client: running with its message whole, or
    /// its answer being written, and not waiting for room.
    fn startedHolds(c: *const Conn) bool {
        for (c.streams.items) |x| {
            if (x.held == 0 or x.arriving() or x.state == .headers) continue;
            if (x.inbox.wanted() != 0) continue;
            return true;
        }
        return false;
    }

    /// Say yes to the calls waiting for room, oldest first, for as long as
    /// each one's inflated copy fits in what the budget has left. **The
    /// oldest starts whatever the room once no started call holds bytes**:
    /// nothing else would give any back, since the other waiting calls hold
    /// only their compressed bytes and the calls still arriving are held to
    /// their windows, so without it a few waiting calls could fill the budget
    /// with none able to start. That is the same rule `mayGrow` keeps for the
    /// oldest call still arriving, and it bounds the connection at the
    /// budget and one more call's copies. Strictly in order: a call that
    /// fits does not pass one that does not, or a stream of small calls
    /// would keep a large one waiting for good. How many were let start.
    fn admitReservations(c: *Conn) ReadError!usize {
        var started: usize = 0;
        while (true) {
            var oldest: ?*Stream = null;
            var room: usize = 0;
            for (c.streams.items) |x| {
                if (x.state != .running) continue;
                room = x.inbox.wanted();
                if (room != 0) {
                    oldest = x;
                    break;
                }
            }
            const s = oldest orelse {
                c.reserving = false;
                return started;
            };
            if (room > c.budgetLeft(s) and c.startedHolds()) return started;
            if (s.inbox.grant(room)) {
                c.hold(s, room);
                started += 1;
                c.settle();
            }
        }
    }

    /// What the calls have said, and the room they asked for: both, in the
    /// order a call needs them.
    fn admit(c: *Conn) ReadError!void {
        _ = try c.admitAll();
    }

    fn admitAll(c: *Conn) ReadError!usize {
        const started = if (c.reserving) try c.admitReservations() else 0;
        try c.grantWaiting();
        return started;
    }

    /// What the calls have told this fiber through their pipes: bytes they
    /// read, which are the budget's again and the client's window, and a
    /// `100 Continue` they asked for. One flag to look at when none has.
    fn service(c: *Conn) ReadError!void {
        if (!c.shared.attention.swap(false, .acq_rel)) return;
        for (c.streams.items) |s| {
            if (s.state != .running) continue;
            const said = s.inbox.take();
            s.collecting = said.collecting;
            if (said.freed > 0) {
                const give = @min(said.freed, s.held);
                s.held -= give;
                c.collected -= give;
            }
            if (said.owed > 0 and s.open) try c.credit(s, said.owed);
            // Interim, so before the final head, which cannot be written
            // before the call that asked has returned (§8.1).
            if (said.cont and s.open and !s.head_sent and !c.answerStarted(s)) {
                h2.writeHeaderBlock(c.out, s.id, continue_block, false, c.peer_max_frame) catch return error.Gone;
            }
            if (said.want > 0) c.reserving = true;
        }
    }

    /// The call has begun its answer through its pipe, which makes any interim
    /// answer too late.
    fn answerStarted(c: *const Conn, s: *Stream) bool {
        _ = c;
        const o = @atomicLoad(?*outbound.Outbox, &s.out, .acquire) orelse return false;
        return o.started();
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
    /// until it reads them or `letGo`.
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
        if (!c.writing() and !c.spendCredit()) try c.control();
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
        // A streamed answer whose end is written has no window to give.
        if (s.answerEnded()) return;
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

    /// The client reset the stream, or this side did. A call that is still
    /// running keeps its stream until it returns and is told the rest is not
    /// coming; one that is not is freed at once.
    fn onReset(c: *Conn, s: *Stream) void {
        switch (s.state) {
            // Its fiber owns it until it hands it back; the answer is
            // dropped then. What it was still being sent goes back to the
            // budget now, or `collected` keeps a dead call's bytes until its
            // route returns and the calls beside it wait on a window nothing
            // is left to give back (ADR 220).
            .running => {
                s.reset = true;
                if (s.open) {
                    s.open = false;
                    c.letGo(s);
                }
                s.inbox.fail(.gone);
                s.stuck_since = 0;
                // A call parked in a write wakes with an error, and what it
                // lent is never read again.
                if (@atomicLoad(?*outbound.Outbox, &s.out, .acquire)) |o| o.fail(.reset);
                c.settle();
            },
            // Still arriving or already written: what it held of the
            // budget goes back now.
            .headers, .writing => {
                c.letGo(s);
                c.remove(s);
                s.destroy();
            },
        }
    }

    /// A WINDOW_UPDATE for a streamed answer that this side has written DATA
    /// for, which is progress and not a frame read for nothing.
    fn spendCredit(c: *Conn) bool {
        if (c.out_credit == 0) return false;
        c.out_credit -= 1;
        return true;
    }

    fn writing(c: *const Conn) bool {
        // An event stream is always writing, and a WINDOW_UPDATE for it is
        // progress only because of the bytes written to it (`earnCredit`).
        for (c.streams.items) |s| if (s.state == .writing and s.events == null) return true;
        return false;
    }

    fn find(c: *const Conn, id: u31) ?*Stream {
        for (c.streams.items) |s| if (s.id == id) return s;
        return null;
    }

    fn remove(c: *Conn, s: *Stream) void {
        if (s.ev_seen) {
            s.ev_seen = false;
            c.events_open -= 1;
        }
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

    /// The request's headers are whole. Check it, and run it: as HTTP, or,
    /// when its content type says it is a gRPC call, with its message taken
    /// out of its framing on the call's fiber (ADR 259, ADR 260).
    fn dispatch(c: *Conn, s: *Stream) ReadError!void {
        c.unstarve(s);
        if (s.headers_over_limit) {
            if (!s.grpc) return c.answerStatus(s, 431, "the request's header fields are larger than this server reads");
            return c.answerNow(s, 8, "the call's metadata is larger than this server reads");
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
        s.announced = announcedLength(s.fields.items) catch return c.malformed(s);
        // A request that ends with its headers sends no body, whatever it said.
        if (!s.open and (s.announced orelse 0) != 0) return c.malformed(s);

        // A request with nothing to wait for is a request moved forward,
        // which ends a run of frames that moved nothing. Not before this
        // point, where a request refused as malformed would end it for the
        // cost of one HEADERS frame, and 999 PINGs between two of them would
        // never be a flood; and not for one whose body is still to come,
        // which ends it when it has (`endInbound`).
        if (!s.open) c.control_run = 0;

        if (s.grpc) {
            if (!c.app.routes(c.app.ptr, path))
                return c.answerNow(s, 12, "no route answers this method");
            if (s.field("grpc-timeout")) |text| {
                s.until_ns = grpc.untilNs(text, s.headers_ns) catch return c.refuse(s, grpc.bad_timeout);
            }
        }
        s.piped = s.open and !s.grpc;
        return c.start(s);
    }

    /// Hand the call its pipe, as far as it is told about now, and run it.
    fn armInbox(c: *Conn, s: *Stream) void {
        const prefix: usize = if (s.grpc) grpc.prefix_len else 0;
        s.inbox.limit = s.limit + prefix;
        s.inbox.run_ms = c.runMs(s.limit + prefix);
        s.inbox.silence_ms = c.deadlines.body_ms;
        s.inbox.until_ns = s.until_ns;
        // A gRPC message is read whole, and its window given back as it
        // arrives: nothing reads it out.
        if (s.grpc and !s.collecting) {
            s.collecting = true;
            s.inbox.collecting = true;
        }
        if (!s.open) s.inbox.end();
    }

    /// Run a call whose headers are whole: on a fiber of its own, which
    /// reads what the client has still to send through the stream's pipe.
    fn start(c: *Conn, s: *Stream) ReadError!void {
        c.armInbox(s);
        s.state = .running;
        _ = s.shared.running.fetchAdd(1, .acquire);
        s.shared.retain();
        bulkhead.spawnLocal(runCall, .{ s, true }) catch |err| switch (err) {
            // No server: a test driving the connection through buffers.
            error.NoServer => return c.startWithoutEngine(s),
            // The server is stopping, and has nowhere to put a fiber.
            else => {
                _ = s.shared.running.fetchSub(1, .release);
                s.shared.drop();
                s.state = .headers;
                return c.answerNow(s, 14, "the server is stopping");
            },
        };
        c.settle();
    }

    fn startWithoutEngine(c: *Conn, s: *Stream) ReadError!void {
        switch (fallback) {
            .inline_when_ended => {
                // A call that can wait has nothing to wait on: it runs when
                // the stream has ended, which is when its body is whole.
                if (s.open) {
                    _ = s.shared.running.fetchSub(1, .release);
                    s.shared.drop();
                    s.deferred = true;
                    return;
                }
                s.inbox.can_park = false;
                runCall(s, false);
            },
            .threads => {
                c.shared.baton = true;
                const thread = std.Thread.spawn(.{}, callThread, .{s}) catch {
                    _ = s.shared.running.fetchSub(1, .release);
                    s.shared.drop();
                    s.state = .headers;
                    return c.answerNow(s, 14, "the call could not be given a thread");
                };
                thread.detach();
                c.settle();
            },
        }
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
            // Too slow sending: cancelled, and not answered (§8.1's reset
            // for a stream that will not be completed).
            if (s.cancel) {
                try h2.writeRstStream(c.out, s.id, .cancel);
                c.forget(s);
                continue;
            }
            s.state = .writing;
        }
        // Whole answers first: they are finite, and a streamed one that has
        // the connection's window every round would leave them none, and the
        // connection waiting on them past the write limit.
        var i: usize = 0;
        var blocked = false;
        while (i < c.streams.items.len) {
            const s = c.streams.items[i];
            if (s.state != .writing) {
                i += 1;
                continue;
            }
            if (s.events) |*ev| if (!s.ev_seen) c.takeEvents(s, ev);
            if (s.out) |o| {
                // Streamed, and its call has returned: written by the pump
                // below, and let go of here once its end is out.
                i += 1;
                _ = o;
                continue;
            }
            if (try c.writeStream(s)) continue;
            blocked = true;
            i += 1;
        }
        if (blocked) {
            if (c.blocked_since == 0) c.blocked_since = bulkhead.monotonicNanos();
        } else c.blocked_since = 0;
        try c.pumpOutputs();
        if (c.events_open != 0) try c.heartbeats();
        // Streamed answers whose call returned and whose end is written.
        i = 0;
        while (i < c.streams.items.len) {
            const s = c.streams.items[i];
            // An event stream is let go of when it ends, which is not here.
            if (s.state == .writing and s.events == null) if (s.out) |o| if (try c.settleReturned(s, o)) continue;
            i += 1;
        }
    }

    /// An event stream handed over by a call that has returned: counted, its
    /// client's side shut (anything it sends on the stream from here is a
    /// stream error, as on a stream whose request has ended, which is "a
    /// client that speaks has gone" for HTTP/1.1's reader), and its first
    /// comment due a quiet stretch from now.
    fn takeEvents(c: *Conn, s: *Stream, ev: *framing.EventSource) void {
        s.ev_seen = true;
        c.events_open += 1;
        if (s.open) {
            s.open = false;
            c.letGo(s);
        }
        s.inbox.fail(.gone);
        ev.due_ns = bulkhead.monotonicNanos() +| @as(u64, ev.keepalive_ms) * std.time.ns_per_ms;
    }

    /// Write as much of one answer as the windows allow. True when it is all
    /// gone and the stream has been let go of.
    fn writeStream(c: *Conn, s: *Stream) !bool {
        if (!s.head_sent) {
            try h2.writeHeaderBlock(c.out, s.id, s.head_block, s.trailers_only, c.peer_max_frame);
            s.head_sent = true;
            if (s.trailers_only) return c.finished(s);
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
        return c.finished(s);
    }

    // ---- the outbound pipes ----

    /// Write what the calls that are running have lent: a round of at most
    /// `pump_quantum` bytes to each stream that has some. A stream that used
    /// its whole turn with more to send sets `out_more`, and the connection
    /// runs another round, after the other fibers have had theirs, before it
    /// waits: so one stream with a large answer takes turns with the others,
    /// and a call whose piece was written goes on while the large one is
    /// still being sent.
    fn pumpOutputs(c: *Conn) !void {
        c.out_more = false;
        if (c.shared.streaming.load(.acquire) == 0) return;
        const n = c.streams.items.len;
        if (n == 0) return;
        // From where the last round stopped: the stream that used the window
        // up goes last the next time, and every stream's turn comes.
        const first = c.pump_next % n;
        var last: ?usize = null;
        for (0..n) |k| {
            const at = (first + k) % n;
            const s = c.streams.items[at];
            // An event stream is written in the same rotation as every other,
            // so a stream that posts a great deal takes its turn and no more.
            if (s.state == .writing) if (s.events) |*ev| {
                switch (try c.pumpEvents(s, ev)) {
                    .idle => {},
                    .moved => last = at,
                    .more => {
                        last = at;
                        c.out_more = true;
                    },
                }
                continue;
            };
            const o = @atomicLoad(?*outbound.Outbox, &s.out, .acquire) orelse continue;
            // Reset before its call began to answer: nothing of it is
            // written, and the call is told on its first write.
            if (s.reset) {
                o.fail(.reset);
                continue;
            }
            switch (try c.pump(s, o)) {
                .idle => {},
                .moved => last = at,
                .more => {
                    last = at;
                    c.out_more = true;
                },
            }
        }
        if (last) |at| c.pump_next = at + 1;
        // Event streams that could not be written, reset above.
        var i: usize = 0;
        while (i < c.streams.items.len) {
            const s = c.streams.items[i];
            if (s.ev_failed) c.forget(s) else i += 1;
        }
    }

    const Pumped = enum { idle, moved, more };

    /// One stream's turn: its head if it has not gone, as much of the piece
    /// its call lent as both windows and the quantum allow, and the end of its
    /// body when that is all written. Nothing here waits, and nothing is held
    /// while a byte is written: what the call lent is read without the lock,
    /// because the call is parked until this fiber wakes it.
    fn pump(c: *Conn, s: *Stream, o: *outbound.Outbox) !Pumped {
        const work = o.take();
        if (work.over) return .idle;
        var moved = false;
        if (work.head) |block| {
            try h2.writeHeaderBlock(c.out, s.id, block, false, c.peer_max_frame);
            o.headWritten();
            moved = true;
        }
        var complete = !work.pending;
        var quantum: usize = pump_quantum;
        if (work.pending) {
            var sent = work.sent;
            while (sent < work.lent.len and quantum > 0) {
                const room = @min(c.send_window, s.send_window);
                if (room <= 0) break;
                const n: usize = @intCast(@min(@as(i64, @intCast(work.lent.len - sent)), room, c.peer_max_frame, @as(i64, @intCast(quantum))));
                try h2.writeHeader(c.out, n, .data, 0, s.id);
                try work.lent.write(c.out, sent, n);
                sent += n;
                quantum -= n;
                c.send_window -= @intCast(n);
                s.send_window -= @intCast(n);
                c.out_bytes += n;
                moved = true;
            }
            complete = sent == work.lent.len;
            if (sent != work.sent or complete) o.wrote(sent, complete);
            c.earnCredit();
            // The deadline is for a client that is not taking the answer: it
            // runs from the last time bytes went, and stops when a piece is
            // written whole. A piece that is large and honestly slow is
            // therefore not cut while it is moving, and one that is only
            // waiting for its turn after a full quantum is not stuck.
            if (complete) {
                s.stuck_since = 0;
            } else if (sent != work.sent or s.stuck_since == 0) s.stuck_since = bulkhead.monotonicNanos();
        }
        if (work.ending and complete) {
            if (work.head_only) {
                // A HEAD: the head is the answer, and ends the stream, with no
                // trailers, which belong to a body there is not.
                try h2.writeHeaderBlock(c.out, s.id, o.head, true, c.peer_max_frame);
            } else if (work.trailers.len > 0) {
                try h2.writeHeaderBlock(c.out, s.id, work.trailers, true, c.peer_max_frame);
            } else try h2.writeHeader(c.out, 0, .data, h2.Flags.end_stream, s.id);
            o.ended();
            s.stuck_since = 0;
            return .moved;
        }
        if (!complete and quantum == 0) return .more;
        return if (moved) .moved else .idle;
    }

    /// One event stream's turn: its head if it has not gone, then what the
    /// rooms posted, as far as both windows and the quantum allow. **Nothing
    /// here waits and nothing is lent**: the stream holds a reference to the
    /// post it is partway through and an offset, and a client that stops
    /// reading leaves the rest in its seats' rings, under the policy the room
    /// names (ADR 227). The deadline is the outbound pipe's: it runs from the
    /// last time bytes of the stream went, and a stream with something held
    /// that takes nothing for the write limit is reset (`overdue`).
    fn pumpEvents(c: *Conn, s: *Stream, ev: *framing.EventSource) !Pumped {
        var moved = false;
        if (!s.ev_head) {
            s.ev_head = true;
            if ((try c.pump(s, s.out.?)) != .idle) moved = true;
        }
        var wire: framing.EventWire = .{
            .conn = c,
            .stream = s,
            .scratch = &c.scratch,
            .gpa = c.gpa,
            .quantum = pump_quantum,
            .put = putEvent,
            .room = roomEvent,
        };
        const outcome = ev.step(ev.state, &wire) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            // No room to format an event: this stream is reset, the others
            // go on (the round forgets it).
            error.OutOfMemory => {
                try h2.writeRstStream(c.out, s.id, .internal_error);
                s.ev_failed = true;
                s.ev_blocked = false;
                return .idle;
            },
        };
        if (c.scratch.writer.buffer.len > scratch_keep) {
            c.scratch.deinit();
            c.scratch = .init(c.gpa);
        }
        const wrote = pump_quantum - wire.quantum;
        if (wrote > 0) {
            moved = true;
            c.earnCredit();
        }
        s.ev_blocked = outcome == .blocked;
        switch (outcome) {
            .drained => s.stuck_since = 0,
            .blocked => if (wrote > 0 or s.stuck_since == 0) {
                s.stuck_since = bulkhead.monotonicNanos();
            },
        }
        if (wrote > 0 and ev.keepalive_ms != 0) {
            ev.due_ns = bulkhead.monotonicNanos() +| @as(u64, ev.keepalive_ms) * std.time.ns_per_ms;
        }
        if (outcome == .blocked and wire.quantum == 0) return .more;
        return if (moved) .moved else .idle;
    }

    /// `EventWire.put`: DATA frames for as much of `bytes` as both windows,
    /// the frame size and the turn allow.
    fn putEvent(wire: *framing.EventWire, bytes: []const u8) std.Io.Writer.Error!usize {
        const c: *Conn = @ptrCast(@alignCast(wire.conn));
        const s: *Stream = @ptrCast(@alignCast(wire.stream));
        var sent: usize = 0;
        while (sent < bytes.len and wire.quantum > 0) {
            const room = @min(c.send_window, s.send_window);
            if (room <= 0) break;
            const n: usize = @intCast(@min(@as(i64, @intCast(bytes.len - sent)), room, c.peer_max_frame, @as(i64, @intCast(wire.quantum))));
            try h2.writeHeader(c.out, n, .data, 0, s.id);
            try c.out.writeAll(bytes[sent..][0..n]);
            sent += n;
            wire.quantum -= n;
            c.send_window -= @intCast(n);
            s.send_window -= @intCast(n);
            c.out_bytes += n;
        }
        return sent;
    }

    fn roomEvent(wire: *const framing.EventWire) usize {
        const c: *Conn = @ptrCast(@alignCast(wire.conn));
        const s: *Stream = @ptrCast(@alignCast(wire.stream));
        const room = @min(c.send_window, s.send_window);
        return if (room <= 0) 0 else @min(@as(usize, @intCast(room)), wire.quantum);
    }

    /// The comment each event stream owes when it has said nothing for its
    /// `keepalive_ms`: three bytes, the least a proxy counts as the connection
    /// speaking. A stream with something held is not quiet, and one whose
    /// window has no room for three bytes is not owed one now.
    fn heartbeats(c: *Conn) !void {
        const now = bulkhead.monotonicNanos();
        for (c.streams.items) |s| {
            if (s.state != .writing) continue;
            const ev = if (s.events) |*e| e else continue;
            if (ev.keepalive_ms == 0 or now < ev.due_ns or s.stuck_since != 0) continue;
            ev.due_ns = now +| @as(u64, ev.keepalive_ms) * std.time.ns_per_ms;
            if (@min(c.send_window, s.send_window) < 3) continue;
            try h2.writeHeader(c.out, 3, .data, 0, s.id);
            try c.out.writeAll(":\n\n");
            c.send_window -= 3;
            s.send_window -= 3;
            c.out_bytes += 3;
        }
        c.earnCredit();
    }

    /// The connection is going: the client said GOAWAY, or the server is
    /// stopping. Each event stream gets what was posted if the windows take
    /// it and then its end, or a reset if the client had stopped reading, so
    /// that it finishes as an HTTP/1.1 one does when the server stops, and
    /// every seat goes (ADR 019, ADR 260).
    fn endEvents(c: *Conn) !void {
        var i: usize = 0;
        while (i < c.streams.items.len) {
            const s = c.streams.items[i];
            const ev = if (s.state == .writing and s.ev_seen) &s.events.? else {
                i += 1;
                continue;
            };
            // What the windows take of what is posted, a turn at a time while
            // a turn runs out before the stream does.
            var rounds: u8 = 0;
            while (try c.pumpEvents(s, ev) == .more and rounds < 64) rounds += 1;
            if (s.ev_failed) {
                c.forget(s);
                continue;
            }
            // An event left unfinished cannot be ended with its stream: it
            // would be cut short and read as whole. That is a reset, and
            // it is decided by the event, not by how long the stream has
            // been waiting.
            if (s.ev_blocked) {
                try h2.writeRstStream(c.out, s.id, .cancel);
            } else try h2.writeHeader(c.out, 0, .data, h2.Flags.end_stream, s.id);
            c.forget(s);
        }
    }

    /// A streamed answer whose call has returned, and whose last pump has
    /// run: let the stream go once the end is written. A call that returned
    /// without ending its body (an error after the head, a handler that
    /// forgot) leaves an answer that cannot be completed, which is a stream
    /// error, as a half-sent HTTP/1.1 answer is a closed connection. True
    /// when the stream has gone from the table.
    fn settleReturned(c: *Conn, s: *Stream, o: *outbound.Outbox) !bool {
        if (o.isDone()) return c.finished(s);
        if (o.isFailed()) {
            c.forget(s);
            return true;
        }
        if (o.abandoned()) {
            try h2.writeRstStream(c.out, s.id, .internal_error);
            c.forget(s);
            return true;
        }
        return false;
    }

    /// The updates the flood count lets pass for the DATA written: two for
    /// each `credit_bytes` of it.
    fn earnCredit(c: *Conn) void {
        const earned = c.out_bytes / credit_bytes;
        if (earned == 0) return;
        c.out_bytes -= earned * credit_bytes;
        c.out_credit = @intCast(@min(@as(usize, c.out_credit) + earned * 2, max_control_run));
    }

    /// Fail every pipe whose piece cannot go because the client has no window
    /// left and nothing more is being read to give it one: a connection that
    /// is winding down.
    fn failStuck(c: *Conn) void {
        for (c.streams.items) |s| {
            if (s.stuck_since == 0) continue;
            if (@atomicLoad(?*outbound.Outbox, &s.out, .acquire)) |o| o.fail(.gone);
        }
    }

    /// Fail every pipe: the client is gone, or the connection is.
    fn abortOutbound(c: *Conn) void {
        // Before the walk, so a pipe published after it still sees the flag
        // at its first lend (`Outbox.goneLocked`).
        c.shared.monitor.enter();
        c.shared.dead = true;
        c.shared.monitor.leave();
        for (c.streams.items) |s| {
            if (s.state != .running) continue;
            if (@atomicLoad(?*outbound.Outbox, &s.out, .acquire)) |o| o.fail(.gone);
        }
    }

    /// The whole answer is out. A client that is still sending is asked to
    /// stop, which RFC 9113 §8.1 allows after a complete response, since the
    /// route answered without what it had not sent.
    fn finished(c: *Conn, s: *Stream) !bool {
        if (s.open) try h2.writeRstStream(c.out, s.id, .no_error);
        c.forget(s);
        return true;
    }
};

// ---- the call's fiber ----

/// A call on a thread of its own, with no Engine to give it a fiber.
fn callThread(s: *Stream) void {
    runCall(s, false);
}

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
        // An answer whose head is out cannot be replaced by a 500: it is
        // reset where it stands, which `writeReturned` does for a pipe whose
        // body was never ended.
        if (s.out != null) return;
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
    // A gRPC call's message is waited for here, on the call's fiber, and
    // handed to the route whole: it is the route's body. A call that was
    // answered instead is done.
    const message: []const u8 = if (s.grpc) (try readMessage(s)) orelse return else "";
    const call: framing.Call = .{
        .method = s.field(":method").?,
        .target = s.field(":path").?,
        .head = try fieldHead(a, s, message.len),
        .body = message,
        // Any other request reads its body through the pipe.
        .inbox = if (s.piped) &s.inbox else null,
    };

    var lifetime = core.Lifetime.init();
    defer lifetime.deinit();
    // A call has five bytes in front of its body, so the message is framed
    // where it lies and held once for as long as the client's window keeps
    // it. Any other request is answered as HTTP, and a route's headers kept
    // as whole lines are read into fields for it.
    var collected: framing.Collected = .{ .arena = a, .front = if (s.grpc) grpc.prefix_len else 0, .lines = !s.grpc };
    // Any request but a gRPC call can stream its answer, through a pipe the
    // connection writes (ADR 260).
    if (!s.grpc) collected.streamer = .{
        .link = s.shared.link(),
        .slot = &s.out,
        .events = &s.events,
        .live = &s.shared.streaming,
        .file_held = &s.shared.file_held,
        .can_park = s.inbox.can_park,
        .head = streamedHead,
    };
    s.app.handle(s.app.ptr, a, &lifetime, in_flight, call, &collected, s.peer, s.until_ns);
    lifetime.end();
    if (!s.grpc) {
        // Written already, a piece at a time: nothing is left to frame.
        if (collected.outbox != null) return;
        return httpReply(s, &collected);
    }
    const reply = try grpc.fromCollected(a, &collected, s.until_ns);
    s.head_block = reply.head_block;
    s.data = reply.data;
    s.trailers = reply.trailers;
    s.trailers_only = reply.trailers_only;
}

/// Say the call is answered without its route: one HEADERS frame carrying the
/// status (Trailers-Only), ready for the connection to write. Null, as a
/// message that was not read.
fn refused(s: *Stream, code: u8, message: []const u8) !?[]const u8 {
    s.head_block = try grpc.trailersOnly(s.arena.allocator(), code, .{ .ours = message });
    s.trailers_only = true;
    return null;
}

/// The one message of a call, from the stream's pipe: waited for, the five-byte
/// prefix taken off and held to what it says, and a gzip message inflated
/// after the call has been given room in the connection's budget for the
/// copy, and has waited for it where there was none (ADR 220, ADR 260).
/// Null where the call was answered instead, or has nobody to answer.
fn readMessage(s: *Stream) !?[]const u8 {
    const a = s.arena.allocator();
    // A client that asked to be told to send the message is told when it is
    // first waited for, and not if it has begun to (ADR 073, ADR 260).
    if (s.field("expect")) |wish| if (std.ascii.eqlIgnoreCase(wish, "100-continue")) s.inbox.askContinue();
    const whole = s.inbox.whole(s.limit + grpc.prefix_len) catch |err| switch (err) {
        error.BodyTooLarge => return refused(s, 8, "the message is larger than its route's body limit"),
        error.BodyTooSlow => {
            // The client's own deadline passed while the message was still
            // coming. A client too slow is cancelled and not answered.
            if (s.inbox.cause() == .deadline) return refused(s, 4, "the call's deadline passed before its message arrived");
            s.cancel = true;
            return null;
        },
        // The stream was reset or the connection went: there is nobody to
        // answer, and the connection already knows.
        error.EndOfStream => {
            s.reset = true;
            return null;
        },
    };
    switch (grpc.envelope(whole, s.field("grpc-encoding"))) {
        .refused => |r| return refused(s, r.code, r.message),
        .identity => return whole[grpc.prefix_len..],
        .unsupported => {
            s.head_block = try grpc.unsupportedEncoding(a);
            s.trailers_only = true;
            return null;
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
    const announced = encoded.announcedSize(whole[grpc.prefix_len..]) catch
        return refused(s, 13, "the message's gzip could not be read");
    if (announced > s.limit) return refused(s, 8, "the message is larger than its route's body limit");
    // No room: the call waits with only its compressed bytes, and
    // goes on when the calls ahead of it give room back, which is the
    // connection's to say, in order. It used to be refused UNAVAILABLE,
    // which a Collector retries only after its backoff: with ten consumers
    // on one connection its queue grew while the server sat idle (ADR 220).
    s.inbox.reserve(announced) catch |err| switch (err) {
        error.BodyTooSlow => return refused(s, 4, "the call's deadline passed while it waited for room on this connection"),
        error.EndOfStream => {
            s.reset = true;
            return null;
        },
    };
    return encoded.inflate(a, whole[grpc.prefix_len..], announced) catch |err| switch (err) {
        error.BodyTooLarge => return refused(s, 8, "the message is larger than its route's body limit"),
        else => return refused(s, 13, "the message's gzip could not be read"),
    };
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

/// The head of a streamed answer, encoded on the call's fiber into its arena
/// for the connection's to write: what `httpReply` makes of a whole one, with
/// the length the stream promised, if it promised one.
fn streamedHead(a: std.mem.Allocator, collected: *const framing.Collected) anyerror![]const u8 {
    var extra: usize = 0;
    for (collected.headers) |f| extra += f.name.len + f.value.len + 4;
    var w: std.Io.Writer.Allocating = try .initCapacity(a, 96 + collected.content_type.len + extra);
    try writeHttpHead(&w.writer, if (collected.status == 0) 500 else collected.status, collected.content_type, collected.length, collected.headers);
    return w.written();
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
/// line, `:authority` as `host`, and the metadata. A request that is read
/// through a pipe carries the `content-length` and `expect` its client sent,
/// which the App reads as it reads an HTTP/1.1 head; a call whose message was
/// already read whole gets the length of that message and no `expect`, since
/// there is nothing left to wait for.
fn fieldHead(a: std.mem.Allocator, s: *const Stream, message_len: usize) ![]const u8 {
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
        if (!s.piped and std.mem.eql(u8, f.name, "expect")) continue;
        try out.writeAll(f.name);
        try out.writeAll(": ");
        try out.writeAll(f.value);
        try out.writeAll("\r\n");
    }
    if (s.piped) {
        if (s.announced) |n| try out.print("content-length: {d}\r\n", .{n});
        try out.writeAll("\r\n");
    } else try out.print("content-length: {d}\r\n\r\n", .{message_len});
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

/// The `content-length` the client sent, if any: digits only, and every one of
/// them the same number (§8.1.1). Anything else is a malformed request.
fn announcedLength(fields: []const hpack.Field) error{Malformed}!?u64 {
    var said: ?u64 = null;
    for (fields) |f| {
        if (!std.mem.eql(u8, f.name, "content-length")) continue;
        if (f.value.len == 0) return error.Malformed;
        for (f.value) |ch| if (ch < '0' or ch > '9') return error.Malformed;
        const n = std.fmt.parseInt(u64, f.value, 10) catch return error.Malformed;
        if (said) |was| if (was != n) return error.Malformed;
        said = n;
    }
    return said;
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

    const refusal = try got.trailers(3);
    try testing.expectEqualStrings("3", Answer.value(refusal, "grpc-status").?);
    try testing.expect(std.mem.indexOf(u8, Answer.value(refusal, "grpc-message").?, "not a protobuf") != null);
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
        .scratch = .init(testing.allocator),
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
        .scratch = .init(testing.allocator),
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
        // left, all six started and held about 480,000. Now each is charged
        // its announced 40,000 before it copies: some start, the rest hold
        // their few hundred compressed bytes and wait.
        try testing.expect(conn.collected <= conn.budget() + 40_000 + 6 * zipped.written().len);
        const waiting = conn.reservationWaiters();
        try testing.expect(waiting >= 1 and waiting < ids.len);
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
    try testing.expect(waiting.inbox.wanted() != 0);
    // The call's own deadline passes while it waits: the call wakes, answers
    // DEADLINE_EXCEEDED and returns, with nothing charged to the budget.
    waiting.inbox.setDeadline(1);
    waiting.inbox.link.poke(waiting.inbox.link.ctx);
    waiting.inbox.fail(.deadline);
    conn.settle();
    try conn.writeReady();
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

var one_file: ?*OneFile = null;

/// A directory with one file in it, for the route that sends it.
const OneFile = struct {
    tmp: nilo_testing.TmpDir,
    dir: bulkhead.Dir,

    fn init() !OneFile {
        return initWith("0123456789");
    }

    fn initWith(bytes: []const u8) !OneFile {
        var tmp = nilo_testing.tmpDir();
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.bin", .data = bytes });
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

/// A route that asks for what HTTP/2 does not give, and the call it names in
/// its sentence.
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
    try testing.expect(std.mem.indexOf(u8, ex.body, "is HTTP/1.1 only") != null);
}

test "a WebSocket is refused by name on HTTP/2, and the sentence says it is HTTP/1.1" {
    try expectRefusedByName("GET", "/ws", "c.upgrade()");
    try expectRefusedByName("GET", "/ws", "a WebSocket is HTTP/1.1");
}

test "a file is read into frames on HTTP/2, and a HEAD of it sends the head and no DATA" {
    var files = try OneFile.init();
    defer files.deinit();
    one_file = &files;
    defer one_file = null;

    var app = try httpApp();
    defer app.deinit();
    var got = try h2test.roundTrip(&app, .{ .path = "/file" });
    defer got.deinit();
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expectEqualStrings("10", got.header("content-length").?);
    try testing.expectEqualStrings("0123456789", got.body);

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

// ---- a request's body read through its pipe (stage 6.1, ADR 260) ----

const heap_count = @import("budget.zig");

var upload_total: std.atomic.Value(usize) = .init(0);
var upload_failed: std.atomic.Value(bool) = .init(false);
var upload_pause_ms: std.atomic.Value(u64) = .init(0);

fn resetUploads() void {
    upload_total.store(0, .release);
    upload_failed.store(false, .release);
    upload_pause_ms.store(0, .release);
}

/// Reads its body in pieces, which is what a handler of an upload does, and
/// says whether the read failed.
fn uploadRoute(c: *Ctx) anyerror!void {
    var incoming = try c.bodyStream();
    var buf: [1000]u8 = undefined;
    var total: usize = 0;
    while (incoming.read(&buf) catch |err| {
        upload_failed.store(true, .release);
        return err;
    }) |part| {
        total += part.len;
        const pause = upload_pause_ms.load(.acquire);
        if (pause != 0) bulkhead.sleep(pause) catch {};
    }
    upload_total.store(total, .release);
    var text: [20]u8 = undefined;
    try c.sendText(200, std.fmt.bufPrint(&text, "{d}", .{total}) catch unreachable);
}

/// Waits for its whole body, and says whether the wait failed.
fn waitRoute(c: *Ctx) anyerror!void {
    const got = c.body() catch |err| {
        upload_failed.store(true, .release);
        return err;
    };
    upload_total.store(got.view().len, .release);
    try c.sendText(200, "had it");
}

/// Looks at its body only after the client has sent all of it.
fn lateRoute(c: *Ctx) anyerror!void {
    bulkhead.sleep(80) catch {};
    return sizeRoute(c);
}

fn pipeApp() !App {
    var app = App.init(testing.allocator);
    errdefer app.deinit();
    try app.post("/upload", uploadRoute);
    try app.post("/wait", waitRoute);
    try app.post("/late", lateRoute);
    try app.post("/size", sizeRoute);
    try app.resolveChains();
    return app;
}

/// The increments of the WINDOW_UPDATE frames the connection wrote for
/// `stream`.
fn windowIncrements(a: std.mem.Allocator, got: *const Answer, stream: u31) ![]u32 {
    var all: std.ArrayList(u32) = .empty;
    for (got.frames.items) |f| {
        if (f.head.type == .window_update and f.head.stream == stream)
            try all.append(a, std.mem.readInt(u32, f.payload[0..4], .big) & 0x7fff_ffff);
    }
    return all.items;
}

test "a body that arrived whole before the handler read it costs the request no allocation of its own" {
    var app = try pipeApp();
    defer app.deinit();
    // A body that fits the buffer a spare stream keeps, so only a request
    // that copied or allocated for it would show.
    var totals: [2]usize = undefined;
    var gpa_h2 = heap_count.Counting{ .child = testing.allocator };
    for (&totals, [_]usize{ 2, 12 }) |*total, requests| {
        var client = try h2test.TestClient.init();
        defer client.deinit();
        var id: u31 = 1;
        for (0..requests) |_| {
            try h2test.requestOn(&client, id, .{ .method = "POST", .path = "/size", .body = "b" ** 3_000, .frame = 1_000 });
            id += 2;
        }
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(client.buf.written());
        var host = app.grpcHost();
        host.gpa = gpa_h2.allocator();
        gpa_h2.reset();
        serveConnection(host, &in, &out.writer, .off, .off, .{});
        total.* = gpa_h2.allocs;
        var ex = try h2test.exchangeOf(try h2test.answerOf(out.written()), 1);
        defer ex.deinit();
        try testing.expectEqualStrings("3000", ex.body);
    }
    try testing.expectEqual(@as(usize, 0), totals[1] - totals[0]);
}

test "a body arriving in many DATA frames after the handler started is read through the pipe, and WINDOW_UPDATEs follow the reads in half windows" {
    resetUploads();
    var app = try pipeApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .method = "POST", .path = "/upload", .body = "u" ** 60_000, .frame = 4_000 });
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 200), ex.status);
    try testing.expectEqualStrings("60000", ex.body);
    try testing.expectEqual(@as(usize, 60_000), upload_total.load(.acquire));
    const steps = try windowIncrements(ex.answer.arena.allocator(), &ex.answer, 1);
    // Sixty reads of a thousand bytes made one top-up, not sixty: a half
    // window is what is waited for.
    try testing.expect(steps.len >= 1 and steps.len <= 2);
    for (steps) |n| try testing.expect(n >= h2.default_window / 2);
}

test "a body that arrived whole before the handler read it is not asked for with a 100 Continue" {
    resetUploads();
    // The handler runs once the stream has ended, which is what a body that
    // arrived before it was read is.
    const before = fallback;
    fallback = .inline_when_ended;
    defer fallback = before;
    var app = try pipeApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{
        .method = "POST",
        .path = "/size",
        .fields = &.{.{ .name = "expect", .value = "100-continue" }},
        .body = "all of it",
    });
    defer ex.deinit();
    try testing.expectEqualStrings("9", ex.body);
    try testing.expectEqual(@as(usize, 0), ex.interim.len);
}

test "a content-length the DATA overruns resets the stream with PROTOCOL_ERROR and fails the read that is waiting" {
    resetUploads();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipeApp();
    defer app.deinit();
    var client = try h2test.TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{
        .method = "POST",
        .path = "/upload",
        .fields = &.{.{ .name = "content-length", .value = "10" }},
        .body = "x" ** 24,
        .frame = 12,
    });
    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.protocol_error, got.rst(1).?);
    try testing.expect(upload_failed.load(.acquire));
    try testing.expectEqual(@as(usize, 0), Answer.of(.data, &got, 1).len);
    try testing.expect(got.goaway() == null);
}

test "a content-length the stream ends short of resets the stream with PROTOCOL_ERROR and fails the read" {
    resetUploads();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipeApp();
    defer app.deinit();
    var client = try h2test.TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{
        .method = "POST",
        .path = "/wait",
        .fields = &.{.{ .name = "content-length", .value = "20" }},
        .body = "short",
    });
    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.protocol_error, got.rst(1).?);
    try testing.expect(upload_failed.load(.acquire));
}

test "a stream reset while its handler waits for the body wakes the handler, and nothing is left behind" {
    resetUploads();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipeApp();
    defer app.deinit();
    var client = try h2test.TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .method = "POST", .path = "/wait", .open = true });
    try h2.writeRstStream(client.w(), 1, .cancel);
    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expect(upload_failed.load(.acquire));
    // The answer has nobody to read it, so none is written.
    try testing.expectEqual(@as(usize, 0), Answer.of(.headers, &got, 1).len);
}

test "a connection that ends while its handler waits for the body wakes the handler, and nothing is left behind" {
    resetUploads();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipeApp();
    defer app.deinit();
    var client = try h2test.TestClient.init();
    defer client.deinit();
    // A request whose DATA never ends, then the client's GOAWAY and the end
    // of the connection.
    try h2test.requestOn(&client, 1, .{ .method = "POST", .path = "/wait", .open = true });
    try h2.writeHeader(client.w(), 3, .data, 0, 1);
    try client.w().writeAll("abc");
    try h2.writeGoaway(client.w(), 0, .no_error);
    var ex = try h2test.exchangeOf(try converse(&app, &client), 1);
    defer ex.deinit();
    try testing.expect(upload_failed.load(.acquire));
    // What the failed read made of it is written to a client that may still
    // be reading: a 400, not a hang.
    try testing.expectEqual(@as(u16, 400), ex.status);
}

/// A connection that sends what it was given and then goes quiet for
/// `pause_ms` before it ends, as a client that stops sending does.
const QuietReader = struct {
    reader: std.Io.Reader,
    bytes: []const u8,
    pos: usize = 0,
    pause_ms: u64,

    fn init(bytes: []const u8, pause_ms: u64, buffer: []u8) QuietReader {
        return .{
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .bytes = bytes,
            .pause_ms = pause_ms,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *QuietReader = @alignCast(@fieldParentPtr("reader", r));
        if (self.pos < self.bytes.len) {
            const n = limit.minInt(self.bytes.len - self.pos);
            const wrote = try w.write(self.bytes[self.pos..][0..n]);
            self.pos += wrote;
            return wrote;
        }
        bulkhead.sleep(self.pause_ms) catch {};
        return error.EndOfStream;
    }
};

test "a client that stops sending its body is held to the read bound, and the handler answers 408" {
    resetUploads();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipeApp();
    defer app.deinit();
    var client = try h2test.TestClient.init();
    defer client.deinit();
    var block: std.Io.Writer.Allocating = .init(testing.allocator);
    defer block.deinit();
    try hpack.writeLiteral(&block.writer, ":method", "POST");
    try hpack.writeInt(&block.writer, 0x80, 7, 6);
    try hpack.writeLiteral(&block.writer, ":path", "/wait");
    try h2.writeHeaderBlock(client.w(), 1, block.written(), false, h2.default_max_frame);
    try h2.writeHeader(client.w(), 3, .data, 0, 1);
    try client.w().writeAll("abc");

    var buffer: [32 * 1024]u8 = undefined;
    var quiet_in = QuietReader.init(client.buf.written(), 600, &buffer);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const started = bulkhead.monotonicNanos();
    serveConnection(app.grpcHost(), &quiet_in.reader, &out.writer, .{ .body_ms = 100 }, .off, .{});
    _ = started;
    var ex = try h2test.exchangeOf(try h2test.answerOf(out.written()), 1);
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 408), ex.status);
    try testing.expect(upload_failed.load(.acquire));
}

test "a gzip message read through the pipe is inflated on the call's own fiber, and is the route's body" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    var zipped: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer zipped.deinit();
    try gzipRun(&zipped, 'g', 30_000);
    try client.headersFor(1, "/test.Echo/Say", &.{.{ .name = "grpc-encoding", .value = "gzip" }}, false);
    try client.messageInFrames(1, zipped.written(), true);
    try h2.writeWindowUpdate(client.w(), 0, 100_000);
    try h2.writeWindowUpdate(client.w(), 1, 100_000);
    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
    try testing.expectEqual(@as(usize, 30_000), (try got.message(1)).len);
}

// ---- what a reset or a lying client can make the connection do (stage 6.1 review) ----

test "a collecting stream is not given a buffer the size of the length its client announced" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    // A gRPC call that says its message is a megabyte and sends one byte.
    try client.headersFor(1, "/test.Echo/Say", &.{.{ .name = "content-length", .value = "1000000" }}, false);
    try h2.writeHeader(client.w(), 1, .data, 0, 1);
    try client.w().writeByte('x');

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    var conn = try steppedConn(&app, &in, &out.writer);
    defer conn.deinit();
    while (in.bufferedLen() > 0) try conn.readFrame();
    const s = conn.find(1).?;
    try testing.expect(s.inbox.buf.len <= 4096);
    try testing.expectEqual(@as(usize, 1), conn.collected);
}

test "DATA on a stream that was reset and is still running is thrown away without a word" {
    resetUploads();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipeApp();
    defer app.deinit();
    var client = try h2test.TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .method = "POST", .path = "/wait", .open = true });
    try h2.writeRstStream(client.w(), 1, .cancel);
    for (0..6) |i| {
        try h2.writeHeader(client.w(), if (i % 2 == 0) 0 else 3, .data, 0, 1);
        if (i % 2 == 1) try client.w().writeAll("abc");
    }
    var got = try converse(&app, &client);
    defer got.deinit();
    // The client reset it, and this side answers none of what follows.
    try testing.expect(got.rst(1) == null);
    try testing.expect(got.goaway() == null);
}

test "a client that ended its request and keeps sending is reset once, and no more" {
    resetUploads();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipeApp();
    defer app.deinit();
    var client = try h2test.TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .method = "POST", .path = "/size", .body = "abc" });
    for (0..5) |_| try h2.writeHeader(client.w(), 0, .data, 0, 1);
    var got = try converse(&app, &client);
    defer got.deinit();
    var resets: usize = 0;
    for (got.frames.items) |f| {
        if (f.head.type == .rst_stream and f.head.stream == 1) resets += 1;
    }
    try testing.expect(resets <= 1);
}

test "trailers in flight to a stream this side reset do not end the connection" {
    resetUploads();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipeApp();
    defer app.deinit();
    var client = try h2test.TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .method = "POST", .path = "/wait", .open = true });
    var block: std.Io.Writer.Allocating = .init(testing.allocator);
    defer block.deinit();
    try hpack.writeLiteral(&block.writer, "x-checksum", "1");
    try h2.writeHeaderBlock(client.w(), 1, block.written(), true, h2.default_max_frame);
    try h2.writeHeader(client.w(), 8, .ping, 0, 0);
    try client.w().writeAll("12345678");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    var conn = try steppedConn(&app, &in, &out.writer);
    defer conn.deinit();
    // The request starts and its handler parks on the body. This side then
    // resets the stream, as a length mismatch does, which leaves it running.
    while (conn.find(1) == null) try conn.readFrame();
    const s = conn.find(1).?;
    s.open = false;
    s.reset = true;
    // The client's trailers, sent before it saw the reset, and a PING behind
    // them that has to be answered.
    try conn.readFrame();
    try conn.readFrame();
    try testing.expect(!conn.goaway_sent);
    var got = try h2test.answerOf(out.written());
    defer got.deinit();
    try testing.expect(got.goaway() == null);
}

// ---- an answer written in pieces through its pipe (stage 6.2, ADR 260) ----

var piped_failed: std.atomic.Value(bool) = .init(false);
var piped_pieces: std.atomic.Value(usize) = .init(0);

fn resetPiped() void {
    piped_failed.store(false, .release);
    piped_pieces.store(0, .release);
}

/// What a route writing `piece_count` pieces of ten bytes sends.
const piece_count = 200;

fn expectedPieces(a: std.mem.Allocator) ![]const u8 {
    var all: std.Io.Writer.Allocating = .init(a);
    for (0..piece_count) |i| try all.writer.print("piece {d:0>3};", .{i});
    return all.written();
}

/// Ten bytes at a time, each flushed, so each is a piece of its own, and a
/// trailer after the last.
fn piecesRoute(c: *Ctx) anyerror!void {
    var out = try c.stream(200, "text/plain");
    for (0..piece_count) |i| {
        out.print("piece {d:0>3};", .{i}) catch |err| {
            piped_failed.store(true, .release);
            return err;
        };
        out.flush() catch |err| {
            piped_failed.store(true, .release);
            return err;
        };
        _ = piped_pieces.fetchAdd(1, .acq_rel);
    }
    try c.setTrailer("x-pieces", "200");
    try out.finish();
}

/// One piece and the end, for the count of allocations a piece costs.
fn pieceRoute(c: *Ctx) anyerror!void {
    var out = try c.stream(200, "text/plain");
    try out.writeAll("piece 000;");
    try out.flush();
    try c.setTrailer("x-pieces", "1");
    try out.finish();
}

const huge_chunk = "0123456789abcdef" ** 256;
const huge_chunks = 75;

/// 307,200 bytes in the stream's buffer's worth, which is more than the
/// window a connection starts with.
fn hugeRoute(c: *Ctx) anyerror!void {
    var out = try c.stream(200, "application/octet-stream");
    for (0..huge_chunks) |_| out.writeAll(huge_chunk) catch |err| {
        piped_failed.store(true, .release);
        return err;
    };
    try out.finish();
}

fn tickRoute(c: *Ctx) anyerror!void {
    var events = try c.events();
    try events.send(.{ .name = "tick", .data = "1" });
    try events.send(.{ .id = "2", .data = "two" });
    try events.close();
}

fn promisedRoute(c: *Ctx) anyerror!void {
    var out = try c.streamWith(200, "text/plain", .{ .length = 12 });
    try out.writeAll("twelve bytes");
    try out.finish();
}

fn bigFileRoute(c: *Ctx) anyerror!void {
    const file = try one_file.?.dir.openFile("f.bin");
    return c.sendFile(.{ .file = file, .content_type = "application/octet-stream" });
}

fn grpcStreamRoute(c: *Ctx) anyerror!void {
    var out = try c.stream(200, "text/plain");
    try out.finish();
}

fn pipedApp() !App {
    var app = App.init(testing.allocator);
    errdefer app.deinit();
    try app.get("/pieces", piecesRoute);
    try app.get("/piece", pieceRoute);
    try app.get("/huge", hugeRoute);
    try app.get("/tick", tickRoute);
    try app.get("/promised", promisedRoute);
    try app.get("/file", bigFileRoute);
    try app.get("/ping", pingRoute);
    try app.post("/test.Echo/Stream", grpcStreamRoute);
    try app.resolveChains();
    return app;
}

/// The frames of `stream` in the order they were written.
fn frameKinds(a: std.mem.Allocator, got: *const Answer, stream: u31) ![]const h2.Type {
    var all: std.ArrayList(h2.Type) = .empty;
    for (got.frames.items) |f| if (f.head.stream == stream) try all.append(a, f.head.type);
    return all.items;
}

test "a streamed answer of many pieces, written across windows smaller than it, arrives in order with its trailers after the last piece" {
    resetPiped();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipedApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .path = "/pieces", .window = 700 });
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 200), ex.status);
    try testing.expectEqualStrings("text/plain", ex.header("content-type").?);
    try testing.expect(ex.header("content-length") == null);
    try testing.expectEqualStrings(try expectedPieces(ex.answer.arena.allocator()), ex.body);
    try testing.expectEqualStrings("200", Answer.value(ex.trailers, "x-pieces").?);
    try testing.expectEqual(@as(usize, piece_count), piped_pieces.load(.acquire));
    // The head, the body and then the trailers, which end the stream.
    const kinds = try frameKinds(ex.answer.arena.allocator(), &ex.answer, 1);
    try testing.expectEqual(h2.Type.headers, kinds[0]);
    try testing.expectEqual(h2.Type.headers, kinds[kinds.len - 1]);
    for (Answer.of(.data, &ex.answer, 1)) |f| try testing.expect(!f.head.has(h2.Flags.end_stream));
    try testing.expect(Answer.of(.headers, &ex.answer, 1)[1].head.has(h2.Flags.end_stream));
}

test "a streamed answer larger than the window a connection starts with is sent in frames as the client opens it" {
    resetPiped();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .path = "/huge" });
    // What the client opens after the 65,535 bytes it started with, which is
    // read after the call has had to wait for them.
    try h2.writeWindowUpdate(client.w(), 0, 1_000_000);
    try h2.writeWindowUpdate(client.w(), 1, 1_000_000);
    var ex = try h2test.exchangeOf(try converse(&app, &client), 1);
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 200), ex.status);
    try testing.expectEqual(@as(usize, huge_chunk.len * huge_chunks), ex.body.len);
    for (0..huge_chunks) |i| try testing.expectEqualStrings(huge_chunk, ex.body[i * huge_chunk.len ..][0..huge_chunk.len]);
    for (Answer.of(.data, &ex.answer, 1)) |f| try testing.expect(f.head.len <= h2.default_max_frame);
    // The end is a DATA frame of no bytes, because nothing said it was coming.
    const data = Answer.of(.data, &ex.answer, 1);
    try testing.expect(data[data.len - 1].head.has(h2.Flags.end_stream));
}

test "a stream that promised its length says it in the head, and an event stream carries its two headers" {
    resetPiped();
    var app = try pipedApp();
    defer app.deinit();
    var promised = try h2test.roundTrip(&app, .{ .path = "/promised" });
    defer promised.deinit();
    try testing.expectEqualStrings("12", promised.header("content-length").?);
    try testing.expectEqualStrings("twelve bytes", promised.body);

    var events = try h2test.roundTrip(&app, .{ .path = "/tick" });
    defer events.deinit();
    try testing.expectEqual(@as(u16, 200), events.status);
    try testing.expectEqualStrings("text/event-stream", events.header("content-type").?);
    try testing.expectEqualStrings("no-cache", events.header("cache-control").?);
    try testing.expectEqualStrings("event: tick\ndata: 1\n\nid: 2\ndata: two\n\n", events.body);
}

test "a HEAD of a streamed route is its head, ending the stream, and no DATA" {
    resetPiped();
    var app = try pipedApp();
    defer app.deinit();
    var ex = try h2test.roundTrip(&app, .{ .method = "HEAD", .path = "/pieces" });
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 200), ex.status);
    try testing.expectEqual(@as(usize, 0), Answer.of(.data, &ex.answer, 1).len);
    const heads = Answer.of(.headers, &ex.answer, 1);
    try testing.expectEqual(@as(usize, 1), heads.len);
    try testing.expect(heads[0].head.has(h2.Flags.end_stream));
    try testing.expectEqual(@as(usize, 0), ex.trailers.len);
}

test "a piece costs no allocation: a stream of two hundred allocates what a stream of one does" {
    var app = try pipedApp();
    defer app.deinit();
    var counting = heap_count.Counting{ .child = testing.allocator };
    var results: [2]usize = undefined;
    for (&results, [_][]const u8{ "/piece", "/pieces" }) |*r, path| {
        var client = try TestClient.init();
        defer client.deinit();
        try h2test.requestOn(&client, 1, .{ .path = path });
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(client.buf.written());
        var host = app.grpcHost();
        host.gpa = counting.allocator();
        counting.reset();
        serveConnection(host, &in, &out.writer, .off, .off, .{});
        r.* = counting.allocs;
        var got = try h2test.answerOf(out.written());
        defer got.deinit();
        try testing.expect(Answer.of(.data, &got, 1).len >= 1);
    }
    try testing.expectEqual(results[0], results[1]);
}

test "a file larger than the window is read into frames, a buffer at a time, and a range of it is a 206" {
    var bytes: [100_000]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast('a' + i % 26);
    var files = try OneFile.initWith(&bytes);
    defer files.deinit();
    one_file = &files;
    defer one_file = null;
    var app = try pipedApp();
    defer app.deinit();

    var whole = try h2test.roundTrip(&app, .{ .path = "/file", .window = h2.default_window });
    defer whole.deinit();
    try testing.expectEqual(@as(u16, 200), whole.status);
    try testing.expectEqualStrings("100000", whole.header("content-length").?);
    try testing.expectEqualStrings(&bytes, whole.body);

    var part = try h2test.roundTrip(&app, .{ .path = "/file", .fields = &.{.{ .name = "range", .value = "bytes=26-77" }} });
    defer part.deinit();
    try testing.expectEqual(@as(u16, 206), part.status);
    try testing.expectEqualStrings("bytes 26-77/100000", part.header("content-range").?);
    try testing.expectEqualStrings(bytes[26..78], part.body);
}

test "a streamed answer in a gRPC call is refused by name, and says a call answers one message" {
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Echo/Stream", "x");
    var got = try converse(&app, &client);
    defer got.deinit();
    const trailers = try got.trailers(1);
    try testing.expectEqualStrings("13", Answer.value(trailers, "grpc-status").?);
    const said = Answer.value(trailers, "grpc-message").?;
    try testing.expect(std.mem.indexOf(u8, said, "c.stream()") != null);
    try testing.expect(std.mem.indexOf(u8, said, "answers one message") != null);
}

/// A client whose window is 0, so nothing a call writes can be sent, and the
/// request for a route that writes.
fn closedWindow(client: *TestClient, stream: u31, path: []const u8) !void {
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 0 }});
    try h2test.requestOn(client, stream, .{ .path = path });
}

test "a stream the client resets wakes the call that waits to write with an error, and the connection answers the next request" {
    resetPiped();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try closedWindow(&client, 1, "/pieces");
    try h2.writeRstStream(client.w(), 1, .cancel);
    try h2test.requestOn(&client, 3, .{ .path = "/ping" });
    try h2.writeWindowUpdate(client.w(), 3, 100);
    var next = try h2test.exchangeOf(try converse(&app, &client), 3);
    defer next.deinit();
    try testing.expect(piped_failed.load(.acquire));
    try testing.expectEqual(@as(usize, 0), piped_pieces.load(.acquire));
    try testing.expectEqualStrings("pong", next.body);
    try testing.expect(next.answer.goaway() == null);
}

test "a connection that ends while a call waits on a window wakes it with an error and leaves nothing behind" {
    resetPiped();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try closedWindow(&client, 1, "/pieces");
    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expect(piped_failed.load(.acquire));
    try testing.expectEqual(@as(usize, 0), piped_pieces.load(.acquire));
}

test "a GOAWAY from the client and then the end of the connection wakes the call that waits on a window" {
    resetPiped();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try closedWindow(&client, 1, "/pieces");
    try h2.writeGoaway(client.w(), 1, .no_error);
    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expect(piped_failed.load(.acquire));
}

test "updates of a window nothing was written into are a flood" {
    resetPiped();
    const previous = quiet();
    defer testing.log_level = previous;
    var app = try pipedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    // The stream's window stays at 0, so the connection's grows for nothing:
    // no DATA is written for any of them, and none of them is progress.
    try closedWindow(&client, 1, "/pieces");
    for (0..max_control_run + 5) |_| try h2.writeWindowUpdate(client.w(), 0, 1);
    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.enhance_your_calm, got.goaway().?);
    try testing.expect(piped_failed.load(.acquire));
}

// ---- an event stream handed to the connection (stage 6.3) ----

const room_file = @import("room.zig");
const Room = room_file.Room;

var feed_room: ?*Room = null;
var feed_calls: std.atomic.Value(u32) = .init(0);
var feed_inside: std.atomic.Value(u32) = .init(0);
var feed_keepalive: std.atomic.Value(u32) = .init(0);
var said_count: std.atomic.Value(u32) = .init(0);

fn resetFeed() void {
    feed_calls.store(0, .release);
    feed_inside.store(0, .release);
    feed_keepalive.store(0, .release);
    said_count.store(0, .release);
}

/// The handler of a stream the rooms feed, counted going in and coming out, so
/// a test can say that no handler is left when the stream is open.
fn feedRoute(c: *Ctx) anyerror!void {
    _ = feed_calls.fetchAdd(1, .acq_rel);
    _ = feed_inside.fetchAdd(1, .acq_rel);
    defer _ = feed_inside.fetchSub(1, .acq_rel);
    return c.eventsFrom(feed_room.?, .{ .keepalive_ms = feed_keepalive.load(.acquire) });
}

fn feedRetryRoute(c: *Ctx) anyerror!void {
    return c.eventsFrom(feed_room.?, .{ .keepalive_ms = 0, .retry_ms = 3000 });
}

/// Says one numbered line into the room, from another call's fiber.
fn sayRoute(c: *Ctx) anyerror!void {
    const n = said_count.fetchAdd(1, .acq_rel);
    try feed_room.?.print("say {d}", .{n});
    try c.sendText(200, "said");
}

fn stopNowRoute(c: *Ctx) anyerror!void {
    stopping_app.stop.request();
    try c.sendText(200, "stopping");
}

fn feedApp() !App {
    var app = App.init(testing.allocator);
    errdefer app.deinit();
    try app.get("/feed", feedRoute);
    try app.get("/feed/retry", feedRetryRoute);
    try app.get("/say", sayRoute);
    try app.get("/stop", stopNowRoute);
    try app.get("/ping", pingRoute);
    try app.get("/ws", upgradeRoute);
    try app.resolveChains();
    return app;
}

fn feedRoom(options: room_file.Options) !Room {
    return Room.initWith(testing.allocator, options);
}

/// Everything the connection wrote on `stream` as DATA, in order.
fn dataOn(got: *Answer, stream: u31) ![]const u8 {
    var all: std.ArrayList(u8) = .empty;
    for (Answer.of(.data, got, stream)) |f| try all.appendSlice(got.arena.allocator(), f.payload);
    return all.items;
}

/// A client's frames after the ones the connection was built over.
fn nextFrames(conn: *Conn, in: *std.Io.Reader) !void {
    conn.in = in;
    while (in.bufferedLen() > 0) try conn.readFrame();
}

test "an event stream handed to the HTTP/2 connection writes what its room posts as events in order, and no handler is left running" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 8, .backlog = 8 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .path = "/feed" });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    {
        var conn = try steppedConn(&app, &in, &out.writer);
        defer conn.deinit();
        while (in.bufferedLen() > 0) try conn.readFrame();
        try conn.writeReady();

        // The handler has returned and holds nothing; the stream is open, in
        // the room, and the connection's.
        try testing.expectEqual(@as(u32, 1), feed_calls.load(.acquire));
        try testing.expectEqual(@as(u32, 0), feed_inside.load(.acquire));
        try testing.expectEqual(@as(u32, 0), conn.shared.running.load(.acquire));
        try testing.expectEqual(@as(u32, 1), conn.events_open);
        try testing.expectEqual(@as(usize, 1), conn.streams.items.len);
        try testing.expectEqual(@as(usize, 1), room.count());

        try room.sayText("one");
        try room.event(.{ .name = "tick", .id = "2", .data = "two\nlines" });
        try room.sayText("three");
        try conn.writeReady();
    }
    // The connection's end gave the seat up.
    try testing.expectEqual(@as(usize, 0), room.count());

    var ex = try h2test.exchangeOf(try h2test.answerOf(out.written()), 1);
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 200), ex.status);
    try testing.expectEqualStrings("text/event-stream", ex.header("content-type").?);
    try testing.expectEqualStrings("no-cache", ex.header("cache-control").?);
    try testing.expectEqualStrings("data: one\n\nevent: tick\nid: 2\ndata: two\ndata: lines\n\ndata: three\n\n", ex.body);
    // It has no end: nothing ended the stream, and nothing reset it.
    for (ex.answer.frames.items) |f| try testing.expect(!f.head.has(h2.Flags.end_stream) or f.head.stream != 1);
    try testing.expect(ex.answer.rst(1) == null);
}

test "an event stream on HTTP/2 sends retry first and the history a returning client is owed before anything new" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 8, .backlog = 8, .history = 4 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    try room.event(.{ .id = "1", .data = "one" });
    try room.event(.{ .id = "2", .data = "two" });
    try room.event(.{ .id = "3", .data = "three" });
    var app = try feedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .path = "/feed/retry", .fields = &.{.{ .name = "last-event-id", .value = "1" }} });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    {
        var conn = try steppedConn(&app, &in, &out.writer);
        defer conn.deinit();
        while (in.bufferedLen() > 0) try conn.readFrame();
        try conn.writeReady();
        try room.event(.{ .id = "4", .data = "four" });
        try conn.writeReady();
    }
    try testing.expectEqual(@as(usize, 0), room.count());
    var ex = try h2test.exchangeOf(try h2test.answerOf(out.written()), 1);
    defer ex.deinit();
    try testing.expectEqualStrings("retry: 3000\n\nid: 2\ndata: two\n\nid: 3\ndata: three\n\nid: 4\ndata: four\n\n", ex.body);
}

test "an event stream on HTTP/2 that has said nothing for its keep-alive is sent a comment, and not before" {
    resetFeed();
    feed_keepalive.store(150, .release);
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 4 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .path = "/feed" });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    var conn = try steppedConn(&app, &in, &out.writer);
    defer conn.deinit();
    while (in.bufferedLen() > 0) try conn.readFrame();
    try conn.writeReady();
    {
        var early = try h2test.answerOf(out.written());
        defer early.deinit();
        try testing.expectEqual(@as(usize, 0), (try dataOn(&early, 1)).len);
    }
    // The wait the connection would make is bounded by the comment due.
    const limit = conn.inFlightLimitMs().?;
    try testing.expect(limit > 0 and limit <= 150);
    bulkhead.sleep(200) catch {};
    try conn.writeReady();
    var late = try h2test.answerOf(out.written());
    defer late.deinit();
    try testing.expectEqualStrings(":\n\n", try dataOn(&late, 1));
    // Said, so the next is a whole stretch away.
    try conn.writeReady();
    var again = try h2test.answerOf(out.written());
    defer again.deinit();
    try testing.expectEqualStrings(":\n\n", try dataOn(&again, 1));
}

test "an event stream on HTTP/2 reset by its client leaves the room, the connection answers the next request, and a post to the room is harmless" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 4 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .path = "/feed" });
    var second = try TestClient.init();
    defer second.deinit();
    // Not a second preface: only the frames.
    var later: std.Io.Writer.Allocating = .init(testing.allocator);
    defer later.deinit();
    try h2.writeRstStream(&later.writer, 1, .cancel);
    try h2test.requestOn(&second, 3, .{ .path = "/ping" });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    {
        var conn = try steppedConn(&app, &in, &out.writer);
        defer conn.deinit();
        while (in.bufferedLen() > 0) try conn.readFrame();
        try conn.writeReady();
        try testing.expectEqual(@as(usize, 1), room.count());

        var cancel: std.Io.Reader = .fixed(later.written());
        try nextFrames(&conn, &cancel);
        try testing.expectEqual(@as(usize, 0), room.count());
        try testing.expectEqual(@as(u32, 0), conn.events_open);
        try testing.expectEqual(@as(usize, 0), conn.streams.items.len);
        // A room speaking to nobody, and to a connection that was reset.
        try room.sayText("into nothing");

        const ping_frames = second.buf.written()[h2.preface.len + h2.header_len ..];
        var ping: std.Io.Reader = .fixed(ping_frames);
        try nextFrames(&conn, &ping);
        try conn.writeReady();
    }
    var got = try h2test.answerOf(out.written());
    defer got.deinit();
    try testing.expectEqualStrings("pong", try dataOn(&got, 3));
    try testing.expectEqual(@as(usize, 0), (try dataOn(&got, 1)).len);
    try testing.expect(got.goaway() == null);
}

test "an event stream on HTTP/2 whose client stops reading holds what its room bounds, and is reset at the write limit while the connection goes on" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 4, .backlog = 4 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    // A client whose windows are shut: it takes nothing.
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 0 }});
    try h2test.requestOn(&client, 1, .{ .path = "/feed" });
    try h2test.requestOn(&client, 3, .{ .path = "/ping" });
    var later: std.Io.Writer.Allocating = .init(testing.allocator);
    defer later.deinit();
    try h2.writeWindowUpdate(&later.writer, 3, 100);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    {
        var conn = try steppedConn(&app, &in, &out.writer);
        defer conn.deinit();
        conn.deadlines.write_ms = 40;
        while (in.bufferedLen() > 0) try conn.readFrame();
        try conn.writeReady();
        try testing.expectEqual(@as(usize, 1), room.count());

        // Forty events into a room that keeps four for a seat: the rest are
        // counted as missed, and nothing else is held for a client that reads
        // none of them.
        for (0..40) |i| try room.print("event {d}", .{i});
        try conn.writeReady();
        const ev: *@import("stream.zig").Http2Events = @ptrCast(@alignCast(conn.streams.items[0].events.?.state));
        const seat = &room.seats[ev.seated.ticket.index];
        try testing.expect(seat.count <= 4);
        try testing.expectEqual(@as(u64, 40 - 4), seat.dropped.load(.monotonic));
        try testing.expect(ev.held != null);
        try testing.expect(conn.streams.items[0].stuck_since != 0);

        var update: std.Io.Reader = .fixed(later.written());
        try nextFrames(&conn, &update);
        // The ping goes out, so the write limit it was counting is over.
        try conn.writeReady();
        bulkhead.sleep(80) catch {};
        try testing.expectEqual(Conn.Waited.again, conn.overdue());
        // Cancelled, and gone from the room; the other stream is answered.
        try testing.expectEqual(@as(usize, 0), room.count());
        try conn.writeReady();
    }
    var got = try h2test.answerOf(out.written());
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.cancel, got.rst(1).?);
    try testing.expectEqualStrings("pong", try dataOn(&got, 3));
    try testing.expectEqual(@as(usize, 0), (try dataOn(&got, 1)).len);
}

test "event streams on HTTP/2 take turns with each other and with a whole answer, and every one gets its event" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 8, .backlog = 4 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    const ids = [_]u31{ 1, 3, 5, 7, 9, 11 };
    for (ids) |id| try h2test.requestOn(&client, id, .{ .path = "/feed" });
    // The ping arrives once the window is gone, with ten bytes of it back.
    var second = try TestClient.init();
    defer second.deinit();
    try h2test.requestOn(&second, 13, .{ .path = "/ping" });
    try h2.writeWindowUpdate(second.w(), 0, 10);
    var third: std.Io.Writer.Allocating = .init(testing.allocator);
    defer third.deinit();
    try h2.writeWindowUpdate(&third.writer, 0, 60_000);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var first: std.Io.Reader = .fixed(client.buf.written());
    var big: [20_000]u8 = undefined;
    @memset(&big, 'x');
    const event_bytes = 20_000 + "data: ".len + "\n\n".len;
    {
        var conn = try steppedConn(&app, &first, &out.writer);
        defer conn.deinit();
        while (first.bufferedLen() > 0) try conn.readFrame();
        try conn.writeReady();
        try testing.expectEqual(@as(u32, 6), conn.events_open);
        // 6 x 20,008 against a window of 65,535: three go whole and a fourth
        // in part before the window is gone.
        try room.sayText(&big);
        try conn.writeReady();
        {
            var got = try h2test.answerOf(out.written());
            defer got.deinit();
            var total: usize = 0;
            var starved: usize = 0;
            for (ids) |id| {
                const n = (try dataOn(&got, id)).len;
                total += n;
                if (n == 0) starved += 1;
            }
            try testing.expectEqual(@as(usize, 65_535), total);
            try testing.expectEqual(@as(usize, 2), starved);
        }
        var ping: std.Io.Reader = .fixed(second.buf.written()[h2.preface.len + h2.header_len ..]);
        try nextFrames(&conn, &ping);
        try conn.writeReady();
        {
            // Ten bytes of window: the whole answer, which is four of them,
            // goes before the streams that have waited longest.
            var got = try h2test.answerOf(out.written());
            defer got.deinit();
            try testing.expectEqualStrings("pong", try dataOn(&got, 13));
        }
        var more: std.Io.Reader = .fixed(third.written());
        try nextFrames(&conn, &more);
        try conn.writeReady();
    }
    var got = try h2test.answerOf(out.written());
    defer got.deinit();
    for (ids) |id| try testing.expectEqual(@as(usize, event_bytes), (try dataOn(&got, id)).len);
}

test "a GOAWAY from the client ends an event stream on HTTP/2 after what was posted, and the seat goes" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 4 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .path = "/feed" });
    try h2test.requestOn(&client, 3, .{ .path = "/say" });
    try h2.writeGoaway(client.w(), 3, .no_error);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("data: say 0\n\n", try dataOn(&got, 1));
    const data = Answer.of(.data, &got, 1);
    try testing.expect(data[data.len - 1].head.has(h2.Flags.end_stream));
    try testing.expectEqualStrings("said", try dataOn(&got, 3));
    try testing.expectEqual(@as(usize, 0), room.count());
    try room.sayText("after the connection");
}

test "a connection that ends under an event stream on HTTP/2 gives the seat up, and a room that speaks after it is harmless" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 4 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .path = "/feed" });
    try h2test.requestOn(&client, 3, .{ .path = "/say" });

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("data: say 0\n\n", try dataOn(&got, 1));
    // It was left open: nothing ended it, and the client simply went.
    for (Answer.of(.data, &got, 1)) |f| try testing.expect(!f.head.has(h2.Flags.end_stream));
    try testing.expectEqual(@as(usize, 0), room.count());
    try room.sayText("after the connection");
    try room.event(.{ .id = "9", .data = "still harmless" });
}

test "a server that is stopping ends the event streams of an HTTP/2 connection and says GOAWAY" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 4 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();
    stopping_app = &app;
    var client = try TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .path = "/feed" });
    try h2test.requestOn(&client, 3, .{ .path = "/stop" });

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.no_error, got.goaway().?);
    const data = Answer.of(.data, &got, 1);
    try testing.expect(data.len >= 1 and data[data.len - 1].head.has(h2.Flags.end_stream));
    try testing.expectEqualStrings("stopping", try dataOn(&got, 3));
    try testing.expectEqual(@as(usize, 0), room.count());
}

test "event streams count against the cap of streams like any open stream, and the one past it is refused" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = max_streams + 8 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    var id: u31 = 1;
    for (0..max_streams + 1) |_| {
        try h2test.requestOn(&client, id, .{ .path = "/feed" });
        id += 2;
    }
    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.refused_stream, got.rst(id - 2).?);
    try testing.expect(got.rst(1) == null);
    try testing.expectEqual(@as(u32, max_streams), feed_calls.load(.acquire));
    try testing.expectEqual(@as(usize, 0), room.count());
}

test "an event stream on HTTP/2 allocates nothing for a post: a hundred cost what one does" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 4, .backlog = 4 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();
    var counting = heap_count.Counting{ .child = testing.allocator };
    var results: [2]usize = undefined;
    for (&results, [_]usize{ 1, 100 }) |*result, posts| {
        var client = try TestClient.init();
        defer client.deinit();
        try h2test.requestOn(&client, 1, .{ .path = "/feed" });
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(client.buf.written());
        var conn = try steppedConn(&app, &in, &out.writer);
        defer conn.deinit();
        conn.scratch.deinit();
        conn.scratch = .init(counting.allocator());
        conn.gpa = counting.allocator();
        while (in.bufferedLen() > 0) try conn.readFrame();
        try conn.writeReady();
        // The first event sizes the buffer it is formatted in, once.
        try room.sayText("warm");
        try conn.writeReady();
        counting.reset();
        for (0..posts) |_| {
            try room.sayText("0123456789abcdef");
            try conn.writeReady();
        }
        result.* = counting.allocs;
        var got = try h2test.answerOf(out.written());
        defer got.deinit();
        try testing.expectEqual((try dataOn(&got, 1)).len, "data: warm\n\n".len + posts * "data: 0123456789abcdef\n\n".len);
    }
    try testing.expectEqual(@as(usize, 0), results[0]);
    try testing.expectEqual(results[0], results[1]);
}

test "a WebSocket is still refused by name on HTTP/2 beside an event stream" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 4 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2test.requestOn(&client, 1, .{ .path = "/feed" });
    try h2test.requestOn(&client, 3, .{ .path = "/ws" });
    var ex = try h2test.exchangeOf(try converse(&app, &client), 3);
    defer ex.deinit();
    try testing.expectEqual(@as(u16, 500), ex.status);
    try testing.expect(std.mem.indexOf(u8, ex.body, "is HTTP/1.1 only") != null);
    try testing.expectEqual(@as(usize, 0), room.count());
}

test "a client that gives its window back a byte at a time does not make a held event be formatted again, and is a flood" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 4, .backlog = 4 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 0 }});
    try h2test.requestOn(&client, 1, .{ .path = "/feed" });
    var updates: std.Io.Writer.Allocating = .init(testing.allocator);
    defer updates.deinit();
    for (0..max_control_run + 5) |_| try h2.writeWindowUpdate(&updates.writer, 1, 1);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    var conn = try steppedConn(&app, &in, &out.writer);
    defer conn.deinit();
    while (in.bufferedLen() > 0) try conn.readFrame();
    try conn.writeReady();

    const stream_mod = @import("stream.zig");
    stream_mod.Http2Events.formatted = 0;
    const big = [_]u8{'x'} ** 5000;
    try room.sayText(&big);
    // Nothing can be written: the event is not even formatted.
    try conn.writeReady();
    try conn.writeReady();
    try testing.expectEqual(@as(usize, 0), stream_mod.Http2Events.formatted);

    var feed: std.Io.Reader = .fixed(updates.written());
    conn.in = &feed;
    var calm = false;
    while (feed.bufferedLen() > 0) {
        conn.readFrame() catch |err| {
            try testing.expectEqual(error.Calm, err);
            calm = true;
            break;
        };
        try conn.writeReady();
    }
    // A byte a frame is a flood, however the event is written.
    try testing.expect(calm);
    // And the event was formatted the once, whatever the turns it took.
    try testing.expectEqual(@as(usize, 1), stream_mod.Http2Events.formatted);
}

test "a server that stops ends a busy event stream with its end and everything posted, and a stuck one with a reset" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 4, .backlog = 16 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();

    // Open windows and more posted than one turn writes: the stream is busy,
    // not stuck, so it is ended and not reset.
    {
        var client = try TestClient.init();
        defer client.deinit();
        try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 1 << 24 }});
        try h2.writeWindowUpdate(client.w(), 0, (1 << 24) - 65_535);
        try h2test.requestOn(&client, 1, .{ .path = "/feed" });
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(client.buf.written());
        {
            var conn = try steppedConn(&app, &in, &out.writer);
            defer conn.deinit();
            while (in.bufferedLen() > 0) try conn.readFrame();
            try conn.writeReady();
            const piece = [_]u8{'y'} ** 20_000;
            for (0..12) |_| try room.sayText(&piece);
            try conn.goaway(.no_error);
            try conn.endEvents();
        }
        var got = try h2test.answerOf(out.written());
        defer got.deinit();
        try testing.expect(got.rst(1) == null);
        const data = Answer.of(.data, &got, 1);
        try testing.expect(data[data.len - 1].head.has(h2.Flags.end_stream));
        try testing.expectEqual(@as(usize, 12 * (20_000 + "data: \n\n".len)), (try dataOn(&got, 1)).len);
        try testing.expectEqual(@as(usize, 0), room.count());
    }

    // A window of 100 bytes and an event of 5,000: it cannot be finished, so
    // the stream is reset rather than ended in the middle of an event.
    {
        var client = try TestClient.init();
        defer client.deinit();
        try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 100 }});
        try h2test.requestOn(&client, 1, .{ .path = "/feed" });
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(client.buf.written());
        {
            var conn = try steppedConn(&app, &in, &out.writer);
            defer conn.deinit();
            while (in.bufferedLen() > 0) try conn.readFrame();
            try conn.writeReady();
            const piece = [_]u8{'z'} ** 5000;
            try room.sayText(&piece);
            try conn.goaway(.no_error);
            try conn.endEvents();
        }
        var got = try h2test.answerOf(out.written());
        defer got.deinit();
        try testing.expectEqual(h2.ErrorCode.cancel, got.rst(1).?);
        try testing.expectEqual(@as(usize, 100), (try dataOn(&got, 1)).len);
        try testing.expectEqual(@as(usize, 0), room.count());
    }
}

test "an event that cannot be kept for want of memory resets its stream and nothing else" {
    resetFeed();
    const previous = quiet();
    defer testing.log_level = previous;
    var room = try feedRoom(.{ .seats = 4, .backlog = 4 });
    defer room.deinit();
    feed_room = &room;
    defer feed_room = null;
    var app = try feedApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 100 }});
    try h2test.requestOn(&client, 1, .{ .path = "/feed" });
    try h2test.requestOn(&client, 3, .{ .path = "/ping" });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    {
        var conn = try steppedConn(&app, &in, &out.writer);
        defer conn.deinit();
        while (in.bufferedLen() > 0) try conn.readFrame();
        try conn.writeReady();
        // The event goes in part, and the rest has nowhere to be kept.
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        conn.gpa = failing.allocator();
        const piece = [_]u8{'q'} ** 5000;
        try room.sayText(&piece);
        try conn.writeReady();
        conn.gpa = testing.allocator;
        try testing.expectEqual(@as(usize, 0), conn.events_open);
        try testing.expectEqual(@as(usize, 0), room.count());
        try conn.writeReady();
    }
    var got = try h2test.answerOf(out.written());
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.internal_error, got.rst(1).?);
    try testing.expectEqualStrings("pong", try dataOn(&got, 3));
}
