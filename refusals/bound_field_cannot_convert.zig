//! A form field of a type no form value can become, behind a binding. The
//! same mistake as `form_field_cannot_convert`, and the message names the
//! `Bound(Form(…))` the handler actually wrote rather than the `Form(…)`
//! inside it.

const zfast = @import("zfast");

const SignUp = struct { tags: []const u8 = "" };

fn signUp(incoming: zfast.Bound(zfast.Form(SignUp))) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
