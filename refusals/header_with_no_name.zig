//! A `FromHeader` that names no header, which is a lookup with nothing to look
//! up ([ADR 0163](../docs/adr/0163-a-header-a-handler-can-be-given.md)).

const nilo = @import("nilo_http");

fn who(actor: nilo.FromHeader("", u32)) u32 {
    return actor.value;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/thing", who) catch {};
}
