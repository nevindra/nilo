//! A session that is not a struct, so there are no field names for the
//! remembered values to live in.

const zfast = @import("zfast");

fn me(s: zfast.Session(u32)) u32 {
    _ = s;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/me", me) catch {};
}
