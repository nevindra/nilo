//! One argument for two captures. A bare argument cannot say which `:name`
//! it is, so a route with two params is read by name, with `Path(T)` (ADR 002).

const nilo = @import("nilo_http");

fn show(user: u32) u32 {
    return user;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users/:user/pets/:pet", show) catch {};
}
