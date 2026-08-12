//! A path deeper than zfast matches. The answer is a `*` catch-all.

const zfast = @import("zfast");

fn deep(c: *zfast.Ctx) !void {
    _ = c;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q", deep) catch {};
}
