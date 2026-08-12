//! A `Patch` asked for as an argument. It is a field of a body, not a body.

const zfast = @import("zfast");

fn edit(id: u32, name: zfast.Patch(zfast.Str)) u32 {
    _ = name;
    return id;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.patch("/users/:id", edit) catch {};
}
