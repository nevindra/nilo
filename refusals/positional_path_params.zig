//! Two ids as bare arguments: swapped, the handler would compile and run a
//! tenant-scoped query with the wrong tenant. The refusal writes the
//! `Path(T)` that reads them by name (ADR 002).

const nilo = @import("nilo_http");

fn member(id: u32, org: u32) u32 {
    return id + org;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/orgs/:org/members/:id", member) catch {};
}
