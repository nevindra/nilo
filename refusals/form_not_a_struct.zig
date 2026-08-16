//! A form read into something that is not a struct, so there are no field
//! names for the form fields to land in.

const nilo = @import("nilo_http");

fn signUp(incoming: nilo.Form(u32)) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
