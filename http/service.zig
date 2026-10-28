//! Services — long-lived things registered once when the App is built (a
//! database connection, config, a logger), then asked for by handlers
//! according to their type.
//!
//! ```zig
//! try app.provide(&db);                // once, while assembling the App
//! fn getUser(db: *Db, id: u32) !User   // asked for by argument type
//! ```
//!
//! The registry is a runtime one, keyed by type name. ADR 005 explains
//! why: `App` stays one ordinary type, and a handler asking for a service
//! that was never registered is caught by `listen()` — before a single
//! request is served, rather than at three in the morning.

const std = @import("std");
const naming = @import("names.zig");
const fail = @import("fail.zig");
const metric_types = @import("metric_types.zig");

const Limits = @import("nilo_core").Limits;
const AnyScope = @import("nilo_core").AnyScope;

/// What a handler needs from the registry. Computed at compile time by the
/// typed engine, then checked once at startup.
pub const Requirement = struct {
    type_name: []const u8,
    /// The handler asked for a mutable pointer (`*Db`, not `*const Db`).
    needs_mutable: bool,
    /// The route that needs it, so the error message is actionable.
    route: []const u8,
};

/// The requirement implied by a handler argument's pointer type.
pub fn requirementFor(comptime P: type, comptime route: []const u8) Requirement {
    const info = @typeInfo(P).pointer;
    return .{
        .type_name = @typeName(info.child),
        .needs_mutable = !info.attrs.@"const",
        .route = route,
    };
}

/// Fetch the service `P` for the thing that asked for it, or answer 500
/// naming it. The one place a typed handler, a resolver's caller and a typed
/// middleware turn "never registered" into an answer, so all three say the
/// same sentence (ADR 005, ADR 008). `needer` completes "and ___ needs it":
/// `route "/users"`, `the middleware taking (*Keys)`.
///
/// **Logged as well as answered** (ADR 180). `listen()` refuses to open the
/// socket over a missing service and names the type and who needs it, so a
/// server never reaches here; but `testing.Client` does not call `listen()`,
/// and a test used to get a bare 500 with nothing anywhere naming the cause.
/// A warning and not an error, because `std.log.err` fails the test runner
/// and this fires in a test by design.
pub fn required(comptime P: type, comptime needer: []const u8, services: *const Registry) !P {
    return services.get(P) orelse {
        std.log.warn(
            "service {s} was never registered, and {s} needs it. " ++
                "`app.listen()` refuses to start over this and says what needs it; " ++
                "a test driving the App itself does not, so here it is. " ++
                "Call app.provide() before serving.",
            .{ @typeName(P), needer },
        );
        return fail.internal(
            "service {s} was never registered; call app.provide() before app.listen()",
            .{@typeName(P)},
        );
    };
}

pub const Registry = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        type_name: []const u8,
        /// The same type as the reader's own import line spells it, for the
        /// health page (ADR 154). `type_name` is what the lookup compares.
        name: []const u8,
        ptr: *anyopaque,
        is_const: bool,
        /// Set only for a service that declared `nilo_start`. Null is the
        /// ordinary case and costs one branch at startup, never per
        /// request.
        start: ?*const fn (*anyopaque, std.Io, Limits) anyerror!void = null,
        /// Set only for a service that declared `nilo_stop`. The mirror of
        /// `start`, and the reason it exists is that a service which put
        /// work on the Engine's loop has to take it off again before the
        /// loop is torn down (ADR 121).
        stop: ?*const fn (*anyopaque) void = null,
        /// Set only for a service that declared `nilo_ready`. Asked by the
        /// health route and by nothing else, so a service with none costs
        /// one null test per probe and nothing per request (ADR 154).
        ready: ?*const fn (*anyopaque, *AnyScope) ?[]const u8 = null,
        /// Set only for a service that declared `nilo_check`. Run once, after
        /// the work `app.before` registered and before the first request,
        /// which is where a check against what that work made belongs
        /// (ADR 180). Null is the ordinary case and costs one branch at boot.
        check: ?*const fn (*anyopaque, std.Io) anyerror!void = null,
        /// Set only for a service whose type holds a `nilo.Counter`,
        /// `nilo.Gauge` or `nilo.Histogram` field, or declares
        /// `nilo_metrics`. A table built while compiling and shared by every
        /// service of the type; read by a scrape and by `listen()`'s check,
        /// never by a request, so a service with none costs a null test per
        /// scrape and nothing else (ADR 079).
        metrics: ?*const metric_types.Set = null,
    };

    /// The `nilo_start` hook, with the type erased so the registry can hold
    /// it beside every other service.
    ///
    /// A service that needs the event loop cannot be built before
    /// `listen()`, because the loop does not exist until then — and a
    /// connection pool dialled without one blocks the thread every request
    /// on it shares (ADR 013). Declaring `nilo_start` says "finish
    /// building me once there is a loop", and `listen()` calls it before
    /// accepting anything (ADR 037).
    /// **Two arities, and the older one is not deprecated.** A Service that
    /// only wants the loop writes `nilo_start(self, io)` and is untouched by
    /// ADR 056; one that also wants to bound an outbound call writes
    /// `nilo_start(self, io, limits)`. Both erase to the same three-argument
    /// pointer, so the registry holds one kind of thing and the branch is a
    /// `comptime` one paid once per service type.
    ///
    /// Widening every hook to three parameters instead would have been one
    /// line in `sql/db.zig` and a break for every Service written outside this
    /// repository, for a parameter most of them will not use.
    fn startHook(comptime T: type) ?*const fn (*anyopaque, std.Io, Limits) anyerror!void {
        if (!@hasDecl(T, "nilo_start")) return null;

        const params = @typeInfo(@TypeOf(T.nilo_start)).@"fn".param_types;
        if (params.len != 2 and params.len != 3) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_start takes " ++
                std.fmt.comptimePrint("{d}", .{params.len}) ++
                " parameters, and it has to take 2 or 3.\n" ++
                "  fn nilo_start(self: *" ++ naming.of(T) ++ ", io: std.Io) !void\n" ++
                "  fn nilo_start(self: *" ++ naming.of(T) ++ ", io: std.Io, limits: nilo_core.Limits) !void\n" ++
                "  The second form is for a service that bounds an outbound call with a deadline.",
        );

        return &struct {
            fn call(erased: *anyopaque, io: std.Io, limits: Limits) anyerror!void {
                const self: *T = @ptrCast(@alignCast(erased));
                if (params.len == 2) return T.nilo_start(self, io);
                return T.nilo_start(self, io, limits);
            }
        }.call;
    }

    /// The `nilo_stop` hook, erased the way `nilo_start` is.
    ///
    /// **One arity and no error.** A stop hook runs from a `defer` on the
    /// way out of `listen()`, where there is nobody left to hand a failure
    /// to and nothing useful to do with one — a service that hits trouble
    /// putting something down logs it and carries on, which is what every
    /// `deinit` in this repository already does. And it takes no `std.Io`:
    /// the loop it was started on is the loop it is still on, and a service
    /// that needed to remember it kept it in `nilo_start` (ADR 121).
    ///
    /// A service with no `nilo_stop` is the ordinary case and costs one
    /// branch, once, on the way out.
    fn stopHook(comptime T: type) ?*const fn (*anyopaque) void {
        if (!@hasDecl(T, "nilo_stop")) return null;

        const info = @typeInfo(@TypeOf(T.nilo_stop));
        if (info != .@"fn") @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_stop is not a function, and it has to be one.\n" ++
                "  fn nilo_stop(self: *" ++ naming.of(T) ++ ") void",
        );
        const f = info.@"fn";
        if (f.param_types.len != 1) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_stop takes " ++
                std.fmt.comptimePrint("{d}", .{f.param_types.len}) ++
                " parameters, and it has to take 1.\n" ++
                "  fn nilo_stop(self: *" ++ naming.of(T) ++ ") void\n" ++
                "  It runs on the way out of `listen()`, so there is nothing else to hand it.",
        );
        if (f.param_types[0] != *T) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_stop takes " ++
                naming.of(f.param_types[0] orelse anyopaque) ++
                ", and it has to take `*" ++ naming.of(T) ++ "`.\n" ++
                "  A stop hook puts something down, so it needs the service it is putting down.",
        );
        // The type is deliberately not printed. An inferred error union has
        // no readable name — `names.of` renders it as the `@typeInfo` chain
        // that produced it — and naming it adds nothing the reader needs.
        if (f.return_type != void) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_stop returns something other than `void`, and " ++
                "a stop hook has to return `void`.\n" ++
                "  fn nilo_stop(self: *" ++ naming.of(T) ++ ") void\n" ++
                "  It runs from a `defer` on the way out of `listen()`, where there is nobody " ++
                "left to hand a failure to. Log what went wrong and carry on.",
        );

        return &struct {
            fn call(erased: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(erased));
                T.nilo_stop(self);
            }
        }.call;
    }

    /// The `nilo_ready` hook, erased the way `nilo_start` is
    /// ([ADR 154](../docs/adr/154-a-health-route-asks-the-services.md)).
    ///
    /// **Null is ready, and a string is why not.** A bool would have made the
    /// 503 a list of type names, and what an operator wants at three in the
    /// morning is "the database is not answering" beside the name. The
    /// string is a literal or lives as long as the Scope it was handed —
    /// `scope.arena()` is there for one with a number in it.
    ///
    /// **A Scope and not an Io**, because the honest probe is a statement —
    /// `SELECT 1` — and a statement wants somewhere to put its answer. The
    /// hook takes the erased one so a Service can keep naming `anytype`
    /// everywhere else and this registry can hold one kind of pointer
    /// (ADR 134).
    fn readyHook(comptime T: type) ?*const fn (*anyopaque, *AnyScope) ?[]const u8 {
        if (!@hasDecl(T, "nilo_ready")) return null;

        const info = @typeInfo(@TypeOf(T.nilo_ready));
        if (info != .@"fn") @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_ready is not a function, and it has to be one.\n" ++
                "  fn nilo_ready(self: *" ++ naming.of(T) ++ ", scope: *nilo_core.AnyScope) ?[]const u8",
        );
        const f = info.@"fn";
        const shape = comptime "\n  fn nilo_ready(self: *" ++ naming.of(T) ++ ", scope: *nilo_core.AnyScope) ?[]const u8\n" ++
            "  Answer null when the service can do its job, and a sentence saying why when it cannot.";
        if (f.param_types.len != 2) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_ready takes " ++
                std.fmt.comptimePrint("{d}", .{f.param_types.len}) ++
                " parameters, and it has to take 2." ++ shape,
        );
        if (f.param_types[0] != *T and f.param_types[0] != *const T) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_ready takes " ++
                naming.of(f.param_types[0] orelse anyopaque) ++
                " first, and it has to take `*" ++ naming.of(T) ++ "`." ++ shape,
        );
        if (f.param_types[1] != *AnyScope) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_ready takes " ++
                naming.of(f.param_types[1] orelse anyopaque) ++
                " second, and it has to take `*nilo_core.AnyScope`." ++ shape,
        );
        if (f.return_type != ?[]const u8) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_ready returns something other than `?[]const u8`, " ++
                "and a readiness hook answers null or the reason it is not ready." ++ shape,
        );

        return &struct {
            fn call(erased: *anyopaque, scope: *AnyScope) ?[]const u8 {
                const self: *T = @ptrCast(@alignCast(erased));
                return T.nilo_ready(self, scope);
            }
        }.call;
    }

    /// The `nilo_check` hook, erased the way `nilo_start` is
    /// ([ADR 180](../docs/adr/180-work-that-needs-the-services-runs-on-their-loop.md)).
    ///
    /// **After `before`, not inside `nilo_start`.** A `Db` checks its Rows
    /// against their tables at boot, and the tables are made by the work
    /// `app.before` registered (`createMissing`, a migration), which runs
    /// after every `nilo_start`. Checked from `nilo_start`, a first boot on
    /// an empty file refused to start over three tables the next line would
    /// have created. So a service that has something to verify once the boot
    /// work is done declares this, and the App runs it in that gap.
    ///
    /// One arity: `self` and the `Io` the service was started on, which is
    /// what a check that makes a Scope to run a statement in needs. It may
    /// fail, and a failure is the boot's: a schema that disagrees with its
    /// Rows is a server that must not take a request.
    fn checkHook(comptime T: type) ?*const fn (*anyopaque, std.Io) anyerror!void {
        if (!@hasDecl(T, "nilo_check")) return null;

        const info = @typeInfo(@TypeOf(T.nilo_check));
        const shape = comptime "\n  fn nilo_check(self: *" ++ naming.of(T) ++ ", io: std.Io) !void\n" ++
            "  It runs once, after the work `app.before` registered and before the first request.";
        if (info != .@"fn") @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_check is not a function, and it has to be one." ++ shape,
        );
        const f = info.@"fn";
        if (f.param_types.len != 2) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_check takes " ++
                std.fmt.comptimePrint("{d}", .{f.param_types.len}) ++
                " parameters, and it has to take 2." ++ shape,
        );
        if (f.param_types[0] != *T) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_check takes " ++
                naming.of(f.param_types[0] orelse anyopaque) ++
                " first, and it has to take `*" ++ naming.of(T) ++ "`." ++ shape,
        );
        if (f.param_types[1] != std.Io) @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_check takes " ++
                naming.of(f.param_types[1] orelse anyopaque) ++
                " second, and it has to take `std.Io`." ++ shape,
        );

        return &struct {
            fn call(erased: *anyopaque, io: std.Io) anyerror!void {
                const self: *T = @ptrCast(@alignCast(erased));
                return T.nilo_check(self, io);
            }
        }.call;
    }

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.gpa);
    }

    /// Register a service. `ptr` must outlive the App — this registry only
    /// stores the pointer, it copies nothing.
    ///
    /// Two services of the same type (two databases, say) have to be told
    /// apart with named wrappers; the second one is rejected here
    /// (ADR 002).
    pub fn add(self: *Registry, ptr: anytype) !void {
        const P = @TypeOf(ptr);
        const info = switch (@typeInfo(P)) {
            .pointer => |p| p,
            else => @compileError(
                "nilo: app.provide() wants a pointer to a service, not " ++ naming.of(P) ++
                    ".\n  Services outlive the App, so what gets registered is a pointer to one: " ++
                    "`app.provide(&db)`.",
            ),
        };
        if (info.size != .one) @compileError(
            "nilo: app.provide() wants a pointer to a single value, not " ++ naming.of(P) ++ ".",
        );

        if (info.attrs.@"const" and @hasDecl(info.child, "nilo_start")) @compileError(
            "nilo: " ++ naming.of(info.child) ++ " has a `nilo_start`, so it finishes building " ++
                "itself when the server starts — and it was provided as `*const`, which " ++
                "leaves it nothing to build into.\n  Provide it as `app.provide(&thing)` " ++
                "with a `var`.",
        );

        const type_name = @typeName(info.child);
        for (self.entries.items) |e| {
            if (sameName(e.type_name, type_name)) return error.ServiceAlreadyRegistered;
        }
        try self.entries.append(self.gpa, .{
            .type_name = type_name,
            .name = comptime naming.of(info.child),
            .ptr = @ptrCast(@constCast(ptr)),
            .is_const = info.attrs.@"const",
            .start = startHook(info.child),
            .stop = stopHook(info.child),
            .ready = readyHook(info.child),
            .check = checkHook(info.child),
            .metrics = comptime metric_types.setOf(info.child),
        });
    }

    /// The sentence for `error.ServiceAlreadyRegistered`: which type, and the
    /// way round it (ADR 002). A function of the type so a test can read it
    /// without provoking the `std.log.err` that `App.provide` prints, which
    /// would fail the run.
    pub fn duplicateMessage(comptime T: type) []const u8 {
        const n = comptime naming.of(T);
        return "a second " ++ n ++ " was provided, and a service is found by its type, so there " ++
            "can be only one " ++ n ++ ". Give each instance a type of its own: " ++
            "`const Replica = struct { db: " ++ n ++ " };` and take `*Replica` in the handler (ADR 002).";
    }

    /// Run every service's `nilo_check`, in the order they were provided.
    /// Once, after the work `before` registered has finished, and before
    /// anything is accepted (ADR 180). The first failure stops the rest and
    /// the boot with it, for the reason `start`'s does.
    pub fn check(self: *const Registry, io: std.Io) !void {
        for (self.entries.items) |e| {
            if (e.check) |hook| try hook(e.ptr, io);
        }
    }

    /// Finish building every service that asked to be finished, in the
    /// order they were provided. Run once, from inside `listen()`, before
    /// the first connection is accepted (ADR 037).
    ///
    /// The first failure stops the rest: a server whose database is
    /// unreachable should not go on to open anything else and then answer
    /// requests it cannot serve.
    pub fn start(self: *const Registry, io: std.Io, limits: Limits) !void {
        for (self.entries.items) |e| {
            if (e.start) |hook| try hook(e.ptr, io, limits);
        }
    }

    /// How many services declared `nilo_start` — which is how many kept the
    /// `Io` they were started on as their loop, and therefore how many are
    /// wrong once a second loop appears (ADR 180).
    pub fn startedCount(self: *const Registry) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (e.start != null) n += 1;
        }
        return n;
    }

    /// Those services by name, for the line that refuses a `listen()` after
    /// `start(io)`. A formatter rather than a string so nothing is allocated
    /// on a path that is about to stop the process.
    pub fn startedNames(self: *const Registry) StartedNames {
        return .{ .entries = self.entries.items };
    }

    pub const StartedNames = struct {
        entries: []const Entry,

        pub fn format(self: StartedNames, w: *std.Io.Writer) std.Io.Writer.Error!void {
            var first = true;
            for (self.entries) |e| {
                if (e.start == null) continue;
                if (!first) try w.writeAll(", ");
                try w.writeAll(e.name);
                first = false;
            }
        }
    };

    /// Let every service that asked put down what it is holding, **in the
    /// reverse of the order they were provided** — the ordinary unwinding
    /// order, so a service built on top of another is taken down first.
    ///
    /// Run from inside `listen()`, after the last connection has been cut
    /// off and before the Engine's loop is torn down (ADR 121). It cannot
    /// fail and it cannot be skipped: a service that put work on the loop
    /// and did not take it off is a loop that cannot be deinitialised, and
    /// zio says so with an assert on the way out.
    ///
    /// **It also runs when the server never started.** `start` stops at the
    /// first failure, so the services before that one are up and holding
    /// things, and "the server did not start" has to mean they let go.
    /// A hook is therefore written to survive being called on a service
    /// whose `nilo_start` never ran.
    pub fn stopAll(self: *const Registry) void {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (e.stop) |hook| hook(e.ptr);
        }
    }

    /// What a service is called on the metrics page: the last name of its
    /// type, `Shop` for `shop.Shop`, without the arguments of a generic one.
    /// The label that tells two services' samples of one family apart.
    pub fn labelName(full: []const u8) []const u8 {
        var from: usize = 0;
        var to: usize = full.len;
        for (full, 0..) |ch, i| {
            if (ch == '(') {
                to = i;
                break;
            }
            if (ch == '.') from = i + 1;
        }
        return full[from..to];
    }

    /// Whether any of `entries` holds a metric family called `name`.
    fn familyHeldBy(entries: []const Entry, name: []const u8) bool {
        for (entries) |e| {
            const set = e.metrics orelse continue;
            for (set.families) |f| {
                if (std.mem.eql(u8, f.name, name)) return true;
            }
        }
        return false;
    }

    /// Print the metrics of every service that has any, onto the page.
    ///
    /// **A family is printed once and whole.** Two services can hold one name
    /// (two stores, each with its own hit count), and Prometheus rejects a
    /// page where a `# TYPE` appears twice or a family's samples are split by
    /// another's. So for each family, in the order services were provided, the
    /// first service to hold it prints the header and then every service from
    /// there on prints its samples under it. That is a walk of services times
    /// families squared per scrape, over a handful of each, and no
    /// allocation: collecting the names first would need somewhere to put
    /// them (ADR 079).
    pub fn writeMetrics(self: *const Registry, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const items = self.entries.items;
        for (items, 0..) |e, i| {
            const set = e.metrics orelse continue;
            for (set.families) |f| {
                if (familyHeldBy(items[0..i], f.name)) continue;
                if (f.help.len > 0) {
                    try w.print("# HELP {s} ", .{f.name});
                    for (f.help) |ch| switch (ch) {
                        '\\' => try w.writeAll("\\\\"),
                        '\n' => try w.writeAll("\\n"),
                        else => try w.writeByte(ch),
                    };
                    try w.writeByte('\n');
                }
                try w.print("# TYPE {s} {s}\n", .{ f.name, @tagName(f.kind) });
                for (items[i..]) |other| {
                    const theirs = other.metrics orelse continue;
                    for (theirs.families) |g| {
                        if (!std.mem.eql(u8, g.name, f.name)) continue;
                        try g.samples(other.ptr, w, labelName(other.name));
                    }
                }
            }
        }
    }

    /// Why the services' metrics cannot go on one page, or null. Run by
    /// `listen()` before the port is taken (ADR 079), since each of these is a
    /// page Prometheus rejects whole or a scrape nobody sized.
    pub fn metricsProblem(self: *const Registry) ?MetricsProblem {
        const items = self.entries.items;
        var total: usize = 0;
        var biggest: []const u8 = "";
        var biggest_series: usize = 0;
        for (items, 0..) |e, i| {
            const set = e.metrics orelse continue;
            var mine: usize = 0;
            for (set.families, 0..) |f, j| {
                mine += f.series;
                // The same name twice in one service.
                for (set.families[0..j]) |earlier| {
                    if (std.mem.eql(u8, earlier.name, f.name)) return .{ .repeated = .{ .service = e.name, .name = f.name } };
                }
                // The same name in another service: one family only if it is
                // the same kind with the same label keys, and only if the
                // samples can be told apart by `service`.
                for (items[0..i]) |other| {
                    const theirs = other.metrics orelse continue;
                    for (theirs.families) |g| {
                        if (!std.mem.eql(u8, g.name, f.name)) continue;
                        if (!f.sameShape(g)) return .{ .shape = .{ .name = f.name, .first = other.name, .second = e.name } };
                        if (std.mem.eql(u8, labelName(other.name), labelName(e.name))) return .{
                            .same_label = .{ .name = f.name, .first = other.name, .second = e.name },
                        };
                    }
                }
            }
            total += mine;
            if (mine > biggest_series) {
                biggest_series = mine;
                biggest = e.name;
            }
        }
        if (total > metric_types.max_series) return .{ .too_many = .{
            .total = total,
            .biggest = biggest,
            .biggest_series = biggest_series,
        } };
        return null;
    }

    pub const MetricsProblem = union(enum) {
        repeated: struct { service: []const u8, name: []const u8 },
        shape: struct { name: []const u8, first: []const u8, second: []const u8 },
        same_label: struct { name: []const u8, first: []const u8, second: []const u8 },
        too_many: struct { total: usize, biggest: []const u8, biggest_series: usize },

        pub fn format(self: MetricsProblem, w: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self) {
                .repeated => |p| try w.print(
                    "{s} holds two metrics called \"{s}\", and one family cannot have two sets of samples. " ++
                        "Rename one: a metric is named by its field, or by the first string of its `nilo_metrics` row.",
                    .{ p.service, p.name },
                ),
                .shape => |p| try w.print(
                    "the metric \"{s}\" is held by {s} and by {s} as two different things (a counter and a " ++
                        "gauge, or different label keys), and Prometheus rejects a page where one name is " ++
                        "two families. Rename one of them.",
                    .{ p.name, p.first, p.second },
                ),
                .same_label => |p| try w.print(
                    "the metric \"{s}\" is held by {s} and by {s}, whose type names both end in \"{s}\", so " ++
                        "the `service` label cannot tell their samples apart and the page would carry the " ++
                        "same series twice. Give one of the types a different name.",
                    .{ p.name, p.first, p.second, labelName(p.first) },
                ),
                .too_many => |p| try w.print(
                    "the services' metrics make {d} series, and a page carries at most {d}; the biggest " ++
                        "contributor is {s} with {d}. Every value of every label is a series Prometheus stores " ++
                        "and each scrape reads: drop a label, or bucket it into a smaller enum (ADR 079).",
                    .{ p.total, metric_types.max_series, p.biggest, p.biggest_series },
                ),
            }
        }
    };

    /// Fetch the service of type `P` (a pointer type), or null if it was
    /// never registered — or if it was registered as `*const` while the
    /// handler asked to be able to mutate it.
    pub fn get(self: *const Registry, comptime P: type) ?P {
        const info = @typeInfo(P).pointer;
        const type_name = @typeName(info.child);
        for (self.entries.items) |e| {
            if (!sameName(e.type_name, type_name)) continue;
            if (e.is_const and !info.attrs.@"const") return null;
            return @ptrCast(@alignCast(e.ptr));
        }
        return null;
    }

    pub fn has(self: *const Registry, req: Requirement) bool {
        for (self.entries.items) |e| {
            if (!sameName(e.type_name, req.type_name)) continue;
            return !(e.is_const and req.needs_mutable);
        }
        return false;
    }

    /// Type names from `@typeName` are normally the very same literal, so
    /// compare the pointers first; comparing contents is just a safety net.
    fn sameName(a: []const u8, b: []const u8) bool {
        return a.ptr == b.ptr or std.mem.eql(u8, a, b);
    }
};

// ---- tests ----

const testing = std.testing;

const Db = struct { n: u32 = 0 };
const Config = struct { debug: bool = false };

test "provide, then fetch by type" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    var db = Db{ .n = 7 };
    var cfg = Config{ .debug = true };
    try r.add(&db);
    try r.add(&cfg);

    try testing.expectEqual(@as(u32, 7), r.get(*Db).?.n);
    try testing.expect(r.get(*Config).?.debug);

    // Mutated through the service, visible in the original.
    r.get(*Db).?.n = 9;
    try testing.expectEqual(@as(u32, 9), db.n);
}

test "a type that was never registered comes back null" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    var db = Db{};
    try r.add(&db);
    try testing.expect(r.get(*Config) == null);
}

test "two services of the same type are rejected" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    var one = Db{};
    var two = Db{};
    try r.add(&one);
    try testing.expectError(error.ServiceAlreadyRegistered, r.add(&two));
}

test "the refusal of a second service names the type and the wrapper that fixes it" {
    const msg = Registry.duplicateMessage(Db);
    try testing.expect(std.mem.indexOf(u8, msg, "a second ") != null);
    try testing.expect(std.mem.indexOf(u8, msg, comptime naming.of(Db)) != null);
    try testing.expect(std.mem.indexOf(u8, msg, "struct { db: ") != null);
}

test "registered const, asked for mutable, rejected" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    const cfg = Config{ .debug = true };
    try r.add(&cfg);

    try testing.expect(r.get(*const Config) != null);
    try testing.expect(r.get(*Config) == null);
    try testing.expect(r.has(requirementFor(*const Config, "/x")));
    try testing.expect(!r.has(requirementFor(*Config, "/x")));
}

test "has answers the requirements computed at compile time" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    var db = Db{};
    try r.add(&db);

    try testing.expect(r.has(requirementFor(*Db, "/users/:id")));
    try testing.expect(r.has(requirementFor(*const Db, "/users/:id")));
    try testing.expect(!r.has(requirementFor(*Config, "/users/:id")));
}

/// A service that records being stopped, and the order it happened in.
var stop_order: [4]u8 = @splat(0);
var stopped_count: usize = 0;

fn Stoppable(comptime mark: u8) type {
    return struct {
        const Self = @This();
        stopped: bool = false,

        pub fn nilo_stop(self: *Self) void {
            self.stopped = true;
            stop_order[stopped_count] = mark;
            stopped_count += 1;
        }
    };
}

test "a service that says how to stop is stopped, and one that does not is left alone" {
    stopped_count = 0;
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    var one = Stoppable('a'){};
    var plain = Db{};
    try r.add(&one);
    try r.add(&plain);

    r.stopAll();
    try testing.expect(one.stopped);
    try testing.expectEqual(@as(usize, 1), stopped_count);
}

test "services are stopped in the reverse of the order they were provided" {
    stopped_count = 0;
    stop_order = @splat(0);
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    var first = Stoppable('1'){};
    var second = Stoppable('2'){};
    var third = Stoppable('3'){};
    try r.add(&first);
    try r.add(&second);
    try r.add(&third);

    // The ordinary unwinding order, so a service built on top of another is
    // put down before the one underneath it (ADR 121).
    r.stopAll();
    try testing.expectEqual(@as(usize, 3), stopped_count);
    try testing.expectEqualSlices(u8, "321", stop_order[0..3]);
}

test "a service is stopped even though it never started" {
    stopped_count = 0;
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    // `start` stops at the first failure, so a service registered before the
    // one that refused the boot is up and holding something. Nothing here
    // ever calls `start`, which is that case.
    var never = Stoppable('x'){};
    try r.add(&never);

    r.stopAll();
    try testing.expect(never.stopped);
}

// ---- metrics a service holds (ADR 079) ----

const mt = @import("metric_types.zig");

/// Types that stand in for a module's: a table of std types, as `nilo_cache`
/// declares one without naming this framework.
const Hot = struct {
    n: u64 = 0,
    pub const nilo_metrics = .{
        .{ "nilo_store_hits_total", .counter, "Lookups that found a value.", hitsOf },
    };
    fn hitsOf(self: *const Hot) u64 {
        return self.n;
    }
};
const Cold = struct {
    n: u64 = 0,
    pub const nilo_metrics = .{
        .{ "nilo_store_hits_total", .counter, "Lookups that found a value.", hitsOf },
    };
    fn hitsOf(self: *const Cold) u64 {
        return self.n;
    }
};
/// Two types a reader could well write in two files, both called `Store`.
const north = struct {
    const Store = struct {
        pub const nilo_metrics = .{.{ "nilo_store_hits_total", .counter, "Lookups that found a value.", hitsOf }};
        fn hitsOf(_: *const Store) u64 {
            return 0;
        }
    };
};
const south = struct {
    const Store = struct {
        pub const nilo_metrics = .{.{ "nilo_store_hits_total", .counter, "Lookups that found a value.", hitsOf }};
        fn hitsOf(_: *const Store) u64 {
            return 0;
        }
    };
};

const Orders = enum { pending, paid };
const Shop = struct {
    orders_total: mt.Counter(Orders) = .{},
    pub const nilo_help = .{ .orders_total = "Orders." };
};
const Other = struct {
    orders_total: mt.Gauge(Orders) = .{},
};

test "a service that holds no metric has no set, and prints nothing" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    var db = Db{};
    try r.add(&db);
    try testing.expect(r.entries.items[0].metrics == null);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try r.writeMetrics(&out.writer);
    try testing.expectEqualStrings("", out.written());
    try testing.expect(r.metricsProblem() == null);
}

test "two services holding one family print its header once and its samples together" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    var a = Hot{ .n = 3 };
    var shop = Shop{};
    var b = Cold{ .n = 5 };
    shop.orders_total.inc(.paid);
    try r.add(&a);
    try r.add(&shop);
    try r.add(&b);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try r.writeMetrics(&out.writer);
    // Both stores under one header, though another service sits between them
    // in the order they were provided; each sample says whose it is.
    try testing.expectEqualStrings(
        "# HELP nilo_store_hits_total Lookups that found a value.\n" ++
            "# TYPE nilo_store_hits_total counter\n" ++
            "nilo_store_hits_total{service=\"Hot\"} 3\n" ++
            "nilo_store_hits_total{service=\"Cold\"} 5\n" ++
            "# HELP orders_total Orders.\n" ++
            "# TYPE orders_total counter\n" ++
            "orders_total{service=\"Shop\",orders=\"pending\"} 0\n" ++
            "orders_total{service=\"Shop\",orders=\"paid\"} 1\n",
        out.written(),
    );
}

test "two services whose names end alike cannot share a family, because their samples would collide" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    var a = north.Store{};
    var b = south.Store{};
    try r.add(&a);
    try r.add(&b);
    const problem = r.metricsProblem().?;
    try testing.expect(problem == .same_label);
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try problem.format(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "cannot tell their samples apart") != null);
}

test "one name held as a counter and as a gauge is refused" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    var shop = Shop{};
    var other = Other{};
    try r.add(&shop);
    try r.add(&other);
    const problem = r.metricsProblem().?;
    try testing.expect(problem == .shape);
    try testing.expectEqualStrings("orders_total", problem.shape.name);
}

test "a page over the series ceiling is refused, naming the biggest service" {
    const Wide = enum { a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p };
    const Pair = struct { x: Wide, y: Wide };
    const Big = struct {
        a_total: mt.Counter(Pair) = .{},
        b_total: mt.Counter(Pair) = .{},
        c_total: mt.Counter(Pair) = .{},
        d_total: mt.Counter(Pair) = .{},
        e_total: mt.Counter(Pair) = .{},
    };
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    var big = Big{};
    var shop = Shop{};
    try r.add(&shop);
    try r.add(&big);
    const problem = r.metricsProblem().?;
    try testing.expect(problem == .too_many);
    try testing.expectEqual(@as(usize, 5 * 256 + 2), problem.too_many.total);
    try testing.expectEqual(@as(usize, 5 * 256), problem.too_many.biggest_series);
}

test "the label of a service is the last name of its type, without a generic's arguments" {
    try testing.expectEqualStrings("Shop", Registry.labelName("shop.Shop"));
    try testing.expectEqualStrings("Shop", Registry.labelName("Shop"));
    try testing.expectEqualStrings("Cached", Registry.labelName("nilo.Cached(a.b.Pages, …)"));
}
