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

/// The name a `*` catch-all is captured under, so `c.param("*")` reaches
/// it. A typed handler takes it as a positional `Str` like any other.
pub const wildcard = "*";

/// One piece of a pattern between slashes: literal text to match, the name
/// of a param to capture, or a `*` that swallows the rest of the path.
pub const Segment = struct {
    text: []const u8,
    kind: Kind,

    pub const Kind = enum { literal, param, wildcard };
};

pub const Route = struct {
    method: http1.Method,
    pattern: []const u8,
    handler: CtxHandler,
    chain: []const Middleware = &.{},
    /// `pattern`, split up once at registration. Owned by the Router.
    segments: []const Segment,

    /// All three worked out once at registration, so matching reads fields
    /// instead of walking the segments again.
    score: u32 = 0,
    /// Whether the last segment is a `*`, which makes the segment count a
    /// minimum rather than an equality.
    wildcard_tail: bool = false,
    /// A route of nothing but literals is the most specific thing that can
    /// match a path of its length, so finding one ends the scan.
    all_literal: bool = false,

    /// How specific this route is, so that `/users/new` wins over
    /// `/users/:id` no matter which was registered first — the same
    /// order-independence `use` and `get` already have (ADR 0009).
    ///
    /// Two bits per segment, most significant first: a literal beats a
    /// param beats a `*`, and an earlier segment outranks every later one.
    /// `max_segments` is 16, so the whole ranking fits in a u32.
    fn specificity(segments: []const Segment) u32 {
        var score: u32 = 0;
        for (segments) |seg| {
            score = score * 4 + switch (seg.kind) {
                .literal => @as(u32, 3),
                .param => 2,
                .wildcard => 1,
            };
        }
        return score;
    }

    /// Whether two patterns match exactly the same set of paths, which
    /// makes one of them dead code.
    fn sameShape(a: []const Segment, b: []const Segment) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (x.kind != y.kind) return false;
            if (x.kind == .literal and !std.mem.eql(u8, x.text, y.text)) return false;
        }
        return true;
    }
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
    ///
    /// A pattern that makes no sense is caught while compiling, by
    /// `validatePattern` — every route registered through `App` goes
    /// through it first, so the asserts here are internal invariants
    /// rather than the user's error message.
    pub fn add(self: *Router, method: http1.Method, pattern: []const u8, handler: CtxHandler) !void {
        std.debug.assert(pattern.len > 0 and pattern[0] == '/');
        std.debug.assert(std.mem.count(u8, pattern, ":") <= max_params);

        var buf: [max_segments][]const u8 = undefined;
        const parts = split(trimSlashes(pattern), &buf) orelse {
            std.debug.panic(
                "zfast: the route \"{s}\" has more than {d} segments",
                .{ pattern, max_segments },
            );
        };

        const segments = try self.gpa.alloc(Segment, parts.len);
        errdefer self.gpa.free(segments);
        for (segments, parts) |*seg, part| {
            if (std.mem.eql(u8, part, wildcard)) {
                seg.* = .{ .text = wildcard, .kind = .wildcard };
            } else if (part.len > 0 and part[0] == ':') {
                seg.* = .{ .text = part[1..], .kind = .param };
            } else {
                seg.* = .{ .text = part, .kind = .literal };
            }
        }

        // A second route matching exactly the same paths is dead code, and
        // silently dropping it is how an afternoon disappears. Param names
        // are not part of the shape: `/users/:id` and `/users/:name` answer
        // the same requests, so they collide too.
        for (self.routes.items) |existing| {
            if (existing.method != method) continue;
            if (Route.sameShape(existing.segments, segments)) return error.DuplicateRoute;
        }

        const tail_is_wildcard = segments.len > 0 and segments[segments.len - 1].kind == .wildcard;
        var literal_only = true;
        for (segments) |seg| {
            if (seg.kind != .literal) literal_only = false;
        }

        try self.routes.append(self.gpa, .{
            .method = method,
            .pattern = pattern,
            .handler = handler,
            .segments = segments,
            .score = Route.specificity(segments),
            .wildcard_tail = tail_is_wildcard,
            .all_literal = literal_only,
        });
    }

    /// The pattern already registered that `pattern` would collide with, if
    /// there is one. Kept separate from `add` so the error can be reported
    /// by whoever is closer to the user — `App` names both patterns, this
    /// only finds them.
    pub fn conflicting(self: *const Router, method: http1.Method, pattern: []const u8) ?[]const u8 {
        var buf: [max_segments][]const u8 = undefined;
        const parts = split(trimSlashes(pattern), &buf) orelse return null;

        for (self.routes.items) |existing| {
            if (existing.method != method) continue;
            if (existing.segments.len != parts.len) continue;
            const same = for (existing.segments, parts) |seg, part| {
                const kind: Segment.Kind = if (std.mem.eql(u8, part, wildcard))
                    .wildcard
                else if (part.len > 1 and part[0] == ':')
                    .param
                else
                    .literal;
                if (seg.kind != kind) break false;
                if (kind == .literal and !std.mem.eql(u8, seg.text, part)) break false;
            } else true;
            if (same) return existing.pattern;
        }
        return null;
    }

    pub fn match(self: *const Router, method: http1.Method, path: []const u8) ?Match {
        var buf: [max_segments][]const u8 = undefined;
        const trimmed = trimSlashes(path);
        const parts = split(trimmed, &buf) orelse return null;

        if (self.matchExact(method, trimmed, parts)) |m| return m;
        // A HEAD nobody registered is answered by the GET route: the head of
        // a HEAD response has to be what a GET would have sent anyway, and
        // the body is dropped on the way out (Ctx.send). Making people
        // register both would mean every health check and every link
        // checker gets a 404 from a route that plainly exists.
        if (method == .HEAD) return self.matchExact(.GET, trimmed, parts);
        return null;
    }

    /// The best match, not the first one. `/users/new` and `/users/:id` can
    /// both answer `/users/new`; the literal is what the person who wrote
    /// them meant, whichever order they happened to be registered in.
    ///
    /// Deciding first and capturing afterwards, rather than capturing into
    /// a running best: a `Match` carries room for eight params and is a few
    /// hundred bytes, so copying one per candidate cost more than the
    /// second walk over a handful of short segments does.
    fn matchExact(
        self: *const Router,
        method: http1.Method,
        trimmed: []const u8,
        parts: []const []const u8,
    ) ?Match {
        var result: Match = undefined;
        var have = false;
        var best_score: u32 = 0;

        for (self.routes.items) |*route| {
            // Two integer compares throw out nearly every route before any
            // text is looked at.
            if (route.method != method) continue;
            if (route.wildcard_tail) {
                // The `*` stands in for zero or more segments, so its own
                // slot is the only one that need not be there.
                if (parts.len + 1 < route.segments.len) continue;
            } else if (route.segments.len != parts.len) continue;

            // With something already captured, a route that cannot outrank
            // it is not worth testing — and one that can has to be tested
            // before it may write, since a half-filled failure would land
            // on top of the winner. Both are the uncommon path: almost
            // every request has exactly one route that matches it, and that
            // one is filled in a single pass, as it always was.
            if (have) {
                if (route.score <= best_score) continue;
                if (!matches(route, parts)) continue;
            }

            result = .{ .handler = route.handler, .chain = route.chain };
            if (!fill(route, trimmed, parts, &result)) continue;
            have = true;
            best_score = route.score;

            // Nothing can outrank a route made only of literals, and `add`
            // has already refused a second one of the same shape — so a
            // static route still stops the scan where it always did.
            if (route.all_literal) return result;
        }
        return if (have) result else null;
    }

    /// The segments that have to line up with a path segment each — every
    /// one but a trailing `*`, which stands for however many are left.
    /// Splitting it out this way keeps the loop below down to the two cases
    /// it had before catch-alls existed: this is the hottest loop in the
    /// router, and a third case in it was worth 30% of route matching.
    fn fixedSegments(route: *const Route) []const Segment {
        return if (route.wildcard_tail)
            route.segments[0 .. route.segments.len - 1]
        else
            route.segments;
    }

    /// Whether this route answers this path, without writing anything down.
    /// Only needed when a captured match is already in hand.
    fn matches(route: *const Route, parts: []const []const u8) bool {
        const segments = fixedSegments(route);
        for (segments, parts[0..segments.len]) |seg, part| {
            if (seg.kind == .param) {
                if (part.len == 0) return false; // an empty segment fills nothing
            } else if (!std.mem.eql(u8, seg.text, part)) {
                return false;
            }
        }
        return true;
    }

    fn fill(
        route: *const Route,
        trimmed: []const u8,
        parts: []const []const u8,
        result: *Match,
    ) bool {
        const segments = fixedSegments(route);
        for (segments, parts[0..segments.len]) |seg, part| {
            if (seg.kind == .param) {
                if (part.len == 0) return false; // an empty segment fills nothing
                result.params[result.n_params] = .{ .name = seg.text, .value = part };
                result.n_params += 1;
            } else if (!std.mem.eql(u8, seg.text, part)) {
                return false;
            }
        }

        if (route.wildcard_tail) {
            // Whatever is left of the path, slashes and all.
            const rest = if (segments.len < parts.len)
                trimmed[@intFromPtr(parts[segments.len].ptr) - @intFromPtr(trimmed.ptr) ..]
            else
                trimmed[trimmed.len..];
            result.params[result.n_params] = .{ .name = wildcard, .value = rest };
            result.n_params += 1;
        }
        return true;
    }
};

/// Everything that can be wrong with a route pattern, said while
/// compiling. `App` calls this before handing the pattern to `add`, so a
/// typo like `app.get("users", …)` is a build error naming the route
/// instead of an `unreachable` at startup.
pub fn validatePattern(comptime pattern: []const u8) void {
    comptime {
        if (pattern.len == 0) @compileError(
            "zfast: a route pattern cannot be empty.\n" ++
                "  The path a browser asks for always starts with a slash, so the pattern does " ++
                "too: \"/\" for the root.",
        );
        if (pattern[0] != '/') @compileError(
            "zfast: the route pattern \"" ++ pattern ++ "\" does not start with a slash.\n" ++
                "  Write \"/" ++ pattern ++ "\" — patterns are matched against the path as it " ++
                "arrives, and that always begins with one.",
        );

        var names: []const []const u8 = &.{};
        var n_segments: usize = 0;
        var n_params: usize = 0;
        var wildcard_at: ?usize = null;

        var it = std.mem.splitScalar(u8, trimSlashes(pattern), '/');
        while (it.next()) |seg| : (n_segments += 1) {
            if (wildcard_at != null) @compileError(
                "zfast: the route pattern \"" ++ pattern ++ "\" has a `*` that is not the last " ++
                    "segment.\n" ++
                    "  A `*` swallows the whole rest of the path, so nothing after it could ever " ++
                    "match. Move it to the end, or use `:name` for a single segment.",
            );

            if (std.mem.eql(u8, seg, wildcard)) {
                wildcard_at = n_segments;
                n_params += 1;
                names = names ++ [_][]const u8{wildcard};
                continue;
            }
            if (std.mem.indexOfScalar(u8, seg, '*') != null) @compileError(
                "zfast: the segment \"" ++ seg ++ "\" of route \"" ++ pattern ++ "\" mixes `*` " ++
                    "with other text.\n" ++
                    "  A catch-all is a segment of its own: \"/files/*\", not \"/files/" ++ seg ++
                    "\".",
            );

            if (seg.len > 0 and seg[0] == ':') {
                if (seg.len == 1) @compileError(
                    "zfast: the route pattern \"" ++ pattern ++ "\" has a `:` with no name after " ++
                        "it.\n" ++
                        "  A path param is written `:name` — the name is what `c.param(\"name\")` " ++
                        "looks up.",
                );
                for (names) |taken| {
                    if (std.mem.eql(u8, taken, seg[1..])) @compileError(
                        "zfast: the route pattern \"" ++ pattern ++ "\" uses the param name `:" ++
                            seg[1..] ++ "` twice.\n" ++
                            "  `c.param(\"" ++ seg[1..] ++ "\")` could only ever return the first " ++
                            "one. Give them different names.",
                    );
                }
                names = names ++ [_][]const u8{seg[1..]};
                n_params += 1;
                continue;
            }

            if (std.mem.indexOfScalar(u8, seg, ':') != null) @compileError(
                "zfast: the segment \"" ++ seg ++ "\" of route \"" ++ pattern ++ "\" has a `:` " ++
                    "in the middle of it, so it is matched as literal text.\n" ++
                    "  A path param takes the whole segment: \"/users/:id\", not \"/users/id:" ++
                    "\". If the colon really is part of the path, this is already correct — " ++
                    "nothing else to do.",
            );
        }

        if (n_segments > max_segments) @compileError(
            "zfast: the route pattern \"" ++ pattern ++ "\" has " ++ num(n_segments) ++
                " segments, and the most zfast matches is " ++ num(max_segments) ++ ".\n" ++
                "  A path this deep is usually a `*` catch-all waiting to happen: " ++
                "\"/files/*\" hands the rest to the handler as `c.param(\"*\")`.",
        );
        if (n_params > max_params) @compileError(
            "zfast: the route pattern \"" ++ pattern ++ "\" captures " ++ num(n_params) ++
                " params, and the most zfast holds is " ++ num(max_params) ++ ".\n" ++
                "  Fold the extra ones into the request body or the query string.",
        );
    }
}

fn num(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

/// "/a/b/" and "/a/b" come out the same, so a trailing slash is not a
/// different route.
fn trimSlashes(path: []const u8) []const u8 {
    var s = path;
    if (s.len > 0 and s[0] == '/') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    return s;
}

/// Split an already-trimmed path or pattern on "/", into a buffer rather
/// than onto the heap. Null when there are more segments than fit — for a
/// request path that simply means nothing matches.
fn split(trimmed: []const u8, out: *[max_segments][]const u8) ?[][]const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed, '/');
    while (it.next()) |part| {
        if (n == max_segments) return null;
        out[n] = part;
        n += 1;
    }
    return out[0..n];
}

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

test "the most specific route wins, in either registration order" {
    for ([_]bool{ false, true }) |literal_first| {
        var r = Router.init(testing.allocator);
        defer r.deinit();
        if (literal_first) {
            try r.add(.GET, "/users/me", testHandler);
            try r.add(.GET, "/users/:id", otherHandler);
        } else {
            try r.add(.GET, "/users/:id", otherHandler);
            try r.add(.GET, "/users/me", testHandler);
        }

        try testing.expect(r.match(.GET, "/users/me").?.handler == &testHandler);
        try testing.expect(r.match(.GET, "/users/42").?.handler == &otherHandler);
    }
}

test "a param beats a catch-all, and a literal beats both" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    // Registered least specific first, so order cannot be what decides it.
    try r.add(.GET, "/files/*", testHandler);
    try r.add(.GET, "/files/:name", otherHandler);
    try r.add(.GET, "/files/readme", testHandler);

    try testing.expect(r.match(.GET, "/files/readme").?.handler == &testHandler);
    try testing.expect(r.match(.GET, "/files/other").?.handler == &otherHandler);
    // Two segments is more than `:name` can take, so only the `*` is left.
    try testing.expect(r.match(.GET, "/files/a/b").?.handler == &testHandler);
}

test "a catch-all captures the rest of the path, slashes and all" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/files/*", testHandler);

    const deep = r.match(.GET, "/files/css/site.css").?;
    try testing.expectEqual(@as(usize, 1), deep.n_params);
    try testing.expectEqualStrings("*", deep.params[0].name);
    try testing.expectEqualStrings("css/site.css", deep.params[0].value);

    try testing.expectEqualStrings("one", r.match(.GET, "/files/one").?.params[0].value);
    // A `*` standing for nothing at all still matches, with an empty value.
    try testing.expectEqualStrings("", r.match(.GET, "/files").?.params[0].value);
    try testing.expectEqualStrings("", r.match(.GET, "/files/").?.params[0].value);
    try testing.expect(r.match(.GET, "/other") == null);
}

test "a root catch-all answers everything, and loses to every real route" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/*", testHandler);
    try r.add(.GET, "/health", otherHandler);

    try testing.expect(r.match(.GET, "/health").?.handler == &otherHandler);
    try testing.expect(r.match(.GET, "/anything/at/all").?.handler == &testHandler);
    try testing.expectEqualStrings("anything/at/all", r.match(.GET, "/anything/at/all").?.params[0].value);
}

test "the same route twice is refused rather than silently dropped" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/users/:id", testHandler);
    try r.add(.GET, "/files/*", testHandler);

    try testing.expectError(error.DuplicateRoute, r.add(.GET, "/users/:id", otherHandler));
    // Param names are not part of the shape: these answer the same requests.
    try testing.expectError(error.DuplicateRoute, r.add(.GET, "/users/:name", otherHandler));
    try testing.expectError(error.DuplicateRoute, r.add(.GET, "/files/*", otherHandler));

    // A different method, a different literal, or a param where the other
    // has a catch-all, is a different route.
    try r.add(.POST, "/users/:id", otherHandler);
    try r.add(.GET, "/users/me", otherHandler);
    try r.add(.GET, "/files/:name", otherHandler);

    try testing.expect(r.match(.GET, "/users/7").?.handler == &testHandler);
}

test "conflicting names the pattern that is already there" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/users/:id", testHandler);

    try testing.expectEqualStrings("/users/:id", r.conflicting(.GET, "/users/:name").?);
    try testing.expectEqualStrings("/users/:id", r.conflicting(.GET, "/users/:id/").?);
    try testing.expect(r.conflicting(.POST, "/users/:id") == null);
    try testing.expect(r.conflicting(.GET, "/users/me") == null);
    try testing.expect(r.conflicting(.GET, "/users/*") == null);
    try testing.expect(r.conflicting(.GET, "/users") == null);
}
