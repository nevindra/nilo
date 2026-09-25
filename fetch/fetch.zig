//! nilo_fetch — calling somebody else's HTTP API, from inside a request.
//!
//! ```zig
//! var api: fetch.Client = .init(gpa, .{});
//! try app.provide(&api);
//!
//! fn charge(api: *fetch.Client, c: *nilo.Ctx) !Receipt {
//!     const res = try api.postJson(c, "https://api.example.com/v1/charges", .{ .amount = 500 }, .{});
//!     if (res.status == .too_many_requests) return nilo.fail.status(503, "retry after {s}", .{res.header("retry-after") orelse "a while"});
//!     if (!res.ok()) return nilo.fail.badGateway(c, "the payment service said no");
//!     return res.json(Receipt, c);
//! }
//! ```
//!
//! **`std.http.Client` is already the client.** Connection pool, HTTP/1.1,
//! TLS — 1,867 lines of it, on top of 1,670 lines of `std.crypto.tls.Client`.
//! This module is 4% of that and none of it is protocol: it is the policy std
//! leaves to the caller, and every piece of it closes a hole that is real on a
//! server rather than in a script
//! ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)).
//!
//! - **A gate.** `std.http.Client`'s pool bounds *idle* connections
//!   (`free_size`, 32 by default) and does not bound in-use ones at all. 500
//!   concurrent handlers is 500 live connections, and an HTTPS one holds
//!   59,151 bytes of buffers — 29.6 MB nobody asked for, plus 500 handshakes.
//! - **A deadline.** An endpoint that accepts a connection and then says
//!   nothing holds a handler until the process dies. `std.http.Client` has no
//!   deadline field, so the bound is on the fiber
//!   ([ADR 056](../docs/adr/056-the-way-out-was-open-the-clock-was-not.md))
//!   — and where there is no fiber, because the `Io` is a plain
//!   `std.Io.Threaded` with no Engine over it, the call is run as a task of
//!   that `Io` and the task is what gets cancelled
//!   ([ADR 056](../docs/adr/056-the-way-out-was-open-the-clock-was-not.md)).
//!   `timeout_ms` means the same thing at either end. And a second clock
//!   beside it, on silence rather than on the call: `stall_ms` ends a call
//!   whose peer has sent nothing for that long, which is the bound a
//!   transfer can set when the only honest `timeout_ms` is zero
//!   ([ADR 056](../docs/adr/056-the-way-out-was-open-the-clock-was-not.md)).
//! - **A bounded drain, and the drain itself.** `std.http.Client.Request.deinit`
//!   does two different things depending on the state the body was left in, and
//!   both of them are wrong for a client that refuses bodies. From
//!   `.received_head` — nothing read — it calls `discardRemaining()` with no
//!   limit, so refusing a 500 MB object still downloads it. From a body that
//!   was *started* and stopped it does the opposite: that state falls into its
//!   switch's `else` and the connection is marked closing however few bytes are
//!   left. So `Exchange.dropIfDrainIsDearer` supplies both halves — the ceiling
//!   for the first case, and the finishing read for the second, without which
//!   `max_drain` names a limit that decides nothing on the path that reaches
//!   it. It is asked against the length the response announced; the first
//!   version asked how many bytes were *buffered*, which is one read buffer,
//!   and therefore never fired on the case it was written for.
//! - **A body ceiling**, enforced while reading rather than checked after, so
//!   a sender lying about `content-length` cannot get past it.
//! - **A Scope**, so the body comes back as a `Str` that lives exactly as long
//!   as the request does and nobody frees anything.
//! - **A target**, for the service a program calls more than once: its base
//!   URL and the headers it always wants, as a type opened once on the client
//!   and asked for by type in a handler, with a path template whose segments
//!   are encoded on the way in — `stripe.get(c, "/v1/charges/{}", .{id}, .{})`
//!   ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)).
//!
//! Two shapes, and the second is the first with the middle left out. An
//! `Exchange` is one call held open — the response head readable, the body
//! taken into the Scope or piped straight out. `Client.get` and the calls
//! beside it are an Exchange begun and finished in one line, which is what a
//! handler calling somebody's JSON API wants: `postJson` writes the value
//! out and says `content-type`, `withQuery` puts a struct on the URL
//! percent-encoded, and the `Response` keeps its header block so the
//! `Retry-After` off a 429 is one call away
//! ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md),
//! [ADR 187](../docs/adr/187-a-head-that-outlives-its-body.md)).
//!
//! ## Where it sits
//!
//! A **Fitting**: it borrows the event loop and owns no destination. It is
//! handed `std.Io` and given an address on every call, so it holds no
//! connection to any named system — which is what separates it from a Service
//! like `nilo_sql`, which holds a pool to a database named in its URL. It
//! imports `nilo_core` and nothing else, and `zig build layering` holds that.
//!
//! ## What it is not
//!
//! Not a retry policy, not a circuit breaker, not a rate limiter. Those are
//! decisions about somebody else's service — how many times, how long between,
//! what counts as failure — and they belong to the caller who knows what that
//! service promises. What is here is the part that is the same for everybody:
//! do not hold a connection forever, do not hold more than you meant to, and
//! do not read more than you asked for.

const std = @import("std");
const core = @import("nilo_core");

const Str = core.Str;

/// A canned server for a suite of your own: `fetch.testing.Canned`, which
/// answers what `reply` told it to over a real loopback socket on
/// `std.Io.Threaded`. What the module's own tests drive, exported
/// ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)).
pub const testing = @import("testing.zig");

/// A service's base URL and standing headers as a type of its own, opened
/// once on the client: `const Stripe = fetch.Target("stripe", .{});`
/// ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)).
/// `fetch.target.Options` is what the type carries and `fetch.target.Open`
/// what `open` takes.
pub const target = @import("target.zig");
pub const Target = target.Target;

/// The header a request's id travels under (ADR 158). nilo's own spelling,
/// the one `Ctx.requestId` reads on the way in and the logger writes on the
/// way out.
pub const request_id_header = "X-Request-Id";

/// A pooled HTTP client, held as a service for the life of the process.
///
/// Registered with `app.provide(&client)` and asked for by type, the way every
/// other service is. One is enough for a whole program: the pool inside it is
/// keyed by host, so calls to three different APIs share it without knowing
/// about each other.
pub const Client = struct {
    inner: std.http.Client,
    gate: std.Io.Semaphore,
    limits: core.Limits = .none,
    settings: Settings,
    started: bool = false,

    pub const Settings = struct {
        /// How many calls may be in flight at once, across every host.
        ///
        /// This is the one that is not a nicety. Without it the ceiling on
        /// live connections is however many handlers happen to be running,
        /// and each HTTPS connection holds 59,151 bytes of TLS and socket
        /// buffers. Past this a caller waits for a permit rather than opening
        /// connection 501.
        max_in_flight: u32 = 32,

        /// How long one call may take, end to end — connect, send, head and
        /// body. Zero means no limit, the spelling `Deadlines` already uses.
        ///
        /// It bounds the whole call rather than each read, because a server
        /// sending one byte a second satisfies any per-read limit you care to
        /// name and never finishes.
        ///
        /// **It fires without an Engine too.** Under `listen()` the Engine
        /// cancels the fiber; on a client started with `nilo_start(io,
        /// .none)` — a CLI, a worker, a test on `std.Io.Threaded` — each
        /// step of the call runs as a task of that `Io`, and the task is
        /// cancelled when the clock runs out. What that costs is one thread
        /// hop per step, paid only by a client with no Engine and a
        /// non-zero timeout (ADR 056).
        timeout_ms: u32 = 30_000,

        /// How long the far end may say **nothing** before the call is
        /// `error.Stalled`: time since the last byte reached this side, not
        /// time since the call began. Zero, the default, is no such bound.
        ///
        /// The other shape of bound, for the call whose whole point is the
        /// transfer. A download may honestly take an hour, so `timeout_ms`
        /// has to be zero there, and that leaves a peer that went quiet
        /// with the socket open (a CDN edge that lost its origin, a NAT that
        /// dropped the mapping) with nothing to end it. The two compose:
        /// `timeout_ms` is the ceiling on the whole call, this is the
        /// ceiling on silence inside it, and a caller sets either or both
        /// ([ADR 056](../docs/adr/056-the-way-out-was-open-the-clock-was-not.md)).
        ///
        /// It is not a per-read timeout, which ADR 056 rejected and still
        /// does: a server sending one byte a second is *slow*, satisfies this
        /// bound, and is the caller's to judge against its other connections.
        /// What this catches is a server sending nothing.
        stall_ms: u32 = 0,

        /// A response body larger than this is `error.BodyTooLarge` rather
        /// than an allocation. Nothing in std bounds it.
        max_body: usize = 8 << 20,

        /// The read buffer every connection is given, and the number that
        /// decides how much one socket read brings in. std's 8 KiB, passed
        /// through; it is per connection and lives on the heap beside it,
        /// which is the right place for sixteen sockets pulling one file
        /// and the wrong place for a handler's one call, so the default is
        /// std's. `Begin.transfer_buffer` is not this and does not change
        /// the read size, which is the mistake this field is here to spare
        /// the next reader (ADR 186).
        read_buffer_size: usize = 8 << 10,

        /// How much of an unread body is worth reading to keep a pooled
        /// connection. Past this the connection is dropped instead: losing it
        /// costs one handshake, and reading it costs the whole body.
        max_drain: usize = 64 << 10,

        /// Whether a call made under a request sends that request's id as
        /// `X-Request-Id`, so the other side's log lines up with this one
        /// ([ADR 158](../docs/adr/158-a-request-id-goes-out-with-the-call.md)).
        ///
        /// Read off the Scope: a `*Ctx` has an id and a `nilo.Run` has none,
        /// so a call from a CLI or a scheduled tick sends nothing whatever
        /// this says. A call that already carries an `X-Request-Id` of its
        /// own in `Call.headers` keeps it.
        forward_request_id: bool = true,
    };

    /// Per-call overrides. Everything null takes the client's own setting, so
    /// `.{}` is the ordinary case.
    pub const Call = struct {
        /// Sent verbatim, in this order. A name std writes for itself —
        /// `host`, `authorization`, `user-agent`, `content-type`,
        /// `connection`, `accept-encoding` — is sent **once**, the caller's
        /// copy, rather than beside std's (ADR 182).
        headers: []const std.http.Header = &.{},
        /// Overrides `Settings.timeout_ms` for this call — a health check that
        /// should give up in 500ms, an upload that may take a minute.
        timeout_ms: ?u32 = null,
        /// Overrides `Settings.stall_ms` for this call.
        stall_ms: ?u32 = null,
        max_body: ?usize = null,
    };

    pub const Error = error{
        /// The deadline for this call ran out. Distinct from `Canceled`,
        /// which is the server shutting down underneath it.
        TimedOut,
        /// Nothing arrived for `stall_ms`. The peer is still holding the
        /// socket, and this side stopped waiting for it. Told apart from
        /// `TimedOut` because a caller does different things with them: a
        /// stalled transfer is restarted on a fresh connection, a call that
        /// blew its whole budget is given up on.
        Stalled,
        /// The answer was a 3xx with a `Location`, and `Begin.redirects` is
        /// `.refuse`, which is the default. Say `.follow` with a buffer to
        /// walk it, or `.expose` to be handed the 3xx as itself.
        RedirectRefused,
        /// The body was longer than `max_body` and reading stopped there.
        BodyTooLarge,
        /// The body ended before the length its own head announced. A caller
        /// that sized an allocation from `content-length` has to hear about
        /// that rather than be handed a buffer with a tail of nothing in it.
        BodyTooShort,
        /// A call was made before `listen()` ran. A Fitting is finished at
        /// startup like any other service; a unit test that calls a handler
        /// directly without an App gets this.
        NotStarted,
        /// A body on a method std frames no body for — a DELETE with one —
        /// and the head was too long for its length to be written after it
        /// (ADR 174). The connection buffers a head of several kilobytes;
        /// this is a request carrying more headers than that.
        HeadTooLong,
        OutOfMemory,
    } || std.Uri.ParseError || std.http.Client.RequestError ||
        std.http.Client.Request.ReceiveHeadError ||
        std.Io.Writer.Error || std.Io.Reader.Error || std.Io.Cancelable;

    pub fn init(gpa: std.mem.Allocator, settings: Settings) Client {
        return .{
            .inner = .{ .allocator = gpa, .io = undefined, .read_buffer_size = settings.read_buffer_size },
            .gate = .{ .permits = settings.max_in_flight },
            .settings = settings,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.started) self.inner.deinit();
    }

    /// Finished once the event loop exists, like every service that needs one
    /// (ADR 037). The third parameter is what bounds a call in time
    /// (ADR 056); a Fitting that did not take it could open a connection and
    /// never give up on it.
    ///
    /// `.none` for the limits is not "no deadline": it is "no Engine to arm
    /// one on", and the client then bounds the call itself, as a task of
    /// `io` it can cancel (ADR 056).
    pub fn nilo_start(self: *Client, io: std.Io, limits: core.Limits) !void {
        self.inner.io = io;
        self.limits = limits;
        self.started = true;
    }

    pub fn get(self: *Client, c: anytype, url: []const u8, call: Call) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.get");
        return self.send(c, .GET, url, null, call);
    }

    pub fn post(self: *Client, c: anytype, url: []const u8, body: []const u8, call: Call) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.post");
        return self.send(c, .POST, url, body, call);
    }

    pub fn put(self: *Client, c: anytype, url: []const u8, body: []const u8, call: Call) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.put");
        return self.send(c, .PUT, url, body, call);
    }

    pub fn delete(self: *Client, c: anytype, url: []const u8, call: Call) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.delete");
        return self.send(c, .DELETE, url, null, call);
    }

    /// A PATCH; `null` for the verb endpoint whose whole request is its path
    /// (ADR 174). A DELETE with a body is `send(c, .DELETE, url, body, call)`.
    pub fn patch(self: *Client, c: anytype, url: []const u8, body: ?[]const u8, call: Call) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.patch");
        return self.send(c, .PATCH, url, body, call);
    }

    /// `post` with `value` written out as JSON and `content-type:
    /// application/json` said for you — unless `call.headers` names one,
    /// which is then the one that goes. What `res.json(T, c)` is for the way
    /// in, this is for the way out
    /// ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)).
    ///
    /// One arena allocation for the text, which is the one every caller was
    /// already paying to `std.json.Stringify.valueAlloc` by hand. Text is
    /// refused while compiling: a `[]const u8` here would go out as one JSON
    /// *string*, quotes and all, and a body already encoded goes through
    /// `post`.
    pub fn postJson(self: *Client, c: anytype, url: []const u8, value: anytype, call: Call) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.postJson");
        comptime refuseJsonText(@TypeOf(value), "fetch.postJson");
        return self.sendJson(c, .POST, url, value, call);
    }

    pub fn putJson(self: *Client, c: anytype, url: []const u8, value: anytype, call: Call) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.putJson");
        comptime refuseJsonText(@TypeOf(value), "fetch.putJson");
        return self.sendJson(c, .PUT, url, value, call);
    }

    pub fn patchJson(self: *Client, c: anytype, url: []const u8, value: anytype, call: Call) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.patchJson");
        comptime refuseJsonText(@TypeOf(value), "fetch.patchJson");
        return self.sendJson(c, .PATCH, url, value, call);
    }

    /// The whole of what the three above do, for a method they do not name
    /// — a DELETE with `{ids:[…]}` in it (ADR 174).
    pub fn sendJson(
        self: *Client,
        c: anytype,
        method: std.http.Method,
        url: []const u8,
        value: anytype,
        call: Call,
    ) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.sendJson");
        comptime refuseJsonText(@TypeOf(value), "fetch.sendJson");
        const bytes = try std.json.Stringify.valueAlloc(c.arena(), value, .{});
        return self.sendAs(c, method, url, bytes, "application/json", call, .{});
    }

    /// The whole of what `get`, `post`, `put`, `delete` and `patch` do, for
    /// a method they do not name.
    ///
    /// The permit is held until the body is in hand rather than until the head
    /// arrives, because a connection is live for the whole of that — counting
    /// it only while the head is outstanding would let the ceiling be passed
    /// by every call that is still reading.
    pub fn send(
        self: *Client,
        c: anytype,
        method: std.http.Method,
        url: []const u8,
        body: ?[]const u8,
        call: Call,
    ) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.send");
        return self.sendAs(c, method, url, body, null, call, .{});
    }

    /// What a `Target` sends on every call it makes: the headers a service
    /// always wants, held once at `open` rather than repeated at every
    /// call site (ADR 061). `send` and its siblings pass `.{}`, which is
    /// nothing. A line in `Call.headers` naming `authorization` or
    /// `user-agent` goes instead of the standing value, the rule ADR 182
    /// already sets for std's own slot; a line naming any other standing
    /// header shadows it, so a call can say `accept: text/csv` under a
    /// target that says `accept: application/json`.
    pub const Standing = struct {
        authorization: ?[]const u8 = null,
        user_agent: ?[]const u8 = null,
        headers: []const std.http.Header = &.{},
    };

    /// `send`, with a `content-type` the call decided — what `sendJson`
    /// says for its body — and the headers a `Target` stands behind every
    /// call. Null for the type is std's slot left to std, which writes none
    /// for a body it was not told the type of. Public for `target.zig`;
    /// the calls above are the way to write it.
    pub fn sendAs(
        self: *Client,
        c: anytype,
        method: std.http.Method,
        url: []const u8,
        body: ?[]const u8,
        content_type: ?[]const u8,
        call: Call,
        standing: Standing,
    ) Error!Response {
        // The one buffer this call needs, declared where a reader can see
        // what it costs. It is stack, and by
        // [ADR 062](../docs/adr/062-where-a-connection-waits-is-what-it-costs.md) a
        // handler's stack is held for the life of the *inbound* connection — so
        // 2 KiB here is 2 KiB on every connection that ever dials out. An
        // `Exchange` takes it as an argument rather than holding it as a field
        // for exactly that reason: a caller that follows no redirects pays for
        // no redirect buffer.
        //
        // There used to be a 4 KiB transfer buffer beside it, and it bought
        // nothing: the body goes from the connection's own read buffer to the
        // arena without touching it, on every framing (ADR 186).
        var redirect_buffer: [2 << 10]u8 = undefined;

        var ex: Exchange = .idle;
        defer ex.end();

        // A target's standing headers under the call's own, which shadow
        // them by name: nothing to do for the ordinary call, one arena
        // allocation when both lists have something in them (ADR 061).
        const lines = try withStanding(c, standing.headers, call.headers);

        // The request's id, when there is a request. One header, and for the
        // ordinary call — no headers of its own — it lives in this array
        // rather than in the arena (ADR 158).
        var one: [1]std.http.Header = undefined;
        const headers = if (self.settings.forward_request_id)
            try withRequestId(c, lines, &one)
        else
            lines;

        // The caller's own line wins over the value the call or the target
        // decided, and std's slot is then left out so it goes once
        // (ADR 182).
        const given = Exchange.Given.of(lines);
        const head = try ex.begin(self, .{
            .method = method,
            .url = url,
            .headers = headers,
            .body = if (body) |bytes| .{ .slice = bytes } else .none,
            .content_type = if (given.content_type) null else content_type,
            .authorization = if (given.authorization) null else standing.authorization,
            .user_agent = if (given.user_agent) null else standing.user_agent,
            .timeout_ms = call.timeout_ms,
            .stall_ms = call.stall_ms,
            .redirects = .{ .follow = &redirect_buffer },
        });

        // The header block, kept before the body reads over it: the second
        // arena allocation of a whole-body call, beside the body's own, so
        // that `res.header("retry-after")` is there to read after the call
        // ([ADR 187](../docs/adr/187-a-head-that-outlives-its-body.md)).
        const kept = try c.arena().dupe(u8, head.bytes);

        return .{
            .status = head.status,
            .headers = kept,
            .body = try ex.take(c, call.max_body orelse self.settings.max_body),
        };
    }

    /// `given` plus the Scope's request id, or `given` as it was: when the
    /// Scope has no id, or the caller already named one.
    ///
    /// A call with no headers of its own costs nothing here — the one header
    /// goes in `one`. A call that passes headers spends one bump of the
    /// Scope's arena on the merge, which is the one allocation this decision
    /// makes and the reason it is written down (ADR 158).
    fn withRequestId(c: anytype, given: []const std.http.Header, one: *[1]std.http.Header) Error![]const std.http.Header {
        const S = @typeInfo(@TypeOf(c)).pointer.child;
        const id = core.requestIdOf(S, c) orelse return given;
        for (given) |h| if (std.ascii.eqlIgnoreCase(h.name, request_id_header)) return given;
        if (given.len == 0) {
            one[0] = .{ .name = request_id_header, .value = id.view() };
            return one;
        }
        const merged = try c.arena().alloc(std.http.Header, given.len + 1);
        @memcpy(merged[0..given.len], given);
        merged[given.len] = .{ .name = request_id_header, .value = id.view() };
        return merged;
    }

    /// `standing` under `given`, with a standing line the call names again
    /// left out, or one of the two lists as it was when the other is empty.
    ///
    /// The ordinary call has no standing headers and costs nothing here; a
    /// call on a target that passes headers of its own spends one bump of
    /// the Scope's arena on the merge, the way `withRequestId` does for the
    /// id (ADR 061).
    fn withStanding(c: anytype, standing: []const std.http.Header, given: []const std.http.Header) Error![]const std.http.Header {
        if (standing.len == 0) return given;
        if (given.len == 0) return standing;
        var kept: usize = 0;
        for (standing) |s| {
            if (!namesHeader(given, s.name)) kept += 1;
        }
        const merged = try c.arena().alloc(std.http.Header, kept + given.len);
        var i: usize = 0;
        for (standing) |s| {
            if (namesHeader(given, s.name)) continue;
            merged[i] = s;
            i += 1;
        }
        @memcpy(merged[i..], given);
        return merged;
    }

    fn namesHeader(headers: []const std.http.Header, name: []const u8) bool {
        for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
        return false;
    }

    /// Ask the deadline whether this failure is its doing.
    ///
    /// **The bound is the authority, not the error**, and that is the one
    /// thing `fetch/deadline.zig` corrected. This read `err == error.Canceled
    /// and bound.fired()` until a real timer was first seen to fire, and the
    /// error that came back was `error.ReadFailed`: `std.Io.Reader` has a
    /// fixed error set, so `std.http.Client` collapses the cancellation into
    /// it and keeps the cause in a field it does not return. Any client that
    /// pattern-matches on `error.Canceled` therefore reports its own timeouts
    /// as read failures — which is what nilo did, and what only an Engine
    /// could show ([ADR 032](../docs/adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)).
    ///
    /// Asking the bound instead needs nothing of the error: if this call's own
    /// timer expired, every failure after it is downstream of that. A
    /// cancellation from somewhere else — a shutdown — leaves the bound
    /// saying no, and is passed through as itself, which is the distinction
    /// that mattered in the first place.
    ///
    /// `expired` and `stalled` are the same answers from the other clock,
    /// the one an Exchange keeps itself when there is no Engine (ADR 056);
    /// `stall_armed` says which of the two bounds the Engine's one timer was
    /// standing in for when it fired (ADR 056).
    fn blame(_: *Client, bound: *core.Limits.Bound, stall_armed: bool, expired: bool, stalled: bool, err: anytype) Error {
        if (stalled) return error.Stalled;
        if (expired) return error.TimedOut;
        if (bound.fired()) return if (stall_armed) error.Stalled else error.TimedOut;
        return err;
    }

    /// What `Request.deinit` would have done without a limit.
    ///
    /// This is the *second* of two bounds and the weaker one — it can only see
    /// what is already buffered. `Exchange.dropIfDrainIsDearer` asks the
    /// question this one is reaching for, against the length the response
    /// announced, and runs first.
    fn close(self: *Client, req: *std.http.Client.Request) void {
        if (req.connection) |conn| {
            if (conn.reader().bufferedLen() > self.settings.max_drain) conn.closing = true;
        }
        req.deinit();
    }
};

/// One call, held open from the request line to the last byte of the body.
///
/// `Client.get` and the three beside it are this with the middle left out:
/// they send, read the whole body into the Scope and hand back a `Response`,
/// which is what a handler calling somebody's JSON API wants. What they cannot
/// do is the two things a caller of an *object store* needs — read a response
/// header, and move a body too big to hold — so those two are here, on a type
/// that stays open in between.
///
/// ```zig
/// var ex: fetch.Exchange = .idle;
/// defer ex.end();
///
/// const head = try ex.begin(client, .{ .method = .GET, .url = url });
/// const etag = head.header("etag");     // valid until the body is touched
/// _ = try ex.pipe(out);                 // and now it is not; `head.keep(c)` if it must be
/// ```
///
/// **An Exchange must not be copied once it has begun**, for the reason a
/// `core.Limits.Bound` must not: `std.http.Client.Response` holds a pointer to
/// the `Request` beside it, and the deadline slot is registered with the
/// Engine by address. Declare it, begin it where it stands, and leave it
/// there — the same shape spelled the same way, so there is one rule rather
/// than two.
///
/// `end` is safe on one that never began, which is what lets the `defer` go
/// above the `begin` rather than after it.
pub const Exchange = struct {
    client: *Client = undefined,
    /// The Engine's deadline, when there is an Engine.
    bound: core.Limits.Bound = .idle,
    /// The same deadline kept by the Exchange itself, when there is not:
    /// an absolute time on Core's monotonic clock, in microseconds, that
    /// every step of the call is run against, as a task of the `Io` that is
    /// cancelled when the clock passes it (ADR 056). Zero under an Engine,
    /// and for a timeout of zero. An `i64` rather than an `std.Io.Timeout`
    /// because the latter is 48 bytes and this struct sits on the stack of
    /// every handler that dials out, which by ADR 062 is per connection.
    deadline_us: i64 = 0,
    /// Whether `deadline` is what stopped the call. The engineless half of
    /// what `Bound.fired` answers, and read by `blame` the same way.
    expired: bool = false,
    /// The ceiling on silence, in milliseconds, or zero for none. The
    /// other clock (ADR 056): where `deadline_us` counts from the start of
    /// the call, this counts from `last_byte`, which every chunk moves.
    stall_ms: u32 = 0,
    /// When the last byte of body reached this side, on Core's monotonic
    /// clock: the moment `begin` ran until the first chunk lands. Atomic
    /// because with no Engine the reading task writes it and the waiting
    /// caller reads it.
    last_byte: std.atomic.Value(i64) = .init(0),
    /// Whether silence is what stopped the call: the engineless half.
    stalled: bool = false,
    /// Under an Engine there is one timer, and this says which of the two
    /// bounds it was armed for when it fired: the shorter of what is left
    /// of the call and `stall_ms`, re-armed on every chunk.
    stall_armed: bool = false,
    req: std.http.Client.Request = undefined,
    res: std.http.Client.Response = undefined,
    /// The body, as the caller reads it. With a `stall_ms` this is `tap`,
    /// which stamps `last_byte` on the way through; without one it is
    /// std's own body reader, and the tap costs nothing.
    reader: ?*std.Io.Reader = null,
    /// std's body reader, which `tap` reads through.
    inner: *std.Io.Reader = undefined,
    /// An unbuffered reader in front of `inner` that notices every chunk.
    /// Address sensitive like the rest of the struct: its vtable finds the
    /// Exchange by `@fieldParentPtr`.
    tap: std.Io.Reader = .{ .buffer = &.{}, .seek = 0, .end = 0, .vtable = &tap_vtable },
    /// What the response said its body was, kept so that `end` can decide
    /// whether reading the rest of it is cheaper than a new connection. Null
    /// is a body of unknown length, which counts as too much.
    announced: ?u64 = null,
    permit: bool = false,
    open: bool = false,

    /// Nothing held: no permit, no connection, no deadline.
    pub const idle: Exchange = .{};

    /// What goes out. Everything but the method and the URL has a default, and
    /// the defaults are the ordinary call.
    pub const Begin = struct {
        method: std.http.Method,
        url: []const u8,
        /// Written to the wire verbatim and in this order — `std.http.Client`
        /// promises that, and a signature computed over them depends on it.
        ///
        /// **A name std writes for itself is sent once, and it is this copy.**
        /// `std.http.Client` has slots of its own for `host`, `authorization`,
        /// `user-agent`, `content-type`, `connection` and `accept-encoding`,
        /// and it used to write its slot *and* the verbatim line, so a
        /// `user-agent` pasted off a `curl` command went out twice. Now a
        /// name here that matches a slot tells std to leave the slot out, and
        /// the six names are known in one place, which is this file rather
        /// than every caller with a header it did not choose (ADR 182).
        ///
        /// `accept-encoding` is the one to know about: the line goes out as
        /// written, but the client still decodes nothing, so an answer that
        /// arrives compressed is `error.HttpContentEncodingUnsupported`
        /// rather than a `Str` full of gzip. Leave it out to get the
        /// identity the client asks for itself.
        headers: []const std.http.Header = &.{},
        body: Body = .none,

        /// Four headers std writes for itself unless told otherwise. A signed
        /// request has to say exactly what it signed, down to the port in the
        /// authority, so it overrides rather than trusting two spellings to
        /// agree. The explicit form, for a caller who has the value and not a
        /// header line; the same name in `headers` is the other way to say
        /// it. **Not both** — a field here and the line in `headers` go out
        /// as two lines, because the field is the caller's own word for what
        /// the wire should carry.
        host: ?[]const u8 = null,
        authorization: ?[]const u8 = null,
        content_type: ?[]const u8 = null,
        user_agent: ?[]const u8 = null,

        timeout_ms: ?u32 = null,
        /// Overrides `Settings.stall_ms` for this call (ADR 056).
        stall_ms: ?u32 = null,

        /// What a 3xx with a `Location` means to this call. **`.refuse`, the
        /// default, is `error.RedirectRefused`**: a caller who has not
        /// thought about redirects finds out from the error rather than
        /// from a status 301 read as a broken server. `.follow` walks the
        /// chain, and needs the buffer the `Location` is resolved in.
        /// `.expose` is handed the 3xx as itself: for a signed request
        /// checking where an object moved, or a client that reads the
        /// body of the answer, which is what S3 puts its reason in
        /// ([ADR 183](../docs/adr/183-a-redirect-is-a-decision-with-a-name.md)).
        ///
        /// Not following is the right default for anything signed: a
        /// signature is computed over one host and one path, so following a
        /// redirect sends a request that cannot be valid at the other end —
        /// and sends the `authorization` header there while it does it.
        redirects: Redirects = .refuse,
        /// A buffer for a caller who reads the body **buffered** off
        /// `ex.reader` (`take`, `peek`, a delimiter) and for nothing else.
        /// `take`, `readInto`, `pipe` and `stream` here go from the
        /// connection's own read buffer straight to the destination on every
        /// framing and never fill it, so the empty default is the ordinary
        /// call and costs nothing. It does not change how much one socket
        /// read brings in; `Settings.read_buffer_size` does (ADR 186).
        transfer_buffer: []u8 = &.{},
    };

    /// What a 3xx with a `Location` means to a call. See `Begin.redirects`.
    pub const Redirects = union(enum) {
        /// The answer is `error.RedirectRefused`. The default.
        refuse,
        /// The answer comes back as itself, 302 and all.
        expose,
        /// Followed, at most three deep, with the `Location` resolved in
        /// this buffer; `head.redirected` says where it ended, and its text
        /// lives here (ADR 183).
        follow: []u8,

        fn buffer(self: Redirects) []u8 {
            return switch (self) {
                .follow => |buf| buf,
                else => &.{},
            };
        }
    };

    /// A body going out: nothing, bytes already in hand, or a reader of a
    /// known length.
    ///
    /// The length is not optional on the streamed one, and that is the whole
    /// reason this is a union rather than an optional reader. HTTP can frame a
    /// body of unknown length with `transfer-encoding: chunked`, and the
    /// services this exists for — S3 among them — answer `411` to it. Asking
    /// for the length here makes *I do not know it* a compile error rather
    /// than somebody else's error code.
    pub const Body = union(enum) {
        none,
        slice: []const u8,
        stream: struct { reader: *std.Io.Reader, len: u64 },
    };

    /// The response head, and the window in which it can be read.
    ///
    /// **Every slice here points into the connection's own read buffer, and
    /// the first byte of body read overwrites it.** So a caller reads what it
    /// needs — or copies it — before `take` or `pipe`. That is the bargain
    /// `sql`'s Borrowed row makes, made here for the same reason: the
    /// alternative is an allocation per call for text most callers glance at
    /// once and drop.
    pub const Head = struct {
        status: std.http.Status,
        content_length: ?u64,
        content_type: ?[]const u8,
        bytes: []const u8,
        /// Where a followed redirect ended, or null when none was followed
        /// — the URL this head is the answer to, resolved against every
        /// `Location` on the way. **Its text lives in the `redirect_buffer`
        /// the call was given**, which the caller owns, so it is good for as
        /// long as that buffer is and not for a moment longer. `location`
        /// writes it out as one string (ADR 183).
        redirected: ?std.Uri = null,

        /// A header by name, case-insensitively. Null when it is absent —
        /// which for `etag` is a fact about the server rather than an error.
        pub fn header(self: Head, name: []const u8) ?[]const u8 {
            return headerIn(self.bytes, name);
        }

        /// The URL a followed redirect ended at, written into `buf`, or null
        /// when the answer came from the URL that was asked for. What a
        /// caller that will open more connections to the same object wants:
        /// the sixteen after the probe go to where it landed rather than
        /// walking the chain sixteen more times (ADR 183).
        ///
        /// `error.NoSpaceLeft` when `buf` is shorter than the URL, which is
        /// a URL longer than the redirect buffer that held it.
        pub fn location(self: Head, buf: []u8) error{NoSpaceLeft}!?[]const u8 {
            const uri = self.redirected orelse return null;
            var w: std.Io.Writer = .fixed(buf);
            uri.format(&w) catch return error.NoSpaceLeft;
            return w.buffered();
        }

        pub fn ok(self: Head) bool {
            return @intFromEnum(self.status) >= 200 and @intFromEnum(self.status) < 300;
        }

        /// The same head, copied into the Scope, so it reads the same after
        /// the body has been through. For the caller who needs an `etag`
        /// *after* `pipe`: the next run compares against it, and until this
        /// every such caller wrote a `[512]u8` and a length of its own
        /// ([ADR 187](../docs/adr/187-a-head-that-outlives-its-body.md)).
        /// One arena allocation the size of the header block, on the calls
        /// that ask and no other; the borrowed head stays the default.
        pub fn keep(self: Head, c: anytype) error{OutOfMemory}!Head {
            comptime core.checkScope(@TypeOf(c), "head.keep");
            const arena = c.arena();
            var kept = self;
            kept.bytes = try arena.dupe(u8, self.bytes);
            // std cut `content_type` out of the block, so it moves with it;
            // a value that came from anywhere else is copied on its own.
            if (self.content_type) |ct| {
                const start = @intFromPtr(self.bytes.ptr);
                const at = @intFromPtr(ct.ptr);
                kept.content_type = if (at >= start and at + ct.len <= start + self.bytes.len)
                    kept.bytes[at - start ..][0..ct.len]
                else
                    try arena.dupe(u8, ct);
            }
            // A `std.Uri` is eight slices into the redirect buffer. Written
            // out as one string and read back, which is what `location`
            // already does for the caller.
            if (self.redirected) |uri| {
                var w: std.Io.Writer.Allocating = .init(arena);
                uri.format(&w.writer) catch return error.OutOfMemory;
                kept.redirected = std.Uri.parse(w.written()) catch unreachable; // it was one before
            }
            return kept;
        }
    };

    /// Take a permit, arm the deadline, send the head and the body, and read
    /// the response head: everything up to the first byte of the body.
    pub fn begin(self: *Exchange, client: *Client, opts: Begin) Client.Error!Head {
        if (!client.started) return error.NotStarted;
        self.client = client;

        const io = client.inner.io;
        const uri = try std.Uri.parse(opts.url);

        // The permit is taken before the deadline is armed, so a caller
        // queueing for one is not also being timed out of the queue by a clock
        // it has not started. It goes back in `end`, after the connection.
        try client.gate.wait(io);
        self.permit = true;

        // One deadline, held by whichever of the two can enforce it. Under an
        // Engine that is the Bound, which cancels the fiber; with none, it is
        // an absolute time every step below is run against as a task that
        // gets cancelled (ADR 056). Zero is no limit either way.
        // The other clock counts from the last byte, and until one arrives
        // that is now: a head that never comes is silence too (ADR 056).
        const ms = opts.timeout_ms orelse client.settings.timeout_ms;
        self.stall_ms = opts.stall_ms orelse client.settings.stall_ms;
        self.last_byte.store(core.monotonicMicros(), .release);
        if (client.limits.engineless()) {
            if (ms != 0) self.deadline_us = core.monotonicMicros() + @as(i64, ms) * std.time.us_per_ms;
        } else if (self.stall_ms != 0) {
            // One timer for two bounds: armed for whichever is nearer, and
            // re-armed by every chunk. The call's end is kept so that the
            // re-arm can tell which is nearer.
            if (ms != 0) self.deadline_us = core.monotonicMicros() + @as(i64, ms) * std.time.us_per_ms;
            self.armNearer();
        } else self.bound.arm(client.limits, ms);

        // **One retry, and only onto a connection the peer had already
        // closed.** Not a retry policy: `std.http.Client` pools keep-alive
        // connections and every server reaps an idle one, so the first call
        // after a quiet spell takes a socket with a FIN already on it. std
        // names that case exactly — `HttpConnectionClosing`, documented there
        // as "the client sent 0 bytes of headers before closing the stream.
        // This happens when a keep-alive connection is finally closed" — so
        // **nothing was answered and nothing reached anybody.** Sending it
        // again on a fresh connection is transport hygiene, which is why
        // [ADR 058](../docs/adr/058-most-of-an-s3-client-is-not-s3.md)
        // called it correctness while refusing every other retry, and why
        // [ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)'s "no
        // retries" is about somebody else's *service* rather than about a
        // socket this one had already stopped using.
        //
        // Measured before it was written: a `wrk` run against
        // `bench/s3_server.zig` after 80 seconds idle answered **exactly 32
        // requests non-2xx**, and the same run against a warm pool answered
        // zero. 32 is `std.http.Client.ConnectionPool.free_size`, the idle
        // connections std keeps — the whole pool reaped, one spurious 500
        // each.
        //
        // **That is also why the bound is not one.** A first version retried
        // once and took the 32 down to 13, because when a whole pool goes
        // stale together the retry draws a second corpse as easily as a live
        // socket: each attempt can only evict the one connection it was
        // handed. So the limit is the pool's own size — at most one attempt
        // per connection it could be holding — and it follows a caller who
        // resizes the pool rather than being a number written here.
        //
        // It terminates and it is cheap. Every attempt marks its connection
        // closing, so the corpses strictly run out; a closed socket fails
        // with no round trip in it; and the deadline armed above is the real
        // backstop, unchanged by any of this.
        //
        // Three bounds, and each closes something:
        //
        // - **Only a reaped connection.** Anything else is the server
        //   answering, and an answer is not something to send twice. Which
        //   error that is, is `nothingCameBack`'s question rather than a name
        //   written here: a reaped connection arrives as a FIN or as an RST
        //   depending on a race nobody runs, and reading only the first spelling
        //   is what
        //   [ADR 058](../docs/adr/058-most-of-an-s3-client-is-not-s3.md)
        //   fixed.
        // - **Only a body still where it was.** A `.stream` body has had its
        //   reader consumed, so re-sending it would put fewer bytes on the
        //   wire than the `content-length` promised — worse than the error.
        // - **Inside the same permit and the same deadline.** Both are taken
        //   above and neither is re-armed, so a retry cannot double the time
        //   budget or take a second seat at the gate.
        const stale_limit = client.inner.connection_pool.free_size;
        var tries: usize = 0;
        while (true) : (tries += 1) {
            self.bounded(attempt, .{ self, client, uri, opts }) catch |err| {
                if (tries < stale_limit and self.nothingCameBack(err) and
                    replayable(opts.body) and !self.expired and !self.bound.fired())
                {
                    self.forget();
                    continue;
                }
                return self.blame(err);
            };
            break;
        }

        // Read out now, because `Response.reader` deliberately invalidates
        // them: std sets the head's slices to `undefined` the moment the body
        // stream starts, and it is right to — the bytes they point at are
        // about to be read over. What is kept here is the slices rather than a
        // copy, so the window handed to the caller is the same window std was
        // protecting, and it is the header of `Head` that says so.
        const head: Head = .{
            .status = self.res.head.status,
            .content_length = self.res.head.content_length,
            .content_type = self.res.head.content_type,
            .bytes = self.res.head.bytes,
            // std counts the redirects it has left; fewer than it started
            // with is a chain it walked, and `req.uri` is then the end of
            // it, resolved into the caller's `redirect_buffer` by std's own
            // `resolveInPlace`.
            .redirected = if (opts.redirects == .follow and self.req.redirect_behavior.remaining() < max_redirects)
                self.req.uri
            else
                null,
        };

        // A 3xx that says where to go, under the default that made no
        // decision about it. A 304 has no `Location` and is an answer, so
        // it is not this (ADR 183). The Exchange stays open, and the
        // caller's `end` drops the connection or drains the body the way it
        // would for any answer it did not read.
        if (opts.redirects == .refuse and head.status.class() == .redirect and self.res.head.location != null) {
            return error.RedirectRefused;
        }

        // **A HEAD's answer, a 1xx, a 204 and a 304 end at the header block,
        // whatever the headers say** (RFC 9112 §6.3). std's `receiveHead`
        // knows the rule — its comment says so — and records it nowhere the
        // reader reads, so `Response.reader` frames a 204 with no
        // `content-length` as read-to-EOF, and on a keep-alive connection EOF
        // is whenever the server reaps the idle socket: 120 seconds against
        // Garage, for an answer that was complete in 30 ms. Marked read here,
        // so `take` returns empty and `deinit` drains nothing
        // ([ADR 176](../docs/adr/176-an-answer-with-no-body-ends-at-its-head.md)).
        if (bodiless(opts.method, head.status)) {
            self.req.reader.state = .ready;
            self.announced = 0;
            self.reader = std.Io.Reader.ending;
            return head;
        }

        self.announced = head.content_length;
        self.inner = self.res.reader(opts.transfer_buffer);
        self.reader = if (self.stall_ms != 0) &self.tap else self.inner;
        return head;
    }

    /// Under an Engine: arm the one timer for whichever bound is nearer,
    /// what is left of the call or `stall_ms`, and remember which. Called
    /// at `begin` and again from `tap` on every chunk, so a moving transfer
    /// never fires it and a silent one fires it `stall_ms` after the last
    /// byte (ADR 056).
    fn armNearer(self: *Exchange) void {
        self.bound.release();
        var ms = self.stall_ms;
        self.stall_armed = true;
        if (self.deadline_us != 0) {
            const left_us = self.deadline_us - core.monotonicMicros();
            // Rounded up, and never zero: zero would be "no limit", and a
            // call already past its end still has to be stopped.
            const left_ms: u32 = @intCast(@max(1, @divTrunc(@max(left_us, 0) + std.time.us_per_ms - 1, std.time.us_per_ms)));
            if (left_ms <= ms) {
                ms = left_ms;
                self.stall_armed = false;
            }
        }
        self.bound.arm(self.client.limits, ms);
    }

    /// A chunk has landed: move the silence clock. Under an Engine that is
    /// the timer re-armed; without one it is a word the waiter in `bounded`
    /// reads.
    fn mark(self: *Exchange) void {
        self.last_byte.store(core.monotonicMicros(), .release);
        if (!self.client.limits.engineless()) self.armNearer();
    }

    const tap_vtable: std.Io.Reader.VTable = .{
        .stream = tapStream,
        .discard = tapDiscard,
    };

    fn tapStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Exchange = @alignCast(@fieldParentPtr("tap", r));
        const t0 = core.monotonicMicros();
        const n = self.inner.stream(w, limit) catch |err| {
            std.debug.print("DIAG tapStream err={s} after {d}us limit={any}\n", .{ @errorName(err), core.monotonicMicros() - t0, limit });
            return err;
        };
        std.debug.print("DIAG tapStream n={d} took {d}us since_last_mark={d}us limit={any}\n", .{ n, core.monotonicMicros() - t0, core.monotonicMicros() - self.last_byte.load(.acquire), limit });
        self.mark();
        return n;
    }

    fn tapDiscard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self: *Exchange = @alignCast(@fieldParentPtr("tap", r));
        const n = try self.inner.discard(limit);
        self.mark();
        return n;
    }

    /// Whether the answer to this request has no body by rule, rather than
    /// by header — the four cases RFC 9112 §6.3 lists ahead of
    /// `transfer-encoding` and `content-length`.
    fn bodiless(method: std.http.Method, status: std.http.Status) bool {
        return !method.responseHasBody() or
            status.class() == .informational or
            status == .no_content or
            status == .not_modified;
    }

    /// One send and one head read, with no opinion about what a failure means.
    ///
    /// Split out of `begin` so the retry above can run it twice without
    /// repeating it, and so that `blame` is applied in exactly one place.
    fn attempt(self: *Exchange, client: *Client, uri: std.Uri, opts: Begin) !void {
        // The six names std has a slot for, and whether `headers` carries
        // each. A slot the caller wrote a line for is left out, so the line
        // is the one copy on the wire — no allocation and no filtered slice,
        // because std writes `extra_headers` verbatim either way and the
        // only thing that had to move was its own (ADR 182).
        const given = Given.of(opts.headers);
        self.req = try client.inner.request(opts.method, uri, .{
            .extra_headers = opts.headers,
            .redirect_behavior = if (opts.redirects == .follow)
                std.http.Client.Request.RedirectBehavior.init(max_redirects)
            else
                .unhandled,
            .headers = .{
                .host = slot(opts.host, given.host),
                .authorization = slot(opts.authorization, given.authorization),
                .content_type = slot(opts.content_type, given.content_type),
                .user_agent = slot(opts.user_agent, given.user_agent),
                .connection = slot(null, given.connection),
                .accept_encoding = if (given.accept_encoding) .omit else .{ .override = "identity" },
            },
        });
        self.open = true;

        // Ask for the body uncompressed. **Not a default worth inheriting**:
        // `std.http.Client` advertises `gzip, deflate` and then hands back the
        // *compressed* bytes from `reader()`, because decompressing is a
        // different call. A caller who copies the obvious four lines out of
        // std gets a `Str` full of gzip and no error to say so — which is
        // what `fetch/tls.zig` found on the first real endpoint it touched,
        // after every canned test in `live.zig` passed.
        //
        // The alternative is `readerDecompressing`, and it is not free: a
        // `http.Decompress` plus a 32 KiB flate window, which by
        // [ADR 062](../docs/adr/062-where-a-connection-waits-is-what-it-costs.md)
        // is held per *connection* on the handler's stack — twice what the
        // whole call already costs there — and it links flate into every
        // binary that dials out. Identity costs nothing, is understood
        // everywhere, and makes `max_body` count the bytes a caller actually
        // receives rather than the bytes on the wire.
        //
        // Making it a setting would be the worst of both: the branch would be
        // at runtime, so flate would link in whether or not anybody chose it
        // (ADR 017's complaint about `docs()`, exactly).
        // Both halves, and they do different jobs. The override is what goes
        // on the wire — the bool array alone emits a malformed
        // `accept-encoding\r\n` with no value, because std's writer skips
        // `identity` when listing and then trims a separator that was never
        // written. The array is what `receiveHead` checks, so a server that
        // ignores the header and gzips anyway is a clean error rather than a
        // `Str` full of bytes nobody can read.
        // The override is set with the other slots above — unless the caller
        // wrote an `accept-encoding` line of their own, in which case the
        // slot is left out and their line goes. The array is set here
        // regardless: it is what decides whether an answer is *read*, and a
        // caller who asked for gzip gets the clean error rather than the
        // bytes.
        self.req.accept_encoding = @splat(false);
        self.req.accept_encoding[@intFromEnum(std.http.ContentEncoding.identity)] = true;

        // **The body decides, not the method**
        // ([ADR 174](../docs/adr/174-the-body-decides-not-the-method.md)).
        // `std.http.Client` asserts that a POST, PUT or PATCH sends a body
        // and that anything else sends none, and a real API does both the
        // other way: a bulk DELETE with `{ids:[…]}` in it, a PATCH whose
        // whole request is its path. Given a body, it is sent whatever the
        // method; given none, none is, whatever the method — and the two
        // asserts are stepped around rather than tripped, since either would
        // be a panic in a worker thread.
        const framed = opts.method.requestHasBody();
        switch (opts.body) {
            .none => if (framed) {
                // `content-length: 0` is the bodiless request said the way
                // std lets a body-taking method say it.
                self.req.transfer_encoding = .{ .content_length = 0 };
                var w = try self.req.sendBody(&.{});
                try w.end();
            } else try self.req.sendBodiless(),
            .slice => |bytes| if (framed) {
                self.req.transfer_encoding = .{ .content_length = bytes.len };
                var w = try self.req.sendBody(&.{});
                try w.writer.writeAll(bytes);
                try w.end();
            } else {
                const w = try self.sendHeadWithLength(bytes.len);
                try w.writeAll(bytes);
                try self.req.connection.?.flush();
            },
            .stream => |src| if (framed) {
                self.req.transfer_encoding = .{ .content_length = src.len };
                var w = try self.req.sendBody(&.{});
                // Exactly the length that was announced, and nothing else. A
                // source that runs out early fails here rather than sending a
                // body that disagrees with the head describing it.
                try src.reader.streamExact64(&w.writer, src.len);
                try w.end();
            } else {
                const w = try self.sendHeadWithLength(src.len);
                try src.reader.streamExact64(w, src.len);
                try self.req.connection.?.flush();
            },
        }

        self.res = try self.req.receiveHead(opts.redirects.buffer());
    }

    /// The head for a body on a method std frames no body for — a DELETE
    /// with `{ids:[…]}` — and the connection's writer to put the body on.
    ///
    /// std writes the head itself and only itself: `sendBodilessUnflushed`
    /// is the one door a DELETE may go through, and it writes no
    /// `content-length` because it was told there is nothing to measure. So
    /// the head is written unflushed, its closing blank line is taken back
    /// off the connection's buffer, and the length goes where the blank line
    /// was — the same `undo` std's own `sendHead` uses on the
    /// `accept-encoding` list. The check that the blank line is still in the
    /// buffer is what keeps this honest: a head too long to be buffered
    /// whole is refused rather than sent with a length in the wrong place.
    fn sendHeadWithLength(self: *Exchange, len: u64) !*std.Io.Writer {
        self.req.transfer_encoding = .none;
        try self.req.sendBodilessUnflushed();
        const w = self.req.connection.?.writer();
        if (!std.mem.endsWith(u8, w.buffered(), "\r\n\r\n")) return error.HeadTooLong;
        w.undo(2);
        try w.print("content-length: {d}\r\n\r\n", .{len});
        return w;
    }

    /// Whether this attempt ended with **not one byte of a response**, which
    /// is the only condition under which sending it again is transport
    /// hygiene rather than a retry policy.
    ///
    /// A reaped keep-alive connection comes back two ways, and which one is a
    /// race the client does not run. If the peer's `close` lands before this
    /// end writes, the socket carries a FIN, `receiveHead` reads zero bytes
    /// and std says so exactly: `HttpConnectionClosing`, documented there as
    /// "the client sent 0 bytes of headers before closing the stream. This
    /// happens when a keep-alive connection is finally closed."
    ///
    /// **If this end writes first, the peer closes a socket with an unread
    /// request sitting in it, and a close with unread data is an RST rather
    /// than a FIN.** Same reaped connection, same nothing answered, and
    /// `receiveHead` reports `ReadFailed` instead. That is not std being
    /// careless. Look at `receiveHead` and the asymmetry is on purpose: it
    /// splits `EndOfStream` by how much of the head had arrived, giving
    /// `HttpConnectionClosing` at zero and `HttpRequestTruncated` past it, and
    /// has no such split for `ReadFailed`, because a read that failed can
    /// fail for reasons that have nothing to do with reaping.
    ///
    /// So the split is made here, out of the two things std does keep: the
    /// real errno, which `Io.net.Stream.Reader` parks in `err` on its way to
    /// `ReadFailed`, and how much of the head had arrived, which is whatever
    /// the connection's reader still holds. Zero buffered and
    /// `ConnectionResetByPeer` is the same claim `HttpConnectionClosing`
    /// makes, arrived at the long way.
    ///
    /// It is also more than a tidy symmetry. A server that had read the
    /// request would have an empty receive queue and its `close` would send a
    /// FIN; the RST is the kernel saying the request was still sitting there
    /// unread. **The evidence that nothing was processed is stronger in this
    /// branch than in the one that was already trusted.**
    ///
    /// Nothing else is added. A reset partway through a head is
    /// `ReadFailed` with bytes buffered and stays a failure, because
    /// something did come back and re-sending would be a retry policy. So is
    /// a write that fails with `WriteFailed`: some of the request may have
    /// reached the far side, and no test here reproduces it.
    fn nothingCameBack(self: *Exchange, err: anyerror) bool {
        if (err == error.HttpConnectionClosing) return true;
        if (err != error.ReadFailed) return false;
        // `open` is the one thing that says `req` was assigned at all. A
        // failure inside `client.inner.request` leaves it `undefined`, and
        // reaching into it for a connection would be reading a pointer that
        // was never written. `discard` guards on the same flag for the same
        // reason.
        if (!self.open) return false;
        const conn = self.req.connection orelse return false;
        if (conn.stream_reader.interface.bufferedLen() != 0) return false;
        const why = conn.stream_reader.err orelse return false;
        return why == error.ConnectionResetByPeer;
    }

    /// Whether this call may go out a second time.
    ///
    /// Only the bodies whose bytes are still where the caller left them.
    fn replayable(body: Body) bool {
        return switch (body) {
            .none, .slice => true,
            .stream => false,
        };
    }

    /// Put a dead connection beyond reuse and forget the attempt on it.
    ///
    /// `closing` is what stops std returning it to the pool, and without it
    /// the retry would draw the same corpse again.
    fn forget(self: *Exchange) void {
        if (!self.open) return;
        if (self.req.connection) |conn| conn.closing = true;
        self.req.deinit();
        self.open = false;
    }

    /// "I will not read this body; close the connection." For the caller
    /// who knows what `end` would otherwise have to weigh: a probe that
    /// asked for one byte of a file and was answered with the whole file
    /// says this rather than lowering `max_drain` for every call the client
    /// makes, and `max_drain` stays a policy rather than a lever (ADR 184).
    ///
    /// Nothing is read after it. `end` still gives the permit back, and the
    /// connection goes with the body — one handshake, which is what the
    /// caller decided was cheaper.
    pub fn discard(self: *Exchange) void {
        if (!self.open) return;
        if (self.req.connection) |conn| conn.closing = true;
    }

    /// The whole body, in the Scope's memory, up to `max` bytes.
    ///
    /// One allocation, and it is the body. Past `max` it is
    /// `error.BodyTooLarge`: the ceiling is enforced while reading rather than
    /// checked after, so a server lying about `content-length` cannot get past
    /// it.
    pub fn take(self: *Exchange, c: anytype, max: usize) Client.Error!Str {
        comptime core.checkScope(@TypeOf(c), "exchange.take");
        const reader = self.reader orelse unreachable; // begin first, then take
        const bytes = self.bounded(std.Io.Reader.allocRemaining, .{ reader, c.arena(), std.Io.Limit.limited(max) }) catch |err| switch (err) {
            error.StreamTooLong => return error.BodyTooLarge,
            else => |e| return self.blame(e),
        };
        return c.str(bytes);
    }

    /// The body into memory the caller has already sized, exactly filling it.
    ///
    /// For a caller who read `content-length` off the head and would rather
    /// allocate once, at the right size, than let `take` grow into it — which
    /// is what an object store does, because it has a ceiling to check against
    /// that length before reading anything at all.
    pub fn readInto(self: *Exchange, buf: []u8) Client.Error!void {
        const reader = self.reader orelse unreachable; // begin first, then read
        return self.bounded(std.Io.Reader.readSliceAll, .{ reader, buf }) catch |err| switch (err) {
            error.EndOfStream => error.BodyTooShort,
            else => |e| self.blame(e),
        };
    }

    /// The body straight into `w`, allocating nothing at all, and how many
    /// bytes went. What a handler streaming an object into its own response
    /// wants: the ceiling is the transfer buffer rather than the body.
    pub fn pipe(self: *Exchange, w: *std.Io.Writer) Client.Error!u64 {
        const reader = self.reader orelse unreachable; // begin first, then pipe
        return self.bounded(std.Io.Reader.streamRemaining, .{ reader, w }) catch |err| return self.blame(err);
    }

    /// One chunk of the body into `w`, at most `limit` bytes, and how many
    /// went: what one socket read handed over, which is the unit a caller
    /// moving a body in pieces of its own choosing wants: a segment whose
    /// far end another thread may move while it reads. **Zero is the end of
    /// the body.**
    ///
    /// The same call on `ex.reader` directly is outside both clocks on a
    /// client with no Engine, because there is nothing there to cancel the
    /// read; this one is inside them (ADR 056).
    pub fn stream(self: *Exchange, w: *std.Io.Writer, limit: std.Io.Limit) Client.Error!usize {
        const reader = self.reader orelse unreachable; // begin first, then stream
        // std's TLS reader answers zero for a record that carried no
        // application data (a session ticket, a close alert, a record it
        // decrypted into its own buffer for the next call to serve), so a
        // zero from one read is not the end of anything; the end is
        // `EndOfStream`, and only that is handed back as zero.
        while (true) {
            const n = self.bounded(std.Io.Reader.stream, .{ reader, w, limit }) catch |err| switch (err) {
                error.EndOfStream => return 0,
                else => |e| return self.blame(e),
            };
            if (n != 0) return n;
        }
    }

    /// `Client.blame`, asked about every clock at once.
    ///
    /// The Engine's answer is consumed on asking, and `end` needs it as
    /// well: a call its own clock stopped must not then drain the body it
    /// stopped waiting for, which on a server that went quiet is the read
    /// that never returns. So the answer is folded into the two flags the
    /// engineless path already keeps, and `end` reads those. The first
    /// draft asked the bound here and drained in `end`, and the stall test
    /// under the Engine sat at zero CPU until it was noticed.
    fn blame(self: *Exchange, err: anytype) Client.Error {
        if (self.bound.fired()) {
            if (self.stall_armed) self.stalled = true else self.expired = true;
        }
        return self.client.blame(&self.bound, self.stall_armed, self.expired, self.stalled, err);
    }

    /// `f(args...)`, and bounded by `deadline` when there is one.
    ///
    /// With no deadline of its own — an Engine holds it, or there is none —
    /// this is the call, nothing else. With one, the call runs as a task of
    /// the `Io` and this fiber waits on a word the task sets when it is
    /// done, with the deadline as the wait's timeout. Past the deadline the
    /// task is cancelled: on `std.Io.Threaded` that is a signal into the
    /// blocking read, and `Future.cancel` returns only once the task has
    /// come out of it, so nothing is still reading when this returns. The
    /// error the task came back with is passed up and `blame` names it a
    /// timeout, the way it does under an Engine (ADR 056).
    ///
    /// **What it costs**: one `io.concurrent` per step — the head, the body
    /// — which on Threaded is a thread hop each way. Paid only on the path
    /// that asked for it.
    ///
    /// A cancellation of *this* task — a shutdown — comes back through the
    /// wait, is passed to the inner task, and is put back with `recancel`
    /// so the next `Io` call the caller makes still sees it.
    fn bounded(self: *Exchange, comptime f: anytype, args: anytype) Returns(f, @TypeOf(args)) {
        // Under an Engine the fiber carries the bound; with none, and with
        // neither clock set, there is nothing to wait for.
        if (!self.client.limits.engineless()) return @call(.auto, f, args);
        if (self.deadline_us == 0 and self.stall_ms == 0) return @call(.auto, f, args);
        const io = self.client.inner.io;
        const Task = struct {
            fn run(done: *std.atomic.Value(u32), on: std.Io, a: @TypeOf(args)) Returns(f, @TypeOf(args)) {
                defer {
                    done.store(1, .release);
                    on.futexWake(u32, &done.raw, 1);
                }
                return @call(.auto, f, a);
            }
        };
        var done: std.atomic.Value(u32) = .init(0);
        var future = io.concurrent(Task.run, .{ &done, io, args }) catch {
            // Nothing to run a second task on — a single-threaded `Io`. There
            // is then nothing that could cancel the call either, so it is
            // unbounded, exactly as it was before this existed.
            return @call(.auto, f, args);
        };
        while (done.load(.acquire) == 0) {
            // Whichever clock is nearer is the wait. The silence clock is
            // read fresh each time round, because the task moves it with
            // every chunk: a transfer that keeps moving wakes this loop once
            // per `stall_ms` and never fires it (ADR 056).
            const now = core.monotonicMicros();
            var wait: i64 = std.math.maxInt(i64);
            if (self.deadline_us != 0) {
                const left = self.deadline_us - now;
                if (left <= 0) {
                    self.expired = true;
                    return future.cancel(io);
                }
                wait = @min(wait, left);
            }
            if (self.stall_ms != 0) {
                const left = self.last_byte.load(.acquire) + @as(i64, self.stall_ms) * std.time.us_per_ms - now;
                if (left <= 0) {
                    std.debug.print("DIAG watcher: stalled, last_byte age {d}us\n", .{now - self.last_byte.load(.acquire)});
                    self.stalled = true;
                    return future.cancel(io);
                }
                wait = @min(wait, left);
            }
            io.futexWaitTimeout(u32, &done.raw, 0, .{ .duration = .{
                .raw = .fromMicroseconds(wait),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Canceled => {
                    const answer = future.cancel(io);
                    io.recancel();
                    return answer;
                },
            };
        }
        return future.await(io);
    }

    fn Returns(comptime f: anytype, comptime Args: type) type {
        return @TypeOf(@call(.auto, f, @as(Args, undefined)));
    }

    /// The most redirects one call follows. std's number, kept where the
    /// head can tell a walked chain from an unwalked one.
    const max_redirects = 3;

    /// Which of std's own six headers `Begin.headers` carries, so the slot
    /// can be left out and the caller's line sent once (ADR 182).
    const Given = struct {
        host: bool = false,
        authorization: bool = false,
        user_agent: bool = false,
        content_type: bool = false,
        connection: bool = false,
        accept_encoding: bool = false,

        fn of(headers: []const std.http.Header) Given {
            var g: Given = .{};
            for (headers) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "host")) g.host = true;
                if (std.ascii.eqlIgnoreCase(h.name, "authorization")) g.authorization = true;
                if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) g.user_agent = true;
                if (std.ascii.eqlIgnoreCase(h.name, "content-type")) g.content_type = true;
                if (std.ascii.eqlIgnoreCase(h.name, "connection")) g.connection = true;
                if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) g.accept_encoding = true;
            }
            return g;
        }
    };

    /// What one of std's slots is set to: the explicit value when the
    /// caller gave one, left out when `headers` carries the line, and
    /// std's own default otherwise.
    fn slot(explicit: ?[]const u8, given: bool) std.http.Client.Request.Headers.Value {
        if (explicit) |v| return .{ .override = v };
        if (given) return .omit;
        return .default;
    }

    /// Mark the connection closing when what is left of the body costs more to
    /// read than a new connection costs to open.
    ///
    /// **This is the bound `Client.close` was reaching for and does not
    /// reach.** That one asks the connection how many bytes are *buffered*,
    /// which for a 500 MB object that has just been refused is one read
    /// buffer — 8 KiB, under any sane `max_drain` — so the connection is kept
    /// and `std.http.Client.Request.deinit` then downloads all 500 MB to keep
    /// it. The header of this module has claimed since it shipped that a
    /// refused body is not downloaded, and until this ran it was not so.
    ///
    /// `http.Reader.State` carries the remaining length for the ordinary case,
    /// so there is nothing here to estimate. A chunked body, or one that ends
    /// when the connection does, has no remaining length to give — and
    /// something unbounded is over every ceiling, so those drop.
    fn dropIfDrainIsDearer(self: *Exchange) void {
        const conn = self.req.connection orelse return;
        const max_drain = self.client.settings.max_drain;
        switch (self.req.reader.state) {
            // Read to the end; the connection is clean.
            .ready => return,

            // The body was started and stopped, which is every refusal by
            // `take` — it reads up to `max` *before* deciding. std's `deinit`
            // marks the connection closing from this state whatever is left of
            // the body, so a leftover worth keeping has to be finished here or
            // `max_drain` names a ceiling that decides nothing on the only
            // path that reaches it.
            .body_remaining_content_length => |n| {
                if (n > max_drain) {
                    conn.closing = true;
                    return;
                }
                const r = self.reader orelse return;
                _ = r.discardRemaining() catch {
                    conn.closing = true;
                };
            },

            // Nothing was read yet. std's `deinit` drains this one itself and
            // with no limit, so the only job here is to refuse the ones too
            // big to be worth it.
            //
            // **Do not drain it here.** A HEAD response announces a length and
            // sends no body at all, and the Exchange's transfer buffer for one
            // is empty — reading a body that does not exist out of a buffer
            // that is not there segfaults inside `discardRemaining`, which is
            // what `s3/bucket.zig`'s `head` found the moment the drain above
            // was written without this branch beside it.
            .received_head => {
                if (!self.req.method.responseHasBody()) return;
                const left = self.announced orelse std.math.maxInt(u64);
                if (left > max_drain) conn.closing = true;
            },

            // Chunked, or a body that ends when the connection does: no
            // remaining length to weigh, and something unbounded is over every
            // ceiling there is.
            else => conn.closing = true,
        }
    }

    /// Give back the connection and the permit, in that order, and take the
    /// deadline off. Safe on an Exchange that never began, and safe twice.
    ///
    /// The order is the part that is not arbitrary: the permit is what bounds
    /// how many connections are live, so handing it back before the connection
    /// would let the next caller in while this one still holds one.
    pub fn end(self: *Exchange) void {
        if (self.open) {
            // A call its deadline stopped has nothing left worth draining
            // to keep the connection: the drain would be more of the wait
            // that already ran out. Closing is what stops std from trying.
            // And a deadline that has already fired is not armed again for
            // the close, so the drain is skipped rather than bounded: with
            // `closing` set, std's `deinit` reads nothing and lets the
            // socket go. `dropIfDrainIsDearer` would still read a small
            // leftover, and a leftover from a server that stalled is the
            // read that never returns — which is how the first draft of
            // this branch hung the stall test at zero CPU.
            if (self.expired or self.stalled) {
                if (self.req.connection) |conn| conn.closing = true;
                self.client.close(&self.req);
            } else {
                // Under the same deadline as the rest of the call, because a
                // drain is a read, and a server that stalls in the last
                // 64 KiB is the server this exists for.
                self.bounded(finish, .{self});
            }
            self.open = false;
            self.reader = null;
            self.announced = null;
        }
        self.bound.release();
        self.deadline_us = 0;
        self.expired = false;
        self.stall_ms = 0;
        self.stalled = false;
        self.stall_armed = false;
        if (self.permit) {
            self.client.gate.post(self.client.inner.io);
            self.permit = false;
        }
    }

    fn finish(self: *Exchange) void {
        self.dropIfDrainIsDearer();
        self.client.close(&self.req);
    }
};

/// A header by name out of a head block, case-insensitively: the walk
/// `Exchange.Head.header` and `Response.header` share. Null for a block with
/// no line in it, because `std.http.HeaderIterator.init` asserts the first
/// `\r\n` is there and a `Response` built by hand in a test has none.
fn headerIn(block: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, block, "\r\n") == null) return null;
    var it: std.http.HeaderIterator = .init(block);
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

pub const Response = struct {
    status: std.http.Status,
    /// The header block the answer arrived with — status line, every header,
    /// the blank line — kept into the Scope the way `head.keep(c)` keeps it,
    /// so it reads the same after the body has been through. One arena
    /// allocation its own size, on the whole-body calls only
    /// ([ADR 187](../docs/adr/187-a-head-that-outlives-its-body.md)).
    /// `header(name)` is the way to read it; a `Response` built by hand in
    /// a test leaves it empty and every lookup then answers null.
    headers: []const u8 = "",
    /// Request-lifetime text. It is in the Scope's arena, so it goes when the
    /// request does and nothing has to be freed — and it may not outlive the
    /// request without `.keep()`, like every other `Str`.
    body: Str,

    /// 2xx. Written out because `status.class()` reads worse at a call site
    /// and because everybody writes this line anyway.
    pub fn ok(self: Response) bool {
        return @intFromEnum(self.status) >= 200 and @intFromEnum(self.status) < 300;
    }

    /// A header by name, case-insensitively, or null when the answer did not
    /// carry it: `Retry-After` on a 429, `ETag` for the next conditional GET,
    /// `Location` on a 201, `Link` on a page-by-header API. The slice points
    /// into `headers`, so it lives as long as the Scope does and no longer.
    pub fn header(self: Response, name: []const u8) ?[]const u8 {
        return headerIn(self.headers, name);
    }

    /// The body parsed into a type of your own, allocated from the same Scope
    /// the body is in.
    ///
    /// Leaky on purpose: the arena is the request's and is reset whole, so a
    /// per-value `deinit` would be work with nothing to collect.
    pub fn json(self: Response, comptime T: type, c: anytype) !T {
        comptime core.checkScope(@TypeOf(c), "response.json");
        return std.json.parseFromSliceLeaky(T, c.arena(), self.body.view(), .{
            .ignore_unknown_fields = true,
        });
    }
};

/// `base` with `params` on the end of it as a query string, percent-encoded,
/// in the Scope's memory:
///
/// ```zig
/// const url = try fetch.withQuery(c, "https://api.example.com/search", .{ .page = 2, .q = q });
/// // https://api.example.com/search?page=2&q=a%20b
/// const res = try api.get(c, url, .{});
/// ```
///
/// `params` is a struct of your own, one field per param, and the field's
/// type is the whole of what it may be: an int, a bool, text (`[]const u8`,
/// a string literal, a `Str`), or an optional of one of those, where null is
/// the param left out. Anything else is a Refusal naming the field. A `base`
/// that already carries a `?` gets `&`; a `base` ending in `?` or `&` gets
/// the first param straight after it.
///
/// A function that answers a URL rather than a `.query` field on `Call`,
/// because `Call` is a plain struct and a struct of the caller's own cannot
/// sit in a field of it — and the same reason it is not an arm of
/// `Exchange.Body` ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)).
/// The URL is what every call takes, `Exchange.begin` included, so one
/// function serves all of them.
///
/// **One arena allocation, sized exactly**: the params are measured and then
/// written, the way `core.percent`'s own callers do, so there is no growing
/// writer and no second copy. The space is `%20` and never `+`, and the hex
/// is upper-case, for the reasons `core/percent.zig` gives: both are the
/// difference between a signed request that verifies and one that does not.
pub fn withQuery(c: anytype, base: []const u8, params: anytype) error{OutOfMemory}![]const u8 {
    comptime core.checkScope(@TypeOf(c), "fetch.withQuery");
    comptime checkQuery(@TypeOf(params), "fetch.withQuery", &.{});

    // Measured, then written, into exactly that.
    const first = querySeparator(base);
    const out = try c.arena().alloc(u8, base.len + queryLen(params, first, &.{}));
    var w: std.Io.Writer = .fixed(out);
    w.writeAll(base) catch unreachable; // measured above
    queryWrite(&w, params, first, &.{});
    std.debug.assert(w.buffered().len == out.len);
    return w.buffered();
}

/// The Refusal for params that are not a struct with one field per param,
/// and for any field no query string can carry. `skip` names the fields
/// that are not the query's — a target's path segments — so they are held
/// to a segment's rules instead (ADR 061).
pub fn checkQuery(comptime P: type, comptime called: []const u8, comptime skip: []const []const u8) void {
    const info = @typeInfo(P);
    // `.{}` is the empty tuple to Zig and "no params" to a caller, so it
    // passes; a tuple with something in it has no names to be params.
    const named = switch (info) {
        .@"struct" => |st| !st.is_tuple or st.fields.len == 0,
        else => false,
    };
    if (!named) @compileError("nilo: " ++ called ++ " was handed a " ++ @typeName(P) ++
        " for its params, and a query is a struct with one field per param.");
    inline for (info.@"struct".fields) |f| {
        if (comptime !among(skip, f.name)) comptime checkQueryField(f.name, f.type);
    }
}

/// What goes between a base and the first param: nothing when the base
/// already ends on a separator, `&` when it already has a query, `?`
/// otherwise. Every param after the first gets `&`.
pub fn querySeparator(base: []const u8) ?u8 {
    if (base.len == 0) return '?';
    if (base[base.len - 1] == '?' or base[base.len - 1] == '&') return null;
    if (std.mem.indexOfScalar(u8, base, '?') != null) return '&';
    return '?';
}

/// How many bytes `params` add after a base, with `first` the separator
/// before the first of them. The measuring half of `withQuery`, shared with
/// a target's URL so that one is also one allocation sized exactly.
pub fn queryLen(params: anytype, first: ?u8, comptime skip: []const []const u8) usize {
    var len: usize = 0;
    var written: usize = 0;
    inline for (@typeInfo(@TypeOf(params)).@"struct".fields) |f| {
        if (comptime among(skip, f.name)) continue;
        if (queryValue(@field(params, f.name))) |v| {
            if (written > 0 or first != null) len += 1;
            len += core.percent.encodedLen(f.name, .unreserved) + 1 + v.encodedLen();
            written += 1;
        }
    }
    return len;
}

/// The writing half of `queryLen`, into a writer already sized by it.
pub fn queryWrite(w: *std.Io.Writer, params: anytype, first: ?u8, comptime skip: []const []const u8) void {
    var sep = first;
    inline for (@typeInfo(@TypeOf(params)).@"struct".fields) |f| {
        if (comptime among(skip, f.name)) continue;
        if (queryValue(@field(params, f.name))) |v| {
            if (sep) |ch| w.writeByte(ch) catch unreachable;
            sep = '&';
            core.percent.encodeWrite(w, f.name, .unreserved) catch unreachable;
            w.writeByte('=') catch unreachable;
            v.write(w) catch unreachable;
        }
    }
}

fn among(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// One query param's value, on its way out: digits and the two words go as
/// they are, text is percent-encoded. A path segment of a target is written
/// the same way, which is why the type is shared (ADR 061).
pub const QueryValue = union(enum) {
    /// An int, formatted. Forty bytes holds a 128-bit one with its sign.
    number: struct { buf: [40]u8, len: usize },
    /// `true` or `false`.
    word: []const u8,
    /// Text, encoded on the way out with `/` as data.
    text: []const u8,

    pub fn encodedLen(self: QueryValue) usize {
        return switch (self) {
            .number => |n| n.len,
            .word => |s| s.len,
            .text => |s| core.percent.encodedLen(s, .unreserved),
        };
    }

    pub fn write(self: QueryValue, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .number => |n| try w.writeAll(n.buf[0..n.len]),
            .word => |s| try w.writeAll(s),
            .text => |s| try core.percent.encodeWrite(w, s, .unreserved),
        }
    }
};

/// The value of one field of a query struct as a `QueryValue`, or null for
/// an optional that is null, which is the param left out.
pub fn queryValue(v: anytype) ?QueryValue {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .null => return null,
        .optional => return if (v) |inner| queryValue(inner) else null,
        .int, .comptime_int => {
            var out: QueryValue = .{ .number = .{ .buf = undefined, .len = 0 } };
            const digits = std.fmt.bufPrint(&out.number.buf, "{d}", .{v}) catch unreachable; // 40 bytes holds any int here
            out.number.len = digits.len;
            return out;
        },
        .bool => return .{ .word = if (v) "true" else "false" },
        else => return .{ .text = if (T == Str) v.view() else v },
    }
}

/// Whether `T` is text this module reads as such: a `Str`, a slice of
/// bytes, or a pointer to an array of them, which is what a string literal
/// is.
pub fn isText(comptime T: type) bool {
    if (T == Str) return true;
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// The Refusal for a query field of a type no query string can carry: a
/// struct, a float, an enum, a pointer to something that is not text. Named
/// by the field, because the struct is anonymous and the field is what the
/// caller wrote.
pub fn checkQueryField(comptime field: []const u8, comptime T: type) void {
    const ok = switch (@typeInfo(T)) {
        .int, .comptime_int, .bool, .null => true,
        .optional => |o| return checkQueryField(field, o.child),
        else => isText(T),
    };
    if (!ok) @compileError("nilo: the query field `" ++ field ++ "` is a " ++ @typeName(T) ++
        ", and a query value is an int, a bool, text, or an optional of one.");
}

/// The Refusal for text handed to a JSON call. `std.json` would write it
/// out as one JSON string — `"{\"amount\":500}"`, quotes and escapes and all
/// — and the far end would answer 400 to a body that looked right in the
/// editor. A body already encoded goes through `post`.
pub fn refuseJsonText(comptime T: type, comptime called: []const u8) void {
    if (isText(T)) @compileError("nilo: " ++ called ++ " was handed text, and would send it as one JSON string. " ++
        "A body already encoded goes through post, put, patch or send.");
}

test "a client that was never started refuses rather than dialling undefined" {
    var client: Client = .init(std.testing.allocator, .{});
    defer client.deinit();

    var run: core.Run = .init(std.testing.allocator);
    defer run.deinit();

    try std.testing.expectError(error.NotStarted, client.get(&run, "http://example.invalid/", .{}));
}

test "an answer with no body by rule is bodiless whatever its headers say" {
    // The four the RFC lists, and a 200 beside them as the control.
    try std.testing.expect(Exchange.bodiless(.HEAD, .ok));
    try std.testing.expect(Exchange.bodiless(.GET, .@"continue"));
    try std.testing.expect(Exchange.bodiless(.POST, .no_content));
    try std.testing.expect(Exchange.bodiless(.GET, .not_modified));
    try std.testing.expect(!Exchange.bodiless(.GET, .ok));
    try std.testing.expect(!Exchange.bodiless(.DELETE, .ok));
}

test "the gate hands out no more permits than it was given" {
    var client: Client = .init(std.testing.allocator, .{ .max_in_flight = 2 });
    defer client.deinit();
    try std.testing.expectEqual(@as(usize, 2), client.gate.permits);
}

test "a response says whether it is one to read" {
    const body: Str = .static("");
    try std.testing.expect((Response{ .status = .ok, .body = body }).ok());
    try std.testing.expect((Response{ .status = .created, .body = body }).ok());
    try std.testing.expect(!(Response{ .status = .not_found, .body = body }).ok());
    try std.testing.expect(!(Response{ .status = .internal_server_error, .body = body }).ok());
    // The edges of the class, because 299 and 300 are one apart and one of
    // them is a redirect.
    try std.testing.expect((Response{ .status = @enumFromInt(299), .body = body }).ok());
    try std.testing.expect(!(Response{ .status = @enumFromInt(300), .body = body }).ok());
}

/// A `Limits` that always says its deadline is what fired, so the decision
/// `blame` makes can be checked without an Engine to fire one.
const always_fired: core.Limits = .{ .vtable = &.{
    .arm = struct {
        fn f(_: ?*anyopaque, _: *anyopaque, _: u32) void {}
    }.f,
    .release = struct {
        fn f(_: ?*anyopaque, _: *anyopaque) void {}
    }.f,
    .fired = struct {
        fn f(_: ?*anyopaque, _: *anyopaque) bool {
            return true;
        }
    }.f,
    .waiting = struct {
        fn f(_: ?*anyopaque) u64 {
            return 0;
        }
    }.f,
    .waited = struct {
        fn f(_: ?*anyopaque, _: u64) void {}
    }.f,
} };

test "a failure this call's own clock caused is a timeout, whatever it is called" {
    var client: Client = .init(std.testing.allocator, .{});
    defer client.deinit();

    // Armed against a Limits that claims every cancellation as its own: this
    // is the deadline case, and the caller should see `TimedOut`.
    var mine: core.Limits.Bound = .idle;
    defer mine.release();
    mine.arm(always_fired, 1_000);
    try std.testing.expectEqual(Client.Error.TimedOut, client.blame(&mine, false, false, false, error.Canceled));

    // And the case a real timer actually produces. `std.Io.Reader`'s error set
    // is fixed, so a cancellation mid-body arrives as `error.ReadFailed` with
    // the cause kept in a field; `fetch/deadline.zig` is where that was seen.
    // A version of `blame` that matched on `error.Canceled` returned this
    // unchanged and every timeout looked like a broken upstream.
    try std.testing.expectEqual(Client.Error.TimedOut, client.blame(&mine, false, false, false, error.ReadFailed));

    // Armed against nothing, which is what a shutdown looks like: the
    // cancellation was somebody else's and must not be reported as a timeout,
    // or every deploy would look like a slow upstream.
    var theirs: core.Limits.Bound = .idle;
    defer theirs.release();
    theirs.arm(.off, 1_000);
    try std.testing.expectEqual(Client.Error.Canceled, client.blame(&theirs, false, false, false, error.Canceled));

    // A failure with no deadline behind it is passed through as itself, which
    // is the whole reason the bound is asked rather than assumed.
    try std.testing.expectEqual(
        Client.Error.ConnectionRefused,
        client.blame(&theirs, false, false, false, error.ConnectionRefused),
    );
}

test "silence is blamed before the call's clock, and the Engine's one timer says which it stood for" {
    var client: Client = .init(std.testing.allocator, .{});
    defer client.deinit();

    // With no Engine the Exchange keeps both clocks itself, and the one
    // that fired is the one it says.
    var theirs: core.Limits.Bound = .idle;
    defer theirs.release();
    try std.testing.expectEqual(Client.Error.Stalled, client.blame(&theirs, false, false, true, error.ReadFailed));
    try std.testing.expectEqual(Client.Error.TimedOut, client.blame(&theirs, false, true, false, error.ReadFailed));

    // Under an Engine there is one timer, armed for whichever bound was
    // nearer, and `stall_armed` is what remembers which (ADR 056).
    var mine: core.Limits.Bound = .idle;
    defer mine.release();
    mine.arm(always_fired, 1_000);
    try std.testing.expectEqual(Client.Error.Stalled, client.blame(&mine, true, false, false, error.ReadFailed));
    var again: core.Limits.Bound = .idle;
    defer again.release();
    again.arm(always_fired, 1_000);
    try std.testing.expectEqual(Client.Error.TimedOut, client.blame(&again, false, false, false, error.ReadFailed));
}

test "the read buffer size reaches std's client, and the default is std's own" {
    var plain: Client = .init(std.testing.allocator, .{});
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 8 << 10), plain.inner.read_buffer_size);

    var wide: Client = .init(std.testing.allocator, .{ .read_buffer_size = 64 << 10 });
    defer wide.deinit();
    try std.testing.expectEqual(@as(usize, 64 << 10), wide.inner.read_buffer_size);
}

test "a streamed body is not replayed, because its reader is spent" {
    // The bound that keeps the retry honest. `live.zig` proves the retry
    // happens against a server that hangs up; this proves the one case it
    // must not happen in. Re-sending a `.stream` body would put fewer bytes
    // on the wire than the `content-length` announced, which is a corrupted
    // request rather than a recovered one
    // ([ADR 058](../docs/adr/058-most-of-an-s3-client-is-not-s3.md)).
    try std.testing.expect(Exchange.replayable(.none));
    try std.testing.expect(Exchange.replayable(.{ .slice = "x" }));

    var empty: std.Io.Reader = .fixed("");
    try std.testing.expect(!Exchange.replayable(.{ .stream = .{ .reader = &empty, .len = 0 } }));
}

// ---- the ordinary call: a query on the URL (ADR 061) ----

test "a query struct becomes a percent-encoded query string, in one allocation" {
    var run: core.Run = .init(std.testing.allocator);
    defer run.deinit();

    const url = try withQuery(&run, "https://api.example.com/search", .{ .page = 2, .q = "a b" });
    try std.testing.expectEqualStrings("https://api.example.com/search?page=2&q=a%20b", url);

    // Every type a value may be, and the encoding each gets: digits and the
    // two words go bare, text is escaped with `/` as data and the hex in
    // upper case, the way a signature wants it.
    const mixed = try withQuery(&run, "http://h/", .{
        .n = @as(i64, -7),
        .big = @as(u64, std.math.maxInt(u64)),
        .yes = true,
        .no = false,
        .path = "a/b?c=d&e",
        .word = run.str("café"),
    });
    try std.testing.expectEqualStrings(
        "http://h/?n=-7&big=18446744073709551615&yes=true&no=false&path=a%2Fb%3Fc%3Dd%26e&word=caf%C3%A9",
        mixed,
    );
}

test "a null param is left out, and a base that already has a query gets an ampersand" {
    var run: core.Run = .init(std.testing.allocator);
    defer run.deinit();

    const cursor: ?[]const u8 = null;
    const limit: ?u32 = 50;
    const url = try withQuery(&run, "http://h/items?sort=asc", .{ .cursor = cursor, .limit = limit });
    try std.testing.expectEqualStrings("http://h/items?sort=asc&limit=50", url);

    // Nothing to add is the base handed back byte for byte, and a base
    // that ends on its separator takes the first param straight after it.
    try std.testing.expectEqualStrings("http://h/items", try withQuery(&run, "http://h/items", .{ .cursor = cursor }));
    try std.testing.expectEqualStrings("http://h/items", try withQuery(&run, "http://h/items", .{}));
    try std.testing.expectEqualStrings("http://h/?a=1", try withQuery(&run, "http://h/?", .{ .a = 1 }));
    try std.testing.expectEqualStrings("http://h/?x=1&a=1", try withQuery(&run, "http://h/?x=1&", .{ .a = 1 }));
}

test "a query is written into exactly the bytes it was measured at" {
    // The measuring pass and the writing pass are two walks over the same
    // fields, and the assert in `withQuery` is what holds them together;
    // this is the same claim from the outside, on a value of every kind.
    var run: core.Run = .init(std.testing.allocator);
    defer run.deinit();
    const url = try withQuery(&run, "http://h/x", .{ .a = 0, .b = "", .c = true, .d = "%" });
    try std.testing.expectEqualStrings("http://h/x?a=0&b=&c=true&d=%25", url);
}

// ---- a response carries its headers (ADR 187) ----

test "a response answers a header case-insensitively, and null for one it did not carry" {
    const res: Response = .{
        .status = .too_many_requests,
        .headers = "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 30\r\nContent-Length: 0\r\n\r\n",
        .body = .static(""),
    };
    try std.testing.expectEqualStrings("30", res.header("retry-after").?);
    try std.testing.expectEqualStrings("30", res.header("RETRY-AFTER").?);
    try std.testing.expectEqualStrings("0", res.header("content-length").?);
    try std.testing.expect(res.header("etag") == null);

    // A `Response` built by hand carries no block, and a lookup is then a
    // null rather than a walk off the end of nothing.
    const bare: Response = .{ .status = .ok, .body = .static("") };
    try std.testing.expect(bare.header("retry-after") == null);
}

test "text is read as text and a struct is not, which is what the two Refusals rest on" {
    try std.testing.expect(isText([]const u8));
    try std.testing.expect(isText([]u8));
    try std.testing.expect(isText(*const [3:0]u8));
    try std.testing.expect(isText(Str));
    try std.testing.expect(!isText(u32));
    try std.testing.expect(!isText(struct { a: u8 }));
    try std.testing.expect(!isText([]const u32));
}

test {
    _ = @import("live.zig");
    _ = @import("target.zig");
}
