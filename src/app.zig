//! App — one self-contained HTTP application: its routes, services,
//! middleware and static files. It wires the Bulkhead, the HTTP/1.1
//! parser, the Router, the request arena, and Ctx into one thing.
//!
//! `handleRequest` is deliberately separate from the Engine: all it needs
//! is a `std.Io.Reader`/`Writer`, so every bit of App's HTTP behaviour can
//! be tested against in-memory buffers, without starting a server.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");
const http1 = @import("http1.zig");
const router_mod = @import("router.zig");
const ctx_mod = @import("ctx.zig");
const str_mod = @import("str.zig");
const service_mod = @import("service.zig");
const typed = @import("typed.zig");
const fail = @import("fail.zig");
const mw = @import("middleware.zig");
const cors = @import("cors.zig");
const static_mod = @import("static.zig");
const budget = @import("budget.zig");

const Ctx = ctx_mod.Ctx;

/// How much of a connection's request arena survives between requests.
/// Big enough that an ordinary request never allocates twice on the same
/// connection, small enough that one large upload does not leave that
/// connection sitting on the memory for good.
const arena_keep = 16 * 1024;

const RESPONSE_400 = http1.staticResponse(400, "Bad Request", "text/plain", "malformed request\n", false);
const RESPONSE_431 = http1.staticResponse(431, "Request Header Fields Too Large", "text/plain", "head too long\n", false);

pub const App = struct {
    gpa: std.mem.Allocator,
    router: router_mod.Router,
    services: service_mod.Registry,
    /// The services handlers asked for, collected as routes are registered
    /// and checked once in `listen()` (ADR 0006).
    requirements: std.ArrayList(service_mod.Requirement) = .empty,
    /// Middleware registrations, in the order `use` was called.
    scoped: std.ArrayList(mw.Scoped) = .empty,
    /// Directories loaded into memory by `static`, searched only when no
    /// route matched (ADR 0010).
    static_sets: std.ArrayList(static_mod.Set) = .empty,

    pub fn init(gpa: std.mem.Allocator) App {
        return .{
            .gpa = gpa,
            .router = router_mod.Router.init(gpa),
            .services = service_mod.Registry.init(gpa),
        };
    }

    pub fn deinit(self: *App) void {
        self.freeChains();
        for (self.static_sets.items) |*s| s.deinit();
        self.static_sets.deinit(self.gpa);
        self.scoped.deinit(self.gpa);
        self.requirements.deinit(self.gpa);
        self.services.deinit();
        self.router.deinit();
    }

    /// Add a middleware that runs on every route.
    ///
    /// Order against route registration does not matter — chains are
    /// resolved in `listen()`. Order among `use`/`useOn` calls is the run
    /// order (ADR 0009).
    pub fn use(self: *App, middleware: mw.Middleware) !void {
        try self.scoped.append(self.gpa, .{ .prefix = "", .middleware = middleware });
    }

    /// Add a middleware that runs only on routes under `prefix`.
    ///
    /// ```zig
    /// try app.useOn("/api", requireToken);
    /// ```
    pub fn useOn(self: *App, prefix: []const u8, middleware: mw.Middleware) !void {
        std.debug.assert(prefix.len > 0 and prefix[0] == '/');
        try self.scoped.append(self.gpa, .{ .prefix = prefix, .middleware = middleware });
    }

    /// Serve the contents of `dir_path` under `url_prefix`.
    ///
    /// The directory is read into memory here and now, before anything is
    /// being served — nothing touches the disk on the request path (ADR
    /// 0010). `dir_path` is relative to the working directory the server
    /// runs in.
    ///
    /// ```zig
    /// try app.static("/", "public");
    /// ```
    ///
    /// Routes win over static files, so an explicit `app.get("/index.html", …)`
    /// still gets its way.
    pub fn static(self: *App, url_prefix: []const u8, dir_path: []const u8) !void {
        try self.staticWith(url_prefix, dir_path, .{});
    }

    /// `static`, with the caching, index and single-page-app options spelled
    /// out. See `static.Options`.
    pub fn staticWith(
        self: *App,
        url_prefix: []const u8,
        dir_path: []const u8,
        opts: static_mod.Options,
    ) !void {
        const set = try static_mod.load(self.gpa, url_prefix, dir_path, opts);
        errdefer {
            var mutable = set;
            mutable.deinit();
        }
        try self.static_sets.append(self.gpa, set);
    }

    /// Register a service. `ptr` must outlive the App. Its order relative
    /// to route registration does not matter; all that matters is that it
    /// happens before `listen()`.
    pub fn provide(self: *App, ptr: anytype) !void {
        try self.services.add(ptr);
    }

    pub fn get(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.GET, pattern, handler);
    }

    pub fn post(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.POST, pattern, handler);
    }

    pub fn put(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.PUT, pattern, handler);
    }

    pub fn delete(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.DELETE, pattern, handler);
    }

    pub fn patch(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.PATCH, pattern, handler);
    }

    pub fn head(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.HEAD, pattern, handler);
    }

    pub fn options(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.OPTIONS, pattern, handler);
    }

    /// Every route registration goes through here. Whatever shape the
    /// handler has — `fn (*Ctx) !void` or a typed handler — the
    /// compile-time engine stitches it into a Ctx handler, so there is
    /// only ever one request path.
    pub fn route(
        self: *App,
        method: http1.Method,
        comptime pattern: []const u8,
        comptime handler: anytype,
    ) !void {
        comptime router_mod.validatePattern(pattern);

        // Registering the same path twice is not a small mistake: the
        // second handler never runs, and nothing about the running server
        // says so. Caught here, where both patterns can be named.
        if (self.router.conflicting(method, pattern)) |existing| {
            std.log.err(
                "the route \"{s} {s}\" answers the same requests as \"{s}\", which is already " ++
                    "registered — whichever came second would never run. Drop one, or give them " ++
                    "different paths. (Param names do not tell two routes apart: \"/users/:id\" " ++
                    "and \"/users/:name\" are the same route.)",
                .{ @tagName(method), pattern, existing },
            );
            return error.DuplicateRoute;
        }

        try self.requirements.appendSlice(self.gpa, comptime typed.requirements(pattern, handler));
        try self.router.add(method, pattern, comptime typed.wrap(pattern, handler));
    }

    /// The first requirement that is not met, or null if every handler got
    /// what it asked for.
    pub fn missingService(self: *const App) ?service_mod.Requirement {
        for (self.requirements.items) |r| {
            if (!self.services.has(r)) return r;
        }
        return null;
    }

    /// Like `missingService`, but logs everything that is missing and then
    /// fails. Called automatically by `listen()` — this is what makes a
    /// forgotten service show up before a single request is served, rather
    /// than at three in the morning (ADR 0006).
    pub fn checkServices(self: *const App) error{MissingService}!void {
        if (self.missingService() == null) return;
        for (self.requirements.items) |r| {
            if (self.services.has(r)) continue;
            std.log.err(
                "the handler for route \"{s}\" needs service {s}{s}, which was never registered " ++
                    "— call app.provide() before app.listen()",
                .{ r.route, if (r.needs_mutable) "*" else "*const ", r.type_name },
            );
        }
        return error.MissingService;
    }

    /// Work out which middleware wraps each route, once. Called by
    /// `listen()`; separate so tests can drive it without a server.
    ///
    /// Doing this here rather than when each route is registered is what
    /// makes `use` and `get` order-independent — Fiber's most reported
    /// gotcha is middleware registered after a route silently not applying
    /// to it (ADR 0009).
    pub fn resolveChains(self: *App) !void {
        self.freeChains();
        for (self.router.routes.items) |*r| {
            r.chain = try mw.chainFor(self.gpa, self.scoped.items, r.pattern);
        }
    }

    fn freeChains(self: *App) void {
        for (self.router.routes.items) |*r| {
            if (r.chain.len > 0) self.gpa.free(r.chain);
            r.chain = &.{};
        }
    }

    /// Listen and serve until the process is stopped.
    pub fn listen(self: *App, options_: bulkhead.Options) !void {
        checkRootWiring();
        try self.checkServices();
        try self.resolveChains();
        try bulkhead.serve(self.gpa, options_, self, handleConnection);
    }

    fn handleConnection(self: *App, in: *std.Io.Reader, out: *std.Io.Writer) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var lifetime = str_mod.Lifetime{};

        // What this fiber is serving is bound to it once, then reused by
        // every request on the same connection (ADR 0007).
        var in_flight = fail.InFlight{};
        var binding = bulkhead.binding_unset;
        bulkhead.bindSlot(&binding, &in_flight);
        defer bulkhead.unbindSlot(&binding);

        while (true) {
            const keep_going = self.handleRequest(arena.allocator(), &lifetime, &in_flight, in, out);
            // The request is done: every Str of its goes stale, then the
            // bag is emptied in one go.
            //
            // Capacity is kept, but only up to a point. Keeping all of it
            // means one 1MB upload leaves that connection holding a
            // megabyte for as long as it stays open, and a few thousand
            // idle keep-alive connections that each once saw a big request
            // add up to memory nobody can account for.
            lifetime.end();
            _ = arena.reset(.{ .retain_with_limit = arena_keep });
            if (!keep_going) return;
        }
    }

    /// Handle exactly one request from `in`, writing the answer to `out`.
    /// Returns true if the connection may be used for another request.
    pub fn handleRequest(
        self: *App,
        arena: std.mem.Allocator,
        lifetime: *str_mod.Lifetime,
        in_flight: *fail.InFlight,
        in: *std.Io.Reader,
        out: *std.Io.Writer,
    ) bool {
        const failure = &in_flight.failure;
        in_flight.startRequest("", "");
        // On a real server the fiber slot is already installed and wins;
        // this is what keeps fail functions working when App is called
        // straight from a test, with no Engine underneath.
        const prev_slot = bulkhead.setFallbackSlot(in_flight);
        defer _ = bulkhead.setFallbackSlot(prev_slot);

        // The head is copied into the request arena so every Str from this
        // request stays valid even once the connection buffer is refilled
        // (when reading the body, say). One small memcpy, paid once.
        const raw_head = http1.readHead(in) catch |err| {
            switch (err) {
                error.EndOfStream, error.ReadFailed => {},
                error.HeadTooLong => sendFinal(out, RESPONSE_431),
            }
            return false;
        };
        const request_head = arena.dupe(u8, raw_head) catch return false;
        in.toss(raw_head.len);

        var r = http1.Request{};
        http1.parseHead(request_head, &r) catch {
            sendFinal(out, RESPONSE_400);
            return false;
        };

        const qmark = std.mem.indexOfScalar(u8, r.target, '?');
        const path = if (qmark) |i| r.target[0..i] else r.target;
        const raw_query = if (qmark) |i| r.target[i + 1 ..] else "";

        // From here on the panic handler can name what was being served
        // (ADR 0008). Both slices live in the request arena.
        in_flight.startRequest(r.method, path);

        var c = Ctx{
            .method = http1.methodFrom(r.method),
            ._arena = arena,
            ._lifetime = lifetime,
            ._in = in,
            ._out = out,
            ._request = &r,
            ._path = path,
            ._query = raw_query,
            ._query_params = ctx_mod.parseQuery(arena, raw_query) catch return false,
            ._head = request_head,
            ._params = &.{},
            ._services = &self.services,
        };

        // A request that matched no route still runs the middleware: a
        // logger that cannot see 404s and a CORS that cannot answer a
        // preflight for an unknown path are both useless exactly when you
        // need them. What changes is only the innermost call (ADR 0009).
        var chain: []const mw.Middleware = &.{};
        var terminal: mw.CtxHandler = notFoundHandler;

        // Held in a variable of this scope on purpose: `c` borrows the
        // params out of it, and they have to outlive the branch below.
        var matched = self.router.match(c.method, path);

        if (matched) |*match| {
            // Decoded here rather than before matching: `%2F` is a slash of
            // data, and a router that saw it as a separator would let a
            // request reach a route it does not name.
            const params = match.params[0..match.n_params];
            ctx_mod.decodeParams(arena, params) catch return false;
            c._params = params;
            chain = match.chain;
            terminal = match.handler;
        } else {
            // Nothing was precomputed for a path with no route, so the
            // chain is built here — out of the request arena, which costs
            // about as much as the pointer to it.
            if (self.scoped.items.len > 0) {
                chain = mw.chainFor(arena, self.scoped.items, path) catch &.{};
            }
            if (self.findStatic(c.method, path)) |file| {
                c._static_file = file;
                terminal = serveStaticFile;
            }
        }

        (mw.Next{ .rest = chain, .handler = terminal }).run(&c) catch |err| {
            // A half-sent response cannot be taken back, so the connection
            // is closed: the next request on it would read leftover bytes
            // of unclear provenance.
            if (c._sent) {
                std.log.warn("handler {s} {s} failed after answering: {s}", .{ @tagName(c.method), path, @errorName(err) });
                return false;
            }
            // Nothing sent yet: this is a clean failure. A body nobody read
            // still has to be discarded so the connection can be reused —
            // a 404 from a fail function is a normal way to live, not a
            // reason to drop keep-alive. If it cannot be discarded the
            // answer still goes out; only the connection is given up.
            const reusable = drain(&c, in, &r);
            sendFailure(&c, failure, err) catch return false;
            return reusable;
        };

        // A body the handler did not read is discarded so the next request
        // on this connection starts at the right byte.
        const reusable = drain(&c, in, &r);

        if (!c._sent) {
            sendDirect(&c, 200, "") catch return false;
        }
        return reusable;
    }

    /// The static file `path` names, if any set holds one. Only GET and
    /// HEAD: a POST to a `.css` is a mistake, and answering it with the
    /// stylesheet would hide that.
    fn findStatic(self: *const App, method: http1.Method, path: []const u8) ?*const static_mod.File {
        if (method != .GET and method != .HEAD) return null;
        for (self.static_sets.items) |*set| {
            if (set.find(path)) |file| return file;
        }
        return null;
    }
};

/// Step over a body the handler never read, and say whether the
/// connection is still usable afterwards. A body that cannot be stepped
/// over — a chunked one whose sizes do not add up — leaves the stream at
/// an unknown byte, so the connection has to go; the response, though, is
/// still owed and still sent.
/// Two lines belong in a zfast root source file, and forgetting either one
/// fails quietly — the sort of quiet that costs an afternoon. Without
/// `std_options_debug_io`, `std.log` writes to stderr the blocking way and
/// parks the whole event loop behind it; without `std_options`, the
/// Engine's own debug lines bury yours. Neither can be set from a library,
/// so the next best thing is to say so once, by name, at startup.
fn checkRootWiring() void {
    if (comptime !@hasDecl(@import("root"), "std_options_debug_io")) std.log.warn(
        "std.log will block the event loop. Add to your root source file: " ++
            "pub const std_options_debug_io = zfast.debug_io;",
        .{},
    );
    if (comptime std.log.logEnabled(.debug, .zio)) std.log.warn(
        "the Engine's debug lines are switched on and will drown out your own. Add to your " ++
            "root source file: pub const std_options = zfast.std_options;",
        .{},
    );
}

fn drain(c: *Ctx, in: *std.Io.Reader, r: *const http1.Request) bool {
    if (!r.keep_alive or c._stream_desynced) return false;
    if (c._body != null) return true;
    http1.discardBody(in, r, ctx_mod.max_body) catch return false;
    return true;
}

/// The innermost call when no route matched. It is a normal handler so
/// that middleware wraps a 404 exactly as it wraps anything else.
fn notFoundHandler(c: *Ctx) anyerror!void {
    try c.sendText(404, "not found\n");
}

/// Answer with a file loaded at startup. Also a normal handler, so a
/// static response goes through the same middleware as everything else —
/// CORS included, which is what an asset served to another origin needs.
fn serveStaticFile(c: *Ctx) anyerror!void {
    const file = c._static_file.?;

    // Both belong to the loaded file, which outlives every request, so
    // there is nothing to copy.
    try c.setStaticHeader("ETag", file.etag);
    if (file.cache_control.len > 0) try c.setStaticHeader("Cache-Control", file.cache_control);

    // The ETag was computed when the file was read, so a repeat visitor
    // costs a comparison and a head — no body, no work.
    if (c.header("If-None-Match")) |sent| {
        if (static_mod.etagMatches(sent.view(), file.etag)) {
            return c.send(304, file.content_type, "");
        }
    }

    try c.send(200, file.content_type, file.bytes);
}

fn sendFinal(out: *std.Io.Writer, response: []const u8) void {
    out.writeAll(response) catch return;
    out.flush() catch return;
}

/// Responses App assembles itself — an empty 200, a failure response —
/// outside of `Ctx.send`. As there, the body does not go out for a HEAD,
/// and headers middleware added still go out: an error response that
/// silently drops its CORS headers is one a browser refuses to show, which
/// is the worst possible moment to lose them.
fn sendDirect(c: *Ctx, status: u16, body: []const u8) !void {
    c._sent = true;
    c._status = status;
    const keep_alive = c._request.keep_alive;
    if (c.method == .HEAD) return http1.writeResponseHeadOnly(
        c._out,
        status,
        http1.statusPhrase(status),
        "text/plain",
        body.len,
        keep_alive,
        c._extra_headers.items,
    );
    try http1.writeResponse(
        c._out,
        status,
        http1.statusPhrase(status),
        "text/plain",
        body,
        keep_alive,
        c._extra_headers.items,
    );
}

/// Turn a handler failure into a response. A fail function's message is
/// used if there is one; otherwise the error goes through the mapping
/// table, and anything unrecognised becomes a 500 logged with its error
/// name (ADR 0005).
fn sendFailure(c: *Ctx, failure: *const fail.Failure, err: anyerror) !void {
    var buf: [fail.max_message + 1]u8 = undefined;

    const status = fail.resolveStatus(failure, err);
    const message: []const u8 = if (failure.isSet()) failure.message() else blk: {
        if (status == 500) {
            std.log.warn(
                "handler {s} {s} failed: {s}",
                .{ @tagName(c.method), c._path, @errorName(err) },
            );
            // Internal error names are not leaked to the client; anyone who
            // wants a readable message uses a fail function.
            break :blk "internal server error";
        }
        break :blk http1.statusPhrase(status);
    };

    // The message line ends in a newline so it reads nicely under curl.
    const body = std.fmt.bufPrint(&buf, "{s}\n", .{message}) catch message;
    try sendDirect(c, status, body);
}

// ---- tests: all of App's HTTP behaviour, without starting a server ----

const testing = std.testing;
const Str = str_mod.Str;

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    lifetime: str_mod.Lifetime = .{},
    in_flight: fail.InFlight = .{},
    buf: [4096]u8 = undefined,
    restore_log_level: std.log.Level,

    fn init() Harness {
        // Several tests below drive a handler into failure on purpose, and
        // App logs each one — correctly, but to the test runner's stderr,
        // where it makes a passing suite print `failed command`. The lines
        // are the behaviour under test, not news, so they are turned off
        // for as long as the harness is up.
        const previous = testing.log_level;
        testing.log_level = .err;
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .restore_log_level = previous,
        };
    }

    fn deinit(self: *Harness) void {
        testing.log_level = self.restore_log_level;
        self.arena.deinit();
    }

    /// Resolve middleware chains the way `listen()` would, then send.
    fn ready(self: *Harness, app: *App) !void {
        _ = self;
        try app.resolveChains();
    }

    fn send(self: *Harness, app: *App, request: []const u8) struct { response: []const u8, keep_alive: bool } {
        var in = std.Io.Reader.fixed(request);
        var out = std.Io.Writer.fixed(&self.buf);
        const keep_alive = app.handleRequest(self.arena.allocator(), &self.lifetime, &self.in_flight, &in, &out);
        self.lifetime.end();
        _ = self.arena.reset(.retain_capacity);
        return .{ .response = out.buffered(), .keep_alive = keep_alive };
    }
};

fn testGetUser(c: *Ctx) anyerror!void {
    const id = try c.param("id").?.int(u32);
    try c.sendJson(200, .{ .id = id, .name = "tester" });
}

fn testEchoJson(c: *Ctx) anyerror!void {
    const Incoming = struct { message: []const u8 };
    const incoming = try c.json(Incoming);
    try c.sendJson(201, .{ .echo = incoming.message });
}

fn testExplode(_: *Ctx) anyerror!void {
    return error.DeliberateExplosion;
}

fn testQuiet(_: *Ctx) anyerror!void {}

test "a GET with a path param answers JSON and the connection continues" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", testGetUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(result.keep_alive);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":42,\"name\":\"tester\"}") != null);
}

test "POST JSON in, JSON out" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", testEchoJson);

    var h = Harness.init();
    defer h.deinit();
    const body = "{\"message\":\"hello\"}";
    var request_buf: [256]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "POST /echo HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    const result = h.send(&app, request);

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"echo\":\"hello\"}") != null);
}

test "an unknown route answers 404 and the body is still discarded" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/here", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /nowhere HTTP/1.1\r\nContent-Length: 4\r\n\r\nxxxxGET /here HTTP/1.1\r\n\r\n");
    try testing.expect(result.keep_alive);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 404 Not Found\r\n"));
}

test "an unrecognised error becomes a 500, but the connection stays alive" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/explode", testExplode);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /explode HTTP/1.1\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 500 Internal Server Error\r\n"));
    // Not a single byte of a response had gone out when the handler
    // failed, so the connection is still clean and may be reused.
    try testing.expect(result.keep_alive);
    // The internal error name does not leak to the client.
    try testing.expect(std.mem.indexOf(u8, result.response, "DeliberateExplosion") == null);
}

test "a handler that fails after answering closes the connection" {
    const Partial = struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, "half");
            return error.DeliberateExplosion;
        }
    };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/half", Partial.run);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /half HTTP/1.1\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(!result.keep_alive);
}

test "a quiet handler answers an empty 200" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/quiet", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /quiet HTTP/1.1\r\n\r\n");
    try testing.expect(result.keep_alive);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n"));
}

fn testHeaderAndQuery(c: *Ctx) anyerror!void {
    try testing.expectEqualStrings("zig", c.query("word").?.view());
    try testing.expectEqualStrings("", c.query("empty").?.view());
    try testing.expect(c.query("absent") == null);
    try testing.expectEqualStrings("secret", c.header("X-Token").?.view());
    try testing.expectEqualStrings("secret", c.header("x-token").?.view());
    try c.sendText(200, "ok");
}

test "query params and headers are readable from Ctx" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/search", testHeaderAndQuery);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /search?word=zig&empty= HTTP/1.1\r\nX-Token: secret\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200"));
}

// ---- stage 3: typed handlers, services, fail functions ----

const Db = struct {
    rows: []const Row,

    const Row = struct { id: u32, name: []const u8 };

    fn find(self: *const Db, id: u32) ?Row {
        for (self.rows) |row| {
            if (row.id == id) return row;
        }
        return null;
    }
};

const UserOut = struct { id: u32, name: []const u8 };

/// The shape the README has been promising: an ordinary function, no
/// `Ctx`, no fake HTTP, with the service asked for by its type.
fn getUser(db: *Db, id: u32) !UserOut {
    const row = db.find(id) orelse return fail.notFound("no user {d}", .{id});
    return .{ .id = row.id, .name = row.name };
}

test "typed handler: service and path param matched by type" {
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.checkServices();

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /users/7 HTTP/1.1\r\n\r\n");

    try testing.expect(result.keep_alive);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":7,\"name\":\"wati\"}") != null);
}

// The main selling point (ADR 0003): a handler is tested as an ordinary
// function, without starting a server and without fake HTTP.
test "a typed handler can be tested as an ordinary function" {
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };

    try testing.expectEqual(@as(u32, 7), (try getUser(&db, 7)).id);
    try testing.expectError(error.Failed, getUser(&db, 99));
}

test "a fail function becomes its status and message, connection stays alive" {
    var db = Db{ .rows = &.{} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /users/99 HTTP/1.1\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "no user 99") != null);
    try testing.expect(result.keep_alive);
}

test "a path param that is not a number becomes a 400 with a clear message" {
    var db = Db{ .rows = &.{} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /users/abc HTTP/1.1\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, ":id has to be a whole number") != null);
    try testing.expect(result.keep_alive);
}

test "the Failure does not leak into the next request on the same connection" {
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);

    var h = Harness.init();
    defer h.deinit();

    const failed_first = h.send(&app, "GET /users/99 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, failed_first.response, "HTTP/1.1 404"));

    const then_succeeded = h.send(&app, "GET /users/7 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, then_succeeded.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, then_succeeded.response, "no user") == null);
}

const NewUser = struct { name: Str };

fn createUser(incoming: NewUser) !typed.Response(UserOut) {
    if (incoming.name.len() == 0) return fail.unprocessable("name must not be empty", .{});
    return .{ .status = 201, .value = .{ .id = 1, .name = incoming.name.view() } };
}

test "a JSON body comes in as a struct, Response(T) sets the status" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", createUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users HTTP/1.1\r\nContent-Length: 16\r\n\r\n{\"name\":\"wati\"}\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":1,\"name\":\"wati\"}") != null);
}

test "a JSON body that breaks a rule becomes a 422 via a fail function" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", createUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users HTTP/1.1\r\nContent-Length: 12\r\n\r\n{\"name\":\"\"}\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 422 Unprocessable Content\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "name must not be empty") != null);
}

test "broken JSON goes through the mapping table and becomes a 400" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", createUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users HTTP/1.1\r\nContent-Length: 5\r\n\r\n{name");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(result.keep_alive);
}

const Sort = enum { newest, oldest };

const SearchParams = struct {
    q: Str,
    page: u32 = 1,
    sort: Sort = .newest,
    tag: ?Str = null,
};

fn search(params: typed.Query(SearchParams)) !struct {
    q: []const u8,
    page: u32,
    sort: Sort,
    tag: ?[]const u8,
} {
    const p = params.value;
    return .{
        .q = p.q.view(),
        .page = p.page,
        .sort = p.sort,
        .tag = if (p.tag) |t| t.view() else null,
    };
}

test "Query(T) fills from the query string: defaults, optionals, decoding" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/search", search);

    var h = Harness.init();
    defer h.deinit();

    // Only the required field given: the rest fall back to their defaults.
    const bare = h.send(&app, "GET /search?q=zig HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, bare.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(
        u8,
        bare.response,
        "{\"q\":\"zig\",\"page\":1,\"sort\":\"newest\",\"tag\":null}",
    ) != null);

    // Everything given, and percent-decoded on the way in like a path param.
    const full = h.send(&app, "GET /search?q=hello%20world&page=3&sort=oldest&tag=a+b HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(
        u8,
        full.response,
        "{\"q\":\"hello world\",\"page\":3,\"sort\":\"oldest\",\"tag\":\"a b\"}",
    ) != null);
}

test "a query param that is missing or malformed is a 400 that says which one" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/search", search);

    var h = Harness.init();
    defer h.deinit();

    // No default and not optional, so absent is the client's mistake.
    const missing = h.send(&app, "GET /search HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, missing.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(std.mem.indexOf(u8, missing.response, "?q is required") != null);

    const not_a_number = h.send(&app, "GET /search?q=zig&page=soon HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, not_a_number.response, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(
        u8,
        not_a_number.response,
        "?page has to be a whole number, not \"soon\"",
    ) != null);

    // An enum says what it would have accepted, rather than only refusing.
    const bad_enum = h.send(&app, "GET /search?q=zig&sort=sideways HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, bad_enum.response, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, bad_enum.response, "newest, oldest") != null);

    // The connection survives all of it: a 400 is an answer, not a hang-up.
    try testing.expect(missing.keep_alive and not_a_number.keep_alive and bad_enum.keep_alive);
}

fn createWithLocation() typed.Response(UserOut) {
    return .{
        .status = 201,
        .headers = &.{
            .{ .name = "Location", .value = "/users/7" },
            .{ .name = "X-Made-By", .value = "zfast" },
        },
        .value = .{ .id = 7, .name = "wati" },
    };
}

test "Response(T) carries headers of its own, without reaching for a Ctx" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", createWithLocation);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Location: /users/7\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Made-By: zfast\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":7,\"name\":\"wati\"}") != null);
}

fn createInArena(arena: std.mem.Allocator, id: u32) !typed.Response(UserOut) {
    return .{
        .status = 201,
        .headers = &.{.{
            .name = "Location",
            .value = try std.fmt.allocPrint(arena, "/users/{d}", .{id}),
        }},
        .value = .{ .id = id, .name = "made" },
    };
}

test "a handler can ask for the request arena to build a header in" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users/:id", createInArena);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users/42 HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Location: /users/42\r\n") != null);

    // The arena is reset between requests, so a second one is not looking
    // at what the first left behind.
    const again = h.send(&app, "POST /users/7 HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, again.response, "Location: /users/7\r\n") != null);
}

fn serveAnything(rest: Str) Str {
    return rest;
}

test "a catch-all route hands the rest of the path to the handler" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/files/*", serveAnything);
    try app.get("/files/readme", plainOk);

    var h = Harness.init();
    defer h.deinit();

    const deep = h.send(&app, "GET /files/css/site.css HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, deep.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, deep.response, "css/site.css"));

    // A literal route still wins over the catch-all it sits inside.
    const literal = h.send(&app, "GET /files/readme HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, literal.response, "handler"));

    const nothing = h.send(&app, "GET /elsewhere HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, nothing.response, "HTTP/1.1 404"));
}

test "the same route registered twice is refused, naming the one already there" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", getUser);

    // The message goes to std.log.err, which the test runner counts as a
    // failure — so what is checked here is the refusal itself. The wording
    // lives in `App.route`, and the shape rule is covered in router.zig.
    try testing.expect(app.router.conflicting(.GET, "/users/:name") != null);
    try testing.expect(app.router.conflicting(.GET, "/users/me") == null);
    try testing.expectEqual(@as(usize, 1), app.router.routes.items.len);
}

fn greet(name: Str) Str {
    return name;
}

fn multiply(a: i32, b: i32) i64 {
    return @as(i64, a) * b;
}

const Colour = enum { red, green, blue };

fn pickColour(c: Colour, bright: bool) []const u8 {
    return if (bright) @tagName(c) else "dark";
}

test "path params typed as Str, a number, an enum, and a bool" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/greet/:name", greet);
    try app.get("/times/:a/:b", multiply);
    try app.get("/colour/:c/:bright", pickColour);

    var h = Harness.init();
    defer h.deinit();

    const greeting = h.send(&app, "GET /greet/wati HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, greeting.response, "Content-Type: text/plain") != null);
    try testing.expect(std.mem.endsWith(u8, greeting.response, "wati"));

    const product = h.send(&app, "GET /times/6/7 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, product.response, "42"));

    const colour = h.send(&app, "GET /colour/green/true HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, colour.response, "green"));

    const wrong = h.send(&app, "GET /colour/purple/true HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, wrong.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(std.mem.indexOf(u8, wrong.response, ":c is not one of the known choices") != null);
}

test "a service that was never registered is caught before serving" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", getUser); // needs *Db, which is not provided

    // `listen()` calls `checkServices()`, which logs each gap and then
    // fails. Here it is checked through the predicate instead, so the test
    // does not count those error logs as a failure.
    const missing = app.missingService().?;
    try testing.expectEqualStrings("/users/:id", missing.route);
    try testing.expectEqualStrings(@typeName(Db), missing.type_name);
    try testing.expect(missing.needs_mutable);
}

const Config = struct { debug: bool };

fn showMode(cfg: *const Config, c: *Ctx) !void {
    try c.sendText(200, if (cfg.debug) "debug" else "release");
}

test "a const service and a *Ctx can be asked for together" {
    const cfg = Config{ .debug = true };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&cfg);
    try app.get("/mode", showMode);
    try app.checkServices();

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /mode HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, result.response, "debug"));
}

test "HEAD gives the same head as GET, with no body" {
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.head("/users/:id", getUser);

    var h = Harness.init();
    defer h.deinit();

    const got = h.send(&app, "GET /users/7 HTTP/1.1\r\n\r\n");
    const got_head = got.response[0 .. std.mem.indexOf(u8, got.response, "\r\n\r\n").? + 4];

    const headed = h.send(&app, "HEAD /users/7 HTTP/1.1\r\n\r\n");

    // The head is identical — including the Content-Length naming the
    // length of the body it would have sent — but not one byte of body.
    try testing.expectEqualStrings(got_head, headed.response);
    try testing.expect(std.mem.indexOf(u8, headed.response, "Content-Length: 22\r\n") != null);
    try testing.expect(headed.keep_alive);
}

test "HEAD on an unknown route and on the failure path is also body-less" {
    var db = Db{ .rows = &.{} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.head("/users/:id", getUser);

    var h = Harness.init();
    defer h.deinit();

    const failed = h.send(&app, "HEAD /users/99 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, failed.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.endsWith(u8, failed.response, "\r\n\r\n"));
    try testing.expect(std.mem.indexOf(u8, failed.response, "no user 99") == null);

    const unrouted = h.send(&app, "HEAD /nowhere HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, unrouted.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.endsWith(u8, unrouted.response, "\r\n\r\n"));
}

fn ctxOnly(c: *Ctx) !void {
    // A `*Ctx` handler may ignore the path params in the pattern; it
    // fetches whichever ones it needs itself.
    try c.sendText(200, c.param("id").?.view());
}

test "a *Ctx handler need not declare the path params" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/raw/:id/:other", ctxOnly);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /raw/42/x HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, result.response, "42"));
}

// ---- stage 4: response headers and middleware ----

fn setsHeaders(c: *Ctx) anyerror!void {
    try c.setHeader("X-One", "1");
    try c.setHeader("X-Two", "2");
    try c.sendText(200, "ok");
}

test "extra response headers are written after the framework's own" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/h", setsHeaders);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /h HTTP/1.1\r\n\r\n");
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n" ++
            "Connection: keep-alive\r\nX-One: 1\r\nX-Two: 2\r\n\r\nok",
        result.response,
    );
}

fn reservedHeader(c: *Ctx) anyerror!void {
    try testing.expectError(error.ReservedHeader, c.setHeader("Content-Length", "999"));
    try testing.expectError(error.ReservedHeader, c.setHeader("connection", "close"));
    // Setting the same header twice replaces it rather than sending both.
    try c.setHeader("X-Once", "first");
    try c.setHeader("x-once", "second");
    try c.sendText(200, "ok");
}

test "framework-owned headers are refused, repeats replace" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/h", reservedHeader);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /h HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "x-once: second") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "first") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.response, "Content-Length:"));
}

fn tagOuter(c: *Ctx, next: mw.Next) anyerror!void {
    try c.setHeader("X-Order", "outer");
    try next.run(c);
}

fn tagInner(c: *Ctx, next: mw.Next) anyerror!void {
    try c.setHeader("X-Inner", "yes");
    try next.run(c);
}

fn rejectingMiddleware(_: *Ctx, _: mw.Next) anyerror!void {
    return fail.unauthorized("no token", .{});
}

fn answeringMiddleware(c: *Ctx, _: mw.Next) anyerror!void {
    try c.sendText(200, "from middleware");
}

fn plainOk(c: *Ctx) anyerror!void {
    try c.sendText(200, "handler");
}

test "middleware wraps the handler and can set response headers" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(tagOuter);
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Order: outer") != null);
    try testing.expect(std.mem.endsWith(u8, result.response, "handler"));
}

test "use and get can be registered in either order" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    // Route first, middleware second — Fiber's classic gotcha, where the
    // middleware would silently never run.
    try app.get("/x", plainOk);
    try app.use(tagOuter);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Order: outer") != null);
}

test "a prefix scopes middleware to the routes under it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.useOn("/api", tagInner);
    try app.get("/api/thing", plainOk);
    try app.get("/health", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const on = h.send(&app, "GET /api/thing HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, on.response, "X-Inner: yes") != null);

    const off = h.send(&app, "GET /health HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, off.response, "X-Inner") == null);
}

test "middleware that answers short-circuits the handler" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(answeringMiddleware);
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, result.response, "from middleware"));
}

test "middleware failing goes through the same path as a handler failing" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.useOn("/api", rejectingMiddleware);
    try app.get("/api/secret", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /api/secret HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 401 Unauthorized\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "no token") != null);
    try testing.expect(result.keep_alive);
}

test "middleware runs even when no route matched" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(tagOuter);
    try app.get("/known", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /nowhere HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 404 Not Found\r\n"));
    // A logger has to be able to see 404s, and CORS has to answer
    // preflights for paths with no route (ADR 0009).
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Order: outer") != null);
}

test "CORS adds its headers and answers a preflight" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.permissive);
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const normal = h.send(&app, "GET /x HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, normal.response, "Access-Control-Allow-Origin: *") != null);
    try testing.expect(std.mem.endsWith(u8, normal.response, "handler"));

    // A preflight on a path with no OPTIONS route is still answered.
    const preflight = h.send(
        &app,
        "OPTIONS /x HTTP/1.1\r\nAccess-Control-Request-Method: POST\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, preflight.response, "HTTP/1.1 204 No Content\r\n"));
    try testing.expect(std.mem.indexOf(u8, preflight.response, "Access-Control-Allow-Methods:") != null);
    try testing.expect(std.mem.indexOf(u8, preflight.response, "Access-Control-Allow-Headers:") != null);
}

fn alwaysFails(_: *Ctx) anyerror!void {
    return fail.notFound("nope", .{});
}

test "headers middleware set survive onto a failure response" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.permissive);
    try app.get("/gone", alwaysFails);
    try app.get("/quiet2", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // An error response that quietly dropped its CORS headers is one the
    // browser refuses to show — the worst moment to lose them.
    const failed = h.send(&app, "GET /gone HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, failed.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.indexOf(u8, failed.response, "Access-Control-Allow-Origin: *") != null);

    // Same for the empty 200 App fills in when a handler sends nothing.
    const quiet = h.send(&app, "GET /quiet2 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, quiet.response, "Access-Control-Allow-Origin: *") != null);
}

test "CORS with a named origin also sends Vary" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.with(.{ .origin = "https://example.com", .credentials = true }));
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "Access-Control-Allow-Origin: https://example.com") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "Vary: Origin") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "Access-Control-Allow-Credentials: true") != null);
}

// ---- stage 5: percent-decoding, chunked bodies, static files ----

fn echoParamAndQuery(c: *Ctx) anyerror!void {
    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{s}|{s}", .{
        c.param("name").?.view(),
        if (c.query("q")) |q| q.view() else "-",
    });
    try c.sendText(200, text);
}

test "path params and query values arrive decoded" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/hello/:name", echoParamAndQuery);

    var h = Harness.init();
    defer h.deinit();

    const spaced = h.send(&app, "GET /hello/wati%20sari?q=caf%C3%A9+latte HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, spaced.response, "wati sari|café latte"));

    // An encoded slash is one character of data. Had the target been
    // decoded before matching, this would have been three segments and
    // would not have matched /hello/:name at all.
    const slashed = h.send(&app, "GET /hello/a%2Fb HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, slashed.response, "a/b|-"));
}

fn echoBody(c: *Ctx) anyerror!void {
    try c.sendText(200, (try c.body()).view());
}

test "a chunked body reaches the handler and keep-alive survives it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoBody);
    try app.get("/after", plainOk);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(
        &app,
        "POST /echo HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, result.response, "hello world"));
    try testing.expect(result.keep_alive);
}

test "a chunked body nobody read is still stepped over" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/ignore", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    // Two requests down one connection: the second only parses if the
    // first body was consumed to exactly the right byte.
    var in = std.Io.Reader.fixed(
        "POST /ignore HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n" ++
            "GET /ignore HTTP/1.1\r\n\r\n",
    );
    var out = std.Io.Writer.fixed(&h.buf);
    try testing.expect(app.handleRequest(h.arena.allocator(), &h.lifetime, &h.in_flight, &in, &out));

    const next = try http1.readRequest(&in);
    try testing.expectEqualStrings("/ignore", next.target);
}

test "a chunked body whose sizes do not add up gets a 400, not silence" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoBody);

    var h = Harness.init();
    defer h.deinit();
    // Says 5 bytes, then does not put a CRLF where one has to be.
    const result = h.send(
        &app,
        "POST /echo HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX\r\n0\r\n\r\n",
    );

    // The stream is at an unknown byte now, so the connection goes — but
    // the client is still told why rather than having the door shut on it.
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(!result.keep_alive);
}

test "HEAD with no HEAD route falls back to the GET one" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/page", plainOk);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "HEAD /page HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Content-Length: 7\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, result.response, "\r\n\r\n")); // no body
}

/// A directory of real files on disk, written for one test and removed
/// after it. Returned as a path relative to the working directory, which
/// is what `app.static` takes.
const TmpFiles = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init(gpa: std.mem.Allocator, files: []const [2][]const u8) !TmpFiles {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        for (files) |entry| {
            if (std.fs.path.dirname(entry[0])) |sub| try tmp.dir.createDirPath(std.testing.io, sub);
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = entry[0], .data = entry[1] });
        }
        return .{
            .tmp = tmp,
            .path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path}),
        };
    }

    fn deinit(self: *TmpFiles, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        self.tmp.cleanup();
    }
};

test "static files: content type, ETag, 304, index and the dotfile that is not served" {
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "index.html", "<h1>home</h1>" },
        .{ "app.css", "body{}" },
        .{ "docs/index.html", "<h1>docs</h1>" },
        .{ ".env", "SECRET=1" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static("/", files.path);

    var h = Harness.init();
    defer h.deinit();

    const css = h.send(&app, "GET /app.css HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, css.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, css.response, "Content-Type: text/css; charset=utf-8") != null);
    try testing.expect(std.mem.indexOf(u8, css.response, "Cache-Control: public, max-age=3600") != null);
    try testing.expect(std.mem.endsWith(u8, css.response, "body{}"));

    // A directory path picks up its index.html.
    const home = h.send(&app, "GET / HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, home.response, "<h1>home</h1>"));
    const docs = h.send(&app, "GET /docs/ HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, docs.response, "<h1>docs</h1>"));

    // A dotfile that found its way into the directory is not published.
    const dotfile = h.send(&app, "GET /.env HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, dotfile.response, "HTTP/1.1 404"));

    // The ETag the last response carried, handed back, costs no body.
    const etag = app.findStatic(.GET, "/app.css").?.etag;
    var request_buf: [256]u8 = undefined;
    const conditional = std.fmt.bufPrint(
        &request_buf,
        "GET /app.css HTTP/1.1\r\nIf-None-Match: {s}\r\n\r\n",
        .{etag},
    ) catch unreachable;
    const not_modified = h.send(&app, conditional);
    try testing.expect(std.mem.startsWith(u8, not_modified.response, "HTTP/1.1 304 Not Modified\r\n"));
    try testing.expect(std.mem.indexOf(u8, not_modified.response, "body{}") == null);
}

test "static files: routes win, a prefix scopes, and middleware still wraps" {
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "app.js", "console.log(1)" },
        .{ "index.html", "spa" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.permissive);
    try app.staticWith("/assets", files.path, .{ .spa_fallback = "index.html" });
    try app.get("/assets/app.js", plainOk); // deliberately shadows the file

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // A route beats a file of the same name.
    const shadowed = h.send(&app, "GET /assets/app.js HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, shadowed.response, "handler"));

    // The SPA fallback catches a deep link under the prefix — and CORS,
    // registered as ordinary middleware, wraps the static response too.
    const deep = h.send(&app, "GET /assets/users/42 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, deep.response, "spa"));
    try testing.expect(std.mem.indexOf(u8, deep.response, "Access-Control-Allow-Origin: *") != null);

    // Outside the prefix nothing is claimed.
    const outside = h.send(&app, "GET /users/42 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, outside.response, "HTTP/1.1 404"));
}

test "static files: HEAD gives the head, POST is not answered with the file" {
    var files = try TmpFiles.init(testing.allocator, &.{.{ "logo.svg", "<svg/>" }});
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static("/", files.path);

    var h = Harness.init();
    defer h.deinit();

    const headed = h.send(&app, "HEAD /logo.svg HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, headed.response, "Content-Length: 6\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, headed.response, "\r\n\r\n"));

    const posted = h.send(&app, "POST /logo.svg HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, posted.response, "HTTP/1.1 404"));
}

// A number that is the same on every machine, unlike requests per second
// on a shared VM (docs/plan.md, "Where to measure"). It will not tell you
// how fast the server is, but it does notice the day somebody puts an
// allocation back onto the path everything goes down.
test "the request path stays inside its allocation budget" {
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.use(cors.permissive);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    // The shape of the primary metric: a routed GET with a path param
    // answering JSON, on a keep-alive connection, with CORS installed.
    const request = "GET /users/7 HTTP/1.1\r\nHost: example.dev\r\nUser-Agent: wrk\r\n" ++
        "Accept: */*\r\nAccept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out);
            l.end();
        }
    }.once;

    // Warm the arena first: growing it is a cost of the connection's first
    // request, not of the path being measured.
    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }

    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // Three, and what each one is for:
    //   1. the request head, copied so its Strs outlive the read buffer
    //   2. the list of response headers CORS adds
    //   3. the JSON body
    // All three are bump allocations into an arena that is already warm.
    // Raising this number needs a reason; lowering it is welcome.
    try testing.expectEqual(@as(usize, 3), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);
}

test "the in-flight request is readable, which is what the panic handler uses" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/known", plainOk);

    var h = Harness.init();
    defer h.deinit();
    _ = h.send(&app, "GET /known HTTP/1.1\r\n\r\n");

    // App records these before running the chain, so a panic anywhere
    // inside it can name the request (ADR 0008).
    try testing.expectEqualStrings("GET", h.in_flight.method);
    try testing.expectEqualStrings("/known", h.in_flight.path);
}
