//! A form with nothing in it, which would read nothing whatever was sent.

const zfast = @import("zfast");

const Empty = struct {};

fn signUp(incoming: zfast.Form(Empty)) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
