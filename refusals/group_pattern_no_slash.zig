//! A pattern inside a group written as if it were joined by the group.

const nilo = @import("nilo");

fn index() []const u8 {
    return "";
}

export fn refusal() void {
    var app: nilo.App = undefined;
    const api = app.group("/api");
    api.get("users", index) catch {};
}
