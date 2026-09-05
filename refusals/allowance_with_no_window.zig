//! An allowance with nothing to count inside. "A hundred requests" is not a
//! rate until it says a hundred per what.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.allowance.with(.{ .per_window = 100, .window_s = 0 })) catch {};
}
