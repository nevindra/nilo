//! Middleware — work that runs before and after a handler, at the Ctx
//! layer (ADR 002), assembled as an onion (ADR 008).
//!
//! ```zig
//! fn timing(c: *Ctx, next: Next) !void {
//!     const started = nilo.monotonicNanos();
//!     try next.run(c);
//!     std.log.info("{s} took {d}µs", .{ c.path().view(), (nilo.monotonicNanos() - started) / 1000 });
//! }
//!
//! try app.use(timing);
//! try app.useOn("/api", requireToken);
//! ```
//!
//! A middleware that does not call `next.run(c)` ends the chain — that is
//! all short-circuiting is — and it answers, or the request is a 500 naming
//! it: an empty 200 is what a handler returning `void` means (ADR 120), and
//! a guard that forgot its 401 must not read as a success. One that returns an error goes through exactly
//! the same path a failing handler does, fail functions and mapping table
//! included (ADR 004), so there is only ever one error path.
//!
//! **A middleware that changes the answer after `next` holds it**:
//!
//! ```zig
//! fn timing(c: *Ctx, next: Next) !void {
//!     const started = nilo.monotonicNanos();
//!     const answer = try next.hold(c);
//!     var buf: [32]u8 = undefined;
//!     const took = (nilo.monotonicNanos() - started) / std.time.ns_per_ms;
//!     try answer.setHeader("Server-Timing", try std.fmt.bufPrint(&buf, "app;dur={d}", .{took}));
//! }
//! ```
//!
//! A failure below `hold` comes back as its error, as from `run`, and App
//! answers it after the chain. A header set on the way out with `defer` goes
//! on that answer too, so one line covers both.
//!
//! `next.run(c)` writes the answer as soon as the handler sends it, so the
//! half after it can read what was sent and change nothing; `next.hold(c)`
//! keeps the answer until the chain has unwound, and what has not had to
//! leave yet can still change (ADR 008). A header set after `run` is refused
//! with a sentence naming `hold`, where Go and Gin drop one without a word.
//!
//! Middleware still produces no value for the handler, and it no longer
//! needs to: the thing it used to be asked for — auth resolving a user — is
//! a resolved value now (ADR 015). A middleware guards, a resolved value
//! provides, and a guard reads one without making the handler behind it work
//! the same thing out twice.
//!
//! **A middleware is given what it needs, after `Next`** (ADR 008,
//! `typedmw.zig`):
//!
//! ```zig
//! fn requireKey(c: *Ctx, next: Next, keys: *KeyStore, user: CurrentUser) !void {
//!     if (!keys.allows(user.id)) return fail.forbidden("no key", .{});
//!     try next.run(c);
//! }
//! try app.use(requireKey);
//! ```
//!
//! A service, a resolved value, `Path(T)`, the arena: by the rule a handler
//! follows, and wrapped while compiling into the bare `Middleware` below, so
//! the onion and the chain are unchanged. What it needs is checked at
//! `listen()`, where `c.service(T) orelse return next.run(c)` would have let
//! every request through when the service was missing. The bare form is
//! still the right one for a middleware that needs nothing.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const fail = @import("fail.zig");
const http1 = @import("http1.zig");
const Late = @import("late.zig").Late;
const typedmw = @import("typedmw.zig");

/// The innermost layer: a plain Ctx handler. This is what the typed layer
/// compiles down to, and what the onion wraps.
pub const CtxHandler = *const fn (*Ctx) anyerror!void;

pub const Middleware = *const fn (*Ctx, Next) anyerror!void;

/// A middleware that also says how much body the routes it covers take
/// (`nilo.maxBody`, ADR 156). A function pointer cannot say it: a gRPC call
/// collects its message before any middleware runs, so the collector has to
/// learn the limit from the registration instead, and the registration is
/// where `use` and `with` take this in place of a bare `Middleware`
/// (ADR 156, ADR 220). Everywhere else it is the `run` inside it.
pub const Limited = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Limited";

    run: Middleware,
    limit: Limit,

    /// Where the number is: in the program, or in a `usize` it fills before
    /// `listen()` (`nilo.Late`).
    pub const Limit = Late(usize);

    /// The limit now, 0 for none: a held limit left at zero leaves
    /// `listen()`'s number in force, as it does on HTTP/1.
    pub fn read(self: Limited) usize {
        return self.limit.read();
    }
};

/// The function a registration was handed, whether it was a bare
/// `Middleware`, a `Limited`, or a typed function that takes services and
/// resolved values after `Next`, which is wrapped here into a bare one
/// (`typedmw.zig`, ADR 008). A function body is comptime-known whatever the
/// parameter says, which is all wrapping needs; a `Middleware` held in a
/// runtime variable is passed through as it always was.
pub fn runOf(middleware: anytype) Middleware {
    comptime typedmw.refuseRuntimePointer(@TypeOf(middleware));
    if (comptime typedmw.isTypedType(@TypeOf(middleware))) return typedmw.wrap(middleware);
    return if (@TypeOf(middleware) == Limited) middleware.run else middleware;
}

/// The `Limited` inside a registration, as a slice of none or one, so a
/// comptime `with` can keep it beside the chain.
pub fn limitsOf(comptime middleware: anytype) []const Limited {
    return if (@TypeOf(middleware) == Limited) &[_]Limited{middleware} else &[_]Limited{};
}

/// The rest of the onion. Two words, passed by value, allocating nothing.
pub const Next = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Next";

    rest: []const Middleware,
    handler: CtxHandler,

    pub fn run(self: Next, c: *Ctx) anyerror!void {
        // How much of the onion is left below the deepest layer reached, 0
        // once the handler runs. App reads it to tell a handler that meant
        // an empty 200 from a middleware that stopped the chain and said
        // nothing, and to say which one that was (ADR 008).
        c._chain_left = @intCast(@min(self.rest.len, std.math.maxInt(u8)));
        if (self.rest.len == 0) return self.handler(c);
        return self.rest[0](c, .{ .rest = self.rest[1..], .handler = self.handler });
    }

    /// `run`, with the answer held until the chain has unwound rather than
    /// written when the handler sends it, and handed back to change (ADR 008).
    ///
    /// ```zig
    /// const answer = try next.hold(c);
    /// if (answer.status() == 200) try answer.setHeader("Cache-Control", "max-age=60");
    /// ```
    ///
    /// What can change is what has not had to leave: a whole answer's status,
    /// headers, body and trailers; a file's headers; a stream's trailers and
    /// its end, whose head left when it opened. A failure below comes back as
    /// its error, as from `run`, and a header set with `defer` goes on its
    /// answer too; a failure after this replaces a held whole answer, where
    /// after `run` it could only close the connection. The cost is a copy: a body handed to `c.send` is copied
    /// into the request arena to outlive the handler, which is free under
    /// 16 KiB and not above it (`Ctx.send`); one the typed layer sends from a
    /// returned value is not copied.
    pub fn hold(self: Next, c: *Ctx) anyerror!Answer {
        c._hold = true;
        try self.run(c);
        return .{ ._c = c };
    }
};

/// The answer a middleware is holding (`Next.hold`): written when the chain
/// has unwound, and until then this middleware's to read and change.
pub const Answer = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Answer";

    _c: *Ctx,

    /// The status it answers with, or null when nothing below answered: App's
    /// empty 200, or its 500 for a guard that said nothing, is still to come.
    pub fn status(self: Answer) ?u16 {
        return self._c.answered();
    }

    /// The body of a whole answer, as it was sent and before any compression.
    /// Null for a stream, a file, or nothing answered.
    pub fn body(self: Answer) ?[]const u8 {
        const held = self._c._held orelse return null;
        return switch (held.*) {
            .whole => |w| w.body,
            .file => null,
        };
    }

    /// A header on the answer, as `Ctx.setHeader`. Refused on a stream, whose
    /// head has gone.
    pub fn setHeader(self: Answer, name: []const u8, value: []const u8) !void {
        return self._c.setHeader(name, value);
    }

    /// A trailer on the answer, as `Ctx.setTrailer`. A stream takes one too,
    /// because its end is held as well.
    pub fn setTrailer(self: Answer, name: []const u8, value: []const u8) !void {
        return self._c.setTrailer(name, value);
    }

    /// A different whole answer in its place: a 304 for a body whose tag the
    /// client already has, a page of HTML for a browser that got JSON. The
    /// headers set so far stay. `new_body` is copied. Refused once a head
    /// has gone, a stream's or a handed-over connection's.
    pub fn replace(self: Answer, new_status: u16, content_type: []const u8, new_body: []const u8) !void {
        const c = self._c;
        if (c._head_written) return fail.internal(
            "the answer being replaced has written its head already (a stream, or a connection " ++
                "handed over), so there is nothing left to replace it with",
            .{},
        );
        try c.contentTypeOk(content_type);
        if (c._held) |held| if (held.* == .file) held.file.contents.file.close();
        c.markAnswered(new_status);
        (try c.heldSlot()).* = .{ .whole = .{
            .status = new_status,
            .content_type = try c._arena.dupe(u8, content_type),
            .body = try c._arena.dupe(u8, new_body),
            .compress = true,
        } };
    }
};

/// One `use` registration: a middleware plus the path prefix it applies
/// to. An empty prefix means every route.
pub const Scoped = struct {
    prefix: []const u8,
    middleware: Middleware,

    pub fn covers(self: Scoped, path: []const u8) bool {
        if (self.prefix.len == 0) return true;
        return underPrefix(self.prefix, path);
    }
};

/// Whether `path` sits under `prefix`, comparing whole segments, with a
/// `:name` segment in the prefix matching any one segment of the path.
///
/// Both halves matter. **Whole segments** is what `static.zig`'s
/// `underPrefix` has always done and this had not: `startsWith` alone put
/// `/api` middleware on `/apiary`.
///
/// **A `:name` segment** is what lets a group prefix carry a param. This is
/// asked two different questions and has to answer both: at `listen()` the
/// chain for each route is resolved against its *pattern*, where `/orgs/:org`
/// is compared with `/orgs/:org/members`; per request, on the cold path where
/// nothing matched, it is compared with a real path like `/orgs/acme/members`.
/// A prefix segment that begins with `:` matches whatever is opposite it,
/// which answers both without either caller having to say which it is asking.
///
/// A path segment is compared as it decodes, because the router matches
/// `/files/%70rivate/x` to the same route as `/files/private/x`, and a guard
/// that a percent escape steps around is not a guard.
fn underPrefix(prefix: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, prefix, "/")) return true;

    var wanted = std.mem.tokenizeScalar(u8, prefix, '/');
    var got = std.mem.tokenizeScalar(u8, path, '/');
    while (wanted.next()) |want| {
        const have = got.next() orelse return false;
        if (want.len > 0 and want[0] == ':') continue;
        if (!decodesTo(have, want)) return false;
    }
    return true;
}

/// Whether `raw`, percent-decoded, is `want`, without decoding it anywhere.
fn decodesTo(raw: []const u8, want: []const u8) bool {
    var i: usize = 0;
    var n: usize = 0;
    while (i < raw.len) : (n += 1) {
        if (n == want.len) return false;
        var byte = raw[i];
        if (byte == '%' and i + 2 < raw.len) {
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch 255;
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch 255;
            if (hi != 255 and lo != 255) {
                byte = hi * 16 + lo;
                i += 2;
            }
        }
        if (byte != want[n]) return false;
        i += 1;
    }
    return n == want.len;
}

/// Whether a route's pattern settles a prefix's question on its own.
///
/// `chainFor` is asked once per route at `listen()`, about the pattern, and
/// for most routes the pattern is the whole answer: `/api/users/:id` is under
/// `/api` whatever the id is. It is not the whole answer where the pattern has
/// a `:param` or a `*` opposite a literal segment of the prefix: `/files/*`
/// is under `/files/private` for `/files/private/x` and not for
/// `/files/public/x`, and comparing `private` with `*` attached nothing, so
/// the first was served without the guard (ADR 008). Such a route's chain is
/// `.depends`, and is resolved per request against the real path.
pub const Reach = enum { covered, outside, depends };

pub fn reach(prefix: []const u8, pattern: []const u8) Reach {
    if (prefix.len == 0 or std.mem.eql(u8, prefix, "/")) return .covered;

    var wanted = std.mem.tokenizeScalar(u8, prefix, '/');
    var got = std.mem.tokenizeScalar(u8, pattern, '/');
    var depends = false;
    while (wanted.next()) |want| {
        const have = got.next() orelse return .outside;
        // A `*` takes any number of segments, so nothing after it in the
        // prefix can be read off the pattern.
        if (std.mem.eql(u8, have, "*")) return .depends;
        if (want[0] == ':') continue;
        if (have[0] == ':') {
            depends = true;
            continue;
        }
        if (!std.mem.eql(u8, want, have)) return .outside;
    }
    return if (depends) .depends else .covered;
}

/// Whether any scoped middleware leaves `pattern`'s chain to the real path.
pub fn dependsOnPath(scoped: []const Scoped, pattern: []const u8) bool {
    for (scoped) |s| {
        if (reach(s.prefix, pattern) == .depends) return true;
    }
    return false;
}

/// One route saying it is not covered by a middleware its group is.
///
/// **Every API with accounts has the same shape**: one prefix, almost all of it
/// behind a session, and two routes inside it that cannot be — you cannot
/// require a session to create one. There was nothing that removed a middleware
/// and nothing that attached one to a single route, so `use(requireOperator)`
/// on `/v1` guarded `/v1/sign-up` too and sign-up answered 401
/// ([ADR 008](../docs/adr/008-middleware-is-an-onion-of-ctx-functions.md)).
///
/// The pattern is **exact** rather than a prefix, and it is the joined one the
/// route was registered under, produced by the same `joined(prefix, pattern)`
/// call. That is what keeps the compiler in the loop: the exception is written
/// where the route is declared, so renaming the route moves it, where a string
/// skip-list inside the middleware would go on guarding a route that no longer
/// exists.
pub const Exemption = struct {
    pattern: []const u8,
    /// Which verb on that pattern. `GET /users/:id` and `DELETE /users/:id`
    /// are two routes, and excusing one of them must not excuse the other —
    /// which it did until `with` arrived and needed the same distinction
    /// ([ADR 099](../docs/adr/099-a-route-can-say-what-covers-it.md)).
    method: http1.Method,
    middleware: Middleware,

    fn frees(self: Exemption, path: []const u8, method: ?http1.Method, middleware: Middleware) bool {
        if (self.middleware != middleware) return false;
        if (method == null or self.method != method.?) return false;
        return std.mem.eql(u8, self.pattern, path);
    }
};

/// One route saying a middleware *does* cover it — the other direction of
/// `Exemption`, and the same shape for the same reason
/// ([ADR 099](../docs/adr/099-a-route-can-say-what-covers-it.md)).
///
/// **The awkward case `use` cannot say** is a route that wants more than its
/// neighbours: `use`, `useOn` and `group().use` all scope by path, so one
/// endpoint behind an extra guard meant a prefix invented to match only it, or
/// a group holding a single route. Gin and Fiber both take middleware as extra
/// arguments to the route; here it is `with`, which hands back a group, so the
/// vocabulary does not grow a second shape.
///
/// The pattern is **exact** and is the joined one the route was registered
/// under, produced by the same `joined(prefix, pattern)` call `Exemption` uses
/// — which is what keeps the compiler in the loop when somebody renames the
/// route.
pub const Attached = struct {
    pattern: []const u8,
    /// Which verb on that pattern, for the reason `Exemption` carries one:
    /// `with(adminOnly).delete("/users/:id", …)` must not put `adminOnly` on
    /// the `GET` that reads the same path.
    method: http1.Method,
    middleware: Middleware,

    fn covers(self: Attached, path: []const u8, method: ?http1.Method) bool {
        if (method == null or self.method != method.?) return false;
        return std.mem.eql(u8, self.pattern, path);
    }
};

/// The chain for `path`: the scoped middleware in registration order, then
/// whatever the route carries of its own. The caller owns the result.
/// Resolved once per route at `listen()`; for a request that matched no route
/// this runs per request, which is fine because that is the cold path, and so
/// it does for a route whose pattern does not settle its chain (`reach`).
///
/// `pattern` is what an exemption or an attachment names, and `path` is what
/// a prefix is compared with: the same string at `listen()`, and the real
/// path where the chain is resolved per request.
///
/// **Attached last means attached innermost**, which is the order the nesting
/// means rather than a choice between two equally good ones: a group's session
/// check has to have run before the one route's check of what that session is
/// allowed to do. A route with nothing attached gets the identical chain it
/// got before, because the second loop runs zero times.
pub fn chainFor(
    gpa: std.mem.Allocator,
    scoped: []const Scoped,
    exemptions: []const Exemption,
    attached: []const Attached,
    method: ?http1.Method,
    pattern: []const u8,
    path: []const u8,
) ![]const Middleware {
    var n: usize = 0;
    for (scoped) |s| {
        if (covered(s, exemptions, method, pattern, path)) n += 1;
    }
    for (attached) |a| {
        if (a.covers(pattern, method)) n += 1;
    }
    if (n == 0) return &.{};

    const chain = try gpa.alloc(Middleware, n);
    var i: usize = 0;
    for (scoped) |s| {
        if (!covered(s, exemptions, method, pattern, path)) continue;
        chain[i] = s.middleware;
        i += 1;
    }
    for (attached) |a| {
        if (!a.covers(pattern, method)) continue;
        chain[i] = a.middleware;
        i += 1;
    }
    return chain;
}

/// A middleware the program said reads the session cookie, from `app.guard`
/// (ADR 153). The document cannot check that it does; what it can check is
/// which routes the middleware is in front of, and that half is `wraps`.
pub const Guard = struct {
    middleware: Middleware,
    /// The cookie's name, for `securitySchemes`. The document's only
    /// unverifiable claim.
    cookie: []const u8,
};

/// Whether `middleware` would be in `chainFor`'s answer for this route —
/// the same two questions, asked without building the chain. What the
/// document asks at `writeOpenApi`, which runs before `listen()` has
/// resolved anything and must not allocate a chain per route to find out
/// ([ADR 153](../docs/adr/153-an-authorization-header-a-handler-can-ask-for.md)).
pub fn wraps(
    scoped: []const Scoped,
    exemptions: []const Exemption,
    attached: []const Attached,
    method: ?http1.Method,
    path: []const u8,
    middleware: Middleware,
) bool {
    for (scoped) |s| {
        if (s.middleware == middleware and covered(s, exemptions, method, path, path)) return true;
    }
    for (attached) |a| {
        if (a.middleware == middleware and a.covers(path, method)) return true;
    }
    return false;
}

fn covered(s: Scoped, exemptions: []const Exemption, method: ?http1.Method, pattern: []const u8, path: []const u8) bool {
    if (!s.covers(path)) return false;
    for (exemptions) |e| if (e.frees(pattern, method, s.middleware)) return false;
    return true;
}

const testing = std.testing;

/// A trail of single letters, so the order the onion ran in can be read
/// off as a string.
var trail_buf: [32]u8 = undefined;
var trail_len: usize = 0;

fn mark(letter: u8) void {
    trail_buf[trail_len] = letter;
    trail_len += 1;
}

fn trail() []const u8 {
    return trail_buf[0..trail_len];
}

fn markA(c: *Ctx, next: Next) anyerror!void {
    mark('a');
    try next.run(c);
    mark('A');
}

fn markB(c: *Ctx, next: Next) anyerror!void {
    mark('b');
    try next.run(c);
    mark('B');
}

fn stopHere(_: *Ctx, _: Next) anyerror!void {
    mark('x');
}

fn terminal(_: *Ctx) anyerror!void {
    mark('H');
}

test "the onion runs outside in, then inside out" {
    trail_len = 0;
    var c: Ctx = undefined;
    try (Next{ .rest = &.{ markA, markB }, .handler = terminal }).run(&c);
    try testing.expectEqualStrings("abHBA", trail());
}

test "a middleware that never calls next ends the chain" {
    trail_len = 0;
    var c: Ctx = undefined;
    try (Next{ .rest = &.{ markA, stopHere, markB }, .handler = terminal }).run(&c);
    // markB and the handler never run; markA's tail still does.
    try testing.expectEqualStrings("axA", trail());
}

test "an empty chain calls the handler directly" {
    trail_len = 0;
    var c: Ctx = undefined;
    try (Next{ .rest = &.{}, .handler = terminal }).run(&c);
    try testing.expectEqualStrings("H", trail());
}

test "a prefix scopes a middleware to the routes under it" {
    const scoped = [_]Scoped{
        .{ .prefix = "", .middleware = markA },
        .{ .prefix = "/api", .middleware = markB },
    };

    const on_api = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/api/users/:id", "/api/users/:id");
    defer testing.allocator.free(on_api);
    try testing.expectEqual(@as(usize, 2), on_api.len);

    const off_api = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/health", "/health");
    defer testing.allocator.free(off_api);
    try testing.expectEqual(@as(usize, 1), off_api.len);
    try testing.expect(off_api[0] == markA);
}

test "a prefix only covers whole segments" {
    const scoped = [_]Scoped{.{ .prefix = "/api", .middleware = markA }};

    const inside = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/api/users", "/api/users");
    defer testing.allocator.free(inside);
    try testing.expectEqual(@as(usize, 1), inside.len);

    // The group's own path, with nothing under it.
    const itself = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/api", "/api");
    defer testing.allocator.free(itself);
    try testing.expectEqual(@as(usize, 1), itself.len);

    // `startsWith` used to put this middleware on a route that merely began
    // with the same letters. `static.zig` had the right rule all along.
    const apiary = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/apiary", "/apiary");
    defer testing.allocator.free(apiary);
    try testing.expectEqual(@as(usize, 0), apiary.len);
}

test "a prefix carrying a param covers a pattern and a real path alike" {
    const scoped = [_]Scoped{.{ .prefix = "/orgs/:org", .middleware = markA }};

    // What `listen()` asks: the chain for each route, against its pattern.
    const pattern = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/orgs/:org/members", "/orgs/:org/members");
    defer testing.allocator.free(pattern);
    try testing.expectEqual(@as(usize, 1), pattern.len);

    // What a request that matched no route asks: against the real path.
    const real = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/orgs/acme/members", "/orgs/acme/members");
    defer testing.allocator.free(real);
    try testing.expectEqual(@as(usize, 1), real.len);

    // A param matches one segment, not the rest of the path.
    const elsewhere = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/teams/acme/members", "/teams/acme/members");
    defer testing.allocator.free(elsewhere);
    try testing.expectEqual(@as(usize, 0), elsewhere.len);

    // Too short to be under it at all.
    const short = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/orgs", "/orgs");
    defer testing.allocator.free(short);
    try testing.expectEqual(@as(usize, 0), short.len);
}

test "a middleware a route carries runs inside the ones scoped over it" {
    // The order the nesting means: the group's guard has already run by the
    // time the route's own guard does (ADR 099).
    const scoped = [_]Scoped{.{ .prefix = "", .middleware = markA }};
    const attached = [_]Attached{.{ .pattern = "/v1/orders", .method = .POST, .middleware = markB }};

    const both = try chainFor(testing.allocator, &scoped, &.{}, &attached, .POST, "/v1/orders", "/v1/orders");
    defer testing.allocator.free(both);
    try testing.expectEqual(@as(usize, 2), both.len);
    try testing.expect(both[0] == markA);
    try testing.expect(both[1] == markB);

    trail_len = 0;
    var c: Ctx = undefined;
    try (Next{ .rest = both, .handler = terminal }).run(&c);
    try testing.expectEqualStrings("abHBA", trail());
}

test "an attached middleware covers its own route and nothing beside it" {
    // Exact, not a prefix — which is the difference between this and `useOn`,
    // and the reason `with` can be used on a route whose neighbours are named
    // similarly.
    const attached = [_]Attached{.{ .pattern = "/v1/orders", .method = .POST, .middleware = markA }};

    const itself = try chainFor(testing.allocator, &.{}, &.{}, &attached, .POST, "/v1/orders", "/v1/orders");
    defer testing.allocator.free(itself);
    try testing.expectEqual(@as(usize, 1), itself.len);

    // A route underneath it is a different route.
    const under = try chainFor(testing.allocator, &.{}, &.{}, &attached, .POST, "/v1/orders/:id", "/v1/orders/:id");
    defer testing.allocator.free(under);
    try testing.expectEqual(@as(usize, 0), under.len);

    // And one that merely begins with the same letters is not it either.
    const alike = try chainFor(testing.allocator, &.{}, &.{}, &attached, .POST, "/v1/orders-archive", "/v1/orders-archive");
    defer testing.allocator.free(alike);
    try testing.expectEqual(@as(usize, 0), alike.len);
}

test "an attached middleware covers one verb on its path, not every verb" {
    // `with(adminOnly).delete("/users/:id", …)` must not put `adminOnly` on
    // the `GET` that reads the same path. They are two routes (ADR 099).
    const attached = [_]Attached{.{ .pattern = "/users/:id", .method = .DELETE, .middleware = markA }};

    const removing = try chainFor(testing.allocator, &.{}, &.{}, &attached, .DELETE, "/users/:id", "/users/:id");
    defer testing.allocator.free(removing);
    try testing.expectEqual(@as(usize, 1), removing.len);

    const reading = try chainFor(testing.allocator, &.{}, &.{}, &attached, .GET, "/users/:id", "/users/:id");
    defer testing.allocator.free(reading);
    try testing.expectEqual(@as(usize, 0), reading.len);
}

test "an exemption frees one verb on its path, not every verb" {
    // The same distinction, in the direction `without` goes — and it was
    // missing until `with` needed it: a `GET` registered on the path of an
    // excused `POST` was excused too.
    const scoped = [_]Scoped{.{ .prefix = "", .middleware = markA }};
    const exemptions = [_]Exemption{.{ .pattern = "/sign-up", .method = .POST, .middleware = markA }};

    const posting = try chainFor(testing.allocator, &scoped, &exemptions, &.{}, .POST, "/sign-up", "/sign-up");
    defer testing.allocator.free(posting);
    try testing.expectEqual(@as(usize, 0), posting.len);

    const getting = try chainFor(testing.allocator, &scoped, &exemptions, &.{}, .GET, "/sign-up", "/sign-up");
    defer testing.allocator.free(getting);
    try testing.expectEqual(@as(usize, 1), getting.len);
}

test "registration order is the run order, prefix or not" {
    const scoped = [_]Scoped{
        .{ .prefix = "/api", .middleware = markB },
        .{ .prefix = "", .middleware = markA },
    };
    const chain = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/api/x", "/api/x");
    defer testing.allocator.free(chain);
    try testing.expect(chain[0] == markB);
    try testing.expect(chain[1] == markA);
}

test "a pattern settles a prefix only where its own segments can" {
    try testing.expectEqual(Reach.covered, reach("", "/anything/*"));
    try testing.expectEqual(Reach.covered, reach("/api", "/api/users/:id"));
    try testing.expectEqual(Reach.outside, reach("/api", "/health"));
    try testing.expectEqual(Reach.outside, reach("/api/users", "/api"));
    try testing.expectEqual(Reach.covered, reach("/orgs/:org", "/orgs/:org/members"));
    // A param or a `*` opposite a word is a question for the real path.
    try testing.expectEqual(Reach.depends, reach("/files/private", "/files/*"));
    try testing.expectEqual(Reach.depends, reach("/admin", "/:page/settings"));
    try testing.expectEqual(Reach.depends, reach("/admin", "/*"));
    // A word further on that can never match still settles it.
    try testing.expectEqual(Reach.outside, reach("/admin/x", "/:page/settings"));
}

test "a path segment is compared as it decodes" {
    try testing.expect(decodesTo("private", "private"));
    try testing.expect(decodesTo("%70rivate", "private"));
    try testing.expect(decodesTo("priv%61te", "private"));
    try testing.expect(!decodesTo("privat", "private"));
    try testing.expect(!decodesTo("privatee", "private"));
    try testing.expect(!decodesTo("%7", "%7x"));
    try testing.expect(decodesTo("100%", "100%"));
}
