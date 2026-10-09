//! A `Path(T)` beside a bare path param: the route's params are read one way.

const nilo = @import("nilo_http");

const Params = struct { id: u32 };

fn member(id: u32, p: nilo.Path(Params)) u32 {
    return id + p.value.id;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/members/:id", member) catch {};
}
