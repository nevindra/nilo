//! A route registered with no pattern at all.

const nilo = @import("nilo_http");

fn index() []const u8 {
    return "";
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("", index) catch {};
}
