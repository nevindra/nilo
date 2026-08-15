//! A `Redirect` on a status that carries no `Location`, which no client
//! would follow.

const zfast = @import("zfast");

fn old() zfast.Redirect(200) {
    return .to("/new");
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/old", old) catch {};
}
