//! A name longer than the RateLimit line built for it can hold.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.allowance.with(.{ .per_window = 5, .name = "a-name-much-longer-than-the-header-line-has-room-for" })) catch {};
}
