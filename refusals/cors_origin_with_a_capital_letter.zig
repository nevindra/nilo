//! An origin a browser could never send. Scheme and host are lowercased
//! before an `Origin` header goes out, so this one matches nothing and the
//! browser refuses the response without saying why.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.cors.with(.{ .origins = &.{"https://Example.com"} })) catch {};
}
