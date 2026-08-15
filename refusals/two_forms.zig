//! A handler asking for the form twice. A request has one body.

const zfast = @import("zfast");

const Account = struct { email: zfast.Str };
const Details = struct { name: zfast.Str };

fn signUp(account: zfast.Form(Account), details: zfast.Form(Details)) u32 {
    _ = account;
    _ = details;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
