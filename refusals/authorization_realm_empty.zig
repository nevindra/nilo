//! A Basic realm with nothing in it, which RFC 7617 requires and the browser
//! shows ([ADR 0191](../docs/adr/0191-an-authorization-header-a-handler-can-ask-for.md)).

const nilo = @import("nilo_http");

fn admin(auth: nilo.Authorization(.{ .basic = "" })) []const u8 {
    return auth.user.view();
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/admin", admin) catch {};
}
