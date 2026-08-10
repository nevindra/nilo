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

test {
    _ = @import("str.zig");
    _ = @import("http1.zig");
    _ = @import("router.zig");
    _ = @import("fail.zig");
    _ = @import("service.zig");
    _ = @import("typed.zig");
    _ = @import("ctx.zig");
    _ = @import("app.zig");
}
