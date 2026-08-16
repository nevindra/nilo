//! A bound form beside a plain one. A binding occupies the slot it binds, so
//! this is asking for the form twice — and the message says so, rather than
//! treating the binding as some other kind of argument.

const zfast = @import("zfast");

const SignUp = struct { email: zfast.Str };
const Extra = struct { referrer: zfast.Str };

fn signUp(incoming: zfast.Bound(zfast.Form(SignUp)), also: zfast.Form(Extra)) u32 {
    _ = incoming;
    _ = also;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
