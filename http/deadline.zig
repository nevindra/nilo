//! How long a route gets (ADR 105).
//!
//! ```zig
//! try app.with(nilo.deadline(2000)).get("/report", buildReport);
//! ```
//!
//! `listen()`'s four deadlines bound one operation each — a head, a read of a
//! body, a write, a gap between requests (ADR 022) — and none of them bounds
//! the request. A handler that reads a body slowly, calls two services and
//! writes a large response can be inside every one of them all afternoon.
//!
//! ## What it does and does not do
//!
//! **Every wait nilo owns is cut down to it.** `Deadlines.clamped` is the one
//! place that happens for a read, so a limit armed anywhere — the body, a
//! WebSocket's silence — is whichever of the two comes first. The write has
//! its own rule in `Deadlines.armWrite`, because `listen()` arms it before
//! the route has run: `Ctx.armWriteLimit` re-arms it where the answer is
//! written, and a deadline nearer than `write_timeout_ms` becomes the write's
//! limit. A deadline further off leaves the per-write limit as it is, which
//! stops a client that stops reading and not one that trickles
//! ([ADR 105](../docs/adr/105-a-route-can-say-how-long-it-has.md)).
//!
//! **A handler that is running rather than waiting is not interrupted.** There
//! is no cancellation here and deliberately none: a cancel that fires
//! mid-handler is a cancel every handler, every `nilo.Mutex` and every Service
//! has to survive, and [ADR 082](../docs/adr/082-a-cleanup-path-is-not-cancellable.md)
//! has already had to carve the cleanup path out of cancellation once. A loop
//! doing its own work asks `c.overdue()`.
//!
//! So this catches the two shapes a request actually overruns in — a client
//! that is slow and a response that is large — and hands the third to the
//! handler as a question it can ask. That is less than Fiber's `timeout`
//! middleware, which abandons a goroutine, and it is what a language without
//! a runtime to abandon can honestly offer.

const std = @import("std");

const Ctx = @import("ctx.zig").Ctx;
const fail = @import("fail.zig");
const mw = @import("middleware.zig");

/// The middleware. `ms` is settled while compiling, so the message below is a
/// constant and nothing is formatted per request.
pub fn with(comptime ms: u32) mw.Middleware {
    if (ms == 0) @compileError(
        "nilo: a deadline of 0 milliseconds is not a limit, it is a request that has " ++
            "already run out.\n  Leave the route without a deadline instead.",
    );

    const late = std.fmt.comptimePrint(
        "this request was given {d}ms and took longer",
        .{ms},
    );

    return struct {
        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            c.giveDeadline(ms);

            next.run(c) catch |err| {
                // A handler that failed *because* the clock ran out says so
                // with the status the operator can act on, rather than with
                // whatever the failed read or write happened to raise. Only
                // when nothing has gone out yet: a half-sent response cannot
                // be taken back and turned into a 503.
                if (c.overdue() and c.answered() == null) return fail.status(503, late, .{});
                return err;
            };

            // Finished, but late, and without noticing. Worth a line and not
            // worth an error: the answer is already on the wire and is
            // correct. What is wrong is the route's budget or the work in it,
            // and both are somebody's afternoon rather than this request's.
            if (c.overdue()) sayLate(ms);
        }

        /// `noinline` for the reason `allowance.sayIfEverybodyLooksTheSame` is
        /// ([ADR 062](../docs/adr/062-where-a-connection-waits-is-what-it-costs.md)):
        /// inlined, `std.log.warn`'s format machinery would sit on the frame
        /// of every request this covers, and a suspended fiber holds its stack
        /// at its high-water mark for the life of the connection.
        noinline fn sayLate(budget: u32) void {
            std.log.warn(
                "a handler finished after its {d}ms deadline had already passed. The answer " ++
                    "went out and is correct; what is over budget is the route. A handler that " ++
                    "does its own work between waits can ask `c.overdue()` and stop.",
                .{budget},
            );
        }
    }.run;
}

// ---- tests ----

const testing = std.testing;
const App = @import("app.zig").App;
const bulkhead = @import("bulkhead.zig");
const nilo_testing = @import("testing.zig");

fn holdFor(ms: u64) void {
    const until = bulkhead.monotonicNanos() + ms * std.time.ns_per_ms;
    while (bulkhead.monotonicNanos() < until) {}
}

fn overrunsAndNotices(c: *Ctx) anyerror!void {
    holdFor(30);
    // The shape a handler with a loop of its own is meant to take: ask, and
    // stop. Nothing interrupts it, so nothing else can.
    if (c.overdue()) return fail.status(503, "gave up", .{});
    try c.sendEmpty(200);
}

fn overrunsAndDoesNot(c: *Ctx) anyerror!void {
    holdFor(30);
    try c.sendEmpty(200);
}

fn insideItsBudget(c: *Ctx) anyerror!void {
    try testing.expect(!c.overdue());
    try testing.expect(c.timeLeftMs().? > 0);
    try c.sendEmpty(200);
}

fn hasNoDeadlineAtAll(c: *Ctx) anyerror!void {
    // A handler may ask without knowing whether its route set one.
    try testing.expect(!c.overdue());
    try testing.expect(c.timeLeftMs() == null);
    try c.sendEmpty(200);
}

test "a handler that asks whether it is overdue is told, and its failure is a 503" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.with(with(10)).get("/report", overrunsAndNotices);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    const answer = try client.get(&app, "/report");
    try testing.expectEqual(@as(u16, 503), answer.status);
    // The middleware's own sentence, not the handler's: an overdue request
    // that failed is described by what ran out rather than by what raised.
    try testing.expect(std.mem.indexOf(u8, answer.body, "10ms") != null);
}

test "a handler that overruns without noticing still answers" {
    // The answer is on the wire and is correct; a 503 here would throw away
    // work that is already done. What is wrong is the route's budget, and
    // that is said in the log rather than to the client.
    const noisy = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = noisy;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.with(with(10)).get("/report", overrunsAndDoesNot);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    try testing.expectEqual(@as(u16, 200), (try client.get(&app, "/report")).status);
}

test "a handler inside its budget is not told anything" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.with(with(60_000)).get("/quick", insideItsBudget);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    try testing.expectEqual(@as(u16, 200), (try client.get(&app, "/quick")).status);
}

test "a route with no deadline answers null, so asking is always safe" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/quick", hasNoDeadlineAtAll);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    try testing.expectEqual(@as(u16, 200), (try client.get(&app, "/quick")).status);
}

test "every limit nilo arms is cut down to the deadline, and none is lengthened" {
    // The one place the clamping happens, checked directly: `Deadlines.set`
    // is private, so what is asserted here is what it hands the Engine.
    var caught: bulkhead.Limit = .none;
    const Trap = struct {
        fn limit(target: ?*anyopaque, _: bulkhead.Side, l: bulkhead.Limit) void {
            const into: *bulkhead.Limit = @ptrCast(@alignCast(target.?));
            into.* = l;
        }
        fn timedOut(_: ?*anyopaque) bool {
            return false;
        }
    };
    const vtable: bulkhead.Deadlines.VTable = .{ .limit = Trap.limit, .timedOut = Trap.timedOut };

    const soon = bulkhead.monotonicNanos() + 5 * std.time.ns_per_ms;
    const d: bulkhead.Deadlines = .{
        .target = &caught,
        .vtable = &vtable,
        .body_ms = 30_000,
        .idle_ms = 75_000,
        .until_ns = soon,
    };

    // A per-read limit far past the deadline comes back as the deadline.
    d.armBody();
    try testing.expectEqual(soon, caught.by_ns);

    // And so does "as long as it takes", which is the case a WebSocket and an
    // idle connection take and the one a per-operation limit cannot express.
    d.readForever();
    try testing.expectEqual(soon, caught.by_ns);

    // A limit already shorter than the deadline is left alone. A deadline
    // that lengthened one would be a deadline that loosened the server's own
    // protection against a slow client.
    const sooner: bulkhead.Deadlines = .{
        .target = &caught,
        .vtable = &vtable,
        .body_ms = 1,
        .until_ns = bulkhead.monotonicNanos() + 60 * std.time.ns_per_s,
    };
    sooner.armBody();
    try testing.expect(caught.by_ns < sooner.until_ns);

    // With no deadline the limit passes through as it always did.
    const none: bulkhead.Deadlines = .{ .target = &caught, .vtable = &vtable, .body_ms = 30_000 };
    none.armBody();
    try testing.expectEqual(@as(u32, 30_000), caught.within_ms);
}

// ---- listen()'s default deadline (ADR 105) ----

fn hasTheDefault(c: *Ctx) anyerror!void {
    // What `listen()` gave every request, seen from a route that set none.
    try testing.expect(c.timeLeftMs() != null);
    try testing.expect(c.timeLeftMs().? <= 60_000);
    try c.sendEmpty(200);
}

fn streamsAndLetsGo(c: *Ctx) anyerror!void {
    try testing.expect(c.timeLeftMs() != null);
    var s = try c.stream(200, "text/plain");
    // Taking the connection over drops the default: a stream is meant to
    // outlive a number chosen for the requests that answer and go.
    try testing.expect(c.timeLeftMs() == null);
    try s.writeAll("hello");
    try s.finish();
}

fn streamsAndKeepsItsOwn(c: *Ctx) anyerror!void {
    const before = c.timeLeftMs().?;
    var s = try c.stream(200, "text/plain");
    // A deadline the route asked for by name is kept through the takeover.
    try testing.expect(c.timeLeftMs() != null);
    try testing.expect(c.timeLeftMs().? <= before);
    try s.writeAll("hello");
    try s.finish();
}

test "listen()'s deadline reaches every route, and a route's own replaces it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/plain", hasTheDefault);
    try app.with(with(20)).get("/own", insideItsBudget);
    app.limits.request_deadline_ms = 60_000;

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    try testing.expectEqual(@as(u16, 200), (try client.get(&app, "/plain")).status);
    try testing.expectEqual(@as(u16, 200), (try client.get(&app, "/own")).status);

    // Off, which is the default, is exactly what it was before: null.
    app.limits.request_deadline_ms = 0;
    var none = App.init(testing.allocator);
    defer none.deinit();
    try none.get("/quick", hasNoDeadlineAtAll);
    try testing.expectEqual(@as(u16, 200), (try client.get(&none, "/quick")).status);
}

test "a request that takes the connection over lets go of the default and keeps its own" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/default", streamsAndLetsGo);
    try app.with(with(60_000)).get("/own", streamsAndKeepsItsOwn);
    app.limits.request_deadline_ms = 60_000;

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    try testing.expectEqual(@as(u16, 200), (try client.get(&app, "/default")).status);
    try testing.expectEqual(@as(u16, 200), (try client.get(&app, "/own")).status);
}
