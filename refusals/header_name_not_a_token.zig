//! A header name with a space in it. It can never match anything on the wire,
//! and the generated document would carry it verbatim
//! ([ADR 0163](../docs/adr/0163-a-header-a-handler-can-be-given.md)).

const nilo = @import("nilo_http");

fn who(actor: nilo.FromHeader("X Staff Id", u32)) u32 {
    return actor.value;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/thing", who) catch {};
}
