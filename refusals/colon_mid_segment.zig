//! A param written the way a Rails route spells it, so the colon lands in
//! the middle of the segment and is matched as literal text.

const zfast = @import("zfast");

fn show(id: u32) u32 {
    return id;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/users/id:id", show) catch {};
}
