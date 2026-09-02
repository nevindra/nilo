//! `*` next to a name it already covers. One of the two is not doing
//! anything, and which one the author meant is not guessable.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.cors.with(.{ .origins = &.{ "*", "https://example.com" } })) catch {};
}
