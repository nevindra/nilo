//! An empty list, which matches nothing — so every cross-origin request would
//! be refused by a middleware that was installed to allow them.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.cors.with(.{ .origins = &.{} })) catch {};
}
