//! A `Path(T)` field that is spelled differently from the `:name` it means.
//! The refusal lists the route's params and suggests the one left over.

const nilo = @import("nilo_http");

const Params = struct { org: u32, ident: u32 };

fn member(p: nilo.Path(Params)) u32 {
    return p.value.org + p.value.ident;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/orgs/:org/members/:id", member) catch {};
}
