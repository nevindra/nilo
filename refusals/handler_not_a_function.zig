//! The handler called instead of named — the mistake `app.get("/", index())`
//! makes, here in its plainest form.

const zfast = @import("zfast");

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/", 42) catch {};
}
