//! A pointer that is not to a single value, so it is not a service either.

const zfast = @import("zfast");

fn greet(name: [*]const u8) u8 {
    return name[0];
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/greet/:name", greet) catch {};
}
