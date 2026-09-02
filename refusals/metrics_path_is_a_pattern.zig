//! A metrics path with a param in it. The page is one address something
//! scrapes on a timer, not a family of them.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.metrics(.{ .path = "/metrics/:name" }) catch {};
}
