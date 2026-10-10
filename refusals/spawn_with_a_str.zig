//! Spawned work handed a `Str`. The text points into the request arena, which
//! is reset when the request ends, and the fiber outlives the request.

const nilo = @import("nilo_http");

fn audit(who: nilo.Str) void {
    _ = who;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.spawn(audit, .{@as(nilo.Str, undefined)}) catch {};
}
