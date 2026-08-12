//! A catch-all with a segment after it, which nothing could ever match.

const zfast = @import("zfast");

fn raw(c: *zfast.Ctx) !void {
    _ = c;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/files/*/raw", raw) catch {};
}
