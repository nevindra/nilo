//! App — one self-contained HTTP application: its routes, services,
//! middleware and static files. It wires the Bulkhead, the HTTP/1.1
//! parser, the Router, the request arena, and Ctx into one thing.
//!
//! `handleRequest` is deliberately separate from the Engine: all it needs
//! is a `std.Io.Reader`/`Writer`, so every bit of App's HTTP behaviour can
//! be tested against in-memory buffers, without starting a server.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");
const body_mod = @import("body.zig");
const http1 = @import("http1.zig");
const range_mod = @import("range.zig");
const router_mod = @import("router.zig");
const ctx_mod = @import("ctx.zig");
const str_mod = @import("str.zig");
const patch_mod = @import("patch.zig");
const service_mod = @import("service.zig");
const typed = @import("typed.zig");
const fail = @import("fail.zig");
const mw = @import("middleware.zig");
const cors = @import("cors.zig");
const static_mod = @import("static.zig");
const openapi = @import("openapi.zig");
const budget = @import("budget.zig");
const watchdog = @import("watchdog.zig");
const session_mod = @import("session.zig");

const Ctx = ctx_mod.Ctx;

/// How much of a connection's request arena survives between requests.
/// Big enough that an ordinary request never allocates twice on the same
/// connection, small enough that one large upload does not leave that
/// connection sitting on the memory for good.
const arena_keep = 16 * 1024;

/// The three answers that go out before there is a Ctx to assemble one with.
/// They carry the same JSON shape every other failure does (ADR 0025), so a
/// client has one thing to parse and not two.
const RESPONSE_400 = http1.staticResponse(400, "Bad Request", failure_content_type, staticFailure(400, "malformed request"), false);
const RESPONSE_431 = http1.staticResponse(431, "Request Header Fields Too Large", failure_content_type, staticFailure(431, "head too long"), false);
/// Sent when a request head started arriving and then stopped (ADR 0023).
/// Not when a keep-alive connection simply sat idle: that client has not
/// asked for anything, and a status answering nothing is noise a proxy has
/// to decide what to do with.
const RESPONSE_408 = http1.staticResponse(408, "Request Timeout", failure_content_type, staticFailure(408, "request head timed out"), false);

const failure_content_type = "application/json";

/// Room for the longest failure body there can be: a message at the Failure's
/// ceiling where every byte needs the six-character `\u00xx` escape, plus the
/// wrapper around it.
const failure_body_max = fail.max_message * 6 + 32;

/// A failure body for a message known while compiling — no escaping, because
/// these three are written here and have nothing in them to escape.
fn staticFailure(comptime status: u16, comptime message: []const u8) []const u8 {
    return std.fmt.comptimePrint("{{\"error\":\"{s}\",\"status\":{d}}}", .{ message, status });
}

/// The body of a failure response: the sentence a fail function wrote, in the
/// one shape every client can read (ADR 0025).
///
/// A frontend calling `res.json()` on a 4xx used to throw, which is the
/// worst moment to lose the message that says what went wrong. The message
/// itself is unchanged, so `curl` still shows the sentence — one pair of
/// braces further in.
fn writeFailureBody(w: *std.Io.Writer, status: u16, message: []const u8) !void {
    try w.writeAll("{\"error\":\"");
    for (message) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch),
    };
    try w.print("\",\"status\":{d}}}", .{status});
}

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
    /// One middleware chain per file in `docs_set`, in the same order, and
    /// the same again for each entry of `static_sets`. Resolved at
    /// `listen()` beside the routes' chains, and for the same reason: a
    /// static file is a hot path, and building its chain per request is an
    /// allocation on a path that did not ask for one
    /// ([ADR 0018](../docs/adr/0018-the-trade-budget-has-three-axes.md)).
    ///
    /// Per file rather than per set, which is what makes it unconditional.
    /// A set has one URL prefix, but a middleware can be scoped *below* it
    /// — `static("/assets")` with `use("/assets/private", auth)` — so one
    /// chain for the whole set would be wrong for exactly the case where
    /// getting it wrong means running no auth.
    docs_chains: []const []const mw.Middleware = &.{},
    static_chains: std.ArrayList([]const []const mw.Middleware) = .empty,
    /// Set when the server should stop. Read by the Engine's accept loop
    /// and by every connection between requests.
    stop: bulkhead.Stop = .{},
    /// The part of `listen()`'s options a request reads rather than the
    /// socket, copied out once when the server starts. Defaults stand for
    /// an App a test drives directly, which never calls `listen()`.
    limits: Limits = .{},
    /// The key session cookies are sealed with, from
    /// `listen(.{ .session_secret = … })` and checked there. Null for an App
    /// with no sessions, and for one a test drives directly — a test that
    /// wants sessions sets this field.
    session_key: ?session_mod.Key = null,

    /// What one request is allowed to do. Declared on the Ctx, which is
    /// what reads it.
    pub const Limits = ctx_mod.Limits;

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
        self.static_chains.deinit(self.gpa);
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
        comptime typed.check(pattern, handler);
        try self.route(.GET, pattern, handler);
    }

    pub fn post(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        comptime typed.check(pattern, handler);
        try self.route(.POST, pattern, handler);
    }

    pub fn put(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        comptime typed.check(pattern, handler);
        try self.route(.PUT, pattern, handler);
    }

    pub fn delete(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        comptime typed.check(pattern, handler);
        try self.route(.DELETE, pattern, handler);
    }

    pub fn patch(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        comptime typed.check(pattern, handler);
        try self.route(.PATCH, pattern, handler);
    }

    pub fn head(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        comptime typed.check(pattern, handler);
        try self.route(.HEAD, pattern, handler);
    }

    pub fn options(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        comptime typed.check(pattern, handler);
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
        comptime typed.check(pattern, handler);
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
        comptime typed.check(pattern, handler);

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

        // After `buildDocs`, which is what makes `docs_set` exist to have
        // chains for.
        if (self.docs_set) |*set| self.docs_chains = try self.chainsFor(set);
        try self.static_chains.ensureTotalCapacityPrecise(self.gpa, self.static_sets.items.len);
        for (self.static_sets.items) |*set| {
            self.static_chains.appendAssumeCapacity(try self.chainsFor(set));
        }
    }

    /// The chain for every file in `set`, in the set's own order, so a
    /// lookup that found a file has found its chain as well.
    fn chainsFor(self: *App, set: *const static_mod.Set) ![]const []const mw.Middleware {
        const chains = try self.gpa.alloc([]const mw.Middleware, set.files.len);
        var made: usize = 0;
        errdefer {
            for (chains[0..made]) |c| if (c.len > 0) self.gpa.free(c);
            self.gpa.free(chains);
        }
        for (set.files, chains) |file, *chain| {
            chain.* = try mw.chainFor(self.gpa, self.scoped.items, file.url);
            made += 1;
        }
        return chains;
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

        // Freed here rather than in `deinit` alone, because `resolveChains`
        // can run more than once — a test, or a program that listens twice
        // — and `buildDocs` replaces the very `docs_set` these parallel.
        self.freeChainList(self.docs_chains);
        self.docs_chains = &.{};
        for (self.static_chains.items) |chains| self.freeChainList(chains);
        self.static_chains.clearRetainingCapacity();
    }

    fn freeChainList(self: *App, chains: []const []const mw.Middleware) void {
        for (chains) |c| if (c.len > 0) self.gpa.free(c);
        if (chains.len > 0) self.gpa.free(chains);
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
        self.countUndescribed();
        // The two knobs a request reads rather than the socket. Kept on the
        // App because that is what a request can reach; a test driving
        // `handleRequest` with no server gets the defaults below.
        self.limits = .{
            .max_body = options_.max_body,
            .trusted_hops = options_.trusted_hops,
            .block_warning_ms = options_.block_warning_ms,
        };
        // Here rather than at the first request that reads a cookie: a secret
        // of the wrong length is a deployment mistake, and the moment somebody
        // is watching for one is startup. The key is copied onto the App, so
        // whatever the caller passed does not have to outlive this call.
        if (options_.session_secret) |secret| {
            self.session_key = session_mod.checkSecret(secret) catch {
                std.log.err(
                    "the session secret is {d} bytes and it has to be exactly {d}. It is a key, " ++
                        "not a password: {d} bytes of randomness, the same on every instance and " ++
                        "the same after a restart, or everybody is signed out.",
                    .{ secret.len, session_mod.key_len, session_mod.key_len },
                );
                return error.SessionSecretWrongLength;
            };
        }
        try bulkhead.serve(self.gpa, options_, &self.stop, self, handleConnection);
    }

    /// Say how many routes the document cannot describe, at the one moment
    /// somebody is looking: startup.
    ///
    /// A handler that writes its own answer is a fine thing to write — it is
    /// how a stream or an upload has to work — but it is invisible to a
    /// generated client, and it is easy to drop to a `*Ctx` for one small
    /// reason and not notice what went with it. The document itself now says
    /// so per route (`"this endpoint writes its own response"`), and nobody
    /// reads the document to find out what is missing from it.
    fn countUndescribed(self: *App) void {
        if (self.docs_options == null) return;

        var written: usize = 0;
        for (self.operations.items) |op| {
            if (op.answer.written) written += 1;
        }
        if (written == 0) return;

        std.log.info(
            "{d} of {d} routes write their own response, so the API description does not " ++
                "describe what they answer",
            .{ written, self.operations.items.len },
        );
    }

    /// Stop the server: `listen()` stops accepting, connections finish the
    /// request they are on and close, and `listen()` returns.
    ///
    /// Safe to call from any thread, and from a handler — a `/admin/quit`
    /// route is an ordinary handler that calls this.
    pub fn shutdown(self: *App) void {
        self.stop.request();
    }

    fn handleConnection(
        self: *App,
        in: *std.Io.Reader,
        out: *std.Io.Writer,
        deadlines: bulkhead.Deadlines,
        waker: bulkhead.Waker,
        peer: bulkhead.Peer,
    ) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        // A span of its own, so a Str this connection hands out cannot pass
        // for one of the next connection's (ADR 0004).
        var lifetime = str_mod.Lifetime.init();
        defer lifetime.deinit();

        // Once for the connection. Nothing in a response changes how long a
        // single write may take, so nothing re-arms it — including a stream
        // that writes for an hour, where each write is still one write.
        deadlines.armWrite();

        // What this fiber is serving is bound to it once, then reused by
        // every request on the same connection (ADR 0007).
        var in_flight = fail.InFlight{};
        var binding = bulkhead.binding_unset;
        bulkhead.bindSlot(&binding, &in_flight);
        defer bulkhead.unbindSlot(&binding);

        while (true) {
            // Find out whether this connection is going quiet before deciding
            // to give its pages back.
            //
            // Doing it unconditionally costs more than it saves: on a busy
            // keep-alive connection the next request is already arriving, so
            // every cycle pays an madvise and faults the same pages straight
            // back in — measured at 1.31M req/s down to 626k, a 52% loss,
            // because MADV_DONTNEED in a process with eight threads shoots
            // down TLB entries on all of them. So the pages only go once a
            // short read has come back empty, which a connection under load
            // never sees and a browser tab between clicks always does.
            waitOrRelease(in, out, deadlines);

            // Waiting for the next request to start is the idle limit, not
            // the header one. Re-armed every time round: a connection that
            // has just served a request is idle again from now, not from
            // whenever it was accepted.
            deadlines.armIdle();
            const keep_going = self.handleRequest(arena.allocator(), &lifetime, &in_flight, in, out, deadlines, waker, peer);
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

    /// How long a connection has to produce its next request before its
    /// buffers are handed back to the kernel.
    ///
    /// Long enough that nothing serving back-to-back requests ever reaches it,
    /// short enough that a connection a person is behind reaches it between
    /// almost any two clicks. It is not a timeout: running out of it costs a
    /// syscall and some page faults on the next request, not the connection.
    const idle_peek_ms = 200;

    /// Give the client `idle_peek_ms` to say something. If it does, this is a
    /// busy connection and nothing else happens — the bytes stay buffered and
    /// the request that follows reads them. If it does not, the connection is
    /// idle and its buffers are worth more to the kernel than to us.
    ///
    /// Every error is swallowed: a broken connection is `handleRequest`'s to
    /// diagnose and report, and it will meet the same failure one call later
    /// with all the machinery for saying so.
    fn waitOrRelease(in: *std.Io.Reader, out: *std.Io.Writer, deadlines: bulkhead.Deadlines) void {
        // Already holding a pipelined request: not idle, and the buffer is
        // live data that must not be discarded.
        if (in.seek != in.end) return;

        deadlines.armPeek(idle_peek_ms);
        in.fillMore() catch {
            if (deadlines.timedOut()) bulkhead.releaseIdlePages(in, out);
        };
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
        deadlines: bulkhead.Deadlines,
        waker: bulkhead.Waker,
        peer: bulkhead.Peer,
    ) bool {
        const failure = &in_flight.failure;
        in_flight.startRequest("", "");
        // On a real server the fiber slot is already installed and wins;
        // this is what keeps fail functions working when App is called
        // straight from a test, with no Engine underneath.
        const prev_slot = bulkhead.setFallbackSlot(in_flight);
        defer _ = bulkhead.setFallbackSlot(prev_slot);

        const raw_head = http1.readHead(in, deadlines) catch |err| {
            switch (err) {
                error.EndOfStream => {},
                // A timeout arrives as a read failure like any other, so
                // which one it was has to be asked (ADR 0023). The bytes
                // that did turn up are still buffered, and they are what
                // separates the two cases worth telling apart: a client
                // halfway through a head gets a 408, a connection that sat
                // idle without asking for anything is just closed.
                error.ReadFailed => if (deadlines.timedOut() and in.buffered().len > 0) {
                    sendFinal(out, RESPONSE_408);
                },
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

        var r = http1.Request{};
        http1.parseHead(raw_head, &r) catch {
            sendFinal(out, RESPONSE_400);
            return false;
        };

        // Every `Str` from this request points into the head, and the head is
        // sitting in the connection's read buffer — where the next read
        // overwrites it. So it is copied into the request arena, but only when
        // there is going to be a next read: a body to take in, or a protocol
        // about to take the socket over. On a GET, which is the shape the
        // primary metric measures and most of the traffic besides, nothing
        // reads again and the copy has nobody to protect — worth 19ns on a
        // small head and 77ns on the one a browser really sends, plus one of
        // the three allocations a request makes.
        //
        // What holds it together is `Ctx.aboutToRead`: every path that reads
        // from the connection calls it, and it fails loudly in a debug build
        // if this decision said there would be no such path.
        const borrowed = !http1.readsMore(&r);
        const request_head = if (borrowed) raw_head else copy: {
            const copied = arena.dupe(u8, raw_head) catch return false;
            // The two slices the parser left pointing into the old bytes.
            // Everything derived below — the path, the query, the params —
            // comes off `r.target`, so moving these two moves all of it.
            r.method = rebase(raw_head, copied, r.method);
            r.target = rebase(raw_head, copied, r.target);
            break :copy copied;
        };
        in.toss(raw_head.len);


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
            ._head_borrowed = borrowed,
            ._watch = &in_flight.watch,
            ._deadlines = deadlines,
            ._waker = waker,
            ._peer = peer,
            ._limits = self.limits,
            // A pointer to the App's copy, not the copy: the key is 32 bytes
            // on every Ctx otherwise, for something almost no request reads.
            ._session_key = if (self.session_key) |*k| k else null,
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
        } else if (self.findStatic(c.method, path)) |found| {
            // Resolved at `listen()` with the routes' chains, so an asset
            // served with a logger or a CORS in front of it allocates
            // nothing — which is the shape nearly every app deploys, and
            // the one the budget test used to step around rather than
            // measure (ADR 0018).
            c._static_file = found.file;
            terminal = serveStaticFile;
            chain = found.chain;
        } else {
            // Nothing is precomputed for a path that is neither a route nor
            // a file, because the set of them is every string there is. So
            // the chain is built here, out of the request arena — one
            // allocation, bounded by the middleware count, and paid only by
            // a 404 or a 405.
            if (self.scoped.items.len > 0) {
                chain = mw.chainFor(arena, self.scoped.items, path) catch &.{};
            }
            // No route for this method, but the path itself is spelled out
            // by routes under other methods. "There is nothing here" and
            // "there is something here, but not for that verb" are
            // different answers, and a 404 for the second one sends you
            // looking for a registration bug that is not there.
            const allowed = self.router.allowedFor(path);
            if (allowed.count() > 0) {
                c._allowed = allowed;
                terminal = methodNotAllowedHandler;
            }
        }

        // The one mistake the compiler cannot catch and everybody else pays
        // for: a handler that waits on the operating system directly holds
        // the thread every other request on it is being served by
        // (ADR 0034). Bracketed around the whole chain rather than around
        // the terminal handler, because a middleware that blocks stops the
        // thread just as dead as a handler that does.
        watchdog.begin(&in_flight.watch, self.limits.block_warning_ms);

        (mw.Next{ .rest = chain, .handler = terminal }).run(&c) catch |err| {
            watchdog.finish(&in_flight.watch, @tagName(c.method), path, c._took_over);
            // A half-sent response cannot be taken back, so the connection
            // is closed: the next request on it would read leftover bytes
            // of unclear provenance.
            if (c._sent) {
                // A write that ran out of time is the ordinary way a
                // response to a client that stopped reading ends, and
                // "handler failed" sends whoever reads the log looking for a
                // bug in a handler that did nothing wrong (ADR 0023).
                if (deadlines.timedOut()) {
                    std.log.warn(
                        "{s} {s}: gave up writing after {d}ms — the client stopped reading",
                        .{ @tagName(c.method), path, deadlines.write_ms },
                    );
                } else {
                    std.log.warn("handler {s} {s} failed after answering: {s}", .{ @tagName(c.method), path, @errorName(err) });
                }
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
        watchdog.finish(&in_flight.watch, @tagName(c.method), path, c._took_over);

        // A body the handler did not read is discarded so the next request
        // on this connection starts at the right byte.
        const reusable = drain(&c, in, &r);

        if (!c._sent) {
            // A handler that returned without answering meant an empty 200.
            // No content type, because there is no content to give one to.
            sendDirect(&c, 200, "", "") catch return false;
        }
        if (c._stream != null) return endAbandonedStream(&c);
        return reusable;
    }

    /// The static file `path` names, if any set holds one. Only GET and
    /// HEAD: a POST to a `.css` is a mistake, and answering it with the
    /// stylesheet would hide that.
    /// A file and the middleware in front of it, both settled before the
    /// socket opened.
    const StaticHit = struct {
        file: *const static_mod.File,
        chain: []const mw.Middleware,
    };

    fn findStatic(self: *const App, method: http1.Method, path: []const u8) ?StaticHit {
        if (method != .GET and method != .HEAD) return null;
        // Asked before the loaded directories, not after. A single-page app
        // served from `/` with an `index.html` fallback answers for every
        // path there is, and it would swallow `/openapi.json` whole —
        // which is exactly the setup most likely to want the document.
        if (self.docs_set) |*set| {
            if (set.find(path)) |file| return hit(file, self.docs_chains, set.indexOf(file));
        }
        for (self.static_sets.items, 0..) |*set, i| {
            if (set.find(path)) |file| {
                // A set appended without `resolveChains` having run since —
                // which only a test reaching past `static()` can arrange —
                // has no chains, exactly as an unresolved route has none.
                const chains = if (i < self.static_chains.items.len) self.static_chains.items[i] else &.{};
                return hit(file, chains, set.indexOf(file));
            }
        }
        return null;
    }

    fn hit(
        file: *const static_mod.File,
        chains: []const []const mw.Middleware,
        i: usize,
    ) StaticHit {
        return .{ .file = file, .chain = if (i < chains.len) chains[i] else &.{} };
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
            comptime typed.check(joined(prefix, pattern), handler);
            return self.app.get(comptime joined(prefix, pattern), handler);
        }

        pub fn post(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            return self.app.post(comptime joined(prefix, pattern), handler);
        }

        pub fn put(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            return self.app.put(comptime joined(prefix, pattern), handler);
        }

        pub fn delete(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            return self.app.delete(comptime joined(prefix, pattern), handler);
        }

        pub fn patch(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            return self.app.patch(comptime joined(prefix, pattern), handler);
        }

        pub fn head(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            return self.app.head(comptime joined(prefix, pattern), handler);
        }

        pub fn options(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            return self.app.options(comptime joined(prefix, pattern), handler);
        }

        pub fn route(
            self: Self,
            method: http1.Method,
            comptime pattern: []const u8,
            comptime handler: anytype,
        ) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            return self.app.route(method, comptime joined(prefix, pattern), handler);
        }

        pub fn tryRoute(
            self: Self,
            method: http1.Method,
            comptime pattern: []const u8,
            comptime handler: anytype,
        ) !void {
            comptime typed.check(joined(prefix, pattern), handler);
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

/// A group prefix has a leading slash, no trailing one, and no catch-all.
/// A param is allowed: `use` scopes middleware by matching whole segments,
/// and a `:name` segment matches whatever is opposite it (`middleware.zig`).
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
        if (std.mem.indexOfScalar(u8, prefix, '*') != null) @compileError(
            "zfast: the group prefix \"" ++ prefix ++ "\" has a `*` in it, and a catch-all " ++
                "cannot be a prefix.\n" ++
                "  A `*` matches the whole rest of the path, so there would be nothing left for " ++
                "the routes inside the group to match — every one of them would be unreachable.\n" ++
                "  A `*` belongs at the end of a route pattern, where it is the last thing that " ++
                "matches: `app.get(\"" ++ prefix[0 .. std.mem.indexOfScalar(u8, prefix, '*').? - 1] ++
                "/*\", …)`.\n" ++
                "  A `:` in a prefix is fine — `app.group(\"/orgs/:org\")` works.",
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
/// The same bytes as `slice`, pointed at `to` instead of at `from` — for
/// moving a slice of a buffer onto a copy of that buffer.
fn rebase(from: []const u8, to: []const u8, slice: []const u8) []const u8 {
    const offset = @intFromPtr(slice.ptr) - @intFromPtr(from.ptr);
    return to[offset..][0..slice.len];
}

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
    // Reading here as well as in the handler, so the clock goes on here as
    // well (ADR 0023). Without it these reads would inherit whatever limit
    // was last set — the header deadline, which by now has passed — and a
    // client with a body left to send would have its connection dropped for
    // no reason. Only where something is really read, though: arming it on a
    // GET would leave a limit meant for a body sitting on a connection that
    // is about to go idle instead.
    //
    // The handler read the body in pieces and may have stopped part way —
    // a `while (try incoming.read(…))` that breaks early is an ordinary
    // thing to write. What is left of it goes here, so the next request on
    // this connection starts where it should (ADR 0020).
    if (c._incoming) |*progress| {
        if (progress.finished()) return true;
        c._deadlines.armBody();
        var rest = body_mod.Body.init(in, progress);
        rest.discardRest() catch return false;
        return true;
    }
    if (http1.readsMore(r)) {
        c._deadlines.armBody();
        http1.discardBody(in, r, c._limits.max_body) catch return false;
    }
    return true;
}

/// The innermost call when no route matched. It is a normal handler so
/// that middleware wraps a 404 exactly as it wraps anything else.
///
/// It fails rather than answering, so this 404 goes out through the one
/// place that assembles a failure and gets the same body shape as every
/// other (ADR 0025).
fn notFoundHandler(c: *Ctx) anyerror!void {
    return fail.notFound("there is no {s}", .{c._path});
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
    if (c.method == .OPTIONS) return c.sendEmpty(204);

    // Failing rather than answering, for the reason `notFoundHandler` does:
    // one place assembles a failure body. The `Allow` header set above
    // survives it — `sendDirect` writes whatever headers the request
    // collected, which is also what keeps CORS on an error response.
    return fail.status(405, "{s} is not allowed here. This path answers: {s}", .{
        @tagName(c.method),
        allow,
    });
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

/// Answer with a file the App listed at startup. Also a normal handler, so
/// a static response goes through the same middleware as everything else —
/// CORS included, which is what an asset served to another origin needs.
///
/// The one branch is here, at the top, and it is the only place either arm
/// knows the other exists (ADR 0037).
fn serveStaticFile(c: *Ctx) anyerror!void {
    const file = c._static_file.?;
    switch (file.contents) {
        .held => return serveHeldFile(c, file),
        .spilled => |on_disk| return serveSpilledFile(c, file, on_disk),
    }
}

/// A file that was too big to read at load. It was never read and is not
/// being read now: the descriptor goes to `sendfile.send`, which writes the
/// head and hands the bytes to the socket without them passing through this
/// process.
fn serveSpilledFile(
    c: *Ctx,
    file: *const static_mod.File,
    on_disk: static_mod.File.Spilled,
) anyerror!void {
    // The name was written down by the directory walk before the socket
    // opened, and the descriptor it is resolved against was too. Nothing a
    // request carried is being turned into a path (ADR 0037).
    const open = on_disk.dir.openFile(on_disk.path) catch |err| switch (err) {
        // The list said the file was there and the disk disagrees, which
        // from the client's side is indistinguishable from asking for
        // something that never existed. Every other way of failing to open
        // one is this server's problem and says so with a 500.
        error.FileNotFound => return fail.notFound("there is no {s}", .{c._path}),
        else => return err,
    };

    // No `Vary`, because there is nothing to vary on: a spilled file has one
    // representation and no gzipped copy to negotiate against (ADR 0018 —
    // nothing compresses per request). No `defer open.close()` either: the
    // file belongs to `sendFile` from here, on every path out of it.
    //
    // The size is the one the walk recorded rather than a fresh `stat`,
    // because the ETag is made of that number.
    return c.sendFile(.{
        .file = open,
        .size = on_disk.size,
        .content_type = file.content_type,
        .etag = file.etag,
        .cache_control = file.cache_control,
    });
}

/// A file read at load and answered from memory — everything at or below
/// `max_file_bytes`, which is nearly every file a web tree has.
///
/// **What this shares with the spilled arm, and what it does not.** Shared,
/// and it is the part ADR 0021 exists to protect: `range_mod.parse` is the
/// only thing anywhere that decides what a `Range` means, including the rule
/// that turns a 206 back into a 200 when `If-Range` does not match — both
/// arms hand it that decision as a flag and neither implements it.
/// `contentRange` and `unsatisfiableRange` write the header, and
/// `static_mod.etagMatches` compares the tags. There is exactly one copy of
/// each, and a corrupt resumed download would have to be a bug in one of
/// them rather than a disagreement between two.
///
/// Not shared, and it cannot be: every line below is measured against a
/// *representation* rather than against the file. A held file may have two —
/// the plain bytes and a gzipped copy, with a different ETag each — so which
/// one the client gets decides the ETag the conditionals compare, the length
/// the range is taken from, and the bytes that go out. A spilled file has
/// exactly one representation and always will (a file that is not held
/// cannot be compressed once), so `sendfile.send` has nothing to choose
/// between and answers from the file's own tag and size. Sharing these lines
/// would mean handing it a choice it can never have.
fn serveHeldFile(c: *Ctx, file: *const static_mod.File) anyerror!void {
    // A `Range` is an offset into a representation, and the gzipped copy is
    // a different representation with different offsets. Rather than work
    // out which one a client meant, a request that asks for part of a file
    // gets the plain one — which is the representation `Accept-Ranges:
    // bytes` has been promising all along.
    const wants_part = c.header("Range") != null;
    const wants_gzip = !wants_part and
        static_mod.acceptsGzip(headerValue(c, "Accept-Encoding"));
    const sending = file.representation(wants_gzip);

    // Everything here belongs to the loaded file, which outlives every
    // request, so there is nothing to copy.
    try c.setStaticHeader("ETag", sending.etag);
    if (file.cache_control.len > 0) try c.setStaticHeader("Cache-Control", file.cache_control);
    // Said on every file response, including the 304 and the 416: it is how
    // a client learns it may ask for part of one at all.
    try c.setStaticHeader("Accept-Ranges", "bytes");
    // Whenever there are two representations to choose between — not only
    // when the gzipped one is the one going out. A shared cache that stored
    // the plain answer without this would go on handing it to clients that
    // could have had the small one, and, worse, the other way round.
    if (file.contents.held.gzip != null) try c.setStaticHeader("Vary", "Accept-Encoding");
    if (sending.gzipped) try c.setStaticHeader("Content-Encoding", "gzip");

    // The ETag was computed when the file was read, so a repeat visitor
    // costs a comparison and a head — no body, no work. Compared against
    // the representation actually going out, which is why the two ETags are
    // kept apart in the first place.
    if (c.header("If-None-Match")) |sent| {
        if (static_mod.etagMatches(sent.view(), sending.etag)) {
            return c.send(304, file.content_type, "");
        }
    }

    const total = sending.bytes.len;
    // `If-Range` means "only give me the part if the file is still the one I
    // started with". A client resuming a download sends the ETag it had;
    // anything else and the safe answer is all of it.
    const still_the_same = if (c.header("If-Range")) |sent|
        static_mod.etagMatches(sent.view(), sending.etag)
    else
        true;

    var buf: [range_mod.max_content_range]u8 = undefined;
    switch (range_mod.parse(headerValue(c, "Range"), total, still_the_same)) {
        .whole => {},
        .part => |part| {
            try c.setHeader("Content-Range", range_mod.contentRange(&buf, part, total));
            return c.send(206, file.content_type, part.slice(sending.bytes));
        },
        .unsatisfiable => {
            // The one answer whose whole content is "you have the wrong idea
            // about how big this is", which the header carries and the body
            // does not need to repeat.
            try c.setHeader("Content-Range", range_mod.unsatisfiableRange(&buf, total));
            return c.send(416, file.content_type, "");
        },
    }

    try c.send(200, file.content_type, sending.bytes);
}

/// A request header as plain bytes. The `Str` a handler gets is the right
/// shape for a handler and the wrong one for a parser that takes `?[]const
/// u8`, and this is the only place that difference comes up.
fn headerValue(c: *const Ctx, name: []const u8) ?[]const u8 {
    const found = c.header(name) orelse return null;
    return found.view();
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
fn sendDirect(c: *Ctx, status: u16, content_type: []const u8, body: []const u8) !void {
    c._sent = true;
    c._status = status;
    // `Ctx.send`'s reason, and the other half of the same accounting: this
    // is zfast waiting on the client, not a handler running (ADR 0034).
    const w = watchdog.waiting(c._watch);
    defer watchdog.waited(c._watch, w);
    const keep_alive = c.keepAlive();
    if (c.method == .HEAD) return http1.writeResponseHeadOnly(
        c._out,
        status,
        http1.statusPhrase(status),
        content_type,
        body.len,
        keep_alive,
        c.extraHeaders(),
    );
    try http1.writeResponse(
        c._out,
        status,
        http1.statusPhrase(status),
        content_type,
        body,
        keep_alive,
        c.extraHeaders(),
    );
}

/// Turn a handler failure into a response. A fail function's message is
/// used if there is one; otherwise the error goes through the mapping
/// table, and anything unrecognised becomes a 500 logged with its error
/// name (ADR 0005).
fn sendFailure(c: *Ctx, failure: *const fail.Failure, err: anyerror) !void {
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

    var buf: [failure_body_max]u8 = undefined;
    var body: std.Io.Writer = .fixed(&buf);
    // The buffer is sized for the longest message a Failure can hold, so
    // this cannot run out of room; if it somehow did, what was written so
    // far would not be JSON, and the status alone is better than that.
    writeFailureBody(&body, status, message) catch {
        return sendDirect(c, status, "", "");
    };
    try sendDirect(c, status, failure_content_type, buf[0..body.end]);
}

// ---- tests: all of App's HTTP behaviour, without starting a server ----

const testing = std.testing;
const Str = str_mod.Str;

// Reached for only by the tests below, which is why they are here rather
// than at the top: `testing.zig` imports this file, and the tests are the
// one place that wants to go back the other way.
const zfast_testing = @import("testing.zig");
const form_mod = @import("form.zig");
const bound_mod = @import("bound.zig");
const redirect_mod = @import("redirect.zig");

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    lifetime: str_mod.Lifetime = .{},
    in_flight: fail.InFlight = .{},
    buf: [4096]u8 = undefined,
    restore_log_level: std.log.Level,
    /// Who these requests come from. No socket by default, which is what
    /// every test that does not care about the address wants.
    peer: bulkhead.Peer = .{},

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

    /// Whether a failure response says `wanted`, read out of the JSON body
    /// rather than off the wire (ADR 0025). A test then spells the message
    /// the way a person reads it, instead of the way JSON escapes it — and
    /// gets "the body really was JSON" asserted for free.
    fn saysFailure(response: []const u8, wanted: []const u8) !bool {
        const blank = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return false;
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            testing.allocator,
            response[blank + 4 ..],
            .{},
        );
        defer parsed.deinit();
        const message = (parsed.value.object.get("error") orelse return false).string;
        return std.mem.indexOf(u8, message, wanted) != null;
    }

    fn send(self: *Harness, app: *App, request: []const u8) struct { response: []const u8, keep_alive: bool } {
        var in = std.Io.Reader.fixed(request);
        var out = std.Io.Writer.fixed(&self.buf);
        const keep_alive = app.handleRequest(self.arena.allocator(), &self.lifetime, &self.in_flight, &in, &out, .off, .off, self.peer);
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
    // No Content-Type: there is no content to give one to.
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"));
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
        // An enum says which names it knows, the way a query param does —
        // and quotes back the word it was given, because "has to be one of
        // free, paid, not text" is a sentence arguing with itself.
        .{
            .body = "{\"name\":\"w\",\"age\":7,\"plan\":\"gold\"}",
            .says = "\"plan\" is not one of the known choices (free, paid): \"gold\"",
        },
        // Not a word at all, which is the other way to get an enum wrong,
        // and there the kind is the thing worth saying.
        .{
            .body = "{\"name\":\"w\",\"age\":7,\"plan\":9}",
            .says = "\"plan\" has to be one of free, paid, not a number",
        },
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
        testing.expect(try Harness.saysFailure(response, case.says)) catch |err| {
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

const EditTodo = struct {
    title: patch_mod.Patch(Str) = .absent,
    due: patch_mod.Patch(Str) = .absent,
};

fn editTodo(incoming: EditTodo) !struct { title: []const u8, due: []const u8 } {
    return .{
        .title = switch (incoming.title) {
            .absent => "absent",
            .cleared => "cleared",
            // Read through `view()`, which is what proves the Str inside a
            // Patch got its lifetime marker like any other.
            .value => |v| v.view(),
        },
        .due = switch (incoming.due) {
            .absent => "absent",
            .cleared => "cleared",
            .value => |v| v.view(),
        },
    };
}

test "a PATCH body tells a field left out from one sent as null" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.patch("/todos", editTodo);

    var h = Harness.init();
    defer h.deinit();

    const cases = [_]struct { body: []const u8, says: []const u8 }{
        // The distinction `?T` cannot make, and the reason Patch exists
        // (ADR 0026).
        .{ .body = "{}", .says = "{\"title\":\"absent\",\"due\":\"absent\"}" },
        .{ .body = "{\"title\":null}", .says = "{\"title\":\"cleared\",\"due\":\"absent\"}" },
        .{ .body = "{\"title\":\"buy milk\"}", .says = "{\"title\":\"buy milk\",\"due\":\"absent\"}" },
        .{
            .body = "{\"title\":\"x\",\"due\":null}",
            .says = "{\"title\":\"x\",\"due\":\"cleared\"}",
        },
    };

    for (cases) |case| {
        var buf: [256]u8 = undefined;
        const request = std.fmt.bufPrint(
            &buf,
            "PATCH /todos HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ case.body.len, case.body },
        ) catch unreachable;
        const response = h.send(&app, request).response;
        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
        testing.expect(std.mem.indexOf(u8, response, case.says) != null) catch |err| {
            std.debug.print("body {s}\n  wanted: {s}\n  got:    {s}\n", .{ case.body, case.says, response });
            return err;
        };
    }

    // And a value of the wrong shape still says so, naming the field: a
    // Patch takes its value or null, and nothing else.
    const wrong = h.send(
        &app,
        "PATCH /todos HTTP/1.1\r\nContent-Length: 14\r\n\r\n{\"title\":123}\n",
    );
    try testing.expect(std.mem.startsWith(u8, wrong.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(wrong.response, "\"title\" has to be text or null"));
}

const Address = struct { street: Str, city: Str };
const Line = struct { sku: Str, qty: u32 };
const Order = struct {
    customer: Str,
    address: Address,
    lines: []const Line,
    note: ?Str = null,
};

fn placeOrder(incoming: Order) !struct { customer: []const u8 } {
    return .{ .customer = incoming.customer.view() };
}

test "a field below the top level is named by where it is, not left to a bare 400" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/orders", placeOrder);

    var h = Harness.init();
    defer h.deinit();

    const good_address = "\"address\":{\"street\":\"jl mawar\",\"city\":\"bandung\"}";
    const good_lines = "\"lines\":[{\"sku\":\"a\",\"qty\":1}]";

    const cases = [_]struct { body: []const u8, says: []const u8 }{
        // Inside a nested object: missing, unknown, and the wrong shape.
        .{
            .body = "{\"customer\":\"wati\",\"address\":{\"street\":\"jl mawar\"}," ++ good_lines ++ "}",
            .says = "missing \"address.city\"",
        },
        .{
            .body = "{\"customer\":\"wati\",\"address\":{\"street\":\"a\",\"city\":\"b\",\"zip\":\"c\"}," ++ good_lines ++ "}",
            .says = "field \"address.zip\" this endpoint does not know",
        },
        .{
            .body = "{\"customer\":\"wati\",\"address\":{\"street\":1,\"city\":\"b\"}," ++ good_lines ++ "}",
            .says = "\"address.street\" has to be text, not a number",
        },
        // Inside a list, which is named by the position that went wrong
        // rather than by the list.
        .{
            .body = "{\"customer\":\"wati\"," ++ good_address ++ ",\"lines\":[{\"sku\":\"a\",\"qty\":1},{\"sku\":\"b\",\"qty\":\"two\"}]}",
            .says = "\"lines[1].qty\" has to be a whole number, not text",
        },
        .{
            .body = "{\"customer\":\"wati\"," ++ good_address ++ ",\"lines\":[{\"sku\":\"a\"}]}",
            .says = "missing \"lines[0].qty\"",
        },
        // The top level still reads exactly as it did before any of this
        // went deeper: no prefix, because there is nothing to be inside of.
        .{
            .body = "{" ++ good_address ++ "," ++ good_lines ++ "}",
            .says = "the request body is missing \"customer\"",
        },
    };

    for (cases) |case| {
        var head_buf: [128]u8 = undefined;
        const head = std.fmt.bufPrint(
            &head_buf,
            "POST /orders HTTP/1.1\r\nContent-Length: {d}\r\n\r\n",
            .{case.body.len},
        ) catch unreachable;
        var request_buf: [1024]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buf, "{s}{s}", .{ head, case.body }) catch unreachable;
        const response = h.send(&app, request).response;

        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n"));
        testing.expect(try Harness.saysFailure(response, case.says)) catch |err| {
            std.debug.print("body {s}\n  wanted: {s}\n  got:    {s}\n", .{ case.body, case.says, response });
            return err;
        };
    }
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
    try testing.expect(try Harness.saysFailure(
        not_a_number.response,
        "?page has to be a whole number, not \"soon\"",
    ));

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

fn deleteWithResponse() typed.Response(void) {
    return .{ .status = 204 };
}

fn deleteWithStatus() typed.Status(204, void) {
    return .{};
}

fn createWithStatus() typed.Status(201, UserOut) {
    return .{
        .headers = .of(&.{.{ .name = "Location", .value = "/users/7" }}),
        .value = .{ .id = 7, .name = "wati" },
    };
}

test "an empty response is a 204 with nothing after the head" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.delete("/one", deleteWithResponse);
    try app.delete("/two", deleteWithStatus);

    var h = Harness.init();
    defer h.deinit();

    // Both spellings answer the same thing. A 204 carries neither
    // Content-Type nor Content-Length — see `http1.bodyless` — and the
    // connection is fine to carry another request.
    for ([_][]const u8{ "/one", "/two" }) |path| {
        var buf: [64]u8 = undefined;
        const request = std.fmt.bufPrint(&buf, "DELETE {s} HTTP/1.1\r\n\r\n", .{path}) catch unreachable;
        const result = h.send(&app, request);
        try testing.expectEqualStrings(
            "HTTP/1.1 204 No Content\r\nConnection: keep-alive\r\n\r\n",
            result.response,
        );
        try testing.expect(result.keep_alive);
    }
}

test "a Status(code, T) answers that code and carries headers like a Response does" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", createWithStatus);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Location: /users/7\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":7,\"name\":\"wati\"}") != null);
}

fn findUser(id: u32) !?UserOut {
    if (id != 7) return null;
    return .{ .id = 7, .name = "wati" };
}

test "a handler returning ?T answers 404 when there is none, and never sends null" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", findUser);

    var h = Harness.init();
    defer h.deinit();

    const found = h.send(&app, "GET /users/7 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, found.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, found.response, "{\"id\":7,\"name\":\"wati\"}") != null);

    // Not `200 null`, which is what this used to be and what nobody meant
    // (ADR 0024). The path is in the message, so the log says which one.
    const missing = h.send(&app, "GET /users/99 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, missing.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(try Harness.saysFailure(missing.response, "there is no /users/99"));
    try testing.expect(missing.keep_alive);
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

/// Runs the rest of the onion and does nothing else — a middleware that set
/// a header would have the budget test measuring the header instead.
///
/// It counts, because "allocated nothing" is also what an empty chain looks
/// like: without this the test would pass just as happily if the middleware
/// never ran at all, which is the way this could break.
var pass_through_runs: usize = 0;

fn passThrough(c: *Ctx, next: mw.Next) anyerror!void {
    pass_through_runs += 1;
    return next.run(c);
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

test "a prefix carrying a param scopes middleware the same way" {
    // The multi-tenant shape, which used to be a compile error. Three things
    // have to hold: the route under it, the 404 under it — that one was
    // genuinely broken, because the cold path matches against the real path
    // rather than the pattern — and a neighbouring tree staying untouched.
    var app = App.init(testing.allocator);
    defer app.deinit();

    var orgs = app.group("/orgs/:org");
    try orgs.use(tagInner);
    try orgs.get("/members", plainOk);
    try app.get("/health", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const on = h.send(&app, "GET /orgs/acme/members HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, on.response, "X-Inner: yes") != null);

    const missing = h.send(&app, "GET /orgs/acme/nothing-here HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, missing.response, "HTTP/1.1 404"));
    try testing.expect(std.mem.indexOf(u8, missing.response, "X-Inner: yes") != null);

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
    try testing.expect(app.handleRequest(h.arena.allocator(), &h.lifetime, &h.in_flight, &in, &out, .off, .off, .{}));

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
    const etag = app.findStatic(.GET, "/app.css").?.file.etag;
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
// on a shared VM (docs/roadmap.md). It will not tell you how fast the
// server is, but it does notice the day somebody puts an allocation back
// onto the path everything goes down.
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
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
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

    // One, and it is the JSON body. Raising this number needs a reason;
    // lowering it is welcome.
    //
    // It was three. The two that went:
    //
    //   - **The copy of the request head.** A request with no body does not
    //     need it: nothing is going to read from the connection again, so the
    //     head can stay in the read buffer where the parser found it (see
    //     `handleRequest`, and `Ctx.aboutToRead` for what stops that from
    //     becoming a dangling `Str`). A POST still pays it, which is what the
    //     next test checks — so the saving cannot quietly become a bug.
    //   - **The list of response headers CORS adds.** The first six now sit
    //     in the `Ctx` itself; the arena only hears about a seventh.
    try testing.expectEqual(@as(usize, 1), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);
}

test "a fifth response header spills to the arena, and all five go out in order" {
    // The other side of holding four inline: the fifth has to join them rather
    // than replace them, and the response has to carry one list.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/many", struct {
        fn run(c: *Ctx) anyerror!void {
            inline for (.{ "A", "B", "C", "D", "E", "F" }) |name| {
                try c.setStaticHeader("X-" ++ name, name);
            }
            // And one that repeats an inline entry, which must replace it.
            try c.setStaticHeader("x-b", "again");
            try c.sendText(200, "ok");
        }
    }.run);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();
    const sent = h.send(&app, "GET /many HTTP/1.1\r\n\r\n");

    for ([_][]const u8{ "X-A: A", "X-C: C", "X-D: D", "X-E: E", "X-F: F" }) |line| {
        try testing.expect(std.mem.indexOf(u8, sent.response, line) != null);
    }
    // Replaced, not duplicated.
    try testing.expect(std.mem.indexOf(u8, sent.response, "x-b: again") != null);
    try testing.expect(std.mem.indexOf(u8, sent.response, "X-B: B") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sent.response, "again"));
}

/// A connection that hands its bytes over a few at a time, into a buffer of
/// its own — which is what a socket does and what `Reader.fixed` never does,
/// because there the input *is* the buffer and no read ever refills it.
///
/// Two things can only be tested through something like this: that a head
/// arriving in pieces is still found (`readHead` resumes its scan rather than
/// starting again), and that a head left in the read buffer is copied out
/// before a body read overwrites it.
const Trickle = struct {
    rest: []const u8,
    per_read: usize,
    reader: std.Io.Reader,

    fn init(source: []const u8, per_read: usize, buffer: []u8) Trickle {
        return .{
            .rest = source,
            .per_read = per_read,
            .reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .end = 0,
                .seek = 0,
            },
        };
    }

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *Trickle = @alignCast(@fieldParentPtr("reader", r));
        if (self.rest.len == 0) return error.EndOfStream;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = @min(@min(dest.len, self.per_read), self.rest.len);
        @memcpy(dest[0..n], self.rest[0..n]);
        self.rest = self.rest[n..];
        w.advance(n);
        return n;
    }
};

fn echoHeadAfterBody(c: *Ctx) anyerror!void {
    const body_text = (try c.body()).view();
    // Read out of the head *after* the body: on a head still sitting in the
    // read buffer, these are whatever the refill put there.
    const host = c.header("Host") orelse return fail.badRequest("no Host", .{});
    try c.sendText(200, try std.fmt.allocPrint(
        c._arena,
        "{s}|{s}|{f}",
        .{ host.view(), body_text, c.path() },
    ));
}

test "a request with a body copies the head, so its Strs survive reading it" {
    // The other half of the budget above: the saving is only allowed to exist
    // because a request that *will* read still pays for the copy. Driven
    // through a connection that trickles, so the body genuinely cannot arrive
    // without refilling the buffer the head is in.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoHeadAfterBody);
    try app.resolveChains();

    const wire = "POST /echo HTTP/1.1\r\nHost: example.dev\r\n" ++
        "Content-Length: 11\r\n\r\nhello world";

    // Several read sizes, so the head/body split lands in a different place
    // each time — including one byte at a time, which is the worst case for
    // both the scan and the copy.
    for ([_]usize{ 1, 3, 7, 16, 64 }) |per_read| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var lifetime = str_mod.Lifetime{};
        var in_flight = fail.InFlight{};
        var out_buf: [4096]u8 = undefined;
        var read_buf: [128]u8 = undefined;

        var conn = Trickle.init(wire, per_read, &read_buf);
        var out = std.Io.Writer.fixed(&out_buf);
        _ = app.handleRequest(arena.allocator(), &lifetime, &in_flight, &conn.reader, &out, .off, .off, .{});

        try testing.expect(std.mem.startsWith(u8, out.buffered(), "HTTP/1.1 200"));
        try testing.expect(std.mem.endsWith(u8, out.buffered(), "example.dev|hello world|/echo"));
    }
}

test "a head arriving a byte at a time is still parsed, and its Strs are sound" {
    // The no-body side, on a trickling connection. Nothing reads again, so the
    // head stays where it was parsed — and every Str off it has to hold up for
    // the whole request anyway.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", struct {
        fn run(c: *Ctx) anyerror!void {
            const host = c.header("Host") orelse return fail.badRequest("no Host", .{});
            const agent = c.header("User-Agent") orelse return fail.badRequest("no UA", .{});
            const id = c.param("id") orelse return fail.badRequest("no id", .{});
            try c.sendText(200, try std.fmt.allocPrint(
                c._arena,
                "{s}|{s}|{s}|{f}",
                .{ host.view(), agent.view(), id.view(), c.path() },
            ));
        }
    }.run);
    try app.resolveChains();

    const wire = "GET /users/42 HTTP/1.1\r\nHost: example.dev\r\n" ++
        "User-Agent: curl/8.0\r\nAccept: */*\r\n\r\n";

    for ([_]usize{ 1, 2, 5, 31, 32, 33, 200 }) |per_read| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var lifetime = str_mod.Lifetime{};
        var in_flight = fail.InFlight{};
        var out_buf: [4096]u8 = undefined;
        var read_buf: [256]u8 = undefined;

        var conn = Trickle.init(wire, per_read, &read_buf);
        var out = std.Io.Writer.fixed(&out_buf);
        _ = app.handleRequest(arena.allocator(), &lifetime, &in_flight, &conn.reader, &out, .off, .off, .{});

        try testing.expect(std.mem.endsWith(
            u8,
            out.buffered(),
            "example.dev|curl/8.0|42|/users/42",
        ));
    }
}

test "two requests on one trickling connection do not borrow each other's head" {
    // A keep-alive connection reuses the buffer, so the second request's head
    // lands where the first one's was. Both answers have to be about their own
    // request.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/*", struct {
        fn run(c: *Ctx) anyerror!void {
            const host = c.header("Host") orelse return fail.badRequest("no Host", .{});
            try c.sendText(200, try std.fmt.allocPrint(
                c._arena,
                "{f}@{s}",
                .{ c.path(), host.view() },
            ));
        }
    }.run);
    try app.resolveChains();

    const wire = "GET /first HTTP/1.1\r\nHost: one.example\r\n\r\n" ++
        "GET /second HTTP/1.1\r\nHost: two.example\r\n\r\n";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var read_buf: [128]u8 = undefined;
    var conn = Trickle.init(wire, 4, &read_buf);

    for ([_][]const u8{ "/first@one.example", "/second@two.example" }) |want| {
        var out_buf: [4096]u8 = undefined;
        var out = std.Io.Writer.fixed(&out_buf);
        try testing.expect(app.handleRequest(
            arena.allocator(),
            &lifetime,
            &in_flight,
            &conn.reader,
            &out,
            .off,
            .off,
            .{},
        ));
        try testing.expect(std.mem.endsWith(u8, out.buffered(), want));
        lifetime.end();
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }
}

// ---- deadlines (ADR 0023) ----
//
// What is tested here is the policy: which limit the request path asks for,
// when, how many times, and what it sends when one runs out. What zio does
// once it has a limit is zio's, and it is checked by hand against a real
// socket rather than pretended at here — the numbers from that run are in
// the ADR. A fake makes the difference between an absolute header deadline
// and a per-read one visible, which no amount of waiting on a real socket
// would make *quick* to check.

/// A `Deadlines` that writes down what it was asked to do instead of doing
/// it.
const Recorded = struct {
    const Call = struct { side: bulkhead.Side, limit: bulkhead.Limit };

    calls: [16]Call = undefined,
    n: usize = 0,
    /// What `timedOut()` answers — the fake stands in for the socket here
    /// too, since a fake reader cannot really run out of time.
    timed_out: bool = false,

    /// A `Deadlines` carrying real numbers and this recorder's behaviour.
    fn with(self: *Recorded, limits: bulkhead.Deadlines) bulkhead.Deadlines {
        var d = limits;
        d.target = self;
        d.vtable = &vtable;
        return d;
    }

    const vtable: bulkhead.Deadlines.VTable = .{ .limit = record, .timedOut = wasTimeout };

    fn record(target: ?*anyopaque, side: bulkhead.Side, l: bulkhead.Limit) void {
        const self: *Recorded = @ptrCast(@alignCast(target.?));
        if (self.n == self.calls.len) return;
        self.calls[self.n] = .{ .side = side, .limit = l };
        self.n += 1;
    }

    fn wasTimeout(target: ?*anyopaque) bool {
        const self: *const Recorded = @ptrCast(@alignCast(target.?));
        return self.timed_out;
    }

    fn lastRead(self: *const Recorded) ?bulkhead.Limit {
        var i = self.n;
        while (i > 0) {
            i -= 1;
            if (self.calls[i].side == .read) return self.calls[i].limit;
        }
        return null;
    }

    fn countReads(self: *const Recorded, tag: @typeInfo(bulkhead.Limit).@"union".tag_type.?) usize {
        var found: usize = 0;
        for (self.calls[0..self.n]) |call| {
            if (call.side == .read and call.limit == tag) found += 1;
        }
        return found;
    }
};

/// The four numbers a server runs with, small and distinct so a test can
/// tell from the value alone which limit was asked for.
const test_limits: bulkhead.Deadlines = .{
    .header_ms = 700,
    .idle_ms = 900,
    .body_ms = 1100,
    .write_ms = 1300,
};

/// `Trickle`, except that when it runs out it fails the way a socket that
/// ran out of time does — `error.ReadFailed`, with the reason kept
/// elsewhere — rather than reporting a clean end of stream.
const Stalling = struct {
    rest: []const u8,
    per_read: usize,
    reader: std.Io.Reader,

    fn init(source: []const u8, per_read: usize, buffer: []u8) Stalling {
        return .{
            .rest = source,
            .per_read = per_read,
            .reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .end = 0,
                .seek = 0,
            },
        };
    }

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *Stalling = @alignCast(@fieldParentPtr("reader", r));
        if (self.rest.len == 0) return error.ReadFailed;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = @min(@min(dest.len, self.per_read), self.rest.len);
        @memcpy(dest[0..n], self.rest[0..n]);
        self.rest = self.rest[n..];
        w.advance(n);
        return n;
    }
};

const Deadline = struct {
    app: App,
    arena: std.heap.ArenaAllocator,
    lifetime: str_mod.Lifetime = .{},
    in_flight: fail.InFlight = .{},
    clock: Recorded = .{},
    out_buf: [4096]u8 = undefined,
    read_buf: [512]u8 = undefined,

    fn init() Deadline {
        return .{
            .app = App.init(testing.allocator),
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn deinit(self: *Deadline) void {
        self.app.deinit();
        self.arena.deinit();
    }

    /// One request over a connection that hands `wire` over `per_read` bytes
    /// at a time and then stops dead.
    fn stall(self: *Deadline, wire: []const u8, per_read: usize) struct {
        response: []const u8,
        keep_alive: bool,
    } {
        var conn = Stalling.init(wire, per_read, &self.read_buf);
        var out = std.Io.Writer.fixed(&self.out_buf);
        const keep_alive = self.app.handleRequest(
            self.arena.allocator(),
            &self.lifetime,
            &self.in_flight,
            &conn.reader,
            &out,
            self.clock.with(test_limits),
            .off,
            .{},
        );
        return .{ .response = out.buffered(), .keep_alive = keep_alive };
    }
};

test "a head that starts arriving and then stops is answered with 408" {
    var d = Deadline.init();
    defer d.deinit();
    try d.app.get("/", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, "should never run");
        }
    }.run);
    try d.app.resolveChains();
    d.clock.timed_out = true;

    // A head with no blank line: the client said something and then went
    // quiet, which is the slowloris shape.
    const sent = d.stall("GET / HTTP/1.1\r\nHost: example.dev\r\n", 8);

    try testing.expect(std.mem.startsWith(u8, sent.response, "HTTP/1.1 408"));
    try testing.expect(!sent.keep_alive);
}

test "a connection that goes quiet without asking for anything is closed without a word" {
    // The other half of the 408 decision. Nothing was asked, so there is
    // nothing to answer, and a status here would be a proxy's problem
    // rather than a client's answer.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.resolveChains();
    d.clock.timed_out = true;

    const sent = d.stall("", 8);

    try testing.expectEqual(@as(usize, 0), sent.response.len);
    try testing.expect(!sent.keep_alive);
}

test "a connection that breaks mid-head is closed without a 408 as well" {
    // Same failure, different reason: the client is gone, not slow. A 408
    // would be written into a socket nobody is holding.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.resolveChains();
    d.clock.timed_out = false;

    const sent = d.stall("GET / HTTP/1.1\r\nHost: example.dev\r\n", 8);

    try testing.expectEqual(@as(usize, 0), sent.response.len);
}

test "the header deadline is set once, however many reads the head takes" {
    // The whole reason the header limit is an absolute deadline rather than a
    // per-read one. A client sending a byte at a time drives dozens of reads
    // through here; if any of them re-armed the limit, it would move the
    // finish line forward every time and never be reached — which is the
    // attack, not the defence.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.get("/x", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, "ok");
        }
    }.run);
    try d.app.resolveChains();

    const sent = d.stall("GET /x HTTP/1.1\r\nHost: example.dev\r\nAccept: */*\r\n\r\n", 1);
    try testing.expect(std.mem.startsWith(u8, sent.response, "HTTP/1.1 200"));

    // Once for the whole head, and as a deadline rather than a duration.
    try testing.expectEqual(@as(usize, 1), d.clock.countReads(.by_ns));
    try testing.expectEqual(@as(usize, 0), d.clock.countReads(.within_ms));
}

test "a head that arrives whole still starts the header clock" {
    // The ordinary case: one read brings everything. `readHead` finds the
    // terminator on the first look and never has to wait again, so nothing is
    // armed at all — the read that mattered was the idle one, and the
    // connection loop armed that before calling in.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.get("/x", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, "ok");
        }
    }.run);
    try d.app.resolveChains();

    const sent = d.stall("GET /x HTTP/1.1\r\nHost: example.dev\r\n\r\n", 1024);

    try testing.expect(std.mem.startsWith(u8, sent.response, "HTTP/1.1 200"));
    try testing.expectEqual(@as(usize, 0), d.clock.countReads(.by_ns));
}

test "reading a body puts the body's limit on it, not the head's" {
    // The head's deadline has passed by the time a handler asks for the body,
    // so a body read that inherited it would fail at once.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.post("/echo", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, (try c.body()).view());
        }
    }.run);
    try d.app.resolveChains();

    const sent = d.stall(
        "POST /echo HTTP/1.1\r\nHost: example.dev\r\nContent-Length: 5\r\n\r\nhello",
        3,
    );

    try testing.expect(std.mem.endsWith(u8, sent.response, "hello"));
    try testing.expectEqual(bulkhead.Limit{ .within_ms = test_limits.body_ms }, d.clock.lastRead().?);
}

test "a WebSocket is allowed to sit quiet once the handshake is done" {
    // A chat tab with nobody typing is working correctly, and the limit that
    // protects the HTTP side would close it. Writes keep theirs.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.get("/ws", struct {
        fn run(c: *Ctx) anyerror!void {
            _ = try c.upgrade();
        }
    }.run);
    try d.app.resolveChains();

    const sent = d.stall(
        "GET /ws HTTP/1.1\r\nHost: example.dev\r\nUpgrade: websocket\r\n" ++
            "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
        1024,
    );

    try testing.expect(std.mem.startsWith(u8, sent.response, "HTTP/1.1 101"));
    try testing.expectEqual(bulkhead.Limit.none, d.clock.lastRead().?);
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
        // Held, necessarily: the document was generated into memory and
        // there is no directory for it to have spilled to.
        if (std.mem.eql(u8, f.url, "/openapi.json")) return f.contents.held.bytes;
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

fn docFindUser(_: *Db, id: u32) !?DocUser {
    _ = id;
    return null;
}
fn docMakeUser(_: *Db, _: DocNewUser) !typed.Status(201, DocUser) {
    return undefined;
}
fn docDropUser(_: *Db, _: u32) !typed.Status(204, void) {
    return .{};
}

test "the document names the statuses and failures the signatures settle" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{});

    try app.get("/users/:id", docFindUser);
    try app.post("/users", docMakeUser);
    try app.delete("/users/:id", docDropUser);

    const json = try docsFor(&app);

    // `Status(code, T)` puts the code in the type, so the document names it
    // instead of falling back to `default` (ADR 0024).
    try testing.expect(std.mem.indexOf(u8, json, "\"responses\":{\"201\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"responses\":{\"204\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"default\":") == null);

    // A handler returning `?T` promises a 404, and the body it describes is
    // the thing itself — not "the thing or null", which was the old answer
    // and the reason nobody could generate a client from this.
    try testing.expect(std.mem.indexOf(u8, json, "\"404\":") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"200\":{\"description\":\"the response\",\"content\":{\"application/json\":" ++
            "{\"schema\":{\"$ref\":\"#/components/schemas/DocUser\"}}}}",
    ) != null);

    // Every failure the document promises has the one shape all of them
    // take, described once (ADR 0025).
    try testing.expect(std.mem.indexOf(u8, json, "\"Failure\":{\"type\":\"object\"") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"$ref\":\"#/components/schemas/Failure\"",
    ) != null);
}

test "a shape used by more than one route is written once and referred to" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{});

    try app.get("/users/:id", docGetUser);
    try app.get("/users", docListUsers);
    try app.post("/users", docCreateUser);

    const json = try docsFor(&app);

    // The shape itself appears once, under the name of the Zig type it came
    // from, and everywhere else is a reference to it.
    try testing.expect(std.mem.indexOf(u8, json, "\"DocUser\":{\"type\":\"object\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"DocNewUser\":{\"type\":\"object\"") != null);

    var found: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, json, at, "\"$ref\":\"#/components/schemas/DocUser\"")) |i| {
        found += 1;
        at = i + 1;
    }
    // Once for the single user, once inside the list, once for the created
    // one — three references and one copy, where there used to be three
    // copies.
    try testing.expectEqual(@as(usize, 3), found);
    try testing.expectEqual(@as(usize, 1), countOccurrences(json, "\"id\":{\"type\":\"integer\"}"));
}

/// Handlers that write their own answer, and one that merely reads the
/// request before returning a value. The difference is the whole point of
/// the test below: taking a `*Ctx` is not what makes an endpoint
/// undescribable — returning nothing while holding one is.
fn docStreamsIt(c: *Ctx, id: u32) !void {
    var body = try c.stream(202, "text/csv");
    try body.print("id\n{d}\n", .{id});
    try body.finish();
}

fn docReadsHeaderThenAnswers(c: *Ctx) !DocUser {
    return .{ .id = 1, .name = c.header("X-Who") orelse Str.static("nobody") };
}

test "a handler that writes its own answer says so, instead of promising an empty 200" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});

    try app.get("/report/:id", docStreamsIt);
    try app.get("/me", docReadsHeaderThenAnswers);

    const json = try docsFor(&app);

    // The one that streams answers 202 with a CSV, and its signature says
    // none of that. Claiming "200, empty" — which is what reading the return
    // type alone produces — would be a document that is wrong twice.
    try testing.expect(std.mem.indexOf(u8, json, "writes its own response") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"an empty response\"") == null);

    // ...and holding a `*Ctx` is not itself the disqualification. This one
    // reads a header and still returns its answer, so the answer is known.
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"200\":{\"description\":\"the response\",\"content\":{\"application/json\":" ++
            "{\"schema\":{\"$ref\":\"#/components/schemas/DocUser\"}}}}",
    ) != null);
}

fn DocBox(comptime T: type) type {
    return struct { held: T, at: u32 };
}

fn docBoxedUser(db: *Db) !DocBox(DocUser) {
    _ = db;
    return .{ .held = .{ .id = 1, .name = .static("wati") }, .at = 0 };
}

fn docBoxedText(db: *Db) !DocBox([]const u8) {
    _ = db;
    return .{ .held = "hello", .at = 0 };
}

test "an instantiated generic keeps a name, made out of the one the compiler gives it" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{});

    try app.get("/boxed/user", docBoxedUser);
    try app.get("/boxed/text", docBoxedText);

    const json = try docsFor(&app);

    // `app.DocBox(app.DocUser)` read back into an identifier. Without this a
    // generic envelope — which is how Zig says "the same shape twice", and
    // so the answer to writing every body struct out again with `Str` in it
    // — costs the shape its name in every generated client.
    try testing.expect(std.mem.indexOf(u8, json, "\"DocBox_DocUser\":{\"type\":\"object\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"$ref\":\"#/components/schemas/DocBox_DocUser\"") != null);

    // A slice of bytes is text rather than `const_u8`, because that is what
    // it is on the wire and `DocBox_const_u8` is nobody's idea of a name.
    try testing.expect(std.mem.indexOf(u8, json, "\"DocBox_Text\":{\"type\":\"object\"") != null);
}

const nudged = struct {
    fn Box(comptime T: type) type {
        return struct { held: T };
    }
};

const shoved = struct {
    fn Box(comptime T: type) type {
        return struct { thrown: T };
    }
};

fn docNudgedBox(db: *Db) !nudged.Box(u32) {
    _ = db;
    return .{ .held = 1 };
}

fn docShovedBox(db: *Db) !shoved.Box(u32) {
    _ = db;
    return .{ .thrown = 2 };
}

test "a name two different generics both answer to belongs to neither" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{});

    try app.get("/nudged", docNudgedBox);
    try app.get("/shoved", docShovedBox);

    const json = try docsFor(&app);

    // Both render to `Box_u32` and they are not the same shape. A `$ref`
    // either way round would describe one endpoint as the other, so neither
    // gets the name and both are written out where they appear.
    try testing.expect(std.mem.indexOf(u8, json, "Box_u32") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"held\":{\"type\":\"integer\"}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"thrown\":{\"type\":\"integer\"}") != null);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |i| {
        n += 1;
        at = i + 1;
    }
    return n;
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
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // One: no CORS, so no response header list, and no body to read, so no
    // copy of the head. All that is left is the JSON.
    try testing.expectEqual(@as(usize, 1), counting.allocs);
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
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // One: the stream's own buffer. Two hundred pieces went out through it
    // and not one of them allocated — which is the promise ADR 0020 makes, and
    // the reason a stream can run for a week. (It was two; the request head is
    // no longer copied for a request with no body.)
    try testing.expectEqual(@as(usize, 1), counting.allocs);
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

// ---- request bodies read in pieces (ADR 0020) ----

/// Counts the body rather than holding it, which is the point: this handler
/// works the same for eleven bytes and eleven gigabytes.
fn weighBody(c: *Ctx) anyerror!void {
    var incoming = try c.bodyStream();
    var buf: [8]u8 = undefined;
    var total: u64 = 0;
    var pieces: u32 = 0;
    while (try incoming.read(&buf)) |part| {
        total += part.len;
        pieces += 1;
    }
    try c.sendJson(200, .{ .bytes = total, .pieces = pieces, .said = incoming.size() });
}

/// Reads the first few bytes and loses interest. App has to leave the
/// connection at the next request anyway.
fn peekBody(c: *Ctx) anyerror!void {
    var incoming = try c.bodyStream();
    var buf: [4]u8 = undefined;
    const first = (try incoming.read(&buf)) orelse "";
    try c.sendText(200, first);
}

test "a body read in pieces arrives whole, and says how big it said it was" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/weigh", weighBody);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /weigh HTTP/1.1\r\nContent-Length: 20\r\n\r\nabcdefghijklmnopqrst");

    // Twenty bytes through an eight-byte buffer: three reads, and the
    // handler never held more than eight of them.
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"bytes\":20,\"pieces\":3,\"said\":20}") != null);
    try testing.expect(result.keep_alive);
}

test "a chunked body read in pieces says nothing about its size" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/weigh", weighBody);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(
        &app,
        "POST /weigh HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\n",
    );

    // Twelve bytes of body, and `said` is null: a chunked body announces no
    // length, which is the whole reason it exists.
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"bytes\":12,\"pieces\":2,\"said\":null}") != null);
}

test "a body the handler stopped reading is discarded, and the connection continues" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/peek", peekBody);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(
        &app,
        "POST /peek HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\n",
    );

    try testing.expect(std.mem.endsWith(u8, result.response, "hell"));
    // Eight bytes of body were never read and the connection is still
    // offered: App finished what the handler started.
    try testing.expect(result.keep_alive);
}

test "a Content-Length past the ceiling is refused before a byte is read" {
    const refuse = struct {
        fn run(c: *Ctx) anyerror!void {
            var incoming = c.bodyStreamWith(.{ .max_bytes = 8 }) catch
                return fail.tooLarge("that upload is bigger than this endpoint takes", .{});
            var buf: [8]u8 = undefined;
            while (try incoming.read(&buf)) |_| {}
            try c.sendText(200, "took it");
        }
    }.run;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/upload", refuse);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /upload HTTP/1.1\r\nContent-Length: 20\r\n\r\nabcdefghijklmnopqrst");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 413"));
    try testing.expect(std.mem.indexOf(u8, result.response, "bigger than this endpoint takes") != null);
    // The body was never read, but it is still discarded, so the connection
    // is usable — a 413 is an answer, not a reason to hang up.
    try testing.expect(result.keep_alive);
}

test "a body read in pieces allocates nothing" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/weigh", weighBody);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    const request = "POST /weigh HTTP/1.1\r\nContent-Length: 200\r\n\r\n" ++ ("x" ** 200);
    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // Two: the request head, and the JSON answer. Two hundred bytes of body
    // went past in twenty-five reads and not one of them allocated —
    // `c.body()` would have made it three and held the lot.
    try testing.expectEqual(@as(usize, 2), counting.allocs);
}

// ---- asking for part of a file (ADR 0021) ----

test "a range asks for part of a file and gets a 206" {
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "alphabet.txt", "abcdefghijklmnopqrstuvwxyz" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static("/", files.path);

    var h = Harness.init();
    defer h.deinit();

    // A whole-file request advertises that ranges are possible at all.
    const whole = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, whole.response, "Accept-Ranges: bytes\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, whole.response, "abcdefghijklmnopqrstuvwxyz"));

    const part = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nRange: bytes=3-7\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, part.response, "HTTP/1.1 206 Partial Content\r\n"));
    try testing.expect(std.mem.indexOf(u8, part.response, "Content-Range: bytes 3-7/26\r\n") != null);
    // Content-Length is the part's length, not the file's.
    try testing.expect(std.mem.indexOf(u8, part.response, "Content-Length: 5\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, part.response, "defgh"));
    try testing.expect(part.keep_alive);

    // Resuming a download: everything from here on.
    const rest = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nRange: bytes=20-\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, rest.response, "Content-Range: bytes 20-25/26\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, rest.response, "uvwxyz"));

    // The tail, counted from the end.
    const tail = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nRange: bytes=-3\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, tail.response, "Content-Range: bytes 23-25/26\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, tail.response, "xyz"));
}

test "a range past the end of a file says how big it really is" {
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "alphabet.txt", "abcdefghijklmnopqrstuvwxyz" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static("/", files.path);

    var h = Harness.init();
    defer h.deinit();

    const past = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nRange: bytes=100-200\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, past.response, "HTTP/1.1 416 Range Not Satisfiable\r\n"));
    // The whole content of the answer, and the reason a client asked wrong.
    try testing.expect(std.mem.indexOf(u8, past.response, "Content-Range: bytes */26\r\n") != null);
    try testing.expect(past.keep_alive);

    // Nonsense is ignored rather than refused: the whole file is a correct
    // answer to every request, and a 416 for a typo helps nobody.
    const nonsense = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nRange: bytes=abc-def\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, nonsense.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, nonsense.response, "abcdefghijklmnopqrstuvwxyz"));

    // More than one range wants a multipart body zfast does not assemble.
    const several = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nRange: bytes=0-2,10-12\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, several.response, "HTTP/1.1 200 OK\r\n"));
}

test "If-Range holds a resumed download to the file it started with" {
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "alphabet.txt", "abcdefghijklmnopqrstuvwxyz" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static("/", files.path);

    var h = Harness.init();
    defer h.deinit();

    // Read the ETag off a normal response, the way a client resuming would.
    const first = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\n\r\n");
    const etag_at = std.mem.indexOf(u8, first.response, "ETag: ").? + 6;
    const etag_end = std.mem.indexOfPos(u8, first.response, etag_at, "\r\n").?;
    var etag_buf: [64]u8 = undefined;
    const etag = etag_buf[0 .. etag_end - etag_at];
    @memcpy(etag, first.response[etag_at..etag_end]);

    var request: [256]u8 = undefined;
    const matching = std.fmt.bufPrint(
        &request,
        "GET /alphabet.txt HTTP/1.1\r\nRange: bytes=20-\r\nIf-Range: {s}\r\n\r\n",
        .{etag},
    ) catch unreachable;
    const resumed = h.send(&app, matching);
    try testing.expect(std.mem.startsWith(u8, resumed.response, "HTTP/1.1 206"));

    // A stale ETag means the file is no longer the one the client started
    // with, so byte 20 of it is not the byte they wanted. All of it, then.
    const stale = h.send(
        &app,
        "GET /alphabet.txt HTTP/1.1\r\nRange: bytes=20-\r\nIf-Range: \"nope\"\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, stale.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, stale.response, "abcdefghijklmnopqrstuvwxyz"));
}

test "a HEAD with a range gets the head a GET would have, and no body" {
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "alphabet.txt", "abcdefghijklmnopqrstuvwxyz" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static("/", files.path);

    var h = Harness.init();
    defer h.deinit();

    const head = h.send(&app, "HEAD /alphabet.txt HTTP/1.1\r\nRange: bytes=3-7\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, head.response, "HTTP/1.1 206 Partial Content\r\n"));
    try testing.expect(std.mem.indexOf(u8, head.response, "Content-Range: bytes 3-7/26\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, head.response, "Content-Length: 5\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, head.response, "\r\n\r\n"));
}

// ---- WebSocket (ADR 0022) ----

fn echoSocket(c: *Ctx) anyerror!void {
    var socket = try c.upgrade();
    var buf: [1024]u8 = undefined;
    while (try socket.receive(&buf)) |message| {
        try socket.send(message.kind, message.data);
    }
}

const upgrade_request = "GET /ws HTTP/1.1\r\nHost: x\r\n" ++
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
    "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";

test "a WebSocket handshake is answered with the key every client checks" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", echoSocket);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, upgrade_request);

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 101 Switching Protocols\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Upgrade: websocket\r\n") != null);
    // The answer from RFC 6455 §1.3 for that key.
    try testing.expect(std.mem.indexOf(
        u8,
        result.response,
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n",
    ) != null);

    // The connection has stopped being HTTP, so it cannot carry another
    // request whatever anybody asked for.
    try testing.expect(!result.keep_alive);
}

test "a message sent over the upgraded connection comes back" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", echoSocket);

    var h = Harness.init();
    defer h.deinit();

    // The handshake and one masked text frame in the same buffer, which is
    // how a client that starts talking immediately looks on the wire.
    const frame = "\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58"; // "Hello"
    const result = h.send(&app, upgrade_request ++ frame);

    const after_head = std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4;
    // 0x81 = FIN + text, 0x05 = five bytes, no mask bit: a server never masks.
    try testing.expectEqualStrings("\x81\x05Hello", result.response[after_head..]);
}

test "a WebSocket allocates nothing per message, however many it carries" {
    // The claim the docs make about `receive`, which nothing checked. A
    // stream and a body reader each have a test like this one; the largest
    // and longest-lived of the three had none, which is the wrong way round
    // — a per-message allocation on a socket open for a day is a leak with
    // a nicer name.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", echoSocket);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [8192]u8 = undefined;

    // "Hello", masked, two hundred times over.
    const frame = "\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58";
    const conversation = upgrade_request ++ frame ** 200;

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(conversation);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // One: the request head. Not the handshake, not the frame headers, and
    // not one of the two hundred messages — `receive` reads into the buffer
    // the handler already owns, and a server frame is a ten-byte header
    // written straight to the connection.
    try testing.expectEqual(@as(usize, 1), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);
}

test "a request that is not asking to be upgraded is told which part is missing" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", echoSocket);

    var h = Harness.init();
    defer h.deinit();

    const plain = h.send(&app, "GET /ws HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, plain.response, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, plain.response, "Upgrade: websocket") != null);

    const no_version = h.send(
        &app,
        "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
    );
    try testing.expect(std.mem.indexOf(u8, no_version.response, "missing Sec-WebSocket-Version") != null);

    const wrong_version = h.send(
        &app,
        "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Version: 8\r\nSec-WebSocket-Key: x\r\n\r\n",
    );
    try testing.expect(std.mem.indexOf(u8, wrong_version.response, "speaks WebSocket version 13") != null);
}

// ---- who the client is (X-Forwarded-For) ----

fn echoClientIp(c: *Ctx) anyerror!void {
    try c.sendText(200, try std.fmt.allocPrint(c._arena, "{f}", .{c.clientIp()}));
}

// The whole point of the default. A server that believed the header
// without being told to would let anyone be any address they liked, and
// the things that read a client address — rate limits, audit logs,
// blocklists — are exactly the things worth lying to.
test "with no proxies trusted, a forged X-Forwarded-For is ignored" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", echoClientIp);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("198.51.100.7");

    const answer = h.send(&app, "GET /who HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, answer.response, "198.51.100.7"));
}

test "with one proxy trusted, the client is the entry that proxy wrote" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", echoClientIp);
    try app.resolveChains();
    app.limits.trusted_hops = 1;

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("10.0.0.1");

    // Nothing forged: the proxy appended the address it saw, and that is
    // the only entry there is.
    const plain = h.send(&app, "GET /who HTTP/1.1\r\nX-Forwarded-For: 203.0.113.9\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, plain.response, "203.0.113.9"));

    // The client sent an address of its own and the proxy appended after
    // it. Counting from the right reads the proxy's entry; the forgery is
    // to the left of it and is never looked at. This is why the count is
    // from the right and not from the left.
    const forged = h.send(
        &app,
        "GET /who HTTP/1.1\r\nX-Forwarded-For: 9.9.9.9, 203.0.113.9\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, forged.response, "203.0.113.9"));
}

test "with two proxies trusted, the client is two entries from the right" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", echoClientIp);
    try app.resolveChains();
    app.limits.trusted_hops = 2;

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("10.0.0.1");

    // A CDN saw the client and appended it; the load balancer saw the CDN
    // and appended that. Two hops back from the right is the client.
    const answer = h.send(
        &app,
        "GET /who HTTP/1.1\r\nX-Forwarded-For: 203.0.113.9, 198.51.100.2\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, answer.response, "203.0.113.9"));
}

test "a header with fewer entries than there are hops falls back to the socket" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", echoClientIp);
    try app.resolveChains();
    app.limits.trusted_hops = 2;

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("10.0.0.1");

    // Two proxies were configured and one entry turned up, so the chain is
    // not the one this server was told about. The closest guess would be
    // the client's own forgery, so there is no guess.
    const short = h.send(&app, "GET /who HTTP/1.1\r\nX-Forwarded-For: 9.9.9.9\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, short.response, "10.0.0.1"));

    // And no header at all is the same answer.
    const none = h.send(&app, "GET /who HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, none.response, "10.0.0.1"));
}

test "the socket's own address is there whatever the header says" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/peer", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, try std.fmt.allocPrint(c._arena, "{f}", .{c.peer()}));
        }
    }.run);
    try app.resolveChains();
    app.limits.trusted_hops = 1;

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("198.51.100.7");

    const answer = h.send(&app, "GET /peer HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, answer.response, "198.51.100.7"));
}

// ---- the body ceiling is a number somebody can change ----

test "a body past max_body is a 413, and max_body is what listen() was told" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, (try c.body()).view());
        }
    }.run);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    const body = "0123456789";
    const request = "POST /echo HTTP/1.1\r\nContent-Length: 10\r\n\r\n" ++ body;

    // Ten bytes is under the default megabyte.
    const allowed = h.send(&app, request);
    try testing.expect(std.mem.startsWith(u8, allowed.response, "HTTP/1.1 200"));

    // The same ten bytes against a ceiling of four.
    app.limits.max_body = 4;
    const refused = h.send(&app, request);
    try testing.expect(std.mem.startsWith(u8, refused.response, "HTTP/1.1 413"));

    // And raising it past the default works in the other direction, which
    // is the half a proxy in front cannot do for you.
    app.limits.max_body = 32 * 1024 * 1024;
    const raised = h.send(&app, request);
    try testing.expect(std.mem.startsWith(u8, raised.response, "HTTP/1.1 200"));
}

test "a chunked body is counted against max_body as it arrives" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, (try c.body()).view());
        }
    }.run);
    try app.resolveChains();
    app.limits.max_body = 4;

    var h = Harness.init();
    defer h.deinit();

    // No Content-Length to refuse up front, so the only way to catch this
    // is to count the chunks.
    const answer = h.send(
        &app,
        "POST /echo HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n0\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 413"));
}

// ---- static files, gzipped once at startup ----

/// Big enough and repetitive enough to be worth compressing, which is what
/// a real stylesheet or bundle is.
const test_css = "body { margin: 0; padding: 0; } " ** 64;

fn cssApp(gpa: std.mem.Allocator) !App {
    var app = App.init(gpa);
    errdefer app.deinit();
    try app.static_sets.append(gpa, try static_mod.fromMemory(gpa, &.{.{
        .url = "/app.css",
        .bytes = test_css,
        .content_type = "text/css",
    }}));
    try app.resolveChains();
    return app;
}

test "a client that says gzip gets the copy made at startup" {
    var app = try cssApp(testing.allocator);
    defer app.deinit();

    var h = Harness.init();
    defer h.deinit();

    const answer = h.send(&app, "GET /app.css HTTP/1.1\r\nAccept-Encoding: gzip\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, answer.response, "Content-Encoding: gzip") != null);
    // Whenever there are two representations, whichever one goes out.
    try testing.expect(std.mem.indexOf(u8, answer.response, "Vary: Accept-Encoding") != null);

    const body = answer.response[std.mem.indexOf(u8, answer.response, "\r\n\r\n").? + 4 ..];
    try testing.expect(body.len < test_css.len);
    try testing.expectEqual(@as(u8, 0x1f), body[0]);
    try testing.expectEqual(@as(u8, 0x8b), body[1]);
}

test "a client that says nothing gets the file as it is, and still gets Vary" {
    var app = try cssApp(testing.allocator);
    defer app.deinit();

    var h = Harness.init();
    defer h.deinit();

    const answer = h.send(&app, "GET /app.css HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, answer.response, "Content-Encoding") == null);
    // Said even though the plain copy is the one going out: a shared cache
    // that stored this without it would hand it to every client after,
    // including the ones that could have had the small one.
    try testing.expect(std.mem.indexOf(u8, answer.response, "Vary: Accept-Encoding") != null);
    try testing.expect(std.mem.endsWith(u8, answer.response, test_css));
}

test "a client that refuses gzip with q=0 is not sent gzip" {
    var app = try cssApp(testing.allocator);
    defer app.deinit();

    var h = Harness.init();
    defer h.deinit();

    const answer = h.send(&app, "GET /app.css HTTP/1.1\r\nAccept-Encoding: gzip;q=0\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, answer.response, "Content-Encoding") == null);
    try testing.expect(std.mem.endsWith(u8, answer.response, test_css));
}

test "the ETag of one representation does not answer for the other" {
    var app = try cssApp(testing.allocator);
    defer app.deinit();

    var h = Harness.init();
    defer h.deinit();

    // Collect both tags, from the two answers that carry them.
    var plain_buf: [128]u8 = undefined;
    const plain = h.send(&app, "GET /app.css HTTP/1.1\r\n\r\n");
    const plain_etag = try dupeHeader(&plain_buf, plain.response, "ETag");

    var gz_buf: [128]u8 = undefined;
    const gz = h.send(&app, "GET /app.css HTTP/1.1\r\nAccept-Encoding: gzip\r\n\r\n");
    const gz_etag = try dupeHeader(&gz_buf, gz.response, "ETag");

    try testing.expect(!std.mem.eql(u8, plain_etag, gz_etag));

    // Each tag is a 304 for its own representation.
    var buf: [512]u8 = undefined;
    const plain_again = h.send(&app, try std.fmt.bufPrint(
        &buf,
        "GET /app.css HTTP/1.1\r\nIf-None-Match: {s}\r\n\r\n",
        .{plain_etag},
    ));
    try testing.expect(std.mem.startsWith(u8, plain_again.response, "HTTP/1.1 304"));

    const gz_again = h.send(&app, try std.fmt.bufPrint(
        &buf,
        "GET /app.css HTTP/1.1\r\nAccept-Encoding: gzip\r\nIf-None-Match: {s}\r\n\r\n",
        .{gz_etag},
    ));
    try testing.expect(std.mem.startsWith(u8, gz_again.response, "HTTP/1.1 304"));

    // And neither is a 304 for the other. This is the failure the two tags
    // exist to prevent: a client holding the plain copy, now asking for
    // gzip, must be sent gzip rather than told what it has is current.
    const crossed = h.send(&app, try std.fmt.bufPrint(
        &buf,
        "GET /app.css HTTP/1.1\r\nAccept-Encoding: gzip\r\nIf-None-Match: {s}\r\n\r\n",
        .{plain_etag},
    ));
    try testing.expect(std.mem.startsWith(u8, crossed.response, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, crossed.response, "Content-Encoding: gzip") != null);
}

test "a range is served from the plain file even when gzip was offered" {
    var app = try cssApp(testing.allocator);
    defer app.deinit();

    var h = Harness.init();
    defer h.deinit();

    // A range is an offset into a representation. Answering with gzipped
    // bytes would hand back the wrong ones, silently.
    const answer = h.send(
        &app,
        "GET /app.css HTTP/1.1\r\nAccept-Encoding: gzip\r\nRange: bytes=0-4\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 206"));
    try testing.expect(std.mem.indexOf(u8, answer.response, "Content-Encoding") == null);
    try testing.expect(std.mem.endsWith(u8, answer.response, test_css[0..5]));
}

test "a file too small to be worth gzipping has one representation and no Vary" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static_sets.append(testing.allocator, try static_mod.fromMemory(testing.allocator, &.{.{
        .url = "/hi.txt",
        .bytes = "hello",
        .content_type = "text/plain",
    }}));
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    const answer = h.send(&app, "GET /hi.txt HTTP/1.1\r\nAccept-Encoding: gzip\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, answer.response, "Content-Encoding") == null);
    try testing.expect(std.mem.indexOf(u8, answer.response, "Vary") == null);
    try testing.expect(std.mem.endsWith(u8, answer.response, "hello"));
}

/// A response header, copied out of the raw answer into `buf` so it can
/// outlive the harness buffer the next request will overwrite.
fn dupeHeader(buf: []u8, response: []const u8, name: []const u8) ![]const u8 {
    const head_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.NoHead;
    var lines = std.mem.splitSequence(u8, response[0..head_end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len > buf.len) return error.NoRoom;
        @memcpy(buf[0..value.len], value);
        return buf[0..value.len];
    }
    return error.NoSuchHeader;
}

// The static half of the budget above. A compressed asset carries five
// response headers where a plain one carried three, and five is the number
// `inline_headers` was raised past — so this is what says the extra two did
// not quietly become an allocation on the path every asset goes down.
test "serving a gzipped static file allocates nothing, middleware included" {
    // Middleware in front of it, deliberately — this test used to leave it
    // out and say so, because a path that matched no route built its chain
    // out of the request arena and that one allocation would have hidden
    // what the test was measuring. Leaving it out meant the shape nearly
    // every app deploys — assets behind a logger — was the one shape the
    // allocation budget never checked. The chains are resolved at
    // `listen()` now, per file, so this is the case that proves it.
    var app = try cssApp(testing.allocator);
    defer app.deinit();

    // One global and one scoped somewhere else, so the chain is a genuine
    // filter of the registrations rather than all of them.
    try app.use(passThrough);
    try app.useOn("/api", passThrough);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [8192]u8 = undefined;

    const request = "GET /app.css HTTP/1.1\r\nHost: example.dev\r\n" ++
        "Accept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }

    counting.reset();
    pass_through_runs = 0;
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // The global one, and not the one scoped to `/api`.
    try testing.expectEqual(@as(usize, 1), pass_through_runs);

    // Zero, not one: the bytes were compressed when the App was built and
    // the body going out is a slice of them. Nothing is serialised, nothing
    // is copied, the five headers fit in the Ctx, and the chain the
    // middleware runs in was worked out before the socket opened.
    try testing.expectEqual(@as(usize, 0), counting.allocs);
}

test "a middleware scoped below a static prefix still runs, and still costs nothing" {
    // The case that decided this is resolved per file rather than per set.
    // A set has one prefix, so one chain for the whole of it would be the
    // chain for `/assets` — and this middleware, scoped underneath, would
    // never run. Getting that wrong is silent, and it is silent in the
    // direction of not running somebody's auth.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static_sets.append(testing.allocator, try static_mod.fromMemory(testing.allocator, &.{
        .{ .url = "/assets/open.css", .bytes = test_css, .content_type = "text/css" },
        .{ .url = "/assets/private/secret.css", .bytes = test_css, .content_type = "text/css" },
    }));
    try app.useOn("/assets/private", rejectingMiddleware);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    const open = h.send(&app, "GET /assets/open.css HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, open.response, "HTTP/1.1 200"));

    const shut = h.send(&app, "GET /assets/private/secret.css HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, shut.response, "HTTP/1.1 401"));
}

// ---- cookies, forms and redirects, down the real request path ----
//
// Each of the three has its own module and its own tests; what these are
// for is the wiring — that a cookie survives the head being parsed, that a
// form is read out of a body the connection really delivered, and that a
// redirect's Location comes out of the same header machinery everything
// else uses.

fn echoCookie(c: *Ctx) anyerror!void {
    const session = c.cookie("session") orelse
        return c.sendText(200, "no cookie");
    try c.sendText(200, session.view());
}

test "a cookie is read out of the head the connection delivered" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/me", echoCookie);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /me HTTP/1.1\r\nCookie: theme=dark; session=abc123\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, answer.response, "abc123"));

    // A request carrying no cookie at all takes the other branch rather
    // than reading somebody else's head.
    const bare = h.send(&app, "GET /me HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, bare.response, "no cookie"));
}

test "a cookie split across two Cookie headers is still found" {
    // What an HTTP/2 client's request looks like once a proxy has turned it
    // back into HTTP/1.1.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/me", echoCookie);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /me HTTP/1.1\r\nCookie: theme=dark\r\nCookie: session=abc123\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, answer.response, "abc123"));
}

test "reading a cookie allocates nothing" {
    // The claim `Ctx.cookie` makes: the header is walked where it lies, so a
    // request that carries cookies costs the same as one that does not
    // (ADR 0018's hard invariant, ADR 0030).
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/me", echoCookie);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    const request = "GET /me HTTP/1.1\r\nHost: example.dev\r\n" ++
        "Cookie: theme=dark; lang=id; session=abc123; consent=yes\r\n\r\n";

    for (0..3) |_| {
        var warm_in = std.Io.Reader.fixed(request);
        var warm_out = std.Io.Writer.fixed(&buf);
        _ = app.handleRequest(counting.allocator(), &lifetime, &in_flight, &warm_in, &warm_out, .off, .off, .{});
        lifetime.end();
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }

    counting.reset();
    var in = std.Io.Reader.fixed(request);
    var out = std.Io.Writer.fixed(&buf);
    _ = app.handleRequest(counting.allocator(), &lifetime, &in_flight, &in, &out, .off, .off, .{});

    try testing.expectEqual(@as(usize, 0), counting.allocs);
}

fn setsTwoCookies(c: *Ctx) anyerror!void {
    try c.setCookie(.{ .name = "session", .value = "abc123" });
    try c.setCookie(.{ .name = "theme", .value = "dark", .http_only = false, .secure = false });
    try c.sendEmpty(200);
}

test "two cookies are two Set-Cookie lines, not one replacing the other" {
    // The reason `http1.repeats` exists. Every other header replaces on a
    // second `setHeader`, and applying that rule here would have delivered
    // only the theme — silently, and only in the case where a login sets a
    // session alongside anything else.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/sign-in", setsTwoCookies);

    var client = try zfast_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/sign-in");
    try testing.expectEqual(@as(usize, 2), answer.headerCount("Set-Cookie"));
    try testing.expectEqualStrings(
        "session=abc123; Path=/; Secure; HttpOnly; SameSite=Lax",
        answer.setCookie("session").?,
    );
    try testing.expectEqualStrings("theme=dark; Path=/; SameSite=Lax", answer.setCookie("theme").?);
}

fn signsOut(c: *Ctx) anyerror!void {
    try c.clearCookie(.{ .name = "session" });
    try c.sendEmpty(204);
}

test "clearing a cookie sends one that has already expired" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sign-out", signsOut);

    var client = try zfast_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.post(&app, "/sign-out", "");
    try testing.expectEqual(@as(u16, 204), answer.status);
    const line = answer.setCookie("session").?;
    try testing.expect(std.mem.indexOf(u8, line, "Max-Age=0") != null);
    try testing.expect(std.mem.indexOf(u8, line, "Expires=Thu, 01 Jan 1970") != null);
}

fn setsASmuggledCookie(c: *Ctx) anyerror!void {
    // A value assembled from something the request supplied, which is how
    // this happens for real.
    try c.setCookie(.{ .name = "session", .value = "abc; Path=/admin" });
    try c.sendEmpty(200);
}

test "a cookie value that would smuggle an attribute is refused, not escaped" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/bad", setsASmuggledCookie);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /bad HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 500"));
    try testing.expect(try Harness.saysFailure(answer.response, "holds a character a cookie value cannot"));
    // And nothing went out with it.
    try testing.expect(std.mem.indexOf(u8, answer.response, "Set-Cookie") == null);
}

const SignIn = struct {
    email: Str,
    password: Str,
    remember: bool = false,
};

fn signIn(incoming: form_mod.Form(SignIn)) !redirect_mod.Redirect(303) {
    if (!incoming.value.email.eql("wati@example.dev")) {
        return fail.unauthorized("no such account", .{});
    }
    return .with("/welcome", .of(&.{
        .{ .name = "Set-Cookie", .value = "session=abc123; Path=/; HttpOnly" },
    }));
}

test "a urlencoded form reaches a typed handler, and its redirect carries the cookie" {
    // The whole shape of a sign-in, which is what these three features were
    // added for: a form in, a session cookie out, and a 303 so the browser's
    // reload does not post the form again.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sign-in", signIn);

    var client = try zfast_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.postWith(
        &app,
        "/sign-in",
        "application/x-www-form-urlencoded",
        "email=wati%40example.dev&password=hunter2&remember=true",
    );
    try testing.expectEqual(@as(u16, 303), answer.status);
    try testing.expectEqualStrings("/welcome", answer.header("Location").?);
    try testing.expectEqualStrings("session=abc123; Path=/; HttpOnly", answer.setCookie("session").?);
    // A redirect has no body to read.
    try testing.expectEqualStrings("", answer.body);
}

test "a form that does not fit is a 400 naming the field, like a query param" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sign-in", signIn);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const missing = h.send(&app, "POST /sign-in HTTP/1.1\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 24\r\n\r\n" ++
        "email=wati%40example.dev");
    try testing.expect(std.mem.startsWith(u8, missing.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(missing.response, "the form is missing \"password\""));

    const wrong_type = h.send(&app, "POST /sign-in HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
    try testing.expect(std.mem.startsWith(u8, wrong_type.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(wrong_type.response, "this endpoint takes a form"));
}

// ---- request ids ----

const logger_mod = @import("logger.zig");

fn echoesItsRequestId(c: *Ctx) ![]const u8 {
    return c.requestId().view();
}

test "a request with no id of its own is given one, and told which" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(logger_mod.with(.{ .request_id = true }));
    try app.get("/x", echoesItsRequestId);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /x HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));

    // Sixteen hex characters, and the handler and the response header agree
    // about which — one id per request, worked out once.
    const sent = sentHeader(answer.response, "X-Request-Id").?;
    try testing.expectEqual(@as(usize, 16), sent.len);
    for (sent) |ch| try testing.expect(std.ascii.isHex(ch));
    try testing.expect(std.mem.endsWith(u8, answer.response, sent));
}

test "an id from the proxy in front is adopted rather than replaced" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(logger_mod.with(.{ .request_id = true }));
    try app.get("/x", echoesItsRequestId);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /x HTTP/1.1\r\nX-Request-Id: 2f8a4c1e-5b6d\r\n\r\n");
    try testing.expectEqualStrings("2f8a4c1e-5b6d", sentHeader(answer.response, "X-Request-Id").?);
    try testing.expect(std.mem.endsWith(u8, answer.response, "2f8a4c1e-5b6d"));
}

test "an id that would smuggle something is ignored, not repeated" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(logger_mod.with(.{ .request_id = true }));
    try app.get("/x", echoesItsRequestId);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // A header value cannot carry a bare CR or LF this far — the parser
    // stops that — so the shape that does arrive is the one with characters
    // a JSON log line or a downstream reader would take as structure.
    const answer = h.send(&app, "GET /x HTTP/1.1\r\nX-Request-Id: \"quoted, and long\"\r\n\r\n");
    const sent = sentHeader(answer.response, "X-Request-Id").?;
    try testing.expectEqual(@as(usize, 16), sent.len);
    for (sent) |ch| try testing.expect(std.ascii.isHex(ch));

    // And an over-long one is dropped for the same reason.
    const long = h.send(&app, "GET /x HTTP/1.1\r\nX-Request-Id: " ++ ("a" ** 65) ++ "\r\n\r\n");
    try testing.expectEqual(@as(usize, 16), sentHeader(long.response, "X-Request-Id").?.len);
}

test "a request nobody asks about is given no id at all" {
    // The option costs a header on every response, so it is off by default
    // and `c.requestId()` is what a handler reaches for when it wants one.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(logger_mod.standard);
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /x HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, answer.response, "X-Request-Id") == null);
}

/// One response header's value, for the tests above.
fn sentHeader(response: []const u8, name: []const u8) ?[]const u8 {
    const head_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse response.len;
    var lines = std.mem.splitSequence(u8, response[0..head_end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
    }
    return null;
}

// ---- a binding that hands its failures back ----

const Registration = struct {
    email: Str,
    age: u32,
    newsletter: bool = false,
};

/// The shortcut: everything or a 422 naming what went wrong.
fn register(b: bound_mod.Bound(form_mod.Form(Registration))) ![]const u8 {
    const form = b.value() orelse return b.fail();
    return form.email.view();
}

/// The other way in: the handler decides what a failure looks like, and
/// reads back the text that was typed so a page could show it again.
fn registerShowingTheForm(
    arena: std.mem.Allocator,
    b: bound_mod.Bound(form_mod.Form(Registration)),
) !struct { wrong: []const []const u8, typed_age: []const u8 } {
    var wrong: std.ArrayList([]const u8) = .empty;
    var it = b.failures();
    while (it.next()) |f| try wrong.append(arena, f.field);
    return .{ .wrong = wrong.items, .typed_age = b.given("age").view() };
}

test "a form binding hands every failed field back at once" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/register", register);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // Two things wrong at once. The all-or-nothing `Form(T)` would have said
    // only the first, which is the gap this exists to close.
    const answer = h.send(&app, "POST /register HTTP/1.1\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 9\r\n\r\n" ++
        "age=soon&");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 422"));
    try testing.expect(try Harness.saysFailure(answer.response, "2 fields did not fit"));
    try testing.expect(try Harness.saysFailure(answer.response, "the form is missing \"email\" (text)"));
    try testing.expect(try Harness.saysFailure(
        answer.response,
        "\"age\" has to be a whole number, not \"soon\"",
    ));
}

test "a binding that bound answers exactly as the plain form would have" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/register", register);

    var client = try zfast_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.postWith(
        &app,
        "/register",
        "application/x-www-form-urlencoded",
        "email=wati%40example.dev&age=31",
    );
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings("wati@example.dev", answer.body);
}

test "a handler can answer its own way, and read back what was typed" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/register", registerShowingTheForm);

    var client = try zfast_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.postWith(
        &app,
        "/register",
        "application/x-www-form-urlencoded",
        "age=soon",
    );
    // 200, because the handler chose to answer rather than to fail.
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "{\"wrong\":[\"email\",\"age\"],\"typed_age\":\"soon\"}",
        answer.body,
    );
}

/// The same, on a JSON body rather than a form.
const NewOrder = struct {
    reference: Str,
    quantity: u32,
    priority: enum { low, high } = .low,
};

fn placeBoundOrder(b: bound_mod.Bound(NewOrder)) ![]const u8 {
    const order = b.value() orelse return b.fail();
    return order.reference.view();
}

test "a JSON body binding names every field that did not bind" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/orders", placeBoundOrder);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const body = "{\"quantity\":\"soon\",\"priority\":\"sideways\"}";
    var head_buf: [128]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "POST /orders HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;

    var request_buf: [256]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "{s}{s}", .{ head, body }) catch unreachable;

    const answer = h.send(&app, request);
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 422"));
    try testing.expect(try Harness.saysFailure(answer.response, "3 fields did not fit"));
    try testing.expect(try Harness.saysFailure(
        answer.response,
        "the request body is missing \"reference\" (text)",
    ));
    // Not `not "soon"`, the way a form would say it. In JSON a quoted value
    // is *text*, and sending text where a number belongs is a mistake about
    // the kind rather than about what the characters spell — which is the
    // sentence the body parser has always given, and this does not get to
    // reword it just because it collected several.
    try testing.expect(try Harness.saysFailure(
        answer.response,
        "\"quantity\" has to be a whole number, not text",
    ));
    try testing.expect(try Harness.saysFailure(
        answer.response,
        "\"priority\" is not one of the known choices (low, high): \"sideways\"",
    ));
}

test "what leaves no binding to hand back is still a plain 400" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/orders", placeBoundOrder);
    try app.post("/register", register);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // A field the endpoint has never heard of: naming the typo ends the
    // search, where "reference is missing" would not.
    const unknown = h.send(&app, "POST /orders HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 14\r\n\r\n" ++
        "{\"refrence\":1}");
    try testing.expect(std.mem.startsWith(u8, unknown.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(unknown.response, "a field \"refrence\" this endpoint does not know"));

    // Text that is not JSON at all is not a mistake about any one field.
    const garbage = h.send(&app, "POST /orders HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 5\r\n\r\n" ++
        "{[[[[");
    try testing.expect(std.mem.startsWith(u8, garbage.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(garbage.response, "not valid JSON"));

    // And a body that is not a form at all, on the form side.
    const not_a_form = h.send(&app, "POST /register HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
    try testing.expect(std.mem.startsWith(u8, not_a_form.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(not_a_form.response, "this endpoint takes a form"));
}

const NewAvatar = struct {
    caption: Str,
    image: form_mod.Upload,
};

fn uploadAvatar(incoming: form_mod.Form(NewAvatar)) !struct {
    caption: []const u8,
    filename: []const u8,
    content_type: []const u8,
    bytes: usize,
} {
    const image = incoming.value.image;
    return .{
        .caption = incoming.value.caption.view(),
        .filename = image.filename.view(),
        .content_type = image.content_type.view(),
        .bytes = image.len(),
    };
}

test "a multipart upload reaches a typed handler with its bytes intact" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/avatars", uploadAvatar);

    var client = try zfast_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const body = "--X\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\nme, squinting\r\n" ++
        "--X\r\nContent-Disposition: form-data; name=\"image\"; filename=\"me.png\"\r\n" ++
        "Content-Type: image/png\r\n\r\n\x89PNG\r\n\x1a\n....\r\n" ++
        "--X--\r\n";

    const answer = try client.postWith(&app, "/avatars", "multipart/form-data; boundary=X", body);
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "{\"caption\":\"me, squinting\",\"filename\":\"me.png\"," ++
            "\"content_type\":\"image/png\",\"bytes\":12}",
        answer.body,
    );
}

test "an endpoint wanting a file, sent a form that cannot carry one, says which to send" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/avatars", uploadAvatar);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "POST /avatars HTTP/1.1\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\n" ++
        "caption=hey");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(answer.response, "has to be sent as multipart/form-data"));
}

fn redirectsItself(c: *Ctx) anyerror!void {
    try c.redirect(302, "/somewhere-else");
}

test "a *Ctx handler can redirect, and a redirect carries no body" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/old", redirectsItself);

    var client = try zfast_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/old");
    try testing.expectEqual(@as(u16, 302), answer.status);
    try testing.expectEqualStrings("/somewhere-else", answer.header("Location").?);
    try testing.expectEqualStrings("0", answer.header("Content-Length").?);
    try testing.expectEqualStrings("", answer.body);
    // A redirect is an ordinary answer, so the connection carries on.
    try testing.expect(answer.keep_alive);
}

fn redirectsNowhere(c: *Ctx) anyerror!void {
    try c.redirect(302, "");
}

test "a redirect with nowhere to go is a 500 rather than a Location nobody can follow" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/old", redirectsNowhere);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /old HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 500"));
    try testing.expect(try Harness.saysFailure(answer.response, "has to say where to"));
}

fn docsSignIn(_: form_mod.Form(SignIn)) !redirect_mod.Redirect(303) {
    return .to("/welcome");
}

fn docsUpload(_: form_mod.Form(NewAvatar)) !typed.Status(201, DocUser) {
    return .{ .value = .{ .id = 1, .name = .static("x") } };
}

test "the document says which encoding a form takes, and where a redirect sends you" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sign-in", docsSignIn);
    try app.post("/avatars", docsUpload);
    app.docs(.{ .title = "Forms" });

    // Borrowed from the App, which owns it — not a copy to free.
    const document = try docsFor(&app);

    // A form with no file in it is what a browser sends urlencoded; one with
    // a file can only be multipart, and a generated client that guessed
    // would post something the endpoint refuses.
    try testing.expect(std.mem.indexOf(u8, document, "\"application/x-www-form-urlencoded\":{\"schema\":") != null);
    try testing.expect(std.mem.indexOf(u8, document, "\"multipart/form-data\":{\"schema\":") != null);
    // The file itself is bytes, not the three-field struct carrying it.
    try testing.expect(std.mem.indexOf(u8, document, "\"image\":{\"type\":\"string\",\"format\":\"binary\"}") != null);
    // And the redirect promises the one header that makes it followable.
    try testing.expect(std.mem.indexOf(u8, document, "\"303\":{\"description\":\"the client is sent somewhere else\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "\"Location\"") != null);
    // Nothing about a JSON body, which neither of these takes.
    try testing.expect(std.mem.indexOf(u8, document, "\"requestBody\":{\"required\":true,\"content\":{\"application/json\"") == null);
}

// ---- a handler that holds its thread (ADR 0034) ----
//
// The whole point of these is that the detector is watched failing, in the
// shape a person would hit it (ADR 0033). They cost real milliseconds of
// wall clock, which is the price of measuring something whose unit is time.

/// Hold this thread for `ms`, the way a database driver waiting on a socket
/// would. Spelled out rather than reached for from `std`, which in Zig 0.16
/// only sleeps through an `Io` — and an `Io` is exactly the thing a handler
/// that makes this mistake does not have.
fn holdFor(ms: u64) void {
    const until = bulkhead.monotonicNanos() + ms * std.time.ns_per_ms;
    while (bulkhead.monotonicNanos() < until) {}
}

const held_ms = 30;

fn holdsTheThread(c: *Ctx) anyerror!void {
    holdFor(held_ms);
    try c.sendEmpty(200);
}

fn waitsProperly(c: *Ctx) anyerror!void {
    // The same wait, done right. With no Engine underneath, `blocking` runs
    // the call inline — so this test really does spend the 20ms on this
    // thread, and passes only because the wait is accounted for, not because
    // it did not happen.
    bulkhead.blocking(holdFor, .{held_ms});
    try c.sendEmpty(200);
}

test "a handler that blocks is caught, on the first request and with nobody else waiting" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = 10;
    try app.get("/slow", holdsTheThread);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    const answer = h.send(&app, "GET /slow HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));
    try testing.expectEqual(before + 1, watchdog.caught.load(.monotonic));
}

test "the same wait through zfast.blocking is not" {
    // The half that decides whether anybody keeps the detector switched on.
    // A guard that fires on correct code is a guard that gets turned off,
    // and then it is not a guard.
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = 10;
    try app.get("/slow", waitsProperly);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    const answer = h.send(&app, "GET /slow HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));
    try testing.expectEqual(before, watchdog.caught.load(.monotonic));
}

test "zero turns it off, and then even a blocking handler goes unremarked" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = 0;
    try app.get("/slow", holdsTheThread);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    _ = h.send(&app, "GET /slow HTTP/1.1\r\n\r\n");
    try testing.expectEqual(before, watchdog.caught.load(.monotonic));
}

fn streamsSlowly(c: *Ctx) anyerror!void {
    var out = try c.stream(200, "text/plain");
    holdFor(held_ms);
    try out.writeAll("done");
    try out.finish();
}

test "a stream is excused, because holding the connection is what it is for" {
    // The stated gap, pinned so that closing it later is a decision rather
    // than a surprise: a blocking call inside a stream, a body reader or a
    // WebSocket is real and is not reported.
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = 10;
    try app.get("/feed", streamsSlowly);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    const answer = h.send(&app, "GET /feed HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));
    try testing.expectEqual(before, watchdog.caught.load(.monotonic));
}

fn blocksAfterAnswering(c: *Ctx) anyerror!void {
    try c.sendEmpty(200);
    holdFor(held_ms);
}

test "work after the answer went out is still work, and still counted" {
    // Stopping the clock at the response would have been simpler and would
    // have missed a middleware that logs to a file after `next.run`, which
    // is the second most common way to block.
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = 10;
    try app.get("/late", blocksAfterAnswering);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    _ = h.send(&app, "GET /late HTTP/1.1\r\n\r\n");
    try testing.expectEqual(before + 1, watchdog.caught.load(.monotonic));
}

fn blocksThenFails(_: *Ctx) anyerror!void {
    holdFor(held_ms);
    return fail.notFound("nothing here", .{});
}

test "a handler that blocks and then fails is caught on the way out" {
    // Two exits from the chain, and the early one is the one a hand-written
    // pair of calls can forget.
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = 10;
    try app.get("/gone", blocksThenFails);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    const answer = h.send(&app, "GET /gone HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 404"));
    try testing.expectEqual(before + 1, watchdog.caught.load(.monotonic));
}

fn locksAndAnswers(c: *Ctx) anyerror!void {
    var lock: bulkhead.Mutex = .init;
    try lock.lock();
    try testing.expect(!lock.tryLock());
    lock.unlock();
    try c.sendEmpty(200);
}

test "a zfast.Mutex still locks after being wrapped for the detector" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/guarded", locksAndAnswers);

    var h = Harness.init();
    defer h.deinit();
    const answer = h.send(&app, "GET /guarded HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));
}
