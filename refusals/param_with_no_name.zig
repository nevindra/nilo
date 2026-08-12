//! A colon with nothing after it, so nothing can look the param up.

const zfast = @import("zfast");

fn show(id: u32) u32 {
    return id;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/users/:", show) catch {};
}
