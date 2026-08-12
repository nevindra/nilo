//! More captures on one route than zfast holds per request.

const zfast = @import("zfast");

fn deep(c: *zfast.Ctx) !void {
    _ = c;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/:a/:b/:c/:d/:e/:f/:g/:h/:i", deep) catch {};
}
