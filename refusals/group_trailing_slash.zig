//! A group prefix with a slash on the end, which would double up with the
//! leading slash of every pattern registered inside it.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    _ = app.group("/api/");
}
