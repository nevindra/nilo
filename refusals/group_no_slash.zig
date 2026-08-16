//! A group prefix without its leading slash.

const nilo = @import("nilo");

export fn refusal() void {
    var app: nilo.App = undefined;
    _ = app.group("api");
}
