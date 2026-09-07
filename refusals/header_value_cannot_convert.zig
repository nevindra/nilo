//! A header asked for as a type request text cannot become. A header arrives
//! as text, the same as a query param does, so the set of types it can be read
//! into is the same one
//! ([ADR 0163](../docs/adr/0163-a-header-a-handler-can-be-given.md)).

const nilo = @import("nilo_http");

const Actor = struct { id: u32 };

fn who(actor: nilo.FromHeader("X-Staff-Id", Actor)) u32 {
    return actor.value.id;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/thing", who) catch {};
}
