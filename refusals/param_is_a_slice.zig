//! Text from a request asked for as a bare slice instead of a `Str`.

const nilo = @import("nilo_http");

fn greet(name: []const u8) []const u8 {
    return name;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/greet/:name", greet) catch {};
}
