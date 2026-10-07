//! App — one self-contained HTTP application: its routes, services,
//! middleware and static files. It wires the Bulkhead, the HTTP/1.1
//! parser, the Router, the request arena, and Ctx into one thing.
//!
//! `handleRequest` is deliberately separate from the Engine: all it needs
//! is a `std.Io.Reader`/`Writer`, so every bit of App's HTTP behaviour can
//! be tested against in-memory buffers, without starting a server.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");
const grpc = @import("grpc.zig");
const http1 = @import("http1.zig");
const router = @import("router.zig");
const ctx_mod = @import("ctx.zig");
const str_mod = @import("nilo_core");
const service_mod = @import("service.zig");
const typed = @import("typed.zig");
const cached_mod = @import("cached.zig");
const fail = @import("fail.zig");
const mw = @import("middleware.zig");
const static_mod = @import("static.zig");
const proxies_mod = @import("proxies.zig");
const openapi = @import("openapi.zig");
const budget = @import("budget.zig");
const session_mod = @import("session.zig");
const password_mod = @import("password.zig");
const metrics_mod = @import("metrics.zig");
const serve = @import("serve.zig");
const framing_mod = @import("framing.zig");
const wiring = @import("wiring.zig");
const health_mod = @import("health.zig");
const failurebody = @import("failurebody.zig");
const connect = @import("connect.zig");
const rpc_mod = @import("rpc.zig");
const compress_mod = @import("compress.zig");
const trace_mod = @import("trace.zig");

/// Say so if the program was built in a mode its log level does not match.
/// Lives in `wiring.zig`; re-exported because `nilo.warn…` is public API.
pub const warnIfBuiltDifferently = wiring.warnIfBuiltDifferently;

const Ctx = ctx_mod.Ctx;

/// How much of a connection's request arena survives between requests, when
/// `listen()` was not told otherwise.
///
/// Big enough that an ordinary request never allocates twice on the same
/// connection, small enough that one large upload does not leave that
/// connection sitting on the memory for good.
///
/// **A response larger than this is a page fault per 4 KiB, every request.**
/// The arena hands the block back on reset, so the next request takes fresh
/// pages and the kernel zeroes every one of them. Measured on a route
/// answering a megabyte: 257 minor faults a request, and raising this past
/// the response took the same route from 7,908 req/s to 11,069
/// ([ADR 075](../docs/adr/075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)).
/// That is why it is a `listen()` option and not only this constant.
pub const default_arena_keep = 16 * 1024;

/// The health page (ADR 154). A `*Ctx` handler rather than a typed one
/// because what it reads is the registry itself, which no argument type
/// names.
fn healthRoute(c: *Ctx) anyerror!void {
    var scope = str_mod.AnyScope.of(c);
    var out: std.Io.Writer.Allocating = try .initCapacity(c.arena(), 256);
    const outcome = try health_mod.write(&out.writer, &scope, c._services.entries.items, c.stopping());
    // A health answer a proxy remembers is a health answer about the past.
    try c.setStaticHeader("Cache-Control", "no-store");
    try c.send(@intFromEnum(outcome), health_mod.content_type, out.written());
}

/// The two calls `app.trace` gives the request path (`serve.trace_hooks`).
pub const TraceHooks = struct {
    begin: *const fn (*ctx_mod.Ctx, *trace_mod.Tracer) void,
    finish: *const fn (*ctx_mod.Ctx, []const u8) void,
    /// The rings, once the thread count is known (`wiring.resolveChains`).
    size: *const fn (*App) anyerror!void,
    /// The exporter and the tracer, after the services have stopped.
    free: *const fn (*App) void,
};

/// What `trace()` points the App at. Referenced from nowhere else, so none
/// of what it names is compiled into a program that never traces (ADR 247).
const tracing_hooks: TraceHooks = .{
    .begin = serve.traceBegin,
    .finish = serve.traceFinish,
    .size = wiring.sizeTracer,
    .free = freeTracing,
};

fn freeTracing(self: *App) void {
    const otlp = @import("otlp.zig");
    if (self.exporter) |erased| {
        const e: *otlp.Exporter = @ptrCast(@alignCast(erased));
        e.deinit();
        self.gpa.destroy(e);
    }
    if (self.tracer) |tracer| {
        tracer.deinit();
        self.gpa.destroy(tracer);
    }
}

pub const App = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.App";

    gpa: std.mem.Allocator,
    router: router.Router,
    services: service_mod.Registry,
    /// The services handlers asked for, collected as routes are registered
    /// and checked once in `listen()` (ADR 005).
    requirements: std.ArrayList(service_mod.Requirement) = .empty,
    /// Middleware registrations, in the order `use` was called.
    scoped: std.ArrayList(mw.Scoped) = .empty,
    /// Routes that said a middleware does not cover them, from `without`
    /// (ADR 008). Empty for almost every App: the shape it exists for is the
    /// sign-up route inside a prefix that requires a session.
    exemptions: std.ArrayList(mw.Exemption) = .empty,
    /// The networks `listen(.{ .trusted_proxies = … })` named, parsed once
    /// (ADR 102). Owned by the App; `limits.trusted_proxies` points at it.
    trusted_proxies: []const proxies_mod.Cidr = &.{},
    /// Routes carrying a middleware of their own, from `with` (ADR 099). The
    /// other direction of the same question, and empty for almost every App
    /// too: the shape it exists for is the one endpoint inside a group that
    /// needs a guard its neighbours do not.
    attached: std.ArrayList(mw.Attached) = .empty,
    /// The limits `maxBody` gave, one per function it made, from `use` and
    /// `with`. A gRPC call is collected before its middleware runs, so the
    /// limit it is collected under is found here, by the functions in the
    /// route's chain (ADR 156, ADR 220). Empty unless `maxBody` is used.
    body_limits: std.ArrayList(mw.Limited) = .empty,
    /// The middleware `guard` said reads the session cookie, if one did
    /// (ADR 153). Read by `writeOpenApi` and by nothing on the request path.
    declared_guard: ?mw.Guard = null,
    /// Directories loaded into memory by `static`, searched only when no
    /// route matched (ADR 009).
    static_sets: std.ArrayList(static_mod.Set) = .empty,
    /// What each route's signature says about it, collected as routes are
    /// registered and turned into an OpenAPI document by `listen()` if
    /// `docs()` asked for one (ADR 016).
    operations: std.ArrayList(openapi.Operation) = .empty,
    /// The `operationId` of every route that did not say its own, worked
    /// out once at registration so that `Ctx.routeName` can hand it to a
    /// middleware without a request paying to spell it (ADR 162). One
    /// allocation per unnamed route at boot, and nothing per request; a
    /// route registered through `named` points at its comptime literal and
    /// takes no slot here.
    derived_names: std.ArrayList([]const u8) = .empty,
    docs_options: ?openapi.Options = null,
    /// The body a failure goes out with, from `failures()`, or null for
    /// nilo's own `{"error":…,"status":…}` (ADR 024). Read on the failure
    /// path only, so a request that succeeds never touches it. The schema
    /// beside it is what the document says under `Failure`; set together.
    failure_write: ?failurebody.Write = null,
    failure_schema: ?*const openapi.Schema = null,
    /// Connect's failure body, for a request that says it is a Connect call;
    /// set by the first route that reads or answers a message and null in a
    /// program with none, which then links none of it (ADR 257).
    failure_connect: ?failurebody.Pick = null,
    /// Every counter in the process, or null on a server that never called
    /// `metrics()` — which is what makes the whole feature one branch on the
    /// request path (ADR 079). Sized when the chains are resolved, because
    /// that is the moment the route count stops moving.
    ///
    /// Held by value rather than allocated so that `metrics()` can hand a
    /// pointer to it straight to the service registry, which is how the
    /// readout handler reaches it without `Ctx` growing a field.
    metrics_table: ?metrics_mod.Table = null,
    /// Numbers the application owns and asked nilo to publish, from
    /// `expose()`. Empty for almost every App, and read only by a scrape.
    exposed: std.ArrayList(metrics_mod.Exposed) = .empty,
    /// What `compress()` asked for, kept until the chains are resolved and
    /// the thread count is known, which is when the pool is sized. Null on
    /// every App that never asked.
    compress_options: ?compress_mod.Options = null,
    /// The compressors, one per thread, built at `resolveChains` and never
    /// touched by a request's stack (ADR 211). Held by value so that a
    /// request can point at it, the way `_session_key` points at the key.
    compressors: ?compress_mod.Pool = null,
    /// How many compressors to build: the thread count `listen()` was given,
    /// set just before the chains are resolved. 0 means one per core, which
    /// is what `start(io)` and a test that resolves the chains by hand get.
    compress_slots: u8 = 0,
    /// What `trace()` set up: the rings, the exporter and its client. Null on
    /// every App that never asked, and then a request pays one compare
    /// (ADR 247). On the heap, because it is a service and a service is
    /// handed out by pointer.
    tracer: ?*trace_mod.Tracer = null,
    /// The exporter `trace()` made, behind a pointer with its type erased:
    /// `otlp.zig` is what names `nilo_fetch` and `nilo_proto`, and an App
    /// that never traces must not reach it, `deinit` included (ADR 247).
    exporter: ?*anyopaque = null,
    /// The span the request path opens and closes, set with `tracer` and
    /// only by `trace()`. A pointer rather than a call because a call behind
    /// a runtime null is still linked: this way a program that never traces
    /// carries none of the ids, the header walk or the ring (ADR 247).
    trace_hooks: ?*const TraceHooks = null,
    /// The generated document and its reader page, held the way a loaded
    /// directory is so that ETags and 304s arrive without a second code
    /// path. Null until `listen()` builds it.
    docs_set: ?static_mod.Set = null,
    /// One middleware chain per file in `docs_set`, in the same order, and
    /// the same again for each entry of `static_sets`. Resolved at
    /// `listen()` beside the routes' chains, and for the same reason: a
    /// static file is a hot path, and building its chain per request is an
    /// allocation on a path that did not ask for one
    /// ([ADR 017](../docs/adr/017-the-trade-budget-has-four-axes.md)).
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
    /// The port the Engine bound, written once by `serverStarting` and read
    /// by `boundPort()` from whichever thread asks. 0 is "not yet", and a
    /// unix socket.
    bound_port: std.atomic.Value(u16) = .init(0),
    /// The part of `listen()`'s options a request reads rather than the
    /// socket, copied out once when the server starts. Defaults stand for
    /// an App a test drives directly, which never calls `listen()`; a test
    /// that wants another `max_body`, `max_in_flight` or deadline sets the
    /// field, `wired.app.limits.max_body = 4096`, the way it sets
    /// `session_key`.
    limits: Limits = .{},
    /// How much of a connection's request arena survives between requests,
    /// from `listen(.{ .arena_keep = … })`. Held here rather than read from
    /// `limits` because it is the connection loop's, not a request's, and
    /// `Limits` is Core's and is shared with modules that have no arena.
    arena_keep: usize = default_arena_keep,
    /// The key session cookies are sealed with, from
    /// `listen(.{ .session_secret = … })` and checked there. Null for an App
    /// with no sessions, and for one a test drives directly — a test that
    /// wants sessions sets this field.
    session_key: ?session_mod.Key = null,
    /// Secrets a session cookie is opened under when `session_key` does not
    /// open it, and never sealed under, from
    /// `listen(.{ .session_fallback_secrets = … })` (ADR 225). A test that wants a rotation sets this field, the way it
    /// sets `session_key`.
    session_fallbacks: []const session_mod.Key = &.{},
    /// Where `listen()` copies the fallback secrets, so that what the caller
    /// passed does not have to outlive the call. `session_fallbacks` points
    /// into it.
    fallback_store: [session_mod.max_fallbacks]session_mod.Key = undefined,
    /// Whether a plain `session` cookie is read, from
    /// `listen(.{ .session_plain_name = … })`. A test that sends one sets
    /// this field, the way it sets `session_key`.
    session_plain_name: bool = false,
    /// Who ran `nilo_start` over the registry, if anybody. `start` sets it
    /// for a program that never listens — a test, a script — and `listen()`
    /// sets it on the server's own loop. **`.start` and then `listen()` is
    /// refused** when a service took that `Io`, because it was the wrong
    /// one (ADR 180).
    services_started: StartedBy = .nobody,
    /// Work that needs the services and has to finish before the first
    /// request: a migration, a version guard, a key set fetched once.
    /// Registered with `before`, run by `listen()` on the server's loop
    /// after the services have started (ADR 180). Empty for most Apps.
    before_serving: std.ArrayList(Background) = .empty,
    /// Whether the list above has run. A second `listen()` on the same App
    /// — a test that restarts one — does not migrate twice.
    before_ran: bool = false,
    /// Whether every service's `nilo_check` has run, once, after the list
    /// above (ADR 180). Held apart from `before_ran` for the reason
    /// `background_started` is: set at a different moment, by either of
    /// `start` and `listen()`.
    checks_ran: bool = false,
    /// Work that is not a request, registered before the server exists and
    /// started once it does (ADR 028). Empty for almost every App.
    background: std.ArrayList(Background) = .empty,
    /// Whether the list above has been started. Separate from
    /// `services_started` on purpose: the two are set at different moments
    /// and a program that ran `start()` before `listen()` must still get its
    /// background work started.
    background_started: bool = false,

    /// Which of the two callers of `startServices` got there, which is what
    /// the refusal in `serverStarting` reads: the services are on a loop of
    /// their own only when it was `start`.
    const StartedBy = enum { nobody, start, listen };

    /// One registration from `spawn` or `before`, with the function and its
    /// arguments erased so the App can hold a list of them.
    ///
    /// The arguments are kept in an allocation of the App's rather than in
    /// the list, because their type differs per entry and the list holds one
    /// kind of thing. It is startup memory — one allocation per registered
    /// function, none per connection and none per request.
    ///
    /// `start` takes the App's allocator and the loop's `Io` as well as the
    /// arguments. `spawn` has no use for either — the fiber it starts finds
    /// the loop through the Bulkhead — and `before` builds the boot's `Run`
    /// out of both, so that work which mints a key there can (ADR 128).
    const Background = struct {
        args: *anyopaque,
        start: *const fn (args: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror!void,
        free: *const fn (gpa: std.mem.Allocator, args: *anyopaque) void,
    };

    /// Where this is mounted, which for an App is nowhere — the empty prefix.
    ///
    /// Here so that a plugin written as `fn mount(g: anytype) !void` can ask
    /// without caring whether it was handed a group or the App itself, which
    /// is the shape `guide/routing.md` recommends (ADR 008).
    pub const mounted_at = "";

    /// What one request is allowed to do. Declared on the Ctx, which is
    /// what reads it.
    pub const Limits = ctx_mod.Limits;

    pub fn init(gpa: std.mem.Allocator) App {
        return .{
            .gpa = gpa,
            .router = router.Router.init(gpa),
            .services = service_mod.Registry.init(gpa),
        };
    }

    pub fn deinit(self: *App) void {
        for (self.background.items) |b| b.free(self.gpa, b.args);
        self.background.deinit(self.gpa);
        for (self.before_serving.items) |b| b.free(self.gpa, b.args);
        self.before_serving.deinit(self.gpa);
        wiring.freeChains(self);
        if (self.docs_set) |*set| set.deinit();
        self.operations.deinit(self.gpa);
        for (self.derived_names.items) |name| self.gpa.free(name);
        self.derived_names.deinit(self.gpa);
        if (self.metrics_table) |*t| t.free(self.gpa);
        self.exposed.deinit(self.gpa);
        if (self.compressors) |*p| p.deinit(self.gpa);
        for (self.static_sets.items) |*s| s.deinit();
        self.static_sets.deinit(self.gpa);
        self.static_chains.deinit(self.gpa);
        self.scoped.deinit(self.gpa);
        self.exemptions.deinit(self.gpa);
        self.attached.deinit(self.gpa);
        self.body_limits.deinit(self.gpa);
        self.gpa.free(self.trusted_proxies);
        self.requirements.deinit(self.gpa);
        self.services.deinit();
        // After the services: the tracer is one, and its stop hook is what
        // sends the last of the spans.
        if (self.trace_hooks) |hooks| hooks.free(self);
        self.router.deinit();
    }

    /// Everything registered through the returned value sits under
    /// `prefix` — routes, middleware, static files and further groups
    /// (ADR 014).
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
    /// order (ADR 008).
    pub fn use(self: *App, middleware: anytype) !void {
        try self.noteLimit(middleware);
        try self.scoped.append(self.gpa, .{ .prefix = "", .middleware = mw.runOf(middleware) });
    }

    /// Keep what `maxBody` says, if `middleware` is one, for the gRPC side to
    /// find (ADR 220). A function is one limit, so one entry is enough.
    fn noteLimit(self: *App, middleware: anytype) !void {
        if (@TypeOf(middleware) != mw.Limited) return;
        for (self.body_limits.items) |l| if (l.run == middleware.run) return;
        try self.body_limits.append(self.gpa, middleware);
    }

    /// Add a middleware that runs only on routes under `prefix`.
    ///
    /// ```zig
    /// try app.useOn("/api", requireToken);
    /// ```
    pub fn useOn(self: *App, prefix: []const u8, middleware: anytype) !void {
        std.debug.assert(prefix.len > 0 and prefix[0] == '/');
        try self.noteLimit(middleware);
        try self.scoped.append(self.gpa, .{ .prefix = prefix, .middleware = mw.runOf(middleware) });
    }

    /// The App, with `middleware` off for the routes registered through what
    /// this hands back.
    ///
    /// The shape it exists for is the one every API with accounts has: a prefix
    /// behind a session, and the two routes inside it that cannot be, because
    /// you cannot require a session to create one
    /// ([ADR 008](../docs/adr/008-middleware-is-an-onion-of-ctx-functions.md)).
    ///
    /// ```zig
    /// const v1 = app.group("/v1");
    /// try v1.use(requireOperator);
    ///
    /// const open = v1.without(requireOperator);
    /// try open.post("/sign-up", signUp);
    /// try open.post("/sign-in", signIn);
    /// ```
    ///
    /// **The default stays deny**, so a route added later is guarded by
    /// accident rather than exposed by accident — and the exception is written
    /// where the route is, so renaming the route moves it (ADR 008).
    pub fn without(self: *App, comptime middleware: anytype) GroupOf("", &.{mw.runOf(middleware)}) {
        return .{ .app = self };
    }

    /// The App, with `middleware` on for the routes registered through what
    /// this hands back — one route, if one route is what you register.
    ///
    /// The case `without` leaves open: a route that wants *more* than its
    /// neighbours, without inventing a prefix that matches only it
    /// ([ADR 099](../docs/adr/099-a-route-can-say-what-covers-it.md)).
    ///
    /// ```zig
    /// try app.with(requireAdmin).delete("/users/:id", removeUser);
    ///
    /// const v1 = app.group("/v1");
    /// try v1.use(requireOperator);
    /// try v1.with(auditLog).post("/orders", place);   // composes with a group
    /// ```
    ///
    /// **It runs innermost**, after everything a `use` put in front of the same
    /// route, whatever order the two were written in — a group's session check
    /// has to run before the route's own check of what that session may do.
    pub fn with(self: *App, comptime middleware: anytype) GroupWith("", &.{}, &.{mw.runOf(middleware)}, mw.limitsOf(middleware), null, router.every_listener) {
        return .{ .app = self };
    }

    /// The App, answering the routes registered through what this hands back
    /// only on the listeners numbered in `which`: `0` is the one `.address`
    /// and `.port` name, `1` the first `.also` entry, and so on. A request
    /// that arrived on another listener finds no such route and gets the
    /// 404 an unknown path gets, decided before any middleware runs
    /// ([ADR 252](../docs/adr/252-a-request-knows-which-listener-it-came-in-on.md)).
    ///
    /// ```zig
    /// const ingest = app.onListener(&.{1});
    /// try ingest.post("/v1/logs", receiveLogs);
    /// try app.onListener(&.{0}).group("/api").get("/status", status);
    /// ```
    ///
    /// A route that is not bound is answered on every listener, as before.
    /// **A path is one route** whichever listener it is bound to: the same
    /// method and shape registered twice is still `DuplicateRoute`.
    pub fn onListener(self: *App, comptime which: []const u8) GroupWith("", &.{}, &.{}, &.{}, null, router.listenerBits(which)) {
        return .{ .app = self };
    }

    /// Say that `middleware` refuses a request without the session cookie
    /// named `cookie`, so the API description can say so too
    /// ([ADR 153](../docs/adr/153-an-authorization-header-a-handler-can-ask-for.md)).
    ///
    /// ```zig
    /// const api = app.group("/api");
    /// try api.use(requireSession);
    /// try app.guard(requireSession, nilo.session.host_cookie_name);
    /// ```
    ///
    /// Every route the middleware is in front of — through `use`, `useOn`
    /// or `with`, less what `without` took out — is written with a
    /// `cookieAuth` requirement and a 401; the rest are written as they
    /// were. Which routes those are is read from the middleware wiring when
    /// the document is written, so an exception moves in the document the
    /// moment it moves in the program. The cookie's name is the one thing
    /// the document takes on your word.
    ///
    /// Declaring it does not install it: `use` the middleware as before.
    /// One guard per App, because a program has one session cookie
    /// (ADR 033); a second call is `error.GuardAlreadyDeclared`.
    pub fn guard(self: *App, middleware: mw.Middleware, cookie: []const u8) error{GuardAlreadyDeclared}!void {
        std.debug.assert(cookie.len > 0);
        if (self.declared_guard != null) return error.GuardAlreadyDeclared;
        self.declared_guard = .{ .middleware = middleware, .cookie = cookie };
    }

    /// The App, with the next route registered through what this hands back
    /// carrying `name` as its `operationId`
    /// ([ADR 119](../docs/adr/119-a-route-can-say-its-own-name.md)).
    ///
    /// ```zig
    /// try app.named("addPartnerCapability")
    ///     .put("/api/partners/:id/capabilities/:cap", addCapability);
    /// ```
    ///
    /// **This says what the route is called and nothing about what it does** —
    /// the document is still described from the signature (ADR 016). A name
    /// derived from the path cannot be a *key*, because it changes when the
    /// path moves.
    ///
    /// It composes like the rest of the vocabulary, so a group's prefix and a
    /// route's own middleware still apply:
    ///
    /// ```zig
    /// const api = app.group("/api");
    /// try api.named("listPartners").get("/partners", listPartners);
    /// ```
    ///
    /// Two routes with the same name stop the process at registration, for the
    /// reason a duplicate route does: the document would carry the same key
    /// twice and whichever consumer read it would see one of them.
    pub fn named(self: *App, comptime name: []const u8) GroupWith("", &.{}, &.{}, &.{}, name, router.every_listener) {
        return .{ .app = self };
    }

    /// Serve the contents of `dir_path` under `url_prefix`.
    ///
    /// The directory is read into memory here and now, before anything is
    /// being served — nothing touches the disk on the request path (ADR
    /// 009). `dir_path` is relative to the working directory the server
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
    /// process, for the reason `listen()` and `route()` do (ADR 001).
    /// `tryStatic` is the same call with the error as a value.
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
        self.loadStatic(url_prefix, dir_path, opts, .reported) catch |err| {
            if (static_mod.explained(err)) std.process.exit(1);
            return err;
        };
    }

    /// `static`, for a caller that would rather handle a missing directory
    /// than have the process stopped under it: a test, or a program with a
    /// fallback, a backend that serves without its frontend built. **A
    /// directory that is not there comes back as `error.StaticDirNotFound`
    /// and nothing is logged**, because the caller has the path and the
    /// decision, and a program that handles a case should not read `error:`
    /// in its own log for it
    /// ([ADR 207](../docs/adr/207-a-try-call-hands-back-the-error-and-says-nothing.md)).
    /// A problem inside a directory that *is* there (a file that could not
    /// be read, a path too long) is still said in one line, since the
    /// error cannot name the file and the line can.
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
        return self.loadStatic(url_prefix, dir_path, opts, .returned);
    }

    /// What the four `static` calls share: the load, and the set kept.
    fn loadStatic(
        self: *App,
        url_prefix: []const u8,
        dir_path: []const u8,
        opts: static_mod.Options,
        absent: static_mod.Absent,
    ) !void {
        const set = try static_mod.load(self.gpa, url_prefix, dir_path, opts, absent);
        errdefer {
            var mutable = set;
            mutable.deinit();
        }
        try self.static_sets.append(self.gpa, set);
    }

    /// Serve files the binary carries, the way `static` serves a directory
    /// (ADR 009).
    ///
    /// ```zig
    /// try app.embedded("/", &.{
    ///     .{ .path = "index.html", .bytes = @embedFile("dist/index.html") },
    ///     .{ .path = "assets/app.js", .bytes = @embedFile("dist/assets/app.js") },
    /// });
    /// ```
    ///
    /// A front end's build output is listed into the list by `embedDir` in
    /// nilo's `build.zig`, called from the dependent's own (ADR 009).
    ///
    /// Everything `static` does past the read — an ETag per file, a gzipped
    /// copy made once, the SPA fallback, nothing per request — happens here
    /// too, on the same code. What is different is that there is no
    /// directory to get wrong at deploy time: the files are in the
    /// executable, and the list is the whole of what the caller writes.
    ///
    /// The failures are the caller's, not the environment's — a URL listed
    /// twice, a fallback that names no entry — so they say why in one line
    /// and stop the process, and there is no `try` variant to catch them
    /// with: the list that failed was fixed when the program was compiled.
    pub fn embedded(self: *App, url_prefix: []const u8, files: []const static_mod.Embedded) !void {
        try self.embeddedWith(url_prefix, files, .{});
    }

    /// `embedded`, with the caching, index and single-page-app options
    /// spelled out. See `static.EmbedOptions`.
    pub fn embeddedWith(
        self: *App,
        url_prefix: []const u8,
        files: []const static_mod.Embedded,
        opts: static_mod.EmbedOptions,
    ) !void {
        const set = static_mod.embed(self.gpa, url_prefix, files, opts) catch |err| {
            if (static_mod.explained(err)) std.process.exit(1);
            return err;
        };
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

    /// Run `func` in a fiber of its own, once the server is up.
    ///
    /// The same fiber `nilo.spawn` starts, started for you at the one moment
    /// it can be: `nilo.spawn` is "now" and needs a running server, this is
    /// "when there is one" and is registered beside the routes (ADR 028).
    ///
    /// ```zig
    /// try app.provide(&exporter);
    /// try app.spawn(flushEvery, .{&exporter});
    /// try app.listen(.{ .port = 8080 });
    /// ```
    ///
    /// It is owned by the server exactly as a connection is: counted while
    /// it runs, and cut off when the shutdown grace period ends. So the
    /// shape of one of these is a loop around a wait that says when to stop:
    ///
    /// ```zig
    /// fn flushEvery(exporter: *Exporter) void {
    ///     while (true) {
    ///         nilo.sleep(60_000) catch return;   // Canceled — the server is going
    ///         exporter.flush() catch |err| std.log.err("flush: {t}", .{err});
    ///     }
    /// }
    /// ```
    ///
    /// Registered here rather than in a Service's `nilo_start`, which runs in
    /// a phase that may have no server to own the fiber (ADR 028).
    ///
    /// `func` may not fail: there is no request to answer and nobody to
    /// answer it, so an error has nowhere to go. Log instead. The two things
    /// that must not travel in are the two `nilo.spawn` names — a `Str`,
    /// which points into a request arena, and a fail function, which has no
    /// request to fail.
    pub fn spawn(self: *App, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
        const Args = @TypeOf(args);
        const held = try self.gpa.create(Args);
        errdefer self.gpa.destroy(held);
        held.* = args;

        try self.background.append(self.gpa, .{
            .args = @as(*anyopaque, @ptrCast(held)),
            .start = &struct {
                fn f(erased: *anyopaque, _: std.mem.Allocator, _: std.Io) anyerror!void {
                    const a: *Args = @ptrCast(@alignCast(erased));
                    return bulkhead.spawn(func, a.*);
                }
            }.f,
            .free = &struct {
                fn f(gpa: std.mem.Allocator, erased: *anyopaque) void {
                    const a: *Args = @ptrCast(@alignCast(erased));
                    gpa.destroy(a);
                }
            }.f,
        });
    }

    /// Run `func` once, on the server's loop, after the services have
    /// started and before the first connection is accepted. The place for
    /// work that needs a pool and has to be done before anybody is served:
    /// a migration, a version guard, a key set fetched once
    /// ([ADR 180](../docs/adr/180-work-that-needs-the-services-runs-on-their-loop.md)).
    ///
    /// ```zig
    /// fn migrate(run: *nilo.Run, db: *sql.Db) !void {
    ///     try sql.migrate.applyPending(db, run, try manifest.chain(run.arena()));
    /// }
    ///
    /// try app.provide(&db);
    /// try app.before(migrate, .{&db});
    /// try app.listen(.{ .port = 8080 });
    /// ```
    ///
    /// `func` takes a `*nilo.Run` first — the boot's own Scope, made here on
    /// the server's `Io` and thrown away when `func` returns — and then
    /// whatever `args` holds, the way a job's `run` takes its Run and then
    /// its services. **If it fails, the server does not start**: the error
    /// comes back out of `listen()` after one line saying so, and the
    /// services are put down on the way. A migration that could not run is
    /// a database this binary must not serve. A fail function called inside
    /// it keeps its sentence, which that line carries (ADR 129).
    ///
    /// This is the phase ADR 180 put *before* `listen()`, as
    /// `app.start(io)` on an `Io` of the caller's, moved inside it. What
    /// changes is which loop the work runs on, and that is the whole
    /// difference: a pool is dialled through the `Io` it is given and a
    /// worker parks on it, so a service started on the caller's `Io` and
    /// then driven from the server's fibers is the wrong pool on the right
    /// loop, and the `Io` may already be gone. Here the services were
    /// started by `listen()` a moment ago, on the loop the requests will
    /// run on.
    pub fn before(self: *App, comptime func: anytype, args: BeforeArgs(func)) !void {
        const Args = @TypeOf(args);
        const held = try self.gpa.create(Args);
        errdefer self.gpa.destroy(held);
        held.* = args;

        try self.before_serving.append(self.gpa, .{
            .args = @as(*anyopaque, @ptrCast(held)),
            .start = &struct {
                fn f(erased: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror!void {
                    const a: *Args = @ptrCast(@alignCast(erased));
                    var run: str_mod.Run = .initIo(gpa, io);
                    defer run.deinit();
                    const answer = @call(.auto, func, .{&run} ++ a.*);
                    if (@typeInfo(@TypeOf(answer)) == .error_union) return answer;
                }
            }.f,
            .free = &struct {
                fn f(gpa: std.mem.Allocator, erased: *anyopaque) void {
                    const a: *Args = @ptrCast(@alignCast(erased));
                    gpa.destroy(a);
                }
            }.f,
        });
    }

    /// The arguments `before` takes for `func`: everything after the
    /// `*nilo.Run` in front, as a tuple — so `fn (run: *nilo.Run, db: *Db)`
    /// is registered with `.{&db}`.
    ///
    /// The Run is nilo's to make, and a function written without one in
    /// front is refused here rather than at the call that hands it a Run it
    /// has no parameter for.
    fn BeforeArgs(comptime func: anytype) type {
        const F = @TypeOf(func);
        const info = switch (@typeInfo(F)) {
            .@"fn" => |f| f,
            else => @compileError(
                "nilo: app.before() takes a function, not " ++ @typeName(F) ++ ".\n" ++
                    "  Its shape is `fn (run: *nilo.Run, …) !void`: the boot's Run first, " ++
                    "then whatever the work needs, handed over as `.{ … }`.",
            ),
        };
        const shape = "\n  Its shape is `fn (run: *nilo.Run, …) !void`. The Run is the boot's " ++
            "own Scope, made by `listen()` on the server's loop and thrown away when " ++
            "the work returns; what the work needs after it — a `*Db`, a `*Client` — " ++
            "is handed over as `.{ &db }`.";
        if (info.params.len == 0 or info.params[0].type != *str_mod.Run) @compileError(
            "nilo: app.before() was given a function whose first parameter is " ++
                (if (info.params.len == 0) "nothing" else @typeName(info.params[0].type.?)) ++
                ", and it has to be `*nilo.Run`." ++ shape,
        );
        const R = info.return_type.?;
        const payload = switch (@typeInfo(R)) {
            .error_union => |e| e.payload,
            else => R,
        };
        // The payload rather than `R`: an inferred error union has no
        // readable name, and the value is what the reader has to take out.
        if (payload != void) @compileError(
            "nilo: app.before() was given a function that answers with " ++ @typeName(payload) ++
                ", and there is nobody to hand the value to." ++ shape,
        );
        var types: [info.params.len - 1]type = undefined;
        for (info.params[1..], 0..) |p, i| types[i] = p.type.?;
        const frozen = types;
        return std.meta.Tuple(&frozen);
    }

    pub fn get(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        comptime typed.check(pattern, handler);
        try self.route(.GET, pattern, handler);
    }

    pub fn post(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        comptime typed.check(pattern, handler);
        comptime typed.checkVerb(.POST, pattern, handler);
        try self.route(.POST, pattern, handler);
    }

    /// Serve a struct of typed functions as an RPC service: each `pub fn`
    /// a method at `POST /<nilo_service>/<Method>`, the name's first letter
    /// upper-cased, reachable by gRPC, Connect and plain JSON alike
    /// (ADR 258). The same routes `post` would have registered one by one.
    pub fn rpc(self: *App, comptime T: type) !void {
        inline for (comptime rpc_mod.methodsOf(T)) |method| try self.post(method.path, @field(T, method.fn_name));
    }

    pub fn put(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        comptime typed.check(pattern, handler);
        comptime typed.checkVerb(.PUT, pattern, handler);
        try self.route(.PUT, pattern, handler);
    }

    pub fn delete(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        comptime typed.check(pattern, handler);
        comptime typed.checkVerb(.DELETE, pattern, handler);
        try self.route(.DELETE, pattern, handler);
    }

    pub fn patch(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        comptime typed.check(pattern, handler);
        comptime typed.checkVerb(.PATCH, pattern, handler);
        try self.route(.PATCH, pattern, handler);
    }

    pub fn head(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        comptime typed.check(pattern, handler);
        try self.route(.HEAD, pattern, handler);
    }

    pub fn options(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        comptime typed.check(pattern, handler);
        comptime typed.checkVerb(.OPTIONS, pattern, handler);
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
    /// nilo's own files on top of the answer, and which file inside the
    /// framework noticed the collision is not the user's problem (ADR
    /// 001). `tryRoute` is the same call with the error as a value.
    pub fn route(
        self: *App,
        method: http1.Method,
        comptime pattern: []const u8,
        comptime handler: anytype,
    ) !void {
        return self.routeNamed(null, method, pattern, handler);
    }

    /// `route`, with the `operationId` the route was given by `app.named(…)`.
    /// Called by the group methods; `route` is this with no name (ADR 119).
    pub fn routeNamed(
        self: *App,
        comptime name: ?[]const u8,
        method: http1.Method,
        comptime pattern: []const u8,
        comptime handler: anytype,
    ) !void {
        comptime typed.check(pattern, handler);
        self.register(true, name, method, pattern, handler) catch |err| {
            if (err == error.DuplicateRoute or err == error.DuplicateName or err == error.CachedWrite) std.process.exit(1);
            return err;
        };
    }

    /// `route`, for a caller that would rather handle a collision than have
    /// the process stopped under it — a test, or a program building its
    /// routes from a list. The one-line explanation still goes to the log,
    /// at `warn`, because the error cannot name the route it collided with
    /// (ADR 207); what changes is that the error comes back as a value and
    /// nothing of the refused route is kept (ADR 008).
    pub fn tryRoute(
        self: *App,
        method: http1.Method,
        comptime pattern: []const u8,
        comptime handler: anytype,
    ) !void {
        return self.tryRouteNamed(null, method, pattern, handler);
    }

    /// `tryRoute`, with the `operationId` the route was given (ADR 119).
    pub fn tryRouteNamed(
        self: *App,
        comptime name: ?[]const u8,
        method: http1.Method,
        comptime pattern: []const u8,
        comptime handler: anytype,
    ) !void {
        return self.register(false, name, method, pattern, handler);
    }

    /// The one registration `routeNamed` and `tryRouteNamed` share.
    /// `stops` says whether a refusal ends the process, which decides how
    /// loud it is: `err` is a server refusing to start, and a `tryRoute`
    /// caller who asked for the error back is not one, so it hears a
    /// `warn`.
    ///
    /// **Every check runs before anything is kept.** A name already taken
    /// was found after the router held the route, so a `tryRoute` refused
    /// for it left the route live and out of the document; the name is
    /// checked with the path now, before the router, the requirements or
    /// the derived names are touched.
    fn register(
        self: *App,
        comptime stops: bool,
        comptime name: ?[]const u8,
        method: http1.Method,
        comptime pattern: []const u8,
        comptime handler: anytype,
    ) !void {
        comptime typed.check(pattern, handler);
        comptime if (name) |given| checkName(given);
        const say = if (stops) std.log.err else std.log.warn;

        // Registering the same path twice is not a small mistake: the
        // second handler never runs, and nothing about the running server
        // says so. Caught here, where both patterns can be named.
        if (self.router.conflicting(method, pattern)) |existing| {
            say(
                "the route \"{s} {s}\" answers the same requests as \"{s}\", which is already " ++
                    "registered — whichever came second would never run. Drop one, or give them " ++
                    "different paths. (Param names do not tell two routes apart: \"/users/:id\" " ++
                    "and \"/users/:name\" are the same route.)",
                .{ @tagName(method), pattern, existing },
            );
            return error.DuplicateRoute;
        }

        // `app.post` refuses this while compiling; here the verb is a
        // runtime value, so it is said at registration instead — and, like
        // a duplicate, stops the process unless the caller asked for the
        // error (ADR 188).
        if (comptime typed.isCached(pattern, handler)) {
            if (!cached_mod.allows(method)) {
                say(
                    "the route \"{s} {s}\" takes a `Cached(…)`, and a {s} is not an answer to keep: " ++
                        "a kept answer is served again to whoever asks next, and the request the second " ++
                        "client sent was not the one the first client sent. A `Cached(…)` goes on a GET " ++
                        "or a HEAD; for a write answered once per client, that is `Idempotent(…)`.",
                    .{ @tagName(method), pattern, @tagName(method) },
                );
                return error.CachedWrite;
            }
        }

        // A name given twice is the document carrying the same key twice,
        // and whichever consumer read it would see one of the two. Caught
        // here, where both routes can be named (ADR 119).
        if (name) |given| {
            if (wiring.nameTaken(self, given)) |existing| {
                say(
                    "the route \"{s} {s}\" is named `{s}`, and so is \"{s} {s}\". An " ++
                        "operationId is the key a generated client and an authorisation " ++
                        "table are written against, so two routes cannot share one.",
                    .{ @tagName(method), pattern, given, @tagName(existing.method), existing.pattern },
                );
                return error.DuplicateName;
            }
        }

        try self.requirements.appendSlice(self.gpa, comptime typed.requirements(pattern, handler));
        // The name the route answers to at run time is the one the document
        // prints — given, or derived by the same function the document
        // calls — so a middleware keyed by `operationId` and a contract
        // held against the document cannot disagree about a route
        // (ADR 162).
        const route_name: []const u8 = name orelse blk: {
            var out: std.Io.Writer.Allocating = .init(self.gpa);
            errdefer out.deinit();
            try openapi.writeDerivedName(&out.writer, method, pattern);
            const derived = try out.toOwnedSlice();
            errdefer self.gpa.free(derived);
            try self.derived_names.append(self.gpa, derived);
            break :blk derived;
        };
        try self.router.addNamed(method, pattern, comptime typed.wrap(pattern, handler), route_name);
        if (comptime typed.speaksAMessage(pattern, handler)) self.failure_connect = &connect.pick;

        // Read from the same argument list `wrap` just read, so the
        // description of an endpoint and the code that serves it cannot
        // drift apart (ADR 016). Comptime data, so what is appended here is
        // one struct of slices pointing at read-only memory.
        var op = comptime typed.operation(pattern, handler);
        op.method = method;
        op.name = name;
        try self.operations.append(self.gpa, op);
    }

    /// Serve a description of this API, worked out from the handler
    /// signatures (ADR 016).
    ///
    /// ```zig
    /// app.docs(.{ .title = "Orders", .version = "2.0.0" });
    /// ```
    ///
    /// The document lands at `/openapi.json` and a page for reading it at
    /// `/docs`. Both are built when `listen()` resolves the routes, so it
    /// does not matter whether this is called before or after them — the
    /// same order-independence `use` and `get` have (ADR 008).
    ///
    /// Routes win over both paths, so registering a `/docs` of your own
    /// still gets its way.
    pub fn docs(self: *App, opts: openapi.Options) void {
        self.docs_options = opts;
    }

    /// The body every failure goes out with, when nilo's
    /// `{"error":"…","status":404}` is not the one your clients already read
    /// ([ADR 024](../docs/adr/024-every-failure-answers-as-json.md)).
    ///
    /// ```zig
    /// const ApiError = struct {
    ///     code: u16,
    ///     detail: []const u8,
    ///     pub fn nilo_failure(status: u16, message: []const u8) ApiError {
    ///         return .{ .code = status, .detail = message };
    ///     }
    /// };
    /// try app.failures(ApiError);
    /// ```
    ///
    /// The struct's fields are the JSON; `nilo_failure` fills it from the
    /// status and the fail function's sentence; the API description's
    /// `Failure` schema is derived from the same fields. Every failure nilo
    /// assembles takes the shape — a fail function, a 404, a 405 with its
    /// `Allow`, a 401 with its challenge, a 500 — and the headers the request
    /// collected still go out with it. The five answers written before there
    /// is a request to route (a malformed head, a head too long or too slow,
    /// an unreadable coding, a shed 503) keep nilo's own; `failurebody.zig`
    /// says why. Called once; a second call is `error.FailureShapeAlreadySet`.
    pub fn failures(self: *App, comptime T: type) error{FailureShapeAlreadySet}!void {
        const write = comptime failurebody.writerOf(T);
        const schema = comptime openapi.schemaOf(T);
        if (self.failure_write != null) return error.FailureShapeAlreadySet;
        self.failure_write = write;
        self.failure_schema = schema;
    }

    /// Serve a page that says whether this process can do its job, by asking
    /// every service that declared `nilo_ready`
    /// ([ADR 154](../docs/adr/154-a-health-route-asks-the-services.md)).
    ///
    /// ```zig
    /// try app.health("/healthz");
    /// ```
    ///
    /// `200 {"status":"ok"}` when every service answers ready; `503` with
    /// the ones that did not and why; `503 {"status":"stopping"}` from the
    /// moment the server was told to stop, so a balancer drains this
    /// instance before the listener goes. A service with no hook is assumed
    /// ready. An ordinary route, like the metrics page: what protects it is
    /// where you mount it.
    pub fn health(self: *App, comptime path: []const u8) !void {
        try self.get(path, healthRoute);
        // The one thing ADR 120 cannot read off a `*Ctx` handler is what
        // it answers, and this handler is nilo's own: a JSON page with a
        // `status` in it, 200 when everything is ready. Said here so the
        // document describes the route and the count of routes it cannot
        // describe is the application's alone (ADR 120). The 503s are
        // failures, which the document does not promise for any route.
        self.describeLast(.{
            .status = 200,
            .content_type = health_mod.content_type,
            .schema = comptime openapi.schemaOf(health_mod.Page),
        });
    }

    /// Give the route registered last an answer nilo already knows, for
    /// the two handlers nilo wrote itself (ADR 120). A `*Ctx` handler that
    /// returns nothing is otherwise `written`: undescribed, and counted in
    /// the line `listen()` prints about them.
    fn describeLast(self: *App, answer: openapi.Answer) void {
        self.operations.items[self.operations.items.len - 1].answer = answer;
    }

    /// Count every request, and serve the numbers at `/metrics` in the format
    /// Prometheus scrapes (ADR 079).
    ///
    /// ```zig
    /// try app.metrics(.{});
    /// try app.metrics(.{ .path = "/internal/metrics" });
    /// ```
    ///
    /// What gets counted is the three things a log line cannot answer: how
    /// many requests each route answered, at what status class, and how long
    /// they took. **Per route, not per path** — `/users/1` and `/users/2` are
    /// both `/users/:id`, because the counter is the route's index in the
    /// table rather than a string somebody hashed, and a crawler cannot make
    /// a series.
    ///
    /// The page is an **ordinary route** with no authentication of its own:
    /// what protects it is where you mount it and what you `use` there. Called
    /// before or after the routes, either way (ADR 008).
    pub fn metrics(self: *App, comptime opts: metrics_mod.Options) !void {
        comptime metrics_mod.check(opts);
        if (self.metrics_table != null) return error.MetricsAlreadyEnabled;

        self.metrics_table = .{ .boundaries = opts.buckets };
        // The readout reaches the table the way every handler reaches
        // anything long-lived: as a service, asked for by type. That is what
        // keeps this whole feature out of `Ctx` — a request that is not the
        // scrape never touches it.
        try self.services.add(&self.metrics_table.?);
        try self.get(opts.path, metrics_mod.readout);
        // nilo wrote the readout, so it can say what the readout answers:
        // the text format Prometheus scrapes, as a 200 (ADR 120).
        self.describeLast(.{
            .status = 200,
            .content_type = metrics_mod.content_type,
            .schema = comptime openapi.schemaOf([]const u8),
        });
    }

    /// Gzip every answer worth gzipping, per request, for a client that
    /// asked for it (ADR 211).
    ///
    /// ```zig
    /// try app.compress(.{});
    /// try app.compress(.{ .level = .best, .min_bytes = 512 });
    /// ```
    ///
    /// From then on a body that is text (JSON, HTML, anything under
    /// `text/`) and at least `min_bytes` long goes out gzipped to a client
    /// whose `Accept-Encoding` says gzip is welcome, with `Content-Encoding:
    /// gzip`, `Vary: Accept-Encoding` and the compressed length. A client
    /// that did not ask gets the body as it is. Static files are not
    /// touched: they were gzipped once when the App was built. Streams and
    /// event streams are never compressed.
    ///
    /// **What it costs is stated rather than hidden.** One compressor per
    /// thread, `~288 KB` each, allocated when the chains are resolved and
    /// held for the life of the App; one more arena allocation on every
    /// request that is compressed, for the compressed body; and the CPU of
    /// gzip itself, which for a five-kilobyte JSON answer at `.default` is
    /// in the tens of microseconds. Nothing on a request that is not
    /// compressed, and nothing per connection.
    ///
    /// Once per App; a second call is `error.CompressionAlreadyEnabled`.
    pub fn compress(self: *App, opts: compress_mod.Options) error{CompressionAlreadyEnabled}!void {
        if (self.compress_options != null) return error.CompressionAlreadyEnabled;
        self.compress_options = opts;
    }

    /// Trace every request, and send the spans to an OpenTelemetry receiver
    /// ([ADR 247](../docs/adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)).
    ///
    /// ```zig
    /// try app.trace(.{ .service = "orders" });   // OTLP/HTTP to localhost:4318
    /// ```
    ///
    /// From then on every request is a server span named for its route, a
    /// request that arrives with a `traceparent` joins that trace, a call
    /// through `nilo_fetch` is a client span whose `traceparent` names it, and
    /// `c.span(name)` opens a span of the handler's own. The spans are sent in
    /// batches by a fiber of the server's every `flush_ms`, and what is left
    /// when it stops is sent on the way out.
    ///
    /// **What it costs is stated rather than hidden.** On the request path:
    /// two clock reads, two ids from a generator per thread, one walk of the
    /// headers, and a copy of the finished span into this thread's ring. No
    /// allocation and no lock. Held for the life of the App: a ring of
    /// `spans_per_thread` records per thread, allocated when the chains are
    /// resolved, and a batch of `max_batch`. Nothing per connection.
    ///
    /// The text in `opts` is borrowed and has to outlive the App. Options
    /// that could send nothing (an empty service, an endpoint that is not
    /// `http://` or `https://`, a sample outside 0 to 1) are refused here.
    /// Once per App; a second call is `error.TracingAlreadyEnabled`.
    pub fn trace(self: *App, opts: trace_mod.Options) !void {
        const otlp = @import("otlp.zig");
        if (self.tracer != null) return error.TracingAlreadyEnabled;

        // Built inside a block so its errdefers end where the App takes
        // ownership: after `services.add`, `deinit` frees both, and an
        // errdefer still standing would free them a second time.
        const exporter = made: {
            const tracer = try self.gpa.create(trace_mod.Tracer);
            errdefer self.gpa.destroy(tracer);
            tracer.* = try trace_mod.Tracer.init(self.gpa, opts);
            errdefer tracer.deinit();

            const exporter = try self.gpa.create(otlp.Exporter);
            errdefer self.gpa.destroy(exporter);
            exporter.* = try otlp.Exporter.init(self.gpa, tracer);
            errdefer exporter.deinit();

            // A service, so its client starts on the server's loop and its
            // stop hook sends the last of the spans.
            try self.services.add(exporter);
            self.tracer = tracer;
            self.trace_hooks = &tracing_hooks;
            break :made exporter;
        };
        self.exporter = exporter;
        // And a fiber, which is the loop that sends.
        try self.spawn(otlp.Exporter.exportEvery, .{exporter});
    }

    /// Publish a number of the application's own on the metrics page.
    ///
    /// ```zig
    /// var orders_placed: std.atomic.Value(u64) = .init(0);
    /// try app.expose("orders_placed", .counter, &orders_placed);
    /// ```
    ///
    /// **This is what stands in for a registry, and the difference is where
    /// the naming is paid.** A registry would take a name per increment,
    /// which means a hash and a lock on the path of a request. Here you own
    /// the counter and increment it yourself — `_ = orders_placed.fetchAdd(1,
    /// .monotonic)` — and nilo only reads it, once per scrape. Nothing about
    /// this touches a request that is not the scrape (ADR 079).
    ///
    /// The number has to be a `std.atomic.Value(u64)`, because handlers run
    /// on several threads at once and a plain `u64` counted from all of them
    /// loses increments silently. A refusal says so while compiling.
    pub fn expose(
        self: *App,
        comptime name: []const u8,
        comptime kind: metrics_mod.Kind,
        number: anytype,
    ) !void {
        comptime metrics_mod.checkExposed(name, @TypeOf(number));
        for (self.exposed.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return error.MetricAlreadyExposed;
        }
        try self.exposed.append(self.gpa, .{ .name = name, .kind = kind, .value = number });
        // The table holds a slice of this list, and appending to a list moves
        // it. Re-pointed here rather than only at `resolveChains`, because a
        // caller that has already resolved — `start()` before `listen()`, or a
        // test — would otherwise leave the table reading freed memory.
        if (self.metrics_table) |*t| t.exposed = self.exposed.items;
    }

    /// Every route this App answers, in the order they were registered
    /// ([ADR 100](../docs/adr/100-a-route-pattern-is-the-name-of-its-url.md)).
    ///
    /// The question it exists for is "did my routes register":
    ///
    /// ```zig
    /// std.log.info("serving {d} routes:\n{f}", .{ app.routes().len(), app.routes() });
    /// ```
    ///
    /// A view over the table rather than a copy of it, so this allocates
    /// nothing and costs a request nothing: the table is what the router
    /// already scans and what metrics already index into (ADR 079). It stays
    /// valid until another route is registered.
    pub fn routes(self: *const App) Routes {
        return .{ ._inner = self.router.routes.items };
    }

    // Reached through `App` because they always have been. These are the
    // public half of `wiring.zig` and `serve.zig`; moving a file is not a
    // reason to move somebody's call site. Everything else in those two is
    // called as `wiring.name(app, …)`, which says which half of the App's
    // life the call belongs to.
    pub const checkServices = wiring.checkServices;
    pub const resolveChains = wiring.resolveChains;
    pub const missingService = wiring.missingService;
    pub const writeOpenApi = wiring.writeOpenApi;
    pub const serveRequest = serve.serveRequest;
    pub const Served = serve.Served;

    /// Listen and serve until the server is stopped — by Ctrl-C, by a
    /// SIGTERM from whatever is supervising the process, or by `shutdown()`.
    /// Returns once the requests still in flight have finished.
    ///
    /// A server that cannot start says why in one line and stops the
    /// process there. That is the whole point of those messages: letting
    /// the error travel back to `main` instead would print a stack trace
    /// through nilo's own files on top of the answer (ADR 001). Use
    /// `tryListen` to get the error as a value and no message.
    pub fn listen(self: *App, options_: bulkhead.Options) !void {
        self.tryListen(options_) catch |err| {
            // Every one of these has already said, in one line, what is
            // wrong and what to change. `TrustedProxyNotAnAddress`,
            // the four `SessionSecret…` errors and `StartedOnAnotherLoop`
            // are `tryListen`'s own; the rest are the Engine's.
            if (bulkhead.explained(err) or
                err == error.MissingService or
                err == error.TrustedProxyNotAnAddress or
                err == error.SessionSecretWrongLength or
                err == error.SessionSecretMissing or
                err == error.SessionSecretRepeated or
                err == error.SessionSecretsTooMany or
                err == error.StartedOnAnotherLoop) std.process.exit(1);
            return err;
        };
    }

    /// `listen`, for a caller that would rather handle a startup failure
    /// than have the process stopped under it — a test, or a program that
    /// falls back to another port. The one-line explanations still go to
    /// the log; what changes is that the error comes back as a value.
    pub fn tryListen(self: *App, options_: bulkhead.Options) !void {
        wiring.checkRootWiring();
        try self.checkServices();
        // Before the chains are resolved, because that is when the
        // compressors are sized, and they are sized to the threads the
        // Engine is about to start (ADR 211).
        self.compress_slots = bulkhead.threadCount(options_);
        try self.resolveChains();
        wiring.countUndescribed(self);
        // Parsed here rather than per request, and before the port is taken:
        // a rule that is not an address is a deployment mistake, and the
        // moment somebody is watching for one is startup (ADR 102).
        wiring.parseTrustedProxies(self, options_.trusted_proxies) catch |err| {
            // Said here rather than inside the parse, so the parse can be
            // tested: a logged error during a test is a failed test whatever
            // level it prints at (see `test_root.zig`), and in this project an
            // error line means the server will not start — which is what
            // happens on the next line.
            if (proxies_mod.firstBad(options_.trusted_proxies)) |rule| std.log.err(
                "trusted proxy \"{s}\" is not an address, a CIDR, \"private\" or " ++
                    "\"loopback\" — nothing would ever match it, so every request would " ++
                    "be answered with the address the connection came from",
                .{rule},
            );
            return err;
        };

        // The knobs a request reads rather than the socket. Kept on the
        // App because that is what a request can reach; a test driving
        // `handleRequest` with no server gets the defaults below.
        self.limits = .{
            .max_body = options_.max_body,
            .max_in_flight = options_.max_in_flight,
            .trusted_hops = options_.trusted_hops,
            .trusted_proxies = self.trusted_proxies,
            .block_warning_ms = options_.block_warning_ms,
            .request_deadline_ms = options_.request_deadline_ms,
        };
        // Read once per request by the connection loop rather than by a
        // request, which is why it is a field of its own (ADR 075).
        self.arena_keep = options_.arena_keep;
        // Not on the App, because there is one memory controller per process
        // rather than one per App: two Apps hashing eight each would be
        // sixteen, which is the number the measurement in ADR 044 says not
        // to run.
        password_mod.setLimit(options_.password_hashes_at_once);
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
        try self.keepFallbacks(options_.session_fallback_secrets);
        self.session_plain_name = options_.session_plain_name;
        try bulkhead.serve(
            self.gpa,
            options_,
            &self.stop,
            self,
            serverStarting,
            serverStopping,
            serve.handleConnection,
            serveGrpc,
        );
    }

    /// Check the fallback session secrets and copy them onto the App, or say in
    /// one line what is wrong with them (ADR 225). Its own function so that
    /// `tryListen` reads as the list of what it checks.
    fn keepFallbacks(self: *App, fallbacks: []const []const u8) !void {
        self.session_fallbacks = session_mod.checkFallbacks(self.session_key, fallbacks, &self.fallback_store) catch |err| {
            switch (err) {
                error.SessionSecretMissing => std.log.err(
                    "{d} fallback session secrets were given and no session_secret, so they would " ++
                        "open cookies nothing can seal any more. A rotation keeps the new secret " ++
                        "in session_secret and the old one in session_fallback_secrets.",
                    .{fallbacks.len},
                ),
                error.SessionSecretsTooMany => std.log.err(
                    "{d} fallback session secrets were given and at most {d} are kept: each is one " ++
                        "more decryption for every cookie the current secret does not open. A " ++
                        "secret needs to stay a fallback for one max_age; drop the oldest.",
                    .{ fallbacks.len, session_mod.max_fallbacks },
                ),
                error.SessionSecretWrongLength => for (fallbacks) |secret| {
                    if (secret.len == session_mod.key_len) continue;
                    std.log.err(
                        "a fallback session secret is {d} bytes and it has to be exactly {d}, " ++
                            "the length it had when it was the session secret.",
                        .{ secret.len, session_mod.key_len },
                    );
                    break;
                },
                error.SessionSecretRepeated => std.log.err(
                    "a fallback session secret is the same as session_secret or as another " ++
                        "fallback, so the rotation it stands for did not happen. The new " ++
                        "secret goes in session_secret and only the old ones in " ++
                        "session_fallback_secrets.",
                    .{},
                ),
            }
            return err;
        };
    }

    /// Everything `listen()` does **before it accepts anything**, for a
    /// program that is not going to listen at all.
    ///
    /// The services are checked, the middleware chains are resolved, every
    /// service that declared `nilo_start` is started on `io`, the work
    /// `before` registered runs, and every `nilo_check` runs after it, so a
    /// `Db` has its pool, its tables if `createMissing` was registered, and
    /// has had its schema checked against them, and a query works. A test
    /// driving the App through `testing.Client`, a script, a worker process
    /// that runs `jobs.serveOn(io)` and never takes a socket: those are what
    /// this is for, and `std.Io.Threaded` is the `Io` they hold.
    ///
    /// ```zig
    /// var threaded: std.Io.Threaded = .init(gpa, .{});
    /// defer threaded.deinit();
    ///
    /// try app.start(threaded.io());          // the pool is open from here
    /// try client.get("/users/1");            // and a test can use it
    /// ```
    ///
    /// **Not before `listen()`.** ADR 180 had it there, as the phase a
    /// migration runs in, and that shape is refused now
    /// ([ADR 180](../docs/adr/180-work-that-needs-the-services-runs-on-their-loop.md)):
    /// a service keeps the `Io` it was started on, `listen()` runs on a loop
    /// of its own, and a pool dialled through one cannot be driven from the
    /// other — a job worker started that way crashes on an `Io` that has
    /// been freed, or parks where nothing can cancel it. The phase is
    /// `before`, which runs the same work inside `listen()` on the server's
    /// loop, and `db.expecting(version)` for the version guard alone.
    ///
    /// **What this does not start is what `spawn` registered.** There is no
    /// server here — the `Io` is the caller's own, and a fiber owned by a
    /// server that does not exist has nothing to count it and nothing to cut
    /// it off (ADR 028).
    pub fn start(self: *App, io: std.Io) !void {
        try self.checkServices();
        try self.resolveChains();
        try self.startServices(io, .{}, .start);
        // The same two phases `listen()` runs after the pool is open, on
        // the same `Io`: the work `before` registered, then what each
        // service checks once that work is done (ADR 180). A test that
        // registered `createMissing` with `before` gets its tables here, and
        // a `Db` checks its Rows against them rather than against an empty
        // file.
        try self.runBefore(io);
        try self.checkServiceHooks(io);
    }

    /// Finish building the services that could not be finished before the
    /// event loop existed.
    ///
    /// Called by the Engine from inside `listen()`, after the port is taken
    /// and before anything is accepted (ADR 037), and by `start` above for a
    /// caller with an `Io` of their own. Nothing is kept: a service that needs
    /// the loop after startup took a copy of it here, and the App has no use
    /// for one.
    ///
    /// **Once.** Opening a pool twice leaks the first one, and `start` called
    /// twice by a test reaches here twice.
    fn startServices(self: *App, io: std.Io, limits: bulkhead.Limits, by: StartedBy) anyerror!void {
        if (self.services_started != .nobody) return;
        self.services_started = by;
        try self.services.start(io, limits);
    }

    /// Whether `listen()` would find the services on a loop that is not its
    /// own: `start(io)` ran, and at least one service took that `Io`. The
    /// refusal in `serverStarting` is this and one log line, and it is a
    /// function of its own so a test can ask without provoking the line.
    fn startedElsewhere(self: *const App) bool {
        return self.services_started == .start and self.services.startedCount() > 0;
    }

    /// Everything that has to happen once, inside `listen()`, after the port
    /// is taken and before anything is accepted. The hook the Engine is
    /// handed (ADR 037), which is four steps rather than one (ADR 028,
    /// ADR 180).
    ///
    /// The order is the only one available: the work registered by `before`
    /// needs the services, a service's `nilo_check` looks at what that work
    /// made, and the work registered by `spawn` may use any of it. The four
    /// guards are separate because each is skipped under its own condition,
    /// and a program that ran `start()` for a test and then listened must
    /// still get its background work started.
    ///
    /// **A service started by `start(io)` before this is refused here**, and
    /// this is the one place that can see it: `services_started` is set and
    /// the loop in hand is the server's, so whatever `Io` the services hold
    /// is not this one. The alternative — stopping them and starting them
    /// again on this loop — would work for a pool and was not taken, because
    /// a refusal names the mistake and a restart hides it, and because the
    /// shape it would rescue is the one `before` exists to replace.
    fn serverStarting(
        self: *App,
        io: std.Io,
        limits: bulkhead.Limits,
        port: ?u16,
    ) anyerror!void {
        if (self.startedElsewhere()) {
            std.log.err(
                "nilo will not start: `app.start(io)` ran before `listen()`, and {d} service(s) " ++
                    "took that `Io` as their loop: {f}. `listen()` runs on a loop of its own, " ++
                    "and a service dialled through one `Io` cannot be driven from another — " ++
                    "a pool blocks the wrong thread, a worker parks where nothing can cancel " ++
                    "it, and the `Io` may be gone by the time it is used. Work that needs the " ++
                    "services before the first request goes in `app.before(f, args)`, which " ++
                    "runs inside `listen()` on the server's loop; a version guard alone is " ++
                    "`db.expecting(version)`. `app.start(io)` is for a program that never " ++
                    "listens: a test, a script, a worker on `serveOn`.",
                .{ self.services.startedCount(), self.services.startedNames() },
            );
            return error.StartedOnAnotherLoop;
        }
        // **After the refusal and not before it.** The port is what
        // `boundPort` answers, and a boot that is about to fail has no
        // port anybody should write down.
        self.bound_port.store(port orelse 0, .release);
        try self.startServices(io, limits, .listen);
        try self.runBefore(io);
        try self.checkServiceHooks(io);
        try self.startBackground(io);
    }

    /// Run what every service declared as `nilo_check`, once, after the
    /// work `before` registered and before anything is accepted
    /// ([ADR 180](../docs/adr/180-work-that-needs-the-services-runs-on-their-loop.md)).
    ///
    /// **This is the phase the schema check moved into.** A `Db` compares
    /// its Rows against their tables, and the tables are what
    /// `createMissing` or a migration in `before` just made; run from
    /// `nilo_start` the check saw the file before that work and refused a
    /// first boot over tables the next step would have created. A failure
    /// here is a boot that does not finish, after one line saying so.
    fn checkServiceHooks(self: *App, io: std.Io) !void {
        if (self.checks_ran) return;
        self.checks_ran = true;
        self.services.check(io) catch |err| {
            std.log.err(
                "nilo will not start: a service's check after the boot work failed with {t}, " ++
                    "and a server whose services disagree with what they hold must not take a request.",
                .{err},
            );
            return err;
        };
    }

    /// Run what `before` registered, once, in the order it was registered.
    ///
    /// The first failure stops the rest and the boot with it, after a line
    /// saying so: the work's own error is what comes back out of `listen()`,
    /// and a migration that could not run is a database this binary must not
    /// serve.
    ///
    /// **The line carries what a fail function said.** Boot work calls the
    /// same service functions a handler does, and a `fail.unprocessable(…)`
    /// in one of them used to reach this line as `Failed` and nothing else,
    /// because outside a request there was no box to write the sentence
    /// into (ADR 129). The boot now has one, on this frame, for as long as
    /// the work runs. Once, at boot: no request and no connection pays for
    /// it.
    fn runBefore(self: *App, io: std.Io) !void {
        if (self.before_ran) return;
        self.before_ran = true;
        var in_flight: fail.InFlight = .{};
        const n = self.before_serving.items.len;
        for (self.before_serving.items, 1..) |b, i| runOneBefore(b, self.gpa, io, &in_flight) catch |err| {
            const f = &in_flight.failure;
            if (fail.failed(f, err)) std.log.err(
                "nilo will not start: work {d} of {d} registered with `app.before` failed with " ++
                    "{t}, {d} \"{s}\", and a server whose boot work did not finish must not take a request.",
                .{ i, n, err, f.status, f.message() },
            ) else std.log.err(
                "nilo will not start: work {d} of {d} registered with `app.before` failed with " ++
                    "{t}, and a server whose boot work did not finish must not take a request.",
                .{ i, n, err },
            );
            return err;
        };
    }

    /// One piece of boot work, with `in_flight` where a fail function looks.
    ///
    /// **Bound the way a connection binds it, or handed over the way
    /// `nilo.blocking` hands it, and which one is decided by the loop the
    /// boot runs on.** On the Engine's loop, which is `listen()`'s, it is
    /// bound to the task running the boot, and no spawned fiber inherits a
    /// binding. The fallback slot is a threadlocal, and set on an executor
    /// thread it is read by every spawned fiber that runs there: ADR 006's
    /// leak. Any other `Io` is a caller's own, `app.start(io)` on
    /// `std.Io.Threaded` in a test or a script, with no task to bind to and
    /// no spawned fiber reading the threadlocal, so it is the fallback there,
    /// put back afterwards.
    fn runOneBefore(b: Background, gpa: std.mem.Allocator, io: std.Io, in_flight: *fail.InFlight) anyerror!void {
        in_flight.failure.clear();
        if (bulkhead.bindsOn(io)) {
            var binding = bulkhead.binding_unset;
            bulkhead.bindSlot(&binding, in_flight);
            defer bulkhead.unbindSlot(&binding);
            return b.start(b.args, gpa, io);
        }
        const previous = bulkhead.setFallbackSlot(in_flight);
        defer _ = bulkhead.setFallbackSlot(previous);
        return b.start(b.args, gpa, io);
    }

    /// The port the server is listening on, once it is: null before
    /// `listen()` has bound its socket, and null for a unix socket, which has
    /// none. Ask for `.port = 0` and this is the kernel's answer — the way a
    /// test gets a free port without walking a range of them and hoping, and
    /// the way a supervisor that was handed 0 learns what to write down.
    ///
    /// Atomic because `listen()` does not return, so whoever asks is on
    /// another thread.
    pub fn boundPort(self: *const App) ?u16 {
        const port = self.bound_port.load(.acquire);
        return if (port == 0) null else port;
    }

    /// The mirror of `serverStarting`, run on the way out of `listen()`
    /// (ADR 121).
    ///
    /// A Service that was handed the Engine's loop in `nilo_start` may have
    /// left work on it — pg.zig's pool refills itself from a task there —
    /// and the loop cannot be torn down while that work exists. So every
    /// service that declared `nilo_stop` gets told, after the connections
    /// are cut off and before the Runtime goes.
    ///
    /// **It runs whether or not the server ever started.** `startServices`
    /// stops at the first failure, so a `Db` that came up before the one
    /// that refused the boot is holding a pool nobody will ever ask for.
    fn serverStopping(self: *App) void {
        self.services.stopAll();
    }

    /// Start what `spawn` registered, into the group the Engine has by now.
    ///
    /// The first failure stops the rest, for the reason `Registry.start` has:
    /// a server that could not start the work it was told to start should say
    /// so at startup rather than serve requests while quietly doing none of
    /// it.
    fn startBackground(self: *App, io: std.Io) !void {
        if (self.background_started) return;
        self.background_started = true;
        for (self.background.items) |b| try b.start(b.args, self.gpa, io);
    }

    /// Stop the server: `listen()` stops accepting, connections finish the
    /// request they are on and close, and `listen()` returns.
    ///
    /// Safe to call from any thread, and from a handler — a `/admin/quit`
    /// route is an ordinary handler that calls this.
    pub fn shutdown(self: *App) void {
        self.stop.request();
    }

    /// Handle exactly one request from `in`, writing the answer to `out`.
    /// Returns true if the connection may be used for another request.
    ///
    /// The shape a test drives App with, and the shape everything but the
    /// connection loop wants. A handler that upgrades has its socket loop run
    /// here, on this frame — which is a page deeper than the connection loop
    /// would run it, and does not matter to anything that calls this.
    /// What a listener with `.grpc = true` runs for each connection, in place
    /// of `serve.handleConnection` (ADR 220). Reached only by an Engine
    /// built with `-Dgrpc`, so a build without it analyses none of `grpc.zig`.
    fn serveGrpc(
        self: *App,
        in: *std.Io.Reader,
        out: *std.Io.Writer,
        deadlines: bulkhead.Deadlines,
        waker: bulkhead.Waker,
        peer: bulkhead.Peer,
    ) void {
        grpc.serveConnection(self.grpcHost(), in, out, deadlines, waker, peer);
    }

    /// The App as a gRPC connection sees it (ADR 220). `grpc.zig` is outside
    /// this core and cannot name `App`, so it is handed the few things it
    /// uses instead: the router's answer to one path, and `serve.serveRequest`.
    pub fn grpcHost(self: *App) grpc.Host {
        // A call is collected into a `framing.Collected`, which a build
        // without `-Dgrpc` does not have: the arm is `noreturn` there, so
        // reaching it would be undefined behaviour in ReleaseFast. A compile
        // error says so instead (ADR 220).
        if (comptime !framing_mod.grpc_built) @compileError(
            "nilo: the App answers gRPC only in a build with `.grpc = true` (`-Dgrpc`).",
        );
        const Adapter = struct {
            fn routes(ptr: *anyopaque, path: []const u8) bool {
                const app: *App = @ptrCast(@alignCast(ptr));
                return app.router.match(.POST, path) != null;
            }
            fn bodyLimit(ptr: *anyopaque, path: []const u8) usize {
                const app: *App = @ptrCast(@alignCast(ptr));
                return app.grpcBodyLimit(path);
            }
            fn handle(
                ptr: *anyopaque,
                arena: std.mem.Allocator,
                lifetime: *str_mod.Lifetime,
                in_flight: *fail.InFlight,
                call: framing_mod.Call,
                collected: *framing_mod.Collected,
                peer: bulkhead.Peer,
                until_ns: u64,
            ) void {
                const app: *App = @ptrCast(@alignCast(ptr));
                // Handed over as what was read, with its body as the
                // reader, and answered into `collected`, never onto a
                // socket: the connection's fiber frames it (ADR 220,
                // ADR 253). A call cannot hand a socket over, so there is no
                // handover to run.
                var in: std.Io.Reader = .fixed(call.body);
                _ = serve.serveRequest(app, arena, lifetime, in_flight, &in, .{ .call = &call }, .{ .collect = collected }, .{ .until_ns = until_ns }, .{}, peer);
            }
        };
        return .{
            .ptr = self,
            .gpa = self.gpa,
            .stop = &self.stop,
            .max_body = self.limits.max_body,
            .ceiling = self.grpcBodyCeiling(),
            .body_limit = Adapter.bodyLimit,
            .routes = Adapter.routes,
            .handle = Adapter.handle,
        };
    }

    /// What a gRPC call to `path` may be collected under: the limit of the
    /// last `maxBody` in the chain of the route it reaches, which is the one
    /// that would have the last word on HTTP/1, and `listen()`'s `max_body`
    /// where there is none. Read before the message arrives, so what the
    /// route says is what the connection collects (ADR 156, ADR 220).
    /// Allocates nothing, and does nothing at all for an App that never
    /// called `maxBody`.
    fn grpcBodyLimit(self: *App, path: []const u8) usize {
        const base = self.limits.max_body;
        if (self.body_limits.items.len == 0) return base;
        var found: router.Match = undefined;
        if (!self.router.matchInto(.POST, path, &found)) return base;
        const found_route = &self.router.routes.items[found.index];
        if (!found_route.chain_by_path) return self.chainBodyLimit(found.chain, base);
        // A chain that depends on the path: built from the real one, as the
        // request path does, and given back. Only such a route pays for it.
        const chain = mw.chainFor(self.gpa, self.scoped.items, self.exemptions.items, self.attached.items, found_route.method, found_route.pattern, path) catch return base;
        defer if (chain.len > 0) self.gpa.free(chain);
        return self.chainBodyLimit(chain, base);
    }

    /// The limit `chain` ends up giving: the last non-zero one, `base` if
    /// no function in it is a `maxBody`.
    fn chainBodyLimit(self: *const App, chain: []const mw.Middleware, base: usize) usize {
        var limit = base;
        for (chain) |m| {
            for (self.body_limits.items) |l| {
                if (l.run != m) continue;
                const n = l.read();
                if (n != 0) limit = n;
                break;
            }
        }
        return limit;
    }

    /// The most any gRPC route may be collected under: what bounds one
    /// connection's messages together, because `max_body` no longer does once
    /// a route raises its own (ADR 220). A route whose chain depends on the
    /// path counts every limit `maxBody` was given. Only POST routes, which
    /// is what a call is.
    fn grpcBodyCeiling(self: *App) usize {
        var most = self.limits.max_body;
        if (self.body_limits.items.len == 0) return most;
        for (self.router.routes.items) |r| {
            if (r.method != .POST) continue;
            if (r.chain_by_path) {
                for (self.body_limits.items) |l| most = @max(most, l.read());
            } else {
                most = @max(most, self.chainBodyLimit(r.chain, self.limits.max_body));
            }
        }
        return most;
    }

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
        var served = serve.serveRequest(self, arena, lifetime, in_flight, in, .wire, .{ .wire = out }, deadlines, waker, peer);
        serve.runHandover(&served);
        return served.keep_alive;
    }
};

/// One registered route, as much of it as is anybody's business from outside:
/// what it answers and where.
///
/// Not the handler, not the middleware chain, not the split segments. Those
/// are how the router does its job, and a reader that could reach them is a
/// reader the router cannot change underneath.
pub const Registered = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Registered";

    method: http1.Method,
    /// The joined pattern the route was registered under — the same literal
    /// `Ctx.url` takes and every error message quotes.
    pattern: []const u8,
    /// The route's `operationId`, given or derived — the word `Ctx.routeName`
    /// answers and the document prints, so a test can hold an authorisation
    /// table against the route table without going through the document
    /// (ADR 162).
    name: []const u8,

    pub fn format(self: Registered, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} {s}", .{ @tagName(self.method), self.pattern });
    }
};

/// A read-only view over the route table — what `app.routes()` hands back.
///
/// A view rather than a list of its own: nothing is copied, nothing is
/// allocated, and a route is turned into a `Registered` only when somebody
/// asks for one.
pub const Routes = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Routes";

    _inner: []const router.Route,

    pub fn len(self: Routes) usize {
        return self._inner.len;
    }

    pub fn at(self: Routes, i: usize) Registered {
        const r = self._inner[i];
        return .{ .method = r.method, .pattern = r.pattern, .name = r.name };
    }

    /// One route a line, so a whole table goes into one log call.
    pub fn format(self: Routes, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self._inner, 0..) |r, i| {
            if (i > 0) try w.writeByte('\n');
            try w.print("  {s} {s}", .{ @tagName(r.method), r.pattern });
        }
    }
};

/// One prefix and everything registered beneath it — what `app.group()`
/// hands back (ADR 014).
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
    return GroupOf(prefix, &.{});
}

/// A group, and the middlewares the routes registered through it say do not
/// cover them (ADR 008).
///
/// `excluded` is empty for every group `app.group()` hands back; `without`
/// is what puts something in it, and what comes back is a different type, so
/// which routes carry an exception is decided while compiling.
pub fn GroupOf(comptime prefix: []const u8, comptime excluded: []const mw.Middleware) type {
    return GroupWith(prefix, excluded, &.{}, &.{}, null, router.every_listener);
}

/// The same, plus the middlewares the routes registered through it carry of
/// their own — what `with` puts there
/// ([ADR 099](../docs/adr/099-a-route-can-say-what-covers-it.md)).
///
/// Three comptime parameters and no fields but the App: which middleware a
/// route ends up wrapped in is settled while compiling, and the chain itself
/// is built once at `listen()` like every other. A route that carries one
/// costs a request exactly what a route covered by a `use` costs — nothing
/// beyond running it.
pub fn GroupWith(
    comptime prefix: []const u8,
    comptime excluded: []const mw.Middleware,
    comptime attached: []const mw.Middleware,
    comptime bounds: []const mw.Limited,
    comptime route_name: ?[]const u8,
    comptime only: u32,
) type {
    comptime checkPrefix(prefix);
    comptime if (route_name) |name| checkName(name);

    return struct {
        const Self = @This();

        app: *App,

        /// Where this group is mounted.
        ///
        /// Published because a plugin written as `fn mount(g: anytype) !void`
        /// otherwise cannot ask, and the prefix is a comptime parameter of the
        /// type rather than a field — so the only way to get at it was parsing
        /// `@typeName(@TypeOf(g))`, which is not a thing to ship (ADR 008).
        pub const mounted_at = prefix;

        /// A group inside this one. `app.group("/api").group("/v1")` and
        /// `app.group("/api/v1")` are the same thing.
        pub fn group(self: Self, comptime sub: []const u8) GroupWith(prefix ++ sub, excluded, attached, bounds, route_name, only) {
            return .{ .app = self.app };
        }

        /// This group with `middleware` off for the routes registered through
        /// what comes back — see `App.without`, which is the same call at the
        /// top level.
        pub fn without(self: Self, comptime middleware: anytype) GroupWith(
            prefix,
            excluded ++ &[_]mw.Middleware{mw.runOf(middleware)},
            attached,
            bounds,
            route_name,
            only,
        ) {
            return .{ .app = self.app };
        }

        /// This group with `middleware` **on** for the routes registered
        /// through what comes back — see `App.with`, which is the same call at
        /// the top level.
        pub fn with(self: Self, comptime middleware: anytype) GroupWith(
            prefix,
            excluded,
            attached ++ &[_]mw.Middleware{mw.runOf(middleware)},
            bounds ++ mw.limitsOf(middleware),
            route_name,
            only,
        ) {
            return .{ .app = self.app };
        }

        /// This group, with the next route registered through what comes back
        /// carrying `name` as its `operationId` — see `App.named`, which is
        /// the same call at the top level (ADR 119).
        pub fn named(self: Self, comptime name: []const u8) GroupWith(prefix, excluded, attached, bounds, name, only) {
            return .{ .app = self.app };
        }

        /// This group, answered only on the listeners numbered in `which`: a
        /// request that arrived on another listener finds no route here and
        /// gets the 404 an unknown path gets, before any middleware runs.
        /// See `App.onListener`, which is the same call at the top level
        /// (ADR 252). Narrowing only: a group already bound to `{1}` and
        /// asked for `{1, 2}` is still bound to `{1}`.
        pub fn onListener(self: Self, comptime which: []const u8) GroupWith(prefix, excluded, attached, bounds, route_name, only & router.listenerBits(which)) {
            return .{ .app = self.app };
        }

        /// Record that this route is not covered by the middleware `without`
        /// named, whatever a `use`/`useOn` says. Only ever from `add`: the
        /// exception is attached by the registration rather than typed as a
        /// second string, so renaming the route moves it. `excluded` is empty
        /// for almost every group, and an empty `inline for` compiles to
        /// nothing.
        fn excepting(self: Self, comptime pattern: []const u8, method: http1.Method) void {
            inline for (excluded) |middleware| {
                self.app.exemptions.appendAssumeCapacity(.{
                    .pattern = comptime joined(prefix, pattern),
                    .method = method,
                    .middleware = middleware,
                });
            }
        }

        /// Record what this route carries of its own, the same way and for the
        /// same cost: `attached` is empty for every group but the one `with`
        /// made, and an empty `inline for` compiles to nothing.
        fn attaching(self: Self, comptime pattern: []const u8, method: http1.Method) void {
            inline for (attached) |middleware| {
                self.app.attached.appendAssumeCapacity(.{
                    .pattern = comptime joined(prefix, pattern),
                    .method = method,
                    .middleware = middleware,
                });
            }
        }

        /// A route of this group: the route first, then what it is excused
        /// from and what it carries of its own. **In that order** because an
        /// exemption and an attachment are keyed on the pattern and method,
        /// not on the route, so one recorded for a registration that was then
        /// refused applied to the route already there: `without(auth)` and a
        /// `DuplicateRoute` exempted the first route from `auth`. The room is
        /// taken before the route goes in, so nothing after it can fail.
        fn add(
            self: Self,
            comptime stops: bool,
            method: http1.Method,
            comptime pattern: []const u8,
            comptime handler: anytype,
        ) !void {
            try self.app.exemptions.ensureUnusedCapacity(self.app.gpa, excluded.len);
            try self.app.attached.ensureUnusedCapacity(self.app.gpa, attached.len);
            inline for (bounds) |limited| try self.app.noteLimit(limited);
            if (stops) {
                try self.app.routeNamed(route_name, method, comptime joined(prefix, pattern), handler);
            } else {
                try self.app.tryRouteNamed(route_name, method, comptime joined(prefix, pattern), handler);
            }
            if (only != router.every_listener) {
                // The route just added is the last one: `routeNamed` returned
                // without error, so the router holds it at the end of its list.
                const routes_added = self.app.router.routes.items;
                routes_added[routes_added.len - 1].listeners = only;
            }
            self.excepting(pattern, method);
            self.attaching(pattern, method);
        }

        /// Middleware on everything in this group — `app.useOn(prefix, …)`,
        /// without repeating the prefix.
        pub fn use(self: Self, middleware: anytype) !void {
            if (prefix.len == 0) return self.app.use(middleware);
            return self.app.useOn(prefix, middleware);
        }

        /// Middleware on part of this group, `sub` being relative to it.
        pub fn useOn(self: Self, comptime sub: []const u8, middleware: anytype) !void {
            const full = comptime joined(prefix, sub);
            if (full.len == 0) return self.app.use(middleware);
            return self.app.useOn(full, middleware);
        }

        /// A service. Groups do not scope services — a `*Db` is a `*Db` to
        /// the whole App (ADR 005) — but a plugin that brings its own has
        /// to be able to register it without being handed the App as well.
        pub fn provide(self: Self, ptr: anytype) !void {
            return self.app.provide(ptr);
        }

        pub fn get(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            return self.add(true, .GET, pattern, handler);
        }

        pub fn post(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            comptime typed.checkVerb(.POST, joined(prefix, pattern), handler);
            return self.add(true, .POST, pattern, handler);
        }

        /// `App.rpc` under this group's prefix and middleware. A gRPC
        /// client calls `/<nilo_service>/<Method>` from the root, so its
        /// group has no prefix; a Connect client may call it under one.
        pub fn rpc(self: Self, comptime T: type) !void {
            inline for (comptime rpc_mod.methodsOf(T)) |method| try self.post(method.path, @field(T, method.fn_name));
        }

        pub fn put(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            comptime typed.checkVerb(.PUT, joined(prefix, pattern), handler);
            return self.add(true, .PUT, pattern, handler);
        }

        pub fn delete(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            comptime typed.checkVerb(.DELETE, joined(prefix, pattern), handler);
            return self.add(true, .DELETE, pattern, handler);
        }

        pub fn patch(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            comptime typed.checkVerb(.PATCH, joined(prefix, pattern), handler);
            return self.add(true, .PATCH, pattern, handler);
        }

        pub fn head(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            return self.add(true, .HEAD, pattern, handler);
        }

        pub fn options(self: Self, comptime pattern: []const u8, comptime handler: anytype) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            comptime typed.checkVerb(.OPTIONS, joined(prefix, pattern), handler);
            return self.add(true, .OPTIONS, pattern, handler);
        }

        pub fn route(
            self: Self,
            method: http1.Method,
            comptime pattern: []const u8,
            comptime handler: anytype,
        ) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            return self.add(true, method, pattern, handler);
        }

        pub fn tryRoute(
            self: Self,
            method: http1.Method,
            comptime pattern: []const u8,
            comptime handler: anytype,
        ) !void {
            comptime typed.check(joined(prefix, pattern), handler);
            return self.add(false, method, pattern, handler);
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

        pub fn embedded(self: Self, comptime url_prefix: []const u8, files: []const static_mod.Embedded) !void {
            return self.app.embedded(comptime joined(prefix, url_prefix), files);
        }

        pub fn embeddedWith(
            self: Self,
            comptime url_prefix: []const u8,
            files: []const static_mod.Embedded,
            opts: static_mod.EmbedOptions,
        ) !void {
            return self.app.embeddedWith(comptime joined(prefix, url_prefix), files, opts);
        }
    };
}

/// A route's own `operationId` is a word a client generator turns into a
/// method name, so it has to be one (ADR 119). Letters, digits, `_` and
/// `-`, starting with a letter or `_`.
///
/// **The hyphen is allowed because the document on the other side of a port
/// may already have it**
/// ([ADR 119](../docs/adr/119-a-route-can-say-its-own-name.md)).
/// OpenAPI permits one, every client generator in use folds `auth-login` to
/// `authLogin`, and a contract spelled by somebody else's generator is not a
/// contract this framework gets to respell. A space, a dot or a slash is
/// still refused: those are not a name under any convention.
fn checkName(comptime name: []const u8) void {
    comptime {
        // **A framework spending a caller's comptime budget is the
        // framework's to account for**
        // ([ADR 126](../docs/adr/126-a-check-pays-for-its-own-branches.md)).
        // This loop walks a name a byte at a time, so sixteen `named` routes
        // on one group were enough to finish the default 1,000 backwards
        // branches — and what the caller saw was `evaluation exceeded 1000
        // backwards branches` pointing at a line in `app.zig` and at whichever
        // route it happened to stop on, which reads like a problem with that
        // route.
        //
        // **Generous rather than exact, and that is what the quota is.** It
        // is a ceiling on the caller's whole `register`, not on this call: a
        // comptime call is analysed inside the caller's evaluation, so every
        // route's bytes are counted against one budget and setting it again
        // per route only ever raises it. An exact `name.len` would therefore
        // be right for the first route and short by the two hundredth. What
        // this buys is that nilo's own walk is never the thing that runs out;
        // a caller whose comptime work genuinely needs more still says so.
        // `row.zig`'s `distance` sizes its own the same way, one file over.
        @setEvalBranchQuota(10_000 + 1_000 * (name.len + 1));
        if (name.len == 0) @compileError(
            "nilo: `app.named(\"\")` is a route with no name, which is `app` with extra steps.\n" ++
                "  Give it the name the generated client and your own authorisation table " ++
                "will use: `app.named(\"addPartnerCapability\")`.",
        );
        for (name, 0..) |ch, i| {
            const ok = std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
            const starts = std.ascii.isAlphabetic(ch) or ch == '_';
            if (!ok or (i == 0 and !starts)) @compileError(
                "nilo: the route name \"" ++ name ++ "\" is not something a client generator " ++
                    "can turn into a method.\n" ++
                    "  An operationId is letters, digits, `_` and `-`, starting with a letter or " ++
                    "`_`: `addPartnerCapability` or `auth-login`, not \"" ++ name ++ "\".",
            );
        }
    }
}

/// A group prefix has a leading slash, no trailing one, and no catch-all.
/// A param is allowed: `use` scopes middleware by matching whole segments,
/// and a `:name` segment matches whatever is opposite it (`middleware.zig`).
fn checkPrefix(comptime prefix: []const u8) void {
    comptime {
        // The root group, which is what a plugin mounted at the top gets.
        if (prefix.len == 0) return;

        if (prefix[0] != '/') @compileError(
            "nilo: the group prefix \"" ++ prefix ++ "\" does not start with a slash.\n" ++
                "  Write `app.group(\"/" ++ prefix ++ "\")` — a prefix is the front of a path, " ++
                "and a path always begins with one.",
        );
        if (prefix[prefix.len - 1] == '/') @compileError(
            "nilo: the group prefix \"" ++ prefix ++ "\" ends with a slash.\n" ++
                "  Drop it: `app.group(\"" ++ prefix[0 .. prefix.len - 1] ++ "\")`. The patterns " ++
                "registered inside bring their own leading slash, and two would make " ++
                "\"" ++ prefix ++ "/users\".",
        );
        if (std.mem.indexOfScalar(u8, prefix, '*') != null) @compileError(
            "nilo: the group prefix \"" ++ prefix ++ "\" has a `*` in it, and a catch-all " ++
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
            "nilo: a route pattern inside the group \"" ++ prefix ++ "\" cannot be empty.\n" ++
                "  Use \"/\" for the group's own path.",
        );
        if (pattern[0] != '/') @compileError(
            "nilo: the route pattern \"" ++ pattern ++ "\" inside the group \"" ++ prefix ++
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

// ---- tests: the one thing here that never leaves this file ----

const testing = std.testing;

/// A service that needs the loop, in the shape `nilo_sql`'s `Db` has one:
/// `init` opens nothing and `nilo_start` is where the pool would be built.
const Opened = struct {
    times: usize = 0,
    io_seen: bool = false,

    pub fn nilo_start(self: *Opened, io: std.Io) !void {
        self.times += 1;
        self.io_seen = io.vtable != undefined;
    }
};

fn readsOpened(_: *Opened) []const u8 {
    return "ok";
}

test "app.start refuses when a route needs a service nobody provided" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/thing", readsOpened);

    // Through the predicate rather than `app.start`, which logs each gap
    // before it fails — the same reason the `listen()` test above uses it: a
    // test process that writes an error log is reported as a failure, and
    // those lines are the feature rather than the accident.
    const missing = app.missingService().?;
    try testing.expectEqualStrings("/thing", missing.route);
    try testing.expectEqualStrings(@typeName(Opened), missing.type_name);

    // And nothing was opened, because the gate is in front of the pools.
    try testing.expectEqual(App.StartedBy.nobody, app.services_started);
}

test "app.start opens the services once, and a second call is not a second pool" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var app = App.init(testing.allocator);
    defer app.deinit();
    var opened: Opened = .{};
    try app.provide(&opened);
    try app.get("/thing", readsOpened);

    // A program that never listens: a test, a script (ADR 180).
    try app.start(threaded.io());
    try testing.expectEqual(@as(usize, 1), opened.times);

    try app.start(threaded.io());
    try testing.expectEqual(@as(usize, 1), opened.times);
}

test "listen after app.start is refused when a service took the caller's Io" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var app = App.init(testing.allocator);
    defer app.deinit();
    var opened: Opened = .{};
    try app.provide(&opened);

    // Through the predicate `serverStarting` reads, for the reason the test
    // above gives: the refusal is the predicate and one error line, and the
    // line is the feature.
    try testing.expect(!app.startedElsewhere());
    try app.start(threaded.io());
    try testing.expect(app.startedElsewhere());
    try testing.expectEqual(App.StartedBy.start, app.services_started);
}

test "listen after app.start goes ahead when no service needed the loop" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    // A service with no `nilo_start` kept no `Io`, so there is nothing on
    // the wrong loop: the shape `http/live.zig` drives end to end.
    const Plain = struct { n: u8 = 0 };
    var plain: Plain = .{};

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&plain);

    try app.start(threaded.io());
    try testing.expect(!app.startedElsewhere());
    try app.serverStarting(threaded.io(), .{}, null);
}

/// What `before` work saw when it ran: whether the service it was handed
/// had already been started, and whether its Run could reach the loop.
const Witness = struct {
    times: usize = 0,
    service_was_up: bool = false,
    had_io: bool = false,
    noted: bool = false,

    fn record(run: *str_mod.Run, opened: *Opened, self: *Witness) !void {
        self.times += 1;
        self.service_was_up = opened.times == 1;
        // The Run is built on the loop the services were started on, so a
        // key can be minted from it (ADR 128); `Run.init` would say NoIo.
        _ = try run.entropy(4);
        self.had_io = true;
    }

    /// Work that cannot fail is registered the same way.
    fn note(_: *str_mod.Run, self: *Witness) void {
        self.noted = true;
    }

    fn refuse(_: *str_mod.Run, _: *Witness) !void {
        return error.Nope;
    }

    /// Boot work calling what a handler calls, and refused by it.
    fn refuseInWords(_: *str_mod.Run, _: *Witness) !void {
        return fail.unprocessable("no suspicious return in {s}", .{"Sekernan"});
    }
};

test "app.before runs inside the boot, after the services, with a Run on their loop" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var app = App.init(testing.allocator);
    defer app.deinit();
    var opened: Opened = .{};
    var witness: Witness = .{};
    try app.provide(&opened);
    try app.before(Witness.record, .{ &opened, &witness });
    try app.before(Witness.note, .{&witness});

    // Nothing runs at registration: the loop does not exist yet.
    try testing.expectEqual(@as(usize, 0), witness.times);

    // What the Engine calls once the port is taken.
    try app.serverStarting(threaded.io(), .{}, null);
    try testing.expectEqual(@as(usize, 1), opened.times);
    try testing.expectEqual(@as(usize, 1), witness.times);
    try testing.expect(witness.service_was_up);
    try testing.expect(witness.had_io);
    try testing.expect(witness.noted);
    try testing.expectEqual(App.StartedBy.listen, app.services_started);

    // And not twice: a second boot on the same App is not a second migration.
    try app.serverStarting(threaded.io(), .{}, null);
    try testing.expectEqual(@as(usize, 1), witness.times);
}

/// A service with something to verify once the boot work is done: what a
/// `Db` does with its schema (ADR 180). Records whether the `before` work
/// had already run when the check did, which is the whole point of the
/// phase.
const Checked = struct {
    checks: usize = 0,
    saw_before_done: bool = false,
    refuse: bool = false,
    witness: ?*const Witness = null,

    pub fn nilo_start(_: *Checked, _: std.Io) !void {}

    pub fn nilo_check(self: *Checked, io: std.Io) !void {
        self.checks += 1;
        _ = io;
        if (self.witness) |w| self.saw_before_done = w.noted;
        if (self.refuse) return error.SchemaMismatch;
    }
};

test "a service's nilo_check runs after the before work, once, inside the boot" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var app = App.init(testing.allocator);
    defer app.deinit();
    var witness: Witness = .{};
    var checked: Checked = .{ .witness = &witness };
    try app.provide(&checked);
    try app.before(Witness.note, .{&witness});

    try app.serverStarting(threaded.io(), .{}, null);
    // The order is the fix: a `createMissing` in `before` has made its tables
    // by the time the schema is checked against them.
    try testing.expectEqual(@as(usize, 1), checked.checks);
    try testing.expect(checked.saw_before_done);

    // Once, like the before work it follows.
    try app.serverStarting(threaded.io(), .{}, null);
    try testing.expectEqual(@as(usize, 1), checked.checks);
}

test "app.start runs the before work and the checks too, so a test's tables exist" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var app = App.init(testing.allocator);
    defer app.deinit();
    var witness: Witness = .{};
    var checked: Checked = .{ .witness = &witness };
    try app.provide(&checked);
    try app.before(Witness.note, .{&witness});

    // Everything `listen()` does before it accepts anything, on the
    // caller's `Io`: the phase is the same, the loop is theirs.
    try app.start(threaded.io());
    try testing.expect(witness.noted);
    try testing.expectEqual(@as(usize, 1), checked.checks);
    try testing.expect(checked.saw_before_done);
}

test "a nilo_check that fails hands its own error to the boot" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var app = App.init(testing.allocator);
    defer app.deinit();
    var checked: Checked = .{ .refuse = true };
    try app.provide(&checked);

    // Through the registry rather than `checkServiceHooks`, which says in
    // one error line that the server will not start, for the reason the
    // `before` test below drives its entry directly.
    try testing.expectError(error.SchemaMismatch, app.services.check(threaded.io()));
}

test "app.before work that fails hands its own error to the boot" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var app = App.init(testing.allocator);
    defer app.deinit();
    var witness: Witness = .{};
    try app.before(Witness.refuse, .{&witness});

    // The registration is driven directly rather than through `runBefore`,
    // which says in one error line that the server will not start — the
    // same reason the refusals above go through predicates. What is under
    // test is that the error crosses the erasure unchanged, so `listen()`
    // can hand it back as the value it was.
    const entry = app.before_serving.items[0];
    try testing.expectError(error.Nope, entry.start(entry.args, testing.allocator, threaded.io()));
}

test "a fail function in app.before work leaves its words for the boot's line" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var app = App.init(testing.allocator);
    defer app.deinit();
    var witness: Witness = .{};
    try app.before(Witness.refuseInWords, .{&witness});

    // Driven one piece at a time for the reason the test above gives: what
    // `runBefore` does with the words is log them at `err`. Outside a
    // request a fail function used to return `Failed` and drop the
    // sentence, so the boot said which error and never why.
    var in_flight: fail.InFlight = .{};
    const entry = app.before_serving.items[0];
    try testing.expectError(error.Failed, App.runOneBefore(entry, testing.allocator, threaded.io(), &in_flight));
    try testing.expectEqual(@as(u16, 422), in_flight.failure.status);
    try testing.expectEqualStrings("no suspicious return in Sekernan", in_flight.failure.message());

    // And the box was the boot's for as long as the work ran, not after it:
    // a fallback slot left pointing at this frame would be a dangling
    // pointer for the next fail function on this thread.
    try testing.expectEqual(@as(?*anyopaque, null), bulkhead.slot());
}
