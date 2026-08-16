//! A path param made optional, as if the route could match without it.

const nilo = @import("nilo");

fn show(id: ?u32) u32 {
    return id orelse 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users/:id", show) catch {};
}
