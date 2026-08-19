//! nilo_fetch — calling somebody else's HTTP API, from inside a request.
//!
//! ```zig
//! var api: fetch.Client = .init(gpa, .{});
//! try app.provide(&api);
//!
//! fn charge(api: *fetch.Client, c: *nilo.Ctx) !Receipt {
//!     const res = try api.post(c, "https://api.example.com/v1/charges", "amount=500", .{});
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
//! ([ADR 0070](../docs/adr/0070-a-fitting-borrows-the-loop.md)).
//!
//! - **A gate.** `std.http.Client`'s pool bounds *idle* connections
//!   (`free_size`, 32 by default) and does not bound in-use ones at all. 500
//!   concurrent handlers is 500 live connections, and an HTTPS one holds
//!   59,151 bytes of buffers — 29.6 MB nobody asked for, plus 500 handshakes.
//! - **A deadline.** An endpoint that accepts a connection and then says
//!   nothing holds a handler until the process dies. `std.http.Client` has no
//!   deadline field, so the bound is on the fiber
//!   ([ADR 0065](../docs/adr/0065-the-way-out-was-open-the-clock-was-not.md)).
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
//!
//! Two shapes, and the second is the first with the middle left out. An
//! `Exchange` is one call held open — the response head readable, the body
//! taken into the Scope or piped straight out. `Client.get` and the three
//! beside it are an Exchange begun and finished in one line, which is what a
//! handler calling somebody's JSON API wants.
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

/// A pooled HTTP client, held as a service for the life of the process.
///
/// Registered with `app.provide(&client)` and asked for by type, the way every
/// other service is. One is enough for a whole program: the pool inside it is
/// keyed by host, so calls to three different APIs share it without knowing
/// about each other.
pub const Client = struct {
    inner: std.http.Client,
    gate: std.Io.Semaphore,
    limits: core.Limits = .off,
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
        timeout_ms: u32 = 30_000,

        /// A response body larger than this is `error.BodyTooLarge` rather
        /// than an allocation. Nothing in std bounds it.
        max_body: usize = 8 << 20,

        /// How much of an unread body is worth reading to keep a pooled
        /// connection. Past this the connection is dropped instead: losing it
        /// costs one handshake, and reading it costs the whole body.
        max_drain: usize = 64 << 10,
    };

    /// Per-call overrides. Everything null takes the client's own setting, so
    /// `.{}` is the ordinary case.
    pub const Call = struct {
        headers: []const std.http.Header = &.{},
        /// Overrides `Settings.timeout_ms` for this call — a health check that
        /// should give up in 500ms, an upload that may take a minute.
        timeout_ms: ?u32 = null,
        max_body: ?usize = null,
    };

    pub const Error = error{
        /// The deadline for this call ran out. Distinct from `Canceled`,
        /// which is the server shutting down underneath it.
        TimedOut,
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
        OutOfMemory,
    } || std.Uri.ParseError || std.http.Client.RequestError ||
        std.http.Client.Request.ReceiveHeadError ||
        std.Io.Writer.Error || std.Io.Reader.Error || std.Io.Cancelable;

    pub fn init(gpa: std.mem.Allocator, settings: Settings) Client {
        return .{
            .inner = .{ .allocator = gpa, .io = undefined },
            .gate = .{ .permits = settings.max_in_flight },
            .settings = settings,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.started) self.inner.deinit();
    }

    /// Finished once the event loop exists, like every service that needs one
    /// (ADR 0040). The third parameter is what bounds a call in time
    /// (ADR 0065); a Fitting that did not take it could open a connection and
    /// never give up on it.
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

    /// The whole of what the four above do, for a method they do not name.
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

        // The two buffers this call needs, declared where a reader can see what
        // they cost. They are stack, and by
        // [ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md) a
        // handler's stack is held for the life of the *inbound* connection — so
        // 6 KiB here is 6 KiB on every connection that ever dials out, which is
        // a third of what ADR 0070 measured. An `Exchange` takes them as
        // arguments rather than holding them as fields for exactly that reason:
        // a caller that follows no redirects pays for no redirect buffer.
        var redirect_buffer: [2 << 10]u8 = undefined;
        var transfer_buffer: [4 << 10]u8 = undefined;

        var ex: Exchange = .idle;
        defer ex.end();

        const head = try ex.begin(self, .{
            .method = method,
            .url = url,
            .headers = call.headers,
            .body = if (body) |bytes| .{ .slice = bytes } else .none,
            .timeout_ms = call.timeout_ms,
            .redirect_buffer = &redirect_buffer,
            .transfer_buffer = &transfer_buffer,
        });

        return .{
            .status = head.status,
            .body = try ex.take(c, call.max_body orelse self.settings.max_body),
        };
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
    /// could show ([ADR 0033](../docs/adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)).
    ///
    /// Asking the bound instead needs nothing of the error: if this call's own
    /// timer expired, every failure after it is downstream of that. A
    /// cancellation from somewhere else — a shutdown — leaves the bound
    /// saying no, and is passed through as itself, which is the distinction
    /// that mattered in the first place.
    fn blame(_: *Client, bound: *core.Limits.Bound, err: anytype) Error {
        if (bound.fired()) return error.TimedOut;
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
/// const head = try ex.begin(client, .{ .method = .GET, .url = url, .transfer_buffer = &buf });
/// const etag = head.header("etag");     // valid until the body is touched
/// _ = try ex.pipe(out);                 // and now it is not
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
    bound: core.Limits.Bound = .idle,
    req: std.http.Client.Request = undefined,
    res: std.http.Client.Response = undefined,
    reader: ?*std.Io.Reader = null,
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
        headers: []const std.http.Header = &.{},
        body: Body = .none,

        /// Three headers std writes for itself unless told otherwise. A signed
        /// request has to say exactly what it signed, down to the port in the
        /// authority, so it overrides rather than trusting two spellings to
        /// agree.
        host: ?[]const u8 = null,
        authorization: ?[]const u8 = null,
        content_type: ?[]const u8 = null,

        timeout_ms: ?u32 = null,

        /// Where a redirect's `Location` is kept while it is followed. **An
        /// empty one means redirects are not followed at all** — the response
        /// comes back as itself, 302 and all.
        ///
        /// That is the right default for anything signed: a signature is
        /// computed over one host and one path, so following a redirect sends
        /// a request that cannot be valid at the other end — and sends the
        /// `authorization` header there while it does it.
        redirect_buffer: []u8 = &.{},
        /// What the body is read through. Bigger is fewer trips into the
        /// connection for a large object and more stack held per connection;
        /// `Client.send` uses 4 KiB.
        transfer_buffer: []u8 = &.{},
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

        /// A header by name, case-insensitively. Null when it is absent —
        /// which for `etag` is a fact about the server rather than an error.
        pub fn header(self: Head, name: []const u8) ?[]const u8 {
            var it: std.http.HeaderIterator = .init(self.bytes);
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
            }
            return null;
        }

        pub fn ok(self: Head) bool {
            return @intFromEnum(self.status) >= 200 and @intFromEnum(self.status) < 300;
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

        self.bound.arm(client.limits, opts.timeout_ms orelse client.settings.timeout_ms);

        // **One retry, and only onto a connection the peer had already
        // closed.** Not a retry policy: `std.http.Client` pools keep-alive
        // connections and every server reaps an idle one, so the first call
        // after a quiet spell takes a socket with a FIN already on it. std
        // names that case exactly — `HttpConnectionClosing`, documented there
        // as "the client sent 0 bytes of headers before closing the stream.
        // This happens when a keep-alive connection is finally closed" — so
        // **nothing was answered and nothing reached anybody.** Sending it
        // again on a fresh connection is transport hygiene, which is why
        // [ADR 0067](../docs/adr/0067-most-of-an-s3-client-is-not-s3.md)
        // called it correctness while refusing every other retry, and why
        // [ADR 0070](../docs/adr/0070-a-fitting-borrows-the-loop.md)'s "no
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
        //   [ADR 0091](../docs/adr/0091-a-reaped-connection-arrives-two-ways.md)
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
            self.attempt(client, uri, opts) catch |err| {
                if (tries < stale_limit and self.nothingCameBack(err) and
                    replayable(opts.body) and !self.bound.fired())
                {
                    self.discard();
                    continue;
                }
                return client.blame(&self.bound, err);
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
        };

        self.announced = head.content_length;
        self.reader = self.res.reader(opts.transfer_buffer);
        return head;
    }

    /// One send and one head read, with no opinion about what a failure means.
    ///
    /// Split out of `begin` so the retry above can run it twice without
    /// repeating it, and so that `blame` is applied in exactly one place.
    fn attempt(self: *Exchange, client: *Client, uri: std.Uri, opts: Begin) !void {
        self.req = try client.inner.request(opts.method, uri, .{
            .extra_headers = opts.headers,
            .redirect_behavior = if (opts.redirect_buffer.len == 0)
                .unhandled
            else
                std.http.Client.Request.RedirectBehavior.init(3),
            .headers = .{
                .host = if (opts.host) |h| .{ .override = h } else .default,
                .authorization = if (opts.authorization) |a| .{ .override = a } else .default,
                .content_type = if (opts.content_type) |t| .{ .override = t } else .default,
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
        // [ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md)
        // is held per *connection* on the handler's stack — twice what the
        // whole call already costs there — and it links flate into every
        // binary that dials out. Identity costs nothing, is understood
        // everywhere, and makes `max_body` count the bytes a caller actually
        // receives rather than the bytes on the wire.
        //
        // Making it a setting would be the worst of both: the branch would be
        // at runtime, so flate would link in whether or not anybody chose it
        // (ADR 0018's complaint about `docs()`, exactly).
        // Both halves, and they do different jobs. The override is what goes
        // on the wire — the bool array alone emits a malformed
        // `accept-encoding\r\n` with no value, because std's writer skips
        // `identity` when listing and then trims a separator that was never
        // written. The array is what `receiveHead` checks, so a server that
        // ignores the header and gzips anyway is a clean error rather than a
        // `Str` full of bytes nobody can read.
        self.req.headers.accept_encoding = .{ .override = "identity" };
        self.req.accept_encoding = @splat(false);
        self.req.accept_encoding[@intFromEnum(std.http.ContentEncoding.identity)] = true;

        switch (opts.body) {
            .none => try self.req.sendBodiless(),
            .slice => |bytes| {
                self.req.transfer_encoding = .{ .content_length = bytes.len };
                var w = try self.req.sendBody(&.{});
                try w.writer.writeAll(bytes);
                try w.end();
            },
            .stream => |src| {
                self.req.transfer_encoding = .{ .content_length = src.len };
                var w = try self.req.sendBody(&.{});
                // Exactly the length that was announced, and nothing else. A
                // source that runs out early fails here rather than sending a
                // body that disagrees with the head describing it.
                try src.reader.streamExact64(&w.writer, src.len);
                try w.end();
            },
        }

        self.res = try self.req.receiveHead(opts.redirect_buffer);
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
    fn discard(self: *Exchange) void {
        if (!self.open) return;
        if (self.req.connection) |conn| conn.closing = true;
        self.req.deinit();
        self.open = false;
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
        const bytes = reader.allocRemaining(c.arena(), .limited(max)) catch |err| switch (err) {
            error.StreamTooLong => return error.BodyTooLarge,
            else => |e| return self.client.blame(&self.bound, e),
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
        return reader.readSliceAll(buf) catch |err| switch (err) {
            error.EndOfStream => error.BodyTooShort,
            else => |e| self.client.blame(&self.bound, e),
        };
    }

    /// The body straight into `w`, allocating nothing at all, and how many
    /// bytes went. What a handler streaming an object into its own response
    /// wants: the ceiling is the transfer buffer rather than the body.
    pub fn pipe(self: *Exchange, w: *std.Io.Writer) Client.Error!u64 {
        const reader = self.reader orelse unreachable; // begin first, then pipe
        return reader.streamRemaining(w) catch |err| return self.client.blame(&self.bound, err);
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
            self.dropIfDrainIsDearer();
            self.client.close(&self.req);
            self.open = false;
            self.reader = null;
            self.announced = null;
        }
        self.bound.release();
        if (self.permit) {
            self.client.gate.post(self.client.inner.io);
            self.permit = false;
        }
    }
};

pub const Response = struct {
    status: std.http.Status,
    /// Request-lifetime text. It is in the Scope's arena, so it goes when the
    /// request does and nothing has to be freed — and it may not outlive the
    /// request without `.keep()`, like every other `Str`.
    body: Str,

    /// 2xx. Written out because `status.class()` reads worse at a call site
    /// and because everybody writes this line anyway.
    pub fn ok(self: Response) bool {
        return @intFromEnum(self.status) >= 200 and @intFromEnum(self.status) < 300;
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

const testing = std.testing;

test "a client that was never started refuses rather than dialling undefined" {
    var client: Client = .init(testing.allocator, .{});
    defer client.deinit();

    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    try testing.expectError(error.NotStarted, client.get(&run, "http://example.invalid/", .{}));
}

test "the gate hands out no more permits than it was given" {
    var client: Client = .init(testing.allocator, .{ .max_in_flight = 2 });
    defer client.deinit();
    try testing.expectEqual(@as(usize, 2), client.gate.permits);
}

test "a response says whether it is one to read" {
    const body: Str = .static("");
    try testing.expect((Response{ .status = .ok, .body = body }).ok());
    try testing.expect((Response{ .status = .created, .body = body }).ok());
    try testing.expect(!(Response{ .status = .not_found, .body = body }).ok());
    try testing.expect(!(Response{ .status = .internal_server_error, .body = body }).ok());
    // The edges of the class, because 299 and 300 are one apart and one of
    // them is a redirect.
    try testing.expect((Response{ .status = @enumFromInt(299), .body = body }).ok());
    try testing.expect(!(Response{ .status = @enumFromInt(300), .body = body }).ok());
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
} };

test "a failure this call's own clock caused is a timeout, whatever it is called" {
    var client: Client = .init(testing.allocator, .{});
    defer client.deinit();

    // Armed against a Limits that claims every cancellation as its own: this
    // is the deadline case, and the caller should see `TimedOut`.
    var mine: core.Limits.Bound = .idle;
    defer mine.release();
    mine.arm(always_fired, 1_000);
    try testing.expectEqual(Client.Error.TimedOut, client.blame(&mine, error.Canceled));

    // And the case a real timer actually produces. `std.Io.Reader`'s error set
    // is fixed, so a cancellation mid-body arrives as `error.ReadFailed` with
    // the cause kept in a field; `fetch/deadline.zig` is where that was seen.
    // A version of `blame` that matched on `error.Canceled` returned this
    // unchanged and every timeout looked like a broken upstream.
    try testing.expectEqual(Client.Error.TimedOut, client.blame(&mine, error.ReadFailed));

    // Armed against nothing, which is what a shutdown looks like: the
    // cancellation was somebody else's and must not be reported as a timeout,
    // or every deploy would look like a slow upstream.
    var theirs: core.Limits.Bound = .idle;
    defer theirs.release();
    theirs.arm(.off, 1_000);
    try testing.expectEqual(Client.Error.Canceled, client.blame(&theirs, error.Canceled));

    // A failure with no deadline behind it is passed through as itself, which
    // is the whole reason the bound is asked rather than assumed.
    try testing.expectEqual(
        Client.Error.ConnectionRefused,
        client.blame(&theirs, error.ConnectionRefused),
    );
}

test "a streamed body is not replayed, because its reader is spent" {
    // The bound that keeps the retry honest. `live.zig` proves the retry
    // happens against a server that hangs up; this proves the one case it
    // must not happen in. Re-sending a `.stream` body would put fewer bytes
    // on the wire than the `content-length` announced, which is a corrupted
    // request rather than a recovered one
    // ([ADR 0067](../docs/adr/0067-most-of-an-s3-client-is-not-s3.md)).
    try testing.expect(Exchange.replayable(.none));
    try testing.expect(Exchange.replayable(.{ .slice = "x" }));

    var empty: std.Io.Reader = .fixed("");
    try testing.expect(!Exchange.replayable(.{ .stream = .{ .reader = &empty, .len = 0 } }));
}

test {
    _ = @import("live.zig");
}
