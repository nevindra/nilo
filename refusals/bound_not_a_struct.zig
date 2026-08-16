//! A binding of something that is not a struct. A binding records an outcome
//! per field, and a `u32` has no fields to record anything against.

const zfast = @import("zfast");

fn signUp(incoming: zfast.Bound(u32)) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
