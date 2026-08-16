//! A param written the way a Rails route spells it, so the colon lands in
//! the middle of the segment and is matched as literal text.

const nilo = @import("nilo");

fn show(id: u32) u32 {
    return id;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users/id:id", show) catch {};
}
