//! Ctx — one request in flight, and all the control over it. This is
//! nilo's real API (ADR 002): the typed layer above it turns into calls
//! to this while compiling.
//!
//! Every piece of text coming out of Ctx is a `Str`: it lives as long as
//! the request, and is copied deliberately with `.keep()` if it needs to
//! live longer (ADR 003). Fields prefixed with `_` belong to nilo's
//! internals — the request arena behind them is never touched directly by
//! users.

const std = @import("std");
const body_mod = @import("body.zig");
const bulkhead = @import("bulkhead.zig");
const compress_mod = @import("compress.zig");
const convert = @import("convert.zig");
const cookie_mod = @import("cookie.zig");
const encoded = @import("encoded.zig");
const framing_mod = @import("framing.zig");
const http1 = @import("http1.zig");
const json_mod = @import("json.zig");
const jsonmark = @import("jsonmark.zig");
const password_mod = @import("password.zig");
const router = @import("router.zig");
const scan = @import("scan.zig");
const sendfile_mod = @import("sendfile.zig");
const service_mod = @import("service.zig");
const static_mod = @import("static.zig");
const stream_mod = @import("stream.zig");
const url_mod = @import("url.zig");
const proxies_mod = @import("proxies.zig");
const str_mod = @import("nilo_core");
const patch_mod = @import("patch.zig");
const websocket = @import("websocket.zig");
const handover_mod = @import("handover.zig");
const room_mod = @import("room.zig");
const rooms_mod = @import("rooms.zig");
const naming = @import("names.zig");
const percent = @import("nilo_core").percent;
const fail = @import("fail.zig");
const watchdog = @import("watchdog.zig");
const authorization_mod = @import("authorization.zig");
const verified_mod = @import("verified.zig");
const versioned_mod = @import("versioned.zig");
const trace_mod = @import("trace.zig");

/// What `Ctx._session_fallbacks` points at when there are no fallbacks, which is
/// every App that never rotated and every Ctx a test builds by hand.
const no_fallbacks: []const [32]u8 = &.{};

const Str = str_mod.Str;

/// What one request is allowed to do. Filled from `listen()`'s options and
/// carried on the Ctx, so a limit is one field away rather than a reach
/// back into the App. The defaults are what a test driving a handler
/// directly gets, and they are `bulkhead.Options`' defaults.
pub const Limits = struct {
    max_body: usize = 1024 * 1024,
    /// The most requests answered at once; 0 is no limit (ADR 159).
    max_in_flight: u32 = 0,
    trusted_hops: u8 = 0,
    /// The networks `.trusted_proxies` named, parsed once at `listen()` and
    /// owned by the App (ADR 102). Empty means the hop count decides, which
    /// is what every App that never set it gets.
    trusted_proxies: []const proxies_mod.Cidr = &.{},
    block_warning_ms: u32 = 250,
    /// The deadline every request starts with, in milliseconds; 0 is none.
    /// What `nilo.deadline` gives one route, given to all of them at
    /// `listen()` (ADR 105).
    request_deadline_ms: u32 = 0,
};

/// The size `sendJson` reserves before serialising. Not a limit — a
/// bigger response simply grows past it.
pub const json_hint = 512;

/// How many response headers a request holds without reaching for the arena.
///
/// Seven covers the shape most applications deploy: a CORS naming an origin
/// (`Access-Control-Allow-Origin` and `Vary: Origin`) in front of a gzipped
/// static file (`ETag`, `Cache-Control`, `Accept-Ranges`, `Vary:
/// Accept-Encoding`, `Content-Encoding`). It was four until gzip added two,
/// six until `Vary` stopped replacing itself (ADR 029), and each of those
/// moves was made because a test measured the spill rather than because the
/// arithmetic looked tight — `test "a gzipped file behind a named-origin CORS
/// still allocates nothing"` is the one that holds this number.
///
/// **A CORS with `credentials` or `expose` set still spills**, as it did
/// before: those add two more and the count is nine. That is one arena
/// allocation on a response that has already decided to carry nine headers,
/// and raising the number to cover it would cost every request the stack
/// instead.
///
/// Each slot is two slices on a Ctx that lives on the fiber's stack — and on a
/// frame that is unwound before the connection waits for its next request
/// (ADR 062), so this is not memory an idle connection holds. Which is why
/// the trade runs this way at all: 32 bytes of a transient frame against an
/// allocation on the path nearly every app serves (ADR 017).
pub const inline_headers = 7;

/// One resolved value, kept for the rest of the request that asked for it.
///
/// Keyed by type name rather than by anything cleverer for the same reason
/// the service registry is (ADR 005): the list is two entries long in
/// practice, and `@typeName` is normally the very same literal, so finding
/// one is a pointer compare.
const Resolved = struct {
    type_name: []const u8,
    value: *anyopaque,
};

/// An answer a middleware is holding (`Next.hold`), kept until the chain has
/// unwound and written then (ADR 008). In the request arena, so only a
/// request that holds pays for it.
pub const Held = union(enum) {
    whole: struct {
        status: u16,
        content_type: []const u8,
        body: []const u8,
        /// Whether `app.compress` may still gzip it, which it may for an
        /// answer `send` made and not for one App made itself.
        compress: bool,
        /// The bytes are the framework's and outlive the stream (see
        /// `sendOwned` in this file): the arena's, or the App's. What the handler
        /// returned is not, and HTTP/2 copies it.
        owned: bool = false,
    },
    file: sendfile_mod.Held,
};

pub const Ctx = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Ctx";

    method: http1.Method,

    _arena: std.mem.Allocator,
    _lifetime: *const str_mod.Lifetime,
    _in: *std.Io.Reader,
    /// Where the answer goes: the bytes of HTTP/1.1, or an answer kept for
    /// an HTTP/2 connection to frame. Nothing in `Ctx` writes a protocol's
    /// bytes itself (ADR 253).
    _framing: framing_mod.Framing,
    _request: *const http1.Request,
    _path: []const u8,
    /// The query string as it arrived, still encoded. `_query_params` is
    /// the decoded form and is what `query()` reads.
    _query: []const u8,
    _query_params: []const router.Param = &.{},
    /// The whole request head, request line included. Headers are read out
    /// of it on demand rather than collected up front — most handlers ask
    /// for none, and the ones that ask, ask for two. An HTTP/2 call's head
    /// has an empty request line, its method and path having arrived as
    /// fields of their own (`framing.Call`, ADR 253), and is read the same.
    _head: []const u8,
    /// Whether `_head` is still the connection's own read buffer rather than a
    /// copy in the request arena. True for a request nothing will read from
    /// the connection for again, which is most of them — see the copy in
    /// `serve.serveRequest`, and `aboutToRead` for what keeps it honest.
    /// Never for an HTTP/2 call, whose head is in the call's arena.
    _head_borrowed: bool = false,
    /// This connection's time limits (ADR 022). Every path that reads from
    /// the connection arms the one that applies to it first; `.off` — which
    /// is the default, and what a test driving App directly gets — makes
    /// every one of those calls do nothing.
    _deadlines: bulkhead.Deadlines = .off,
    /// The connection's second way to be woken — by another fiber rather than
    /// by the client. Only a WebSocket that has been registered for broadcast
    /// ever uses it; `.off` is the default, and what a test driving App
    /// directly gets, and it answers "go and read" to everything.
    _waker: bulkhead.Waker = .off,
    /// Where `upgrade` leaves the socket and the loop that is going to run it,
    /// and where `eventsFrom` leaves its stream.
    ///
    /// Points at a slot in the *connection* loop's frame, which is the whole
    /// point: the loop runs from there, after this request's machinery has
    /// unwound (ADR 062). Null for a `Ctx` built by hand in a test.
    _handover: ?*handover_mod.Handover = null,
    /// Who the connection came from, as the socket reports it. Empty when
    /// there is no socket — a test driving App directly, a Unix socket.
    _peer: bulkhead.Peer = .{},
    /// This request's id, once somebody has asked for one. Null until then,
    /// so a request nobody ties to anything pays nothing for the option.
    _request_id: ?Str = null,
    /// Where a generated id is written. Sixteen hex characters, on the Ctx
    /// and therefore on the fiber's stack — not on the connection, whose
    /// 4,669 idle bytes are an invariant rather than a budget (ADR 017).
    _request_id_buf: [16]u8 = undefined,
    /// The App's tracer, when `app.trace` was called. Null on a request of an
    /// App that does not trace (ADR 247).
    _tracer: ?*trace_mod.Tracer = null,
    /// Where this request is in its trace. Set when `_tracer` is, and read
    /// only then.
    _trace: trace_mod.Active = undefined,
    /// Set by `putPolicy`, so that `putHeader` reaches the code that edits a
    /// policy block only on a request that has one, and a program with no
    /// `nilo.secure` does not link it (ADR 246).
    _policy_edit: ?*const fn (std.mem.Allocator, []const u8, []const u8) error{OutOfMemory}![]const u8 = null,
    /// What this request may do, from `listen()`. Defaults when App was
    /// never listened on, which is what a test gets.
    _limits: Limits = .{},
    /// The key session cookies are sealed with, from
    /// `listen(.{ .session_secret = … })`. Points at the App's copy, which
    /// outlives every request it serves.
    ///
    /// Null when the application never set one. That is what makes a
    /// `Session(T)` fail with a sentence naming the option instead of
    /// quietly sealing everything under zeroes — a default key would be a
    /// key every reader of this repository already has.
    ///
    /// Spelled `[32]u8` rather than `session.Key` because session.zig needs
    /// `Ctx` and a field type cannot be imported from inside a function body
    /// the way `resolve` below does it. `session.zig` asserts the two agree,
    /// so the duplication cannot drift silently.
    _session_key: ?*const [32]u8 = null,
    /// Secrets a session cookie is opened under when `_session_key` does not
    /// open it, and never sealed under, from
    /// `listen(.{ .session_fallback_secrets = … })` (ADR 225).
    ///
    /// A pointer to the App's slice rather than the slice, so it is 8 bytes on
    /// every Ctx rather than 16, for something only a request whose cookie
    /// the current secret did not open ever reads.
    _session_fallbacks: *const []const [32]u8 = &no_fallbacks,
    /// Whether a plain `session` cookie is read when no `__Host-session`
    /// came, from `listen(.{ .session_plain_name = … })` (ADR 033).
    _session_plain: bool = false,
    /// The compressors `app.compress` gave the App, or null when it never
    /// did, which is what every App that did not ask for it gets, and a
    /// test driving a handler by hand. A pointer to the App's, eight bytes
    /// on the Ctx (ADR 211).
    _compressors: ?*const compress_mod.Pool = null,
    _params: []const router.Param,
    /// The route that matched, or null when none did. A pointer into the
    /// App's own table rather than a copy of anything on it — eight bytes on
    /// a Ctx, which is the number a handler that parks its frame pays per
    /// connection for this (ADR 162). The table does not move while the
    /// server runs: registration is over before the first request.
    _route: ?*const router.Route = null,
    _services: *const service_mod.Registry,
    /// Set by App when the path names a file in a static set, so the
    /// terminal handler does not have to look it up a second time.
    _static_file: ?*const static_mod.File = null,
    /// The methods that do answer this path, when the one asked for does
    /// not. Set by App only on the way to a 405, which is the one answer
    /// that has to list them.
    _allowed: router.MethodSet = .initEmpty(),
    /// Set while the server is stopping, so a response can say so. Null
    /// when App is driven directly by a test, where nothing is stopping.
    _stopping: ?*const std.atomic.Value(bool) = null,
    _body: ?[]const u8 = null,
    /// Set when the handler asked to read the body in pieces, and how far it
    /// got. App reads it to discard whatever is left (ADR 019).
    _incoming: ?body_mod.Progress = null,
    /// Set when reading the body went wrong in a way that leaves the
    /// connection at an unknown byte. App reads it and does not reuse the
    /// connection.
    _stream_desynced: bool = false,
    /// Set when `body()` took the bytes off the wire and could not hand them
    /// over, a gzip stream that did not inflate: a second `body()` is refused
    /// rather than answered from `_body`, which is empty then.
    _body_refused: bool = false,
    /// Written by `Next.run`: how many layers of the onion were left below
    /// the deepest one reached, 0 once the handler ran, and the maximum
    /// while nothing has run. A chain that ends unanswered above 0 was
    /// stopped by a middleware that said nothing (ADR 008). A `u8` because
    /// it fits in padding the Ctx already had, 824 bytes with it or without;
    /// a `u16` was 8 more. Saturated, so a chain past 255 layers names the
    /// layer that stopped it only roughly, and still tells it from the handler.
    _chain_left: u8 = std.math.maxInt(u8),
    _sent: bool = false,
    /// Set once `100 Continue` has gone out, so it goes out at most once even
    /// though two body paths can each be the first to read (ADR 073). App
    /// reads it with `Request.expect_continue` to tell a body the client is
    /// still holding from one it has already sent.
    _continued: bool = false,
    /// Set between `stream()` and the stream's `finish()`, which clears it.
    /// App reads it to find a body nobody ended (ADR 019).
    _stream: ?stream_mod.Open = null,
    /// The blocking detector's stopwatch for this request, or null when
    /// there is no request behind this Ctx — a handler called straight from
    /// a test. Held here rather than looked up: `Ctx.send` is on the path of
    /// every request, and finding it through the fiber slot instead cost a
    /// measured 45ns of the 612 a whole request takes (ADR 013).
    _watch: ?*watchdog.Watch = null,
    /// Set when this request took the connection over — a stream, a body
    /// reader, a WebSocket. Once set it stays set, which is what separates
    /// it from `_stream` above: a stream that was finished properly is
    /// still a request that spent its time on the socket, and the blocking
    /// detector has to leave it alone either way (ADR 013).
    _took_over: bool = false,
    /// Set while the deadline on `_deadlines` is `listen()`'s default rather
    /// than a route's own. A request that takes the connection over drops a
    /// default deadline — a stream or a WebSocket is meant to outlive it —
    /// and keeps one a route asked for by name (ADR 105).
    _deadline_default: bool = false,
    /// Set when the response cannot share its connection with another
    /// request whatever the client asked for — an unframed HTTP/1.0 stream,
    /// where the end of the body *is* the end of the connection.
    _force_close: bool = false,
    /// The status actually sent, once something has been. 0 until then.
    _status: u16 = 0,
    /// Response headers a handler or middleware added.
    ///
    /// The first four live here rather than in the arena. CORS sets one to
    /// three of them and a static file two, so an ArrayList meant an
    /// allocation on the path of every request that had any middleware at all
    /// — for something that fits in 128 bytes of a struct already on the
    /// stack. Past four it spills, and then the spill is the whole list.
    _extra_inline: [inline_headers]http1.Header = undefined,
    _extra_n: usize = 0,
    _extra_spill: std.ArrayList(http1.Header) = .empty,
    /// Resolved values already worked out for this request (ADR 015).
    /// Stays empty — and costs nothing — on a request that asks for none.
    _resolved: std.ArrayList(Resolved) = .empty,
    /// Trailers the route set, sent after the body by whichever framing
    /// carries it (ADR 254). Empty, and costing nothing, on an answer that
    /// sets none.
    _trailers: framing_mod.Trailing = .{},
    /// Set by `Next.hold`: a whole answer and a stream's end wait for the
    /// chain to unwind, so the middleware that asked can still change them
    /// (ADR 008). Never cleared before then.
    _hold: bool = false,
    /// What is being held, while `_hold` is set and something answered.
    _held: ?*Held = null,
    /// Set once the head is on its way. A header after it has nowhere to go,
    /// and is refused rather than lost.
    _head_written: bool = false,
    /// Set once the body has ended. A trailer after it has nowhere to go.
    _body_ended: bool = false,

    /// Memory that lasts exactly as long as this request.
    ///
    /// Reset when the request ends, so nothing taken from here needs — or
    /// may have — a `free`. It is what `Str` points into, and it is the
    /// reason a `Str` never escapes its request without `.keep()`
    /// (ADR 003).
    ///
    /// Public because a module beside the framework has to be able to
    /// allocate for the request without reaching into a field: `nilo_sql`
    /// fills its rows out of here, and rows a handler returns then live
    /// exactly as long as the response that carries them.
    ///
    /// Several threads may allocate from it at once: it is a
    /// `std.heap.ArenaAllocator` over the App's allocator, which is
    /// thread-safe whenever its child is, and the App's allocator already
    /// serves every executor thread. So a handler can hand it to a pool
    /// of its own inside `nilo.blocking` and return a typed value that
    /// borrows from it, since the reset comes after the response is
    /// written. Every such thread has to be joined before the handler
    /// returns.
    pub fn arena(self: *const Ctx) std.mem.Allocator {
        return self._arena;
    }

    /// Text that belongs to this request, as a `Str`.
    ///
    /// `bytes` has to live at least as long as the request — memory from
    /// `arena()` does, by construction, which is the pairing this exists
    /// for. What it buys over passing the slice around is the Debug-only
    /// trap: a `Str` read after its request has ended says so, instead of
    /// quietly reading whatever is in the arena the next time round
    /// (ADR 003).
    ///
    /// The `Lifetime` itself stays private. Handing one out would let a
    /// caller stamp any bytes at all with this request's lifetime, and the
    /// trap only means something while the stamp is true.
    pub fn str(self: *const Ctx, bytes: []const u8) Str {
        return Str.fromRequest(bytes, self._lifetime);
    }

    /// The service of type `P` (a pointer type), for handlers that hold a
    /// `*Ctx` and so do not go through argument matching. Null if it was
    /// never registered — in the typed layer that case is already filtered
    /// out by `listen()`.
    pub fn service(self: *const Ctx, comptime P: type) ?P {
        return self._services.get(P);
    }

    /// The resolved value of type `V` for this request — worked out now if
    /// nobody has asked yet, and handed back as-is if they have (ADR 015).
    ///
    /// A handler gets these by writing the type in its argument list and
    /// never calls this. What it is here for is middleware, which has no
    /// argument list to write in:
    ///
    /// ```zig
    /// fn requireAdmin(c: *nilo.Ctx, next: nilo.Next) !void {
    ///     const user = try c.resolve(CurrentUser);
    ///     if (!user.is_admin) return nilo.fail.forbidden("admins only", .{});
    ///     try next.run(c);
    /// }
    /// ```
    ///
    /// The handler behind that middleware can then take a `CurrentUser` of
    /// its own without authenticating a second time.
    pub fn resolve(self: *Ctx, comptime V: type) !V {
        // Imported here rather than at the top of the file: resolve.zig
        // needs Ctx, and asking for it from inside the function body keeps
        // the two out of each other's way.
        return @import("resolve.zig").value(V, self);
    }

    /// The resolved value of type `V` if this request has already worked one
    /// out. nilo's own; users go through `resolve`.
    pub fn cachedResolved(self: *const Ctx, comptime V: type) ?V {
        const p = self.resolvedNamed(@typeName(V)) orelse return null;
        return @as(*const V, @ptrCast(@alignCast(p))).*;
    }

    /// The resolved value under that type name, untyped — what an erased
    /// Scope reads through its table, where the type cannot be said
    /// ([ADR 144](../docs/adr/144-a-scope-that-crosses-a-function-pointer.md)).
    /// Only what has *already* been worked out: an erased Scope cannot run a
    /// resolver. nilo's own; users go through `resolve`.
    pub fn resolvedNamed(self: *const Ctx, type_name: []const u8) ?*const anyopaque {
        for (self._resolved.items) |entry| {
            if (entry.type_name.ptr != type_name.ptr and !std.mem.eql(u8, entry.type_name, type_name))
                continue;
            return entry.value;
        }
        return null;
    }

    /// Remember a resolved value for the rest of this request. nilo's own.
    ///
    /// The value is copied into the request arena, so it dies with the
    /// request exactly as every `Str` inside it does.
    pub fn cacheResolved(self: *Ctx, comptime V: type, resolved: V) !void {
        const box = try self._arena.create(V);
        box.* = resolved;
        // Two is the shape this has in practice — a user, and something
        // worked out from the user — so the list is sized for that once
        // rather than grown twice.
        if (self._resolved.capacity == 0) {
            try self._resolved.ensureTotalCapacity(self._arena, 2);
        }
        try self._resolved.append(self._arena, .{
            .type_name = @typeName(V),
            .value = @ptrCast(box),
        });
    }

    // ---- the request side ----

    pub fn path(self: *const Ctx) Str {
        return Str.fromRequest(self._path, self._lifetime);
    }

    /// Whether the client already holds `version` — its `If-None-Match`
    /// names the tag a `nilo.Versioned(T)` with that version goes out under
    /// (ADR 189). Asked before building the body, so a handler returning
    /// `.unchanged(version)` skips the work as well as the bytes:
    ///
    /// ```zig
    /// if (c.clientHas(version)) return .unchanged(version);
    /// ```
    ///
    /// A handler that never asks still answers 304 to such a client; what
    /// asking buys is the query it did not run.
    pub fn clientHas(self: *const Ctx, version: u64) bool {
        const sent = self.header("If-None-Match") orelse return false;
        return versioned_mod.matches(sent.view(), version);
    }

    /// A path param from the route pattern: `/users/:id` → `param("id")`.
    /// Percent-decoded, so `/users/wati%20sari` gives `wati sari`.
    pub fn param(self: *const Ctx, name: []const u8) ?Str {
        for (self._params) |p| {
            if (std.mem.eql(u8, p.name, name)) return Str.fromRequest(p.value, self._lifetime);
        }
        return null;
    }

    /// The `operationId` of the route this request matched — what
    /// `app.named` gave it, or the name derived from the method and the
    /// pattern, exactly as the API description prints it
    /// ([ADR 162](../docs/adr/162-a-middleware-can-learn-which-route-it-is-in-front-of.md)).
    ///
    /// ```zig
    /// fn authorize(c: *nilo.Ctx, next: nilo.Next) !void {
    ///     const name = c.routeName() orelse return next.run(c);
    ///     const needed = table.get(name) orelse return nilo.fail.forbidden("{s} is not in the permission table", .{name});
    ///     …
    /// }
    /// ```
    ///
    /// This is what lets one middleware hold a default-deny table over every
    /// route: the name is the one identifier a route has that the contract
    /// also has, so a table keyed by it can be checked against the document
    /// in both directions, and a route the table does not name is refused
    /// rather than open. Null when nothing matched — a 404, a 405, a static
    /// file — and for a `Ctx` built by hand in a test. A `HEAD` answered by
    /// a `GET` route carries the `GET`'s name, because that is the operation
    /// that ran.
    ///
    /// A `[]const u8` rather than a `Str`, because nothing about it ends with
    /// the request: it points at a comptime literal or at a name the App
    /// derived at registration and owns for its whole life.
    pub fn routeName(self: *const Ctx) ?[]const u8 {
        const route = self._route orelse return null;
        return route.name;
    }

    /// Which request this is: moved when the request ends, never the same on
    /// two connections. nilo's own; `core.serialOf` is how a module reads it,
    /// and `sql.problem` is the one that does (ADR 117).
    pub fn serial(self: *const Ctx) u64 {
        return self._lifetime.serial();
    }

    /// The URL of one of this server's routes, built out of the pattern it was
    /// registered under
    /// ([ADR 100](../docs/adr/100-a-route-pattern-is-the-name-of-its-url.md)).
    ///
    /// ```zig
    /// try c.redirect(303, (try c.url("/users/:id", .{ .id = made.id })).view());
    /// ```
    ///
    /// The pattern is the name, so there is no route name to register and
    /// none to keep in step. Every mistake left is a compile error: a param
    /// with no value, a value with no param, a type a path cannot carry. Each
    /// value is percent-encoded, so nothing a user typed can add a segment.
    ///
    /// One allocation out of the request arena, on a request that asked for
    /// one. `url.into` is the same call with a buffer of the caller's, for
    /// code with no request in flight.
    pub fn url(self: *Ctx, comptime pattern: []const u8, args: anytype) !Str {
        var out: std.Io.Writer.Allocating = .init(self._arena);
        try url_mod.write(&out.writer, pattern, args);
        return Str.fromRequest(out.written(), self._lifetime);
    }

    /// A query param, percent-decoded: `/search?q=hello%20world` →
    /// `query("q")` is `hello world`. A `+` counts as a space, the way an
    /// HTML form encodes one.
    pub fn query(self: *const Ctx, name: []const u8) ?Str {
        for (self._query_params) |p| {
            if (std.mem.eql(u8, p.name, name)) return Str.fromRequest(p.value, self._lifetime);
        }
        return null;
    }

    /// A request header, name matched case-insensitively.
    ///
    /// Read straight out of the head each time rather than from a list
    /// built in advance. A list would mean an allocation on every request
    /// including the many that never look at a header at all, to save a
    /// scan of a few hundred bytes on the few that look twice. The scan looks
    /// only at the lines that start with the name's letter, where splitting and
    /// trimming each line was several times the work (`http1.findHeader`,
    /// ADR 256, and `bench/result/http.md#a-header-is-looked-for-by-the-lines-that-can-hold-it`).
    pub fn header(self: *const Ctx, name: []const u8) ?Str {
        const value = http1.findHeader(self._head, name) orelse return null;
        return Str.fromRequest(value, self._lifetime);
    }

    /// One request header, as `headers()` hands them out.
    ///
    /// Both halves are `Str` rather than `[]const u8` for the reason the type
    /// exists: the head is usually *borrowed* from the connection's read
    /// buffer, so a name kept past the request points at somebody else's
    /// request (ADR 003). A name is as much a slice of the head as a value is.
    pub const RequestHeader = struct {
        name: Str,
        value: Str,
    };

    /// Walks every header the request sent, in the order they arrived.
    /// Returned by `Ctx.headers()`; nothing else constructs one.
    ///
    /// Not to be confused with `nilo.Headers`, which is the *response* side —
    /// a list a handler writes. This one only reads.
    pub const HeaderIterator = struct {
        _inner: http1.HeaderIterator,
        _lifetime: *const str_mod.Lifetime,

        pub fn next(self: *HeaderIterator) ?RequestHeader {
            const h = self._inner.next() orelse return null;
            return .{
                .name = Str.fromRequest(h.name, self._lifetime),
                .value = Str.fromRequest(h.value, self._lifetime),
            };
        }
    };

    /// Every header the request sent, in arrival order.
    ///
    /// ```zig
    /// var it = c.headers();
    /// while (it.next()) |h| { … }
    /// ```
    ///
    /// The two cases `header(name)` cannot serve: a middleware that does not
    /// know the names in advance, and a header sent **twice**, which `header`
    /// answers the first of and never mentions the second (ADR 085).
    ///
    /// The same walk `header` does, so it costs the same nothing — no list is
    /// built and a request that never calls this pays for none of it.
    pub fn headers(self: *const Ctx) HeaderIterator {
        return .{
            ._inner = http1.HeaderIterator.from(self._head),
            ._lifetime = self._lifetime,
        };
    }

    /// One query parameter, as `queries()` hands them out. Both halves are
    /// `Str` for the reason `RequestHeader`'s are.
    pub const QueryParam = struct {
        name: Str,
        value: Str,
    };

    /// Walks every query parameter, in the order they arrived, decoded.
    /// Returned by `Ctx.queries()`; nothing else constructs one.
    pub const QueryIterator = struct {
        _params: []const router.Param,
        _at: usize = 0,
        _lifetime: *const str_mod.Lifetime,

        pub fn next(self: *QueryIterator) ?QueryParam {
            if (self._at == self._params.len) return null;
            const p = self._params[self._at];
            self._at += 1;
            return .{
                .name = Str.fromRequest(p.name, self._lifetime),
                .value = Str.fromRequest(p.value, self._lifetime),
            };
        }
    };

    /// Every query parameter, in arrival order, percent-decoded with `+` read
    /// as a space — the same values `query(name)` answers with.
    ///
    /// ```zig
    /// var it = c.queries();
    /// while (it.next()) |q| { … }
    /// ```
    ///
    /// The case `query(name)` cannot serve: **a filter whose names are data**,
    /// like `?filter[status]=open&filter[owner]=7`, or a request being logged
    /// or forwarded whole (ADR 090). A name sent twice appears twice, in the
    /// order it was sent, which `query` also cannot report.
    ///
    /// Nothing is allocated. The parameters were split once, into the request
    /// arena, before the handler ran.
    pub fn queries(self: *const Ctx) QueryIterator {
        return .{ ._params = self._query_params, ._lifetime = self._lifetime };
    }

    /// The query string as it arrived, still encoded and with no `?` on the
    /// front — `""` when there was none.
    ///
    /// The bytes rather than the parts, for the callers that need what was
    /// sent rather than what it meant: a signature computed over the request
    /// line, a proxy passing one on, a log line that has to match somebody
    /// else's. `queries()` is the one to reach for otherwise.
    pub fn queryString(self: *const Ctx) Str {
        return Str.fromRequest(self._query, self._lifetime);
    }

    /// The host this request was addressed to, without the scheme and with
    /// the port still on it if the client sent one: `"api.example.com"`,
    /// `"localhost:8080"`.
    ///
    /// The `Host` header, which an HTTP/1.1 request has exactly one of or it
    /// is a 400 ([ADR 070](../docs/adr/070-a-request-nobody-else-would-answer-is-refused.md)) —
    /// **unless `listen()` says a proxy stands in front and this request came
    /// through it**, in which case an `X-Forwarded-Host` it wrote is the
    /// answer: with `.trusted_proxies`, only on a connection from an address
    /// it names, as `clientIp` reads `X-Forwarded-For`; with `.trusted_hops`
    /// alone, on any. With neither that header is ignored, because a forged
    /// one ends up inside the password-reset link somebody clicks.
    ///
    /// A target that arrived in absolute form — `GET http://example.com/x` —
    /// is answered from the target instead (RFC 9112 §3.2,
    /// [ADR 095](../docs/adr/095-a-target-is-read-in-the-form-it-arrived-in.md)).
    /// A trusted proxy still outranks it.
    pub fn host(self: *const Ctx) Str {
        if (self.cameThroughProxy()) {
            if (self.header("X-Forwarded-Host")) |sent| {
                // A proxy chain writes a list, and the first entry is the one
                // the client asked for. A value that is not a host — a
                // control byte, a space, a slash — is dropped rather than
                // used, because this ends up in URLs.
                const first = std.mem.trim(u8, upTo(sent.view(), ','), " \t");
                if (isHostLike(first)) return Str.fromRequest(first, self._lifetime);
            }
        }
        const authority = self._request.authority;
        if (authority.len > 0) return Str.fromRequest(authority, self._lifetime);
        return self.header("Host") orelse Str.static("");
    }

    /// `"https"` or `"http"`: what the **client** used, which behind a proxy
    /// is not what nilo saw.
    ///
    /// On a listener with its own `.tls` it is `"https"`, from the connection
    /// ([ADR 212](../docs/adr/212-tls-is-an-option-a-build-asks-for.md)).
    /// Behind a proxy that terminates TLS, the proxy knows, and says so in
    /// `X-Forwarded-Proto`, read only from a proxy `listen()` was told about,
    /// for the reason `host()` gives. Otherwise `"http"`, which is the truth
    /// about the connection rather than a guess.
    pub fn scheme(self: *const Ctx) Str {
        if (self._peer.tls) return Str.static("https");
        if (self.cameThroughProxy()) {
            if (self.header("X-Forwarded-Proto")) |sent| {
                const first = std.mem.trim(u8, upTo(sent.view(), ','), " \t");
                if (std.ascii.eqlIgnoreCase(first, "https")) return Str.static("https");
            }
        }
        return Str.static("http");
    }

    /// Which listener this request arrived on: `0` for the one `.address` and
    /// `.port` name, `1` for the first `.also` entry, `2` for the second, and
    /// so on in the order `listen()` was given them
    /// ([ADR 252](../docs/adr/252-a-request-knows-which-listener-it-came-in-on.md)).
    ///
    /// A number the program chose by writing the list, so a middleware that
    /// refuses a route on the wrong listener compares it with a constant it
    /// declared beside that list. It is read off the connection, never off
    /// a header, so a client cannot say which one it used. `0` for every
    /// request of a test that did not set `.listener`.
    pub fn listener(self: *const Ctx) u8 {
        return self._peer.listener;
    }

    /// Whether the forwarding headers on this request may be believed: it
    /// came from an address `.trusted_proxies` names (or over a unix socket,
    /// ADR 103), or, with no list, `.trusted_hops` says a proxy stands in
    /// front. The rule `clientIp` applies to `X-Forwarded-For`, so `host()`
    /// and `scheme()` cannot be told something `clientIp` would refuse
    /// (ADR 102).
    fn cameThroughProxy(self: *const Ctx) bool {
        const named_proxies = self._limits.trusted_proxies;
        if (named_proxies.len > 0) return self._peer.local or proxies_mod.holds(named_proxies, self._peer.address());
        return self._limits.trusted_hops > 0;
    }

    /// A span of this request's trace, a child of whatever span is current,
    /// and current itself until it ends
    /// ([ADR 247](../docs/adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)).
    ///
    /// ```zig
    /// var span = c.span("charge card");
    /// defer span.end();
    /// errdefer |err| span.fail(err);
    /// ```
    ///
    /// `name` is comptime, because a span name has to be one of a few (it is
    /// what a trace view groups by) and one that has to be known while
    /// compiling cannot carry an id or an email. A call through `nilo_fetch`
    /// while the span is open is its child. On an App that does not trace, or
    /// a request whose trace is not recorded, the span records nothing and
    /// `end` is a compare.
    pub fn span(self: *Ctx, comptime name: []const u8) trace_mod.Span {
        const tracer = self._tracer orelse return .none(&self._trace);
        if (!self._trace.context.sampled) return .none(&self._trace);
        return .open(tracer, &self._trace, name);
    }

    /// This request's trace id, as the 32 hex characters a trace view
    /// searches by, or null on an App that does not trace. For a log line or
    /// an error page that wants to say where to look.
    pub fn traceId(self: *const Ctx) ?[32]u8 {
        if (self._tracer == null) return null;
        var out: [32]u8 = undefined;
        str_mod.trace.writeHex(&self._trace.context.trace_id, &out);
        return out;
    }

    /// The framework's own: the trace id between `before` and `after`, or
    /// nothing on an App that does not trace. What the logger writes, through
    /// the tracer's pointer so that a program with a logger and no tracing
    /// links none of it (ADR 247).
    pub fn writeTraceId(self: *const Ctx, w: *std.Io.Writer, before: []const u8, after: []const u8) std.Io.Writer.Error!void {
        const tracer = self._tracer orelse return;
        return tracer.write_id(&self._trace, w, before, after);
    }

    /// The Scope half of a traced call: `nilo_fetch` asks this before a call
    /// leaves, and sends the context as `traceparent` (ADR 247).
    pub fn traceBegin(self: *Ctx) ?str_mod.trace.Outbound {
        const tracer = self._tracer orelse return null;
        return tracer.begin_call(&self._trace);
    }

    /// The other half: the call ended, and its span is kept if the trace is.
    pub fn traceEnd(self: *Ctx, begun: str_mod.trace.Outbound, ended: str_mod.trace.Ended) void {
        const tracer = self._tracer orelse return;
        tracer.end_call(tracer, begun, ended);
    }

    /// This request's id — the one thing that ties a log line, a response,
    /// and a client's report of "it was slow at 14:02" to each other.
    ///
    /// Taken from the `X-Request-Id` a proxy in front sent when there is one
    /// and it is usable, and generated otherwise. Worked out on the first
    /// call and kept, so a request that never asks pays nothing.
    ///
    /// **A client's id is checked, not trusted.** It goes into log lines and
    /// back out as a response header, so whatever a stranger can put in it is
    /// something they can put in your logs — a newline forges a line of its
    /// own, and in a response header it splits the response. What passes is
    /// 1 to 64 bytes of letters, digits, `.`, `_` and `-`, which is what
    /// every id anybody generates already looks like. Anything else is
    /// ignored in favour of one of nilo's own, rather than refused: a
    /// request is not worth failing over the shape of a correlation id.
    pub fn requestId(self: *Ctx) Str {
        if (self._request_id) |id| return id;

        const id = if (self.header("X-Request-Id")) |given| given: {
            break :given if (usableRequestId(given.view())) given else self.generatedId();
        } else self.generatedId();

        self._request_id = id;
        return id;
    }

    fn generatedId(self: *Ctx) Str {
        // Rendered by hand rather than through `std.fmt`: this is on the
        // path of every request the logger is switched on for, and sixteen
        // shifts is less than reaching for the formatter.
        const hex = "0123456789abcdef";
        var value = nextId();
        var i: usize = self._request_id_buf.len;
        while (i > 0) {
            i -= 1;
            self._request_id_buf[i] = hex[@intCast(value & 0xf)];
            value >>= 4;
        }
        return Str.fromRequest(self._request_id_buf[0..], self._lifetime);
    }

    /// The `std.Io` the server runs on, for what a handler hands to
    /// something that takes one: a `std.Io.Queue`, a `std.Io.Event`, a
    /// `std.Io.Select`, a `std.Io.sleep` (ADR 244).
    ///
    /// ```zig
    /// fn append(c: *nilo.Ctx, wal: *Wal) !void {
    ///     var done: std.Io.Event = .unset;
    ///     var item: Append = .{ .bytes = (try c.body()).view(), .done = &done };
    ///     try wal.queue.putOne(c.io(), &item);
    ///     done.waitUncancelable(c.io()); // the writer holds &item now
    /// }
    /// ```
    ///
    /// **A wait on it parks the fiber, not the thread**, which is what the
    /// rule of ADR 013 asks of a wait, and the other end of the queue is a
    /// fiber started with `app.spawn`, which runs on the same loop
    /// ([ADR 028](../docs/adr/028-a-spawned-fiber-belongs-to-the-server.md)).
    /// A handler that asks for it with `fn (io: std.Io, …)` gets the same
    /// value; this is for a handler or a middleware that already holds the
    /// `*Ctx`.
    ///
    /// **A wait here is not reported as a handler holding its thread**: the
    /// detector (ADR 013) is not told about it, but sees that the loop turned
    /// over while the fiber waited, so a wait of any length is a park. What it
    /// reports is the handler running past `block_warning_ms` (250 ms) after
    /// the wait.
    ///
    /// In a `testing.Client` or `testing.Wired` there is no server, and this
    /// is a process-wide `std.Io.Threaded` (`Wired.io()` is the same one), so
    /// a handler written against it runs in memory.
    pub fn io(self: *const Ctx) std.Io {
        _ = self;
        return bulkhead.loopIo();
    }

    /// `n` bytes from the operating system's entropy source, off the event
    /// loop (ADR 042).
    ///
    /// ```zig
    /// const key = id.v7(try c.entropy(id.Uuid.v7_entropy), nilo.nowMillis());
    /// ```
    ///
    /// **A method rather than a free function**, because entropy is a syscall
    /// and a syscall straight off a fiber stops every request sharing that
    /// thread. This one parks on the Engine's blocking pool instead
    /// (ADR 013). Reaching it only through a `Ctx` is what says the call
    /// costs a wait — which is why `nilo_id` takes randomness as an argument.
    ///
    /// By value, so it fits in the expression that uses it: `n` is comptime,
    /// the array is on the stack, nothing is allocated.
    ///
    /// A program with no loop in it needs none of this: `std.Io.randomSecure`
    /// is the same bytes, and there is no fiber to park.
    pub fn entropy(self: *const Ctx, comptime n: usize) ![n]u8 {
        var out: [n]u8 = undefined;
        try self.entropyInto(&out);
        return out;
    }

    /// `entropy` for a caller that cannot say the length while compiling
    /// ([ADR 134](../docs/adr/134-entropy-a-function-pointer-can-carry.md)).
    ///
    /// The same syscall through the same Bulkhead; what changes is only that
    /// the width is a value. `entropy` returns `![n]u8`, and a **function
    /// pointer** has to name one return type — so a Scope type-erased to
    /// cross one carries exactly one width, and the second caller that wants
    /// a different number of bytes has nowhere to put it. Zig has no
    /// closures, so erasing a Scope is what storing a callback comes to.
    ///
    /// `Run.entropyInto` is the same call off the loop, which is what keeps
    /// one function body compiling under both.
    pub fn entropyInto(self: *const Ctx, buf: []u8) !void {
        _ = self;
        try bulkhead.randomSecure(buf);
    }

    /// Hash a password: salted from `Ctx.entropy`, off the loop, and behind
    /// the Gate that says how many may run at once (ADR 044).
    ///
    /// ```zig
    /// const stored = try c.hashPassword(gpa, form.password.view());
    /// _ = try db.insert(User, conn, .{ .email = form.email, .password = stored.text() });
    /// ```
    ///
    /// **A method for the reason `entropy` is one, and more so.** One hash is
    /// 13 ms of CPU and 19 MiB, and 13 ms is *under* `block_warning_ms` — so
    /// calling `nilo_pw` straight from a handler holds the thread on every
    /// sign-in and nothing in the log ever says so. This is the call that
    /// cannot forget.
    ///
    /// `gpa` is an argument rather than something nilo reaches for, because
    /// 19 MiB is worth seeing at the call site — and because the request
    /// arena is the wrong place for it (ADR 017).
    pub fn hashPassword(
        self: *const Ctx,
        gpa: std.mem.Allocator,
        password: []const u8,
    ) !password_mod.Hash {
        return password_mod.hash(self, gpa, password);
    }

    /// The same, at a Cost of the caller's own. Below the floor it is a
    /// Refusal rather than a weak hash nobody notices.
    pub fn hashPasswordWith(
        self: *const Ctx,
        comptime cost: password_mod.Cost,
        gpa: std.mem.Allocator,
        password: []const u8,
    ) !password_mod.Hash {
        return password_mod.hashWith(cost, self, gpa, password);
    }

    /// Whether `password` is the one `stored` was made from.
    ///
    /// ```zig
    /// const row = try db.find(User, conn, .{ .email = form.email });
    /// if (!try c.verifyPassword(gpa, if (row) |r| r.password else null, form.password.view()))
    ///     return nilo.fail(401, "that is not a sign-in");
    /// ```
    ///
    /// **`stored` is optional, and null is the point rather than a
    /// convenience.** A sign-in for an address with no account has no hash to
    /// check; returning early there answers in a millisecond instead of
    /// thirteen and turns the form into a list of which addresses are
    /// registered. Passing null does the work anyway and answers false. There
    /// is no signature here that lets the fast wrong version be written.
    ///
    /// **The request is not used**: the salt is in the stored string. With
    /// no request in hand — a CLI, a job, a test — `nilo.verifyPassword` is
    /// this call without the `Ctx`, through the same Gate (ADR 044).
    pub fn verifyPassword(
        self: *const Ctx,
        gpa: std.mem.Allocator,
        stored: ?[]const u8,
        password: []const u8,
    ) !bool {
        return password_mod.verify(self, gpa, stored, password);
    }

    /// The same, told what a hash of yours costs.
    ///
    /// **Pass the Cost you hash with, and pass it here too.** The no-account
    /// path does the work of a hash rather than returning early, and the Cost
    /// is what that work is measured out at — left at the default while your
    /// rows are 46 MiB, the two answers take different lengths of time and the
    /// form is a list of addresses again (ADR 044). A stored hash is always
    /// checked at the parameters it carries.
    pub fn verifyPasswordWith(
        self: *const Ctx,
        comptime cost: password_mod.Cost,
        gpa: std.mem.Allocator,
        stored: ?[]const u8,
        password: []const u8,
    ) !bool {
        return password_mod.verifyWith(cost, self, gpa, stored, password);
    }

    /// The cookie called `name`, or null if the request carries no such one
    /// (ADR 029).
    ///
    /// ```zig
    /// const token = c.cookie("session") orelse
    ///     return fail.unauthorized("you are not signed in", .{});
    /// ```
    ///
    /// Read out of the head each time, the way `header` is, so a request
    /// that carries cookies and looks at none pays nothing. The value
    /// arrives exactly as the client sent it: RFC 6265 makes a cookie value
    /// opaque bytes and every framework layers its own encoding on top, so
    /// guessing at one here would corrupt the ones that guessed otherwise.
    ///
    /// A request may carry more than one `Cookie` header — HTTP/2 clients
    /// split them, and a proxy may — so all of them are looked through.
    pub fn cookie(self: *const Ctx, name: []const u8) ?Str {
        var it = http1.HeaderIterator.from(self._head);
        while (it.next()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "cookie")) continue;
            if (cookie_mod.find(h.value, name)) |value| {
                return Str.fromRequest(value, self._lifetime);
            }
        }
        return null;
    }

    /// The `Authorization` header, read as one scheme, or a 401 that says
    /// which ([ADR 153](../docs/adr/153-an-authorization-header-a-handler-can-ask-for.md)).
    /// For a resolver or a middleware, which have a Ctx and no argument
    /// list; a handler writes `nilo.Authorization(.bearer)` in its own and
    /// gets the document entry as well.
    pub fn authorization(self: *Ctx, comptime which: authorization_mod.Scheme) !authorization_mod.Authorization(which) {
        const raw: ?[]const u8 = if (self.header("Authorization")) |h| h.view() else null;
        return authorization_mod.read(which, raw, self.arena(), self._lifetime);
    }

    /// The `Authorization` header verified through the `jwt.Verifier` `V`,
    /// or the 401 — with the challenge — that says why not
    /// ([ADR 191](../docs/adr/191-verified-claims-are-a-handler-argument.md)).
    /// For a middleware guarding a prefix; a handler writes
    /// `nilo.Verified(V)` in its argument list and gets the document entry
    /// as well. A handler under the guard that asks again verifies again.
    pub fn verified(self: *Ctx, comptime V: type) !verified_mod.Verified(V) {
        const T = verified_mod.Verified(V);
        const verifier = self._services.get(*V) orelse return fail.internal(
            "service {s} was never registered; call app.provide() before app.listen()",
            .{@typeName(V)},
        );
        const raw: ?[]const u8 = if (self.header("Authorization")) |h| h.view() else null;
        // Seconds since the epoch, which is what a token's `exp` is in.
        const now_s = @divFloor(str_mod.nowMillis(), std.time.ms_per_s);
        return verified_mod.read(T, raw, self.arena(), self._lifetime, now_s, self, verifier);
    }

    /// The address the connection itself came from — the proxy's, when
    /// there is a proxy. Never forgeable, and never null: this is what the
    /// kernel says, not what a header claims.
    ///
    /// Empty text when there is no socket, which is what a handler called
    /// straight from a test gets.
    ///
    /// A pointer into the Ctx and not a copy: a `Peer` holds its address
    /// inline, so `c.peer().address()` on a copy was a slice into a
    /// temporary that was gone by the end of the expression. This one lives
    /// as long as the request, and so does what `address()` returns.
    pub fn peer(self: *const Ctx) *const bulkhead.Peer {
        return &self._peer;
    }

    /// Give this request a deadline, `ms` from now.
    ///
    /// Normally written as `nilo.deadline(2000)` on a route rather than called
    /// by hand; this is what that middleware does
    /// ([ADR 105](../docs/adr/105-a-route-can-say-how-long-it-has.md)).
    ///
    /// **What it bounds is every wait nilo owns**: reading the body, writing
    /// the response, a stream's pieces, a WebSocket's silence. Each of those
    /// has a limit of its own already and each is cut down to whichever comes
    /// first. **What it cannot bound is a handler that is running rather than
    /// waiting** — there is no interruption here, and there deliberately is
    /// not ([ADR 082](../docs/adr/082-a-cleanup-path-is-not-cancellable.md)).
    /// A loop that does its own work asks `overdue()`.
    ///
    /// Zero takes the deadline off.
    pub fn giveDeadline(self: *Ctx, ms: u32) void {
        self._deadlines.until_ns = if (ms == 0) 0 else bulkhead.monotonicNanos() + @as(u64, ms) * std.time.ns_per_ms;
        // Asked for by name, so it stays through a takeover; `listen()`'s
        // default is the one a stream lets go of (ADR 105).
        self._deadline_default = false;
    }

    /// The deadline `listen()` gives every request, applied before the route
    /// runs. Separate from `giveDeadline` because it has to be marked as the
    /// default: a route's own deadline outlives a takeover, this one does not.
    ///
    /// A request that arrived with an earlier deadline of its own keeps it:
    /// a gRPC call's `grpc-timeout` is the client's, and a default is not a
    /// reason to wait longer than the client will (ADR 220).
    pub fn giveDefaultDeadline(self: *Ctx, ms: u32) void {
        if (ms == 0) return;
        const due = bulkhead.monotonicNanos() + @as(u64, ms) * std.time.ns_per_ms;
        if (self._deadlines.until_ns != 0 and self._deadlines.until_ns <= due) return;
        self._deadlines.until_ns = due;
        self._deadline_default = true;
    }

    /// This request has taken the connection over — a body read in pieces, a
    /// stream, a WebSocket. The three callers used to set `_took_over` by
    /// hand; one place, so the deadline rule below cannot be forgotten at a
    /// fourth.
    ///
    /// A default deadline is dropped here: `listen()`'s number is for the
    /// requests that answer and go, and a stream cut off at thirty seconds
    /// because every other route wanted thirty is the shape ADR 105 refused.
    /// A deadline the route asked for by name is kept, since that route knew
    /// what it was.
    fn tookOver(self: *Ctx) void {
        self._took_over = true;
        if (self._deadline_default) {
            self._deadlines.until_ns = 0;
            self._deadline_default = false;
        }
        self.armWriteLimit();
    }

    /// Put the request's deadline on the write clock, which `listen()` armed
    /// once for the connection before any route ran and which a deadline set
    /// later does not reach by itself (ADR 105). Called where the answer or
    /// a takeover is about to write. Nothing at all for a request with no
    /// deadline: the limit already stands, and the next request on the
    /// connection starts from `listen()`'s again (`serve.handleConnection`).
    pub fn armWriteLimit(self: *const Ctx) void {
        if (self._deadlines.until_ns != 0) self._deadlines.armWrite();
    }

    /// How much body this request may read into the arena, in place of
    /// `listen()`'s `max_body`. `app.with(nilo.maxBody(bytes))` is the way to
    /// say it for a route; this is what that middleware does
    /// ([ADR 156](../docs/adr/156-a-route-can-say-how-much-body-it-takes.md)).
    ///
    /// Bounds every read into the arena — `body()`, `json`, a `Form(T)` —
    /// and not `bodyStream()`, which holds nothing there and takes its own
    /// `max_bytes`. Has to be called before the body is read; a body already
    /// in the arena was read under the limit that stood at the time.
    pub fn giveBodyLimit(self: *Ctx, bytes: usize) void {
        self._limits.max_body = bytes;
    }

    /// Whether this request has run out of the time it was given.
    ///
    /// Always false for a request with no deadline, so a handler may ask
    /// without knowing whether the route it is on set one:
    ///
    /// ```zig
    /// while (try rows.next()) |row| {
    ///     if (c.overdue()) return fail.status(503, "too many rows to do in time", .{});
    ///     try out.json(row);
    /// }
    /// ```
    pub fn overdue(self: *const Ctx) bool {
        const until = self._deadlines.until_ns;
        return until != 0 and bulkhead.monotonicNanos() >= until;
    }

    /// How many milliseconds are left, or null when this request has no
    /// deadline. Zero once it has passed.
    ///
    /// For a handler that has a limit of its own to hand somewhere else — an
    /// outbound call, say — and should not be given longer than the request
    /// has.
    pub fn timeLeftMs(self: *const Ctx) ?u32 {
        const until = self._deadlines.until_ns;
        if (until == 0) return null;
        const now = bulkhead.monotonicNanos();
        if (now >= until) return 0;
        return @intCast(@min((until - now) / std.time.ns_per_ms, std.math.maxInt(u32)));
    }

    /// The address of the client, looking through whatever `listen()` was told
    /// stands in front — `.trusted_proxies`, or `.trusted_hops`.
    ///
    /// With neither set this is `peer()` — the connection's own address —
    /// because `X-Forwarded-For` is a header like any other and a server that
    /// believes it without being told to has handed every client the ability
    /// to be any address it likes. Rate limits, audit logs and blocklists are
    /// the things that read this, and they are exactly the things worth lying
    /// to.
    ///
    /// **`.trusted_proxies` is the one to use**, and it wins when both are set
    /// ([ADR 102](../docs/adr/102-a-proxy-is-trusted-by-which-one-it-is.md)).
    /// The header is read only when the connection came from an address you
    /// named; entries written by addresses you named are skipped from the
    /// right; the first one left is the client. Nothing depends on how many
    /// proxies there are today.
    ///
    /// **A connection over a unix socket passes that first check by arriving.**
    /// It has no address for a rule to name, and nothing but a process on this
    /// machine could have opened it — which is what a `"loopback"` rule
    /// establishes about a proxy over TCP
    /// ([ADR 103](../docs/adr/103-a-path-is-an-address-to-listen-on.md)).
    /// Without `.trusted_proxies` set, `clientIp` on such a connection is
    /// empty, because there is no address and nobody said to read the header.
    ///
    /// `.trusted_hops` is the older shape and still works: counted from the
    /// right, so the entries a trusted proxy wrote are the only ones reachable
    /// and anything the client put in the header itself stays to the left,
    /// unread. A header with fewer entries than there are hops means the chain
    /// is not the one configured, so the socket's address is used rather than
    /// the closest guess.
    ///
    /// **Every `X-Forwarded-For` field is read, as one list in wire order.** A
    /// proxy may add a field of its own rather than append to the one the
    /// client sent — HAProxy does — and reading only the first field handed
    /// that client its own forgery back. Past `proxies.max_forwarded_fields`
    /// of them the last ones are read and the first let go: the walk is from
    /// the right, so what is let go is the far end, the part a client wrote.
    /// Answering with the socket's address instead, as this once did, answered
    /// with the proxy's, and a client that sent eight fields was read as the
    /// proxy by every allow-list of private addresses.
    pub fn clientIp(self: *const Ctx) Str {
        const hops = self._limits.trusted_hops;
        const named_proxies = self._limits.trusted_proxies;
        if (hops == 0 and named_proxies.len == 0) {
            return Str.fromRequest(self._peer.address(), self._lifetime);
        }

        // The last fields of that name, in wire order, as slices into the
        // head. Collected here rather than walked in place because the walk
        // goes right to left and a header iterator only goes forward; eight
        // slices on the stack is cheaper than a second pass per entry. Past
        // eight, the oldest is shifted out.
        var fields: [proxies_mod.max_forwarded_fields][]const u8 = undefined;
        var n: usize = 0;
        var it = http1.HeaderIterator.from(self._head);
        while (it.next()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "X-Forwarded-For")) continue;
            if (n == fields.len) {
                std.mem.copyForwards([]const u8, fields[0 .. n - 1], fields[1..n]);
                n -= 1;
            }
            fields[n] = h.value;
            n += 1;
        }
        if (n == 0) return Str.fromRequest(self._peer.address(), self._lifetime);

        // Naming the network wins over counting it: an operator who described
        // their proxies meant that, and a hop count left over from before is
        // the thing the description exists to stop mattering.
        const found = if (named_proxies.len > 0)
            proxies_mod.clientFrom(named_proxies, self._peer.address(), self._peer.local, fields[0..n])
        else
            proxies_mod.clientByHops(hops, fields[0..n]);
        return Str.fromRequest(found orelse self._peer.address(), self._lifetime);
    }

    /// Called by everything that is about to read from the connection.
    ///
    /// The head normally still lives in the connection's read buffer, because
    /// copying it into the arena costs an allocation and a memcpy that a
    /// request with no body has no use for. A read can overwrite it, so every
    /// read has to be one `App.handleRequest` already foresaw when it made
    /// that call. This is what says so out loud instead of leaving it to be
    /// remembered — a new way to read from the connection trips it in `Debug`
    /// and `ReleaseSafe`, which is where the suite runs, rather than handing
    /// somebody a `Str` full of the next request's bytes.
    fn aboutToRead(self: *const Ctx) void {
        std.debug.assert(!self._head_borrowed);
        // Here for the same reason the assert is, rather than at each call
        // site: a read nobody put a clock on is a fiber a client can park
        // by going quiet (ADR 022). One choke point means a new way to
        // read from the connection gets its limit without anybody
        // remembering to give it one. A WebSocket takes the limit back off,
        // once it is the thing doing the reading.
        self._deadlines.armBody();
    }

    /// `aboutToRead`, for the two paths that read the **request body** rather
    /// than the connection.
    ///
    /// The difference is `Expect: 100-continue`, which is a statement about a
    /// body and not about a socket: a client that sends it holds the body back
    /// until the server answers, and a server that never answers leaves it
    /// waiting on its own timer — one second, in curl's case, on every upload
    /// past its threshold (ADR 073). The handshake path keeps plain
    /// `aboutToRead`, because a WebSocket is about to read frames and has
    /// already decided to write a 101.
    ///
    /// Sending it here rather than when the head is parsed is what buys the
    /// other half of RFC 9110 §10.1.1 for nothing: a request refused before it
    /// reaches this line — a body over `max_body`, a 404, a 405, a handler that
    /// never asks — is answered with its final status and the body is never
    /// sent at all.
    fn aboutToReadBody(self: *Ctx) !void {
        self.aboutToRead();
        if (!self._request.expect_continue or self._continued) return;
        // One that has already been answered is past the point where a 100
        // would mean anything. Which clients may be sent one at all is the
        // framing's to know.
        if (self.answered() != null) return;
        self._continued = true;
        try self._framing.interimContinue();
    }

    /// The whole request body, read once into the request arena. Chunked
    /// and Content-Length look the same from here — the handler asks for
    /// the body, not for the way it arrived.
    ///
    /// **A gzipped body comes back inflated, and the head still says gzip.**
    /// `header("Content-Encoding")` and `header("Content-Length")` describe
    /// what arrived on the wire, because the head is read in place and
    /// nothing rewrites it (ADR 085, ADR 089). A handler that forwards
    /// this body to another service along with the request's headers would
    /// be sending plain bytes labelled `gzip`, at the wrong length: send
    /// `body().len` as the length and no `Content-Encoding`, or forward the
    /// wire bytes through `bodyStream()`, which hands them over as they came.
    pub fn body(self: *Ctx) !Str {
        // A body that failed once has used up the bytes on the wire, so
        // asking again can only read someone else's, or nothing. The answer
        // is the same refusal, and never the compressed bytes a failed
        // inflate used to leave behind (the audit of `http/` at `39896d2`).
        if (self._stream_desynced or self._body_refused) return fail.badRequest(
            "the request body could not be read, and reading it again does not change that",
            .{},
        );
        if (self._body == null) {
            // Waiting for a client to finish sending is not the handler
            // holding its thread — the fiber parks and the thread serves
            // somebody else. Said out loud, or a slow uploader would be
            // reported as a blocking handler (ADR 013).
            const w = watchdog.waiting(self._watch);
            defer watchdog.waited(self._watch, w);

            var received: []const u8 = undefined;
            if (framing_mod.http2_built and self._request.ends_with_stream) {
                received = try self.readStreamBody();
            } else if (self._request.chunked) {
                try self.aboutToReadBody();
                // A chunked body announces nothing, so the only length there
                // is to size a deadline from is the most it may be. That
                // gives it the same worst case as a body that announced
                // `max_body` and no more, which is the point: neither framing
                // is the cheaper way to hold a connection (ADR 022).
                self._deadlines.armBodyRun(self._limits.max_body);
                received = http1.readChunkedBody(self._in, self._arena, self._limits.max_body) catch |err| {
                    // The chunk sizes and the stream have come apart, so
                    // where this body ends is now a guess. Reading on and
                    // hoping to land on the next request is exactly how a
                    // smuggled request gets through — even when the bytes
                    // happen to line up, which they sometimes will.
                    self._stream_desynced = true;
                    return self.slowBody(err);
                };
            } else {
                if (self._request.content_length > self._limits.max_body) return error.BodyTooLarge;
                // A body of nothing reads nothing, so it is not a read — and a
                // client that framed one as empty is not holding anything back,
                // whatever it expected.
                if (self._request.content_length > 0) try self.aboutToReadBody();
                // Taken as it arrives rather than as it was announced, so a
                // client that promises a megabyte and trickles holds what it
                // sent and not what it said. See `readSizedBody`.
                received = http1.readSizedBody(
                    self._in,
                    self._arena,
                    @intCast(self._request.content_length),
                    self._deadlines,
                ) catch |err| {
                    // A read that stopped part way leaves the stream at a
                    // byte nothing knows, whether the client went away, was
                    // too slow or the socket broke.
                    self._stream_desynced = true;
                    return self.slowBody(err);
                };
            }

            // A gzipped body is the bytes above, inflated once into the arena
            // and held in their place — so `json`, `form` and every reader
            // past this line see the body and not the way it was sent, the
            // same way they see neither framing (ADR 089). What was read
            // above was bounded by `max_body` as compressed bytes; what it
            // inflates to is bounded by the same number, checked against the
            // length the stream announces before a byte is inflated.
            //
            // **Held only once it has inflated.** The compressed bytes used
            // to be assigned first and replaced on success, so a second
            // `body()` after a failure was handed them as the body (ADR 089).
            if (self._request.content_encoding == .gzip) {
                received = encoded.inflate(self._arena, received, self._limits.max_body) catch |err| {
                    // Nothing is held as the body, and the wire has been
                    // read to its end, which is what a non-null `_body`
                    // tells App's drain: the connection is still good.
                    self._body = &.{};
                    self._body_refused = true;
                    switch (err) {
                        error.BodyTooLarge, error.OutOfMemory => |e| return e,
                        error.BadEncodedBody => return fail.badRequest(
                            "the request body is not a gzip stream this server could decode — " ++
                                "it arrived under Content-Encoding: gzip",
                            .{},
                        ),
                    }
                };
            }
            self._body = received;
        }
        return Str.fromRequest(self._body.?, self._lifetime);
    }

    /// The body of a request on HTTP/2, which ends where its stream does:
    /// waited for where it has not arrived, and handed over where it lies,
    /// with no copy, where it has (ADR 260). Held to `max_body` as a chunked
    /// body is, and to the bound a chunked body's read is held to, by the
    /// pipe the wait is on. `noinline`: a request that reads no body does not
    /// carry it.
    noinline fn readStreamBody(self: *Ctx) ![]const u8 {
        const r = self._request;
        if (r.has_content_length and r.content_length == 0) return "";
        if (r.content_length > self._limits.max_body) return error.BodyTooLarge;
        try self.aboutToReadBody();
        const inbox = self._framing.inbox().?;
        inbox.setDeadline(self._deadlines.until_ns);
        return inbox.whole(self._limits.max_body) catch |err| {
            if (err == error.BodyTooLarge) return err;
            self._stream_desynced = true;
            return self.slowBody(err);
        };
    }

    /// A body read that ended because the client was too slow, told apart
    /// from one that ended because the connection broke.
    ///
    /// Both arrive as `error.ReadFailed` through a `std.Io` interface, and
    /// they deserve different answers: 408 says the request never finished
    /// arriving and inviting a retry is correct, where 500 blames the server
    /// for something the client did (ADR 022).
    ///
    /// And a third: a client that closed before it had sent what it said it
    /// would. That is `error.EndOfStream` from the reader, which names no one
    /// and fell through to a 500 and a warning, where the fault is the
    /// client's and the answer is a 400 (the audit of `http/` at `39896d2`).
    fn slowBody(self: *Ctx, err: anyerror) anyerror {
        if (err == error.ReadFailed and self._deadlines.timedOut()) return error.BodyTooSlow;
        if (err == error.EndOfStream) return fail.badRequest(
            "the request body ended before all of it had been sent",
            .{},
        );
        return err;
    }

    /// The request body, read in pieces rather than all at once — for the
    /// ones too big to hold (ADR 019).
    ///
    /// ```zig
    /// var incoming = try c.bodyStream();
    /// var buf: [64 * 1024]u8 = undefined;
    /// while (try incoming.read(&buf)) |part| try file.writeAll(part);
    /// ```
    ///
    /// Memory is the buffer you pass in and nothing else: this allocates
    /// not one byte, where `body()` reads the whole thing into the request
    /// arena and refuses past a megabyte. Content-Length and chunked look
    /// the same from here, as they do to `body()`.
    ///
    /// A body left half-read is fine — App discards the rest so the
    /// connection is clean for the next request.
    pub fn bodyStream(self: *Ctx) !body_mod.Body {
        return self.bodyStreamWith(.{});
    }

    /// `bodyStream`, with a different ceiling on how much body to accept.
    pub fn bodyStreamWith(self: *Ctx, options: body_mod.Options) !body_mod.Body {
        // Asking twice would hand out two readers into one stream, and the
        // second would get whatever the first left.
        std.debug.assert(self._body == null and self._incoming == null);
        // A stream hands the bytes out as they arrive and holds nothing, so
        // there is nowhere to inflate a gzipped body into: the destination
        // that `body()` uses as the inflater's window is the caller's buffer
        // here, and it is handed back a piece at a time (ADR 089). Refused
        // with the status the parser gives every other coding, and the
        // sentence says which side to change.
        if (self._request.content_encoding != .identity) return fail.status(
            415,
            "this route reads its body as a stream, which is not decoded — send it as identity",
            .{},
        );

        // A Content-Length says up front how big it is, so a body over the
        // limit is refused before a byte of it is read. A chunked one has to
        // be counted as it arrives.
        if (!self._request.chunked and self._request.content_length > options.max_bytes) {
            return error.BodyTooLarge;
        }
        // A body the transport frames has no length to look at, so what asks
        // is the pipe: a client that announced none, and sent none, is told
        // nothing is wanted.
        const transport = framing_mod.http2_built and self._request.ends_with_stream and
            !(self._request.has_content_length and self._request.content_length == 0);
        if (self._request.chunked or self._request.content_length > 0 or transport) try self.aboutToReadBody();
        if (transport) self._framing.inbox().?.setDeadline(self._deadlines.until_ns);

        self.tookOver();
        self._incoming = .start(self._request, options.max_bytes);
        var incoming: body_mod.Body = .init(self._in, &self._incoming.?);
        incoming._watch = self._watch;
        return incoming;
    }

    /// What a body with a key twice is answered with: `error.Failed` when
    /// `json.parseLeaky` put a sentence naming the key on the Failure, which
    /// speaks only for that error (`fail.failed`), and the bare error when it
    /// could not name one.
    fn repeatedKey(err: anyerror) anyerror {
        const failure = fail.current() orelse return err;
        return if (failure.isSet()) error.Failed else err;
    }

    /// Parse the request body as JSON into `T`. The result lives in the
    /// request arena — `keep` the fields you need for longer.
    ///
    /// `Str` fields get stamped with the request lifetime, so using one
    /// after the request has finished trips the debug trap just like any
    /// other Str (ADR 003).
    pub fn json(self: *Ctx, comptime T: type) !T {
        const b = (try self.body()).view();
        try refuseTooDeep(T, b);
        // A repeated key already said which on the Failure (`json.parseLeaky`),
        // and the dynamic re-read below cannot hold a repeated key at all.
        var value = json_mod.parseLeaky(T, self._arena, b, .{}) catch |err|
            return if (err == error.DuplicateField) misfit(T, repeatedKey(err)) else describeBadBody(T, self._arena, b, err);
        str_mod.stamp(&value, self._lifetime);
        // A struct that checks itself is checked once it is whole, and a
        // rule that did not hold is a 422 naming it (ADR 193).
        try @import("bound.zig").enforce(.body, T, value);
        return value;
    }

    /// Parse the request body as an HTML form into `T` — the `*Ctx` way in
    /// to what `Form(T)` does for a typed handler (ADR 030).
    ///
    /// `application/x-www-form-urlencoded` and `multipart/form-data` are
    /// both read; which one arrived is the browser's business, not the
    /// endpoint's. The whole body is held in memory and bounded by
    /// `max_body`, exactly as `json` is.
    ///
    /// Every `Str` in the result — a file's bytes included — points into the
    /// request arena and dies with the request, so `keep` is what takes one
    /// out of it (ADR 003).
    pub fn form(self: *Ctx, comptime T: type) !T {
        // Read before the body, while it is certain nothing has moved the
        // head: `body()` may read from the connection, and on a request with
        // a body the head has been copied for exactly that reason.
        const content_type = if (self.header("Content-Type")) |h| h.view() else null;
        const b = (try self.body()).view();
        const value = try @import("form.zig").readInto(T, self._arena, self._lifetime, content_type, b);
        // The same check a JSON body gets, in the form's own words (ADR 193).
        try @import("bound.zig").enforce(.form, T, value);
        return value;
    }

    /// The same as `form`, but recording why each field that would not bind
    /// did not, rather than stopping at the first one — the `*Ctx` way in to
    /// what `Bound(Form(T))` does for a typed handler.
    ///
    /// What is refused outright is what leaves no binding to hand back: a
    /// body that is not a form at all, and a form sent a way that cannot
    /// carry the file this endpoint wants (`bound.zig`).
    pub fn formCollecting(
        self: *Ctx,
        comptime T: type,
        outcomes: *[@typeInfo(T).@"struct".fields.len]convert.Outcome,
    ) !T {
        const content_type = if (self.header("Content-Type")) |h| h.view() else null;
        const b = (try self.body()).view();
        return @import("form.zig").readIntoCollecting(
            T,
            self._arena,
            self._lifetime,
            content_type,
            b,
            outcomes,
        );
    }

    /// The same as `json`, but recording why each field that would not bind
    /// did not — the `*Ctx` way in to what `Bound(T)` does for a typed
    /// handler.
    ///
    /// The body that parses pays for none of this: one parse, no second
    /// pass, and every outcome left clear.
    pub fn jsonCollecting(
        self: *Ctx,
        comptime T: type,
        outcomes: *[@typeInfo(T).@"struct".fields.len]convert.Outcome,
    ) !T {
        const b = (try self.body()).view();
        try refuseTooDeep(T, b);
        if (json_mod.parseLeaky(T, self._arena, b, .{})) |parsed| {
            var value = parsed;
            str_mod.stamp(&value, self._lifetime);
            for (outcomes) |*o| o.* = .{};
            return value;
        } else |err| {
            if (err == error.DuplicateField) return misfit(T, repeatedKey(err));
            return collectBadBody(T, self._arena, self._lifetime, b, err, outcomes);
        }
    }

    /// The status this request has already been answered with, or null if
    /// nothing has gone out yet.
    ///
    /// The seam everything that needs to know reaches through — a logger
    /// writing the line, a `sendFile` asserting it is first, a deadline
    /// deciding whether a 503 can still be sent. All of them used to read
    /// `_sent` and `_status` in a pair, which is two fields to keep in step
    /// and two ways to read one of them and forget the other.
    pub fn answered(self: *const Ctx) ?u16 {
        return if (self._sent) self._status else null;
    }

    /// Record that this request has been answered, and with what.
    ///
    /// The other half of `answered`, for the two places that put an answer on
    /// the wire without going through `send` — `sendFile`, which writes the
    /// head itself so a `Range` can be honoured, and the responses `serve`
    /// assembles. Both used to set `_sent` and `_status` by hand, which is
    /// the pair this seam exists to stop anybody keeping in step again.
    pub fn markAnswered(self: *Ctx, status: u16) void {
        self._sent = true;
        self._status = status;
    }

    /// Say this connection cannot carry another request, whatever the headers
    /// said.
    ///
    /// A response whose length nobody can work out — a stream with no
    /// `Content-Length` and no chunking, a file the client stopped reading
    /// halfway through — leaves the socket at a byte the next request cannot
    /// start from. Written through here rather than by setting `_force_close`
    /// from another file, because the flag is one direction only: nothing
    /// takes it off again.
    pub fn closeWhenDone(self: *Ctx) void {
        self._force_close = true;
    }

    /// Whether this connection is offered for another request.
    ///
    /// Checked when the response is written rather than when the request
    /// was read, because a stop can land in between — a handler that was
    /// halfway through when Ctrl-C was pressed still finishes, and the
    /// answer it sends has to admit that the socket is about to go. A
    /// client told `keep-alive` by a process that is leaving spends its
    /// next request finding out otherwise.
    pub fn keepAlive(self: *const Ctx) bool {
        if (self._force_close) return false;
        if (!self._request.keep_alive) return false;
        return !self.stopping();
    }

    /// Whether the server has been told to stop and is draining. What the
    /// health route answers `stopping` on (ADR 154).
    pub fn stopping(self: *const Ctx) bool {
        const flag = self._stopping orelse return false;
        return flag.load(.acquire);
    }

    /// Whether this request arrived over HTTP/2, whose answer is collected
    /// whole and framed by the connection's fiber (ADR 259). Comptime-false in
    /// a build without `-Dhttp2`, so the calls below that ask it cost that
    /// build nothing.
    fn onHttp2(self: *const Ctx) bool {
        if (comptime !framing_mod.http2_built) return false;
        return self._framing == .http2;
    }

    /// What HTTP/2 does not carry, a WebSocket: a 500 whose sentence names the
    /// call and says it is HTTP/1.1's, and a `warn` line saying the same where
    /// the developer reads. Never a 501, which would read as the route's own
    /// answer (ADR 259, ADR 260). A fail function, so the sentence reaches the
    /// client in the failure body every other failure uses (ADR 006, ADR 024).
    ///
    /// `noinline`, because a format string costs stack in whatever frame it is
    /// inlined into (ADR 062).
    noinline fn notOnHttp2(self: *const Ctx, comptime what: []const u8, comptime hint: []const u8) fail.Error {
        std.log.warn("{s} {s}: {s} is HTTP/1.1 only; answered 500", .{ @tagName(self.method), self._path, what });
        return fail.internal(what ++ " is HTTP/1.1 only: " ++ hint, .{});
    }

    /// The refusal of a streamed answer, an event stream or a file in a gRPC
    /// call, which answers one message and has no pipe to the connection for
    /// more (ADR 220, ADR 260). Every other request on HTTP/2 streams as one
    /// on HTTP/1.1 does. A fail function, so the sentence reaches the client
    /// as every failure does (ADR 006), and `noinline` for the reason
    /// `notOnHttp2` is.
    noinline fn notInCall(self: *const Ctx, comptime what: []const u8) fail.Error {
        std.log.warn("{s} {s}: {s} is not available in a gRPC call; answered 500", .{ @tagName(self.method), self._path, what });
        return fail.internal(what ++ " is not available in a gRPC call: a call answers one message, so its answer is whole. Answer it with c.send().", .{});
    }

    /// Whether the answer can be streamed: a request's can on either framing,
    /// and a gRPC call's cannot. Called by `sendfile.zig` where the body is
    /// about to be written, and by `stream` and `events` (ADR 260).
    pub fn refuseFileInCall(self: *const Ctx) !void {
        if (self.onHttp2() and !self._framing.canStream()) return self.notInCall("c.sendFile()");
    }

    // ---- the response side ----

    /// Add a response header. Set it before sending: an answer is written
    /// when it is sent, unless a middleware holds it with `next.hold(c)`, and
    /// a header set once the head is written is refused with a sentence
    /// saying so rather than lost (ADR 008).
    ///
    /// `name` and `value` are copied into the request arena, so passing a
    /// value you built on the stack is safe. Setting a header the
    /// framework writes itself — Content-Type, Content-Length, Connection
    /// — is refused: a response carrying two of those is malformed, and in
    /// the case of Content-Length it is a request-smuggling bug.
    /// Content-Type is chosen through `send` instead.
    ///
    /// **A value carrying `\r`, `\n` or `\0` is refused** with
    /// `error.BadHeaderValue`, and a name that is not a token with
    /// `error.BadHeaderName`: those bytes end the header line rather than
    /// sitting in it, so a value built from request data would write the rest
    /// of the response itself (`http1.headerValueOk` has the shape).
    pub fn setHeader(self: *Ctx, name: []const u8, value: []const u8) !void {
        return self.putHeader(.{
            .name = try self._arena.dupe(u8, name),
            .value = try self._arena.dupe(u8, value),
        });
    }

    /// `setHeader` for text that already outlives the request — a literal,
    /// or something a Service owns — so nothing is copied.
    ///
    /// This is what the built-in middleware use: CORS's header values are
    /// compile-time constants and a static file's ETag belongs to the file,
    /// so copying either into the request arena is work with no purpose.
    ///
    /// Hand it something built on the stack and the response goes out with
    /// whatever those bytes have become. When in doubt, `setHeader`.
    pub fn setStaticHeader(self: *Ctx, name: []const u8, value: []const u8) !void {
        return self.putHeader(.{ .name = name, .value = value });
    }

    /// The response headers added so far, in the order they were set.
    pub fn extraHeaders(self: *const Ctx) []const http1.Header {
        if (self._extra_spill.items.len > 0) return self._extra_spill.items;
        return self._extra_inline[0..self._extra_n];
    }

    /// Take back what the headers said about an answer that is not going
    /// out, because a failure is replacing it (`http1.describesAnswer`,
    /// ADR 024). In place and in order; nothing is allocated or freed.
    pub fn forgetAnswerHeaders(self: *Ctx) void {
        const all = self.extraHeadersMutable();
        var kept: usize = 0;
        for (all) |h| {
            if (http1.describesAnswer(h.name, h.value)) continue;
            all[kept] = h;
            kept += 1;
        }
        if (self._extra_spill.items.len > 0) {
            self._extra_spill.shrinkRetainingCapacity(kept);
        } else {
            self._extra_n = kept;
        }
    }

    fn extraHeadersMutable(self: *Ctx) []http1.Header {
        if (self._extra_spill.items.len > 0) return self._extra_spill.items;
        return self._extra_inline[0..self._extra_n];
    }

    /// The content type is written into the head beside the headers
    /// `putHeader` checks, and never passes through it, since it is chosen
    /// through `send`, `streamWith` or a file body rather than set. It gets
    /// the same value check, before the response is marked answered so the
    /// refusal can still go out: a MIME type stored from an upload or passed
    /// on from upstream is request data like any other header value.
    pub fn contentTypeOk(self: *const Ctx, content_type: []const u8) !void {
        _ = self;
        if (!http1.headerValueOk(content_type)) return fail.internal(
            "the content type holds a character a header value cannot: a control byte, most " ++
                "often a carriage return or a newline, which would end the header early and " ++
                "start one nobody wrote. It is refused rather than escaped; strip it where the " ++
                "type came from.",
            .{},
        );
    }

    /// Every response header goes through here — `setHeader`,
    /// `setStaticHeader`, `setCookie`, a `Response`'s or a `Redirect`'s
    /// `.headers`, and the built-in middleware. **One choke point on purpose**,
    /// for `aboutToRead`'s reason: a new way to set a header gets the checks
    /// below without anybody remembering to give it one (ADR 029).
    ///
    /// All three refusals are a mistake in the server rather than in the
    /// request, so all three are `fail.internal` — a 500 that says which
    /// header and why, the way `setCookie` has always answered a `;` in a
    /// cookie value. A bare error here would arrive as "internal server
    /// error" and send somebody looking through their handler for it.
    fn putHeader(self: *Ctx, entry: http1.Header) !void {
        try self.headStillOpen(entry.name);
        try checkHeader(entry);
        // Setting a header twice is somebody changing their mind, so the
        // second call replaces the first — except for the two a response may
        // legitimately carry more than one of (`http1.repeats`).
        if (!http1.repeats(entry.name)) {
            for (self.extraHeadersMutable()) |*h| {
                // `nilo.secure`'s block, which may hold a line for this name:
                // the header being set replaces that line, as it would a
                // header set on its own (ADR 246). Through the pointer
                // `putPolicy` left, so an App with no `nilo.secure` links none
                // of the matching.
                if (h.name.len == 0) {
                    if (self._policy_edit) |edit| h.value = try edit(self._arena, h.value, entry.name);
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(h.name, entry.name)) {
                    h.* = entry; // last one wins, rather than sending both
                    return;
                }
            }
        } else {
            // A repeating header naming something already named is nothing —
            // not a second fact, just the same one twice. Dropping it keeps
            // `Vary: Origin, Vary: Origin` off a response when two middlewares
            // both depend on the origin, and keeps the count inside the six
            // held on the Ctx, which is where the allocation budget lives
            // (ADR 029). Never reached by `Set-Cookie` in practice: two
            // cookies that agree on name *and* value are one cookie.
            for (self.extraHeaders()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, entry.name) and
                    std.mem.eql(u8, h.value, entry.value)) return;
            }
        }

        return self.appendHeader(entry);
    }

    /// `nilo.secure`'s headers: a block of whole lines assembled while
    /// compiling, kept as one entry with no name and written as it is
    /// ([ADR 246](../docs/adr/246-the-headers-a-browser-reads-as-policy-are-one-block.md)).
    /// One slot of the seven held on the Ctx however many lines the block has,
    /// so a policy of seven headers does not push CORS and gzip into the
    /// arena. A second block replaces the first, which is how a group
    /// installs a policy of its own over the App's.
    ///
    /// The framework's own: `block` is checked line by line while compiling,
    /// which is the only reason it may skip `checkHeader`.
    pub fn putPolicy(self: *Ctx, block: []const u8) !void {
        try self.headStillOpen("the nilo.secure block");
        self._policy_edit = &policyWithout;
        for (self.extraHeadersMutable()) |*h| {
            if (h.name.len == 0) {
                h.value = block;
                return;
            }
        }
        return self.appendHeader(.{ .name = "", .value = block });
    }

    /// `block` without its line for `name`, when `name` is one of the headers
    /// a block holds; `block` itself otherwise. What `putHeader` calls when a
    /// handler sets a header the policy already sent.
    fn policyWithout(gpa: std.mem.Allocator, block: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
        if (!http1.isPolicyHeader(name)) return block;
        return http1.withoutLine(gpa, block, name);
    }

    /// A header set once the head has gone is refused with a sentence, where
    /// it used to be added to a list nothing would write again and lost
    /// without a word, the way Go and Gin lose one.
    fn headStillOpen(self: *const Ctx, name: []const u8) !void {
        if (!self._head_written) return;
        return refuseField(name, "is a header set after the head of this answer was written, so it " ++
            "has nowhere to go. Set it before the answer is sent; a middleware that changes an answer " ++
            "after `next` calls `next.hold(c)` instead of `next.run(c)`.");
    }

    /// A refusal that names a field and says why, through one format. Every
    /// refusal of a header or a trailer starts with the field's name, and a
    /// format shared is what keeps them from being one copy each of the
    /// formatting code (ADR 017's size axis).
    noinline fn refuseField(name: []const u8, sentence: []const u8) fail.Error {
        return fail.internal("\"{s}\" {s}", .{ name, sentence });
    }

    fn appendHeader(self: *Ctx, entry: http1.Header) !void {
        if (self._extra_spill.items.len > 0) {
            return self._extra_spill.append(self._arena, entry);
        }
        if (self._extra_n < inline_headers) {
            self._extra_inline[self._extra_n] = entry;
            self._extra_n += 1;
            return;
        }
        // The fifth one. The inline four move across so the list stays in one
        // piece — whoever writes the response wants a single slice.
        try self._extra_spill.ensureTotalCapacity(self._arena, inline_headers * 2);
        self._extra_spill.appendSliceAssumeCapacity(&self._extra_inline);
        self._extra_spill.appendAssumeCapacity(entry);
    }

    /// The checks `putHeader` makes, on their own: whether `setHeader` would
    /// refuse this header, and the same 500 if so. For a caller that keeps an
    /// answer to send again (`Cached`, `Idempotent`) and has to know before
    /// it is kept, because a kept refusal is replayed until it expires
    /// (ADR 155, ADR 188).
    pub fn checkHeader(entry: http1.Header) !void {
        if (http1.isReservedHeader(entry.name)) return refuseField(entry.name, "is a header nilo writes " ++
            "itself, so setting it would send the response two of them — which is malformed, and " ++
            "for Content-Length is a request-smuggling bug. The content type is chosen through " ++
            "`send`; the other three are the framing and are not yours to set.");
        // gRPC reads its status after the message, and a client that found it
        // among the headers would take the call as over before its answer.
        if (std.ascii.eqlIgnoreCase(entry.name, "grpc-status") or
            std.ascii.eqlIgnoreCase(entry.name, "grpc-message")) return refuseField(entry.name, "is a trailer: " ++
            "gRPC reads it after the message, so it is set with `c.setTrailer`. A failure needs " ++
            "neither: `return error.AlreadyExists`, or a fail function, is answered with the " ++
            "matching code (ADR 220).");
        return checkBytes(entry);
    }

    /// What a header and a trailer are both held to: a name that is a token,
    /// and a value with nothing in it that ends a line.
    fn checkBytes(entry: http1.Header) !void {
        if (!http1.headerNameOk(entry.name)) return refuseField(entry.name, "is not a name a header can " ++
            "have — a field name is letters, digits, and any of !#$%&'*+-.^_`|~");
        // The value is **not** quoted into the message. It is the half most
        // likely to have come from a request, a row or a filename, and a
        // response that echoed it back would hand the sender a way to read
        // what the check caught.
        if (!http1.headerValueOk(entry.value)) return fail.internal(
            "the value of the header \"{s}\" holds a character a header value cannot: a control " ++
                "byte, most often a carriage return or a newline. Either one ends the header " ++
                "early and starts a second one nobody wrote, and two of them start a second " ++
                "response — so this is refused rather than escaped, because there is no " ++
                "escaping in this grammar to do it with. Percent-encode the value, or strip it.",
            .{entry.name},
        );
    }

    /// Send a cookie back with this response (ADR 029).
    ///
    /// ```zig
    /// try c.setCookie(.{ .name = "session", .value = token });
    /// ```
    ///
    /// The defaults are the careful ones — `Secure`, `HttpOnly`,
    /// `SameSite=Lax`, `Path=/` — so turning a protection off is a visible
    /// line rather than a forgotten one. See `nilo.Cookie` for the rest.
    ///
    /// Calling this twice sets two cookies rather than replacing the first,
    /// which is the one way `Set-Cookie` differs from every other response
    /// header. Costs **one arena allocation per cookie**, sized exactly.
    ///
    /// A cookie nilo cannot write — a value with a `;` in it, which would
    /// smuggle an attribute nobody wrote — is a 500 saying which character
    /// and why, because it is a mistake in the server rather than in the
    /// request.
    pub fn setCookie(self: *Ctx, c: cookie_mod.Cookie) !void {
        cookie_mod.check(c) catch |err| return switch (err) {
            error.CookieNameEmpty => fail.internal("a cookie has to have a name", .{}),
            error.CookieNameInvalid => fail.internal(
                "\"{s}\" is not a name a cookie can have — a cookie name is letters, digits, " ++
                    "and any of !#$%&'*+-.^_`|~",
                .{c.name},
            ),
            error.CookieValueInvalid => fail.internal(
                "the value of the cookie \"{s}\" holds a character a cookie value cannot: a " ++
                    "space, a comma, a semicolon, a quote, a backslash or a control byte. A " ++
                    "semicolon would start an attribute nobody wrote, so this is refused rather " ++
                    "than escaped — encode the value (base64, or percent) before setting it.",
                .{c.name},
            ),
            error.CookieAttributeInvalid => fail.internal(
                "the path, domain or expiry of the cookie \"{s}\" holds a semicolon or a " ++
                    "control byte, which would end that attribute and start one nobody wrote. " ++
                    "Refused rather than escaped: a path built from the request's own is the " ++
                    "usual way it gets there.",
                .{c.name},
            ),
            error.CookieNeedsSecure => fail.internal(
                "the cookie \"{s}\" asks for SameSite=None without Secure, and browsers drop " ++
                    "that combination outright",
                .{c.name},
            ),
        };

        // Sized from `lengthOf`, so this is one allocation and the writer
        // below cannot run out of room. A test holds the two together.
        const buf = try self._arena.alloc(u8, cookie_mod.lengthOf(c));
        var out: std.Io.Writer = .fixed(buf);
        cookie_mod.write(&out, c) catch unreachable;
        return self.putHeader(.{ .name = "Set-Cookie", .value = out.buffered() });
    }

    /// Delete a cookie the browser is holding.
    ///
    /// ```zig
    /// try c.clearCookie(.{ .name = "session" });
    /// ```
    ///
    /// A browser matches a deletion on the name, the path **and** the
    /// domain, so a cookie set under `/admin` is not cleared by a deletion
    /// at the default `/` — and nothing anywhere reports that it was not.
    /// Pass the same path and domain the cookie was set with.
    pub fn clearCookie(self: *Ctx, clearing: cookie_mod.Clearing) !void {
        return self.setCookie(cookie_mod.deletion(clearing));
    }

    /// Send the client somewhere else (ADR 031).
    ///
    /// ```zig
    /// try c.redirect(303, "/welcome");
    /// ```
    ///
    /// A handler that knows its status while it is being written returns
    /// `nilo.Redirect(303)` instead, which is the same response and lets
    /// the generated API description name it.
    pub fn redirect(self: *Ctx, status: u16, location: []const u8) !void {
        if (location.len == 0) return fail.internal(
            "a redirect has to say where to — `c.redirect({d}, …)` was given nothing",
            .{status},
        );
        if (status < 300 or status > 399) return fail.internal(
            "{d} is not a redirect status, so a Location on it means nothing to a client",
            .{status},
        );
        try self.setHeader("Location", location);
        // No body. A browser follows the Location and never looks, and the
        // handful of clients that do not are better served by the status
        // than by a paragraph of HTML nobody maintains.
        return self.sendEmpty(status);
    }

    /// **A second answer is `error.AlreadyAnswered`, not an assert.** A
    /// middleware that answers an error after the handler's own write failed
    /// is an ordinary thing to write, and the assert panicked a ReleaseSafe
    /// build and wrote a second response in ReleaseFast. The first answer
    /// stands, and App closes the connection, because a half-sent response
    /// cannot be taken back (the audit of `http/` at `39896d2`).
    ///
    /// **Under a middleware that called `next.hold(c)` the body is copied into
    /// the request arena** and written when the chain has unwound: the
    /// handler's frame, and whatever its `defer`s gave back, are gone by
    /// then. That copy is the one cost holding has, and it is the body's
    /// size: free while it fits in what the arena keeps (16 KiB), and 63% of
    /// throughput at 64 KiB in the run that settled it (ADR 008). An answer
    /// the typed layer sends from a returned value is not copied.
    pub fn send(self: *Ctx, status: u16, content_type: []const u8, response_body: []const u8) !void {
        return self.sendWhole(status, content_type, response_body, false, false);
    }

    /// `send`, for a body that outlives the middleware chain already: one in
    /// the request arena, or one a typed handler returned, whose frame was
    /// gone before it was sent whether or not anything holds. Not copied
    /// when a middleware holds the answer.
    pub fn sendKept(self: *Ctx, status: u16, content_type: []const u8, response_body: []const u8) !void {
        return self.sendWhole(status, content_type, response_body, true, false);
    }


    fn sendWhole(self: *Ctx, status: u16, content_type: []const u8, response_body: []const u8, kept: bool, owned: bool) !void {
        if (self.answered() != null) return error.AlreadyAnswered; // one request, one response
        try self.contentTypeOk(content_type);
        self.markAnswered(status);
        if (self._hold) return self.holdWhole(status, content_type, response_body, kept, owned, true);
        return self.deliverWhole(status, content_type, response_body, true, owned);
    }

    /// A whole answer compressed where it qualifies, then put on the wire.
    fn deliverWhole(self: *Ctx, status: u16, content_type: []const u8, response_body: []const u8, compress: bool, owned: bool) !void {
        // Gzipped, when the App asked for that and this body and this client
        // both qualify (ADR 211). Before the wait below rather than inside
        // it: compressing is the handler's work, and it borrows a compressor
        // nothing waiting on a client may hold.
        var outgoing = response_body;
        var in_arena = owned;
        if (compress) if (self._compressors) |pool| {
            if (try self.squeezed(pool, status, content_type, response_body)) |smaller| {
                outgoing = smaller;
                in_arena = true;
            }
        };

        // Putting the answer on the wire is nilo waiting on the client, not
        // the handler running. A client too slow to take a large response
        // parks this fiber for as long as it takes, and without this that
        // would be reported as a handler holding its thread (ADR 013).
        const w = watchdog.waiting(self._watch);
        defer watchdog.waited(self._watch, w);
        self.armWriteLimit();

        try self.putWhole(status, content_type, outgoing, in_arena);
    }

    /// A whole answer App makes itself (a 404, an empty 200, a failure),
    /// held like any other when a middleware holds the answer, and written
    /// otherwise. `send` and these both end in `putWhole`, so there is one
    /// way out.
    pub fn writeWhole(self: *Ctx, status: u16, content_type: []const u8, response_body: []const u8) !void {
        if (self._hold) return self.holdWhole(status, content_type, response_body, false, false, false);
        return self.putWhole(status, content_type, response_body, false);
    }

    /// A whole answer handed to the framing, with the headers middleware and
    /// the handler set and the trailers after it. A handler need not know
    /// this is a HEAD: it assembles a response as usual, and what must not go
    /// out is filtered by the framing. The length is the one a GET would have
    /// carried.
    fn putWhole(self: *Ctx, status: u16, content_type: []const u8, response_body: []const u8, kept: bool) !void {
        self._head_written = true;
        self._body_ended = true;
        try self._framing.whole(status, content_type, response_body, kept, self.method == .HEAD, self.keepAlive(), self.extraHeaders(), self.trailersOut());
    }

    /// Keep a whole answer for the chain's end, copied unless it outlives the
    /// chain already.
    fn holdWhole(self: *Ctx, status: u16, content_type: []const u8, response_body: []const u8, kept: bool, owned: bool, compress: bool) !void {
        const held = try self.heldSlot();
        held.* = .{ .whole = .{
            .status = status,
            .content_type = try self._arena.dupe(u8, content_type),
            .body = if (kept) response_body else try self._arena.dupe(u8, response_body),
            .compress = compress,
            // A copy is in the arena, and so is what the caller said is.
            .owned = owned or !kept,
        } };
    }

    /// Where a held answer goes: the one already there when an answer is
    /// being replaced, so a request holds at most one.
    pub fn heldSlot(self: *Ctx) !*Held {
        if (self._held) |held| return held;
        const held = try self._arena.create(Held);
        self._held = held;
        return held;
    }

    /// Write what a middleware held, now that the chain has unwound, and
    /// stop holding: App's own answers after this go straight out.
    pub fn releaseHeld(self: *Ctx) !void {
        self._hold = false;
        const held = self._held orelse return;
        self._held = null;
        switch (held.*) {
            .whole => |w| try self.deliverWhole(w.status, w.content_type, w.body, w.compress, w.owned),
            .file => |f| try sendfile_mod.writeHeld(self, f),
        }
    }

    /// Let go of a held answer a failure is replacing. Nothing of it has
    /// been written, so the request reads as unanswered again and the
    /// failure goes out in its place.
    pub fn dropHeld(self: *Ctx) void {
        self._hold = false;
        const held = self._held orelse return;
        self._held = null;
        if (held.* == .file) held.file.contents.file.close();
        self._sent = false;
        self._status = 0;
    }

    /// The trailers for a whole answer, and whether the client said it reads
    /// them, worked out only when there are some.
    fn trailersOut(self: *const Ctx) framing_mod.Trailers {
        if (self._trailers.list.items.len == 0) return .{};
        return self._trailers.out(self.clientReadsTrailers());
    }

    /// Whether the client said it reads trailers: a `TE` naming `trailers`
    /// (RFC 9110 §10.1.4). What decides whether a whole HTTP/1.1 answer with
    /// trailers is chunked to carry them (ADR 254).
    pub fn clientReadsTrailers(self: *const Ctx) bool {
        const te = self.header("TE") orelse return false;
        var parts = std.mem.splitScalar(u8, te.view(), ',');
        while (parts.next()) |part| {
            const coding = part[0 .. std.mem.indexOfScalar(u8, part, ';') orelse part.len];
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, coding, " \t"), "trailers")) return true;
        }
        return false;
    }

    /// Add a trailer: a field sent after the body, for what is known only
    /// once the body is (ADR 254).
    ///
    /// ```zig
    /// try c.setTrailer("Server-Timing", "db;dur=12");
    /// ```
    ///
    /// **Settable until the body ends, on every framing alike**: before
    /// `send` for a whole answer, before `finish` for a stream, and after
    /// `next` from a middleware that called `next.hold(c)`. HTTP/2 sends it
    /// after the body; a chunked HTTP/1.1 stream as a trailer section; a
    /// whole HTTP/1.1 answer chunked to carry it when the client sent
    /// `TE: trailers`, and without it otherwise, which a client that never
    /// asked could not have read anyway (RFC 9110 §6.5.1).
    ///
    /// Copied into the request arena, as `setHeader` copies. Refused: a name
    /// RFC 9110 §6.5.1 keeps out of trailers (the framing, the route,
    /// authentication, a cache rule, the content's type and encoding), and
    /// anything `setHeader` would refuse for its bytes.
    pub fn setTrailer(self: *Ctx, name: []const u8, value: []const u8) !void {
        if (self._body_ended) return refuseField(name, "is a trailer set after the body ended, so it has " ++
            "nowhere to go. Set it before `send`, before a stream's `finish`, or from a middleware " ++
            "that called `next.hold(c)` rather than `next.run(c)`.");
        try checkTrailer(.{ .name = name, .value = value });
        const entry: http1.Header = .{
            .name = try self._arena.dupe(u8, name),
            .value = try self._arena.dupe(u8, value),
        };
        for (self._trailers.list.items) |*t| {
            if (std.ascii.eqlIgnoreCase(t.name, name)) {
                t.* = entry; // last one wins, as a header set twice
                return;
            }
        }
        try self._trailers.list.append(self._arena, entry);
        self._trailers.writers = &framing_mod.writers;
    }

    /// The checks `setTrailer` makes on a field, on their own, for a caller
    /// that keeps an answer to send again and has to know first (ADR 155).
    pub fn checkTrailer(entry: http1.Header) !void {
        if (http1.barredFromTrailer(entry.name)) return refuseField(entry.name, "cannot be a trailer: it says " ++
            "something a client needs before the body (its framing, its route, its format, a cache " ++
            "or authentication rule), and RFC 9110 §6.5.1 lets a client drop or misread it after. " ++
            "Set it with `setHeader`.");
        return checkBytes(entry);
    }

    /// The trailers set so far, in the order they were set.
    pub fn trailers(self: *const Ctx) []const http1.Header {
        return self._trailers.list.items;
    }

    /// The compressed body, when this answer is one to compress: long
    /// enough, text, not already encoded by the handler, and going to a
    /// client that asked. Null otherwise, and the body goes out as it is.
    ///
    /// `Vary: Accept-Encoding` goes out on every answer that *could* have
    /// been compressed, whether or not this client wanted it: a shared cache
    /// that stored the plain answer without it would hand that answer to the
    /// next client whatever it asked for (ADR 029). `Content-Encoding` only
    /// when it was.
    fn squeezed(self: *Ctx, pool: *const compress_mod.Pool, status: u16, content_type: []const u8, response_body: []const u8) !?[]const u8 {
        // A static file chose its representation already: the copy gzipped
        // at load, or the plain one because no copy was worth holding, or a
        // range, which is an offset into the plain bytes. Its ETag names
        // that choice, so gzipping here would put one tag on two bodies.
        if (self._static_file != null) return null;
        if (!pool.eligible(status, content_type, response_body.len)) return null;
        // What the handler said about this representation stands. A
        // `Content-Encoding` of its own means it gzipped the body itself (a
        // cached copy, a file it read compressed), and it is not compressed
        // twice. A `Content-Range` is an offset into the plain bytes, and
        // `Cache-Control: no-transform` is the handler forbidding exactly
        // this (ADR 211).
        for (self.extraHeaders()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Content-Encoding")) return null;
            if (std.ascii.eqlIgnoreCase(h.name, "Content-Range")) return null;
            if (std.ascii.eqlIgnoreCase(h.name, "Cache-Control") and compress_mod.forbidsTransform(h.value)) return null;
        }
        try self.setStaticHeader("Vary", "Accept-Encoding");
        const accept = if (self.header("Accept-Encoding")) |h| h.view() else null;
        if (!compress_mod.acceptsGzip(accept)) return null;

        const smaller = pool.gzip(self._arena, response_body) orelse return null;
        try self.weakenETag();
        try self.setStaticHeader("Content-Encoding", "gzip");
        return smaller;
    }

    /// A strong `ETag` promises the same bytes, and the gzipped body and the
    /// plain one are different bytes, so the tag a handler set for the plain
    /// body is made weak once the answer goes out gzipped (RFC 9110
    /// section 8.8.1; `static.zig` gives the two bodies two tags for the same
    /// reason). One arena allocation, and only on an answer that carries a
    /// strong tag and was compressed.
    fn weakenETag(self: *Ctx) !void {
        for (self.extraHeaders()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "ETag")) continue;
            if (std.mem.startsWith(u8, h.value, "W/")) return;
            const weak = try self._arena.alloc(u8, h.value.len + 2);
            @memcpy(weak[0..2], "W/");
            @memcpy(weak[2..], h.value);
            return self.setStaticHeader("ETag", weak);
        }
    }

    pub fn sendText(self: *Ctx, status: u16, text: []const u8) !void {
        try self.send(status, "text/plain", text);
    }

    /// A response with no body at all — a 204 after a DELETE, mostly. What a
    /// handler returning `void` becomes.
    ///
    /// No `Content-Type`, because there is no content to give a type to. On
    /// a 204 there is no `Content-Length` either; that is not this function's
    /// doing but the status's, and `http1.bodyless` is where it is decided.
    pub fn sendEmpty(self: *Ctx, status: u16) !void {
        try self.send(status, "", "");
    }

    /// Serialise `value` to JSON (through the request arena) and send it.
    ///
    /// The buffer starts at `json_hint` rather than at nothing, so a
    /// response of ordinary size is assembled in one allocation instead of
    /// a handful of doublings. Overshooting costs nothing: the arena is
    /// emptied when the request ends either way.
    ///
    /// The serialising itself is `json.write`, which produces exactly what
    /// `std.json` would and is several times quicker at it for the shapes a
    /// handler returns.
    pub fn sendJson(self: *Ctx, status: u16, value: anytype) !void {
        var out: std.Io.Writer.Allocating = try .initCapacity(self._arena, json_hint);
        try json_mod.write(&out.writer, value);
        try sendOwned(self, status, "application/json", out.written());
    }

    /// Answer with an open file, without ever holding it in memory
    /// (ADR 009).
    ///
    /// ```zig
    /// const invoice = try files.dir.openFile(name);
    /// try c.sendFile(.{ .file = invoice, .content_type = "application/pdf" });
    /// ```
    ///
    /// **The file is closed here**, on every way out: a 304, a 416, a HEAD,
    /// a whole file, part of one, or a client that walks away mid-transfer.
    /// The caller opens it and hands it over; after this call it is gone.
    ///
    /// Everything a static file's answer carries, this carries too: `ETag`,
    /// `Cache-Control`, `Accept-Ranges`, a 304, a 206 with `Content-Range`,
    /// and `If-Range` checked so a resumed download of a changed file starts
    /// again rather than arriving corrupt (ADR 020). The bytes go from the
    /// file to the socket without passing through this process.
    ///
    /// A handler that knows it is answering with a file before it runs
    /// returns `nilo.FileBody` instead, which is the same response and
    /// lets the generated API description say so (ADR 031's move for
    /// redirects, applied here).
    pub fn sendFile(self: *Ctx, contents: sendfile_mod.Contents) !void {
        return sendfile_mod.send(self, contents);
    }

    // ---- answering in pieces ----

    /// Start a response whose length is not known yet, and get back
    /// something to write the pieces into (ADR 019).
    ///
    /// ```zig
    /// var body = try c.stream(200, "text/csv");
    /// for (rows) |row| try body.print("{s},{d}\n", .{ row.name, row.total });
    /// try body.finish();
    /// ```
    ///
    /// The head goes out immediately, so every `setHeader` has to be called
    /// before this. `finish()` is required: it writes the marker saying
    /// where the body ends.
    ///
    /// A status with no body (204, 304, any 1xx) is refused with a 500 that
    /// says so, before anything is written.
    pub fn stream(self: *Ctx, status: u16, content_type: []const u8) !stream_mod.Stream {
        return self.streamWith(status, content_type, .{});
    }

    /// `stream`, with the buffer size turned up or down — and with the body's
    /// length, for a handler that already knows it.
    ///
    /// ```zig
    /// const object = try bucket.stream(c, key);
    /// var body = try c.streamWith(200, object.content_type, .{ .length = object.len });
    /// ```
    ///
    /// See `stream.Options.length`: a promised length is a `Content-Length`
    /// rather than chunked framing, and it is held to
    /// ([ADR 101](../docs/adr/101-a-stream-that-knows-its-length-says-so.md)).
    pub fn streamWith(
        self: *Ctx,
        status: u16,
        content_type: []const u8,
        options: stream_mod.Options,
    ) !stream_mod.Stream {
        if (self.answered() != null) return error.AlreadyAnswered; // one request, one response, as `send`
        if (self.onHttp2() and !self._framing.canStream()) return self.notInCall("c.stream()");
        try self.contentTypeOk(content_type);
        // `writeHead` drops the framing for these, so the chunks that
        // followed would be read as the next response (ADR 019).
        if (http1.bodyless(status)) return fail.internal(
            "the handler streams a {d}, a status that has no body: the head cannot carry " ++
                "the chunked framing or the length a stream needs, so what it wrote next " ++
                "would be read as the start of the next response. Answer it with " ++
                "`c.send({d}, …)` and no body, or stream under a status that has one.",
            .{ status, status },
        );

        // How the body is told apart from the next answer is the framing's.
        // One that only the connection closing can end means that connection
        // cannot carry another request whatever either side asked for.
        var shape = self._framing.streamShape(options.length);
        if (shape.ends_connection) self._force_close = true;
        // Only HTTP/2 needs to know before the body ends, and a default build has no such arm.
        if (comptime framing_mod.http2_built) shape.bodyless = self.method == .HEAD;

        self.markAnswered(status);
        self.tookOver();
        self._stream = .{
            .chunked = shape.chunked,
            .drop = self.method == .HEAD,
            .promised = options.length,
        };

        // A stream's head cannot wait for the chain, held or not: the body
        // follows it now. What a holding middleware can still change is the
        // end, and the trailers that go with it.
        self._head_written = true;
        try self._framing.streamHead(status, content_type, shape, options.length, self.keepAlive(), self.extraHeaders());

        // The one allocation a stream makes, made once. Everything written
        // afterwards goes through this buffer and allocates nothing.
        const buffer = try self._arena.alloc(u8, options.buffer);
        var out: stream_mod.Stream =
            .initClosing(buffer, &self._framing, self._stopping, &self._stream, &self._force_close);
        out._watch = self._watch;
        out._trailers = &self._trailers;
        out._hold = &self._hold;
        out._ended = &self._body_ended;
        return out;
    }

    /// Turn this request into a WebSocket connection (ADR 021, ADR 062).
    ///
    /// ```zig
    /// fn echo(c: *nilo.Ctx) !void {
    ///     return c.upgrade(echoLoop, {});
    /// }
    ///
    /// fn echoLoop(socket: *nilo.Socket) !void {
    ///     while (try socket.receive()) |message| {
    ///         try socket.send(message.kind, message.data);
    ///     }
    /// }
    /// ```
    ///
    /// The loop is a function rather than the tail of the handler so the
    /// request can unwind first: a suspended fiber holds every byte of stack
    /// it ever touched, and that is 9,290 bytes an idle socket against 5,183
    /// (ADR 062).
    ///
    /// `state` is what the handler knows and the loop needs — a name off the
    /// query, the room this path belongs to. Pass `{}` when there is nothing.
    /// It is copied into the connection's frame, so it may be up to
    /// `websocket.state_max` bytes; anything bigger goes in the request arena
    /// (which outlives the handler, and the loop) with a pointer carried here.
    ///
    /// A request that is not asking to be upgraded is refused with a 400
    /// saying which part is missing, rather than left to fail as framing
    /// nobody can read.
    ///
    /// After this the connection is no longer HTTP and cannot carry another
    /// request, which nilo arranges — the handler only has to return.
    pub fn upgrade(self: *Ctx, comptime loop: anytype, state: anytype) !void {
        return self.upgradeWith(loop, state, .{});
    }

    /// `upgrade`, naming a sub-protocol, a ping interval or a message ceiling.
    pub fn upgradeWith(
        self: *Ctx,
        comptime loop: anytype,
        state: anytype,
        options: websocket.Options,
    ) !void {
        const State = @TypeOf(state);
        comptime websocket.checkLoop(loop, State);

        var socket = try self.handshake(options);

        // No connection loop to hand it to — a `Ctx` built by hand in a test,
        // with nothing above it that will ever run this. Running it here is
        // the same conversation on a deeper stack, which is exactly what this
        // call exists to avoid and exactly what a test does not care about.
        const slot = self._handover orelse {
            const carried = state;
            return websocket.runner(loop, State)(&socket, @ptrCast(&carried));
        };

        slot.* = .{ .socket = .{
            .socket = socket,
            .run = websocket.runner(loop, State),
            .path = self._path,
        } };
        if (@sizeOf(State) > 0) {
            const carried: *State = @ptrCast(@alignCast(&slot.socket.state));
            carried.* = state;
        }
    }

    /// The handshake itself: check the request is really one, answer 101, and
    /// build the Socket. Split out from `upgrade` because both the connection
    /// loop and a hand-built `Ctx` need it and only one of them hands the loop
    /// back.
    fn handshake(self: *Ctx, options: websocket.Options) !websocket.Socket {
        if (self.answered() != null) return error.AlreadyAnswered; // one request, one response, as `send`

        if (self.method != .GET) {
            return fail.badRequest("a WebSocket handshake has to be a GET, not a {s}", .{@tagName(self.method)});
        }
        // A WebSocket takes its connection for the rest of its life, and an
        // HTTP/2 stream has none of its own to give: WebSockets over HTTP/2
        // (RFC 8441) are not served (ADR 253).
        if (self.onHttp2()) return self.notOnHttp2(
            "c.upgrade()",
            "a WebSocket is HTTP/1.1, which a browser falls back to by itself. RFC 8441 is not served.",
        );
        const wire = self._framing.wire().?;
        if (!websocket.isUpgrade(self._head)) {
            return fail.badRequest(
                "this endpoint is a WebSocket; the request needs Upgrade: websocket and Connection: Upgrade",
                .{},
            );
        }
        // Only once the handshake is real: from here a Socket is going to read
        // from the connection for as long as it lives, so the head must have
        // been copied out of the read buffer. `Request.upgrade` is what told
        // `handleRequest` to copy it, and it is deliberately the looser of the
        // two tests — anything `isUpgrade` accepts, it accepted first.
        self.aboutToRead();
        // Before anything else about the handshake, because which page is
        // asking decides whether there is a handshake to have. A browser
        // applies no CORS to a WebSocket and sends no preflight, so nothing in
        // front of this refuses a cross-site page — and the handshake is an
        // ordinary GET, so it arrives carrying the session cookie. Same-origin
        // unless the route named somebody; `websocket.Options.origins` is the
        // whole account.
        if (self.header("Origin")) |origin| {
            // The `Host` header itself, deliberately, and not `host()`: that
            // one reads `X-Forwarded-Host` from a trusted proxy, and what
            // this compares has to be the authority the request really named
            // (ADR 080).
            const authority = if (self.header("Host")) |h| h.view() else "";
            if (!websocket.originAllowed(origin.view(), authority, options.origins)) {
                return fail.forbidden(
                    "this WebSocket answers \"{s}\" and the request came from \"{s}\" — " ++
                        "name it in .origins if that is a page you serve",
                    .{ authority, origin.view() },
                );
            }
        }
        const version = self.header("Sec-WebSocket-Version") orelse
            return fail.badRequest("the handshake is missing Sec-WebSocket-Version", .{});
        // 13 is the only version there has ever been in the published RFC.
        if (!std.mem.eql(u8, version.view(), "13")) {
            return fail.badRequest(
                "this server speaks WebSocket version 13, and the request asked for \"{s}\"",
                .{version.view()},
            );
        }
        const key = self.header("Sec-WebSocket-Key") orelse
            return fail.badRequest("the handshake is missing Sec-WebSocket-Key", .{});
        // Sixteen bytes of base64 (RFC 6455 §4.1), refused before anything is
        // answered: a key that is not one is not a WebSocket client.
        if (!websocket.keyIsValid(key.view())) {
            return fail.badRequest("Sec-WebSocket-Key has to be 16 bytes of base64", .{});
        }

        // From here the answer is written, so nothing above may fail.
        self.markAnswered(101);
        self._head_written = true;
        self.tookOver();
        // The connection stops being HTTP at the blank line below, so it can
        // never carry another request.
        self._force_close = true;

        const answer = websocket.accept(key.view());
        try websocket.writeAcceptance(wire.out, &answer, websocket.negotiated(self._head, options));

        // A WebSocket is allowed to sit quiet. A chat tab with nobody typing
        // is working correctly, and the read limit that protects the HTTP
        // side would close it in half a minute. What is worth catching here
        // is a client that has gone away without saying so, and the answer
        // to that is a ping it does not answer — a WebSocket feature, with a
        // frame to send and a reply to wait for, rather than a deadline
        // (ADR 022). Writes keep their limit: they are how the server finds
        // out the client stopped listening.
        //
        // **Quiet between frames, not inside one.** Silence between frames is
        // waited on by the Socket's park, which asks for readiness and reads
        // nothing, so every read is of a frame already begun. A client that
        // stopped half way through one was never pinged, because a ping goes
        // out only with nothing buffered, and it held the fiber for ever. Each
        // read gets what a silent client gets between frames before it is
        // closed: a ping's stretch and the one after it.
        if (options.idle_ms == 0) {
            self._deadlines.readForever();
        } else {
            self._deadlines.armEachRead(options.idle_ms *| 2);
        }

        return .{
            ._in = self._in,
            ._out = wire.out,
            ._stopping = self._stopping,
            // How this socket can be told something by a fiber that is not
            // holding it. Nothing uses it until the handler joins a Room.
            ._waker = self._waker,
            ._idle_ms = options.idle_ms,
            // Left null on purpose. The connection loop points it at the slot
            // beside the Socket in the `Handover` once that struct has stopped
            // moving; a hand-built `Ctx` with no loop above it falls back to
            // the Socket's own slot.
            ._max_message = options.max_message,
            ._watch = self._watch,
        };
    }

    /// Start a stream of server-sent events — a `text/event-stream` a
    /// browser reads with `new EventSource(url)`.
    ///
    /// ```zig
    /// var events = try c.events();
    /// while (events.live()) try events.send(.{ .name = "tick", .data = "." });
    /// try events.close();
    /// ```
    ///
    /// The two headers past the content type are what keep an event stream
    /// working through the things between the handler and the browser:
    /// `Cache-Control: no-cache` so nothing stores it, and
    /// `X-Accel-Buffering: no` so an nginx in front does not hold the events
    /// back waiting for a buffer to fill.
    pub fn events(self: *Ctx) !stream_mod.Events {
        if (self.onHttp2() and !self._framing.canStream()) return self.notInCall("c.events()");
        try self.setStaticHeader("Cache-Control", "no-cache");
        try self.setStaticHeader("X-Accel-Buffering", "no");
        return .{ .stream = try self.stream(200, stream_mod.Events.content_type) };
    }

    /// An event stream whose every event comes from Rooms, handed to the
    /// connection rather than held by this handler (ADR 227).
    ///
    /// ```zig
    /// fn feed(c: *nilo.Ctx, lobby: *nilo.Room) !void {
    ///     return c.eventsFrom(lobby, .{});
    /// }
    ///
    /// fn inbox(c: *nilo.Ctx, lobby: *nilo.Room, mine: *Inbox) !void {
    ///     return c.eventsFrom(.{ lobby, mine.roomOf(c) }, .{ .retry_ms = 5_000 });
    /// }
    /// ```
    ///
    /// `rooms` is one `*nilo.Room` or `rooms.named(key)`, or a tuple of them.
    /// The stream takes a seat in each before the head goes out, so a full
    /// room, or a pool with no Room left for a key, is a 503 the client can
    /// read rather than a stream that ends at once.
    ///
    /// A browser coming back sends `Last-Event-ID`, and a room that keeps
    /// history (`Room.Options.history`) writes what it said after that id
    /// before anything new, taken under the same lock as the seat so nothing
    /// is written twice or missed in between (ADR 229). After that the
    /// handler returns and the connection waits: every `say`, `print`, `json`
    /// and `event` into those rooms goes out as an event, a comment keeps the
    /// connection speaking every `keepalive_ms`, and the stream ends when the
    /// client goes or the server stops. A binary post is not an event and is
    /// counted as missed.
    ///
    /// What this does not do is anything of the handler's own between
    /// events. That is `c.events()`, which keeps the handler and costs what a
    /// held handler costs (ADR 019).
    pub fn eventsFrom(self: *Ctx, rooms: anytype, options: stream_mod.FromRooms) !void {
        comptime checkRooms(@TypeOf(rooms));
        if (self.answered() != null) return error.AlreadyAnswered; // one request, one response, as `send`
        // HTTP/2 hands its rooms to the connection, which writes what they post
        // between the frames of every other stream (ADR 227, ADR 260).
        if (comptime framing_mod.http2_built) if (self.onHttp2()) return self.eventsFromHttp2(rooms, options);
        // The connection loop runs this stream once the handler has returned,
        // which needs a connection that is this request's alone (ADR 227).
        const wire = self._framing.wire().?;
        const shape = self._framing.streamShape(null);

        var held: stream_mod.RoomEvents = .{
            ._in = self._in,
            ._out = wire.out,
            ._stopping = self._stopping,
            ._waker = self._waker,
            ._watch = self._watch,
            ._keepalive_ms = options.keepalive_ms,
            // HTTP/1.0 has no chunks, so the end of the stream is the end of
            // the connection, which it always is here anyway.
            ._chunked = shape.chunked,
        };

        // A HEAD is answered with the head a GET would get and nothing else,
        // so there is nothing to sit in a room for (ADR 019).
        const head_only = self.method == .HEAD;
        const last_id: []const u8 = if (self.header("Last-Event-ID")) |id| id.view() else "";
        // What each room kept for this client, holding a reference apiece
        // until it is written. A post taken here and never written would be
        // held for ever, so every way out releases what is left.
        var replays: [roomsIn(@TypeOf(rooms))]Replay = @splat(.{});
        defer for (&replays) |*kept| kept.release();
        if (!head_only) {
            errdefer held.leaveRooms();
            if (comptime isRoomLike(@TypeOf(rooms))) {
                try self.seatEvents(rooms, &held, last_id, &replays[0]);
            } else inline for (rooms, 0..) |in_room, i| {
                try self.seatEvents(in_room, &held, last_id, &replays[i]);
            }
        }
        errdefer held.leaveRooms();

        try self.setStaticHeader("Cache-Control", "no-cache");
        try self.setStaticHeader("X-Accel-Buffering", "no");
        self.markAnswered(200);
        self.tookOver();
        self._head_written = true;
        try self._framing.streamHead(200, stream_mod.Events.content_type, shape, null, self.keepAlive(), self.extraHeaders());
        if (head_only) return;

        // The stream never ends while the connection could carry another
        // request, so the connection ends with it.
        self._force_close = true;
        if (options.retry_ms) |millis| try held.sendRetry(millis);
        for (&replays) |*kept| {
            const posts = kept.posts;
            kept.posts = &.{};
            try held.replay(kept.room orelse continue, posts);
        }

        // No connection loop to hand it to: a `Ctx` built by hand in a test.
        // The same wait on a deeper stack, which only a test can afford.
        const slot = self._handover orelse return held.run();
        slot.* = .{ .events = .{ .stream = held, .run = stream_mod.RoomEvents.run } };
    }

    /// `eventsFrom` on HTTP/2 (ADR 227, ADR 260). The same seats, the same
    /// history and the same refusals as HTTP/1.1; the difference is who writes.
    /// The rooms ring the bell of the stream's `Http2Events`, which wakes the
    /// connection, and the connection writes what was posted as `DATA` between
    /// the frames of its other streams. This fiber ends at the return below:
    /// it has lent nothing, so nothing waits on it.
    noinline fn eventsFromHttp2(self: *Ctx, rooms: anytype, options: stream_mod.FromRooms) !void {
        if (!self._framing.canStream()) return self.notInCall("c.eventsFrom()");
        const feed = try self._arena.create(stream_mod.Http2Events);
        feed.* = .{ .link = self._framing.eventLink().?, .retry_ms = options.retry_ms };

        const head_only = self.method == .HEAD;
        const last_id: []const u8 = if (self.header("Last-Event-ID")) |id| id.view() else "";
        var replays: [roomsIn(@TypeOf(rooms))]Replay = @splat(.{});
        defer for (&replays) |*kept| kept.release();
        if (!head_only) {
            errdefer feed.leave();
            if (comptime isRoomLike(@TypeOf(rooms))) {
                try self.seatEvents(rooms, feed, last_id, &replays[0]);
            } else inline for (rooms, 0..) |in_room, i| {
                try self.seatEvents(in_room, feed, last_id, &replays[i]);
            }
        }
        errdefer feed.leave();
        // Before the head, so that nothing after it can fail: the history
        // moves to the stream, which releases it as it writes it.
        feed.replays = try self._arena.dupe(Replay, &replays);
        for (&replays) |*kept| kept.posts = &.{};

        try self.setStaticHeader("Cache-Control", "no-cache");
        try self.setStaticHeader("X-Accel-Buffering", "no");
        var shape = self._framing.streamShape(null);
        shape.bodyless = head_only;
        self.markAnswered(200);
        self.tookOver();
        self._head_written = true;
        try self._framing.streamHead(200, stream_mod.Events.content_type, shape, null, self.keepAlive(), self.extraHeaders());
        // A HEAD is the head and nothing else, and ends with it.
        if (head_only) return self._framing.end(false, .{});

        try self._framing.handOverEvents(.{
            .state = feed,
            .step = stream_mod.Http2Events.stepErased,
            .leave = stream_mod.Http2Events.leaveErased,
            .keepalive_ms = options.keepalive_ms,
        });
    }

    /// One seat for `eventsFrom`, in a Room or under a key, with a full room
    /// said as what it is. `sitter` is who sits: a `RoomEvents` on HTTP/1.1,
    /// whose room rings the request's waker, and an `Http2Events` on HTTP/2,
    /// whose room rings its own bell. Passed whole and not as a seat and a
    /// bell, so that the HTTP/1.1 helpers are the ones they were (ADR 017).
    fn seatEvents(
        self: *Ctx,
        target: anytype,
        sitter: anytype,
        last_id: []const u8,
        kept: *Replay,
    ) !void {
        if (comptime @TypeOf(target) == *room_mod.Room) {
            return self.seatIn(target, sitter, last_id, kept);
        } else {
            return self.seatNamed(target, sitter, last_id, kept);
        }
    }

    fn seatNamed(
        self: *Ctx,
        target: rooms_mod.Rooms.Named,
        sitter: anytype,
        last_id: []const u8,
        kept: *Replay,
    ) !void {
        const lent = target.rooms.pin(target.key) catch |err| switch (err) {
            error.NoRoomFree => return fail.status(
                503,
                "every Room in the pool is lent to a key somebody is in; the pool's rooms is the number to raise",
                .{},
            ),
            else => |e| return e,
        };
        // Seated before it is let go, so the Room cannot go back to the pool
        // in between (ADR 228).
        defer target.rooms.unpin(lent);
        return self.seatIn(&lent.room, sitter, last_id, kept);
    }

    fn seatIn(
        self: *Ctx,
        in_room: *room_mod.Room,
        sitter: anytype,
        last_id: []const u8,
        kept: *Replay,
    ) !void {
        // Asked for only by a client coming back to a room that keeps
        // something, so a first connection allocates nothing here.
        const into: []*room_mod.Post = if (last_id.len != 0 and in_room.keeps() != 0)
            try self._arena.alloc(*room_mod.Post, in_room.keeps())
        else
            &.{};
        const n = (if (comptime @TypeOf(sitter) == *stream_mod.RoomEvents)
            in_room.sitAfter(sitter.seating(), self._waker, true, last_id, into)
        else
            in_room.sitAfter(&sitter.seated, sitter.bell(), true, last_id, into)) catch |err| switch (err) {
            error.RoomFull => return fail.status(
                503,
                "every seat in this room is taken; the room's seats is the number to raise",
                .{},
            ),
            else => |e| return e,
        };
        kept.* = .{ .room = in_room, .posts = into[0..n] };
    }
};

/// `Ctx.sendKept`, for bytes the framework owns and knows outlive the
/// stream: the request arena's own output (a writer's, a message's, the JSON
/// of a value) or memory the App holds for its whole life (a loaded static
/// file). On HTTP/2 the connection's fiber writes the answer after the
/// handler has returned, under flow control, and a body of 16 KiB or more is
/// written from where it lies instead of being copied
/// (`Collected.wholeKept`). **Never for a slice a handler returned or a
/// service holds**: that is the user's to free, and it can be gone by then.
/// HTTP/1.1 writes before the handler returns and is the same as `sendKept`.
///
/// A function of this file and not a method, so that only the framework can
/// name it: `nilo.Ctx` is what a handler sees, and a lifetime promise the
/// compiler cannot check is not one a handler gets to make (ADR 260).
pub fn sendOwned(c: *Ctx, status: u16, content_type: []const u8, response_body: []const u8) !void {
    return c.sendWhole(status, content_type, response_body, true, true);
}

/// The posts one room kept for a client coming back, each holding a
/// reference until `eventsFrom` writes it (ADR 229).
const Replay = stream_mod.Replay;

fn isRoomLike(comptime T: type) bool {
    return T == *room_mod.Room or T == rooms_mod.Rooms.Named;
}

fn roomsIn(comptime T: type) usize {
    return if (isRoomLike(T)) 1 else @typeInfo(T).@"struct".fields.len;
}

/// What `eventsFrom` can sit a stream in, checked where the mistake is made
/// (ADR 026). A stream in no room is one that can only ever send keep-alive
/// comments, which is a mistake rather than a feed.
fn checkRooms(comptime T: type) void {
    const shape = "; it takes a *nilo.Room or rooms.named(key), or a tuple of them like .{ lobby, mine }";
    if (isRoomLike(T)) return;
    switch (@typeInfo(T)) {
        .@"struct" => |s| if (s.is_tuple) {
            if (s.fields.len == 0) @compileError(
                "nilo: eventsFrom was given no rooms, so the stream could only ever send keep-alive comments" ++ shape,
            );
            for (s.fields) |field| {
                if (!isRoomLike(field.type)) @compileError(
                    "nilo: eventsFrom was given a tuple holding " ++ naming.of(field.type) ++ shape,
                );
            }
            return;
        },
        else => {},
    }
    @compileError("nilo: eventsFrom was given " ++ naming.of(T) ++ shape);
}

// ---- saying what is wrong with a request body ----
//
// A query param that does not fit gets `?page has to be a whole number, not
// "soon"`. A body field that does not fit used to get `Bad Request`, and
// nothing else — same framework, same request, two completely different
// standards. What follows closes that gap.
//
// std.json reports `error.UnknownField` without saying which field, and
// that name is the whole of what the person holding the curl command needs.
// So on the failure path — and only there — the body is read a second time
// as a plain `std.json.Value` and compared against `T` field by field.
// Paying for a second parse to explain a request that was already going to
// be refused is a trade worth making; a body that parses never comes here.

/// How far down a body this walks. The same limit `openapi.schemaOf` and
/// `str.stamp` use, and for the same reason: a type holding one of its own
/// would otherwise be followed for ever. Nothing below it is described, so a
/// mistake down there is still a plain 400.
const max_body_depth = 8;

/// How deeply a JSON body may nest when the type it is read into holds
/// itself. `std.json` reads such a type by recursing once per level on the
/// fiber's stack, with no bound of its own: `{"c":[` twenty thousand times,
/// 160 KB, took the process down on an 8 MB stack. A comment tree or a menu
/// 32 deep is two levels a node, so 64 is past anything a page shows, and
/// the stack it can touch is a few kilobytes rather than all of it.
pub const max_json_nesting = 64;

/// Refuse a body nested past `max_json_nesting`, before it is parsed, when
/// `T` can nest without a bound, or holds a struct that skips unknown keys
/// (`.unknown_fields = .ignore`, ADR 168): a skipped value is read by no
/// field, so the declaration bounds nothing about it. A type that does neither
/// is bounded by its own declaration, pays nothing, and is not scanned.
fn refuseTooDeep(comptime T: type, body: []const u8) !void {
    if (comptime !nestsWithoutBound(T) and !jsonmark.ignoresUnknownWithin(T)) return;
    return refuseDeepBody(body);
}

/// The scan itself, for whatever type: **a body that failed to parse is read
/// again as a `std.json.Value`, which nests without a bound whatever `T` is**
/// and allocates for every level, so `describeBadBody` and `collectBadBody`
/// run it before that second parse. A megabyte of `[` sent to a plain struct
/// route cost the arena 130 times the body, and ADR 226's bound covered only
/// the first parse (the audit of `http/` at `39896d2`).
fn refuseDeepBody(body: []const u8) !void {
    if (!nestedDeeperThan(body, max_json_nesting)) return;
    return fail.badRequest(
        "the body nests deeper than {d} levels, which is as deep as this endpoint reads",
        .{max_json_nesting},
    );
}

/// Whether some type reachable from `T` reaches itself again, through a
/// field, a slice, a pointer, an optional, an array or a union's payload:
/// the shape `std.json` recurses into once per level of the input.
fn nestsWithoutBound(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    return comptime onCycle(T, &.{});
}

fn onCycle(comptime T: type, comptime path: []const type) bool {
    for (path) |seen| if (seen == T) return true;
    const deeper = path ++ [_]type{T};
    switch (@typeInfo(T)) {
        .@"struct" => |s| for (s.fields) |f| {
            if (onCycle(f.type, deeper)) return true;
        },
        .@"union" => |u| for (u.fields) |f| {
            if (onCycle(f.type, deeper)) return true;
        },
        .optional => |o| return onCycle(o.child, deeper),
        .pointer => |p| return onCycle(p.child, deeper),
        .array => |a| return onCycle(a.child, deeper),
        else => {},
    }
    return false;
}

/// Whether `body` opens more than `limit` arrays and objects inside one
/// another. Brackets inside a string are text, so strings and their escapes
/// are stepped over. Malformed JSON is the parser's to refuse; this only has
/// to be right about the depth of JSON that is well formed.
fn nestedDeeperThan(body: []const u8, limit: usize) bool {
    var depth: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const b = body[i];
        if (in_string) {
            switch (b) {
                '\\' => i += 1,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }
        switch (b) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                if (depth > limit) return true;
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
    return false;
}

/// Turn a failed body parse into a 400 that names what is wrong with it,
/// falling back to `err` when nothing here can do better.
fn describeBadBody(
    comptime T: type,
    arena: std.mem.Allocator,
    body: []const u8,
    err: anyerror,
) anyerror {
    // Anything but a struct, or a union with a discriminator, is somebody
    // using `Ctx.json` directly for a list or a number, where there are no
    // field names to talk about.
    const tagged = comptime tagOf(T) != null;
    if (@typeInfo(T) != .@"struct" and !tagged) return err;

    if (std.mem.trim(u8, body, " \t\r\n").len == 0) {
        if (comptime tagged) return fail.badRequest(
            "the request body is empty. This endpoint expects an object whose \"{s}\" is one of {s}",
            .{ comptime tagOf(T).?, comptime variantList(T) },
        );
        return fail.badRequest(
            "the request body is empty. This endpoint expects a JSON object with: {s}",
            .{comptime fieldList(T)},
        );
    }

    // Read again with no shape to satisfy. If even this fails, the text is
    // not JSON at all, and where it stopped making sense is the useful part.
    // Not before the depth is known to be one a second parse can afford.
    try refuseDeepBody(body);
    var scanner = std.json.Scanner.initCompleteInput(arena, body);
    defer scanner.deinit();
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);

    const dynamic = std.json.parseFromTokenSourceLeaky(
        std.json.Value,
        arena,
        &scanner,
        .{},
    ) catch return fail.badRequest(
        "the request body is not valid JSON — it stops making sense at line {d}, column {d}",
        .{ diagnostics.getLine(), diagnostics.getColumn() },
    );

    // From here on the body is JSON, so whatever is wrong with it is its
    // shape, and that is the refusal a type can choose the status of.
    if (dynamic != .object) {
        if (comptime tagged) return misfit(T, fail.badRequest(
            "the request body has to be an object whose \"{s}\" is one of {s}, not {s}",
            .{ comptime tagOf(T).?, comptime variantList(T), kindOf(dynamic) },
        ));
        return misfit(T, fail.badRequest(
            "the request body has to be a JSON object with: {s} — this is {s}",
            .{ comptime fieldList(T), kindOf(dynamic) },
        ));
    }

    var deeper = false;
    const found = if (comptime tagged)
        describeTagged(T, arena, dynamic.object, "", max_body_depth, &deeper)
    else
        describeObject(T, arena, dynamic.object, "", .{}, max_body_depth, &deeper);
    if (found) |explained| return misfit(T, explained);
    return misfit(T, if (deeper) tooDeep() else err);
}

/// A refusal of a body that is JSON and not `T`'s shape, answered with the
/// status `T` chose (`.misfit = 422` in its `nilo_json`), or exactly as it
/// came when `T` chose none, which is every type that says nothing and costs
/// it nothing: the first line returns while compiling
/// ([ADR 251](../docs/adr/251-json-that-does-not-fit-can-be-a-422.md)).
///
/// The sentence is the one the 400 would have carried, so only the status
/// moves. A refusal with no sentence behind it, the bare `std.json` error a
/// walk that found nothing hands back, is given one, because the error's own
/// status is 400 by name.
fn misfit(comptime T: type, refused: anyerror) anyerror {
    const chosen = comptime jsonmark.misfitStatus(T);
    if (comptime chosen == null) return refused;
    const status = chosen.?;
    // Outside a request there is no Failure, and the bare error is the answer
    // a fail function gives there too.
    const failure = fail.current() orelse return refused;
    if (fail.failed(failure, refused)) {
        // Only a 400 is a refusal of the shape; anything else was chosen by
        // something below, such as a type's own reader, and stands.
        if (failure.status == 400) failure.status = status;
        return refused;
    }
    if (refused == error.OutOfMemory) return refused;
    return fail.status(status, "the request body is valid JSON and does not fit this endpoint", .{});
}

/// Turn a failed body parse into one outcome per field of `T`, instead of
/// into the first sentence that explains it.
///
/// Same second parse `describeBadBody` pays for, and for the same reason:
/// the request was going to be refused anyway, and a body that parses never
/// comes here. What differs is where it stops — this one keeps going, so a
/// client that sent three bad fields learns about three.
///
/// **Three things stay a hard 400**, and they are the three that leave no
/// binding to hand back. Text that is not JSON, or a body that is not an
/// object, is not a mistake about any particular field. A field this
/// endpoint has never heard of is not one of `T`'s fields, so there is no
/// outcome to record it against — and "you sent `nme`" ends the search where
/// "`name` is missing" would not. And a mistake *nested* inside a field is
/// about the shape of the request rather than about which of this endpoint's
/// own fields to show again; `describeField` names it down to eight levels,
/// which is more than a list of top-level names could say.
fn collectBadBody(
    comptime T: type,
    arena: std.mem.Allocator,
    lifetime: *const str_mod.Lifetime,
    body: []const u8,
    err: anyerror,
    outcomes: *[@typeInfo(T).@"struct".fields.len]convert.Outcome,
) !T {
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return fail.badRequest(
        "the request body is empty. This endpoint expects a JSON object with: {s}",
        .{comptime fieldList(T)},
    );

    // The same bound `describeBadBody` puts in front of its second parse.
    try refuseDeepBody(body);
    var scanner = std.json.Scanner.initCompleteInput(arena, body);
    defer scanner.deinit();
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);

    const dynamic = std.json.parseFromTokenSourceLeaky(
        std.json.Value,
        arena,
        &scanner,
        .{},
    ) catch return fail.badRequest(
        "the request body is not valid JSON — it stops making sense at line {d}, column {d}",
        .{ diagnostics.getLine(), diagnostics.getColumn() },
    );

    // JSON from here on: what stays a hard refusal is a refusal of the shape,
    // answered with the status `T` chose for that (ADR 251).
    if (dynamic != .object) return misfit(T, fail.badRequest(
        "the request body has to be a JSON object with: {s} — this is {s}",
        .{ comptime fieldList(T), kindOf(dynamic) },
    ));

    const object = dynamic.object;

    var it = object.iterator();
    while (it.next()) |entry| {
        // The type's own word on keys it does not know, as `describeObject`
        // reads it; skipped, they are left for the fields below to ignore.
        if (comptime jsonmark.ignoresUnknown(T)) break;
        const name = entry.key_ptr.*;
        if (!hasField(T, name)) return misfit(T, fail.badRequest(
            "the request body has a field \"{s}\" this endpoint does not know. It takes: {s}",
            .{ name, comptime fieldList(T) },
        ));
    }

    var out: T = undefined;
    var any = false;

    inline for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
        outcomes[i] = .{};

        if (object.get(f.name)) |given| {
            // Only a string has text to quote back. A list or an object is
            // described by its kind instead, which is what `kind` is for.
            if (given == .string) outcomes[i].given = Str.fromRequest(given.string, lifetime);

            // A field that parses itself is read the way a query value is:
            // the text handed to `nilo_parse`, and null the same `.not_that_type`
            // ([ADR 166](../docs/adr/166-a-body-field-that-parses-itself.md)).
            // Read here rather than through `std.json` so that a type which
            // hands over a `jsonParse` and nothing more is still one outcome
            // among the others, in the same words.
            if (comptime parsedOf(f.type)) |P| {
                var buf: [64]u8 = undefined;
                if (given == .null and @typeInfo(f.type) == .optional) {
                    @field(out, f.name) = null;
                } else if (textOf(given, &buf)) |text| {
                    if (P.nilo_parse(text)) |value| {
                        @field(out, f.name) = value;
                    } else {
                        outcomes[i].reason = .not_that_type;
                        // A number has digits to quote back too, and they
                        // are in a stack buffer, so they are copied out.
                        if (given != .string) outcomes[i].given = Str.fromRequest(try arena.dupe(u8, text), lifetime);
                        any = true;
                        if (f.defaultValue()) |default| @field(out, f.name) = default;
                    }
                } else {
                    outcomes[i].reason = .wrong_kind;
                    outcomes[i].kind = kindOf(given);
                    any = true;
                    if (f.defaultValue()) |default| @field(out, f.name) = default;
                }
            } else {
                // `std.json` would read `"1_0"` into a number, so a number is
                // asked of `fits` first, which reads it the way a query's is
                // (ADR 084).
                const read: anyerror!f.type = if (comptime numberOf(f.type) == null)
                    std.json.parseFromValueLeaky(f.type, arena, given, .{})
                else if (fits(f.type, given))
                    std.json.parseFromValueLeaky(f.type, arena, given, .{})
                else
                    error.InvalidNumber;
                if (read) |value| {
                    @field(out, f.name) = value;
                } else |_| if (!fits(f.type, given)) {
                    // A word that is not one of the choices is the one wrong
                    // value that is the right *kind*, and it gets the sentence a
                    // bad `?stage=` gets rather than one arguing with itself.
                    if (given == .string and comptime choicesOf(f.type) != null) {
                        outcomes[i].reason = .not_a_choice;
                    } else if (numberFault(f.type, arena, given)) |said| {
                        // The number is the right kind and not a value of
                        // this field, so it is quoted back like a query's.
                        outcomes[i].reason = .wrong_kind;
                        outcomes[i].kind = said;
                    } else {
                        outcomes[i].reason = .wrong_kind;
                        outcomes[i].kind = kindOf(given);
                    }
                    any = true;
                    if (f.defaultValue()) |default| @field(out, f.name) = default;
                } else {
                    var deeper = false;
                    if (describeField(f.type, arena, given, f.name, max_body_depth, &deeper)) |found| return misfit(T, found);
                    return misfit(T, if (deeper) tooDeep() else err);
                }
            }
        } else if (f.default_value_ptr == null) {
            outcomes[i].reason = .missing;
            any = true;
        } else {
            @field(out, f.name) = f.defaultValue().?;
        }
    }

    // The parse failed and nothing above accounts for it. Hand it to the
    // walker that says the most, rather than answering with an empty list of
    // failures and a binding nobody can use.
    if (!any) return describeBadBody(T, arena, body, err);

    // Deliberately not stamped. `stamp` walks the struct writing lifetime
    // markers, and this struct has undefined fields in it — following an
    // undefined slice is exactly the crash the marker exists to prevent. It
    // costs nothing: `Bound.value()` withholds the struct while any outcome
    // carries a reason, so nothing in here is reachable. The text that *is*
    // reachable is `outcomes[i].given`, stamped one at a time above.
    return out;
}

/// What is wrong inside one object, or null if nothing here explains the
/// refusal. `where` is what to call this object in a message — empty at the
/// top level, `address` one down, `lines[2]` inside a list — so a nested
/// field is named the way somebody would point at it in the JSON they sent.
fn describeObject(
    comptime T: type,
    arena: std.mem.Allocator,
    object: std.json.ObjectMap,
    where: []const u8,
    comptime within: Within,
    comptime depth: u8,
    deeper: *bool,
) ?anyerror {
    // Something the body carries that the endpoint has no room for. Almost
    // always a typo, which is why the known names go out with it.
    //
    // Asked before "what is missing", because a typo is both at once —
    // `{"nme":"wati"}` has an unknown `nme` and is missing `name` — and of
    // those two true sentences, the one quoting what was actually typed is
    // the one that ends the search.
    var it = object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        // The discriminator is read with the variant's own fields and is not
        // one of them (`describeTagged`).
        if (within.tag.len > 0 and std.mem.eql(u8, name, within.tag)) continue;
        // A type that skips what it does not know has nothing to say about it.
        if (comptime jsonmark.ignoresUnknown(T)) continue;
        if (!hasField(T, name)) return fail.badRequest(
            "the request body has a field \"{s}\" {s} does not know. It takes: {s}",
            .{ nameWithin(arena, where, name), comptime thatWhat(within), comptime takes(T, within) },
        );
    }

    // Something the endpoint needs that the body does not carry. A field
    // with a default is what "absent" is allowed to mean, so it is exempt —
    // the same rule a query struct follows.
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (f.default_value_ptr == null and !object.contains(f.name)) return fail.badRequest(
            "the request body is missing \"{s}\" ({s})",
            .{ nameWithin(arena, where, f.name), comptime expectedOf(f.type) },
        );
    }

    // Everything is present and nothing is spare, so a value is the wrong
    // shape for the field it landed in — here, or somewhere further down.
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (object.get(f.name)) |given| {
            if (describeField(f.type, arena, given, nameWithin(arena, where, f.name), depth, deeper)) |found| {
                return found;
            }
        }
    }

    return null;
}

/// Which variant of an internally tagged union an object is being read as, so
/// that its unknown-field sentence says so. Empty for a plain struct.
const Within = struct { tag: []const u8 = "", variant: []const u8 = "" };

fn thatWhat(comptime within: Within) []const u8 {
    return if (within.tag.len == 0) "this endpoint" else "the \"" ++ within.variant ++ "\" variant";
}

/// What a struct takes, with the discriminator first when it is one variant of
/// a tagged union: the key goes beside the variant's fields on the wire.
fn takes(comptime T: type, comptime within: Within) []const u8 {
    comptime {
        if (within.tag.len == 0) return fieldList(T);
        if (@typeInfo(T) != .@"struct") return within.tag;
        const fields = @typeInfo(T).@"struct".fields;
        var entries: [fields.len + 1][]const u8 = undefined;
        entries[0] = within.tag;
        for (fields, 1..) |f, i| {
            entries[i] = f.name ++ (if (f.default_value_ptr != null) " (optional)" else "");
        }
        return nameList(&entries);
    }
}

/// The discriminator key of an internally tagged union, or null for a type
/// that is not one.
fn tagOf(comptime T: type) ?[]const u8 {
    comptime {
        if (@typeInfo(T) != .@"union") return null;
        const m = jsonmark.of(T) orelse return null;
        return m.tag;
    }
}

/// The variants of a tagged union as the wire spells them.
fn variantList(comptime U: type) []const u8 {
    return comptime nameList(jsonmark.wireNames(U));
}

/// What is wrong inside an internally tagged union's object: the discriminator
/// missing, not text, or not a variant this type has, a key the variant it
/// names does not take, and then whatever is wrong inside the variant's own
/// fields. **Every sentence names what was received and what would have been
/// accepted**, the way the struct's do; a 400 of `Bad Request` and nothing else
/// was all a union ever got.
fn describeTagged(
    comptime U: type,
    arena: std.mem.Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
    comptime depth: u8,
    deeper: *bool,
) ?anyerror {
    const key = comptime tagOf(U).?;
    const at = nameWithin(arena, name, key);

    const given = object.get(key) orelse return fail.badRequest(
        "the request body is missing \"{s}\", which names the variant: one of {s}",
        .{ at, comptime variantList(U) },
    );
    if (given != .string) return fail.badRequest(
        "\"{s}\" has to be text naming the variant, one of {s}, not {s}",
        .{ at, comptime variantList(U), kindOf(given) },
    );

    inline for (@typeInfo(U).@"union".fields, comptime jsonmark.wireNames(U)) |f, on_the_wire| {
        if (std.mem.eql(u8, given.string, on_the_wire)) {
            const within: Within = .{ .tag = key, .variant = on_the_wire };
            if (f.type == void) {
                var it = object.iterator();
                while (it.next()) |entry| {
                    const k = entry.key_ptr.*;
                    if (std.mem.eql(u8, k, key)) continue;
                    return fail.badRequest(
                        "the request body has a field \"{s}\" {s} does not know. It takes: {s}",
                        .{ nameWithin(arena, name, k), comptime thatWhat(within), comptime takes(void, within) },
                    );
                }
                return null;
            }
            return describeObject(f.type, arena, object, name, within, depth, deeper);
        }
    }

    return fail.badRequest(
        "\"{s}\" is not one of the known variants ({s}): \"{s}\"",
        .{ at, comptime variantList(U), given.string },
    );
}

/// What is wrong with one value, given the type it landed in. Answers about
/// this value first, then about whatever is inside it.
fn describeField(
    comptime T: type,
    arena: std.mem.Allocator,
    given: std.json.Value,
    name: []const u8,
    comptime depth: u8,
    deeper: *bool,
) ?anyerror {
    // Asked of `T` and not of what is inside it, so an optional still says
    // "text or null" rather than dropping the half that makes it optional.
    if (!fits(T, given)) {
        // A word that is not one of the choices is the one wrong value that
        // is the right *kind*, so "has to be one of …, not text" is a
        // sentence arguing with itself. It gets the wording a bad `?stage=`
        // gets, which quotes back what was actually sent.
        if (given == .string) {
            if (comptime choicesOf(T)) |choices| return fail.badRequest(
                "\"{s}\" is not one of the known choices ({s}): \"{s}\"",
                .{ name, choices, given.string },
            );
        }
        // A number that is not a value of its field names the field and quotes
        // the number, the way `?age=300` does, rather than calling a number
        // "a number" (ADR 084).
        if (comptime numberOf(T)) |N| {
            if (numberFault(T, arena, given)) |said| return fail.badRequest(
                "\"{s}\" has to be {s}, not {s}",
                .{ name, comptime expectedOf(N), said },
            );
        }
        // The same for a type that parses itself and said no: what arrived
        // was the right kind and the wrong text, and the sentence is the one
        // a query value of that type gets, quoting it (ADR 166).
        if (comptime parsedOf(T)) |P| {
            var buf: [64]u8 = undefined;
            if (textOf(given, &buf)) |text| {
                // A type that words its own refusal — a `nilo.Text`, which
                // says the count and never the text — writes the tail
                // (ADR 193). Small on purpose: this frame is reached eight
                // deep, and only on the way to a 400.
                if (comptime @hasDecl(P, convert.explain_marker)) {
                    var tail: [128]u8 = undefined;
                    var w = std.Io.Writer.fixed(&tail);
                    @field(P, convert.explain_marker)(text, &w) catch {};
                    return fail.badRequest("\"{s}\" {s}", .{ name, w.buffered() });
                }
                return fail.badRequest(
                    "\"{s}\" has to be {s}, not \"{s}\"",
                    .{ name, comptime expectedOf(T), text },
                );
            }
        }
        return fail.badRequest(
            "\"{s}\" has to be {s}, not {s}",
            .{ name, comptime expectedOf(T), kindOf(given) },
        );
    }

    // An optional sent as null fits and holds nothing to look inside.
    if (given == .null) return null;
    // **The bottom of the budget, and it used to be silent.** A body nested
    // deeper than this answered a bare 400 with no field, no reason and no
    // hint that depth was what happened — the cliff is documented and how
    // sheer it looks from the client's side was not (ADR 034). The walk still
    // stops, because there is nothing below here it can name; what changes is
    // that the caller is told a ceiling was reached, and says so instead of
    // saying nothing.
    if (depth == 0) {
        if (hasInsides(T, given)) deeper.* = true;
        return null;
    }

    const Inner = if (comptime patch_mod.isPatch(T)) T.nilo_patch else switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };

    // A value that parsed itself is one value, whatever its kind of type:
    // a `Uuid` is a struct with nothing inside it to point at.
    if (comptime convert.parsesItself(Inner)) return null;

    if (Inner != Str) switch (@typeInfo(Inner)) {
        .@"struct" => return describeObject(Inner, arena, given.object, name, .{}, depth - 1, deeper),
        .@"union" => if (comptime tagOf(Inner) != null) return describeTagged(Inner, arena, given.object, name, depth - 1, deeper),
        .pointer => |p| {
            // `[]const u8` is text, which has nothing inside it to describe.
            if (p.size != .slice or p.child == u8) return null;
            for (given.array.items, 0..) |item, i| {
                const at = std.fmt.allocPrint(arena, "{s}[{d}]", .{ name, i }) catch name;
                if (describeField(p.child, arena, item, at, depth - 1, deeper)) |found| return found;
            }
        },
        else => {},
    };

    return null;
}

/// Whether there is anything below this value worth having walked into — a
/// struct, or a list of something that is not bytes. A `Str` at the ceiling is
/// not a body that is too deep; it is the bottom of one that fits.
fn hasInsides(comptime T: type, given: std.json.Value) bool {
    const Inner = if (comptime patch_mod.isPatch(T)) T.nilo_patch else switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    if (Inner == Str) return false;
    if (comptime convert.parsesItself(Inner)) return false;
    return switch (@typeInfo(Inner)) {
        .@"struct" => given == .object,
        .@"union" => comptime tagOf(Inner) != null and given == .object,
        .pointer => |p| p.size == .slice and p.child != u8 and given == .array and
            given.array.items.len > 0,
        else => false,
    };
}

/// The one thing to say about a body nobody can point inside of.
///
/// **A fact rather than a dead end** (ADR 034). The old answer was
/// `{"error":"Bad Request","status":400}` — not a worse sentence, *no*
/// sentence — and a client holding it had no way to tell a depth ceiling from
/// a parser that gave up. Raising the ceiling is a separate question with a
/// comptime cost attached; saying which wall was hit is free.
fn tooDeep() anyerror {
    return fail.badRequest(
        "the request body is valid JSON and does not fit this endpoint, but it is nested " ++
            "deeper than {d} levels — which is as far as nilo follows a body — so it cannot " ++
            "say which part is wrong. The mistake is somewhere below that.",
        .{max_body_depth},
    );
}

/// `address.street` — what to call a field that is inside something else. At
/// the top level there is nothing to be inside, so the name stands alone and
/// the message reads exactly as it did before any of this nested.
fn nameWithin(arena: std.mem.Allocator, where: []const u8, name: []const u8) []const u8 {
    if (where.len == 0) return name;
    // Out of memory while explaining a bad request: the unqualified name is
    // most of the message, and is better than no message.
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ where, name }) catch name;
}

/// What a JSON value is, in the words an error message wants.
fn kindOf(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "true or false",
        .integer, .float, .number_string => "a number",
        .string => "text",
        .array => "a list",
        .object => "an object",
    };
}

/// What a field will accept, in those same words. Public because a form
/// field that was not sent is missing in the same way a body field is, and
/// says so in the same sentence (`form.zig`).
pub fn expectedOf(comptime T: type) []const u8 {
    comptime {
        if (T == Str) return "text";
        // A `Patch(T)` takes the value or null; leaving it out is the third
        // thing it can be, and that is not a value to describe.
        if (patch_mod.isPatch(T)) return expectedOf(T.nilo_patch) ++ " or null";
        // What the type said it expects, or its name — the words a query
        // value of the same type is asked for in (ADR 166).
        if (convert.parsesItself(T)) return convert.expects(T);
        return switch (@typeInfo(T)) {
            .optional => |o| expectedOf(o.child) ++ " or null",
            .bool => "true or false",
            .int, .comptime_int => "a whole number",
            .float, .comptime_float => "a number",
            .@"enum" => |e| blk: {
                var out: []const u8 = "one of ";
                for (e.fields, 0..) |f, i| out = out ++ (if (i == 0) "" else ", ") ++ f.name;
                break :blk out;
            },
            .@"struct" => "an object",
            .@"union" => if (tagOf(T)) |key| "an object whose \"" ++ key ++ "\" is one of " ++ variantList(T) else "something this endpoint understands",
            .pointer => |p| if (p.size == .slice and p.child == u8) "text" else "a list",
            else => "something this endpoint understands",
        };
    }
}

/// The names an enum field will answer to, or null if the field is not one —
/// through an optional or a `Patch`, since `?Stage` is as much a list of
/// choices as `Stage` is.
fn choicesOf(comptime T: type) ?[]const u8 {
    comptime {
        if (T == Str) return null;
        if (patch_mod.isPatch(T)) return choicesOf(T.nilo_patch);
        return switch (@typeInfo(T)) {
            .optional => |o| choicesOf(o.child),
            .@"enum" => |e| blk: {
                var out: []const u8 = "";
                for (e.fields, 0..) |f, i| out = out ++ (if (i == 0) "" else ", ") ++ f.name;
                break :blk out;
            },
            else => null,
        };
    }
}

/// The field names of `T`, for saying what the endpoint does take.
fn fieldList(comptime T: type) []const u8 {
    comptime {
        const fields = @typeInfo(T).@"struct".fields;
        var entries: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| {
            entries[i] = f.name ++ (if (f.default_value_ptr != null) " (optional)" else "");
        }
        return nameList(&entries);
    }
}

/// How many bytes of names a message carries before it says "and N more".
///
/// **The bound is here and not on the buffer.** A `Failure` is 256 bytes, one a
/// connection, so a longer ceiling is paid by every idle connection for the
/// sake of the few endpoints with wide bodies (ADR 006, ADR 017); the stack
/// buffer that answers it is six times `fail.max_message` as well (ADR 024).
/// A list that stops by itself keeps the whole sentence inside the 240 bytes
/// it has, with room for the quoted name a client sent, and costs nothing at
/// run time: it is spelled while compiling.
const name_list_budget = 100;

/// `names` joined by commas, as many as fit `name_list_budget` (always at least
/// one), then how many were left out. The ones named are the first ones, which
/// are the ones a struct's author put first.
fn nameList(comptime names: []const []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(2_000 + 40 * names.len);
        var out: []const u8 = "";
        var shown: usize = 0;
        for (names, 0..) |name, i| {
            const next = out ++ (if (i == 0) "" else ", ") ++ name;
            if (i > 0 and next.len > name_list_budget) break;
            out = next;
            shown += 1;
        }
        if (shown < names.len) out = out ++ std.fmt.comptimePrint(", and {d} more", .{names.len - shown});
        return out;
    }
}

/// Where generated request ids count from, and how far along they are.
///
/// A correlation id has to tell apart the requests somebody is reading logs
/// for, and a counter starting at 1 in every process behind the same proxy
/// does not do that — so the counting starts somewhere nobody can guess.
///
/// The base is drawn **once**, on the first request that asks. It goes
/// through the Bulkhead, which is a syscall, and a syscall made per request
/// would stop every other request sharing that thread (ADR 001, ADR 013).
/// What is left on the request path is one atomic add.
var id_base: std.atomic.Value(u64) = .init(0);
var id_next: std.atomic.Value(u64) = .init(0);

fn nextId() u64 {
    var base = id_base.load(.monotonic);
    if (base == 0) {
        var bytes: [8]u8 = undefined;
        // Nothing here is worth failing a request over: without a base the
        // counter alone still tells this process's requests apart, which is
        // what somebody reading one process's logs is doing with it.
        bulkhead.randomSecure(&bytes) catch @memset(&bytes, 0);
        // Forced odd so the base is never zero, which is the value standing
        // for "not drawn yet".
        base = std.mem.readInt(u64, &bytes, .little) | 1;
        // A race just means two draws and one kept; whoever lost adopts the
        // winner's base so every id in this process counts from one place.
        if (id_base.cmpxchgStrong(0, base, .monotonic, .monotonic)) |already| base = already;
    }
    return base +% id_next.fetchAdd(1, .monotonic);
}

/// Whether a client-supplied request id is one nilo is willing to repeat.
///
/// Deliberately narrow. The id is written into log lines and into a response
/// header, so the test is not "is this valid" but "can anything in here mean
/// something somewhere else" — a newline, a quote, a control byte. Every id
/// generator in use writes hex, a UUID, or base62, and all of those pass.
fn usableRequestId(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    for (text) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

fn hasField(comptime T: type, name: []const u8) bool {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

/// The type that parses itself inside `T` — `T` itself, or the child of an
/// optional — or null when `T` is not one of those.
fn parsedOf(comptime T: type) ?type {
    comptime {
        const Inner = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        return if (convert.parsesItself(Inner)) Inner else null;
    }
}

/// The text a JSON value is, for a type that reads text: a string as it is,
/// a number as its digits, and nothing for anything else. `buf` is where a
/// number that arrived as an integer or a float is printed.
fn textOf(value: std.json.Value, buf: []u8) ?[]const u8 {
    return switch (value) {
        .string, .number_string => |s| s,
        .integer => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch null,
        .float => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch null,
        else => null,
    };
}

/// The text a JSON number was written as, for a number inside a message. A
/// `.float` has lost its spelling, so it is printed the way `{d}` prints it.
fn numberText(arena: std.mem.Allocator, value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .integer => |n| std.fmt.allocPrint(arena, "{d}", .{n}) catch null,
        .float => |n| std.fmt.allocPrint(arena, "{d}", .{n}) catch null,
        .number_string => |s| s,
        else => null,
    };
}

/// The number type inside `T`, through an optional or a `Patch`, or null when
/// `T` is not one.
fn numberOf(comptime T: type) ?type {
    comptime {
        if (T == Str or convert.parsesItself(T)) return null;
        if (patch_mod.isPatch(T)) return numberOf(T.nilo_patch);
        return switch (@typeInfo(T)) {
            .optional => |o| numberOf(o.child),
            .int, .float => T,
            else => null,
        };
    }
}

/// Whether a JSON number, or a string spelling one, is a value of the number
/// type `N`: the same grammar a query value is read with, and the range of the
/// type, which is what makes `300` a refusal for a `u8` and `1.5` for an
/// integer (ADR 084). Asked of what `std.json.Value` kept, so `5.0` is a
/// `.float` and not a whole number, as it is not in a query either.
fn numberFits(comptime N: type, value: std.json.Value) bool {
    const text: []const u8 = switch (value) {
        .integer => |n| {
            if (@typeInfo(N) == .float) return true;
            return std.math.cast(N, n) != null;
        },
        // A float token is spelled with a point or an exponent. It is a value
        // of a float type when it is finite in *that* width, and never of an
        // integer one.
        .float => |f| return @typeInfo(N) == .float and std.math.isFinite(@as(N, @floatCast(f))),
        .number_string, .string => |s| s,
        else => return false,
    };
    if (!convert.spelledAsNumber(text, @typeInfo(N) == .float or @typeInfo(N).int.signedness == .signed, @typeInfo(N) == .float)) return false;
    if (@typeInfo(N) == .float) return std.math.isFinite(std.fmt.parseFloat(N, text) catch return false);
    _ = std.fmt.parseInt(N, text, 10) catch return false;
    return true;
}

/// What is wrong with a number that is the right kind of value and still not a
/// value of its field, in the words `?age=300` gets: the field is named and the
/// number is quoted back. Null when `T` is not a number or the value is not
/// one, which are the kind's to say (`"age" has to be a whole number, not
/// text`).
fn numberFault(comptime T: type, arena: std.mem.Allocator, given: std.json.Value) ?[]const u8 {
    if (comptime numberOf(T) == null) return null;
    const N = comptime numberOf(T).?;
    // A float token that overflowed has no spelling left to quote.
    if (given == .float and !std.math.isFinite(given.float)) return "one too large for it to hold";
    const text = numberText(arena, given) orelse return null;
    // A whole number that is not in the field's range says what the range is:
    // `300` for a `u8` is the right kind and the wrong size.
    if (comptime @typeInfo(N) == .int) {
        if ((given == .integer or given == .number_string) and convert.spelledAsNumber(text, true, false)) {
            return std.fmt.allocPrint(arena, "{s}, which is outside {d} to {d}", .{
                text, std.math.minInt(N), std.math.maxInt(N),
            }) catch text;
        }
    }
    return text;
}

/// Whether a JSON value could have become a `T`. Loose on purpose: it is
/// only ever asked about a parse std.json has already refused, so its job is
/// to find the field that explains the refusal, not to re-decide it.
fn fits(comptime T: type, value: std.json.Value) bool {
    if (T == Str) return value == .string;
    if (comptime patch_mod.isPatch(T)) return value == .null or fits(T.nilo_patch, value);
    // A type that parses itself decides, from the text — a string, or a
    // number read as its digits, since a bounded integer is one of these
    // and arrives as a JSON number (ADR 166).
    if (comptime convert.parsesItself(T)) {
        var buf: [64]u8 = undefined;
        const text = textOf(value, &buf) orelse return false;
        return T.nilo_parse(text) != null;
    }
    return switch (@typeInfo(T)) {
        .optional => |o| value == .null or fits(o.child, value),
        .bool => value == .bool,
        .int, .float => numberFits(T, value),
        // A string that is not one of the names is the whole reason an enum
        // field fails, so the tag has to be checked and not just the kind.
        .@"enum" => value == .string and std.meta.stringToEnum(T, value.string) != null,
        .@"struct" => value == .object,
        .@"union" => if (comptime tagOf(T) != null) value == .object else true,
        .pointer => |p| if (p.size == .slice and p.child == u8) value == .string else value == .array,
        else => true,
    };
}

/// Everything before `sep`, or the whole of it when there is none.
fn upTo(text: []const u8, sep: u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, text, sep)) |at| text[0..at] else text;
}

/// Whether this could be the authority of a URL: letters, digits, `.`, `-`,
/// `:` for a port, and `[`/`]` for an IPv6 literal. Deliberately narrow —
/// what it is guarding against is a forwarded value ending up inside a link
/// in an email, so anything it is not sure about is not a host.
fn isHostLike(text: []const u8) bool {
    if (text.len == 0 or text.len > 253) return false;
    for (text) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', ':', '[', ']' => {},
        else => return false,
    };
    return true;
}

/// Split a query string into decoded name/value pairs, in the request
/// arena. Called once per request that has one; a request without a `?`
/// never gets here and pays nothing.
///
/// Splitting happens before decoding, so a `%26` inside a value stays an
/// `&` of data instead of becoming a pair separator.
///
/// Walked once, the way the request head is (see `scan.zig`). `&` and `=` are
/// found together — one load, two compares — and each pair's `=` is picked out
/// of the mask with a shift and an `and` rather than by a fresh
/// `std.mem.indexOfScalar` over the pair.
///
/// The `&`s are counted first so the list is allocated once at the right size.
/// Growing it a pair at a time meant three allocations for
/// `?q=…&sort=…&page=…`, one per doubling. Whatever the count overshoots by —
/// an empty pair, a trailing `&` — is arena space nobody uses, and the arena
/// is emptied at the end of the request anyway.
///
/// Measured inside a request, `?q=hello%20world&sort=newest&page=3` went
/// 263ns → 191ns. What is left is mostly the six `percent.decode` calls, one
/// per name and value, and the one allocation the value with the `%20` needs.
pub fn parseQuery(arena: std.mem.Allocator, raw: []const u8) ![]const router.Param {
    if (raw.len == 0) return &.{};

    const params = try arena.alloc(router.Param, scan.countOf(raw, '&') + 1);
    var n: usize = 0;

    var pair_start: usize = 0;
    // Where this pair's first `=` is, as an absolute index. Null until one
    // turns up; a pair may span two blocks, so this outlives the block loop.
    var equals: ?usize = null;

    var i: usize = 0;
    while (i < raw.len) : (i += scan.lanes) {
        var amps = scan.positionsOf(raw, i, '&');
        var unclaimed = scan.positionsOf(raw, i, '=');

        while (amps != 0) : (amps &= amps - 1) {
            const bit: u5 = @intCast(@ctz(amps));
            const amp_at = i + bit;

            const mine = unclaimed & scan.below(bit);
            unclaimed &= ~scan.below(bit);
            if (equals == null and mine != 0) equals = i + @ctz(mine);

            try take(arena, params, &n, raw[pair_start..amp_at], relative(equals, pair_start));
            pair_start = amp_at + 1;
            equals = null;
        }
        // Whatever `=`s are left sit after the last `&` in this block, so they
        // belong to the pair still open.
        if (equals == null and unclaimed != 0) equals = i + @ctz(unclaimed);
    }
    try take(arena, params, &n, raw[pair_start..], relative(equals, pair_start));

    return params[0..n];
}

/// An absolute index inside the pair starting at `pair_start`, as an offset
/// into that pair.
fn relative(at: ?usize, pair_start: usize) ?usize {
    return if (at) |a| a - pair_start else null;
}

/// One `name=value` pair, decoded into the next slot. An empty pair is
/// skipped: `a=1&&b=2` and a trailing `&` both produce one.
fn take(
    arena: std.mem.Allocator,
    params: []router.Param,
    n: *usize,
    pair: []const u8,
    equals: ?usize,
) !void {
    if (pair.len == 0) return;
    const split_at = equals orelse pair.len;
    params[n.*] = .{
        .name = try percent.decode(arena, pair[0..split_at], true),
        .value = if (split_at < pair.len)
            try percent.decode(arena, pair[split_at + 1 ..], true)
        else
            "",
    };
    n.* += 1;
}

/// Decode the path params a match produced, in place in the match's own
/// array. Only a value that actually carries an escape allocates.
pub fn decodeParams(arena: std.mem.Allocator, params: []router.Param) !void {
    for (params) |*p| p.value = try percent.decode(arena, p.value, false);
}

const testing = std.testing;

test "what a client may put in a request id, and what it may not" {
    // Every id generator in use writes one of these.
    try testing.expect(usableRequestId("0123456789abcdef"));
    try testing.expect(usableRequestId("2f8a4c1e-5b6d-4a7f-9c3e-1d2b3a4c5d6e"));
    try testing.expect(usableRequestId("req_7Kd9.Xy-2"));

    // The two that matter: a newline forges a log line of its own, and in a
    // response header it splits the response.
    try testing.expect(!usableRequestId("abc\ndef"));
    try testing.expect(!usableRequestId("abc\r\nSet-Cookie: admin=1"));
    // A quote would end the string it is written into on the JSON line.
    try testing.expect(!usableRequestId("a\"b"));
    // And the shapeless ones.
    try testing.expect(!usableRequestId(""));
    try testing.expect(!usableRequestId("x" ** 65));
    try testing.expect(usableRequestId("x" ** 64));
}

test "generated ids do not repeat" {
    var seen: [64]u64 = undefined;
    for (&seen) |*slot| slot.* = nextId();
    for (seen, 0..) |a, i| {
        for (seen[i + 1 ..]) |b| try testing.expect(a != b);
    }
}

test "query pairs are split first, then decoded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const params = try parseQuery(arena.allocator(), "q=hello%20world&tag=a%26b&plus=a+b&bare&empty=");
    try testing.expectEqual(@as(usize, 5), params.len);
    try testing.expectEqualStrings("hello world", params[0].value);
    // Encoded as %26, so it is one value containing an ampersand — not the
    // separator between two pairs.
    try testing.expectEqualStrings("a&b", params[1].value);
    try testing.expectEqualStrings("a b", params[2].value);
    try testing.expectEqualStrings("", params[3].value);
    try testing.expectEqualStrings("", params[4].value);
}

test "an empty query string parses to nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try parseQuery(arena.allocator(), "")).len);
}

/// The parser this replaced: split on `&`, then look for `=` in each pair.
/// Kept so the block-at-a-time one can be held against it — a rewrite that is
/// faster and subtly different is worse than a slow one.
fn parseQueryTheOldWay(arena: std.mem.Allocator, raw: []const u8) ![]const router.Param {
    if (raw.len == 0) return &.{};
    var list: std.ArrayList(router.Param) = .empty;
    var pairs = std.mem.splitScalar(u8, raw, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        try list.append(arena, .{
            .name = try percent.decode(arena, pair[0..equals], true),
            .value = if (equals < pair.len)
                try percent.decode(arena, pair[equals + 1 ..], true)
            else
                "",
        });
    }
    return list.items;
}

test "the block-at-a-time query parser agrees with the one it replaced" {
    const cases = [_][]const u8{
        "",
        "a",
        "a=",
        "=a",
        "a=1",
        "a=1&b=2",
        "a=1&b=2&c=3",
        "a=1&&b=2",
        "a=1&",
        "&a=1",
        "&&&",
        "=",
        "a==1",
        "a=1=2",
        "bare&a=1",
        "q=hello%20world&tag=a%26b&plus=a+b&bare&empty=",
        "q=%",
        "q=%zz",
        "q=a%2Fb",
        // Long enough to cross block boundaries, with the delimiters landing
        // either side of them — which is what the mask arithmetic decides.
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=1&bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=2",
        "a=" ++ "x" ** 40 ++ "&b=" ++ "y" ** 40,
        "a" ** 31 ++ "=1",
        "a" ** 32 ++ "=1",
        "a" ** 33 ++ "=1",
        "x=1&" ++ "y" ** 31 ++ "=2",
        "x=1&" ++ "y" ** 32 ++ "=2",
        "x=1&" ++ "y" ** 33 ++ "=2",
        "%20" ** 20,
        "a=1&" ** 20,
    };

    for (cases) |raw| {
        var mine_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer mine_arena.deinit();
        var theirs_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer theirs_arena.deinit();

        const mine = try parseQuery(mine_arena.allocator(), raw);
        const theirs = try parseQueryTheOldWay(theirs_arena.allocator(), raw);

        testing.expectEqual(theirs.len, mine.len) catch |err| {
            std.debug.print("query: \"{s}\"\n", .{raw});
            return err;
        };
        for (theirs, mine) |want, got| {
            testing.expectEqualStrings(want.name, got.name) catch |err| {
                std.debug.print("query: \"{s}\"\n", .{raw});
                return err;
            };
            testing.expectEqualStrings(want.value, got.value) catch |err| {
                std.debug.print("query: \"{s}\"\n", .{raw});
                return err;
            };
        }
    }
}

test "a `=` in one pair does not split the next one" {
    // The danger the mask creates: an `=` from an earlier pair being taken as
    // this pair's. `bare` has none and must come out with an empty value.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const params = try parseQuery(arena.allocator(), "a=1&bare&b=2");
    try testing.expectEqual(@as(usize, 3), params.len);
    try testing.expectEqualStrings("bare", params[1].name);
    try testing.expectEqualStrings("", params[1].value);
    try testing.expectEqualStrings("b", params[2].name);
    try testing.expectEqualStrings("2", params[2].value);
}

test "a query string is split in one allocation, whatever it holds" {
    // The other half of the request's allocation budget: one for the list, and
    // one more only for a value that really has an escape in it.
    const budget = @import("budget.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Warm it, so growing the arena is not what is being counted.
    _ = try parseQuery(arena.allocator(), "a=1&b=2&c=3&d=4");
    _ = arena.reset(.retain_capacity);

    var counting = budget.Counting{ .child = arena.allocator() };
    _ = try parseQuery(counting.allocator(), "a=1&b=2&c=3&d=4&e=5&f=6");
    try testing.expectEqual(@as(usize, 1), counting.allocs);

    counting.reset();
    _ = try parseQuery(counting.allocator(), "q=hello%20world&sort=newest");
    // The list, plus the one value that had something to decode.
    try testing.expectEqual(@as(usize, 2), counting.allocs);
}
