//! Asking a binding for the text of a field the struct does not have. A form
//! putting itself back on the page reads every box by name, and a typo there
//! would otherwise be an empty box nobody notices.

const zfast = @import("zfast");

const SignUp = struct { email: zfast.Str, age: u32 };

fn signUp(incoming: zfast.Bound(zfast.Form(SignUp))) zfast.Str {
    return incoming.given("e_mail");
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
