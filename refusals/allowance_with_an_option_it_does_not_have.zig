//! A misspelt option. The options are read from a struct literal of any
//! shape so that a number or the address of one can stand for a count, and
//! a field the options do not have is therefore a refusal of its own.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.allowance.with(.{ .perwindow = 5, .window_s = 60 })) catch {};
}
