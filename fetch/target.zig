//! A target is a type, and a path is a template
//! ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)).
//!
//! ```zig
//! const Stripe = fetch.Target("stripe", .{ .timeout_ms = 5_000, .max_in_flight = 8 });
//!
//! var stripe = try Stripe.open(&api, .{
//!     .base = "https://api.stripe.com",
//!     .authorization = cfg.stripe_key,
//! });
//! try app.provide(&stripe);
//!
//! fn charge(stripe: *Stripe, c: *nilo.Ctx, id: nilo.Str) !Receipt {
//!     const res = try stripe.get(c, "/v1/charges/{}", .{id}, .{});
//!     if (!res.ok()) return nilo.fail.status(502, "stripe said no", .{});
//!     return res.json(Receipt, c);
//! }
//! ```
//!
//! `Client` is one for the whole program on purpose — the pool lives in it —
//! so there was nowhere to write "Stripe is `https://api.stripe.com`, sends
//! `authorization: Bearer …`, and gets five seconds", and every call
//! repeated all three. A target is that sentence as a type: two services
//! are two types, therefore two Services, and which one a handler reaches is
//! in its argument list, the shape ADR 054 chose for a second database and
//! ADR 059 for a second bucket.
//!
//! ## What is settled while compiling, and what is not
//!
//! The rule is ADR 059's: **whatever is a property of the service rather
//! than of the deployment.** The name, the ceilings and the clocks are the
//! service's and sit on the type. The base URL and the credential are the
//! deployment's — a sandbox host and a test key in development, the real
//! pair in production, one binary — and they are given to `open`, where a
//! `Config` can reach them. The win of the type was never comptime; it is
//! a URL and a header block built from parts held once rather than
//! assembled at every call site.
//!
//! What comptime buys is the path. `"/v1/charges/{}"` is read while
//! compiling: the segments are counted against the arguments, each
//! argument is held to what a segment can carry, and a named segment
//! `{id}` is matched to a field. Text in a segment is percent-encoded with
//! `/` as data, so an id off a request cannot reach a path this program
//! never meant to call — the five lines `examples/outbound` wrote by hand
//! for two segments, once.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("fetch.zig");
const encoding = @import("params.zig");
const retry_mod = @import("retry.zig");

const Client = fetch.Client;
const Response = fetch.Response;
const Str = core.Str;

/// What a target's type carries: every field a property of the service.
pub const Options = struct {
    /// Calls in flight to this target at once, under the client's own
    /// ceiling. Zero, the default, is no gate of its own: the client's
    /// `max_in_flight` is the only one. Set it for the third party that is
    /// slow, so that its calls queue at its own gate rather than holding
    /// the permits every other service shares.
    max_in_flight: u32 = 0,
    /// `Settings.timeout_ms` for this service, or null for the client's.
    /// A `Call` on one call still overrides it.
    timeout_ms: ?u32 = null,
    /// `Settings.stall_ms` for this service, or null for the client's.
    stall_ms: ?u32 = null,
    /// `Settings.max_body` for this service, or null for the client's.
    max_body: ?usize = null,
    /// A path the health route GETs on every probe, with 2xx as ready
    /// ([ADR 154](../docs/adr/154-a-health-route-asks-the-services.md)).
    /// Null, the default, is started-is-ready, for the reason `s3.Store`
    /// gives: a balancer asks every second, and a call to somebody else's
    /// API at that rate is a bill and a rate limit rather than a check. A
    /// service that publishes a status path is the one to name here.
    ready: ?[]const u8 = null,
    /// What happens when the service has a bad minute: the caller's numbers
    /// (how many times, how long between, which statuses, how much of the
    /// recent traffic may be retries) and nilo's mechanism (jitter,
    /// `Retry-After`, a budget, idempotent methods only, the route's
    /// deadline) ([ADR 271](../docs/adr/271-a-retry-is-the-callers-numbers-and-nilos-mechanism.md)).
    /// Null, the default, is one try, and the target then holds and runs
    /// none of it.
    retry: ?retry_mod.Retry = null,
};

/// What `open` takes: the deployment's half.
pub const Open = struct {
    /// `https://api.stripe.com`, or `https://api.sandbox.example.com/v2`
    /// — a scheme, a host, and a path prefix if the service has one. No
    /// query and no fragment; a trailing `/` is dropped so that a path
    /// beginning with one joins cleanly. Held, not copied: the value has
    /// to outlive the target, which a `Config` does.
    base: []const u8,
    /// Sent as `authorization` on every call, unless the call's own
    /// `headers` name one. Held, not copied.
    authorization: ?[]const u8 = null,
    /// Sent as `user-agent` on every call, likewise.
    user_agent: ?[]const u8 = null,
    /// Any other header the service always wants — `accept`, an API
    /// version, a tenant — written verbatim ahead of the call's own, which
    /// shadow one of these by name.
    headers: []const std.http.Header = &.{},
};

pub const OpenError = error{
    /// `base` has no scheme or no host. A target hangs paths off an
    /// absolute URL, and a relative one has nothing to hang them off.
    BaseNotAbsolute,
    /// `base` carries a `?` or a `#`. A query is the call's, through the
    /// struct it passes; a fragment never goes on the wire.
    BaseHasQuery,
};

/// The type a handler asks for. `name` tells two targets with the same
/// options apart, and is what the health route and a log line call it.
pub fn Target(comptime name: []const u8, comptime opts: Options) type {
    comptime check(name, opts);

    return struct {
        const Self = @This();

        /// The name, so a caller can print it and a test can assert on it.
        pub const target = name;
        pub const options = opts;

        pub const Error = Client.Error;

        client: *Client,
        /// The base as given, less a trailing `/`.
        base: []const u8,
        authorization: ?[]const u8,
        user_agent: ?[]const u8,
        headers: []const std.http.Header,
        /// This target's own gate, when `max_in_flight` asked for one.
        /// Taken before the client's, so a call queued here holds no
        /// permit the other services could use, and given back after it.
        gate: std.Io.Semaphore,
        /// The retry budget's counts, shared by every handler calling this
        /// service. Nothing, for a target that declares no `.retry`.
        ledger: if (opts.retry != null) retry_mod.Ledger else void,

        pub fn open(client: *Client, o: Open) OpenError!Self {
            const uri = std.Uri.parse(o.base) catch return error.BaseNotAbsolute;
            if (uri.scheme.len == 0 or uri.host == null) return error.BaseNotAbsolute;
            if (uri.query != null or uri.fragment != null) return error.BaseHasQuery;
            const base = if (o.base[o.base.len - 1] == '/') o.base[0 .. o.base.len - 1] else o.base;
            return .{
                .client = client,
                .base = base,
                .authorization = o.authorization,
                .user_agent = o.user_agent,
                .headers = o.headers,
                .gate = .{ .permits = opts.max_in_flight },
                .ledger = if (comptime opts.retry != null) .empty else {},
            };
        }

        /// Finished when the loop exists, by finishing the client
        /// (ADR 037). Starting a client twice sets the same `Io` twice, so
        /// providing the client beside two targets over it is the ordinary
        /// case rather than a mistake.
        pub fn nilo_start(self: *Self, io: std.Io, limits: core.Limits) !void {
            try self.client.nilo_start(io, limits);
        }

        /// What the health route asks
        /// ([ADR 154](../docs/adr/154-a-health-route-asks-the-services.md)).
        /// With no `ready` path, started is ready; with one, a GET to it on
        /// every probe, and anything but a 2xx is the target's name and
        /// what went wrong.
        pub fn nilo_ready(self: *Self, scope: *core.AnyScope) ?[]const u8 {
            if (!self.client.started) return "not started: `listen()` has not run";
            if (comptime opts.ready == null) return null;
            const res = self.get(scope, comptime opts.ready.?, .{}, .{}) catch |err| return switch (err) {
                error.TimedOut => name ++ " took too long to answer",
                error.Stalled => name ++ " went quiet",
                else => name ++ " is not answering",
            };
            if (!res.ok()) return name ++ " answered outside 2xx";
            return null;
        }

        // ---- the ordinary calls, with a path in place of a URL ----

        pub fn get(self: *Self, c: anytype, comptime path: []const u8, args: anytype, call: Client.Call) Error!Response {
            comptime core.checkScope(@TypeOf(c), "target.get");
            return self.through(c, .GET, path, args, null, null, call);
        }

        pub fn post(self: *Self, c: anytype, comptime path: []const u8, args: anytype, body: []const u8, call: Client.Call) Error!Response {
            comptime core.checkScope(@TypeOf(c), "target.post");
            return self.through(c, .POST, path, args, body, null, call);
        }

        pub fn put(self: *Self, c: anytype, comptime path: []const u8, args: anytype, body: []const u8, call: Client.Call) Error!Response {
            comptime core.checkScope(@TypeOf(c), "target.put");
            return self.through(c, .PUT, path, args, body, null, call);
        }

        pub fn delete(self: *Self, c: anytype, comptime path: []const u8, args: anytype, call: Client.Call) Error!Response {
            comptime core.checkScope(@TypeOf(c), "target.delete");
            return self.through(c, .DELETE, path, args, null, null, call);
        }

        pub fn patch(self: *Self, c: anytype, comptime path: []const u8, args: anytype, body: ?[]const u8, call: Client.Call) Error!Response {
            comptime core.checkScope(@TypeOf(c), "target.patch");
            return self.through(c, .PATCH, path, args, body, null, call);
        }

        /// `Client.send` with a path: for a method the five above do not
        /// name, and for a DELETE with a body (ADR 174).
        pub fn send(self: *Self, c: anytype, method: std.http.Method, comptime path: []const u8, args: anytype, body: ?[]const u8, call: Client.Call) Error!Response {
            comptime core.checkScope(@TypeOf(c), "target.send");
            return self.through(c, method, path, args, body, null, call);
        }

        pub fn postJson(self: *Self, c: anytype, comptime path: []const u8, args: anytype, value: anytype, call: Client.Call) Error!Response {
            comptime core.checkScope(@TypeOf(c), "target.postJson");
            comptime encoding.refuseJsonText(@TypeOf(value), "target.postJson");
            return self.sendJson(c, .POST, path, args, value, call);
        }

        pub fn putJson(self: *Self, c: anytype, comptime path: []const u8, args: anytype, value: anytype, call: Client.Call) Error!Response {
            comptime core.checkScope(@TypeOf(c), "target.putJson");
            comptime encoding.refuseJsonText(@TypeOf(value), "target.putJson");
            return self.sendJson(c, .PUT, path, args, value, call);
        }

        pub fn patchJson(self: *Self, c: anytype, comptime path: []const u8, args: anytype, value: anytype, call: Client.Call) Error!Response {
            comptime core.checkScope(@TypeOf(c), "target.patchJson");
            comptime encoding.refuseJsonText(@TypeOf(value), "target.patchJson");
            return self.sendJson(c, .PATCH, path, args, value, call);
        }

        /// `Client.sendJson` with a path.
        pub fn sendJson(self: *Self, c: anytype, method: std.http.Method, comptime path: []const u8, args: anytype, value: anytype, call: Client.Call) Error!Response {
            comptime core.checkScope(@TypeOf(c), "target.sendJson");
            comptime encoding.refuseJsonText(@TypeOf(value), "target.sendJson");
            const bytes = try std.json.Stringify.valueAlloc(c.arena(), value, .{});
            return self.through(c, method, path, args, bytes, "application/json", call);
        }

        /// `Client.postForm` with a path: `fields` is the body, under
        /// `withQuery`'s rules, and `args` fills the template as everywhere
        /// else (ADR 061).
        pub fn postForm(self: *Self, c: anytype, comptime path: []const u8, args: anytype, fields: anytype, call: Client.Call) Error!Response {
            comptime core.checkScope(@TypeOf(c), "target.postForm");
            comptime encoding.checkForm(@TypeOf(fields), "target.postForm");
            return self.sendForm(c, .POST, path, args, fields, call);
        }

        pub fn putForm(self: *Self, c: anytype, comptime path: []const u8, args: anytype, fields: anytype, call: Client.Call) Error!Response {
            comptime core.checkScope(@TypeOf(c), "target.putForm");
            comptime encoding.checkForm(@TypeOf(fields), "target.putForm");
            return self.sendForm(c, .PUT, path, args, fields, call);
        }

        /// `Client.sendForm` with a path.
        pub fn sendForm(self: *Self, c: anytype, method: std.http.Method, comptime path: []const u8, args: anytype, fields: anytype, call: Client.Call) Error!Response {
            comptime core.checkScope(@TypeOf(c), "target.sendForm");
            comptime encoding.checkForm(@TypeOf(fields), "target.sendForm");
            const bytes = try fetch.formBody(c, fields);
            return self.through(c, method, path, args, bytes, encoding.form_content_type, call);
        }

        /// The whole of the calls above: the URL, then the call, tried again
        /// when the target says it may be.
        fn through(
            self: *Self,
            c: anytype,
            method: std.http.Method,
            comptime path: []const u8,
            args: anytype,
            body: ?[]const u8,
            content_type: ?[]const u8,
            call: Client.Call,
        ) Error!Response {
            if (!self.client.started) return error.NotStarted;
            const at = try self.url(c, path, args);
            if (comptime opts.retry == null) return self.once(c, method, at, body, content_type, call);
            return self.retrying(c, method, at, body, content_type, call);
        }

        /// One try: this target's permit, and the client's ordinary call with
        /// the standing headers under it.
        fn once(
            self: *Self,
            c: anytype,
            method: std.http.Method,
            at: []const u8,
            body: ?[]const u8,
            content_type: ?[]const u8,
            call: Client.Call,
        ) Error!Response {
            // The permit is taken before the client's, in `begin`, so a call
            // queued for this service holds nothing the others share; and
            // it goes back after the client's, because this `defer` runs
            // after `sendAs` has ended its Exchange. Being per try, it is
            // given back while a retry waits.
            if (opts.max_in_flight != 0) try self.gate.wait(self.client.inner.io);
            defer if (opts.max_in_flight != 0) self.gate.post(self.client.inner.io);
            return self.client.sendAs(c, method, at, body, content_type, .{
                .headers = call.headers,
                .timeout_ms = call.timeout_ms orelse opts.timeout_ms,
                .stall_ms = call.stall_ms orelse opts.stall_ms,
                .max_body = call.max_body orelse opts.max_body,
            }, .{
                .authorization = self.authorization,
                .user_agent = self.user_agent,
                .headers = self.headers,
            });
        }

        /// The tries (ADR 271). A POST or PATCH with no key, on a type that
        /// mints none, is one try: it is sent once because sending it again
        /// might do it twice. Everything else goes round while the policy,
        /// the budget and the route's time allow.
        fn retrying(
            self: *Self,
            c: anytype,
            method: std.http.Method,
            at: []const u8,
            body: ?[]const u8,
            content_type: ?[]const u8,
            call: Client.Call,
        ) Error!Response {
            const policy: *const retry_mod.Retry = &(comptime opts.retry.?);
            const io = self.client.inner.io;
            var now = call;
            if (!method.idempotent() and !retry_mod.Retry.hasKey(call.headers) and !retry_mod.Retry.hasKey(self.headers)) {
                const key_name = policy.mint_key orelse return self.once(c, method, at, body, content_type, call);
                // One key for the call, on every try: the service answers a
                // repeat of it with the first try's result.
                const text = try c.arena().alloc(u8, 32);
                retry_mod.mintKey(io, text[0..32]);
                const lines = try c.arena().alloc(std.http.Header, call.headers.len + 1);
                @memcpy(lines[0..call.headers.len], call.headers);
                lines[call.headers.len] = .{ .name = key_name, .value = text };
                now.headers = lines;
            }
            var tries = retry_mod.Tries.start(policy, &self.ledger, io);
            while (true) {
                const res = self.once(c, method, at, body, content_type, now) catch |err| {
                    if (retry_mod.Retry.retriesError(err) and try tries.again(c, null)) continue;
                    return err;
                };
                if (policy.retriesStatus(@backingInt(res.status))) {
                    const after = if (res.header("retry-after")) |v|
                        retry_mod.retryAfterMs(v, @divFloor(core.nowMicros(), std.time.us_per_s))
                    else
                        null;
                    if (try tries.again(c, after)) continue;
                }
                return res;
            }
        }

        /// The base, the path with its segments filled and encoded, and the
        /// query, in the Scope's memory — **one arena allocation, sized
        /// exactly**, the way `fetch.withQuery` makes its own. For a caller
        /// who wants the URL and not the call: an `Exchange` begun on the
        /// client, a link written into a response.
        ///
        /// `args` fills the template one of two ways. A tuple fills `{}`
        /// by position: `"/v1/charges/{}", .{id}`. A struct fills `{name}`
        /// by field, and **every field the template does not name is a
        /// query param**: `"/v1/charges/{id}/refunds", .{ .id = id, .limit
        /// = 10, .cursor = cursor }` is `/v1/charges/<id>/refunds?limit=10`
        /// with the null cursor left out, under `withQuery`'s rules. A
        /// segment is an int, a bool or text, and text is percent-encoded
        /// with `/` as data.
        pub fn url(self: *Self, c: anytype, comptime path: []const u8, args: anytype) error{OutOfMemory}![]const u8 {
            comptime core.checkScope(@TypeOf(c), "target.url");
            const pieces = comptime parse(path);
            const A = @TypeOf(args);
            const shape = comptime shapeOf(path, pieces, A);
            const named = comptime namedIn(pieces);

            // Measured, then written, into exactly that.
            var len: usize = self.base.len;
            comptime var at: usize = 0;
            inline for (pieces) |piece| switch (piece) {
                .text => |s| len += s.len,
                .positional => {
                    len += segment(args[at]).encodedLen();
                    at += 1;
                },
                .named => |field| len += segment(@field(args, field)).encodedLen(),
            };
            const first = if (comptime shape == .named) encoding.querySeparator(path) else null;
            if (comptime shape == .named) len += encoding.queryLen(args, first, named);

            const out = try c.arena().alloc(u8, len);
            var w: std.Io.Writer = .fixed(out);
            w.writeAll(self.base) catch unreachable; // measured above
            comptime var again: usize = 0;
            inline for (pieces) |piece| switch (piece) {
                .text => |s| w.writeAll(s) catch unreachable,
                .positional => {
                    segment(args[again]).write(&w) catch unreachable;
                    again += 1;
                },
                .named => |field| segment(@field(args, field)).write(&w) catch unreachable,
            };
            if (comptime shape == .named) encoding.queryWrite(&w, args, first, named);
            std.debug.assert(w.buffered().len == len);
            return w.buffered();
        }
    };
}

/// One piece of a path template: text as written, or a segment to fill.
const Piece = union(enum) {
    text: []const u8,
    positional,
    named: []const u8,
};

/// Whether the template's segments are filled by position or by name,
/// which is decided by the arguments rather than the template so that a
/// template with no segment at all takes `.{}` either way.
const Shape = enum { positional, named };

/// The template, read once while compiling.
fn parse(comptime path: []const u8) []const Piece {
    comptime {
        if (path.len == 0 or path[0] != '/') @compileError("nilo: the path `" ++ path ++
            "` does not begin with `/`, and a target's path hangs off its base.");
        var pieces: []const Piece = &.{};
        var start: usize = 0;
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            switch (path[i]) {
                '{' => {
                    const close = std.mem.indexOfScalarPos(u8, path, i, '}') orelse
                        @compileError("nilo: the path `" ++ path ++ "` opens a `{` it never closes.");
                    if (i > start) pieces = pieces ++ &[_]Piece{.{ .text = path[start..i] }};
                    const inner = path[i + 1 .. close];
                    pieces = pieces ++ &[_]Piece{if (inner.len == 0) .positional else .{ .named = inner }};
                    i = close;
                    start = close + 1;
                },
                '}' => @compileError("nilo: the path `" ++ path ++ "` closes a `}` it never opened."),
                else => {},
            }
        }
        if (start < path.len) pieces = pieces ++ &[_]Piece{.{ .text = path[start..] }};
        return pieces;
    }
}

/// The names the template fills, for `checkQuery` to leave out of the query.
fn namedIn(comptime pieces: []const Piece) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (pieces) |p| if (p == .named) {
            names = names ++ &[_][]const u8{p.named};
        };
        return names;
    }
}

/// The Refusals for arguments that do not fit the template: a count that
/// disagrees, a name with no field, a tuple for a named segment or a struct
/// for a positional one, and a value no segment can carry.
fn shapeOf(comptime path: []const u8, comptime pieces: []const Piece, comptime A: type) Shape {
    comptime {
        const info = @typeInfo(A);
        if (info != .@"struct") @compileError("nilo: the path `" ++ path ++ "` was given a " ++
            @typeName(A) ++ " for its arguments, and they are a tuple for `{}` or a struct for `{name}`.");
        const st = info.@"struct";

        var positional: usize = 0;
        var named: usize = 0;
        for (pieces) |p| switch (p) {
            .positional => positional += 1,
            .named => named += 1,
            .text => {},
        };
        if (positional != 0 and named != 0) @compileError("nilo: the path `" ++ path ++
            "` mixes `{}` and `{name}`, and a template fills its segments one way.");

        if (st.is_tuple) {
            if (named != 0) @compileError("nilo: the path `" ++ path ++ "` names its segments and was given a tuple. " ++
                "Name the fields, `.{ ." ++ firstNamed(pieces) ++ " = … }`.");
            if (st.field_names.len != positional) @compileError("nilo: the path `" ++ path ++ "` has " ++
                count(positional, "segment") ++ " to fill and was given " ++ count(st.field_names.len, "argument") ++ ".");
            for (st.field_types, 0..) |FT, i| checkSegment(path, std.fmt.comptimePrint("{d}", .{i + 1}), FT);
            return .positional;
        }

        if (positional != 0) @compileError("nilo: the path `" ++ path ++ "` fills its segments by position and was given a struct. " ++
            "Pass a tuple, `.{ … }`, or name the segment `{field}`.");
        for (pieces) |p| if (p == .named) {
            if (!@hasField(A, p.named)) @compileError("nilo: the path `" ++ path ++ "` names a segment `" ++
                p.named ++ "`, and the struct it was given has no field `" ++ p.named ++ "`.");
            checkSegment(path, "`" ++ p.named ++ "`", @FieldType(A, p.named));
        };
        encoding.checkQuery(A, "target.url", namedIn(pieces));
        return .named;
    }
}

fn firstNamed(comptime pieces: []const Piece) []const u8 {
    for (pieces) |p| if (p == .named) return p.named;
    unreachable;
}

fn count(comptime n: usize, comptime noun: []const u8) []const u8 {
    return std.fmt.comptimePrint("{d} {s}{s}", .{ n, noun, if (n == 1) "" else "s" });
}

/// The Refusal for a segment of a type no path can carry: an optional,
/// because a segment cannot be left out the way a query param can; a
/// struct, a float, an enum, a pointer to something that is not text.
fn checkSegment(comptime path: []const u8, comptime which: []const u8, comptime T: type) void {
    const ok = switch (@typeInfo(T)) {
        .int, .comptime_int, .bool => true,
        else => encoding.isText(T),
    };
    if (!ok) @compileError("nilo: segment " ++ which ++ " of the path `" ++ path ++ "` is a " ++ @typeName(T) ++
        ", and a segment is an int, a bool or text.");
}

/// A segment's value on its way out: the query's own encoding, with `/` as
/// data, which is what makes `../` in an id a segment rather than a walk.
fn segment(v: anytype) encoding.QueryValue {
    return encoding.queryValue(v) orelse unreachable; // an optional is refused in checkSegment
}

/// The Refusals for the type itself: a name with nothing in it, and a
/// `ready` path that does not hang off the base.
fn check(comptime name: []const u8, comptime opts: Options) void {
    if (name.len == 0) @compileError("nilo: fetch.Target was given an empty name, and the name is what the health route and a log line call it.");
    if (opts.retry) |r| if (r.problem()) |why| @compileError("nilo: fetch.Target(\"" ++ name ++ "\")'s `.retry` is refused: " ++ why ++ ".");
    if (opts.ready) |path| {
        if (path.len == 0 or path[0] != '/') @compileError("nilo: fetch.Target(\"" ++ name ++ "\") has a ready path `" ++
            path ++ "` that does not begin with `/`, and it hangs off the base like any other.");
    }
}

// ---- tests ----

const testing = std.testing;

const Api = Target("api", .{});

fn opened(client: *Client, base: []const u8) !Api {
    return Api.open(client, .{ .base = base });
}

test "a path template fills its segments by position, encoded with slash as data" {
    var client: Client = .init(testing.allocator, .{});
    defer client.deinit();
    var api = try opened(&client, "https://api.example.com");

    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    try testing.expectEqualStrings(
        "https://api.example.com/v1/charges/ch_1",
        try api.url(&run, "/v1/charges/{}", .{"ch_1"}),
    );
    // Two segments, of two kinds, and an id that tries to climb out of its
    // segment stays inside it.
    try testing.expectEqualStrings(
        "https://api.example.com/repos/zig%2F..%2Fadmin/issues/42",
        try api.url(&run, "/repos/{}/issues/{}", .{ run.str("zig/../admin"), @as(u32, 42) }),
    );
    // No segment, and the empty tuple.
    try testing.expectEqualStrings("https://api.example.com/v1/me", try api.url(&run, "/v1/me", .{}));
}

test "a struct fills named segments, and the fields it does not name are the query" {
    var client: Client = .init(testing.allocator, .{});
    defer client.deinit();
    var api = try opened(&client, "https://api.example.com/v2");

    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    const cursor: ?[]const u8 = null;
    try testing.expectEqualStrings(
        "https://api.example.com/v2/charges/ch_1/refunds?limit=10",
        try api.url(&run, "/charges/{id}/refunds", .{ .id = "ch_1", .limit = 10, .cursor = cursor }),
    );
    // A template with no segment and a struct is a query alone; an empty
    // struct is neither.
    try testing.expectEqualStrings(
        "https://api.example.com/v2/search?q=a%20b",
        try api.url(&run, "/search", .{ .q = "a b" }),
    );
    try testing.expectEqualStrings(
        "https://api.example.com/v2/search",
        try api.url(&run, "/search", .{}),
    );
    // A query already on the template gets `&`.
    try testing.expectEqualStrings(
        "https://api.example.com/v2/search?sort=asc&q=x",
        try api.url(&run, "/search?sort=asc", .{ .q = "x" }),
    );
}

test "a base is held less its trailing slash, and one that is not absolute is refused at open" {
    var client: Client = .init(testing.allocator, .{});
    defer client.deinit();

    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    var api = try opened(&client, "https://api.example.com/");
    try testing.expectEqualStrings("https://api.example.com/v1", try api.url(&run, "/v1", .{}));

    try testing.expectError(error.BaseNotAbsolute, opened(&client, "api.example.com"));
    try testing.expectError(error.BaseNotAbsolute, opened(&client, "/v1"));
    try testing.expectError(error.BaseHasQuery, opened(&client, "https://api.example.com/?key=1"));
    try testing.expectError(error.BaseHasQuery, opened(&client, "https://api.example.com/#x"));
}

test "two targets are two types, and a target's options are on the type" {
    const Stripe = Target("stripe", .{ .max_in_flight = 8, .timeout_ms = 5_000 });
    const Google = Target("google", .{ .max_in_flight = 8, .timeout_ms = 5_000 });
    try testing.expect(Stripe != Google);
    try testing.expectEqualStrings("stripe", Stripe.target);
    try testing.expectEqual(@as(u32, 8), Stripe.options.max_in_flight);
    try testing.expectEqual(@as(?u32, 5_000), Stripe.options.timeout_ms);

    var client: Client = .init(testing.allocator, .{});
    defer client.deinit();
    const stripe = try Stripe.open(&client, .{ .base = "https://api.stripe.com" });
    try testing.expectEqual(@as(usize, 8), stripe.gate.permits);
}

test "a call on a target that was never started refuses rather than dialling undefined" {
    var client: Client = .init(testing.allocator, .{});
    defer client.deinit();
    var api = try opened(&client, "http://example.invalid");

    var run: core.Run = .init(testing.allocator);
    defer run.deinit();
    try testing.expectError(error.NotStarted, api.get(&run, "/x", .{}, .{}));

    // And the health route says so in the same words a Db uses.
    var any: core.AnyScope = .of(&run);
    try testing.expectEqualStrings("not started: `listen()` has not run", api.nilo_ready(&any).?);
}
