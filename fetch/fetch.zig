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
//!   concurrent handlers is 500 live connections, and an HTTPS one allocates
//!   up to 59,151 bytes of buffers (about 12 KB stay resident after a small
//!   answer and 45 KB after a large one, `bench/result/fetch.md`) — up to
//!   29.6 MB nobody asked for, plus 500 handshakes.
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
//! - **A redirect that keeps its credentials at home.** A followed redirect
//!   is walked here, not by `std.http.Client`, which re-sends every header
//!   it was handed and strips only a list `nilo_fetch` never fills. Past a
//!   change of scheme, host or port the `authorization`, `cookie` and
//!   `proxy-authorization` lines and a target's standing headers stay
//!   behind, a hop from `https` to `http` is `error.InsecureRedirect`, and
//!   `Response.redirected` says where the call ended
//!   ([ADR 183](../docs/adr/183-a-redirect-is-a-decision-with-a-name.md)).
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
//! Not a circuit breaker, not a rate limiter, and not a retry policy of
//! its own: how many times, how long between and what counts as failure are
//! decisions about somebody else's service, and they stay with the caller who
//! knows what that service promises. What is here is the part that is the
//! same for everybody: do not hold a connection forever, do not hold more
//! than you meant to, do not read more than you asked for, and, for a
//! `Target` that declares `.retry`, try again the way every careful client
//! does and the loop each caller wrote does not: only a call that can be
//! sent again, with jitter, `Retry-After`, a budget and the route's deadline
//! ([ADR 271](../docs/adr/271-a-retry-is-the-callers-numbers-and-nilos-mechanism.md)).
//! The numbers are the caller's, on the type; the mechanism is `retry.zig`.
//! A call that is retried is a new `Exchange` each time, so the
//! stale-connection replay below (transport hygiene, inside one try) and the
//! retry (a decision, between tries) compose: a reaped socket is replaced
//! inside the try and costs the retry nothing.

const std = @import("std");
const core = @import("nilo_core");

const Str = core.Str;

/// How a struct of params is encoded; internal, so that the module root names
/// only what the reference lists.
const encoding = @import("params.zig");

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

/// A call tried again by a mechanism, with the caller's numbers: the policy,
/// its budget and the helpers `nilo_s3` shares
/// ([ADR 271](../docs/adr/271-a-retry-is-the-callers-numbers-and-nilos-mechanism.md)).
pub const retry = @import("retry.zig");
pub const Retry = retry.Retry;

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
    /// The second std client, for the one kind of call that cannot be sent
    /// twice: a body that is a reader. Its pool keeps nothing
    /// (`free_size = 0`), so every call on it opens a connection of its own
    /// and a socket the server closed while it idled can never be the one a
    /// caller's reader is consumed on. Idle until the first `.stream` body,
    /// when it costs what any std client costs on first use (for HTTPS, one
    /// scan of the system's root certificates).
    fresh: std.http.Client,
    gate: std.Io.Semaphore,
    limits: core.Limits = .none,
    settings: Settings,
    started: bool = false,
    /// What `settings.proxy` became, built by `nilo_start` and read by std
    /// through `inner.http_proxy` and `fresh.http_proxy`. On the heap, with
    /// its host and its `Proxy-Authorization` value, so that std's pointer
    /// to it does not depend on where this struct sits; `deinit` frees all
    /// three.
    proxy: ?*std.http.Client.Proxy = null,

    pub const Settings = struct {
        /// How many calls may be in flight at once, across every host.
        ///
        /// This is the one that is not a nicety. Without it the ceiling on
        /// live connections is however many handlers happen to be running,
        /// and each HTTPS connection allocates up to 59,151 bytes of TLS and
        /// socket buffers (about 12 KB stay resident after a small answer and
        /// 45 KB after a large one). Past this a caller waits for a permit
        /// rather than opening connection 501.
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

        /// The egress proxy every `http://` call goes through, or null for
        /// none. **Given here and never read from the environment**: a
        /// process that finds `HTTP_PROXY` set by something it did not write
        /// and routes its calls through it has a surprise to explain, and
        /// the caller's own configuration (`nilo_config`) is where a
        /// deployment says it ([ADR 267](../docs/adr/267-a-call-can-go-through-a-proxy-and-trust-a-private-authority.md)).
        proxy: ?Proxy = null,

        /// The certificate authorities an `https://` call trusts, as a
        /// bundle the caller loaded, or null for the system's (scanned on
        /// the first `https://` call, as `std.http.Client` does). A private
        /// authority is the system's plus one file:
        ///
        /// ```zig
        /// var roots: std.crypto.Certificate.Bundle = .empty;
        /// defer roots.deinit(gpa);
        /// try roots.rescan(gpa, io, now);
        /// try roots.addCertsFromFilePathAbsolute(gpa, io, now, "/etc/corp/ca.pem");
        /// ```
        ///
        /// The bundle is the caller's: it must outlive the client and must
        /// not change while the client lives, and the client never frees it.
        /// Both of the client's std clients read the one copy
        /// ([ADR 267](../docs/adr/267-a-call-can-go-through-a-proxy-and-trust-a-private-authority.md)).
        roots: ?*const std.crypto.Certificate.Bundle = null,
    };

    /// A forward proxy for `http://` calls
    /// ([ADR 267](../docs/adr/267-a-call-can-go-through-a-proxy-and-trust-a-private-authority.md)).
    pub const Proxy = struct {
        /// `http://[user:password@]host[:port]`, or `https://` for a proxy
        /// that is itself reached over TLS. The user and password, when
        /// there are any, go to the proxy as `Proxy-Authorization: Basic`
        /// and to nobody else; percent-encode anything in them that a URL
        /// would not carry. A scheme other than those two, no host, or a
        /// credential over 255 bytes is `error.InvalidProxy` at start.
        url: []const u8,
        /// Hosts that skip the proxy and are dialled directly. std reads no
        /// `NO_PROXY`, so the list is here. An entry matches the host it
        /// names and every host under it, ignoring case: `corp.example`
        /// skips `corp.example` and `api.corp.example`, a leading `.` or
        /// `*.` is the same, `127.0.0.1` skips that address, and `*` skips
        /// everything. There is no CIDR range, and the port is not part of
        /// a match. **Nothing is skipped that is not listed, `localhost`
        /// included.**
        bypass: []const []const u8 = &.{},
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
        /// A followed redirect led from `https` to `http`. Not followed:
        /// whatever the first answer asked for, the next request would
        /// cross the network in the clear, and a caller who meant that
        /// says the `http://` address itself (ADR 183).
        InsecureRedirect,
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
        /// An `https://` call that `Settings.proxy` would carry. std has no
        /// way to start TLS inside a tunnel, and the one it offers sends the
        /// request in the clear, so the call is refused before anything is
        /// dialled. Name the host in `Proxy.bypass` to call it directly
        /// ([ADR 267](../docs/adr/267-a-call-can-go-through-a-proxy-and-trust-a-private-authority.md)).
        TlsThroughProxy,
        OutOfMemory,
    } || std.Uri.ParseError || std.http.Client.RequestError ||
        std.http.Client.Request.ReceiveHeadError ||
        std.Io.Writer.Error || std.Io.Reader.Error || std.Io.Cancelable;

    pub fn init(gpa: std.mem.Allocator, settings: Settings) Client {
        return .{
            .inner = .{ .allocator = gpa, .io = undefined, .read_buffer_size = settings.read_buffer_size },
            .fresh = .{
                .allocator = gpa,
                .io = undefined,
                .read_buffer_size = settings.read_buffer_size,
                .connection_pool = .{ .free_size = 0 },
            },
            .gate = .{ .permits = settings.max_in_flight },
            .settings = settings,
        };
    }

    pub fn deinit(self: *Client) void {
        // Read before std's `deinit`, which leaves `inner` undefined.
        const gpa = self.inner.allocator;
        if (self.started) {
            // The bundle is the caller's, shared by both std clients: leave
            // each with an empty one so that neither frees it.
            if (self.settings.roots != null and !std.http.Client.disable_tls) {
                self.inner.ca_bundle = .empty;
                self.fresh.ca_bundle = .empty;
            }
            self.inner.deinit();
            self.fresh.deinit();
        }
        if (self.proxy) |p| {
            gpa.free(@constCast(p.host.bytes));
            if (p.authorization) |a| gpa.free(@constCast(a));
            gpa.destroy(p);
            self.proxy = null;
        }
    }

    /// Finished once the event loop exists, like every service that needs one
    /// (ADR 037). The third parameter is what bounds a call in time
    /// (ADR 056); a Fitting that did not take it could open a connection and
    /// never give up on it.
    ///
    /// `.none` for the limits is not "no deadline": it is "no Engine to arm
    /// one on", and the client then bounds the call itself, as a task of
    /// `io` it can cancel (ADR 056).
    ///
    /// A `Settings.proxy` is parsed here, so a bad URL stops the program
    /// before it serves, as every other bad setting does: `error.InvalidProxy`.
    /// The client must not move after this: std's two clients are handed
    /// pointers into it.
    pub fn nilo_start(self: *Client, io: std.Io, limits: core.Limits) !void {
        self.inner.io = io;
        self.fresh.io = io;
        if (self.settings.proxy) |p| try self.installProxy(p);
        if (self.settings.roots) |bundle| {
            if (!std.http.Client.disable_tls) {
                // A bundle and a time that is not null is what stops std
                // scanning the system on the first `https://` call, so this
                // is the whole of "trust these". Shared by both clients, not
                // copied: it is read-only from here, and `deinit` takes it
                // back out before std frees anything.
                const now = std.Io.Clock.real.now(io);
                self.inner.ca_bundle = bundle.*;
                self.inner.now = now;
                self.fresh.ca_bundle = bundle.*;
                self.fresh.now = now;
            }
        }
        self.limits = limits;
        self.started = true;
    }

    /// `p` as the `std.http.Client.Proxy` both std clients carry as their
    /// `http_proxy`. Only `http_proxy`: an `https://` call is never sent
    /// through it (`Exchange.pickConnection`), and `https_proxy` stays null
    /// so that std cannot route one by itself. `supports_connect` is false,
    /// so an `http://` call is sent to the proxy as std's forward-proxy form
    /// (the full URL on the request line, `Proxy-Authorization` after the
    /// headers) and never as a `CONNECT` to a port a proxy may refuse.
    fn installProxy(self: *Client, p: Proxy) !void {
        const gpa = self.inner.allocator;
        const uri = std.Uri.parse(p.url) catch return error.InvalidProxy;
        const protocol: std.http.Client.Protocol = if (std.ascii.eqlIgnoreCase(uri.scheme, "http"))
            .plain
        else if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
            .tls
        else
            return error.InvalidProxy;
        var name: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = std.Io.net.HostName.fromUri(uri, &name) catch return error.InvalidProxy;

        const basic = std.http.Client.basic_authorization;
        // `basic_authorization.write` formats into a buffer of 255 and 255
        // bytes and trusts the caller; a longer credential is refused here
        // rather than trusted.
        const has_credential = uri.user != null or uri.password != null;
        const auth_len = if (has_credential) basic.valueLengthFromUri(uri) else 0;
        if (auth_len > basic.max_value_len) return error.InvalidProxy;

        const bytes = try gpa.dupe(u8, host.bytes);
        errdefer gpa.free(bytes);
        const authorization: ?[]u8 = if (has_credential) try gpa.alloc(u8, auth_len) else null;
        errdefer if (authorization) |a| gpa.free(a);
        if (authorization) |a| std.debug.assert(basic.value(uri, a).len == a.len);
        const proxy = try gpa.create(std.http.Client.Proxy);
        proxy.* = .{
            .protocol = protocol,
            .host = .{ .bytes = bytes },
            .authorization = authorization,
            .port = uri.port orelse switch (protocol) {
                .plain => 80,
                .tls => 443,
            },
            .supports_connect = false,
        };
        self.proxy = proxy;
        self.inner.http_proxy = proxy;
        self.fresh.http_proxy = proxy;
    }

    /// Whether `host` is one `Settings.proxy.bypass` names, and so is dialled
    /// directly.
    fn skipsProxy(self: *const Client, host: []const u8) bool {
        const p = self.settings.proxy orelse return false;
        for (p.bypass) |entry| if (bypassMatches(entry, host)) return true;
        return false;
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
        comptime encoding.refuseJsonText(@TypeOf(value), "fetch.postJson");
        return self.sendJson(c, .POST, url, value, call);
    }

    pub fn putJson(self: *Client, c: anytype, url: []const u8, value: anytype, call: Call) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.putJson");
        comptime encoding.refuseJsonText(@TypeOf(value), "fetch.putJson");
        return self.sendJson(c, .PUT, url, value, call);
    }

    pub fn patchJson(self: *Client, c: anytype, url: []const u8, value: anytype, call: Call) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.patchJson");
        comptime encoding.refuseJsonText(@TypeOf(value), "fetch.patchJson");
        return self.sendJson(c, .PATCH, url, value, call);
    }

    /// `post` with `fields` written as an `application/x-www-form-urlencoded`
    /// body and that `content-type` said for you, unless `call.headers`
    /// names one. What an OAuth token endpoint takes for the code exchange
    /// and the client-credentials grant (RFC 6749 §4.1.3, §4.4.2). `fields`
    /// is a struct under `withQuery`'s rules: an int, a bool, text, or an
    /// optional of one, null left out, anything else a Refusal naming the
    /// field ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)).
    pub fn postForm(self: *Client, c: anytype, url: []const u8, fields: anytype, call: Call) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.postForm");
        comptime encoding.checkForm(@TypeOf(fields), "fetch.postForm");
        return self.sendForm(c, .POST, url, fields, call);
    }

    pub fn putForm(self: *Client, c: anytype, url: []const u8, fields: anytype, call: Call) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.putForm");
        comptime encoding.checkForm(@TypeOf(fields), "fetch.putForm");
        return self.sendForm(c, .PUT, url, fields, call);
    }

    /// The whole of what the two above do, for a method they do not name.
    pub fn sendForm(
        self: *Client,
        c: anytype,
        method: std.http.Method,
        url: []const u8,
        fields: anytype,
        call: Call,
    ) Error!Response {
        comptime core.checkScope(@TypeOf(c), "fetch.sendForm");
        comptime encoding.checkForm(@TypeOf(fields), "fetch.sendForm");
        const bytes = try formBody(c, fields);
        return self.sendAs(c, method, url, bytes, encoding.form_content_type, call, .{});
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
        comptime encoding.refuseJsonText(@TypeOf(value), "fetch.sendJson");
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
        // The call's span, when the Scope traces: its context is what the
        // `traceparent` names, so the next service's span is its child
        // (ADR 247). Null under a `Run`, and on an App that does not trace.
        // Ended here, at one place for each way out, rather than by a
        // `defer` inside, which the compiler copies onto every return.
        const begun = core.traceBeginOf(c);
        const res = self.sendCarrying(c, method, url, body, content_type, call, standing, begun) catch |err| {
            if (begun) |b| endTrace(c, b, method, url, 0, @errorName(err));
            return err;
        };
        if (begun) |b| endTrace(c, b, method, url, @backingInt(res.status), null);
        return res;
    }

    fn sendCarrying(
        self: *Client,
        c: anytype,
        method: std.http.Method,
        url: []const u8,
        body: ?[]const u8,
        content_type: ?[]const u8,
        call: Call,
        standing: Standing,
        begun: ?core.trace.Outbound,
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

        var traceparent: [core.trace.text_len]u8 = undefined;

        // The request's id and the trace, when there is a request: up to
        // three headers, and for the ordinary call (no headers of its own)
        // they live in this array rather than in the arena (ADR 158).
        var carried: [3]std.http.Header = undefined;
        const headers = try withCarried(c, lines, &carried, self.settings.forward_request_id, begun, &traceparent);

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
            .route_left_ms = core.timeLeftOf(c),
            .stall_ms = call.stall_ms,
            .redirects = .{ .follow = &redirect_buffer },
            // A target's standing headers are written for its own origin
            // and stay there (ADR 183).
            .origin_only = standing.headers,
        });

        // Where a followed redirect ended, written out before the redirect
        // buffer goes: one arena allocation on a call that was redirected
        // and none on one that was not (ADR 183).
        const landed: ?[]const u8 = if (head.redirected) |uri| try urlIn(c.arena(), uri) else null;

        // The header block, kept before the body reads over it: the second
        // arena allocation of a whole-body call, beside the body's own, so
        // that `res.header("retry-after")` is there to read after the call
        // ([ADR 187](../docs/adr/187-a-head-that-outlives-its-body.md)).
        const kept = try c.arena().dupe(u8, head.bytes);

        return .{
            .status = head.status,
            .headers = kept,
            .redirected = landed,
            .body = try ex.take(c, call.max_body orelse self.settings.max_body),
        };
    }

    /// `given` plus what the call carries from the request: its id, and its
    /// trace when the Scope traces. Each is left out when the caller already
    /// named it, and `given` comes back as it was when nothing is added.
    ///
    /// A call with no headers of its own costs nothing here: what is added
    /// goes in `carried`. A call that passes headers spends one bump of the
    /// Scope's arena on the merge, which is the one allocation this decision
    /// makes and the reason it is written down (ADR 158, ADR 247).
    fn withCarried(
        c: anytype,
        given: []const std.http.Header,
        carried: *[3]std.http.Header,
        forward_id: bool,
        begun: ?core.trace.Outbound,
        traceparent: *[core.trace.text_len]u8,
    ) Error![]const std.http.Header {
        const S = @typeInfo(@TypeOf(c)).pointer.child;
        var n: usize = 0;
        if (forward_id) if (core.requestIdOf(S, c)) |id| {
            if (!namesHeader(given, request_id_header)) {
                carried[n] = .{ .name = request_id_header, .value = id.view() };
                n += 1;
            }
        };
        if (begun) |b| if (!namesHeader(given, core.trace.header)) {
            carried[n] = .{ .name = core.trace.header, .value = b.context.format(traceparent) };
            n += 1;
            if (b.state.len > 0) {
                carried[n] = .{ .name = core.trace.state_header, .value = b.state };
                n += 1;
            }
        };
        if (n == 0) return given;
        if (given.len == 0) return carried[0..n];
        const merged = try c.arena().alloc(std.http.Header, given.len + n);
        @memcpy(merged[0..given.len], given);
        @memcpy(merged[given.len..], carried[0..n]);
        return merged;
    }

    /// Tell a Scope that traces how the call it began a span for ended.
    fn endTrace(c: anytype, begun: core.trace.Outbound, method: std.http.Method, url: []const u8, status: u16, failure: ?[]const u8) void {
        core.traceEndOf(c, begun, .{
            .method = @tagName(method),
            .url = url,
            .status = status,
            .failure = failure,
        });
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

/// Whether `entry`, one line of `Proxy.bypass`, names `host` or a host under
/// it: the same name ignoring case, or a name that ends in a dot and the
/// entry. A leading `.` or `*.` on the entry is the same as none, and `*`
/// is every host.
fn bypassMatches(entry: []const u8, host: []const u8) bool {
    var e = entry;
    if (std.mem.eql(u8, e, "*")) return true;
    if (std.mem.startsWith(u8, e, "*.")) e = e[2..] else if (std.mem.startsWith(u8, e, ".")) e = e[1..];
    if (e.len == 0 or host.len < e.len) return false;
    if (!std.ascii.eqlIgnoreCase(host[host.len - e.len ..], e)) return false;
    return host.len == e.len or host[host.len - e.len - 1] == '.';
}

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
    /// Whether the attempt in hand is on a connection taken out of the pool,
    /// one that had already carried a request, and not on one it dialled.
    /// Set by `attempt`, read by `nothingCameBack` (ADR 058).
    reused: bool = false,
    /// Whether any of an answer reached this side during the attempt in
    /// hand: set by `earlyAnswer` when a head arrived on a failed write.
    heard: bool = false,

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
        /// The time the Scope's request has left, from `core.timeLeftOf`, or
        /// null when it has no deadline. The call's bound is the shorter of
        /// this and `timeout_ms`, and a request with none left makes no call
        /// at all: `error.TimedOut` before the gate, the dial or a byte
        /// ([ADR 105](../docs/adr/105-a-route-can-say-how-long-it-has.md)).
        route_left_ms: ?u32 = null,
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
        /// redirect sends a request that cannot be valid at the other end.
        ///
        /// **A followed redirect is walked by this file, not by std**, so
        /// that each hop is compared with the one before it: past a change
        /// of origin (scheme, host or port) the credentials are dropped, a
        /// hop from `https` to `http` is `error.InsecureRedirect`, and the
        /// method and body change the way std's did (ADR 183).
        redirects: Redirects = .refuse,
        /// Headers, by name, that are written for the origin this call was
        /// made to and go no further: a followed redirect to another origin
        /// leaves them behind, beside the four every call drops there
        /// (`authorization`, `cookie`, `proxy-authorization`,
        /// `www-authenticate`). `Client.send` puts a Target's standing
        /// headers here, because an `x-api-key` is a credential nilo cannot
        /// tell from an `accept` (ADR 183). Only the names are read.
        origin_only: []const std.http.Header = &.{},
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
            return @backingInt(self.status) >= 200 and @backingInt(self.status) < 300;
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

        // A request whose deadline has passed is not dialled for (ADR 105).
        if (opts.route_left_ms) |left| if (left == 0) return error.TimedOut;

        // The permit is taken before the deadline is armed, so a caller
        // queueing for one is not also being timed out of the queue by a clock
        // it has not started. It goes back in `end`, after the connection.
        // A queue is a park like a socket is, so the watchdog is told
        // (ADR 210).
        const queued_at = core.monotonicMicros();
        {
            const w = client.limits.waiting();
            defer client.limits.waited(w);
            try client.gate.wait(io);
        }
        self.permit = true;

        // **The route's time is counted from when it was read, not from when
        // the permit arrived** (ADR 105): what the queue took is already
        // spent, and a request that is past its deadline after the wait is
        // not dialled for. The wait itself is not bounded by the route's
        // deadline, which stays an open item in `docs/todo.md`.
        const route_left_ms: ?u32 = if (opts.route_left_ms) |left| blk: {
            const spent_us = core.monotonicMicros() - queued_at;
            const left_us = @as(i64, left) * std.time.us_per_ms - spent_us;
            if (left_us <= 0) return error.TimedOut;
            break :blk @intCast(@divFloor(left_us + std.time.us_per_ms - 1, std.time.us_per_ms));
        } else null;

        // One deadline, held by whichever of the two can enforce it. Under an
        // Engine that is the Bound, which cancels the fiber; with none, it is
        // an absolute time every step below is run against as a task that
        // gets cancelled (ADR 056). Zero is no limit either way.
        // The other clock counts from the last byte, and until one arrives
        // that is now: a head that never comes is silence too (ADR 056).
        const own_ms = opts.timeout_ms orelse client.settings.timeout_ms;
        // The route's deadline is one more bound on the call, and the
        // shorter wins; zero is no limit at either end (ADR 105).
        const ms = if (route_left_ms) |left| (if (own_ms == 0) left else @min(own_ms, left)) else own_ms;
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
        //   fixed. A third spelling is a request with a body: its head is
        //   flushed first, the peer's RST comes back, and the body write is
        //   what fails (`WriteFailed`). It counts only on a connection taken
        //   out of the pool (`takePooled`), never on one this call dialled,
        //   and only when no head came back; a `putForm` or `postJson` as the
        //   call after a quiet spell failed every time before it did.
        // - **Only a body still where it was.** A `.stream` body has had its
        //   reader consumed, so re-sending it would put fewer bytes on the
        //   wire than the `content-length` promised — worse than the error.
        //   It does not need the replay: it is sent on a fresh connection
        //   (`Client.fresh`), which cannot be stale.
        // - **Inside the same permit and the same deadline.** Both are taken
        //   above and neither is re-armed, so a retry cannot double the time
        //   budget or take a second seat at the gate.
        //
        // **A redirect is walked here, one hop at a time**, with the same
        // permit and the same deadline all the way: std would walk it
        // inside `receiveHead` and re-send every header it was given, so
        // it is told to hand every redirect back and `follow` below makes
        // the decision (ADR 183).
        var here = uri;
        var hop = opts;
        var rest = opts.redirects.buffer();
        var left: u8 = max_redirects;
        var owned: []const std.http.Header = &.{};
        defer if (owned.len != 0) client.inner.allocator.free(owned);
        try self.dispatch(client, here, hop);
        while (opts.redirects == .follow and self.redirects()) {
            if (left == 0) return error.TooManyHttpRedirects;
            try self.follow(&here, &hop, &rest, &owned);
            left -= 1;
            try self.dispatch(client, here, hop);
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
            // Fewer redirects left than it started with is a chain
            // walked, and `here` is then the end of it, resolved into the
            // caller's `redirect_buffer` by std's own `resolveInPlace`.
            .redirected = if (left < max_redirects) here else null,
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

    /// One request to `uri`, sent and its head read, with the one retry onto
    /// a connection the peer had already closed (the long comment in
    /// `begin`). Run once for the call and once more for every redirect
    /// followed, so each hop gets the same protection from a reaped socket.
    fn dispatch(self: *Exchange, client: *Client, uri: std.Uri, opts: Begin) Client.Error!void {
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
            return;
        }
    }

    /// Whether the head just read is a redirect `follow` is to walk. Not a
    /// 304, which has no `Location` and is an answer, and not the answer to
    /// a HEAD, which std never followed and which is handed back as itself.
    fn redirects(self: *const Exchange) bool {
        const status = self.res.head.status;
        return status.class() == .redirect and status != .not_modified and self.req.method != .HEAD;
    }

    /// Turn the redirect just read into the next request: the `Location`
    /// resolved against where this one went, what must not cross carried no
    /// further, and the connection it came on given back.
    ///
    /// **The comparison is with the hop before, and what is dropped stays
    /// dropped.** `hop` is rewritten in place, so a chain that leaves an
    /// origin and comes back to it does not pick the credentials up again.
    /// The rule is `judge` and the headers are `trimmed`, so both are read
    /// and tested apart from a socket.
    ///
    /// The rest is what std did, kept: a 303 becomes a GET, a 301 or 302 on
    /// a POST does too, both without a body, and any other redirect of a
    /// request that has a body is `error.RedirectRequiresResend`, because
    /// the body is spent (ADR 183).
    fn follow(
        self: *Exchange,
        here: *std.Uri,
        hop: *Begin,
        rest: *[]u8,
        owned: *[]const std.http.Header,
    ) Client.Error!void {
        const head = self.res.head;
        const said = head.location orelse return error.HttpRedirectLocationMissing;
        if (said.len > rest.len) return error.HttpRedirectLocationOversize;
        const location = rest.*[0..said.len];
        @memcpy(location, said);
        const next = here.resolveInPlace(location.len, rest) catch |err| switch (err) {
            error.NoSpaceLeft => return error.HttpRedirectLocationOversize,
            else => return error.HttpRedirectLocationInvalid,
        };

        const crossing = judge(here.*, next);
        if (crossing == .downgrade) return error.InsecureRedirect;

        var next_hop = hop.*;
        const to_get = switch (head.status) {
            .see_other => true,
            .moved_permanently, .found => hop.method == .POST,
            else => false,
        };
        if (to_get) {
            next_hop.method = .GET;
            next_hop.body = .none;
            next_hop.content_type = null;
        } else if (hop.method.requestHasBody() or hop.body != .none) {
            return error.RedirectRequiresResend;
        }
        if (crossing == .other_origin) {
            next_hop.authorization = null;
            next_hop.host = null;
        }
        const lines = try trimmed(
            self.client.inner.allocator,
            hop.headers,
            hop.origin_only,
            crossing == .other_origin,
            to_get,
        );
        if (lines.ptr != hop.headers.ptr) {
            if (owned.len != 0) self.client.inner.allocator.free(owned.*);
            owned.* = lines;
        }
        next_hop.headers = lines;

        // The redirect's own body is read or dropped the way any answer's
        // is: a small one is drained and the connection kept, a large or
        // unbounded one costs the connection (`dropIfDrainIsDearer`).
        self.announced = head.content_length;
        self.bounded(finish, .{self});
        self.open = false;
        self.announced = null;

        here.* = next;
        hop.* = next_hop;
    }

    /// What a redirect from one request's address to the next means for the
    /// request that follows.
    const Crossing = enum {
        /// The same scheme, host and port: everything goes along.
        same_origin,
        /// Another origin: credentials stay behind.
        other_origin,
        /// From `https` to `http`: refused.
        downgrade,
    };

    /// The rule for another place: the **origin**, as reqwest and the Fetch
    /// standard have it, and not std's `sameParentDomain`, which is Go's
    /// looser reading and sends a token to any port of the host it was
    /// written for, and to its subdomains (ADR 183). Scheme and host
    /// compare without regard to case, and a port left out is the scheme's
    /// own. Hosts spelled differently (an IPv6 literal against a name, a
    /// trailing dot) count as another origin, which is the safe side to be
    /// wrong on.
    fn judge(from: std.Uri, to: std.Uri) Crossing {
        if (std.ascii.eqlIgnoreCase(from.scheme, "https") and std.ascii.eqlIgnoreCase(to.scheme, "http")) return .downgrade;
        if (!std.ascii.eqlIgnoreCase(from.scheme, to.scheme)) return .other_origin;
        const a = from.host orelse return .other_origin;
        const b = to.host orelse return .other_origin;
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return .other_origin;
        const a_text = switch (a) {
            .raw, .percent_encoded => |text| text,
        };
        const b_text = switch (b) {
            .raw, .percent_encoded => |text| text,
        };
        if (!std.ascii.eqlIgnoreCase(a_text, b_text)) return .other_origin;
        if ((from.port orelse defaultPort(from.scheme)) != (to.port orelse defaultPort(to.scheme))) return .other_origin;
        return .same_origin;
    }

    fn defaultPort(scheme: []const u8) u16 {
        if (std.ascii.eqlIgnoreCase(scheme, "https")) return 443;
        if (std.ascii.eqlIgnoreCase(scheme, "http")) return 80;
        return 0;
    }

    /// `lines` less what the next hop must not carry, or `lines` itself
    /// when nothing is in the way, which costs nothing. Past another
    /// origin that is the credentials (`authorization`, `cookie`,
    /// `proxy-authorization`, `www-authenticate`), the `host` the request
    /// named for the place it left, and every name in `origin_only`; when
    /// the body is dropped it is `content-type` and `content-length`,
    /// which described a body that is no longer there. The one allocation
    /// is on a hop that has something to drop, from the client's own
    /// allocator, and `begin` frees it when the call has its head.
    fn trimmed(
        gpa: std.mem.Allocator,
        lines: []const std.http.Header,
        origin_only: []const std.http.Header,
        other_origin: bool,
        body_dropped: bool,
    ) error{OutOfMemory}![]const std.http.Header {
        var kept: usize = 0;
        for (lines) |h| {
            if (!leavesBehind(h.name, origin_only, other_origin, body_dropped)) kept += 1;
        }
        if (kept == lines.len) return lines;
        const out = try gpa.alloc(std.http.Header, kept);
        var i: usize = 0;
        for (lines) |h| {
            if (leavesBehind(h.name, origin_only, other_origin, body_dropped)) continue;
            out[i] = h;
            i += 1;
        }
        return out;
    }

    fn leavesBehind(name: []const u8, origin_only: []const std.http.Header, other_origin: bool, body_dropped: bool) bool {
        if (body_dropped) {
            if (std.ascii.eqlIgnoreCase(name, "content-type") or std.ascii.eqlIgnoreCase(name, "content-length")) return true;
        }
        if (!other_origin) return false;
        const crossing_names = [_][]const u8{ "authorization", "cookie", "proxy-authorization", "www-authenticate", "host" };
        for (crossing_names) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
        for (origin_only) |h| if (std.ascii.eqlIgnoreCase(name, h.name)) return true;
        return false;
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
        const n = try self.inner.stream(w, limit);
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
        // A reader body is sent on a connection nobody pooled (`Client.fresh`),
        // because it cannot be replayed onto a second one if the first turns
        // out to be a corpse. Every other body keeps the pool, and the replay
        // in `begin` protects it.
        const std_client = if (opts.body == .stream) &client.fresh else &client.inner;
        self.reused = false;
        self.heard = false;
        const picked = try pickConnection(client, std_client, uri);
        const pooled = picked.conn;
        self.req = std_client.request(opts.method, uri, .{
            .connection = pooled,
            .extra_headers = opts.headers,
            // Always std's "pass it to the caller": a followed redirect is
            // `follow`'s, not std's (ADR 183).
            .redirect_behavior = .unhandled,
            .headers = .{
                .host = slot(opts.host, given.host),
                .authorization = slot(opts.authorization, given.authorization),
                .content_type = slot(opts.content_type, given.content_type),
                .user_agent = slot(opts.user_agent, given.user_agent),
                .connection = slot(null, given.connection),
                .accept_encoding = if (given.accept_encoding) .omit else .{ .override = "identity" },
            },
        }) catch |err| {
            // `request` never took it, so nobody else will give it back.
            if (pooled) |conn| std_client.connection_pool.release(conn, std_client.io);
            return err;
        };
        self.open = true;
        self.reused = picked.reused;

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
        self.req.accept_encoding[@backingInt(std.http.ContentEncoding.identity)] = true;

        // **The body decides, not the method**
        // ([ADR 174](../docs/adr/174-the-body-decides-not-the-method.md)).
        // `std.http.Client` asserts that a POST, PUT or PATCH sends a body
        // and that anything else sends none, and a real API does both the
        // other way: a bulk DELETE with `{ids:[…]}` in it, a PATCH whose
        // whole request is its path. Given a body, it is sent whatever the
        // method; given none, none is, whatever the method — and the two
        // asserts are stepped around rather than tripped, since either would
        // be a panic in a worker thread.
        self.send(opts) catch |err| {
            if (err != error.WriteFailed) return err;
            return self.earlyAnswer(error.WriteFailed);
        };

        self.res = try self.req.receiveHead(&.{});
    }

    /// The connection this attempt is to use when `pickConnection` has an
    /// opinion, and whether it came out of the pool.
    const Pick = struct {
        conn: ?*std.http.Client.Connection = null,
        reused: bool = false,
    };

    /// Where the attempt goes, and whether the connection it gets was
    /// already carrying requests.
    ///
    /// **The pool is asked here and not inside `request`**, because `request`
    /// hands a connection back and says nothing of where it came from, and
    /// `nothingCameBack` must tell a write that failed on an idle socket from
    /// one that failed on a socket just dialled. The criteria are
    /// `std.http.Client.connectTcp`'s own, host and port and protocol, and
    /// the connection is the one it would have returned; a miss costs one
    /// lock of the pool that `connectTcp` would have taken anyway and
    /// leaves `request` to dial.
    ///
    /// With `Settings.proxy`, three more things are decided here and nowhere
    /// else (ADR 267). A call the proxy carries is `http://` only: an
    /// `https://` one is `error.TlsThroughProxy`, because the tunnel std
    /// builds for it never starts TLS and sends the request in the clear, so
    /// it is refused before anything is dialled. A call to a host on the
    /// bypass list is dialled directly, handed to `request` as a connection,
    /// because std would otherwise route every `http://` call of a client
    /// that has a proxy through it. And the pool is asked for the proxy's
    /// connection, which is the one a proxied call reuses.
    fn pickConnection(client: *const Client, std_client: *std.http.Client, uri: std.Uri) !Pick {
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return .{};
        var name: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = std.Io.net.HostName.fromUri(uri, &name) catch return .{};
        const port = uri.port orelse switch (protocol) {
            .plain => @as(u16, 80),
            .tls => 443,
        };
        const pool = &std_client.connection_pool;
        if (std_client.http_proxy) |proxy| {
            if (!client.skipsProxy(host.bytes)) {
                if (protocol == .tls) return error.TlsThroughProxy;
                const found = try pool.findConnection(std_client.io, .{
                    .host = proxy.host,
                    .port = proxy.port,
                    .protocol = proxy.protocol,
                });
                return .{ .conn = found, .reused = found != null };
            }
            if (protocol == .plain) {
                const criteria: std.http.Client.ConnectionPool.Criteria = .{ .host = host, .port = port, .protocol = protocol };
                if (try pool.findConnection(std_client.io, criteria)) |found| return .{ .conn = found, .reused = true };
                return .{ .conn = try std_client.connectTcp(host, port, protocol) };
            }
        }
        const found = try pool.findConnection(std_client.io, .{ .host = host, .port = port, .protocol = protocol });
        return .{ .conn = found, .reused = found != null };
    }

    /// The write fails with `WriteFailed` after a refusal that came back
    /// before the body was finished: the answer is already in the
    /// connection's receive buffer, and the error is all the caller gets.
    ///
    /// **A server may answer before it has read the request** (RFC 9110
    /// §15, RFC 9112 §9.6), and one that refuses a large PUT on its head
    /// alone does exactly that: S3 and Garage answer a wrong region with
    /// `400 AuthorizationHeaderMalformed` and close, while the client is still
    /// writing. The close with unread data is an RST, the write fails, and
    /// `could not be reached: WriteFailed` hid the one thing that said what
    /// was wrong (`photon` S4 check 6, gap G2).
    ///
    /// So after a failed write the head is read once, under the call's own
    /// deadline, before the failure is given up. A peer that reset the write
    /// has no more to wait for, so the read returns at once with what the
    /// kernel kept or with an error; there is no new clock.
    ///
    /// **Only a refusal is taken.** A 2xx before the body was all sent would
    /// be a success for an upload the server never received whole, and 1xx is
    /// not final; both stay `WriteFailed`, as does anything unreadable. The
    /// connection is never reused (`keep_alive` off before the read, so std
    /// marks it closing whatever the head says), because the request on it
    /// was left unfinished. No allocation and no syscall on a write that
    /// succeeds: this is a branch on the error path.
    fn earlyAnswer(self: *Exchange, failed: error{WriteFailed}) error{WriteFailed}!void {
        self.req.keep_alive = false;
        const res = self.req.receiveHead(&.{}) catch return failed;
        self.heard = true;
        const class = res.head.status.class();
        if (class == .success or class == .informational) {
            if (self.req.connection) |conn| conn.closing = true;
            return failed;
        }
        self.res = res;
    }

    /// The head and the body, with no opinion about what a failure means.
    fn send(self: *Exchange, opts: Begin) !void {
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
            .stream => |src| {
                // With a `stall_ms` the source is read through `tap`, so that
                // every chunk that leaves it moves the silence clock: nothing
                // arrives from the peer while a body goes out, and without
                // this a transfer longer than `stall_ms` would be `Stalled`
                // however fast it moved. The write buffer is a kilobyte, so
                // a chunk out of the source is a chunk on its way to the
                // socket, and a peer that stopped reading blocks the write
                // and stops the stamps (ADR 056). `inner` is the body reader
                // after the head arrives, and is this until then.
                const source = if (self.stall_ms != 0) src: {
                    self.inner = src.reader;
                    break :src &self.tap;
                } else src.reader;
                if (framed) {
                    self.req.transfer_encoding = .{ .content_length = src.len };
                    var w = try self.req.sendBody(&.{});
                    // Exactly the length that was announced, and nothing else. A
                    // source that runs out early fails here rather than sending a
                    // body that disagrees with the head describing it.
                    try source.streamExact64(&w.writer, src.len);
                    try w.end();
                } else {
                    const w = try self.sendHeadWithLength(src.len);
                    try source.streamExact64(w, src.len);
                    try self.req.connection.?.flush();
                }
                // The head is waited for from here: the silence clock starts
                // again at the last byte that went out.
                if (self.stall_ms != 0) self.mark();
            },
        }
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
    /// **A write that fails on a reused connection is the third spelling.**
    /// A request with a body flushes its head before it writes the body, and
    /// when the peer had already closed the socket the kernel takes the head,
    /// the peer's RST comes back, and the body write is what fails: `EPIPE`
    /// (`SocketUnconnected` in std) or `ECONNRESET`
    /// (`ConnectionResetByPeer`), arriving as `WriteFailed`. Measured: a
    /// `putForm` and a `postJson` as the second call on one `Client` against
    /// a server that closes after every answer failed every time, a `get`
    /// never did (`fetch/live.zig`).
    ///
    /// It counts only when all four hold, and each closes something. The
    /// connection came out of the pool (`reused`), because on one just dialled
    /// the same error is a server that took the request and refused it, not a
    /// socket nobody was using. No head came back on the failed write
    /// (`heard`, and nothing buffered), because `earlyAnswer` reads one and
    /// an answer is not something to send twice. The errno is one of the two
    /// that mean the peer is gone: a write that failed with `Canceled` or
    /// `SystemResources` says nothing about the peer. And the caller of this
    /// asks `replayable` and the deadline as it does for the others.
    ///
    /// Nothing else is added. A reset partway through a head is
    /// `ReadFailed` with bytes buffered and stays a failure, because
    /// something did come back and re-sending would be a retry policy. So is
    /// a write that fails on a connection this call dialled: some of the
    /// request may have reached the far side. That one is not retried; what
    /// it can do is carry an answer the server sent early (`earlyAnswer`).
    fn nothingCameBack(self: *Exchange, err: anyerror) bool {
        if (err == error.HttpConnectionClosing) return true;
        // `open` is the one thing that says `req` was assigned at all. A
        // failure inside `client.inner.request` leaves it `undefined`, and
        // reaching into it for a connection would be reading a pointer that
        // was never written. `discard` guards on the same flag for the same
        // reason.
        if (!self.open) return false;
        const conn = self.req.connection orelse return false;
        if (conn.stream_reader.interface.bufferedLen() != 0) return false;
        if (err == error.WriteFailed) {
            if (!self.reused or self.heard) return false;
            const why = conn.stream_writer.err orelse return false;
            return why == error.ConnectionResetByPeer or why == error.SocketUnconnected;
        }
        if (err != error.ReadFailed) return false;
        const why = conn.stream_reader.err orelse return false;
        return why == error.ConnectionResetByPeer;
    }

    /// Whether this call may go out a second time.
    ///
    /// Only the bodies whose bytes are still where the caller left them. A
    /// `.stream` is not, which is why it is never sent on a pooled
    /// connection at all: `attempt` gives it `Client.fresh`, whose
    /// connection cannot have been reaped, so the one case a replay existed
    /// for cannot arise for it.
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
    ///
    /// **An answer that announced its length is read into exactly that many
    /// bytes**, when they are within `max`: `allocRemaining` grows a writer by
    /// doubling and shrinks it in place, which an arena cannot give back, so
    /// a 1,008-byte body took 1,641 and the node it landed in was kept
    /// resident by `arena_keep` for the life of the connection. Sized, the
    /// same body holds 2,040 bytes less on every idle connection
    /// ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md),
    /// `bench/result/fetch.md`). A chunked body, or one announced past `max`,
    /// takes the growing read, which is what enforces the ceiling on the
    /// bytes that actually arrive; a body that ends short of what it
    /// announced is `error.BodyTooShort`.
    pub fn take(self: *Exchange, c: anytype, max: usize) Client.Error!Str {
        comptime core.checkScope(@TypeOf(c), "exchange.take");
        const reader = self.reader orelse unreachable; // begin first, then take
        if (self.announced) |len| if (len <= max) {
            const buf = try c.arena().alloc(u8, @intCast(len));
            self.bounded(std.Io.Reader.readSliceAll, .{ reader, buf }) catch |err| switch (err) {
                error.EndOfStream => return error.BodyTooShort,
                else => |e| return self.blame(e),
            };
            return c.str(buf);
        };
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
        //
        // Every step of a call that waits on the socket comes through here
        // (the head, `take`, `readInto`, `pipe`, each `stream`, the drain in
        // `end`), so this is where the Engine's watchdog is told the fiber is
        // parked rather than holding its thread (ADR 210). Per step rather
        // than once from `begin` to `end`, because a handler moving a body in
        // pieces does its own work between them, and that work is what the
        // watchdog is for. The token is a local rather than a field: the
        // Exchange is on the stack of every handler that dials out, and a
        // `u64` there is 16 bytes per connection by ADR 062.
        if (!self.client.limits.engineless()) {
            const w = self.client.limits.waiting();
            defer self.client.limits.waited(w);
            return @call(.auto, f, args);
        }
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
    /// Where the call ended when it was redirected on the way, as one URL
    /// in the Scope's memory, and null when the answer came from the URL
    /// that was asked for: what `Exchange.Head.redirected` says, for the
    /// whole-body calls. Without the userinfo and the fragment, so it is
    /// safe to log ([ADR 183](../docs/adr/183-a-redirect-is-a-decision-with-a-name.md)).
    redirected: ?[]const u8 = null,
    /// Request-lifetime text. It is in the Scope's arena, so it goes when the
    /// request does and nothing has to be freed — and it may not outlive the
    /// request without `.keep()`, like every other `Str`.
    body: Str,

    /// 2xx. Written out because `status.class()` reads worse at a call site
    /// and because everybody writes this line anyway.
    pub fn ok(self: Response) bool {
        return @backingInt(self.status) >= 200 and @backingInt(self.status) < 300;
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

/// A URL as text in `arena`, without its userinfo and its fragment: the
/// form a `Response` keeps where a redirect ended, which a caller may log.
fn urlIn(arena: std.mem.Allocator, uri: std.Uri) error{OutOfMemory}![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    uri.writeToStream(&w.writer, .{ .scheme = true, .authority = true, .path = true, .query = true }) catch return error.OutOfMemory;
    return w.written();
}

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
    comptime encoding.checkQuery(@TypeOf(params), "fetch.withQuery", &.{});

    // Measured, then written, into exactly that.
    const first = encoding.querySeparator(base);
    const out = try c.arena().alloc(u8, base.len + encoding.queryLen(params, first, &.{}));
    var w: std.Io.Writer = .fixed(out);
    w.writeAll(base) catch unreachable; // measured above
    encoding.queryWrite(&w, params, first, &.{});
    std.debug.assert(w.buffered().len == out.len);
    return w.buffered();
}

/// `fields` as an `application/x-www-form-urlencoded` body in the Scope's
/// memory: `grant_type=client_credentials&scope=a+b`, **one arena allocation,
/// sized exactly**, by the walk `withQuery` uses. The field types and the
/// Refusals are `withQuery`'s. The one difference is the space: `+` here,
/// where a query string says `%20`, and a literal `+` is `%2B` either way.
/// For a body to hand to `post` with a `content-type` of your own;
/// `postForm` is this and the header said for you.
pub fn formBody(c: anytype, fields: anytype) error{OutOfMemory}![]const u8 {
    comptime core.checkScope(@TypeOf(c), "fetch.formBody");
    comptime encoding.checkForm(@TypeOf(fields), "fetch.formBody");
    const out = try c.arena().alloc(u8, encoding.paramsLen(fields, null, &.{}, .form));
    var w: std.Io.Writer = .fixed(out);
    encoding.paramsWrite(&w, fields, null, &.{}, .form);
    std.debug.assert(w.buffered().len == out.len);
    return w.buffered();
}

/// The value of an `authorization` header for HTTP Basic client
/// authentication, the OAuth way: `Basic ` and the base64 of the form-encoded
/// id, a colon, and the form-encoded secret (RFC 6749 §2.3.1). Plain Basic
/// (RFC 7617) joins the two raw, and a secret holding a `+`, a `:` or a
/// space then fails at the provider and nowhere else. Pass it as
/// `.headers = &.{.{ .name = "authorization", .value = value }}`.
///
/// One arena allocation; the joined text sits at the tail of it while it is
/// encoded into the front.
pub fn basicAuth(c: anytype, id: []const u8, secret: []const u8) error{OutOfMemory}![]const u8 {
    comptime core.checkScope(@TypeOf(c), "fetch.basicAuth");
    const prefix = "Basic ";
    const joined = encoding.textLen(id, .form) + 1 + encoding.textLen(secret, .form);
    const encoder = std.base64.standard.Encoder;
    const b64 = encoder.calcSize(joined);
    const out = try c.arena().alloc(u8, prefix.len + b64 + joined);
    const tail = out[prefix.len + b64 ..];
    var w: std.Io.Writer = .fixed(tail);
    encoding.textWrite(&w, id, .form) catch unreachable; // measured above
    w.writeByte(':') catch unreachable;
    encoding.textWrite(&w, secret, .form) catch unreachable;
    std.debug.assert(w.buffered().len == joined);
    @memcpy(out[0..prefix.len], prefix);
    _ = encoder.encode(out[prefix.len..][0..b64], tail);
    return out[0 .. prefix.len + b64];
}

test "a bypass entry names a host and everything under it, and nothing it is only a tail of" {
    try std.testing.expect(bypassMatches("corp.example", "corp.example"));
    try std.testing.expect(bypassMatches("corp.example", "API.Corp.Example"));
    try std.testing.expect(bypassMatches(".corp.example", "api.corp.example"));
    try std.testing.expect(bypassMatches("*.corp.example", "api.corp.example"));
    try std.testing.expect(bypassMatches("127.0.0.1", "127.0.0.1"));
    try std.testing.expect(bypassMatches("*", "anything.test"));
    try std.testing.expect(!bypassMatches("corp.example", "notcorp.example"));
    try std.testing.expect(!bypassMatches("corp.example", "example"));
    try std.testing.expect(!bypassMatches("", "corp.example"));
    try std.testing.expect(!bypassMatches("localhost", "127.0.0.1"));
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
    try std.testing.expect((Response{ .status = @fromBackingInt(@intCast(299)), .body = body }).ok());
    try std.testing.expect(!(Response{ .status = @fromBackingInt(@intCast(300)), .body = body }).ok());
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

test "a change of scheme, host or port is another place, and https to http is a downgrade" {
    const judge = Exchange.judge;
    const from = try std.Uri.parse("https://api.example.com/v1/a");
    try std.testing.expectEqual(.same_origin, judge(from, try std.Uri.parse("https://API.example.com:443/other?x=1")));
    try std.testing.expectEqual(.other_origin, judge(from, try std.Uri.parse("https://api.example.com:8443/v1/a")));
    try std.testing.expectEqual(.other_origin, judge(from, try std.Uri.parse("https://files.example.com/v1/a")));
    // std's own rule counts a parent domain as the same place; this one does not.
    try std.testing.expectEqual(.other_origin, judge(from, try std.Uri.parse("https://example.com/")));
    try std.testing.expectEqual(.downgrade, judge(from, try std.Uri.parse("http://api.example.com/v1/a")));
    try std.testing.expectEqual(.downgrade, judge(from, try std.Uri.parse("http://other.test/")));
    // The other way is an upgrade, and still another place.
    const plain = try std.Uri.parse("http://api.example.com/");
    try std.testing.expectEqual(.other_origin, judge(plain, try std.Uri.parse("https://api.example.com/")));
    try std.testing.expectEqual(.same_origin, judge(plain, try std.Uri.parse("http://api.example.com:80/x")));
}

test "a hop to another place drops credentials and a target's own headers, and nothing else" {
    const lines = [_]std.http.Header{
        .{ .name = "Authorization", .value = "Bearer t" },
        .{ .name = "cookie", .value = "a=b" },
        .{ .name = "Proxy-Authorization", .value = "Basic eA==" },
        .{ .name = "WWW-Authenticate", .value = "x" },
        .{ .name = "X-Api-Key", .value = "k" },
        .{ .name = "x-trace", .value = "t1" },
        .{ .name = "content-type", .value = "application/json" },
    };
    const standing = [_]std.http.Header{.{ .name = "x-api-key", .value = "k" }};

    // The same place with its body kept: the very slice, no allocation.
    const same = try Exchange.trimmed(std.testing.failing_allocator, &lines, &standing, false, false);
    try std.testing.expectEqual(@as(usize, lines.len), same.len);

    // Another place: the four, the target's, and nothing it did not name.
    const other = try Exchange.trimmed(std.testing.allocator, &lines, &standing, true, false);
    defer std.testing.allocator.free(other);
    try std.testing.expectEqual(@as(usize, 2), other.len);
    try std.testing.expectEqualStrings("x-trace", other[0].name);
    try std.testing.expectEqualStrings("content-type", other[1].name);

    // A body dropped takes its description with it, and no credential.
    const bodiless = try Exchange.trimmed(std.testing.allocator, &lines, &standing, false, true);
    defer std.testing.allocator.free(bodiless);
    try std.testing.expectEqual(@as(usize, 6), bodiless.len);
    try std.testing.expectEqualStrings("Authorization", bodiless[0].name);
}

// ---- the ordinary call: a form body (ADR 061) ----

test "a form body writes a space as plus and a plus, an ampersand and an equals sign as data" {
    var run: core.Run = .init(std.testing.allocator);
    defer run.deinit();

    // The same fields `withQuery` takes, and the one difference between the
    // two is the space: `%20` on a URL, `+` in a body.
    const body = try formBody(&run, .{ .grant_type = "client_credentials", .scope = "read write", .n = @as(u8, 7), .on = true });
    try std.testing.expectEqualStrings("grant_type=client_credentials&scope=read+write&n=7&on=true", body);

    const awkward = try formBody(&run, .{ .v = "a b+c&d=e/f", .@"a b" = "x" });
    try std.testing.expectEqualStrings("v=a+b%2Bc%26d%3De%2Ff&a+b=x", awkward);
    const as_query = try withQuery(&run, "", .{ .v = "a b+c&d=e/f" });
    try std.testing.expectEqualStrings("?v=a%20b%2Bc%26d%3De%2Ff", as_query);

    // A null is left out, nothing is an empty body, and a form body has no
    // leading separator.
    const none: ?[]const u8 = null;
    try std.testing.expectEqualStrings("a=1", try formBody(&run, .{ .skipped = none, .a = 1 }));
    try std.testing.expectEqualStrings("", try formBody(&run, .{}));
}

test "a form body is written into exactly the bytes it was measured at" {
    var run: core.Run = .init(std.testing.allocator);
    defer run.deinit();
    // The assert inside `formBody` holds the two walks together; spaces are
    // where the measure and the write could part, so a value of nothing but.
    try std.testing.expectEqualStrings("a=+++&b=%2B+", try formBody(&run, .{ .a = "   ", .b = "+ " }));
}

test "basic auth form-encodes the id and the secret before it joins and encodes them" {
    var run: core.Run = .init(std.testing.allocator);
    defer run.deinit();

    // Plain text goes as RFC 7617 would write it:
    // base64("client:secret") is Y2xpZW50OnNlY3JldA==.
    try std.testing.expectEqualStrings("Basic Y2xpZW50OnNlY3JldA==", try basicAuth(&run, "client", "secret"));

    // id `my id` and secret `p+q:r s` are `my+id` and `p%2Bq%3Ar+s`, and
    // base64("my+id:p%2Bq%3Ar+s") is bXkraWQ6cCUyQnElM0FyK3M=. Joined raw
    // they would be "my id:p+q:r s", whose first colon is no longer the one
    // between them as far as the provider can tell.
    try std.testing.expectEqualStrings("Basic bXkraWQ6cCUyQnElM0FyK3M=", try basicAuth(&run, "my id", "p+q:r s"));
}

test {
    _ = @import("live.zig");
    _ = @import("target.zig");
    _ = @import("params.zig");
    _ = @import("retry.zig");
    _ = @import("retry_live.zig");
}

/// 400 params with 40-character names. Declared apart from the test, so the
/// test's own quota does not pay for it.
const WideQuery = blk: {
    @setEvalBranchQuota(1_000_000);
    var names: [400][:0]const u8 = undefined;
    var types: [400]type = undefined;
    for (&names, &types, 0..) |*name, *T, i| {
        name.* = std.fmt.comptimePrint("a_query_param_with_a_long_descriptive_name_{d:0>4}", .{i});
        T.* = u32;
    }
    break :blk @Struct(.auto, null, &names, &types, &@splat(.{}));
};

test "a query of 400 params is checked and written without a quota of the caller's" {
    // It stopped with "evaluation exceeded 1000 backwards branches" from a
    // line in `checkQuery`.
    var run: core.Run = .init(std.testing.allocator);
    defer run.deinit();

    const params = std.mem.zeroes(WideQuery);
    const url = try withQuery(&run, "http://example.test/x", params);
    try std.testing.expect(std.mem.startsWith(u8, url, "http://example.test/x?a_query_param_with_a_long_descriptive_name_0000=0&"));
    try std.testing.expect(std.mem.endsWith(u8, url, "_0399=0"));
}
