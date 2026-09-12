//! A Basic realm with a quote in it, which the quoted-string in
//! `WWW-Authenticate` cannot carry
//! ([ADR 0191](../docs/adr/0191-an-authorization-header-a-handler-can-ask-for.md)).

const nilo = @import("nilo_http");

fn admin(auth: nilo.Authorization(.{ .basic = "say \"hi\"" })) []const u8 {
    return auth.user.view();
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/admin", admin) catch {};
}
