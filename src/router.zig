//! Router: matches method + path to a handler, with `/users/:id` style
//! path params.
//!
//! The algorithm is a linear scan over the routes, segment by segment.
//! That is deliberate: the router algorithm is invisible to users and
//! gets decided with numbers later (docs/plan.md, "Still open").

const std = @import("std");
const http1 = @import("http1.zig");
const Ctx = @import("ctx.zig").Ctx;

pub const CtxHandler = *const fn (*Ctx) anyerror!void;

pub const max_params = 8;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const Match = struct {
    handler: CtxHandler,
    params: [max_params]Param = undefined,
    n_params: usize = 0,
};

const Route = struct {
    method: http1.Method,
    pattern: []const u8,
    handler: CtxHandler,
};

pub const Router = struct {
    gpa: std.mem.Allocator,
    routes: std.ArrayList(Route) = .empty,

    pub fn init(gpa: std.mem.Allocator) Router {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.gpa);
    }

    /// `pattern` must outlive the Router (normally a literal).
    pub fn add(self: *Router, method: http1.Method, pattern: []const u8, handler: CtxHandler) !void {
        std.debug.assert(pattern.len > 0 and pattern[0] == '/');
        std.debug.assert(std.mem.count(u8, pattern, ":") <= max_params);
        try self.routes.append(self.gpa, .{ .method = method, .pattern = pattern, .handler = handler });
    }

    pub fn match(self: *const Router, method: http1.Method, path: []const u8) ?Match {
        for (self.routes.items) |route| {
            if (route.method != method) continue;
            var result = Match{ .handler = route.handler };
            if (matchPattern(route.pattern, path, &result)) return result;
        }
        return null;
    }

    fn matchPattern(pattern: []const u8, path: []const u8, result: *Match) bool {
        var pat_segs = std.mem.splitScalar(u8, trimSlashes(pattern), '/');
        var path_segs = std.mem.splitScalar(u8, trimSlashes(path), '/');

        while (true) {
            const p = pat_segs.next();
            const s = path_segs.next();
            if (p == null and s == null) return true;
            if (p == null or s == null) return false;

            if (p.?.len > 0 and p.?[0] == ':') {
                if (s.?.len == 0) return false;
                result.params[result.n_params] = .{ .name = p.?[1..], .value = s.? };
                result.n_params += 1;
            } else if (!std.mem.eql(u8, p.?, s.?)) {
                return false;
            }
        }
    }

    /// "/a/b/" and "/a/b" count as the same path.
    fn trimSlashes(path: []const u8) []const u8 {
        var s = path;
        if (s.len > 0 and s[0] == '/') s = s[1..];
        if (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
        return s;
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

test "the first matching route wins" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/users/me", testHandler);
    try r.add(.GET, "/users/:id", otherHandler);

    try testing.expect(r.match(.GET, "/users/me").?.handler == &testHandler);
    try testing.expect(r.match(.GET, "/users/42").?.handler == &otherHandler);
}
