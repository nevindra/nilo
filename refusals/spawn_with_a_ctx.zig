//! Spawned work handed the request it was started from. A `*Ctx` is gone
//! when the response is sent.

const nilo = @import("nilo_http");

fn audit(c: *nilo.Ctx) void {
    _ = c;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.spawn(audit, .{@as(*nilo.Ctx, undefined)}) catch {};
}
