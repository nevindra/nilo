//! A `Redirect` on a status that carries no `Location`, which no client
//! would follow.

const nilo = @import("nilo");

fn old() nilo.Redirect(200) {
    return .to("/new");
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/old", old) catch {};
}
