//! A service asked for by value on a route with no params, so zfast reads
//! it as a path param that the pattern never captures.

const zfast = @import("zfast");

fn show(id: u32) u32 {
    return id;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/users", show) catch {};
}
