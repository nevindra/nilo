//! A bearer token that is not a struct, so there are no field names for the
//! values it carries to live in.

const nilo = @import("nilo_http");

fn me(b: nilo.Bearer(u32)) u32 {
    _ = b;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/me", me) catch {};
}
