//! The handler called instead of named — the mistake `app.get("/", index())`
//! makes, here in its plainest form.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/", 42) catch {};
}
