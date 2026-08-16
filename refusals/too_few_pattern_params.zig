//! A service asked for by value on a route with no params, so nilo reads
//! it as a path param that the pattern never captures.

const nilo = @import("nilo");

fn show(id: u32) u32 {
    return id;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users", show) catch {};
}
