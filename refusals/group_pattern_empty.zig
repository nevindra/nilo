//! An empty pattern inside a group, meaning to register the group itself.

const nilo = @import("nilo_http");

fn index() []const u8 {
    return "";
}

export fn refusal() void {
    var app: nilo.App = undefined;
    const api = app.group("/api");
    api.get("", index) catch {};
}
