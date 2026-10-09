//! How much body a route takes (ADR 156).
//!
//! ```zig
//! try app.with(nilo.maxBody(50 << 20)).post("/import", importCsv);
//! ```
//!
//! `listen()`'s `max_body` is one number for every route, and one number is
//! the wrong shape: an import that takes fifty megabytes and a sign-in that
//! takes two hundred bytes do not have the same budget, and a number loose
//! enough for the first is no bound on the second. It is the same argument
//! ADR 105 made about time, and it gets the same answer — a route that wants
//! its own limit says so, through `with`.
//!
//! ## What it bounds
//!
//! Every read into the request arena: `c.body()`, a JSON body, a `Form(T)`,
//! a `Bound(…)` of either, an `Idempotent` route's replay. A `Content-Length`
//! past it is a 413 before a byte is read; a chunked body is counted as it
//! arrives and stopped where it crosses. What it does **not** touch is
//! `c.bodyStream()`, which holds nothing in the arena and carries a
//! `max_bytes` of its own for the same reason.
//!
//! Lowering is as ordinary as raising. A sign-in route under a `listen()`
//! that allows a megabyte for the import beside it can say it takes a
//! kilobyte, and a client posting more is refused before the arena grows.
//!
//! ## A number from configuration
//!
//! A cap is sometimes a fact about the deployment rather than the program:
//! an ingest route whose limit is an environment setting. Hand `maxBody` the
//! address of a `usize` instead of a number, and the limit is read from it on
//! every request that reaches the route, the way `cors.reading` reads its
//! origins (ADR 088):
//!
//! ```zig
//! var ingest_limit: usize = 16 << 20;
//!
//! pub fn main() !void {
//!     ingest_limit = settings.ingest_max_body;
//!     try app.with(nilo.maxBody(&ingest_limit)).post("/v1/logs", ingest);
//!     try app.listen(.{});
//! }
//! ```
//!
//! What it is handed decides when it is read, and nothing else changes: the
//! same field is written before the body is read, with the same 413 past it.

const std = @import("std");

const Ctx = @import("ctx.zig").Ctx;
const mw = @import("middleware.zig");

/// The middleware. `limit` is a number of bytes, settled while compiling, or
/// the address of a `usize` the program fills before `listen()`, read on each
/// request (ADR 156).
///
/// One name for both, because what the argument is already says when it is
/// read: a number is the route's limit, a pointer is where the route's limit
/// lives. `nilo.maxBody(50 << 20)` keeps meaning what it always has.
///
/// What comes back is an `mw.Limited`: the middleware plus the limit it
/// gives, which `use` and `with` take wherever they take a middleware. A gRPC
/// call collects its message before any middleware runs, and the limit it is
/// collected under is read from that registration (ADR 156, ADR 220).
pub fn with(comptime limit: anytype) mw.Limited {
    const Limit = @TypeOf(limit);
    switch (@typeInfo(Limit)) {
        .comptime_int, .int => return .{ .run = fixed(limit), .limit = .{ .value = limit } },
        .pointer => |p| if (p.size == .one and p.child == usize) return .{ .run = reading(limit), .limit = .{ .held = limit } },
        else => {},
    }
    @compileError("nilo: maxBody takes a number of bytes or the address of a usize that holds one, and was handed " ++
        @typeName(Limit) ++ ".\n" ++
        "  `nilo.maxBody(50 << 20)` for a limit known while compiling, or " ++
        "`nilo.maxBody(&limit)`, with `var limit: usize` filled before listen(), for one read from configuration.");
}

/// A limit settled while compiling, so nothing is read or formatted per
/// request: the one thing it does is write a field.
fn fixed(comptime bytes: usize) mw.Middleware {
    if (bytes == 0) @compileError(
        "nilo: a body limit of 0 bytes is not a limit, it is a route that refuses every body.\n" ++
            "  A route that takes no body reads none; leave the middleware off.",
    );

    return struct {
        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            c.giveBodyLimit(bytes);
            return next.run(c);
        }
    }.run;
}

/// A limit read from `held` on each request. `held` is a comptime pointer, so
/// it has to be a variable that outlives the App, a container-level `var`,
/// which is what `cors.reading` asks of its `Origins` for the same reason.
///
/// Read on the request path and written before there is one, with no lock: a
/// program that changes it while the server runs is racing every request in
/// flight, and reloading configuration is a separate feature that does not
/// exist.
///
/// **Zero leaves `listen()`'s `max_body` in force**, and says so once. The
/// compile-time form refuses zero because it is a route that refuses every
/// body, and nothing can be refused while compiling about a number that
/// arrives later. A setting left at zero most often means "no limit", and of
/// the three readings (every body refused, no bound, the server's own bound)
/// only the last fails closed without failing every request.
fn reading(comptime held: *const usize) mw.Middleware {
    return struct {
        var said: std.atomic.Value(bool) = .init(false);

        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            const bytes = held.*;
            if (bytes != 0) c.giveBodyLimit(bytes) else sayItIsZero();
            return next.run(c);
        }

        /// `noinline` for the reason `deadline.sayLate` is (ADR 062): inlined,
        /// `std.log.warn`'s format machinery would sit on the frame of every
        /// request this covers, and a suspended fiber holds its stack at its
        /// high-water mark for the life of the connection.
        noinline fn sayItIsZero() void {
            @branchHint(.cold);
            if (said.load(.monotonic)) return;
            if (said.swap(true, .monotonic)) return;
            std.log.warn(
                "maxBody was handed a limit of 0 bytes, so this route reads under " ++
                    "listen()'s max_body instead. Set the usize before listen(), or take " ++
                    "maxBody off the route if listen()'s number is the one meant.",
                .{},
            );
        }
    }.run;
}

// ---- tests ----

const testing = std.testing;
const App = @import("app.zig").App;
const nilo_testing = @import("testing.zig");

fn echoLength(c: *Ctx) anyerror!void {
    const b = try c.body();
    var buf: [16]u8 = undefined;
    try c.send(200, "text/plain", try std.fmt.bufPrint(&buf, "{d}", .{b.view().len}));
}

test "a route with its own limit takes a body listen() would have refused" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.max_body = 4;
    try app.with(with(64)).post("/wide", echoLength);
    try app.post("/narrow", echoLength);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const twelve = "twelve bytes";
    const wide = try client.post(&app, "/wide", twelve);
    try testing.expectEqual(@as(u16, 200), wide.status);
    try testing.expectEqualStrings("12", wide.body);

    // The neighbour is still held to listen()'s number: the limit is the
    // route's, not the server's.
    const narrow = try client.post(&app, "/narrow", twelve);
    try testing.expectEqual(@as(u16, 413), narrow.status);
}

test "a route can also take less than listen() allows" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.with(with(8)).post("/sign-in", echoLength);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const refused = try client.post(&app, "/sign-in", "sixteen bytes!!!");
    try testing.expectEqual(@as(u16, 413), refused.status);
    const fine = try client.post(&app, "/sign-in", "eight by");
    try testing.expectEqual(@as(u16, 200), fine.status);
}

test "a chunked body is counted against the route's limit as it arrives" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.max_body = 4;
    try app.with(with(16)).post("/wide", echoLength);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const fits = try client.send(&app, "POST /wide HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), fits.status);
    try testing.expectEqualStrings("10", fits.body);

    const over = try client.send(&app, "POST /wide HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "9\r\nnine byte\r\n9\r\nnine byte\r\n0\r\n\r\n");
    try testing.expectEqual(@as(u16, 413), over.status);
}

var test_limit: usize = 0;

test "a limit read from a variable is whatever the program put there before the request" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.max_body = 4;
    try app.with(with(&test_limit)).post("/ingest", echoLength);
    try app.post("/narrow", echoLength);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const twelve = "twelve bytes";

    test_limit = 64;
    const wide = try client.post(&app, "/ingest", twelve);
    try testing.expectEqual(@as(u16, 200), wide.status);
    try testing.expectEqualStrings("12", wide.body);

    // The neighbour is held to listen()'s number, as it is beside the
    // compile-time form.
    const narrow = try client.post(&app, "/narrow", twelve);
    try testing.expectEqual(@as(u16, 413), narrow.status);

    // Read on each request, not taken when the route was added: the same
    // route and the same body, under a smaller number.
    test_limit = 8;
    const lowered = try client.post(&app, "/ingest", twelve);
    try testing.expectEqual(@as(u16, 413), lowered.status);
}

var test_zero_limit: usize = 0;

test "a limit read as zero leaves listen()'s number in force rather than refusing every body" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.max_body = 8;
    try app.with(with(&test_zero_limit)).post("/ingest", echoLength);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const fits = try client.post(&app, "/ingest", "eight by");
    try testing.expectEqual(@as(u16, 200), fits.status);
    const over = try client.post(&app, "/ingest", "twelve bytes");
    try testing.expectEqual(@as(u16, 413), over.status);
}

var test_chunked_limit: usize = 16;

test "a chunked body is counted as it arrives against a limit read from a variable" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.max_body = 4;
    try app.with(with(&test_chunked_limit)).post("/ingest", echoLength);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const fits = try client.send(&app, "POST /ingest HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), fits.status);
    try testing.expectEqualStrings("10", fits.body);

    const over = try client.send(&app, "POST /ingest HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "9\r\nnine byte\r\n9\r\nnine byte\r\n0\r\n\r\n");
    try testing.expectEqual(@as(u16, 413), over.status);
}
