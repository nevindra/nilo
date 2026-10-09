//! `Path(u32)`: the params are read into a struct, one field per `:name`.

const nilo = @import("nilo_http");

fn member(p: nilo.Path(u32)) u32 {
    return p.value;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/members/:id", member) catch {};
}
