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
        return self.prefix.len == 0 or std.mem.startsWith(u8, path, self.prefix);
    }
};

/// The chain for `path`, in registration order. The caller owns the
/// result. Resolved once per route at `listen()`; for a request that
/// matched no route this runs per request, which is fine because that is
/// the cold path.
pub fn chainFor(
    gpa: std.mem.Allocator,
    scoped: []const Scoped,
    path: []const u8,
) ![]const Middleware {
    var n: usize = 0;
    for (scoped) |s| {
        if (s.covers(path)) n += 1;
    }
    if (n == 0) return &.{};

    const chain = try gpa.alloc(Middleware, n);
    var i: usize = 0;
    for (scoped) |s| {
        if (!s.covers(path)) continue;
        chain[i] = s.middleware;
        i += 1;
    }
    return chain;
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

    const on_api = try chainFor(testing.allocator, &scoped, "/api/users/:id");
    defer testing.allocator.free(on_api);
    try testing.expectEqual(@as(usize, 2), on_api.len);

    const off_api = try chainFor(testing.allocator, &scoped, "/health");
    defer testing.allocator.free(off_api);
    try testing.expectEqual(@as(usize, 1), off_api.len);
    try testing.expect(off_api[0] == markA);
}

test "registration order is the run order, prefix or not" {
    const scoped = [_]Scoped{
        .{ .prefix = "/api", .middleware = markB },
        .{ .prefix = "", .middleware = markA },
    };
    const chain = try chainFor(testing.allocator, &scoped, "/api/x");
    defer testing.allocator.free(chain);
    try testing.expect(chain[0] == markB);
    try testing.expect(chain[1] == markA);
}
