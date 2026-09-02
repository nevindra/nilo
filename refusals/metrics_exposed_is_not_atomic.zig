//! A plain `u64` handed to `expose`. Handlers run on several threads at
//! once, so a counter that is not atomic loses increments without saying so.

const nilo = @import("nilo_http");

var hits: u64 = 0;

export fn refusal() void {
    var app: nilo.App = undefined;
    app.expose("hits", .counter, &hits) catch {};
}
