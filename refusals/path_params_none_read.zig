//! A route with two params whose handler reads none of them and has no
//! `*Ctx` to fetch them with (ADR 002).

const nilo = @import("nilo_http");

fn nothing() u32 {
    return 1;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/orgs/:org/members/:id", nothing) catch {};
}
