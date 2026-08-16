//! A pointer that is not to a single value, so it is not a service either.

const nilo = @import("nilo_http");

fn greet(name: [*]const u8) u8 {
    return name[0];
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/greet/:name", greet) catch {};
}
