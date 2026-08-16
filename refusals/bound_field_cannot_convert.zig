//! A form field of a type no form value can become, behind a binding. The
//! same mistake as `form_field_cannot_convert`, and the message names the
//! `Bound(Form(…))` the handler actually wrote rather than the `Form(…)`
//! inside it.

const nilo = @import("nilo");

const SignUp = struct { tags: []const u8 = "" };

fn signUp(incoming: nilo.Bound(nilo.Form(SignUp))) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
