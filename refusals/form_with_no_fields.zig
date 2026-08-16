//! A form with nothing in it, which would read nothing whatever was sent.

const nilo = @import("nilo");

const Empty = struct {};

fn signUp(incoming: nilo.Form(Empty)) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
