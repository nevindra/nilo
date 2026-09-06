//! A URL built from a struct where a path segment goes. A param arrives as
//! text, a number, a bool or an enum, and goes back out as one of those.

const nilo = @import("nilo_http");

const User = struct { id: u32 };

export fn refusal() void {
    var buf: [64]u8 = undefined;
    _ = nilo.url.into(&buf, "/users/:id", .{ .id = User{ .id = 42 } }) catch {};
}
