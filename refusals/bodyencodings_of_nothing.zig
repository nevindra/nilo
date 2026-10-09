//! An empty list: the middleware would do nothing, and a route that reads no coding leaves it off.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.bodyEncodings(.{})) catch {};
}
