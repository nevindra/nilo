//! Everything `listen()` settles before the first connection is accepted.
//!
//! Split from `app.zig` for the reason `serve.zig` is: this half runs once,
//! at boot, and nothing in it is on a request path. Which middleware wraps
//! which route, which services are missing, what the OpenAPI document says,
//! how the program was built — all of it is worked out here and then never
//! touched again. `App` still owns these — they are called as
//! `wiring.resolveChains(app)` rather than `app.resolveChains()`.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("app.zig");
const router = @import("router.zig");
const service_mod = @import("service.zig");
const mw = @import("middleware.zig");
const pathparams = @import("pathparams.zig");
const static_mod = @import("static.zig");
const proxies_mod = @import("proxies.zig");
const openapi = @import("openapi.zig");
const compress_mod = @import("compress.zig");
const bulkhead = @import("bulkhead.zig");
const log_mod = @import("log.zig");

const App = app_mod.App;

/// The route already carrying this `operationId`, if one does.
///
/// A function rather than a loop inside `tryRouteNamed` so that the check
/// can be tested without provoking the `std.log.err` registration writes
/// — a logged error is a failed test run, and the noise would sit in
/// `zig build test` forever. This is the shape `router.conflicting`
/// already has, for the same reason (ADR 119).
pub fn nameTaken(self: *const App, given: []const u8) ?openapi.Operation {
    for (self.operations.items) |existing| {
        const taken = existing.name orelse continue;
        if (std.mem.eql(u8, taken, given)) return existing;
    }
    return null;
}

/// Turn `listen(.{ .trusted_proxies = … })` into the networks `clientIp`
/// compares against, once (ADR 102).
///
/// A rule that is not an address stops the server here rather than being
/// quietly ignored, because "ignored" means answering with the wrong
/// client address for the life of the deployment — and the things that
/// read `clientIp` are the rate limit and the audit log.
pub fn parseTrustedProxies(self: *App, rules: []const []const u8) !void {
    self.gpa.free(self.trusted_proxies);
    self.trusted_proxies = &.{};
    if (rules.len == 0) return;

    var room: usize = 0;
    for (rules) |rule| room += proxies_mod.expands(rule);

    const parsed = try self.gpa.alloc(proxies_mod.Cidr, room);
    errdefer self.gpa.free(parsed);

    var n: usize = 0;
    for (rules) |rule| {
        n += try proxies_mod.parseInto(parsed[n..], rule);
    }
    self.trusted_proxies = parsed[0..n];
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
/// than at three in the morning (ADR 005).
pub fn checkServices(self: *const App) error{MissingService}!void {
    if (missingService(self) == null) return;

    // One message per missing service, not one per route that wanted
    // it. Five routes sharing a `*Db` is the normal shape of an app, so
    // forgetting to provide it used to print the same sentence — and
    // the same fix — five times over.
    for (self.requirements.items, 0..) |r, i| {
        if (self.services.has(r)) continue;
        if (alreadyReported(self.requirements.items[0..i], r)) continue;

        var wanting: [3][]const u8 = undefined;
        var n: usize = 0;
        var total: usize = 0;
        for (self.requirements.items) |other| {
            if (!sameService(other, r)) continue;
            total += 1;
            if (n < wanting.len) {
                wanting[n] = other.route;
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
                RouteList{ .routes = wanting[0..n] },
                if (total > n) ", …" else "",
            },
        );
    }
    return error.MissingService;
}

/// A typed middleware reads a path param a route it covers does not have.
pub const PathGap = struct {
    /// "the middleware taking (…)".
    who: []const u8,
    param: []const u8,
    /// The route's pattern, or for a static mount its prefix.
    route: []const u8,
    static: bool = false,
};

/// The first path param a typed middleware reads that a route in its chain
/// lacks, or null. The predicate `checkMiddlewarePaths` reports through, and
/// what a test reads, as `missingService` is for services (ADR 005).
pub fn middlewarePathGap(self: *const App) ?PathGap {
    return scanPaths(self, false);
}

fn scanPaths(self: *const App, report: bool) ?PathGap {
    var first: ?PathGap = null;
    for (self.middleware_needs.items) |need| {
        if (need.paths.len == 0) continue;
        for (self.router.routes.items) |r| {
            if (!routeReached(self, need.run, r)) continue;
            for (need.paths) |name| {
                if (pathparams.captures(r.pattern, name)) continue;
                const gap: PathGap = .{ .who = need.who, .param = name, .route = r.pattern };
                if (first == null) first = gap;
                if (!report) return first;
                std.log.err(
                    "{s} reads the path param :{s}, and route \"{s}\" has no such param, " ++
                        "but the middleware covers it. Cover only routes that have it " ++
                        "(`app.useOn(\"/orgs/:org\", …)` or `with`), or read the param " ++
                        "from the `*Ctx` with `c.param(\"{s}\")` instead",
                    .{ need.who, name, r.pattern, name },
                );
                break;
            }
        }
        // A static file has no params at all, so a mount under the middleware
        // would be served unguarded (ADR 008).
        const mounts = [_]?*const static_mod.Set{
            if (self.docs_set) |*set| set else null,
        };
        for (mounts) |maybe| if (maybe) |set| {
            if (!mountReached(self, need.run, set.prefix)) continue;
            const gap: PathGap = .{ .who = need.who, .param = need.paths[0], .route = set.prefix, .static = true };
            if (first == null) first = gap;
            if (!report) return first;
            reportMount(gap);
        };
        for (self.static_sets.items) |*set| {
            if (!mountReached(self, need.run, set.prefix)) continue;
            const gap: PathGap = .{ .who = need.who, .param = need.paths[0], .route = set.prefix, .static = true };
            if (first == null) first = gap;
            if (!report) return first;
            reportMount(gap);
        }
    }
    return first;
}

fn reportMount(gap: PathGap) void {
    std.log.err(
        "{s} reads the path param :{s}, and the static mount \"{s}\" is under its prefix, " ++
            "where a file has no path params: it would be served without the middleware's check. " ++
            "Move the mount outside the middleware's prefix, or the middleware onto the routes " ++
            "that have the param",
        .{ gap.who, gap.param, gap.route },
    );
}

/// Whether the middleware `run` is in front of `r`: in its chain, or on a
/// prefix that only the real path can decide (`reach` says `.depends`, as for
/// `useOn("/api", …)` beside `/:version/list`), taken as covered unless the
/// route was excused from it. Conservative on purpose: a route that might be
/// covered and lacks the param is refused, rather than 500 on a request.
fn routeReached(self: *const App, run: mw.Middleware, r: router.Route) bool {
    for (r.chain) |m| if (m == run) return true;
    for (self.scoped.items) |s| {
        if (s.middleware != run) continue;
        if (mw.reach(s.prefix, r.pattern) != .depends) continue;
        var excused = false;
        for (self.exemptions.items) |e| {
            if (e.middleware == run and e.method == r.method and std.mem.eql(u8, e.pattern, r.pattern)) excused = true;
        }
        if (!excused) return true;
    }
    return false;
}

/// Whether a static mount at `prefix` can hold a file the middleware `run`
/// covers: its prefix and the mount's are nested either way round.
fn mountReached(self: *const App, run: mw.Middleware, prefix: []const u8) bool {
    for (self.scoped.items) |s| {
        if (s.middleware != run) continue;
        if (mw.reach(s.prefix, prefix) != .outside or mw.reach(prefix, s.prefix) != .outside) return true;
    }
    return false;
}

/// Hold the path params every typed middleware reads against each route its
/// chain covers (ADR 008). Called by `listen()` once the chains exist: each
/// route must have a `:name` for every field of a `Path(T)` the middleware
/// takes, directly or through a resolver, or the first request to it would
/// be a 500. Said for every middleware and route, naming both and the param.
pub fn checkMiddlewarePaths(self: *const App) error{MiddlewarePathParam}!void {
    if (scanPaths(self, true) != null) return error.MiddlewarePathParam;
}

/// Work out which middleware wraps each route, once. Called by
/// `listen()`; separate so tests can drive it without a server.
///
/// Doing this here rather than when each route is registered is what
/// makes `use` and `get` order-independent — Fiber's most reported
/// gotcha is middleware registered after a route silently not applying
/// to it (ADR 008).
pub fn resolveChains(self: *App) !void {
    freeChains(self);
    for (self.router.routes.items) |*r| {
        r.chain = try mw.chainFor(self.gpa, self.scoped.items, self.exemptions.items, self.attached.items, r.method, r.pattern, r.pattern);
        r.chain_by_path = mw.dependsOnPath(self.scoped.items, r.pattern);
    }
    try buildDocs(self);

    // After `buildDocs`, which is what makes `docs_set` exist to have
    // chains for.
    if (self.docs_set) |*set| self.docs_chains = try chainsFor(self, set);
    try self.static_chains.ensureTotalCapacityPrecise(self.gpa, self.static_sets.items.len);
    for (self.static_sets.items) |*set| {
        self.static_chains.appendAssumeCapacity(try chainsFor(self, set));
    }
    try sizeMetrics(self);
    try sizeCompressors(self);
    if (self.trace_hooks) |hooks| try hooks.size(self);
}

/// Give `trace()` its rings, one per executor thread, for the reason the
/// compressors are sized here: the thread count is `listen()`'s to say
/// (ADR 247). Kept when already that many. Called through
/// `app.trace_hooks`, so a program that does not trace links none of it.
pub fn sizeTracer(self: *App) anyerror!void {
    const tracer = self.tracer orelse return;
    const count: usize = if (self.compress_slots > 0)
        self.compress_slots
    else
        bulkhead.threadCount(bulkhead.Options{});
    try tracer.size(count);
}

/// Give `compress()` its pool, here rather than at `compress()`, because
/// the thread count is not known until `listen()` says it, and one per
/// thread is the whole design (ADR 211).
///
/// Once. The test client resolves the chains before every request, and
/// `~288 KB` a slot is not something to take again each time; a pool
/// already the right size is kept.
pub fn sizeCompressors(self: *App) !void {
    const options = self.compress_options orelse return;
    const count: usize = if (self.compress_slots > 0)
        self.compress_slots
    else
        bulkhead.threadCount(bulkhead.Options{});
    if (self.compressors) |*pool| {
        if (pool.len() == count) return;
        pool.deinit(self.gpa);
        self.compressors = null;
    }
    self.compressors = try compress_mod.Pool.init(self.gpa, count, options);
}

/// Give the counters their memory and their labels, here rather than at
/// `metrics()`, because the route count is still moving when that is
/// called and has stopped moving by the time this runs.
///
/// Run again from scratch if the chains are resolved twice, which is what
/// a test that registers more routes and resolves again does.
pub fn sizeMetrics(self: *App) !void {
    const table = if (self.metrics_table) |*t| t else return;
    try table.size(self.gpa, self.router.routes.items.len);
    for (self.router.routes.items, 0..) |r, i| {
        table.nameRoute(i, @tagName(r.method), r.pattern);
    }
    table.exposed = self.exposed.items;
    // The App counts this already, to know what a stop has to wait for.
    table.in_flight = &self.stop.in_flight;
}

/// The chain for every file in `set`, in the set's own order, so a
/// lookup that found a file has found its chain as well.
pub fn chainsFor(self: *App, set: *const static_mod.Set) ![]const []const mw.Middleware {
    const chains = try self.gpa.alloc([]const mw.Middleware, set.files.len);
    var made: usize = 0;
    errdefer {
        for (chains[0..made]) |c| if (c.len > 0) self.gpa.free(c);
        self.gpa.free(chains);
    }
    for (set.files, chains) |file, *chain| {
        chain.* = try mw.chainFor(self.gpa, self.scoped.items, self.exemptions.items, self.attached.items, null, file.url, file.url);
        made += 1;
    }
    return chains;
}

/// Write the API description to `w`, with no server and no port
/// ([ADR 135](../docs/adr/135-the-document-is-a-build-artefact.md)).
///
/// ```zig
/// var app = nilo.App.init(gpa);
/// defer app.deinit();
/// try routes.register(&app);
///
/// var out = std.Io.Writer.Allocating.init(gpa);
/// defer out.deinit();
/// try app.writeOpenApi(&out.writer);
/// ```
///
/// Called after the routes are registered and before `listen`, so the file a
/// frontend compiles against needs no port, no database and no network.
///
/// The title and version come from `app.docs(.{ … })` when it was called and
/// are `Info`'s defaults when it was not. Same bytes as `/openapi.json`, from
/// the same call on the same operations — which is what stops a checked-in
/// file and a running server describing two different APIs.
pub fn writeOpenApi(self: *const App, w: *std.Io.Writer) !void {
    var info: openapi.Info = if (self.docs_options) |opts| .{
        .title = opts.title,
        .version = opts.version,
        .description = opts.description,
    } else .{};
    info.failure = self.failure_schema;
    const guard = self.declared_guard orelse
        return openapi.write(self.gpa, w, self.operations.items, info);

    // Which routes the guard is in front of is settled here, from the
    // same wiring `resolveChains` reads, rather than when the route was
    // registered — a `without` or a `with` written after the route would
    // otherwise be missed (ADR 153). On a copy, because the operations
    // are the App's and this is a `*const` view of it.
    info.cookie = guard.cookie;
    const ops = try self.gpa.dupe(openapi.Operation, self.operations.items);
    defer self.gpa.free(ops);
    for (ops) |*op| {
        op.guarded = mw.wraps(
            self.scoped.items,
            self.exemptions.items,
            self.attached.items,
            op.method,
            op.pattern,
            guard.middleware,
        );
    }
    try openapi.write(self.gpa, w, ops, info);
}

/// Turn the collected operations into the document and its reader page.
/// Here rather than in `docs()` because every route has to be registered
/// first, and here rather than on the request path because the answer
/// cannot change once the server is running.
pub fn buildDocs(self: *App) !void {
    if (self.docs_set) |*set| {
        set.deinit();
        self.docs_set = null;
    }
    const opts = self.docs_options orelse return;

    var document: std.Io.Writer.Allocating = .init(self.gpa);
    defer document.deinit();
    // Through the public door rather than beside it: a checked-in file
    // and a served one that came from two calls are two things to keep
    // in step (ADR 135).
    try self.writeOpenApi(&document.writer);

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

pub fn freeChains(self: *App) void {
    for (self.router.routes.items) |*r| {
        if (r.chain.len > 0) self.gpa.free(r.chain);
        r.chain = &.{};
    }

    // Freed here rather than in `deinit` alone, because `resolveChains`
    // can run more than once — a test, or a program that listens twice
    // — and `buildDocs` replaces the very `docs_set` these parallel.
    freeChainList(self, self.docs_chains);
    self.docs_chains = &.{};
    for (self.static_chains.items) |chains| freeChainList(self, chains);
    self.static_chains.clearRetainingCapacity();
}

pub fn freeChainList(self: *App, chains: []const []const mw.Middleware) void {
    for (chains) |c| if (c.len > 0) self.gpa.free(c);
    if (chains.len > 0) self.gpa.free(chains);
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
pub fn countUndescribed(self: *App) void {
    if (self.docs_options == null) return;

    var written: usize = 0;
    for (self.operations.items) |op| {
        if (op.answer.written) written += 1;
    }
    if (written == 0) return;

    std.log.info(
        "{d} of {d} routes hold the Ctx and return nothing, so the API description " ++
            "cannot say what they answer — a handler that means \"200, empty\" says so " ++
            "by returning `Status(200, void)` (ADR 120)",
        .{ written, self.operations.items.len },
    );
}

/// Two lines belong in a nilo root source file, and forgetting either one
/// fails quietly — the sort of quiet that costs an afternoon. Without
/// `std_options_debug_io`, `std.log` writes to stderr the blocking way and
/// parks the whole event loop behind it; without `std_options`, the
/// Engine's own debug lines bury yours. Neither can be set from a library,
/// so the next best thing is to say so once, by name, at startup.
pub fn checkRootWiring(log_format: log_mod.Format) void {
    if (comptime !@hasDecl(@import("root"), "std_options_debug_io")) std.log.warn(
        "std.log will block the event loop. Add to your root source file: " ++
            "pub const std_options_debug_io = nilo.debug_io;",
        .{},
    );
    if (comptime std.log.logEnabled(.debug, .zio)) std.log.warn(
        "the Engine's debug lines are switched on and will drown out your own. Add to your " ++
            "root source file: pub const std_options = nilo.std_options;",
        .{},
    );
    if (comptime missingPanic(@import("root"))) |line| std.log.warn("{s}", .{line});
    // JSON is the format that needs the sink: behind std's default `logFn`
    // every line starts `info: `, which no collector parses (ADR 262).
    if (log_format == .json and comptime !log_mod.installed) std.log.warn(
        "log lines will not be JSON: std's logFn puts `info: ` in front of each. Add to your " ++
            "root source file: pub const std_options: std.Options = .{{ .logFn = nilo.logFn }};",
        .{},
    );
    warnIfBuiltDifferently();
}

/// The warning for a root file with no `pub const panic = nilo.panic`, or
/// null when it has one (ADR 007). A panic ends the process, not the request
/// (Go's net/http loses one request and carries on), and without this line
/// the crash log does not name the request that did it. In `ReleaseFast` the
/// same mistake is undefined behaviour rather than a panic, so the sentence
/// says what to build with. A function of the root so a test can hand it
/// roots that have the line and roots that do not.
pub fn missingPanic(comptime Root: type) ?[]const u8 {
    if (@hasDecl(Root, "panic")) return null;
    return "a panic ends the whole process, not just the request, and the crash log will not " ++
        "name the request that did it. Add to your root source file: " ++
        "pub const panic = nilo.panic;  (build ReleaseSafe in production: in ReleaseFast " ++
        "an overflow or out-of-bounds is undefined behaviour, not a panic)";
}

/// What the *program* was built at, which is not the same question as what
/// nilo was built at.
///
/// `std` is one module per compilation and it takes the root's optimize mode,
/// so a constant of std's own says which that was even when read from a module
/// built at another. **It takes two of them**, and the first version of this
/// shipped with one.
///
/// `std.log.default_level` looked like it separated the modes and does not:
/// in Zig 0.16 `.Debug` is `.debug` and **all three release modes are
/// `.info`**. Reading `.info` as `ReleaseSafe` therefore answered ReleaseSafe
/// for a correctly built `ReleaseFast` program, so the warning fired at
/// exactly the people who had passed the mode through — the opposite of what
/// it is for. `std.debug.runtime_safety` is the other half: true for `Debug`
/// and `ReleaseSafe`, false for the other two, and its own doc comment calls
/// it the optimize mode of the standard library.
///
/// `ReleaseFast` and `ReleaseSmall` are still one answer, which is why the
/// message names them as a pair rather than guessing.
pub const program_mode: ?std.lang.Optimize =
    modeFrom(std.log.default_level, std.debug.runtime_safety);

/// The derivation, as a function so that **every arm of it can be run from a
/// suite that only ever builds in two modes**.
///
/// `program_mode` is one value per compilation, so the `ReleaseFast` arm could
/// only ever be *not run* — and that is how it shipped wrong
/// ([ADR 032](../docs/adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)).
pub fn modeFrom(level: std.log.Level, safety: bool) ?std.lang.Optimize {
    return switch (level) {
        .debug => .debug,
        // The level alone cannot tell the three release modes apart, so the
        // safety flag splits the pair off.
        .info => if (safety) .safe else null,
        // No optimize mode produces any other level. A future std that
        // changes this lands here, and null is the answer that warns nobody
        // rather than everybody.
        else => null,
    };
}

/// Nilo built in `Debug` under a `ReleaseFast` program: legal, slow, and
/// silent until now (ADR 069).
///
/// It happens by leaving `.optimize` out of `b.dependency("nilo", …)`, and it
/// has the same symptom as forgetting `std_options_debug_io` — a server that
/// is merely slow — which nilo has warned about since the beginning. Two
/// identical symptoms deserve two warnings.
///
/// The one that costs most is a *test* build: a suite looping over `.{ .Debug,
/// .ReleaseSafe }` and passing neither through was checking a ReleaseSafe
/// program against a Debug nilo for two milestones, which is why this is
/// reached from the test client as well as from `listen()`.
pub fn warnIfBuiltDifferently() void {
    const ours = @import("builtin").mode;
    const differs = comptime if (program_mode) |theirs|
        theirs != ours
    else
        ours == .debug or ours == .safe;

    if (comptime !differs) return;

    std.log.warn(
        "nilo was built in {s} and this program in {s}, which is legal and slow. " ++
            "Pass the mode through: b.dependency(\"nilo\", .{{ .target = target, " ++
            ".optimize = optimize }}) — in the test step too, which is the one that " ++
            "usually gets missed.",
        .{
            @tagName(ours),
            comptime if (program_mode) |theirs| @tagName(theirs) else "ReleaseFast or ReleaseSmall",
        },
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

test "a root file without nilo.panic is warned about, with the line to add and the ReleaseFast caveat" {
    const Without = struct {};
    const With = struct {
        pub const panic = 1;
    };
    const line = missingPanic(Without).?;
    try std.testing.expect(std.mem.indexOf(u8, line, "pub const panic = nilo.panic;") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "ReleaseFast") != null);
    try std.testing.expect(missingPanic(With) == null);
}

/// Whether the process is inside a container, from three facts a caller
/// reads once: `/.dockerenv` exists, `/run/.containerenv` exists (Podman), or
/// PID 1's cgroup names a container runtime. A function of the facts so a
/// test can feed it fake ones (ADR 103).
pub fn inContainer(dockerenv: bool, containerenv: bool, cgroup: []const u8) bool {
    if (dockerenv or containerenv) return true;
    const runtimes = [_][]const u8{ "docker", "containerd", "kubepods", "libpod", "lxc" };
    for (runtimes) |name| {
        if (std.mem.indexOf(u8, cgroup, name) != null) return true;
    }
    return false;
}

/// Whether an `Options.address` can only be reached from this machine:
/// `127.x.x.x`, `::1` and `localhost`. A unix socket path is not a network
/// address and is never reported.
pub fn isLoopbackAddress(address: []const u8) bool {
    return std.mem.startsWith(u8, address, "127.") or
        std.mem.eql(u8, address, "::1") or
        std.mem.eql(u8, address, "localhost");
}

/// The warning for a loopback listener inside a container, or null (ADR 103).
/// The default address is loopback because that is the safe one, and inside
/// a container it is a server that is up and unreachable: the published port
/// reaches the container's own interface, not its loopback.
pub fn loopbackInContainer(address: []const u8, in_container: bool) ?[]const u8 {
    if (!in_container or !isLoopbackAddress(address)) return null;
    return "this process is in a container and listens on a loopback address, so nothing " ++
        "outside the container can reach it, published port or not. Listen on every " ++
        "interface with .address = \"0.0.0.0\" (or read the address from config)";
}

/// Read the container facts, Linux only, once at startup. Raw syscalls
/// because `tryListen` has no `Io`, and nothing here survives the call: a
/// stack buffer for the first 4 KiB of the cgroup file.
fn readInContainer() bool {
    if (comptime builtin.os.tag != .linux) return false;
    const linux = std.os.linux;
    const exists = struct {
        fn at(path: [*:0]const u8) bool {
            const r = linux.openat(linux.AT.FDCWD, path, .{ .CLOEXEC = true }, 0);
            if (linux.errno(r) != .SUCCESS) return false;
            _ = linux.close(@intCast(r));
            return true;
        }
    }.at;
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    const r = linux.openat(linux.AT.FDCWD, "/proc/1/cgroup", .{ .CLOEXEC = true }, 0);
    if (linux.errno(r) == .SUCCESS) {
        const got = linux.read(@intCast(r), &buf, buf.len);
        if (linux.errno(got) == .SUCCESS) n = got;
        _ = linux.close(@intCast(r));
    }
    return inContainer(exists("/.dockerenv"), exists("/run/.containerenv"), buf[0..n]);
}

/// Called by `tryListen` with the addresses about to be listened on. One
/// line however many of them are loopback.
pub fn warnLoopbackInContainer(primary: []const u8, also: []const bulkhead.Options.Listener) void {
    var loopback = isLoopbackAddress(primary);
    for (also) |l| loopback = loopback or isLoopbackAddress(l.address);
    if (!loopback) return;
    if (loopbackInContainer("127.0.0.1", readInContainer())) |line| std.log.warn("{s}", .{line});
}

test "a container is told apart by its marker files and by PID 1's cgroup" {
    try std.testing.expect(inContainer(true, false, ""));
    try std.testing.expect(inContainer(false, true, ""));
    try std.testing.expect(inContainer(false, false, "12:cpu:/docker/abc123\n"));
    try std.testing.expect(inContainer(false, false, "0::/kubepods/besteffort/pod1\n"));
    try std.testing.expect(!inContainer(false, false, "0::/init.scope\n"));
}

test "a loopback address in a container is warned about and anything else is not" {
    const line = loopbackInContainer("127.0.0.1", true).?;
    try std.testing.expect(std.mem.indexOf(u8, line, ".address = \"0.0.0.0\"") != null);
    try std.testing.expect(loopbackInContainer("::1", true) != null);
    try std.testing.expect(loopbackInContainer("0.0.0.0", true) == null);
    try std.testing.expect(loopbackInContainer("unix:/run/app.sock", true) == null);
    try std.testing.expect(loopbackInContainer("127.0.0.1", false) == null);
}
