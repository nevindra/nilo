//! zfast — an HTTP framework for Zig that puts writing code first. Its
//! vocabulary is in CONTEXT.md, its design decisions in docs/adr/.

pub const App = @import("app.zig").App;
pub const Ctx = @import("ctx.zig").Ctx;
pub const Str = @import("str.zig").Str;
pub const Method = @import("http1.zig").Method;
pub const Options = @import("bulkhead.zig").Options;

/// Fail functions — `fail.notFound("no user {d}", .{id})` and friends,
/// callable from anywhere (ADR 0005).
pub const fail = @import("fail.zig");

/// A response with a status other than 200: `Response(User){ .status = 201, … }`.
pub const Response = @import("typed.zig").Response;

pub const Middleware = @import("middleware.zig").Middleware;
pub const Next = @import("middleware.zig").Next;

/// Built-in middleware.
pub const logger = @import("logger.zig");
pub const cors = @import("cors.zig");

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

test {
    _ = @import("str.zig");
    _ = @import("http1.zig");
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
