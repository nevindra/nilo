//! A bound form beside a plain one. A binding occupies the slot it binds, so
//! this is asking for the form twice — and the message says so, rather than
//! treating the binding as some other kind of argument.

const nilo = @import("nilo_http");

const SignUp = struct { email: nilo.Str };
const Extra = struct { referrer: nilo.Str };

fn signUp(incoming: nilo.Bound(nilo.Form(SignUp)), also: nilo.Form(Extra)) u32 {
    _ = incoming;
    _ = also;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
