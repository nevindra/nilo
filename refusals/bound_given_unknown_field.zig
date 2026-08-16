//! Asking a binding for the text of a field the struct does not have. A form
//! putting itself back on the page reads every box by name, and a typo there
//! would otherwise be an empty box nobody notices.

const nilo = @import("nilo");

const SignUp = struct { email: nilo.Str, age: u32 };

fn signUp(incoming: nilo.Bound(nilo.Form(SignUp))) nilo.Str {
    return incoming.given("e_mail");
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
