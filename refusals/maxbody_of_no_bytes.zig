//! A body limit of zero. Every body on the route would be a 413 before a byte
//! was read, which is a route that refuses bodies and not a budget — and zero
//! is what somebody writes when they mean "no limit", where the answer is to
//! leave the middleware off.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.maxBody(0)) catch {};
}
