//! Answering one request: read the head, match it, run the chain, write back.
//!
//! Split from `app.zig` because the two halves of that file are paid for at
//! different times. Everything here runs per request and is what the
//! allocation budget and the per-connection stack figures are about
//! (ADR 017, ADR 062); `wiring.zig` next door runs once, inside `listen()`.
//! `App` still owns them both — these are its methods, called as
//! `serve.serveRequest(app, …)` rather than `app.serveRequest(…)`.

const std = @import("std");
const app_mod = @import("app.zig");
const bulkhead = @import("bulkhead.zig");
const body_mod = @import("body.zig");
const http1 = @import("http1.zig");
const range_mod = @import("range.zig");
const router = @import("router.zig");
const ctx_mod = @import("ctx.zig");
const str_mod = @import("nilo_core");
const fail = @import("fail.zig");
const mw = @import("middleware.zig");
const static_mod = @import("static.zig");
const compress_mod = @import("compress.zig");
const watchdog = @import("watchdog.zig");
const scratch = @import("scratch.zig");
const websocket = @import("websocket.zig");
const handover_mod = @import("handover.zig");
const metrics_mod = @import("metrics.zig");
const failurebody = @import("failurebody.zig");
const framing_mod = @import("framing.zig");
const json = @import("json.zig");
const trace_mod = @import("trace.zig");

const App = app_mod.App;
const Ctx = ctx_mod.Ctx;

pub fn handleConnection(
    self: *App,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    deadlines: bulkhead.Deadlines,
    waker: bulkhead.Waker,
    peer: bulkhead.Peer,
) void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    // A span of its own, so a Str this connection hands out cannot pass
    // for one of the next connection's (ADR 003).
    var lifetime = str_mod.Lifetime.init();
    defer lifetime.deinit();

    // A stream that writes for an hour is still one write at a time, so
    // this is the per-write limit. A route's own deadline can shorten it for
    // its request (`Ctx.armWriteLimit`), which is why it is armed again
    // below, before each request, rather than left as it was (ADR 105).
    deadlines.armWrite();

    // What this fiber is serving is bound to it once, then reused by
    // every request on the same connection (ADR 006).
    var in_flight = fail.InFlight{};
    var binding = bulkhead.binding_unset;
    bulkhead.bindSlot(&binding, &in_flight);
    defer bulkhead.unbindSlot(&binding);

    while (true) {
        // Find out whether this connection is going quiet before deciding
        // to give its pages back, and then do the waiting *here* —
        // this frame, not `readHead`'s.
        //
        // Doing it unconditionally costs more than it saves: on a busy
        // keep-alive connection the next request is already arriving, so
        // every cycle pays an madvise and faults the same pages straight
        // back in — measured at 1.31M req/s down to 626k, a 52% loss,
        // because MADV_DONTNEED in a process with eight threads shoots
        // down TLB entries on all of them. So the pages only go once a
        // short read has come back empty, which a connection under load
        // never sees and a browser tab between clicks always does.
        if (!waitForRequest(in, out, deadlines, waker)) {
            out.flush() catch {};
            return;
        }

        // Back to `listen()`'s limit for this request, undoing whatever the
        // last one's deadline did to it. A field store and no allocation.
        deadlines.armWrite();
        var served = serveRequest(self, arena.allocator(), &lifetime, &in_flight, in, .{ .wire = out }, deadlines, waker, peer);
        // A handler that upgraded runs its loop here rather than inside
        // `serveRequest`, so that the request's 1,608 bytes are unwound
        // before a socket suspends for the next hour (ADR 062).
        runHandover(&served);
        // The request is done: every Str of its goes stale, then the
        // bag is emptied in one go.
        //
        // Capacity is kept, but only up to a point. Keeping all of it
        // means one 1MB upload leaves that connection holding a
        // megabyte for as long as it stays open, and a few thousand
        // idle keep-alive connections that each once saw a big request
        // add up to memory nobody can account for.
        //
        // Which way that trade goes is the caller's, because the answer
        // depends on how big their responses are and how many connections
        // they hold: below this figure the block is reused, above it the
        // pages are handed back and faulted in again next time (ADR 075).
        lifetime.end();
        _ = arena.reset(.{ .retain_with_limit = self.arena_keep });
        if (!served.keep_alive) {
            // The last answer on this connection may still be buffered: a
            // response is flushed when the connection next reads, and this
            // connection never reads again (ADR 201). Before the FIN below,
            // for the same reason the FIN comes before the close.
            out.flush() catch {};
            if (served.linger) hangUp(in, deadlines, waker);
            return;
        }
    }
}

/// How much of a refused request is thrown away before hanging up on it,
/// and how long that is given. A peer that has read the answer hangs up
/// within a round trip; one that keeps sending, or never reads, gets the
/// reset it was always going to get once either bound is reached.
const linger_limit: usize = 64 * 1024;
const linger_ms: u32 = 1000;

/// Close so the peer gets the answer: a refused request has bytes still
/// queued on the socket, and closing with input unread makes the kernel
/// send a reset instead of a FIN — and a peer that receives a reset throws
/// the buffered answer away. Windows does; so does anything that reads the
/// error before the data. So the send side is shut first, which tells the
/// peer there is nothing more to wait for, and what it sent is thrown away
/// until it hangs up, or `linger_ms` passes, or `linger_limit` bytes of a
/// peer that keeps sending ([ADR 195](../docs/adr/195-a-refused-request-is-hung-up-on-with-a-fin.md)).
///
/// **`linger_ms` is for the whole of it, not for each read.** Armed per read,
/// a peer sending a byte every 900 ms stayed inside it until the 64 KiB,
/// about eighteen hours of a fiber for a request already refused.
///
/// Only on the paths that set `Served.linger`, which is where unread input
/// is possible; an ordinary `Connection: close` has nothing queued and closes
/// as it always did, with no syscall and no wait.
fn hangUp(in: *std.Io.Reader, deadlines: bulkhead.Deadlines, waker: bulkhead.Waker) void {
    waker.halfClose();
    deadlines.armAllReads(linger_ms);
    _ = in.discardShort(linger_limit) catch {};
}

/// How long a connection has to produce its next request before its
/// buffers are handed back to the kernel.
///
/// Long enough that nothing serving back-to-back requests ever reaches it,
/// short enough that a connection a person is behind reaches it between
/// almost any two clicks. It is not a timeout: running out of it costs a
/// syscall and some page faults on the next request, not the connection.
pub const idle_peek_ms = 200;

/// Wait for the next request to start, and hand this connection's pages
/// back if it goes quiet first.
///
/// Give the client `idle_peek_ms` to say something. If it does, this is a
/// busy connection and nothing else happens — the bytes stay buffered and
/// the request that follows reads them. If it does not, the connection is
/// idle and its buffers are worth more to the kernel than to us.
///
/// **The long wait belongs here rather than in `readHead`, and that is the
/// whole point of the function.** A suspended fiber holds its stack down to
/// the frame it is suspended in, so where a connection waits decides what
/// it costs while it waits. The first version released the pages and then
/// walked straight back down into `handleRequest` → `readHead` → `fillMore`
/// and slept there, four kilobytes deeper, faulting in everything it had
/// just given away: the madvise ran on every idle connection and the
/// measured cost per connection did not move by a byte. Waiting at this
/// frame is what makes the release stick — 8,753 bytes an idle keep-alive
/// connection to 4,657, and the difference is exactly one page
/// ([ADR 062](../docs/adr/062-where-a-connection-waits-is-what-it-costs.md)).
///
/// **False ends the connection**, and every way the wait can fail but the
/// peek running out is one: the client closed or broke the connection, the
/// idle limit passed, or a stop cancelled the wait. The last is why it
/// cannot be left for `readHead` to meet again: zio delivers a cancel once,
/// so the read after a swallowed one parked under a fresh idle limit, and a
/// stop waited on every idle keep-alive connection for up to twice that
/// limit. Nothing is lost by not reporting the others, since no request had
/// started and nothing is owed to anybody.
pub fn waitForRequest(
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    deadlines: bulkhead.Deadlines,
    waker: bulkhead.Waker,
) bool {
    // Already holding a pipelined request: not idle, and the buffer is
    // live data that must not be discarded.
    if (in.seek != in.end) {
        deadlines.armIdle();
        return true;
    }

    deadlines.armPeek(idle_peek_ms);
    in.fillMore() catch |err| {
        if (err != error.ReadFailed or !deadlines.timedOut()) return false;
        bulkhead.releaseIdlePages(in, out);
        waker.releaseStack();
    };

    // Waiting for the next request to start is the idle limit, not the
    // header one. Armed every time round: a connection that has just
    // served a request is idle again from now, not from whenever it was
    // accepted.
    deadlines.armIdle();
    if (in.seek == in.end) in.fillMore() catch return false;
    return true;
}

/// What one request left behind.
///
/// `handover` is set when the handler turned the connection into a
/// WebSocket: the socket is open, the handshake is answered, and the loop
/// that is going to read it has not started. Running it is the caller's,
/// so that it runs from the caller's frame (ADR 062).
pub const Served = struct {
    keep_alive: bool,
    handover: handover_mod.Handover = .none,
    /// Set with `keep_alive` false when the client's bytes may still be on
    /// the socket unread — a head that was refused, a body nobody took. The
    /// connection loop then hangs up with a FIN first rather than a reset,
    /// so the answer reaches the peer (ADR 195). Never set for a peer that
    /// is already gone, or one that stalled: there is nothing to wait for.
    linger: bool = false,
};

/// The request's span, opened before the chain and closed on every way out.
/// Reached through `app.trace_hooks`, which only `app.trace` sets, so a
/// program that never calls it compiles none of this, the ids and the ring
/// included (ADR 247, ADR 017's request-path rule). The request path holds
/// one null check on each side.
pub fn traceBegin(c: *Ctx, tracer: *trace_mod.Tracer) void {
    c._tracer = tracer;
    const carried = traceHeaders(c);
    c._trace = tracer.begin(carried.parent, carried.state);
}

pub fn traceFinish(c: *Ctx, path: []const u8) void {
    const tracer = c._tracer orelse return;
    tracer.finish(
        &c._trace,
        spanMethod(c.method),
        if (c._route) |route| route.pattern else "",
        path,
        c.answered() orelse 0,
    );
}

/// `traceparent` and `tracestate` in one walk of the request's headers,
/// rather than one walk each.
fn traceHeaders(c: *const Ctx) struct { parent: ?[]const u8, state: ?[]const u8 } {
    var parent: ?[]const u8 = null;
    var state: ?[]const u8 = null;
    var it = http1.HeaderIterator.from(c._head);
    while (it.next()) |h| {
        if (h.name.len == 11 and std.ascii.eqlIgnoreCase(h.name, "traceparent")) parent = h.value;
        if (h.name.len == 10 and std.ascii.eqlIgnoreCase(h.name, "tracestate")) state = h.value;
    }
    return .{ .parent = parent, .state = state };
}

/// A method's name as a span keeps it: the record outlives the request, so it
/// is a literal, and a method nilo does not name is OpenTelemetry's `_OTHER`.
fn spanMethod(method: http1.Method) []const u8 {
    return switch (method) {
        .other => "_OTHER",
        inline else => |m| @tagName(m),
    };
}

/// Answer one request, and hand back a socket if the handler opened one.
///
/// `noinline` deliberately. Everything this touches — the `Ctx`, the
/// parsed head, the route match — is 1,608 bytes that the connection loop
/// must not be holding while it waits for the next request, and a frame
/// the compiler inlines is a frame that lives as long as its host's
/// (ADR 062).
pub noinline fn serveRequest(
    self: *App,
    arena: std.mem.Allocator,
    lifetime: *str_mod.Lifetime,
    in_flight: *fail.InFlight,
    in: *std.Io.Reader,
    sink: framing_mod.Sink,
    deadlines: bulkhead.Deadlines,
    waker: bulkhead.Waker,
    peer: bulkhead.Peer,
) Served {
    var handover: handover_mod.Handover = .none;
    // Started here rather than after the head is read, so that a request
    // whose head never arrived is timed from the same instant as one that
    // was answered. On a server that never called `metrics()` this is a
    // null pointer and no clock read at all (ADR 079).
    var record = metrics_mod.Record.begin(if (self.metrics_table) |*t| t else null);
    const failure = &in_flight.failure;
    in_flight.startRequest("", "");
    // What keeps fail functions working when App is called straight from a
    // test, with no Engine underneath. Only then: on a real server the
    // fiber's own slot is bound and is what they reach, and the fallback is
    // a threadlocal. Set here, it stayed set on the executor thread through
    // every suspension of this request, where a spawned fiber, which has no
    // slot, read it and wrote into this request (ADR 006).
    const standalone = bulkhead.fiberSlot() == null;
    const prev_slot = if (standalone) bulkhead.setFallbackSlot(in_flight) else null;
    defer if (standalone) {
        _ = bulkhead.setFallbackSlot(prev_slot);
    };

    const raw_head = http1.readHead(in, deadlines) catch |err| {
        switch (err) {
            error.EndOfStream => {},
            // A timeout arrives as a read failure like any other, so
            // which one it was has to be asked (ADR 022). The bytes
            // that did turn up are still buffered, and they are what
            // separates the two cases worth telling apart: a client
            // halfway through a head gets a 408, a connection that sat
            // idle without asking for anything is just closed.
            error.ReadFailed => if (deadlines.timedOut() and in.buffered().len > 0) {
                sendFinal(sink, RESPONSE_408, 408);
                record.finish(408);
            },
            error.HeadTooLong => {
                sendFinal(sink, RESPONSE_431, 431);
                record.finish(431);
                // The rest of the head is still queued: the reason it was
                // refused is that it did not fit in the buffer.
                return .{ .keep_alive = false, .linger = true };
            },
        }
        return .{ .keep_alive = false };
    };
    // From here there is a request to answer, and a stop has to wait for
    // it. Not before: until the head arrived this connection was parked
    // in a read, holding no work, and counting that as something to wait
    // on would put the whole grace period behind every idle browser tab.
    const already = self.stop.in_flight.fetchAdd(1, .acq_rel);
    defer _ = self.stop.in_flight.fetchSub(1, .acq_rel);

    var r = http1.Request{};
    http1.parseHead(raw_head, &r) catch |err| {
        // One of these is not a malformed request: a body under a
        // `Content-Encoding` nilo cannot decode is a request everybody
        // understands and this server cannot read (ADR 089). gzip is not
        // one of them any more.
        const answer, const status: u16 = switch (err) {
            error.UnsupportedContentEncoding => .{ RESPONSE_415, 415 },
            // A version spelled like one and not spoken (RFC 9110 §15.6.6), and
            // a transfer coding stacked under `chunked` (RFC 9112 §6.1). Neither
            // is malformed, and neither is a reason to read what follows.
            error.UnsupportedVersion => .{ RESPONSE_505, 505 },
            error.UnsupportedTransferEncoding => .{ RESPONSE_501, 501 },
            else => .{ RESPONSE_400, 400 },
        };
        sendFinal(sink, answer, status);
        record.finish(status);
        // A head that did not parse may have a body behind it, and a body
        // under a coding nilo cannot read certainly does.
        return .{ .keep_alive = false, .linger = true };
    };

    // Past the limit on requests in flight, and said so now rather than
    // after a queue (ADR 159). `already` is what the atomic above handed
    // back for free, so this is one comparison and no second load. Before
    // the head is copied, before the router is asked: a shed request costs
    // one write of a constant.
    if (self.limits.max_in_flight != 0 and already >= self.limits.max_in_flight) {
        sendFinal(sink, RESPONSE_503_SHED, 503);
        record.at(metrics_mod.shed);
        record.finish(503);
        return .{ .keep_alive = false, .linger = http1.readsMore(&r) };
    }

    // Every `Str` from this request points into the head, and the head is
    // sitting in the connection's read buffer — where the next read
    // overwrites it. So it is copied into the request arena, but only when
    // there is going to be a next read: a body to take in, or a protocol
    // about to take the socket over. On a GET, which is the shape the
    // primary metric measures and most of the traffic besides, nothing
    // reads again and the copy has nobody to protect — worth 19ns on a
    // small head and 77ns on the one a browser really sends, plus one of
    // the three allocations a request makes.
    //
    // What holds it together is `Ctx.aboutToRead`: every path that reads
    // from the connection calls it, and it fails loudly in a debug build
    // if this decision said there would be no such path.
    const borrowed = !http1.readsMore(&r);
    const request_head = if (borrowed) raw_head else copy: {
        const copied = arena.dupe(u8, raw_head) catch return .{ .keep_alive = false };
        // The slices the parser left pointing into the old bytes.
        // Everything derived below — the path, the query, the params —
        // comes off `r.target`, so moving these moves all of it.
        r.method = rebase(raw_head, copied, r.method);
        r.target = rebase(raw_head, copied, r.target);
        // Empty unless the target arrived in absolute form (ADR 095), and
        // an empty slice has no offset into the head to move — `""` points
        // at a static byte, and rebasing that lands anywhere.
        if (r.authority.len > 0) r.authority = rebase(raw_head, copied, r.authority);
        break :copy copied;
    };
    in.toss(raw_head.len);

    const qmark = std.mem.indexOfScalar(u8, r.target, '?');
    const path = if (qmark) |i| r.target[0..i] else r.target;
    const raw_query = if (qmark) |i| r.target[i + 1 ..] else "";

    // From here on the panic handler can name what was being served
    // (ADR 007). Both slices live in the request arena.
    in_flight.startRequest(r.method, path);

    var c = Ctx{
        .method = http1.methodFrom(r.method),
        ._arena = arena,
        ._lifetime = lifetime,
        ._in = in,
        ._framing = framing_mod.of(sink, in, r.minor_version),
        ._request = &r,
        ._path = path,
        ._query = raw_query,
        ._query_params = ctx_mod.parseQuery(arena, raw_query) catch return .{ .keep_alive = false },
        ._head = request_head,
        ._head_borrowed = borrowed,
        ._watch = &in_flight.watch,
        ._deadlines = deadlines,
        ._waker = waker,
        ._peer = peer,
        ._limits = self.limits,
        // A pointer to the App's copy, not the copy: the key is 32 bytes
        // on every Ctx otherwise, for something almost no request reads.
        ._session_key = if (self.session_key) |*k| k else null,
        ._session_fallbacks = &self.session_fallbacks,
        ._session_plain = self.session_plain_name,
        ._compressors = if (self.compressors) |*p| p else null,
        ._params = &.{},
        ._services = &self.services,
        // Stopping: this one still gets answered — a request already on
        // the wire is not the client's fault — but the answer says
        // `Connection: close` so the client opens a fresh connection
        // next time, to a server that is still there. Dropping a
        // keep-alive connection without a word is how a deploy turns
        // into a handful of failed requests nobody can reproduce.
        ._stopping = &self.stop.requested,
        // Where a handler that upgrades leaves the socket. The slot is
        // this frame's, and what is in it is copied out on the way back —
        // the caller runs the loop from *its* frame (ADR 062).
        ._handover = &handover,
    };

    // `listen()`'s deadline for every request, before the chain runs so a
    // route's own `nilo.deadline` replaces it rather than the other way
    // round. One clock read when set, none when it is not (ADR 105).
    c.giveDefaultDeadline(self.limits.request_deadline_ms);

    // Every way out of here from this point on — a clean answer, a
    // failure, a stream abandoned, a socket handed over — goes past this,
    // which is the reason the counting is not a middleware. The status a
    // request really had is only settled here, and a second place working
    // it out again is a second place to get it wrong (ADR 079).
    defer record.finish(c.answered() orelse 0);

    // The request's span, opened before the chain so a middleware's time is
    // the request's, and kept on every way out for the reason the counting
    // above is: the status is settled only here (ADR 247). An App that does
    // not trace pays this one compare, and links none of it.
    if (self.trace_hooks) |hooks| hooks.begin(&c, self.tracer.?);
    defer if (self.trace_hooks) |hooks| hooks.finish(&c, path);

    // A request that matched no route still runs the middleware: a
    // logger that cannot see 404s and a CORS that cannot answer a
    // preflight for an unknown path are both useless exactly when you
    // need them. What changes is only the innermost call (ADR 008).
    var chain: []const mw.Middleware = &.{};
    var terminal: mw.CtxHandler = notFoundHandler;

    // Held in a variable of this scope on purpose: `c` borrows the
    // params out of it, and they have to outlive the branch below.
    var matched: router.Match = undefined;

    // The parser lets exactly two targets through that do not begin with `/`:
    // `*` for an OPTIONS and an authority for a CONNECT (ADR 095). Neither
    // names a route, and the router splits on `/` without knowing the first
    // one was missing, so a root `/*` would have answered both.
    const routable = path[0] == '/';

    // A route bound to other listeners is a path that is not here, decided
    // before any middleware runs, so it falls to the same 404 an unknown
    // path gets (ADR 252). A route bound to none is one compare of a word.
    if (routable and self.router.matchInto(c.method, path, &matched) and
        router.onListener(self.router.routes.items[matched.index].listeners, peer.listener))
    {
        const match = &matched;
        // Decoded here rather than before matching: `%2F` is a slash of
        // data, and a router that saw it as a separator would let a
        // request reach a route it does not name.
        const params = match.params[0..match.n_params];
        ctx_mod.decodeParams(arena, params) catch return .{ .keep_alive = false };
        c._params = params;
        const route = &self.router.routes.items[match.index];
        c._route = route;
        // A route whose pattern has a `:param` or `*` where a scoped
        // middleware's prefix has a word is covered by it for some paths
        // and not others, so its chain is built here from the real one: one
        // arena allocation, paid only by such a route (ADR 008). A chain
        // that cannot be built is not run without its guard.
        chain = if (route.chain_by_path)
            mw.chainFor(arena, self.scoped.items, self.exemptions.items, self.attached.items, route.method, route.pattern, path) catch
                return .{ .keep_alive = false }
        else
            match.chain;
        terminal = match.handler;
        record.at(metrics_mod.fixed_slots + match.index);
    } else if (if (routable) findStatic(self, &c, path) else null) |found| {
        // Resolved at `listen()` with the routes' chains, so an asset
        // served with a logger or a CORS in front of it allocates
        // nothing — which is the shape nearly every app deploys, and
        // the one the budget test used to step around rather than
        // measure (ADR 017).
        c._static_file = found.file;
        terminal = serveStaticFile;
        chain = found.chain;
        record.at(metrics_mod.static_file);
    } else {
        // Nothing is precomputed for a path that is neither a route nor
        // a file, because the set of them is every string there is. So
        // the chain is built here, out of the request arena — one
        // allocation, bounded by the middleware count, and paid only by
        // a 404 or a 405.
        if (self.scoped.items.len > 0) {
            chain = mw.chainFor(arena, self.scoped.items, self.exemptions.items, self.attached.items, null, path, path) catch &.{};
        }
        // No route for this method, but the path itself is spelled out
        // by routes under other methods. "There is nothing here" and
        // "there is something here, but not for that verb" are
        // different answers, and a 404 for the second one sends you
        // looking for a registration bug that is not there.
        //
        // A target that is not a path asks the router nothing: `OPTIONS *` is
        // the server-wide question and is answered by `serverOptionsHandler`
        // from every route's method, and a CONNECT is a 404 (ADR 095).
        const allowed = if (routable) self.router.allowedForOn(path, peer.listener) else router.MethodSet.initEmpty();
        if (allowed.count() > 0) {
            c._allowed = allowed;
            terminal = methodNotAllowedHandler;
        } else if (!routable and c.method == .OPTIONS and path[0] == '*') {
            c._allowed = allowedAnywhere(self);
            terminal = serverOptionsHandler;
        }
        // Told apart rather than merged, because a spike against one
        // unnamed slot could be a scanner, a deploy that dropped a route
        // or a form posting to a GET, and those are three afternoons.
        record.at(if (allowed.count() > 0)
            metrics_mod.method_not_allowed
        else
            metrics_mod.unmatched);
    }

    // The one mistake the compiler cannot catch and everybody else pays
    // for: a handler that waits on the operating system directly holds
    // the thread every other request on it is being served by
    // (ADR 013). Bracketed around the whole chain rather than around
    // the terminal handler, because a middleware that blocks stops the
    // thread just as dead as a handler that does.
    watchdog.begin(&in_flight.watch, self.limits.block_warning_ms, @tagName(c.method), path);

    (mw.Next{ .rest = chain, .handler = terminal }).run(&c) catch |err| {
        watchdog.finish(&in_flight.watch);
        // An answer a middleware held has not been written, so the failure
        // replaces it as it would replace nothing (ADR 008).
        c.dropHeld();
        // A half-sent response cannot be taken back, so the connection
        // is closed: the next request on it would read leftover bytes
        // of unclear provenance.
        if (c.answered() != null) {
            warnFailedAfterAnswering(&c, path, deadlines, err);
            return .{ .keep_alive = false, .handover = handover, .linger = http1.readsMore(&r) };
        }
        // Nothing sent yet: this is a clean failure. A body nobody read
        // still has to be discarded so the connection can be reused —
        // a 404 from a fail function is a normal way to live, not a
        // reason to drop keep-alive. If it cannot be discarded the
        // answer still goes out; only the connection is given up.
        const reusable = drain(&c, in, &r);
        // Not reusable and a body was announced: some of it may be unread —
        // too big to discard, or behind an `Expect` nobody answered. That is
        // the 413 naming `bodyStream()` that a reset would take back.
        const linger = !reusable and http1.readsMore(&r);
        sendFailure(&c, failure, err, self.failure_write) catch return .{ .keep_alive = false, .handover = handover, .linger = linger };
        return .{ .keep_alive = reusable, .handover = handover, .linger = linger };
    };
    watchdog.finish(&in_flight.watch);

    // A body the handler did not read is discarded so the next request
    // on this connection starts at the right byte.
    const reusable = drain(&c, in, &r);
    const linger = !reusable and http1.readsMore(&r);

    // What a middleware held goes out now that every layer has had its say
    // (ADR 008). A held file that can no longer be positioned has had its
    // status taken already, so the connection goes rather than a second
    // answer.
    c.releaseHeld() catch return .{ .keep_alive = false, .handover = handover, .linger = linger };

    if (c.answered() == null) {
        // A handler that returned without answering meant an empty 200
        // (ADR 120). A middleware that returned without answering and
        // without calling `next` meant nothing at all: it is a guard that
        // forgot its 401, and an empty 200 would let it read as a success
        // with the handler never run, so it is a 500 naming the layer
        // (ADR 008). A failure a handler caught has nothing to do with it.
        if (c._chain_left != 0) {
            std.log.warn(
                "{s} {s}: middleware {d} of {d} returned without answering and without calling next.run(c); answered 500",
                .{ @tagName(c.method), path, chain.len - @min(c._chain_left, chain.len) + 1, chain.len },
            );
            failure.clear();
            sendFailure(&c, failure, error.MiddlewareAnsweredNothing, self.failure_write) catch
                return .{ .keep_alive = false, .handover = handover, .linger = linger };
            return .{ .keep_alive = reusable, .handover = handover, .linger = linger };
        }
        // No content type, because there is no content to give one to.
        sendDirect(&c, 200, "", "") catch return .{ .keep_alive = false, .handover = handover, .linger = linger };
    }
    if (c._stream != null) return .{ .keep_alive = endStream(&c), .handover = handover, .linger = linger };
    return .{ .keep_alive = reusable, .handover = handover, .linger = linger };
}

/// Run the socket a handler handed back, from the caller's frame.
///
/// The `Handover` has stopped moving by the time this is called, which is
/// what lets the Socket's buffer slot point at the one beside it: the loop
/// may walk out without a word, and a buffer nobody hands back is a leak
/// per connection.
pub fn runHandover(served: *Served) void {
    const h = switch (served.handover) {
        .none => return,
        .socket => |*it| it,
        .events => |*events| {
            // A stream that never ends has no end to keep the connection
            // alive past (ADR 227).
            events.run(&events.stream);
            served.keep_alive = false;
            return;
        },
    };
    h.socket._scratch = &h.scratch;
    defer if (h.scratch) |buf| scratch.give(buf);
    h.run(&h.socket, &h.state) catch |err| warnSocketFailed(h.path, err);
    // A seat the handler did not give up still holds this connection's bell,
    // which lives in a frame that is about to return. The next `say` would
    // ring it there (ADR 082), so every seat goes now, whatever the loop did.
    h.socket.leaveRooms();
    // A connection that has been a WebSocket cannot go back to being HTTP.
    served.keep_alive = false;
}

/// A file and the middleware in front of it, both settled before the
/// socket opened.
pub const StaticHit = struct {
    file: *const static_mod.File,
    chain: []const mw.Middleware,
};

/// The static file `path` names, if any set holds one. Only GET and
/// HEAD: a POST to a `.css` is a mistake, and answering it with the
/// stylesheet would hide that.
/// The file this request names, or the page a single-page directory
/// answers a miss with — in that order, and the order is the point
/// (ADR 087).
pub fn findStatic(self: *const App, c: *const Ctx, path: []const u8) ?StaticHit {
    if (findStaticFile(self, c.method, path)) |found| return found;
    if (c.method != .GET and c.method != .HEAD) return null;

    // Only once every set has been asked for the file itself. A page one
    // directory answers its misses with must not hide a file another
    // directory really holds, and asking set by set would let it.
    const asked: static_mod.Asked = .{
        .accept = if (c.header("Accept")) |h| h.view() else null,
        .fetch_mode = if (c.header("Sec-Fetch-Mode")) |h| h.view() else null,
    };
    for (self.static_sets.items, 0..) |*set, i| {
        if (set.fallbackFor(path, asked)) |file| return hitIn(self, i, set, file);
    }
    return null;
}

/// The file `path` names, with no fallback anywhere in it.
pub fn findStaticFile(self: *const App, method: http1.Method, path: []const u8) ?StaticHit {
    if (method != .GET and method != .HEAD) return null;
    // Asked before the loaded directories, not after. A single-page app
    // served from `/` with an `index.html` fallback answers for every
    // path there is, and it would swallow `/openapi.json` whole —
    // which is exactly the setup most likely to want the document.
    if (self.docs_set) |*set| {
        if (set.find(path)) |file| return hit(file, self.docs_chains, set.indexOf(file));
    }
    for (self.static_sets.items, 0..) |*set, i| {
        if (set.find(path)) |file| return hitIn(self, i, set, file);
    }
    return null;
}

/// A hit in the `i`th loaded directory, with the chain `listen()`
/// resolved for it. A set appended without `resolveChains` having run
/// since — which only a test reaching past `static()` can arrange — has
/// no chains, exactly as an unresolved route has none.
pub fn hitIn(
    self: *const App,
    i: usize,
    set: *const static_mod.Set,
    file: *const static_mod.File,
) StaticHit {
    const chains = if (i < self.static_chains.items.len) self.static_chains.items[i] else &.{};
    return hit(file, chains, set.indexOf(file));
}

pub fn hit(
    file: *const static_mod.File,
    chains: []const []const mw.Middleware,
    i: usize,
) StaticHit {
    return .{ .file = file, .chain = if (i < chains.len) chains[i] else &.{} };
}

/// The three answers that go out before there is a Ctx to assemble one with.
/// They carry the same JSON shape every other failure does (ADR 024), so a
/// client has one thing to parse and not two.
const RESPONSE_400 = http1.staticResponse(400, failure_content_type, staticFailure(400, "malformed request"), .close);
const RESPONSE_431 = http1.staticResponse(431, failure_content_type, staticFailure(431, "head too long"), .close);
/// Sent when a body arrives under a `Content-Encoding` nilo cannot decode,
/// which is all of them but `identity` and `gzip` (ADR 089). The
/// message names the header, because the mistake is one line of client
/// configuration and the alternative — a 400 about malformed JSON — sends
/// the reader to the body.
const RESPONSE_415 = http1.staticResponse(415, failure_content_type, staticFailure(415, "this server decodes Content-Encoding: gzip and nothing else — send the body as identity or gzip"), .close);
/// Sent when a request head started arriving and then stopped (ADR 022).
/// Not when a keep-alive connection simply sat idle: that client has not
/// asked for anything, and a status answering nothing is noise a proxy has
/// to decide what to do with.
const RESPONSE_408 = http1.staticResponse(408, failure_content_type, staticFailure(408, "request head timed out"), .close);

/// Sent for a version spelled `HTTP/d.d` that is neither 1.0 nor 1.1 (RFC 9110
/// §15.6.6), where it used to be a 400 that said nothing about versions.
const RESPONSE_505 = http1.staticResponse(505, failure_content_type, staticFailure(505, "this server speaks HTTP/1.1 and HTTP/1.0"), .close);
/// Sent for a `Transfer-Encoding` that names a coding in front of `chunked`
/// (RFC 9112 §6.1): nilo decodes `chunked` and nothing else (ADR 070).
const RESPONSE_501 = http1.staticResponse(501, failure_content_type, staticFailure(501, "this server decodes Transfer-Encoding: chunked and nothing else"), .close);

const failure_content_type = "application/json";

/// Sent when the server is already answering `max_in_flight` requests
/// (ADR 159). Assembled here rather than through `staticResponse` for the
/// one header that function does not write: `Retry-After`, which is what
/// tells a client and a balancer this is load rather than a fault.
const RESPONSE_503_SHED: http1.Static = blk: {
    const body = staticFailure(503, "this server is answering as many requests as it was told to; try again in a moment");
    break :blk .{
        .line = http1.statusLine(503),
        .rest = std.fmt.comptimePrint(
            "Content-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nRetry-After: 1\r\n\r\n{s}",
            .{ failure_content_type, body.len, body },
        ),
    };
};

/// Room for the longest failure body there can be: a message at the Failure's
/// ceiling where every byte needs the six-character `\u00xx` escape, plus the
/// wrapper around it — nilo's own is 32 bytes, and a shape the application
/// named (ADR 024) gets 256 for its envelope.
const failure_body_max = fail.max_message * 6 + 256;

/// A failure body for a message known while compiling — no escaping, because
/// these three are written here and have nothing in them to escape.
fn staticFailure(comptime status: u16, comptime message: []const u8) []const u8 {
    return std.fmt.comptimePrint("{{\"error\":\"{s}\",\"status\":{d}}}", .{ message, status });
}

/// The body of a failure response: the sentence a fail function wrote, in the
/// one shape every client can read (ADR 024).
///
/// A frontend calling `res.json()` on a 4xx used to throw, which is the
/// worst moment to lose the message that says what went wrong. The message
/// itself is unchanged, so `curl` still shows the sentence — one pair of
/// braces further in.
fn writeFailureBody(w: *std.Io.Writer, status: u16, message: []const u8) !void {
    try w.writeAll("{\"error\":");
    // The message can hold a stranger's bytes (`%ff` in a path is decoded
    // without a check), and a body `res.json()` cannot parse is the failure
    // ADR 024 exists to prevent: so a byte that is not text becomes U+FFFD.
    try json.writeLossyString(w, message);
    try w.print(",\"status\":{d}}}", .{status});
}

/// `message` as text a JSON writer cannot be handed a bad byte by, for a
/// shape the application named: it writes the struct `nilo_failure` filled
/// through the ordinary JSON writer, which sends a `[]const u8` that is not
/// UTF-8 as an array of numbers (ADR 096). Valid text, nearly always, is
/// returned as it is; otherwise one copy in the request arena, on a failure
/// the request asked for, and the original if even that fails.
fn lossyMessage(c: *Ctx, message: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(message)) return message;
    var copy = std.ArrayList(u8).initCapacity(c._arena, message.len * 3) catch return message;
    var i: usize = 0;
    while (i < message.len) {
        const n = std.unicode.utf8ByteSequenceLength(message[i]) catch 0;
        if (n != 0 and i + n <= message.len and std.unicode.utf8ValidateSlice(message[i..][0..n])) {
            copy.appendSliceAssumeCapacity(message[i..][0..n]);
            i += n;
        } else {
            copy.appendSliceAssumeCapacity("\u{FFFD}");
            i += 1;
        }
    }
    return copy.items;
}

/// The same bytes as `slice`, pointed at `to` instead of at `from` — for
/// moving a slice of a buffer onto a copy of that buffer.
fn rebase(from: []const u8, to: []const u8, slice: []const u8) []const u8 {
    const offset = @intFromPtr(slice.ptr) - @intFromPtr(from.ptr);
    return to[offset..][0..slice.len];
}

/// Step over a body the handler never read, and say whether the
/// connection is still usable afterwards. A body that cannot be stepped
/// over — a chunked one whose sizes do not add up — leaves the stream at
/// an unknown byte, so the connection has to go; the response, though, is
/// still owed and still sent.
fn drain(c: *Ctx, in: *std.Io.Reader, r: *const http1.Request) bool {
    if (!c.keepAlive() or c._stream_desynced) return false;
    if (c._body != null) return true;
    // The client said `Expect: 100-continue` and nothing here ever answered
    // it, so the body is still on its side and discarding one would be waiting
    // for bytes nobody is going to send until their own timer fires
    // (ADR 073). The final status has gone out, which is the whole of what
    // RFC 9110 §10.1.1 asks for; what this connection cannot do is carry
    // another request, because the one it has is unfinished.
    if (r.expect_continue and !c._continued) return false;
    // Reading here as well as in the handler, so the clock goes on here as
    // well (ADR 022). Without it these reads would inherit whatever limit
    // was last set — the header deadline, which by now has passed — and a
    // client with a body left to send would have its connection dropped for
    // no reason. Only where something is really read, though: arming it on a
    // GET would leave a limit meant for a body sitting on a connection that
    // is about to go idle instead.
    //
    // The handler read the body in pieces and may have stopped part way —
    // a `while (try incoming.read(…))` that breaks early is an ordinary
    // thing to write. What is left of it goes here, so the next request on
    // this connection starts where it should (ADR 019).
    //
    // **The rest gets `body()`'s rate floor, not a per-read limit.** Per read,
    // a POST to a 404 dribbled at a byte every 29 seconds held its fiber with
    // no end, for a body nobody was going to read. Sized from what is left at
    // most, as `readSizedBody` sizes it (ADR 022).
    if (c._incoming) |*progress| {
        if (progress.finished()) return true;
        c._deadlines.armBodyRun(progress.mostLeft());
        var rest = body_mod.Body.init(in, progress);
        rest.discardRest() catch return false;
        return true;
    }
    if (http1.readsMore(r)) {
        const max_body = c._limits.max_body;
        c._deadlines.armBodyRun(if (r.chunked) max_body else @min(r.content_length, max_body));
        http1.discardBody(in, r, max_body) catch return false;
    }
    return true;
}

/// The innermost call when no route matched. It is a normal handler so
/// that middleware wraps a 404 exactly as it wraps anything else.
///
/// It fails rather than answering, so this 404 goes out through the one
/// place that assembles a failure and gets the same body shape as every
/// other (ADR 024).
fn notFoundHandler(c: *Ctx) anyerror!void {
    return fail.notFound("there is no {s}", .{c._path});
}

/// The innermost call when the path is registered but not for this method.
///
/// A normal handler too, so a 405 carries whatever headers the middleware
/// added — CORS included, since a browser has to be able to read the answer
/// to see what went wrong.
fn methodNotAllowedHandler(c: *Ctx) anyerror!void {
    // An OPTIONS asking what a path supports is answered rather than
    // refused: that is the question the method exists for, and the `Allow`
    // header is the answer. It names OPTIONS, because the request that got
    // this answer is one the path answers (RFC 9110 §9.3.7). A preflight
    // never gets this far: CORS middleware handles those before any handler
    // runs.
    if (c.method == .OPTIONS) {
        var allowed = c._allowed;
        allowed.insert(.OPTIONS);
        // Built in the request arena, which outlives the response it is
        // written into, so there is nothing for `setHeader` to copy.
        try c.setStaticHeader("Allow", try allowList(c._arena, allowed));
        return c.sendEmpty(204);
    }

    const allow = try allowList(c._arena, c._allowed);
    try c.setStaticHeader("Allow", allow);

    // Failing rather than answering, for the reason `notFoundHandler` does:
    // one place assembles a failure body. The `Allow` header set above
    // survives it — `sendDirect` writes whatever headers the request
    // collected, which is also what keeps CORS on an error response.
    return fail.status(405, "{s} is not allowed here. This path answers: {s}", .{
        @tagName(c.method),
        allow,
    });
}

/// Every method some route answers, which is what `OPTIONS *` is asking for
/// (RFC 9110 §9.3.7): what the server as a whole supports. OPTIONS is in it,
/// because this is the answer to one.
fn allowedAnywhere(self: *const App) router.MethodSet {
    var all: router.MethodSet = .initEmpty();
    for (self.router.routes.items) |*route| all.insert(route.method);
    if (all.contains(.GET)) all.insert(.HEAD);
    all.insert(.OPTIONS);
    return all;
}

/// The innermost call for `OPTIONS *`, asterisk-form (RFC 9112 §3.2.4). A normal
/// handler so middleware wraps it as it wraps everything else. It is not the
/// router's to match: `*` is not a path, and a root `/*` single-page fallback
/// used to answer it.
fn serverOptionsHandler(c: *Ctx) anyerror!void {
    try c.setStaticHeader("Allow", try allowList(c._arena, c._allowed));
    return c.sendEmpty(204);
}

/// `GET, HEAD, POST` — an `Allow` header's value, in the order the methods
/// are declared so that two runs of the same server say the same thing.
fn allowList(arena: std.mem.Allocator, allowed: router.MethodSet) ![]const u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(arena, 48);
    var first = true;
    inline for (@typeInfo(http1.Method).@"enum".fields) |f| {
        const method: http1.Method = @enumFromInt(f.value);
        // `other` is not a method anybody can register, so it has no
        // business being offered as one.
        if (method != .other and allowed.contains(method)) {
            if (!first) try out.writer.writeAll(", ");
            try out.writer.writeAll(f.name);
            first = false;
        }
    }
    return out.written();
}

/// Answer with a file the App listed at startup. Also a normal handler, so
/// a static response goes through the same middleware as everything else —
/// CORS included, which is what an asset served to another origin needs.
///
/// The one branch is here, at the top, and it is the only place either arm
/// knows the other exists (ADR 009).
fn serveStaticFile(c: *Ctx) anyerror!void {
    const file = c._static_file.?;
    switch (file.contents) {
        .held => return serveHeldFile(c, file),
        .spilled => |on_disk| return serveSpilledFile(c, file, on_disk),
    }
}

/// A file that was too big to read at load. It was never read and is not
/// being read now: the descriptor goes to `sendfile.send`, which writes the
/// head and hands the bytes to the socket without them passing through this
/// process.
///
/// **Everything in the head comes from the descriptor about to be sent**, not
/// from what the directory walk wrote down
/// ([ADR 098](../docs/adr/098-a-file-is-described-by-the-descriptor-being-sent.md)).
/// A held file cannot go stale, because its bytes are the copy in memory; a
/// spilled file is only a name, and the file under that name is free to move
/// while the server runs. Describing it from the walk meant a file that grew
/// went out as its first recorded-length bytes under the ETag of the version
/// before — a complete, correct-looking response carrying a prefix.
fn serveSpilledFile(
    c: *Ctx,
    file: *const static_mod.File,
    on_disk: static_mod.File.Spilled,
) anyerror!void {
    // The name was written down by the directory walk before the socket
    // opened, and the descriptor it is resolved against was too. Nothing a
    // request carried is being turned into a path (ADR 009).
    //
    // Without following a link in the last component: the walk only listed
    // regular files, so a name that is a link now was put there after
    // startup, and serving it would send whatever it points at out of the
    // tree (ADR 009).
    const open = on_disk.dir.openFileNoFollow(on_disk.path) catch |err| switch (err) {
        // The list said the file was there and the disk disagrees, which
        // from the client's side is indistinguishable from asking for
        // something that never existed. Every other way of failing to open
        // one is this server's problem and says so with a 500. A link is the
        // disk disagreeing too.
        error.FileNotFound, error.SymLinkLoop => return fail.notFound("there is no {s}", .{c._path}),
        else => return err,
    };

    // One look, after the open, at the descriptor whose bytes are going out.
    // Both numbers in the head come from it, so the length and the tag cannot
    // describe two different files however often the disk changes underneath.
    // A `stat` that fails takes the descriptor with it, which is the one exit
    // from here that `sendFile` is not already covering.
    const now = open.stat() catch |err| {
        open.close();
        return err;
    };

    // Written into this frame and borrowed until `sendFile` returns, which is
    // after the head is on the wire — the request arena is not touched, and
    // the budget of one allocation per request is unchanged (ADR 017).
    var etag_buf: [static_mod.max_spilled_etag]u8 = undefined;
    const etag = static_mod.spilledEtag(&etag_buf, @as(i96, now.mtime_ns), now.size);

    // No `Vary`, because there is nothing to vary on: a spilled file has one
    // representation and no gzipped copy to negotiate against (ADR 017 —
    // nothing compresses per request). No `defer open.close()` either: the
    // file belongs to `sendFile` from here, on every path out of it.
    return c.sendFile(.{
        .file = open,
        .size = now.size,
        .content_type = file.content_type,
        .etag = etag,
        .cache_control = file.cache_control,
    });
}

/// A file read at load and answered from memory — everything at or below
/// `max_file_bytes`, which is nearly every file a web tree has.
///
/// **What this shares with the spilled arm, and what it does not.** Shared,
/// and it is the part ADR 020 exists to protect: `range_mod.parse` is the
/// only thing anywhere that decides what a `Range` means, including the rule
/// that turns a 206 back into a 200 when `If-Range` does not match — both
/// arms hand it that decision as a flag and neither implements it.
/// `contentRange` and `unsatisfiableRange` write the header, and
/// `static_mod.etagMatches` compares the tags. There is exactly one copy of
/// each, and a corrupt resumed download would have to be a bug in one of
/// them rather than a disagreement between two.
///
/// Not shared, and it cannot be: every line below is measured against a
/// *representation* rather than against the file. A held file may have two —
/// the plain bytes and a gzipped copy, with a different ETag each — so which
/// one the client gets decides the ETag the conditionals compare, the length
/// the range is taken from, and the bytes that go out. A spilled file has
/// exactly one representation and always will (a file that is not held
/// cannot be compressed once), so `sendfile.send` has nothing to choose
/// between and answers from the file's own tag and size. Sharing these lines
/// would mean handing it a choice it can never have.
///
/// **The seam is here rather than beside `sendfile.zig`, and that is worth
/// knowing before the next change to either arm.** This is the one part of
/// the request path that is about static files rather than about serving
/// requests, `headerValue` below is copied into `sendfile.zig` four lines
/// each, and both `If-Range` gaps diverged exactly here. Nothing is wrong
/// today; moving code that works has to be worth the diff, and the next
/// change to either arm is when it is.
fn serveHeldFile(c: *Ctx, file: *const static_mod.File) anyerror!void {
    // A `Range` is an offset into a representation, and the gzipped copy is
    // a different representation with different offsets. Rather than work
    // out which one a client meant, a request that asks for part of a file
    // gets the plain one — which is the representation `Accept-Ranges:
    // bytes` has been promising all along.
    const wants_part = c.header("Range") != null;
    const wants_gzip = !wants_part and
        compress_mod.acceptsGzip(headerValue(c, "Accept-Encoding"));
    const sending = file.representation(wants_gzip);

    // Everything here belongs to the loaded file, which outlives every
    // request, so there is nothing to copy.
    try c.setStaticHeader("ETag", sending.etag);
    if (file.cache_control.len > 0) try c.setStaticHeader("Cache-Control", file.cache_control);
    // Said on every file response, including the 304 and the 416: it is how
    // a client learns it may ask for part of one at all.
    try c.setStaticHeader("Accept-Ranges", "bytes");
    // Whenever there are two representations to choose between — not only
    // when the gzipped one is the one going out. A shared cache that stored
    // the plain answer without this would go on handing it to clients that
    // could have had the small one, and, worse, the other way round.
    if (file.contents.held.gzip != null) try c.setStaticHeader("Vary", "Accept-Encoding");
    if (sending.gzipped) try c.setStaticHeader("Content-Encoding", "gzip");

    // The ETag was computed when the file was read, so a repeat visitor
    // costs a comparison and a head — no body, no work. Compared against
    // the representation actually going out, which is why the two ETags are
    // kept apart in the first place.
    if (c.header("If-None-Match")) |sent| {
        if (static_mod.etagMatches(sent.view(), sending.etag)) {
            return c.send(304, file.content_type, "");
        }
    }

    const total = sending.bytes.len;
    // `If-Range` means "only give me the part if the file is still the one I
    // started with". A client resuming a download sends the ETag it had;
    // anything else and the safe answer is all of it. Strong comparison, which
    // is `etagMatchesStrong` and not the `etagMatches` above — the two arms of
    // static-file serving used to disagree about this, with `sendfile.send`
    // carrying half the rule as a guard of its own (ADR 073).
    const still_the_same = if (c.header("If-Range")) |sent|
        static_mod.etagMatchesStrong(sent.view(), sending.etag)
    else
        true;

    var buf: [range_mod.max_content_range]u8 = undefined;
    switch (range_mod.parse(headerValue(c, "Range"), total, still_the_same)) {
        .whole => {},
        .part => |part| {
            try c.setHeader("Content-Range", range_mod.contentRange(&buf, part, total));
            return c.sendKept(206, file.content_type, part.slice(sending.bytes));
        },
        .unsatisfiable => {
            // The one answer whose whole content is "you have the wrong idea
            // about how big this is", which the header carries and the body
            // does not need to repeat.
            try c.setHeader("Content-Range", range_mod.unsatisfiableRange(&buf, total));
            return c.send(416, file.content_type, "");
        },
    }

    // The bytes are the App's, loaded at startup, so a middleware holding the
    // answer does not copy them (ADR 008).
    try c.sendKept(200, file.content_type, sending.bytes);
}

/// A request header as plain bytes. The `Str` a handler gets is the right
/// shape for a handler and the wrong one for a parser that takes `?[]const
/// u8`, and this is the only place that difference comes up.
fn headerValue(c: *const Ctx, name: []const u8) ?[]const u8 {
    const found = c.header(name) orelse return null;
    return found.view();
}

/// A stream still open when the chain has unwound: one whose end a
/// middleware held, or one a handler returned from without calling
/// `finish()`.
///
/// The zero-length chunk is written here so the client is told where the
/// body stopped instead of waiting for more, and so the connection is left
/// in a state the next request can start from. What cannot be recovered from
/// an abandoned one is anything still in the stream's buffer — that lived in
/// the handler's own frame and went with it — which is why that case says so
/// out loud rather than quietly tidying up (ADR 019).
noinline fn endStream(c: *Ctx) bool {
    const open = c._stream.?;
    c._stream = null;
    // Finished while a middleware held its end (ADR 008): nothing was lost,
    // and the end goes out now with the trailers that middleware added.
    if (!open.finished) std.log.warn(
        "handler {s} {s} opened a stream and never finished it; " ++
            "call stream.finish() — anything still buffered was lost",
        .{ @tagName(c.method), c._path },
    );
    c._framing.end(open.chunked and !open.drop, c._trailers.out(false)) catch return false;
    c._body_ended = true;

    // A promised length that was never met cannot be tidied up the way a
    // missing zero-length chunk can: the head has gone out saying how many
    // bytes are coming, and this connection has to close rather than let the
    // next response be read as the rest of them (ADR 101).
    if (open.promised) |promised| {
        if (!open.drop and open.written < promised) return false;
    }
    return c.keepAlive();
}

/// A handler that failed after it had already answered, said out loud.
///
/// `noinline` for the reason the whole cold half of `handleRequest` is:
/// **a format string costs stack whether or not it is ever printed.** Zig
/// builds the argument tuple and the `Io.Writer` state in the frame of
/// whatever function the call is inlined into, and that frame belongs to the
/// connection for as long as the connection is open — so four log sites
/// nobody hits put kilobytes on every idle browser tab. Measured across the
/// cold paths, moving them out took `handleConnection` from 3,704 bytes to
/// 1,976; the connection loop is where that is worth counting, not here
/// (see [ADR 062](../docs/adr/062-where-a-connection-waits-is-what-it-costs.md)).
noinline fn warnFailedAfterAnswering(
    c: *Ctx,
    path: []const u8,
    deadlines: bulkhead.Deadlines,
    err: anyerror,
) void {
    // A write that ran out of time is the ordinary way a response to a client
    // that stopped reading ends, and "handler failed" sends whoever reads the
    // log looking for a bug in a handler that did nothing wrong (ADR 022).
    if (deadlines.timedOut()) {
        std.log.warn(
            "{s} {s}: gave up writing after {d}ms — the client stopped reading",
            .{ @tagName(c.method), path, deadlines.write_ms },
        );
    } else {
        std.log.warn("handler {s} {s} failed after answering: {s}", .{ @tagName(c.method), path, @errorName(err) });
    }
}

/// A socket loop that returned an error. `noinline` for `warnFailedAfterAnswering`'s
/// reason: this one sits on the connection loop's frame, which is the frame an
/// idle WebSocket is holding.
noinline fn warnSocketFailed(path: []const u8, err: anyerror) void {
    std.log.warn("the WebSocket loop on {s} failed: {s}", .{ path, @errorName(err) });
}

/// An answer made before there was a `Ctx`: written as the constant it is,
/// or, for a call an HTTP/2 connection is collecting, kept as its status.
fn sendFinal(sink: framing_mod.Sink, response: http1.Static, status: u16) void {
    switch (sink) {
        .wire => |out| {
            http1.writeStatic(out, response) catch return;
            out.flush() catch return;
        },
        .collect => |collected| if (comptime !framing_mod.grpc_built) unreachable else {
            collected.status = status;
        },
    }
}

/// Responses App assembles itself — an empty 200, a failure response —
/// outside of `Ctx.send`. As there, the body does not go out for a HEAD,
/// and headers middleware added still go out: an error response that
/// silently drops its CORS headers is one a browser refuses to show, which
/// is the worst possible moment to lose them.
fn sendDirect(c: *Ctx, status: u16, content_type: []const u8, body: []const u8) !void {
    c.markAnswered(status);
    // `Ctx.send`'s reason, and the other half of the same accounting: this
    // is nilo waiting on the client, not a handler running (ADR 013).
    const w = watchdog.waiting(c._watch);
    defer watchdog.waited(c._watch, w);
    try c.writeWhole(status, content_type, body);
}

/// Turn a handler failure into a response. A fail function's message is
/// used if there is one; otherwise the error goes through the mapping
/// table, and anything unrecognised becomes a 500 logged with its error
/// name (ADR 004). The body is nilo's own shape, or the one the
/// application named with `app.failures` (ADR 024).
noinline fn sendFailure(c: *Ctx, failure: *const fail.Failure, err: anyerror, shape: ?failurebody.Write) !void {
    const status = fail.resolveStatus(failure, err);
    const message: []const u8 = if (fail.failed(failure, err)) failure.message() else blk: {
        if (status == 500) {
            std.log.warn(
                "handler {s} {s} failed: {s}",
                .{ @tagName(c.method), c._path, @errorName(err) },
            );
            // Internal error names are not leaked to the client; anyone who
            // wants a readable message uses a fail function.
            break :blk "internal server error";
        }
        break :blk http1.statusPhrase(status);
    };

    // The headers the request collected go out, CORS above all, but not the
    // ones that described the answer this failure replaces (ADR 024).
    c.forgetAnswerHeaders();

    // Every 401 carries `WWW-Authenticate` (RFC 9110 §15.5.2), and the
    // endpoint that read the header is the one that knows what to say in
    // it (ADR 153). A comptime string, so `setStaticHeader` is right.
    if (fail.failed(failure, err)) if (failure.challenge) |with| {
        c.setStaticHeader("WWW-Authenticate", std.mem.span(with)) catch {};
    };

    var buf: [failure_body_max]u8 = undefined;
    var body: std.Io.Writer = .fixed(&buf);
    // A shape of the application's can outgrow the buffer — an envelope past
    // its 256 bytes — and then nilo's own shape goes out instead, with the
    // sentence intact: the first failure in development shows the wrong
    // shape, which is the whole of what a warning would have said. Not a
    // `std.log.warn` here on purpose — one measured 1,446 bytes of binary
    // (2,121 with two `{d}`s) for a line an App with no shape can never
    // reach, on every App.
    if (shape) |write| write(status, lossyMessage(c, message), &body) catch {
        body = .fixed(&buf);
        writeFailureBody(&body, status, message) catch unreachable; // sized for it, below
    };
    // The buffer is sized for the longest message a Failure can hold, so
    // this cannot run out of room; if it somehow did, what was written so
    // far would not be JSON, and the status alone is better than that.
    // Said to the framing as well as written, so an envelope with codes of
    // its own can choose one from the error (ADR 220).
    try c._framing.failed(err, message);
    if (shape == null) writeFailureBody(&body, status, message) catch {
        return sendDirect(c, status, "", "");
    };
    try sendDirect(c, status, failure_content_type, buf[0..body.end]);
}

// ---- tests ----

const testing = std.testing;

/// One request through `serveRequest` with no Engine, for what it leaves
/// behind rather than for what it writes: the behaviour tests read the
/// response, and this reads `Served`.
fn serveOnce(app: *App, request: []const u8) Served {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lifetime = str_mod.Lifetime.init();
    defer lifetime.deinit();
    var in_flight = fail.InFlight{};
    // A buffer of the connection's own over the bytes, the way a socket is
    // read: `Reader.fixed` alone has no buffer, so an empty request reads as
    // a head too long for it rather than as a peer that hung up.
    var underlying = std.Io.Reader.fixed(request);
    var read_buf: [4096]u8 = undefined;
    var limited = std.Io.Reader.Limited.init(&underlying, .unlimited, &read_buf);
    var buf: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    var served = serveRequest(app, arena.allocator(), &lifetime, &in_flight, &limited.interface, .{ .wire = &out }, .off, .off, .{});
    runHandover(&served);
    lifetime.end();
    return served;
}

fn echoBody(c: *Ctx) anyerror!void {
    try c.sendText(200, (try c.body()).view());
}

test "a connection is lingered on only where the client's bytes may still be unread" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoBody);
    try app.get("/ping", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, "pong");
        }
    }.run);
    try app.resolveChains();
    // The 413 below is logged as a failed handler, which is the behaviour
    // under test rather than news.
    const previous = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = previous;

    // A body the handler read whole: nothing left on the socket, the
    // connection is reused, and there is nothing to linger for.
    const read = serveOnce(&app, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 5\r\n\r\nhello");
    try testing.expect(read.keep_alive);
    try testing.expect(!read.linger);

    // `Connection: close` with no body: closes as it always did, without the
    // shutdown and the wait, because there is nothing queued to reset over.
    const closing = serveOnce(&app, "GET /ping HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    try testing.expect(!closing.keep_alive);
    try testing.expect(!closing.linger);

    // A body past the ceiling: the 413 goes out and the body is still on
    // the wire, which is exactly the answer a reset would take back.
    app.limits.max_body = 4;
    const too_big = serveOnce(&app, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 10\r\n\r\n0123456789");
    try testing.expect(!too_big.keep_alive);
    try testing.expect(too_big.linger);
    app.limits.max_body = 1024 * 1024;

    // A head that did not parse may have a body behind it.
    const malformed = serveOnce(&app, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 10\r\nContent-Length: 11\r\n\r\n0123456789");
    try testing.expect(!malformed.keep_alive);
    try testing.expect(malformed.linger);

    // A body under a coding nilo cannot read certainly has one.
    const coded = serveOnce(&app, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Encoding: br\r\nContent-Length: 2\r\n\r\nhi");
    try testing.expect(!coded.keep_alive);
    try testing.expect(coded.linger);

    // A peer that hung up before saying anything: nothing to wait for.
    const gone = serveOnce(&app, "");
    try testing.expect(!gone.keep_alive);
    try testing.expect(!gone.linger);
}

test "the linger after a refused request is bounded as a whole, not read by read" {
    // Per read, a peer sending a byte every 900 ms held the connection until
    // the 64 KiB cap, about eighteen hours (ADR 195).
    const Caught = struct {
        limit: bulkhead.Limit = .none,
        fn take(target: ?*anyopaque, _: bulkhead.Side, l: bulkhead.Limit) void {
            const self: *@This() = @ptrCast(@alignCast(target.?));
            self.limit = l;
        }
        fn never(_: ?*anyopaque) bool {
            return false;
        }
    };
    var caught: Caught = .{};
    const deadlines: bulkhead.Deadlines = .{ .target = &caught, .vtable = &.{ .limit = Caught.take, .timedOut = Caught.never } };

    var in = std.Io.Reader.fixed("left over");
    const before = bulkhead.monotonicNanos();
    hangUp(&in, deadlines, .off);
    const after = bulkhead.monotonicNanos();

    try testing.expect(caught.limit == .by_ns);
    const at = caught.limit.by_ns;
    try testing.expect(at >= before + @as(u64, linger_ms) * std.time.ns_per_ms);
    try testing.expect(at <= after + @as(u64, linger_ms) * std.time.ns_per_ms);
}

test "a head that does not fit is answered 431 and lingered on" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.resolveChains();

    // A reader whose buffer is smaller than the head, the way a connection's
    // read buffer is: the head cannot be completed, so it is refused, and the
    // rest of it is still on the peer's side of the socket.
    const head = "GET /ping HTTP/1.1\r\nHost: t\r\nCookie: " ++ ("x" ** 200) ++ "\r\n\r\n";
    var underlying = std.Io.Reader.fixed(head);
    var small: [64]u8 = undefined;
    var limited = std.Io.Reader.Limited.init(&underlying, .unlimited, &small);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lifetime = str_mod.Lifetime.init();
    defer lifetime.deinit();
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    const served = serveRequest(&app, arena.allocator(), &lifetime, &in_flight, &limited.interface, .{ .wire = &out }, .off, .off, .{});
    lifetime.end();

    try testing.expect(std.mem.startsWith(u8, out.buffered(), "HTTP/1.1 431"));
    try testing.expect(!served.keep_alive);
    try testing.expect(served.linger);
}

/// `serveOnce`, keeping what was written: the answer is the thing under test.
fn serveAnswer(app: *App, request: []const u8, wire: []u8) struct { served: Served, answer: []const u8 } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lifetime = str_mod.Lifetime.init();
    defer lifetime.deinit();
    var in_flight = fail.InFlight{};
    var underlying = std.Io.Reader.fixed(request);
    var read_buf: [4096]u8 = undefined;
    var limited = std.Io.Reader.Limited.init(&underlying, .unlimited, &read_buf);
    var out = std.Io.Writer.fixed(wire);
    var served = serveRequest(app, arena.allocator(), &lifetime, &in_flight, &limited.interface, .{ .wire = &out }, .off, .off, .{});
    runHandover(&served);
    lifetime.end();
    return .{ .served = served, .answer = out.buffered() };
}

fn sayHit(c: *Ctx) anyerror!void {
    try c.sendText(200, "hit");
}

fn failBadGateway(_: *Ctx) anyerror!void {
    return fail.status(502, "the upstream said no", .{});
}

test "a version nilo does not speak is a 505, and a coding it cannot decode is a 501" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", sayHit);
    try app.resolveChains();
    var wire: [4096]u8 = undefined;

    const old = serveAnswer(&app, "GET / HTTP/2.0\r\nHost: x\r\n\r\n", &wire);
    try testing.expect(std.mem.startsWith(u8, old.answer, "HTTP/1.1 505 HTTP Version Not Supported\r\n"));
    try testing.expect(!old.served.keep_alive);

    // Not a version at all stays a 400.
    const junk = serveAnswer(&app, "GET / HTTP/1.1 x\r\nHost: x\r\n\r\n", &wire);
    try testing.expect(std.mem.startsWith(u8, junk.answer, "HTTP/1.1 400 Bad Request\r\n"));

    const stacked = serveAnswer(&app, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n", &wire);
    try testing.expect(std.mem.startsWith(u8, stacked.answer, "HTTP/1.1 501 Not Implemented\r\n"));
    try testing.expect(!stacked.served.keep_alive);
}

test "an HTTP/1.0 request that carried Transfer-Encoding is answered and the connection closed" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoBody);
    try app.resolveChains();
    var wire: [4096]u8 = undefined;

    const served = serveAnswer(
        &app,
        "POST /echo HTTP/1.0\r\nConnection: keep-alive\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
        &wire,
    );
    try testing.expect(std.mem.startsWith(u8, served.answer, "HTTP/1.0 200") or std.mem.startsWith(u8, served.answer, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, served.answer, "Connection: close\r\n") != null);
    try testing.expect(!served.served.keep_alive);
}

test "OPTIONS * is a server-wide OPTIONS and never reaches a root catch-all" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/*", sayHit);
    try app.post("/items", sayHit);
    try app.resolveChains();
    var wire: [4096]u8 = undefined;

    // Registered for OPTIONS too: matched as the path `*`, this is the handler
    // that answered.
    var catching = App.init(testing.allocator);
    defer catching.deinit();
    try catching.options("/*", sayHit);
    try catching.resolveChains();
    const caught = serveAnswer(&catching, "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n", &wire);
    try testing.expect(std.mem.indexOf(u8, caught.answer, "hit") == null);

    const star = serveAnswer(&app, "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n", &wire);
    try testing.expect(std.mem.startsWith(u8, star.answer, "HTTP/1.1 204 No Content\r\n"));
    try testing.expect(std.mem.indexOf(u8, star.answer, "hit") == null);
    try testing.expect(std.mem.indexOf(u8, star.answer, "Allow: GET, HEAD, POST, OPTIONS\r\n") != null);
    try testing.expect(star.served.keep_alive);

    // Nothing that is not origin-form reaches the router: a scheme-shaped
    // target is a 400, and a CONNECT is a 404 though `/*` matches everything.
    const scheme = serveAnswer(&app, "GET admin:1/x HTTP/1.1\r\nHost: x\r\n\r\n", &wire);
    try testing.expect(std.mem.startsWith(u8, scheme.answer, "HTTP/1.1 400"));
    const connect = serveAnswer(&app, "CONNECT example.com:443 HTTP/1.1\r\nHost: x\r\n\r\n", &wire);
    try testing.expect(std.mem.indexOf(u8, connect.answer, "hit") == null);
    try testing.expect(std.mem.startsWith(u8, connect.answer, "HTTP/1.1 404"));
}

test "the Allow on an OPTIONS answer names OPTIONS" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users", sayHit);
    try app.post("/users", sayHit);
    try app.resolveChains();
    var wire: [4096]u8 = undefined;

    const answered = serveAnswer(&app, "OPTIONS /users HTTP/1.1\r\nHost: x\r\n\r\n", &wire);
    try testing.expect(std.mem.startsWith(u8, answered.answer, "HTTP/1.1 204 No Content\r\n"));
    try testing.expect(std.mem.indexOf(u8, answered.answer, "Allow: GET, HEAD, POST, OPTIONS\r\n") != null);

    // A 405 for another method keeps listing what the routes answer.
    const refused = serveAnswer(&app, "DELETE /users HTTP/1.1\r\nHost: x\r\n\r\n", &wire);
    try testing.expect(std.mem.indexOf(u8, refused.answer, "Allow: GET, HEAD, POST\r\n") != null);
}

test "a status a fail function sends outside the old table still has its phrase" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/gateway", failBadGateway);
    try app.resolveChains();
    var wire: [4096]u8 = undefined;
    const previous = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = previous;

    const bad = serveAnswer(&app, "GET /gateway HTTP/1.1\r\nHost: x\r\n\r\n", &wire);
    try testing.expect(std.mem.startsWith(u8, bad.answer, "HTTP/1.1 502 Bad Gateway\r\n"));
}
