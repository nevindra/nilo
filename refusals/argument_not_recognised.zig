//! An argument of a type that is none of the things a handler may ask for.

const nilo = @import("nilo");

fn show(raw: [4]u8) u8 {
    return raw[0];
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users/:id", show) catch {};
}
