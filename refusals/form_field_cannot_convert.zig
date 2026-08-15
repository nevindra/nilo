//! A form field of a type no form value can become.

const zfast = @import("zfast");

const SignUp = struct { tags: []const u8 = "" };

fn signUp(incoming: zfast.Form(SignUp)) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
