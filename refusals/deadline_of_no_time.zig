//! A deadline of zero. Every request on the route would already have run out
//! before the handler was called, which is a route that answers 503 and not a
//! budget — and zero is what somebody writes when they mean "no deadline",
//! where the answer is to leave the middleware off.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.deadline(0)) catch {};
}
