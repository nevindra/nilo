//! Ctx — one request in flight, and all the control over it. This is
//! nilo's real API (ADR 0003): the typed layer above it turns into calls
//! to this while compiling.
//!
//! Every piece of text coming out of Ctx is a `Str`: it lives as long as
//! the request, and is copied deliberately with `.keep()` if it needs to
//! live longer (ADR 0004). Fields prefixed with `_` belong to nilo's
//! internals — the request arena behind them is never touched directly by
//! users.

const std = @import("std");
const body_mod = @import("body.zig");
const bulkhead = @import("bulkhead.zig");
const convert_mod = @import("convert.zig");
const cookie_mod = @import("cookie.zig");
const http1 = @import("http1.zig");
const json_mod = @import("json.zig");
const password_mod = @import("password.zig");
const router = @import("router.zig");
const scan = @import("scan.zig");
const sendfile_mod = @import("sendfile.zig");
const service_mod = @import("service.zig");
const static_mod = @import("static.zig");
const stream_mod = @import("stream.zig");
const str_mod = @import("nilo_core");
const patch_mod = @import("patch.zig");
const websocket = @import("websocket.zig");
const percent = @import("nilo_core").percent;
const fail = @import("fail.zig");
const watchdog = @import("watchdog.zig");
const Str = str_mod.Str;

/// What one request is allowed to do. Filled from `listen()`'s options and
/// carried on the Ctx, so a limit is one field away rather than a reach
/// back into the App. The defaults are what a test driving a handler
/// directly gets, and they are `bulkhead.Options`' defaults.
pub const Limits = struct {
    max_body: usize = 1024 * 1024,
    trusted_hops: u8 = 0,
    block_warning_ms: u32 = 250,
};

/// The size `sendJson` reserves before serialising. Not a limit — a
/// bigger response simply grows past it.
pub const json_hint = 512;

/// How many response headers a request holds without reaching for the arena.
///
/// Six covers what the built-in middleware set puts on one response: CORS
/// one to three, and a static file up to five — `ETag`, `Cache-Control`,
/// `Accept-Ranges`, and, once a file has a gzipped copy beside it,
/// `Vary` and `Content-Encoding`. It was four until gzip added those two,
/// and four would have meant every compressed asset spilling to the arena
/// for one header over.
///
/// Each slot is two slices on a Ctx that already lives on the fiber's
/// stack, so the two extra cost 64 bytes of a stack that is two pages and
/// nothing at all in allocations — which is the invariant they are here to
/// keep (ADR 0018).
const inline_headers = 6;

/// One resolved value, kept for the rest of the request that asked for it.
///
/// Keyed by type name rather than by anything cleverer for the same reason
/// the service registry is (ADR 0006): the list is two entries long in
/// practice, and `@typeName` is normally the very same literal, so finding
/// one is a pointer compare.
const Resolved = struct {
    type_name: []const u8,
    value: *anyopaque,
};

pub const Ctx = struct {
    method: http1.Method,

    _arena: std.mem.Allocator,
    _lifetime: *const str_mod.Lifetime,
    _in: *std.Io.Reader,
    _out: *std.Io.Writer,
    _request: *const http1.Request,
    _path: []const u8,
    /// The query string as it arrived, still encoded. `_query_params` is
    /// the decoded form and is what `query()` reads.
    _query: []const u8,
    _query_params: []const router.Param = &.{},
    /// The whole request head, request line included. Headers are read out
    /// of it on demand rather than collected up front — most handlers ask
    /// for none, and the ones that ask, ask for two.
    _head: []const u8,
    /// Whether `_head` is still the connection's own read buffer rather than a
    /// copy in the request arena. True for a request nothing will read from
    /// the connection for again, which is most of them — see the copy in
    /// `App.handleRequest`, and `aboutToRead` for what keeps it honest.
    _head_borrowed: bool = false,
    /// This connection's time limits (ADR 0023). Every path that reads from
    /// the connection arms the one that applies to it first; `.off` — which
    /// is the default, and what a test driving App directly gets — makes
    /// every one of those calls do nothing.
    _deadlines: bulkhead.Deadlines = .off,
    /// The connection's second way to be woken — by another fiber rather than
    /// by the client. Only a WebSocket that has been registered for broadcast
    /// ever uses it; `.off` is the default, and what a test driving App
    /// directly gets, and it answers "go and read" to everything.
    _waker: bulkhead.Waker = .off,
    /// Where `upgrade` leaves the socket and the loop that is going to run it.
    ///
    /// Points at a slot in the *connection* loop's frame, which is the whole
    /// point: the loop runs from there, after this request's machinery has
    /// unwound (ADR 0071). Null for a `Ctx` built by hand in a test, and for
    /// every request that is not a WebSocket, which is all but a few.
    _handover: ?*?websocket.Handover = null,
    /// Who the connection came from, as the socket reports it. Empty when
    /// there is no socket — a test driving App directly, a Unix socket.
    _peer: bulkhead.Peer = .{},
    /// This request's id, once somebody has asked for one. Null until then,
    /// so a request nobody ties to anything pays nothing for the option.
    _request_id: ?Str = null,
    /// Where a generated id is written. Sixteen hex characters, on the Ctx
    /// and therefore on the fiber's stack — not on the connection, whose
    /// 4,669 idle bytes are an invariant rather than a budget (ADR 0018).
    _request_id_buf: [16]u8 = undefined,
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
    _params: []const router.Param,
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
    /// got. App reads it to discard whatever is left (ADR 0020).
    _incoming: ?body_mod.Progress = null,
    /// Set when reading the body went wrong in a way that leaves the
    /// connection at an unknown byte. App reads it and does not reuse the
    /// connection.
    _stream_desynced: bool = false,
    _sent: bool = false,
    /// Set between `stream()` and the stream's `finish()`, which clears it.
    /// App reads it to find a body nobody ended (ADR 0020).
    _stream: ?stream_mod.Open = null,
    /// The blocking detector's stopwatch for this request, or null when
    /// there is no request behind this Ctx — a handler called straight from
    /// a test. Held here rather than looked up: `Ctx.send` is on the path of
    /// every request, and finding it through the fiber slot instead cost a
    /// measured 45ns of the 612 a whole request takes (ADR 0034).
    _watch: ?*watchdog.Watch = null,
    /// Set when this request took the connection over — a stream, a body
    /// reader, a WebSocket. Once set it stays set, which is what separates
    /// it from `_stream` above: a stream that was finished properly is
    /// still a request that spent its time on the socket, and the blocking
    /// detector has to leave it alone either way (ADR 0034).
    _took_over: bool = false,
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
    /// Resolved values already worked out for this request (ADR 0016).
    /// Stays empty — and costs nothing — on a request that asks for none.
    _resolved: std.ArrayList(Resolved) = .empty,

    /// Memory that lasts exactly as long as this request.
    ///
    /// Reset when the request ends, so nothing taken from here needs — or
    /// may have — a `free`. It is what `Str` points into, and it is the
    /// reason a `Str` never escapes its request without `.keep()`
    /// (ADR 0004).
    ///
    /// Public because a module beside the framework has to be able to
    /// allocate for the request without reaching into a field: `nilo_sql`
    /// fills its rows out of here, and rows a handler returns then live
    /// exactly as long as the response that carries them.
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
    /// (ADR 0004).
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
    /// nobody has asked yet, and handed back as-is if they have (ADR 0016).
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
        const wanted = @typeName(V);
        for (self._resolved.items) |entry| {
            if (entry.type_name.ptr != wanted.ptr and !std.mem.eql(u8, entry.type_name, wanted))
                continue;
            return @as(*const V, @ptrCast(@alignCast(entry.value))).*;
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

    /// A path param from the route pattern: `/users/:id` → `param("id")`.
    /// Percent-decoded, so `/users/wati%20sari` gives `wati sari`.
    pub fn param(self: *const Ctx, name: []const u8) ?Str {
        for (self._params) |p| {
            if (std.mem.eql(u8, p.name, name)) return Str.fromRequest(p.value, self._lifetime);
        }
        return null;
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
    /// scan of a few hundred bytes on the few that look twice.
    pub fn header(self: *const Ctx, name: []const u8) ?Str {
        var headers = http1.HeaderIterator.from(self._head);
        while (headers.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return Str.fromRequest(h.value, self._lifetime);
        }
        return null;
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

    /// `n` bytes from the operating system's entropy source, off the event
    /// loop (ADR 0046).
    ///
    /// ```zig
    /// const key = id.v7(try c.entropy(id.Uuid.v7_entropy), nilo.nowMillis());
    /// ```
    ///
    /// **A method rather than a free function, and that is the design.**
    /// Entropy comes from a syscall, and a syscall made straight from a
    /// fiber stops every request sharing that thread (ADR 0002, ADR 0014).
    /// This one goes through the Bulkhead, so the fiber parks on the
    /// Engine's blocking pool and the detector is told the handler is not
    /// the one holding it (ADR 0034). Being reachable only from a `Ctx` is
    /// what says *this call costs a wait, and here is where the wait is
    /// paid for* — which is why `nilo_id` takes its randomness as an
    /// argument rather than fetching it: down there, nobody is paying.
    ///
    /// By value rather than into a buffer the caller declares, so it fits
    /// in the expression that uses it. `n` is comptime, the array is on the
    /// stack, and nothing is allocated.
    ///
    /// A program with no loop in it needs none of this: `std.Io.randomSecure`
    /// is the same bytes, and there is no fiber to park.
    pub fn entropy(self: *const Ctx, comptime n: usize) ![n]u8 {
        _ = self;
        var out: [n]u8 = undefined;
        try bulkhead.randomSecure(&out);
        return out;
    }

    /// Hash a password: salted from `Ctx.entropy`, off the loop, and behind
    /// the Gate that says how many may run at once (ADR 0048).
    ///
    /// ```zig
    /// const stored = try c.hashPassword(gpa, form.password);
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
    /// arena is the wrong place for it (ADR 0018).
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
    /// if (!try c.verifyPassword(gpa, if (row) |r| r.password else null, form.password))
    ///     return nilo.fail(401, "that is not a sign-in");
    /// ```
    ///
    /// **`stored` is optional, and null is the point rather than a
    /// convenience.** A sign-in for an address with no account has no hash to
    /// check; returning early there answers in a millisecond instead of
    /// thirteen and turns the form into a list of which addresses are
    /// registered. Passing null does the work anyway and answers false. There
    /// is no signature here that lets the fast wrong version be written.
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
    /// form is a list of addresses again (ADR 0049). A stored hash is always
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
    /// (ADR 0030).
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
        var headers = http1.HeaderIterator.from(self._head);
        while (headers.next()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "cookie")) continue;
            if (cookie_mod.find(h.value, name)) |value| {
                return Str.fromRequest(value, self._lifetime);
            }
        }
        return null;
    }

    /// The address the connection itself came from — the proxy's, when
    /// there is a proxy. Never forgeable, and never null: this is what the
    /// kernel says, not what a header claims.
    ///
    /// Empty text when there is no socket, which is what a handler called
    /// straight from a test gets.
    pub fn peer(self: *const Ctx) bulkhead.Peer {
        return self._peer;
    }

    /// The address of the client, looking through however many proxies
    /// `listen()` was told stand in front (`.trusted_hops`).
    ///
    /// With the default of zero this is `peer()` — the connection's own
    /// address — because `X-Forwarded-For` is a header like any other and
    /// a server that believes it without being told to has handed every
    /// client the ability to be any address it likes. Rate limits, audit
    /// logs and blocklists are the things that read this, and they are
    /// exactly the things worth lying to.
    ///
    /// Counted from the right, so the entries a trusted proxy wrote are
    /// the only ones reachable and anything the client put in the header
    /// itself stays to the left, unread. A header with fewer entries than
    /// there are hops means the chain is not the one configured, so the
    /// socket's address is used rather than the closest guess.
    pub fn clientIp(self: *const Ctx) Str {
        const hops = self._limits.trusted_hops;
        if (hops == 0) return Str.fromRequest(self._peer.address(), self._lifetime);

        const forwarded = self.header("X-Forwarded-For") orelse
            return Str.fromRequest(self._peer.address(), self._lifetime);

        // Walk right to left, counting entries. `hops` of them belong to
        // proxies; the one before those is the client.
        var rest = forwarded.view();
        var seen: u8 = 0;
        while (rest.len > 0) {
            const at = std.mem.lastIndexOfScalar(u8, rest, ',');
            const entry = std.mem.trim(u8, if (at) |i| rest[i + 1 ..] else rest, " \t");
            seen += 1;
            if (seen == hops) {
                if (entry.len == 0) break;
                return Str.fromRequest(entry, self._lifetime);
            }
            rest = if (at) |i| rest[0..i] else "";
        }
        return Str.fromRequest(self._peer.address(), self._lifetime);
    }

    /// The whole request body, read once into the request arena. Chunked
    /// and Content-Length look the same from here — the handler asks for
    /// the body, not for the way it arrived.
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
        // by going quiet (ADR 0023). One choke point means a new way to
        // read from the connection gets its limit without anybody
        // remembering to give it one. A WebSocket takes the limit back off,
        // once it is the thing doing the reading.
        self._deadlines.armBody();
    }

    pub fn body(self: *Ctx) !Str {
        if (self._body == null) {
            // Waiting for a client to finish sending is not the handler
            // holding its thread — the fiber parks and the thread serves
            // somebody else. Said out loud, or a slow uploader would be
            // reported as a blocking handler (ADR 0034).
            const w = watchdog.waiting(self._watch);
            defer watchdog.waited(self._watch, w);

            if (self._request.chunked) {
                self.aboutToRead();
                self._body = http1.readChunkedBody(self._in, self._arena, self._limits.max_body) catch |err| {
                    // The chunk sizes and the stream have come apart, so
                    // where this body ends is now a guess. Reading on and
                    // hoping to land on the next request is exactly how a
                    // smuggled request gets through — even when the bytes
                    // happen to line up, which they sometimes will.
                    self._stream_desynced = true;
                    return err;
                };
            } else {
                if (self._request.content_length > self._limits.max_body) return error.BodyTooLarge;
                // A body of nothing reads nothing, so it is not a read.
                if (self._request.content_length > 0) self.aboutToRead();
                const b = try self._arena.alloc(u8, @intCast(self._request.content_length));
                try self._in.readSliceAll(b);
                self._body = b;
            }
        }
        return Str.fromRequest(self._body.?, self._lifetime);
    }

    /// The request body, read in pieces rather than all at once — for the
    /// ones too big to hold (ADR 0020).
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

        // A Content-Length says up front how big it is, so a body over the
        // limit is refused before a byte of it is read. A chunked one has to
        // be counted as it arrives.
        if (!self._request.chunked and self._request.content_length > options.max_bytes) {
            return error.BodyTooLarge;
        }
        if (self._request.chunked or self._request.content_length > 0) self.aboutToRead();

        self._took_over = true;
        self._incoming = .start(self._request, options.max_bytes);
        return .init(self._in, &self._incoming.?);
    }

    /// Parse the request body as JSON into `T`. The result lives in the
    /// request arena — `keep` the fields you need for longer.
    ///
    /// `Str` fields get stamped with the request lifetime, so using one
    /// after the request has finished trips the debug trap just like any
    /// other Str (ADR 0004).
    pub fn json(self: *Ctx, comptime T: type) !T {
        const b = (try self.body()).view();
        var value = std.json.parseFromSliceLeaky(T, self._arena, b, .{}) catch |err|
            return describeBadBody(T, self._arena, b, err);
        str_mod.stamp(&value, self._lifetime);
        return value;
    }

    /// Parse the request body as an HTML form into `T` — the `*Ctx` way in
    /// to what `Form(T)` does for a typed handler (ADR 0031).
    ///
    /// `application/x-www-form-urlencoded` and `multipart/form-data` are
    /// both read; which one arrived is the browser's business, not the
    /// endpoint's. The whole body is held in memory and bounded by
    /// `max_body`, exactly as `json` is.
    ///
    /// Every `Str` in the result — a file's bytes included — points into the
    /// request arena and dies with the request, so `keep` is what takes one
    /// out of it (ADR 0004).
    pub fn form(self: *Ctx, comptime T: type) !T {
        // Read before the body, while it is certain nothing has moved the
        // head: `body()` may read from the connection, and on a request with
        // a body the head has been copied for exactly that reason.
        const content_type = if (self.header("Content-Type")) |h| h.view() else null;
        const b = (try self.body()).view();
        return @import("form.zig").readInto(T, self._arena, self._lifetime, content_type, b);
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
        outcomes: *[@typeInfo(T).@"struct".fields.len]convert_mod.Outcome,
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
        outcomes: *[@typeInfo(T).@"struct".fields.len]convert_mod.Outcome,
    ) !T {
        const b = (try self.body()).view();
        if (std.json.parseFromSliceLeaky(T, self._arena, b, .{})) |parsed| {
            var value = parsed;
            str_mod.stamp(&value, self._lifetime);
            for (outcomes) |*o| o.* = .{};
            return value;
        } else |err| {
            return collectBadBody(T, self._arena, self._lifetime, b, err, outcomes);
        }
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
        const stopping = self._stopping orelse return true;
        return !stopping.load(.acquire);
    }

    // ---- the response side ----

    /// Add a response header. Set it before sending — a response is
    /// flushed the moment it is sent, so there is nothing left to change
    /// afterwards (ADR 0009).
    ///
    /// `name` and `value` are copied into the request arena, so passing a
    /// value you built on the stack is safe. Setting a header the
    /// framework writes itself — Content-Type, Content-Length, Connection
    /// — is refused: a response carrying two of those is malformed, and in
    /// the case of Content-Length it is a request-smuggling bug.
    /// Content-Type is chosen through `send` instead.
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

    fn extraHeadersMutable(self: *Ctx) []http1.Header {
        if (self._extra_spill.items.len > 0) return self._extra_spill.items;
        return self._extra_inline[0..self._extra_n];
    }

    fn putHeader(self: *Ctx, entry: http1.Header) !void {
        if (http1.isReservedHeader(entry.name)) return error.ReservedHeader;
        // Setting a header twice is somebody changing their mind, so the
        // second call replaces the first — except for the one header a
        // response is *required* to send more than one of. Two cookies are
        // two `Set-Cookie` lines and cannot be folded into one
        // (`http1.repeats`).
        if (!http1.repeats(entry.name)) {
            for (self.extraHeadersMutable()) |*h| {
                if (std.ascii.eqlIgnoreCase(h.name, entry.name)) {
                    h.* = entry; // last one wins, rather than sending both
                    return;
                }
            }
        }

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

    /// Send a cookie back with this response (ADR 0030).
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

    /// Send the client somewhere else (ADR 0032).
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

    pub fn send(self: *Ctx, status: u16, content_type: []const u8, response_body: []const u8) !void {
        std.debug.assert(!self._sent); // one request, one response
        self._sent = true;
        self._status = status;

        // Putting the answer on the wire is nilo waiting on the client, not
        // the handler running. A client too slow to take a large response
        // parks this fiber for as long as it takes, and without this that
        // would be reported as a handler holding its thread (ADR 0034).
        const w = watchdog.waiting(self._watch);
        defer watchdog.waited(self._watch, w);

        // A handler need not know this is a HEAD: it assembles a response
        // as usual, and what must not go out is filtered here.
        if (self.method == .HEAD) return http1.writeResponseHeadOnly(
            self._out,
            status,
            http1.statusPhrase(status),
            content_type,
            response_body.len,
            self.keepAlive(),
            self.extraHeaders(),
        );
        try http1.writeResponse(
            self._out,
            status,
            http1.statusPhrase(status),
            content_type,
            response_body,
            self.keepAlive(),
            self.extraHeaders(),
        );
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
        try self.send(status, "application/json", out.written());
    }

    /// Answer with an open file, without ever holding it in memory
    /// (ADR 0037).
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
    /// Everything a static file's answer carries, this carries too — an
    /// `ETag`, a `Cache-Control` and `Accept-Ranges: bytes` on every answer,
    /// a 304 for a matching `If-None-Match`, a 206 with a `Content-Range`
    /// for a `Range`, and `If-Range` compared against the tag so a download
    /// resumed against a file that has changed underneath starts again
    /// rather than arriving corrupt (ADR 0021). The bytes go from the file
    /// to the socket without passing through this process.
    ///
    /// A handler that knows it is answering with a file before it runs
    /// returns `nilo.FileBody` instead, which is the same response and
    /// lets the generated API description say so (ADR 0032's move for
    /// redirects, applied here).
    pub fn sendFile(self: *Ctx, contents: sendfile_mod.Contents) !void {
        return sendfile_mod.send(self, contents);
    }

    // ---- answering in pieces ----

    /// Start a response whose length is not known yet, and get back
    /// something to write the pieces into (ADR 0020).
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
    pub fn stream(self: *Ctx, status: u16, content_type: []const u8) !stream_mod.Stream {
        return self.streamWith(status, content_type, .{});
    }

    /// `stream`, with the buffer size turned up or down.
    pub fn streamWith(
        self: *Ctx,
        status: u16,
        content_type: []const u8,
        options: stream_mod.Options,
    ) !stream_mod.Stream {
        std.debug.assert(!self._sent); // one request, one response

        // HTTP/1.0 has no chunked framing, so the end of the body can only
        // be the end of the connection — which means this connection cannot
        // carry another request whatever either side asked for.
        const chunked = self._request.minor_version == 1;
        if (!chunked) self._force_close = true;

        self._sent = true;
        self._status = status;
        self._took_over = true;
        self._stream = .{ .chunked = chunked, .drop = self.method == .HEAD };

        try http1.writeStreamHead(
            self._out,
            status,
            http1.statusPhrase(status),
            content_type,
            chunked,
            self.keepAlive(),
            self.extraHeaders(),
        );

        // The one allocation a stream makes, made once. Everything written
        // afterwards goes through this buffer and allocates nothing.
        const buffer = try self._arena.alloc(u8, options.buffer);
        return .init(buffer, self._out, self._stopping, &self._stream);
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
    /// Turn this request into a WebSocket connection (ADR 0022, ADR 0071).
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
    /// **The loop is a function rather than the tail of the handler, and that
    /// is a memory decision.** A handler that loops in place is suspended
    /// 1,608 bytes inside the request machinery for the life of the socket —
    /// the `Ctx`, the parsed head, the route match, none of which the loop can
    /// reach and all of which a suspended fiber holds (ADR 0063). Handing the
    /// loop back lets the request unwind first: measured, an upgraded
    /// connection nobody has spoken to went from 9,290 bytes to 5,186.
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

        slot.* = .{
            .socket = socket,
            .run = websocket.runner(loop, State),
            .path = self._path,
        };
        if (@sizeOf(State) > 0) {
            const carried: *State = @ptrCast(@alignCast(&slot.*.?.state));
            carried.* = state;
        }
    }

    /// The handshake itself: check the request is really one, answer 101, and
    /// build the Socket. Split out from `upgrade` because both the connection
    /// loop and a hand-built `Ctx` need it and only one of them hands the loop
    /// back.
    fn handshake(self: *Ctx, options: websocket.Options) !websocket.Socket {
        std.debug.assert(!self._sent); // one request, one response

        if (self.method != .GET) {
            return fail.badRequest("a WebSocket handshake has to be a GET, not a {s}", .{@tagName(self.method)});
        }
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

        // From here the answer is written, so nothing above may fail.
        self._sent = true;
        self._status = 101;
        self._took_over = true;
        // The connection stops being HTTP at the blank line below, so it can
        // never carry another request.
        self._force_close = true;

        const answer = websocket.accept(key.view());
        try websocket.writeAcceptance(self._out, &answer, options.protocol);

        // A WebSocket is allowed to sit quiet. A chat tab with nobody typing
        // is working correctly, and the read limit that protects the HTTP
        // side would close it in half a minute. What is worth catching here
        // is a client that has gone away without saying so, and the answer
        // to that is a ping it does not answer — a WebSocket feature, with a
        // frame to send and a reply to wait for, rather than a deadline
        // (ADR 0023). Writes keep their limit: they are how the server finds
        // out the client stopped listening.
        self._deadlines.readForever();

        return .{
            ._in = self._in,
            ._out = self._out,
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
        };
    }

    pub fn events(self: *Ctx) !stream_mod.Events {
        try self.setStaticHeader("Cache-Control", "no-cache");
        try self.setStaticHeader("X-Accel-Buffering", "no");
        return .{ .stream = try self.stream(200, stream_mod.Events.content_type) };
    }
};

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

/// Turn a failed body parse into a 400 that names what is wrong with it,
/// falling back to `err` when nothing here can do better.
fn describeBadBody(
    comptime T: type,
    arena: std.mem.Allocator,
    body: []const u8,
    err: anyerror,
) anyerror {
    // Anything but a struct is somebody using `Ctx.json` directly for a
    // list or a number, where there are no field names to talk about.
    if (@typeInfo(T) != .@"struct") return err;

    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return fail.badRequest(
        "the request body is empty. This endpoint expects a JSON object with: {s}",
        .{comptime fieldList(T)},
    );

    // Read again with no shape to satisfy. If even this fails, the text is
    // not JSON at all, and where it stopped making sense is the useful part.
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

    if (dynamic != .object) return fail.badRequest(
        "the request body has to be a JSON object with: {s} — this is {s}",
        .{ comptime fieldList(T), kindOf(dynamic) },
    );

    return describeObject(T, arena, dynamic.object, "", max_body_depth) orelse err;
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
    outcomes: *[@typeInfo(T).@"struct".fields.len]convert_mod.Outcome,
) !T {
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return fail.badRequest(
        "the request body is empty. This endpoint expects a JSON object with: {s}",
        .{comptime fieldList(T)},
    );

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

    if (dynamic != .object) return fail.badRequest(
        "the request body has to be a JSON object with: {s} — this is {s}",
        .{ comptime fieldList(T), kindOf(dynamic) },
    );

    const object = dynamic.object;

    var it = object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!hasField(T, name)) return fail.badRequest(
            "the request body has a field \"{s}\" this endpoint does not know. It takes: {s}",
            .{ name, comptime fieldList(T) },
        );
    }

    var out: T = undefined;
    var any = false;

    inline for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
        outcomes[i] = .{};

        if (object.get(f.name)) |given| {
            // Only a string has text to quote back. A list or an object is
            // described by its kind instead, which is what `kind` is for.
            if (given == .string) outcomes[i].given = Str.fromRequest(given.string, lifetime);

            if (std.json.parseFromValueLeaky(f.type, arena, given, .{})) |value| {
                @field(out, f.name) = value;
            } else |_| if (!fits(f.type, given)) {
                // A word that is not one of the choices is the one wrong
                // value that is the right *kind*, and it gets the sentence a
                // bad `?stage=` gets rather than one arguing with itself.
                if (given == .string and comptime choicesOf(f.type) != null) {
                    outcomes[i].reason = .not_a_choice;
                } else {
                    outcomes[i].reason = .wrong_kind;
                    outcomes[i].kind = kindOf(given);
                }
                any = true;
                if (f.defaultValue()) |default| @field(out, f.name) = default;
            } else {
                return describeField(f.type, arena, given, f.name, max_body_depth) orelse err;
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
    comptime depth: u8,
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
        if (!hasField(T, name)) return fail.badRequest(
            "the request body has a field \"{s}\" this endpoint does not know. It takes: {s}",
            .{ nameWithin(arena, where, name), comptime fieldList(T) },
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
            if (describeField(f.type, arena, given, nameWithin(arena, where, f.name), depth)) |found| {
                return found;
            }
        }
    }

    return null;
}

/// What is wrong with one value, given the type it landed in. Answers about
/// this value first, then about whatever is inside it.
fn describeField(
    comptime T: type,
    arena: std.mem.Allocator,
    given: std.json.Value,
    name: []const u8,
    comptime depth: u8,
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
        return fail.badRequest(
            "\"{s}\" has to be {s}, not {s}",
            .{ name, comptime expectedOf(T), kindOf(given) },
        );
    }

    if (depth == 0) return null;
    // An optional sent as null fits and holds nothing to look inside.
    if (given == .null) return null;

    const Inner = if (comptime patch_mod.isPatch(T)) T.nilo_patch else switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };

    if (Inner != Str) switch (@typeInfo(Inner)) {
        .@"struct" => return describeObject(Inner, arena, given.object, name, depth - 1),
        .pointer => |p| {
            // `[]const u8` is text, which has nothing inside it to describe.
            if (p.size != .slice or p.child == u8) return null;
            for (given.array.items, 0..) |item, i| {
                const at = std.fmt.allocPrint(arena, "{s}[{d}]", .{ name, i }) catch name;
                if (describeField(p.child, arena, item, at, depth - 1)) |found| return found;
            }
        },
        else => {},
    };

    return null;
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
        var out: []const u8 = "";
        for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ f.name;
            if (f.default_value_ptr != null) out = out ++ " (optional)";
        }
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
/// would stop every other request sharing that thread (ADR 0002, ADR 0014).
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

/// Whether a JSON value could have become a `T`. Loose on purpose: it is
/// only ever asked about a parse std.json has already refused, so its job is
/// to find the field that explains the refusal, not to re-decide it.
fn fits(comptime T: type, value: std.json.Value) bool {
    if (T == Str) return value == .string;
    if (comptime patch_mod.isPatch(T)) return value == .null or fits(T.nilo_patch, value);
    return switch (@typeInfo(T)) {
        .optional => |o| value == .null or fits(o.child, value),
        .bool => value == .bool,
        .int, .float => value == .integer or value == .float or value == .number_string,
        // A string that is not one of the names is the whole reason an enum
        // field fails, so the tag has to be checked and not just the kind.
        .@"enum" => value == .string and std.meta.stringToEnum(T, value.string) != null,
        .@"struct" => value == .object,
        .pointer => |p| if (p.size == .slice and p.child == u8) value == .string else value == .array,
        else => true,
    };
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
