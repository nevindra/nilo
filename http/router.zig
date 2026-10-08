//! Router: matches method + path to a handler, with `/users/:id` style
//! path params.
//!
//! A tree of segments, searched literal first, then param, then `*`, backing
//! out of a branch that dead-ends. That order is ADR 012's ranking itself: a
//! literal beats a param beats a `*`, and an earlier segment outranks every
//! later one, so the first route the search reaches is the most specific one
//! and there is no score to carry or compare.
//!
//! It replaced a linear scan over every route, which a real table decided:
//! 276 routes under one `/api` prefix cost 125ns a match, 35% of a request,
//! because a prefix every route shares is the one thing a scan's cheap
//! filters cannot see past (`bench/result/http.md`, "Matching on a real table
//! of 276 routes under one prefix"). The tree is built at registration; a
//! match allocates nothing and walks one node per segment, plus whatever it
//! has to back out of.

const std = @import("std");
const http1 = @import("http1.zig");
const mw = @import("middleware.zig");
const Ctx = @import("ctx.zig").Ctx;

pub const CtxHandler = mw.CtxHandler;
pub const Middleware = mw.Middleware;

pub const max_params = 8;

/// The most segments a pattern can have, and the most a request path is
/// split into. `add` refuses a pattern with more. A request path with more
/// is deeper than any fixed route, so only a `*` can answer it, and a `*`
/// needs no more than the segments before it (at most `max_segments - 1`,
/// since the `*` is one of the sixteen) to take the rest as text.
pub const max_segments = 16;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

/// The methods some route answers a given path with — what `allowedFor`
/// returns, and what an `Allow` header is written from.
pub const MethodSet = std.EnumSet(http1.Method);

pub const Match = struct {
    handler: CtxHandler,
    /// The middleware wrapping this route, resolved once at `listen()`.
    chain: []const Middleware = &.{},
    params: [max_params]Param = undefined,
    n_params: usize = 0,
    /// Where this route sits in `routes`, which is what metrics count
    /// against — an index the scan is already holding rather than the
    /// pattern, so counting a request needs no string and no hash
    /// (ADR 079).
    index: usize = 0,
};

/// The `Route.listeners` of a route bound to no listener in particular:
/// every bit, so a listener that was never named is answered.
pub const every_listener: u32 = std.math.maxInt(u32);

/// The `Route.listeners` word for the listeners numbered in `which`, which
/// is what `onListener` on an App or a group spells. Checked while
/// compiling: a route can be bound to listeners 0 to 31, and naming none
/// would be a route no listener answers (ADR 252).
pub fn listenerBits(comptime which: []const u8) u32 {
    comptime {
        if (which.len == 0) @compileError("nilo: `onListener` names no listener, so no listener would answer the route. Name at least one: `app.onListener(&.{1})`.");
        var bits: u32 = 0;
        for (which) |n| {
            if (n >= 32) @compileError("nilo: a route can be bound to listeners 0 to 31, and `onListener` was given a larger number.");
            bits |= @as(u32, 1) << @as(u5, @intCast(n));
        }
        return bits;
    }
}

/// Whether a route bound to `bound` answers on the listener numbered
/// `listener`. A listener past the 32nd is not one a route can be bound to,
/// so it answers only a route bound to none.
pub fn onListener(bound: u32, listener: u8) bool {
    if (bound == every_listener) return true;
    return listener < 32 and bound & (@as(u32, 1) << @as(u5, @intCast(listener))) != 0;
}

/// The name a `*` catch-all is captured under, so `c.param("*")` reaches
/// it. A typed handler takes it as a positional `Str` like any other.
pub const wildcard = "*";

/// One piece of a pattern between slashes: literal text to match, the name
/// of a param to capture, or a `*` that swallows the rest of the path.
pub const Segment = struct {
    text: []const u8,
    kind: Kind,

    pub const Kind = enum { literal, param, wildcard };

    /// What one piece of a pattern is, decided in the one place both
    /// callers read.
    ///
    /// `add` settles what a route *is* and `conflicting` settles whether
    /// two routes *collide*, and each used to classify a segment itself.
    /// The two copies had already drifted over a segment that is only a
    /// colon: `add` called `/a/:` a param with an empty name, `conflicting`
    /// called it the literal `":"` and so found no collision. What that
    /// cost was the error message rather than the route — `add` refuses a
    /// duplicate on its own — and `validatePattern` refuses the pattern
    /// while compiling anyway. What earned the fix is that one
    /// classification was living in two places, and the copy deciding what
    /// a route is had drifted from the copy deciding whether two collide.
    pub fn of(part: []const u8) Segment {
        if (std.mem.eql(u8, part, wildcard)) return .{ .text = wildcard, .kind = .wildcard };
        if (part.len > 0 and part[0] == ':') return .{ .text = part[1..], .kind = .param };
        return .{ .text = part, .kind = .literal };
    }
};

pub const Route = struct {
    method: http1.Method,
    /// Which listeners answer this route, one bit each (ADR 252). Every
    /// bit set, the default, is a route no listener is singled out for.
    listeners: u32 = every_listener,
    pattern: []const u8,
    handler: CtxHandler,
    chain: []const Middleware = &.{},
    /// A scoped middleware's prefix that the pattern alone cannot settle, a
    /// `:param` or `*` opposite one of its literal segments, so the chain is
    /// resolved per request from the real path rather than read from `chain`
    /// (`middleware.reach`). Set by `resolveChains`.
    chain_by_path: bool = false,
    /// The `operationId` — what `app.named` gave the route, or the name
    /// derived from the method and the pattern, exactly as the API
    /// description prints it. `Ctx.routeName` hands it to a middleware, which
    /// is what lets one authorisation table sit in front of every route
    /// ([ADR 162](../docs/adr/162-a-middleware-can-learn-which-route-it-is-in-front-of.md)).
    /// Owned by whoever registered the route; the Router only points at it.
    name: []const u8 = "",
    /// `pattern`, split up once at registration. Owned by the Router.
    segments: []const Segment,

    /// Whether the last segment is a `*`, which makes the segment count a
    /// minimum rather than an equality.
    wildcard_tail: bool = false,

    /// How specific a route is, as the scan this router replaced ranked it:
    /// two bits per segment, most significant first. Only the tests read it
    /// now, as the oracle the tree is held against on tables where the two
    /// agree (see `the tree agrees with the scan it replaced`).
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

    /// Four bytes standing for a path segment: its length, its first byte,
    /// its last byte and the one in the middle. What a node compares first
    /// when it looks for the literal child a segment names, so a
    /// `mem.eql` runs only where it can succeed.
    ///
    /// Not a hash, and deliberately not: a hash worth the name costs more
    /// than the `mem.eql` it is trying to avoid. This is four loads and
    /// three shifts. It has to tell apart the segments that actually sit
    /// side by side under one node, and those differ at the end (`users`
    /// and `uploads`) or in length far more often than nowhere at all. A
    /// collision costs the `mem.eql` and nothing else.
    fn firstKey(text: []const u8) u32 {
        if (text.len == 0) return 0;
        const len: u32 = @intCast(@min(text.len, 0xff));
        const head: u32 = text[0];
        const tail: u32 = text[text.len - 1];
        const middle: u32 = text[text.len / 2];
        return (len << 24) | (head << 16) | (tail << 8) | middle;
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
    /// The tree `match` searches; node 0 is the root once a route exists.
    /// Indices rather than pointers, because a node is appended while its
    /// parent is being extended.
    nodes: std.ArrayList(Node) = .empty,

    const none = std.math.maxInt(u32);
    const methods = @typeInfo(http1.Method).@"enum".fields.len;

    /// One place in the tree: the path matched so far, and where it can go.
    const Node = struct {
        /// The children a literal segment leads to. `keys` is `firstKey` of
        /// each child's text, kept apart from the text so the search reads
        /// a run of `u32`s before it reads any string.
        keys: std.ArrayList(u32) = .empty,
        texts: std.ArrayList([]const u8) = .empty,
        children: std.ArrayList(u32) = .empty,
        /// The child any one non-empty segment leads to. One, whatever the
        /// param is called: `/users/:id` and `/users/:name/posts` share it,
        /// and the name is read off the route that is found.
        param: u32 = none,
        /// The route of each method that ends here.
        ends: [methods]u32 = @splat(none),
        /// The route of each method whose `*` stands here, taking whatever
        /// is left of the path, nothing included.
        rest: [methods]u32 = @splat(none),
        /// Every method some route at or below this node answers, so the
        /// search does not walk a branch for a `POST` that holds only `GET`s.
        reach: MethodSet = .initEmpty(),

        fn literal(self: *const Node, text: []const u8) ?u32 {
            const key = Route.firstKey(text);
            for (self.keys.items, 0..) |k, i| {
                if (k == key and std.mem.eql(u8, self.texts.items[i], text)) return self.children.items[i];
            }
            return null;
        }

        fn deinit(self: *Node, gpa: std.mem.Allocator) void {
            self.keys.deinit(gpa);
            self.texts.deinit(gpa);
            self.children.deinit(gpa);
        }
    };

    pub fn init(gpa: std.mem.Allocator) Router {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |r| self.gpa.free(r.segments);
        self.routes.deinit(self.gpa);
        for (self.nodes.items) |*n| n.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
    }

    /// `pattern` must outlive the Router (normally a literal).
    ///
    /// A pattern that makes no sense is caught while compiling, by
    /// `validatePattern` — every route registered through `App` goes
    /// through it first, so the asserts here are internal invariants
    /// rather than the user's error message.
    pub fn add(self: *Router, method: http1.Method, pattern: []const u8, handler: CtxHandler) !void {
        return self.addNamed(method, pattern, handler, "");
    }

    /// `add`, with the route's `operationId`. `name` must outlive the Router,
    /// the way `pattern` must; `App` is what owns both.
    pub fn addNamed(
        self: *Router,
        method: http1.Method,
        pattern: []const u8,
        handler: CtxHandler,
        name: []const u8,
    ) !void {
        std.debug.assert(pattern.len > 0 and pattern[0] == '/');

        var buf: [max_segments][]const u8 = undefined;
        const parts = split(trimSlashes(pattern), &buf) orelse {
            std.debug.panic(
                "nilo: the route \"{s}\" has more than {d} segments",
                .{ pattern, max_segments },
            );
        };

        const segments = try self.gpa.alloc(Segment, parts.len);
        errdefer self.gpa.free(segments);
        for (segments, parts) |*seg, part| seg.* = .of(part);

        // A second route matching exactly the same paths is dead code, and
        // silently dropping it is how an afternoon disappears. Param names
        // are not part of the shape: `/users/:id` and `/users/:name` answer
        // the same requests, so they collide too.
        for (self.routes.items) |existing| {
            if (existing.method != method) continue;
            if (Route.sameShape(existing.segments, segments)) return error.DuplicateRoute;
        }

        const tail_is_wildcard = segments.len > 0 and segments[segments.len - 1].kind == .wildcard;

        // Every segment that is not a literal fills a slot in
        // `Match.params`, a `*` included — `fill` writes it under the name
        // "*". Counting the colons in the pattern instead missed the `*`
        // entirely, so eight params beside a catch-all is nine captures and
        // passed an assert whose whole job is to stop `fill` running off the
        // end of an eight-slot array. `validatePattern` says this to the
        // user while compiling; here it is the invariant behind that.
        var captures: usize = 0;
        for (segments) |seg| {
            if (seg.kind != .literal) captures += 1;
        }
        std.debug.assert(captures <= max_params);

        // Room for the route first, so that once it is in the tree nothing
        // can fail before it is in the list the tree points into.
        try self.routes.ensureUnusedCapacity(self.gpa, 1);
        try self.plant(method, segments, @intCast(self.routes.items.len));
        self.routes.appendAssumeCapacity(.{
            .method = method,
            .pattern = pattern,
            .handler = handler,
            .name = name,
            .segments = segments,
            .wildcard_tail = tail_is_wildcard,
        });
    }

    /// Put route `index` into the tree along its segments. A failure part
    /// way leaves nodes nothing ends at, which the search walks past.
    fn plant(self: *Router, method: http1.Method, segments: []const Segment, index: u32) !void {
        const m = @intFromEnum(method);
        if (self.nodes.items.len == 0) try self.nodes.append(self.gpa, .{});
        var at: u32 = 0;
        self.nodes.items[at].reach.insert(method);
        for (segments) |seg| {
            switch (seg.kind) {
                .literal => at = try self.literalChild(at, seg.text),
                .param => at = try self.paramChild(at),
                .wildcard => {
                    // `add` refused a second route of this shape, and a `*`
                    // is always the last segment.
                    std.debug.assert(self.nodes.items[at].rest[m] == none);
                    self.nodes.items[at].rest[m] = index;
                    return;
                },
            }
            self.nodes.items[at].reach.insert(method);
        }
        std.debug.assert(self.nodes.items[at].ends[m] == none);
        self.nodes.items[at].ends[m] = index;
    }

    fn literalChild(self: *Router, at: u32, text: []const u8) !u32 {
        if (self.nodes.items[at].literal(text)) |child| return child;
        const child: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, .{});
        const node = &self.nodes.items[at];
        try node.keys.ensureUnusedCapacity(self.gpa, 1);
        try node.texts.ensureUnusedCapacity(self.gpa, 1);
        try node.children.ensureUnusedCapacity(self.gpa, 1);
        node.keys.appendAssumeCapacity(Route.firstKey(text));
        node.texts.appendAssumeCapacity(text);
        node.children.appendAssumeCapacity(child);
        return child;
    }

    fn paramChild(self: *Router, at: u32) !u32 {
        if (self.nodes.items[at].param != none) return self.nodes.items[at].param;
        const child: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, .{});
        self.nodes.items[at].param = child;
        return child;
    }

    /// The pattern already registered that `pattern` would collide with, if
    /// there is one. Kept separate from `add` so the error can be reported
    /// by whoever is closer to the user — `App` names both patterns, this
    /// only finds them.
    pub fn conflicting(self: *const Router, method: http1.Method, pattern: []const u8) ?[]const u8 {
        var buf: [max_segments][]const u8 = undefined;
        const parts = split(trimSlashes(pattern), &buf) orelse return null;

        // Classified the way `add` would classify it, and compared the way
        // `add` compares — so the two cannot answer differently about the
        // same pair of patterns. Registration only, never a request, so the
        // stack this takes is the App being built rather than a connection
        // holding it.
        var seg_buf: [max_segments]Segment = undefined;
        const segments = seg_buf[0..parts.len];
        for (segments, parts) |*seg, part| seg.* = .of(part);

        for (self.routes.items) |existing| {
            if (existing.method != method) continue;
            if (Route.sameShape(existing.segments, segments)) return existing.pattern;
        }
        return null;
    }

    /// `matchInto`, returning the match. For a caller with nowhere of its
    /// own to put one; the request path uses `matchInto`.
    pub fn match(self: *const Router, method: http1.Method, path: []const u8) ?Match {
        var result: Match = undefined;
        return if (self.matchInto(method, path, &result)) result else null;
    }

    /// Find the route for this request and write it into `out`, which the
    /// caller owns and the params point out of. False is no route.
    ///
    /// Into the caller's memory rather than returned, because a `Match` is
    /// eight params wide, about 300 bytes, and the request path held it in
    /// a variable of its own anyway: returning one by value copied it on the
    /// way out of each call it passed through, on every request, one route
    /// or three hundred. Measured: 19ns to 13ns on a one-route app, 35ns to
    /// 27ns across the ERP's 276 (`bench/result/http.md`).
    pub noinline fn matchInto(self: *const Router, method: http1.Method, path: []const u8, out: *Match) bool {
        var buf: [max_segments][]const u8 = undefined;
        const trimmed = trimSlashes(path);
        const split_path = splitPath(trimmed, &buf);
        const parts = split_path.items;
        const deep = split_path.deep;

        if (self.matchExact(method, trimmed, parts, deep, out)) return true;
        // A HEAD nobody registered is answered by the GET route: the head of
        // a HEAD response has to be what a GET would have sent anyway, and
        // the body is dropped on the way out (Ctx.send). Making people
        // register both would mean every health check and every link
        // checker gets a 404 from a route that plainly exists.
        if (method == .HEAD) return self.matchExact(.GET, trimmed, parts, deep, out);
        return false;
    }

    /// The methods that answer this path, whatever the request asked for.
    ///
    /// Empty means no route spells this path out at all, which is a 404. A
    /// set with something in it and the requested method not in it is the
    /// difference between "there is nothing here" and "there is something
    /// here, but not for that verb" — a 405, and the `Allow` header that
    /// has to come with it.
    ///
    /// Only reached once the ordinary match has already failed, so walking
    /// every route a second time costs nothing on the path that matters.
    pub fn allowedFor(self: *const Router, path: []const u8) MethodSet {
        return self.allowedForOn(path, null);
    }

    /// `allowedFor`, as the listener numbered `listener` would answer it: a
    /// route bound to other listeners is not here, so it neither makes a
    /// 405 nor puts its verb in an `Allow` header (ADR 252). Null is every
    /// listener.
    pub fn allowedForOn(self: *const Router, path: []const u8, listener: ?u8) MethodSet {
        var allowed: MethodSet = .initEmpty();

        var buf: [max_segments][]const u8 = undefined;
        const split_path = splitPath(trimSlashes(path), &buf);

        for (self.routes.items) |*route| {
            if (allowed.contains(route.method)) continue;
            if (listener) |on| if (!onListener(route.listeners, on)) continue;
            if (answers(route, split_path.items, split_path.deep)) allowed.insert(route.method);
        }

        // A HEAD is answered by the GET route, so a path with a GET on it
        // allows HEAD whether or not anybody registered one (see `match`).
        if (allowed.contains(.GET)) allowed.insert(.HEAD);
        return allowed;
    }

    /// Whether this route answers this path, method aside — the length rule
    /// `matchExact` applies before it looks at any text, and then the text.
    ///
    /// `deep` is a path with more segments than `parts` holds: no fixed
    /// route has that many, so a `*` is the only thing that can answer it.
    fn answers(route: *const Route, parts: []const []const u8, deep: bool) bool {
        if (deep) return route.wildcard_tail and matches(route, parts);
        if (route.wildcard_tail) {
            if (parts.len + 1 < route.segments.len) return false;
        } else if (route.segments.len != parts.len) return false;
        return matches(route, parts);
    }

    /// The most specific route for this path, found by walking the tree,
    /// written into `out` field by field: the params array is left as it
    /// was past the ones this route fills.
    fn matchExact(
        self: *const Router,
        method: http1.Method,
        trimmed: []const u8,
        parts: []const []const u8,
        deep: bool,
        out: *Match,
    ) bool {
        const i = self.find(method, parts, deep) orelse return false;
        const route = &self.routes.items[i];
        out.handler = route.handler;
        out.chain = route.chain;
        out.index = i;
        out.n_params = 0;
        capture(route, trimmed, parts, out);
        return true;
    }

    /// The route the search reaches first, which is the most specific one.
    ///
    /// Depth first, and at each segment the three ways on in ADR 012's
    /// order: the literal child that segment names, then the param child,
    /// then a `*` standing here. A branch that reaches the end of the path
    /// with no route for this method is backed out of, and the next way on
    /// at the level above is tried. So `/files/:name` is found for
    /// `/files/a` ahead of `/files/*`, and `/:tenant/dashboard` for
    /// `/acme/dashboard` once `/acme` turns out to lead nowhere.
    ///
    /// Iterative, with the way back held in two small arrays rather than on
    /// the call stack: a match runs on the request's fiber, and by ADR 062
    /// every byte of stack it touches is held for the life of the
    /// connection. Eighty-five bytes here, whatever the path.
    fn find(self: *const Router, method: http1.Method, parts: []const []const u8, deep: bool) ?u32 {
        const nodes = self.nodes.items;
        if (nodes.len == 0) return null;
        const m = @intFromEnum(method);

        var at: [max_segments + 1]u32 = undefined;
        // Which way on this level tries next: 0 the literal, 1 the param,
        // 2 a `*`, 3 nothing left.
        var next: [max_segments + 1]u8 = undefined;
        var d: usize = 0;
        at[0] = 0;
        next[0] = 0;

        while (true) {
            const node = &nodes[at[d]];
            if (d == parts.len) {
                // The whole path is matched. A route ending here is more
                // specific than a `*` standing for nothing. A `deep` path
                // is not matched whole, there is more of it left, so only
                // a `*` standing here can take it.
                if (!deep and node.ends[m] != none) return node.ends[m];
                if (node.rest[m] != none) return node.rest[m];
            } else {
                if (next[d] == 0) {
                    next[d] = 1;
                    if (node.literal(parts[d])) |child| {
                        if (nodes[child].reach.contains(method)) {
                            d += 1;
                            at[d] = child;
                            next[d] = 0;
                            continue;
                        }
                    }
                }
                if (next[d] == 1) {
                    next[d] = 2;
                    // An empty segment fills nothing (`/users//posts`).
                    if (node.param != none and parts[d].len > 0 and
                        nodes[node.param].reach.contains(method))
                    {
                        d += 1;
                        at[d] = node.param;
                        next[d] = 0;
                        continue;
                    }
                }
                if (next[d] == 2) {
                    next[d] = 3;
                    if (node.rest[m] != none) return node.rest[m];
                }
            }
            if (d == 0) return null;
            d -= 1;
        }
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

    /// Write the params of a route the search already found. Nothing is
    /// compared: `find` only reaches a route whose every segment lined up.
    fn capture(
        route: *const Route,
        trimmed: []const u8,
        parts: []const []const u8,
        result: *Match,
    ) void {
        const segments = fixedSegments(route);
        for (segments, parts[0..segments.len]) |seg, part| {
            if (seg.kind != .param) continue;
            result.params[result.n_params] = .{ .name = seg.text, .value = part };
            result.n_params += 1;
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
    }
};

/// Everything that can be wrong with a route pattern, said while
/// compiling. `App` calls this before handing the pattern to `add`, so a
/// typo like `app.get("users", …)` is a build error naming the route
/// instead of an `unreachable` at startup.
pub fn validatePattern(comptime pattern: []const u8) void {
    comptime {
        // The pattern is read a byte at a time by the split, the checks of
        // each segment, and the comparison of every param name with the ones
        // before it, so the cost grows with its length and its params. Eight
        // params of 24 characters ran past the default 1,000 backwards
        // branches at a line in `std`, which reads as a fault in the route
        // ([ADR 126](../docs/adr/126-a-check-pays-for-its-own-branches.md)).
        @setEvalBranchQuota(10_000 + 20 * @as(u32, @intCast(pattern.len)) + @as(u32, @intCast(pattern.len * pattern.len)));
        if (pattern.len == 0) @compileError(
            "nilo: a route pattern cannot be empty.\n" ++
                "  The path a browser asks for always starts with a slash, so the pattern does " ++
                "too: \"/\" for the root.",
        );
        if (pattern[0] != '/') @compileError(
            "nilo: the route pattern \"" ++ pattern ++ "\" does not start with a slash.\n" ++
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
                "nilo: the route pattern \"" ++ pattern ++ "\" has a `*` that is not the last " ++
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
                "nilo: the segment \"" ++ seg ++ "\" of route \"" ++ pattern ++ "\" mixes `*` " ++
                    "with other text.\n" ++
                    "  A catch-all is a segment of its own: \"/files/*\", not \"/files/" ++ seg ++
                    "\".",
            );

            // `{id}` is what OpenAPI writes, what nilo's own document emits,
            // and what every framework a porter arrives from spells. Without
            // this it is five literal characters and the only symptom is a
            // 404 on a URL the generated document promises (ADR 118).
            if (std.mem.indexOfScalar(u8, seg, '{') != null or
                std.mem.indexOfScalar(u8, seg, '}') != null) @compileError(
                "nilo: the segment \"" ++ seg ++ "\" of route \"" ++ pattern ++ "\" is written " ++
                    "with braces, and nilo matches it as literal text.\n" ++
                    "  A path param is written `:name`: \"/users/:id\", not \"/users/{id}\". " ++
                    "The `{}` form is what the OpenAPI document prints, so a path copied out of " ++
                    "one arrives spelled that way and has to be turned back.",
            );

            if (seg.len > 0 and seg[0] == ':') {
                if (seg.len == 1) @compileError(
                    "nilo: the route pattern \"" ++ pattern ++ "\" has a `:` with no name after " ++
                        "it.\n" ++
                        "  A path param is written `:name` — the name is what `c.param(\"name\")` " ++
                        "looks up.",
                );
                for (names) |taken| {
                    if (std.mem.eql(u8, taken, seg[1..])) @compileError(
                        "nilo: the route pattern \"" ++ pattern ++ "\" uses the param name `:" ++
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
                "nilo: the segment \"" ++ seg ++ "\" of route \"" ++ pattern ++ "\" has a `:` " ++
                    "in the middle of it, so it is matched as literal text.\n" ++
                    "  A path param takes the whole segment: \"/users/:id\", not \"/users/id:" ++
                    "\". If the colon really is part of the path, this is already correct — " ++
                    "nothing else to do.",
            );
        }

        if (n_segments > max_segments) @compileError(
            "nilo: the route pattern \"" ++ pattern ++ "\" has " ++ num(n_segments) ++
                " segments, and the most nilo matches is " ++ num(max_segments) ++ ".\n" ++
                "  A path this deep is usually a `*` catch-all waiting to happen: " ++
                "\"/files/*\" hands the rest to the handler as `c.param(\"*\")`.",
        );
        if (n_params > max_params) @compileError(
            "nilo: the route pattern \"" ++ pattern ++ "\" captures " ++ num(n_params) ++
                " params, and the most nilo holds is " ++ num(max_params) ++ ".\n" ++
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
/// than onto the heap. Null when there are more segments than fit, which
/// for a pattern is a registration error (a request path goes through
/// `splitPath`).
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

/// A request path split into at most `max_segments` pieces. `deep` says
/// there were more, which are not held: only a `*` can answer such a path,
/// and it takes the rest from the text, not from the pieces.
const SplitPath = struct {
    items: [][]const u8,
    deep: bool,
};

fn splitPath(trimmed: []const u8, out: *[max_segments][]const u8) SplitPath {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed, '/');
    while (it.next()) |part| {
        if (n == max_segments) return .{ .items = out[0..n], .deep = true };
        out[n] = part;
        n += 1;
    }
    return .{ .items = out[0..n], .deep = false };
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

test "a * route still matches a path seventeen or more segments deep" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/files/*", testHandler);

    var deep: [max_segments + 4][]const u8 = undefined;
    for (&deep) |*seg| seg.* = "/x";
    const tail = try std.mem.concat(testing.allocator, u8, &deep);
    defer testing.allocator.free(tail);
    const path = try std.mem.concat(testing.allocator, u8, &.{ "/files", tail });
    defer testing.allocator.free(path);

    const m = r.match(.GET, path) orelse return error.TestExpectedMatch;
    try testing.expectEqualStrings("x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x", m.params[0].value);
    // The 405 path agrees: a POST to it is a method the route does not have.
    try testing.expect(r.allowedFor(path).contains(.GET));
    try testing.expect(!r.allowedFor(path).contains(.POST));
}

test "a root * fallback matches a path of any depth, and a fixed route never does" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/*", testHandler);
    // Sixteen fixed segments: as deep as a pattern can be, and not as deep
    // as the path below.
    try r.add(.POST, "/1/2/3/4/5/6/7/8/9/10/11/12/13/14/15/16", otherHandler);

    const sixteen = "/1/2/3/4/5/6/7/8/9/10/11/12/13/14/15/16";
    const seventeen = sixteen ++ "/17";
    try testing.expect(r.match(.POST, sixteen) != null);
    try testing.expect(r.match(.POST, seventeen) == null);
    try testing.expect(!r.allowedFor(seventeen).contains(.POST));

    const m = r.match(.GET, seventeen) orelse return error.TestExpectedMatch;
    try testing.expectEqualStrings(seventeen[1..], m.params[0].value);
    try testing.expect(r.allowedFor(seventeen).contains(.GET));
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

test "a first-segment key collision still matches, because the key only skips" {
    var r = Router.init(testing.allocator);
    defer r.deinit();

    // Same length, same first byte, same last byte, same middle byte — so
    // `firstKey` cannot tell these two apart. The scan must fall through to
    // the real comparison rather than trusting the key.
    try testing.expectEqual(Route.firstKey("abcde"), Route.firstKey("axcye"));

    try r.add(.GET, "/abcde/:id", testHandler);
    try r.add(.GET, "/axcye/:id", otherHandler);

    const first = r.match(.GET, "/abcde/7") orelse return error.TestExpectedMatch;
    const second = r.match(.GET, "/axcye/7") orelse return error.TestExpectedMatch;
    try testing.expect(first.handler == testHandler);
    try testing.expect(second.handler == otherHandler);

    // And a third word that collides with neither is still a miss.
    try testing.expect(r.match(.GET, "/zzzzz/7") == null);
}

test "a route starting with a param or a catch-all is never skipped by the key" {
    var r = Router.init(testing.allocator);
    defer r.deinit();

    // A literal-first route sits in front of them, so the key of the path
    // being asked for matches nothing that was registered as a literal.
    try r.add(.GET, "/users/:id", testHandler);
    try r.add(.GET, "/:tenant/dashboard", otherHandler);

    const wild = r.match(.GET, "/acme/dashboard") orelse return error.TestExpectedMatch;
    try testing.expect(wild.handler == otherHandler);
    try testing.expectEqualStrings("tenant", wild.params[0].name);
    try testing.expectEqualStrings("acme", wild.params[0].value);

    // The literal still wins where both could answer.
    const literal = r.match(.GET, "/users/42") orelse return error.TestExpectedMatch;
    try testing.expect(literal.handler == testHandler);
}

test "a catch-all at the root answers a path whose first segment matches no route" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/assets/:file", testHandler);
    try r.add(.GET, "/*", otherHandler);

    const anything = r.match(.GET, "/nothing/like/the/others") orelse
        return error.TestExpectedMatch;
    try testing.expect(anything.handler == otherHandler);

    const asset = r.match(.GET, "/assets/logo.svg") orelse return error.TestExpectedMatch;
    try testing.expect(asset.handler == testHandler);
}

test "the key tells apart the words a route table actually holds" {
    // The point of the key is that neighbouring route names differ where
    // it looks. These are the shapes that turn up in a real table, and the
    // benchmark's `/thingN/...`, which differs only at the end.
    const words = [_][]const u8{
        "users", "uploads", "user", "usage",  "health", "healthz",
        "api",   "admin",   "auth", "thing0", "thing1", "thing99",
    };
    var collisions: usize = 0;
    for (words, 0..) |a, i| {
        for (words[i + 1 ..]) |b| {
            if (Route.firstKey(a) == Route.firstKey(b)) collisions += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), collisions);
}

test "add and conflicting read a segment that is only a colon the same way" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/a/:", testHandler);

    // `add` has always called this a param with an empty name. `conflicting`
    // called it the literal ":" and so found no collision, which left
    // `App.tryRoute` skipping the message that names both patterns and
    // letting `add`'s own check answer with a bare error instead. No second
    // route was ever registered, and `validatePattern` refuses the pattern
    // outright, so nothing reached this but a direct caller — what earned
    // the fix is one classification living in two places.
    try testing.expectEqualStrings("/a/:", r.conflicting(.GET, "/a/:").?);
    try testing.expectError(error.DuplicateRoute, r.add(.GET, "/a/:", otherHandler));
}

test "a catch-all fills a param slot, so the budget has to count it" {
    var r = Router.init(testing.allocator);
    defer r.deinit();

    // Seven names and a `*` is eight captures, which is `max_params`
    // exactly. The assert `add` used to make counted the colons in the
    // pattern, so it read this as seven — and would have let a ninth
    // capture through to write past the end of `Match.params`.
    try r.add(.GET, "/:a/:b/:c/:d/:e/:f/:g/*", testHandler);

    const m = r.match(.GET, "/1/2/3/4/5/6/7/rest/of/it") orelse
        return error.TestExpectedMatch;
    try testing.expectEqual(@as(usize, max_params), m.n_params);
    try testing.expectEqualStrings(wildcard, m.params[max_params - 1].name);
    try testing.expectEqualStrings("rest/of/it", m.params[max_params - 1].value);
}

/// The ranking the scan this router replaced used, with none of its
/// shortcuts: every route that answers the path is scored, and the highest
/// wins. Held against the tree on tables with no `*`, where the score and
/// ADR 012's rule agree (a `*` is where they part; see the test below this
/// one).
fn bestByScore(r: *const Router, method: http1.Method, path: []const u8) ?Match {
    var buf: [max_segments][]const u8 = undefined;
    const trimmed = trimSlashes(path);
    const parts = split(trimmed, &buf) orelse return null;
    var best: ?usize = null;
    var best_score: u32 = 0;
    for (r.routes.items, 0..) |*route, i| {
        if (route.method != method) continue;
        if (!Router.answers(route, parts, false)) continue;
        const score = Route.specificity(route.segments);
        if (best == null or score > best_score) {
            best = i;
            best_score = score;
        }
    }
    const i = best orelse return null;
    const route = &r.routes.items[i];
    var result: Match = .{ .handler = route.handler, .chain = route.chain, .index = i };
    Router.capture(route, trimmed, parts, &result);
    return result;
}

test "the tree agrees with the scan it replaced, on a table under one prefix" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    // The shape that decided the tree: everything under `/api`, several
    // methods per resource, literals beside params at the same depth.
    const table = [_]struct { http1.Method, []const u8 }{
        .{ .GET, "/" },                                 .{ .GET, "/health" },
        .{ .GET, "/api/deals" },                        .{ .POST, "/api/deals" },
        .{ .GET, "/api/deals/:id" },                    .{ .PATCH, "/api/deals/:id" },
        .{ .DELETE, "/api/deals/:id" },                 .{ .GET, "/api/deals/pipeline" },
        .{ .GET, "/api/deals/:id/lines" },              .{ .POST, "/api/deals/:id/lines" },
        .{ .POST, "/api/deals/:id/won" },               .{ .GET, "/api/work-items/mine" },
        .{ .GET, "/api/work-items/:id" },               .{ .POST, "/api/work-items/:id/target-date" },
        .{ .PATCH, "/api/work-items/:id/target-date" }, .{ .GET, "/api/:tenant/settings" },
        .{ .PUT, "/api/:tenant/settings" },             .{ .GET, "/api/deals/:id/lines/:line" },
    };
    for (table) |route| try r.add(route[0], route[1], testHandler);

    const paths = [_][]const u8{
        "/",                         "",                              "/health",
        "/health/",                  "/api",                          "/api/deals",
        "/api/deals/",               "/api/deals/7",                  "/api/deals/pipeline",
        "/api/deals/settings",       "/api/deals/7/lines",            "/api/deals/7/lines/3",
        "/api/deals//lines",         "/api/deals/7/won",              "/api/work-items/mine",
        "/api/work-items/7",         "/api/work-items/7/target-date", "/api/work-items/settings",
        "/api/acme/settings",        "/api//settings",                "/api/nope/7",
        "/api/deals/7/lines/3/more", "//",                            "/api/deals/pipeline/lines",
    };
    for ([_]http1.Method{ .GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS }) |method| {
        for (paths) |path| {
            const now = r.match(method, path);
            // No HEAD route in the table, so a HEAD is answered by the GET.
            const want = bestByScore(&r, if (method == .HEAD) .GET else method, path);
            if (want == null) {
                try testing.expect(now == null);
                continue;
            }
            try testing.expect(now != null);
            try testing.expectEqual(want.?.index, now.?.index);
            try testing.expectEqual(want.?.n_params, now.?.n_params);
            for (0..want.?.n_params) |i| {
                try testing.expectEqualStrings(want.?.params[i].name, now.?.params[i].name);
                try testing.expectEqualStrings(want.?.params[i].value, now.?.params[i].value);
            }
        }
    }
}

test "a literal branch that leads nowhere is backed out of, and the param tried" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/a/b/c", testHandler);
    try r.add(.GET, "/:x/b/d", otherHandler);

    // `/a` is a literal child, and under it there is no `d`: the search has
    // to come back up two levels and take the param.
    const m = r.match(.GET, "/a/b/d") orelse return error.TestExpectedMatch;
    try testing.expect(m.handler == otherHandler);
    try testing.expectEqualStrings("a", m.params[0].value);
    try testing.expect(r.match(.GET, "/a/b/c").?.handler == testHandler);
}

test "a branch that holds no route for the method is not where the answer comes from" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.add(.GET, "/api/deals/:id", testHandler);
    try r.add(.POST, "/api/:kind/:id", otherHandler);

    // `/api/deals` holds only a GET, so a POST goes past it to the param.
    const post = r.match(.POST, "/api/deals/7") orelse return error.TestExpectedMatch;
    try testing.expect(post.handler == otherHandler);
    try testing.expectEqualStrings("kind", post.params[0].name);
    try testing.expectEqualStrings("deals", post.params[0].value);
    try testing.expect(r.match(.GET, "/api/deals/7").?.handler == testHandler);
    try testing.expect(r.match(.DELETE, "/api/deals/7") == null);
}

test "an earlier literal outranks a longer route, which the scan's score got backwards" {
    // ADR 012's rule is that an earlier segment outranks every later one.
    // The scan ranked by a number with two bits a segment, so a route with
    // more segments had more digits and could outrank one that was more
    // specific where they first differ. Both cases turn on a `*`, the only
    // way two routes of different lengths can answer one path.
    for ([_]bool{ false, true }) |star_first| {
        var r = Router.init(testing.allocator);
        defer r.deinit();
        if (star_first) {
            try r.add(.GET, "/a/*", testHandler);
            try r.add(.GET, "/:x/b/c", otherHandler);
            try r.add(.GET, "/files/*", testHandler);
            try r.add(.GET, "/files", otherHandler);
        } else {
            try r.add(.GET, "/:x/b/c", otherHandler);
            try r.add(.GET, "/a/*", testHandler);
            try r.add(.GET, "/files", otherHandler);
            try r.add(.GET, "/files/*", testHandler);
        }
        // `a` is a literal where `/:x/b/c` has a param, so `/a/*` wins; the
        // scan scored `/:x/b/c` 47 and `/a/*` 13.
        try testing.expect(r.match(.GET, "/a/b/c").?.handler == testHandler);
        try testing.expect(r.match(.GET, "/z/b/c").?.handler == otherHandler);
        // A route ending here beats a `*` standing for nothing, whichever
        // was registered first. The scan answered by registration order.
        try testing.expect(r.match(.GET, "/files").?.handler == otherHandler);
        try testing.expect(r.match(.GET, "/files/x").?.handler == testHandler);
    }
}
