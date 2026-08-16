//! A form field of a type no form value can become.

const nilo = @import("nilo_http");

const SignUp = struct { tags: []const u8 = "" };

fn signUp(incoming: nilo.Form(SignUp)) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
