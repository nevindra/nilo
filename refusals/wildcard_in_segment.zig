//! A `*` used as a glob inside a segment. It is a whole segment or nothing.

const nilo = @import("nilo");

fn raw(c: *nilo.Ctx) !void {
    _ = c;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/files/img*", raw) catch {};
}
