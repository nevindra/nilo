//! zfast — an HTTP framework for Zig that puts writing code first. Its
//! vocabulary is in CONTEXT.md, its design decisions in docs/adr/.

pub const App = @import("app.zig").App;
pub const Ctx = @import("ctx.zig").Ctx;
pub const Str = @import("str.zig").Str;
pub const Method = @import("http1.zig").Method;
pub const Options = @import("bulkhead.zig").Options;

/// Wire this into your root file so `std.log` does not block the event
/// loop: `pub const std_options_debug_io = zfast.debug_io;`
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

/// Fail functions — `fail.notFound("no user {d}", .{id})` and friends,
/// callable from anywhere (ADR 0005).
pub const fail = @import("fail.zig");

/// A response with a status other than 200, headers of its own, or both:
/// `Response(User){ .status = 201, .headers = …, .value = user }`.
pub const Response = @import("typed.zig").Response;

/// One response header, as `Response.headers` takes them.
pub const Header = @import("typed.zig").Header;

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

/// Built-in middleware.
pub const logger = @import("logger.zig");
pub const cors = @import("cors.zig");

/// Static files, held in memory (ADR 0010). Used through `app.static()`;
/// the module itself is here for its `Options`.
pub const static = @import("static.zig");

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

test {
    _ = @import("str.zig");
    _ = @import("percent.zig");
    _ = @import("http1.zig");
    _ = @import("static.zig");
    _ = @import("router.zig");
    _ = @import("fail.zig");
    _ = @import("service.zig");
    _ = @import("middleware.zig");
    _ = @import("typed.zig");
    _ = @import("ctx.zig");
    _ = @import("logger.zig");
    _ = @import("cors.zig");
    _ = @import("app.zig");
}
