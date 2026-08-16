//! Two params under one name, copied from the line above and not renamed.

const nilo = @import("nilo_http");

fn show(user: u32, pet: u32) u32 {
    return user + pet;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users/:id/pets/:id", show) catch {};
}
