//! A URL built for a pattern whose second param nobody gave a value for.
//! `:slug` is in the pattern and not in the struct, so the URL would come out
//! with a literal `:slug` in it.

const nilo = @import("nilo_http");

export fn refusal() void {
    var buf: [64]u8 = undefined;
    _ = nilo.url.into(&buf, "/users/:id/posts/:slug", .{ .id = 42 }) catch {};
}
