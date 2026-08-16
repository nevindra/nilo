//! The leading slash left off, which is how the path is spelled in a
//! router that takes them without one.

const nilo = @import("nilo_http");

fn index() []const u8 {
    return "";
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("users", index) catch {};
}
