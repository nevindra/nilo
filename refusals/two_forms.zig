//! A handler asking for the form twice. A request has one body.

const nilo = @import("nilo_http");

const Account = struct { email: nilo.Str };
const Details = struct { name: nilo.Str };

fn signUp(account: nilo.Form(Account), details: nilo.Form(Details)) u32 {
    _ = account;
    _ = details;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
