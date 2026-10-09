//! A name that is nothing, which no `Content-Encoding` header can be.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.bodyEncodings(.{""})) catch {};
}
