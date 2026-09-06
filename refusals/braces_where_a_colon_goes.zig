//! A route spelled the way OpenAPI prints it, so the braces land in the
//! pattern and the five characters are matched as literal text.

const nilo = @import("nilo_http");

fn show(id: u32) u32 {
    return id;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users/{id}", show) catch {};
}
