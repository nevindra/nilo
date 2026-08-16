//! A catch-all with a segment after it, which nothing could ever match.

const nilo = @import("nilo_http");

fn raw(c: *nilo.Ctx) !void {
    _ = c;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/files/*/raw", raw) catch {};
}
