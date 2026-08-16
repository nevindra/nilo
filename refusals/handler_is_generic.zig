//! A handler still holding an `anytype`, so it has no argument types to match.

const nilo = @import("nilo");

fn show(id: anytype) u32 {
    return id;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users/:id", show) catch {};
}
