//! A path param on a route that matched is always there, so an optional field
//! means nothing.

const nilo = @import("nilo_http");

const Params = struct { id: ?u32 };

fn member(p: nilo.Path(Params)) u32 {
    return p.value.id orelse 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/members/:id", member) catch {};
}
