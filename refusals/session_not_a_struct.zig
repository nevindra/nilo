//! A session that is not a struct, so there are no field names for the
//! remembered values to live in.

const nilo = @import("nilo_http");

fn me(s: nilo.Session(u32)) u32 {
    _ = s;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/me", me) catch {};
}
