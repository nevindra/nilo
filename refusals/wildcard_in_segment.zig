//! A `*` used as a glob inside a segment. It is a whole segment or nothing.

const zfast = @import("zfast");

fn raw(c: *zfast.Ctx) !void {
    _ = c;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/files/img*", raw) catch {};
}
