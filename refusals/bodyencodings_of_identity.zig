//! A route told it reads `identity`, which every route does: the list is for codings nilo does not decode, and naming the one that needs no help is a mistake worth saying aloud.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.bodyEncodings(.{"identity"})) catch {};
}
