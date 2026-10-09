//! A param of the pattern that the `Path(T)` has no field for. A handler with
//! a `*Ctx` may leave it out, since it can `c.param` it.

const nilo = @import("nilo_http");

const Params = struct { org: u32 };

fn member(p: nilo.Path(Params)) u32 {
    return p.value.org;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/orgs/:org/members/:id", member) catch {};
}
