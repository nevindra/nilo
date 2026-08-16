//! A group prefix without its leading slash.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    _ = app.group("api");
}
