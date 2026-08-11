//! zfast — an HTTP framework for Zig that puts writing code first. Its
//! vocabulary is in CONTEXT.md, its design decisions in docs/adr/.

pub const App = @import("app.zig").App;

/// What `app.group("/api/v1")` hands back: one prefix and everything
/// registered beneath it. Named here so a plugin can spell out the type it
/// takes instead of using `anytype`.
pub const Group = @import("app.zig").Group;

pub const Ctx = @import("ctx.zig").Ctx;
pub const Str = @import("str.zig").Str;
pub const Method = @import("http1.zig").Method;
pub const Options = @import("bulkhead.zig").Options;

/// One of the two root-file lines, and the one that keeps `std.log` from
/// blocking the event loop:
///
/// ```zig
/// pub const std_options_debug_io = zfast.debug_io;
/// ```
///
/// Note which is which — `debug_io` goes into `std_options_debug_io`, and
/// `std_options` below goes into `std_options`. The two are easy to write
/// the wrong way round, and each fixes a different symptom.
///
/// `listen()` says so at startup if it is missing, because the symptom
/// otherwise is a server that is merely slow.
pub const debug_io = @import("bulkhead.zig").debug_io;

/// The other half of the wiring: `pub const std_options = zfast.std_options;`
///
/// All it does is turn the Engine's debug chatter down to warnings. Without
/// it a debug build opens with `debug(zio): Spawning worker thread 1` and
/// buries your own logs — the Engine is an implementation detail, so it
/// should not be the first thing anybody sees.
///
/// To keep your own settings, start from this one:
///
/// ```zig
/// pub const std_options: std.Options = .{
///     .log_level = .debug,
///     .log_scope_levels = zfast.std_options.log_scope_levels,
/// };
/// ```
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .zio, .level = .warn }},
};

/// A lock for a Service that gets written to. Handlers run concurrently on
/// several OS threads, so shared mutable state needs one — and this is the
/// one to use rather than `std.Thread.Mutex`, which stops the whole thread
/// and every other request being served on it.
///
/// ```zig
/// const Store = struct {
///     lock: zfast.Mutex = .init,
///     users: std.ArrayList(User) = .empty,
/// };
///
/// try store.lock.lock();
/// defer store.lock.unlock();
/// ```
pub const Mutex = @import("bulkhead.zig").Mutex;

/// Run a blocking call without stopping the thread it is on.
///
/// Many requests share one OS thread, so a handler that blocks stops all of
/// them — a database driver, `std.fs`, `std.http.Client`, anything that
/// waits on a syscall. Hand it to this instead and only the one request
/// waits (ADR 0014):
///
/// ```zig
/// fn getUser(db: *Db, id: u32) !User {
///     return zfast.blocking(Db.query, .{ db, id });
/// }
/// ```
///
/// The return value is whatever the function returns, errors included. It
/// allocates nothing, and outside a running server it simply calls the
/// function — so a handler using it is still testable as an ordinary
/// function (ADR 0003).
pub const blocking = @import("bulkhead.zig").blocking;

/// Wait, without stopping the thread. `std.Thread.sleep` would park every
/// other request sharing it; this parks only this one.
///
/// Fails with `error.Canceled` if the request went away while waiting,
/// which maps to a 503 the way `Mutex.lock` does.
pub const sleep = @import("bulkhead.zig").sleep;

/// Fail functions — `fail.notFound("no user {d}", .{id})` and friends,
/// callable from anywhere (ADR 0005).
pub const fail = @import("fail.zig");

/// A response with a status other than 200, headers of its own, or both:
/// `Response(User){ .status = 201, .headers = …, .value = user }`.
pub const Response = @import("typed.zig").Response;

/// One response header, as `Response.headers` takes them.
pub const Header = @import("typed.zig").Header;

/// The headers a `Response` carries, held by value: `.headers = .of(&.{…})`.
/// Copying is the point — a list written in a handler dies with the handler
/// (ADR 0019).
pub const Headers = @import("typed.zig").Headers;

/// A response written in pieces, from `c.stream(status, content_type)` —
/// for a body whose length nobody knows when the head goes out (ADR 0020).
pub const Stream = @import("stream.zig").Stream;

/// A stream of server-sent events, from `c.events()`.
pub const Events = @import("stream.zig").Events;

/// A request body read in pieces, from `c.bodyStream()` — for the ones too
/// big to hold in the request arena (ADR 0020).
pub const Body = @import("body.zig").Body;

/// An open WebSocket connection, from `c.upgrade()` (ADR 0022).
pub const Socket = @import("websocket.zig").Socket;

/// Everything else WebSocket: `Message`, `Kind`, `Close`, `Options`.
pub const websocket = @import("websocket.zig");

/// One message on an event stream: `.{ .name = "token", .data = text }`.
pub const Event = @import("stream.zig").Event;

/// Driving a request into an App from a test, for the handlers that write
/// their answer instead of returning it. Not part of a running server.
pub const testing = @import("testing.zig");

/// The query string, read into a struct of yours — the named counterpart
/// to a positional path param.
///
/// ```zig
/// const Search = struct { q: Str, page: u32 = 1, tag: ?Str = null };
/// fn search(params: zfast.Query(Search)) ![]const Item { … }
/// ```
pub const Query = @import("typed.zig").Query;

pub const Middleware = @import("middleware.zig").Middleware;
pub const Next = @import("middleware.zig").Next;

/// A monotonic clock reading in nanoseconds, for measuring how long
/// something took.
///
/// Zig 0.16's `std.time` carries only constants — no `milliTimestamp`, no
/// `Timer` — and the Engine keeps a clock anyway, so timing a request looks
/// like this rather than like a syscall of your own:
///
/// ```zig
/// fn timing(c: *zfast.Ctx, next: zfast.Next) !void {
///     const started = zfast.monotonicNanos();
///     try next.run(c);
///     const took_us = (zfast.monotonicNanos() - started) / std.time.ns_per_us;
///     std.log.info("{f} took {d}µs", .{ c.path(), took_us });
/// }
/// ```
///
/// Monotonic, so it is the right thing for a duration and the wrong thing
/// for a date: it counts from an arbitrary point, not from the epoch.
pub const monotonicNanos = @import("bulkhead.zig").monotonicNanos;

/// Built-in middleware.
pub const logger = @import("logger.zig");
pub const cors = @import("cors.zig");

/// Static files, held in memory (ADR 0010). Used through `app.static()`;
/// the module itself is here for its `Options`.
pub const static = @import("static.zig");

/// The API description, worked out from the handler signatures (ADR 0017).
/// Switched on with `app.docs(.{ .title = "…" })`; the module is here for
/// its `Options` and for the `Schema` a test might want to look at.
pub const openapi = @import("openapi.zig");

/// Opt in to a panic message that names the request that was in flight,
/// by putting this in your root source file:
///
/// ```zig
/// pub const panic = zfast.panic;
/// ```
///
/// Zig cannot recover from a panic — the process is going down either way
/// (ADR 0008). What this buys is knowing which endpoint took it down, so
/// `panic while handling GET /users/42` replaces a day of guessing.
pub const panic = std.debug.FullPanic(panicNamingRequest);

fn panicNamingRequest(msg: []const u8, first_trace_addr: ?usize) noreturn {
    // If the request is not reachable — outside a request, or a future
    // Engine that clears its task context before the panic handler runs —
    // say nothing rather than guess. A wrong path in a crash log sends you
    // off debugging the wrong endpoint.
    if (fail.inFlight()) |r| {
        if (r.path.len > 0) {
            var buf: [512]u8 = undefined;
            const named = std.fmt.bufPrint(
                &buf,
                "{s} (while handling {s} {s})",
                .{ msg, r.method, r.path },
            ) catch msg;
            std.debug.defaultPanic(named, first_trace_addr);
        }
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

const std = @import("std");

test "a Mutex still works with no Engine under it, so guarded handlers stay testable" {
    var lock: Mutex = .init;
    try lock.lock();
    try std.testing.expect(!lock.tryLock());
    lock.unlock();
    try std.testing.expect(lock.tryLock());
    lock.unlock();
}

fn doubleOrFail(n: u32) !u32 {
    if (n == 0) return fail.badRequest("zero is not a number to double", .{});
    return n * 2;
}

test "blocking runs the call, keeps its errors, and needs no Engine under it" {
    // Outside a server this runs inline, which is the property that keeps a
    // handler using `blocking` testable as an ordinary function (ADR 0003).
    try std.testing.expectEqual(@as(u32, 42), try blocking(doubleOrFail, .{21}));
    try std.testing.expectError(error.Failed, blocking(doubleOrFail, .{0}));
}

test "a fail function inside blocking reaches the request that made the call" {
    // The half of ADR 0014 that has to be got right: on a real server the
    // call runs on a pool worker, which is not the fiber the failure box is
    // bound to, so `blocking` carries the slot across. Here there is no
    // fiber at all and the fallback stands in for one — enough to hold the
    // wiring, while the cross-thread half is what the server itself proves.
    const bulkhead = @import("bulkhead.zig");

    var in_flight = fail.InFlight{};
    in_flight.startRequest("GET", "/users/9");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    try std.testing.expectError(error.Failed, blocking(doubleOrFail, .{0}));
    try std.testing.expectEqual(@as(u16, 400), in_flight.failure.status);
    try std.testing.expectEqualStrings(
        "zero is not a number to double",
        in_flight.failure.message(),
    );

    // And the slot the call was handed is put back, so it cannot leak into
    // whatever this thread picks up next.
    try std.testing.expect(bulkhead.slot() == @as(*anyopaque, @ptrCast(&in_flight)));
}

test {
    _ = @import("str.zig");
    _ = @import("percent.zig");
    _ = @import("http1.zig");
    _ = @import("json.zig");
    _ = @import("scan.zig");
    _ = @import("static.zig");
    _ = @import("router.zig");
    _ = @import("fail.zig");
    _ = @import("service.zig");
    _ = @import("resolve.zig");
    _ = @import("openapi.zig");
    _ = @import("stream.zig");
    _ = @import("body.zig");
    _ = @import("range.zig");
    _ = @import("websocket.zig");
    _ = @import("testing.zig");
    _ = @import("middleware.zig");
    _ = @import("typed.zig");
    _ = @import("ctx.zig");
    _ = @import("logger.zig");
    _ = @import("cors.zig");
    _ = @import("app.zig");
}
