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
//! - **A bounded drain.** `std.http.Client.Request.deinit` calls
//!   `discardRemaining()` with no limit when the head was read and the body
//!   was not, so refusing a 500 MB object still downloads it.
//! - **A body ceiling**, enforced while reading rather than checked after, so
//!   a sender lying about `content-length` cannot get past it.
//! - **A Scope**, so the body comes back as a `Str` that lives exactly as long
//!   as the request does and nobody frees anything.
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
        if (!self.started) return error.NotStarted;

        const uri = try std.Uri.parse(url);
        const io = self.inner.io;

        try self.gate.wait(io);
        defer self.gate.post(io);

        var bound: core.Limits.Bound = .idle;
        defer bound.release();
        bound.arm(self.limits, call.timeout_ms orelse self.settings.timeout_ms);

        var req = self.inner.request(method, uri, .{ .extra_headers = call.headers }) catch |err| {
            return self.blame(&bound, err);
        };
        defer self.close(&req);

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
        req.headers.accept_encoding = .{ .override = "identity" };
        req.accept_encoding = @splat(false);
        req.accept_encoding[@intFromEnum(std.http.ContentEncoding.identity)] = true;

        if (body) |bytes| {
            req.transfer_encoding = .{ .content_length = bytes.len };
            var w = req.sendBody(&.{}) catch |err| return self.blame(&bound, err);
            w.writer.writeAll(bytes) catch |err| return self.blame(&bound, err);
            w.end() catch |err| return self.blame(&bound, err);
        } else {
            req.sendBodiless() catch |err| return self.blame(&bound, err);
        }

        var redirect_buffer: [2 << 10]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            return self.blame(&bound, err);
        };

        var transfer_buffer: [4 << 10]u8 = undefined;
        const reader = response.reader(&transfer_buffer);

        const ceiling = call.max_body orelse self.settings.max_body;
        const bytes = reader.allocRemaining(c.arena(), .limited(ceiling)) catch |err| switch (err) {
            error.StreamTooLong => return error.BodyTooLarge,
            else => |e| return self.blame(&bound, e),
        };

        return .{ .status = response.head.status, .body = c.str(bytes) };
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
    fn close(self: *Client, req: *std.http.Client.Request) void {
        if (req.connection) |conn| {
            if (conn.reader().bufferedLen() > self.settings.max_drain) conn.closing = true;
        }
        req.deinit();
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

test {
    _ = @import("live.zig");
}
