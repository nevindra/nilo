//! A URL built for a route whose pattern ends in a `*`. The catch-all stands
//! for however much path is left, so there is no one value to put there.

const nilo = @import("nilo_http");

export fn refusal() void {
    var buf: [64]u8 = undefined;
    _ = nilo.url.into(&buf, "/assets/*", .{}) catch {};
}
