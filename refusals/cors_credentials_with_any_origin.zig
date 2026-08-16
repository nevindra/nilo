//! Credentials and `*` together, which every browser rejects — and rejects
//! as a CORS error that says nothing about the real cause.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.cors.with(.{ .origin = "*", .credentials = true })) catch {};
}
