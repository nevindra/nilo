//! One argument for two captures. Params are matched by position, so `:pet`
//! would never be read.

const zfast = @import("zfast");

fn show(user: u32) u32 {
    return user;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/users/:user/pets/:pet", show) catch {};
}
