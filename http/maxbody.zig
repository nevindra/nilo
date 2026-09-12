//! How much body a route takes (ADR 0194).
//!
//! ```zig
//! try app.with(nilo.maxBody(50 << 20)).post("/import", importCsv);
//! ```
//!
//! `listen()`'s `max_body` is one number for every route, and one number is
//! the wrong shape: an import that takes fifty megabytes and a sign-in that
//! takes two hundred bytes do not have the same budget, and a number loose
//! enough for the first is no bound on the second. It is the same argument
//! ADR 0133 made about time, and it gets the same answer — a route that wants
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

const std = @import("std");

const Ctx = @import("ctx.zig").Ctx;
const mw = @import("middleware.zig");

/// The middleware. `bytes` is settled while compiling, so nothing is read
/// or formatted per request: the one thing it does is write a field.
pub fn with(comptime bytes: usize) mw.Middleware {
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
