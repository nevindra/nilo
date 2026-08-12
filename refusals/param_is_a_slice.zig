//! Text from a request asked for as a bare slice instead of a `Str`.

const zfast = @import("zfast");

fn greet(name: []const u8) []const u8 {
    return name;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/greet/:name", greet) catch {};
}
