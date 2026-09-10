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
const static_mod = @import("static.zig");
const proxies_mod = @import("proxies.zig");
const openapi = @import("openapi.zig");

const App = app_mod.App;

/// The route already carrying this `operationId`, if one does.
///
/// A function rather than a loop inside `tryRouteNamed` so that the check
/// can be tested without provoking the `std.log.err` registration writes
/// — a logged error is a failed test run, and the noise would sit in
/// `zig build test` forever. This is the shape `router.conflicting`
/// already has, for the same reason (ADR 0149).
pub fn nameTaken(self: *const App, given: []const u8) ?openapi.Operation {
    for (self.operations.items) |existing| {
        const taken = existing.name orelse continue;
        if (std.mem.eql(u8, taken, given)) return existing;
    }
    return null;
}

/// Turn `listen(.{ .trusted_proxies = … })` into the networks `clientIp`
/// compares against, once (ADR 0129).
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
/// than at three in the morning (ADR 0006).
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

/// Work out which middleware wraps each route, once. Called by
/// `listen()`; separate so tests can drive it without a server.
///
/// Doing this here rather than when each route is registered is what
/// makes `use` and `get` order-independent — Fiber's most reported
/// gotcha is middleware registered after a route silently not applying
/// to it (ADR 0009).
pub fn resolveChains(self: *App) !void {
    freeChains(self);
    for (self.router.routes.items) |*r| {
        r.chain = try mw.chainFor(self.gpa, self.scoped.items, self.exemptions.items, self.attached.items, r.method, r.pattern);
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
        chain.* = try mw.chainFor(self.gpa, self.scoped.items, self.exemptions.items, self.attached.items, null, file.url);
        made += 1;
    }
    return chains;
}

/// Write the API description to `w`, with no server and no port
/// ([ADR 0167](../docs/adr/0167-the-document-is-a-build-artefact.md)).
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
    const info: openapi.Info = if (self.docs_options) |opts| .{
        .title = opts.title,
        .version = opts.version,
        .description = opts.description,
    } else .{};
    try openapi.write(w, self.operations.items, info);
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
    // in step (ADR 0167).
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
            "by returning `Status(200, void)` (ADR 0150)",
        .{ written, self.operations.items.len },
    );
}

/// Two lines belong in a nilo root source file, and forgetting either one
/// fails quietly — the sort of quiet that costs an afternoon. Without
/// `std_options_debug_io`, `std.log` writes to stderr the blocking way and
/// parks the whole event loop behind it; without `std_options`, the
/// Engine's own debug lines bury yours. Neither can be set from a library,
/// so the next best thing is to say so once, by name, at startup.
pub fn checkRootWiring() void {
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
    warnIfBuiltDifferently();
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
pub const program_mode: ?std.builtin.OptimizeMode =
    modeFrom(std.log.default_level, std.debug.runtime_safety);

/// The derivation, as a function so that **every arm of it can be run from a
/// suite that only ever builds in two modes**.
///
/// `program_mode` is one value per compilation, so the `ReleaseFast` arm could
/// only ever be *not run* — and that is how it shipped wrong
/// ([ADR 0033](../docs/adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)).
pub fn modeFrom(level: std.log.Level, safety: bool) ?std.builtin.OptimizeMode {
    return switch (level) {
        .debug => .Debug,
        // The level alone cannot tell the three release modes apart, so the
        // safety flag splits the pair off.
        .info => if (safety) .ReleaseSafe else null,
        // No optimize mode produces any other level. A future std that
        // changes this lands here, and null is the answer that warns nobody
        // rather than everybody.
        else => null,
    };
}

/// Nilo built in `Debug` under a `ReleaseFast` program: legal, slow, and
/// silent until now (ADR 0084).
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
        ours == .Debug or ours == .ReleaseSafe;

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
