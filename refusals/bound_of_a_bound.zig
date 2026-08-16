//! A binding wrapped in a binding. There is one way for a field to fail and
//! one place the failures go, so the second wrapper has nothing to add.

const zfast = @import("zfast");

const SignUp = struct { email: zfast.Str };

fn signUp(incoming: zfast.Bound(zfast.Bound(zfast.Form(SignUp)))) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
