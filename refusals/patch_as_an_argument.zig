//! A `Patch` asked for as an argument. It is a field of a body, not a body.

const nilo = @import("nilo");

fn edit(id: u32, name: nilo.Patch(nilo.Str)) u32 {
    _ = name;
    return id;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.patch("/users/:id", edit) catch {};
}
