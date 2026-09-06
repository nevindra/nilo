//! A URL built with a value for a param the pattern does not have — a
//! renamed route, or a typo, and either way the value goes nowhere.

const nilo = @import("nilo_http");

export fn refusal() void {
    var buf: [64]u8 = undefined;
    _ = nilo.url.into(&buf, "/users/:id", .{ .id = 42, .slug = "hello" }) catch {};
}
