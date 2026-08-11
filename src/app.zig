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
const openapi = @import("openapi.zig");
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
    /// What each route's signature says about it, collected as routes are
    /// registered and turned into an OpenAPI document by `listen()` if
    /// `docs()` asked for one (ADR 0017).
    operations: std.ArrayList(openapi.Operation) = .empty,
    docs_options: ?openapi.Options = null,
    /// The generated document and its reader page, held the way a loaded
    /// directory is so that ETags and 304s arrive without a second code
    /// path. Null until `listen()` builds it.
    docs_set: ?static_mod.Set = null,
    /// Set when the server should stop. Read by the Engine's accept loop
    /// and by every connection between requests.
    stop: bulkhead.Stop = .{},

    pub fn init(gpa: std.mem.Allocator) App {
        return .{
            .gpa = gpa,
            .router = router_mod.Router.init(gpa),
            .services = service_mod.Registry.init(gpa),
        };
    }

    pub fn deinit(self: *App) void {
        self.freeChains();
        if (self.docs_set) |*set| set.deinit();
        self.operations.deinit(self.gpa);
        for (self.static_sets.items) |*s| s.deinit();
        self.static_sets.deinit(self.gpa);
        self.scoped.deinit(self.gpa);
        self.requirements.deinit(self.gpa);
        self.services.deinit();
        self.router.deinit();
    }

    /// Everything registered through the returned value sits under
    /// `prefix` — routes, middleware, static files and further groups
    /// (ADR 0015).
    ///
    /// ```zig
    /// const api = app.group("/api/v1");
    /// try api.use(requireToken);            // only /api/v1/…
    /// try api.get("/users/:id", getUser);   // → /api/v1/users/:id
    /// ```
    ///
    /// It is also how a plugin is written, because a plugin is nothing more
    /// than a function that takes one of these:
    ///
    /// ```zig
    /// fn health(g: anytype) !void {
    ///     try g.get("/healthz", ok);
    /// }
    ///
    /// try health(app.group("/internal"));
    /// ```
    ///
    /// The prefix is compile-time text, so the pattern the route is
    /// registered under is one literal — the same thing you would have
    /// typed, and the same thing every error message quotes back at you.
    pub fn group(self: *App, comptime prefix: []const u8) Group(prefix) {
        return .{ .app = self };
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
    ///
    /// A directory that cannot be loaded says why in one line and stops the
    /// process, for the reason `listen()` and `route()` do: the sentence
    /// naming the missing directory is the whole answer, and letting the
    /// error travel back to `main` prints a stack trace through zfast's own
    /// files on top of it (ADR 0002). `tryStatic` is the same call with the
    /// error as a value.
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
        self.tryStaticWith(url_prefix, dir_path, opts) catch |err| {
            if (static_mod.explained(err)) std.process.exit(1);
            return err;
        };
    }

    /// `static`, for a caller that would rather handle a missing directory
    /// than have the process stopped under it — a test, or a program with a
    /// fallback. The one-line explanation still goes to the log; what
    /// changes is that the error comes back as a value.
    pub fn tryStatic(self: *App, url_prefix: []const u8, dir_path: []const u8) !void {
        return self.tryStaticWith(url_prefix, dir_path, .{});
    }

    /// `staticWith`, with the error as a value. See `tryStatic`.
    pub fn tryStaticWith(
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
    ///
    /// A route that collides with one already registered says so in one
    /// line and stops the process, for the same reason `listen()` does:
    /// letting the error travel back to `main` prints a stack trace through
    /// zfast's own files on top of the answer, and which file inside the
    /// framework noticed the collision is not the user's problem (ADR
    /// 0002). `tryRoute` is the same call with the error as a value.
    pub fn route(
        self: *App,
        method: http1.Method,
        comptime pattern: []const u8,
        comptime handler: anytype,
    ) !void {
        self.tryRoute(method, pattern, handler) catch |err| {
            if (err == error.DuplicateRoute) std.process.exit(1);
            return err;
        };
    }

    /// `route`, for a caller that would rather handle a collision than have
    /// the process stopped under it — a test, or a program building its
    /// routes from a list. The one-line explanation still goes to the log;
    /// what changes is that the error comes back as a value.
    pub fn tryRoute(
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

        // Read from the same argument list `wrap` just read, so the
        // description of an endpoint and the code that serves it cannot
        // drift apart (ADR 0017). Comptime data, so what is appended here is
        // one struct of slices pointing at read-only memory.
        var op = comptime typed.operation(pattern, handler);
        op.method = method;
        try self.operations.append(self.gpa, op);
    }

    /// Serve a description of this API, worked out from the handler
    /// signatures (ADR 0017).
    ///
    /// ```zig
    /// app.docs(.{ .title = "Orders", .version = "2.0.0" });
    /// ```
    ///
    /// The document lands at `/openapi.json` and a page for reading it at
    /// `/docs`. Both are built when `listen()` resolves the routes, so it
    /// does not matter whether this is called before or after them — the
    /// same order-independence `use` and `get` have (ADR 0009).
    ///
    /// Routes win over both paths, so registering a `/docs` of your own
    /// still gets its way.
    pub fn docs(self: *App, opts: openapi.Options) void {
        self.docs_options = opts;
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

        // One message per missing service, not one per route that wanted
        // it. Five routes sharing a `*Db` is the normal shape of an app, so
        // forgetting to provide it used to print the same sentence — and
        // the same fix — five times over.
        for (self.requirements.items, 0..) |r, i| {
            if (self.services.has(r)) continue;
            if (alreadyReported(self.requirements.items[0..i], r)) continue;

            var routes: [3][]const u8 = undefined;
            var n: usize = 0;
            var total: usize = 0;
            for (self.requirements.items) |other| {
                if (!sameService(other, r)) continue;
                total += 1;
                if (n < routes.len) {
                    routes[n] = other.route;
                    n += 1;
                }
            }

            std.log.err(
                "service {s}{s} was never registered, but {d} route{s} need{s} it ({f}{s}) " ++
                    "— call app.provide() before app.listen()",
                .{
                    if (r.needs_mutable) "*" else "*const ",
                    r.type_name,
                    total,
                    if (total == 1) "" else "s",
                    if (total == 1) "s" else "",
                    RouteList{ .routes = routes[0..n] },
                    if (total > n) ", …" else "",
                },
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
        try self.buildDocs();
    }

    /// Turn the collected operations into the document and its reader page.
    /// Here rather than in `docs()` because every route has to be registered
    /// first, and here rather than on the request path because the answer
    /// cannot change once the server is running.
    fn buildDocs(self: *App) !void {
        if (self.docs_set) |*set| {
            set.deinit();
            self.docs_set = null;
        }
        const opts = self.docs_options orelse return;

        var document: std.Io.Writer.Allocating = .init(self.gpa);
        defer document.deinit();
        try openapi.write(&document.writer, self.operations.items, .{
            .title = opts.title,
            .version = opts.version,
            .description = opts.description,
        });

        var page: std.Io.Writer.Allocating = .init(self.gpa);
        defer page.deinit();

        var entries: [2]static_mod.Entry = undefined;
        var n: usize = 0;
        entries[n] = .{
            .url = opts.path,
            .bytes = document.written(),
            .content_type = "application/json",
        };
        n += 1;

        if (opts.ui_path.len > 0) {
            try openapi.writeReaderPage(&page.writer, opts.title, opts.path);
            entries[n] = .{
                .url = opts.ui_path,
                .bytes = page.written(),
                .content_type = "text/html; charset=utf-8",
            };
            n += 1;
        }

        self.docs_set = try static_mod.fromMemory(self.gpa, entries[0..n]);
    }

    fn freeChains(self: *App) void {
        for (self.router.routes.items) |*r| {
            if (r.chain.len > 0) self.gpa.free(r.chain);
            r.chain = &.{};
        }
    }

    /// Listen and serve until the server is stopped — by Ctrl-C, by a
    /// SIGTERM from whatever is supervising the process, or by `shutdown()`.
    /// Returns once the requests still in flight have finished.
    ///
    /// A server that cannot start says why in one line and stops the
    /// process there. That is the whole point of those messages: letting
    /// the error travel back to `main` instead would print a stack trace
    /// through zfast's own files on top of the answer (ADR 0002). Use
    /// `tryListen` to get the error as a value and no message.
    pub fn listen(self: *App, options_: bulkhead.Options) !void {
        self.tryListen(options_) catch |err| {
            if (bulkhead.explained(err) or err == error.MissingService) std.process.exit(1);
            return err;
        };
    }

    /// `listen`, for a caller that would rather handle a startup failure
    /// than have the process stopped under it — a test, or a program that
    /// falls back to another port. The one-line explanations still go to
    /// the log; what changes is that the error comes back as a value.
    pub fn tryListen(self: *App, options_: bulkhead.Options) !void {
        checkRootWiring();
        try self.checkServices();
        try self.resolveChains();
        try bulkhead.serve(self.gpa, options_, &self.stop, self, handleConnection);
    }

    /// Stop the server: `listen()` stops accepting, connections finish the
    /// request they are on and close, and `listen()` returns.
    ///
    /// Safe to call from any thread, and from a handler — a `/admin/quit`
    /// route is an ordinary handler that calls this.
    pub fn shutdown(self: *App) void {
        self.stop.request();
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
        // From here there is a request to answer, and a stop has to wait for
        // it. Not before: until the head arrived this connection was parked
        // in a read, holding no work, and counting that as something to wait
        // on would put the whole grace period behind every idle browser tab.
        _ = self.stop.in_flight.fetchAdd(1, .acq_rel);
        defer _ = self.stop.in_flight.fetchSub(1, .acq_rel);

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
            // Stopping: this one still gets answered — a request already on
            // the wire is not the client's fault — but the answer says
            // `Connection: close` so the client opens a fresh connection
            // next time, to a server that is still there. Dropping a
            // keep-alive connection without a word is how a deploy turns
            // into a handful of failed requests nobody can reproduce.
            ._stopping = &self.stop.requested,
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
            } else {
                // No route for this method, but the path itself is spelled
                // out by routes under other methods. "There is nothing
                // here" and "there is something here, but not for that
                // verb" are different answers, and a 404 for the second one
                // sends you looking for a registration bug that is not
                // there.
                const allowed = self.router.allowedFor(path);
                if (allowed.count() > 0) {
                    c._allowed = allowed;
                    terminal = methodNotAllowedHandler;
                }
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
        if (c._stream != null) return endAbandonedStream(&c);
        return reusable;
    }

    /// The static file `path` names, if any set holds one. Only GET and
    /// HEAD: a POST to a `.css` is a mistake, and answering it with the
    /// stylesheet would hide that.
    fn findStatic(self: *const App, method: http1.Method, path: []const u8) ?*const static_mod.File {
        if (method != .GET and method != .HEAD) return null;
        // Asked before the loaded directories, not after. A single-page app
        // served from `/` with an `index.html` fallback answers for every
        // path there is, and it would swallow `/openapi.json` whole —
        // which is exactly the setup most likely to want the document.
        if (self.docs_set) |*set| {
            if (set.find(path)) |file| return file;
        }
        for (self.static_sets.items) |*set| {
            if (set.find(path)) |file| return file;
        }
        return null;
    }
};

/// One prefix and everything registered beneath it — what `app.group()`
/// hands back (ADR 0015).
///
/// The prefix is a compile-time parameter rather than a field, because the
/// route patterns have to be joined while compiling: `typed.wrap` reads the
/// pattern to work out what the handler's arguments mean, and a pattern
/// assembled at runtime would arrive too late for that.
///
/// Every method here forwards to the same one on `App` with the prefix
/// already on the front, so a group adds no layer to the request path and
/// nothing to `App`'s state. It is a way of typing less that disappears
/// entirely by the time the server runs.
pub fn Group(comptime prefix: []const u8) type {
    comptime checkPrefix(prefix);

    return struct {
        const Self = @This();

        app: *App,

        /// A group inside this one. `app.group("/api").group("/v1")` and
        /// `app.group("/api/v1")` are the same thing.
        pub fn group(self: Self, comptime sub: []const u8) Group(prefix ++ sub) {
            return .{ .app = self.app };
        }

        /// Middleware on everything in this group — `app.useOn(prefix, …)`,
        /// without repeating the prefix.
        pub fn use(self: Self, middleware: mw.Middleware) !void {
            if (prefix.len == 0) return self.app.use(middleware);
            return self.app.useOn(prefix, middleware);
        }

        /// Middleware on part of this group, `sub` being relative to it.
        pub fn useOn(self: Self, comptime sub: []const u8, middleware: mw.Middleware) !void {
            const full = comptime joined(prefix, sub);
            if (full.len == 0) return self.app.use(middleware);
            return self.app.useOn(full, middleware);
        }

        /// A service. Groups do not scope services — a `*Db` is a `*Db` to
        /// the whole App (ADR 0006) — but a plugin that brings its own has
        /// to be able to register it without being handed the App as well.
        pub fn provide(self: Self, ptr: anytype) !void {
            return self.app.provide(ptr);
        }

        pub fn get(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            return self.app.get(comptime joined(prefix, pattern), handler);
        }

        pub fn post(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            return self.app.post(comptime joined(prefix, pattern), handler);
        }

        pub fn put(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            return self.app.put(comptime joined(prefix, pattern), handler);
        }

        pub fn delete(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            return self.app.delete(comptime joined(prefix, pattern), handler);
        }

        pub fn patch(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            return self.app.patch(comptime joined(prefix, pattern), handler);
        }

        pub fn head(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            return self.app.head(comptime joined(prefix, pattern), handler);
        }

        pub fn options(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            return self.app.options(comptime joined(prefix, pattern), handler);
        }

        pub fn route(
            self: Self,
            method: http1.Method,
            comptime pattern: []const u8,
            comptime handler: anytype,
        ) !void {
            return self.app.route(method, comptime joined(prefix, pattern), handler);
        }

        pub fn tryRoute(
            self: Self,
            method: http1.Method,
            comptime pattern: []const u8,
            comptime handler: anytype,
        ) !void {
            return self.app.tryRoute(method, comptime joined(prefix, pattern), handler);
        }

        pub fn static(self: Self, comptime url_prefix: []const u8, dir_path: []const u8) !void {
            return self.app.static(comptime joined(prefix, url_prefix), dir_path);
        }

        pub fn staticWith(
            self: Self,
            comptime url_prefix: []const u8,
            dir_path: []const u8,
            opts: static_mod.Options,
        ) !void {
            return self.app.staticWith(comptime joined(prefix, url_prefix), dir_path, opts);
        }

        pub fn tryStatic(self: Self, comptime url_prefix: []const u8, dir_path: []const u8) !void {
            return self.app.tryStatic(comptime joined(prefix, url_prefix), dir_path);
        }

        pub fn tryStaticWith(
            self: Self,
            comptime url_prefix: []const u8,
            dir_path: []const u8,
            opts: static_mod.Options,
        ) !void {
            return self.app.tryStaticWith(comptime joined(prefix, url_prefix), dir_path, opts);
        }
    };
}

/// A group prefix is literal text with a leading slash and no trailing one.
fn checkPrefix(comptime prefix: []const u8) void {
    comptime {
        // The root group, which is what a plugin mounted at the top gets.
        if (prefix.len == 0) return;

        if (prefix[0] != '/') @compileError(
            "zfast: the group prefix \"" ++ prefix ++ "\" does not start with a slash.\n" ++
                "  Write `app.group(\"/" ++ prefix ++ "\")` — a prefix is the front of a path, " ++
                "and a path always begins with one.",
        );
        if (prefix[prefix.len - 1] == '/') @compileError(
            "zfast: the group prefix \"" ++ prefix ++ "\" ends with a slash.\n" ++
                "  Drop it: `app.group(\"" ++ prefix[0 .. prefix.len - 1] ++ "\")`. The patterns " ++
                "registered inside bring their own leading slash, and two would make " ++
                "\"" ++ prefix ++ "/users\".",
        );
        if (std.mem.indexOfAny(u8, prefix, ":*") != null) @compileError(
            "zfast: the group prefix \"" ++ prefix ++ "\" has a `:` or a `*` in it, and a group " ++
                "prefix is literal text.\n" ++
                "  The reason is `use`: middleware on a group is scoped by comparing the front of " ++
                "the request path against the prefix, and \"" ++ prefix ++ "\" is not the front " ++
                "of any real path — so every middleware on this group would quietly never run.\n" ++
                "  Put the param in the route patterns instead: " ++
                "`app.get(\"" ++ prefix ++ "/…\", …)`.",
        );
    }
}

/// `"/api" + "/users/:id"` → `"/api/users/:id"`, and `"/api" + "/"` →
/// `"/api"` rather than a pattern with a trailing slash in it.
fn joined(comptime prefix: []const u8, comptime pattern: []const u8) []const u8 {
    comptime {
        if (pattern.len == 0) @compileError(
            "zfast: a route pattern inside the group \"" ++ prefix ++ "\" cannot be empty.\n" ++
                "  Use \"/\" for the group's own path.",
        );
        if (pattern[0] != '/') @compileError(
            "zfast: the route pattern \"" ++ pattern ++ "\" inside the group \"" ++ prefix ++
                "\" does not start with a slash.\n" ++
                "  Patterns inside a group are written the same way as outside one, relative to " ++
                "the prefix: `\"/" ++ pattern ++ "\"` registers " ++
                "\"" ++ prefix ++ "/" ++ pattern ++ "\".",
        );
        // The group's own path. Joining plainly would give "/api/", which
        // matches the same requests but reads back wrong in every error
        // message and in the generated documentation.
        if (prefix.len > 0 and std.mem.eql(u8, pattern, "/")) return prefix;
        return prefix ++ pattern;
    }
}

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

/// Two requirements naming the same service, whatever route each came from.
fn sameService(a: service_mod.Requirement, b: service_mod.Requirement) bool {
    return a.needs_mutable == b.needs_mutable and std.mem.eql(u8, a.type_name, b.type_name);
}

fn alreadyReported(earlier: []const service_mod.Requirement, r: service_mod.Requirement) bool {
    for (earlier) |e| {
        if (sameService(e, r)) return true;
    }
    return false;
}

/// `"/users", "/users/:id"` — the routes that wanted a service, for the
/// message saying nobody provided it.
const RouteList = struct {
    routes: []const []const u8,

    pub fn format(self: RouteList, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.routes, 0..) |route, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("\"{s}\"", .{route});
        }
    }
};

fn drain(c: *Ctx, in: *std.Io.Reader, r: *const http1.Request) bool {
    if (!c.keepAlive() or c._stream_desynced) return false;
    if (c._body != null) return true;
    http1.discardBody(in, r, ctx_mod.max_body) catch return false;
    return true;
}

/// The innermost call when no route matched. It is a normal handler so
/// that middleware wraps a 404 exactly as it wraps anything else.
fn notFoundHandler(c: *Ctx) anyerror!void {
    try c.sendText(404, "not found\n");
}

/// The innermost call when the path is registered but not for this method.
///
/// A normal handler too, so a 405 carries whatever headers the middleware
/// added — CORS included, since a browser has to be able to read the answer
/// to see what went wrong.
fn methodNotAllowedHandler(c: *Ctx) anyerror!void {
    // Built in the request arena, which outlives the response it is written
    // into, so there is nothing for `setHeader` to copy.
    const allow = try allowList(c._arena, c._allowed);
    try c.setStaticHeader("Allow", allow);

    // An OPTIONS asking what a path supports is answered rather than
    // refused: that is the question the method exists for, and the `Allow`
    // header above is the answer. A preflight never gets this far — CORS
    // middleware handles those before any handler runs.
    if (c.method == .OPTIONS) return c.send(204, "text/plain", "");

    var buf: [160]u8 = undefined;
    const body = std.fmt.bufPrint(
        &buf,
        "{s} is not allowed here. This path answers: {s}\n",
        .{ @tagName(c.method), allow },
    ) catch "method not allowed\n";
    try c.sendText(405, body);
}

/// `GET, HEAD, POST` — an `Allow` header's value, in the order the methods
/// are declared so that two runs of the same server say the same thing.
fn allowList(arena: std.mem.Allocator, allowed: router_mod.MethodSet) ![]const u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(arena, 48);
    var first = true;
    inline for (@typeInfo(http1.Method).@"enum".fields) |f| {
        const method: http1.Method = @enumFromInt(f.value);
        // `other` is not a method anybody can register, so it has no
        // business being offered as one.
        if (method != .other and allowed.contains(method)) {
            if (!first) try out.writer.writeAll(", ");
            try out.writer.writeAll(f.name);
            first = false;
        }
    }
    return out.written();
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

/// A handler opened a stream and returned without calling `finish()`.
///
/// The zero-length chunk is written here so the client is told where the
/// body stopped instead of waiting for more, and so the connection is left
/// in a state the next request can start from. What cannot be recovered is
/// anything still in the stream's buffer — that lived in the handler's own
/// frame and went with it — which is why this says so out loud rather than
/// quietly tidying up (ADR 0020).
fn endAbandonedStream(c: *Ctx) bool {
    const open = c._stream.?;
    c._stream = null;
    std.log.warn(
        "handler {s} {s} opened a stream and never finished it; " ++
            "call stream.finish() — anything still buffered was lost",
        .{ @tagName(c.method), c._path },
    );
    if (open.chunked and !open.drop) http1.writeLastChunk(c._out) catch return false;
    c._out.flush() catch return false;
    return c.keepAlive();
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
    const keep_alive = c.keepAlive();
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

test "broken JSON is a 400 that says where it stopped making sense" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", createUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users HTTP/1.1\r\nContent-Length: 5\r\n\r\n{name");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "not valid JSON") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "line 1, column 2") != null);
    try testing.expect(result.keep_alive);
}

// The point of what follows: a query param that does not fit has always
// been answered with the name of the param and what was wrong with it. A
// body field used to get `Bad Request` and nothing else. These are the same
// standard, applied to the other half of the request.

const Signup = struct {
    name: Str,
    age: u32,
    plan: enum { free, paid } = .free,
    nickname: ?Str = null,
};

fn signup(incoming: Signup) !struct { name: []const u8 } {
    return .{ .name = incoming.name.view() };
}

fn signupResponse(h: *Harness, app: *App, body: []const u8) []const u8 {
    var head_buf: [128]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "POST /signup HTTP/1.1\r\nContent-Length: {d}\r\n\r\n",
        .{body.len},
    ) catch unreachable;
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "{s}{s}", .{ head, body }) catch unreachable;
    return h.send(app, request).response;
}

test "a body field that does not fit is a 400 naming the field, like a query param" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/signup", signup);

    var h = Harness.init();
    defer h.deinit();

    const cases = [_]struct { body: []const u8, says: []const u8 }{
        // Something the endpoint needs that is not there. A field with a
        // default is exempt: that is what "absent" is allowed to mean.
        .{ .body = "{\"name\":\"wati\"}", .says = "missing \"age\"" },
        // A typo, which is what an unknown field almost always is — so the
        // names it could have been go out with the complaint.
        .{ .body = "{\"nme\":\"wati\",\"age\":7}", .says = "field \"nme\" this endpoint does not know" },
        // Present, but the wrong shape for where it landed.
        .{ .body = "{\"name\":123,\"age\":7}", .says = "\"name\" has to be text, not a number" },
        .{ .body = "{\"name\":\"wati\",\"age\":\"soon\"}", .says = "\"age\" has to be a whole number, not text" },
        // An enum says which names it knows, the way a query param does.
        .{ .body = "{\"name\":\"w\",\"age\":7,\"plan\":\"gold\"}", .says = "\"plan\" has to be one of free, paid" },
        // An optional field takes null, but not anything at all.
        .{ .body = "{\"name\":\"w\",\"age\":7,\"nickname\":9}", .says = "\"nickname\" has to be text or null" },
        // Valid JSON of the wrong kind entirely.
        .{ .body = "[1,2,3]", .says = "has to be a JSON object" },
        // No body at all — the commonest way a first curl goes wrong.
        .{ .body = "", .says = "the request body is empty" },
    };

    for (cases) |case| {
        const response = signupResponse(&h, &app, case.body);
        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n"));
        testing.expect(std.mem.indexOf(u8, response, case.says) != null) catch |err| {
            std.debug.print("body {s}\n  wanted: {s}\n  got:    {s}\n", .{ case.body, case.says, response });
            return err;
        };
    }
}

test "a body that fits still parses, so the diagnosis costs the happy path nothing" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/signup", signup);

    var h = Harness.init();
    defer h.deinit();
    const response = signupResponse(&h, &app, "{\"name\":\"wati\",\"age\":7,\"plan\":\"paid\"}");

    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, response, "{\"name\":\"wati\"}") != null);
}

// ---- 405 ----

fn testEchoOptions(c: *Ctx) anyerror!void {
    try c.sendText(200, "mine");
}

test "a path registered under another method is a 405 with Allow, not a 404" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users", testQuiet);
    try app.post("/users", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "DELETE /users HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 405 Method Not Allowed\r\n"));
    // HEAD is in there without anybody registering one, because the GET
    // route already answers it.
    try testing.expect(std.mem.indexOf(u8, result.response, "Allow: GET, HEAD, POST\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "DELETE is not allowed here") != null);
    // A wrong verb is a normal thing to answer, not a reason to hang up.
    try testing.expect(result.keep_alive);
}

test "a path nothing is registered under is still a 404" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "DELETE /nowhere HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Allow:") == null);
}

test "a 405 knows about params and catch-alls, not just literal paths" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", testQuiet);
    try app.patch("/files/*", testQuiet);

    var h = Harness.init();
    defer h.deinit();

    const on_param = h.send(&app, "PUT /users/42 HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, on_param.response, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try testing.expect(std.mem.indexOf(u8, on_param.response, "Allow: GET, HEAD\r\n") != null);

    const on_catch_all = h.send(&app, "POST /files/a/b/c.txt HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, on_catch_all.response, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try testing.expect(std.mem.indexOf(u8, on_catch_all.response, "Allow: PATCH\r\n") != null);
}

test "an OPTIONS asking what a path supports is answered, not refused" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users", testQuiet);
    try app.post("/users", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "OPTIONS /users HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 204 No Content\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Allow: GET, HEAD, POST\r\n") != null);
}

test "a route registered for the method still wins over the 405" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users", testQuiet);
    try app.options("/users", testEchoOptions);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "OPTIONS /users HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "mine") != null);
    // The framework's own Allow is not bolted onto an answer somebody else
    // wrote.
    try testing.expect(std.mem.indexOf(u8, result.response, "Allow:") == null);
}

test "middleware wraps a 405 the way it wraps everything else" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users", testQuiet);
    try app.use(tagOuter);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "DELETE /users HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Order: outer\r\n") != null);
}

// ---- stopping ----

test "once a stop is asked for, a connection answers what it has and closes" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users", testQuiet);

    var h = Harness.init();
    defer h.deinit();

    const before = h.send(&app, "GET /users HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(before.keep_alive);
    try testing.expect(std.mem.indexOf(u8, before.response, "Connection: keep-alive\r\n") != null);

    app.shutdown();

    // Still answered — a request already on the wire is not the client's
    // fault. What changes is that the connection is not offered again.
    const after = h.send(&app, "GET /users HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, after.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, after.response, "Connection: close\r\n") != null);
    try testing.expect(!after.keep_alive);
}

/// A handler that stops the server is an ordinary handler — which is what
/// an `/admin/quit` route is.
fn quitHandler(c: *Ctx) anyerror!void {
    c.service(*App).?.shutdown();
    try c.sendText(200, "going down\n");
}

test "a stop that lands mid-request still answers it, and says the socket is going" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&app);
    try app.get("/quit", quitHandler);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /quit HTTP/1.1\r\nHost: x\r\n\r\n");

    // The request arrived before the stop and is answered in full. Whether
    // the connection lives on is decided when the response is written, not
    // when the head was read, which is the only way this can be right.
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "going down") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "Connection: close\r\n") != null);
    try testing.expect(!result.keep_alive);
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
        .headers = .of(&.{
            .{ .name = "Location", .value = "/users/7" },
            .{ .name = "X-Made-By", .value = "zfast" },
        }),
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

fn headersBuiltInAFrameThatDies(arena: std.mem.Allocator, id: u32) !typed.Headers {
    return .of(&.{
        .{ .name = "Location", .value = try std.fmt.allocPrint(arena, "/users/{d}", .{id}) },
        .{ .name = "X-Made-By", .value = "zfast" },
    });
}

/// Walks over the stack the frame above left behind, so that a `Headers`
/// pointing back into it reads this rather than what it was given.
fn scribbleOverTheStack() u64 {
    var noise: [512]u8 = undefined;
    for (&noise, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 7);
    var total: u64 = 0;
    for (noise) |byte| total += byte;
    return total;
}

test "a Response's headers are copied out of the frame that wrote them" {
    // This is the test the old `headers: []const Header` could not pass in a
    // release build, and passed in Debug for a whole stage (ADR 0019).
    var buffer: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const headers = try headersBuiltInAFrameThatDies(fixed.allocator(), 42);

    std.mem.doNotOptimizeAway(scribbleOverTheStack());

    try testing.expectEqual(@as(usize, 2), headers.view().len);
    try testing.expectEqualStrings("Location", headers.view()[0].name);
    try testing.expectEqualStrings("/users/42", headers.view()[0].value);
    try testing.expectEqualStrings("zfast", headers.view()[1].value);

    // And a Response that says nothing about headers carries none.
    const quiet: typed.Response(u8) = .{ .value = 1 };
    try testing.expectEqual(@as(usize, 0), quiet.headers.view().len);
}

fn createInArena(arena: std.mem.Allocator, id: u32) !typed.Response(UserOut) {
    return .{
        .status = 201,
        .headers = .of(&.{.{
            .name = "Location",
            .value = try std.fmt.allocPrint(arena, "/users/{d}", .{id}),
        }}),
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

    // Neither form can be called here: `app.get` stops the process the way
    // `listen()` does, and `tryRoute` reaches the same `std.log.err`, which
    // Zig's test runner counts as a failed test whatever `logFn` says. So
    // what is checked is the detection the refusal is built on. The wording
    // lives in `App.tryRoute`, and the shape rule in router.zig.
    try testing.expect(app.router.conflicting(.GET, "/users/:name") != null);
    try testing.expect(app.router.conflicting(.GET, "/users/me") == null);
    try testing.expectEqual(@as(usize, 1), app.router.routes.items.len);

    // A route that does not collide still goes in, so the check above is
    // not simply refusing everything.
    try app.tryRoute(.GET, "/users/me", testQuiet);
    try testing.expectEqual(@as(usize, 2), app.router.routes.items.len);
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

// ---- the generated API description (ADR 0017) ----

const DocUser = struct { id: u32, name: Str, admin: bool = false };
const DocNewUser = struct { name: Str, age: ?u32 = null, plan: enum { free, paid } };
const DocSearch = struct {
    q: Str,
    page: u32 = 1,
    sort: enum { newest, oldest } = .newest,
    tag: ?Str = null,
};

fn docGetUser(_: *Db, id: u32) !DocUser {
    return .{ .id = id, .name = undefined };
}
fn docListUsers(_: *Db, _: typed.Query(DocSearch)) ![]const DocUser {
    return &.{};
}
fn docCreateUser(_: *Db, _: DocNewUser) !typed.Response(DocUser) {
    return undefined;
}
fn docDeleteUser(_: *Db, _: u32) !void {}
fn docServeFile(rest: Str) Str {
    return rest;
}

/// Build an app with one of everything and hand back its document.
fn docsFor(app: *App) ![]const u8 {
    try app.resolveChains();
    const set = app.docs_set.?;
    for (set.files) |f| {
        if (std.mem.eql(u8, f.url, "/openapi.json")) return f.bytes;
    }
    return error.NoDocument;
}

test "the document describes what the signatures say" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{ .title = "Orders", .version = "2.1.0" });

    const api = app.group("/api/v1");
    try api.get("/users/:id", docGetUser);
    try api.delete("/users/:id", docDeleteUser);
    try api.get("/users", docListUsers);
    try api.post("/users", docCreateUser);
    try app.get("/files/*", docServeFile);

    const json = try docsFor(&app);

    try testing.expect(std.mem.startsWith(u8, json, "{\"openapi\":\"3.1.0\","));
    try testing.expect(std.mem.indexOf(u8, json, "\"title\":\"Orders\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"version\":\"2.1.0\"") != null);

    // A `:id` becomes `{id}`, and the two verbs on it share one path entry.
    const users_id = std.mem.indexOf(u8, json, "\"/api/v1/users/{id}\":{").?;
    const next_path = std.mem.indexOf(u8, json[users_id..], "\"/api/v1/users\"").?;
    const entry = json[users_id..][0..next_path];
    try testing.expect(std.mem.indexOf(u8, entry, "\"get\":") != null);
    try testing.expect(std.mem.indexOf(u8, entry, "\"delete\":") != null);

    // The path param's type came from the handler's argument, not a guess.
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"name\":\"id\",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"integer\"}",
    ) != null);

    // A catch-all has no OpenAPI spelling, so it is `{path}` in both places.
    try testing.expect(std.mem.indexOf(u8, json, "\"/files/{path}\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"path\",\"in\":\"path\"") != null);

    // The query struct, with a default meaning "not required".
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"q\",\"in\":\"query\",\"required\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"page\",\"in\":\"query\",\"required\":false") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"name\":\"sort\",\"in\":\"query\",\"required\":false,\"schema\":" ++
            "{\"type\":\"string\",\"enum\":[\"newest\",\"oldest\"]}",
    ) != null);

    // The body, from the struct argument.
    try testing.expect(std.mem.indexOf(u8, json, "\"requestBody\":{\"required\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"plan\":{\"type\":\"string\",\"enum\":[\"free\",\"paid\"]}") != null);

    // A handler returning `Response(T)` chooses its status at runtime, so
    // the document says `default` instead of claiming one.
    try testing.expect(std.mem.indexOf(u8, json, "\"responses\":{\"default\":") != null);
    // One returning a plain value always answers 200, so it says so.
    try testing.expect(std.mem.indexOf(u8, json, "\"responses\":{\"200\":") != null);

    // A route with something to convert can be refused before the handler
    // runs, and the document admits it.
    try testing.expect(std.mem.indexOf(u8, json, "\"400\":") != null);
}

test "the document is valid JSON, all of it" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{ .title = "A \"quoted\" name", .description = "line one\nline two" });

    try app.get("/users/:id", docGetUser);
    try app.get("/users", docListUsers);
    try app.post("/users", docCreateUser);
    try app.delete("/users/:id", docDeleteUser);
    try app.get("/files/*", docServeFile);
    try app.get("/", plainOk);

    const json = try docsFor(&app);

    // The assertions above check the shape a phrase at a time; this checks
    // that the whole thing parses, which is what a client generator will do
    // to it. Escaping is deliberately given something to escape.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const paths = parsed.value.object.get("paths").?.object;
    try testing.expectEqual(@as(usize, 4), paths.count());
    try testing.expect(paths.contains("/users/{id}"));
    try testing.expect(paths.contains("/files/{path}"));
    try testing.expect(paths.contains("/"));

    const on_users_id = paths.get("/users/{id}").?.object;
    try testing.expectEqual(@as(usize, 2), on_users_id.count());
    try testing.expectEqualStrings(
        "getUsersId",
        on_users_id.get("get").?.object.get("operationId").?.string,
    );

    try testing.expectEqualStrings(
        "A \"quoted\" name",
        parsed.value.object.get("info").?.object.get("title").?.string,
    );
}

test "docs can be asked for before or after the routes, and both pages appear" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);

    // After the routes this time — the order-independence `use` and `get`
    // already have (ADR 0009).
    try app.get("/users/:id", docGetUser);
    app.docs(.{ .title = "Late", .ui_path = "/reference" });

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const spec = h.send(&app, "GET /openapi.json HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, spec.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, spec.response, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, spec.response, "\"title\":\"Late\"") != null);
    // Served as a file, so it arrives with an ETag like any other.
    try testing.expect(std.mem.indexOf(u8, spec.response, "ETag: ") != null);

    const page = h.send(&app, "GET /reference HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, page.response, "Content-Type: text/html") != null);
    try testing.expect(std.mem.indexOf(u8, page.response, "data-url=\"/openapi.json\"") != null);
}

test "no docs asked for, no documents served" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", docGetUser);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    try testing.expect(app.docs_set == null);
    try testing.expect(std.mem.startsWith(
        u8,
        h.send(&app, "GET /openapi.json HTTP/1.1\r\n\r\n").response,
        "HTTP/1.1 404 Not Found\r\n",
    ));
}

test "a route of your own at the docs path still wins" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{ .ui_path = "/docs" });
    try app.get("/docs", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // Routes are matched before anything static is looked at, docs included
    // — so this is the handler, not the reader page.
    const result = h.send(&app, "GET /docs HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, result.response, "handler"));
}

test "a single-page app serving everything does not swallow the document" {
    // The setup most likely to want an API description is also the one that
    // would hide it: an SPA fallback answers for every path there is.
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "index.html", "<h1>app</h1>" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{ .title = "Behind an SPA" });
    try app.tryStaticWith("/", files.path, .{ .spa_fallback = "index.html" });

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // The fallback really does answer for every path, which is the premise
    // this test exists for rather than an aside.
    try testing.expect(std.mem.indexOf(
        u8,
        h.send(&app, "GET /whatever/deep HTTP/1.1\r\n\r\n").response,
        "<h1>app</h1>",
    ) != null);

    const spec = h.send(&app, "GET /openapi.json HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, spec.response, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, spec.response, "\"title\":\"Behind an SPA\"") != null);
}

test "rebuilding the document twice does not leak the first one" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{});
    try app.get("/users/:id", docGetUser);

    // `resolveChains` is what `listen()` calls, and a test — or a program
    // that listens twice — can reach it more than once.
    try app.resolveChains();
    try app.resolveChains();
    try app.resolveChains();
    try testing.expect(app.docs_set != null);
}

// ---- groups and plugins (ADR 0015) ----

/// A plugin: an ordinary function that registers into whatever group it is
/// handed. Taking `anytype` rather than a named type is what lets the same
/// function be mounted at any prefix, or at none.
fn healthPlugin(g: anytype) !void {
    try g.get("/healthz", plainOk);
    try g.get("/readyz", plainOk);
}

test "a group puts its prefix on every route inside it" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const api = app.group("/api/v1");
    try api.get("/users", plainOk);
    try api.post("/users", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    try testing.expect(std.mem.startsWith(
        u8,
        h.send(&app, "GET /api/v1/users HTTP/1.1\r\n\r\n").response,
        "HTTP/1.1 200 OK\r\n",
    ));
    // And the unprefixed path is not a route, which is the other half of
    // what "the prefix is on every route" means.
    try testing.expect(std.mem.startsWith(
        u8,
        h.send(&app, "GET /users HTTP/1.1\r\n\r\n").response,
        "HTTP/1.1 404 Not Found\r\n",
    ));
}

test "a group's own path is the prefix, with no trailing slash left on it" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const api = app.group("/api");
    try api.get("/", plainOk);

    // Registered as "/api", not "/api/" — the two match the same requests,
    // but only one of them reads correctly in an error message or in the
    // generated documentation.
    try testing.expectEqualStrings("/api", app.router.routes.items[0].pattern);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    try testing.expect(std.mem.startsWith(
        u8,
        h.send(&app, "GET /api HTTP/1.1\r\n\r\n").response,
        "HTTP/1.1 200 OK\r\n",
    ));
}

test "use on a group scopes the middleware to the group" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const api = app.group("/api");
    try api.use(tagInner);
    try api.get("/thing", plainOk);
    try app.get("/health", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const inside = h.send(&app, "GET /api/thing HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, inside.response, "X-Inner: yes") != null);

    const outside = h.send(&app, "GET /health HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, outside.response, "X-Inner") == null);
}

test "groups nest, and nesting is the same as writing the prefix out" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const v1 = app.group("/api").group("/v1");
    try v1.get("/users/:id", plainOk);

    try testing.expectEqualStrings("/api/v1/users/:id", app.router.routes.items[0].pattern);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    try testing.expect(std.mem.startsWith(
        u8,
        h.send(&app, "GET /api/v1/users/7 HTTP/1.1\r\n\r\n").response,
        "HTTP/1.1 200 OK\r\n",
    ));
}

test "a plugin is a function taking a group, and mounts wherever it is put" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    // The same function, twice, at two prefixes — which is the thing a
    // group buys that repeating the prefix by hand does not.
    try healthPlugin(app.group("/internal"));
    try healthPlugin(app.group("/admin"));

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    for ([_][]const u8{
        "GET /internal/healthz HTTP/1.1\r\n\r\n",
        "GET /internal/readyz HTTP/1.1\r\n\r\n",
        "GET /admin/healthz HTTP/1.1\r\n\r\n",
        "GET /admin/readyz HTTP/1.1\r\n\r\n",
    }) |request| {
        try testing.expect(std.mem.startsWith(
            u8,
            h.send(&app, request).response,
            "HTTP/1.1 200 OK\r\n",
        ));
    }
}

test "a group at the root registers exactly what it was given" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    // What a plugin mounted at the top gets. `use` here has to mean every
    // route rather than every route under "", which is not a prefix.
    const root = app.group("");
    try root.use(tagInner);
    try healthPlugin(root);

    try testing.expectEqualStrings("/healthz", app.router.routes.items[0].pattern);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /healthz HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Inner: yes") != null);
}

test "a duplicate route inside a group is still refused, naming the joined path" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const api = app.group("/api");
    try api.get("/users/:id", plainOk);

    // Checked through the detection rather than the refusal, for the reason
    // the test above this one gives: both forms of the refusal reach a
    // `std.log.err` that Zig's test runner reads as a failure.
    //
    // A prefix is not a namespace — it is text on the front — so the
    // collision is against the joined pattern and nothing else (ADR 0013).
    try testing.expect(app.router.conflicting(.GET, "/api/users/:name") != null);
    try testing.expect(app.router.conflicting(.GET, "/users/:id") == null);
}

// ---- resolved values (ADR 0016) ----
//
// The gap ADR 0009 wrote down and left open: middleware can refuse a
// request but cannot hand the handler the user it just looked up. These
// tests are that gap closed, end to end through a real request.

/// Counts its lookups, because "how many times did this run" is the whole
/// question for the memoisation below.
const Sessions = struct {
    rows: []const struct { token: []const u8, user_id: u32 } = &.{},
    lookups: usize = 0,

    fn userFor(self: *Sessions, token: []const u8) ?u32 {
        self.lookups += 1;
        for (self.rows) |row| {
            if (std.mem.eql(u8, row.token, token)) return row.user_id;
        }
        return null;
    }
};

const SignedIn = struct {
    pub const zfast_resolve = authenticateRequest;

    id: u32,
};

fn authenticateRequest(c: *Ctx, sessions: *Sessions) !SignedIn {
    const token = c.header("Authorization") orelse
        return fail.unauthorized("this endpoint needs an Authorization header", .{});
    return .{
        .id = sessions.userFor(token.view()) orelse
            return fail.unauthorized("that token is not valid", .{}),
    };
}

fn whoAmI(user: SignedIn) !UserOut {
    return .{ .id = user.id, .name = "wati" };
}

/// The other half of the pattern: middleware guards a whole prefix, and the
/// handler behind it still gets the value as an argument.
fn requireSignedIn(c: *Ctx, next: mw.Next) anyerror!void {
    _ = try c.resolve(SignedIn);
    try next.run(c);
}

test "a handler asks for the signed-in user by writing it in its arguments" {
    var sessions = Sessions{ .rows = &.{.{ .token = "t0k", .user_id = 7 }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&sessions);
    try app.get("/me", whoAmI);
    try app.checkServices();

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /me HTTP/1.1\r\nAuthorization: t0k\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":7,\"name\":\"wati\"}") != null);
}

test "a resolver that refuses answers its own status and the handler never runs" {
    var sessions = Sessions{ .rows = &.{.{ .token = "t0k", .user_id = 7 }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&sessions);
    try app.get("/me", whoAmI);

    var h = Harness.init();
    defer h.deinit();

    const no_header = h.send(&app, "GET /me HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, no_header.response, "HTTP/1.1 401 Unauthorized\r\n"));
    try testing.expect(std.mem.indexOf(u8, no_header.response, "needs an Authorization header") != null);

    const wrong = h.send(&app, "GET /me HTTP/1.1\r\nAuthorization: nope\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, wrong.response, "HTTP/1.1 401 Unauthorized\r\n"));
    // Refusing a request is a normal thing to do, not a reason to hang up.
    try testing.expect(wrong.keep_alive);
}

test "a middleware and the handler behind it resolve the user once between them" {
    // Without memoisation this is the shape that quietly doubles every
    // authenticated request's database work: the guard looks the user up to
    // decide, and the handler looks the same user up to answer.
    var sessions = Sessions{ .rows = &.{.{ .token = "t0k", .user_id = 7 }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&sessions);
    try app.useOn("/me", requireSignedIn);
    try app.get("/me", whoAmI);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /me HTTP/1.1\r\nAuthorization: t0k\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expectEqual(@as(usize, 1), sessions.lookups);
}

test "what one request resolved does not leak into the next on the same connection" {
    var sessions = Sessions{ .rows = &.{
        .{ .token = "wati", .user_id = 7 },
        .{ .token = "budi", .user_id = 9 },
    } };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&sessions);
    try app.get("/me", whoAmI);

    var h = Harness.init();
    defer h.deinit();

    const first = h.send(&app, "GET /me HTTP/1.1\r\nAuthorization: wati\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, first.response, "\"id\":7") != null);

    // Same connection, different token. The cache lives in the request
    // arena and the arena is reset between requests, so this is the second
    // user and not the first one again — which would be the worst bug this
    // feature could have.
    const second = h.send(&app, "GET /me HTTP/1.1\r\nAuthorization: budi\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, second.response, "\"id\":9") != null);
    try testing.expectEqual(@as(usize, 2), sessions.lookups);
}

test "a service only a resolver needs is still caught before serving" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    // `*Sessions` appears nowhere in whoAmI's arguments — only inside the
    // resolver behind `SignedIn`. Missing it has to stop `listen()` all the
    // same (ADR 0006), or the first authenticated request finds out instead.
    try app.get("/me", whoAmI);

    // Through the predicate rather than `checkServices()`, which logs the
    // gap before failing — and a test counting those logs reads as a failed
    // suite. Same check, no stderr.
    const missing = app.missingService().?;
    try testing.expectEqualStrings(@typeName(Sessions), missing.type_name);
    try testing.expectEqualStrings("/me", missing.route);
}

test "a route that resolves nothing still costs what it always did" {
    // ADR 0018's rule, as a test: a feature nobody used must not show up on
    // the request path. `_resolved` starts empty and allocates only when
    // something is put in it, so this is the same budget as before.
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed("GET /users/7 HTTP/1.1\r\nHost: x\r\n\r\n");
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out);
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // Two here rather than three: no CORS, so no response header list.
    try testing.expectEqual(@as(usize, 2), counting.allocs);
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

// ---- responses written in pieces (ADR 0020) ----

fn streamRows(c: *Ctx) anyerror!void {
    var body = try c.stream(200, "text/csv");
    for ([_][]const u8{ "wati", "budi", "sari" }, 1..) |name, id| {
        try body.print("{d},{s}\n", .{ id, name });
        // Flushed one at a time so the test sees the framing, and because
        // this is what a report being watched actually wants.
        try body.flush();
    }
    try body.finish();
}

fn streamAndForget(c: *Ctx) anyerror!void {
    var body = try c.stream(200, "text/plain");
    try body.writeAll("half a thought");
    try body.flush();
    // No finish(). App has to make the connection safe anyway.
}

fn streamAfterHeader(c: *Ctx) anyerror!void {
    try c.setStaticHeader("X-Report", "quarterly");
    var body = try c.stream(200, "text/plain");
    try body.writeAll("ok");
    try body.finish();
}

test "a streamed response is chunked, and the connection survives it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/rows", streamRows);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /rows HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Transfer-Encoding: chunked\r\n") != null);
    // No Content-Length: that is the whole reason to stream.
    try testing.expect(std.mem.indexOf(u8, result.response, "Content-Length") == null);

    const body = result.response[std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4 ..];
    try testing.expectEqualStrings(
        "7\r\n1,wati\n\r\n7\r\n2,budi\n\r\n7\r\n3,sari\n\r\n0\r\n\r\n",
        body,
    );
    try testing.expect(result.keep_alive);
}

test "a stream to an HTTP/1.0 client is unframed and ends with the connection" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/rows", streamRows);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /rows HTTP/1.0\r\n\r\n");

    // 1.0 has no chunked encoding, so the end of the body can only be the
    // end of the connection — and the head has to say so.
    try testing.expect(std.mem.indexOf(u8, result.response, "Transfer-Encoding") == null);
    try testing.expect(std.mem.indexOf(u8, result.response, "Connection: close\r\n") != null);

    const body = result.response[std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4 ..];
    try testing.expectEqualStrings("1,wati\n2,budi\n3,sari\n", body);
    try testing.expect(!result.keep_alive);
}

test "a HEAD of a streamed route gets the head a GET would have, and no body" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/rows", streamRows);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "HEAD /rows HTTP/1.1\r\n\r\n");

    try testing.expect(std.mem.indexOf(u8, result.response, "Transfer-Encoding: chunked\r\n") != null);
    const body = result.response[std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4 ..];
    try testing.expectEqualStrings("", body);
    try testing.expect(result.keep_alive);
}

test "headers set before a stream go out in its head" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/report", streamAfterHeader);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /report HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Report: quarterly\r\n") != null);
}

test "a stream nobody finished still leaves the connection usable" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/oops", streamAndForget);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /oops HTTP/1.1\r\n\r\n");

    // App writes the terminator the handler forgot, so the client is told
    // where the body stopped rather than waiting for more.
    const body = result.response[std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4 ..];
    try testing.expectEqualStrings("e\r\nhalf a thought\r\n0\r\n\r\n", body);
    try testing.expect(result.keep_alive);
}

fn streamManyPieces(c: *Ctx) anyerror!void {
    var body = try c.stream(200, "text/plain");
    for (0..200) |i| {
        try body.print("{d} ", .{i});
        try body.flush();
    }
    try body.finish();
}

test "a stream allocates once, however many pieces it writes" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/many", streamManyPieces);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [8192]u8 = undefined;

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed("GET /many HTTP/1.1\r\nHost: x\r\n\r\n");
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out);
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // Two: the request head, and the stream's own buffer. Two hundred
    // pieces went out between them and not one of them allocated — which is
    // the promise ADR 0020 makes, and the reason a stream can run for a week.
    try testing.expectEqual(@as(usize, 2), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);
}

// ---- server-sent events ----

fn tickEvents(c: *Ctx) anyerror!void {
    var events = try c.events();
    try events.retry(2000);
    try events.send(.{ .name = "tick", .id = "1", .data = "first" });
    try events.json("state", .{ .open = true, .waiting = 2 });
    try events.close();
}

test "an event stream carries its events, and the headers a proxy needs" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/events", tickEvents);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /events HTTP/1.1\r\n\r\n");

    try testing.expect(std.mem.indexOf(u8, result.response, "Content-Type: text/event-stream\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "Cache-Control: no-cache\r\n") != null);
    // Without this an nginx in front holds the events back until a buffer
    // fills, which for a token stream is the whole point gone.
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Accel-Buffering: no\r\n") != null);

    // Each event is flushed on its own, so each is its own chunk — which is
    // what makes them arrive one at a time rather than in a batch.
    const body = result.response[std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4 ..];
    try testing.expectEqualStrings(
        "d\r\nretry: 2000\n\n\r\n" ++
            "1f\r\nevent: tick\nid: 1\ndata: first\n\n\r\n" ++
            "2e\r\nevent: state\ndata: {\"open\":true,\"waiting\":2}\n\n\r\n" ++
            "0\r\n\r\n",
        body,
    );
    try testing.expect(result.keep_alive);
}

fn streamUntilStopped(c: *Ctx) anyerror!void {
    var events = try c.events();
    var sent: usize = 0;
    while (events.live()) : (sent += 1) {
        try events.data("tick");
        // A real handler waits for something; this one stops the server on
        // its own so the loop has a way out.
        if (sent == 1) c.service(*App).?.shutdown();
    }
    try events.close();
}

test "a shutdown asks a stream to wind up rather than cutting it off" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&app);
    try app.get("/forever", streamUntilStopped);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /forever HTTP/1.1\r\n\r\n");

    // Two events went out and the third was never started: `live()` went
    // false, the loop ended, and the body was closed properly (ADR 0020).
    const body = result.response[std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4 ..];
    try testing.expectEqualStrings("c\r\ndata: tick\n\n\r\nc\r\ndata: tick\n\n\r\n0\r\n\r\n", body);

    // And the connection is not offered for another request, because the
    // server is going away.
    try testing.expect(!result.keep_alive);
}
