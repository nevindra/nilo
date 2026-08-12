//! A group prefix with a slash on the end, which would double up with the
//! leading slash of every pattern registered inside it.

const zfast = @import("zfast");

export fn refusal() void {
    var app: zfast.App = undefined;
    _ = app.group("/api/");
}
