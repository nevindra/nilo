//! `Query` given the type of a single param rather than a struct of them.

const nilo = @import("nilo");

fn list(page: nilo.Query(u32)) u32 {
    return page.value;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users", list) catch {};
}
