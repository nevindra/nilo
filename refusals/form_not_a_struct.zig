//! A form read into something that is not a struct, so there are no field
//! names for the form fields to land in.

const zfast = @import("zfast");

fn signUp(incoming: zfast.Form(u32)) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
