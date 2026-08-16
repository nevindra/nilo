//! More captures on one route than nilo holds per request.

const nilo = @import("nilo");

fn deep(c: *nilo.Ctx) !void {
    _ = c;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/:a/:b/:c/:d/:e/:f/:g/:h/:i", deep) catch {};
}
