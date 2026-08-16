//! A binding wrapped in a binding. There is one way for a field to fail and
//! one place the failures go, so the second wrapper has nothing to add.

const nilo = @import("nilo_http");

const SignUp = struct { email: nilo.Str };

fn signUp(incoming: nilo.Bound(nilo.Bound(nilo.Form(SignUp)))) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
