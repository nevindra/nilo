//! A route named the way the path reads rather than the way a method does, so
//! the operationId is something no client generator can turn into a name.

const nilo = @import("nilo_http");

fn show(id: u32) u32 {
    return id;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.named("add partner-capability").get("/users/:id", show) catch {};
}
