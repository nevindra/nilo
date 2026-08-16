//! A path deeper than nilo matches. The answer is a `*` catch-all.

const nilo = @import("nilo_http");

fn deep(c: *nilo.Ctx) !void {
    _ = c;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q", deep) catch {};
}
