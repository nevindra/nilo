//! A path param made optional, as if the route could match without it.

const zfast = @import("zfast");

fn show(id: ?u32) u32 {
    return id orelse 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/users/:id", show) catch {};
}
