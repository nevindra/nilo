//! Answering one request: read the head, match it, run the chain, write back.
//!
//! Split from `app.zig` because the two halves of that file are paid for at
//! different times. Everything here runs per request and is what the
//! allocation budget and the per-connection stack figures are about
//! (ADR 0018, ADR 0063); `wiring.zig` next door runs once, inside `listen()`.
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
const watchdog = @import("watchdog.zig");
const scratch = @import("scratch.zig");
const websocket = @import("websocket.zig");
const metrics_mod = @import("metrics.zig");

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
    // for one of the next connection's (ADR 0004).
    var lifetime = str_mod.Lifetime.init();
    defer lifetime.deinit();

    // Once for the connection. Nothing in a response changes how long a
    // single write may take, so nothing re-arms it — including a stream
    // that writes for an hour, where each write is still one write.
    deadlines.armWrite();

    // What this fiber is serving is bound to it once, then reused by
    // every request on the same connection (ADR 0007).
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
        waitForRequest(in, out, deadlines, waker);

        var served = serveRequest(self, arena.allocator(), &lifetime, &in_flight, in, out, deadlines, waker, peer);
        // A handler that upgraded runs its loop here rather than inside
        // `serveRequest`, so that the request's 1,608 bytes are unwound
        // before a socket suspends for the next hour (ADR 0071).
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
        // pages are handed back and faulted in again next time (ADR 0096).
        lifetime.end();
        _ = arena.reset(.{ .retain_with_limit = self.arena_keep });
        if (!served.keep_alive) return;
    }
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
/// ([ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md)).
///
/// Every error is swallowed: a broken connection is `handleRequest`'s to
/// diagnose and report, and it will meet the same failure one call later
/// with all the machinery for saying so. A wait that runs out of the idle
/// limit leaves the deadline expired, so `readHead` fails at once and the
/// connection closes without a second full idle period.
pub fn waitForRequest(
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    deadlines: bulkhead.Deadlines,
    waker: bulkhead.Waker,
) void {
    // Already holding a pipelined request: not idle, and the buffer is
    // live data that must not be discarded.
    if (in.seek != in.end) {
        deadlines.armIdle();
        return;
    }

    deadlines.armPeek(idle_peek_ms);
    in.fillMore() catch {
        if (deadlines.timedOut()) {
            bulkhead.releaseIdlePages(in, out);
            waker.releaseStack();
        }
    };

    // Waiting for the next request to start is the idle limit, not the
    // header one. Armed every time round: a connection that has just
    // served a request is idle again from now, not from whenever it was
    // accepted.
    deadlines.armIdle();
    if (in.seek == in.end) in.fillMore() catch {};
}

/// What one request left behind.
///
/// `handover` is set when the handler turned the connection into a
/// WebSocket: the socket is open, the handshake is answered, and the loop
/// that is going to read it has not started. Running it is the caller's,
/// so that it runs from the caller's frame (ADR 0071).
pub const Served = struct {
    keep_alive: bool,
    handover: ?websocket.Handover = null,
};

/// Answer one request, and hand back a socket if the handler opened one.
///
/// `noinline` deliberately. Everything this touches — the `Ctx`, the
/// parsed head, the route match — is 1,608 bytes that the connection loop
/// must not be holding while it waits for the next request, and a frame
/// the compiler inlines is a frame that lives as long as its host's
/// (ADR 0063).
pub noinline fn serveRequest(
    self: *App,
    arena: std.mem.Allocator,
    lifetime: *str_mod.Lifetime,
    in_flight: *fail.InFlight,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    deadlines: bulkhead.Deadlines,
    waker: bulkhead.Waker,
    peer: bulkhead.Peer,
) Served {
    var handover: ?websocket.Handover = null;
    // Started here rather than after the head is read, so that a request
    // whose head never arrived is timed from the same instant as one that
    // was answered. On a server that never called `metrics()` this is a
    // null pointer and no clock read at all (ADR 0100).
    var record = metrics_mod.Record.begin(if (self.metrics_table) |*t| t else null);
    const failure = &in_flight.failure;
    in_flight.startRequest("", "");
    // On a real server the fiber slot is already installed and wins;
    // this is what keeps fail functions working when App is called
    // straight from a test, with no Engine underneath.
    const prev_slot = bulkhead.setFallbackSlot(in_flight);
    defer _ = bulkhead.setFallbackSlot(prev_slot);

    const raw_head = http1.readHead(in, deadlines) catch |err| {
        switch (err) {
            error.EndOfStream => {},
            // A timeout arrives as a read failure like any other, so
            // which one it was has to be asked (ADR 0023). The bytes
            // that did turn up are still buffered, and they are what
            // separates the two cases worth telling apart: a client
            // halfway through a head gets a 408, a connection that sat
            // idle without asking for anything is just closed.
            error.ReadFailed => if (deadlines.timedOut() and in.buffered().len > 0) {
                sendFinal(out, RESPONSE_408);
                record.finish(408);
            },
            error.HeadTooLong => {
                sendFinal(out, RESPONSE_431);
                record.finish(431);
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
        // understands and this server cannot read (ADR 0111).
        const answer, const status: u16 = switch (err) {
            error.UnsupportedContentEncoding => .{ RESPONSE_415, 415 },
            else => .{ RESPONSE_400, 400 },
        };
        sendFinal(out, answer);
        record.finish(status);
        return .{ .keep_alive = false };
    };

    // Past the limit on requests in flight, and said so now rather than
    // after a queue (ADR 0197). `already` is what the atomic above handed
    // back for free, so this is one comparison and no second load. Before
    // the head is copied, before the router is asked: a shed request costs
    // one write of a constant.
    if (self.limits.max_in_flight != 0 and already >= self.limits.max_in_flight) {
        sendFinal(out, RESPONSE_503_SHED);
        record.at(metrics_mod.shed);
        record.finish(503);
        return .{ .keep_alive = false };
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
        // Empty unless the target arrived in absolute form (ADR 0120), and
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
    // (ADR 0008). Both slices live in the request arena.
    in_flight.startRequest(r.method, path);

    var c = Ctx{
        .method = http1.methodFrom(r.method),
        ._arena = arena,
        ._lifetime = lifetime,
        ._in = in,
        ._out = out,
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
        // the caller runs the loop from *its* frame (ADR 0071).
        ._handover = &handover,
    };

    // Every way out of here from this point on — a clean answer, a
    // failure, a stream abandoned, a socket handed over — goes past this,
    // which is the reason the counting is not a middleware. The status a
    // request really had is only settled here, and a second place working
    // it out again is a second place to get it wrong (ADR 0100).
    defer record.finish(c.answered() orelse 0);

    // A request that matched no route still runs the middleware: a
    // logger that cannot see 404s and a CORS that cannot answer a
    // preflight for an unknown path are both useless exactly when you
    // need them. What changes is only the innermost call (ADR 0009).
    var chain: []const mw.Middleware = &.{};
    var terminal: mw.CtxHandler = notFoundHandler;

    // Held in a variable of this scope on purpose: `c` borrows the
    // params out of it, and they have to outlive the branch below.
    var matched = self.router.match(c.method, path);

    if (matched) |*match| {
        // Decoded here rather than before matching: `%2F` is a slash of
        // data, and a router that saw it as a separator would let a
        // request reach a route it does not name.
        const params = match.params[0..match.n_params];
        ctx_mod.decodeParams(arena, params) catch return .{ .keep_alive = false };
        c._params = params;
        chain = match.chain;
        terminal = match.handler;
        record.at(metrics_mod.fixed_slots + match.index);
    } else if (findStatic(self, &c, path)) |found| {
        // Resolved at `listen()` with the routes' chains, so an asset
        // served with a logger or a CORS in front of it allocates
        // nothing — which is the shape nearly every app deploys, and
        // the one the budget test used to step around rather than
        // measure (ADR 0018).
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
            chain = mw.chainFor(arena, self.scoped.items, self.exemptions.items, self.attached.items, null, path) catch &.{};
        }
        // No route for this method, but the path itself is spelled out
        // by routes under other methods. "There is nothing here" and
        // "there is something here, but not for that verb" are
        // different answers, and a 404 for the second one sends you
        // looking for a registration bug that is not there.
        const allowed = self.router.allowedFor(path);
        if (allowed.count() > 0) {
            c._allowed = allowed;
            terminal = methodNotAllowedHandler;
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
    // (ADR 0034). Bracketed around the whole chain rather than around
    // the terminal handler, because a middleware that blocks stops the
    // thread just as dead as a handler that does.
    watchdog.begin(&in_flight.watch, self.limits.block_warning_ms, @tagName(c.method), path);

    (mw.Next{ .rest = chain, .handler = terminal }).run(&c) catch |err| {
        watchdog.finish(&in_flight.watch);
        // A half-sent response cannot be taken back, so the connection
        // is closed: the next request on it would read leftover bytes
        // of unclear provenance.
        if (c.answered() != null) {
            warnFailedAfterAnswering(&c, path, deadlines, err);
            return .{ .keep_alive = false, .handover = handover };
        }
        // Nothing sent yet: this is a clean failure. A body nobody read
        // still has to be discarded so the connection can be reused —
        // a 404 from a fail function is a normal way to live, not a
        // reason to drop keep-alive. If it cannot be discarded the
        // answer still goes out; only the connection is given up.
        const reusable = drain(&c, in, &r);
        sendFailure(&c, failure, err) catch return .{ .keep_alive = false, .handover = handover };
        return .{ .keep_alive = reusable, .handover = handover };
    };
    watchdog.finish(&in_flight.watch);

    // A body the handler did not read is discarded so the next request
    // on this connection starts at the right byte.
    const reusable = drain(&c, in, &r);

    if (c.answered() == null) {
        // A handler that returned without answering meant an empty 200.
        // No content type, because there is no content to give one to.
        sendDirect(&c, 200, "", "") catch return .{ .keep_alive = false, .handover = handover };
    }
    if (c._stream != null) return .{ .keep_alive = endAbandonedStream(&c), .handover = handover };
    return .{ .keep_alive = reusable, .handover = handover };
}

/// Run the socket a handler handed back, from the caller's frame.
///
/// The `Handover` has stopped moving by the time this is called, which is
/// what lets the Socket's buffer slot point at the one beside it: the loop
/// may walk out without a word, and a buffer nobody hands back is a leak
/// per connection.
pub fn runHandover(served: *Served) void {
    const h = if (served.handover) |*it| it else return;
    h.socket._scratch = &h.scratch;
    defer if (h.scratch) |buf| scratch.give(buf);
    h.run(&h.socket, &h.state) catch |err| warnSocketFailed(h.path, err);
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
/// (ADR 0109).
pub fn findStatic(self: *const App, c: *const Ctx, path: []const u8) ?StaticHit {
    if (findStaticFile(self, c.method, path)) |found| return found;
    if (c.method != .GET and c.method != .HEAD) return null;

    // Only once every set has been asked for the file itself. A page one
    // directory answers its misses with must not hide a file another
    // directory really holds, and asking set by set would let it.
    const accept_header: ?[]const u8 = if (c.header("Accept")) |h| h.view() else null;
    for (self.static_sets.items, 0..) |*set, i| {
        if (set.fallbackFor(path, accept_header)) |file| return hitIn(self, i, set, file);
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
/// They carry the same JSON shape every other failure does (ADR 0025), so a
/// client has one thing to parse and not two.
const RESPONSE_400 = http1.staticResponse(400, "Bad Request", failure_content_type, staticFailure(400, "malformed request"), false);
const RESPONSE_431 = http1.staticResponse(431, "Request Header Fields Too Large", failure_content_type, staticFailure(431, "head too long"), false);
/// Sent when a body arrives under a `Content-Encoding` nilo cannot decode,
/// which is all of them but `identity` (ADR 0111). The message names the
/// header, because the mistake is one line of client configuration and the
/// alternative — a 400 about malformed JSON — sends the reader to the body.
const RESPONSE_415 = http1.staticResponse(415, "Unsupported Media Type", failure_content_type, staticFailure(415, "this server does not decode a Content-Encoding: send the body as identity"), false);
/// Sent when a request head started arriving and then stopped (ADR 0023).
/// Not when a keep-alive connection simply sat idle: that client has not
/// asked for anything, and a status answering nothing is noise a proxy has
/// to decide what to do with.
const RESPONSE_408 = http1.staticResponse(408, "Request Timeout", failure_content_type, staticFailure(408, "request head timed out"), false);

const failure_content_type = "application/json";

/// Sent when the server is already answering `max_in_flight` requests
/// (ADR 0197). Assembled here rather than through `staticResponse` for the
/// one header that function does not write: `Retry-After`, which is what
/// tells a client and a balancer this is load rather than a fault.
const RESPONSE_503_SHED = blk: {
    const body = staticFailure(503, "this server is answering as many requests as it was told to; try again in a moment");
    break :blk std.fmt.comptimePrint(
        "HTTP/1.1 503 Service Unavailable\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nRetry-After: 1\r\n\r\n{s}",
        .{ failure_content_type, body.len, body },
    );
};

/// Room for the longest failure body there can be: a message at the Failure's
/// ceiling where every byte needs the six-character `\u00xx` escape, plus the
/// wrapper around it.
const failure_body_max = fail.max_message * 6 + 32;

/// A failure body for a message known while compiling — no escaping, because
/// these three are written here and have nothing in them to escape.
fn staticFailure(comptime status: u16, comptime message: []const u8) []const u8 {
    return std.fmt.comptimePrint("{{\"error\":\"{s}\",\"status\":{d}}}", .{ message, status });
}

/// The body of a failure response: the sentence a fail function wrote, in the
/// one shape every client can read (ADR 0025).
///
/// A frontend calling `res.json()` on a 4xx used to throw, which is the
/// worst moment to lose the message that says what went wrong. The message
/// itself is unchanged, so `curl` still shows the sentence — one pair of
/// braces further in.
fn writeFailureBody(w: *std.Io.Writer, status: u16, message: []const u8) !void {
    try w.writeAll("{\"error\":\"");
    for (message) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch),
    };
    try w.print("\",\"status\":{d}}}", .{status});
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
    // (ADR 0094). The final status has gone out, which is the whole of what
    // RFC 9110 §10.1.1 asks for; what this connection cannot do is carry
    // another request, because the one it has is unfinished.
    if (r.expect_continue and !c._continued) return false;
    // Reading here as well as in the handler, so the clock goes on here as
    // well (ADR 0023). Without it these reads would inherit whatever limit
    // was last set — the header deadline, which by now has passed — and a
    // client with a body left to send would have its connection dropped for
    // no reason. Only where something is really read, though: arming it on a
    // GET would leave a limit meant for a body sitting on a connection that
    // is about to go idle instead.
    //
    // The handler read the body in pieces and may have stopped part way —
    // a `while (try incoming.read(…))` that breaks early is an ordinary
    // thing to write. What is left of it goes here, so the next request on
    // this connection starts where it should (ADR 0020).
    if (c._incoming) |*progress| {
        if (progress.finished()) return true;
        c._deadlines.armBody();
        var rest = body_mod.Body.init(in, progress);
        rest.discardRest() catch return false;
        return true;
    }
    if (http1.readsMore(r)) {
        c._deadlines.armBody();
        http1.discardBody(in, r, c._limits.max_body) catch return false;
    }
    return true;
}

/// The innermost call when no route matched. It is a normal handler so
/// that middleware wraps a 404 exactly as it wraps anything else.
///
/// It fails rather than answering, so this 404 goes out through the one
/// place that assembles a failure and gets the same body shape as every
/// other (ADR 0025).
fn notFoundHandler(c: *Ctx) anyerror!void {
    return fail.notFound("there is no {s}", .{c._path});
}

/// The innermost call when the path is registered but not for this method.
///
/// A normal handler too, so a 405 carries whatever headers the middleware
/// added — CORS included, since a browser has to be able to read the answer
/// to see what went wrong.
fn methodNotAllowedHandler(c: *Ctx) anyerror!void {
    // Built in the request arena, which outlives the response it is written
    // into, so there is nothing for `setHeader` to copy.
    const allow = try allowList(c._arena, c._allowed);
    try c.setStaticHeader("Allow", allow);

    // An OPTIONS asking what a path supports is answered rather than
    // refused: that is the question the method exists for, and the `Allow`
    // header above is the answer. A preflight never gets this far — CORS
    // middleware handles those before any handler runs.
    if (c.method == .OPTIONS) return c.sendEmpty(204);

    // Failing rather than answering, for the reason `notFoundHandler` does:
    // one place assembles a failure body. The `Allow` header set above
    // survives it — `sendDirect` writes whatever headers the request
    // collected, which is also what keeps CORS on an error response.
    return fail.status(405, "{s} is not allowed here. This path answers: {s}", .{
        @tagName(c.method),
        allow,
    });
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
/// knows the other exists (ADR 0037).
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
/// ([ADR 0125](../docs/adr/0125-a-file-is-described-by-the-descriptor-being-sent.md)).
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
    // request carried is being turned into a path (ADR 0037).
    const open = on_disk.dir.openFile(on_disk.path) catch |err| switch (err) {
        // The list said the file was there and the disk disagrees, which
        // from the client's side is indistinguishable from asking for
        // something that never existed. Every other way of failing to open
        // one is this server's problem and says so with a 500.
        error.FileNotFound => return fail.notFound("there is no {s}", .{c._path}),
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
    // the budget of one allocation per request is unchanged (ADR 0018).
    var etag_buf: [static_mod.max_spilled_etag]u8 = undefined;
    const etag = static_mod.spilledEtag(&etag_buf, @as(i96, now.mtime_ns), now.size);

    // No `Vary`, because there is nothing to vary on: a spilled file has one
    // representation and no gzipped copy to negotiate against (ADR 0018 —
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
/// and it is the part ADR 0021 exists to protect: `range_mod.parse` is the
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
fn serveHeldFile(c: *Ctx, file: *const static_mod.File) anyerror!void {
    // A `Range` is an offset into a representation, and the gzipped copy is
    // a different representation with different offsets. Rather than work
    // out which one a client meant, a request that asks for part of a file
    // gets the plain one — which is the representation `Accept-Ranges:
    // bytes` has been promising all along.
    const wants_part = c.header("Range") != null;
    const wants_gzip = !wants_part and
        static_mod.acceptsGzip(headerValue(c, "Accept-Encoding"));
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
    // carrying half the rule as a guard of its own (ADR 0094).
    const still_the_same = if (c.header("If-Range")) |sent|
        static_mod.etagMatchesStrong(sent.view(), sending.etag)
    else
        true;

    var buf: [range_mod.max_content_range]u8 = undefined;
    switch (range_mod.parse(headerValue(c, "Range"), total, still_the_same)) {
        .whole => {},
        .part => |part| {
            try c.setHeader("Content-Range", range_mod.contentRange(&buf, part, total));
            return c.send(206, file.content_type, part.slice(sending.bytes));
        },
        .unsatisfiable => {
            // The one answer whose whole content is "you have the wrong idea
            // about how big this is", which the header carries and the body
            // does not need to repeat.
            try c.setHeader("Content-Range", range_mod.unsatisfiableRange(&buf, total));
            return c.send(416, file.content_type, "");
        },
    }

    try c.send(200, file.content_type, sending.bytes);
}

/// A request header as plain bytes. The `Str` a handler gets is the right
/// shape for a handler and the wrong one for a parser that takes `?[]const
/// u8`, and this is the only place that difference comes up.
fn headerValue(c: *const Ctx, name: []const u8) ?[]const u8 {
    const found = c.header(name) orelse return null;
    return found.view();
}

/// A handler opened a stream and returned without calling `finish()`.
///
/// The zero-length chunk is written here so the client is told where the
/// body stopped instead of waiting for more, and so the connection is left
/// in a state the next request can start from. What cannot be recovered is
/// anything still in the stream's buffer — that lived in the handler's own
/// frame and went with it — which is why this says so out loud rather than
/// quietly tidying up (ADR 0020).
noinline fn endAbandonedStream(c: *Ctx) bool {
    const open = c._stream.?;
    c._stream = null;
    std.log.warn(
        "handler {s} {s} opened a stream and never finished it; " ++
            "call stream.finish() — anything still buffered was lost",
        .{ @tagName(c.method), c._path },
    );
    if (open.chunked and !open.drop) http1.writeLastChunk(c._out) catch return false;
    c._out.flush() catch return false;

    // A promised length that was never met cannot be tidied up the way a
    // missing zero-length chunk can: the head has gone out saying how many
    // bytes are coming, and this connection has to close rather than let the
    // next response be read as the rest of them (ADR 0128).
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
/// (see [ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md)).
noinline fn warnFailedAfterAnswering(
    c: *Ctx,
    path: []const u8,
    deadlines: bulkhead.Deadlines,
    err: anyerror,
) void {
    // A write that ran out of time is the ordinary way a response to a client
    // that stopped reading ends, and "handler failed" sends whoever reads the
    // log looking for a bug in a handler that did nothing wrong (ADR 0023).
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

fn sendFinal(out: *std.Io.Writer, response: []const u8) void {
    out.writeAll(response) catch return;
    out.flush() catch return;
}

/// Responses App assembles itself — an empty 200, a failure response —
/// outside of `Ctx.send`. As there, the body does not go out for a HEAD,
/// and headers middleware added still go out: an error response that
/// silently drops its CORS headers is one a browser refuses to show, which
/// is the worst possible moment to lose them.
fn sendDirect(c: *Ctx, status: u16, content_type: []const u8, body: []const u8) !void {
    c.markAnswered(status);
    // `Ctx.send`'s reason, and the other half of the same accounting: this
    // is nilo waiting on the client, not a handler running (ADR 0034).
    const w = watchdog.waiting(c._watch);
    defer watchdog.waited(c._watch, w);
    const keep_alive = c.keepAlive();
    if (c.method == .HEAD) return http1.writeResponseHeadOnly(
        c._out,
        status,
        http1.statusPhrase(status),
        content_type,
        body.len,
        keep_alive,
        c.extraHeaders(),
    );
    try http1.writeResponse(
        c._out,
        status,
        http1.statusPhrase(status),
        content_type,
        body,
        keep_alive,
        c.extraHeaders(),
    );
}

/// Turn a handler failure into a response. A fail function's message is
/// used if there is one; otherwise the error goes through the mapping
/// table, and anything unrecognised becomes a 500 logged with its error
/// name (ADR 0005).
noinline fn sendFailure(c: *Ctx, failure: *const fail.Failure, err: anyerror) !void {
    const status = fail.resolveStatus(failure, err);
    const message: []const u8 = if (failure.isSet()) failure.message() else blk: {
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

    // Every 401 carries `WWW-Authenticate` (RFC 9110 §15.5.2), and the
    // endpoint that read the header is the one that knows what to say in
    // it (ADR 0191). A comptime string, so `setStaticHeader` is right.
    if (failure.challenge) |with| {
        c.setStaticHeader("WWW-Authenticate", std.mem.span(with)) catch {};
    }

    var buf: [failure_body_max]u8 = undefined;
    var body: std.Io.Writer = .fixed(&buf);
    // The buffer is sized for the longest message a Failure can hold, so
    // this cannot run out of room; if it somehow did, what was written so
    // far would not be JSON, and the status alone is better than that.
    writeFailureBody(&body, status, message) catch {
        return sendDirect(c, status, "", "");
    };
    try sendDirect(c, status, failure_content_type, buf[0..body.end]);
}
