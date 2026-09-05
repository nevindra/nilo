//! An allowance of zero. A route nobody may ever reach is a route that is not
//! registered, or one that answers 403 — it is not a limit, and reading it as
//! one would mean the first request of the day is refused.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.allowance.with(.{ .per_window = 0, .window_s = 60 })) catch {};
}
