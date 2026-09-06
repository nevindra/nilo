//! Middleware — work that runs before and after a handler, at the Ctx
//! layer (ADR 0003), assembled as an onion (ADR 0009).
//!
//! ```zig
//! fn timing(c: *Ctx, next: Next) !void {
//!     var timer = try std.time.Timer.start();
//!     try next.run(c);
//!     std.log.info("{s} took {d}µs", .{ c.path().view(), timer.read() / 1000 });
//! }
//!
//! try app.use(timing);
//! try app.use("/api", requireToken);
//! ```
//!
//! A middleware that does not call `next.run(c)` ends the chain — that is
//! all short-circuiting is. One that returns an error goes through exactly
//! the same path a failing handler does, fail functions and mapping table
//! included (ADR 0005), so there is only ever one error path.
//!
//! Middleware still produces no value for the handler, and it no longer
//! needs to: the thing it used to be asked for — auth resolving a user — is
//! a resolved value now (ADR 0016). A middleware guards, a resolved value
//! provides, and `c.resolve(T)` is how a guard reads one without making the
//! handler behind it work the same thing out twice.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const http1 = @import("http1.zig");

/// The innermost layer: a plain Ctx handler. This is what the typed layer
/// compiles down to, and what the onion wraps.
pub const CtxHandler = *const fn (*Ctx) anyerror!void;

pub const Middleware = *const fn (*Ctx, Next) anyerror!void;

/// The rest of the onion. Two words, passed by value, allocating nothing.
pub const Next = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 0122).
    pub const nilo_type_name = "nilo.Next";

    rest: []const Middleware,
    handler: CtxHandler,

    pub fn run(self: Next, c: *Ctx) anyerror!void {
        if (self.rest.len == 0) return self.handler(c);
        return self.rest[0](c, .{ .rest = self.rest[1..], .handler = self.handler });
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
fn underPrefix(prefix: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, prefix, "/")) return true;

    var wanted = std.mem.tokenizeScalar(u8, prefix, '/');
    var got = std.mem.tokenizeScalar(u8, path, '/');
    while (wanted.next()) |want| {
        const have = got.next() orelse return false;
        if (want.len > 0 and want[0] == ':') continue;
        if (!std.mem.eql(u8, want, have)) return false;
    }
    return true;
}

/// One route saying it is not covered by a middleware its group is.
///
/// **Every API with accounts has the same shape**: one prefix, almost all of it
/// behind a session, and two routes inside it that cannot be — you cannot
/// require a session to create one. There was nothing that removed a middleware
/// and nothing that attached one to a single route, so `use(requireOperator)`
/// on `/v1` guarded `/v1/sign-up` too and sign-up answered 401
/// ([ADR 0080](../docs/adr/0080-a-route-can-say-it-is-not-covered.md)).
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
    /// ([ADR 0126](../docs/adr/0126-a-route-can-say-what-covers-it.md)).
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
/// ([ADR 0126](../docs/adr/0126-a-route-can-say-what-covers-it.md)).
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
/// this runs per request, which is fine because that is the cold path.
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
    path: []const u8,
) ![]const Middleware {
    var n: usize = 0;
    for (scoped) |s| {
        if (covered(s, exemptions, method, path)) n += 1;
    }
    for (attached) |a| {
        if (a.covers(path, method)) n += 1;
    }
    if (n == 0) return &.{};

    const chain = try gpa.alloc(Middleware, n);
    var i: usize = 0;
    for (scoped) |s| {
        if (!covered(s, exemptions, method, path)) continue;
        chain[i] = s.middleware;
        i += 1;
    }
    for (attached) |a| {
        if (!a.covers(path, method)) continue;
        chain[i] = a.middleware;
        i += 1;
    }
    return chain;
}

fn covered(s: Scoped, exemptions: []const Exemption, method: ?http1.Method, path: []const u8) bool {
    if (!s.covers(path)) return false;
    for (exemptions) |e| if (e.frees(path, method, s.middleware)) return false;
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

    const on_api = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/api/users/:id");
    defer testing.allocator.free(on_api);
    try testing.expectEqual(@as(usize, 2), on_api.len);

    const off_api = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/health");
    defer testing.allocator.free(off_api);
    try testing.expectEqual(@as(usize, 1), off_api.len);
    try testing.expect(off_api[0] == markA);
}

test "a prefix only covers whole segments" {
    const scoped = [_]Scoped{.{ .prefix = "/api", .middleware = markA }};

    const inside = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/api/users");
    defer testing.allocator.free(inside);
    try testing.expectEqual(@as(usize, 1), inside.len);

    // The group's own path, with nothing under it.
    const itself = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/api");
    defer testing.allocator.free(itself);
    try testing.expectEqual(@as(usize, 1), itself.len);

    // `startsWith` used to put this middleware on a route that merely began
    // with the same letters. `static.zig` had the right rule all along.
    const apiary = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/apiary");
    defer testing.allocator.free(apiary);
    try testing.expectEqual(@as(usize, 0), apiary.len);
}

test "a prefix carrying a param covers a pattern and a real path alike" {
    const scoped = [_]Scoped{.{ .prefix = "/orgs/:org", .middleware = markA }};

    // What `listen()` asks: the chain for each route, against its pattern.
    const pattern = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/orgs/:org/members");
    defer testing.allocator.free(pattern);
    try testing.expectEqual(@as(usize, 1), pattern.len);

    // What a request that matched no route asks: against the real path.
    const real = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/orgs/acme/members");
    defer testing.allocator.free(real);
    try testing.expectEqual(@as(usize, 1), real.len);

    // A param matches one segment, not the rest of the path.
    const elsewhere = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/teams/acme/members");
    defer testing.allocator.free(elsewhere);
    try testing.expectEqual(@as(usize, 0), elsewhere.len);

    // Too short to be under it at all.
    const short = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/orgs");
    defer testing.allocator.free(short);
    try testing.expectEqual(@as(usize, 0), short.len);
}

test "a middleware a route carries runs inside the ones scoped over it" {
    // The order the nesting means: the group's guard has already run by the
    // time the route's own guard does (ADR 0126).
    const scoped = [_]Scoped{.{ .prefix = "", .middleware = markA }};
    const attached = [_]Attached{.{ .pattern = "/v1/orders", .method = .POST, .middleware = markB }};

    const both = try chainFor(testing.allocator, &scoped, &.{}, &attached, .POST, "/v1/orders");
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

    const itself = try chainFor(testing.allocator, &.{}, &.{}, &attached, .POST, "/v1/orders");
    defer testing.allocator.free(itself);
    try testing.expectEqual(@as(usize, 1), itself.len);

    // A route underneath it is a different route.
    const under = try chainFor(testing.allocator, &.{}, &.{}, &attached, .POST, "/v1/orders/:id");
    defer testing.allocator.free(under);
    try testing.expectEqual(@as(usize, 0), under.len);

    // And one that merely begins with the same letters is not it either.
    const alike = try chainFor(testing.allocator, &.{}, &.{}, &attached, .POST, "/v1/orders-archive");
    defer testing.allocator.free(alike);
    try testing.expectEqual(@as(usize, 0), alike.len);
}

test "an attached middleware covers one verb on its path, not every verb" {
    // `with(adminOnly).delete("/users/:id", …)` must not put `adminOnly` on
    // the `GET` that reads the same path. They are two routes (ADR 0126).
    const attached = [_]Attached{.{ .pattern = "/users/:id", .method = .DELETE, .middleware = markA }};

    const removing = try chainFor(testing.allocator, &.{}, &.{}, &attached, .DELETE, "/users/:id");
    defer testing.allocator.free(removing);
    try testing.expectEqual(@as(usize, 1), removing.len);

    const reading = try chainFor(testing.allocator, &.{}, &.{}, &attached, .GET, "/users/:id");
    defer testing.allocator.free(reading);
    try testing.expectEqual(@as(usize, 0), reading.len);
}

test "an exemption frees one verb on its path, not every verb" {
    // The same distinction, in the direction `without` goes — and it was
    // missing until `with` needed it: a `GET` registered on the path of an
    // excused `POST` was excused too.
    const scoped = [_]Scoped{.{ .prefix = "", .middleware = markA }};
    const exemptions = [_]Exemption{.{ .pattern = "/sign-up", .method = .POST, .middleware = markA }};

    const posting = try chainFor(testing.allocator, &scoped, &exemptions, &.{}, .POST, "/sign-up");
    defer testing.allocator.free(posting);
    try testing.expectEqual(@as(usize, 0), posting.len);

    const getting = try chainFor(testing.allocator, &scoped, &exemptions, &.{}, .GET, "/sign-up");
    defer testing.allocator.free(getting);
    try testing.expectEqual(@as(usize, 1), getting.len);
}

test "registration order is the run order, prefix or not" {
    const scoped = [_]Scoped{
        .{ .prefix = "/api", .middleware = markB },
        .{ .prefix = "", .middleware = markA },
    };
    const chain = try chainFor(testing.allocator, &scoped, &.{}, &.{}, .GET, "/api/x");
    defer testing.allocator.free(chain);
    try testing.expect(chain[0] == markB);
    try testing.expect(chain[1] == markA);
}
