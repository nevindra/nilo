//! Two `Path(T)` arguments: a route has one set of params.

const nilo = @import("nilo_http");

const A = struct { org: u32 };
const B = struct { id: u32 };

fn member(a: nilo.Path(A), b: nilo.Path(B)) u32 {
    return a.value.org + b.value.id;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/orgs/:org/members/:id", member) catch {};
}
