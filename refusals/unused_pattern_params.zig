//! One argument for two captures. Params are matched by position, so `:pet`
//! would never be read.

const nilo = @import("nilo_http");

fn show(user: u32) u32 {
    return user;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users/:user/pets/:pet", show) catch {};
}
