//! Router: matches method + path to a handler, with `/users/:id` style
//! path params.
//!
//! Still a linear scan over the routes — which one to use instead gets
//! decided with numbers, and there are none yet (docs/plan.md, "Still
//! open"). What the scan costs, though, does not need numbers to reason
//! about, and it used to cost too much: every route re-split the request
//! path from scratch, so fifty routes meant fifty passes over it.
//!
//! Now the patterns are split once when they are registered and the path
//! once per request. A route whose segment count differs is rejected on an
//! integer compare, which is nearly all of them. The scan is still linear
//! in the number of routes; it is no longer linear in their number times
//! the length of the path.

const std = @import("std");
const http1 = @import("http1.zig");
const middleware = @import("middleware.zig");
const Ctx = @import("ctx.zig").Ctx;

pub const CtxHandler = middleware.CtxHandler;
pub const Middleware = middleware.Middleware;

pub const max_params = 8;

/// The most segments a path can have. A request path with more is matched
/// by nothing, which is the right answer anyway: no pattern can have more
/// either, and `add` refuses one that does.
pub const max_segments = 16;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const Match = struct {
    handler: CtxHandler,
    /// The middleware wrapping this route, resolved once at `listen()`.
    chain: []const Middleware = &.{},
    params: [max_params]Param = undefined,
    n_params: usize = 0,
};

/// One piece of a pattern between slashes: either literal text to match,
/// or the name of a param to capture.
pub const Segment = struct {
    text: []const u8,
    is_param: bool,
};

pub const Route = struct {
    method: http1.Method,
    pattern: []const u8,
    handler: CtxHandler,
    chain: []const Middleware = &.{},
    /// `pattern`, split up once at registration. Owned by the Router.
    segments: []const Segment,
};

pub const Router = struct {
    gpa: std.mem.Allocator,
    routes: std.ArrayList(Route) = .empty,

    pub fn init(gpa: std.mem.Allocator) Router {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |r| self.gpa.free(r.segments);
        self.routes.deinit(self.gpa);
    }

    /// `pattern` must outlive the Router (normally a literal).
    pub fn add(self: *Router, method: http1.Method, pattern: []const u8, handler: CtxHandler) !void {
        std.debug.assert(pattern.len > 0 and pattern[0] == '/');
        std.debug.assert(std.mem.count(u8, pattern, ":") <= max_params);

        var buf: [max_segments][]const u8 = undefined;
        const parts = split(pattern, &buf) orelse {
            std.debug.panic(
                "zfast: the route \"{s}\" has more than {d} segments",
                .{ pattern, max_segments },
            );
        };

        const segments = try self.gpa.alloc(Segment, parts.len);
        errdefer self.gpa.free(segments);
        for (segments, parts) |*seg, part| {
            const is_param = part.len > 0 and part[0] == ':';
            seg.* = .{ .text = if (is_param) part[1..] else part, .is_param = is_param };
        }

        try self.routes.append(self.gpa, .{
            .method = method,
            .pattern = pattern,
            .handler = handler,
            .segments = segments,
        });
    }

    pub fn match(self: *const Router, method: http1.Method, path: []const u8) ?Match {
        var buf: [max_segments][]const u8 = undefined;
        const parts = split(path, &buf) orelse return null;

        if (self.matchExact(method, parts)) |m| return m;
        // A HEAD nobody registered is answered by the GET route: the head of
        // a HEAD response has to be what a GET would have sent anyway, and
        // the body is dropped on the way out (Ctx.send). Making people
        // register both would mean every health check and every link
        // checker gets a 404 from a route that plainly exists.
        if (method == .HEAD) return self.matchExact(.GET, parts);
        return null;
    }

    fn matchExact(self: *const Router, method: http1.Method, parts: []const []const u8) ?Match {
        for (self.routes.items) |route| {
            // Two integer compares throw out nearly every route before any
            // text is looked at.
            if (route.method != method) continue;
            if (route.segments.len != parts.len) continue;

            var result = Match{ .handler = route.handler, .chain = route.chain };
            if (fill(route.segments, parts, &result)) return result;
        }
        return null;
    }

    fn fill(segments: []const Segment, parts: []const []const u8, result: *Match) bool {
        for (segments, parts) |seg, part| {
            if (seg.is_param) {
                if (part.len == 0) return false; // an empty segment fills nothing
                result.params[result.n_params] = .{ .name = seg.text, .value = part };
                result.n_params += 1;
            } else if (!std.mem.eql(u8, seg.text, part)) {
                return false;
            }
        }
        return true;
    }

    /// Split a path or pattern on "/", into a buffer rather than onto the
    /// heap. Null when there are more segments than fit — for a request
    /// path that simply means nothing matches.
    ///
    /// "/a/b/" and "/a/b" come out the same, so a trailing slash is not a
    /// different route.
    fn split(path: []const u8, out: *[max_segments][]const u8) ?[][]const u8 {
        var s = path;
        if (s.len > 0 and s[0] == '/') s = s[1..];
        if (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];

        var n: usize = 0;
        var it = std.mem.splitScalar(u8, s, '/');
        while (it.next()) |part| {
            if (n == max_segments) return null;
            out[n] = part;
            n += 1;
        }
        return out[0..n];
    }
};

const testing = std.testing;

fn testHandler(_: *Ctx) anyerror!void {}
fn otherHandler(_: *Ctx) anyerror!void {}

test "static routes and methods" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/health", testHandler);

    try testing.expect(r.match(.GET, "/health") != null);
    try testing.expect(r.match(.POST, "/health") == null);
    try testing.expect(r.match(.GET, "/other") == null);
    try testing.expect(r.match(.GET, "/health/") != null);
}

test "path params are captured" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/users/:id", testHandler);
    try r.add(.GET, "/users/:id/posts/:post", otherHandler);

    const m = r.match(.GET, "/users/42").?;
    try testing.expectEqual(@as(usize, 1), m.n_params);
    try testing.expectEqualStrings("id", m.params[0].name);
    try testing.expectEqualStrings("42", m.params[0].value);

    const m2 = r.match(.GET, "/users/7/posts/99").?;
    try testing.expectEqual(@as(usize, 2), m2.n_params);
    try testing.expectEqualStrings("99", m2.params[1].value);
    try testing.expect(m2.handler == &otherHandler);

    try testing.expect(r.match(.GET, "/users") == null);
    try testing.expect(r.match(.GET, "/users/42/posts") == null);
    try testing.expect(r.match(.GET, "/users//posts/9") == null);
}

test "HEAD falls back to the GET route, and an explicit one still wins" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/page", testHandler);

    try testing.expect(r.match(.HEAD, "/page").?.handler == &testHandler);
    try testing.expect(r.match(.HEAD, "/absent") == null);
    // The fallback never reaches for anything but GET.
    try testing.expect(r.match(.POST, "/page") == null);

    try r.add(.HEAD, "/page", otherHandler);
    try testing.expect(r.match(.HEAD, "/page").?.handler == &otherHandler);
}

/// The matcher exactly as it was before patterns were split up front:
/// both the pattern and the path re-split for every route tried. Kept so
/// the rewrite can be held against it, since a router that is faster and
/// subtly different is worse than a slow one.
fn matchTheOldWay(r: *const Router, method: http1.Method, path: []const u8) ?Match {
    const trim = struct {
        fn slashes(p: []const u8) []const u8 {
            var s = p;
            if (s.len > 0 and s[0] == '/') s = s[1..];
            if (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
            return s;
        }
    }.slashes;

    for (r.routes.items) |route| {
        if (route.method != method) continue;
        var result = Match{ .handler = route.handler, .chain = route.chain };

        var pat_segs = std.mem.splitScalar(u8, trim(route.pattern), '/');
        var path_segs = std.mem.splitScalar(u8, trim(path), '/');
        const matched = while (true) {
            const p = pat_segs.next();
            const s = path_segs.next();
            if (p == null and s == null) break true;
            if (p == null or s == null) break false;
            if (p.?.len > 0 and p.?[0] == ':') {
                if (s.?.len == 0) break false;
                result.params[result.n_params] = .{ .name = p.?[1..], .value = s.? };
                result.n_params += 1;
            } else if (!std.mem.eql(u8, p.?, s.?)) {
                break false;
            }
        } else false;

        if (matched) return result;
    }
    return null;
}

test "the rewritten matcher agrees with the one it replaced, path for path" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    const patterns = [_][]const u8{
        "/",                      "/health",
        "/users",                 "/users/me",
        "/users/:id",             "/users/:id/posts",
        "/users/:id/posts/:post", "/a/b/c/d/e",
        "/files/:name",           "/api/v1/things/:id/parts/:part",
    };
    for (patterns) |p| try r.add(.GET, p, testHandler);
    try r.add(.POST, "/users", otherHandler);

    const paths = [_][]const u8{
        "/",                        "",
        "/health",                  "/health/",
        "/users",                   "/users/",
        "/users/me",                "/users/42",
        "/users/42/",               "/users//posts",
        "/users/42/posts",          "/users/42/posts/9",
        "/users/42/posts/9/extra",  "/a/b/c/d/e",
        "/a/b/c/d",                 "/files/a%2Fb",
        "/files/",                  "//",
        "/api/v1/things/7/parts/3", "/nope",
        "/api/v1/things//parts/3",
    };

    for ([_]http1.Method{ .GET, .POST, .HEAD, .DELETE }) |method| {
        for (paths) |path| {
            const now = r.match(method, path);
            // HEAD is new behaviour the old matcher never had, so it is
            // compared against what the old one would say for GET.
            const before = matchTheOldWay(&r, if (method == .HEAD) .GET else method, path);

            if (before == null) {
                try testing.expect(now == null);
                continue;
            }
            try testing.expect(now != null);
            try testing.expect(now.?.handler == before.?.handler);
            try testing.expectEqual(before.?.n_params, now.?.n_params);
            for (0..before.?.n_params) |i| {
                try testing.expectEqualStrings(before.?.params[i].name, now.?.params[i].name);
                try testing.expectEqualStrings(before.?.params[i].value, now.?.params[i].value);
            }
        }
    }
}

test "a path with more segments than any route can have matches nothing" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/a", testHandler);

    var deep: [max_segments * 2][]const u8 = undefined;
    for (&deep) |*seg| seg.* = "/x";
    const path = try std.mem.concat(testing.allocator, u8, &deep);
    defer testing.allocator.free(path);

    try testing.expect(r.match(.GET, path) == null);
}

test "the first matching route wins" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/users/me", testHandler);
    try r.add(.GET, "/users/:id", otherHandler);

    try testing.expect(r.match(.GET, "/users/me").?.handler == &testHandler);
    try testing.expect(r.match(.GET, "/users/42").?.handler == &otherHandler);
}
