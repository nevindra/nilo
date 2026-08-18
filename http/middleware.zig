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

/// The innermost layer: a plain Ctx handler. This is what the typed layer
/// compiles down to, and what the onion wraps.
pub const CtxHandler = *const fn (*Ctx) anyerror!void;

pub const Middleware = *const fn (*Ctx, Next) anyerror!void;

/// The rest of the onion. Two words, passed by value, allocating nothing.
pub const Next = struct {
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
    middleware: Middleware,

    fn frees(self: Exemption, path: []const u8, middleware: Middleware) bool {
        return self.middleware == middleware and std.mem.eql(u8, self.pattern, path);
    }
};

/// The chain for `path`, in registration order. The caller owns the
/// result. Resolved once per route at `listen()`; for a request that
/// matched no route this runs per request, which is fine because that is
/// the cold path.
pub fn chainFor(
    gpa: std.mem.Allocator,
    scoped: []const Scoped,
    exemptions: []const Exemption,
    path: []const u8,
) ![]const Middleware {
    var n: usize = 0;
    for (scoped) |s| {
        if (covered(s, exemptions, path)) n += 1;
    }
    if (n == 0) return &.{};

    const chain = try gpa.alloc(Middleware, n);
    var i: usize = 0;
    for (scoped) |s| {
        if (!covered(s, exemptions, path)) continue;
        chain[i] = s.middleware;
        i += 1;
    }
    return chain;
}

fn covered(s: Scoped, exemptions: []const Exemption, path: []const u8) bool {
    if (!s.covers(path)) return false;
    for (exemptions) |e| if (e.frees(path, s.middleware)) return false;
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

    const on_api = try chainFor(testing.allocator, &scoped, &.{}, "/api/users/:id");
    defer testing.allocator.free(on_api);
    try testing.expectEqual(@as(usize, 2), on_api.len);

    const off_api = try chainFor(testing.allocator, &scoped, &.{}, "/health");
    defer testing.allocator.free(off_api);
    try testing.expectEqual(@as(usize, 1), off_api.len);
    try testing.expect(off_api[0] == markA);
}

test "a prefix only covers whole segments" {
    const scoped = [_]Scoped{.{ .prefix = "/api", .middleware = markA }};

    const inside = try chainFor(testing.allocator, &scoped, &.{}, "/api/users");
    defer testing.allocator.free(inside);
    try testing.expectEqual(@as(usize, 1), inside.len);

    // The group's own path, with nothing under it.
    const itself = try chainFor(testing.allocator, &scoped, &.{}, "/api");
    defer testing.allocator.free(itself);
    try testing.expectEqual(@as(usize, 1), itself.len);

    // `startsWith` used to put this middleware on a route that merely began
    // with the same letters. `static.zig` had the right rule all along.
    const apiary = try chainFor(testing.allocator, &scoped, &.{}, "/apiary");
    defer testing.allocator.free(apiary);
    try testing.expectEqual(@as(usize, 0), apiary.len);
}

test "a prefix carrying a param covers a pattern and a real path alike" {
    const scoped = [_]Scoped{.{ .prefix = "/orgs/:org", .middleware = markA }};

    // What `listen()` asks: the chain for each route, against its pattern.
    const pattern = try chainFor(testing.allocator, &scoped, &.{}, "/orgs/:org/members");
    defer testing.allocator.free(pattern);
    try testing.expectEqual(@as(usize, 1), pattern.len);

    // What a request that matched no route asks: against the real path.
    const real = try chainFor(testing.allocator, &scoped, &.{}, "/orgs/acme/members");
    defer testing.allocator.free(real);
    try testing.expectEqual(@as(usize, 1), real.len);

    // A param matches one segment, not the rest of the path.
    const elsewhere = try chainFor(testing.allocator, &scoped, &.{}, "/teams/acme/members");
    defer testing.allocator.free(elsewhere);
    try testing.expectEqual(@as(usize, 0), elsewhere.len);

    // Too short to be under it at all.
    const short = try chainFor(testing.allocator, &scoped, &.{}, "/orgs");
    defer testing.allocator.free(short);
    try testing.expectEqual(@as(usize, 0), short.len);
}

test "registration order is the run order, prefix or not" {
    const scoped = [_]Scoped{
        .{ .prefix = "/api", .middleware = markB },
        .{ .prefix = "", .middleware = markA },
    };
    const chain = try chainFor(testing.allocator, &scoped, &.{}, "/api/x");
    defer testing.allocator.free(chain);
    try testing.expect(chain[0] == markB);
    try testing.expect(chain[1] == markA);
}
